import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import { getLocation } from './locations.ts';
import { createPayment } from './payments.ts';
import { fitInclusive } from './pos.ts';
import { documentRoute } from '../lib/openapi.ts';

/*
 * Hotel and guest house front office: room types, rooms, rate plans, reservations, stays, folios and check-out.
 * A night belongs to its date. A booking from `arrival` to `departure` has `departure - arrival` nights.
 * Billing goes through createInvoice and createPayment; this module never writes ledger rows.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const blank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? undefined : v);
const round2 = (n: number) => Math.round(n * 100) / 100;
const MODES = ['cash', 'bank', 'upi', 'cheque', 'card'] as const;
const SOURCES = ['walk_in', 'phone', 'ota', 'agent'] as const;
const ID_TYPES = ['aadhaar', 'passport', 'driving_licence', 'voter_id', 'pan', 'other'] as const;
const ROOM_STATUSES = ['dirty', 'clean', 'inspected', 'out_of_order'] as const;
const RES_STATUSES = ['tentative', 'confirmed', 'checked_in', 'checked_out', 'cancelled', 'no_show'] as const;
const CHARGE_TYPES = ['food', 'laundry', 'minibar', 'extra_bed', 'other', 'discount'] as const;
const LIVE_STATUSES = ['tentative', 'confirmed', 'checked_in'];

/**
 * GST rate for one night of hotel accommodation, from the declared per-night tariff of the room.
 * Slabs used here (2026): up to 1,000 exempt; 1,001 to 7,500 at 5 percent without input tax credit;
 * above 7,500 at 18 percent. NEEDS A CA CHECK against current notifications before real invoicing:
 * the slab follows the declared tariff, and the no-credit condition for the 5 percent slab is not modelled.
 */
export function roomNightGstRate(nightlyTariff: number): 0 | 5 | 18 {
  if (nightlyTariff <= 1000) return 0;
  if (nightlyTariff <= 7500) return 5;
  return 18;
}

const isForeign = (nationality: string | null | undefined) => !!nationality && !/^(india|indian)$/i.test(nationality.trim());
const nightsBetween = (arrival: string, departure: string) =>
  Array.from({ length: Math.max(daysBetween(arrival, departure), 0) }, (_, i) => addDays(arrival, i));
/** Friday and Saturday nights use the weekend tariff. */
const isWeekendNight = (date: string) => [5, 6].includes(new Date(`${date}T00:00:00Z`).getUTCDay());
const hmText = (v: unknown) => z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:MM').parse(v);

// Validation ------------------------------------------------------------------------------------

const phoneField = z.string().trim().min(5, 'Enter a phone number').max(20).regex(/^[0-9+() -]+$/, 'Digits only');
const typeFields = {
  name: z.string().trim().min(1, 'Required').max(80),
  baseOccupancy: z.coerce.number().int().min(1).max(20),
  maxOccupancy: z.coerce.number().int().min(1).max(20),
  baseTariff: moneyField,
  extraPersonCharge: moneyField,
  isActive: z.boolean(),
};
const typeCreate = z.object({
  ...typeFields, baseOccupancy: typeFields.baseOccupancy.default(2), maxOccupancy: typeFields.maxOccupancy.default(3),
  extraPersonCharge: typeFields.extraPersonCharge.default(0), isActive: typeFields.isActive.default(true),
}).refine((b) => b.maxOccupancy >= b.baseOccupancy, { message: 'Max cannot be below base', path: ['maxOccupancy'] });
const typePatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: typeFields.name.optional(), baseOccupancy: typeFields.baseOccupancy.optional(), maxOccupancy: typeFields.maxOccupancy.optional(),
  baseTariff: typeFields.baseTariff.optional(), extraPersonCharge: typeFields.extraPersonCharge.optional(), isActive: typeFields.isActive.optional(),
});
const roomCreate = z.object({
  roomTypeId: z.uuid(), number: z.string().trim().min(1, 'Required').max(20), floor: optionalText(20),
});
const roomPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  roomTypeId: z.uuid().optional(), number: z.string().trim().min(1).max(20).optional(),
  floor: z.preprocess((v) => (v === '' ? null : v), z.string().trim().max(20).nullable().optional()), isActive: z.boolean().optional(),
});
const roomStatusBody = z.object({ status: z.enum(ROOM_STATUSES), reason: optionalText(200) });
const planFields = {
  roomTypeId: z.uuid(), name: z.string().trim().min(1, 'Required').max(80), meal: z.enum(['room_only', 'breakfast']),
  weekdayTariff: moneyField, weekendTariff: moneyField, isActive: z.boolean(),
};
const planCreate = z.object({ ...planFields, meal: planFields.meal.default('room_only'), isActive: planFields.isActive.default(true) });
const planPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  roomTypeId: planFields.roomTypeId.optional(), name: planFields.name.optional(), meal: planFields.meal.optional(),
  weekdayTariff: planFields.weekdayTariff.optional(), weekendTariff: planFields.weekendTariff.optional(), isActive: planFields.isActive.optional(),
});
const settingsBody = z.object({
  pricesIncludeTax: z.boolean().optional(),
  checkInTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:MM').optional(),
  checkOutTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:MM').optional(),
});

const payBody = z.object({
  accountId: z.uuid(), mode: z.enum(MODES), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), reference: optionalText(60),
});
const refundBody = z.object({ refund: payBody.optional() });
const roomReq = z.object({
  roomTypeId: z.uuid(), roomId: z.uuid().optional(), ratePlanId: z.uuid().optional(),
  adults: z.coerce.number().int().min(1).max(20).default(1), children: z.coerce.number().int().min(0).max(20).default(0),
});
const reservationCreate = z.object({
  guest: z.union([
    z.object({ partyId: z.uuid() }),
    z.object({ name: z.string().trim().min(1, 'Required').max(200), phone: phoneField, address: optionalText(500) }),
  ]),
  arrival: dateField, departure: dateField,
  rooms: z.array(roomReq).min(1, 'Add at least one room').max(20),
  overrideTariff: z.preprocess(blank, moneyField.optional()),
  source: z.enum(SOURCES).default('walk_in'), sourceName: optionalText(100),
  status: z.enum(['tentative', 'confirmed']).default('confirmed'), notes: optionalText(1000),
  advance: payBody.optional(),
}).refine((b) => b.departure > b.arrival, { message: 'Departure must be after arrival', path: ['departure'] });
const reservationPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  arrival: dateField.optional(), departure: dateField.optional(),
  overrideTariff: z.preprocess((v) => (v === '' ? null : v), moneyField.nullable().optional()),
  source: z.enum(SOURCES).optional(), sourceName: z.preprocess((v) => (v === '' ? null : v), z.string().trim().max(100).nullable().optional()),
  notes: z.preprocess((v) => (v === '' ? null : v), z.string().trim().max(1000).nullable().optional()),
});
const reservationList = pagingQuery.extend({
  status: z.enum(RES_STATUSES).optional(), date: dateField.optional(), from: dateField.optional(), to: dateField.optional(),
});
const assignBody = z.object({ rooms: z.array(z.object({ id: z.uuid(), roomId: z.uuid() })).min(1).max(20) });
const guestBody = z.object({
  name: z.string().trim().min(1, 'Required').max(200),
  phone: z.preprocess(blank, phoneField.optional()), address: optionalText(500),
  idType: z.enum(ID_TYPES), idNumber: z.string().trim().min(1, 'Required').max(60),
  nationality: optionalText(60), passportNo: optionalText(40), visaNo: optionalText(40), visaType: optionalText(40),
  visaExpiry: z.preprocess(blank, dateField.optional()),
  arrivedFrom: optionalText(120), goingTo: optionalText(120), purpose: optionalText(120),
});
const checkInBody = z.object({
  rooms: z.array(z.object({ id: z.uuid(), roomId: z.uuid().optional(), guest: guestBody })).min(1).max(20),
  force: z.boolean().optional(),
});
const chargeBody = z.object({
  chargeType: z.enum(CHARGE_TYPES), description: z.string().trim().min(1, 'Required').max(300),
  qty: z.coerce.number().min(0.001).max(100000).default(1), rate: moneyField,
  itemId: z.uuid().optional(), reservationRoomId: z.uuid().optional(),
});
const voidBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(200) });
const checkOutBody = z.object({ payment: payBody.optional(), allowCredit: z.boolean().optional(), locationId: z.uuid().optional() });
const nightBody = z.object({ date: dateField.optional() });
const rangeQuery = z.object({ from: dateField, to: dateField });
const boardQuery = z.object({ from: dateField.optional(), days: z.coerce.number().int().min(1).max(31).default(14) });

// Settings and items ------------------------------------------------------------------------------

