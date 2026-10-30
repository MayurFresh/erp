import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { toCsv } from '../lib/csv.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { notFound } from '../lib/errors.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const query = z.object({ from: dateField.optional(), to: dateField.optional() });

type Table = [string[], unknown[][]];
interface Range { from?: string; to?: string }

/** Each dataset builds a header and rows; scoped users only get rows of their locations. */
const DATASETS: Record<string, (tx: Tx, ctx: RequestContext, r: Range) => Promise<Table>> = {
  async parties(tx, ctx) {
    const rows = await tx.selectFrom('parties as p').leftJoin('tds_sections as s', 's.id', 'p.tds_section_id').selectAll('p').select('s.code as section')
      .where('p.company_id', '=', ctx.companyId).orderBy('p.name').execute();
    return [['type', 'name', 'gstin', 'pan', 'state_code', 'phone', 'email', 'address', 'pincode', 'credit_limit', 'credit_days', 'udyam_no', 'msme_category', 'tds_section'],
      rows.map((r) => [r.type, r.name, r.gstin, r.pan, r.state_code, r.phone, r.email, r.address, r.pincode, r.credit_limit, r.credit_days, r.udyam_no, r.msme_category, r.section])];
  },
  async items(tx, ctx) {
    const rows = await tx.selectFrom('items').selectAll().where('company_id', '=', ctx.companyId).orderBy('name').execute();
    return [['name', 'sku', 'hsn_code', 'unit', 'gst_rate', 'sale_price', 'purchase_price', 'track_stock', 'is_active'],
      rows.map((r) => [r.name, r.sku, r.hsn_code, r.unit, r.gst_rate, r.sale_price, r.purchase_price, r.track_stock, r.is_active])];
  },
  async invoices(tx, ctx, r) {
    let q = tx.selectFrom('invoices as i').innerJoin('parties as p', 'p.id', 'i.party_id').select(['i.number', 'i.invoice_date', 'p.name', 'p.gstin', 'i.place_of_supply', 'i.supply_type', 'i.status',
      'i.subtotal', 'i.cgst', 'i.sgst', 'i.igst', 'i.round_off', 'i.total', 'i.amount_paid', 'i.due_date']).where('i.company_id', '=', ctx.companyId);
    const scope = scopedLocationIds(ctx);
    if (scope) q = q.where('i.location_id', 'in', scope);
    if (r.from) q = q.where('i.invoice_date', '>=', r.from);
    if (r.to) q = q.where('i.invoice_date', '<=', r.to);
    const rows = await q.orderBy('i.invoice_date').orderBy('i.number').execute();
    return [['number', 'date', 'party', 'gstin', 'place_of_supply', 'supply_type', 'status', 'taxable', 'cgst', 'sgst', 'igst', 'round_off', 'total', 'amount_paid', 'due_date'],
      rows.map((x) => [x.number, x.invoice_date, x.name, x.gstin, x.place_of_supply, x.supply_type, x.status, x.subtotal, x.cgst, x.sgst, x.igst, x.round_off, x.total, x.amount_paid, x.due_date])];
  },
  async 'invoice-lines'(tx, ctx, r) {
    let q = tx.selectFrom('invoice_lines as l').innerJoin('invoices as i', 'i.id', 'l.invoice_id').select(['i.number', 'i.invoice_date', 'l.line_no', 'l.description', 'l.hsn_code', 'l.qty', 'l.unit', 'l.rate',
      'l.discount_pct', 'l.taxable_value', 'l.gst_rate', 'l.cgst', 'l.sgst', 'l.igst', 'l.line_total']).where('i.company_id', '=', ctx.companyId);
    const scope = scopedLocationIds(ctx);
    if (scope) q = q.where('i.location_id', 'in', scope);
    if (r.from) q = q.where('i.invoice_date', '>=', r.from);
    if (r.to) q = q.where('i.invoice_date', '<=', r.to);
    const rows = await q.orderBy('i.invoice_date').orderBy('i.number').orderBy('l.line_no').execute();
    return [['invoice_number', 'date', 'line_no', 'description', 'hsn_code', 'qty', 'unit', 'rate', 'discount_pct', 'taxable_value', 'gst_rate', 'cgst', 'sgst', 'igst', 'line_total'],
      rows.map((x) => [x.number, x.invoice_date, x.line_no, x.description, x.hsn_code, x.qty, x.unit, x.rate, x.discount_pct, x.taxable_value, x.gst_rate, x.cgst, x.sgst, x.igst, x.line_total])];
  },
  async purchases(tx, ctx, r) {
    let q = tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id').select(['v.number', 'v.bill_date', 'v.supplier_invoice_no', 'v.supplier_invoice_date', 'p.name', 'p.gstin',
      'v.status', 'v.subtotal', 'v.cgst', 'v.sgst', 'v.igst', 'v.round_off', 'v.total', 'v.tds_amount', 'v.net_payable', 'v.reverse_charge', 'v.amount_paid', 'v.due_date']).where('v.company_id', '=', ctx.companyId);
    const scope = scopedLocationIds(ctx);
    if (scope) q = q.where('v.location_id', 'in', scope);
    if (r.from) q = q.where('v.bill_date', '>=', r.from);
    if (r.to) q = q.where('v.bill_date', '<=', r.to);
    const rows = await q.orderBy('v.bill_date').orderBy('v.number').execute();
    return [['number', 'date', 'supplier_invoice_no', 'supplier_invoice_date', 'party', 'gstin', 'status', 'taxable', 'cgst', 'sgst', 'igst', 'round_off', 'total', 'tds_amount', 'net_payable', 'reverse_charge', 'amount_paid', 'due_date'],
      rows.map((x) => [x.number, x.bill_date, x.supplier_invoice_no, x.supplier_invoice_date, x.name, x.gstin, x.status, x.subtotal, x.cgst, x.sgst, x.igst, x.round_off, x.total, x.tds_amount, x.net_payable, x.reverse_charge, x.amount_paid, x.due_date])];
  },
  async 'purchase-lines'(tx, ctx, r) {
    let q = tx.selectFrom('purchase_lines as l').innerJoin('purchases as v', 'v.id', 'l.purchase_id').select(['v.number', 'v.bill_date', 'l.line_no', 'l.description', 'l.hsn_code', 'l.qty', 'l.unit', 'l.rate',
      'l.discount_pct', 'l.taxable_value', 'l.gst_rate', 'l.cgst', 'l.sgst', 'l.igst', 'l.line_total']).where('v.company_id', '=', ctx.companyId);
    const scope = scopedLocationIds(ctx);
    if (scope) q = q.where('v.location_id', 'in', scope);
    if (r.from) q = q.where('v.bill_date', '>=', r.from);
    if (r.to) q = q.where('v.bill_date', '<=', r.to);
    const rows = await q.orderBy('v.bill_date').orderBy('v.number').orderBy('l.line_no').execute();
    return [['purchase_number', 'date', 'line_no', 'description', 'hsn_code', 'qty', 'unit', 'rate', 'discount_pct', 'taxable_value', 'gst_rate', 'cgst', 'sgst', 'igst', 'line_total'],
      rows.map((x) => [x.number, x.bill_date, x.line_no, x.description, x.hsn_code, x.qty, x.unit, x.rate, x.discount_pct, x.taxable_value, x.gst_rate, x.cgst, x.sgst, x.igst, x.line_total])];
  },
  async payments(tx, ctx, r) {
    let q = tx.selectFrom('payments as y').innerJoin('parties as p', 'p.id', 'y.party_id').innerJoin('accounts as a', 'a.id', 'y.account_id')
      .select(['y.number', 'y.payment_date', 'y.kind', 'p.name', 'a.name as account', 'y.mode', 'y.reference', 'y.amount', 'y.tds_amount', 'y.status', 'y.notes']).where('y.company_id', '=', ctx.companyId);
    if (r.from) q = q.where('y.payment_date', '>=', r.from);
    if (r.to) q = q.where('y.payment_date', '<=', r.to);
    const rows = await q.orderBy('y.payment_date').orderBy('y.number').execute();
    return [['number', 'date', 'kind', 'party', 'account', 'mode', 'reference', 'amount', 'tds_amount', 'status', 'notes'],
      rows.map((x) => [x.number, x.payment_date, x.kind, x.name, x.account, x.mode, x.reference, x.amount, x.tds_amount, x.status, x.notes])];
  },
  async expenses(tx, ctx, r) {
    let q = tx.selectFrom('expenses as e').innerJoin('accounts as a', 'a.id', 'e.account_id').leftJoin('parties as p', 'p.id', 'e.party_id')
      .select(['e.number', 'e.expense_date', 'a.name as account', 'p.name as party', 'e.description', 'e.amount', 'e.gst_rate', 'e.cgst', 'e.sgst', 'e.igst', 'e.total', 'e.tds_amount', 'e.reverse_charge', 'e.status'])
      .where('e.company_id', '=', ctx.companyId);
    const scope = scopedLocationIds(ctx);
    if (scope) q = q.where('e.location_id', 'in', scope);
    if (r.from) q = q.where('e.expense_date', '>=', r.from);
    if (r.to) q = q.where('e.expense_date', '<=', r.to);
    const rows = await q.orderBy('e.expense_date').orderBy('e.number').execute();
    return [['number', 'date', 'account', 'party', 'description', 'amount', 'gst_rate', 'cgst', 'sgst', 'igst', 'total', 'tds_amount', 'reverse_charge', 'status'],
      rows.map((x) => [x.number, x.expense_date, x.account, x.party, x.description, x.amount, x.gst_rate, x.cgst, x.sgst, x.igst, x.total, x.tds_amount, x.reverse_charge, x.status])];
  },
  async journal(tx, ctx, r) {
    let q = tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id').innerJoin('accounts as a', 'a.id', 'jl.account_id')
      .leftJoin('parties as p', 'p.id', 'jl.party_id')
      .select(['je.entry_date', 'je.voucher_type', 'je.number', 'a.code', 'a.name as account', 'p.name as party', 'jl.debit', 'jl.credit', 'je.narration'])
      .where('je.company_id', '=', ctx.companyId);
    const scope = scopedLocationIds(ctx);
    if (scope) q = q.where('jl.location_id', 'in', scope);
    if (r.from) q = q.where('je.entry_date', '>=', r.from);
    if (r.to) q = q.where('je.entry_date', '<=', r.to);
    const rows = await q.orderBy('je.entry_date').orderBy('je.created_at').orderBy('jl.line_no').execute();
    return [['date', 'voucher_type', 'number', 'account_code', 'account_name', 'party', 'debit', 'credit', 'narration'],
      rows.map((x) => [x.entry_date, x.voucher_type, x.number, x.code, x.account, x.party, x.debit, x.credit, x.narration])];
  },
};

export async function exportRoutes(app: FastifyInstance) {
  app.get<{ Params: { dataset: string } }>('/export/:dataset', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('data.export');
    const build = Object.hasOwn(DATASETS, req.params.dataset) ? DATASETS[req.params.dataset] : undefined;
    if (!build) throw notFound('Dataset');
    const q = parse(query, req.query);
    const [header, rows] = await ctx.tx((tx) => build(tx, ctx, q));
    return reply.header('content-disposition', `attachment; filename="${req.params.dataset}-${todayIst()}.csv"`)
      .type('text/csv; charset=utf-8').send(toCsv(header, rows));
  });
}
