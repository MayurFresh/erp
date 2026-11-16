import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';

export const round2 = (n: number) => Math.round(n * 100) / 100;
export const lastDay = (m: string) =>
  `${m.slice(0, 8)}${String(new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)), 0)).getUTCDate()).padStart(2, '0')}`;

export const ACC = {
  payable: 'Employee Reimbursements Payable',
  loans: 'Employee Loans and Advances',
  interest: 'Interest on Employee Loans',
  oneTime: 'Salary - One-time additions',
  otherDed: 'Other Salary Deductions Payable',
} as const;

/** Finds an account by name or creates it with the next free code from `base`. */
export async function ensureAccount(
  tx: Tx, ctx: { tenantId: string; companyId: string }, name: string,
  type: 'expense' | 'liability' | 'asset' | 'income', base: number,
): Promise<string> {
  const ex = await tx.selectFrom('accounts').select('id').where('company_id', '=', ctx.companyId).where('name', '=', name).executeTakeFirst();
  if (ex) return ex.id;
  const used = new Set((await tx.selectFrom('accounts').select('code').where('company_id', '=', ctx.companyId).execute()).map((r) => r.code));
  let code = base;
  while (used.has(String(code))) code += 1;
  const row = await tx.insertInto('accounts').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, code: String(code), name, type, subtype: 'other', system_key: null, is_system: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

export const payableAccount = (tx: Tx, ctx: RequestContext) => ensureAccount(tx, ctx, ACC.payable, 'liability', 2460);
export const loanAccount = (tx: Tx, ctx: RequestContext) => ensureAccount(tx, ctx, ACC.loans, 'asset', 1450);
