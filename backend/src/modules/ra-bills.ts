import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { insertDeduction, cancelDeduction } from '../lib/tds.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { advanceFigures, computeRaBill, latestCumQtys, projectLocationId, requireProjectVisible, round2, user, visibleProjectIds } from './subcontract-common.ts';
import { getWorkOrder } from './work-orders.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const reasonBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const rejectBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });

const common = {
  date: docDate.optional(), periodFrom: dateField.nullish(), periodTo: dateField.nullish(), dueDate: dateField.optional(),
  isFinal: z.boolean().optional(), notes: nullableText(1000),
  lines: z.array(z.object({ workOrderLineId: z.uuid(), cumQty: qtyField })).max(500).optional(),
  retention: moneyField.optional(), advanceRecovery: moneyField.optional(), tds: moneyField.optional(),
  cess: moneyField.optional(), otherDeduction: moneyField.optional(), otherDeductionNote: nullableText(300),
};
const createBody = z.object({ workOrderId: z.uuid(), ...common, submit: z.boolean().optional() });
const patchBody = z.object(common);
const listQuery = pagingQuery.extend({
  workOrderId: z.uuid().optional(), projectId: z.uuid().optional(), contractorId: z.uuid().optional(),
  status: z.enum(['draft', 'submitted', 'approved', 'cancelled']).optional(),
  paymentStatus: z.enum(['unpaid', 'partial', 'paid']).optional(),
});

export async function loadRaBills(tx: Tx, ids: string[], withLines: boolean) {
  if (!ids.length) return [];
  const rows = await tx.selectFrom('ra_bills as b').innerJoin('work_orders as w', 'w.id', 'b.work_order_id')
    .innerJoin('projects as p', 'p.id', 'w.project_id').innerJoin('parties as c', 'c.id', 'w.contractor_party_id')
    .innerJoin('users as u', 'u.id', 'b.created_by').leftJoin('users as ap', 'ap.id', 'b.approved_by')
    .selectAll('b').select([
      'w.number as wo_number', 'w.project_id', 'w.contractor_party_id', 'p.name as project_name', 'c.name as contractor_name',
      'u.name as created_by_name', 'ap.name as approved_by_name',
    ]).where('b.id', 'in', ids).execute();
  const lines = withLines
    ? await tx.selectFrom('ra_bill_lines as l').innerJoin('work_order_lines as wl', 'wl.id', 'l.work_order_line_id')
      .select(['l.ra_bill_id', 'l.work_order_line_id', 'wl.description', 'wl.unit', 'wl.qty', 'wl.line_no', 'l.prev_qty', 'l.cum_qty', 'l.this_qty', 'l.rate', 'l.amount'])
      .where('l.ra_bill_id', 'in', ids).orderBy('wl.line_no').execute()
    : [];
  return ids.map((id) => rows.find((r) => r.id === id)).filter((b) => !!b).map((b) => {
    const invoiceTotal = round2(b.gross + b.cgst + b.sgst + b.igst);
    const totalDeductions = round2(b.retention + b.advance_recovery + b.tds + b.cess + b.other_deduction);
    const amountDue = b.status === 'approved' ? round2(b.net_payable - b.amount_paid) : 0;
    return {
      id: b.id, number: b.number, workOrderId: b.work_order_id, workOrderNumber: b.wo_number, projectId: b.project_id,
      projectName: b.project_name, contractorPartyId: b.contractor_party_id, contractorName: b.contractor_name,
      billSeq: b.bill_seq, date: b.bill_date, periodFrom: b.period_from, periodTo: b.period_to, dueDate: b.due_date,
      status: b.status, isFinal: b.is_final,
      ...(withLines ? {
        lines: lines.filter((l) => l.ra_bill_id === b.id).map((l) => ({
          workOrderLineId: l.work_order_line_id, description: l.description, unit: l.unit, rate: l.rate, qty: l.qty,
          prevQty: l.prev_qty, cumQty: l.cum_qty, thisQty: l.this_qty, amount: l.amount,
        })),
      } : {}),
      gross: b.gross, cgst: b.cgst, sgst: b.sgst, igst: b.igst, invoiceTotal, retention: b.retention,
      advanceRecovery: b.advance_recovery, tds: b.tds, cess: b.cess, otherDeduction: b.other_deduction,
      otherDeductionNote: b.other_deduction_note, totalDeductions, netPayable: b.net_payable, amountPaid: b.amount_paid, amountDue,
      paymentStatus: b.amount_paid <= 0 && b.net_payable > 0 ? 'unpaid' : b.amount_paid + 0.001 >= b.net_payable ? 'paid' : 'partial',
      notes: b.notes, rejectReason: b.reject_reason, createdAt: b.created_at, createdBy: user(b.created_by, b.created_by_name),
      submittedAt: b.submitted_at, approvedAt: b.approved_at,
      approvedBy: b.approved_by ? user(b.approved_by, b.approved_by_name ?? '') : null,
      cancelledAt: b.cancelled_at, cancelReason: b.cancel_reason,
    };
  });
}

