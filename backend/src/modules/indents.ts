import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { boqLinesAt } from './projects.ts';

const round3 = (n: number) => Math.round(n * 1000) / 1000;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const STATUSES = ['draft', 'submitted', 'approved', 'rejected', 'closed'] as const;

const createBody = z.object({
  locationId: z.uuid(),
  requiredBy: dateField.optional(),
  notes: optionalText(1000),
  submit: z.boolean().optional(),
  lines: z.array(z.object({
    itemId: z.uuid(),
    qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
    boqLineId: z.uuid().nullable().optional(),
  })).min(1, 'Add at least one item').max(200),
});
const approveBody = z.object({
  lines: z.array(z.object({
    lineId: z.uuid(),
    approvedQty: qtyField.refine((v) => v >= 0, 'Cannot be negative'),
  })).max(200).optional(),
});
const reasonBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(STATUSES).optional(),
  locationId: z.uuid().optional(),
  projectId: z.uuid().optional(),
});

/** Indents as JSON, in the order of `ids`. */
async function loadIndents(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const rows = await tx.selectFrom('indents as n')
    .innerJoin('locations as l', 'l.id', 'n.location_id')
    .innerJoin('users as u', 'u.id', 'n.created_by')
    .leftJoin('users as a', 'a.id', 'n.approved_by')
    .selectAll('n')
    .select(['l.name as location_name', 'l.project_id', 'u.name as created_by_name', 'a.name as approved_by_name'])
    .where('n.id', 'in', ids).execute();
  const fulfilled = tx.selectFrom('indent_fulfilments')
    .select((eb) => ['indent_line_id', eb.fn.sum<number>('qty').as('qty')])
    .where('indent_line_id', 'in', tx.selectFrom('indent_lines').select('id').where('indent_id', 'in', ids))
    .groupBy('indent_line_id');
  const lines = await tx.selectFrom('indent_lines as il')
    .innerJoin('items as i', 'i.id', 'il.item_id')
    .leftJoin(fulfilled.as('f'), 'f.indent_line_id', 'il.id')
    .select(['il.id', 'il.indent_id', 'il.item_id', 'i.name as item_name', 'i.unit', 'il.qty', 'il.approved_qty',
      'il.boq_line_id', sql<number>`coalesce(f.qty, 0)`.as('fulfilled_qty')])
    .where('il.indent_id', 'in', ids).orderBy('il.line_no').execute();
  return ids.map((id) => {
    const n = rows.find((r) => r.id === id)!;
    const mine = lines.filter((l) => l.indent_id === id).map((l) => ({
      id: l.id, itemId: l.item_id, itemName: l.item_name, unit: l.unit, qty: l.qty, approvedQty: l.approved_qty,
      fulfilledQty: round3(Number(l.fulfilled_qty)), boqLineId: l.boq_line_id,
    }));
    return {
      id: n.id, number: n.number, projectId: n.project_id, locationId: n.location_id, locationName: n.location_name,
      requiredBy: n.required_by, status: n.status, notes: n.notes, createdAt: n.created_at,
      createdBy: { id: n.created_by, name: n.created_by_name },
      approvedAt: n.approved_at, approvedBy: n.approved_by ? { id: n.approved_by, name: n.approved_by_name! } : null,
      rejectReason: n.reject_reason,
      isFulfilled: (n.status === 'approved' || n.status === 'closed')
        && mine.every((l) => l.approvedQty !== null && l.fulfilledQty + 0.0005 >= l.approvedQty),
      lines: mine,
    };
  });
}

/** Locks an indent of the active company that the caller may see. */
async function getIndent(tx: Tx, ctx: RequestContext, id: string) {
  const n = await tx.selectFrom('indents').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId)
    .forUpdate().executeTakeFirst();
  if (!n || !ctx.canAccessLocation(n.location_id)) throw notFound('Indent');
  return n;
}

function requireStatus(n: { status: string; number: string }, wanted: string, action: string) {
  if (n.status !== wanted) throw conflict(`Indent ${n.number} is ${n.status}; only ${wanted} indents can be ${action}.`, 'CONFLICT');
}

// Fulfilment through transfers and purchases ----------------------------------------------------

/** Validates the `indentId` of a new transfer or purchase going to `locationId`. */
export async function checkIndentLink(tx: Tx, ctx: RequestContext, indentId: string, locationId: string) {
  const n = await tx.selectFrom('indents').select(['id', 'number', 'status', 'location_id'])
    .where('id', '=', indentId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!n) throw badRequest('Indent not found.', { indentId: 'Not found' });
  if (n.status !== 'approved') throw badRequest(`Indent ${n.number} is ${n.status}; only approved indents can be fulfilled.`, { indentId: 'Not approved' });
  if (n.location_id !== locationId) throw badRequest(`Indent ${n.number} is for another location.`, { indentId: 'Different location' });
}

