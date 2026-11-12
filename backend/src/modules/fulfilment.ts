import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import { lockItems } from '../accounting/costing.ts';
import type { Tx } from '../db/database.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { isValidDate } from '../lib/dates.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import {
  EPS, FULFILLABLE, addEvent, closeReservation, lockLines, lockOrder, openQty, refreshStatus, round3,
} from './o2c-common.ts';
import { illegal, loadOrder } from './sales-orders.ts';
import { loadShipment } from './shipments.ts';
import { documentRoute } from '../lib/openapi.ts';

const positive = qtyField.refine((v) => v > 0, 'Must be more than zero');
const scanId = z.string().trim().min(4, 'At least 4 characters').max(100);
const scanBody = z.object({
  scanId,
  code: z.string().trim().min(1).max(64).optional(),
  itemId: z.uuid().optional(),
  qty: positive.default(1),
  orderLineId: z.uuid().optional(),
}).refine((b) => Boolean(b.code) !== Boolean(b.itemId), 'Give code or itemId');
const packScanBody = scanBody;
const createListBody = z.object({
  locationId: z.uuid(),
  orderIds: z.array(z.uuid()).min(1, 'Choose at least one order').max(50),
});
const packBody = z.object({ lines: z.array(z.object({ lineId: z.uuid(), qty: positive })).min(1).max(200).optional() });
const dispatchBody = z.object({
  courier: optionalText(100),
  awb: optionalText(60),
  mode: z.enum(['prepaid', 'cod']).default('prepaid'),
  codAmount: moneyField.optional(),
  notes: optionalText(500),
  invoiceDate: z.string().refine(isValidDate, 'Use YYYY-MM-DD').optional(),
});
const listQuery = pagingQuery.extend({
  status: z.enum(['open', 'completed', 'cancelled']).optional(),
  locationId: z.uuid().optional(),
});

/** Finds an item by barcode, else by SKU (case-insensitive). */
async function itemByCode(tx: Tx, ctx: RequestContext, code: string) {
  const base = () => tx.selectFrom('items').select(['id', 'name', 'sku']).where('company_id', '=', ctx.companyId);
  return (await base().where('barcode', '=', code).executeTakeFirst())
    ?? (await base().where(sql<boolean>`lower(sku) = lower(${code})`).orderBy('is_active', 'desc').executeTakeFirst());
}

async function resolveScanItem(tx: Tx, ctx: RequestContext, b: { code?: string; itemId?: string }) {
  if (b.code) {
    const item = await itemByCode(tx, ctx, b.code);
    if (!item) throw new AppError(400, 'UNKNOWN_BARCODE', `No item has the code ${b.code}.`, { code: b.code });
    return item;
  }
  const item = await tx.selectFrom('items').select(['id', 'name', 'sku']).where('id', '=', b.itemId!).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!item) throw badRequest('Item not found.', { itemId: 'Not found' });
  return item;
}

// ---- pick lists -------------------------------------------------------------------------------------------------

function listSelect(tx: Tx) {
  return tx.selectFrom('pick_lists as p').innerJoin('locations as l', 'l.id', 'p.location_id')
    .selectAll('p').select(['l.name as location_name']);
}
type ListRow = Awaited<ReturnType<ReturnType<typeof listSelect>['executeTakeFirstOrThrow']>>;

async function listSummaries(tx: Tx, rows: ListRow[]) {
  if (!rows.length) return [];
  const agg = await tx.selectFrom('pick_list_lines as pl').innerJoin('sales_orders as o', 'o.id', 'pl.order_id')
    .select(['pl.pick_list_id', sql<number>`sum(pl.qty_target)`.as('target'), sql<number>`sum(pl.qty_picked)`.as('picked'),
      sql<string[]>`array_agg(distinct o.number)`.as('numbers')])
    .where('pl.pick_list_id', 'in', rows.map((r) => r.id)).groupBy('pl.pick_list_id').execute();
  const by = new Map(agg.map((a) => [a.pick_list_id, a]));
  return rows.map((r) => ({
    id: r.id, number: r.number, status: r.status, locationId: r.location_id, locationName: r.location_name,
    orderNumbers: [...(by.get(r.id)?.numbers ?? [])].sort(), totalTarget: Number(by.get(r.id)?.target ?? 0),
    totalPicked: Number(by.get(r.id)?.picked ?? 0), createdAt: r.created_at, completedAt: r.completed_at,
  }));
}

