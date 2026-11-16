import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { locationQty, lockItems } from '../accounting/costing.ts';
import { postJournal, reverseVoucher, type JLine } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { documentRoute } from '../lib/openapi.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

/**
 * Splits `total` over `weights` in proportion, to the paise. The line with the largest weight takes
 * the rounding remainder, so the parts always add up to the total.
 */
export function allocate(total: number, weights: number[]): number[] {
  const sum = weights.reduce((s, w) => s + w, 0);
  if (!weights.length || sum <= 0) return weights.map(() => 0);
  const paise = weights.map((w) => Math.floor((Math.round(total * 100) * w) / sum + 1e-9));
  const remainder = Math.round(total * 100) - paise.reduce((s, p) => s + p, 0);
  let big = 0;
  weights.forEach((w, i) => { if (w > weights[big]!) big = i; });
  paise[big]! += remainder;
  return paise.map((p) => p / 100);
}

const chargeBody = z.object({
  kind: z.enum(['freight', 'customs_duty', 'insurance', 'clearing', 'handling', 'other']),
  description: optionalText(200),
  amount: moneyField,
  igstAmount: moneyField.optional(),
  sourceType: z.enum(['direct', 'expense', 'vendor_bill', 'journal']).optional(),
  sourceId: z.uuid().nullable().optional(),
  creditAccountId: z.uuid().nullable().optional(),
  partyId: z.uuid().nullable().optional(),
});
const body = z.object({
  voucherDate: docDate.optional(),
  basis: z.enum(['value', 'qty', 'weight']),
  notes: optionalText(1000),
  docs: z.array(z.object({ docType: z.enum(['purchase', 'grn']), docId: z.uuid() })).min(1, 'Choose a bill or receipt').max(20, 'At most 20 documents'),
  weights: z.array(z.object({ docLineId: z.uuid(), weight: qtyField.refine((v) => v >= 0, 'Cannot be negative') })).max(500).optional(),
  charges: z.array(chargeBody).min(1, 'Add a charge').max(20, 'At most 20 charges'),
});
type Body = z.infer<typeof body>;
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(['posted', 'cancelled']).optional(), from: dateField.optional(), to: dateField.optional(),
});
const reportQuery = z.object({ from: dateField.optional(), to: dateField.optional(), itemId: z.uuid().optional(), docId: z.uuid().optional() });

interface SrcLine {
  docType: 'purchase' | 'grn'; docId: string; docLineId: string; docNumber: string; docDate: string;
  itemId: string; itemName: string; locationId: string; qty: number; baseValue: number;
}