/**
 * Records goods that arrived at the indent's location against its matching item lines,
 * in line order and capped at each line's approved quantity.
 */
export async function fulfilIndent(
  tx: Tx, ctx: RequestContext, indentId: string, source: { type: 'transfer' | 'purchase'; id: string; locationId: string },
  received: { itemId: string; qty: number }[],
) {
  const n = await tx.selectFrom('indents').select(['id', 'number', 'status', 'location_id'])
    .where('id', '=', indentId).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!n || n.location_id !== source.locationId || !['approved', 'closed'].includes(n.status)) return;
  const lines = await tx.selectFrom('indent_lines').select(['id', 'item_id', 'approved_qty'])
    .where('indent_id', '=', indentId).orderBy('line_no').execute();
  const done = await tx.selectFrom('indent_fulfilments')
    .select((eb) => ['indent_line_id', eb.fn.sum<number>('qty').as('qty')])
    .where('indent_line_id', 'in', lines.length ? lines.map((l) => l.id) : ['00000000-0000-0000-0000-000000000000'])
    .groupBy('indent_line_id').execute();
  const open = new Map(lines.map((l) => [l.id, round3((l.approved_qty ?? 0) - Number(done.find((d) => d.indent_line_id === l.id)?.qty ?? 0))]));

  const perItem = new Map<string, number>();
  for (const r of received) perItem.set(r.itemId, round3((perItem.get(r.itemId) ?? 0) + r.qty));
  const rows: { indent_line_id: string; qty: number }[] = [];
  for (const [itemId, qty] of perItem) {
    let left = qty;
    for (const l of lines.filter((x) => x.item_id === itemId)) {
      const room = open.get(l.id)!;
      if (left <= 0 || room <= 0) continue;
      const take = round3(Math.min(left, room));
      rows.push({ indent_line_id: l.id, qty: take });
      open.set(l.id, round3(room - take));
      left = round3(left - take);
    }
  }
  if (!rows.length) return;
  await tx.insertInto('indent_fulfilments').values(rows.map((r) => ({
    tenant_id: ctx.tenantId, indent_line_id: r.indent_line_id, source_type: source.type, source_id: source.id, qty: r.qty,
  }))).execute();
  await writeAudit(tx, auditOf(ctx), 'indent', indentId, 'fulfil', null, { source: source.type, sourceId: source.id, lines: rows });
}

/** Undoes what a cancelled transfer or purchase delivered against its indent. */
export async function reverseFulfilment(tx: Tx, ctx: RequestContext, indentId: string | null, sourceId: string) {
  if (!indentId) return;
  const removed = await tx.deleteFrom('indent_fulfilments').where('source_id', '=', sourceId).returning(['indent_line_id', 'qty']).execute();
  if (removed.length) await writeAudit(tx, auditOf(ctx), 'indent', indentId, 'unfulfil', { sourceId, lines: removed }, null);
}

// ---------------------------------------------------------------------------------------------

