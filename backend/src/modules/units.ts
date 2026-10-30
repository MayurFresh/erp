import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getProject } from './projects.ts';

const UNIT_STATUSES = ['available', 'hold', 'booked', 'agreement', 'possession'] as const;

const blankToNull = (v: unknown) => (v === '' ? null : v);
const unitFields = {
  code: z.string().trim().min(1, 'Required').max(30),
  wing: optionalText(20),
  floor: z.coerce.number().int().min(-5).max(200).optional(),
  unitType: z.string().trim().min(1, 'Required').max(40),
  carpetArea: qtyField.refine((v) => v > 0 && v <= 100000, 'Must be more than zero'),
  balconyArea: qtyField.refine((v) => v >= 0 && v <= 100000, 'Invalid area').optional(),
  listPrice: moneyField.optional(),
  notes: optionalText(500),
};
const unitBody = z.object(unitFields);
const createBody = z.union([
  z.object({ projectId: z.uuid(), units: z.array(unitBody).min(1, 'Add at least one unit').max(500, 'At most 500 units') }),
  z.object({ projectId: z.uuid(), ...unitFields }),
]);
const patchBody = z.object({
  code: unitFields.code.optional(),
  wing: nullableText(20),
  floor: z.preprocess(blankToNull, z.coerce.number().int().min(-5).max(200).nullable().optional()),
  unitType: unitFields.unitType.optional(),
  carpetArea: unitFields.carpetArea.optional(),
  balconyArea: z.preprocess(blankToNull, unitFields.balconyArea.nullable()),
  listPrice: unitFields.listPrice,
  notes: nullableText(500),
  status: z.enum(UNIT_STATUSES).optional(),
});
const listQuery = pagingQuery.extend({
  projectId: z.uuid().optional(),
  status: z.enum(UNIT_STATUSES).optional(),
  wing: z.string().trim().max(20).optional(),
  unitType: z.string().trim().max(40).optional(),
});

const stageBody = z.object({
  name: z.string().trim().min(1, 'Required').max(100),
  pct: z.coerce.number().gt(0).max(100).refine((v) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-6, 'At most 2 decimals'),
});
const stagesField = z.array(stageBody).min(1, 'Add at least one stage').max(30, 'At most 30 stages');
const planCreateBody = z.object({ projectId: z.uuid(), name: z.string().trim().min(1, 'Required').max(100), stages: stagesField });
const planPatchBody = z.object({
  name: z.string().trim().min(1, 'Required').max(100).optional(),
  isActive: z.boolean().optional(),
  stages: stagesField.optional(),
});
const planListQuery = pagingQuery.extend({
  projectId: z.uuid().optional(),
  activeOnly: z.enum(['true', 'false']).optional(),
});

// Units ----------------------------------------------------------------------------------------

function unitSelect(tx: Tx) {
  return tx.selectFrom('units as u')
    .innerJoin('projects as p', 'p.id', 'u.project_id')
    .leftJoin('bookings as b', (j) => j.onRef('b.unit_id', '=', 'u.id').on('b.status', '<>', 'cancelled'))
    .selectAll('u')
    .select(['p.name as project_name', 'b.id as booking_id']);
}
type UnitRow = Awaited<ReturnType<ReturnType<typeof unitSelect>['executeTakeFirstOrThrow']>>;

const unitJson = (r: UnitRow) => ({
  id: r.id, projectId: r.project_id, projectName: r.project_name, code: r.code, wing: r.wing, floor: r.floor,
  unitType: r.unit_type, carpetArea: r.carpet_area, balconyArea: r.balcony_area, listPrice: r.list_price,
  status: r.status, bookingId: r.booking_id, notes: r.notes, createdAt: r.created_at,
});

async function loadUnits(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const rows = await unitSelect(tx).where('u.id', 'in', ids).execute();
  return ids.map((id) => unitJson(rows.find((r) => r.id === id)!));
}

export async function getUnit(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('units').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const unit = await q.executeTakeFirst();
  if (!unit) throw notFound('Unit');
  await getProject(tx, ctx, unit.project_id);
  return unit;
}

// Payment plans --------------------------------------------------------------------------------

