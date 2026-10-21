import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { moneyField, percentField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const createBody = z.object({
  expenseDate: dateField.optional(),
  locationId: z.uuid(),
  accountId: z.uuid(),
  description: z.string().trim().min(2).max(300),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  gstRate: percentField.optional(),
  partyId: z.uuid().nullable().optional(),
  paidFromAccountId: z.uuid(),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  from: dateField.optional(),
  to: dateField.optional(),
  accountId: z.uuid().optional(),
  locationId: z.uuid().optional(),
  status: z.enum(['posted', 'cancelled']).optional(),
});

function expenseSelect(tx: Tx) {
  return tx.selectFrom('expenses as e')
    .innerJoin('locations as l', 'l.id', 'e.location_id')
    .innerJoin('accounts as a', 'a.id', 'e.account_id')
    .innerJoin('accounts as pf', 'pf.id', 'e.paid_from_account_id')
    .leftJoin('parties as p', 'p.id', 'e.party_id')
    .innerJoin('users as u', 'u.id', 'e.created_by')
    .selectAll('e')
    .select(['l.name as location_name', 'a.name as account_name', 'pf.name as paid_from_name', 'p.name as party_name', 'u.name as created_by_name']);
}

type ExpenseRow = Awaited<ReturnType<ReturnType<typeof expenseSelect>['executeTakeFirstOrThrow']>>;

const expenseJson = (r: ExpenseRow) => ({
  id: r.id, companyId: r.company_id, number: r.number, expenseDate: r.expense_date, locationId: r.location_id,
  locationName: r.location_name, accountId: r.account_id, accountName: r.account_name, partyId: r.party_id,
  partyName: r.party_name, description: r.description, amount: r.amount, gstRate: r.gst_rate, cgst: r.cgst,
  sgst: r.sgst, igst: r.igst, total: r.total, paidFromAccountId: r.paid_from_account_id, paidFromAccountName: r.paid_from_name,
  status: r.status, createdAt: r.created_at, createdBy: { id: r.created_by, name: r.created_by_name },
  cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
});

async function loadExpense(tx: Tx, ctx: RequestContext, id: string) {
  const row = await expenseSelect(tx).where('e.id', '=', id).where('e.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Expense');
  return expenseJson(row);
}

export async function expenseRoutes(app: FastifyInstance) {
  app.get('/expenses', async (req) => {
    const ctx = req.ctx;
    ctx.require('expenses.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = expenseSelect(tx).where('e.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('e.location_id', 'in', scope);
      if (q.from) base = base.where('e.expense_date', '>=', q.from);
      if (q.to) base = base.where('e.expense_date', '<=', q.to);
      if (q.accountId) base = base.where('e.account_id', '=', q.accountId);
      if (q.locationId) base = base.where('e.location_id', '=', q.locationId);
      if (q.status) base = base.where('e.status', '=', q.status);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('e.number', 'ilike', t), eb('e.description', 'ilike', t), eb('p.name', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('e.expense_date', 'desc').orderBy('e.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(expenseJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/expenses/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('expenses.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadExpense(tx, ctx, id));
  });

  app.post('/expenses', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('expenses.create');
    const body = parse(createBody, req.body);
    const expense = await ctx.tx(async (tx) => {
      const location = await getLocation(tx, ctx, body.locationId);
      const accounts = await tx.selectFrom('accounts').select(['id', 'name', 'type', 'subtype', 'is_active', 'system_key'])
        .where('company_id', '=', ctx.companyId).where('id', 'in', [body.accountId, body.paidFromAccountId]).execute();
      const head = accounts.find((a) => a.id === body.accountId);
      const paidFrom = accounts.find((a) => a.id === body.paidFromAccountId);
      if (!head || head.type !== 'expense' || !head.is_active || head.system_key === 'cogs') {
        throw badRequest('Choose an active expense head.', { accountId: 'Not an expense account' });
      }
      if (!paidFrom || !['cash', 'bank'].includes(paidFrom.subtype) || !paidFrom.is_active) {
        throw badRequest('Choose an active cash or bank account.', { paidFromAccountId: 'Not a cash or bank account' });
      }
      let party: { id: string; name: string; state_code: string | null } | undefined;
      if (body.partyId) {
        party = await tx.selectFrom('parties').select(['id', 'name', 'state_code', 'type'])
          .where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!party) throw badRequest('Vendor not found.', { partyId: 'Not found' });
      }
      const date = body.expenseDate ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { expenseDate: 'In the future' });

      const gstRate = body.gstRate ?? 0;
      const g = computeGst(location.state_code, party?.state_code ?? location.state_code,
        [{ qty: 1, rate: body.amount, discountPct: 0, gstRate }]);
      const line = g.lines[0]!;
      const number = await nextNumber(tx, ctx, 'expense', financialYear(date));
      const row = await tx.insertInto('expenses').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, expense_date: date, location_id: location.id,
        account_id: head.id, party_id: party?.id ?? null, description: body.description, amount: body.amount, gst_rate: gstRate,
        cgst: line.cgst, sgst: line.sgst, igst: line.igst, total: line.lineTotal, paid_from_account_id: paidFrom.id,
        created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();

      const acc = await systemAccounts(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'expense', voucherId: row.id, number, narration: `${head.name}: ${body.description}`,
        lines: [
          { accountId: head.id, amount: body.amount, locationId: location.id, partyId: null },
          { accountId: acc.input_cgst, amount: line.cgst, locationId: location.id },
          { accountId: acc.input_sgst, amount: line.sgst, locationId: location.id },
          { accountId: acc.input_igst, amount: line.igst, locationId: location.id },
          { accountId: paidFrom.id, amount: -line.lineTotal, locationId: location.id },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'expense', row.id, 'create', null, { number, amount: body.amount, total: line.lineTotal });
      return loadExpense(tx, ctx, row.id);
    });
    return reply.status(201).send(expense);
  });

  app.post<{ Params: { id: string } }>('/expenses/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('expenses.cancel');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const e = await tx.selectFrom('expenses').select(['id', 'status', 'number', 'location_id'])
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!e || !ctx.canAccessLocation(e.location_id)) throw notFound('Expense');
      if (e.status === 'cancelled') throw conflict('This expense is already cancelled.', 'ALREADY_CANCELLED');
      await tx.updateTable('expenses').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${e.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'expense', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return loadExpense(tx, ctx, id);
    });
  });
}
