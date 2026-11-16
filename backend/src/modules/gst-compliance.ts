import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { einvoiceState, EINVOICE_WARN_FROM_DAY, EINVOICE_WINDOW_DAYS, ewbValidity, proposeSlab, RATE_HISTORY_START, SLAB_EFFECTIVE_FROM } from '../lib/gst-compliance.ts';
import { percentField } from '../lib/numbers.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { documentRoute } from '../lib/openapi.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const periodField = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM');

// ---- IMS -------------------------------------------------------------------------------------

export type ImsBucket = 'pending' | 'not_in_books' | 'in_books_rejected' | 'in_books_accepted';

/** Pending first, then documents with no purchase, then rejected, else accepted (a missing action is deemed accepted). */
export function imsBucket(action: string, purchaseId: string | null): ImsBucket {
  if (action === 'pending') return 'pending';
  if (!purchaseId) return 'not_in_books';
  if (action === 'reject') return 'in_books_rejected';
  return 'in_books_accepted';
}

/** Tax of posted, non-RCM purchases dated in the period that are linked to a rejected or pending 2B line. */
export async function imsExcludedItc(tx: Tx, companyId: string, period: string) {
  const from = `${period}-01`;
  const to = lastDay(period);
  const rows = await tx.selectFrom('gst_2b_lines as l').innerJoin('gst_2b_imports as i', 'i.id', 'l.import_id')
    .innerJoin('purchases as v', 'v.id', 'l.purchase_id')
    .select(['v.id', 'v.subtotal', 'v.igst', 'v.cgst', 'v.sgst'])
    .where('l.company_id', '=', companyId).where('i.period', '=', period).where('l.ims_action', 'in', ['reject', 'pending'])
    .where('v.status', '=', 'posted').where('v.reverse_charge', '=', false).where('v.bill_date', '>=', from).where('v.bill_date', '<=', to).execute();
  const seen = new Set<string>();
  let t = { taxable: 0, igst: 0, cgst: 0, sgst: 0 };
  for (const r of rows) {
    if (seen.has(r.id)) continue;
    seen.add(r.id);
    t = { taxable: round2(t.taxable + r.subtotal), igst: round2(t.igst + r.igst), cgst: round2(t.cgst + r.cgst), sgst: round2(t.sgst + r.sgst) };
  }
  return t;
}
function lastDay(period: string) {
  const [y, m] = period.split('-').map(Number) as [number, number];
  return `${period}-${String(new Date(Date.UTC(y, m, 0)).getUTCDate()).padStart(2, '0')}`;
}

// ---- 43B(h) ----------------------------------------------------------------------------------

/** Amounts owed to micro and small vendors beyond the time limit and unpaid on 31 March of the tax year. */
export async function msme43bh(tx: Tx, companyId: string, taxYear: string) {
  const asOf = `${Number(taxYear.slice(0, 4)) + 1}-03-31`;
  const bills = await tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id')
    .select(['v.id', 'v.number', 'v.bill_date', 'v.msme_due_date', 'v.net_payable', 'p.id as party_id', 'p.name', 'p.udyam_no', 'p.msme_category'])
    .where('v.company_id', '=', companyId).where('v.status', '=', 'posted').where('v.bill_date', '<=', asOf)
    .where('p.msme_category', 'in', ['micro', 'small']).execute();
  const due = (b: (typeof bills)[number]) => b.msme_due_date ?? addDays(b.bill_date, 15);
  const late = bills.filter((b) => due(b) < asOf);
  const paid = late.length
    ? await tx.selectFrom('payment_allocations as a').innerJoin('payments as y', 'y.id', 'a.payment_id')
      .select(['a.doc_id', (eb) => eb.fn.sum<number>('a.amount').as('paid')]).where('a.doc_type', '=', 'purchase')
      .where('a.doc_id', 'in', late.map((b) => b.id)).where('y.status', '=', 'posted').where('y.payment_date', '<=', asOf).groupBy('a.doc_id').execute()
    : [];
  const paidBy = new Map(paid.map((p) => [p.doc_id, Number(p.paid)]));
  const rows = late.map((b) => {
    const p = paidBy.get(b.id) ?? 0;
    return {
      purchaseId: b.id, number: b.number, billDate: b.bill_date, dueDate: due(b), partyId: b.party_id, partyName: b.name, udyamNo: b.udyam_no,
      category: b.msme_category, total: Number(b.net_payable), paidByYearEnd: round2(p), outstanding: round2(Math.max(0, Number(b.net_payable) - p)),
      daysOverdue: daysBetween(due(b), asOf),
    };
  }).filter((r) => r.outstanding > 0.004).sort((a, b) => a.dueDate.localeCompare(b.dueDate));
  return { taxYear, asOf, rows, total: round2(rows.reduce((s, r) => s + r.outstanding, 0)) };
}

