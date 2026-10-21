import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const NIL = '00000000-0000-0000-0000-000000000000';
const round2 = (n: number) => Math.round(n * 100) / 100;
const round3 = (n: number) => Math.round(n * 1000) / 1000;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const blankToNull = (v: unknown) => (v === '' ? null : v);
const nullableId = z.preprocess(blankToNull, z.uuid().nullable().optional());
const nullableDate = z.preprocess(blankToNull, dateField.nullable().optional());
const STATUSES = ['planning', 'active', 'on_hold', 'completed'] as const;
const MAX_AMOUNT = 1e12;

const projectFields = {
  clientPartyId: nullableId,
  managerUserId: nullableId,
  status: z.enum(STATUSES).optional(),
  startDate: nullableDate,
  endDate: nullableDate,
  contractValue: moneyField.optional(),
  siteIds: z.array(z.uuid()).max(200).nullable().optional(),
};
const createBody = z.object({
  ...projectFields,
  code: z.string().trim().min(1, 'Required').max(30),
  name: z.string().trim().min(2).max(200),
  address: optionalText(500),
});
const patchBody = z.object({
  ...projectFields,
  code: z.string().trim().min(1, 'Required').max(30).optional(),
  name: z.string().trim().min(2).max(200).optional(),
  address: nullableText(500),
});
const listQuery = pagingQuery.extend({ status: z.enum(STATUSES).optional() });
const costsQuery = z.object({ from: dateField.optional(), to: dateField.optional() });

const boqFields = {
  code: z.string().trim().min(1, 'Required').max(30),
  description: z.string().trim().min(1, 'Required').max(1000),
  unit: z.string().trim().min(1, 'Required').max(20),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
  rate: moneyField,
  materialBudget: moneyField.optional(),
  labourBudget: moneyField.optional(),
  otherBudget: moneyField.optional(),
  sortOrder: z.number().int().min(0).max(1_000_000).optional(),
};
const boqLineBody = z.object(boqFields)
  .refine((l) => l.qty * l.rate <= MAX_AMOUNT, { message: 'Amount is too large', path: ['rate'] });
const boqBulkBody = z.object({ lines: z.array(boqLineBody).min(1, 'Add at least one line').max(500, 'At most 500 lines') });
const boqPatchBody = z.object({
  code: boqFields.code.optional(),
  description: boqFields.description.optional(),
  unit: boqFields.unit.optional(),
  qty: boqFields.qty.optional(),
  rate: boqFields.rate.optional(),
  materialBudget: boqFields.materialBudget,
  labourBudget: boqFields.labourBudget,
  otherBudget: boqFields.otherBudget,
  sortOrder: boqFields.sortOrder,
});
const boqListQuery = pagingQuery;

type BoqInput = z.infer<typeof boqLineBody>;

// ---------------------------------------------------------------------------------------------
// Helpers shared with indents, issues and DPRs.

/** Projects the caller may see: any of its sites in scope (projects without sites: unscoped users only). */
export async function getProject(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('projects').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const project = await q.executeTakeFirst();
  if (!project) throw notFound('Project');
  const scope = scopedLocationIds(ctx);
  if (scope) {
    const site = await tx.selectFrom('locations').select('id').where('project_id', '=', id).where('id', 'in', scope).executeTakeFirst();
    if (!site) throw notFound('Project');
  }
  return project;
}

/**
 * Checks that BOQ lines belong to the project of a location; returns them by id.
 * `refs` pairs each id with the request field to report on.
 */
export async function boqLinesAt(
  tx: Tx, location: { project_id: string | null; name: string }, refs: { id: string; field: string }[],
) {
  const ids = [...new Set(refs.map((r) => r.id))];
  const rows = ids.length
    ? await tx.selectFrom('boq_lines').select(['id', 'code', 'unit', 'project_id']).where('id', 'in', ids).execute()
    : [];
  const byId = new Map(rows.map((r) => [r.id, r]));
  for (const ref of refs) {
    const line = byId.get(ref.id);
    if (!line || !location.project_id || line.project_id !== location.project_id) {
      throw badRequest(`This BOQ line is not part of the project of ${location.name}.`, { [ref.field]: 'Not in this project' });
    }
  }
  return byId;
}