async function getSettings(tx: Tx, ctx: RequestContext) {
  const s = await tx.selectFrom('hotel_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst();
  return {
    pricesIncludeTax: s?.prices_include_tax ?? false, checkInTime: s?.check_in_time ?? '14:00', checkOutTime: s?.check_out_time ?? '11:00',
    updatedAt: s?.updated_at ?? null,
  };
}

const SERVICE_ITEMS = {
  food: { name: 'Hotel food and beverage', sku: 'HOTEL-FOOD', hsn: '996332', gst: 5 },
  laundry: { name: 'Hotel laundry', sku: 'HOTEL-LAUNDRY', hsn: '999711', gst: 18 },
  minibar: { name: 'Hotel minibar', sku: 'HOTEL-MINIBAR', hsn: '996332', gst: 18 },
  extra_bed: { name: 'Hotel extra bed', sku: 'HOTEL-EXTRABED', hsn: '996311', gst: 18 },
  other: { name: 'Hotel other services', sku: 'HOTEL-OTHER', hsn: '999799', gst: 18 },
  room0: { name: 'Room rent (exempt tariff)', sku: 'HOTEL-ROOM-0', hsn: '996311', gst: 0 },
  room5: { name: 'Room rent (5% tariff)', sku: 'HOTEL-ROOM-5', hsn: '996311', gst: 5 },
  room18: { name: 'Room rent (18% tariff)', sku: 'HOTEL-ROOM-18', hsn: '996311', gst: 18 },
} as const;

/** Service items the front office bills with, created on first use. */
async function serviceItem(tx: Tx, ctx: RequestContext, key: keyof typeof SERVICE_ITEMS): Promise<string> {
  const def = SERVICE_ITEMS[key];
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId)
    .where(sql`lower(sku)`, '=', def.sku.toLowerCase()).executeTakeFirst();
  if (found) return found.id;
  const row = await tx.insertInto('items').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, name: def.name, sku: def.sku, hsn_code: def.hsn,
    unit: 'NOS', gst_rate: def.gst, sale_price: 0, track_stock: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}
const roomItem = (tx: Tx, ctx: RequestContext, gst: number) => serviceItem(tx, ctx, gst === 0 ? 'room0' : gst === 5 ? 'room5' : 'room18');

// Loaders ---------------------------------------------------------------------------------------

async function loadType(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('hotel_room_types').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Room type');
  return row;
}
const typeJson = (t: Awaited<ReturnType<typeof loadType>>) => ({
  id: t.id, name: t.name, baseOccupancy: t.base_occupancy, maxOccupancy: t.max_occupancy, baseTariff: t.base_tariff,
  extraPersonCharge: t.extra_person_charge, isActive: t.is_active, updatedAt: t.updated_at,
});
async function loadRoom(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('hotel_rooms').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Room');
  return row;
}
async function loadPlan(tx: Tx, ctx: RequestContext, id: string) {
  const row = await tx.selectFrom('hotel_rate_plans').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row) throw notFound('Rate plan');
  return row;
}
const planJson = (p: Awaited<ReturnType<typeof loadPlan>>) => ({
  id: p.id, roomTypeId: p.room_type_id, name: p.name, meal: p.meal, weekdayTariff: p.weekday_tariff,
  weekendTariff: p.weekend_tariff, isActive: p.is_active, updatedAt: p.updated_at,
});

async function loadRes(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('hotel_reservations').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Reservation');
  return row;
}

function rrSelect(tx: Tx) {
  return tx.selectFrom('hotel_reservation_rooms as x')
    .innerJoin('hotel_room_types as t', 't.id', 'x.room_type_id')
    .leftJoin('hotel_rooms as rm', 'rm.id', 'x.room_id')
    .leftJoin('hotel_rate_plans as rp', 'rp.id', 'x.rate_plan_id')
    .selectAll('x')
    .select(['t.name as type_name', 't.base_occupancy', 't.base_tariff', 't.extra_person_charge', 'rm.number as room_number',
      'rm.status as room_status', 'rp.name as plan_name', 'rp.weekday_tariff', 'rp.weekend_tariff']);
}
type RR = Awaited<ReturnType<ReturnType<typeof rrSelect>['execute']>>[number];

function rrJson(x: RR, withGuest: boolean) {
  return {
    id: x.id, roomTypeId: x.room_type_id, typeName: x.type_name, roomId: x.room_id, roomNumber: x.room_number, roomStatus: x.room_status,
    ratePlanId: x.rate_plan_id, ratePlanName: x.plan_name, adults: x.adults, children: x.children,
    ...(withGuest ? {
      guest: x.guest_name ? {
        name: x.guest_name, phone: x.guest_phone, address: x.guest_address, idType: x.id_type, idNumber: x.id_number,
        nationality: x.nationality, passportNo: x.passport_no, visaNo: x.visa_no, visaType: x.visa_type, visaExpiry: x.visa_expiry,
        arrivedFrom: x.arrived_from, goingTo: x.going_to, purpose: x.purpose,
      } : null,
    } : {}),
  };
}

async function paidOf(tx: Tx, resId: string, kind?: 'advance' | 'payment') {
  let q = tx.selectFrom('hotel_folio_payments as f').innerJoin('payments as p', 'p.id', 'f.payment_id')
    .select(sql<number>`coalesce(sum(case when f.kind = 'refund' then -f.amount else f.amount end), 0)`.as('s'))
    .where('f.reservation_id', '=', resId).where('p.status', '!=', 'cancelled');
  // Advance held is the advances less what was refunded.
  if (kind === 'advance') q = q.where('f.kind', 'in', ['advance', 'refund']);
  else if (kind) q = q.where('f.kind', '=', kind);
  return round2(Number((await q.executeTakeFirstOrThrow()).s));
}

async function reservationJson(tx: Tx, ctx: RequestContext, r: Awaited<ReturnType<typeof loadRes>>, detail: boolean) {
  const party = await tx.selectFrom('parties').select(['id', 'name', 'phone', 'gstin']).where('id', '=', r.party_id).executeTakeFirstOrThrow();
  const rooms = await rrSelect(tx).where('x.reservation_id', '=', r.id).orderBy('x.created_at').orderBy('x.id').execute();
  return {
    id: r.id, number: r.number, status: r.status, arrival: r.arrival, departure: r.departure, nights: daysBetween(r.arrival, r.departure),
    guest: { partyId: party.id, name: party.name, phone: party.phone, ...(detail ? { gstin: party.gstin } : {}) },
    overrideTariff: r.override_tariff, source: r.source, sourceName: r.source_name, notes: r.notes, cancelReason: r.cancel_reason,
    checkedInAt: r.checked_in_at, checkedOutAt: r.checked_out_at, invoiceId: r.invoice_id,
    advance: await paidOf(tx, r.id, 'advance'), rooms: rooms.map((x) => rrJson(x, detail)), updatedAt: r.updated_at,
  };
}

const needFrontOffice = (ctx: RequestContext) => ctx.require('hotel.front_office', 'hotel.manage');
const needManage = (ctx: RequestContext) => ctx.require('hotel.manage');
const clash = (err: unknown) => (err as { code?: string }).code === '23P01';

// Availability ----------------------------------------------------------------------------------

async function sellableRooms(tx: Tx, ctx: RequestContext, typeId: string): Promise<number> {
  const r = await tx.selectFrom('hotel_rooms').select((eb) => eb.fn.countAll<number>().as('n'))
    .where('company_id', '=', ctx.companyId).where('room_type_id', '=', typeId).where('is_active', '=', true)
    .where('status', '!=', 'out_of_order').executeTakeFirstOrThrow();
  return Number(r.n);
}

async function bookedByDate(tx: Tx, ctx: RequestContext, typeId: string, from: string, to: string, excludeRes?: string) {
  let q = tx.selectFrom('hotel_reservation_rooms').select(['arrival', 'departure'])
    .where('company_id', '=', ctx.companyId).where('room_type_id', '=', typeId).where('live', '=', true)
    .where('arrival', '<', to).where('departure', '>', from);
  if (excludeRes) q = q.where('reservation_id', '!=', excludeRes);
  const map = new Map<string, number>();
  for (const r of await q.execute()) {
    for (const d of nightsBetween(r.arrival, r.departure)) if (d >= from && d < to) map.set(d, (map.get(d) ?? 0) + 1);
  }
  return map;
}

/** Locks the room type, then refuses when `wanted` more rooms would not fit on every night. */
async function assertTypeAvailable(tx: Tx, ctx: RequestContext, typeId: string, from: string, to: string, wanted: number, excludeRes?: string) {
  const type = await loadType(tx, ctx, typeId, true);
  const total = await sellableRooms(tx, ctx, typeId);
  const booked = await bookedByDate(tx, ctx, typeId, from, to, excludeRes);
  for (const d of nightsBetween(from, to)) {
    if ((booked.get(d) ?? 0) + wanted > total) {
      throw conflict(`No ${type.name} room is free on ${d}.`, 'NO_AVAILABILITY', { roomTypeId: typeId, date: d });
    }
  }
}

/** A specific room cannot be held twice on overlapping nights; the database also enforces this. */
async function assertRoomFree(tx: Tx, ctx: RequestContext, roomId: string, from: string, to: string, excludeRr: string[] = []) {
  await loadRoom(tx, ctx, roomId, true);
  let q = tx.selectFrom('hotel_reservation_rooms as x').innerJoin('hotel_reservations as r', 'r.id', 'x.reservation_id')
    .select(['r.number', 'x.arrival', 'x.departure']).where('x.room_id', '=', roomId).where('x.live', '=', true)
    .where('x.arrival', '<', to).where('x.departure', '>', from);
  if (excludeRr.length) q = q.where('x.id', 'not in', excludeRr);
  const hit = await q.executeTakeFirst();
  if (hit) {
    throw conflict(`That room is already booked from ${hit.arrival} to ${hit.departure} (${hit.number}).`, 'ROOM_TAKEN', { roomId });
  }
}

// Tariff and folio ------------------------------------------------------------------------------

/** Tariff for one night of one booked room: reservation override, else rate plan, else the room type. */
function nightTariff(x: RR, overrideTariff: number | null, date: string): number {
  if (overrideTariff !== null && overrideTariff !== undefined) return round2(overrideTariff);
  let base = x.base_tariff;
  if (x.rate_plan_id && x.weekday_tariff !== null && x.weekend_tariff !== null) base = isWeekendNight(date) ? x.weekend_tariff : x.weekday_tariff;
  const extraPeople = Math.max(x.adults + x.children - x.base_occupancy, 0);
  return round2(base + extraPeople * x.extra_person_charge);
}

