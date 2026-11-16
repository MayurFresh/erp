import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { todayIst } from '../lib/dates.ts';
import { BUSINESS_TYPES } from '../lib/business-types.ts';
import { computeGst } from '../lib/gst.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createCreditNote } from './credit-notes.ts';
import { createInvoice, loadInvoice } from './invoices.ts';
import { getLocation } from './locations.ts';
import { createPayment } from './payments.ts';
import { reservedQty } from './stock.ts';
import { whExtras, whLineFields } from './warehouse.ts';
import { documentRoute } from '../lib/openapi.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const MODES = ['cash', 'upi', 'card', 'other'] as const;
type Mode = (typeof MODES)[number];
const WALK_IN = 'Walk-in Customer';

const positive = moneyField.refine((v) => v > 0, 'Must be more than zero');

const openBody = z.object({ locationId: z.uuid(), openingFloat: moneyField.default(0), notes: optionalText(500) });
const closeBody = z.object({
  counted: z.object({ cash: moneyField, upi: moneyField.optional(), card: moneyField.optional(), other: moneyField.optional() }),
  notes: optionalText(500),
  confirmHeld: z.boolean().optional(),
});
const cashMoveBody = z.object({ kind: z.enum(['in', 'out']), amount: positive, reason: z.string().trim().min(2, 'Give a reason').max(200) });
const sessionsQuery = pagingQuery.extend({
  status: z.enum(['open', 'closed']).optional(), locationId: z.uuid().optional(),
  from: docDate.optional(), to: docDate.optional(), mine: z.enum(['true', 'false']).optional(),
});