/** Quantities reported done on approved DPRs, per BOQ line of the given projects. */
function executedQtys(tx: Tx, projectIds: string[]) {
  return tx.selectFrom('dpr_work as w').innerJoin('dprs as d', 'd.id', 'w.dpr_id')
    .innerJoin('boq_lines as bl', 'bl.id', 'w.boq_line_id')
    .select((eb) => ['w.boq_line_id', eb.fn.sum<number>('w.qty').as('executed')])
    .where('d.status', '=', 'approved').where('w.qty', 'is not', null)
    .where('bl.project_id', 'in', projectIds.length ? projectIds : [NIL])
    .groupBy('w.boq_line_id');
}

function boqSelect(tx: Tx, projectId: string) {
  return tx.selectFrom('boq_lines as b')
    .leftJoin(executedQtys(tx, [projectId]).as('e'), 'e.boq_line_id', 'b.id')
    .selectAll('b')
    .select(sql<number>`coalesce(e.executed, 0)`.as('executed_qty'))
    .where('b.project_id', '=', projectId);
}

type BoqRow = Awaited<ReturnType<ReturnType<typeof boqSelect>['executeTakeFirstOrThrow']>>;

const progressOf = (executed: number, qty: number) => (qty > 0 ? round2(Math.min((executed / qty) * 100, 100)) : 0);

function boqJson(r: BoqRow) {
  const executedQty = round3(Number(r.executed_qty));
  return {
    id: r.id, projectId: r.project_id, code: r.code, description: r.description, unit: r.unit, qty: r.qty, rate: r.rate,
    amount: r.amount, materialBudget: r.material_budget, labourBudget: r.labour_budget, otherBudget: r.other_budget,
    executedQty, progressPct: progressOf(executedQty, r.qty), sortOrder: r.sort_order,
  };
}

async function loadBoqLines(tx: Tx, projectId: string, ids: string[]) {
  if (!ids.length) return [];
  const rows = await boqSelect(tx, projectId).where('b.id', 'in', ids).execute();
  return ids.map((id) => boqJson(rows.find((r) => r.id === id)!));
}

/** Projects as JSON, in the order of `ids`. Visibility is checked by the caller. */
async function loadProjects(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const rows = await tx.selectFrom('projects as p')
    .leftJoin('parties as c', 'c.id', 'p.client_party_id')
    .leftJoin('users as m', 'm.id', 'p.manager_user_id')
    .selectAll('p').select(['c.name as client_name', 'm.name as manager_name'])
    .where('p.id', 'in', ids).execute();
  const sites = await tx.selectFrom('locations').select(['id', 'name', 'project_id'])
    .where('project_id', 'in', ids).orderBy('name').execute();
  const totals = await tx.selectFrom('boq_lines as b')
    .leftJoin(executedQtys(tx, ids).as('e'), 'e.boq_line_id', 'b.id')
    .select([
      'b.project_id',
      sql<number>`coalesce(sum(b.amount), 0)`.as('budget'),
      sql<number>`coalesce(sum(b.amount * least(coalesce(e.executed, 0) / b.qty, 1)), 0)`.as('done'),
    ])
    .where('b.project_id', 'in', ids).groupBy('b.project_id').execute();
  return ids.map((id) => {
    const p = rows.find((r) => r.id === id)!;
    const t = totals.find((x) => x.project_id === id);
    const budget = Number(t?.budget ?? 0);
    const done = Number(t?.done ?? 0);
    return {
      id: p.id, companyId: p.company_id, code: p.code, name: p.name, clientPartyId: p.client_party_id,
      clientName: p.client_name, managerUserId: p.manager_user_id, managerName: p.manager_name, status: p.status,
      startDate: p.start_date, endDate: p.end_date, contractValue: p.contract_value, address: p.address,
      sites: sites.filter((s) => s.project_id === id).map((s) => ({ id: s.id, name: s.name })),
      budgetTotal: round2(budget), progressPct: budget > 0 ? round2((done / budget) * 100) : 0,
      createdAt: p.created_at,
    };
  });
}