/** Posts the room charge of every in-house room for one date. Repeating it adds nothing. Returns rooms newly charged. */
async function postNights(tx: Tx, ctx: RequestContext, date: string, onlyReservation?: string): Promise<number> {
  let q = tx.selectFrom('hotel_reservation_rooms as x').innerJoin('hotel_reservations as r', 'r.id', 'x.reservation_id')
    .select(['x.id', 'x.reservation_id', 'r.override_tariff']).where('x.company_id', '=', ctx.companyId)
    .where('r.status', '=', 'checked_in').where('x.live', '=', true).where('x.room_id', 'is not', null)
    .where('x.arrival', '<=', date).where('x.departure', '>', date);
  if (onlyReservation) q = q.where('r.id', '=', onlyReservation);
  const targets = await q.execute();
  let posted = 0;
  for (const t of targets) {
    const x = (await rrSelect(tx).where('x.id', '=', t.id).executeTakeFirstOrThrow());
    const tariff = nightTariff(x, t.override_tariff, date);
    const gst = roomNightGstRate(tariff);
    const done = await tx.insertInto('hotel_folio_lines').values({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, reservation_id: t.reservation_id, reservation_room_id: t.id, line_date: date,
      kind: 'room', charge_type: 'room', description: `Room ${x.room_number} (${x.type_name}), night of ${date}`,
      item_id: await roomItem(tx, ctx, gst), qty: 1, rate: tariff, amount: tariff, gst_rate: gst, source: 'night_audit', created_by: ctx.userId,
    }).onConflict((oc) => oc.doNothing()).returning('id').executeTakeFirst();
    if (done) posted += 1;
  }
  return posted;
}

interface FolioLine { kind: string; amount: number; gst_rate: number; voided: boolean }

/** Estimate of the folio before check-out: the invoice at check-out is the exact figure. */
function folioTotals(lines: FolioLine[], inclusive: boolean) {
  const live = lines.filter((l) => !l.voided);
  const charges = live.filter((l) => l.kind !== 'discount');
  const gross = round2(charges.reduce((s, l) => s + l.amount, 0));
  const discount = round2(Math.min(live.filter((l) => l.kind === 'discount').reduce((s, l) => s + l.amount, 0), gross));
  const keep = gross > 0 ? 1 - discount / gross : 1;
  let subtotal = 0;
  let tax = 0;
  for (const l of charges) {
    const taxable = (inclusive ? l.amount / (1 + l.gst_rate / 100) : l.amount) * keep;
    subtotal += taxable;
    tax += (taxable * l.gst_rate) / 100;
  }
  subtotal = round2(subtotal);
  tax = round2(tax);
  return { gross, discount, subtotal, tax, total: round2(subtotal + tax) };
}

function lineJson(l: { id: string; line_date: string; kind: string; charge_type: string; description: string; qty: number; rate: number; amount: number; gst_rate: number; source: string; voided: boolean; void_reason: string | null; reservation_room_id: string | null; item_id: string | null }) {
  return {
    id: l.id, date: l.line_date, kind: l.kind, chargeType: l.charge_type, description: l.description, qty: l.qty, rate: l.rate,
    amount: l.amount, gstRate: l.gst_rate, source: l.source, voided: l.voided, voidReason: l.void_reason,
    reservationRoomId: l.reservation_room_id, itemId: l.item_id,
  };
}

async function folioOf(tx: Tx, ctx: RequestContext, r: Awaited<ReturnType<typeof loadRes>>) {
  const settings = await getSettings(tx, ctx);
  const lines = await tx.selectFrom('hotel_folio_lines').selectAll().where('reservation_id', '=', r.id)
    .orderBy('line_date').orderBy('created_at').orderBy('id').execute();
  const payments = await tx.selectFrom('hotel_folio_payments as f').innerJoin('payments as p', 'p.id', 'f.payment_id')
    .select(['f.id', 'f.kind', 'f.amount', 'f.created_at', 'p.id as payment_id', 'p.number', 'p.mode', 'p.reference', 'p.status'])
    .where('f.reservation_id', '=', r.id).orderBy('f.created_at').execute();
  const paid = round2(payments.filter((p) => p.status !== 'cancelled').reduce((s, p) => s + (p.kind === 'refund' ? -p.amount : p.amount), 0));
  const invoice = r.invoice_id
    ? await tx.selectFrom('invoices').select(['id', 'number', 'total', 'subtotal', 'cgst', 'sgst', 'igst', 'round_off', 'amount_paid', 'status', 'invoice_date'])
      .where('id', '=', r.invoice_id).executeTakeFirst()
    : undefined;
  let totals = folioTotals(lines, settings.pricesIncludeTax);
  if (invoice && invoice.status !== 'cancelled') {
    totals = { ...totals, subtotal: invoice.subtotal, tax: round2(invoice.cgst + invoice.sgst + invoice.igst), total: invoice.total };
  }
  const reservation = await reservationJson(tx, ctx, r, true);
  return {
    reservation, pricesIncludeTax: settings.pricesIncludeTax, lines: lines.map(lineJson),
    payments: payments.map((p) => ({ id: p.id, paymentId: p.payment_id, number: p.number, kind: p.kind, amount: p.amount, mode: p.mode, reference: p.reference, status: p.status, at: p.created_at })),
    totals: { ...totals, paid, balance: round2(totals.total - paid), estimate: !(invoice && invoice.status !== 'cancelled') },
    invoice: invoice ? { id: invoice.id, number: invoice.number, total: invoice.total, amountPaid: invoice.amount_paid, status: invoice.status, date: invoice.invoice_date } : null,
  };
}

/**
 * Adds a charge to the open folio of a room (for other modules, such as the restaurant's "charge to room").
 * Give the reservation id, or the room number of an in-house guest. Repeating a call with the same source and
 * sourceRef returns the first line. `rate` is the unit price before tax unless the property prices include tax.
 */
export async function postFolioCharge(ctx: RequestContext, tx: Tx, input: {
  reservationId?: string; roomNumber?: string; description: string; rate: number; qty?: number; itemId?: string;
  chargeType?: 'food' | 'laundry' | 'minibar' | 'extra_bed' | 'other'; source: string; sourceRef?: string;
}): Promise<{ lineId: string; reservationId: string; created: boolean }> {
  if (input.sourceRef) {
    const dup = await tx.selectFrom('hotel_folio_lines').select(['id', 'reservation_id']).where('company_id', '=', ctx.companyId)
      .where('source', '=', input.source).where('source_ref', '=', input.sourceRef).executeTakeFirst();
    if (dup) return { lineId: dup.id, reservationId: dup.reservation_id, created: false };
  }
  let resId = input.reservationId;
  if (!resId) {
    const hit = await tx.selectFrom('hotel_reservation_rooms as x').innerJoin('hotel_rooms as rm', 'rm.id', 'x.room_id')
      .innerJoin('hotel_reservations as r', 'r.id', 'x.reservation_id').select('r.id')
      .where('x.company_id', '=', ctx.companyId).where('rm.number', '=', input.roomNumber ?? '').where('r.status', '=', 'checked_in')
      .where('x.live', '=', true).executeTakeFirst();
    resId = hit?.id;
  }
  if (!resId) throw conflict('No guest is checked in to that room.', 'NO_OPEN_FOLIO');
  const res = await loadRes(tx, ctx, resId, true);
  if (res.status !== 'checked_in') throw conflict('That stay is not open.', 'NO_OPEN_FOLIO');
  const line = await addExtraLine(tx, ctx, res.id, {
    chargeType: input.chargeType ?? 'food', description: input.description, qty: input.qty ?? 1, rate: input.rate,
    itemId: input.itemId, reservationRoomId: undefined,
  }, input.source, input.sourceRef ?? null);
  return { lineId: line.id, reservationId: res.id, created: true };
}

async function addExtraLine(tx: Tx, ctx: RequestContext, resId: string, b: {
  chargeType: string; description: string; qty: number; rate: number; itemId?: string; reservationRoomId?: string;
}, source: string, sourceRef: string | null) {
  let itemId: string | null = null;
  let gst = 0;
  if (b.chargeType !== 'discount') {
    if (b.itemId) {
      const item = await tx.selectFrom('items').select(['id', 'gst_rate']).where('id', '=', b.itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!item) throw badRequest('Item not found.', { itemId: 'Not found' });
      itemId = item.id;
      gst = item.gst_rate;
    } else {
      const key = b.chargeType as keyof typeof SERVICE_ITEMS;
      itemId = await serviceItem(tx, ctx, key);
      gst = SERVICE_ITEMS[key].gst;
    }
  }
  if (b.reservationRoomId) {
    const own = await tx.selectFrom('hotel_reservation_rooms').select('id').where('id', '=', b.reservationRoomId).where('reservation_id', '=', resId).executeTakeFirst();
    if (!own) throw badRequest('That room is not part of this stay.', { reservationRoomId: 'Not found' });
  }
  const isDiscount = b.chargeType === 'discount';
  const qty = isDiscount ? 1 : b.qty;
  return tx.insertInto('hotel_folio_lines').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, reservation_id: resId, reservation_room_id: b.reservationRoomId ?? null,
    line_date: todayIst(), kind: isDiscount ? 'discount' : 'extra', charge_type: b.chargeType, description: b.description,
    item_id: itemId, qty, rate: b.rate, amount: round2(qty * b.rate), gst_rate: gst, source, source_ref: sourceRef, created_by: ctx.userId,
  }).returning('id').executeTakeFirstOrThrow();
}

