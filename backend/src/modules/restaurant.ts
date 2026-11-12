import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { systemAccounts } from '../accounting/accounts.ts';
import { todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import { postFolioCharge } from './hotel.ts';
import { createPayment } from './payments.ts';
import { documentRoute } from '../lib/openapi.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const DIETS = ['veg', 'non_veg', 'egg'] as const;
const KITCHEN_FLOW = ['new', 'preparing', 'ready', 'served'] as const;
type KStatus = (typeof KITCHEN_FLOW)[number];
const rank = (s: string) => KITCHEN_FLOW.indexOf(s as KStatus);
const ACTIVE = ['open', 'bill_printed'] as const;

const READ_ANY = ['restaurant.orders', 'restaurant.kitchen', 'restaurant.settle', 'restaurant.manage'];
const ORDER_ANY = ['restaurant.orders', 'restaurant.manage'];

// Validation -----------------------------------------------------------------------------------------

const qtyPositive = qtyField.refine((v) => v > 0 && v <= 1000, 'Must be more than zero');
const sortField = z.coerce.number().int().min(0).max(100000);
const nameField = (max: number) => z.string().trim().min(1, 'Required').max(max);

const settingsBody = z.object({
  serviceChargePct: percentField.max(30).optional(),
  serviceChargeGst: percentField.max(28).optional(),
  locationId: z.uuid().nullable().optional(),
});
const categoryBody = z.object({ name: nameField(80), sortOrder: sortField.optional(), isActive: z.boolean().optional() });
const categoryPatch = categoryBody.partial();
const menuFields = {
  categoryId: z.uuid().nullable().optional(),
  diet: z.enum(DIETS).optional(),
  available: z.boolean().optional(),
  station: nameField(40).optional(),
  shortName: nullableText(40),
};
const menuCreate = z.object({
  itemId: z.uuid().optional(),
  newItem: z.object({
    name: nameField(200), salePrice: moneyField, gstRate: percentField.max(28).default(5),
    hsnCode: z.preprocess((v) => (v === '' ? undefined : v), z.string().trim().regex(/^\d{4,8}$/, 'HSN/SAC must be 4–8 digits').optional()),
    unit: z.string().trim().min(1).max(20).default('PLATE'),
  }).optional(),
  ...menuFields,
}).refine((b) => !!b.itemId !== !!b.newItem, { message: 'Give an existing item or a new item', path: ['itemId'] });
const menuPatch = z.object({ ...menuFields, expectedUpdatedAt: z.string().max(40).optional() });
const areaBody = z.object({ name: nameField(60), sortOrder: sortField.optional(), isActive: z.boolean().optional() });
const tableBody = z.object({
  areaId: z.uuid(), name: nameField(30), seats: z.coerce.number().int().min(1).max(100).default(4),
  sortOrder: sortField.optional(), isActive: z.boolean().optional(),
});
const tablePatch = tableBody.partial();

const lineInput = z.object({ itemId: z.uuid(), qty: qtyPositive.default(1), note: optionalText(200) });
const orderCreate = z.object({
  kind: z.enum(['dine_in', 'takeaway', 'delivery']),
  tableId: z.uuid().optional(),
  covers: z.coerce.number().int().min(1).max(500).optional(),
  captainId: z.uuid().optional(),
  customerPartyId: z.uuid().optional(),
  customerName: optionalText(120),
  customerPhone: optionalText(20),
  deliveryAddress: optionalText(300),
  notes: optionalText(500),
  locationId: z.uuid().optional(),
  lines: z.array(lineInput).max(100).optional(),
});
const orderPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  covers: z.coerce.number().int().min(1).max(500).nullable().optional(),
  captainId: z.uuid().nullable().optional(),
  customerName: nullableText(120), customerPhone: nullableText(20), deliveryAddress: nullableText(300), notes: nullableText(500),
});
const addLines = z.object({ items: z.array(lineInput).min(1, 'Add at least one item').max(100) });
const linePatch = z.object({ qty: qtyPositive.optional(), note: nullableText(200) });
const cancelBody = z.object({ reason: z.string().trim().max(300).optional() });
const moveBody = z.object({ tableId: z.uuid() });
const mergeBody = z.object({ fromOrderId: z.uuid() });
const printBody = z.object({
  discountPct: percentField.optional(), discountAmount: z.coerce.number().positive().optional(), discountReason: optionalText(200), waiveServiceCharge: z.boolean().optional(),
});
const settleBody = z.object({
  payments: z.array(z.object({
    mode: z.enum(['cash', 'upi', 'card']), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
    reference: optionalText(60),
  })).max(10).default([]),
  partyId: z.uuid().optional(),
  chargeToRoom: z.object({ roomNumber: z.string().trim().min(1).max(20).optional(), reservationId: z.uuid().optional() })
    .refine((v) => v.roomNumber || v.reservationId, 'Give a room number').optional(),
}).refine((b) => b.chargeToRoom || b.payments.length > 0, { message: 'Add a payment', path: ['payments'] });
const kotQuery = z.object({
  station: z.string().trim().max(40).optional(),
  status: z.string().trim().max(60).optional(),
  orderId: z.uuid().optional(),
  limit: z.coerce.number().int().min(1).max(200).default(100),
});
const statusBody = z.object({ status: z.enum(KITCHEN_FLOW) });
const orderListQuery = z.object({
  kind: z.enum(['dine_in', 'takeaway', 'delivery']).optional(),
  status: z.string().trim().max(60).optional(),
  date: z.string().regex(/^\d{4}-\d{2}-\d{2}$/).optional(),
  q: z.string().trim().max(100).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(100),
  offset: z.coerce.number().int().min(0).default(0),
});

// Bill arithmetic ------------------------------------------------------------------------------------

export interface BillLine { itemId: string; name: string; qty: number; rate: number; gstRate: number }

/** Lines with the same item and rate share one row on the bill and the invoice. */
function groupLines(lines: BillLine[]): BillLine[] {
  const map = new Map<string, BillLine>();
  for (const l of lines) {
    const key = `${l.itemId}|${l.rate}`;
    const cur = map.get(key);
    if (cur) cur.qty = Math.round((cur.qty + l.qty) * 1000) / 1000;
    else map.set(key, { ...l });
  }
  return [...map.values()];
}

/** Bill figures: discount on every line, then service charge on the discounted food value, GST on each line's own rate. */
export function computeBill(lines: BillLine[], o: { discountPct: number; discountAmount?: number | null; serviceChargePct: number; serviceChargeGst: number; sellerState: string; placeOfSupply: string }) {
  const rows = groupLines(lines);
  // A fixed discount is split over the food lines in proportion to their value, in paise; the leftover paise go to the largest line.
  const grossP = rows.map((l) => Math.round(l.qty * l.rate * 100));
  const grossTotalP = grossP.reduce((a, b) => a + b, 0);
  const fixedP = o.discountAmount ? Math.min(Math.round(o.discountAmount * 100), grossTotalP) : 0;
  const shareP = grossP.map((g) => (grossTotalP > 0 ? Math.floor(fixedP * g / grossTotalP) : 0));
  if (fixedP > 0) {
    let big = 0;
    grossP.forEach((g, i) => { if (g > grossP[big]!) big = i; });
    shareP[big] = Math.min(shareP[big]! + fixedP - shareP.reduce((a, b) => a + b, 0), grossP[big]!);
  }
  const food = rows.map((l, i) => ({
    qty: l.qty, rate: l.rate, discountPct: fixedP > 0 ? 0 : o.discountPct, gstRate: l.gstRate,
    ...(fixedP > 0 ? { discountAmount: shareP[i]! / 100 } : {}),
  }));
  const pass1 = computeGst(o.sellerState, o.placeOfSupply, food);
  const serviceCharge = o.serviceChargePct > 0 ? round2(pass1.subtotal * o.serviceChargePct / 100) : 0;
  const inputs = serviceCharge > 0 ? [...food, { qty: 1, rate: serviceCharge, discountPct: 0, gstRate: o.serviceChargeGst }] : food;
  const gst = computeGst(o.sellerState, o.placeOfSupply, inputs);
  const gross = round2(rows.reduce((s, l) => s + Math.round(l.qty * l.rate * 100) / 100, 0));
  const summary = new Map<number, { rate: number; taxable: number; cgst: number; sgst: number; igst: number }>();
  inputs.forEach((inp, i) => {
    const g = gst.lines[i]!;
    const cur = summary.get(inp.gstRate) ?? { rate: inp.gstRate, taxable: 0, cgst: 0, sgst: 0, igst: 0 };
    cur.taxable = round2(cur.taxable + g.taxableValue); cur.cgst = round2(cur.cgst + g.cgst);
    cur.sgst = round2(cur.sgst + g.sgst); cur.igst = round2(cur.igst + g.igst);
    summary.set(inp.gstRate, cur);
  });
  return {
    rows, serviceCharge, gst, gross, discounts: fixedP > 0 ? shareP.map((p) => p / 100) : null,
    json: {
      lines: rows.map((l) => ({ itemId: l.itemId, name: l.name, qty: l.qty, rate: l.rate, gstRate: l.gstRate, amount: round2(l.qty * l.rate) })),
      gross, discountPct: fixedP > 0 ? Math.round(fixedP / grossTotalP * 10000) / 100 : o.discountPct, discountAmount: fixedP > 0 ? fixedP / 100 : null,
      discount: round2(gross - pass1.subtotal),
      serviceChargePct: o.serviceChargePct, serviceCharge, serviceChargeGst: o.serviceChargeGst,
      taxable: gst.subtotal, cgst: gst.cgst, sgst: gst.sgst, igst: gst.igst, taxTotal: gst.taxTotal,
      roundOff: gst.roundOff, total: gst.total,
      gstSummary: [...summary.values()].sort((a, b) => a.rate - b.rate),
    },
  };
}