async function getBill(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('ra_bills').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const bill = await q.executeTakeFirst();
  if (!bill) throw notFound('RA bill');
  const wo = await tx.selectFrom('work_orders').selectAll().where('id', '=', bill.work_order_id).executeTakeFirstOrThrow();
  await requireProjectVisible(tx, ctx, wo.project_id, 'RA bill');
  return { bill, wo };
}

type WorkOrderRow = Awaited<ReturnType<typeof getWorkOrder>>;
type Fields = z.infer<typeof patchBody>;

/** Computes the bill from the work order and writes header + lines. `billId` null inserts. */
async function saveBill(
  tx: Tx, ctx: RequestContext, wo: WorkOrderRow, f: Fields, billId: string | null, base: { seq?: number; existingCum?: Map<string, number> },
): Promise<string> {
  const woLines = await tx.selectFrom('work_order_lines').selectAll().where('work_order_id', '=', wo.id).orderBy('line_no').execute();
  const prev = await latestCumQtys(tx, wo.id);
  const given = new Map<string, number>();
  (f.lines ?? []).forEach((l, i) => {
    if (!woLines.some((w) => w.id === l.workOrderLineId)) throw badRequest('This line is not on the work order.', { [`lines.${i}.workOrderLineId`]: 'Not on this work order' });
    if (given.has(l.workOrderLineId)) throw badRequest('A line can appear only once.', { [`lines.${i}.workOrderLineId`]: 'Duplicate' });
    given.set(l.workOrderLineId, l.cumQty);
  });
  const contractor = await tx.selectFrom('parties').select(['state_code', 'credit_days']).where('id', '=', wo.contractor_party_id).executeTakeFirstOrThrow();
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const fig = await advanceFigures(tx, wo.id);
  const inputs = woLines.map((w) => ({
    prevQty: prev.get(w.id) ?? 0, cumQty: given.get(w.id) ?? (f.lines ? undefined : base.existingCum?.get(w.id)) ?? prev.get(w.id) ?? 0,
    qty: w.qty, rate: w.rate,
  }));
  const calc = computeRaBill({
    gstPct: wo.gst_pct, retentionPct: wo.retention_pct, advanceRecoveryPct: wo.advance_recovery_pct, tdsPct: wo.tds_pct,
    cessPct: wo.cess_pct, intraState: !contractor.state_code || contractor.state_code === company.state_code,
    advanceBalance: fig.advance.balance, lines: inputs,
    overrides: { retention: f.retention, advanceRecovery: f.advanceRecovery, tds: f.tds, cess: f.cess, otherDeduction: f.otherDeduction },
  });
  const date = f.date ?? todayIst();
  const header = {
    bill_date: date, period_from: f.periodFrom ?? null, period_to: f.periodTo ?? null,
    due_date: f.dueDate ?? addDays(date, contractor.credit_days), is_final: f.isFinal ?? false, notes: f.notes ?? null,
    gross: calc.gross, cgst: calc.cgst, sgst: calc.sgst, igst: calc.igst, retention: calc.retention,
    advance_recovery: calc.advanceRecovery, tds: calc.tds, cess: calc.cess, other_deduction: calc.otherDeduction,
    other_deduction_note: f.otherDeductionNote ?? null, net_payable: calc.netPayable,
  };
  let id = billId;
  if (id) {
    await tx.updateTable('ra_bills').set(header).where('id', '=', id).execute();
    await tx.deleteFrom('ra_bill_lines').where('ra_bill_id', '=', id).execute();
  } else {
    const number = await nextNumber(tx, ctx, 'ra_bill', financialYear(date));
    const row = await tx.insertInto('ra_bills').values({
      ...header, tenant_id: ctx.tenantId, company_id: ctx.companyId, number, work_order_id: wo.id, bill_seq: base.seq!,
      status: 'draft', created_by: ctx.userId, submitted_at: null, approved_by: null, approved_at: null,
      cancelled_at: null, cancel_reason: null, reject_reason: null,
    }).returning('id').executeTakeFirstOrThrow();
    id = row.id;
  }
  await tx.insertInto('ra_bill_lines').values(woLines.map((w, i) => ({
    tenant_id: ctx.tenantId, ra_bill_id: id!, work_order_line_id: w.id, prev_qty: calc.lines[i]!.prevQty,
    cum_qty: calc.lines[i]!.cumQty, this_qty: calc.lines[i]!.thisQty, rate: w.rate, amount: calc.lines[i]!.amount,
  }))).execute();
  return id;
}

