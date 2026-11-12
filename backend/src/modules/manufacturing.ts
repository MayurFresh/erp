import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { activeBoms, explode, round2, round3, showCost, type BomDef } from './mfg-common.ts';
import { manufacturingOrderRoutes } from './manufacturing-orders.ts';
import { computeShortages, manufacturingPlanningRoutes } from './manufacturing-planning.ts';
import { documentRoute } from '../lib/openapi.ts';

const nameField = z.string().trim().min(1, 'Required').max(80);
const qtyPositive = qtyField.refine((v) => v > 0, 'Must be more than zero');

const settingsBody = z.object({ overheadPct: percentField.max(500) });
const centreBody = z.object({ name: nameField, hourlyCost: moneyField });
const centrePatch = z.object({
  name: nameField.optional(), hourlyCost: moneyField.optional(), isActive: z.boolean().optional(), expectedUpdatedAt: z.string().optional(),
});

const bomLine = z.object({
  kind: z.enum(['component', 'byproduct']).default('component'),
  itemId: z.uuid(),
  qty: qtyPositive,
  scrapPct: percentField.optional(),
  rate: moneyField.optional(),
});
const bomStep = z.object({
  operation: z.string().trim().min(1, 'Required').max(100),
  workCentreId: z.uuid(),
  minutesPerUnit: z.coerce.number().positive().max(100000),
});
const bomBody = z.object({
  itemId: z.uuid(),
  outputQty: qtyPositive.optional(),
  note: optionalText(500),
  lines: z.array(bomLine).min(1, 'Add at least one component').max(200),
  steps: z.array(bomStep).max(50).optional(),
});
const bomPatch = z.object({
  outputQty: qtyPositive.optional(),
  note: z.string().trim().max(500).nullable().optional(),
  lines: z.array(bomLine).min(1, 'Add at least one component').max(200).optional(),
  steps: z.array(bomStep).max(50).optional(),
  expectedUpdatedAt: z.string().optional(),
});
const bomList = pagingQuery.extend({ itemId: z.uuid().optional(), status: z.enum(['draft', 'active', 'archived']).optional() });
const explodeQuery = z.object({ itemId: z.uuid().optional(), bomId: z.uuid().optional(), qty: qtyPositive.default(1) });

/** Checks the items and work centres of a BOM body. */
async function checkBomParts(
  tx: Tx, ctx: RequestContext, itemId: string, lines: z.infer<typeof bomLine>[], steps: z.infer<typeof bomStep>[],
) {
  const ids = [...new Set([itemId, ...lines.map((l) => l.itemId)])];
  const items = await tx.selectFrom('items').select(['id', 'name', 'track_stock', 'is_active'])
    .where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const finished = items.find((i) => i.id === itemId);
  if (!finished) throw badRequest('Finished item not found.', { itemId: 'Not found' });
  if (!finished.track_stock) throw badRequest('The finished item must be a stock item.', { itemId: 'Stock not tracked' });
  lines.forEach((l, i) => {
    const it = items.find((x) => x.id === l.itemId);
    if (!it) throw badRequest(`Line ${i + 1}: item not found.`, { [`lines.${i}.itemId`]: 'Not found' });
    if (!it.track_stock) throw badRequest(`Line ${i + 1}: ${it.name} is not a stock item.`, { [`lines.${i}.itemId`]: 'Stock not tracked' });
    if (l.itemId === itemId) throw badRequest('An item cannot be its own component or by-product.', { [`lines.${i}.itemId`]: 'Same as finished item' });
  });
  const wcIds = [...new Set(steps.map((s) => s.workCentreId))];
  if (wcIds.length) {
    const found = await tx.selectFrom('mfg_work_centres').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', wcIds).execute();
    steps.forEach((s, i) => {
      if (!found.some((f) => f.id === s.workCentreId)) throw badRequest(`Step ${i + 1}: work centre not found.`, { [`steps.${i}.workCentreId`]: 'Not found' });
    });
  }
}

