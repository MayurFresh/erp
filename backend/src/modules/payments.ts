import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import { ledger, partyBalances } from '../accounting/ledger.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, fyStart, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const createBody = z.object({
  kind: z.enum(['receipt', 'payment']),
  partyId: z.uuid(),
  date: dateField.optional(),
  accountId: z.uuid(),
  mode: z.enum(['cash', 'bank', 'upi', 'cheque', 'card']),
  reference: optionalText(60),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  notes: optionalText(500),
  allocations: z.array(z.object({ docId: z.uuid(), amount: moneyField.refine((v) => v > 0, 'Must be more than zero') })).max(200).optional(),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  kind: z.enum(['receipt', 'payment']).optional(),
  partyId: z.uuid().optional(),
  status: z.enum(['posted', 'cancelled']).optional(),
  from: dateField.optional(),
  to: dateField.optional(),
});
const rangeQuery = z.object({ from: dateField.optional(), to: dateField.optional() });

export interface OpenDoc { id: string; number: string; date: string; dueDate: string; total: number; amountDue: number }

/** Posted invoices (receipts) or bills (payments) of a party that still have something due, oldest first. */
export async function openDocs(tx: Tx, ctx: RequestContext, kind: 'receipt' | 'payment', partyId: string, lock = false): Promise<OpenDoc[]> {
  if (kind === 'receipt') {
    let q = tx.selectFrom('invoices').select(['id', 'number', 'invoice_date as date', 'due_date', 'total', 'amount_paid'])
      .where('company_id', '=', ctx.companyId).where('party_id', '=', partyId).where('status', '=', 'posted')
      .whereRef('amount_paid', '<', 'total').orderBy('invoice_date').orderBy('created_at');
    if (lock) q = q.forUpdate();
    return (await q.execute()).map((r) => ({ id: r.id, number: r.number, date: r.date, dueDate: r.due_date, total: r.total, amountDue: round2(r.total - r.amount_paid) }));
  }
  let q = tx.selectFrom('purchases').select(['id', 'number', 'bill_date as date', 'due_date', 'total', 'amount_paid'])
    .where('company_id', '=', ctx.companyId).where('party_id', '=', partyId).where('status', '=', 'posted')
    .whereRef('amount_paid', '<', 'total').orderBy('bill_date').orderBy('created_at');
  if (lock) q = q.forUpdate();
  return (await q.execute()).map((r) => ({ id: r.id, number: r.number, date: r.date, dueDate: r.due_date, total: r.total, amountDue: round2(r.total - r.amount_paid) }));
}

