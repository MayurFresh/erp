import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { systemAccounts } from '../accounting/accounts.ts';
import { issue, lockItems, positions } from '../accounting/costing.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import { addDays, financialYear, invoiceNumber, isValidDate, todayIst } from '../lib/dates.ts';
import { paymentInfo } from '../lib/docs.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { assertGstRates } from '../lib/rates.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { requireStock } from './stock.ts';

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
  invoiceDate: docDate.optional(),
  notes: optionalText(1000),
  lines: z.array(lineBody).min(1, 'Add at least one line').max(200, 'At most 200 lines'),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(['posted', 'cancelled']).optional(),
  from: dateField.optional(),
  to: dateField.optional(),
  locationId: z.uuid().optional(),
  partyId: z.uuid().optional(),
  paymentStatus: z.enum(['unpaid', 'partial', 'paid']).optional(),
});

type CreateBody = z.infer<typeof createBody>;

/** Validates the request against the database and computes all GST figures. Saves nothing. */
async function prepare(tx: Tx, ctx: RequestContext, body: CreateBody) {
  const location = await getLocation(tx, ctx, body.locationId);
  if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });

  const party = await tx.selectFrom('parties').selectAll()
    .where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!party) throw badRequest('Customer not found.', { partyId: 'Not found' });
  if (party.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });

  const invoiceDate = body.invoiceDate ?? todayIst();
  if (invoiceDate > todayIst()) throw badRequest('Invoice date cannot be in the future.', { invoiceDate: 'In the future' });

  const ids = [...new Set(body.lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').selectAll()
    .where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const byId = new Map(items.map((i) => [i.id, i]));
  const lines = body.lines.map((l, idx) => {
    const item = byId.get(l.itemId);
    if (!item) throw badRequest(`Line ${idx + 1}: item not found.`, { [`lines.${idx}.itemId`]: 'Not found' });
    if (!item.is_active) throw badRequest(`Line ${idx + 1}: ${item.name} is inactive.`, { [`lines.${idx}.itemId`]: 'Inactive' });
    return { item, qty: l.qty, rate: l.rate ?? item.sale_price, discountPct: l.discountPct ?? 0, description: l.description ?? item.name };
  });

  await assertGstRates(tx, invoiceDate, lines.map((l, idx) => ({
    rate: l.item.gst_rate, hsn: l.item.hsn_code, field: `lines.${idx}.itemId`, label: `${l.item.name} (line ${idx + 1})`,
  })));

  const placeOfSupply = party.state_code ?? location.state_code;
  const gst = computeGst(location.state_code, placeOfSupply, lines.map((l) => ({
    qty: l.qty, rate: l.rate, discountPct: l.discountPct, gstRate: l.item.gst_rate,
  })));
  return {
    location, party, invoiceDate, dueDate: addDays(invoiceDate, party.credit_days), fy: financialYear(invoiceDate),
    placeOfSupply, lines, gst,
  };
}

type Prepared = Awaited<ReturnType<typeof prepare>>;

function preparedJson(ctx: RequestContext, p: Prepared) {
  return {
    id: null, companyId: ctx.companyId, locationId: p.location.id, locationName: p.location.name,
    partyId: p.party.id, partyName: p.party.name, partyGstin: p.party.gstin, number: null, fy: p.fy,
    invoiceDate: p.invoiceDate, dueDate: p.dueDate, placeOfSupply: p.placeOfSupply, supplyType: p.gst.supplyType, status: 'posted',
    subtotal: p.gst.subtotal, cgst: p.gst.cgst, sgst: p.gst.sgst, igst: p.gst.igst, taxTotal: p.gst.taxTotal,
    roundOff: p.gst.roundOff, total: p.gst.total, ...paymentInfo(p.gst.total, 0, 'posted'), notes: null, createdAt: new Date(),
    createdBy: { id: ctx.userId, name: ctx.userName }, cancelledAt: null, cancelReason: null, einvoice: null, ewaybill: null,
    lines: p.lines.map((l, i) => ({
      id: null, itemId: l.item.id, description: l.description, hsnCode: l.item.hsn_code, qty: l.qty, unit: l.item.unit,
      rate: l.rate, discountPct: l.discountPct, gstRate: l.item.gst_rate, ...p.gst.lines[i]!, returnedQty: 0,
    })),
  };
}

function invoiceSelect(tx: Tx) {
  return tx.selectFrom('invoices as v')
    .innerJoin('locations as l', 'l.id', 'v.location_id')
    .innerJoin('parties as p', 'p.id', 'v.party_id')
    .innerJoin('users as u', 'u.id', 'v.created_by')
    .selectAll('v')
    .select(['l.name as location_name', 'p.name as party_name', 'p.gstin as party_gstin', 'u.name as created_by_name']);
}

type InvoiceRow = Awaited<ReturnType<ReturnType<typeof invoiceSelect>['executeTakeFirstOrThrow']>>;

function invoiceJson(r: InvoiceRow) {
  return {
    id: r.id, companyId: r.company_id, locationId: r.location_id, locationName: r.location_name, partyId: r.party_id,
    partyName: r.party_name, partyGstin: r.party_gstin, number: r.number, fy: r.fy, invoiceDate: r.invoice_date,
    dueDate: r.due_date, placeOfSupply: r.place_of_supply, supplyType: r.supply_type, status: r.status, subtotal: r.subtotal,
    cgst: r.cgst, sgst: r.sgst, igst: r.igst, taxTotal: Math.round((r.cgst + r.sgst + r.igst) * 100) / 100,
    roundOff: r.round_off, total: r.total, ...paymentInfo(r.total, r.amount_paid, r.status), notes: r.notes, createdAt: r.created_at,
    createdBy: { id: r.created_by, name: r.created_by_name }, cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
    einvoice: r.irn ? {
      irn: r.irn, ackNo: r.irn_ack_no, ackDate: r.irn_ack_date, signedQrCode: r.irn_signed_qr, status: r.irn_status,
      sandbox: r.irn_sandbox, cancelledAt: r.irn_cancelled_at, cancelReason: r.irn_cancel_reason,
    } : null,
    ewaybill: r.ewb_no ? {
      ewbNo: r.ewb_no, ewbDate: r.ewb_date, validUntil: r.ewb_valid_until, status: r.ewb_status,
      transportMode: r.ewb_transport_mode, vehicleNo: r.ewb_vehicle_no, distanceKm: r.ewb_distance_km,
      transporterGstin: r.ewb_transporter_gstin, cancelledAt: r.ewb_cancelled_at,
    } : null,
  };
}

async function loadInvoice(tx: Tx, ctx: RequestContext, id: string) {
  const row = await invoiceSelect(tx).where('v.id', '=', id).where('v.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Invoice');
  const lines = await tx.selectFrom('invoice_lines').selectAll().where('invoice_id', '=', id).orderBy('line_no').execute();
  const receipts = await tx.selectFrom('payment_allocations as a').innerJoin('payments as p', 'p.id', 'a.payment_id')
    .select(['p.id', 'p.number', 'p.payment_date', 'a.amount'])
    .where('a.doc_id', '=', id).where('a.doc_type', '=', 'invoice').where('p.status', '=', 'posted').execute();
  const notes = await tx.selectFrom('credit_notes').select(['id', 'number', 'note_date', 'applied_amount'])
    .where('invoice_id', '=', id).where('status', '=', 'posted').where('applied_amount', '>', 0).execute();
  const settlements = [
    ...receipts.map((r) => ({ kind: 'receipt', id: r.id, number: r.number, date: r.payment_date, amount: r.amount })),
    ...notes.map((n) => ({ kind: 'credit_note', id: n.id, number: n.number, date: n.note_date, amount: n.applied_amount })),
  ].sort((a, b) => a.date.localeCompare(b.date));
  return {
    ...invoiceJson(row),
    settlements,
    lines: lines.map((l) => ({
      id: l.id, itemId: l.item_id, description: l.description, hsnCode: l.hsn_code, qty: l.qty, unit: l.unit,
      rate: l.rate, discountPct: l.discount_pct, taxableValue: l.taxable_value, gstRate: l.gst_rate,
      cgst: l.cgst, sgst: l.sgst, igst: l.igst, lineTotal: l.line_total, returnedQty: l.returned_qty,
    })),
  };
}

export { invoiceJson, invoiceSelect, loadInvoice };

export async function invoiceRoutes(app: FastifyInstance) {
  app.get('/invoices', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = invoiceSelect(tx).where('v.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('v.location_id', 'in', scope);
      if (q.status) base = base.where('v.status', '=', q.status);
      if (q.from) base = base.where('v.invoice_date', '>=', q.from);
      if (q.to) base = base.where('v.invoice_date', '<=', q.to);
      if (q.locationId) base = base.where('v.location_id', '=', q.locationId);
      if (q.partyId) base = base.where('v.party_id', '=', q.partyId);
      if (q.paymentStatus === 'paid') base = base.where('v.status', '=', 'posted').whereRef('v.amount_paid', '>=', 'v.total');
      if (q.paymentStatus === 'partial') base = base.where('v.status', '=', 'posted').where('v.amount_paid', '>', 0).whereRef('v.amount_paid', '<', 'v.total');
      if (q.paymentStatus === 'unpaid') base = base.where('v.status', '=', 'posted').where('v.amount_paid', '=', 0).where('v.total', '>', 0);
      if (q.q) base = base.where((eb) => eb.or([eb('v.number', 'ilike', likeTerm(q.q!)), eb('p.name', 'ilike', likeTerm(q.q!))]));
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('v.invoice_date', 'desc').orderBy('v.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(invoiceJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/invoices/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadInvoice(tx, ctx, id));
  });

  app.post('/invoices/preview', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.create');
    const body = parse(createBody, req.body);
    return ctx.tx(async (tx) => preparedJson(ctx, await prepare(tx, ctx, body)));
  });

  app.post('/invoices', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('invoices.create');
    const body = parse(createBody, req.body);
    const invoice = await ctx.tx(async (tx) => {
      const p = await prepare(tx, ctx, body);

      // Stock check and cost of goods sold for tracked items, holding locks until commit.
      const tracked = p.lines.filter((l) => l.item.track_stock);
      await lockItems(tx, ctx.companyId, tracked.map((l) => l.item.id));
      const needed = new Map<string, number>();
      for (const l of tracked) needed.set(l.item.id, Math.round(((needed.get(l.item.id) ?? 0) + l.qty) * 1000) / 1000);
      for (const [itemId, qty] of needed) {
        const item = tracked.find((l) => l.item.id === itemId)!.item;
        await requireStock(tx, ctx, p.location, item, qty);
      }
      const pos = await positions(tx, ctx.companyId, [...needed.keys()]);
      const costs = tracked.map((l) => {
        const out = issue(pos.get(l.item.id)!, l.qty, l.item.purchase_price);
        pos.set(l.item.id, out.after);
        return { line: l, ...out };
      });

      // Gapless number: the series row stays locked until this transaction ends.
      const series = await tx.insertInto('invoice_series')
        .values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, fy: p.fy, next_no: 2 })
        .onConflict((oc) => oc.columns(['company_id', 'fy']).doUpdateSet((eb) => ({ next_no: eb('invoice_series.next_no', '+', 1) })))
        .returning('next_no')
        .executeTakeFirstOrThrow();
      const number = invoiceNumber(p.fy, series.next_no - 1);

      const inv = await tx.insertInto('invoices').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: p.location.id, party_id: p.party.id, number,
        fy: p.fy, invoice_date: p.invoiceDate, due_date: p.dueDate, place_of_supply: p.placeOfSupply, supply_type: p.gst.supplyType,
        subtotal: p.gst.subtotal, cgst: p.gst.cgst, sgst: p.gst.sgst, igst: p.gst.igst, round_off: p.gst.roundOff,
        total: p.gst.total, notes: body.notes ?? null, created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();

      await tx.insertInto('invoice_lines').values(p.lines.map((l, i) => {
        const g = p.gst.lines[i]!;
        return {
          tenant_id: ctx.tenantId, invoice_id: inv.id, line_no: i + 1, item_id: l.item.id, description: l.description,
          hsn_code: l.item.hsn_code, qty: l.qty, unit: l.item.unit, rate: l.rate, discount_pct: l.discountPct,
          taxable_value: g.taxableValue, gst_rate: l.item.gst_rate, cgst: g.cgst, sgst: g.sgst, igst: g.igst, line_total: g.lineTotal,
        };
      })).execute();

      if (costs.length) {
        await tx.insertInto('stock_moves').values(costs.map((c) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: p.location.id, item_id: c.line.item.id,
          qty: -c.line.qty, rate: c.line.rate, cost_rate: c.costRate, value: -c.value, ref_type: 'invoice', ref_id: inv.id,
          note: number, created_by: ctx.userId,
        }))).execute();
      }

      const acc = await systemAccounts(tx, ctx);
      const cogs = costs.reduce((sum, c) => sum + c.value, 0);
      const loc = p.location.id;
      await postJournal(tx, auditOf(ctx), {
        date: p.invoiceDate, voucherType: 'sales', voucherId: inv.id, number, narration: `Sales to ${p.party.name}`,
        lines: [
          { accountId: acc.receivables, amount: p.gst.total, partyId: p.party.id, locationId: loc },
          { accountId: acc.sales, amount: -p.gst.subtotal, locationId: loc },
          { accountId: acc.output_cgst, amount: -p.gst.cgst, locationId: loc },
          { accountId: acc.output_sgst, amount: -p.gst.sgst, locationId: loc },
          { accountId: acc.output_igst, amount: -p.gst.igst, locationId: loc },
          { accountId: acc.round_off, amount: -p.gst.roundOff, locationId: loc },
          { accountId: acc.cogs, amount: cogs, locationId: loc },
          { accountId: acc.inventory, amount: -cogs, locationId: loc },
        ],
      });

      const saved = await loadInvoice(tx, ctx, inv.id);
      await writeAudit(tx, auditOf(ctx), 'invoice', inv.id, 'create', null,
        { number, total: saved.total, partyId: saved.partyId, locationId: saved.locationId });
      return saved;
    });
    return reply.status(201).send(invoice);
  });

  app.post<{ Params: { id: string } }>('/invoices/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.cancel');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const current = await tx.selectFrom('invoices').select(['id', 'status', 'location_id', 'number', 'amount_paid', 'irn_status'])
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!current || !ctx.canAccessLocation(current.location_id)) throw notFound('Invoice');
      if (current.status === 'cancelled') throw conflict('This invoice is already cancelled.', 'ALREADY_CANCELLED');
      if (current.irn_status === 'active') {
        throw conflict('This invoice has an active IRN. Cancel the IRN first (within 24 hours) or issue a credit note.', 'IRN_ACTIVE');
      }
      const notes = await tx.selectFrom('credit_notes').select('id').where('invoice_id', '=', id).where('status', '=', 'posted').executeTakeFirst();
      if (current.amount_paid > 0 || notes) {
        throw conflict('Receipts or credit notes are applied to this invoice. Cancel them first.', 'HAS_SETTLEMENTS');
      }

      await tx.updateTable('invoices').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason })
        .where('id', '=', id).execute();
      const moves = await tx.selectFrom('stock_moves').selectAll()
        .where('ref_type', '=', 'invoice').where('ref_id', '=', id).execute();
      if (moves.length) {
        await lockItems(tx, ctx.companyId, moves.map((m) => m.item_id));
        await tx.insertInto('stock_moves').values(moves.map((m) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: m.location_id, item_id: m.item_id, qty: -m.qty,
          rate: m.rate, cost_rate: m.cost_rate, value: -m.value, ref_type: 'invoice_cancel', ref_id: id,
          note: `Cancelled ${current.number}`, created_by: ctx.userId,
        }))).execute();
      }
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${current.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'invoice', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return loadInvoice(tx, ctx, id);
    });
  });
}
