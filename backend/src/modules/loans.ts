import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { moneyField } from '../lib/numbers.ts';
import { documentRoute } from '../lib/openapi.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { ACC, ensureAccount, loanAccount, round2 } from './claims-common.ts';
import { myEmployee } from './hr.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const blank = (v: unknown) => (v === '' || v === null ? undefined : v);
export const PERQUISITE_LIMIT = 20000;
export const PERQUISITE_NOTE = 'Interest-free or concessional loans above 20,000 may be a taxable perquisite for the employee. Tax treatment not confirmed; mark for CA review.';

const addMonth = (m: string, n: number) => {
  const d = new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)) - 1 + n, 1));
  return d.toISOString().slice(0, 10);
};

/**
 * What it costs to close a reducing-balance loan on `payDate`: all open principal, plus interest that has accrued to that date.
 * An instalment's interest belongs to its due month and accrues day by day through it; months wholly before the date are in full,
 * months after the date carry none.
 */
export function foreclosureQuote(open: { dueMonth: string; principal: number; interest: number }[], payDate: string) {
  let principal = 0, interest = 0;
  for (const o of open) {
    principal += o.principal;
    const start = `${o.dueMonth.slice(0, 7)}-01`;
    const days = new Date(Date.UTC(Number(start.slice(0, 4)), Number(start.slice(5, 7)), 0)).getUTCDate();
    if (payDate < start) continue;
    const upto = payDate >= `${start.slice(0, 8)}${String(days).padStart(2, '0')}` ? days : Number(payDate.slice(8, 10));
    interest += round2((o.interest * upto) / days);
  }
  principal = round2(principal); interest = round2(interest);
  return { principal, interest, total: round2(principal + interest) };
}

export function buildSchedule(amount: number, ratePct: number, emi: number, startMonth: string) {
  const r = ratePct / 1200;
  const rows: { seq: number; dueMonth: string; principal: number; interest: number; amount: number }[] = [];
  let bal = amount;
  while (bal > 0.004) {
    if (rows.length >= 600) throw badRequest('The instalment is too small: the loan would take over 50 years.', { instalment: 'Too small' });
    const interest = round2(bal * r);
    if (emi <= interest) throw badRequest('The instalment does not cover the monthly interest.', { instalment: 'Too small' });
    const pay = Math.min(emi, round2(bal + interest));
    const principal = round2(pay - interest);
    bal = round2(bal - principal);
    rows.push({ seq: rows.length + 1, dueMonth: addMonth(startMonth, rows.length), principal, interest, amount: round2(principal + interest) });
  }
  return rows;
}

const createBody = z.object({
  employeeId: z.uuid(), kind: z.enum(['advance', 'loan']), purpose: z.string().trim().min(2).max(300),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  interestRate: z.coerce.number().min(0).max(50).optional(),
  instalment: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  startMonth: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM'),
  disbursedOn: z.preprocess(blank, dateField.optional()), accountId: z.preprocess(blank, z.uuid().optional()),
});

type LoanRow = Awaited<ReturnType<ReturnType<typeof loanSelect>['executeTakeFirstOrThrow']>>;
function loanSelect(tx: Tx) {
  return tx.selectFrom('employee_loans as l').innerJoin('employees as e', 'e.id', 'l.employee_id')
    .selectAll('l').select(['e.name as emp_name', 'e.code as emp_code', 'e.user_id as emp_user_id']);
}

async function figures(tx: Tx, loanIds: string[]) {
  const out = new Map<string, { outstanding: number; principal: number; next: string | null; paid: number }>();
  if (!loanIds.length) return out;
  const rows = await tx.selectFrom('loan_installments').select(['loan_id', 'seq', 'status', 'amount', 'principal', 'due_month', 'paid_amount'])
    .where('loan_id', 'in', loanIds).orderBy('seq').execute();
  for (const r of rows) {
    const f = out.get(r.loan_id) ?? { outstanding: 0, principal: 0, next: null, paid: 0 };
    f.paid = round2(f.paid + (r.paid_amount ?? 0));
    if (r.status === 'due' || r.status === 'in_run') {
      f.outstanding = round2(f.outstanding + r.amount); f.principal = round2(f.principal + r.principal);
      if (!f.next) f.next = r.due_month;
    } else if (r.status === 'recovered') f.paid = round2(f.paid + r.amount);
    out.set(r.loan_id, f);
  }
  return out;
}

