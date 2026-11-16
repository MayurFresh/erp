import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { lockItems } from '../accounting/costing.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { documentRoute } from '../lib/openapi.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { requireStock } from './stock.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const round3 = (n: number) => Math.round(n * 1000) / 1000;
const round4 = (n: number) => Math.round(n * 10_000) / 10_000;
const EPS = 0.0005;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const createBody = z.object({
  purchaseId: z.uuid(),
  returnDate: docDate.optional(),
  reason: z.string().trim().min(3, 'Give a reason').max(300),
  kind: z.enum(['goods', 'price']),
  lines: z.array(z.object({
    purchaseLineId: z.uuid(),
    qty: qtyField.refine((v) => v > 0, 'Must be more than zero').optional(),
    amount: moneyField.refine((v) => v > 0, 'Must be more than zero').optional(),
  })).min(1, 'Choose at least one line').max(200, 'At most 200 lines'),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(['posted', 'cancelled']).optional(),
  kind: z.enum(['goods', 'price']).optional(),
  purchaseId: z.uuid().optional(),
  partyId: z.uuid().optional(),
  from: dateField.optional(),
  to: dateField.optional(),
});

const overReturn = (lineNo: number, billed: number, returned: number, left: number, what: string) =>
  new AppError(409, 'OVER_RETURN', `Line ${lineNo}: only ${left} ${what} can still be returned.`, { lineNo, billed, returned, left });

function returnSelect(tx: Tx) {
  return tx.selectFrom('purchase_returns as r')
    .innerJoin('purchases as v', 'v.id', 'r.purchase_id')
    .innerJoin('locations as l', 'l.id', 'r.location_id')
    .innerJoin('parties as p', 'p.id', 'r.party_id')
    .innerJoin('users as u', 'u.id', 'r.created_by')
    .selectAll('r')
    .select(['v.number as purchase_number', 'v.supplier_invoice_no', 'l.name as location_name', 'p.name as party_name',
      'p.gstin as party_gstin', 'u.name as created_by_name']);
}
type ReturnRow = Awaited<ReturnType<ReturnType<typeof returnSelect>['executeTakeFirstOrThrow']>>;

function returnJson(r: ReturnRow) {
  return {
    id: r.id, companyId: r.company_id, number: r.number, fy: r.fy, status: r.status, kind: r.kind, reason: r.reason,
    returnDate: r.return_date, purchaseId: r.purchase_id, purchaseNumber: r.purchase_number, supplierInvoiceNo: r.supplier_invoice_no,
    partyId: r.party_id, partyName: r.party_name, partyGstin: r.party_gstin, locationId: r.location_id, locationName: r.location_name,
    placeOfSupply: r.place_of_supply, supplyType: r.supply_type, reverseCharge: r.reverse_charge, subtotal: r.subtotal,
    cgst: r.cgst, sgst: r.sgst, igst: r.igst, taxTotal: round2(r.cgst + r.sgst + r.igst), roundOff: r.round_off, total: r.total,
    tdsReversed: r.tds_reversed, appliedAmount: r.applied_amount, stockValue: r.stock_value,
    createdBy: { id: r.created_by, name: r.created_by_name }, createdAt: r.created_at,
    cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
  };
}

async function loadReturn(tx: Tx, ctx: RequestContext, id: string) {
  const row = await returnSelect(tx).where('r.id', '=', id).where('r.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Debit note');
  const lines = await tx.selectFrom('purchase_return_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.id', 'l.line_no', 'l.purchase_line_id', 'l.item_id', 'l.description', 'l.hsn_code', 'l.qty', 'l.unit', 'l.gst_rate',
      'l.taxable_value', 'l.cgst', 'l.sgst', 'l.igst', 'l.line_total', 'l.stock_value', 'i.name as item_name'])
    .where('l.return_id', '=', id).orderBy('l.line_no').execute();
  return {
    ...returnJson(row),
    lines: lines.map((l) => ({
      id: l.id, lineNo: l.line_no, purchaseLineId: l.purchase_line_id, itemId: l.item_id, itemName: l.item_name,
      description: l.description, hsnCode: l.hsn_code, qty: l.qty, unit: l.unit, gstRate: l.gst_rate,
      taxableValue: l.taxable_value, cgst: l.cgst, sgst: l.sgst, igst: l.igst, lineTotal: l.line_total, stockValue: l.stock_value,
    })),
  };
}