async function recordPayment(tx: Tx, ctx: RequestContext, r: Awaited<ReturnType<typeof loadRes>>, p: z.infer<typeof payBody>, kind: 'advance' | 'payment') {
  ctx.require('payments.create');
  // allocations: [] keeps the receipt unallocated, so it is not applied to some older bill of the same guest.
  const receipt = await createPayment(ctx, tx, {
    kind: 'receipt', partyId: r.party_id, accountId: p.accountId, mode: p.mode, reference: p.reference, amount: p.amount,
    notes: `${kind === 'advance' ? 'Advance' : 'Payment'} ${r.number}`, allocations: [],
  } as never);
  await tx.insertInto('hotel_folio_payments').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, reservation_id: r.id, payment_id: receipt.id, kind, amount: p.amount,
  }).execute();
  return receipt;
}

// Check-in and check-out ------------------------------------------------------------------------

async function firstLocation(tx: Tx, ctx: RequestContext, wanted?: string): Promise<string> {
  if (wanted) return wanted;
  const locs = await tx.selectFrom('locations').select('id').where('company_id', '=', ctx.companyId).where('is_active', '=', true).orderBy('created_at').execute();
  const id = locs.find((l) => ctx.canAccessLocation(l.id))?.id;
  if (!id) throw badRequest('Add a location before billing.', { locationId: 'Required' });
  return id;
}

async function assignRoom(tx: Tx, ctx: RequestContext, x: { id: string; room_type_id: string; arrival: string; departure: string }, roomId: string) {
  const room = await loadRoom(tx, ctx, roomId, true);
  if (!room.is_active) throw badRequest('That room is not in use.', { roomId: 'Inactive' });
  if (room.room_type_id !== x.room_type_id) throw badRequest('That room is a different room type.', { roomId: 'Wrong type' });
  await assertRoomFree(tx, ctx, roomId, x.arrival, x.departure, [x.id]);
  try {
    await tx.updateTable('hotel_reservation_rooms').set({ room_id: roomId }).where('id', '=', x.id).execute();
  } catch (e) {
    if (clash(e)) throw conflict('That room is already booked on those nights.', 'ROOM_TAKEN', { roomId });
    throw e;
  }
  return room;
}

// Routes ----------------------------------------------------------------------------------------

