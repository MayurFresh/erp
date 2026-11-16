import type { Tx } from '../db/database.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;

export interface AccountTotal { id: string; code: string; name: string; type: string; system_key: string | null; d: number; c: number }

/** Filters on journal lines: a cost centre, or a location (branch P&L). */
export interface LineFilter { costCentreId?: string | null; locationId?: string | null }

/** Debit and credit totals per account, optionally within a date range and for some lines only. */
export async function accountTotals(
  tx: Tx, companyId: string, from: string | null, to: string, filter: LineFilter = {},
): Promise<AccountTotal[]> {
  let q = tx.selectFrom('accounts as a')
    .innerJoin('journal_lines as jl', 'jl.account_id', 'a.id')
    .innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .where('a.company_id', '=', companyId).where('je.entry_date', '<=', to);
  // A dated profit and loss ignores year-end closing entries; trial balance and balance sheet (from null) count them.
  if (from) q = q.where('je.entry_date', '>=', from).where('je.voucher_type', '<>', 'closing');
  if (filter.costCentreId) q = q.where('jl.cost_centre_id', '=', filter.costCentreId);
  if (filter.locationId) q = q.where('jl.location_id', '=', filter.locationId);
  const rows = await q.groupBy(['a.id', 'a.code', 'a.name', 'a.type', 'a.system_key'])
    .select((eb) => ['a.id', 'a.code', 'a.name', 'a.type', 'a.system_key',
      eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
    .orderBy('a.code').execute();
  return rows.map((r) => ({ ...r, d: Number(r.d), c: Number(r.c) }));
}

export interface SectionRow { accountId: string | null; code: string | null; name: string; amount: number }
export interface Section { rows: SectionRow[]; total: number }

export const section = (rows: { id: string | null; code: string | null; name: string; amount: number }[]): Section => {
  const kept = rows.filter((r) => Math.abs(r.amount) >= 0.005).map((r) => ({ accountId: r.id, code: r.code, name: r.name, amount: round2(r.amount) }));
  return { rows: kept, total: round2(kept.reduce((s, r) => s + r.amount, 0)) };
};

export interface TrialBalanceRow { accountId: string; code: string; name: string; type: string; debit: number; credit: number }

export function trialBalance(totals: AccountTotal[]) {
  const rows: TrialBalanceRow[] = totals
    .map((a) => ({ a, bal: round2(a.d - a.c) }))
    .filter((x) => x.bal !== 0)
    .map(({ a, bal }) => ({ accountId: a.id, code: a.code, name: a.name, type: a.type, debit: bal > 0 ? bal : 0, credit: bal < 0 ? -bal : 0 }));
  return {
    rows,
    totalDebit: round2(rows.reduce((s, r) => s + r.debit, 0)),
    totalCredit: round2(rows.reduce((s, r) => s + r.credit, 0)),
  };
}

const DIRECT = ['cogs', 'purchases_nonstock'];
const isSales = (a: AccountTotal) => a.system_key === 'sales' || a.system_key === 'sales_returns';

export function profitLoss(totals: AccountTotal[]) {
  const credit = (a: AccountTotal) => a.c - a.d;
  const debit = (a: AccountTotal) => a.d - a.c;
  const pick = (f: (a: AccountTotal) => boolean, amount: (a: AccountTotal) => number) =>
    section(totals.filter(f).map((a) => ({ id: a.id, code: a.code, name: a.name, amount: amount(a) })));
  const revenue = pick(isSales, credit);
  const cogs = pick((a) => DIRECT.includes(a.system_key ?? ''), debit);
  const otherIncome = pick((a) => a.type === 'income' && !isSales(a), credit);
  const expenses = pick((a) => a.type === 'expense' && !DIRECT.includes(a.system_key ?? ''), debit);
  const grossProfit = round2(revenue.total - cogs.total);
  return { revenue, cogs, grossProfit, otherIncome, expenses, netProfit: round2(grossProfit + otherIncome.total - expenses.total) };
}

export function balanceSheet(totals: AccountTotal[]) {
  const of = (type: string, sign: 1 | -1) =>
    totals.filter((a) => a.type === type).map((a) => ({ id: a.id, code: a.code, name: a.name, amount: sign * (a.d - a.c) }));
  const profit = totals.filter((a) => a.type === 'income' || a.type === 'expense').reduce((s, a) => s + (a.c - a.d), 0);
  const assets = section(of('asset', 1));
  const liabilities = section(of('liability', -1));
  const equity = section([...of('equity', -1), { id: null, code: null, name: 'Profit & Loss', amount: profit }]);
  return {
    assets, liabilities, equity,
    totalAssets: assets.total, totalLiabilitiesAndEquity: round2(liabilities.total + equity.total),
  };
}
