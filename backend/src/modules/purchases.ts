import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { lockItems } from '../accounting/costing.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { paymentInfo } from '../lib/docs.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { assertGstRates } from '../lib/rates.ts';
import { calcTds, cancelDeduction, insertDeduction } from '../lib/tds.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { checkIndentLink, fulfilIndent, reverseFulfilment } from './indents.ts';
import { getLocation } from './locations.ts';
import { requireStock } from './stock.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const lineBody = z.object({
  itemId: z.uuid(),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
  rate: moneyField.optional(),
  discountPct: percentField.optional(),
  description: optionalText(300),
});
const createBody = z.object({
  locationId: z.uuid(),
  partyId: z.uuid(),
  billDate: docDate.optional(),
  supplierInvoiceNo: optionalText(40),
  supplierInvoiceDate: docDate.optional(),
  notes: optionalText(1000),
  indentId: z.uuid().nullable().optional(),
  tdsSectionId: z.uuid().nullable().optional(),
  reverseCharge: z.boolean().optional(),
  lines: z.array(lineBody).min(1, 'Add at least one line').max(200, 'At most 200 lines'),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(['posted', 'cancelled']).optional(),
  paymentStatus: z.enum(['unpaid', 'partial', 'paid']).optional(),
  from: dateField.optional(),
  to: dateField.optional(),
  locationId: z.uuid().optional(),
  partyId: z.uuid().optional(),
});

type CreateBody = z.infer<typeof createBody>;