async function loadPlans(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const plans = await tx.selectFrom('payment_plans').selectAll().where('id', 'in', ids).execute();
  const stages = await tx.selectFrom('payment_plan_stages').selectAll().where('payment_plan_id', 'in', ids).orderBy('sort_order').execute();
  return ids.map((id) => {
    const p = plans.find((x) => x.id === id)!;
    return {
      id: p.id, projectId: p.project_id, name: p.name, isActive: p.is_active,
      stages: stages.filter((s) => s.payment_plan_id === id).map((s) => ({ id: s.id, name: s.name, pct: s.pct, sortOrder: s.sort_order })),
      createdAt: p.created_at,
    };
  });
}

async function getPlan(tx: Tx, ctx: RequestContext, id: string) {
  const plan = await tx.selectFrom('payment_plans').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!plan) throw notFound('Payment plan');
  await getProject(tx, ctx, plan.project_id);
  return plan;
}

function checkPct(stages: { pct: number }[]) {
  const paise = stages.reduce((s, x) => s + Math.round(x.pct * 100), 0);
  if (paise !== 10000) throw badRequest('Stage percentages must add up to exactly 100.', { stages: 'Must total 100%' });
}

function nameConflict(err: unknown, message: string, field: string): never {
  if ((err as { code?: string }).code === '23505') throw conflict(message, 'CONFLICT', { [field]: 'Already used' });
  throw err;
}