// Loading --------------------------------------------------------------------------------------------

async function loadSettings(tx: Tx, ctx: RequestContext) {
  const row = await tx.selectFrom('restaurant_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst();
  return {
    serviceChargePct: row?.service_charge_pct ?? 0, serviceChargeGst: row?.service_charge_gst ?? 5,
    locationId: row?.location_id ?? null, updatedAt: row?.updated_at ?? null,
  };
}

async function defaultLocation(tx: Tx, ctx: RequestContext, requested?: string) {
  const settings = await loadSettings(tx, ctx);
  const wanted = requested ?? settings.locationId;
  let q = tx.selectFrom('locations').select(['id', 'name', 'state_code', 'is_active'])
    .where('company_id', '=', ctx.companyId).where('is_active', '=', true).orderBy('created_at');
  if (wanted) q = q.where('id', '=', wanted);
  const scope = scopedLocationIds(ctx);
  if (scope) q = q.where('id', 'in', scope);
  const loc = await q.executeTakeFirst();
  if (!loc) throw badRequest(wanted ? 'That location is not available.' : 'Add a location first.', { locationId: 'Not available' });
  return loc;
}

async function nextCounter(tx: Tx, ctx: RequestContext, kind: 'order' | 'kot', day: string): Promise<number> {
  const row = await tx.insertInto('restaurant_counters')
    .values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, kind, day, next_no: 2 })
    .onConflict((oc) => oc.columns(['company_id', 'kind', 'day']).doUpdateSet((eb) => ({ next_no: eb('restaurant_counters.next_no', '+', 1) })))
    .returning('next_no').executeTakeFirstOrThrow();
  return row.next_no - 1;
}

async function lockOrder(tx: Tx, ctx: RequestContext, id: string) {
  const o = await tx.selectFrom('restaurant_orders').selectAll()
    .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!o || !ctx.canAccessLocation(o.location_id)) throw notFound('Order');
  return o;
}

type OrderRow = Awaited<ReturnType<typeof lockOrder>>;

function requireEditable(o: OrderRow) {
  if (o.status === 'bill_printed') throw conflict('The bill is printed. Ask a manager to reopen it to change the order.', 'BILL_PRINTED');
  if (o.status !== 'open') throw conflict(`This order is ${o.status.replace('_', ' ')}.`, 'ORDER_CLOSED');
}

const lineJson = (l: any, kotNo: Map<string, number>) => ({
  id: l.id, itemId: l.item_id, name: l.name, shortName: l.short_name, station: l.station, qty: l.qty, rate: l.rate,
  amount: round2(l.qty * l.rate), note: l.note, state: l.state, kitchenStatus: l.kitchen_status, kotId: l.kot_id,
  kotNo: l.kot_id ? kotNo.get(l.kot_id) ?? null : null, cancelReason: l.cancel_reason, cancelledAt: l.cancelled_at,
});

async function gstRates(tx: Tx, itemIds: string[]) {
  if (!itemIds.length) return new Map<string, number>();
  const rows = await tx.selectFrom('items').select(['id', 'gst_rate']).where('id', 'in', itemIds).execute();
  return new Map(rows.map((r) => [r.id, r.gst_rate]));
}