async function writeBomParts(
  tx: Tx, ctx: RequestContext, bomId: string, lines: z.infer<typeof bomLine>[], steps: z.infer<typeof bomStep>[],
) {
  await tx.insertInto('mfg_bom_lines').values(lines.map((l, i) => ({
    tenant_id: ctx.tenantId, bom_id: bomId, line_no: i + 1, kind: l.kind, item_id: l.itemId, qty: l.qty,
    scrap_pct: l.kind === 'component' ? (l.scrapPct ?? 0) : 0, rate: l.kind === 'byproduct' ? (l.rate ?? 0) : 0,
  }))).execute();
  if (steps.length) {
    await tx.insertInto('mfg_bom_steps').values(steps.map((s, i) => ({
      tenant_id: ctx.tenantId, bom_id: bomId, step_no: i + 1, operation: s.operation, work_centre_id: s.workCentreId,
      minutes_per_unit: s.minutesPerUnit,
    }))).execute();
  }
}

export async function loadBom(tx: Tx, ctx: RequestContext, id: string) {
  const bom = await tx.selectFrom('mfg_boms as b').innerJoin('items as i', 'i.id', 'b.item_id')
    .selectAll('b').select(['i.name as item_name', 'i.unit as item_unit'])
    .where('b.id', '=', id).where('b.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!bom) throw notFound('Bill of materials');
  const lines = await tx.selectFrom('mfg_bom_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.id', 'l.kind', 'l.item_id', 'l.qty', 'l.scrap_pct', 'l.rate', 'i.name', 'i.unit', 'i.purchase_price'])
    .where('l.bom_id', '=', id).orderBy('l.line_no').execute();
  const steps = await tx.selectFrom('mfg_bom_steps as s').innerJoin('mfg_work_centres as w', 'w.id', 's.work_centre_id')
    .select(['s.id', 's.operation', 's.work_centre_id', 's.minutes_per_unit', 'w.name as wc_name', 'w.hourly_cost'])
    .where('s.bom_id', '=', id).orderBy('s.step_no').execute();
  const sub = await tx.selectFrom('mfg_boms').select(['item_id', 'id']).where('company_id', '=', ctx.companyId)
    .where('status', '=', 'active').where('item_id', 'in', lines.map((l) => l.item_id).concat(['00000000-0000-0000-0000-000000000000'])).execute();
  const cost = showCost(ctx);
  const material = lines.filter((l) => l.kind === 'component')
    .reduce((s, l) => s + (l.qty / bom.output_qty) * (1 + l.scrap_pct / 100) * l.purchase_price, 0);
  const byValue = lines.filter((l) => l.kind === 'byproduct').reduce((s, l) => s + (l.qty / bom.output_qty) * l.rate, 0);
  const work = steps.reduce((s, st) => s + (st.minutes_per_unit / 60) * st.hourly_cost, 0);
  return {
    id: bom.id, itemId: bom.item_id, itemName: bom.item_name, unit: bom.item_unit, version: bom.version, status: bom.status,
    outputQty: bom.output_qty, note: bom.note, activatedAt: bom.activated_at, createdAt: bom.created_at, updatedAt: bom.updated_at,
    lines: lines.map((l) => ({
      id: l.id, kind: l.kind, itemId: l.item_id, name: l.name, unit: l.unit, qty: l.qty, scrapPct: l.scrap_pct,
      ...(l.kind === 'byproduct' ? { rate: l.rate } : {}), hasBom: sub.some((s) => s.item_id === l.item_id),
    })),
    steps: steps.map((s) => ({
      id: s.id, operation: s.operation, workCentreId: s.work_centre_id, workCentreName: s.wc_name, minutesPerUnit: s.minutes_per_unit,
      ...(cost ? { hourlyCost: s.hourly_cost } : {}),
    })),
    ...(cost ? { standardCost: { material: round2(material), work: round2(work), byProducts: round2(byValue), unitCost: round2(material + work - byValue), basis: 'Purchase price of components' } } : {}),
  };
}

function bomDefOf(itemId: string, id: string, outputQty: number, lines: z.infer<typeof bomLine>[]): BomDef {
  return {
    id, itemId, outputQty,
    lines: lines.map((l) => ({ kind: l.kind, itemId: l.itemId, qty: l.qty, scrapPct: l.scrapPct ?? 0, rate: l.rate ?? 0 })),
  };
}