function loanJson(l: LoanRow, f?: { outstanding: number; principal: number; next: string | null; paid: number }) {
  const review = l.kind === 'loan' && l.amount > PERQUISITE_LIMIT;
  return {
    id: l.id, number: l.number, employeeId: l.employee_id, employeeName: l.emp_name, employeeCode: l.emp_code, kind: l.kind,
    purpose: l.purpose, amount: l.amount, interestRate: l.interest_rate, instalment: l.instalment, startMonth: l.start_month.slice(0, 7),
    tenure: l.tenure, totalInterest: l.total_interest, totalPayable: round2(l.amount + l.total_interest), status: l.status,
    disbursedOn: l.disbursed_on, outstanding: f?.outstanding ?? 0, outstandingPrincipal: f?.principal ?? 0, recovered: f?.paid ?? 0,
    nextDueMonth: f?.next ? f.next.slice(0, 7) : null, caReview: review || l.ca_review, perquisiteNote: review ? PERQUISITE_NOTE : null,
    foreclosedOn: l.foreclosed_on, foreclosePrincipal: l.foreclose_principal, forecloseInterest: l.foreclose_interest, forecloseAmount: l.foreclose_amount, closedOn: l.closed_on,
  };
}

async function canSee(tx: Tx, ctx: RequestContext, employeeId: string) {
  if (ctx.can('loans.manage') || ctx.can('payroll.view')) return;
  const me = await myEmployee(tx, ctx);
  if (!(ctx.can('payroll.self') && me?.id === employeeId)) throw notFound('Loan');
}

