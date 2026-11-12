import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { componentNeed, post, putStock, round2, round3, round4, showCost, takeStock, type BomDef } from './mfg-common.ts';
import { overheadPct } from './manufacturing.ts';
import { documentRoute } from '../lib/openapi.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const qtyPositive = qtyField.refine((v) => v > 0, 'Must be more than zero');
const qtyZero = qtyField.refine((v) => v >= 0, 'Cannot be negative');

const createBody = z.object({
  itemId: z.uuid(),
  qty: qtyPositive,
  locationId: z.uuid(),
  bomId: z.uuid().optional(),
  plannedStart: dateField.nullable().optional(),
  plannedEnd: dateField.nullable().optional(),
  salesOrderId: z.uuid().nullable().optional(),
  notes: optionalText(1000),
});
const patchBody = z.object({
  qty: qtyPositive.optional(),
  locationId: z.uuid().optional(),
  plannedStart: dateField.nullable().optional(),
  plannedEnd: dateField.nullable().optional(),
  notes: nullableText(1000),
  expectedUpdatedAt: z.string().optional(),
});
const reasonBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const lineList = z.array(z.object({ itemId: z.uuid(), qty: qtyPositive })).min(1).max(200);
const issueBody = z.object({ all: z.boolean().optional(), lines: lineList.optional(), note: optionalText(300) })
  .refine((b) => b.all || b.lines, { message: 'Choose what to issue' });
const returnBody = z.object({ lines: lineList, note: optionalText(300) });
const outputBody = z.object({
  goodQty: qtyZero,
  rejectedQty: qtyZero.optional(),
  minutes: z.coerce.number().min(0).max(1_000_000).optional(),
  byProducts: z.array(z.object({ itemId: z.uuid(), qty: qtyPositive })).max(50).optional(),
  date: docDate.optional(),
  note: optionalText(300),
}).refine((b) => b.goodQty + (b.rejectedQty ?? 0) > 0, { message: 'Enter a good or rejected quantity', path: ['goodQty'] });
const inspectBody = z.object({
  outputId: z.uuid().optional(),
  passQty: qtyZero, reworkQty: qtyZero, rejectQty: qtyZero,
  note: z.string().trim().min(1, 'Add a note').max(500),
}).refine((b) => b.passQty + b.reworkQty + b.rejectQty > 0, { message: 'Enter a quantity', path: ['passQty'] });
const listQuery = pagingQuery.extend({
  status: z.enum(['draft', 'released', 'in_progress', 'completed', 'cancelled']).optional(),
  itemId: z.uuid().optional(), from: dateField.optional(), to: dateField.optional(),
});

const OPEN = ['released', 'in_progress'];

function needStatus(status: string, allowed: string[], what: string) {
  if (allowed.includes(status)) return;
  if (status === 'draft') throw conflict(`Release the order before you ${what}.`, 'ORDER_NOT_OPEN');
  if (status === 'completed' || status === 'cancelled') throw conflict(`This order is ${status}.`, 'ORDER_NOT_OPEN');
  throw conflict(`You cannot ${what} while the order is ${status.replace('_', ' ')}.`, 'BAD_TRANSITION');
}

async function lockOrder(tx: Tx, ctx: RequestContext, id: string) {
  const row = await tx.selectFrom('mfg_orders').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Production order');
  return row;
}

const netValue = (m: { issued_value: number; returned_value: number }) => m.issued_value - m.returned_value;

/** Material value in WIP that no output has taken yet. */
async function unabsorbed(tx: Tx, orderId: string, absorbed: number) {
  const mats = await tx.selectFrom('mfg_order_materials').selectAll().where('order_id', '=', orderId).execute();
  return { mats, value: round2(mats.reduce((s, m) => s + netValue(m), 0) - absorbed) };
}