export async function createPurchaseReturn(ctx: RequestContext, tx: Tx, body: z.infer<typeof createBody>) {
  const bill = await tx.selectFrom('purchases').selectAll()
    .where('id', '=', body.purchaseId).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!bill || !ctx.canAccessLocation(bill.location_id)) throw badRequest('Purchase bill not found.', { purchaseId: 'Not found' });
  if (bill.status !== 'posted') throw conflict('This bill is cancelled, so nothing can be returned against it.', 'BILL_CANCELLED');

  const returnDate = body.returnDate ?? todayIst();
  if (returnDate > todayIst()) throw badRequest('Date cannot be in the future.', { returnDate: 'In the future' });
  if (returnDate < bill.bill_date) throw badRequest('A debit note cannot be dated before its bill.', { returnDate: 'Before the bill' });

  const billLines = await tx.selectFrom('purchase_lines as pl').innerJoin('items as i', 'i.id', 'pl.item_id')
    .selectAll('pl').select(['i.track_stock', 'i.name as item_name']).where('pl.purchase_id', '=', bill.id).orderBy('pl.id').forUpdate('pl').execute();
  const prior = billLines.length
    ? await tx.selectFrom('purchase_return_lines as l').innerJoin('purchase_returns as r', 'r.id', 'l.return_id')
      .select(['l.purchase_line_id', 'l.stock_value']).where('r.status', '=', 'posted').where('r.purchase_id', '=', bill.id).execute()
    : [];
  const priorStock = new Map<string, number>();
  for (const x of prior) priorStock.set(x.purchase_line_id, round2((priorStock.get(x.purchase_line_id) ?? 0) + x.stock_value));

  const seen = new Set<string>();
  const lines = body.lines.map((l, idx) => {
    const src = billLines.find((x) => x.id === l.purchaseLineId);
    const no = idx + 1;
    if (!src) throw badRequest(`Line ${no}: not a line of this bill.`, { [`lines.${idx}.purchaseLineId`]: 'Not found' });
    if (seen.has(src.id)) throw badRequest('Each bill line can appear once.', { [`lines.${idx}.purchaseLineId`]: 'Duplicate' });
    seen.add(src.id);
    const taxLeft = round2(src.taxable_value - src.returned_taxable);
    let qty = 0;
    let taxable: number;
    let stockValue = 0;
    if (body.kind === 'goods') {
      if (l.qty === undefined) throw badRequest(`Line ${no}: give a quantity.`, { [`lines.${idx}.qty`]: 'Required' });
      qty = l.qty;
      const qtyLeft = round3(src.qty - src.returned_qty);
      if (qty > qtyLeft + EPS || taxLeft <= 0) throw overReturn(no, src.qty, src.returned_qty, Math.max(qtyLeft, 0), src.unit);
      const last = qty >= qtyLeft - EPS;
      taxable = last ? taxLeft : Math.min(taxLeft, round2((src.taxable_value * qty) / src.qty));
      if (src.track_stock) {
        const base = src.grn_line_id ? src.grni_value : src.taxable_value;
        stockValue = last ? Math.max(round2(base - (priorStock.get(src.id) ?? 0)), 0) : round2((base * qty) / src.qty);
      }
    } else {
      if (l.amount === undefined) throw badRequest(`Line ${no}: give an amount.`, { [`lines.${idx}.amount`]: 'Required' });
      taxable = l.amount;
      if (taxable > taxLeft + 0.005) throw overReturn(no, src.taxable_value, src.returned_taxable, Math.max(taxLeft, 0), 'rupees before GST');
    }
    return { src, qty, taxable, stockValue };
  });

  // Same tax treatment as the bill: its supply type, the line's GST rate, and reverse charge.
  const seller = bill.supply_type === 'intra' ? bill.place_of_supply : 'XX';
  const gst = computeGst(seller, bill.place_of_supply, lines.map((l) => ({ qty: 1, rate: l.taxable, discountPct: 0, gstRate: l.src.gst_rate })));
  const total = bill.reverse_charge ? Math.round(gst.subtotal) : gst.total;
  const roundOff = bill.reverse_charge ? round2(total - gst.subtotal) : gst.roundOff;

  // TDS comes back in proportion to the taxable value returned.
  let tdsReversed = 0;
  if (bill.tds_amount > 0 && bill.subtotal > 0) {
    const priorTds = (await tx.selectFrom('purchase_returns').select((eb) => eb.fn.sum<number>('tds_reversed').as('s'))
      .where('purchase_id', '=', bill.id).where('status', '=', 'posted').executeTakeFirstOrThrow()).s;
    const left = round2(bill.tds_amount - Number(priorTds ?? 0));
    const priorTaxable = billLines.reduce((s, l) => s + l.returned_taxable, 0);
    const completes = priorTaxable + gst.subtotal >= bill.subtotal - 0.005;
    tdsReversed = Math.max(0, Math.min(left, completes ? left : round2((bill.tds_amount * gst.subtotal) / bill.subtotal)));
  }

  const location = await getLocation(tx, ctx, bill.location_id);
  const goodsTracked = body.kind === 'goods' ? lines.filter((l) => l.src.track_stock) : [];
  await lockItems(tx, ctx.companyId, goodsTracked.map((l) => l.src.item_id));
  const need = new Map<string, { name: string; unit: string; qty: number }>();
  for (const l of goodsTracked) {
    const e = need.get(l.src.item_id) ?? { name: l.src.item_name, unit: l.src.unit, qty: 0 };
    e.qty = round3(e.qty + l.qty);
    need.set(l.src.item_id, e);
  }
  for (const [itemId, e] of need) await requireStock(tx, ctx, location, { id: itemId, name: e.name, unit: e.unit }, e.qty);

  const fy = financialYear(returnDate);
  const number = await nextNumber(tx, ctx, 'debit_note', fy);
  const stockValue = round2(lines.reduce((s, l) => s + l.stockValue, 0));
  const vendorDebit = round2(total - tdsReversed);
  const due = round2(bill.net_payable - bill.amount_paid);
  const applied = round2(Math.min(vendorDebit, Math.max(due, 0)));

  const row = await tx.insertInto('purchase_returns').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, purchase_id: bill.id, location_id: bill.location_id, party_id: bill.party_id,
    number, fy, return_date: returnDate, kind: body.kind, reason: body.reason, place_of_supply: bill.place_of_supply,
    supply_type: bill.supply_type, reverse_charge: bill.reverse_charge, subtotal: gst.subtotal, cgst: gst.cgst, sgst: gst.sgst,
    igst: gst.igst, round_off: roundOff, total, tds_reversed: tdsReversed, applied_amount: applied, stock_value: stockValue,
    created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
  }).returning('id').executeTakeFirstOrThrow();

  await tx.insertInto('purchase_return_lines').values(lines.map((l, i) => {
    const g = gst.lines[i]!;
    return {
      tenant_id: ctx.tenantId, return_id: row.id, line_no: i + 1, purchase_line_id: l.src.id, item_id: l.src.item_id,
      description: l.src.description, hsn_code: l.src.hsn_code, qty: l.qty, unit: l.src.unit, gst_rate: l.src.gst_rate,
      taxable_value: g.taxableValue, cgst: g.cgst, sgst: g.sgst, igst: g.igst, line_total: g.lineTotal, stock_value: l.stockValue,
    };
  })).execute();
  for (const l of lines) {
    await tx.updateTable('purchase_lines').set((eb) => ({
      returned_qty: eb('returned_qty', '+', l.qty), returned_taxable: eb('returned_taxable', '+', l.taxable),
    })).where('id', '=', l.src.id).execute();
  }
  if (applied > 0) {
    await tx.updateTable('purchases').set((eb) => ({ amount_paid: eb('amount_paid', '+', applied) })).where('id', '=', bill.id).execute();
  }

  const moves = goodsTracked.filter((l) => l.stockValue > 0 || l.qty > 0);
  if (moves.length) {
    await tx.insertInto('stock_moves').values(moves.map((l) => ({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: bill.location_id, item_id: l.src.item_id, qty: -l.qty,
      rate: l.src.rate, cost_rate: round4(l.stockValue / l.qty), value: -l.stockValue, ref_type: 'purchase_return', ref_id: row.id,
      note: number, created_by: ctx.userId,
    }))).execute();
  }

  // The bill's entry in reverse. Stock cost leaves inventory; any other part of the taxable value goes to price variance
  // (stocked item, price claim, or a GRN line billed at a different cost) or to non-stock purchases.
  const acc = await systemAccounts(tx, ctx);
  const loc = bill.location_id;
  const nonStock = round2(lines.reduce((s, l, i) => s + (l.src.track_stock ? 0 : gst.lines[i]!.taxableValue), 0));
  const variance = round2(gst.subtotal - nonStock - stockValue);
  await postJournal(tx, auditOf(ctx), {
    date: returnDate, voucherType: 'debit_note', voucherId: row.id, number,
    narration: `Purchase return to vendor against ${bill.number}: ${body.reason}`,
    lines: [
      { accountId: acc.payables, amount: vendorDebit, partyId: bill.party_id, locationId: loc },
      { accountId: acc.tds_payable, amount: tdsReversed, locationId: loc },
      { accountId: acc.inventory, amount: -stockValue, locationId: loc },
      { accountId: acc.purchase_price_variance, amount: -variance, locationId: loc },
      { accountId: acc.purchases_nonstock, amount: -nonStock, locationId: loc, costCentreId: bill.cost_centre_id },
      { accountId: acc.input_cgst, amount: -gst.cgst, locationId: loc },
      { accountId: acc.input_sgst, amount: -gst.sgst, locationId: loc },
      { accountId: acc.input_igst, amount: -gst.igst, locationId: loc },
      { accountId: acc.round_off, amount: -roundOff, locationId: loc },
      { accountId: acc.rcm_payable, amount: bill.reverse_charge ? gst.taxTotal : 0, locationId: loc },
    ],
  });
  await writeAudit(tx, auditOf(ctx), 'purchase_return', row.id, 'create', null,
    { number, purchaseId: bill.id, kind: body.kind, total, applied, stockValue, tdsReversed });
  return loadReturn(tx, ctx, row.id);
}