async function loadPickList(tx: Tx, ctx: RequestContext, id: string) {
  const row = await listSelect(tx).where('p.id', '=', id).where('p.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Pick list');
  const [summary] = await listSummaries(tx, [row]);
  const lines = await tx.selectFrom('pick_list_lines as pl').innerJoin('sales_orders as o', 'o.id', 'pl.order_id')
    .innerJoin('items as i', 'i.id', 'pl.item_id')
    .select(['pl.id', 'pl.line_no', 'pl.order_id', 'o.number as order_number', 'pl.order_line_id', 'pl.item_id', 'i.name as item_name',
      'i.sku', 'i.barcode', 'i.unit', 'pl.qty_target', 'pl.qty_picked'])
    .where('pl.pick_list_id', '=', id).orderBy('pl.line_no').execute();
  return {
    ...summary!,
    lines: lines.map((l) => ({
      id: l.id, lineNo: l.line_no, orderId: l.order_id, orderNumber: l.order_number, orderLineId: l.order_line_id, itemId: l.item_id,
      itemName: l.item_name, sku: l.sku, barcode: l.barcode, unit: l.unit, qtyTarget: l.qty_target, qtyPicked: l.qty_picked,
    })),
  };
}

async function lockPickList(tx: Tx, ctx: RequestContext, id: string) {
  const p = await tx.selectFrom('pick_lists').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!p || !ctx.canAccessLocation(p.location_id)) throw notFound('Pick list');
  return p;
}

const listIllegal = (p: { status: string }, action: string) =>
  conflict(`This pick list is ${p.status}, so it can't be ${action}.`, 'ILLEGAL_TRANSITION', { status: p.status });

/** Orders for pick-list locking are always taken in id order so concurrent lists cannot deadlock. */
async function lockOrdersSorted(tx: Tx, ctx: RequestContext, ids: string[]) {
  const out = [];
  for (const id of [...new Set(ids)].sort()) out.push(await lockOrder(tx, ctx, id));
  return out;
}