export async function hotelRoutes(app: FastifyInstance) {
  // Settings ----------------------------------------------------------------------------------

  app.get('/hotel/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    return ctx.tx((tx) => getSettings(tx, ctx));
  });

  app.patch('/hotel/settings', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await getSettings(tx, ctx);
      const vals = {
        prices_include_tax: b.pricesIncludeTax ?? cur.pricesIncludeTax, check_in_time: hmText(b.checkInTime ?? cur.checkInTime),
        check_out_time: hmText(b.checkOutTime ?? cur.checkOutTime),
      };
      await tx.insertInto('hotel_settings').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, ...vals })
        .onConflict((oc) => oc.column('company_id').doUpdateSet(vals)).execute();
      await writeAudit(tx, auditOf(ctx), 'hotel_settings', ctx.companyId, 'update', cur, vals);
      return getSettings(tx, ctx);
    });
  });

  // Room types --------------------------------------------------------------------------------

  app.get('/hotel/room-types', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('hotel_room_types').selectAll().where('company_id', '=', ctx.companyId).orderBy('name').execute();
      const counts = await tx.selectFrom('hotel_rooms').select(['room_type_id', (eb) => eb.fn.countAll<number>().as('n')])
        .where('company_id', '=', ctx.companyId).where('is_active', '=', true).groupBy('room_type_id').execute();
      return { data: rows.map((t) => ({ ...typeJson(t), roomCount: Number(counts.find((c) => c.room_type_id === t.id)?.n ?? 0) })) };
    });
  });

  app.post('/hotel/room-types', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(typeCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('hotel_room_types').select('id').where('company_id', '=', ctx.companyId).where(sql`lower(name)`, '=', b.name.toLowerCase()).executeTakeFirst();
      if (dup) throw conflict('A room type with this name exists.', 'DUPLICATE', { name: 'Already used' });
      const row = await tx.insertInto('hotel_room_types').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, base_occupancy: b.baseOccupancy, max_occupancy: b.maxOccupancy,
        base_tariff: b.baseTariff, extra_person_charge: b.extraPersonCharge, is_active: b.isActive,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'hotel_room_type', row.id, 'create', null, { name: b.name });
      return typeJson(await loadType(tx, ctx, row.id));
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/hotel/room-types/:id', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(typePatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadType(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'room type');
      const base = b.baseOccupancy ?? before.base_occupancy;
      const max = b.maxOccupancy ?? before.max_occupancy;
      if (max < base) throw badRequest('Max occupancy cannot be below base occupancy.', { maxOccupancy: 'Below base' });
      const changes = definedOnly({
        name: b.name, base_occupancy: b.baseOccupancy, max_occupancy: b.maxOccupancy, base_tariff: b.baseTariff,
        extra_person_charge: b.extraPersonCharge, is_active: b.isActive,
      });
      if (Object.keys(changes).length) await tx.updateTable('hotel_room_types').set(changes).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'hotel_room_type', id, 'update', null, { fields: Object.keys(changes) });
      return typeJson(await loadType(tx, ctx, id));
    });
  });

  // Rooms -------------------------------------------------------------------------------------

  const roomRows = (tx: Tx, ctx: RequestContext) => tx.selectFrom('hotel_rooms as rm')
    .innerJoin('hotel_room_types as t', 't.id', 'rm.room_type_id').where('rm.company_id', '=', ctx.companyId)
    .select(['rm.id', 'rm.number', 'rm.floor', 'rm.status', 'rm.status_reason', 'rm.is_active', 'rm.room_type_id', 'rm.updated_at', 't.name as type_name',
      sql<string | null>`(select p.name from hotel_reservation_rooms x join hotel_reservations r on r.id = x.reservation_id join parties p on p.id = r.party_id
        where x.room_id = rm.id and x.live and r.status = 'checked_in' limit 1)`.as('in_house_guest')]);
  type RoomRow = Awaited<ReturnType<ReturnType<typeof roomRows>['execute']>>[number];
  const roomJson = (r: RoomRow) => ({
    id: r.id, number: r.number, floor: r.floor, status: r.status, statusReason: r.status_reason, isActive: r.is_active,
    roomTypeId: r.room_type_id, type: r.type_name, occupied: !!r.in_house_guest, guest: r.in_house_guest, updatedAt: r.updated_at,
  });

  app.get('/hotel/rooms', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const q = parse(z.object({ status: z.enum(ROOM_STATUSES).optional(), roomTypeId: z.uuid().optional(), all: z.coerce.boolean().optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = roomRows(tx, ctx);
      if (!q.all) base = base.where('rm.is_active', '=', true);
      if (q.status) base = base.where('rm.status', '=', q.status);
      if (q.roomTypeId) base = base.where('rm.room_type_id', '=', q.roomTypeId);
      const rows = await base.orderBy('rm.floor').orderBy('rm.number').execute();
      rows.sort((a, b) => a.number.localeCompare(b.number, undefined, { numeric: true }));
      return { data: rows.map(roomJson) };
    });
  });

  app.post('/hotel/rooms', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(roomCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      await loadType(tx, ctx, b.roomTypeId);
      const dup = await tx.selectFrom('hotel_rooms').select('id').where('company_id', '=', ctx.companyId).where('number', '=', b.number).executeTakeFirst();
      if (dup) throw conflict('A room with this number exists.', 'DUPLICATE', { number: 'Already used' });
      const row = await tx.insertInto('hotel_rooms').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, room_type_id: b.roomTypeId, number: b.number, floor: b.floor ?? null,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'hotel_room', row.id, 'create', null, { number: b.number });
      return roomJson(await roomRows(tx, ctx).where('rm.id', '=', row.id).executeTakeFirstOrThrow());
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/hotel/rooms/:id', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(roomPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadRoom(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'room');
      if (b.roomTypeId && b.roomTypeId !== before.room_type_id) {
        await loadType(tx, ctx, b.roomTypeId);
        const held = await tx.selectFrom('hotel_reservation_rooms').select('id').where('room_id', '=', id).where('live', '=', true).executeTakeFirst();
        if (held) throw conflict('This room has bookings. Move them before changing its type.', 'ROOM_IN_USE');
      }
      if (b.number && b.number !== before.number) {
        const dup = await tx.selectFrom('hotel_rooms').select('id').where('company_id', '=', ctx.companyId).where('number', '=', b.number).executeTakeFirst();
        if (dup) throw conflict('A room with this number exists.', 'DUPLICATE', { number: 'Already used' });
      }
      if (b.isActive === false) {
        const held = await tx.selectFrom('hotel_reservation_rooms').select('id').where('room_id', '=', id).where('live', '=', true).executeTakeFirst();
        if (held) throw conflict('This room has bookings. Move them before switching it off.', 'ROOM_IN_USE');
      }
      const changes = definedOnly({ room_type_id: b.roomTypeId, number: b.number, floor: b.floor, is_active: b.isActive });
      if (Object.keys(changes).length) await tx.updateTable('hotel_rooms').set(changes).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'hotel_room', id, 'update', null, { fields: Object.keys(changes) });
      return roomJson(await roomRows(tx, ctx).where('rm.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.patch<{ Params: { id: string } }>('/hotel/rooms/:id/status', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.housekeeping', 'hotel.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(roomStatusBody, req.body);
    return ctx.tx(async (tx) => {
      const room = await loadRoom(tx, ctx, id, true);
      const from = room.status;
      const allowed: Record<string, string[]> = {
        dirty: ['clean', 'out_of_order'], clean: ['inspected', 'dirty', 'out_of_order'],
        inspected: ['dirty', 'clean', 'out_of_order'], out_of_order: ['dirty'],
      };
      if (b.status !== from && !allowed[from]!.includes(b.status)) {
        throw conflict(`A ${from.replace('_', ' ')} room cannot go straight to ${b.status.replace('_', ' ')}.`, 'BAD_ROOM_STATUS');
      }
      if (b.status === 'out_of_order') {
        if (!b.reason) throw badRequest('Give a reason for taking the room out of order.', { reason: 'Required' });
        const occ = await tx.selectFrom('hotel_reservation_rooms as x').innerJoin('hotel_reservations as r', 'r.id', 'x.reservation_id')
          .select('x.id').where('x.room_id', '=', id).where('x.live', '=', true).where('r.status', '=', 'checked_in').executeTakeFirst();
        if (occ) throw conflict('A guest is in this room.', 'ROOM_OCCUPIED');
      }
      await tx.updateTable('hotel_rooms').set({ status: b.status, status_reason: b.status === 'out_of_order' ? b.reason ?? null : null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'hotel_room', id, 'status', { status: from }, { status: b.status });
      return roomJson(await roomRows(tx, ctx).where('rm.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  // Rate plans --------------------------------------------------------------------------------

  app.get('/hotel/rate-plans', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const q = parse(z.object({ roomTypeId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('hotel_rate_plans').selectAll().where('company_id', '=', ctx.companyId);
      if (q.roomTypeId) base = base.where('room_type_id', '=', q.roomTypeId);
      return { data: (await base.orderBy('name').execute()).map(planJson) };
    });
  });

  app.post('/hotel/rate-plans', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(planCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      await loadType(tx, ctx, b.roomTypeId);
      const row = await tx.insertInto('hotel_rate_plans').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, room_type_id: b.roomTypeId, name: b.name, meal: b.meal,
        weekday_tariff: b.weekdayTariff, weekend_tariff: b.weekendTariff, is_active: b.isActive,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'hotel_rate_plan', row.id, 'create', null, { name: b.name });
      return planJson(await loadPlan(tx, ctx, row.id));
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/hotel/rate-plans/:id', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(planPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadPlan(tx, ctx, id);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'rate plan');
      if (b.roomTypeId) await loadType(tx, ctx, b.roomTypeId);
      const changes = definedOnly({
        room_type_id: b.roomTypeId, name: b.name, meal: b.meal, weekday_tariff: b.weekdayTariff, weekend_tariff: b.weekendTariff, is_active: b.isActive,
      });
      if (Object.keys(changes).length) await tx.updateTable('hotel_rate_plans').set(changes).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'hotel_rate_plan', id, 'update', null, { fields: Object.keys(changes) });
      return planJson(await loadPlan(tx, ctx, id));
    });
  });

  // Availability, board and today -------------------------------------------------------------

  app.get('/hotel/availability', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const q = parse(rangeQuery, req.query);
    const dates = nightsBetween(q.from, q.to);
    if (!dates.length) throw badRequest('Pick at least one night.', { to: 'After from' });
    if (dates.length > 62) throw badRequest('Ask for at most 62 nights.', { to: 'Too far' });
    return ctx.tx(async (tx) => {
      const types = await tx.selectFrom('hotel_room_types').selectAll().where('company_id', '=', ctx.companyId).where('is_active', '=', true).orderBy('name').execute();
      const out = [];
      for (const t of types) {
        const total = await sellableRooms(tx, ctx, t.id);
        const booked = await bookedByDate(tx, ctx, t.id, q.from, q.to);
        out.push({
          roomTypeId: t.id, name: t.name, baseTariff: t.base_tariff, total,
          byDate: dates.map((d) => ({ date: d, booked: booked.get(d) ?? 0, available: Math.max(total - (booked.get(d) ?? 0), 0) })),
        });
      }
      return { dates, types: out };
    });
  });

  app.get('/hotel/board', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const q = parse(boardQuery, req.query);
    const from = q.from ?? todayIst();
    const to = addDays(from, q.days);
    return ctx.tx(async (tx) => {
      const rooms = await roomRows(tx, ctx).where('rm.is_active', '=', true).execute();
      rooms.sort((a, b) => a.number.localeCompare(b.number, undefined, { numeric: true }));
      const stays = await tx.selectFrom('hotel_reservation_rooms as x').innerJoin('hotel_reservations as r', 'r.id', 'x.reservation_id')
        .innerJoin('parties as p', 'p.id', 'r.party_id').innerJoin('hotel_room_types as t', 't.id', 'x.room_type_id')
        .select(['x.id', 'x.room_id', 'x.arrival', 'x.departure', 'x.guest_name', 'r.id as reservation_id', 'r.number', 'r.status', 'p.name as party_name', 't.name as type_name'])
        .where('x.company_id', '=', ctx.companyId).where('r.status', 'in', ['tentative', 'confirmed', 'checked_in', 'checked_out'])
        .where('x.arrival', '<', to).where('x.departure', '>', from).execute();
      const stayJson = (s: (typeof stays)[number]) => ({
        id: s.id, reservationId: s.reservation_id, number: s.number, guest: s.guest_name ?? s.party_name, arrival: s.arrival,
        departure: s.departure, status: s.status, typeName: s.type_name,
      });
      return {
        from, days: q.days, dates: nightsBetween(from, to),
        rooms: rooms.map((r) => ({
          id: r.id, number: r.number, floor: r.floor, type: r.type_name, status: r.status,
          stays: stays.filter((s) => s.room_id === r.id).map(stayJson),
        })),
        unassigned: stays.filter((s) => !s.room_id && s.status !== 'checked_out').map(stayJson),
      };
    });
  });

  app.get('/hotel/today', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    return ctx.tx(async (tx) => {
      const today = todayIst();
      const settings = await getSettings(tx, ctx);
      const pick = async (rows: Awaited<ReturnType<typeof loadRes>>[], withBalance: boolean) => {
        const out = [];
        for (const r of rows) {
          const j = await reservationJson(tx, ctx, r, false);
          let balance: number | null = null;
          if (withBalance) {
            const lines = await tx.selectFrom('hotel_folio_lines').select(['kind', 'amount', 'gst_rate', 'voided']).where('reservation_id', '=', r.id).execute();
            balance = round2(folioTotals(lines, settings.pricesIncludeTax).total - (await paidOf(tx, r.id)));
          }
          out.push({
            id: j.id, number: j.number, status: j.status, guest: j.guest.name, phone: j.guest.phone, arrival: j.arrival, departure: j.departure,
            rooms: j.rooms.map((x) => ({ id: x.id, type: x.typeName, number: x.roomNumber })), advance: j.advance, balance,
          });
        }
        return out;
      };
      const base = () => tx.selectFrom('hotel_reservations').selectAll().where('company_id', '=', ctx.companyId);
      const arrivals = await base().where('status', 'in', ['tentative', 'confirmed']).where('arrival', '=', today).orderBy('number').execute();
      const departures = await base().where('status', '=', 'checked_in').where('departure', '<=', today).orderBy('number').execute();
      const inHouse = await base().where('status', '=', 'checked_in').orderBy('departure').orderBy('number').execute();
      const counts = await tx.selectFrom('hotel_rooms').select(['status', (eb) => eb.fn.countAll<number>().as('n')])
        .where('company_id', '=', ctx.companyId).where('is_active', '=', true).groupBy('status').execute();
      const roomCounts = { clean: 0, dirty: 0, inspected: 0, out_of_order: 0 } as Record<string, number>;
      for (const c of counts) roomCounts[c.status] = Number(c.n);
      const occ = await tx.selectFrom('hotel_reservation_rooms as x').innerJoin('hotel_reservations as r', 'r.id', 'x.reservation_id')
        .select((eb) => eb.fn.countAll<number>().as('n')).where('x.company_id', '=', ctx.companyId).where('x.live', '=', true).where('r.status', '=', 'checked_in').executeTakeFirstOrThrow();
      return {
        date: today, arrivals: await pick(arrivals, false), departures: await pick(departures, true), inHouse: await pick(inHouse, false),
        roomCounts, occupied: Number(occ.n), totalRooms: Object.values(roomCounts).reduce((a, b) => a + b, 0),
      };
    });
  });

  // Reservations ------------------------------------------------------------------------------

  app.get('/hotel/reservations', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const q = parse(reservationList, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('hotel_reservations as r').innerJoin('parties as p', 'p.id', 'r.party_id').where('r.company_id', '=', ctx.companyId);
      if (q.status) base = base.where('r.status', '=', q.status);
      if (q.date) base = base.where('r.arrival', '<=', q.date).where('r.departure', '>', q.date);
      if (q.from) base = base.where('r.arrival', '>=', q.from);
      if (q.to) base = base.where('r.arrival', '<=', q.to);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('p.name', 'ilike', t), eb('r.number', 'ilike', t), eb('p.phone', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.select('r.id').orderBy('r.arrival', 'desc').orderBy('r.number', 'desc').limit(q.limit).offset(q.offset).execute();
      const data = [];
      for (const row of rows) data.push(await reservationJson(tx, ctx, await loadRes(tx, ctx, row.id), false));
      return { total: Number(total), data };
    });
  });

  app.post('/hotel/reservations', async (req, reply) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const b = parse(reservationCreate, req.body);
    if (b.arrival < todayIst()) throw badRequest('Arrival cannot be in the past.', { arrival: 'In the past' });
    const out = await ctx.tx(async (tx) => {
      // Party: existing, or a new customer party for a new guest.
      let partyId: string;
      if ('partyId' in b.guest) {
        const p = await tx.selectFrom('parties').select('id').where('id', '=', b.guest.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p) throw badRequest('Guest not found.', { guest: 'Not found' });
        partyId = p.id;
      } else {
        const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
        const party = await tx.insertInto('parties').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: b.guest.name, phone: b.guest.phone,
          address: b.guest.address ?? null, state_code: company.state_code, gstin: null, email: null, pan: null, pincode: null,
          udyam_no: null, msme_category: null, tds_section_id: null,
        }).returning('id').executeTakeFirstOrThrow();
        partyId = party.id;
      }

      // Rooms: types must exist; per type the count must fit on every night; specific rooms must be free.
      const perType = new Map<string, number>();
      for (const r of b.rooms) {
        const t = await loadType(tx, ctx, r.roomTypeId);
        if (!t.is_active) throw badRequest(`${t.name} is not in use.`, { rooms: 'Inactive room type' });
        if (r.adults + r.children > t.max_occupancy) throw badRequest(`${t.name} holds at most ${t.max_occupancy} guests.`, { rooms: 'Too many guests' });
        if (r.ratePlanId) {
          const plan = await loadPlan(tx, ctx, r.ratePlanId);
          if (plan.room_type_id !== r.roomTypeId) throw badRequest('That rate plan is for a different room type.', { ratePlanId: 'Wrong room type' });
        }
        perType.set(r.roomTypeId, (perType.get(r.roomTypeId) ?? 0) + 1);
      }
      const typeIds = [...perType.keys()].sort();
      for (const typeId of typeIds) await assertTypeAvailable(tx, ctx, typeId, b.arrival, b.departure, perType.get(typeId)!);
      const seenRooms = new Set<string>();
      for (const r of b.rooms) {
        if (!r.roomId) continue;
        if (seenRooms.has(r.roomId)) throw badRequest('The same room is listed twice.', { rooms: 'Duplicate room' });
        seenRooms.add(r.roomId);
        const room = await loadRoom(tx, ctx, r.roomId, true);
        if (room.room_type_id !== r.roomTypeId || !room.is_active) throw badRequest('That room does not match the room type.', { rooms: 'Wrong room' });
        await assertRoomFree(tx, ctx, r.roomId, b.arrival, b.departure);
      }

      const number = await nextNumber(tx, ctx, 'reservation', financialYear(todayIst()));
      const res = await tx.insertInto('hotel_reservations').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, party_id: partyId, arrival: b.arrival, departure: b.departure,
        override_tariff: b.overrideTariff ?? null, source: b.source, source_name: b.sourceName ?? null, status: b.status,
        notes: b.notes ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      try {
        await tx.insertInto('hotel_reservation_rooms').values(b.rooms.map((r) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, reservation_id: res.id, room_type_id: r.roomTypeId, room_id: r.roomId ?? null,
          rate_plan_id: r.ratePlanId ?? null, arrival: b.arrival, departure: b.departure, adults: r.adults, children: r.children,
        }))).execute();
      } catch (e) {
        if (clash(e)) throw conflict('A room is already booked on those nights.', 'ROOM_TAKEN');
        throw e;
      }
      const row = await loadRes(tx, ctx, res.id);
      if (b.advance) await recordPayment(tx, ctx, row, b.advance, 'advance');
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', res.id, 'create', null, { number, arrival: b.arrival, departure: b.departure, rooms: b.rooms.length });
      return reservationJson(tx, ctx, await loadRes(tx, ctx, res.id), true);
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/hotel/reservations/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => reservationJson(tx, ctx, await loadRes(tx, ctx, id), true));
  });

  app.patch<{ Params: { id: string } }>('/hotel/reservations/:id', async (req) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(reservationPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadRes(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'reservation');
      if (!LIVE_STATUSES.includes(before.status)) throw conflict('This reservation is closed.', 'RESERVATION_CLOSED');
      const inHouse = before.status === 'checked_in';
      if (inHouse && b.arrival && b.arrival !== before.arrival) throw badRequest('A guest in the house cannot change arrival.', { arrival: 'Already arrived' });
      const arrival = b.arrival ?? before.arrival;
      const departure = b.departure ?? before.departure;
      if (departure <= arrival) throw badRequest('Departure must be after arrival.', { departure: 'Not after arrival' });
      if (!inHouse && arrival < todayIst()) throw badRequest('Arrival cannot be in the past.', { arrival: 'In the past' });
      if (inHouse && departure <= todayIst() && departure < before.departure) {
        // Shortening to today or earlier is allowed only as today; check-out handles the rest.
        if (departure < todayIst()) throw badRequest('Departure cannot be before today.', { departure: 'In the past' });
      }
      if (arrival !== before.arrival || departure !== before.departure) {
        const rooms = await tx.selectFrom('hotel_reservation_rooms').selectAll().where('reservation_id', '=', id).where('live', '=', true).execute();
        const perType = new Map<string, number>();
        for (const x of rooms) perType.set(x.room_type_id, (perType.get(x.room_type_id) ?? 0) + 1);
        for (const typeId of [...perType.keys()].sort()) await assertTypeAvailable(tx, ctx, typeId, arrival, departure, perType.get(typeId)!, id);
        for (const x of rooms) if (x.room_id) await assertRoomFree(tx, ctx, x.room_id, arrival, departure, [x.id]);
        try {
          await tx.updateTable('hotel_reservation_rooms').set({ arrival, departure }).where('reservation_id', '=', id).execute();
        } catch (e) {
          if (clash(e)) throw conflict('A room is already booked on those nights.', 'ROOM_TAKEN');
          throw e;
        }
      }
      const changes = definedOnly({
        arrival, departure, override_tariff: b.overrideTariff, source: b.source, source_name: b.sourceName, notes: b.notes,
      });
      await tx.updateTable('hotel_reservations').set(changes).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, 'update', null, { fields: Object.keys(changes) });
      return reservationJson(tx, ctx, await loadRes(tx, ctx, id), true);
    });
  });

  const setStatus = (action: 'confirm' | 'cancel' | 'no-show') => async (req: { ctx: RequestContext; params: { id: string }; body: unknown }) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = action === 'cancel' ? parse(z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) }).extend(refundBody.shape), req.body) : { reason: undefined, refund: undefined };
    return ctx.tx(async (tx) => {
      const r = await loadRes(tx, ctx, id, true);
      if (action === 'confirm') {
        if (r.status !== 'tentative') throw conflict('Only a tentative reservation can be confirmed.', 'BAD_STATUS');
        await tx.updateTable('hotel_reservations').set({ status: 'confirmed' }).where('id', '=', id).execute();
      } else {
        if (!['tentative', 'confirmed'].includes(r.status)) throw conflict('Only a reservation that has not arrived can be closed this way.', 'BAD_STATUS');
        if (action === 'no-show' && r.arrival > todayIst()) throw conflict('The guest is not due yet.', 'BAD_STATUS');
        await tx.updateTable('hotel_reservations').set({ status: action === 'cancel' ? 'cancelled' : 'no_show', cancel_reason: b.reason ?? null }).where('id', '=', id).execute();
        await tx.updateTable('hotel_reservation_rooms').set({ live: false }).where('reservation_id', '=', id).execute();
      }
      if (b.refund) {
        ctx.require('payments.create');
        const held = await paidOf(tx, id, 'advance');
        if (b.refund.amount > held + 0.005) throw badRequest(`Only ₹${held.toFixed(2)} of advance is held.`, { refund: 'More than the advance held' });
        // An unallocated outgoing payment to the guest; the payments service posts the journal.
        const pay = await createPayment(ctx, tx, {
          kind: 'payment', partyId: r.party_id, accountId: b.refund.accountId, mode: b.refund.mode, reference: b.refund.reference,
          amount: b.refund.amount, notes: `Advance refund ${r.number}`, allocations: [],
        } as never, { customerRefund: true });
        await tx.insertInto('hotel_folio_payments').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, reservation_id: id, payment_id: pay.id, kind: 'refund', amount: b.refund.amount,
        }).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, action, null, b.refund ? { refund: b.refund.amount } : null);
      const out = await reservationJson(tx, ctx, await loadRes(tx, ctx, id), true);
      return action === 'confirm' ? out : { ...out, advanceHeld: out.advance };
    });
  };
  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/confirm', async (req) => setStatus('confirm')(req as never));
  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/cancel', async (req) => setStatus('cancel')(req as never));
  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/no-show', async (req) => setStatus('no-show')(req as never));

  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/advance', async (req, reply) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(payBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const r = await loadRes(tx, ctx, id, true);
      if (!LIVE_STATUSES.includes(r.status)) throw conflict('This reservation is closed.', 'RESERVATION_CLOSED');
      await recordPayment(tx, ctx, r, b, 'advance');
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, 'advance', null, { amount: b.amount });
      return folioOf(tx, ctx, r);
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/assign', async (req) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(assignBody, req.body);
    return ctx.tx(async (tx) => {
      const r = await loadRes(tx, ctx, id, true);
      if (!LIVE_STATUSES.includes(r.status)) throw conflict('This reservation is closed.', 'RESERVATION_CLOSED');
      for (const a of b.rooms) {
        const x = await tx.selectFrom('hotel_reservation_rooms').selectAll().where('id', '=', a.id).where('reservation_id', '=', id).executeTakeFirst();
        if (!x) throw notFound('Booked room');
        const room = await assignRoom(tx, ctx, x, a.roomId);
        if (r.status === 'checked_in' && !['clean', 'inspected'].includes(room.status) && !ctx.can('hotel.manage')) {
          throw conflict(`Room ${room.number} is not ready.`, 'ROOM_NOT_READY');
        }
      }
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, 'assign', null, { rooms: b.rooms.length });
      return reservationJson(tx, ctx, await loadRes(tx, ctx, id), true);
    });
  });

  // Check-in ----------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/check-in', async (req) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(checkInBody, req.body);
    if (b.force) needManage(ctx);
    return ctx.tx(async (tx) => {
      const r = await loadRes(tx, ctx, id, true);
      if (!['tentative', 'confirmed'].includes(r.status)) throw conflict('This reservation cannot be checked in.', 'BAD_STATUS');
      const today = todayIst();
      if (r.arrival > today) throw badRequest(`Arrival is on ${r.arrival}. Change the dates to check in early.`, { arrival: 'Not yet' });
      if (r.departure <= today) throw badRequest('The departure date has passed. Change the dates first.', { departure: 'In the past' });
      const booked = await tx.selectFrom('hotel_reservation_rooms').selectAll().where('reservation_id', '=', id).where('live', '=', true).execute();
      const given = new Map(b.rooms.map((x) => [x.id, x]));
      for (const x of b.rooms) if (!booked.some((y) => y.id === x.id)) throw notFound('Booked room');
      for (const x of booked) {
        const entry = given.get(x.id);
        if (!entry) throw badRequest('Give guest details for every room.', { rooms: 'Missing room' });
        const g = entry.guest;
        if (isForeign(g.nationality)) {
          const missing = (['passportNo', 'visaNo', 'visaExpiry'] as const).filter((k) => !g[k]);
          if (missing.length) {
            throw badRequest('A foreign guest needs passport number, visa number and visa expiry.',
              Object.fromEntries(missing.map((k) => [`rooms.guest.${k}`, 'Required for foreign guests'])));
          }
        }
        const roomId = entry.roomId ?? x.room_id;
        if (!roomId) throw badRequest('Assign a room before check-in.', { roomId: 'Required' });
        const room = roomId === x.room_id ? await loadRoom(tx, ctx, roomId, true) : await assignRoom(tx, ctx, x, roomId);
        if (!['clean', 'inspected'].includes(room.status) && !(b.force && ctx.can('hotel.manage'))) {
          throw conflict(`Room ${room.number} is ${room.status.replace('_', ' ')}, not ready for a guest.`, 'ROOM_NOT_READY', { roomId });
        }
        const busy = await tx.selectFrom('hotel_reservation_rooms as y').innerJoin('hotel_reservations as q', 'q.id', 'y.reservation_id')
          .select('q.number').where('y.room_id', '=', roomId).where('y.live', '=', true).where('q.status', '=', 'checked_in').where('y.id', '!=', x.id).executeTakeFirst();
        if (busy) throw conflict(`Room ${room.number} still has a guest (${busy.number}).`, 'ROOM_TAKEN', { roomId });
        await tx.updateTable('hotel_reservation_rooms').set({
          guest_name: g.name, guest_phone: g.phone ?? null, guest_address: g.address ?? null, id_type: g.idType, id_number: g.idNumber,
          nationality: g.nationality ?? 'Indian', passport_no: g.passportNo ?? null, visa_no: g.visaNo ?? null, visa_type: g.visaType ?? null,
          visa_expiry: g.visaExpiry ?? null, arrived_from: g.arrivedFrom ?? null, going_to: g.goingTo ?? null, purpose: g.purpose ?? null,
        }).where('id', '=', x.id).execute();
      }
      await tx.updateTable('hotel_reservations').set({ status: 'checked_in', checked_in_at: new Date() }).where('id', '=', id).execute();
      // Post every night from arrival up to today so a late check-in is billed for the nights held.
      for (const d of nightsBetween(r.arrival, addDays(today, 1))) await postNights(tx, ctx, d, id);
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, 'check_in', null, { rooms: booked.length });
      return reservationJson(tx, ctx, await loadRes(tx, ctx, id), true);
    });
  });

  // Folio -------------------------------------------------------------------------------------

  app.get<{ Params: { id: string } }>('/hotel/reservations/:id/folio', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => folioOf(tx, ctx, await loadRes(tx, ctx, id)));
  });

  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/charges', async (req, reply) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(chargeBody, req.body);
    if (b.chargeType === 'discount') needManage(ctx);
    const out = await ctx.tx(async (tx) => {
      const r = await loadRes(tx, ctx, id, true);
      if (r.status !== 'checked_in') throw conflict('Charges can be added while the guest is in the house.', 'BAD_STATUS');
      if (b.chargeType === 'discount') {
        const lines = await tx.selectFrom('hotel_folio_lines').select(['kind', 'amount', 'gst_rate', 'voided']).where('reservation_id', '=', id).execute();
        const t = folioTotals(lines, true);
        if (b.rate > t.gross - t.discount + 0.005) throw badRequest('The discount is more than the charges.', { rate: 'More than the folio' });
      }
      await addExtraLine(tx, ctx, id, b, 'front_office', null);
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, b.chargeType === 'discount' ? 'discount' : 'charge', null, { amount: b.rate, type: b.chargeType });
      return folioOf(tx, ctx, r);
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string; lineId: string } }>('/hotel/reservations/:id/charges/:lineId/void', async (req) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const id = parse(z.uuid(), req.params.id);
    const lineId = parse(z.uuid(), req.params.lineId);
    const b = parse(voidBody, req.body);
    return ctx.tx(async (tx) => {
      const r = await loadRes(tx, ctx, id, true);
      if (r.status !== 'checked_in') throw conflict('Charges can only be voided before check-out.', 'BAD_STATUS');
      const line = await tx.selectFrom('hotel_folio_lines').selectAll().where('id', '=', lineId).where('reservation_id', '=', id).executeTakeFirst();
      if (!line) throw notFound('Charge');
      if (line.kind === 'room') throw badRequest('Room charges cannot be voided. Change the stay dates instead.', { lineId: 'Room charge' });
      if (line.kind === 'discount' ) needManage(ctx);
      if (line.voided) throw conflict('Already voided.', 'ALREADY_VOIDED');
      await tx.updateTable('hotel_folio_lines').set({ voided: true, void_reason: b.reason }).where('id', '=', lineId).execute();
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, 'void_charge', null, { lineId, reason: b.reason });
      return folioOf(tx, ctx, r);
    });
  });

  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/payments', async (req, reply) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(payBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const r = await loadRes(tx, ctx, id, true);
      if (!LIVE_STATUSES.includes(r.status)) throw conflict('This stay is closed.', 'BAD_STATUS');
      await recordPayment(tx, ctx, r, b, r.status === 'checked_in' ? 'payment' : 'advance');
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, 'payment', null, { amount: b.amount });
      return folioOf(tx, ctx, r);
    });
    return reply.status(201).send(out);
  });

  app.post('/hotel/night-charges', async (req) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    const b = parse(nightBody, req.body ?? {});
    const date = b.date ?? todayIst();
    if (date > todayIst()) throw badRequest('Night charges cannot be posted for a future date.', { date: 'In the future' });
    return ctx.tx(async (tx) => {
      const posted = await postNights(tx, ctx, date);
      await writeAudit(tx, auditOf(ctx), 'hotel_night_charges', ctx.companyId, 'post', null, { date, posted });
      return { date, posted };
    });
  });

  // Check-out ---------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/hotel/reservations/:id/check-out', async (req) => {
    const ctx = req.ctx;
    needFrontOffice(ctx);
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(checkOutBody, req.body ?? {});
    return ctx.tx(async (tx) => {
      const r = await loadRes(tx, ctx, id, true);
      if (r.status !== 'checked_in') throw conflict('This guest is not checked in.', 'BAD_STATUS');
      const today = todayIst();
      const settings = await getSettings(tx, ctx);
      // Catch up any night not yet posted, up to last night (the check-in already charged its own night).
      for (const d of nightsBetween(r.arrival, today)) if (d < r.departure) await postNights(tx, ctx, d, id);

      const lines = await tx.selectFrom('hotel_folio_lines').selectAll().where('reservation_id', '=', id).where('voided', '=', false).orderBy('line_date').orderBy('created_at').execute();
      const charges = lines.filter((l) => l.kind !== 'discount');
      if (!charges.length) throw badRequest('There is nothing to bill on this stay.', { lines: 'Empty folio' });
      const gross = round2(charges.reduce((s, l) => s + l.amount, 0));
      const discount = round2(Math.min(lines.filter((l) => l.kind === 'discount').reduce((s, l) => s + l.amount, 0), gross));

      // Group identical charges (for example all nights of a room at one tariff) into one invoice line.
      const rooms = await rrSelect(tx).where('x.reservation_id', '=', id).execute();
      const groups = new Map<string, { itemId: string; qty: number; rate: number; gst: number; description: string }>();
      for (const l of charges) {
        const rn = l.reservation_room_id ? rooms.find((x) => x.id === l.reservation_room_id)?.room_number : null;
        const key = [l.item_id, l.rate, l.kind === 'room' ? rn : l.description].join('|');
        const g = groups.get(key);
        if (g) g.qty = Math.round((g.qty + l.qty) * 1000) / 1000;
        else groups.set(key, {
          itemId: l.item_id!, qty: l.qty, rate: l.rate, gst: l.gst_rate,
          description: l.kind === 'room' ? `Room ${rn} (${rooms.find((x) => x.id === l.reservation_room_id)?.type_name})` : l.description,
        });
      }
      const list = [...groups.values()];
      const locationId = await firstLocation(tx, ctx, b.locationId);
      const location = await getLocation(tx, ctx, locationId);
      const party = await tx.selectFrom('parties').select(['id', 'state_code']).where('id', '=', r.party_id).executeTakeFirstOrThrow();
      let invLines: { itemId: string; qty: number; rate: number; discountPct: number; description: string }[];
      if (settings.pricesIncludeTax) {
        const fit = fitInclusive(location.state_code, party.state_code ?? location.state_code,
          list.map((g) => ({ itemId: g.itemId, qty: g.qty, rateIncl: g.rate, discountPct: 0, gstRate: g.gst })),
          discount > 0 ? { type: 'amount', value: discount } : undefined, undefined);
        invLines = fit.lines.map((l, i) => ({ itemId: l.itemId, qty: l.qty, rate: l.rate, discountPct: l.discountPct, description: list[i]!.description }));
      } else {
        const pct = gross > 0 ? Math.round((discount / gross) * 10000) / 100 : 0;
        invLines = list.map((g) => ({ itemId: g.itemId, qty: g.qty, rate: g.rate, discountPct: pct, description: g.description }));
      }
      const roomNos = rooms.map((x) => x.room_number).filter(Boolean).join(', ');
      const invoice = await createInvoice(ctx, tx, {
        locationId, partyId: r.party_id, invoiceDate: today, lines: invLines,
        notes: `Stay ${r.number}, rooms ${roomNos}, ${r.arrival} to ${r.departure}`,
      } as never);

      // Advances and payments taken during the stay settle this invoice.
      let due = round2(invoice.total);
      const folioPays = await tx.selectFrom('hotel_folio_payments as f').innerJoin('payments as p', 'p.id', 'f.payment_id')
        .select(['f.payment_id', 'f.amount']).where('f.reservation_id', '=', id).where('p.status', '!=', 'cancelled').orderBy('f.created_at').execute();
      let applied = 0;
      for (const fp of folioPays) {
        const take = round2(Math.min(due, fp.amount));
        if (take <= 0) continue;
        await tx.insertInto('payment_allocations').values({ tenant_id: ctx.tenantId, payment_id: fp.payment_id, doc_type: 'invoice', doc_id: invoice.id, amount: take }).execute();
        due = round2(due - take);
        applied = round2(applied + take);
      }
      if (applied > 0) await tx.updateTable('invoices').set((eb) => ({ amount_paid: eb('amount_paid', '+', applied) })).where('id', '=', invoice.id).execute();
      const credited = round2(folioPays.reduce((s, p) => s + p.amount, 0) - applied);

      if (b.payment) {
        ctx.require('payments.create');
        if (b.payment.amount > due + 0.005) throw badRequest(`Only ₹${due.toFixed(2)} is due.`, { payment: 'More than the balance' });
        const receipt = await createPayment(ctx, tx, {
          kind: 'receipt', partyId: r.party_id, accountId: b.payment.accountId, mode: b.payment.mode, reference: b.payment.reference,
          amount: b.payment.amount, notes: `Check-out ${r.number}`, allocations: [{ docId: invoice.id, amount: b.payment.amount }],
        } as never);
        await tx.insertInto('hotel_folio_payments').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, reservation_id: id, payment_id: receipt.id, kind: 'payment', amount: b.payment.amount,
        }).execute();
        due = round2(due - b.payment.amount);
      }
      if (due > 0.005 && !b.allowCredit) throw conflict(`₹${due.toFixed(2)} is still due. Take payment or allow credit.`, 'BALANCE_DUE', { due });

      await tx.updateTable('hotel_reservations').set({
        status: 'checked_out', checked_out_at: new Date(), invoice_id: invoice.id,
        ...(today < r.departure && today > r.arrival ? { departure: today } : {}),
      }).where('id', '=', id).execute();
      await tx.updateTable('hotel_reservation_rooms').set({ live: false, ...(today < r.departure && today > r.arrival ? { departure: today } : {}) })
        .where('reservation_id', '=', id).execute();
      const roomIds = rooms.map((x) => x.room_id).filter((x): x is string => !!x);
      if (roomIds.length) await tx.updateTable('hotel_rooms').set({ status: 'dirty', status_reason: null }).where('id', 'in', roomIds).execute();
      await writeAudit(tx, auditOf(ctx), 'hotel_reservation', id, 'check_out', null, { invoiceId: invoice.id, total: invoice.total });
      return {
        reservation: await reservationJson(tx, ctx, await loadRes(tx, ctx, id), true),
        invoice: { id: invoice.id, number: invoice.number, total: invoice.total },
        balanceDue: due > 0.005 ? due : 0, refundDue: credited > 0.005 ? credited : 0,
      };
    });
  });

  // Reports -----------------------------------------------------------------------------------

  app.get('/hotel/reports/occupancy', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const q = parse(rangeQuery, req.query);
    if (q.to < q.from) throw badRequest('End date is before start date.', { to: 'Before from' });
    const days = nightsBetween(q.from, addDays(q.to, 1));
    if (days.length > 366) throw badRequest('Ask for at most a year.', { to: 'Too long' });
    return ctx.tx(async (tx) => {
      const avail = await tx.selectFrom('hotel_rooms').select((eb) => eb.fn.countAll<number>().as('n')).where('company_id', '=', ctx.companyId).where('is_active', '=', true).executeTakeFirstOrThrow();
      const available = Number(avail.n);
      const rows = await tx.selectFrom('hotel_folio_lines').select(['line_date', (eb) => eb.fn.countAll<number>().as('sold'), sql<number>`coalesce(sum(amount), 0)`.as('revenue')])
        .where('company_id', '=', ctx.companyId).where('kind', '=', 'room').where('line_date', '>=', q.from).where('line_date', '<=', q.to).groupBy('line_date').execute();
      const out = days.map((date) => {
        const row = rows.find((x) => x.line_date === date);
        const sold = Number(row?.sold ?? 0);
        const revenue = round2(Number(row?.revenue ?? 0));
        return {
          date, available, sold, revenue, occupancyPct: available ? round2((sold / available) * 100) : 0,
          adr: sold ? round2(revenue / sold) : 0, revpar: available ? round2(revenue / available) : 0,
        };
      });
      const sold = out.reduce((s, x) => s + x.sold, 0);
      const revenue = round2(out.reduce((s, x) => s + x.revenue, 0));
      const cap = available * days.length;
      return {
        rows: out,
        totals: { available: cap, sold, revenue, occupancyPct: cap ? round2((sold / cap) * 100) : 0, adr: sold ? round2(revenue / sold) : 0, revpar: cap ? round2(revenue / cap) : 0 },
        note: 'Based on posted room nights. Revenue is the room tariff before tax unless prices include tax.',
      };
    });
  });

  app.get('/hotel/reports/guest-register', async (req) => {
    const ctx = req.ctx;
    ctx.require('hotel.view');
    const q = parse(rangeQuery, req.query);
    if (q.to < q.from) throw badRequest('End date is before start date.', { to: 'Before from' });
    return ctx.tx(async (tx) => {
      const rows = await rrSelect(tx).innerJoin('hotel_reservations as r', 'r.id', 'x.reservation_id')
        .select(['r.number', 'r.checked_in_at', 'r.checked_out_at', 'r.status'])
        .where('x.company_id', '=', ctx.companyId).where('r.status', 'in', ['checked_in', 'checked_out'])
        .where('x.arrival', '<=', q.to).where('x.departure', '>=', q.from).orderBy('r.checked_in_at').orderBy('x.id').execute();
      return {
        data: rows.map((x, i) => ({
          serial: i + 1, reservationNumber: x.number, room: x.room_number, name: x.guest_name, address: x.guest_address, phone: x.guest_phone,
          nationality: x.nationality, idType: x.id_type, idNumber: x.id_number, passportNo: x.passport_no, visaNo: x.visa_no,
          visaType: x.visa_type, visaExpiry: x.visa_expiry, arrivedFrom: x.arrived_from, goingTo: x.going_to, purpose: x.purpose,
          adults: x.adults, children: x.children, checkedInAt: x.checked_in_at, checkedOutAt: x.checked_out_at, status: x.status,
        })),
      };
    });
  });
}