/** Full order with lines, kitchen tickets and the running bill. */
async function loadOrder(tx: Tx, ctx: RequestContext, id: string) {
  const o = await tx.selectFrom('restaurant_orders as o')
    .leftJoin('restaurant_tables as t', 't.id', 'o.table_id')
    .leftJoin('restaurant_areas as a', 'a.id', 't.area_id')
    .leftJoin('users as c', 'c.id', 'o.captain_id')
    .leftJoin('invoices as i', 'i.id', 'o.invoice_id')
    .leftJoin('locations as l', 'l.id', 'o.location_id')
    .selectAll('o')
    .select(['t.name as table_name', 'a.name as area_name', 'c.name as captain_name', 'i.number as invoice_number', 'l.state_code as state_code'])
    .where('o.id', '=', id).where('o.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!o || !ctx.canAccessLocation(o.location_id)) throw notFound('Order');
  const [lines, kots, settings] = await Promise.all([
    tx.selectFrom('restaurant_order_lines').selectAll().where('order_id', '=', id).orderBy('created_at').orderBy('id').execute(),
    tx.selectFrom('restaurant_kots').selectAll().where('order_id', '=', id).orderBy('kot_no').orderBy('station').execute(),
    loadSettings(tx, ctx),
  ]);
  const rates = await gstRates(tx, [...new Set(lines.map((l) => l.item_id))]);
  const kotNo = new Map(kots.map((k) => [k.id, k.kot_no]));
  const live = lines.filter((l) => l.state !== 'cancelled');
  const scPct = o.status === 'open' ? settings.serviceChargePct : o.service_charge_pct;
  const bill = computeBill(live.map((l) => ({ itemId: l.item_id, name: l.name, qty: l.qty, rate: l.rate, gstRate: rates.get(l.item_id) ?? 0 })), {
    discountPct: o.discount_pct, discountAmount: o.discount_amount, serviceChargePct: scPct, serviceChargeGst: settings.serviceChargeGst,
    sellerState: o.state_code ?? '', placeOfSupply: o.state_code ?? '',
  });
  return {
    id: o.id, number: o.number, orderDate: o.order_date, kind: o.kind, tableId: o.table_id, tableName: o.table_name,
    areaName: o.area_name, covers: o.covers, captain: o.captain_id ? { id: o.captain_id, name: o.captain_name } : null,
    customerPartyId: o.customer_party_id, customerName: o.customer_name, customerPhone: o.customer_phone,
    deliveryAddress: o.delivery_address, notes: o.notes, status: o.status, locationId: o.location_id,
    discountPct: o.discount_pct, discountAmount: o.discount_amount, discountReason: o.discount_reason, serviceChargePct: scPct,
    billPrintedAt: o.bill_printed_at, settledAt: o.settled_at, invoiceId: o.invoice_id, invoiceNumber: o.invoice_number,
    cancelReason: o.cancel_reason, createdAt: o.created_at, updatedAt: o.updated_at,
    lines: lines.map((l) => lineJson(l, kotNo)),
    kots: kots.map((k) => ({ id: k.id, kotNo: k.kot_no, kotDate: k.kot_date, station: k.station, status: k.status, createdAt: k.created_at })),
    bill: bill.json,
  };
}

/** Recomputes a ticket's status from its live lines. */
async function refreshKot(tx: Tx, kotId: string) {
  const lines = await tx.selectFrom('restaurant_order_lines').select(['kitchen_status', 'state']).where('kot_id', '=', kotId).execute();
  const live = lines.filter((l) => l.state !== 'cancelled');
  let status: string;
  if (!live.length) status = 'cancelled';
  else {
    const min = Math.min(...live.map((l) => rank(l.kitchen_status)));
    const max = Math.max(...live.map((l) => rank(l.kitchen_status)));
    status = min >= 3 ? 'served' : min >= 2 ? 'ready' : max >= 1 ? 'preparing' : 'new';
  }
  await tx.updateTable('restaurant_kots').set({ status }).where('id', '=', kotId).execute();
}

async function requireTable(tx: Tx, ctx: RequestContext, tableId: string) {
  const t = await tx.selectFrom('restaurant_tables').selectAll().where('id', '=', tableId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!t) throw badRequest('Table not found.', { tableId: 'Not found' });
  if (!t.is_active) throw badRequest('This table is not in use.', { tableId: 'Inactive' });
  return t;
}

async function assertTableFree(tx: Tx, tableId: string) {
  const busy = await tx.selectFrom('restaurant_orders').select(['id', 'number']).where('table_id', '=', tableId).where('status', 'in', [...ACTIVE]).executeTakeFirst();
  if (busy) throw conflict('This table already has an open order.', 'TABLE_BUSY', { orderId: busy.id, orderNumber: busy.number });
}

async function menuLines(tx: Tx, ctx: RequestContext, inputs: z.infer<typeof lineInput>[]) {
  const ids = [...new Set(inputs.map((i) => i.itemId))];
  const rows = await tx.selectFrom('restaurant_menu as m').innerJoin('items as i', 'i.id', 'm.item_id')
    .select(['i.id', 'i.name', 'i.sale_price', 'i.is_active', 'm.available', 'm.station', 'm.short_name'])
    .where('m.company_id', '=', ctx.companyId).where('m.item_id', 'in', ids).execute();
  const by = new Map(rows.map((r) => [r.id, r]));
  return inputs.map((inp, idx) => {
    const m = by.get(inp.itemId);
    if (!m) throw badRequest(`Item ${idx + 1} is not on the menu.`, { [`items.${idx}.itemId`]: 'Not on the menu' });
    if (!m.is_active || !m.available) throw conflict(`${m.name} is not available today.`, 'ITEM_UNAVAILABLE', { itemId: m.id });
    return { m, qty: inp.qty, note: inp.note ?? null };
  });
}

async function insertLines(tx: Tx, ctx: RequestContext, orderId: string, inputs: z.infer<typeof lineInput>[]) {
  const resolved = await menuLines(tx, ctx, inputs);
  await tx.insertInto('restaurant_order_lines').values(resolved.map((r) => ({
    tenant_id: ctx.tenantId, order_id: orderId, item_id: r.m.id, name: r.m.name, short_name: r.m.short_name, station: r.m.station,
    qty: r.qty, rate: r.m.sale_price, note: r.note,
  }))).execute();
}

/** Walk-in guest party that bills without customer details. */
async function walkInParty(tx: Tx, ctx: RequestContext) {
  const found = await tx.selectFrom('parties').select('id').where('company_id', '=', ctx.companyId)
    .where('name', '=', 'Walk-in guest').where('type', '=', 'customer').executeTakeFirst();
  if (found) return found.id;
  const row = await tx.insertInto('parties').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: 'Walk-in guest', gstin: null, state_code: null,
    phone: null, email: null, address: null, credit_days: 0, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

/** Service charge as a non-stock service item so it posts like any other sale. */
async function serviceChargeItem(tx: Tx, ctx: RequestContext, gstRate: number) {
  const found = await tx.selectFrom('items').select(['id', 'gst_rate']).where('company_id', '=', ctx.companyId).where('sku', '=', 'SERVICE-CHARGE').executeTakeFirst();
  if (found) {
    if (found.gst_rate !== gstRate) await tx.updateTable('items').set({ gst_rate: gstRate }).where('id', '=', found.id).execute();
    return found.id;
  }
  const row = await tx.insertInto('items').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, name: 'Service charge', sku: 'SERVICE-CHARGE', hsn_code: '996331', unit: 'NOS',
    gst_rate: gstRate, sale_price: 0, purchase_price: 0, track_stock: false, reorder_level: 0, barcode: null,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

function dup(err: unknown, message: string): never {
  if ((err as { code?: string }).code === '23505') throw conflict(message, 'CONFLICT');
  throw err;
}

// Routes ---------------------------------------------------------------------------------------------

export async function restaurantRoutes(app: FastifyInstance) {
  // Settings --------------------------------------------------------------------------------------
  app.get('/restaurant/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    return ctx.tx(async (tx) => {
      const s = await loadSettings(tx, ctx);
      const stations = await tx.selectFrom('restaurant_menu').select('station').distinct().where('company_id', '=', ctx.companyId).execute();
      return { ...s, stations: [...new Set(['Main', ...stations.map((x) => x.station)])].sort() };
    });
  });

  app.patch('/restaurant/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      if (b.locationId) await defaultLocation(tx, ctx, b.locationId);
      const set = definedOnly({ service_charge_pct: b.serviceChargePct, service_charge_gst: b.serviceChargeGst, location_id: b.locationId });
      await tx.insertInto('restaurant_settings').values({ company_id: ctx.companyId, tenant_id: ctx.tenantId, ...set })
        .onConflict((oc) => oc.column('company_id').doUpdateSet({ company_id: ctx.companyId, ...set })).execute();
      await writeAudit(tx, auditOf(ctx), 'restaurant_settings', ctx.companyId, 'update', null, b);
      return loadSettings(tx, ctx);
    });
  });

  // Categories ------------------------------------------------------------------------------------
  const categoryJson = (c: any) => ({ id: c.id, name: c.name, sortOrder: c.sort_order, isActive: c.is_active, updatedAt: c.updated_at });

  app.get('/restaurant/categories', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('restaurant_categories').selectAll().where('company_id', '=', ctx.companyId)
        .orderBy('sort_order').orderBy('name').execute();
      return { data: rows.map(categoryJson), total: rows.length };
    });
  });

  app.post('/restaurant/categories', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const b = parse(categoryBody, req.body);
    const row = await ctx.tx(async (tx) => {
      try {
        return await tx.insertInto('restaurant_categories').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, sort_order: b.sortOrder ?? 0, is_active: b.isActive ?? true,
        }).returningAll().executeTakeFirstOrThrow();
      } catch (e) { return dup(e, 'A category with this name already exists.'); }
    });
    return reply.status(201).send(categoryJson(row));
  });

  app.patch<{ Params: { id: string } }>('/restaurant/categories/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(categoryPatch, req.body);
    return ctx.tx(async (tx) => {
      const set = definedOnly({ name: b.name, sort_order: b.sortOrder, is_active: b.isActive });
      try {
        const row = Object.keys(set).length
          ? await tx.updateTable('restaurant_categories').set(set).where('id', '=', id).where('company_id', '=', ctx.companyId).returningAll().executeTakeFirst()
          : await tx.selectFrom('restaurant_categories').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!row) throw notFound('Category');
        return categoryJson(row);
      } catch (e) { return dup(e, 'A category with this name already exists.'); }
    });
  });

  app.delete<{ Params: { id: string } }>('/restaurant/categories/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const r = await tx.deleteFrom('restaurant_categories').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!r.numDeletedRows) throw notFound('Category');
    });
    return reply.status(204).send();
  });

  // Menu ------------------------------------------------------------------------------------------
  const menuSelect = (tx: Tx) => tx.selectFrom('restaurant_menu as m').innerJoin('items as i', 'i.id', 'm.item_id')
    .leftJoin('restaurant_categories as c', 'c.id', 'm.category_id')
    .select(['m.item_id', 'm.category_id', 'm.diet', 'm.available', 'm.station', 'm.short_name', 'm.updated_at', 'i.name', 'i.sale_price',
      'i.gst_rate', 'i.unit', 'i.is_active', 'c.name as category_name', 'c.sort_order as category_sort']);
  const menuJson = (m: any) => ({
    itemId: m.item_id, name: m.name, shortName: m.short_name, price: m.sale_price, gstRate: m.gst_rate, unit: m.unit,
    categoryId: m.category_id, categoryName: m.category_name, diet: m.diet, available: m.available && m.is_active,
    availableToday: m.available, isActive: m.is_active, station: m.station, updatedAt: m.updated_at,
  });

  app.get('/restaurant/menu', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    const q = parse(z.object({
      q: z.string().trim().max(100).optional(), categoryId: z.uuid().optional(), available: z.enum(['true', 'false']).optional(),
      station: z.string().trim().max(40).optional(),
    }), req.query);
    return ctx.tx(async (tx) => {
      let base = menuSelect(tx).where('m.company_id', '=', ctx.companyId);
      if (q.categoryId) base = base.where('m.category_id', '=', q.categoryId);
      if (q.station) base = base.where('m.station', '=', q.station);
      if (q.available === 'true') base = base.where('m.available', '=', true).where('i.is_active', '=', true);
      if (q.available === 'false') base = base.where((eb) => eb.or([eb('m.available', '=', false), eb('i.is_active', '=', false)]));
      if (q.q) base = base.where((eb) => eb.or([eb('i.name', 'ilike', likeTerm(q.q!)), eb('m.short_name', 'ilike', likeTerm(q.q!))]));
      const rows = await base.orderBy('c.sort_order').orderBy('c.name').orderBy('i.name').execute();
      return { data: rows.map(menuJson), total: rows.length };
    });
  });

  app.post('/restaurant/menu', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const b = parse(menuCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      let itemId = b.itemId;
      if (b.newItem) {
        const it = await tx.insertInto('items').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.newItem.name, sku: null, barcode: null,
          hsn_code: b.newItem.hsnCode ?? '996331', unit: b.newItem.unit, gst_rate: b.newItem.gstRate, sale_price: b.newItem.salePrice,
          purchase_price: 0, track_stock: false, reorder_level: 0,
        }).returning('id').executeTakeFirstOrThrow();
        itemId = it.id;
      } else {
        const it = await tx.selectFrom('items').select('id').where('id', '=', itemId!).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!it) throw badRequest('Item not found.', { itemId: 'Not found' });
      }
      if (b.categoryId) {
        const c = await tx.selectFrom('restaurant_categories').select('id').where('id', '=', b.categoryId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!c) throw badRequest('Category not found.', { categoryId: 'Not found' });
      }
      try {
        await tx.insertInto('restaurant_menu').values({
          item_id: itemId!, tenant_id: ctx.tenantId, company_id: ctx.companyId, category_id: b.categoryId ?? null, diet: b.diet ?? 'veg',
          available: b.available ?? true, station: b.station ?? 'Main', short_name: b.shortName ?? null,
        }).execute();
      } catch (e) { dup(e, 'This item is already on the menu.'); }
      await writeAudit(tx, auditOf(ctx), 'restaurant_menu', itemId!, 'create', null, { itemId });
      return menuJson(await menuSelect(tx).where('m.item_id', '=', itemId!).executeTakeFirstOrThrow());
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/restaurant/menu/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(menuPatch, req.body);
    // Captains and the kitchen may only flip today's availability.
    const onlyAvailable = Object.entries(b).every(([k, v]) => v === undefined || k === 'available' || k === 'expectedUpdatedAt');
    if (!ctx.can('restaurant.manage') && !onlyAvailable) throw forbidden();
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('restaurant_menu').select(['item_id', 'updated_at']).where('item_id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!cur) throw notFound('Menu entry');
      assertFresh(cur.updated_at, b.expectedUpdatedAt, 'menu entry');
      if (b.categoryId) {
        const c = await tx.selectFrom('restaurant_categories').select('id').where('id', '=', b.categoryId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!c) throw badRequest('Category not found.', { categoryId: 'Not found' });
      }
      const set = definedOnly({ category_id: b.categoryId, diet: b.diet, available: b.available, station: b.station, short_name: b.shortName });
      if (Object.keys(set).length) await tx.updateTable('restaurant_menu').set(set).where('item_id', '=', id).execute();
      return menuJson(await menuSelect(tx).where('m.item_id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.delete<{ Params: { id: string } }>('/restaurant/menu/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const r = await tx.deleteFrom('restaurant_menu').where('item_id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!r.numDeletedRows) throw notFound('Menu entry');
    });
    return reply.status(204).send();
  });

  // Floor setup -----------------------------------------------------------------------------------
  const areaJson = (a: any) => ({ id: a.id, name: a.name, sortOrder: a.sort_order, isActive: a.is_active, updatedAt: a.updated_at });
  const tableJson = (t: any) => ({ id: t.id, areaId: t.area_id, name: t.name, seats: t.seats, sortOrder: t.sort_order, isActive: t.is_active, updatedAt: t.updated_at });

  app.post('/restaurant/areas', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const b = parse(areaBody, req.body);
    const row = await ctx.tx(async (tx) => {
      try {
        return await tx.insertInto('restaurant_areas').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, sort_order: b.sortOrder ?? 0, is_active: b.isActive ?? true,
        }).returningAll().executeTakeFirstOrThrow();
      } catch (e) { return dup(e, 'An area with this name already exists.'); }
    });
    return reply.status(201).send(areaJson(row));
  });

  app.patch<{ Params: { id: string } }>('/restaurant/areas/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(areaBody.partial(), req.body);
    return ctx.tx(async (tx) => {
      const set = definedOnly({ name: b.name, sort_order: b.sortOrder, is_active: b.isActive });
      try {
        const row = Object.keys(set).length
          ? await tx.updateTable('restaurant_areas').set(set).where('id', '=', id).where('company_id', '=', ctx.companyId).returningAll().executeTakeFirst()
          : await tx.selectFrom('restaurant_areas').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!row) throw notFound('Area');
        return areaJson(row);
      } catch (e) { return dup(e, 'An area with this name already exists.'); }
    });
  });

  app.delete<{ Params: { id: string } }>('/restaurant/areas/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const t = await tx.selectFrom('restaurant_tables').select('id').where('area_id', '=', id).executeTakeFirst();
      if (t) throw conflict('Move or remove the tables in this area first.', 'HAS_TABLES');
      const r = await tx.deleteFrom('restaurant_areas').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!r.numDeletedRows) throw notFound('Area');
    });
    return reply.status(204).send();
  });

  async function checkArea(tx: Tx, ctx: RequestContext, areaId: string) {
    const a = await tx.selectFrom('restaurant_areas').select('id').where('id', '=', areaId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!a) throw badRequest('Area not found.', { areaId: 'Not found' });
  }

  app.post('/restaurant/tables', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const b = parse(tableBody, req.body);
    const row = await ctx.tx(async (tx) => {
      await checkArea(tx, ctx, b.areaId);
      try {
        return await tx.insertInto('restaurant_tables').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, area_id: b.areaId, name: b.name, seats: b.seats,
          sort_order: b.sortOrder ?? 0, is_active: b.isActive ?? true,
        }).returningAll().executeTakeFirstOrThrow();
      } catch (e) { return dup(e, 'A table with this name already exists.'); }
    });
    return reply.status(201).send(tableJson(row));
  });

  app.patch<{ Params: { id: string } }>('/restaurant/tables/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(tablePatch, req.body);
    return ctx.tx(async (tx) => {
      if (b.areaId) await checkArea(tx, ctx, b.areaId);
      if (b.isActive === false) await assertTableFree(tx, id);
      const set = definedOnly({ area_id: b.areaId, name: b.name, seats: b.seats, sort_order: b.sortOrder, is_active: b.isActive });
      try {
        const row = Object.keys(set).length
          ? await tx.updateTable('restaurant_tables').set(set).where('id', '=', id).where('company_id', '=', ctx.companyId).returningAll().executeTakeFirst()
          : await tx.selectFrom('restaurant_tables').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!row) throw notFound('Table');
        return tableJson(row);
      } catch (e) { return dup(e, 'A table with this name already exists.'); }
    });
  });

  app.delete<{ Params: { id: string } }>('/restaurant/tables/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const t = await tx.selectFrom('restaurant_tables').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!t) throw notFound('Table');
      await assertTableFree(tx, id);
      const used = await tx.selectFrom('restaurant_orders').select('id').where('table_id', '=', id).executeTakeFirst();
      if (used) await tx.updateTable('restaurant_tables').set({ is_active: false }).where('id', '=', id).execute();
      else await tx.deleteFrom('restaurant_tables').where('id', '=', id).execute();
    });
    return reply.status(204).send();
  });

  /** Areas with tables; each table's status comes from its open order. */
  app.get('/restaurant/floor', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    return ctx.tx(async (tx) => {
      const [areas, tables, settings] = await Promise.all([
        tx.selectFrom('restaurant_areas').selectAll().where('company_id', '=', ctx.companyId).orderBy('sort_order').orderBy('name').execute(),
        tx.selectFrom('restaurant_tables').selectAll().where('company_id', '=', ctx.companyId).orderBy('sort_order').orderBy('name').execute(),
        loadSettings(tx, ctx),
      ]);
      const orders = await tx.selectFrom('restaurant_orders as o')
        .leftJoin('users as u', 'u.id', 'o.captain_id').leftJoin('locations as l', 'l.id', 'o.location_id')
        .select(['o.id', 'o.number', 'o.table_id', 'o.covers', 'o.status', 'o.discount_pct', 'o.service_charge_pct', 'o.created_at',
          'u.name as captain_name', 'l.state_code'])
        .where('o.company_id', '=', ctx.companyId).where('o.status', 'in', [...ACTIVE]).where('o.table_id', 'is not', null).execute();
      const ids = orders.map((o) => o.id);
      const lines = ids.length ? await tx.selectFrom('restaurant_order_lines').selectAll().where('order_id', 'in', ids).where('state', '!=', 'cancelled').execute() : [];
      const rates = await gstRates(tx, [...new Set(lines.map((l) => l.item_id))]);
      const byTable = new Map(orders.map((o) => {
        const ls = lines.filter((l) => l.order_id === o.id);
        const bill = computeBill(ls.map((l) => ({ itemId: l.item_id, name: l.name, qty: l.qty, rate: l.rate, gstRate: rates.get(l.item_id) ?? 0 })), {
          discountPct: o.discount_pct, serviceChargePct: o.status === 'open' ? settings.serviceChargePct : o.service_charge_pct,
          serviceChargeGst: settings.serviceChargeGst, sellerState: o.state_code ?? '', placeOfSupply: o.state_code ?? '',
        });
        return [o.table_id!, {
          id: o.id, number: o.number, covers: o.covers, captainName: o.captain_name, openedAt: o.created_at, amount: bill.json.total,
          unsentLines: ls.filter((l) => l.state === 'draft').length, readyLines: ls.filter((l) => l.state === 'sent' && l.kitchen_status === 'ready').length,
        }];
      }));
      const statusOf = (tableId: string) => {
        const o = orders.find((x) => x.table_id === tableId);
        return !o ? 'free' : o.status === 'bill_printed' ? 'bill_printed' : 'occupied';
      };
      return {
        areas: areas.map((a) => ({
          ...areaJson(a),
          tables: tables.filter((t) => t.area_id === a.id).map((t) => ({ ...tableJson(t), status: statusOf(t.id), order: byTable.get(t.id) ?? null })),
        })),
      };
    });
  });

  // Orders ----------------------------------------------------------------------------------------
  app.get('/restaurant/orders', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    const q = parse(orderListQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('restaurant_orders as o').leftJoin('restaurant_tables as t', 't.id', 'o.table_id')
        .leftJoin('invoices as i', 'i.id', 'o.invoice_id')
        .select(['o.id', 'o.number', 'o.order_date', 'o.kind', 'o.status', 'o.customer_name', 'o.customer_phone', 'o.covers',
          'o.created_at', 'o.settled_at', 't.name as table_name', 'i.total as invoice_total', 'i.number as invoice_number'])
        .where('o.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('o.location_id', 'in', scope);
      if (q.kind) base = base.where('o.kind', '=', q.kind);
      if (q.status === 'active') base = base.where('o.status', 'in', [...ACTIVE]);
      else if (q.status) base = base.where('o.status', 'in', q.status.split(',').filter(Boolean));
      if (q.date) base = base.where('o.order_date', '=', q.date);
      if (q.q) base = base.where((eb) => eb.or([eb('o.number', 'ilike', likeTerm(q.q!)), eb('o.customer_name', 'ilike', likeTerm(q.q!)), eb('o.customer_phone', 'ilike', likeTerm(q.q!))]));
      const total = (await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow()).n;
      const rows = await base.orderBy('o.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      const ids = rows.map((r) => r.id);
      const lines = ids.length ? await tx.selectFrom('restaurant_order_lines').select(['order_id', 'qty', 'rate', 'state', 'kitchen_status']).where('order_id', 'in', ids).execute() : [];
      return {
        total,
        data: rows.map((r) => {
          const ls = lines.filter((l) => l.order_id === r.id && l.state !== 'cancelled');
          return {
            id: r.id, number: r.number, orderDate: r.order_date, kind: r.kind, status: r.status, tableName: r.table_name,
            customerName: r.customer_name, customerPhone: r.customer_phone, covers: r.covers, createdAt: r.created_at, settledAt: r.settled_at,
            itemCount: ls.length, amount: r.invoice_total ?? round2(ls.reduce((s, l) => s + l.qty * l.rate, 0)),
            invoiceNumber: r.invoice_number,
            readyLines: ls.filter((l) => l.state === 'sent' && l.kitchen_status === 'ready').length,
            unsentLines: ls.filter((l) => l.state === 'draft').length,
          };
        }),
      };
    });
  });

  app.get<{ Params: { id: string } }>('/restaurant/orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadOrder(tx, ctx, id));
  });

  app.post('/restaurant/orders', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const b = parse(orderCreate, req.body);
    if (b.kind === 'dine_in' && !b.tableId) throw badRequest('Choose a table.', { tableId: 'Required' });
    if (b.kind !== 'dine_in' && b.tableId) throw badRequest('Takeaway and delivery orders have no table.', { tableId: 'Not for this order type' });
    if (b.kind === 'delivery' && !b.customerPhone) throw badRequest('Delivery needs a phone number.', { customerPhone: 'Required' });
    const out = await ctx.tx(async (tx) => {
      const loc = await defaultLocation(tx, ctx, b.locationId);
      if (b.tableId) {
        await requireTable(tx, ctx, b.tableId);
        // Serialise two people opening the same table.
        await tx.selectFrom('restaurant_tables').select('id').where('id', '=', b.tableId).forUpdate().execute();
        await assertTableFree(tx, b.tableId);
      }
      if (b.customerPartyId) {
        const p = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', b.customerPartyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p || p.type === 'vendor') throw badRequest('Customer not found.', { customerPartyId: 'Not found' });
      }
      const captainId = b.captainId ?? ctx.userId;
      const day = todayIst();
      const n = await nextCounter(tx, ctx, 'order', day);
      const number = `O${day.slice(2).replace(/-/g, '')}-${String(n).padStart(3, '0')}`;
      const row = await tx.insertInto('restaurant_orders').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: loc.id, number, order_date: day, kind: b.kind,
        table_id: b.tableId ?? null, covers: b.covers ?? null, captain_id: captainId, customer_party_id: b.customerPartyId ?? null,
        customer_name: b.customerName ?? null, customer_phone: b.customerPhone ?? null, delivery_address: b.deliveryAddress ?? null,
        notes: b.notes ?? null, discount_reason: null, bill_printed_at: null, settled_at: null, invoice_id: null, cancel_reason: null,
        created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      if (b.lines?.length) await insertLines(tx, ctx, row.id, b.lines);
      await writeAudit(tx, auditOf(ctx), 'restaurant_order', row.id, 'create', null, { number, kind: b.kind, tableId: b.tableId ?? null });
      return loadOrder(tx, ctx, row.id);
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/restaurant/orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(orderPatch, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      assertFresh(o.updated_at, b.expectedUpdatedAt, 'order');
      requireEditable(o);
      const set = definedOnly({
        covers: b.covers, captain_id: b.captainId, customer_name: b.customerName, customer_phone: b.customerPhone,
        delivery_address: b.deliveryAddress, notes: b.notes,
      });
      if (Object.keys(set).length) await tx.updateTable('restaurant_orders').set(set).where('id', '=', id).execute();
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/restaurant/orders/:id/lines', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(addLines, req.body);
    const out = await ctx.tx(async (tx) => {
      requireEditable(await lockOrder(tx, ctx, id));
      await insertLines(tx, ctx, id, b.items);
      return loadOrder(tx, ctx, id);
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string; lineId: string } }>('/restaurant/orders/:id/lines/:lineId', async (req) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    const lineId = parse(z.uuid(), req.params.lineId);
    const b = parse(linePatch, req.body);
    return ctx.tx(async (tx) => {
      requireEditable(await lockOrder(tx, ctx, id));
      const line = await tx.selectFrom('restaurant_order_lines').selectAll().where('id', '=', lineId).where('order_id', '=', id).executeTakeFirst();
      if (!line) throw notFound('Line');
      if (line.state !== 'draft') throw conflict('This line is already with the kitchen. Add a new line or cancel it with a reason.', 'LINE_SENT');
      const set = definedOnly({ qty: b.qty, note: b.note });
      if (Object.keys(set).length) await tx.updateTable('restaurant_order_lines').set(set).where('id', '=', lineId).execute();
      return loadOrder(tx, ctx, id);
    });
  });

  /** Unsent lines are simply removed. Sent lines need a manager and a reason and leave an audit row. */
  app.post<{ Params: { id: string; lineId: string } }>('/restaurant/orders/:id/lines/:lineId/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    const lineId = parse(z.uuid(), req.params.lineId);
    const b = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      requireEditable(await lockOrder(tx, ctx, id));
      const line = await tx.selectFrom('restaurant_order_lines').selectAll().where('id', '=', lineId).where('order_id', '=', id).forUpdate().executeTakeFirst();
      if (!line || line.state === 'cancelled') throw notFound('Line');
      if (line.state === 'draft') {
        await tx.deleteFrom('restaurant_order_lines').where('id', '=', lineId).execute();
        return loadOrder(tx, ctx, id);
      }
      if (!ctx.can('restaurant.manage')) throw forbidden('A manager must cancel items already sent to the kitchen.');
      if (!b.reason || b.reason.length < 3) throw badRequest('Give a reason.', { reason: 'Give a reason' });
      await tx.updateTable('restaurant_order_lines').set({
        state: 'cancelled', cancel_reason: b.reason, cancelled_by: ctx.userId, cancelled_at: new Date(),
      }).where('id', '=', lineId).execute();
      if (line.kot_id) await refreshKot(tx, line.kot_id);
      await writeAudit(tx, auditOf(ctx), 'restaurant_order_line', lineId, 'cancel', { name: line.name, qty: line.qty, kitchenStatus: line.kitchen_status },
        { reason: b.reason, orderId: id });
      return loadOrder(tx, ctx, id);
    });
  });

  /** One ticket per station for the lines not yet sent. Sending twice sends nothing the second time. */
  app.post<{ Params: { id: string } }>('/restaurant/orders/:id/send-kot', async (req) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      requireEditable(o);
      const drafts = await tx.selectFrom('restaurant_order_lines').selectAll().where('order_id', '=', id).where('state', '=', 'draft').orderBy('created_at').execute();
      const created: string[] = [];
      if (drafts.length) {
        const kotDate = todayIst();
        const kotNo = await nextCounter(tx, ctx, 'kot', kotDate);
        const stations = [...new Set(drafts.map((l) => l.station))];
        for (const station of stations) {
          const kot = await tx.insertInto('restaurant_kots').values({
            tenant_id: ctx.tenantId, company_id: ctx.companyId, order_id: id, kot_date: kotDate, kot_no: kotNo, station, created_by: ctx.userId,
          }).returning('id').executeTakeFirstOrThrow();
          await tx.updateTable('restaurant_order_lines').set({ state: 'sent', kitchen_status: 'new', kot_id: kot.id })
            .where('id', 'in', drafts.filter((l) => l.station === station).map((l) => l.id)).execute();
          created.push(kot.id);
        }
        await writeAudit(tx, auditOf(ctx), 'restaurant_order', id, 'send_kot', null, { kotNo, stations, lines: drafts.length });
      }
      const order = await loadOrder(tx, ctx, id);
      return { newKotIds: created, order };
    });
  });

  app.post<{ Params: { id: string } }>('/restaurant/orders/:id/move', async (req) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(moveBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      requireEditable(o);
      if (o.kind !== 'dine_in') throw badRequest('Only dine-in orders have a table.');
      if (o.table_id === b.tableId) return loadOrder(tx, ctx, id);
      await requireTable(tx, ctx, b.tableId);
      await tx.selectFrom('restaurant_tables').select('id').where('id', '=', b.tableId).forUpdate().execute();
      await assertTableFree(tx, b.tableId);
      await tx.updateTable('restaurant_orders').set({ table_id: b.tableId }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'restaurant_order', id, 'move', { tableId: o.table_id }, { tableId: b.tableId });
      return loadOrder(tx, ctx, id);
    });
  });

  /** Moves the other order's lines and tickets into this one and closes the other order. */
  app.post<{ Params: { id: string } }>('/restaurant/orders/:id/merge', async (req) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(mergeBody, req.body);
    if (b.fromOrderId === id) throw badRequest('Choose a different order.', { fromOrderId: 'Same order' });
    return ctx.tx(async (tx) => {
      const [first, second] = [id, b.fromOrderId].sort();
      await lockOrder(tx, ctx, first!);
      await lockOrder(tx, ctx, second!);
      const target = await lockOrder(tx, ctx, id);
      const source = await lockOrder(tx, ctx, b.fromOrderId);
      requireEditable(target);
      requireEditable(source);
      await tx.updateTable('restaurant_order_lines').set({ order_id: id }).where('order_id', '=', source.id).execute();
      await tx.updateTable('restaurant_kots').set({ order_id: id }).where('order_id', '=', source.id).execute();
      await tx.updateTable('restaurant_orders').set({
        status: 'cancelled', cancel_reason: `Merged into ${target.number}`,
      }).where('id', '=', source.id).execute();
      await tx.updateTable('restaurant_orders').set({
        covers: (target.covers ?? 0) + (source.covers ?? 0) || null,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'restaurant_order', id, 'merge', null, { fromOrderId: source.id, fromNumber: source.number });
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/restaurant/orders/:id/print-bill', async (req) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(printBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      if (o.status === 'bill_printed') return loadOrder(tx, ctx, id);
      requireEditable(o);
      if (b.discountAmount && b.discountPct) throw badRequest('Give a discount as a percent or an amount, not both.');
      let discountPct = b.discountPct ?? 0;
      if (b.discountAmount) {
        // The amount is kept as typed; the percent is only for display.
        const gross = (await loadOrder(tx, ctx, id)).bill.gross;
        if (b.discountAmount > gross) throw badRequest('The discount is more than the bill.', { discountAmount: 'Too large' });
        discountPct = Math.round(b.discountAmount / gross * 10000) / 100;
      }
      if ((discountPct > 0 || b.waiveServiceCharge) && !ctx.can('restaurant.manage')) {
        throw forbidden('A manager must approve a discount or waive the service charge.');
      }
      if (discountPct > 0 && !b.discountReason) throw badRequest('Give a reason for the discount.', { discountReason: 'Required' });
      const live = await tx.selectFrom('restaurant_order_lines').select(['id', 'state']).where('order_id', '=', id).where('state', '!=', 'cancelled').execute();
      if (!live.length) throw badRequest('Add items before printing the bill.');
      const settings = await loadSettings(tx, ctx);
      await tx.updateTable('restaurant_orders').set({
        status: 'bill_printed', bill_printed_at: new Date(), discount_pct: discountPct, discount_amount: b.discountAmount ?? null, discount_reason: discountPct > 0 ? b.discountReason ?? null : null,
        service_charge_pct: b.waiveServiceCharge ? 0 : settings.serviceChargePct,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'restaurant_order', id, 'print_bill', null,
        { discountPct, discountAmount: b.discountAmount ?? null, discountReason: b.discountReason ?? null, waivedServiceCharge: !!b.waiveServiceCharge });
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/restaurant/orders/:id/reopen', async (req) => {
    const ctx = req.ctx;
    ctx.require('restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      if (o.status !== 'bill_printed') throw conflict('Only a printed bill can be reopened.', 'NOT_BILLED');
      await tx.updateTable('restaurant_orders').set({ status: 'open', bill_printed_at: null, discount_pct: 0, discount_amount: null, discount_reason: null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'restaurant_order', id, 'reopen', { status: 'bill_printed' }, { status: 'open' });
      return loadOrder(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/restaurant/orders/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require(...ORDER_ANY);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      if (o.status !== 'open' && o.status !== 'bill_printed') throw conflict(`This order is ${o.status}.`, 'ORDER_CLOSED');
      const sent = await tx.selectFrom('restaurant_order_lines').select('id').where('order_id', '=', id).where('state', '=', 'sent').executeTakeFirst();
      if (sent || o.status === 'bill_printed') {
        if (!ctx.can('restaurant.manage')) throw forbidden('A manager must cancel an order that has gone to the kitchen.');
      }
      if (!b.reason || b.reason.length < 3) throw badRequest('Give a reason.', { reason: 'Give a reason' });
      await tx.deleteFrom('restaurant_order_lines').where('order_id', '=', id).where('state', '=', 'draft').execute();
      await tx.updateTable('restaurant_order_lines').set({ state: 'cancelled', cancel_reason: b.reason, cancelled_by: ctx.userId, cancelled_at: new Date() })
        .where('order_id', '=', id).where('state', '=', 'sent').execute();
      await tx.updateTable('restaurant_kots').set({ status: 'cancelled' }).where('order_id', '=', id).execute();
      await tx.updateTable('restaurant_orders').set({ status: 'cancelled', cancel_reason: b.reason }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'restaurant_order', id, 'cancel', { status: o.status }, { reason: b.reason });
      return loadOrder(tx, ctx, id);
    });
  });

  /** Tax invoice and receipts in one transaction; the table becomes free. */
  app.post<{ Params: { id: string } }>('/restaurant/orders/:id/settle', async (req) => {
    const ctx = req.ctx;
    ctx.require('restaurant.settle', 'restaurant.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(settleBody, req.body);
    return ctx.tx(async (tx) => {
      const o = await lockOrder(tx, ctx, id);
      if (o.status === 'settled') throw conflict('This order is already settled.', 'ALREADY_SETTLED');
      if (o.status === 'cancelled') throw conflict('This order is cancelled.', 'ORDER_CLOSED');
      const rows = await tx.selectFrom('restaurant_order_lines').selectAll().where('order_id', '=', id).where('state', '!=', 'cancelled').execute();
      if (!rows.length) throw badRequest('There is nothing to bill.');
      if (rows.some((l) => l.state === 'draft')) throw conflict('Send the new items to the kitchen before settling.', 'UNSENT_LINES');

      const settings = await loadSettings(tx, ctx);
      const loc = await tx.selectFrom('locations').select(['id', 'state_code']).where('id', '=', o.location_id).executeTakeFirstOrThrow();
      const partyId = b.partyId ?? o.customer_party_id ?? await walkInParty(tx, ctx);
      const party = await tx.selectFrom('parties').select(['id', 'state_code', 'type']).where('id', '=', partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party || party.type === 'vendor') throw badRequest('Customer not found.', { partyId: 'Not found' });
      const rates = await gstRates(tx, [...new Set(rows.map((l) => l.item_id))]);
      const scPct = o.status === 'open' ? settings.serviceChargePct : o.service_charge_pct;
      const bill = computeBill(rows.map((l) => ({ itemId: l.item_id, name: l.name, qty: l.qty, rate: l.rate, gstRate: rates.get(l.item_id) ?? 0 })), {
        discountPct: o.discount_pct, discountAmount: o.discount_amount, serviceChargePct: scPct, serviceChargeGst: settings.serviceChargeGst,
        sellerState: loc.state_code, placeOfSupply: party.state_code ?? loc.state_code,
      });
      if (b.chargeToRoom) {
        // The bill moves to the guest's hotel folio and is taxed there on the hotel invoice at check-out; no restaurant invoice is made.
        if (b.payments.length) throw badRequest('A bill charged to a room takes no payment now.', { payments: 'Not with charge to room' });
        const posted = await postFolioCharge(ctx, tx, {
          reservationId: b.chargeToRoom.reservationId, roomNumber: b.chargeToRoom.roomNumber,
          description: `Restaurant ${o.number}`, rate: bill.gst.subtotal, chargeType: 'food', source: 'restaurant', sourceRef: id,
        });
        await tx.updateTable('restaurant_orders').set({
          status: 'settled', settled_at: new Date(), bill_printed_at: o.bill_printed_at ?? new Date(), service_charge_pct: scPct,
        }).where('id', '=', id).execute();
        await tx.updateTable('restaurant_kots').set({ status: 'served' }).where('order_id', '=', id).where('status', '!=', 'cancelled').execute();
        await tx.updateTable('restaurant_order_lines').set({ kitchen_status: 'served' }).where('order_id', '=', id).where('state', '=', 'sent').execute();
        await writeAudit(tx, auditOf(ctx), 'restaurant_order', id, 'settle', null, { chargedToReservationId: posted.reservationId, folioLineId: posted.lineId, amount: bill.gst.subtotal });
        return { order: await loadOrder(tx, ctx, id), invoice: null, receipts: [], folio: { reservationId: posted.reservationId, lineId: posted.lineId, amount: bill.gst.subtotal } };
      }
      const paid = round2(b.payments.reduce((s, p) => s + p.amount, 0));
      if (Math.abs(paid - bill.gst.total) > 0.005) {
        throw badRequest(`Payments add up to ${paid} but the bill is ${bill.gst.total}.`, { payments: `Bill is ${bill.gst.total}` });
      }

      const invLines: { itemId: string; qty: number; rate: number; discountPct?: number; discountAmount?: number; description: string }[] = bill.rows.map((l, i) => (
        bill.discounts ? { itemId: l.itemId, qty: l.qty, rate: l.rate, discountAmount: bill.discounts[i]!, description: l.name }
          : { itemId: l.itemId, qty: l.qty, rate: l.rate, discountPct: o.discount_pct, description: l.name }));
      if (bill.serviceCharge > 0) {
        invLines.push({ itemId: await serviceChargeItem(tx, ctx, settings.serviceChargeGst), qty: 1, rate: bill.serviceCharge, discountPct: 0, description: 'Service charge' });
      }
      const invoice = await createInvoice(ctx, tx, {
        locationId: loc.id, partyId, invoiceDate: todayIst(), notes: `Restaurant order ${o.number}`, lines: invLines,
      } as any);
      if (invoice.total !== bill.gst.total) throw conflict('The invoice total differs from the bill. Nothing was saved.', 'TOTAL_MISMATCH');

      const acc = await systemAccounts(tx, ctx);
      const receipts: { id: string; number: string; mode: string; amount: number }[] = [];
      for (const p of b.payments) {
        const r = await createPayment(ctx, tx, {
          kind: 'receipt', partyId, date: todayIst(), accountId: p.mode === 'cash' ? acc.cash : acc.bank, mode: p.mode,
          reference: p.reference, amount: p.amount, notes: `Restaurant order ${o.number}`, allocations: [{ docId: invoice.id, amount: p.amount }],
        } as any);
        receipts.push({ id: r.id, number: r.number, mode: p.mode, amount: p.amount });
      }
      await tx.updateTable('restaurant_orders').set({
        status: 'settled', settled_at: new Date(), invoice_id: invoice.id, customer_party_id: partyId,
        bill_printed_at: o.bill_printed_at ?? new Date(), service_charge_pct: scPct,
      }).where('id', '=', id).execute();
      await tx.updateTable('restaurant_kots').set({ status: 'served' }).where('order_id', '=', id).where('status', '!=', 'cancelled').execute();
      await tx.updateTable('restaurant_order_lines').set({ kitchen_status: 'served' }).where('order_id', '=', id).where('state', '=', 'sent').execute();
      await writeAudit(tx, auditOf(ctx), 'restaurant_order', id, 'settle', null, { invoiceId: invoice.id, invoiceNumber: invoice.number, total: invoice.total, receipts });
      return { order: await loadOrder(tx, ctx, id), invoice: { id: invoice.id, number: invoice.number, total: invoice.total }, receipts };
    });
  });

  // Kitchen ---------------------------------------------------------------------------------------
  async function kotList(tx: Tx, ctx: RequestContext, q: z.infer<typeof kotQuery>, onlyId?: string) {
    let base = tx.selectFrom('restaurant_kots as k')
      .innerJoin('restaurant_orders as o', 'o.id', 'k.order_id')
      .leftJoin('restaurant_tables as t', 't.id', 'o.table_id').leftJoin('restaurant_areas as a', 'a.id', 't.area_id')
      .leftJoin('users as c', 'c.id', 'o.captain_id')
      .select(['k.id', 'k.kot_no', 'k.kot_date', 'k.station', 'k.status', 'k.created_at', 'k.updated_at', 'o.id as order_id', 'o.number as order_number',
        'o.kind', 'o.covers', 'o.customer_name', 'o.location_id', 't.name as table_name', 'a.name as area_name', 'c.name as captain_name'])
      .where('k.company_id', '=', ctx.companyId);
    const scope = scopedLocationIds(ctx);
    if (scope) base = base.where('o.location_id', 'in', scope);
    if (onlyId) base = base.where('k.id', '=', onlyId);
    else {
      const statuses = q.status ? q.status.split(',').filter(Boolean) : ['new', 'preparing', 'ready'];
      base = base.where('k.status', 'in', statuses);
      if (q.station) base = base.where('k.station', '=', q.station);
      if (q.orderId) base = base.where('k.order_id', '=', q.orderId);
      // A finished or cancelled order's tickets never reach the live board.
      if (!q.orderId && !q.status) base = base.where('o.status', 'in', [...ACTIVE]);
    }
    const kots = await base.orderBy('k.created_at').limit(q.limit).execute();
    const ids = kots.map((k) => k.id);
    const lines = ids.length ? await tx.selectFrom('restaurant_order_lines').selectAll().where('kot_id', 'in', ids).orderBy('created_at').orderBy('id').execute() : [];
    return kots.map((k) => ({
      id: k.id, kotNo: k.kot_no, kotDate: k.kot_date, station: k.station, status: k.status, createdAt: k.created_at, updatedAt: k.updated_at,
      orderId: k.order_id, orderNumber: k.order_number, kind: k.kind, covers: k.covers, tableName: k.table_name, areaName: k.area_name,
      captainName: k.captain_name, customerName: k.customer_name,
      lines: lines.filter((l) => l.kot_id === k.id).map((l) => ({
        id: l.id, name: l.short_name ?? l.name, fullName: l.name, qty: l.qty, note: l.note, state: l.state, kitchenStatus: l.kitchen_status,
        cancelReason: l.cancel_reason,
      })),
    }));
  }

  app.get('/restaurant/kots', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    const q = parse(kotQuery, req.query);
    return ctx.tx(async (tx) => {
      const data = await kotList(tx, ctx, q);
      return { data, total: data.length };
    });
  });

  app.get<{ Params: { id: string } }>('/restaurant/kots/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require(...READ_ANY);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const [k] = await kotList(tx, ctx, kotQuery.parse({}), id);
      if (!k) throw notFound('Kitchen ticket');
      return k;
    });
  });

  function requireKitchenMove(ctx: RequestContext, to: KStatus) {
    if (ctx.can('restaurant.kitchen') || ctx.can('restaurant.manage')) return;
    if (ctx.can('restaurant.orders') && to === 'served') return; // a captain marks food served
    throw forbidden();
  }

  /** Moves every live line of a ticket forward; going back is not allowed. */
  app.patch<{ Params: { id: string } }>('/restaurant/kots/:id/status', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const b = parse(statusBody, req.body);
    requireKitchenMove(ctx, b.status);
    return ctx.tx(async (tx) => {
      const k = await tx.selectFrom('restaurant_kots as k').innerJoin('restaurant_orders as o', 'o.id', 'k.order_id')
        .select(['k.id', 'k.status', 'o.location_id']).where('k.id', '=', id).where('k.company_id', '=', ctx.companyId).forUpdate('k').executeTakeFirst();
      if (!k || !ctx.canAccessLocation(k.location_id)) throw notFound('Kitchen ticket');
      if (k.status === 'cancelled') throw conflict('This ticket is cancelled.', 'KOT_CANCELLED');
      const lines = await tx.selectFrom('restaurant_order_lines').select(['id', 'kitchen_status']).where('kot_id', '=', id).where('state', '=', 'sent').execute();
      if (rank(k.status) > rank(b.status)) throw conflict('A ticket cannot go back a step.', 'STATUS_BACKWARD');
      const ids = lines.filter((l) => rank(l.kitchen_status) < rank(b.status)).map((l) => l.id);
      if (ids.length) await tx.updateTable('restaurant_order_lines').set({ kitchen_status: b.status }).where('id', 'in', ids).execute();
      await refreshKot(tx, id);
      const [out] = await kotList(tx, ctx, kotQuery.parse({}), id);
      return out;
    });
  });

  app.patch<{ Params: { id: string } }>('/restaurant/kot-lines/:id/status', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const b = parse(statusBody, req.body);
    requireKitchenMove(ctx, b.status);
    return ctx.tx(async (tx) => {
      const l = await tx.selectFrom('restaurant_order_lines as l').innerJoin('restaurant_orders as o', 'o.id', 'l.order_id')
        .select(['l.id', 'l.kot_id', 'l.state', 'l.kitchen_status', 'o.location_id', 'o.company_id']).where('l.id', '=', id).forUpdate('l').executeTakeFirst();
      if (!l || l.company_id !== ctx.companyId || !ctx.canAccessLocation(l.location_id) || !l.kot_id) throw notFound('Kitchen line');
      if (l.state !== 'sent') throw conflict('This line is cancelled.', 'LINE_CANCELLED');
      if (rank(b.status) < rank(l.kitchen_status)) throw conflict('A line cannot go back a step.', 'STATUS_BACKWARD');
      await tx.updateTable('restaurant_order_lines').set({ kitchen_status: b.status }).where('id', '=', id).execute();
      await refreshKot(tx, l.kot_id);
      const [out] = await kotList(tx, ctx, kotQuery.parse({}), l.kot_id);
      return out;
    });
  });
}