async function loadPayment(tx: Tx, ctx: RequestContext, id: string) {
  const p = await tx.selectFrom('payments as p')
    .innerJoin('parties as pt', 'pt.id', 'p.party_id')
    .innerJoin('accounts as a', 'a.id', 'p.account_id')
    .innerJoin('users as u', 'u.id', 'p.created_by')
    .selectAll('p').select(['pt.name as party_name', 'a.name as account_name', 'u.name as created_by_name'])
    .where('p.id', '=', id).where('p.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!p) throw notFound('Payment');
  const allocs = await tx.selectFrom('payment_allocations').selectAll().where('payment_id', '=', id).execute();
  const ids = allocs.map((a) => a.doc_id);
  const docs = ids.length
    ? p.kind === 'receipt'
      ? await tx.selectFrom('invoices').select(['id', 'number', 'invoice_date as date', 'total']).where('id', 'in', ids).execute()
      : await tx.selectFrom('purchases').select(['id', 'number', 'bill_date as date', 'total']).where('id', 'in', ids).execute()
    : [];
  const allocated = round2(allocs.reduce((s, a) => s + a.amount, 0));
  return {
    id: p.id, companyId: p.company_id, kind: p.kind, number: p.number, date: p.payment_date, partyId: p.party_id,
    partyName: p.party_name, accountId: p.account_id, accountName: p.account_name, mode: p.mode, reference: p.reference,
    amount: p.amount, allocated, unallocated: round2(p.amount - allocated), notes: p.notes, status: p.status,
    createdAt: p.created_at, createdBy: { id: p.created_by, name: p.created_by_name }, cancelledAt: p.cancelled_at,
    cancelReason: p.cancel_reason,
    allocations: allocs.map((a) => {
      const d = docs.find((x) => x.id === a.doc_id);
      return { docType: a.doc_type, docId: a.doc_id, docNumber: d?.number ?? '', docDate: d?.date ?? '', docTotal: d?.total ?? 0, amount: a.amount };
    }),
  };
}

export async function paymentRoutes(app: FastifyInstance) {
  app.get('/payments', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('payments as p').innerJoin('parties as pt', 'pt.id', 'p.party_id')
        .where('p.company_id', '=', ctx.companyId);
      if (q.kind) base = base.where('p.kind', '=', q.kind);
      if (q.partyId) base = base.where('p.party_id', '=', q.partyId);
      if (q.status) base = base.where('p.status', '=', q.status);
      if (q.from) base = base.where('p.payment_date', '>=', q.from);
      if (q.to) base = base.where('p.payment_date', '<=', q.to);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('p.number', 'ilike', t), eb('pt.name', 'ilike', t), eb('p.reference', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('p.id').orderBy('p.payment_date', 'desc').orderBy('p.created_at', 'desc')
        .limit(q.limit).offset(q.offset).execute();
      const data = [];
      for (const { id } of ids) data.push(await loadPayment(tx, ctx, id));
      return { data, total };
    });
  });

  app.get<{ Params: { id: string } }>('/payments/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadPayment(tx, ctx, id));
  });

  app.post('/payments', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payments.create');
    const body = parse(createBody, req.body);
    const payment = await ctx.tx(async (tx) => {
      const party = await tx.selectFrom('parties').select(['id', 'name', 'type'])
        .where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw badRequest('Party not found.', { partyId: 'Not found' });
      if (body.kind === 'receipt' && party.type === 'vendor') throw badRequest('Receipts are from customers.', { partyId: 'Not a customer' });
      if (body.kind === 'payment' && party.type === 'customer') throw badRequest('Payments are to vendors.', { partyId: 'Not a vendor' });

      const account = await tx.selectFrom('accounts').select(['id', 'name', 'subtype', 'is_active'])
        .where('id', '=', body.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!account || !account.is_active || !['cash', 'bank'].includes(account.subtype)) {
        throw badRequest('Choose an active cash or bank account.', { accountId: 'Not a cash or bank account' });
      }
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });

      // Decide allocations: as given, or oldest documents first.
      const open = await openDocs(tx, ctx, body.kind, party.id, true);
      let allocations: { docId: string; amount: number }[];
      if (body.allocations) {
        const seen = new Set<string>();
        allocations = body.allocations.map((a, i) => {
          const doc = open.find((d) => d.id === a.docId);
          if (!doc) throw badRequest(`Allocation ${i + 1}: document is not open for this party.`, { [`allocations.${i}.docId`]: 'Not open' });
          if (seen.has(a.docId)) throw badRequest('Each document can be allocated once.', { [`allocations.${i}.docId`]: 'Duplicate' });
          seen.add(a.docId);
          if (a.amount > doc.amountDue + 0.001) {
            throw badRequest(`Only ₹${doc.amountDue} is due on ${doc.number}.`, { [`allocations.${i}.amount`]: `At most ${doc.amountDue}` });
          }
          return a;
        });
        const sum = round2(allocations.reduce((s, a) => s + a.amount, 0));
        if (sum > body.amount + 0.001) throw badRequest('Allocations exceed the amount.', { allocations: 'More than the amount' });
      } else {
        let left = body.amount;
        allocations = [];
        for (const d of open) {
          if (left <= 0) break;
          const take = round2(Math.min(left, d.amountDue));
          allocations.push({ docId: d.id, amount: take });
          left = round2(left - take);
        }
      }

      const number = await nextNumber(tx, ctx, body.kind, financialYear(date));
      const row = await tx.insertInto('payments').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: body.kind, number, payment_date: date, party_id: party.id,
        account_id: account.id, mode: body.mode, reference: body.reference ?? null, amount: body.amount,
        notes: body.notes ?? null, created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();

      const docType = body.kind === 'receipt' ? 'invoice' : 'purchase';
      const table = body.kind === 'receipt' ? 'invoices' : 'purchases';
      if (allocations.length) {
        await tx.insertInto('payment_allocations').values(allocations.map((a) => ({
          tenant_id: ctx.tenantId, payment_id: row.id, doc_type: docType, doc_id: a.docId, amount: a.amount,
        }))).execute();
        for (const a of allocations) {
          await tx.updateTable(table).set((eb) => ({ amount_paid: eb('amount_paid', '+', a.amount) })).where('id', '=', a.docId).execute();
        }
      }

      const acc = await systemAccounts(tx, ctx);
      const control = body.kind === 'receipt' ? acc.receivables : acc.payables;
      const sign = body.kind === 'receipt' ? 1 : -1;
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: body.kind, voucherId: row.id, number,
        narration: `${body.kind === 'receipt' ? 'Received from' : 'Paid to'} ${party.name} by ${body.mode}${body.reference ? ` (${body.reference})` : ''}`,
        lines: [
          { accountId: account.id, amount: sign * body.amount },
          { accountId: control, amount: -sign * body.amount, partyId: party.id },
        ],
      });
      const saved = await loadPayment(tx, ctx, row.id);
      await writeAudit(tx, auditOf(ctx), 'payment', row.id, 'create', null, { number, kind: body.kind, amount: body.amount, partyId: party.id, allocations });
      return saved;
    });
    return reply.status(201).send(payment);
  });

  app.post<{ Params: { id: string } }>('/payments/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.cancel');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const current = await tx.selectFrom('payments').select(['id', 'status', 'kind', 'number'])
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!current) throw notFound('Payment');
      if (current.status === 'cancelled') throw conflict('This is already cancelled.', 'ALREADY_CANCELLED');
      await tx.updateTable('payments').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      const table = current.kind === 'receipt' ? 'invoices' : 'purchases';
      const allocs = await tx.selectFrom('payment_allocations').select(['doc_id', 'amount']).where('payment_id', '=', id).execute();
      for (const a of allocs) {
        await tx.updateTable(table).set((eb) => ({ amount_paid: eb('amount_paid', '-', a.amount) })).where('id', '=', a.doc_id).execute();
      }
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${current.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'payment', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return loadPayment(tx, ctx, id);
    });
  });

  app.get<{ Params: { id: string } }>('/parties/:id/outstanding', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const party = await tx.selectFrom('parties').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw notFound('Party');
      const balance = (await partyBalances(tx, ctx.companyId, [id])).get(id) ?? 0;
      return { balance, invoices: await openDocs(tx, ctx, 'receipt', id), purchases: await openDocs(tx, ctx, 'payment', id) };
    });
  });

  app.get<{ Params: { id: string } }>('/parties/:id/statement', async (req) => {
    const ctx = req.ctx;
    ctx.require('parties.view');
    ctx.require('payments.view', 'accounts.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(rangeQuery, req.query);
    const to = q.to ?? todayIst();
    const from = q.from ?? fyStart(to);
    return ctx.tx(async (tx) => {
      const party = await tx.selectFrom('parties').select(['id', 'name', 'type']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw notFound('Party');
      const acc = await systemAccounts(tx, ctx);
      const result = await ledger(tx, ctx.companyId, { accountIds: [acc.receivables, acc.payables], partyId: id, from, to });
      return {
        accountId: party.type === 'vendor' ? acc.payables : acc.receivables,
        accountName: `${party.name} — party ledger`, ...result,
      };
    });
  });
}