async function loadLoan(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = loanSelect(tx).where('l.id', '=', id).where('l.company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate('l');
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Loan');
  await canSee(tx, ctx, row.employee_id);
  return row;
}

async function cashAccount(tx: Tx, ctx: RequestContext, accountId: string | undefined) {
  if (!accountId) {
    const a = await tx.selectFrom('accounts').select('id').where('company_id', '=', ctx.companyId).where('system_key', '=', 'bank').executeTakeFirstOrThrow();
    return a.id;
  }
  const a = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active']).where('id', '=', accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!a || !['cash', 'bank'].includes(a.subtype) || !a.is_active) throw badRequest('Choose an active cash or bank account.', { accountId: 'Not a cash or bank account' });
  return a.id;
}

export async function employeeLoansSummary(tx: Tx, employeeId: string) {
  const rows = await loanSelect(tx).where('l.employee_id', '=', employeeId).where('l.status', 'in', ['active', 'paused']).orderBy('l.created_at').execute();
  const f = await figures(tx, rows.map((r) => r.id));
  const loans = rows.map((r) => loanJson(r, f.get(r.id)));
  return {
    employeeId, outstanding: round2(loans.reduce((s, l) => s + l.outstanding, 0)),
    outstandingPrincipal: round2(loans.reduce((s, l) => s + l.outstandingPrincipal, 0)), loans,
  };
}

export async function loanRoutes(app: FastifyInstance) {
  app.get('/loans', async (req) => {
    const ctx = req.ctx;
    ctx.require('loans.manage', 'payroll.view', 'payroll.self');
    const q = parse(z.object({ employeeId: z.uuid().optional(), status: z.enum(['active', 'paused', 'closed', 'foreclosed']).optional(), kind: z.enum(['advance', 'loan']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let b = loanSelect(tx).where('l.company_id', '=', ctx.companyId);
      if (!ctx.can('loans.manage') && !ctx.can('payroll.view')) b = b.where('e.user_id', '=', ctx.userId);
      if (q.employeeId) b = b.where('l.employee_id', '=', q.employeeId);
      if (q.status) b = b.where('l.status', '=', q.status);
      if (q.kind) b = b.where('l.kind', '=', q.kind);
      const rows = await b.orderBy('l.created_at', 'desc').limit(200).execute();
      const f = await figures(tx, rows.map((r) => r.id));
      return { data: rows.map((r) => loanJson(r, f.get(r.id))), total: rows.length };
    });
  });

  app.post('/loans', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('loans.manage');
    const b = parse(createBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const emp = await tx.selectFrom('employees').select(['id', 'status', 'location_id']).where('id', '=', b.employeeId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!emp) throw notFound('Employee');
      if (emp.status !== 'active') throw badRequest('This employee is not active.', { employeeId: 'Not active' });
      const date = b.disbursedOn ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { disbursedOn: 'In the future' });
      const rate = b.interestRate ?? 0;
      const schedule = buildSchedule(b.amount, rate, b.instalment, `${b.startMonth}-01`);
      const interest = round2(schedule.reduce((s, r) => s + r.interest, 0));
      const bank = await cashAccount(tx, ctx, b.accountId);
      const number = await nextNumber(tx, ctx, 'employee_loan', financialYear(date));
      const entry = await postJournal(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId }, {
        date, voucherType: 'payment', voucherId: null, number, narration: `${b.kind === 'loan' ? 'Loan' : 'Advance'} ${number} to employee`,
        lines: [{ accountId: await loanAccount(tx, ctx), amount: b.amount, locationId: emp.location_id }, { accountId: bank, amount: -b.amount, locationId: emp.location_id }],
      });
      const l = await tx.insertInto('employee_loans').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, employee_id: b.employeeId, kind: b.kind, purpose: b.purpose, amount: b.amount,
        interest_rate: rate, instalment: b.instalment, start_month: `${b.startMonth}-01`, tenure: schedule.length, total_interest: interest,
        disbursed_on: date, disburse_account_id: bank, disburse_entry_id: entry, ca_review: b.kind === 'loan' && b.amount > PERQUISITE_LIMIT, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('loan_installments').values(schedule.map((s) => ({
        tenant_id: ctx.tenantId, loan_id: l.id, seq: s.seq, due_month: s.dueMonth, principal: s.principal, interest: s.interest, amount: s.amount,
      }))).execute();
      await writeAudit(tx, auditOf(ctx), 'employee_loan', l.id, 'create', null, { number, amount: b.amount, employeeId: b.employeeId });
      const row = await loadLoan(tx, ctx, l.id);
      return loanJson(row, (await figures(tx, [l.id])).get(l.id));
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/loans/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('loans.manage', 'payroll.view', 'payroll.self');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const row = await loadLoan(tx, ctx, id);
      const sched = await tx.selectFrom('loan_installments').selectAll().where('loan_id', '=', id).orderBy('seq').execute();
      return {
        ...loanJson(row, (await figures(tx, [id])).get(id)),
        schedule: sched.map((s) => ({ seq: s.seq, dueMonth: s.due_month.slice(0, 7), principal: s.principal, interest: s.interest, amount: s.amount, status: s.status, paidAmount: s.paid_amount, runId: s.run_id, recoveredOn: s.recovered_on })),
      };
    });
  });

  const setStatus = (from: string, to: string, action: string) => async (req: { ctx: RequestContext; params: unknown }) => {
    const ctx = req.ctx;
    ctx.require('loans.manage');
    const id = parse(z.uuid(), (req.params as { id: string }).id);
    return ctx.tx(async (tx) => {
      const row = await loadLoan(tx, ctx, id, true);
      if (row.status !== from) throw conflict(`This loan is ${row.status}.`, 'LOAN_STATE', { status: row.status });
      await tx.updateTable('employee_loans').set({ status: to }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'employee_loan', id, action, { status: from }, { status: to });
      return loanJson({ ...row, status: to }, (await figures(tx, [id])).get(id));
    });
  };
  app.post<{ Params: { id: string } }>('/loans/:id/pause', setStatus('active', 'paused', 'pause'));
  app.post<{ Params: { id: string } }>('/loans/:id/resume', setStatus('paused', 'active', 'resume'));

  app.get<{ Params: { id: string } }>('/loans/:id/foreclosure', async (req) => {
    const ctx = req.ctx;
    ctx.require('loans.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ payDate: z.preprocess(blank, dateField.optional()) }), req.query);
    return ctx.tx(async (tx) => {
      const row = await loadLoan(tx, ctx, id);
      if (!['active', 'paused'].includes(row.status)) throw conflict(`This loan is ${row.status}.`, 'LOAN_STATE', { status: row.status });
      const open = await tx.selectFrom('loan_installments').select(['status', 'principal', 'interest', 'due_month']).where('loan_id', '=', id).where('status', 'in', ['due', 'in_run']).execute();
      const date = b.payDate ?? todayIst();
      return { payDate: date, interestRate: row.interest_rate, method: 'reducing_balance', inRun: open.some((o) => o.status === 'in_run'),
        ...foreclosureQuote(open.map((o) => ({ dueMonth: o.due_month, principal: o.principal, interest: o.interest })), date) };
    });
  });

  app.post<{ Params: { id: string } }>('/loans/:id/foreclose', async (req) => {
    const ctx = req.ctx;
    ctx.require('loans.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ accountId: z.preprocess(blank, z.uuid().optional()), payDate: z.preprocess(blank, dateField.optional()) }), req.body);
    return ctx.tx(async (tx) => {
      const row = await loadLoan(tx, ctx, id, true);
      if (!['active', 'paused'].includes(row.status)) throw conflict(`This loan is ${row.status}.`, 'LOAN_STATE', { status: row.status });
      const open = await tx.selectFrom('loan_installments').select(['status', 'principal', 'interest', 'due_month']).where('loan_id', '=', id).where('status', 'in', ['due', 'in_run']).execute();
      if (open.some((o) => o.status === 'in_run')) throw conflict('An instalment is in an open payroll run. Remove it from the run or finish the run first.', 'INSTALMENT_IN_RUN');
      const date = b.payDate ?? todayIst();
      const q = foreclosureQuote(open.map((o) => ({ dueMonth: o.due_month, principal: o.principal, interest: o.interest })), date);
      const due = q.total;
      let entry: string | null = null;
      if (due > 0) {
        const bank = await cashAccount(tx, ctx, b.accountId);
        entry = await postJournal(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId }, {
          date, voucherType: 'receipt', voucherId: null, number: row.number,
          narration: `Foreclosure of ${row.number}: principal ${q.principal.toFixed(2)}, interest ${q.interest.toFixed(2)}`,
          lines: [
            { accountId: bank, amount: due }, { accountId: await loanAccount(tx, ctx), amount: -q.principal },
            { accountId: await ensureAccount(tx, ctx, ACC.interest, 'income', 4800), amount: -q.interest },
          ],
        });
      }
      await tx.updateTable('loan_installments').set({ status: 'waived' }).where('loan_id', '=', id).where('status', '=', 'due').execute();
      await tx.updateTable('employee_loans').set({ status: 'foreclosed', foreclosed_on: date, foreclose_amount: due, foreclose_principal: q.principal, foreclose_interest: q.interest, foreclose_entry_id: entry }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'employee_loan', id, 'foreclose', { status: row.status }, { status: 'foreclosed', amount: due, principal: q.principal, interest: q.interest });
      const fresh = await loadLoan(tx, ctx, id);
      return loanJson(fresh, (await figures(tx, [id])).get(id));
    });
  });

  app.get<{ Params: { id: string } }>('/employees/:id/loans', async (req) => {
    const ctx = req.ctx;
    ctx.require('loans.manage', 'payroll.view', 'payroll.self');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const e = await tx.selectFrom('employees').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!e) throw notFound('Employee');
      await canSee(tx, ctx, id);
      return employeeLoansSummary(tx, id);
    });
  });
}

documentRoute('POST', '/loans', { summary: 'Give a salary advance or loan', body: createBody });