const saleLine = z.object({
  itemId: z.uuid(),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
  rate: moneyField.optional(),
  discountPct: percentField.optional(),
  ...whLineFields,
});
const saleBody = z.object({
  sessionId: z.uuid().optional(),
  locationId: z.uuid().optional(),
  partyId: z.uuid().nullable().optional(),
  lines: z.array(saleLine).min(1, 'Add at least one line').max(200, 'At most 200 lines'),
  billDiscount: z.object({ type: z.enum(['pct', 'amount']), value: moneyField }).optional(),
  payments: z.array(z.object({ mode: z.enum(MODES), amount: positive, reference: optionalText(60) })).max(8).default([]),
  allowCredit: z.boolean().optional(),
  /** The total the counter showed; with tax-inclusive prices the invoice is fitted to it. */
  expectedTotal: moneyField.optional(),
  notes: optionalText(500),
});
const returnBody = z.object({
  sessionId: z.uuid().optional(),
  lines: z.array(z.object({ invoiceLineId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero') })).min(1, 'Choose at least one line').max(200),
  reason: z.string().trim().min(3, 'Give a reason').max(300),
  refundMode: z.enum(MODES).default('cash'),
});
const salesQuery = pagingQuery.extend({ sessionId: z.uuid().optional(), locationId: z.uuid().optional(), from: docDate.optional(), to: docDate.optional() });
const itemsQuery = z.object({
  q: z.string().trim().max(100).optional(), locationId: z.uuid().optional(), limit: z.coerce.number().int().min(1).max(60).default(30),
});
const heldBody = z.object({
  sessionId: z.uuid().optional(), locationId: z.uuid().optional(), label: optionalText(60),
  payload: z.record(z.string(), z.unknown()).refine((p) => JSON.stringify(p).length <= 60_000, 'Bill is too large'),
  total: moneyField.optional(),
});
const heldQuery = z.object({ locationId: z.uuid().optional() });

type SessionRow = {
  id: string; company_id: string; location_id: string; user_id: string; status: string; opening_float: number;
  opened_at: Date; closed_at: Date | null; closed_by: string | null; expected: unknown; counted: unknown; difference: unknown; notes: string | null;
};

// ---------------------------------------------------------------- sessions

/** Loads a session the caller may act on: their own, or any when they hold pos.manage. */
async function loadSession(tx: Tx, ctx: RequestContext, id: string, lock = false): Promise<SessionRow> {
  let q = tx.selectFrom('pos_sessions').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const s = await q.executeTakeFirst();
  if (!s || !ctx.canAccessLocation(s.location_id)) throw notFound('Register session');
  if (s.user_id !== ctx.userId && !ctx.can('pos.manage')) throw forbidden('This register session belongs to someone else.');
  return s as SessionRow;
}

/** The caller's open session, by id or by location; locked so a sale and a close cannot overlap. */
async function openSessionFor(tx: Tx, ctx: RequestContext, ref: { sessionId?: string; locationId?: string }): Promise<SessionRow> {
  if (ref.sessionId) {
    const s = await loadSession(tx, ctx, ref.sessionId, true);
    if (s.status !== 'open') throw conflict('This register session is closed. Open a new one to continue.', 'SESSION_CLOSED');
    return s;
  }
  let q = tx.selectFrom('pos_sessions').selectAll().where('company_id', '=', ctx.companyId)
    .where('user_id', '=', ctx.userId).where('status', '=', 'open');
  if (ref.locationId) q = q.where('location_id', '=', ref.locationId);
  const rows = await q.forUpdate().execute();
  if (rows.length === 0) throw conflict('Open a register session before billing.', 'NO_SESSION');
  if (rows.length > 1) throw badRequest('You have more than one open session. Choose one.', { sessionId: 'Choose a session' });
  return rows[0] as SessionRow;
}

interface Figures {
  sales: { count: number; total: number; taxTotal: number; discountTotal: number; itemsSold: number; creditGiven: number };
  payments: Record<Mode, number>;
  refunds: Record<Mode, number>;
  returns: { count: number; total: number };
  cashIn: number;
  cashOut: number;
  expected: Record<Mode, number>;
}

const zeroModes = (): Record<Mode, number> => ({ cash: 0, upi: 0, card: 0, other: 0 });

async function figures(tx: Tx, s: { id: string; opening_float: number }): Promise<Figures> {
  const sales = await tx.selectFrom('pos_sales')
    .select((eb) => [
      eb.fn.countAll<number>().as('count'),
      eb.fn.coalesce(eb.fn.sum<number>('total'), sql<number>`0`).as('total'),
      eb.fn.coalesce(eb.fn.sum<number>('tax_total'), sql<number>`0`).as('tax'),
      eb.fn.coalesce(eb.fn.sum<number>('discount_total'), sql<number>`0`).as('disc'),
      eb.fn.coalesce(eb.fn.sum<number>('item_qty'), sql<number>`0`).as('qty'),
      eb.fn.coalesce(eb.fn.sum<number>('credit_amount'), sql<number>`0`).as('credit'),
    ]).where('session_id', '=', s.id).executeTakeFirstOrThrow();
  const pays = await tx.selectFrom('pos_payments')
    .select(['mode', (eb) => eb.fn.sum<number>('amount').as('amount')]).where('session_id', '=', s.id).groupBy('mode').execute();
  const rets = await tx.selectFrom('pos_returns')
    .select(['refund_mode', (eb) => eb.fn.sum<number>('refund_amount').as('refund'), (eb) => eb.fn.sum<number>('total').as('total'),
      (eb) => eb.fn.countAll<number>().as('count')])
    .where('session_id', '=', s.id).groupBy('refund_mode').execute();
  const moves = await tx.selectFrom('pos_cash_moves').select(['kind', (eb) => eb.fn.sum<number>('amount').as('amount')])
    .where('session_id', '=', s.id).groupBy('kind').execute();

  const payments = zeroModes(), refunds = zeroModes();
  for (const p of pays) payments[p.mode as Mode] = round2(Number(p.amount));
  let retCount = 0, retTotal = 0;
  for (const r of rets) { refunds[r.refund_mode as Mode] = round2(Number(r.refund)); retCount += Number(r.count); retTotal += Number(r.total); }
  const cashIn = round2(Number(moves.find((m) => m.kind === 'in')?.amount ?? 0));
  const cashOut = round2(Number(moves.find((m) => m.kind === 'out')?.amount ?? 0));
  const expected = zeroModes();
  for (const m of MODES) expected[m] = round2(payments[m] - refunds[m]);
  expected.cash = round2(Number(s.opening_float) + expected.cash + cashIn - cashOut);
  return {
    sales: {
      count: Number(sales.count), total: round2(Number(sales.total)), taxTotal: round2(Number(sales.tax)),
      discountTotal: round2(Number(sales.disc)), itemsSold: Number(sales.qty), creditGiven: round2(Number(sales.credit)),
    },
    payments, refunds, returns: { count: retCount, total: round2(retTotal) }, cashIn, cashOut, expected,
  };
}

async function sessionJson(tx: Tx, s: SessionRow) {
  const loc = await tx.selectFrom('locations').select('name').where('id', '=', s.location_id).executeTakeFirst();
  const usr = await tx.selectFrom('users').select('name').where('id', '=', s.user_id).executeTakeFirst();
  const names = { location_name: loc?.name, user_name: usr?.name };
  return {
    id: s.id, locationId: s.location_id, locationName: names?.location_name ?? '', userId: s.user_id, userName: names?.user_name ?? '',
    status: s.status, openingFloat: Number(s.opening_float), openedAt: s.opened_at, closedAt: s.closed_at, notes: s.notes,
  };
}

async function reportOf(tx: Tx, s: SessionRow) {
  const f = await figures(tx, s);
  const moves = await tx.selectFrom('pos_cash_moves as m').innerJoin('users as u', 'u.id', 'm.created_by')
    .select(['m.id', 'm.kind', 'm.amount', 'm.reason', 'm.created_at', 'u.name as by']).where('m.session_id', '=', s.id)
    .orderBy('m.created_at').execute();
  const closed = s.status === 'closed';
  const held = await tx.selectFrom('pos_held_bills').select((eb) => eb.fn.countAll<number>().as('n')).where('session_id', '=', s.id).executeTakeFirstOrThrow();
  return {
    heldCount: Number(held.n),
    kind: closed ? 'Z' : 'X',
    session: await sessionJson(tx, s),
    ...f,
    expected: closed && s.expected ? (s.expected as Record<Mode, number>) : f.expected,
    counted: closed ? s.counted ?? null : null,
    difference: closed ? s.difference ?? null : null,
    cashMoves: moves.map((m) => ({ id: m.id, kind: m.kind, amount: Number(m.amount), reason: m.reason, at: m.created_at, by: m.by })),
  };
}

// ---------------------------------------------------------------- sales

async function walkInParty(tx: Tx, ctx: RequestContext): Promise<{ id: string; name: string }> {
  await sql`select pg_advisory_xact_lock(hashtext(${'pos-walkin:' + ctx.companyId}))`.execute(tx);
  const found = await tx.selectFrom('parties').select(['id', 'name']).where('company_id', '=', ctx.companyId)
    .where('name', '=', WALK_IN).where('type', '=', 'customer').orderBy('created_at').executeTakeFirst();
  if (found) return found;
  const row = await tx.insertInto('parties').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: WALK_IN, gstin: null, state_code: null,
    phone: null, email: null, address: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
  }).returning(['id', 'name']).executeTakeFirstOrThrow();
  await writeAudit(tx, auditOf(ctx), 'party', row.id, 'create', null, { name: WALK_IN, source: 'pos' });
  return row;
}

async function modeAccounts(tx: Tx, ctx: RequestContext) {
  const acc = await systemAccounts(tx, ctx);
  return { cash: acc.cash, bank: acc.bank, receivables: acc.receivables };
}

async function loadSale(tx: Tx, ctx: RequestContext, id: string) {
  const sale = await tx.selectFrom('pos_sales as s')
    .innerJoin('pos_sessions as ss', 'ss.id', 's.session_id')
    .innerJoin('users as u', 'u.id', 's.created_by')
    .innerJoin('parties as p', 'p.id', 's.party_id')
    .selectAll('s').select(['ss.location_id', 'u.name as cashier', 'p.name as party_name', 'p.gstin as party_gstin', 'p.phone as party_phone'])
    .where('s.id', '=', id).where('s.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!sale || !ctx.canAccessLocation(sale.location_id)) throw notFound('Sale');
  const inv = await loadInvoice(tx, ctx, sale.invoice_id);
  const company = await tx.selectFrom('companies').select(['name', 'legal_name', 'gstin', 'address', 'phone', 'pincode', 'invoice_footer', 'upi_id'])
    .where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const pays = await tx.selectFrom('pos_payments').select(['mode', 'amount', 'reference']).where('sale_id', '=', id).orderBy('mode').execute();
  const rets = await tx.selectFrom('pos_returns as r').innerJoin('credit_notes as n', 'n.id', 'r.credit_note_id')
    .select(['r.id', 'n.number', 'r.total', 'r.refund_mode', 'r.refund_amount', 'r.reason', 'r.created_at']).where('r.sale_id', '=', id).orderBy('r.created_at').execute();

  const bands = new Map<number, { rate: number; taxable: number; cgst: number; sgst: number; igst: number }>();
  for (const l of inv.lines) {
    const b = bands.get(l.gstRate) ?? { rate: l.gstRate, taxable: 0, cgst: 0, sgst: 0, igst: 0 };
    b.taxable = round2(b.taxable + l.taxableValue); b.cgst = round2(b.cgst + l.cgst); b.sgst = round2(b.sgst + l.sgst); b.igst = round2(b.igst + l.igst);
    bands.set(l.gstRate, b);
  }
  return {
    id: sale.id, sessionId: sale.session_id, invoiceId: sale.invoice_id, number: inv.number, date: inv.invoiceDate, createdAt: sale.created_at,
    locationId: inv.locationId, locationName: inv.locationName, cashier: sale.cashier,
    company: {
      name: company.name, legalName: company.legal_name, gstin: company.gstin, address: company.address, phone: company.phone,
      pincode: company.pincode, footer: company.invoice_footer, upiId: company.upi_id,
    },
    customer: { id: sale.party_id, name: sale.party_name, gstin: sale.party_gstin, phone: sale.party_phone, isWalkIn: sale.party_name === WALK_IN },
    lines: inv.lines.map((l) => ({
      invoiceLineId: l.id, itemId: l.itemId, description: l.description, hsnCode: l.hsnCode, qty: l.qty, unit: l.unit, rate: l.rate,
      discountPct: l.discountPct, gstRate: l.gstRate, taxableValue: l.taxableValue, lineTotal: l.lineTotal, returnedQty: l.returnedQty,
    })),
    taxSummary: [...bands.values()].sort((a, b) => a.rate - b.rate),
    subtotal: inv.subtotal, cgst: inv.cgst, sgst: inv.sgst, igst: inv.igst, taxTotal: inv.taxTotal, roundOff: inv.roundOff,
    discountTotal: Number(sale.discount_total), billDiscount: Number(sale.bill_discount), total: Number(sale.total),
    payments: pays.map((p) => ({ mode: p.mode, amount: Number(p.amount), reference: p.reference })),
    tenderedCash: Number(sale.tendered_cash), changeDue: Number(sale.change_due), creditAmount: Number(sale.credit_amount),
    status: inv.status,
    returns: rets.map((r) => ({
      id: r.id, creditNoteNumber: r.number, total: Number(r.total), refundMode: r.refund_mode, refundAmount: Number(r.refund_amount),
      reason: r.reason, createdAt: r.created_at,
    })),
  };
}

/** Whether counter prices include GST: the company's choice, else the default for its business type. */
async function pricesIncludeTax(tx: Tx, ctx: RequestContext): Promise<boolean> {
  const c = await tx.selectFrom('companies').select(['pos_prices_include_tax', 'business_type']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  if (c.pos_prices_include_tax !== null && c.pos_prices_include_tax !== undefined) return c.pos_prices_include_tax;
  return BUSINESS_TYPES.find((t) => t.id === c.business_type)?.modules.includes('pos') ?? false;
}

/** Number prefix for POS bills, set in POS settings. */
async function posPrefix(tx: Tx, ctx: RequestContext): Promise<string> {
  const c = await tx.selectFrom('companies').select('pos_invoice_prefix').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  return c.pos_invoice_prefix;
}

const r2 = (n: number) => Math.round(n * 100) / 100;

/** Finds a 2-decimal rate and discount % whose taxable value is exactly `targetP` paise. */
function fitLine(qty: number, targetP: number, gstRate: number): { rate: number; discountPct: number } | null {
  if (targetP <= 0) return { rate: 0, discountPct: 0 };
  const taxableP = (rate: number, d: number) =>
    Math.round(computeGst('x', 'x', [{ qty, rate, discountPct: d, gstRate }]).lines[0]!.taxableValue * 100);
  const base = r2(targetP / 100 / qty);
  for (const k of [0, 1, -1, 2, -2, 3, -3, 5, -5]) {
    const rate = r2(base + k * 0.01);
    if (rate <= 0 || qty * rate * 100 < targetP - 0.5) continue;
    const d0 = r2((1 - targetP / (qty * rate * 100)) * 100);
    for (const dd of [0, 0.01, -0.01, 0.02, -0.02, 0.03, -0.03]) {
      const d = r2(d0 + dd);
      if (d < 0 || d > 100) continue;
      if (taxableP(rate, d) === targetP) return { rate, discountPct: d };
    }
  }
  return null;
}

/**
 * Tax-inclusive counter bill: the customer sees line amounts that include GST. Each line's ex-tax rate and
 * discount are back-calculated so the invoice total equals the shown total exactly; spare paise land in round-off.
 */
export function fitInclusive(
  sellerState: string, placeState: string,
  items: { itemId: string; qty: number; rateIncl: number; discountPct: number; gstRate: number }[],
  bill: z.infer<typeof saleBody>['billDiscount'], expectedTotal: number | undefined,
) {
  const raw = items.map((l) => l.qty * l.rateIncl * (1 - l.discountPct / 100));
  const sumRaw = raw.reduce((a, b) => a + b, 0);
  let billPct = 0;
  if (bill && bill.value > 0 && sumRaw > 0) {
    if (bill.type === 'pct') {
      if (bill.value > 100) throw badRequest('Discount cannot be more than 100%.', { billDiscount: 'Over 100%' });
      billPct = bill.value;
    } else {
      if (bill.value > sumRaw + 0.005) throw badRequest('Discount is more than the bill.', { billDiscount: 'More than the bill' });
      billPct = (bill.value / sumRaw) * 100;
    }
  }
  const lineP = raw.map((v) => Math.round(v * (1 - billPct / 100) * 100));
  const sumP = lineP.reduce((a, b) => a + b, 0);
  let totalP = Math.floor((sumP + 50) / 100) * 100;
  if (expectedTotal !== undefined) {
    if (Math.abs(expectedTotal * 100 - sumP) > 100) throw badRequest('The bill total changed. Refresh prices and try again.', { expectedTotal: 'Does not match the lines' });
    totalP = Math.round(expectedTotal * 100);
  }
  const targets = items.map((l, i) => Math.round((lineP[i]! * 100) / (100 + l.gstRate)));
  const cache = new Map<string, { rate: number; discountPct: number } | null>();
  const fit = (i: number, t: number) => {
    const key = `${i}:${t}`;
    if (!cache.has(key)) cache.set(key, fitLine(items[i]!.qty, t, items[i]!.gstRate));
    return cache.get(key)!;
  };
  const deltas = [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6];
  for (const delta of deltas) {
    for (let j = 0; j < (delta === 0 ? 1 : items.length); j++) {
      const t = targets.map((x, i) => (i === j ? x + delta : x));
      const fits = t.map((x, i) => fit(i, x));
      if (fits.some((f) => f === null)) continue;
      const g = computeGst(sellerState, placeState, items.map((l, i) => ({ qty: l.qty, rate: fits[i]!.rate, discountPct: fits[i]!.discountPct, gstRate: l.gstRate })));
      if (Math.round(g.total * 100) === totalP) {
        return {
          lines: items.map((l, i) => ({ itemId: l.itemId, qty: l.qty, rate: fits[i]!.rate, discountPct: fits[i]!.discountPct })),
          total: totalP / 100, billAmount: r2((sumRaw * billPct) / 100), sumIncl: sumP / 100,
          mrpGross: r2(items.reduce((s, l) => s + l.qty * l.rateIncl, 0)),
        };
      }
    }
  }
  throw badRequest('Could not fit this bill to its total. Change a quantity or discount slightly.', { lines: 'No exact fit' });
}

async function createSale(ctx: RequestContext, tx: Tx, body: z.infer<typeof saleBody>) {
  if (!body.sessionId && !body.locationId) throw badRequest('Say which register session this sale belongs to.', { sessionId: 'Required' });
  const session = await openSessionFor(tx, ctx, body);
  if (session.user_id !== ctx.userId && !ctx.can('pos.manage')) throw forbidden();
  const location = await getLocation(tx, ctx, session.location_id);

  // Party: named customer, or the shared walk-in customer.
  let party: { id: string; name: string; state_code?: string | null };
  let named = false;
  if (body.partyId) {
    const p = await tx.selectFrom('parties').select(['id', 'name', 'type', 'state_code']).where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!p) throw badRequest('Customer not found.', { partyId: 'Not found' });
    if (p.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });
    party = p; named = p.name !== WALK_IN;
  } else {
    party = await walkInParty(tx, ctx);
  }
  if (body.allowCredit && !named) throw badRequest('Credit needs a named customer.', { partyId: 'Choose a customer' });

  // Effective line discount = line discount combined with the bill discount.
  const ids = [...new Set(body.lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').select(['id', 'sale_price', 'gst_rate']).where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const price = new Map(items.map((i) => [i.id, Number(i.sale_price)]));
  const afterLine = body.lines.map((l) => {
    const rate = l.rate ?? price.get(l.itemId);
    if (rate === undefined) throw badRequest('Item not found.', { lines: 'Item not found' });
    return l.qty * rate * (1 - (l.discountPct ?? 0) / 100);
  });
  const gross = afterLine.reduce((a, b) => a + b, 0);
  let billPct = 0;
  if (body.billDiscount && body.billDiscount.value > 0 && gross > 0) {
    if (body.billDiscount.type === 'pct') {
      if (body.billDiscount.value > 100) throw badRequest('Discount cannot be more than 100%.', { billDiscount: 'Over 100%' });
      billPct = body.billDiscount.value;
    } else {
      if (body.billDiscount.value > gross + 0.005) throw badRequest('Discount is more than the bill.', { billDiscount: 'More than the bill' });
      billPct = (body.billDiscount.value / gross) * 100;
    }
  }
  const inclusive = await pricesIncludeTax(tx, ctx);
  let lines: { itemId: string; qty: number; rate: number | undefined; discountPct: number }[];
  let fitted: ReturnType<typeof fitInclusive> | null = null;
  if (inclusive) {
    const gst = new Map(items.map((i) => [i.id, Number(i.gst_rate)]));
    fitted = fitInclusive(location.state_code, party.state_code ?? location.state_code, body.lines.map((l) => ({
      itemId: l.itemId, qty: l.qty, rateIncl: l.rate ?? price.get(l.itemId)!, discountPct: l.discountPct ?? 0, gstRate: gst.get(l.itemId)!,
    })), body.billDiscount, body.expectedTotal);
    lines = fitted.lines;
  } else {
    lines = body.lines.map((l) => {
      const eff = 100 * (1 - (1 - (l.discountPct ?? 0) / 100) * (1 - billPct / 100));
      return { itemId: l.itemId, qty: l.qty, rate: l.rate, discountPct: Math.min(100, Math.round(eff * 100) / 100) };
    });
  }

  const inv = await createInvoice(ctx, tx, {
    locationId: location.id, partyId: party.id, notes: body.notes ?? 'Counter sale', lines: lines.map((l, i) => ({ ...l, ...whExtras(body.lines[i]) })),
  } as never, { series: { key: 'pos_invoice', prefix: await posPrefix(tx, ctx) }, itemPriceOnly: true });
  const total = Number(inv.total);
  if (fitted && Math.abs(total - fitted.total) > 0.001) throw conflict('The bill total could not be matched. Try again.', 'TOTAL_MISMATCH');

  // Payments: non-cash is exact money; cash may be tendered above what is due, and the rest is change.
  const sum = (m: Mode) => round2(body.payments.filter((p) => p.mode === m).reduce((s, p) => s + p.amount, 0));
  const nonCash = round2(sum('upi') + sum('card') + sum('other'));
  if (nonCash > total + 0.001) throw badRequest('UPI, card and other payments are more than the bill.', { payments: 'More than the bill total' });
  const tendered = sum('cash');
  const cashDue = round2(total - nonCash);
  const cashApplied = round2(Math.min(tendered, Math.max(cashDue, 0)));
  const change = round2(tendered - cashApplied);
  const paid = round2(nonCash + cashApplied);
  const short = round2(total - paid);
  if (short > 0.001 && !(named && body.allowCredit)) {
    throw badRequest(`Payment is short by ₹${short.toFixed(2)}.`, { payments: `Short by ${short.toFixed(2)}` });
  }
  const credit = short > 0.001 ? short : 0;

  const accounts = await modeAccounts(tx, ctx);
  const sale = await tx.insertInto('pos_sales').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, session_id: session.id, invoice_id: inv.id, party_id: party.id, total,
    tax_total: inv.taxTotal,
    discount_total: fitted ? round2(fitted.mrpGross - fitted.sumIncl) : round2(inv.lines.reduce((s, l) => s + l.qty * l.rate, 0) - Number(inv.subtotal)),
    bill_discount: fitted ? fitted.billAmount : billPct > 0 ? round2((gross * billPct) / 100) : 0,
    item_qty: inv.lines.reduce((s, l) => s + l.qty, 0), tendered_cash: tendered, change_due: change, credit_amount: credit, created_by: ctx.userId,
  }).returning('id').executeTakeFirstOrThrow();

  // One receipt per mode, allocated to this bill. Cash is recorded net of change.
  const perMode: { mode: Mode; amount: number; reference: string | null }[] = [];
  if (cashApplied > 0) perMode.push({ mode: 'cash', amount: cashApplied, reference: null });
  for (const m of ['upi', 'card', 'other'] as const) {
    const amt = sum(m);
    if (amt > 0) perMode.push({ mode: m, amount: amt, reference: body.payments.find((p) => p.mode === m && p.reference)?.reference ?? null });
  }
  for (const p of perMode) {
    const receipt = await createPayment(ctx, tx, {
      kind: 'receipt', partyId: party.id, accountId: p.mode === 'cash' ? accounts.cash : accounts.bank,
      mode: p.mode === 'other' ? 'bank' : p.mode, amount: p.amount, reference: p.reference ?? undefined,
      notes: `Counter sale ${inv.number}`, allocations: [{ docId: inv.id, amount: p.amount }],
    } as never);
    await tx.insertInto('pos_payments').values({
      tenant_id: ctx.tenantId, sale_id: sale.id, session_id: session.id, mode: p.mode, amount: p.amount,
      payment_id: receipt.id, reference: p.reference,
    }).execute();
  }
  await writeAudit(tx, auditOf(ctx), 'pos_sale', sale.id, 'create', null, { invoice: inv.number, total, sessionId: session.id });
  return loadSale(tx, ctx, sale.id);
}

async function createReturn(ctx: RequestContext, tx: Tx, saleId: string, body: z.infer<typeof returnBody>) {
  const sale = await tx.selectFrom('pos_sales as s').innerJoin('invoices as v', 'v.id', 's.invoice_id')
    .select(['s.id', 's.invoice_id', 's.party_id', 'v.location_id', 'v.number'])
    .where('s.id', '=', saleId).where('s.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!sale || !ctx.canAccessLocation(sale.location_id)) throw notFound('Sale');
  const session = await openSessionFor(tx, ctx, { sessionId: body.sessionId, locationId: body.sessionId ? undefined : sale.location_id });
  if (session.location_id !== sale.location_id) throw conflict('This bill was made at another location. Open a session there to return it.', 'WRONG_LOCATION');

  const note = await createCreditNote(ctx, tx, {
    invoiceId: sale.invoice_id, reason: body.reason, restock: true, lines: body.lines,
  } as never);
  const cn = await tx.selectFrom('credit_notes').select(['id', 'total', 'applied_amount']).where('id', '=', note.id).executeTakeFirstOrThrow();
  const total = Number(cn.total);
  const refund = round2(total - Number(cn.applied_amount));
  const ret = await tx.insertInto('pos_returns').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, session_id: session.id, sale_id: sale.id, credit_note_id: cn.id, total,
    refund_mode: body.refundMode, refund_amount: refund, reason: body.reason, created_by: ctx.userId,
  }).returning('id').executeTakeFirstOrThrow();

  if (refund > 0) {
    // The credit note left the customer with a credit balance; paying it out clears the receivable.
    const a = await modeAccounts(tx, ctx);
    await postJournal(tx, auditOf(ctx), {
      date: todayIst(), voucherType: 'journal', voucherId: ret.id, number: null,
      narration: `Counter refund ${note.number} against ${sale.number} by ${body.refundMode}`,
      lines: [
        { accountId: a.receivables, amount: refund, partyId: sale.party_id, locationId: sale.location_id },
        { accountId: body.refundMode === 'cash' ? a.cash : a.bank, amount: -refund, locationId: sale.location_id },
      ],
    });
  }
  await writeAudit(tx, auditOf(ctx), 'pos_return', ret.id, 'create', null, { creditNote: note.number, total, refund, mode: body.refundMode });
  return { ...(await loadSale(tx, ctx, sale.id)), returned: { creditNoteId: cn.id, creditNoteNumber: note.number, total, refundAmount: refund, refundMode: body.refundMode } };
}