export async function loadOrder(tx: Tx, ctx: RequestContext, id: string) {
  const o = await tx.selectFrom('mfg_orders as o')
    .innerJoin('items as i', 'i.id', 'o.item_id').innerJoin('locations as l', 'l.id', 'o.location_id')
    .innerJoin('mfg_boms as b', 'b.id', 'o.bom_id').leftJoin('sales_orders as s', 's.id', 'o.sales_order_id')
    .selectAll('o').select(['i.name as item_name', 'i.unit', 'l.name as location_name', 'b.version as bom_version', 's.number as so_number'])
    .where('o.id', '=', id).where('o.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!o || !ctx.canAccessLocation(o.location_id)) throw notFound('Production order');
  const cost = showCost(ctx);
  const mats = await tx.selectFrom('mfg_order_materials as m').innerJoin('items as i', 'i.id', 'm.item_id')
    .select(['m.item_id', 'i.name', 'i.unit', 'i.purchase_price', 'm.planned_qty', 'm.issued_qty', 'm.returned_qty', 'm.issued_value', 'm.returned_value'])
    .where('m.order_id', '=', id).orderBy('i.name').execute();
  const stock = mats.length ? await tx.selectFrom('stock_moves').select((eb) => ['item_id', eb.fn.sum<number>('qty').as('qty')])
    .where('company_id', '=', ctx.companyId).where('location_id', '=', o.location_id).where('item_id', 'in', mats.map((m) => m.item_id))
    .groupBy('item_id').execute() : [];
  const steps = await tx.selectFrom('mfg_order_steps as s').innerJoin('mfg_work_centres as w', 'w.id', 's.work_centre_id')
    .select(['s.step_no', 's.operation', 's.minutes_per_unit', 's.hourly_cost', 'w.name as wc_name']).where('s.order_id', '=', id).orderBy('s.step_no').execute();
  const outs = await tx.selectFrom('mfg_outputs').selectAll().where('order_id', '=', id).orderBy('created_at').execute();
  const bys = outs.length ? await tx.selectFrom('mfg_output_byproducts as p').innerJoin('items as i', 'i.id', 'p.item_id')
    .select(['p.output_id', 'p.item_id', 'i.name', 'i.unit', 'p.qty', 'p.value']).where('p.output_id', 'in', outs.map((x) => x.id)).execute() : [];
  const moves = await tx.selectFrom('mfg_movements as v').innerJoin('items as i', 'i.id', 'v.item_id').innerJoin('users as u', 'u.id', 'v.created_by')
    .select(['v.id', 'v.kind', 'v.item_id', 'i.name', 'i.unit', 'v.qty', 'v.cost_rate', 'v.value', 'v.note', 'v.created_at', 'u.name as by'])
    .where('v.order_id', '=', id).orderBy('v.created_at', 'desc').execute();
  const insp = await tx.selectFrom('mfg_inspections as n').innerJoin('users as u', 'u.id', 'n.inspected_by')
    .select(['n.id', 'n.output_id', 'n.pass_qty', 'n.rework_qty', 'n.reject_qty', 'n.note', 'n.created_at', 'u.name as by'])
    .where('n.order_id', '=', id).orderBy('n.created_at', 'desc').execute();

  const units = o.good_qty + o.rejected_qty;
  const scale = o.qty > 0 ? units / o.qty : 0;
  const variance = mats.map((m) => {
    const actual = round3(m.issued_qty - m.returned_qty);
    const expected = round3(m.planned_qty * scale);
    const rate = m.issued_qty > 0 ? m.issued_value / m.issued_qty : m.purchase_price;
    return {
      itemId: m.item_id, name: m.name, unit: m.unit, expectedQty: expected, actualQty: actual,
      varianceQty: round3(actual - expected), ...(cost ? { varianceValue: round2((actual - expected) * rate) } : {}),
    };
  });
  const goodValue = outs.reduce((s, x) => s + x.value, 0);
  const planned = o.status === 'draft' || o.status === 'cancelled';
  const nextActions = planned ? (o.status === 'draft' ? ['edit', 'release', 'cancel'] : [])
    : o.status === 'released' ? ['issue', 'output', 'cancel']
      : o.status === 'in_progress' ? ['issue', 'return', 'output', 'inspect', 'close'] : [];
  return {
    id: o.id, number: o.number, status: o.status, itemId: o.item_id, itemName: o.item_name, unit: o.unit,
    bomId: o.bom_id, bomVersion: o.bom_version, locationId: o.location_id, locationName: o.location_name,
    qty: o.qty, goodQty: o.good_qty, rejectedQty: o.rejected_qty, plannedStart: o.planned_start, plannedEnd: o.planned_end,
    salesOrderId: o.sales_order_id, salesOrderNumber: o.so_number, notes: o.notes, releasedAt: o.released_at, closedAt: o.closed_at,
    closeNote: o.close_note, cancelReason: o.cancel_reason, createdAt: o.created_at, updatedAt: o.updated_at, nextActions,
    materials: mats.map((m) => ({
      itemId: m.item_id, name: m.name, unit: m.unit, plannedQty: m.planned_qty, issuedQty: m.issued_qty, returnedQty: m.returned_qty,
      netQty: round3(m.issued_qty - m.returned_qty), pendingQty: Math.max(0, round3(m.planned_qty - (m.issued_qty - m.returned_qty))),
      onHand: round3(Number(stock.find((s) => s.item_id === m.item_id)?.qty ?? 0)),
      ...(cost ? { issuedValue: round2(netValue(m)) } : {}),
    })),
    steps: steps.map((s) => ({
      stepNo: s.step_no, operation: s.operation, workCentreName: s.wc_name, minutesPerUnit: s.minutes_per_unit,
      plannedMinutes: round2(s.minutes_per_unit * o.qty), ...(cost ? { hourlyCost: s.hourly_cost } : {}),
    })),
    outputs: outs.map((x) => ({
      id: x.id, date: x.output_date, goodQty: x.good_qty, rejectedQty: x.rejected_qty, minutes: x.minutes, note: x.note, createdAt: x.created_at,
      ...(cost ? { materialCost: x.material_cost, labourCost: x.labour_cost, overheadCost: x.overhead_cost, unitCost: x.unit_cost, value: x.value, lossValue: x.loss_value } : {}),
      byProducts: bys.filter((b) => b.output_id === x.id).map((b) => ({ itemId: b.item_id, name: b.name, unit: b.unit, qty: b.qty, ...(cost ? { value: b.value } : {}) })),
    })),
    movements: moves.map((m) => ({
      id: m.id, kind: m.kind, itemId: m.item_id, name: m.name, unit: m.unit, qty: m.qty, note: m.note, createdAt: m.created_at, by: m.by,
      ...(cost ? { costRate: m.cost_rate, value: m.value } : {}),
    })),
    inspections: insp.map((n) => ({
      id: n.id, outputId: n.output_id, passQty: n.pass_qty, reworkQty: n.rework_qty, rejectQty: n.reject_qty, note: n.note, createdAt: n.created_at, by: n.by,
    })),
    ...(cost ? {
      cost: {
        material: o.material_absorbed, conversion: o.conversion_cost, overheadPct: o.overhead_pct,
        total: round2(o.output_value + o.loss_value), finishedValue: round2(goodValue), lossValue: o.loss_value,
        unitCost: o.good_qty > 0 ? round4(goodValue / o.good_qty) : 0,
      },
    } : {}),
    variance: { lines: variance, yieldPct: units > 0 ? round2((o.good_qty / units) * 100) : null, completionPct: o.qty > 0 ? round2((o.good_qty / o.qty) * 100) : 0 },
  };
}

export async function manufacturingOrderRoutes(app: FastifyInstance) {
  app.get('/manufacturing/orders', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('mfg_orders as o').innerJoin('items as i', 'i.id', 'o.item_id').where('o.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('o.location_id', 'in', scope);
      if (q.status) base = base.where('o.status', '=', q.status);
      if (q.itemId) base = base.where('o.item_id', '=', q.itemId);
      if (q.from) base = base.where('o.created_at', '>=', new Date(`${q.from}T00:00:00+05:30`));
      if (q.to) base = base.where('o.created_at', '<', new Date(new Date(`${q.to}T00:00:00+05:30`).getTime() + 86_400_000));
      if (q.q) base = base.where((eb) => eb.or([eb('o.number', 'ilike', likeTerm(q.q!)), eb('i.name', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.select(['o.id', 'o.number', 'o.status', 'o.item_id', 'i.name as item_name', 'i.unit', 'o.qty', 'o.good_qty', 'o.rejected_qty',
        'o.planned_start', 'o.planned_end', 'o.updated_at']).orderBy('o.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((r) => ({
          id: r.id, number: r.number, status: r.status, itemId: r.item_id, itemName: r.item_name, unit: r.unit, qty: r.qty,
          goodQty: r.good_qty, rejectedQty: r.rejected_qty, plannedStart: r.planned_start, plannedEnd: r.planned_end, updatedAt: r.updated_at,
        })),
        total,
      };
    });
  });

  app.get<{ Params: { id: string } }>('/manufacturing/orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadOrder(tx, ctx, id));
  });

  app.post('/manufacturing/orders', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.orders');
    const body = parse(createBody, req.body);
    const saved = await ctx.tx(async (tx) => {
      const location = await getLocation(tx, ctx, body.locationId);
      if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
      const bom = await (body.bomId
        ? tx.selectFrom('mfg_boms').selectAll().where('id', '=', body.bomId).where('company_id', '=', ctx.companyId).executeTakeFirst()
        : tx.selectFrom('mfg_boms').selectAll().where('company_id', '=', ctx.companyId).where('item_id', '=', body.itemId).where('status', '=', 'active').executeTakeFirst());
      if (!bom) {
        if (body.bomId) throw badRequest('Bill of materials not found.', { bomId: 'Not found' });
        throw conflict('This item has no active bill of materials. Activate one first.', 'NO_ACTIVE_BOM');
      }
      if (bom.item_id !== body.itemId) throw badRequest('This bill of materials is for another item.', { bomId: 'Wrong item' });
      if (bom.status === 'draft') throw conflict('Activate the bill of materials before using it.', 'NO_ACTIVE_BOM');
      if (body.salesOrderId) {
        const so = await tx.selectFrom('sales_orders').select('id').where('id', '=', body.salesOrderId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!so) throw badRequest('Sales order not found.', { salesOrderId: 'Not found' });
      }
      if (body.plannedStart && body.plannedEnd && body.plannedEnd < body.plannedStart) {
        throw badRequest('The end date is before the start date.', { plannedEnd: 'Before start' });
      }
      const lines = await tx.selectFrom('mfg_bom_lines').selectAll().where('bom_id', '=', bom.id).where('kind', '=', 'component').orderBy('line_no').execute();
      const steps = await tx.selectFrom('mfg_bom_steps as s').innerJoin('mfg_work_centres as w', 'w.id', 's.work_centre_id')
        .select(['s.step_no', 's.operation', 's.work_centre_id', 's.minutes_per_unit', 'w.hourly_cost']).where('s.bom_id', '=', bom.id).orderBy('s.step_no').execute();
      const def: BomDef = { id: bom.id, itemId: bom.item_id, outputQty: bom.output_qty, lines: [] };
      const number = await nextNumber(tx, ctx, 'production_order', financialYear(todayIst()));
      const row = await tx.insertInto('mfg_orders').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, fy: financialYear(todayIst()), item_id: body.itemId, bom_id: bom.id,
        location_id: location.id, qty: body.qty, planned_start: body.plannedStart ?? null, planned_end: body.plannedEnd ?? null,
        overhead_pct: await overheadPct(tx, ctx.companyId), sales_order_id: body.salesOrderId ?? null, notes: body.notes ?? null,
        created_by: ctx.userId, released_at: null, closed_at: null, close_note: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      // Same item twice in one BOM adds up on one planned line.
      const planned = new Map<string, number>();
      for (const l of lines) planned.set(l.item_id, (planned.get(l.item_id) ?? 0) + componentNeed(def, { kind: 'component', itemId: l.item_id, qty: l.qty, scrapPct: l.scrap_pct, rate: 0 }, body.qty));
      await tx.insertInto('mfg_order_materials').values([...planned].map(([itemId, q]) => ({
        tenant_id: ctx.tenantId, order_id: row.id, item_id: itemId, planned_qty: round3(q),
      }))).execute();
      if (steps.length) {
        await tx.insertInto('mfg_order_steps').values(steps.map((s) => ({
          tenant_id: ctx.tenantId, order_id: row.id, step_no: s.step_no, operation: s.operation, work_centre_id: s.work_centre_id,
          minutes_per_unit: s.minutes_per_unit, hourly_cost: s.hourly_cost,
        }))).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'mfg_order', row.id, 'create', null, { number, itemId: body.itemId, qty: body.qty, bomVersion: bom.version });
      return loadOrder(tx, ctx, row.id);
    });
    return reply.status(201).send(saved);
  });

  app.patch<{ Params: { id: string } }>('/manufacturing/orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.orders');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      needStatus(o.status, ['draft', 'released', 'in_progress'], 'edit the order');
      assertFresh(o.updated_at, body.expectedUpdatedAt, 'production order');
      const planning = body.qty !== undefined || body.locationId !== undefined;
      if (planning && o.status === 'in_progress') throw conflict('Quantity and location cannot change once work has started.', 'BAD_TRANSITION');
      if (body.locationId) await getLocation(tx, ctx, body.locationId);
      const start = body.plannedStart === undefined ? o.planned_start : body.plannedStart;
      const end = body.plannedEnd === undefined ? o.planned_end : body.plannedEnd;
      if (start && end && end < start) throw badRequest('The end date is before the start date.', { plannedEnd: 'Before start' });
      if (body.qty !== undefined && body.qty !== o.qty) {
        const mats = await tx.selectFrom('mfg_order_materials').selectAll().where('order_id', '=', id).execute();
        for (const m of mats) {
          if (m.issued_qty === 0) {
            await tx.updateTable('mfg_order_materials').set({ planned_qty: round3((m.planned_qty * body.qty) / o.qty) }).where('id', '=', m.id).execute();
          }
        }
      }
      await tx.updateTable('mfg_orders').set({
        ...definedOnly({ qty: body.qty, location_id: body.locationId, notes: body.notes }),
        planned_start: start, planned_end: end, updated_at: new Date(),
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'update', { qty: o.qty }, body);
      return loadOrder(tx, ctx, id);
    });
  });

  app.route<{ Params: { id: string; itemId: string } }>({ method: ['PUT', 'PATCH'], url: '/manufacturing/orders/:id/materials/:itemId', handler: async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.orders');
    const id = parse(z.uuid(), req.params.id);
    const itemId = parse(z.uuid(), req.params.itemId);
    const { plannedQty } = parse(z.object({ plannedQty: qtyZero }), req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      needStatus(o.status, ['draft', 'released', 'in_progress'], 'change the material plan');
      const item = await tx.selectFrom('items').select(['id', 'name', 'track_stock']).where('id', '=', itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!item) throw notFound('Item');
      if (!item.track_stock) throw badRequest(`${item.name} is not a stock item.`, { itemId: 'Stock not tracked' });
      if (itemId === o.item_id) throw badRequest('The finished item cannot be its own material.', { itemId: 'Same as finished item' });
      const cur = await tx.selectFrom('mfg_order_materials').selectAll().where('order_id', '=', id).where('item_id', '=', itemId).executeTakeFirst();
      if (cur) {
        if (plannedQty === 0 && cur.issued_qty > 0) throw conflict('Material was already issued. Return it first or keep a quantity.', 'HAS_ACTIVITY');
        if (plannedQty === 0) await tx.deleteFrom('mfg_order_materials').where('id', '=', cur.id).execute();
        else await tx.updateTable('mfg_order_materials').set({ planned_qty: plannedQty }).where('id', '=', cur.id).execute();
      } else if (plannedQty > 0) {
        await tx.insertInto('mfg_order_materials').values({ tenant_id: ctx.tenantId, order_id: id, item_id: itemId, planned_qty: plannedQty }).execute();
      }
      await tx.updateTable('mfg_orders').set({ updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'plan_material', { plannedQty: cur?.planned_qty ?? 0 }, { itemId, plannedQty });
      return loadOrder(tx, ctx, id);
    });
  } });

  app.post<{ Params: { id: string } }>('/manufacturing/orders/:id/release', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.orders');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      if (o.status !== 'draft') throw conflict('Only a draft order can be released.', 'BAD_TRANSITION');
      await tx.updateTable('mfg_orders').set({ status: 'released', released_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'release', { status: 'draft' }, { status: 'released' });
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/manufacturing/orders/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.orders');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(reasonBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      needStatus(o.status, ['draft', 'released', 'in_progress'], 'cancel the order');
      const { mats } = await unabsorbed(tx, id, o.material_absorbed);
      const outputs = await tx.selectFrom('mfg_outputs').select('id').where('order_id', '=', id).limit(1).execute();
      if (outputs.length || mats.some((m) => m.issued_qty - m.returned_qty > 0.0005)) {
        throw conflict('Material is issued or output is recorded. Return the material, or close the order instead.', 'HAS_ACTIVITY');
      }
      await tx.updateTable('mfg_orders').set({ status: 'cancelled', cancel_reason: reason, updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'cancel', { status: o.status }, { status: 'cancelled', reason });
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/manufacturing/orders/:id/issue', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.issue');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(issueBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      needStatus(o.status, OPEN, 'issue material');
      const mats = await tx.selectFrom('mfg_order_materials').selectAll().where('order_id', '=', id).execute();
      let lines: { itemId: string; qty: number }[];
      if (body.lines) {
        const sum = new Map<string, number>();
        for (const l of body.lines) sum.set(l.itemId, (sum.get(l.itemId) ?? 0) + l.qty);
        lines = [...sum].map(([itemId, qty]) => ({ itemId, qty: round3(qty) }));
        if (lines.some((l) => l.itemId === o.item_id)) throw badRequest('The finished item cannot be issued to its own order.', { itemId: 'Same as finished item' });
      } else {
        lines = mats.map((m) => ({ itemId: m.item_id, qty: round3(m.planned_qty - (m.issued_qty - m.returned_qty)) })).filter((l) => l.qty > 0.0005);
        if (!lines.length) throw conflict('Everything planned has been issued.', 'NOTHING_TO_ISSUE');
      }
      const location = await getLocation(tx, ctx, o.location_id);
      const costed = await takeStock(tx, ctx, location, lines, 'production_issue', id, `${o.number} material issue`);
      for (const c of costed) {
        const m = mats.find((x) => x.item_id === c.itemId);
        if (m) {
          await tx.updateTable('mfg_order_materials').set({ issued_qty: round3(m.issued_qty + c.qty), issued_value: round2(m.issued_value + c.value) }).where('id', '=', m.id).execute();
        } else {
          await tx.insertInto('mfg_order_materials').values({
            tenant_id: ctx.tenantId, order_id: id, item_id: c.itemId, planned_qty: 0, issued_qty: c.qty, issued_value: c.value,
          }).execute();
        }
      }
      await tx.insertInto('mfg_movements').values(costed.map((c) => ({
        tenant_id: ctx.tenantId, order_id: id, kind: 'issue', item_id: c.itemId, qty: c.qty, cost_rate: c.costRate, value: c.value,
        note: body.note ?? null, created_by: ctx.userId,
      }))).execute();
      const value = round2(costed.reduce((s, c) => s + c.value, 0));
      await post(tx, ctx, {
        date: todayIst(), type: 'issue', voucherId: id, number: o.number, locationId: location.id,
        narration: `Material issued to ${o.number}`, lines: [['wip', value], ['inventory', -value]],
      });
      if (o.status === 'released') await tx.updateTable('mfg_orders').set({ status: 'in_progress' }).where('id', '=', id).execute();
      await tx.updateTable('mfg_orders').set({ updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'issue', null, { lines, value });
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/manufacturing/orders/:id/return', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.issue');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(returnBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      needStatus(o.status, OPEN, 'return material');
      const mats = await tx.selectFrom('mfg_order_materials').selectAll().where('order_id', '=', id).execute();
      const sum = new Map<string, number>();
      for (const l of body.lines) sum.set(l.itemId, (sum.get(l.itemId) ?? 0) + l.qty);
      const free = (await unabsorbed(tx, id, o.material_absorbed)).value;
      const back: { itemId: string; qty: number; value: number; rate: number }[] = [];
      for (const [itemId, qtyRaw] of sum) {
        const qty = round3(qtyRaw);
        const m = mats.find((x) => x.item_id === itemId);
        const net = m ? round3(m.issued_qty - m.returned_qty) : 0;
        if (!m || qty > net + 0.0005) throw conflict('You cannot return more than was issued.', 'RETURN_TOO_MUCH', { itemId, issued: net });
        const value = Math.abs(qty - net) < 0.0005 ? round2(netValue(m)) : round2(qty * (netValue(m) / net));
        back.push({ itemId, qty, value, rate: qty > 0 ? value / qty : 0 });
      }
      const total = round2(back.reduce((s, b) => s + b.value, 0));
      if (total > free + 0.005) throw conflict('Part of this material is already used in recorded output.', 'RETURN_TOO_MUCH');
      const location = await getLocation(tx, ctx, o.location_id);
      await putStock(tx, ctx, location.id, back, 'production_return', id, `${o.number} unused material returned`);
      for (const b of back) {
        const m = mats.find((x) => x.item_id === b.itemId)!;
        await tx.updateTable('mfg_order_materials').set({ returned_qty: round3(m.returned_qty + b.qty), returned_value: round2(m.returned_value + b.value) }).where('id', '=', m.id).execute();
      }
      await tx.insertInto('mfg_movements').values(back.map((b) => ({
        tenant_id: ctx.tenantId, order_id: id, kind: 'return', item_id: b.itemId, qty: b.qty, cost_rate: round4(b.rate), value: b.value,
        note: body.note ?? null, created_by: ctx.userId,
      }))).execute();
      await post(tx, ctx, {
        date: todayIst(), type: 'issue', voucherId: id, number: o.number, locationId: location.id,
        narration: `Unused material returned from ${o.number}`, lines: [['inventory', total], ['wip', -total]],
      });
      await tx.updateTable('mfg_orders').set({ updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'return', null, { lines: back.map((b) => ({ itemId: b.itemId, qty: b.qty })), total });
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/manufacturing/orders/:id/output', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.output');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(outputBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      needStatus(o.status, OPEN, 'record output');
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      const item = await tx.selectFrom('items').select(['id', 'name', 'track_stock']).where('id', '=', o.item_id).executeTakeFirstOrThrow();
      if (!item.track_stock) throw badRequest('The finished item is not a stock item.', { itemId: 'Stock not tracked' });
      const good = body.goodQty;
      const rej = body.rejectedQty ?? 0;
      const units = good + rej;

      // Material: this entry takes its share of what is still sitting in WIP.
      const { value: wip } = await unabsorbed(tx, id, o.material_absorbed);
      const remaining = Math.max(o.qty - o.good_qty - o.rejected_qty, units);
      const matCost = units >= remaining - 0.0005 ? Math.max(wip, 0) : round2(Math.max(wip, 0) * (units / remaining));

      // Work centre time: entered minutes at the routing's average rate, or routing minutes per unit.
      const steps = await tx.selectFrom('mfg_order_steps').selectAll().where('order_id', '=', id).execute();
      const mpu = steps.reduce((s, x) => s + x.minutes_per_unit, 0);
      const minutes = body.minutes ?? round2(mpu * units);
      const avgRate = mpu > 0 ? steps.reduce((s, x) => s + x.minutes_per_unit * x.hourly_cost, 0) / mpu : 0;
      const labour = body.minutes === undefined
        ? round2(steps.reduce((s, x) => s + (x.minutes_per_unit * units / 60) * x.hourly_cost, 0))
        : round2((body.minutes / 60) * avgRate);
      const overhead = round2((matCost + labour) * (o.overhead_pct / 100));
      const total = round2(matCost + labour + overhead);

      // By-products carry the value set on the BOM; the finished goods carry the rest.
      const bomBy = await tx.selectFrom('mfg_bom_lines').select(['item_id', 'rate']).where('bom_id', '=', o.bom_id).where('kind', '=', 'byproduct').execute();
      const byRows: { itemId: string; qty: number; value: number }[] = [];
      let byTotal = 0;
      if (body.byProducts?.length) {
        const ids = body.byProducts.map((b) => b.itemId);
        const items = await tx.selectFrom('items').select(['id', 'track_stock', 'name']).where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
        for (const b of body.byProducts) {
          const it = items.find((x) => x.id === b.itemId);
          if (!it) throw badRequest('By-product item not found.', { byProducts: 'Not found' });
          if (!it.track_stock) throw badRequest(`${it.name} is not a stock item.`, { byProducts: 'Stock not tracked' });
          const value = Math.min(round2(b.qty * (bomBy.find((x) => x.item_id === b.itemId)?.rate ?? 0)), round2(total - byTotal));
          byTotal = round2(byTotal + value);
          byRows.push({ itemId: b.itemId, qty: b.qty, value });
        }
      }
      const mainValue = good > 0 ? round2(total - byTotal) : 0;
      const loss = round2(total - byTotal - mainValue);
      const unitCost = good > 0 ? round4(mainValue / good) : 0;

      const out = await tx.insertInto('mfg_outputs').values({
        tenant_id: ctx.tenantId, order_id: id, output_date: date, good_qty: good, rejected_qty: rej, minutes, material_cost: matCost,
        labour_cost: labour, overhead_cost: overhead, byproduct_value: byTotal, unit_cost: unitCost, value: mainValue, loss_value: loss,
        note: body.note ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      if (byRows.length) {
        await tx.insertInto('mfg_output_byproducts').values(byRows.map((b) => ({ tenant_id: ctx.tenantId, output_id: out.id, item_id: b.itemId, qty: b.qty, value: b.value }))).execute();
      }
      const location = await getLocation(tx, ctx, o.location_id);
      await putStock(tx, ctx, location.id, [{ itemId: o.item_id, qty: good, value: mainValue }, ...byRows], 'production_output', id, `${o.number} output`);
      await post(tx, ctx, {
        date, type: 'stock', voucherId: out.id, number: o.number, locationId: location.id, narration: `Production output ${o.number}`,
        lines: [['inventory', mainValue + byTotal], ['stock_loss', loss], ['wip', -matCost], ['conversion_absorbed', -round2(labour + overhead)]],
      });
      await tx.updateTable('mfg_orders').set({
        status: 'in_progress', good_qty: round3(o.good_qty + good), rejected_qty: round3(o.rejected_qty + rej),
        material_absorbed: round2(o.material_absorbed + matCost), conversion_cost: round2(o.conversion_cost + labour + overhead),
        output_value: round2(o.output_value + mainValue + byTotal), loss_value: round2(o.loss_value + loss), updated_at: new Date(),
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'output', null, { good, rejected: rej, unitCost, total });
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/manufacturing/orders/:id/inspections', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.inspect');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(inspectBody, req.body);
    const saved = await ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      needStatus(o.status, ['in_progress', 'completed'], 'inspect output');
      const done = await tx.selectFrom('mfg_inspections').select((eb) => [
        eb.fn.sum<number>('pass_qty').as('p'), eb.fn.sum<number>('rework_qty').as('w'), eb.fn.sum<number>('reject_qty').as('r')])
        .where('order_id', '=', id).$if(!!body.outputId, (qb) => qb.where('output_id', '=', body.outputId!)).executeTakeFirstOrThrow();
      let limit = o.good_qty;
      if (body.outputId) {
        const out = await tx.selectFrom('mfg_outputs').select('good_qty').where('id', '=', body.outputId).where('order_id', '=', id).executeTakeFirst();
        if (!out) throw badRequest('Output entry not found.', { outputId: 'Not found' });
        limit = out.good_qty;
      }
      const already = Number(done.p ?? 0) + Number(done.w ?? 0) + Number(done.r ?? 0);
      const now = body.passQty + body.reworkQty + body.rejectQty;
      if (round3(already + now) > limit + 0.0005) {
        throw conflict(`Only ${round3(limit - already)} of the good output is left to inspect.`, 'INSPECTION_TOO_MUCH', { left: round3(limit - already) });
      }
      const row = await tx.insertInto('mfg_inspections').values({
        tenant_id: ctx.tenantId, order_id: id, output_id: body.outputId ?? null, pass_qty: body.passQty, rework_qty: body.reworkQty,
        reject_qty: body.rejectQty, note: body.note, inspected_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'inspect', null, { inspectionId: row.id, ...body });
      return loadOrder(tx, ctx, id);
    });
    return reply.status(201).send(saved);
  });

  app.post<{ Params: { id: string } }>('/manufacturing/orders/:id/close', async (req) => {
    const ctx = req.ctx;
    ctx.require('manufacturing.manage');
    const id = parse(z.uuid(), req.params.id);
    const { note } = parse(z.object({ note: optionalText(500) }), req.body ?? {});
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      needStatus(o.status, OPEN, 'close the order');
      const { value: leftover } = await unabsorbed(tx, id, o.material_absorbed);
      if (leftover > 0.004) {
        await post(tx, ctx, {
          date: todayIst(), type: 'stock', voucherId: id, number: o.number, locationId: o.location_id,
          narration: `Unused material written off on closing ${o.number}`, lines: [['stock_loss', leftover], ['wip', -leftover]],
        });
      }
      await tx.updateTable('mfg_orders').set({
        status: 'completed', closed_at: new Date(), close_note: note ?? null,
        loss_value: round2(o.loss_value + Math.max(leftover, 0)), updated_at: new Date(),
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mfg_order', id, 'close', { status: o.status }, { status: 'completed', leftover });
      return loadOrder(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/manufacturing/orders', { body: createBody });
documentRoute('PATCH', '/manufacturing/orders/:id', { body: patchBody });
documentRoute('POST', '/manufacturing/orders/:id/cancel', { body: reasonBody });
documentRoute('POST', '/manufacturing/orders/:id/issue', { body: issueBody });
documentRoute('POST', '/manufacturing/orders/:id/return', { body: returnBody });
documentRoute('POST', '/manufacturing/orders/:id/output', { body: outputBody });
documentRoute('POST', '/manufacturing/orders/:id/inspections', { body: inspectBody });