export async function purchaseReturnRoutes(app: FastifyInstance) {
  app.get('/purchase-returns', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = returnSelect(tx).where('r.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('r.location_id', 'in', scope);
      if (q.status) base = base.where('r.status', '=', q.status);
      if (q.kind) base = base.where('r.kind', '=', q.kind);
      if (q.purchaseId) base = base.where('r.purchase_id', '=', q.purchaseId);
      if (q.partyId) base = base.where('r.party_id', '=', q.partyId);
      if (q.from) base = base.where('r.return_date', '>=', q.from);
      if (q.to) base = base.where('r.return_date', '<=', q.to);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('r.number', 'ilike', t), eb('v.number', 'ilike', t), eb('p.name', 'ilike', t), eb('v.supplier_invoice_no', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('r.return_date', 'desc').orderBy('r.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(returnJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/purchase-returns/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadReturn(tx, ctx, id));
  });

  app.post('/purchase-returns', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('purchases.create');
    const body = parse(createBody, req.body);
    const created = await ctx.tx((tx) => createPurchaseReturn(ctx, tx, body));
    return reply.status(201).send(created);
  });

  app.post<{ Params: { id: string } }>('/purchase-returns/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.cancel');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('purchase_returns').selectAll()
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!cur || !ctx.canAccessLocation(cur.location_id)) throw notFound('Debit note');
      if (cur.status === 'cancelled') throw conflict('This debit note is already cancelled.', 'ALREADY_CANCELLED');
      await tx.selectFrom('purchases').select('id').where('id', '=', cur.purchase_id).forUpdate().execute();

      const moves = await tx.selectFrom('stock_moves').select(['item_id', 'location_id', 'qty', 'rate', 'cost_rate', 'value'])
        .where('ref_type', '=', 'purchase_return').where('ref_id', '=', id).execute();
      if (moves.length) {
        await lockItems(tx, ctx.companyId, moves.map((m) => m.item_id));
        await tx.insertInto('stock_moves').values(moves.map((m) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: m.location_id, item_id: m.item_id, qty: -m.qty,
          rate: m.rate, cost_rate: m.cost_rate, value: -m.value, ref_type: 'purchase_return_cancel', ref_id: id,
          note: `Cancelled ${cur.number}`, created_by: ctx.userId,
        }))).execute();
      }
      const lines = await tx.selectFrom('purchase_return_lines').select(['purchase_line_id', 'qty', 'taxable_value']).where('return_id', '=', id).execute();
      for (const l of lines) {
        await tx.updateTable('purchase_lines').set((eb) => ({
          returned_qty: eb('returned_qty', '-', l.qty), returned_taxable: eb('returned_taxable', '-', l.taxable_value),
        })).where('id', '=', l.purchase_line_id).execute();
      }
      if (cur.applied_amount > 0) {
        await tx.updateTable('purchases').set((eb) => ({ amount_paid: eb('amount_paid', '-', cur.applied_amount) })).where('id', '=', cur.purchase_id).execute();
      }
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${cur.number}: ${reason}`);
      await tx.updateTable('purchase_returns').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'purchase_return', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return loadReturn(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/purchase-returns', { summary: 'Return goods to a vendor or claim a price reduction (debit note)', body: createBody });
documentRoute('POST', '/purchase-returns/:id/cancel', { summary: 'Cancel a debit note', body: cancelBody });