export async function fulfilmentRoutes(app: FastifyInstance) {
  app.get('/pick-lists', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = listSelect(tx).where('p.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('p.location_id', 'in', scope);
      if (q.status) base = base.where('p.status', '=', q.status);
      if (q.locationId) base = base.where('p.location_id', '=', q.locationId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([
          eb('p.number', 'ilike', t),
          eb.exists(eb.selectFrom('pick_list_lines as pl').innerJoin('sales_orders as o', 'o.id', 'pl.order_id')
            .select('pl.id').whereRef('pl.pick_list_id', '=', 'p.id').where('o.number', 'ilike', t)),
        ]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('p.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await listSummaries(tx, rows), total };
    });
  });

  app.get<{ Params: { id: string } }>('/pick-lists/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadPickList(tx, ctx, id));
  });

  app.post('/pick-lists', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const body = parse(createListBody, req.body);
    const created = await ctx.tx(async (tx) => {
      const loc = await tx.selectFrom('locations').select(['id', 'name']).where('id', '=', body.locationId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!loc || !ctx.canAccessLocation(loc.id)) throw badRequest('Location not found.', { locationId: 'Not found' });
      const orders = await lockOrdersSorted(tx, ctx, body.orderIds);
      for (const o of orders) {
        if (o.location_id !== loc.id) throw badRequest(`Order ${o.number} is at another location.`, { orderIds: 'Wrong location' });
        if (!(FULFILLABLE as readonly string[]).includes(o.status)) throw illegal(o, 'picked');
      }
      const rows: { orderId: string; lineId: string; itemId: string; qty: number }[] = [];
      for (const o of orders) {
        const lines = await lockLines(tx, o.id);
        const onLists = await tx.selectFrom('pick_list_lines as pl').innerJoin('pick_lists as p', 'p.id', 'pl.pick_list_id')
          .select(['pl.order_line_id', sql<number>`sum(pl.qty_target - pl.qty_picked)`.as('out')])
          .where('pl.order_id', '=', o.id).where('p.status', '=', 'open').groupBy('pl.order_line_id').execute();
        const outBy = new Map(onLists.map((r) => [r.order_line_id, Number(r.out)]));
        for (const l of lines) {
          const pickable = round3(l.qty_reserved - (l.qty_picked - l.qty_dispatched) - (outBy.get(l.id) ?? 0));
          if (pickable > EPS) rows.push({ orderId: o.id, lineId: l.id, itemId: l.item_id, qty: pickable });
        }
      }
      if (!rows.length) throw conflict(`Nothing to pick at ${loc.name}.`, 'NOTHING_TO_PICK', { locationId: loc.id });
      const number = await nextNumber(tx, ctx, 'pick_list', financialYear(todayIst()));
      const list = await tx.insertInto('pick_lists').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: loc.id, number, status: 'open', created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('pick_list_lines').values(rows.map((r, i) => ({
        tenant_id: ctx.tenantId, pick_list_id: list.id, line_no: i + 1, order_id: r.orderId, order_line_id: r.lineId,
        item_id: r.itemId, qty_target: r.qty, qty_picked: 0,
      }))).execute();
      for (const o of orders) {
        await addEvent(tx, ctx, o.id, 'pick', `Pick list ${number} created`);
        await refreshStatus(tx, ctx, o.id);
      }
      await writeAudit(tx, auditOf(ctx), 'pick_list', list.id, 'create', null, { number, orders: orders.map((o) => o.number) });
      return loadPickList(tx, ctx, list.id);
    });
    return reply.status(201).send(created);
  });

  app.post<{ Params: { id: string } }>('/pick-lists/:id/scan', async (req) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(scanBody, req.body);
    return ctx.tx(async (tx) => {
      const list = await lockPickList(tx, ctx, id);
      const prior = await tx.selectFrom('scan_events').select('result').where('company_id', '=', ctx.companyId)
        .where('kind', '=', 'pick').where('ref_id', '=', id).where('scan_id', '=', body.scanId).executeTakeFirst();
      if (prior) return { ...(prior.result as object), duplicate: true, pickList: await loadPickList(tx, ctx, id) };
      if (list.status !== 'open') throw listIllegal(list, 'scanned');
      const item = await resolveScanItem(tx, ctx, body);
      let lines = await tx.selectFrom('pick_list_lines').selectAll().where('pick_list_id', '=', id).where('item_id', '=', item.id)
        .orderBy('line_no').forUpdate().execute();
      if (body.orderLineId) lines = lines.filter((l) => l.order_line_id === body.orderLineId);
      if (!lines.length) throw new AppError(400, 'WRONG_ITEM', `${item.name} is not on this pick list.`, { itemId: item.id });
      const remaining = round3(lines.reduce((s, l) => s + (l.qty_target - l.qty_picked), 0));
      if (body.qty > remaining + EPS) {
        throw new AppError(400, 'OVER_PICK', remaining <= EPS ? `${item.name} is already fully picked.` : `Only ${remaining} more of ${item.name} is needed.`,
          { itemId: item.id, remaining });
      }
      const orders = await lockOrdersSorted(tx, ctx, lines.map((l) => l.order_id));
      const allocations: { lineId: string; qty: number }[] = [];
      let left = body.qty;
      for (const l of lines) {
        if (left <= EPS) break;
        const take = round3(Math.min(left, l.qty_target - l.qty_picked));
        if (take <= EPS) continue;
        await tx.updateTable('pick_list_lines').set({ qty_picked: round3(l.qty_picked + take) }).where('id', '=', l.id).execute();
        await tx.updateTable('sales_order_lines').set((eb) => ({ qty_picked: eb('qty_picked', '+', take) })).where('id', '=', l.order_line_id).execute();
        allocations.push({ lineId: l.order_line_id, qty: take });
        left = round3(left - take);
      }
      const result = { item: { id: item.id, name: item.name, sku: item.sku }, qty: body.qty, allocations };
      await tx.insertInto('scan_events').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: 'pick', ref_id: id, scan_id: body.scanId, code: body.code ?? null,
        item_id: item.id, qty: body.qty, result: JSON.stringify(result) as never, created_by: ctx.userId,
      }).execute();
      for (const o of orders) await refreshStatus(tx, ctx, o.id);
      return { duplicate: false, ...result, pickList: await loadPickList(tx, ctx, id) };
    });
  });

  app.post<{ Params: { id: string } }>('/pick-lists/:id/complete', async (req) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const list = await lockPickList(tx, ctx, id);
      if (list.status !== 'open') throw listIllegal(list, 'completed');
      await tx.updateTable('pick_lists').set({ status: 'completed', completed_at: new Date() }).where('id', '=', id).execute();
      const orderIds = (await tx.selectFrom('pick_list_lines').select('order_id').distinct().where('pick_list_id', '=', id).execute()).map((r) => r.order_id);
      for (const o of await lockOrdersSorted(tx, ctx, orderIds)) {
        await addEvent(tx, ctx, o.id, 'pick', `Pick list ${list.number} completed`);
        await refreshStatus(tx, ctx, o.id);
      }
      await writeAudit(tx, auditOf(ctx), 'pick_list', id, 'complete', { status: 'open' }, { status: 'completed' });
      return loadPickList(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/pick-lists/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const list = await lockPickList(tx, ctx, id);
      if (list.status !== 'open') throw listIllegal(list, 'cancelled');
      const lines = await tx.selectFrom('pick_list_lines').select(['order_id', 'qty_picked']).where('pick_list_id', '=', id).execute();
      if (lines.some((l) => l.qty_picked > EPS)) throw conflict('Some items are already picked, so this list can only be completed.', 'HAS_PICKS');
      await tx.updateTable('pick_lists').set({ status: 'cancelled' }).where('id', '=', id).execute();
      for (const o of await lockOrdersSorted(tx, ctx, lines.map((l) => l.order_id))) {
        await addEvent(tx, ctx, o.id, 'pick', `Pick list ${list.number} cancelled`);
        await refreshStatus(tx, ctx, o.id);
      }
      await writeAudit(tx, auditOf(ctx), 'pick_list', id, 'cancel', { status: 'open' }, { status: 'cancelled' });
      return loadPickList(tx, ctx, id);
    });
  });

  // ---- pack -----------------------------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/sales-orders/:id/pack-scans', async (req) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(packScanBody, req.body);
    return ctx.tx(async (tx) => {
      const order = await lockOrder(tx, ctx, id);
      const prior = await tx.selectFrom('scan_events').select('result').where('company_id', '=', ctx.companyId)
        .where('kind', '=', 'pack').where('ref_id', '=', id).where('scan_id', '=', body.scanId).executeTakeFirst();
      if (prior) return { ...(prior.result as object), duplicate: true, order: await loadOrder(tx, ctx, id) };
      if (!(FULFILLABLE as readonly string[]).includes(order.status)) throw illegal(order, 'packed');
      const item = await resolveScanItem(tx, ctx, body);
      const lines = (await lockLines(tx, id)).filter((l) => l.item_id === item.id);
      if (!lines.length) throw new AppError(400, 'WRONG_ITEM', `${item.name} is not on this order.`, { itemId: item.id });
      const room = round3(lines.reduce((s, l) => s + (l.qty_picked - l.qty_packed), 0));
      if (room <= EPS && !lines.some((l) => l.qty_picked - l.qty_dispatched > EPS)) {
        throw new AppError(400, 'WRONG_ITEM', `${item.name} has not been picked for this order.`, { itemId: item.id });
      }
      if (body.qty > room + EPS) {
        throw new AppError(400, 'OVER_PACK', room <= EPS ? `${item.name} is already fully packed.` : `Only ${room} more of ${item.name} was picked.`,
          { itemId: item.id, remaining: room });
      }
      let left = body.qty;
      for (const l of lines) {
        if (left <= EPS) break;
        const take = round3(Math.min(left, l.qty_picked - l.qty_packed));
        if (take <= EPS) continue;
        await tx.updateTable('sales_order_lines').set({ qty_packed: round3(l.qty_packed + take) }).where('id', '=', l.id).execute();
        left = round3(left - take);
      }
      const result = { item: { id: item.id, name: item.name, sku: item.sku }, qty: body.qty };
      await tx.insertInto('scan_events').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: 'pack', ref_id: id, scan_id: body.scanId, code: body.code ?? null,
        item_id: item.id, qty: body.qty, result: JSON.stringify(result) as never, created_by: ctx.userId,
      }).execute();
      await refreshStatus(tx, ctx, id);
      return { duplicate: false, ...result, order: await loadOrder(tx, ctx, id) };
    });
  });

  app.post<{ Params: { id: string } }>('/sales-orders/:id/pack', async (req) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(packBody, req.body ?? {});
    return ctx.tx(async (tx) => {
      const order = await lockOrder(tx, ctx, id);
      if (!(FULFILLABLE as readonly string[]).includes(order.status)) throw illegal(order, 'packed');
      const lines = await lockLines(tx, id);
      const want = new Map<string, number>();
      if (body.lines) {
        for (const l of body.lines) {
          if (!lines.some((x) => x.id === l.lineId)) throw badRequest('Not a line of this order.', { lineId: 'Not found' });
          want.set(l.lineId, round3((want.get(l.lineId) ?? 0) + l.qty));
        }
      } else {
        for (const l of lines) if (l.qty_picked - l.qty_packed > EPS) want.set(l.id, round3(l.qty_picked - l.qty_packed));
      }
      if (!want.size) throw conflict('Nothing is waiting to be packed.', 'NOTHING_TO_PACK');
      for (const [lineId, qty] of want) {
        const l = lines.find((x) => x.id === lineId)!;
        const room = round3(l.qty_picked - l.qty_packed);
        if (qty > room + EPS) throw new AppError(400, 'OVER_PACK', `Line ${l.line_no}: only ${room} more was picked.`, { lineId, remaining: room });
        await tx.updateTable('sales_order_lines').set({ qty_packed: round3(l.qty_packed + qty) }).where('id', '=', lineId).execute();
      }
      await addEvent(tx, ctx, id, 'pack', 'Packed');
      await refreshStatus(tx, ctx, id);
      await writeAudit(tx, auditOf(ctx), 'sales_order', id, 'pack', null, { lines: [...want] });
      return loadOrder(tx, ctx, id);
    });
  });

  // ---- dispatch -------------------------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/sales-orders/:id/dispatch', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(dispatchBody, req.body ?? {});
    const key = req.idemKey ?? null;
    const shipment = await ctx.tx(async (tx) => {
      const order = await lockOrder(tx, ctx, id);
      if (!(FULFILLABLE as readonly string[]).includes(order.status)) throw illegal(order, 'dispatched');
      const lines = await lockLines(tx, id);
      const ship = lines.filter((l) => l.qty_packed - l.qty_dispatched > EPS);
      if (!ship.length) throw conflict('Nothing is packed and ready to dispatch.', 'NOTHING_TO_DISPATCH');
      if (lines.some((l) => Math.abs(l.qty_picked - l.qty_packed) > EPS)) {
        throw conflict('Packed quantity does not match picked.', 'PACK_INCOMPLETE');
      }
      if (body.mode === 'prepaid' && body.codAmount && body.codAmount > 0) {
        throw badRequest('A prepaid shipment has no cash to collect.', { codAmount: 'Must be 0 for prepaid' });
      }
      await lockItems(tx, ctx.companyId, ship.map((l) => l.item_id));
      const qtys = ship.map((l) => ({ line: l, qty: round3(l.qty_packed - l.qty_dispatched) }));
      for (const { line, qty } of qtys) {
        await closeReservation(tx, line.id, Math.min(qty, line.qty_reserved), 'consumed', 'Dispatched');
        await tx.updateTable('sales_order_lines').set({
          qty_reserved: round3(Math.max(line.qty_reserved - qty, 0)), qty_dispatched: round3(line.qty_dispatched + qty),
        }).where('id', '=', line.id).execute();
      }
      const invoice = await createInvoice(ctx, tx, {
        locationId: order.location_id, partyId: order.party_id, invoiceDate: body.invoiceDate, notes: `Sales order ${order.number}`,
        lines: qtys.map(({ line, qty }) => ({ itemId: line.item_id, qty, rate: line.rate, discountPct: line.discount_pct, description: line.description })),
      } as Parameters<typeof createInvoice>[2]);
      const invLines = await tx.selectFrom('invoice_lines').select(['id', 'line_no']).where('invoice_id', '=', invoice.id).orderBy('line_no').execute();
      const cod = body.mode === 'cod' ? (body.codAmount ?? invoice.total) : 0;
      const number = await nextNumber(tx, ctx, 'shipment', financialYear(todayIst()));
      const row = await tx.insertInto('shipments').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, order_id: id, invoice_id: invoice.id, number, courier: body.courier ?? null,
        awb: body.awb ?? null, mode: body.mode, cod_amount: cod, status: 'booked', dispatch_key: key, notes: body.notes ?? null,
        created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('shipment_lines').values(qtys.map(({ line, qty }, i) => ({
        tenant_id: ctx.tenantId, shipment_id: row.id, order_line_id: line.id, invoice_line_id: invLines[i]!.id, item_id: line.item_id, qty,
      }))).execute();
      await tx.insertInto('shipment_status_history').values({
        tenant_id: ctx.tenantId, shipment_id: row.id, status: 'booked', note: null, created_by: ctx.userId,
      }).execute();
      await addEvent(tx, ctx, id, 'dispatch', `Dispatched on invoice ${invoice.number} (shipment ${number})`);
      await refreshStatus(tx, ctx, id);
      await writeAudit(tx, auditOf(ctx), 'shipment', row.id, 'create', null, { number, orderId: id, invoiceId: invoice.id, mode: body.mode });
      return loadShipment(tx, ctx, row.id);
    });
    return reply.status(201).send(shipment);
  });
}

documentRoute('POST', '/pick-lists', { body: createListBody });
documentRoute('POST', '/pick-lists/:id/scan', { body: scanBody });
documentRoute('POST', '/sales-orders/:id/pack-scans', { body: packScanBody });