export async function raBillRoutes(app: FastifyInstance) {
  app.get('/ra-bills', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('ra_bills as b').innerJoin('work_orders as w', 'w.id', 'b.work_order_id')
        .innerJoin('parties as c', 'c.id', 'w.contractor_party_id').where('b.company_id', '=', ctx.companyId);
      const visible = await visibleProjectIds(tx, ctx);
      if (visible) base = base.where('w.project_id', 'in', visible);
      if (q.workOrderId) base = base.where('b.work_order_id', '=', q.workOrderId);
      if (q.projectId) base = base.where('w.project_id', '=', q.projectId);
      if (q.contractorId) base = base.where('w.contractor_party_id', '=', q.contractorId);
      if (q.status) base = base.where('b.status', '=', q.status);
      if (q.paymentStatus === 'unpaid') base = base.where('b.amount_paid', '<=', 0);
      if (q.paymentStatus === 'paid') base = base.where('b.amount_paid', '>', 0).whereRef('b.amount_paid', '>=', 'b.net_payable');
      if (q.paymentStatus === 'partial') base = base.where('b.amount_paid', '>', 0).whereRef('b.amount_paid', '<', 'b.net_payable');
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('b.number', 'ilike', t), eb('w.number', 'ilike', t), eb('c.name', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('b.id').orderBy('b.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadRaBills(tx, ids.map((r) => r.id), false), total };
    });
  });

  app.get<{ Params: { id: string } }>('/ra-bills/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await getBill(tx, ctx, id);
      return (await loadRaBills(tx, [id], true))[0];
    });
  });

  app.post('/ra-bills', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.manage');
    const body = parse(createBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const wo = await getWorkOrder(tx, ctx, body.workOrderId, true);
      if (wo.status !== 'active') throw conflict('The work order must be active.');
      const bills = await tx.selectFrom('ra_bills').select(['bill_seq', 'status', 'is_final']).where('work_order_id', '=', wo.id).execute();
      if (bills.some((b) => b.status === 'approved' && b.is_final)) throw conflict('A final bill has been approved. No more bills can be raised.');
      if (bills.some((b) => b.status === 'draft' || b.status === 'submitted')) throw conflict('A draft or submitted RA bill already exists for this work order.');
      const seq = Math.max(0, ...bills.map((b) => b.bill_seq)) + 1;
      const id = await saveBill(tx, ctx, wo, body, null, { seq });
      if (body.submit) await tx.updateTable('ra_bills').set({ status: 'submitted', submitted_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'ra_bill', id, 'create', null, { workOrderId: wo.id, billSeq: seq, submit: !!body.submit });
      return (await loadRaBills(tx, [id], true))[0];
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/ra-bills/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const { bill } = await getBill(tx, ctx, id, true);
      const wo = await getWorkOrder(tx, ctx, bill.work_order_id, true);
      if (bill.status !== 'draft') throw conflict('Only a draft RA bill can be edited.');
      const existing = new Map((await tx.selectFrom('ra_bill_lines').select(['work_order_line_id', 'cum_qty']).where('ra_bill_id', '=', id).execute())
        .map((l) => [l.work_order_line_id, l.cum_qty]));
      // Fields not sent keep their saved values; deduction overrides not sent are recomputed.
      const merged: Fields = {
        ...body,
        date: body.date ?? bill.bill_date, dueDate: body.dueDate ?? bill.due_date,
        periodFrom: body.periodFrom === undefined ? bill.period_from : body.periodFrom,
        periodTo: body.periodTo === undefined ? bill.period_to : body.periodTo,
        isFinal: body.isFinal ?? bill.is_final, notes: body.notes === undefined ? bill.notes : body.notes,
        otherDeductionNote: body.otherDeductionNote === undefined ? bill.other_deduction_note : body.otherDeductionNote,
      };
      await saveBill(tx, ctx, wo, merged, id, { existingCum: existing });
      await writeAudit(tx, auditOf(ctx), 'ra_bill', id, 'update', { number: bill.number }, body);
      return (await loadRaBills(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/ra-bills/:id/submit', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const { bill } = await getBill(tx, ctx, id, true);
      if (bill.status !== 'draft') throw conflict('Only a draft RA bill can be submitted.');
      await tx.updateTable('ra_bills').set({ status: 'submitted', submitted_at: new Date(), reject_reason: null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'ra_bill', id, 'submit', { status: 'draft' }, { status: 'submitted' });
      return (await loadRaBills(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/ra-bills/:id/reject', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.approve');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(rejectBody, req.body);
    return ctx.tx(async (tx) => {
      const { bill } = await getBill(tx, ctx, id, true);
      if (bill.status !== 'submitted') throw conflict('Only a submitted RA bill can be rejected.');
      await tx.updateTable('ra_bills').set({ status: 'draft', reject_reason: reason, submitted_at: null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'ra_bill', id, 'reject', { status: 'submitted' }, { status: 'draft', reason });
      return (await loadRaBills(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/ra-bills/:id/approve', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.approve');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const { bill } = await getBill(tx, ctx, id, true);
      const wo = await getWorkOrder(tx, ctx, bill.work_order_id, true);
      if (bill.status !== 'submitted') throw conflict('Only a submitted RA bill can be approved.');
      if (wo.status !== 'active') throw conflict('The work order must be active.');
      const fig = await advanceFigures(tx, wo.id);
      if (bill.advance_recovery > fig.advance.balance + 0.001) throw conflict(`Advance recovery exceeds the advance balance of ₹${fig.advance.balance}.`);
      const acc = await systemAccounts(tx, ctx);
      const loc = await projectLocationId(tx, wo.project_id);
      const party = wo.contractor_party_id;
      const gst = round2(bill.cgst + bill.sgst + bill.igst);
      const lines = [
        { accountId: acc.subcontract_cost, amount: wo.itc_eligible ? bill.gross : round2(bill.gross + gst), locationId: loc },
        ...(wo.itc_eligible ? [
          { accountId: acc.input_cgst, amount: bill.cgst, locationId: loc },
          { accountId: acc.input_sgst, amount: bill.sgst, locationId: loc },
          { accountId: acc.input_igst, amount: bill.igst, locationId: loc },
        ] : []),
        { accountId: acc.payables, amount: -bill.net_payable, partyId: party, locationId: loc },
        { accountId: acc.retention_payable, amount: -bill.retention, locationId: loc },
        { accountId: acc.contractor_advances, amount: -bill.advance_recovery, partyId: party, locationId: loc },
        { accountId: acc.tds_payable, amount: -bill.tds, locationId: loc },
        { accountId: acc.cess_payable, amount: -bill.cess, locationId: loc },
        { accountId: acc.other_income, amount: -bill.other_deduction, locationId: loc },
      ];
      await postJournal(tx, auditOf(ctx), {
        date: bill.bill_date, voucherType: 'ra_bill', voucherId: id, number: bill.number,
        narration: `RA bill ${bill.bill_seq} ${wo.number}`, lines,
      });
      // 194C at the work order's rate on the bill gross; no threshold logic. Zero-amount rows are kept.
      const sec = await tx.selectFrom('tds_sections').select('id').where('code', '=', '194C')
        .where('effective_from', '<=', bill.bill_date).where((eb) => eb.or([eb('effective_to', 'is', null), eb('effective_to', '>=', bill.bill_date)]))
        .orderBy('effective_from', 'desc').executeTakeFirst();
      await insertDeduction(tx, ctx, {
        sourceType: 'ra_bill', sourceId: id, number: bill.number, date: bill.bill_date, partyId: party, sectionId: sec?.id ?? null,
        sectionCode: '194C', gross: bill.gross, base: bill.gross, rate: wo.tds_pct, amount: bill.tds,
      });
      await tx.updateTable('ra_bills').set({ status: 'approved', approved_by: ctx.userId, approved_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'ra_bill', id, 'approve', { status: 'submitted' }, { status: 'approved', netPayable: bill.net_payable });
      return (await loadRaBills(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/ra-bills/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.approve');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(reasonBody, req.body);
    return ctx.tx(async (tx) => {
      const { bill } = await getBill(tx, ctx, id, true);
      const wo = await getWorkOrder(tx, ctx, bill.work_order_id, true);
      if (bill.status === 'cancelled') throw conflict('This RA bill is already cancelled.', 'ALREADY_CANCELLED');
      if (bill.status !== 'approved') throw conflict('Only an approved RA bill can be cancelled.');
      if (bill.amount_paid > 0) throw conflict('Payments are allocated to this bill. Cancel them first.');
      const later = await tx.selectFrom('ra_bills').select('id').where('work_order_id', '=', wo.id)
        .where('status', 'in', ['approved', 'draft', 'submitted']).where('bill_seq', '>', bill.bill_seq).limit(1).executeTakeFirst();
      if (later) throw conflict('Only the latest approved RA bill can be cancelled, and no later draft may exist.');
      const other = await tx.selectFrom('ra_bills').select('id').where('work_order_id', '=', wo.id)
        .where('status', 'in', ['draft', 'submitted']).limit(1).executeTakeFirst();
      if (other) throw conflict('A draft or submitted RA bill exists. Cancel or approve it first.');
      const fig = await advanceFigures(tx, wo.id);
      if (round2(fig.retention.balance - bill.retention) < 0) throw conflict('Retention from this bill has already been released.');
      await cancelDeduction(tx, 'ra_bill', id);
      await tx.updateTable('ra_bills').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${bill.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'ra_bill', id, 'cancel', { status: 'approved' }, { status: 'cancelled', reason });
      return (await loadRaBills(tx, [id], true))[0];
    });
  });
}