documentRoute('PATCH', '/hotel/settings', { body: settingsBody });
documentRoute('POST', '/hotel/room-types', { body: typeCreate });
documentRoute('PATCH', '/hotel/room-types/:id', { body: typePatch });
documentRoute('POST', '/hotel/rooms', { body: roomCreate });
documentRoute('PATCH', '/hotel/rooms/:id', { body: roomPatch });
documentRoute('PATCH', '/hotel/rooms/:id/status', { body: roomStatusBody });
documentRoute('POST', '/hotel/rate-plans', { body: planCreate });
documentRoute('PATCH', '/hotel/rate-plans/:id', { body: planPatch });
documentRoute('POST', '/hotel/reservations', { body: reservationCreate });
documentRoute('PATCH', '/hotel/reservations/:id', { body: reservationPatch });
documentRoute('POST', '/hotel/reservations/:id/advance', { body: payBody });
documentRoute('POST', '/hotel/reservations/:id/assign', { body: assignBody });
documentRoute('POST', '/hotel/reservations/:id/check-in', { body: checkInBody });
documentRoute('POST', '/hotel/reservations/:id/charges', { body: chargeBody });
documentRoute('POST', '/hotel/reservations/:id/charges/:lineId/void', { body: voidBody });
documentRoute('POST', '/hotel/reservations/:id/payments', { body: payBody });
