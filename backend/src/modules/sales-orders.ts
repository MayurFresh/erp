import { emitEvent } from '../lib/webhooks.ts';
import { assertFresh } from '../lib/stale.ts';
import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { lockItems, locationQty } from '../accounting/costing.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { fallbackRates } from '../lib/pricing.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import {
  EPS, FULFILLABLE, addEvent, addReservation, closeReservation, lockLines, lockOrder, openQty, refreshStatus, round2, round3,
  type OrderLine,
} from './o2c-common.ts';
import { reservedQty } from './stock.ts';
import { enforceCreditLimit, type CreditCheck } from './credit-limit.ts';
import { documentRoute } from '../lib/openapi.ts';
import { convertUnits, enteredJson, enteredOf, saveEntered } from '../lib/uom.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const positive = qtyField.refine((v) => v > 0, 'Must be more than zero');

const lineBody = z.object({
  itemId: z.uuid(),
  qty: positive,
  rate: moneyField.optional(),
  discountPct: percentField.optional(),
  description: optionalText(300),
  allowBackorder: z.boolean().optional(),
  /** Unit the quantity and rate are entered in (an alternate unit of the item); omitted means the base unit. */
  unit: z.string().trim().max(20).optional(),
});
const orderFields = {
  locationId: z.uuid(),
  partyId: z.uuid(),
  orderDate: docDate.optional(),
  expectedDate: dateField.nullable().optional(),
  externalRef: z.string().trim().min(1).max(100).nullable().optional(),
  notes: optionalText(2000),
  lines: z.array(lineBody).min(1, 'Add at least one line').max(200, 'At most 200 lines'),
};
const createBody = z.object({ ...orderFields, allowOverLimit: z.boolean().optional() });
const patchBody = z.object(orderFields).partial().extend({ expectedUpdatedAt: z.string().max(40).optional() });
const cancelBody = z.object({
  reason: z.string().trim().min(3, 'Give a reason').max(300),
  lines: z.array(z.object({ lineId: z.uuid(), qty: positive })).min(1).max(200).optional(),
});
const listQuery = pagingQuery.extend({
  status: z.enum(['draft', 'confirmed', 'picking', 'packed', 'partially_dispatched', 'dispatched', 'closed', 'cancelled']).optional(),
  partyId: z.uuid().optional(),
  locationId: z.uuid().optional(),
  from: dateField.optional(),
  to: dateField.optional(),
});
const availabilityQuery = pagingQuery.extend({ locationId: z.uuid() });

export const illegal = (order: { status: string }, action: string) =>
  conflict(`This order is ${order.status.replace('_', ' ')}, so it can't be ${action}.`, 'ILLEGAL_TRANSITION', { status: order.status });

type CreateBody = z.infer<typeof createBody>;