async function checkRefs(tx: Tx, ctx: RequestContext, body: { clientPartyId?: string | null; managerUserId?: string | null }) {
  if (body.clientPartyId) {
    const party = await tx.selectFrom('parties').select(['id', 'type'])
      .where('id', '=', body.clientPartyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!party) throw badRequest('Client not found.', { clientPartyId: 'Not found' });
    if (party.type === 'vendor') throw badRequest('Choose a customer as the client.', { clientPartyId: 'Not a customer' });
  }
  if (body.managerUserId) {
    const member = await tx.selectFrom('user_roles').select('user_id')
      .where('user_id', '=', body.managerUserId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!member) throw badRequest('Project manager not found.', { managerUserId: 'Not a user of this company' });
  }
}

/** Replaces the sites of a project. A site belongs to at most one project. */
async function setSites(tx: Tx, ctx: RequestContext, projectId: string, wanted: string[]) {
  const ids = [...new Set(wanted)];
  const current = (await tx.selectFrom('locations').select('id').where('project_id', '=', projectId).forUpdate().execute()).map((r) => r.id);
  const found = ids.length
    ? await tx.selectFrom('locations').select(['id', 'name', 'type', 'project_id'])
      .where('company_id', '=', ctx.companyId).where('id', 'in', ids).forUpdate().execute()
    : [];
  if (found.length !== ids.length) throw badRequest('One or more sites were not found.', { siteIds: 'Not found' });
  const notSite = found.find((l) => l.type !== 'site');
  if (notSite) throw badRequest(`${notSite.name} is not a site.`, { siteIds: 'Only sites can be linked' });
  const taken = found.find((l) => l.project_id !== null && l.project_id !== projectId);
  if (taken) {
    const other = await tx.selectFrom('projects').select('code').where('id', '=', taken.project_id!).executeTakeFirst();
    throw conflict(`${taken.name} already belongs to project ${other?.code ?? ''}.`.replace(' .', '.'), 'CONFLICT',
      { siteIds: 'Already in another project' });
  }
  const added = ids.filter((id) => !current.includes(id));
  const removed = current.filter((id) => !ids.includes(id));
  if ([...added, ...removed].some((id) => !ctx.canAccessLocation(id))) {
    throw forbidden('You can only link or unlink sites you have access to.');
  }
  if (removed.length) await tx.updateTable('locations').set({ project_id: null }).where('id', 'in', removed).execute();
  if (added.length) await tx.updateTable('locations').set({ project_id: projectId }).where('id', 'in', added).execute();
  return { added, removed };
}

function codeConflict(err: unknown, message: string): never {
  if ((err as { code?: string }).code === '23505') throw conflict(message, 'CONFLICT', { code: 'Already used' });
  throw err;
}

// ---------------------------------------------------------------------------------------------