export async function indentRoutes(app: FastifyInstance) {
  app.get('/indents', async (req) => {
    const ctx = req.ctx;
    ctx.require('indents.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('indents as n').innerJoin('locations as l', 'l.id', 'n.location_id')
        .where('n.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('n.location_id', 'in', scope);
      if (q.status) base = base.where('n.status', '=', q.status);
      if (q.locationId) base = base.where('n.location_id', '=', q.locationId);
      if (q.projectId) base = base.where('l.project_id', '=', q.projectId);
      if (q.q) base = base.where((eb) => eb.or([eb('n.number', 'ilike', likeTerm(q.q!)), eb('n.notes', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('n.id').orderBy('n.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadIndents(tx, ids.map((r) => r.id)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/indents/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('indents.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const n = await tx.selectFrom('indents').select('location_id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!n || !ctx.canAccessLocation(n.location_id)) throw notFound('Indent');
      return (await loadIndents(tx, [id]))[0];
    });
  });

  app.post('/indents', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('indents.create');
    const body = parse(createBody, req.body);
    const indent = await ctx.tx(async (tx) => {
      const location = await getLocation(tx, ctx, body.locationId);
      if (!['site', 'store'].includes(location.type)) throw badRequest('Indents are raised by a site or a store.', { locationId: 'Not a site or store' });
      if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });

      const itemIds = [...new Set(body.lines.map((l) => l.itemId))];
      const items = await tx.selectFrom('items').select(['id', 'name', 'is_active'])
        .where('company_id', '=', ctx.companyId).where('id', 'in', itemIds).execute();
      body.lines.forEach((l, i) => {
        const item = items.find((x) => x.id === l.itemId);
        if (!item) throw badRequest(`Line ${i + 1}: item not found.`, { [`lines.${i}.itemId`]: 'Not found' });
        if (!item.is_active) throw badRequest(`Line ${i + 1}: ${item.name} is inactive.`, { [`lines.${i}.itemId`]: 'Inactive' });
      });
      await boqLinesAt(tx, location, body.lines.flatMap((l, i) => (l.boqLineId ? [{ id: l.boqLineId, field: `lines.${i}.boqLineId` }] : [])));

      const today = todayIst();
      const number = await nextNumber(tx, ctx, 'indent', financialYear(today));
      const row = await tx.insertInto('indents').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, location_id: location.id,
        required_by: body.requiredBy ?? null, status: body.submit ? 'submitted' : 'draft', notes: body.notes ?? null,
        created_by: ctx.userId, submitted_at: body.submit ? new Date() : null, approved_by: null, approved_at: null,
        rejected_by: null, rejected_at: null, reject_reason: null, closed_by: null, closed_at: null,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('indent_lines').values(body.lines.map((l, i) => ({
        tenant_id: ctx.tenantId, indent_id: row.id, line_no: i + 1, item_id: l.itemId, qty: l.qty, approved_qty: null,
        boq_line_id: l.boqLineId ?? null,
      }))).execute();
      await writeAudit(tx, auditOf(ctx), 'indent', row.id, 'create', null, { number, locationId: location.id, lines: body.lines, submit: !!body.submit });
      return (await loadIndents(tx, [row.id]))[0];
    });
    return reply.status(201).send(indent);
  });

  app.post<{ Params: { id: string } }>('/indents/:id/submit', async (req) => {
    const ctx = req.ctx;
    ctx.require('indents.create');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const n = await getIndent(tx, ctx, id);
      requireStatus(n, 'draft', 'submitted');
      await tx.updateTable('indents').set({ status: 'submitted', submitted_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'indent', id, 'submit', { status: 'draft' }, { status: 'submitted' });
      return (await loadIndents(tx, [id]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/indents/:id/approve', async (req) => {
    const ctx = req.ctx;
    ctx.require('indents.approve');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(approveBody, req.body);
    return ctx.tx(async (tx) => {
      const n = await getIndent(tx, ctx, id);
      requireStatus(n, 'submitted', 'approved');
      const lines = await tx.selectFrom('indent_lines').select(['id', 'qty']).where('indent_id', '=', id).execute();
      const given = new Map<string, number>();
      (body.lines ?? []).forEach((l, i) => {
        const line = lines.find((x) => x.id === l.lineId);
        if (!line) throw badRequest(`Line ${i + 1}: not a line of this indent.`, { [`lines.${i}.lineId`]: 'Not in this indent' });
        if (l.approvedQty > line.qty + 0.0005) {
          throw badRequest(`Line ${i + 1}: cannot approve more than the ${line.qty} requested.`, { [`lines.${i}.approvedQty`]: `At most ${line.qty}` });
        }
        given.set(l.lineId, l.approvedQty);
      });
      for (const line of lines) {
        await tx.updateTable('indent_lines').set({ approved_qty: given.get(line.id) ?? line.qty }).where('id', '=', line.id).execute();
      }
      await tx.updateTable('indents').set({ status: 'approved', approved_by: ctx.userId, approved_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'indent', id, 'approve', { status: 'submitted' },
        { status: 'approved', lines: lines.map((l) => ({ lineId: l.id, approvedQty: given.get(l.id) ?? l.qty })) });
      return (await loadIndents(tx, [id]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/indents/:id/reject', async (req) => {
    const ctx = req.ctx;
    ctx.require('indents.approve');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(reasonBody, req.body);
    return ctx.tx(async (tx) => {
      const n = await getIndent(tx, ctx, id);
      requireStatus(n, 'submitted', 'rejected');
      await tx.updateTable('indents').set({ status: 'rejected', rejected_by: ctx.userId, rejected_at: new Date(), reject_reason: reason })
        .where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'indent', id, 'reject', { status: 'submitted' }, { status: 'rejected', reason });
      return (await loadIndents(tx, [id]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/indents/:id/close', async (req) => {
    const ctx = req.ctx;
    ctx.require('indents.approve', 'indents.create');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const n = await getIndent(tx, ctx, id);
      if (!ctx.can('indents.approve') && n.created_by !== ctx.userId) throw forbidden('Only an approver or the person who raised this indent can close it.');
      requireStatus(n, 'approved', 'closed');
      await tx.updateTable('indents').set({ status: 'closed', closed_by: ctx.userId, closed_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'indent', id, 'close', { status: 'approved' }, { status: 'closed' });
      return (await loadIndents(tx, [id]))[0];
    });
  });
}