async function lockBom(tx: Tx, ctx: RequestContext, id: string) {
  const row = await tx.selectFrom('mfg_boms').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!row) throw notFound('Bill of materials');
  return row;
}

export async function overheadPct(tx: Tx, companyId: string): Promise<number> {
  const row = await tx.selectFrom('mfg_settings').select('overhead_pct').where('company_id', '=', companyId).executeTakeFirst();
  return row?.overhead_pct ?? 0;
}

export async function manufacturingRoutes(app: FastifyInstance) {
  // Settings and work centres ------------------------------------------------------------------------
  app.get('/manufacturing/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    return ctx.tx(async (tx) => ({ overheadPct: await overheadPct(tx, ctx.companyId) }));
  });

  app.route({ method: ['PUT', 'PATCH'], url: '/manufacturing/settings', handler: async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.manage');
    const body = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await overheadPct(tx, ctx.companyId);
      await tx.insertInto('mfg_settings').values({ company_id: ctx.companyId, tenant_id: ctx.tenantId, overhead_pct: body.overheadPct })
        .onConflict((oc) => oc.column('company_id').doUpdateSet({ overhead_pct: body.overheadPct })).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_settings', ctx.companyId, 'update', { overheadPct: before }, body);
      return { overheadPct: body.overheadPct };
    });
  } });

  const centreJson = (ctx: RequestContext, c: { id: string; name: string; hourly_cost: number; is_active: boolean; updated_at: Date }) => ({
    id: c.id, name: c.name, isActive: c.is_active, updatedAt: c.updated_at, ...(showCost(ctx) ? { hourlyCost: c.hourly_cost } : {}),
  });

  app.get('/manufacturing/work-centres', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const q = parse(z.object({ q: z.string().optional(), active: z.enum(['true', 'false']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let qb = tx.selectFrom('mfg_work_centres').selectAll().where('company_id', '=', ctx.companyId);
      if (q.q) qb = qb.where('name', 'ilike', likeTerm(q.q));
      if (q.active) qb = qb.where('is_active', '=', q.active === 'true');
      const rows = await qb.orderBy('name').execute();
      return { data: rows.map((r) => centreJson(ctx, r)), total: rows.length };
    });
  });

  app.post('/manufacturing/work-centres', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.bom', 'manufacturing.manage');
    const body = parse(centreBody, req.body);
    const row = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('mfg_work_centres').select('id').where('company_id', '=', ctx.companyId)
        .where(sql<boolean>`lower(name) = ${body.name.toLowerCase()}`).executeTakeFirst();
      if (dup) throw conflict('A work centre with this name already exists.', 'DUPLICATE_NAME');
      const r = await tx.insertInto('mfg_work_centres').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: body.name, hourly_cost: body.hourlyCost,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'mfg_work_centre', r.id, 'create', null, body);
      return r;
    });
    return reply.status(201).send(centreJson(ctx, row));
  });

  app.patch<{ Params: { id: string } }>('/manufacturing/work-centres/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.bom', 'manufacturing.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(centrePatch, req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('mfg_work_centres').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!cur) throw notFound('Work centre');
      assertFresh(cur.updated_at, body.expectedUpdatedAt, 'work centre');
      if (body.name && body.name.toLowerCase() !== cur.name.toLowerCase()) {
        const dup = await tx.selectFrom('mfg_work_centres').select('id').where('company_id', '=', ctx.companyId)
          .where(sql<boolean>`lower(name) = ${body.name.toLowerCase()}`).executeTakeFirst();
        if (dup) throw conflict('A work centre with this name already exists.', 'DUPLICATE_NAME');
      }
      const set = definedOnly({ name: body.name, hourly_cost: body.hourlyCost, is_active: body.isActive });
      const row = Object.keys(set).length
        ? await tx.updateTable('mfg_work_centres').set(set).where('id', '=', id).returningAll().executeTakeFirstOrThrow() : cur;
      await writeAudit(tx, auditOf(ctx), 'mfg_work_centre', id, 'update', null, set);
      return centreJson(ctx, row);
    });
  });

  // Bills of materials -------------------------------------------------------------------------------
  app.get('/manufacturing/boms', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const q = parse(bomList, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('mfg_boms as b').innerJoin('items as i', 'i.id', 'b.item_id').where('b.company_id', '=', ctx.companyId);
      if (q.itemId) base = base.where('b.item_id', '=', q.itemId);
      if (q.status) base = base.where('b.status', '=', q.status);
      if (q.q) base = base.where('i.name', 'ilike', likeTerm(q.q));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.select(['b.id', 'b.item_id', 'i.name as item_name', 'i.unit', 'b.version', 'b.status', 'b.output_qty', 'b.updated_at',
        (eb) => eb.selectFrom('mfg_bom_lines as l').select((e2) => e2.fn.countAll<number>().as('n')).whereRef('l.bom_id', '=', 'b.id').as('line_count')])
        .orderBy('i.name').orderBy('b.version', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((r) => ({
          id: r.id, itemId: r.item_id, itemName: r.item_name, unit: r.unit, version: r.version, status: r.status,
          outputQty: r.output_qty, lineCount: Number(r.line_count ?? 0), updatedAt: r.updated_at,
        })),
        total,
      };
    });
  });

  app.post('/manufacturing/boms', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.bom');
    const body = parse(bomBody, req.body);
    const saved = await ctx.tx(async (tx) => {
      await checkBomParts(tx, ctx, body.itemId, body.lines, body.steps ?? []);
      const last = await tx.selectFrom('mfg_boms').select((eb) => eb.fn.max('version').as('v'))
        .where('company_id', '=', ctx.companyId).where('item_id', '=', body.itemId).executeTakeFirst();
      const version = Number(last?.v ?? 0) + 1;
      const row = await tx.insertInto('mfg_boms').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: body.itemId, version, output_qty: body.outputQty ?? 1,
        note: body.note ?? null, activated_at: null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeBomParts(tx, ctx, row.id, body.lines, body.steps ?? []);
      await writeAudit(tx, auditOf(ctx), 'mfg_bom', row.id, 'create', null, { itemId: body.itemId, version });
      return loadBom(tx, ctx, row.id);
    });
    return reply.status(201).send(saved);
  });

  app.get<{ Params: { id: string } }>('/manufacturing/boms/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadBom(tx, ctx, id));
  });

  app.patch<{ Params: { id: string } }>('/manufacturing/boms/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.bom');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(bomPatch, req.body);
    return ctx.tx(async (tx) => {
      const cur = await lockBom(tx, ctx, id);
      if (cur.status !== 'draft') throw conflict('Only a draft can be edited. Copy it to a new version.', 'BOM_LOCKED');
      assertFresh(cur.updated_at, body.expectedUpdatedAt, 'bill of materials');
      if (body.lines || body.steps) {
        const lines = body.lines ?? (await tx.selectFrom('mfg_bom_lines').selectAll().where('bom_id', '=', id).execute())
          .map((l) => ({ kind: l.kind as 'component' | 'byproduct', itemId: l.item_id, qty: l.qty, scrapPct: l.scrap_pct, rate: l.rate }));
        const steps = body.steps ?? (await tx.selectFrom('mfg_bom_steps').selectAll().where('bom_id', '=', id).orderBy('step_no').execute())
          .map((s) => ({ operation: s.operation, workCentreId: s.work_centre_id, minutesPerUnit: s.minutes_per_unit }));
        await checkBomParts(tx, ctx, cur.item_id, lines, steps);
        await tx.deleteFrom('mfg_bom_lines').where('bom_id', '=', id).execute();
        await tx.deleteFrom('mfg_bom_steps').where('bom_id', '=', id).execute();
        await writeBomParts(tx, ctx, id, lines, steps);
      }
      await tx.updateTable('mfg_boms').set({
        ...(body.outputQty !== undefined ? { output_qty: body.outputQty } : {}),
        ...(body.note !== undefined ? { note: body.note } : {}), updated_at: new Date(),
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_bom', id, 'update', null, { lines: body.lines?.length, steps: body.steps?.length });
      return loadBom(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/manufacturing/boms/:id/activate', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.bom');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const cur = await lockBom(tx, ctx, id);
      if (cur.status === 'active') return loadBom(tx, ctx, id);
      if (cur.status !== 'draft') throw conflict('This version is archived. Copy it to a new version to use it again.', 'BOM_LOCKED');
      const lines = await tx.selectFrom('mfg_bom_lines').selectAll().where('bom_id', '=', id).execute();
      // A structure that loops back on itself would never finish: test it before it becomes active.
      const def: BomDef = {
        id, itemId: cur.item_id, outputQty: cur.output_qty,
        lines: lines.map((l) => ({ kind: l.kind, itemId: l.item_id, qty: l.qty, scrapPct: l.scrap_pct, rate: l.rate })),
      };
      explode(await activeBoms(tx, ctx.companyId, def), def, 1);
      await tx.updateTable('mfg_boms').set({ status: 'archived', updated_at: new Date() })
        .where('company_id', '=', ctx.companyId).where('item_id', '=', cur.item_id).where('status', '=', 'active').execute();
      await tx.updateTable('mfg_boms').set({ status: 'active', activated_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_bom', id, 'activate', { status: 'draft' }, { status: 'active', version: cur.version });
      return loadBom(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/manufacturing/boms/:id/copy', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.bom');
    const id = parse(z.uuid(), req.params.id);
    const saved = await ctx.tx(async (tx) => {
      const cur = await lockBom(tx, ctx, id);
      const last = await tx.selectFrom('mfg_boms').select((eb) => eb.fn.max('version').as('v'))
        .where('company_id', '=', ctx.companyId).where('item_id', '=', cur.item_id).executeTakeFirst();
      const row = await tx.insertInto('mfg_boms').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: cur.item_id, version: Number(last?.v ?? 0) + 1,
        output_qty: cur.output_qty, note: cur.note, activated_at: null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const lines = await tx.selectFrom('mfg_bom_lines').selectAll().where('bom_id', '=', id).orderBy('line_no').execute();
      const steps = await tx.selectFrom('mfg_bom_steps').selectAll().where('bom_id', '=', id).orderBy('step_no').execute();
      await tx.insertInto('mfg_bom_lines').values(lines.map((l) => ({
        tenant_id: ctx.tenantId, bom_id: row.id, line_no: l.line_no, kind: l.kind, item_id: l.item_id, qty: l.qty, scrap_pct: l.scrap_pct, rate: l.rate,
      }))).execute();
      if (steps.length) {
        await tx.insertInto('mfg_bom_steps').values(steps.map((s) => ({
          tenant_id: ctx.tenantId, bom_id: row.id, step_no: s.step_no, operation: s.operation, work_centre_id: s.work_centre_id,
          minutes_per_unit: s.minutes_per_unit,
        }))).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'mfg_bom', row.id, 'create', null, { copiedFrom: id });
      return loadBom(tx, ctx, row.id);
    });
    return reply.status(201).send(saved);
  });

  app.delete<{ Params: { id: string } }>('/manufacturing/boms/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.bom');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const cur = await lockBom(tx, ctx, id);
      if (cur.status !== 'draft') throw conflict('Only a draft can be deleted.', 'BOM_LOCKED');
      await tx.deleteFrom('mfg_boms').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_bom', id, 'delete', { version: cur.version }, null);
    });
    return reply.status(204).send();
  });

  app.get('/manufacturing/explode', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const q = parse(explodeQuery, req.query);
    if (!q.itemId && !q.bomId) throw badRequest('Give an item or a bill of materials.', { itemId: 'Required' });
    return ctx.tx(async (tx) => {
      let root: BomDef | undefined;
      const defs = await activeBoms(tx, ctx.companyId);
      if (q.bomId) {
        const b = await loadBom(tx, ctx, q.bomId);
        root = {
          id: b.id, itemId: b.itemId, outputQty: b.outputQty,
          lines: b.lines.map((l) => ({ kind: l.kind, itemId: l.itemId, qty: l.qty, scrapPct: l.scrapPct, rate: l.rate ?? 0 })),
        };
      } else {
        root = defs.get(q.itemId!);
        if (!root) throw conflict('This item has no active bill of materials.', 'NO_ACTIVE_BOM');
      }
      const out = explode(defs, root, q.qty);
      const ids = new Set<string>([root.itemId, ...out.raw.keys()]);
      const walkIds = (n: { itemId: string; children: typeof out.tree }[]) => n.forEach((x) => { ids.add(x.itemId); walkIds(x.children); });
      walkIds(out.tree);
      const items = await tx.selectFrom('items').select(['id', 'name', 'unit']).where('id', 'in', [...ids]).execute();
      const stock = await tx.selectFrom('stock_moves').select((eb) => ['item_id', eb.fn.sum<number>('qty').as('qty')])
        .where('company_id', '=', ctx.companyId).where('item_id', 'in', [...ids]).groupBy('item_id').execute();
      const meta = (id: string) => items.find((i) => i.id === id);
      const onHand = (id: string) => round3(Number(stock.find((s) => s.item_id === id)?.qty ?? 0));
      const decorate = (nodes: typeof out.tree): unknown[] => nodes.map((n) => ({
        itemId: n.itemId, name: meta(n.itemId)?.name, unit: meta(n.itemId)?.unit, qty: n.qty, bomId: n.bomId, children: decorate(n.children),
      }));
      return {
        itemId: root.itemId, itemName: meta(root.itemId)?.name, qty: q.qty, tree: decorate(out.tree),
        raw: [...out.raw].map(([itemId, qty]) => ({ itemId, name: meta(itemId)?.name, unit: meta(itemId)?.unit, qty, onHand: onHand(itemId) }))
          .sort((a, b) => String(a.name).localeCompare(String(b.name))),
      };
    });
  });

  app.get('/manufacturing/home', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    return ctx.tx(async (tx) => {
      const byStatus = await tx.selectFrom('mfg_orders').select((eb) => ['status', eb.fn.countAll<number>().as('n')])
        .where('company_id', '=', ctx.companyId).groupBy('status').execute();
      const today = await tx.selectFrom('mfg_outputs as o').innerJoin('mfg_orders as m', 'm.id', 'o.order_id')
        .innerJoin('items as i', 'i.id', 'm.item_id')
        .select((eb) => ['m.item_id', 'i.name', 'i.unit', eb.fn.sum<number>('o.good_qty').as('good'), eb.fn.sum<number>('o.rejected_qty').as('rej')])
        .where('m.company_id', '=', ctx.companyId).where('o.output_date', '=', todayIst()).groupBy(['m.item_id', 'i.name', 'i.unit']).execute();
      const jw = await tx.selectFrom('mfg_jobwork_challans').select((eb) => eb.fn.countAll<number>().as('n'))
        .where('company_id', '=', ctx.companyId).where('status', 'in', ['open', 'partially_returned']).executeTakeFirstOrThrow();
      const shortages = await computeShortages(tx, ctx, undefined);
      const counts: Record<string, number> = { draft: 0, released: 0, in_progress: 0, completed: 0, cancelled: 0 };
      for (const r of byStatus) counts[r.status] = Number(r.n);
      return {
        ordersByStatus: counts, shortagesCount: shortages.length,
        todayOutput: today.map((t) => ({ itemId: t.item_id, name: t.name, unit: t.unit, goodQty: Number(t.good), rejectedQty: Number(t.rej) })),
        openJobWork: Number(jw.n),
      };
    });
  });

  await manufacturingOrderRoutes(app);
  await manufacturingPlanningRoutes(app);
}

documentRoute('PUT', '/manufacturing/settings', { body: settingsBody });
documentRoute('PATCH', '/manufacturing/settings', { body: settingsBody });
documentRoute('POST', '/manufacturing/work-centres', { body: centreBody });
documentRoute('PATCH', '/manufacturing/work-centres/:id', { body: centrePatch });
documentRoute('POST', '/manufacturing/boms', { body: bomBody });
documentRoute('PATCH', '/manufacturing/boms/:id', { body: bomPatch });