documentRoute('PATCH', '/restaurant/settings', { body: settingsBody });
documentRoute('POST', '/restaurant/categories', { body: categoryBody });
documentRoute('PATCH', '/restaurant/categories/:id', { body: categoryPatch });
documentRoute('POST', '/restaurant/menu', { body: menuCreate });
documentRoute('PATCH', '/restaurant/menu/:id', { body: menuPatch });
documentRoute('POST', '/restaurant/areas', { body: areaBody });
documentRoute('POST', '/restaurant/tables', { body: tableBody });
documentRoute('PATCH', '/restaurant/tables/:id', { body: tablePatch });
documentRoute('POST', '/restaurant/orders', { body: orderCreate });
documentRoute('PATCH', '/restaurant/orders/:id', { body: orderPatch });
documentRoute('POST', '/restaurant/orders/:id/lines', { body: addLines });
documentRoute('PATCH', '/restaurant/orders/:id/lines/:lineId', { body: linePatch });
documentRoute('POST', '/restaurant/orders/:id/lines/:lineId/cancel', { body: cancelBody });
documentRoute('POST', '/restaurant/orders/:id/move', { body: moveBody });
documentRoute('POST', '/restaurant/orders/:id/merge', { body: mergeBody });
documentRoute('POST', '/restaurant/orders/:id/print-bill', { body: printBody });
documentRoute('POST', '/restaurant/orders/:id/cancel', { body: cancelBody });
documentRoute('POST', '/restaurant/orders/:id/settle', { body: settleBody });
documentRoute('PATCH', '/restaurant/kots/:id/status', { body: statusBody });
documentRoute('PATCH', '/restaurant/kot-lines/:id/status', { body: statusBody });