// ---------------------------------------------------------------- routes

export async function posRoutes(app: FastifyInstance) {
  const use = (ctx: RequestContext) => ctx.require('pos.use', 'pos.manage');

  // ---- sessions
  app.get('/pos/sessions/current', async (req) => {
    const ctx = req.ctx; use(ctx);
    const { locationId } = parse(heldQuery, req.query);
    return ctx.tx(async (tx) => {
      let q = tx.selectFrom('pos_sessions').selectAll().where('company_id', '=', ctx.companyId)
        .where('user_id', '=', ctx.userId).where('status', '=', 'open').orderBy('opened_at', 'desc');
      if (locationId) q = q.where('location_id', '=', locationId);
      const rows = await q.execute();
      const mine = rows.filter((r) => ctx.canAccessLocation(r.location_id)) as SessionRow[];
      return { session: mine[0] ? await sessionJson(tx, mine[0]) : null, openCount: mine.length };
    });
  });

  app.post('/pos/sessions', async (req, reply) => {
    const ctx = req.ctx; use(ctx);
    const body = parse(openBody, req.body);
    ctx.requireLocation(body.locationId);
    const out = await ctx.tx(async (tx) => {
      const loc = await getLocation(tx, ctx, body.locationId);
      if (!loc.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
      const existing = await tx.selectFrom('pos_sessions').select('id').where('company_id', '=', ctx.companyId)
        .where('location_id', '=', loc.id).where('user_id', '=', ctx.userId).where('status', '=', 'open').executeTakeFirst();
      if (existing) throw conflict('You already have an open session at this location.', 'SESSION_OPEN', { sessionId: existing.id });
      const row = await tx.insertInto('pos_sessions').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: loc.id, user_id: ctx.userId,
        opening_float: body.openingFloat, notes: body.notes ?? null, closed_at: null, closed_by: null,
        expected: null, counted: null, difference: null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'pos_session', row.id, 'open', null, { locationId: loc.id, openingFloat: body.openingFloat });
      return sessionJson(tx, row as SessionRow);
    });
    return reply.status(201).send(out);
  });

  app.get('/pos/sessions', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(sessionsQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('pos_sessions as s').innerJoin('users as u', 'u.id', 's.user_id').innerJoin('locations as l', 'l.id', 's.location_id')
        .select(['s.id', 's.location_id', 's.user_id', 's.status', 's.opening_float', 's.opened_at', 's.closed_at', 's.difference', 'l.name as location_name', 'u.name as user_name'])
        .where('s.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('s.location_id', 'in', scope);
      if (!ctx.can('pos.manage') || q.mine === 'true') base = base.where('s.user_id', '=', ctx.userId);
      if (q.status) base = base.where('s.status', '=', q.status);
      if (q.locationId) base = base.where('s.location_id', '=', q.locationId);
      if (q.from) base = base.where('s.opened_at', '>=', sql<Date>`${q.from}::date`);
      if (q.to) base = base.where('s.opened_at', '<', sql<Date>`(${q.to}::date + 1)`);
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('s.opened_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        total: Number(total),
        data: rows.map((r) => ({
          id: r.id, locationId: r.location_id, locationName: r.location_name, userId: r.user_id, userName: r.user_name, status: r.status,
          openingFloat: Number(r.opening_float), openedAt: r.opened_at, closedAt: r.closed_at, difference: r.difference ?? null,
        })),
      };
    });
  });

  app.get<{ Params: { id: string } }>('/pos/sessions/:id', async (req) => {
    const ctx = req.ctx; use(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => reportOf(tx, await loadSession(tx, ctx, id)));
  });
  // The X report while open, the Z report once closed.
  app.get<{ Params: { id: string } }>('/pos/sessions/:id/report', async (req) => {
    const ctx = req.ctx; use(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => reportOf(tx, await loadSession(tx, ctx, id)));
  });

  app.post<{ Params: { id: string } }>('/pos/sessions/:id/cash-moves', async (req, reply) => {
    const ctx = req.ctx; use(ctx);
    const id = parse(z.uuid(), req.params.id);
    const body = parse(cashMoveBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const s = await loadSession(tx, ctx, id, true);
      if (s.status !== 'open') throw conflict('This register session is closed.', 'SESSION_CLOSED');
      if (body.kind === 'out') {
        const f = await figures(tx, s);
        if (body.amount > f.expected.cash + 0.001) {
          throw conflict(`Only ₹${f.expected.cash.toFixed(2)} cash is in the drawer.`, 'INSUFFICIENT_CASH', { available: f.expected.cash });
        }
      }
      const row = await tx.insertInto('pos_cash_moves').values({
        tenant_id: ctx.tenantId, session_id: s.id, kind: body.kind, amount: body.amount, reason: body.reason, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'pos_session', s.id, `cash_${body.kind}`, null, { amount: body.amount, reason: body.reason });
      return { id: row.id, kind: row.kind, amount: Number(row.amount), reason: row.reason, at: row.created_at, by: ctx.userName };
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/pos/sessions/:id/close', async (req) => {
    const ctx = req.ctx; use(ctx);
    const id = parse(z.uuid(), req.params.id);
    const body = parse(closeBody, req.body);
    return ctx.tx(async (tx) => {
      const s = await loadSession(tx, ctx, id, true);
      if (s.status !== 'open') throw conflict('This register session is already closed.', 'SESSION_CLOSED');
      const held = await tx.selectFrom('pos_held_bills').select((eb) => eb.fn.countAll<number>().as('n')).where('session_id', '=', s.id).executeTakeFirstOrThrow();
      if (Number(held.n) > 0 && !body.confirmHeld) {
        throw conflict(`${held.n} bill${Number(held.n) === 1 ? ' is' : 's are'} still on hold from this session.`, 'HELD_BILLS', { count: Number(held.n) });
      }
      const f = await figures(tx, s);
      const counted: Partial<Record<Mode, number>> = {};
      const difference: Partial<Record<Mode, number>> = {};
      for (const m of MODES) {
        const c = body.counted[m];
        if (c === undefined) continue;
        counted[m] = c;
        difference[m] = round2(c - f.expected[m]);
      }
      await tx.updateTable('pos_sessions').set({
        status: 'closed', closed_at: new Date(), closed_by: ctx.userId, expected: JSON.stringify(f.expected) as never,
        counted: JSON.stringify(counted) as never, difference: JSON.stringify(difference) as never,
        notes: body.notes ?? s.notes,
      }).where('id', '=', id).execute();
      // Bills still on hold belong to a closed session; they stay available to other counters at the location.
      await writeAudit(tx, auditOf(ctx), 'pos_session', id, 'close', { status: 'open' }, { expected: f.expected, counted, difference });
      return reportOf(tx, await loadSession(tx, ctx, id));
    });
  });

  // ---- settings
  app.get('/pos/settings', async (req) => {
    const ctx = req.ctx; use(ctx);
    return ctx.tx(async (tx) => ({ pricesIncludeTax: await pricesIncludeTax(tx, ctx), invoicePrefix: await posPrefix(tx, ctx) }));
  });
  app.put('/pos/settings', async (req) => {
    const ctx = req.ctx; ctx.require('pos.manage', 'company.manage');
    const body = parse(z.object({
      pricesIncludeTax: z.boolean().nullable().optional(),
      invoicePrefix: z.string().trim().toUpperCase().regex(/^[A-Z0-9-]{1,8}$/, 'Use 1 to 8 letters, digits or hyphens').optional(),
    }), req.body);
    return ctx.tx(async (tx) => {
      const patch: { pos_prices_include_tax?: boolean | null; pos_invoice_prefix?: string } = {};
      if (body.pricesIncludeTax !== undefined) patch.pos_prices_include_tax = body.pricesIncludeTax;
      if (body.invoicePrefix !== undefined) patch.pos_invoice_prefix = body.invoicePrefix;
      if (Object.keys(patch).length) await tx.updateTable('companies').set(patch).where('id', '=', ctx.companyId).execute();
      await writeAudit(tx, auditOf(ctx), 'company', ctx.companyId, 'pos_settings', null, body);
      return { pricesIncludeTax: await pricesIncludeTax(tx, ctx), invoicePrefix: await posPrefix(tx, ctx) };
    });
  });

  // ---- items
  app.get('/pos/items', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(itemsQuery, req.query);
    return ctx.tx(async (tx) => {
      const locationId = await counterLocation(tx, ctx, q.locationId);
      const term = q.q ?? '';
      let rows: ItemRow[] = [];
      let exact = false;
      if (term) {
        rows = await tx.selectFrom('items').select(ITEM_COLS).where('company_id', '=', ctx.companyId).where('is_active', '=', true)
          .where((eb) => eb.or([eb('barcode', '=', term), eb(sql`lower(sku)`, '=', term.toLowerCase())])).limit(5).execute();
        exact = rows.length > 0;
        if (!exact) {
          const like = likeTerm(term);
          rows = await tx.selectFrom('items').select(ITEM_COLS).where('company_id', '=', ctx.companyId).where('is_active', '=', true)
            .where((eb) => eb.or([eb('name', 'ilike', like), eb('sku', 'ilike', like), eb('barcode', 'ilike', like)]))
            .orderBy(sql`(lower(name) like ${term.toLowerCase().replace(/[\\%_]/g, '') + '%'}) desc`).orderBy('name').limit(q.limit).execute();
        }
      } else {
        rows = await tx.selectFrom('items').select(ITEM_COLS).where('company_id', '=', ctx.companyId).where('is_active', '=', true)
          .orderBy('name').limit(q.limit).execute();
      }
      return { exact, data: await withStock(tx, ctx, locationId, rows) };
    });
  });

  app.get('/pos/items/frequent', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(itemsQuery, req.query);
    return ctx.tx(async (tx) => {
      const locationId = await counterLocation(tx, ctx, q.locationId);
      const top = await tx.selectFrom('invoice_lines as il').innerJoin('invoices as v', 'v.id', 'il.invoice_id')
        .select(['il.item_id', (eb) => eb.fn.sum<number>('il.qty').as('qty')])
        .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted').where('v.location_id', '=', locationId)
        .where('v.created_at', '>=', sql<Date>`now() - interval '60 days'`).groupBy('il.item_id').orderBy('qty', 'desc').limit(q.limit).execute();
      let rows: ItemRow[] = [];
      if (top.length) {
        const found = await tx.selectFrom('items').select(ITEM_COLS).where('company_id', '=', ctx.companyId).where('is_active', '=', true)
          .where('id', 'in', top.map((t) => t.item_id)).execute();
        rows = top.map((t) => found.find((f) => f.id === t.item_id)).filter((x): x is ItemRow => !!x);
      }
      if (rows.length < Math.min(q.limit, 12)) {
        const have = rows.map((r) => r.id);
        let more = tx.selectFrom('items').select(ITEM_COLS).where('company_id', '=', ctx.companyId).where('is_active', '=', true);
        if (have.length) more = more.where('id', 'not in', have);
        rows = [...rows, ...await more.orderBy('name').limit(q.limit - rows.length).execute()];
      }
      return { data: await withStock(tx, ctx, locationId, rows) };
    });
  });

  // ---- sales
  app.post('/pos/sales', async (req, reply) => {
    const ctx = req.ctx; use(ctx);
    ctx.require('invoices.create', 'pos.use');
    const body = parse(saleBody, req.body);
    const sale = await ctx.tx((tx) => createSale(ctx, tx, body));
    return reply.status(201).send(sale);
  });

  app.get('/pos/sales', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(salesQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('pos_sales as s').innerJoin('pos_sessions as ss', 'ss.id', 's.session_id')
        .innerJoin('invoices as v', 'v.id', 's.invoice_id').innerJoin('parties as p', 'p.id', 's.party_id')
        .select(['s.id', 's.session_id', 's.total', 's.created_at', 's.credit_amount', 'v.number', 'v.status', 'p.name as party_name', 'ss.location_id'])
        .where('s.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('ss.location_id', 'in', scope);
      if (q.sessionId) base = base.where('s.session_id', '=', q.sessionId);
      if (q.locationId) base = base.where('ss.location_id', '=', q.locationId);
      if (q.from) base = base.where('s.created_at', '>=', sql<Date>`${q.from}::date`);
      if (q.to) base = base.where('s.created_at', '<', sql<Date>`(${q.to}::date + 1)`);
      if (q.q) base = base.where((eb) => eb.or([eb('v.number', 'ilike', likeTerm(q.q!)), eb('p.name', 'ilike', likeTerm(q.q!))]));
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('s.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        total: Number(total),
        data: rows.map((r) => ({
          id: r.id, sessionId: r.session_id, number: r.number, status: r.status, total: Number(r.total), creditAmount: Number(r.credit_amount),
          customerName: r.party_name, createdAt: r.created_at,
        })),
      };
    });
  });

  app.get<{ Params: { id: string } }>('/pos/sales/:id', async (req) => {
    const ctx = req.ctx; use(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadSale(tx, ctx, id));
  });

  app.post<{ Params: { id: string } }>('/pos/sales/:id/return', async (req, reply) => {
    const ctx = req.ctx; use(ctx);
    ctx.require('credit_notes.create', 'pos.use');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(returnBody, req.body);
    const out = await ctx.tx((tx) => createReturn(ctx, tx, id, body));
    return reply.status(201).send(out);
  });

  // ---- held bills
  app.post('/pos/held', async (req, reply) => {
    const ctx = req.ctx; use(ctx);
    const body = parse(heldBody, req.body);
    if (!body.sessionId && !body.locationId) throw badRequest('Say which register session this bill is held on.', { sessionId: 'Required' });
    const out = await ctx.tx(async (tx) => {
      const s = await openSessionFor(tx, ctx, body);
      const row = await tx.insertInto('pos_held_bills').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: s.location_id, session_id: s.id,
        label: body.label ?? null, payload: JSON.stringify(body.payload) as never, total: body.total ?? 0, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      return heldJson(row, ctx.userName);
    });
    return reply.status(201).send(out);
  });

  app.get('/pos/held', async (req) => {
    const ctx = req.ctx; use(ctx);
    const { locationId } = parse(heldQuery, req.query);
    return ctx.tx(async (tx) => {
      let q = tx.selectFrom('pos_held_bills as h').innerJoin('users as u', 'u.id', 'h.created_by')
        .select(['h.id', 'h.location_id', 'h.label', 'h.total', 'h.created_at', 'h.payload', 'u.name as by'])
        .where('h.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) q = q.where('h.location_id', 'in', scope);
      if (locationId) q = q.where('h.location_id', '=', locationId);
      const rows = await q.orderBy('h.created_at').limit(100).execute();
      return { data: rows.map((r) => heldJson(r, r.by)) };
    });
  });

  // Resume: hands back the bill and removes it, so two counters cannot both pick it up.
  app.post<{ Params: { id: string } }>('/pos/held/:id/resume', async (req) => {
    const ctx = req.ctx; use(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const row = await tx.selectFrom('pos_held_bills').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Held bill');
      await tx.deleteFrom('pos_held_bills').where('id', '=', id).execute();
      const by = await tx.selectFrom('users').select('name').where('id', '=', row.created_by).executeTakeFirst();
      return heldJson(row, by?.name ?? '');
    });
  });

  app.delete<{ Params: { id: string } }>('/pos/held/:id', async (req, reply) => {
    const ctx = req.ctx; use(ctx);
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const row = await tx.selectFrom('pos_held_bills').select(['id', 'location_id']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Held bill');
      await tx.deleteFrom('pos_held_bills').where('id', '=', id).execute();
    });
    return reply.status(204).send();
  });
}