async function loadSourceLines(tx: Tx, ctx: RequestContext, docs: Body['docs']): Promise<SrcLine[]> {
  const out: SrcLine[] = [];
  const seen = new Set<string>();
  for (const d of docs) {
    if (seen.has(d.docId)) throw badRequest('The same document is listed twice.', { docs: 'Duplicate' });
    seen.add(d.docId);
    if (d.docType === 'purchase') {
      const head = await tx.selectFrom('purchases').select(['id', 'number', 'bill_date', 'location_id', 'status'])
        .where('id', '=', d.docId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!head || !ctx.canAccessLocation(head.location_id)) throw notFound('Purchase bill');
      if (head.status !== 'posted') throw conflict(`Bill ${head.number} is cancelled.`, 'INVALID_STATE');
      const rows = await tx.selectFrom('purchase_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
        .select(['l.id', 'l.item_id', 'l.qty', 'l.taxable_value', 'l.grn_line_id', 'i.name', 'i.track_stock'])
        .where('l.purchase_id', '=', d.docId).orderBy('l.line_no').execute();
      for (const r of rows) {
        if (!r.track_stock || r.grn_line_id) continue;
        out.push({ docType: 'purchase', docId: head.id, docLineId: r.id, docNumber: head.number, docDate: head.bill_date,
          itemId: r.item_id, itemName: r.name, locationId: head.location_id, qty: r.qty, baseValue: r.taxable_value });
      }
    } else {
      const head = await tx.selectFrom('goods_receipts').select(['id', 'number', 'receipt_date', 'location_id', 'status'])
        .where('id', '=', d.docId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!head || !ctx.canAccessLocation(head.location_id)) throw notFound('Goods receipt');
      if (head.status !== 'posted') throw conflict(`Receipt ${head.number} is cancelled.`, 'INVALID_STATE');
      const rows = await tx.selectFrom('goods_receipt_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
        .select(['l.id', 'l.item_id', 'l.accepted_qty', 'l.value', 'i.name', 'i.track_stock'])
        .where('l.goods_receipt_id', '=', d.docId).where('l.accepted_qty', '>', 0).orderBy('l.line_no').execute();
      for (const r of rows) {
        if (!r.track_stock) continue;
        out.push({ docType: 'grn', docId: head.id, docLineId: r.id, docNumber: head.number, docDate: head.receipt_date,
          itemId: r.item_id, itemName: r.name, locationId: head.location_id, qty: r.accepted_qty, baseValue: r.value });
      }
    }
  }
  if (!out.length) throw badRequest('These documents have no stock lines to add cost to.', { docs: 'No stock lines' });
  return out;
}

type Acc = Awaited<ReturnType<typeof systemAccounts>>;

interface PreparedCharge {
  kind: string; description: string | null; amount: number; igst: number; sourceType: string; sourceId: string | null;
  creditAccountId: string | null; partyId: string | null; creditTo: { accountId: string; partyId?: string };
}

async function prepareCharges(tx: Tx, ctx: RequestContext, acc: Acc, charges: Body['charges']): Promise<PreparedCharge[]> {
  const out: PreparedCharge[] = [];
  for (const [i, c] of charges.entries()) {
    const sourceType = c.sourceType ?? 'direct';
    const igst = c.igstAmount ?? 0;
    if (c.amount + igst <= 0) throw badRequest(`Charge ${i + 1}: enter an amount.`, { [`charges.${i}.amount`]: 'Required' });
    let creditTo: PreparedCharge['creditTo'] | null = null;
    if (sourceType === 'expense' || sourceType === 'vendor_bill') {
      if (!c.sourceId) throw badRequest(`Charge ${i + 1}: choose the ${sourceType === 'expense' ? 'expense' : 'vendor bill'}.`, { [`charges.${i}.sourceId`]: 'Required' });
      const used = await tx.selectFrom('landed_cost_charges as c').innerJoin('landed_costs as h', 'h.id', 'c.landed_cost_id')
        .select('h.number').where('c.source_id', '=', c.sourceId).where('c.source_type', '=', sourceType).where('h.status', '=', 'posted')
        .executeTakeFirst();
      if (used) throw conflict(`Already on landed cost ${used.number}.`, 'SOURCE_USED');
      if (sourceType === 'expense') {
        const e = await tx.selectFrom('expenses').select(['account_id', 'amount', 'status'])
          .where('id', '=', c.sourceId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!e) throw notFound('Expense');
        if (e.status !== 'posted') throw conflict('That expense is cancelled.', 'INVALID_STATE');
        if (c.amount > e.amount + 0.001) throw badRequest(`Charge ${i + 1}: more than the expense of ${e.amount}.`, { [`charges.${i}.amount`]: 'Too high' });
        creditTo = { accountId: e.account_id };
      } else {
        const p = await tx.selectFrom('purchases').select(['status']).where('id', '=', c.sourceId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p) throw notFound('Vendor bill');
        if (p.status !== 'posted') throw conflict('That bill is cancelled.', 'INVALID_STATE');
        creditTo = { accountId: acc.purchases_nonstock };
      }
    } else if (c.creditAccountId) {
      const a = await tx.selectFrom('accounts').select('id').where('id', '=', c.creditAccountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!a) throw badRequest(`Charge ${i + 1}: account not found.`, { [`charges.${i}.creditAccountId`]: 'Not found' });
      creditTo = { accountId: a.id };
    } else if (c.partyId) {
      const p = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', c.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!p) throw badRequest(`Charge ${i + 1}: vendor not found.`, { [`charges.${i}.partyId`]: 'Not found' });
      if (p.type === 'customer') throw badRequest(`Charge ${i + 1}: choose a vendor.`, { [`charges.${i}.partyId`]: 'Not a vendor' });
      creditTo = { accountId: acc.payables, partyId: p.id };
    }
    if (!creditTo) throw badRequest(`Charge ${i + 1}: choose where the cost was booked, or the vendor.`, { [`charges.${i}.creditAccountId`]: 'Required' });
    out.push({ kind: c.kind, description: c.description ?? null, amount: c.amount, igst, sourceType, sourceId: c.sourceId ?? null,
      creditAccountId: c.creditAccountId ?? null, partyId: c.partyId ?? null, creditTo });
  }
  return out;
}

async function prepare(tx: Tx, ctx: RequestContext, b: Body) {
  const voucherDate = b.voucherDate ?? todayIst();
  if (voucherDate > todayIst()) throw badRequest('Date cannot be in the future.', { voucherDate: 'In the future' });
  const acc = await systemAccounts(tx, ctx);
  const src = await loadSourceLines(tx, ctx, b.docs);
  const charges = await prepareCharges(tx, ctx, acc, b.charges);
  const cost = round2(charges.reduce((s, c) => s + c.amount, 0));
  const igst = round2(charges.reduce((s, c) => s + c.igst, 0));

  const weightBy = new Map((b.weights ?? []).map((w) => [w.docLineId, w.weight]));
  const weights = src.map((l) => b.basis === 'value' ? l.baseValue : b.basis === 'qty' ? l.qty : (weightBy.get(l.docLineId) ?? 0));
  if (cost > 0 && weights.reduce((s, w) => s + w, 0) <= 0) {
    throw badRequest(b.basis === 'weight' ? 'Enter the weight of at least one line.' : 'The lines have nothing to share the cost by.', { weights: 'Required' });
  }
  const shares = allocate(cost, weights);

  // Share of the received quantity still in stock, per item and location.
  const groups = new Map<string, { itemId: string; locationId: string; qty: number }>();
  for (const l of src) {
    const g = groups.get(`${l.itemId}:${l.locationId}`) ?? { itemId: l.itemId, locationId: l.locationId, qty: 0 };
    g.qty += l.qty;
    groups.set(`${l.itemId}:${l.locationId}`, g);
  }
  const fraction = new Map<string, number>();
  for (const [k, g] of groups) {
    const onHand = await locationQty(tx, ctx.companyId, g.locationId, g.itemId);
    fraction.set(k, Math.max(0, Math.min(1, onHand / g.qty)));
  }
  const lines = src.map((l, i) => {
    const f = fraction.get(`${l.itemId}:${l.locationId}`) ?? 0;
    const allocated = shares[i]!;
    const toInventory = round2(allocated * f);
    return {
      ...l, weight: weightBy.get(l.docLineId) ?? 0,
      onHandPct: Math.round(f * 1_000_000) / 10_000, allocated, toInventory, toCogs: round2(allocated - toInventory),
      landedUnitCost: Math.round(((l.baseValue + allocated) / l.qty) * 10_000) / 10_000,
    };
  });
  return { voucherDate, fy: financialYear(voucherDate), acc, charges, cost, igst, lines, basis: b.basis };
}

type Prepared = Awaited<ReturnType<typeof prepare>>;

const lineJson = (l: Prepared['lines'][number]) => ({
  docType: l.docType, docId: l.docId, docLineId: l.docLineId, docNumber: l.docNumber, docDate: l.docDate, itemId: l.itemId,
  itemName: l.itemName, locationId: l.locationId, qty: l.qty, baseValue: l.baseValue, weight: l.weight, onHandPct: l.onHandPct,
  allocated: l.allocated, toInventory: l.toInventory, toCogs: l.toCogs, landedUnitCost: l.landedUnitCost,
});
const chargeJson = (c: PreparedCharge) => ({
  kind: c.kind, description: c.description, amount: c.amount, igstAmount: c.igst, sourceType: c.sourceType, sourceId: c.sourceId,
  creditAccountId: c.creditAccountId, partyId: c.partyId,
});

function previewJson(p: Prepared, b: Body, ctx: RequestContext) {
  return {
    id: null, number: null, status: 'posted', voucherDate: p.voucherDate, basis: p.basis, chargesTotal: p.cost, igstTotal: p.igst,
    inventoryTotal: round2(p.lines.reduce((s, l) => s + l.toInventory, 0)), cogsTotal: round2(p.lines.reduce((s, l) => s + l.toCogs, 0)),
    notes: b.notes ?? null, createdAt: null, createdBy: { id: ctx.userId, name: ctx.userName },
    charges: p.charges.map(chargeJson), lines: p.lines.map(lineJson),
  };
}

async function loadLc(tx: Tx, ctx: RequestContext, id: string) {
  const h = await tx.selectFrom('landed_costs as h').innerJoin('users as u', 'u.id', 'h.created_by').selectAll('h').select('u.name as created_by_name')
    .where('h.id', '=', id).where('h.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!h) throw notFound('Landed cost');
  const charges = await tx.selectFrom('landed_cost_charges').selectAll().where('landed_cost_id', '=', id).orderBy('line_no').execute();
  const lines = await tx.selectFrom('landed_cost_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.doc_type', 'l.doc_id', 'l.doc_line_id', 'l.doc_number', 'l.doc_date', 'l.item_id', 'i.name as item_name', 'l.location_id',
      'l.qty', 'l.base_value', 'l.weight', 'l.on_hand_pct', 'l.allocated', 'l.to_inventory', 'l.to_cogs'])
    .where('l.landed_cost_id', '=', id).orderBy('l.line_no').execute();
  return {
    id: h.id, number: h.number, status: h.status, voucherDate: h.voucher_date, basis: h.basis, chargesTotal: h.charges_total,
    igstTotal: h.igst_total, inventoryTotal: h.inventory_total, cogsTotal: h.cogs_total, notes: h.notes, createdAt: h.created_at,
    createdBy: { id: h.created_by, name: h.created_by_name }, cancelledAt: h.cancelled_at, cancelReason: h.cancel_reason,
    charges: charges.map((c) => ({ kind: c.kind, description: c.description, amount: c.amount, igstAmount: c.igst_amount,
      sourceType: c.source_type, sourceId: c.source_id, creditAccountId: c.credit_account_id, partyId: c.party_id })),
    lines: lines.map((l) => ({
      docType: l.doc_type, docId: l.doc_id, docLineId: l.doc_line_id, docNumber: l.doc_number, docDate: l.doc_date, itemId: l.item_id,
      itemName: l.item_name, locationId: l.location_id, qty: l.qty, baseValue: l.base_value, weight: l.weight, onHandPct: l.on_hand_pct,
      allocated: l.allocated, toInventory: l.to_inventory, toCogs: l.to_cogs,
      landedUnitCost: Math.round(((l.base_value + l.allocated) / l.qty) * 10_000) / 10_000,
    })),
  };
}

export async function createLandedCost(ctx: RequestContext, tx: Tx, b: Body) {
  const p = await prepare(tx, ctx, b);
  const number = await nextNumber(tx, ctx, 'landed_cost', p.fy);
  const inventoryTotal = round2(p.lines.reduce((s, l) => s + l.toInventory, 0));
  const cogsTotal = round2(p.lines.reduce((s, l) => s + l.toCogs, 0));
  const row = await tx.insertInto('landed_costs').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, number, fy: p.fy, voucher_date: p.voucherDate, basis: p.basis,
    charges_total: p.cost, igst_total: p.igst, inventory_total: inventoryTotal, cogs_total: cogsTotal, notes: b.notes ?? null,
    created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
  }).returning('id').executeTakeFirstOrThrow();
  await tx.insertInto('landed_cost_charges').values(p.charges.map((c, i) => ({
    tenant_id: ctx.tenantId, landed_cost_id: row.id, line_no: i + 1, kind: c.kind, description: c.description, amount: c.amount,
    igst_amount: c.igst, source_type: c.sourceType, source_id: c.sourceId, credit_account_id: c.creditTo.partyId ? null : c.creditTo.accountId,
    party_id: c.creditTo.partyId ?? null,
  }))).execute();
  await tx.insertInto('landed_cost_lines').values(p.lines.map((l, i) => ({
    tenant_id: ctx.tenantId, landed_cost_id: row.id, line_no: i + 1, doc_type: l.docType, doc_id: l.docId, doc_line_id: l.docLineId,
    doc_number: l.docNumber, doc_date: l.docDate, item_id: l.itemId, location_id: l.locationId, qty: l.qty, base_value: l.baseValue,
    weight: l.weight, on_hand_pct: l.onHandPct, allocated: l.allocated, to_inventory: l.toInventory, to_cogs: l.toCogs,
  }))).execute();

  // Stock value: one value-only move per item and location.
  const perItem = new Map<string, { itemId: string; locationId: string; value: number }>();
  for (const l of p.lines) {
    const g = perItem.get(`${l.itemId}:${l.locationId}`) ?? { itemId: l.itemId, locationId: l.locationId, value: 0 };
    g.value = round2(g.value + l.toInventory);
    perItem.set(`${l.itemId}:${l.locationId}`, g);
  }
  const moves = [...perItem.values()].filter((g) => g.value !== 0);
  await lockItems(tx, ctx.companyId, moves.map((m) => m.itemId));
  if (moves.length) {
    await tx.insertInto('stock_moves').values(moves.map((m) => ({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: m.locationId, item_id: m.itemId, qty: 0, rate: null,
      cost_rate: null, value: m.value, ref_type: 'landed_cost', ref_id: row.id, note: number, created_by: ctx.userId,
    }))).execute();
  }

  const byLoc = (pick: (l: Prepared['lines'][number]) => number) => {
    const m = new Map<string, number>();
    for (const l of p.lines) m.set(l.locationId, round2((m.get(l.locationId) ?? 0) + pick(l)));
    return m;
  };
  const jl: JLine[] = [];
  for (const [loc, v] of byLoc((l) => l.toInventory)) jl.push({ accountId: p.acc.inventory, amount: v, locationId: loc });
  for (const [loc, v] of byLoc((l) => l.toCogs)) jl.push({ accountId: p.acc.cogs, amount: v, locationId: loc });
  const firstLoc = p.lines[0]!.locationId;
  jl.push({ accountId: p.acc.input_igst, amount: p.igst, locationId: firstLoc });
  for (const c of p.charges) {
    jl.push({ accountId: c.creditTo.accountId, amount: -round2(c.amount + c.igst), partyId: c.creditTo.partyId ?? null, locationId: firstLoc });
  }
  await postJournal(tx, auditOf(ctx), {
    date: p.voucherDate, voucherType: 'stock', voucherId: row.id, number,
    narration: `Landed cost ${number}`, lines: jl,
  });
  await writeAudit(tx, auditOf(ctx), 'landed_cost', row.id, 'create', null, { number, chargesTotal: p.cost, igstTotal: p.igst });
  return loadLc(tx, ctx, row.id);
}