// ---- Routes ----------------------------------------------------------------------------------

const imsBody = z.object({
  ids: z.array(z.uuid()).min(1).max(500), action: z.enum(['accept', 'reject', 'pending', 'none']), reason: z.string().trim().max(300).optional(),
});
const rateBody = z.object({ rate: percentField, effectiveFrom: dateField, reason: z.string().trim().max(200).optional() });
const applyBody = z.object({
  effectiveFrom: dateField, items: z.array(z.object({ itemId: z.uuid(), newRate: percentField })).min(1).max(500),
});

export async function gstComplianceRoutes(app: FastifyInstance) {
  app.post('/gst/ims/actions', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const b = parse(imsBody, req.body);
    if ((b.action === 'reject' || b.action === 'pending') && (b.reason ?? '').length < 3) {
      throw badRequest('Give a reason for this action.', { reason: 'Required for reject and pending' });
    }
    return ctx.tx(async (tx) => {
      const found = await tx.selectFrom('gst_2b_lines').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', b.ids).execute();
      if (!found.length) throw notFound('2B document');
      const none = b.action === 'none';
      await tx.updateTable('gst_2b_lines').set({
        ims_action: b.action, ims_reason: none || b.action === 'accept' ? (b.reason ?? null) : b.reason!,
        ims_acted_at: none ? null : new Date(), ims_acted_by: none ? null : ctx.userId,
      }).where('company_id', '=', ctx.companyId).where('id', 'in', found.map((f) => f.id)).execute();
      await writeAudit(tx, auditOf(ctx), 'gst_2b_ims', found[0]!.id, 'ims_action', null, { action: b.action, count: found.length, reason: b.reason ?? null });
      return { updated: found.length };
    });
  });

  app.get('/gst/ims', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ period: periodField, bucket: z.enum(['pending', 'not_in_books', 'in_books_rejected', 'in_books_accepted']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      const imp = await tx.selectFrom('gst_2b_imports').select(['id', 'created_at']).where('company_id', '=', ctx.companyId).where('period', '=', q.period).executeTakeFirst();
      const empty = () => ({ count: 0, itc: 0 });
      const summary = { inBooksAccepted: empty(), inBooksRejected: empty(), pending: empty(), notInBooks: empty(), deemedAccepted: 0 };
      if (!imp) return { period: q.period, importedAt: null, summary, rows: [] };
      const lines = await tx.selectFrom('gst_2b_lines as l').leftJoin('purchases as v', 'v.id', 'l.purchase_id')
        .select(['l.id', 'l.supplier_gstin', 'l.supplier_name', 'l.doc_type', 'l.doc_no', 'l.doc_date', 'l.taxable', 'l.igst', 'l.cgst', 'l.sgst', 'l.purchase_id',
          'l.match_status', 'l.ims_action', 'l.ims_reason', 'l.ims_acted_at', 'v.number as purchase_number'])
        .where('l.import_id', '=', imp.id).orderBy('l.supplier_gstin').orderBy('l.doc_no').execute();
      const rows = lines.map((l) => {
        const bucket = imsBucket(l.ims_action, l.purchase_id);
        const itc = round2((Number(l.igst) + Number(l.cgst) + Number(l.sgst)) * (l.doc_type === 'credit_note' ? -1 : 1));
        const key = bucket === 'pending' ? 'pending' : bucket === 'not_in_books' ? 'notInBooks' : bucket === 'in_books_rejected' ? 'inBooksRejected' : 'inBooksAccepted';
        summary[key].count++; summary[key].itc = round2(summary[key].itc + itc);
        const deemed = l.ims_action === 'none';
        if (deemed && bucket !== 'pending') summary.deemedAccepted++;
        return {
          id: l.id, bucket, deemed, imsAction: l.ims_action, imsReason: l.ims_reason, imsActedAt: l.ims_acted_at, supplierGstin: l.supplier_gstin,
          supplierName: l.supplier_name, docType: l.doc_type, docNo: l.doc_no, docDate: l.doc_date, taxable: Number(l.taxable), igst: Number(l.igst),
          cgst: Number(l.cgst), sgst: Number(l.sgst), purchaseId: l.purchase_id, purchaseNumber: l.purchase_number, matchStatus: l.match_status,
        };
      });
      return { period: q.period, importedAt: imp.created_at, summary, rows: q.bucket ? rows.filter((r) => r.bucket === q.bucket) : rows };
    });
  });

  app.get('/gst/einvoice/unreported', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ asOf: dateField.optional() }), req.query);
    const asOf = q.asOf ?? todayIst();
    return ctx.tx(async (tx) => {
      const co = await tx.selectFrom('companies').select('aato_band').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const rows = await tx.selectFrom('invoices as i').innerJoin('parties as p', 'p.id', 'i.party_id')
        .select(['i.id', 'i.number', 'i.invoice_date', 'i.total', 'i.location_id', 'p.name', 'p.gstin'])
        .where('i.company_id', '=', ctx.companyId).where('i.status', '<>', 'cancelled').where((eb) => eb.or([eb('i.irn_status', 'is', null), eb('i.irn_status', '<>', 'active')]))
        .where('p.gstin', 'is not', null).where('i.invoice_date', '<=', asOf).orderBy('i.invoice_date').execute();
      const out = rows.filter((r) => ctx.canAccessLocation(r.location_id)).map((r) => {
        const ageDays = daysBetween(r.invoice_date, asOf);
        return {
          invoiceId: r.id, number: r.number, date: r.invoice_date, partyName: r.name, gstin: r.gstin, total: Number(r.total), ageDays,
          lastDay: addDays(r.invoice_date, EINVOICE_WINDOW_DAYS), state: einvoiceState(co.aato_band, ageDays),
        };
      });
      const count = (s: string) => out.filter((r) => r.state === s).length;
      return { asOf, band: co.aato_band, windowDays: EINVOICE_WINDOW_DAYS, warnFromDay: EINVOICE_WARN_FROM_DAY, counts: { ok: count('ok'), warn: count('warn'), blocked: count('blocked') }, rows: out };
    });
  });

  app.get('/gst/ewaybill-validity', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ date: dateField.optional(), distanceKm: z.coerce.number().int().min(0).max(4000) }), req.query);
    const from = q.date ? new Date(`${q.date}T00:00:00+05:30`) : new Date();
    return ewbValidity(from, q.distanceKm);
  });

  // ---- item GST rate history ----
  app.get<{ Params: { id: string } }>('/items/:id/gst-rates', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const item = await tx.selectFrom('items').select(['id', 'gst_rate']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!item) throw notFound('Item');
      const rows = await tx.selectFrom('item_gst_rates').selectAll().where('item_id', '=', id).orderBy('effective_from', 'desc').execute();
      return { currentRate: Number(item.gst_rate), data: rows.map((r) => ({ id: r.id, rate: Number(r.rate), effectiveFrom: r.effective_from, reason: r.reason })) };
    });
  });

  app.post<{ Params: { id: string } }>('/items/:id/gst-rates', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(rateBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const item = await tx.selectFrom('items').select(['id', 'gst_rate']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!item) throw notFound('Item');
      const same = await tx.selectFrom('item_gst_rates').select('id').where('item_id', '=', id).where('effective_from', '=', b.effectiveFrom).executeTakeFirst();
      if (same) throw conflict('This item already has a rate from that date.', 'CONFLICT', { effectiveFrom: 'Already used' });
      await addRateRow(tx, ctx, item, b.rate, b.effectiveFrom, b.reason ?? null);
      await writeAudit(tx, auditOf(ctx), 'item_gst_rate', id, 'create', { rate: Number(item.gst_rate) }, { rate: b.rate, effectiveFrom: b.effectiveFrom });
      return { itemId: id, rate: b.rate, effectiveFrom: b.effectiveFrom };
    });
    return reply.status(201).send(out);
  });

  // ---- September 2025 slab review ----
  app.get('/gst/slab-review', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ effectiveFrom: dateField.default(SLAB_EFFECTIVE_FROM) }), req.query);
    return ctx.tx(async (tx) => {
      const items = await tx.selectFrom('items').select(['id', 'name', 'hsn_code', 'gst_rate']).where('company_id', '=', ctx.companyId)
        .where('is_active', '=', true).where('gst_rate', 'in', [12, 28]).orderBy('name').execute();
      const done = items.length
        ? new Set((await tx.selectFrom('item_gst_rates').select('item_id').where('item_id', 'in', items.map((i) => i.id)).where('effective_from', '=', q.effectiveFrom).execute()).map((r) => r.item_id))
        : new Set<string>();
      return {
        effectiveFrom: q.effectiveFrom,
        note: 'From 22 September 2025 the slabs are 5%, 18% and 40%. These are proposals only; check each against the rate notification for its HSN code.',
        rows: items.map((i) => {
          const p = proposeSlab(Number(i.gst_rate), i.hsn_code);
          return { itemId: i.id, name: i.name, hsnCode: i.hsn_code, currentRate: Number(i.gst_rate), proposedRate: p.proposed, needsCheck: p.needsCheck, reviewed: done.has(i.id) };
        }),
      };
    });
  });

  app.post('/gst/slab-review/apply', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const b = parse(applyBody, req.body);
    if (b.effectiveFrom > todayIst()) throw badRequest('The change date is in the future.', { effectiveFrom: 'In the future' });
    return ctx.tx(async (tx) => {
      const items = await tx.selectFrom('items').select(['id', 'gst_rate']).where('company_id', '=', ctx.companyId).where('id', 'in', b.items.map((i) => i.itemId)).forUpdate().execute();
      const byId = new Map(items.map((i) => [i.id, i]));
      let applied = 0;
      for (const it of b.items) {
        const item = byId.get(it.itemId);
        if (!item) throw badRequest('Item not found.', { itemId: it.itemId });
        const exists = await tx.selectFrom('item_gst_rates').select('id').where('item_id', '=', item.id).where('effective_from', '=', b.effectiveFrom).executeTakeFirst();
        if (exists) continue;
        await addRateRow(tx, ctx, item, it.newRate, b.effectiveFrom, it.newRate === Number(item.gst_rate) ? 'Slab review: kept' : 'Slab review');
        applied++;
      }
      await writeAudit(tx, auditOf(ctx), 'item_gst_rate', items[0]?.id ?? ctx.companyId, 'slab_review', null, { effectiveFrom: b.effectiveFrom, applied });
      return { applied };
    });
  });

  app.get('/reports/msme-43bh', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const q = parse(z.object({ taxYear: z.string().regex(/^\d{4}-\d{2}$/).optional() }), req.query);
    const today = todayIst();
    const y = Number(today.slice(0, 4));
    const endYear = today.slice(5) >= '03-31' ? y : y - 1; // the tax year that ended on the latest 31 March
    const taxYear = q.taxYear ?? `${endYear - 1}-${String(endYear % 100).padStart(2, '0')}`;
    return ctx.tx((tx) => msme43bh(tx, ctx.companyId, taxYear));
  });
}