// ---------------------------------------------------------------- helpers

const ITEM_COLS = ['id', 'name', 'sku', 'barcode', 'unit', 'gst_rate', 'sale_price', 'track_stock', 'hsn_code'] as const;
type ItemRow = { id: string; name: string; sku: string | null; barcode: string | null; unit: string; gst_rate: number; sale_price: number; track_stock: boolean; hsn_code: string | null };

function heldJson(r: { id: string; location_id: string; label: string | null; total: number; created_at: Date; payload: unknown }, by: string) {
  return { id: r.id, locationId: r.location_id, label: r.label, total: Number(r.total), createdAt: r.created_at, createdBy: by, payload: r.payload };
}

/** Location for lookups: the one asked for, else the caller's open session's. */
async function counterLocation(tx: Tx, ctx: RequestContext, asked?: string): Promise<string> {
  if (asked) { ctx.requireLocation(asked); return asked; }
  const s = await tx.selectFrom('pos_sessions').select('location_id').where('company_id', '=', ctx.companyId)
    .where('user_id', '=', ctx.userId).where('status', '=', 'open').orderBy('opened_at', 'desc').executeTakeFirst();
  if (!s) throw conflict('Open a register session before billing.', 'NO_SESSION');
  return s.location_id;
}

async function withStock(tx: Tx, ctx: RequestContext, locationId: string, rows: ItemRow[]) {
  const ids = rows.map((r) => r.id);
  const onHand = new Map<string, number>();
  if (ids.length) {
    const sums = await tx.selectFrom('stock_moves').select(['item_id', (eb) => eb.fn.sum<number>('qty').as('qty')])
      .where('company_id', '=', ctx.companyId).where('location_id', '=', locationId).where('item_id', 'in', ids).groupBy('item_id').execute();
    for (const s of sums) onHand.set(s.item_id, Number(s.qty));
  }
  const out = [];
  for (const r of rows) {
    let stock: number | null = null;
    if (r.track_stock) {
      const reserved = await reservedQty(tx, ctx.companyId, locationId, r.id);
      stock = Math.round(((onHand.get(r.id) ?? 0) - reserved) * 1000) / 1000;
    }
    out.push({
      id: r.id, name: r.name, sku: r.sku, barcode: r.barcode, unit: r.unit, price: Number(r.sale_price), gstRate: Number(r.gst_rate),
      hsnCode: r.hsn_code, trackStock: r.track_stock, stock,
    });
  }
  return out;
}

documentRoute('POST', '/pos/sessions', { body: openBody });
documentRoute('POST', '/pos/sessions/:id/cash-moves', { body: cashMoveBody });
documentRoute('POST', '/pos/sessions/:id/close', { body: closeBody });
documentRoute('POST', '/pos/sales', { body: saleBody });
documentRoute('POST', '/pos/sales/:id/return', { body: returnBody });
documentRoute('POST', '/pos/held', { body: heldBody });
