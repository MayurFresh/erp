import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { lockItems } from '../accounting/costing.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { requireStock } from './stock.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const round3 = (n: number) => Math.round(n * 1000) / 1000;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const createBody = z.object({
  invoiceId: z.uuid(),
  noteDate: dateField.optional(),
  reason: z.string().trim().min(3, 'Give a reason').max(300),
  restock: z.boolean().optional(),
  lines: z.array(z.object({ invoiceLineId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero') }))
    .min(1, 'Choose at least one line').max(200),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(['posted', 'cancelled']).optional(),
  from: dateField.optional(),
  to: dateField.optional(),
  invoiceId: z.uuid().optional(),
  partyId: z.uuid().optional(),
});

type CreateBody = z.infer<typeof createBody>;

async function prepare(tx: Tx, ctx: RequestContext, body: CreateBody, lock: boolean) {
  let invQ = tx.selectFrom('invoices').selectAll().where('id', '=', body.invoiceId).where('company_id', '=', ctx.companyId);
  if (lock) invQ = invQ.forUpdate();
  const invoice = await invQ.executeTakeFirst();
  if (!invoice || !ctx.canAccessLocation(invoice.location_id)) throw badRequest('Invoice not found.', { invoiceId: 'Not found' });
  if (invoice.status !== 'posted') throw badRequest('Only posted invoices can be returned.', { invoiceId: 'Cancelled' });

  const noteDate = body.noteDate ?? todayIst();
  if (noteDate > todayIst()) throw badRequest('Date cannot be in the future.', { noteDate: 'In the future' });
  if (noteDate < invoice.invoice_date) throw badRequest('A credit note cannot be dated before its invoice.', { noteDate: 'Before the invoice' });

  let linesQ = tx.selectFrom('invoice_lines as il').innerJoin('items as i', 'i.id', 'il.item_id')
    .selectAll('il').select(['i.track_stock', 'i.name as item_name'])
    .where('il.invoice_id', '=', invoice.id);
  if (lock) linesQ = linesQ.forUpdate();
  const invLines = await linesQ.execute();

  const seen = new Set<string>();
  const lines = body.lines.map((l, idx) => {
    const src = invLines.find((x) => x.id === l.invoiceLineId);
    if (!src) throw badRequest(`Line ${idx + 1}: not a line of this invoice.`, { [`lines.${idx}.invoiceLineId`]: 'Not found' });
    if (seen.has(src.id)) throw badRequest('Each invoice line can appear once.', { [`lines.${idx}.invoiceLineId`]: 'Duplicate' });
    seen.add(src.id);
    const returnable = round3(src.qty - src.returned_qty);
    if (l.qty > returnable + 0.0005) {
      throw badRequest(`Line ${idx + 1}: only ${returnable} ${src.unit} can still be returned.`, { [`lines.${idx}.qty`]: `At most ${returnable}` });
    }
    return { src, qty: l.qty };
  });

  // Same tax treatment as the invoice.
  const seller = invoice.supply_type === 'intra' ? invoice.place_of_supply : 'XX';
  const gst = computeGst(seller, invoice.place_of_supply, lines.map((l) => ({
    qty: l.qty, rate: l.src.rate, discountPct: l.src.discount_pct, gstRate: l.src.gst_rate,
  })));
  const location = await getLocation(tx, ctx, invoice.location_id);
  const party = await tx.selectFrom('parties').select(['id', 'name']).where('id', '=', invoice.party_id).executeTakeFirstOrThrow();
  return { invoice, location, party, noteDate, fy: financialYear(noteDate), lines, gst, restock: body.restock ?? true };
}

type Prepared = Awaited<ReturnType<typeof prepare>>;

function preparedJson(ctx: RequestContext, p: Prepared, reason: string) {
  return {
    id: null, companyId: ctx.companyId, invoiceId: p.invoice.id, invoiceNumber: p.invoice.number, locationId: p.location.id,
    locationName: p.location.name, partyId: p.party.id, partyName: p.party.name, number: null, fy: p.fy,
    noteDate: p.noteDate, reason, restock: p.restock, placeOfSupply: p.invoice.place_of_supply, supplyType: p.gst.supplyType,
    status: 'posted', subtotal: p.gst.subtotal, cgst: p.gst.cgst, sgst: p.gst.sgst, igst: p.gst.igst,
    taxTotal: p.gst.taxTotal, roundOff: p.gst.roundOff, total: p.gst.total, createdAt: new Date(),
    createdBy: { id: ctx.userId, name: ctx.userName }, cancelledAt: null, cancelReason: null,
    lines: p.lines.map((l, i) => ({
      id: null, invoiceLineId: l.src.id, itemId: l.src.item_id, description: l.src.description, hsnCode: l.src.hsn_code,
      qty: l.qty, unit: l.src.unit, rate: l.src.rate, discountPct: l.src.discount_pct, gstRate: l.src.gst_rate, ...p.gst.lines[i]!,
    })),
  };
}

function noteSelect(tx: Tx) {
  return tx.selectFrom('credit_notes as n')
    .innerJoin('invoices as v', 'v.id', 'n.invoice_id')
    .innerJoin('locations as l', 'l.id', 'n.location_id')
    .innerJoin('parties as p', 'p.id', 'n.party_id')
    .innerJoin('users as u', 'u.id', 'n.created_by')
    .selectAll('n')
    .select(['v.number as invoice_number', 'l.name as location_name', 'p.name as party_name', 'u.name as created_by_name']);
}

type NoteRow = Awaited<ReturnType<ReturnType<typeof noteSelect>['executeTakeFirstOrThrow']>>;

function noteJson(r: NoteRow) {
  return {
    id: r.id, companyId: r.company_id, invoiceId: r.invoice_id, invoiceNumber: r.invoice_number, locationId: r.location_id,
    locationName: r.location_name, partyId: r.party_id, partyName: r.party_name, number: r.number, fy: r.fy,
    noteDate: r.note_date, reason: r.reason, restock: r.restock, placeOfSupply: r.place_of_supply, supplyType: r.supply_type,
    status: r.status, subtotal: r.subtotal, cgst: r.cgst, sgst: r.sgst, igst: r.igst,
    taxTotal: round2(r.cgst + r.sgst + r.igst), roundOff: r.round_off, total: r.total, createdAt: r.created_at,
    createdBy: { id: r.created_by, name: r.created_by_name }, cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
  };
}

async function loadNote(tx: Tx, ctx: RequestContext, id: string) {
  const row = await noteSelect(tx).where('n.id', '=', id).where('n.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Credit note');
  const lines = await tx.selectFrom('credit_note_lines').selectAll().where('credit_note_id', '=', id).orderBy('line_no').execute();
  return {
    ...noteJson(row),
    lines: lines.map((l) => ({
      id: l.id, invoiceLineId: l.invoice_line_id, itemId: l.item_id, description: l.description, hsnCode: l.hsn_code,
      qty: l.qty, unit: l.unit, rate: l.rate, discountPct: l.discount_pct, taxableValue: l.taxable_value, gstRate: l.gst_rate,
      cgst: l.cgst, sgst: l.sgst, igst: l.igst, lineTotal: l.line_total,
    })),
  };
}

export async function creditNoteRoutes(app: FastifyInstance) {
  app.get('/credit-notes', async (req) => {
    const ctx = req.ctx;
    ctx.require('credit_notes.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = noteSelect(tx).where('n.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('n.location_id', 'in', scope);
      if (q.status) base = base.where('n.status', '=', q.status);
      if (q.from) base = base.where('n.note_date', '>=', q.from);
      if (q.to) base = base.where('n.note_date', '<=', q.to);
      if (q.invoiceId) base = base.where('n.invoice_id', '=', q.invoiceId);
      if (q.partyId) base = base.where('n.party_id', '=', q.partyId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('n.number', 'ilike', t), eb('v.number', 'ilike', t), eb('p.name', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('n.note_date', 'desc').orderBy('n.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(noteJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/credit-notes/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('credit_notes.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadNote(tx, ctx, id));
  });

  app.post('/credit-notes/preview', async (req) => {
    const ctx = req.ctx;
    ctx.require('credit_notes.create');
    const body = parse(createBody, req.body);
    return ctx.tx(async (tx) => preparedJson(ctx, await prepare(tx, ctx, body, false), body.reason));
  });

  app.post('/credit-notes', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('credit_notes.create');
    const body = parse(createBody, req.body);
    const note = await ctx.tx(async (tx) => {
      const p = await prepare(tx, ctx, body, true);
      const number = await nextNumber(tx, ctx, 'credit_note', p.fy);
      const due = round2(p.invoice.total - p.invoice.amount_paid);
      const applied = round2(Math.min(p.gst.total, Math.max(due, 0)));

      const row = await tx.insertInto('credit_notes').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, invoice_id: p.invoice.id, location_id: p.location.id,
        party_id: p.party.id, number, fy: p.fy, note_date: p.noteDate, reason: body.reason, restock: p.restock,
        place_of_supply: p.invoice.place_of_supply, supply_type: p.gst.supplyType, subtotal: p.gst.subtotal,
        cgst: p.gst.cgst, sgst: p.gst.sgst, igst: p.gst.igst, round_off: p.gst.roundOff, total: p.gst.total,
        applied_amount: applied, created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();

      await tx.insertInto('credit_note_lines').values(p.lines.map((l, i) => {
        const g = p.gst.lines[i]!;
        return {
          tenant_id: ctx.tenantId, credit_note_id: row.id, invoice_line_id: l.src.id, line_no: i + 1, item_id: l.src.item_id,
          description: l.src.description, hsn_code: l.src.hsn_code, qty: l.qty, unit: l.src.unit, rate: l.src.rate,
          discount_pct: l.src.discount_pct, taxable_value: g.taxableValue, gst_rate: l.src.gst_rate,
          cgst: g.cgst, sgst: g.sgst, igst: g.igst, line_total: g.lineTotal,
        };
      })).execute();
      for (const l of p.lines) {
        await tx.updateTable('invoice_lines').set((eb) => ({ returned_qty: eb('returned_qty', '+', l.qty) })).where('id', '=', l.src.id).execute();
      }
      if (applied > 0) {
        await tx.updateTable('invoices').set((eb) => ({ amount_paid: eb('amount_paid', '+', applied) })).where('id', '=', p.invoice.id).execute();
      }

      // Restock returned goods at the cost they left at.
      let restockValue = 0;
      const tracked = p.restock ? p.lines.filter((l) => l.src.track_stock) : [];
      if (tracked.length) {
        await lockItems(tx, ctx.companyId, tracked.map((l) => l.src.item_id));
        const sold = await tx.selectFrom('stock_moves').select(['item_id', 'cost_rate'])
          .where('ref_type', '=', 'invoice').where('ref_id', '=', p.invoice.id).execute();
        const moves = tracked.map((l) => {
          const costRate = sold.find((m) => m.item_id === l.src.item_id)?.cost_rate ?? 0;
          const value = round2(l.qty * costRate);
          restockValue += value;
          return {
            tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: p.location.id, item_id: l.src.item_id, qty: l.qty,
            rate: l.src.rate, cost_rate: costRate, value, ref_type: 'credit_note', ref_id: row.id, note: number, created_by: ctx.userId,
          };
        });
        await tx.insertInto('stock_moves').values(moves).execute();
      }

      const acc = await systemAccounts(tx, ctx);
      const loc = p.location.id;
      await postJournal(tx, auditOf(ctx), {
        date: p.noteDate, voucherType: 'credit_note', voucherId: row.id, number,
        narration: `Sales return from ${p.party.name} against ${p.invoice.number}: ${body.reason}`,
        lines: [
          { accountId: acc.sales_returns, amount: p.gst.subtotal, locationId: loc },
          { accountId: acc.output_cgst, amount: p.gst.cgst, locationId: loc },
          { accountId: acc.output_sgst, amount: p.gst.sgst, locationId: loc },
          { accountId: acc.output_igst, amount: p.gst.igst, locationId: loc },
          { accountId: acc.round_off, amount: p.gst.roundOff, locationId: loc },
          { accountId: acc.receivables, amount: -p.gst.total, partyId: p.party.id, locationId: loc },
          { accountId: acc.inventory, amount: round2(restockValue), locationId: loc },
          { accountId: acc.cogs, amount: -round2(restockValue), locationId: loc },
        ],
      });
      const saved = await loadNote(tx, ctx, row.id);
      await writeAudit(tx, auditOf(ctx), 'credit_note', row.id, 'create', null,
        { number, invoiceId: p.invoice.id, total: p.gst.total, applied, restock: p.restock });
      return saved;
    });
    return reply.status(201).send(note);
  });

  app.post<{ Params: { id: string } }>('/credit-notes/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('credit_notes.cancel');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const current = await tx.selectFrom('credit_notes').selectAll()
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!current || !ctx.canAccessLocation(current.location_id)) throw notFound('Credit note');
      if (current.status === 'cancelled') throw conflict('This credit note is already cancelled.', 'ALREADY_CANCELLED');

      const moves = await tx.selectFrom('stock_moves as m').innerJoin('items as i', 'i.id', 'm.item_id')
        .select(['m.item_id', 'm.location_id', 'm.qty', 'm.rate', 'm.cost_rate', 'm.value', 'i.name', 'i.unit'])
        .where('m.ref_type', '=', 'credit_note').where('m.ref_id', '=', id).execute();
      if (moves.length) {
        await lockItems(tx, ctx.companyId, moves.map((m) => m.item_id));
        const location = await getLocation(tx, ctx, current.location_id);
        for (const m of moves) await requireStock(tx, ctx, location, { id: m.item_id, name: m.name, unit: m.unit }, m.qty);
        await tx.insertInto('stock_moves').values(moves.map((m) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: m.location_id, item_id: m.item_id, qty: -m.qty,
          rate: m.rate, cost_rate: m.cost_rate, value: -m.value, ref_type: 'credit_note_cancel', ref_id: id,
          note: `Cancelled ${current.number}`, created_by: ctx.userId,
        }))).execute();
      }

      await tx.updateTable('credit_notes').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      const lines = await tx.selectFrom('credit_note_lines').select(['invoice_line_id', 'qty']).where('credit_note_id', '=', id).execute();
      for (const l of lines) {
        await tx.updateTable('invoice_lines').set((eb) => ({ returned_qty: eb('returned_qty', '-', l.qty) })).where('id', '=', l.invoice_line_id).execute();
      }
      if (current.applied_amount > 0) {
        await tx.updateTable('invoices').set((eb) => ({ amount_paid: eb('amount_paid', '-', current.applied_amount) }))
          .where('id', '=', current.invoice_id).execute();
      }
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${current.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'credit_note', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return loadNote(tx, ctx, id);
    });
  });
}