async function prepare(tx: Tx, ctx: RequestContext, body: CreateBody) {
  const location = await getLocation(tx, ctx, body.locationId);
  if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });

  const party = await tx.selectFrom('parties').selectAll()
    .where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!party) throw badRequest('Vendor not found.', { partyId: 'Not found' });
  if (party.type === 'customer') throw badRequest('Choose a vendor, not a customer.', { partyId: 'Not a vendor' });

  const billDate = body.billDate ?? todayIst();
  if (billDate > todayIst()) throw badRequest('Bill date cannot be in the future.', { billDate: 'In the future' });
  if (body.indentId) await checkIndentLink(tx, ctx, body.indentId, location.id);

  const ids = [...new Set(body.lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').selectAll().where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const byId = new Map(items.map((i) => [i.id, i]));
  const lines = body.lines.map((l, idx) => {
    const item = byId.get(l.itemId);
    if (!item) throw badRequest(`Line ${idx + 1}: item not found.`, { [`lines.${idx}.itemId`]: 'Not found' });
    if (!item.is_active) throw badRequest(`Line ${idx + 1}: ${item.name} is inactive.`, { [`lines.${idx}.itemId`]: 'Inactive' });
    return { item, qty: l.qty, rate: l.rate ?? item.purchase_price, discountPct: l.discountPct ?? 0, description: l.description ?? item.name };
  });

  await assertGstRates(tx, billDate, lines.map((l, idx) => ({
    rate: l.item.gst_rate, hsn: l.item.hsn_code, field: `lines.${idx}.itemId`, label: `${l.item.name} (line ${idx + 1})`,
  })));

  // Input tax: supplier's state against the receiving location's state.
  const supplierState = party.state_code ?? location.state_code;
  const gst = computeGst(location.state_code, supplierState, lines.map((l) => ({
    qty: l.qty, rate: l.rate, discountPct: l.discountPct, gstRate: l.item.gst_rate,
  })));
  // Tax deducted at source: the party's default section unless the request names one (or null for none).
  const sectionId = body.tdsSectionId !== undefined ? body.tdsSectionId : party.tds_section_id;
  const tds = sectionId
    ? await calcTds(tx, ctx.companyId, { partyId: party.id, sectionId, date: billDate, gross: gst.subtotal })
    : null;
  // Reverse charge: the supplier charges no GST, so the total leaves the tax out (rounded on the taxable value alone).
  const reverseCharge = body.reverseCharge ?? false;
  const total = reverseCharge ? Math.round(gst.subtotal) : gst.total;
  const roundOff = reverseCharge ? round2(total - gst.subtotal) : gst.roundOff;
  const tdsAmount = tds?.amount ?? 0;
  const msme = party.msme_category === 'micro' || party.msme_category === 'small';
  const msmeDueDate = msme ? addDays(billDate, party.credit_days > 0 ? Math.min(party.credit_days, 45) : 15) : null;
  return {
    location, party, billDate, dueDate: addDays(billDate, party.credit_days), fy: financialYear(billDate),
    placeOfSupply: location.state_code, lines, gst, tds, reverseCharge, total, roundOff, tdsAmount,
    netPayable: round2(total - tdsAmount), msmeDueDate,
  };
}

type Prepared = Awaited<ReturnType<typeof prepare>>;

function preparedJson(ctx: RequestContext, p: Prepared, body: CreateBody) {
  return {
    id: null, companyId: ctx.companyId, locationId: p.location.id, locationName: p.location.name,
    partyId: p.party.id, partyName: p.party.name, partyGstin: p.party.gstin, number: null,
    supplierInvoiceNo: body.supplierInvoiceNo ?? null, supplierInvoiceDate: body.supplierInvoiceDate ?? null,
    indentId: body.indentId ?? null, fy: p.fy, billDate: p.billDate, dueDate: p.dueDate, placeOfSupply: p.placeOfSupply, supplyType: p.gst.supplyType,
    status: 'posted', subtotal: p.gst.subtotal, cgst: p.gst.cgst, sgst: p.gst.sgst, igst: p.gst.igst,
    taxTotal: p.gst.taxTotal, roundOff: p.roundOff, total: p.total, ...paymentInfo(p.netPayable, 0, 'posted'),
    tdsSectionId: p.tds?.sectionId ?? null, tdsSectionCode: p.tds?.sectionCode ?? null, tdsBase: p.tds?.base ?? 0,
    tdsRate: p.tds?.rate ?? 0, tdsAmount: p.tdsAmount, netPayable: p.netPayable, reverseCharge: p.reverseCharge,
    rcmSelfInvoiceNo: null, msmeDueDate: p.msmeDueDate, msmeCategory: p.party.msme_category,
    notes: body.notes ?? null, createdAt: new Date(), createdBy: { id: ctx.userId, name: ctx.userName },
    cancelledAt: null, cancelReason: null,
    lines: p.lines.map((l, i) => ({
      id: null, itemId: l.item.id, description: l.description, hsnCode: l.item.hsn_code, qty: l.qty, unit: l.item.unit,
      rate: l.rate, discountPct: l.discountPct, gstRate: l.item.gst_rate, ...p.gst.lines[i]!,
    })),
  };
}

export function purchaseSelect(tx: Tx) {
  return tx.selectFrom('purchases as v')
    .innerJoin('locations as l', 'l.id', 'v.location_id')
    .innerJoin('parties as p', 'p.id', 'v.party_id')
    .innerJoin('users as u', 'u.id', 'v.created_by')
    .leftJoin('tds_sections as ts', 'ts.id', 'v.tds_section_id')
    .selectAll('v')
    .select(['l.name as location_name', 'p.name as party_name', 'p.gstin as party_gstin', 'u.name as created_by_name',
      'p.msme_category as party_msme_category', 'ts.code as tds_section_code']);
}

type PurchaseRow = Awaited<ReturnType<ReturnType<typeof purchaseSelect>['executeTakeFirstOrThrow']>>;

export function purchaseJson(r: PurchaseRow) {
  return {
    id: r.id, companyId: r.company_id, locationId: r.location_id, locationName: r.location_name, partyId: r.party_id,
    partyName: r.party_name, partyGstin: r.party_gstin, number: r.number, supplierInvoiceNo: r.supplier_invoice_no,
    supplierInvoiceDate: r.supplier_invoice_date, indentId: r.indent_id, fy: r.fy, billDate: r.bill_date, dueDate: r.due_date,
    placeOfSupply: r.place_of_supply, supplyType: r.supply_type, status: r.status, subtotal: r.subtotal,
    cgst: r.cgst, sgst: r.sgst, igst: r.igst, taxTotal: Math.round((r.cgst + r.sgst + r.igst) * 100) / 100,
    roundOff: r.round_off, total: r.total, ...paymentInfo(r.net_payable, r.amount_paid, r.status),
    tdsSectionId: r.tds_section_id, tdsSectionCode: r.tds_section_code, tdsBase: r.tds_base, tdsRate: r.tds_rate,
    tdsAmount: r.tds_amount, netPayable: r.net_payable, reverseCharge: r.reverse_charge, rcmSelfInvoiceNo: r.rcm_self_invoice_no,
    msmeDueDate: r.msme_due_date, msmeCategory: r.msme_due_date ? r.party_msme_category : null, notes: r.notes,
    createdAt: r.created_at, createdBy: { id: r.created_by, name: r.created_by_name },
    cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
  };
}

async function loadPurchase(tx: Tx, ctx: RequestContext, id: string) {
  const row = await purchaseSelect(tx).where('v.id', '=', id).where('v.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Purchase bill');
  const lines = await tx.selectFrom('purchase_lines').selectAll().where('purchase_id', '=', id).orderBy('line_no').execute();
  const payments = await tx.selectFrom('payment_allocations as a').innerJoin('payments as p', 'p.id', 'a.payment_id')
    .select(['p.id', 'p.number', 'p.payment_date', 'a.amount'])
    .where('a.doc_id', '=', id).where('a.doc_type', '=', 'purchase').where('p.status', '=', 'posted')
    .orderBy('p.payment_date').execute();
  return {
    ...purchaseJson(row),
    settlements: payments.map((p) => ({ kind: 'payment', id: p.id, number: p.number, date: p.payment_date, amount: p.amount })),
    lines: lines.map((l) => ({
      id: l.id, itemId: l.item_id, description: l.description, hsnCode: l.hsn_code, qty: l.qty, unit: l.unit,
      rate: l.rate, discountPct: l.discount_pct, taxableValue: l.taxable_value, gstRate: l.gst_rate,
      cgst: l.cgst, sgst: l.sgst, igst: l.igst, lineTotal: l.line_total,
    })),
  };
}

export async function purchaseRoutes(app: FastifyInstance) {
  app.get('/purchases', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = purchaseSelect(tx).where('v.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('v.location_id', 'in', scope);
      if (q.status) base = base.where('v.status', '=', q.status);
      if (q.from) base = base.where('v.bill_date', '>=', q.from);
      if (q.to) base = base.where('v.bill_date', '<=', q.to);
      if (q.locationId) base = base.where('v.location_id', '=', q.locationId);
      if (q.partyId) base = base.where('v.party_id', '=', q.partyId);
      if (q.paymentStatus === 'paid') base = base.where('v.status', '=', 'posted').whereRef('v.amount_paid', '>=', 'v.net_payable');
      if (q.paymentStatus === 'partial') base = base.where('v.status', '=', 'posted').where('v.amount_paid', '>', 0).whereRef('v.amount_paid', '<', 'v.net_payable');
      if (q.paymentStatus === 'unpaid') base = base.where('v.status', '=', 'posted').where('v.amount_paid', '=', 0).where('v.net_payable', '>', 0);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('v.number', 'ilike', t), eb('v.supplier_invoice_no', 'ilike', t), eb('p.name', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('v.bill_date', 'desc').orderBy('v.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(purchaseJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/purchases/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadPurchase(tx, ctx, id));
  });

  app.post('/purchases/preview', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.create');
    const body = parse(createBody, req.body);
    return ctx.tx(async (tx) => preparedJson(ctx, await prepare(tx, ctx, body), body));
  });

  app.post('/purchases', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('purchases.create');
    const body = parse(createBody, req.body);
    const purchase = await ctx.tx(async (tx) => {
      const p = await prepare(tx, ctx, body);
      const number = await nextNumber(tx, ctx, 'purchase', p.fy);
      const rcmNo = p.reverseCharge ? await nextNumber(tx, ctx, 'rcm_invoice', p.fy) : null;
      const row = await tx.insertInto('purchases').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: p.location.id, party_id: p.party.id, number,
        supplier_invoice_no: body.supplierInvoiceNo ?? null, supplier_invoice_date: body.supplierInvoiceDate ?? null,
        fy: p.fy, bill_date: p.billDate, due_date: p.dueDate, place_of_supply: p.placeOfSupply, supply_type: p.gst.supplyType,
        subtotal: p.gst.subtotal, cgst: p.gst.cgst, sgst: p.gst.sgst, igst: p.gst.igst, round_off: p.roundOff,
        total: p.total, tds_section_id: p.tds?.sectionId ?? null, tds_base: p.tds?.base ?? 0, tds_rate: p.tds?.rate ?? 0,
        tds_amount: p.tdsAmount, reverse_charge: p.reverseCharge, rcm_self_invoice_no: rcmNo, msme_due_date: p.msmeDueDate, notes: body.notes ?? null, created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
        indent_id: body.indentId ?? null,
      }).returning('id').executeTakeFirstOrThrow();

      await tx.insertInto('purchase_lines').values(p.lines.map((l, i) => {
        const g = p.gst.lines[i]!;
        return {
          tenant_id: ctx.tenantId, purchase_id: row.id, line_no: i + 1, item_id: l.item.id, description: l.description,
          hsn_code: l.item.hsn_code, qty: l.qty, unit: l.item.unit, rate: l.rate, discount_pct: l.discountPct,
          taxable_value: g.taxableValue, gst_rate: l.item.gst_rate, cgst: g.cgst, sgst: g.sgst, igst: g.igst, line_total: g.lineTotal,
        };
      })).execute();

      // Tracked items enter stock at their taxable value (GST is claimed separately as input credit).
      const tracked = p.lines.map((l, i) => ({ l, g: p.gst.lines[i]! })).filter((x) => x.l.item.track_stock);
      await lockItems(tx, ctx.companyId, tracked.map((x) => x.l.item.id));
      if (tracked.length) {
        await tx.insertInto('stock_moves').values(tracked.map(({ l, g }) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: p.location.id, item_id: l.item.id, qty: l.qty,
          rate: l.rate, cost_rate: Math.round((g.taxableValue / l.qty) * 10_000) / 10_000, value: g.taxableValue,
          ref_type: 'purchase', ref_id: row.id, note: number, created_by: ctx.userId,
        }))).execute();
      }

      const acc = await systemAccounts(tx, ctx);
      const stockValue = tracked.reduce((s, x) => s + x.g.taxableValue, 0);
      const loc = p.location.id;
      await postJournal(tx, auditOf(ctx), {
        date: p.billDate, voucherType: 'purchase', voucherId: row.id, number,
        narration: `Purchase from ${p.party.name}${body.supplierInvoiceNo ? ` (bill ${body.supplierInvoiceNo})` : ''}`,
        lines: [
          { accountId: acc.inventory, amount: stockValue, locationId: loc },
          { accountId: acc.purchases_nonstock, amount: p.gst.subtotal - stockValue, locationId: loc },
          { accountId: acc.input_cgst, amount: p.gst.cgst, locationId: loc },
          { accountId: acc.input_sgst, amount: p.gst.sgst, locationId: loc },
          { accountId: acc.input_igst, amount: p.gst.igst, locationId: loc },
          { accountId: acc.round_off, amount: p.roundOff, locationId: loc },
          { accountId: acc.payables, amount: -p.netPayable, partyId: p.party.id, locationId: loc },
          { accountId: acc.tds_payable, amount: -p.tdsAmount, locationId: loc },
          { accountId: acc.rcm_payable, amount: p.reverseCharge ? -p.gst.taxTotal : 0, locationId: loc },
        ],
      });
      if (p.tds) {
        await insertDeduction(tx, ctx, {
          sourceType: 'purchase', sourceId: row.id, number, date: p.billDate, partyId: p.party.id, sectionId: p.tds.sectionId,
          sectionCode: p.tds.sectionCode, gross: p.tds.gross, base: p.tds.base, rate: p.tds.rate, amount: p.tds.amount,
        });
      }

      if (body.indentId) {
        await fulfilIndent(tx, ctx, body.indentId, { type: 'purchase', id: row.id, locationId: p.location.id },
          p.lines.map((l) => ({ itemId: l.item.id, qty: l.qty })));
      }
      const saved = await loadPurchase(tx, ctx, row.id);
      await writeAudit(tx, auditOf(ctx), 'purchase', row.id, 'create', null,
        { number, total: saved.total, partyId: saved.partyId, locationId: saved.locationId });
      return saved;
    });
    return reply.status(201).send(purchase);
  });

  app.post<{ Params: { id: string } }>('/purchases/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchases.cancel');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const current = await tx.selectFrom('purchases').select(['id', 'status', 'location_id', 'number', 'amount_paid', 'indent_id'])
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!current || !ctx.canAccessLocation(current.location_id)) throw notFound('Purchase bill');
      if (current.status === 'cancelled') throw conflict('This bill is already cancelled.', 'ALREADY_CANCELLED');
      if (current.amount_paid > 0) throw conflict('Payments are applied to this bill. Cancel them first.', 'HAS_SETTLEMENTS');

      const moves = await tx.selectFrom('stock_moves as m').innerJoin('items as i', 'i.id', 'm.item_id')
        .select(['m.item_id', 'm.location_id', 'm.qty', 'm.rate', 'm.cost_rate', 'm.value', 'i.name', 'i.unit'])
        .where('m.ref_type', '=', 'purchase').where('m.ref_id', '=', id).execute();
      await lockItems(tx, ctx.companyId, moves.map((m) => m.item_id));
      const location = await getLocation(tx, ctx, current.location_id);
      const perItem = new Map<string, { name: string; unit: string; qty: number }>();
      for (const m of moves) {
        const e = perItem.get(m.item_id) ?? { name: m.name, unit: m.unit, qty: 0 };
        e.qty += m.qty;
        perItem.set(m.item_id, e);
      }
      for (const [itemId, e] of perItem) await requireStock(tx, ctx, location, { id: itemId, ...e }, e.qty);

      await cancelDeduction(tx, 'purchase', id);
      await tx.updateTable('purchases').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason })
        .where('id', '=', id).execute();
      if (moves.length) {
        await tx.insertInto('stock_moves').values(moves.map((m) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: m.location_id, item_id: m.item_id, qty: -m.qty,
          rate: m.rate, cost_rate: m.cost_rate, value: -m.value, ref_type: 'purchase_cancel', ref_id: id,
          note: `Cancelled ${current.number}`, created_by: ctx.userId,
        }))).execute();
      }
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${current.number}: ${reason}`);
      await reverseFulfilment(tx, ctx, current.indent_id, id);
      await writeAudit(tx, auditOf(ctx), 'purchase', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return loadPurchase(tx, ctx, id);
    });
  });
}