/** Validates references and works out an estimate of the totals with the invoice's GST rules. */
async function prepare(tx: Tx, ctx: RequestContext, body: { locationId: string; partyId: string; lines: CreateBody['lines']; placeOfSupply?: string | null }) {
  const location = await getLocation(tx, ctx, body.locationId);
  if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
  const party = await tx.selectFrom('parties').selectAll()
    .where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!party) throw badRequest('Customer not found.', { partyId: 'Not found' });
  if (party.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });
  await convertUnits(tx, ctx, body.lines);
  const ids = [...new Set(body.lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').selectAll().where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const byId = new Map(items.map((i) => [i.id, i]));
  const priced = await fallbackRates(tx, ctx.companyId, body.partyId, body.lines, todayIst());
  const lines = body.lines.map((l, idx) => {
    const item = byId.get(l.itemId);
    if (!item) throw badRequest(`Line ${idx + 1}: item not found.`, { [`lines.${idx}.itemId`]: 'Not found' });
    if (!item.is_active) throw badRequest(`Line ${idx + 1}: ${item.name} is inactive.`, { [`lines.${idx}.itemId`]: 'Inactive' });
    if (!item.track_stock) {
      throw badRequest(`Line ${idx + 1}: ${item.name} is not a stock item. Only stock items can be on a sales order.`, { [`lines.${idx}.itemId`]: 'Not a stock item' });
    }
    return {
      item, qty: l.qty, rate: l.rate ?? priced[idx] ?? item.sale_price, discountPct: l.discountPct ?? 0, description: l.description ?? item.name,
      allowBackorder: l.allowBackorder ?? false,
    };
  });
  const placeOfSupply = body.placeOfSupply ?? party.state_code ?? location.state_code;
  const gst = computeGst(location.state_code, placeOfSupply, lines.map((l) => ({
    qty: l.qty, rate: l.rate, discountPct: l.discountPct, gstRate: l.item.gst_rate,
  })));
  return { location, party, lines, placeOfSupply, gst, entered: enteredOf(body.lines) };
}

type Prepared = Awaited<ReturnType<typeof prepare>>;

async function insertLines(tx: Tx, ctx: RequestContext, orderId: string, p: Prepared) {
  await tx.insertInto('sales_order_lines').values(p.lines.map((l, i) => ({
    tenant_id: ctx.tenantId, order_id: orderId, line_no: i + 1, item_id: l.item.id, description: l.description,
    qty_ordered: l.qty, rate: l.rate, discount_pct: l.discountPct, gst_rate: l.item.gst_rate, allow_backorder: l.allowBackorder,
  }))).execute();
  await saveEntered(tx, 'sales_order_lines', 'order_id', orderId, p.entered);
}

const isDuplicateRef = (err: unknown) => ['sales_orders_external_uq', 'sales_orders_channel_ref_uq'].includes((err as { constraint?: string }).constraint ?? '');
const duplicateRef = () => conflict('An order with this external reference already exists.', 'DUPLICATE_ORDER', { externalRef: 'Already used' });

function orderSelect(tx: Tx) {
  return tx.selectFrom('sales_orders as o')
    .innerJoin('locations as l', 'l.id', 'o.location_id')
    .innerJoin('parties as p', 'p.id', 'o.party_id')
    .innerJoin('users as u', 'u.id', 'o.created_by')
    .selectAll('o')
    .select(['l.name as location_name', 'p.name as party_name', 'u.name as created_by_name']);
}
type OrderRow = Awaited<ReturnType<ReturnType<typeof orderSelect>['executeTakeFirstOrThrow']>>;

export function orderJson(r: OrderRow, packVerified = false) {
  return {
    id: r.id, number: r.number, fy: r.fy, status: r.status, source: r.source, externalRef: r.external_ref,
    locationId: r.location_id, locationName: r.location_name, partyId: r.party_id, partyName: r.party_name,
    orderDate: r.order_date, expectedDate: r.expected_date, placeOfSupply: r.place_of_supply, subtotal: r.subtotal,
    taxTotal: r.tax_total, total: r.total, notes: r.notes, cancelReason: r.cancel_reason, confirmedAt: r.confirmed_at,
    packVerified, createdAt: r.created_at, updatedAt: r.updated_at, createdBy: { id: r.created_by, name: r.created_by_name },
  };
}

async function linesJson(tx: Tx, orderId: string) {
  const rows = await tx.selectFrom('sales_order_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .selectAll('l').select(['i.name as item_name', 'i.sku', 'i.barcode', 'i.unit'])
    .where('l.order_id', '=', orderId).orderBy('l.line_no').execute();
  return rows.map((l) => ({
    id: l.id, lineNo: l.line_no, itemId: l.item_id, itemName: l.item_name, sku: l.sku, barcode: l.barcode, unit: l.unit,
    description: l.description, qtyOrdered: l.qty_ordered, rate: l.rate, discountPct: l.discount_pct, gstRate: l.gst_rate,
    allowBackorder: l.allow_backorder, qtyReserved: l.qty_reserved, qtyPicked: l.qty_picked, qtyPacked: l.qty_packed,
    qtyDispatched: l.qty_dispatched, qtyReturned: l.qty_returned, qtyCancelled: l.qty_cancelled,
    qtyOpen: openQty(l), qtyShort: round3(openQty(l) - l.qty_reserved), ...enteredJson(l, l.qty_ordered),
  }));
}

export async function loadOrder(tx: Tx, ctx: RequestContext, id: string) {
  const row = await orderSelect(tx).where('o.id', '=', id).where('o.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Sales order');
  const lines = await linesJson(tx, id);
  const events = await tx.selectFrom('sales_order_events as e').leftJoin('users as u', 'u.id', 'e.created_by')
    .select(['e.kind', 'e.message', 'e.created_at', 'u.name as by_name']).where('e.order_id', '=', id).orderBy('e.created_at').execute();
  const shipments = await tx.selectFrom('shipments as s').innerJoin('invoices as v', 'v.id', 's.invoice_id')
    .select(['s.id', 's.number', 's.status', 's.awb', 's.courier', 'v.number as invoice_number']).where('s.order_id', '=', id)
    .orderBy('s.created_at').execute();
  const returns = await tx.selectFrom('sales_returns').select(['id', 'number', 'type', 'status']).where('order_id', '=', id)
    .orderBy('created_at').execute();
  return {
    ...orderJson(row, lines.every((l) => Math.abs(l.qtyPicked - l.qtyPacked) < EPS)),
    lines,
    events: events.map((e) => ({ kind: e.kind, message: e.message, createdAt: e.created_at, by: e.by_name })),
    shipments: shipments.map((s) => ({ id: s.id, number: s.number, status: s.status, awb: s.awb, courier: s.courier, invoiceNumber: s.invoice_number })),
    returns: returns.map((r) => ({ id: r.id, number: r.number, type: r.type, status: r.status })),
  };
}

/** Available stock per item at the order's location, using the locks held by the caller. */
async function availableOf(tx: Tx, ctx: RequestContext, locationId: string, itemId: string) {
  const onHand = await locationQty(tx, ctx.companyId, locationId, itemId);
  const reserved = await reservedQty(tx, ctx.companyId, locationId, itemId);
  return round3(onHand - reserved);
}

/**
 * Reserves stock for the open, unreserved quantity of each line. Strict mode (confirm) reserves a line fully or
 * fails the whole order with the shortages; backorder lines (and `strict = false`) reserve what is available.
 */
async function reserveOrder(tx: Tx, ctx: RequestContext, order: { id: string; location_id: string }, lines: OrderLine[], strict: boolean) {
  await lockItems(tx, ctx.companyId, lines.map((l) => l.item_id));
  const left = new Map<string, number>();
  const plan: { line: OrderLine; take: number }[] = [];
  const shortages: Record<string, unknown>[] = [];
  const names = new Map((await tx.selectFrom('items').select(['id', 'name']).where('id', 'in', [...new Set(lines.map((l) => l.item_id))]).execute())
    .map((i) => [i.id, i.name]));
  for (const line of lines) {
    const need = round3(openQty(line) - line.qty_reserved);
    if (need <= EPS) continue;
    if (!left.has(line.item_id)) left.set(line.item_id, await availableOf(tx, ctx, order.location_id, line.item_id));
    const avail = Math.max(left.get(line.item_id)!, 0);
    if (strict && !line.allow_backorder && avail + EPS < need) {
      shortages.push({ lineNo: line.line_no, itemId: line.item_id, itemName: names.get(line.item_id), available: avail, required: need });
      continue;
    }
    const take = round3(Math.min(avail, need));
    left.set(line.item_id, round3(left.get(line.item_id)! - take));
    if (take > EPS) plan.push({ line, take });
  }
  if (shortages.length) {
    const first = shortages[0]!;
    throw conflict(`Not enough stock for ${shortages.length === 1 ? String(first.itemName) : `${shortages.length} items`}. Only ${String(first.available)} available for ${String(first.required)} ordered.`,
      'INSUFFICIENT_STOCK', { shortages });
  }
  for (const { line, take } of plan) {
    await addReservation(tx, ctx, order, line, take);
    await tx.updateTable('sales_order_lines').set({ qty_reserved: round3(line.qty_reserved + take) }).where('id', '=', line.id).execute();
  }
  return plan.reduce((s, p) => s + p.take, 0);
}

/** Confirms a draft and reserves its stock; fails with INSUFFICIENT_STOCK unless every line is covered or on backorder. */
export async function confirmOrder(tx: Tx, ctx: RequestContext, id: string): Promise<void> {
  const order = await lockOrder(tx, ctx, id);
  if (order.status !== 'draft') throw illegal(order, 'confirmed');
  const lines = await lockLines(tx, id);
  const location = await tx.selectFrom('locations').select('is_active').where('id', '=', order.location_id).executeTakeFirstOrThrow();
  if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
  await reserveOrder(tx, ctx, order, lines, true);
  await tx.updateTable('sales_orders').set({ status: 'confirmed', confirmed_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
  const after = await lockLines(tx, id);
  const short = after.filter((l) => openQty(l) - l.qty_reserved > EPS).length;
  await addEvent(tx, ctx, id, 'confirmed', short ? `Order confirmed; ${short} line${short === 1 ? '' : 's'} on backorder` : 'Order confirmed and stock reserved');
  await writeAudit(tx, auditOf(ctx), 'sales_order', id, 'confirm', { status: 'draft' }, { status: 'confirmed' });
}

/** Cancels a draft, or the open quantity of a fulfillable order (all lines unless `body.lines`). */
export async function cancelOrder(tx: Tx, ctx: RequestContext, id: string, body: z.infer<typeof cancelBody>): Promise<void> {
  const order = await lockOrder(tx, ctx, id);
  if (order.status !== 'draft' && !(FULFILLABLE as readonly string[]).includes(order.status)) throw illegal(order, 'cancelled');
  if (order.status === 'draft') {
    if (body.lines) throw badRequest('Cancel the whole draft order.', { lines: 'Not allowed for a draft' });
    await tx.updateTable('sales_orders').set({ status: 'cancelled', cancel_reason: body.reason, cancelled_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
    await addEvent(tx, ctx, id, 'cancelled', `Draft cancelled: ${body.reason}`);
    await writeAudit(tx, auditOf(ctx), 'sales_order', id, 'cancel', { status: 'draft' }, { status: 'cancelled', reason: body.reason });
    return;
  }
  const onList = await tx.selectFrom('pick_list_lines as pl').innerJoin('pick_lists as p', 'p.id', 'pl.pick_list_id')
    .select('p.number').where('pl.order_id', '=', id).where('p.status', '=', 'open').executeTakeFirst();
  if (onList) throw conflict(`Pick list ${onList.number} is open for this order. Complete or cancel it first.`, 'HAS_OPEN_PICK_LIST');
  const lines = await lockLines(tx, id);
  await lockItems(tx, ctx.companyId, lines.map((l) => l.item_id));
  const wanted = new Map<string, number>();
  if (body.lines) {
    for (const l of body.lines) {
      const line = lines.find((x) => x.id === l.lineId);
      if (!line) throw badRequest('Not a line of this order.', { lineId: 'Not found' });
      if (wanted.has(line.id)) throw badRequest('Each line can appear once.', { lineId: 'Duplicate' });
      if (l.qty > openQty(line) + EPS) {
        throw badRequest(`Line ${line.line_no}: only ${openQty(line)} can still be cancelled.`, { qty: `At most ${openQty(line)}` });
      }
      wanted.set(line.id, l.qty);
    }
  } else {
    for (const line of lines) if (openQty(line) > EPS) wanted.set(line.id, openQty(line));
  }
  for (const line of lines) {
    const q = wanted.get(line.id);
    if (!q) continue;
    const openAfter = round3(openQty(line) - q);
    const reservedAfter = round3(Math.min(line.qty_reserved, openAfter));
    await closeReservation(tx, line.id, round3(line.qty_reserved - reservedAfter), 'released', `Cancelled: ${body.reason}`.slice(0, 300));
    const pickedOut = round3(line.qty_picked - line.qty_dispatched);
    const pickedNew = round3(line.qty_dispatched + Math.min(pickedOut, reservedAfter));
    await tx.updateTable('sales_order_lines').set({
      qty_cancelled: round3(line.qty_cancelled + q), qty_reserved: reservedAfter,
      qty_picked: pickedNew, qty_packed: Math.min(line.qty_packed, pickedNew),
    }).where('id', '=', line.id).execute();
  }
  const status = await refreshStatus(tx, ctx, id);
  await tx.updateTable('sales_orders').set({ cancel_reason: body.reason, updated_at: new Date() }).where('id', '=', id).execute();
  await addEvent(tx, ctx, id, 'cancelled', `${body.lines ? 'Quantity cancelled' : 'Open quantity cancelled'}: ${body.reason}`);
  await writeAudit(tx, auditOf(ctx), 'sales_order', id, 'cancel', { status: order.status }, { status, reason: body.reason });
}

export interface NewOrder extends CreateBody {
  source?: 'manual' | 'csv' | 'channel'; placeOfSupply?: string | null; createdNote?: string; channelId?: string | null;
}

/** Creates a draft order and returns its id. A repeated external reference fails on a unique index (see isDuplicateRef). */
export async function createOrder(
  tx: Tx, ctx: RequestContext, body: NewOrder,
  /** Set by the HTTP route only; channel imports and other callers are never blocked by the credit limit. */
  opts?: { creditCheck?: CreditCheck },
): Promise<string> {
  const p = await prepare(tx, ctx, body);
  if (opts?.creditCheck) await enforceCreditLimit(tx, ctx, p.party.id, p.gst.total, opts.creditCheck);
  const orderDate = body.orderDate ?? todayIst();
  const number = await nextNumber(tx, ctx, 'sales_order', financialYear(orderDate));
  const row = await tx.insertInto('sales_orders').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: p.location.id, party_id: p.party.id, number,
    fy: financialYear(orderDate), order_date: orderDate, expected_date: body.expectedDate ?? null,
    external_ref: body.externalRef ?? null, source: body.source ?? 'manual', channel_id: body.channelId ?? null, place_of_supply: p.placeOfSupply, subtotal: p.gst.subtotal,
    tax_total: p.gst.taxTotal, total: p.gst.total, notes: body.notes ?? null, created_by: ctx.userId,
    cancel_reason: null, confirmed_at: null, cancelled_at: null, closed_at: null,
  }).returning('id').executeTakeFirstOrThrow();
  await insertLines(tx, ctx, row.id, p);
  await addEvent(tx, ctx, row.id, 'created', body.createdNote ?? `Order ${number} created as a draft`);
  await writeAudit(tx, auditOf(ctx), 'sales_order', row.id, 'create', null, { number, total: p.gst.total });
  await emitEvent(tx, ctx, 'order.created', { id: row.id, number, total: p.gst.total, partyId: p.party.id });
  return row.id;
}

export async function salesOrderRoutes(app: FastifyInstance) {
  app.get('/sales-orders', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = orderSelect(tx).where('o.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('o.location_id', 'in', scope);
      if (q.status) base = base.where('o.status', '=', q.status);
      if (q.partyId) base = base.where('o.party_id', '=', q.partyId);
      if (q.locationId) base = base.where('o.location_id', '=', q.locationId);
      if (q.from) base = base.where('o.order_date', '>=', q.from);
      if (q.to) base = base.where('o.order_date', '<=', q.to);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('o.number', 'ilike', t), eb('p.name', 'ilike', t), eb('o.external_ref', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('o.order_date', 'desc').orderBy('o.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map((r) => orderJson(r)), total };
    });
  });

  app.get('/sales-orders/availability', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const q = parse(availabilityQuery, req.query);
    return ctx.tx(async (tx) => {
      const loc = await getLocation(tx, ctx, q.locationId);
      let base = tx.selectFrom('items as i').where('i.company_id', '=', ctx.companyId)
        .where('i.is_active', '=', true).where('i.track_stock', '=', true);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('i.name', 'ilike', t), eb('i.sku', 'ilike', t), eb('i.barcode', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.select(['i.id', 'i.name', 'i.sku', 'i.barcode', 'i.unit', 'i.sale_price', 'i.gst_rate'])
        .select(sql<number>`coalesce((select sum(m.qty) from stock_moves m where m.item_id = i.id and m.location_id = ${loc.id}), 0)`.as('on_hand'))
        .select(sql<number>`coalesce((select sum(r.qty) from stock_reservations r where r.item_id = i.id and r.location_id = ${loc.id} and r.status = 'active'), 0)`.as('reserved'))
        .orderBy('i.name').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((r) => ({
          itemId: r.id, name: r.name, sku: r.sku, barcode: r.barcode, unit: r.unit, salePrice: r.sale_price, gstRate: r.gst_rate,
          onHand: Number(r.on_hand), reserved: Number(r.reserved), available: round3(Number(r.on_hand) - Number(r.reserved)),
        })),
        total,
      };
    });
  });

  app.get<{ Params: { id: string } }>('/sales-orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadOrder(tx, ctx, id));
  });

  app.post('/sales-orders', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.manage');
    const body = parse(createBody, req.body);
    try {
      const order = await ctx.tx(async (tx) => loadOrder(tx, ctx, await createOrder(tx, ctx, body, { creditCheck: { allowOver: body.allowOverLimit } })));
      return reply.status(201).send(order);
    } catch (err) {
      if (isDuplicateRef(err)) throw duplicateRef();
      throw err;
    }
  });

  app.patch<{ Params: { id: string } }>('/sales-orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    try {
      return await ctx.tx(async (tx) => {
        const order = await lockOrder(tx, ctx, id);
        assertFresh(order.updated_at, body.expectedUpdatedAt, 'order');
        if (order.status !== 'draft') throw illegal(order, 'edited');
        const old = await tx.selectFrom('sales_order_lines').select(['item_id', 'qty_ordered', 'rate', 'discount_pct', 'allow_backorder', 'description']).where('order_id', '=', id).orderBy('line_no').execute();
        const lineInput = body.lines ?? old.map((l) => ({
          itemId: l.item_id, qty: l.qty_ordered, rate: l.rate, discountPct: l.discount_pct, allowBackorder: l.allow_backorder, description: l.description,
        }));
        const p = await prepare(tx, ctx, { locationId: body.locationId ?? order.location_id, partyId: body.partyId ?? order.party_id, lines: lineInput });
        const orderDate = body.orderDate ?? order.order_date;
        await tx.updateTable('sales_orders').set({
          location_id: p.location.id, party_id: p.party.id, order_date: orderDate, fy: financialYear(orderDate),
          expected_date: body.expectedDate !== undefined ? body.expectedDate : order.expected_date,
          external_ref: body.externalRef !== undefined ? body.externalRef : order.external_ref,
          notes: body.notes !== undefined ? body.notes : order.notes, place_of_supply: p.placeOfSupply,
          subtotal: p.gst.subtotal, tax_total: p.gst.taxTotal, total: p.gst.total, updated_at: new Date(),
        }).where('id', '=', id).execute();
        await tx.deleteFrom('sales_order_lines').where('order_id', '=', id).execute();
        await insertLines(tx, ctx, id, p);
        await addEvent(tx, ctx, id, 'edited', 'Order edited');
        await writeAudit(tx, auditOf(ctx), 'sales_order', id, 'update', { total: order.total }, { total: p.gst.total });
        return loadOrder(tx, ctx, id);
      });
    } catch (err) {
      if (isDuplicateRef(err)) throw duplicateRef();
      throw err;
    }
  });

  app.post<{ Params: { id: string } }>('/sales-orders/:id/confirm', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await confirmOrder(tx, ctx, id);
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/sales-orders/:id/reserve', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const order = await lockOrder(tx, ctx, id);
      if (!(FULFILLABLE as readonly string[]).includes(order.status)) throw illegal(order, 'reserved');
      const lines = await lockLines(tx, id);
      const qty = await reserveOrder(tx, ctx, order, lines, false);
      if (qty > EPS) await addEvent(tx, ctx, id, 'reserved', `Reserved ${qty} more units for backordered lines`);
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/sales-orders/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      await cancelOrder(tx, ctx, id, body);
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/sales-orders/:id/close', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const order = await lockOrder(tx, ctx, id);
      if (order.status !== 'dispatched') throw illegal(order, 'closed');
      await tx.updateTable('sales_orders').set({ status: 'closed', closed_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
      await addEvent(tx, ctx, id, 'closed', 'Order closed');
      await writeAudit(tx, auditOf(ctx), 'sales_order', id, 'close', { status: 'dispatched' }, { status: 'closed' });
      return loadOrder(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/sales-orders', { body: createBody });
documentRoute('PATCH', '/sales-orders/:id', { body: patchBody });
documentRoute('POST', '/sales-orders/:id/cancel', { body: cancelBody });