export async function landedCostRoutes(app: FastifyInstance) {
  app.post('/landed-costs/preview', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.create');
    const b = parse(body, req.body);
    return ctx.tx(async (tx) => previewJson(await prepare(tx, ctx, b), b, ctx));
  });

  app.post('/landed-costs', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('purchases.create');
    const b = parse(body, req.body);
    return reply.status(201).send(await ctx.tx((tx) => createLandedCost(ctx, tx, b)));
  });

  app.get('/landed-costs', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('landed_costs as h').innerJoin('users as u', 'u.id', 'h.created_by').selectAll('h')
        .select('u.name as created_by_name').where('h.company_id', '=', ctx.companyId);
      if (q.status) base = base.where('h.status', '=', q.status);
      if (q.from) base = base.where('h.voucher_date', '>=', q.from);
      if (q.to) base = base.where('h.voucher_date', '<=', q.to);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('h.number', 'ilike', t), eb('h.notes', 'ilike', t),
          eb.exists(eb.selectFrom('landed_cost_lines as l').select('l.id').whereRef('l.landed_cost_id', '=', 'h.id').where('l.doc_number', 'ilike', t))]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('h.voucher_date', 'desc').orderBy('h.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((h) => ({
          id: h.id, number: h.number, status: h.status, voucherDate: h.voucher_date, basis: h.basis, chargesTotal: h.charges_total,
          igstTotal: h.igst_total, inventoryTotal: h.inventory_total, cogsTotal: h.cogs_total, notes: h.notes, createdAt: h.created_at,
          createdBy: { id: h.created_by, name: h.created_by_name },
        })),
        total,
      };
    });
  });

  app.get('/landed-costs/report', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.view');
    const q = parse(reportQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('landed_cost_lines as l').innerJoin('landed_costs as h', 'h.id', 'l.landed_cost_id')
        .innerJoin('items as i', 'i.id', 'l.item_id')
        .select(['h.id as voucher_id', 'h.number', 'h.voucher_date', 'l.doc_type', 'l.doc_id', 'l.doc_number', 'l.item_id', 'i.name as item_name',
          'l.qty', 'l.base_value', 'l.allocated', 'l.to_inventory', 'l.to_cogs'])
        .where('h.company_id', '=', ctx.companyId).where('h.status', '=', 'posted');
      if (q.from) base = base.where('h.voucher_date', '>=', q.from);
      if (q.to) base = base.where('h.voucher_date', '<=', q.to);
      if (q.itemId) base = base.where('l.item_id', '=', q.itemId);
      if (q.docId) base = base.where('l.doc_id', '=', q.docId);
      const rows = await base.orderBy('h.voucher_date', 'desc').orderBy('l.doc_number').execute();
      const data = rows.map((r) => ({
        voucherId: r.voucher_id, voucherNumber: r.number, voucherDate: r.voucher_date, docType: r.doc_type, docId: r.doc_id,
        docNumber: r.doc_number, itemId: r.item_id, itemName: r.item_name, qty: r.qty, baseValue: r.base_value, allocated: r.allocated,
        toInventory: r.to_inventory, toCogs: r.to_cogs, landedValue: round2(r.base_value + r.allocated),
        landedUnitCost: Math.round(((r.base_value + r.allocated) / r.qty) * 10_000) / 10_000,
      }));
      const sum = (f: (r: (typeof data)[number]) => number) => round2(data.reduce((s, r) => s + f(r), 0));
      return { data, totals: { baseValue: sum((r) => r.baseValue), allocated: sum((r) => r.allocated), toInventory: sum((r) => r.toInventory),
        toCogs: sum((r) => r.toCogs), landedValue: sum((r) => r.landedValue) } };
    });
  });

  app.get<{ Params: { id: string } }>('/landed-costs/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadLc(tx, ctx, id));
  });

  app.post<{ Params: { id: string } }>('/landed-costs/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.cancel');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const h = await tx.selectFrom('landed_costs').select(['id', 'status', 'number']).where('id', '=', id)
        .where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!h) throw notFound('Landed cost');
      if (h.status === 'cancelled') throw conflict('This landed cost is already cancelled.', 'ALREADY_CANCELLED');
      const moves = await tx.selectFrom('stock_moves').select(['location_id', 'item_id', 'value']).where('ref_type', '=', 'landed_cost').where('ref_id', '=', id).execute();
      await lockItems(tx, ctx.companyId, moves.map((m) => m.item_id));
      await tx.updateTable('landed_costs').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      if (moves.length) {
        await tx.insertInto('stock_moves').values(moves.map((m) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: m.location_id, item_id: m.item_id, qty: 0, rate: null,
          cost_rate: null, value: -m.value, ref_type: 'landed_cost_cancel', ref_id: id, note: `Cancelled ${h.number}`, created_by: ctx.userId,
        }))).execute();
      }
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${h.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'landed_cost', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return loadLc(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/landed-costs', { summary: 'Post a landed cost voucher', body });
documentRoute('POST', '/landed-costs/preview', { summary: 'Preview the allocation of a landed cost', body });
documentRoute('POST', '/landed-costs/:id/cancel', { summary: 'Cancel a landed cost voucher', body: cancelBody });