export async function projectRoutes(app: FastifyInstance) {
  app.get('/projects', async (req) => {
    const ctx = req.ctx;
    ctx.require('projects.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('projects as p').where('p.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) {
        base = base.where((eb) => eb.exists(eb.selectFrom('locations as s').select('s.id')
          .whereRef('s.project_id', '=', 'p.id').where('s.id', 'in', scope)));
      }
      if (q.status) base = base.where('p.status', '=', q.status);
      if (q.q) base = base.where((eb) => eb.or([eb('p.code', 'ilike', likeTerm(q.q!)), eb('p.name', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('p.id').orderBy('p.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadProjects(tx, ids.map((r) => r.id)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/projects/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('projects.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await getProject(tx, ctx, id);
      return (await loadProjects(tx, [id]))[0];
    });
  });

  app.post('/projects', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('projects.manage');
    const body = parse(createBody, req.body);
    const siteIds = body.siteIds ?? [];
    if (ctx.company.locationIds !== null && !siteIds.length) {
      throw forbidden('Link at least one of your sites to the project.');
    }
    if (body.startDate && body.endDate && body.endDate < body.startDate) {
      throw badRequest('The end date is before the start date.', { endDate: 'Before the start date' });
    }
    try {
      const project = await ctx.tx(async (tx) => {
        await checkRefs(tx, ctx, body);
        const row = await tx.insertInto('projects').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, code: body.code, name: body.name,
          client_party_id: body.clientPartyId ?? null, manager_user_id: body.managerUserId ?? null,
          status: body.status ?? 'planning', start_date: body.startDate ?? null, end_date: body.endDate ?? null,
          contract_value: body.contractValue ?? 0, address: body.address ?? null, created_by: ctx.userId,
        }).returning('id').executeTakeFirstOrThrow();
        await setSites(tx, ctx, row.id, siteIds);
        const saved = (await loadProjects(tx, [row.id]))[0]!;
        await writeAudit(tx, auditOf(ctx), 'project', row.id, 'create', null, saved);
        return saved;
      });
      return reply.status(201).send(project);
    } catch (err) {
      codeConflict(err, 'A project with this code already exists.');
    }
  });

  app.patch<{ Params: { id: string } }>('/projects/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('projects.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    try {
      return await ctx.tx(async (tx) => {
        const before = await getProject(tx, ctx, id, true);
        await checkRefs(tx, ctx, body);
        const start = body.startDate !== undefined ? body.startDate : before.start_date;
        const end = body.endDate !== undefined ? body.endDate : before.end_date;
        if (start && end && end < start) throw badRequest('The end date is before the start date.', { endDate: 'Before the start date' });
        const changes = Object.fromEntries(Object.entries({
          code: body.code, name: body.name, client_party_id: body.clientPartyId, manager_user_id: body.managerUserId,
          status: body.status, start_date: body.startDate, end_date: body.endDate, contract_value: body.contractValue,
          address: body.address,
        }).filter(([, v]) => v !== undefined));
        const old = (await loadProjects(tx, [id]))[0]!;
        if (Object.keys(changes).length) await tx.updateTable('projects').set(changes).where('id', '=', id).execute();
        if (body.siteIds !== undefined) await setSites(tx, ctx, id, body.siteIds ?? []);
        const after = (await loadProjects(tx, [id]))[0]!;
        if (Object.keys(changes).length || body.siteIds !== undefined) {
          await writeAudit(tx, auditOf(ctx), 'project', id, 'update', old, after);
        }
        return after;
      });
    } catch (err) {
      codeConflict(err, 'A project with this code already exists.');
    }
  });

  // BOQ ---------------------------------------------------------------------------------------

  app.get<{ Params: { id: string } }>('/projects/:id/boq', async (req) => {
    const ctx = req.ctx;
    ctx.require('projects.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(boqListQuery, req.query);
    return ctx.tx(async (tx) => {
      await getProject(tx, ctx, id);
      let base = boqSelect(tx, id);
      if (q.q) base = base.where((eb) => eb.or([eb('b.code', 'ilike', likeTerm(q.q!)), eb('b.description', 'ilike', likeTerm(q.q!))]));
      const { total } = await tx.selectFrom(base.as('x')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('b.sort_order').orderBy('b.code').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(boqJson), total };
    });
  });

  app.post<{ Params: { id: string } }>('/projects/:id/boq', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('boq.manage');
    const id = parse(z.uuid(), req.params.id);
    const raw = req.body as { lines?: unknown } | undefined;
    const bulk = !!raw && typeof raw === 'object' && 'lines' in raw;
    const inputs: BoqInput[] = bulk ? parse(boqBulkBody, req.body).lines : [parse(boqLineBody, req.body)];
    const seen = new Map<string, number>();
    inputs.forEach((l, i) => {
      const key = l.code.toLowerCase();
      if (seen.has(key)) throw badRequest(`Line ${i + 1}: code ${l.code} appears twice.`, { [`lines.${i}.code`]: 'Duplicate code' });
      seen.set(key, i);
    });
    try {
      const created = await ctx.tx(async (tx) => {
        await getProject(tx, ctx, id, true);
        const existing = await tx.selectFrom('boq_lines').select(['code', 'sort_order']).where('project_id', '=', id).execute();
        const clash = existing.find((e) => seen.has(e.code.toLowerCase()));
        if (clash) {
          const i = seen.get(clash.code.toLowerCase())!;
          throw conflict(`BOQ code ${clash.code} already exists in this project.`, 'CONFLICT', { [bulk ? `lines.${i}.code` : 'code']: 'Already used' });
        }
        let next = existing.reduce((m, e) => Math.max(m, e.sort_order), 0);
        const rows = await tx.insertInto('boq_lines').values(inputs.map((l) => ({
          tenant_id: ctx.tenantId, project_id: id, code: l.code, description: l.description, unit: l.unit, qty: l.qty,
          rate: l.rate, material_budget: l.materialBudget ?? 0, labour_budget: l.labourBudget ?? 0,
          other_budget: l.otherBudget ?? 0, sort_order: l.sortOrder ?? (next += 1),
        }))).returning('id').execute();
        const ids = rows.map((r) => r.id);
        await writeAudit(tx, auditOf(ctx), 'boq_line', bulk ? null : ids[0]!, bulk ? 'bulk_create' : 'create', null,
          { projectId: id, lines: inputs.map((l) => ({ code: l.code, qty: l.qty, rate: l.rate })) });
        return loadBoqLines(tx, id, ids);
      });
      return reply.status(201).send(bulk ? { data: created, total: created.length } : created[0]);
    } catch (err) {
      codeConflict(err, 'A BOQ line with this code already exists in this project.');
    }
  });

  /** A BOQ line of the active company the caller may see, locked for change. */
  async function getBoqLine(tx: Tx, ctx: RequestContext, id: string) {
    const line = await tx.selectFrom('boq_lines as b').innerJoin('projects as p', 'p.id', 'b.project_id')
      .selectAll('b').where('b.id', '=', id).where('p.company_id', '=', ctx.companyId).executeTakeFirst();
    if (!line) throw notFound('BOQ line');
    await getProject(tx, ctx, line.project_id, true);
    return line;
  }

  app.patch<{ Params: { id: string } }>('/boq/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('boq.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(boqPatchBody, req.body);
    try {
      return await ctx.tx(async (tx) => {
        const before = await getBoqLine(tx, ctx, id);
        const qty = body.qty ?? before.qty;
        const rate = body.rate ?? before.rate;
        if (qty * rate > MAX_AMOUNT) throw badRequest('Amount is too large.', { rate: 'Amount is too large' });
        const changes = Object.fromEntries(Object.entries({
          code: body.code, description: body.description, unit: body.unit, qty: body.qty, rate: body.rate,
          material_budget: body.materialBudget, labour_budget: body.labourBudget, other_budget: body.otherBudget,
          sort_order: body.sortOrder,
        }).filter(([, v]) => v !== undefined));
        const old = (await loadBoqLines(tx, before.project_id, [id]))[0]!;
        if (!Object.keys(changes).length) return old;
        await tx.updateTable('boq_lines').set(changes).where('id', '=', id).execute();
        const after = (await loadBoqLines(tx, before.project_id, [id]))[0]!;
        await writeAudit(tx, auditOf(ctx), 'boq_line', id, 'update', old, after);
        return after;
      });
    } catch (err) {
      codeConflict(err, 'A BOQ line with this code already exists in this project.');
    }
  });

  app.delete<{ Params: { id: string } }>('/boq/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('boq.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const line = await getBoqLine(tx, ctx, id);
      const [work, issue, indent] = await Promise.all([
        tx.selectFrom('dpr_work').select('id').where('boq_line_id', '=', id).limit(1).executeTakeFirst(),
        tx.selectFrom('issues').select('id').where('boq_line_id', '=', id).limit(1).executeTakeFirst(),
        tx.selectFrom('indent_lines').select('id').where('boq_line_id', '=', id).limit(1).executeTakeFirst(),
      ]);
      if (work || issue || indent) {
        const used = [work && 'a DPR', issue && 'a material issue', indent && 'an indent'].filter(Boolean).join(', ');
        throw conflict(`BOQ line ${line.code} is used by ${used} and cannot be deleted.`, 'IN_USE');
      }
      await tx.deleteFrom('boq_lines').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'boq_line', id, 'delete',
        { projectId: line.project_id, code: line.code, description: line.description, qty: line.qty, rate: line.rate }, null);
    });
    return reply.status(204).send();
  });

  // Costs ------------------------------------------------------------------------------------

  app.get<{ Params: { id: string } }>('/projects/:id/costs', async (req) => {
    const ctx = req.ctx;
    ctx.require('projects.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(costsQuery, req.query);
    return ctx.tx(async (tx) => {
      const project = await getProject(tx, ctx, id);
      const to = q.to ?? todayIst();
      const from = q.from ?? project.start_date ?? null;
      if (from && from > to) throw badRequest('`from` is after `to`.', { from: 'After to' });
      const scope = scopedLocationIds(ctx);

      // Sites of the project the caller can see.
      let sitesQuery = tx.selectFrom('locations').select('id').where('project_id', '=', id);
      if (scope) sitesQuery = sitesQuery.where('id', 'in', scope);
      const siteRows = await sitesQuery.execute();
      const sites = siteRows.length ? siteRows.map((r) => r.id) : [NIL];

      const lines = await boqSelect(tx, id).orderBy('b.sort_order').orderBy('b.code').execute();
      const sum = (f: (r: BoqRow) => number) => round2(lines.reduce((s, r) => s + f(r), 0));
      const budget = { material: sum((r) => r.material_budget), labour: sum((r) => r.labour_budget), other: sum((r) => r.other_budget), total: 0 };
      budget.total = round2(budget.material + budget.labour + budget.other);

      const showCost = ctx.can('items.view_cost');
      let issued = tx.selectFrom('issue_lines as il').innerJoin('issues as i', 'i.id', 'il.issue_id')
        .where('i.company_id', '=', ctx.companyId).where('i.status', '=', 'posted').where('i.issue_date', '<=', to);
      if (from) issued = issued.where('i.issue_date', '>=', from);
      let material = 0;
      const byLine = new Map<string, number>();
      if (showCost) {
        const m = await issued.where('i.location_id', 'in', sites)
          .select(sql<number>`coalesce(sum(il.value), 0)`.as('v')).executeTakeFirstOrThrow();
        material = round2(Number(m.v));
        if (lines.length) {
          let perLine = issued.where('i.boq_line_id', 'in', lines.map((l) => l.id));
          if (scope) perLine = perLine.where('i.location_id', 'in', scope);
          const rows = await perLine.select(['i.boq_line_id', sql<number>`sum(il.value)`.as('v')]).groupBy('i.boq_line_id').execute();
          for (const r of rows) byLine.set(r.boq_line_id!, round2(Number(r.v)));
        }
      }

      let wages = tx.selectFrom('wage_sheets').select(sql<number>`coalesce(sum(total_gross), 0)`.as('v'))
        .where('company_id', '=', ctx.companyId).where('site_id', 'in', sites).where('status', 'in', ['approved', 'paid'])
        .where('to_date', '<=', to);
      if (from) wages = wages.where('to_date', '>=', from);
      const labour = round2(Number((await wages.executeTakeFirstOrThrow()).v));

      let spent = tx.selectFrom('expenses').select(sql<number>`coalesce(sum(amount), 0)`.as('v'))
        .where('company_id', '=', ctx.companyId).where('location_id', 'in', sites).where('status', '=', 'posted')
        .where('expense_date', '<=', to);
      if (from) spent = spent.where('expense_date', '>=', from);
      const expenses = round2(Number((await spent.executeTakeFirstOrThrow()).v));

      return {
        projectId: id, from, to, budget,
        actual: { material, labour, expenses, total: round2(material + labour + expenses) },
        byBoqLine: lines.map((r) => {
          const b = boqJson(r);
          return {
            boqLineId: b.id, code: b.code, description: b.description, qty: b.qty, executedQty: b.executedQty,
            progressPct: b.progressPct, materialBudget: b.materialBudget, materialActual: byLine.get(b.id) ?? 0,
          };
        }),
      };
    });
  });
}