export async function unitRoutes(app: FastifyInstance) {
  app.get('/units', async (req) => {
    const ctx = req.ctx;
    ctx.require('units.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('units as u').where('u.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) {
        base = base.where((eb) => eb.exists(eb.selectFrom('locations as s').select('s.id')
          .whereRef('s.project_id', '=', 'u.project_id').where('s.id', 'in', scope)));
      }
      if (q.projectId) base = base.where('u.project_id', '=', q.projectId);
      if (q.status) base = base.where('u.status', '=', q.status);
      if (q.wing) base = base.where('u.wing', '=', q.wing);
      if (q.unitType) base = base.where('u.unit_type', '=', q.unitType);
      if (q.q) base = base.where((eb) => eb.or([eb('u.code', 'ilike', likeTerm(q.q!)), eb('u.unit_type', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('u.id').orderBy('u.wing').orderBy('u.floor').orderBy('u.code').limit(q.limit).offset(q.offset).execute();
      return { data: await loadUnits(tx, ids.map((r) => r.id)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/units/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('units.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await getUnit(tx, ctx, id);
      return (await loadUnits(tx, [id]))[0];
    });
  });

  app.post('/units', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('units.manage');
    const body = parse(createBody, req.body);
    const bulk = 'units' in body;
    const list = bulk ? body.units : [body];
    const out = await ctx.tx(async (tx) => {
      await getProject(tx, ctx, body.projectId);
      const codes = list.map((u) => u.code.toLowerCase());
      const dup = codes.find((c, i) => codes.indexOf(c) !== i);
      if (dup) throw conflict(`Unit code ${dup} appears twice.`, 'CONFLICT', { code: 'Duplicate in request' });
      const existing = await tx.selectFrom('units').select('code').where('project_id', '=', body.projectId)
        .where((eb) => eb(eb.fn('lower', ['code']), 'in', codes)).executeTakeFirst();
      if (existing) throw conflict(`Unit ${existing.code} already exists in this project.`, 'CONFLICT', { code: 'Already used' });
      const rows = await tx.insertInto('units').values(list.map((u) => ({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, project_id: body.projectId, code: u.code, wing: u.wing ?? null,
        floor: u.floor ?? null, unit_type: u.unitType, carpet_area: u.carpetArea, balcony_area: u.balconyArea ?? null,
        list_price: u.listPrice ?? 0, notes: u.notes ?? null,
      }))).returning('id').execute();
      const saved = await loadUnits(tx, rows.map((r) => r.id));
      for (const u of saved) await writeAudit(tx, auditOf(ctx), 'unit', u.id, 'create', null, u);
      return saved;
    });
    return reply.status(201).send(bulk ? { data: out, total: out.length } : out[0]);
  });

  app.patch<{ Params: { id: string } }>('/units/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('units.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    try {
      return await ctx.tx(async (tx) => {
        const before = await getUnit(tx, ctx, id, true);
        if (body.status !== undefined && body.status !== before.status) {
          const ok = (['available', 'hold'] as string[]).includes(body.status) && (['available', 'hold'] as string[]).includes(before.status);
          if (!ok) throw conflict('Status changes with bookings only; a unit can move between available and hold.', 'CONFLICT');
        }
        if (body.code && body.code.toLowerCase() !== before.code.toLowerCase()) {
          const clash = await tx.selectFrom('units').select('id').where('project_id', '=', before.project_id)
            .where((eb) => eb(eb.fn('lower', ['code']), '=', body.code!.toLowerCase())).executeTakeFirst();
          if (clash) throw conflict('A unit with this code already exists in the project.', 'CONFLICT', { code: 'Already used' });
        }
        const changes = definedOnly({
          code: body.code, wing: body.wing, floor: body.floor, unit_type: body.unitType, carpet_area: body.carpetArea,
          balcony_area: body.balconyArea, list_price: body.listPrice, notes: body.notes, status: body.status,
        });
        const old = (await loadUnits(tx, [id]))[0]!;
        if (!Object.keys(changes).length) return old;
        await tx.updateTable('units').set(changes).where('id', '=', id).execute();
        const after = (await loadUnits(tx, [id]))[0]!;
        await writeAudit(tx, auditOf(ctx), 'unit', id, 'update', old, after);
        return after;
      });
    } catch (err) {
      nameConflict(err, 'A unit with this code already exists in the project.', 'code');
    }
  });

  // Payment plans ------------------------------------------------------------------------------

  app.get('/payment-plans', async (req) => {
    const ctx = req.ctx;
    ctx.require('units.view');
    const q = parse(planListQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('payment_plans as pp').where('pp.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) {
        base = base.where((eb) => eb.exists(eb.selectFrom('locations as s').select('s.id')
          .whereRef('s.project_id', '=', 'pp.project_id').where('s.id', 'in', scope)));
      }
      if (q.projectId) base = base.where('pp.project_id', '=', q.projectId);
      if (q.activeOnly === 'true') base = base.where('pp.is_active', '=', true);
      if (q.q) base = base.where('pp.name', 'ilike', likeTerm(q.q));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('pp.id').orderBy('pp.name').limit(q.limit).offset(q.offset).execute();
      return { data: await loadPlans(tx, ids.map((r) => r.id)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/payment-plans/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('units.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await getPlan(tx, ctx, id);
      return (await loadPlans(tx, [id]))[0];
    });
  });

  app.post('/payment-plans', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('units.manage');
    const body = parse(planCreateBody, req.body);
    checkPct(body.stages);
    try {
      const plan = await ctx.tx(async (tx) => {
        await getProject(tx, ctx, body.projectId);
        const row = await tx.insertInto('payment_plans').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, project_id: body.projectId, name: body.name,
        }).returning('id').executeTakeFirstOrThrow();
        await tx.insertInto('payment_plan_stages').values(body.stages.map((s, i) => ({
          tenant_id: ctx.tenantId, payment_plan_id: row.id, sort_order: i + 1, name: s.name, pct: s.pct,
        }))).execute();
        const saved = (await loadPlans(tx, [row.id]))[0]!;
        await writeAudit(tx, auditOf(ctx), 'payment_plan', row.id, 'create', null, saved);
        return saved;
      });
      return reply.status(201).send(plan);
    } catch (err) {
      nameConflict(err, 'A payment plan with this name already exists in the project.', 'name');
    }
  });

  app.patch<{ Params: { id: string } }>('/payment-plans/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('units.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(planPatchBody, req.body);
    if (body.stages) checkPct(body.stages);
    try {
      return await ctx.tx(async (tx) => {
        await getPlan(tx, ctx, id);
        const old = (await loadPlans(tx, [id]))[0]!;
        const changes = definedOnly({ name: body.name, is_active: body.isActive });
        if (Object.keys(changes).length) await tx.updateTable('payment_plans').set(changes).where('id', '=', id).execute();
        if (body.stages) {
          await tx.deleteFrom('payment_plan_stages').where('payment_plan_id', '=', id).execute();
          await tx.insertInto('payment_plan_stages').values(body.stages.map((s, i) => ({
            tenant_id: ctx.tenantId, payment_plan_id: id, sort_order: i + 1, name: s.name, pct: s.pct,
          }))).execute();
        }
        const after = (await loadPlans(tx, [id]))[0]!;
        if (Object.keys(changes).length || body.stages) await writeAudit(tx, auditOf(ctx), 'payment_plan', id, 'update', old, after);
        return after;
      });
    } catch (err) {
      nameConflict(err, 'A payment plan with this name already exists in the project.', 'name');
    }
  });
}
