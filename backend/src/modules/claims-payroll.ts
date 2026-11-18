import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { auditOf, writeAudit } from './audit.ts';
import { ACC, ensureAccount, lastDay, loanAccount, payableAccount, round2 } from './claims-common.ts';

/**
 * Called by the payroll approve route after the accrual is posted. Instalments and reimbursements that were
 * attached to the run by the database trigger become final: the cost already booked by the claim is taken back
 * out of "Salary - One-time additions", and loan instalments clear the deduction payable into the loan account
 * and interest income. Entries for employees who ended up without a payroll line are released to the next run.
 */
export async function onPayrollApproved(tx: Tx, ctx: RequestContext, run: { id: string; month: string; number: string; location_id: string | null }, employeeIds: string[]) {
  const date = lastDay(run.month);
  const who = { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId };
  const inLine = new Set(employeeIds);

  const insts = await tx.selectFrom('loan_installments as i').innerJoin('employee_loans as l', 'l.id', 'i.loan_id')
    .select(['i.id', 'i.loan_id', 'i.principal', 'i.interest', 'i.amount', 'i.paid_amount', 'i.adjustment_id', 'l.employee_id'])
    .where('i.run_id', '=', run.id).where('i.status', '=', 'in_run').execute();
  const lineAdj = new Map<string, { id?: string; amount: number }[]>();
  for (const l of await tx.selectFrom('payroll_lines').select(['employee_id', 'adjustments']).where('run_id', '=', run.id).execute()) lineAdj.set(l.employee_id, l.adjustments as { id?: string; amount: number }[]);
  let principal = 0, interest = 0;
  const loanIds = new Set<string>();
  for (const i of insts) {
    if (!inLine.has(i.employee_id)) {
      if (i.adjustment_id) await tx.deleteFrom('payroll_adjustments').where('id', '=', i.adjustment_id).execute();
      continue;
    }
    // Net pay may have limited the recovery (payroll.ts): the line holds the amount actually taken.
    const lineAdjs = lineAdj.get(i.employee_id) ?? [];
    const took = round2(lineAdjs.find((a) => a.id === i.adjustment_id)?.amount ?? i.amount);
    if (took < i.amount) {
      const intPart = Math.min(took, i.interest), prinPart = round2(took - intPart);
      principal += prinPart; interest += intPart; loanIds.add(i.loan_id);
      if (i.adjustment_id) {
        if (took > 0) await tx.updateTable('payroll_adjustments').set({ amount: took }).where('id', '=', i.adjustment_id).execute();
        else await tx.deleteFrom('payroll_adjustments').where('id', '=', i.adjustment_id).execute();
      }
      await tx.updateTable('loan_installments').set({
        status: 'due', run_id: null, adjustment_id: null, paid_amount: round2(i.paid_amount + took), principal: round2(i.principal - prinPart),
        interest: round2(i.interest - intPart), amount: round2(i.amount - took),
      }).where('id', '=', i.id).execute();
      continue;
    }
    principal += i.principal; interest += i.interest; loanIds.add(i.loan_id);
    await tx.updateTable('loan_installments').set({ status: 'recovered', recovered_on: date }).where('id', '=', i.id).execute();
  }
  if (principal + interest > 0) {
    await postJournal(tx, who, {
      date, voucherType: 'journal', voucherId: run.id, number: run.number, narration: `Loan and advance recovery in ${run.number}`,
      lines: [
        { accountId: await ensureAccount(tx, ctx, ACC.otherDed, 'liability', 2450), amount: round2(principal + interest), locationId: run.location_id },
        { accountId: await loanAccount(tx, ctx), amount: -round2(principal), locationId: run.location_id },
        { accountId: await ensureAccount(tx, ctx, ACC.interest, 'income', 4800), amount: -round2(interest), locationId: run.location_id },
      ],
    });
  }
  for (const loanId of loanIds) {
    const left = await tx.selectFrom('loan_installments').select((eb) => eb.fn.countAll<number>().as('n'))
      .where('loan_id', '=', loanId).where('status', 'in', ['due', 'in_run']).executeTakeFirstOrThrow();
    if (Number(left.n) === 0) {
      await tx.updateTable('employee_loans').set({ status: 'closed', closed_on: date }).where('id', '=', loanId).where('status', 'in', ['active', 'paused']).execute();
      await writeAudit(tx, auditOf(ctx), 'employee_loan', loanId, 'close', null, { closedOn: date });
    }
  }

  const claims = await tx.selectFrom('expense_claims').select(['id', 'employee_id', 'total', 'payroll_adjustment_id', 'number'])
    .where('payroll_run_id', '=', run.id).where('status', '=', 'approved').execute();
  let reimbursed = 0;
  for (const c of claims) {
    if (!inLine.has(c.employee_id)) {
      if (c.payroll_adjustment_id) await tx.deleteFrom('payroll_adjustments').where('id', '=', c.payroll_adjustment_id).execute();
      continue;
    }
    reimbursed += c.total;
    await tx.updateTable('expense_claims').set({ status: 'paid', paid_at: new Date(), pay_date: date }).where('id', '=', c.id).execute();
    await writeAudit(tx, auditOf(ctx), 'expense_claim', c.id, 'paid_in_payroll', { status: 'approved' }, { status: 'paid', run: run.number });
  }
  if (reimbursed > 0) {
    await postJournal(tx, who, {
      date, voucherType: 'journal', voucherId: run.id, number: run.number, narration: `Claim reimbursements paid through ${run.number}`,
      lines: [
        { accountId: await payableAccount(tx, ctx), amount: round2(reimbursed), locationId: run.location_id },
        { accountId: await ensureAccount(tx, ctx, ACC.oneTime, 'expense', 6500), amount: -round2(reimbursed), locationId: run.location_id },
      ],
    });
  }
}