/** Adds a history row. First history row also records the old rate from the start of GST so earlier dates keep it. */
async function addRateRow(tx: Tx, ctx: { tenantId: string; companyId: string; userId: string }, item: { id: string; gst_rate: number }, rate: number, from: string, reason: string | null) {
  const has = await tx.selectFrom('item_gst_rates').select('id').where('item_id', '=', item.id).limit(1).executeTakeFirst();
  if (!has && from > RATE_HISTORY_START) {
    await tx.insertInto('item_gst_rates').values({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: item.id, rate: Number(item.gst_rate), effective_from: RATE_HISTORY_START, reason: 'Earlier rate', created_by: ctx.userId,
    }).execute();
  }
  await tx.insertInto('item_gst_rates').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: item.id, rate, effective_from: from, reason, created_by: ctx.userId,
  }).execute();
  const latest = await tx.selectFrom('item_gst_rates').select(['rate']).where('item_id', '=', item.id).where('effective_from', '<=', todayIst())
    .orderBy('effective_from', 'desc').limit(1).executeTakeFirst();
  if (latest && Number(latest.rate) !== Number(item.gst_rate)) await tx.updateTable('items').set({ gst_rate: Number(latest.rate) }).where('id', '=', item.id).execute();
}

documentRoute('POST', '/gst/ims/actions', { body: imsBody });
documentRoute('POST', '/items/:id/gst-rates', { body: rateBody });
documentRoute('POST', '/gst/slab-review/apply', { body: applyBody });
