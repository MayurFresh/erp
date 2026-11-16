import type { Tx } from '../db/database.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;

export type CfCategory = 'operating' | 'investing' | 'financing' | 'noncash';
export const CF_CATEGORIES: CfCategory[] = ['operating', 'investing', 'financing', 'noncash'];

export interface CfAccount {
  id: string; code: string; name: string; type: string; subtype: string; system_key: string | null;
}

const INVESTMENT_NAME = /invest|fixed deposit|\bfd\b|mutual fund|shares|securities|bonds/i;
const LOAN_NAME = /loan|borrow|debenture|overdraft|\bod\b/i;
const INTEREST_NAME = /interest/i;

export const isCash = (a: CfAccount) => a.type === 'asset' && (a.subtype === 'cash' || a.subtype === 'bank');
export const isInterestExpense = (a: CfAccount) => a.type === 'expense' && INTEREST_NAME.test(a.name) && a.system_key !== 'tax_interest';
export const isInterestIncome = (a: CfAccount) => a.type === 'income' && INTEREST_NAME.test(a.name);

/** Where a balance sheet account lands when the company has not mapped it. */
export function defaultCategory(a: CfAccount): CfCategory {
  if (a.type === 'equity') return 'financing';
  if (a.type === 'asset') {
    if (a.subtype === 'fixed_asset' || INVESTMENT_NAME.test(a.name)) return 'investing';
    return 'operating';
  }
  if (a.type === 'liability' && LOAN_NAME.test(a.name)) return 'financing';
  return 'operating';
}

export interface CfAccountAmount { accountId: string | null; code: string; name: string; amount: number }
export interface CfLine { key: string; label: string; group: 'profit' | 'adjustment' | 'working_capital' | 'other'; amount: number; accounts: CfAccountAmount[] }
export interface CfSection { key: 'operating' | 'investing' | 'financing'; title: string; total: number; lines: CfLine[] }
export interface CashFlow {
  from: string; to: string; netProfit: number; openingCash: number; closingCash: number; netChange: number;
  computedChange: number; difference: number; reconciles: boolean; sections: CfSection[];
}

/** Debit and credit movement per account in a date range, leaving out year-end closing entries. */
async function movement(tx: Tx, companyId: string, from: string | null, to: string) {
  let q = tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .where('je.company_id', '=', companyId).where('je.entry_date', '<=', to).where('je.voucher_type', '<>', 'closing');
  if (from) q = q.where('je.entry_date', '>=', from);
  const rows = await q.groupBy('jl.account_id')
    .select((eb) => ['jl.account_id', eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')]).execute();
  return new Map(rows.map((r) => [r.account_id, Number(r.d) - Number(r.c)]));
}

export async function loadCfMapping(tx: Tx, companyId: string): Promise<Map<string, CfCategory>> {
  const rows = await tx.selectFrom('cf_mappings').select(['account_id', 'category']).where('company_id', '=', companyId).execute();
  return new Map(rows.map((r) => [r.account_id, r.category as CfCategory]));
}

export async function loadAccounts(tx: Tx, companyId: string): Promise<CfAccount[]> {
  return tx.selectFrom('accounts').select(['id', 'code', 'name', 'type', 'subtype', 'system_key'])
    .where('company_id', '=', companyId).orderBy('code').execute();
}

/** Indirect-method cash flow for one period. `net` is debit less credit; the cash effect of an asset is the opposite. */
export async function buildCashFlow(
  tx: Tx, companyId: string, from: string, to: string, mapping: Map<string, CfCategory>,
): Promise<CashFlow> {
  const accounts = await loadAccounts(tx, companyId);
  const mv = await movement(tx, companyId, from, to);
  const before = await movement(tx, companyId, null, new Date(Date.parse(`${from}T00:00:00Z`) - 86_400_000).toISOString().slice(0, 10));
  const net = (a: CfAccount) => mv.get(a.id) ?? 0;

  const lines = new Map<string, CfLine>();
  const section = new Map<string, 'operating' | 'investing' | 'financing'>();
  const order: string[] = [];
  const put = (sec: 'operating' | 'investing' | 'financing', key: string, label: string, group: CfLine['group'], a: CfAccount | null, amount: number, name?: string) => {
    if (!lines.has(key)) { lines.set(key, { key, label, group, amount: 0, accounts: [] }); section.set(key, sec); order.push(key); }
    const l = lines.get(key)!;
    l.amount += amount;
    l.accounts.push({ accountId: a?.id ?? null, code: a?.code ?? '', name: name ?? a?.name ?? label, amount: round2(amount) });
  };

  let netProfit = 0;
  let dep = 0; let gain = 0; let loss = 0; let intExp = 0; let intInc = 0;
  for (const a of accounts) {
    const n = net(a);
    if (a.type === 'income') netProfit -= n; else if (a.type === 'expense') netProfit -= n;
    if (a.system_key === 'depreciation') { dep += n; put('operating', 'dep', 'Depreciation', 'adjustment', a, n); }
    else if (a.system_key === 'asset_gain') { gain += -n; put('operating', 'asset_gain_loss', 'Loss (gain) on sale of assets', 'adjustment', a, n); }
    else if (a.system_key === 'asset_loss') { loss += n; put('operating', 'asset_gain_loss', 'Loss (gain) on sale of assets', 'adjustment', a, n); }
    else if (isInterestExpense(a)) { intExp += n; put('operating', 'interest_paid_addback', 'Interest expense added back', 'adjustment', a, n); }
    else if (isInterestIncome(a)) { intInc += -n; put('operating', 'interest_received_less', 'Interest income taken out', 'adjustment', a, n); }
  }
  put('operating', 'net_profit', 'Net profit for the period', 'profit', null, netProfit);
  if (intExp) put('financing', 'interest_paid', 'Interest paid', 'other', null, -intExp);
  if (intInc) put('investing', 'interest_received', 'Interest received', 'other', null, intInc);

  let fixedEffect = 0;
  for (const a of accounts) {
    if (a.type === 'income' || a.type === 'expense' || isCash(a)) continue;
    const n = net(a);
    if (Math.abs(n) < 0.005) continue;
    const effect = -n; // asset: -(d-c); liability and equity: c-d, which is the same expression
    const cat = mapping.get(a.id) ?? defaultCategory(a);
    if (cat === 'noncash') put('operating', 'provisions', 'Provisions and other non-cash items', 'adjustment', a, effect);
    else if (cat === 'investing') {
      if (a.subtype === 'fixed_asset') { fixedEffect += effect; put('investing', 'fixed_assets', 'Purchase and sale of fixed assets', 'other', a, effect); }
      else put('investing', 'investments', 'Investments', 'other', a, effect);
    } else if (cat === 'financing') {
      if (a.type === 'equity') put('financing', 'capital', 'Capital introduced, drawings and other equity', 'other', a, effect);
      else put('financing', 'loans', 'Loans taken and repaid', 'other', a, effect);
    } else if (a.type === 'asset') {
      if (a.subtype === 'receivables') put('operating', 'receivables', 'Trade receivables', 'working_capital', a, effect);
      else if (a.subtype === 'inventory') put('operating', 'inventory', 'Inventory', 'working_capital', a, effect);
      else put('operating', 'other_assets', 'Other current assets', 'working_capital', a, effect);
    } else if (a.type === 'liability') {
      if (a.subtype === 'payables') put('operating', 'payables', 'Trade payables', 'working_capital', a, effect);
      else put('operating', 'other_liabilities', 'Other current liabilities', 'working_capital', a, effect);
    } else put('operating', 'other_liabilities', 'Other current liabilities', 'working_capital', a, effect);
  }
  // Depreciation and the gain or loss on disposals were taken out of the asset movement, so the fixed-asset line is net of them.
  const fixedAdj = -dep + gain - loss;
  if (fixedAdj !== 0 || fixedEffect !== 0) {
    put('investing', 'fixed_assets', 'Purchase and sale of fixed assets', 'other', null, fixedAdj, 'Depreciation, gain and loss already counted in profit');
  }

  const sections: CfSection[] = (['operating', 'investing', 'financing'] as const).map((key) => {
    const ls = order.filter((k) => section.get(k) === key).map((k) => lines.get(k)!)
      .map((l) => ({ ...l, amount: round2(l.amount), accounts: l.accounts.filter((x) => Math.abs(x.amount) >= 0.005) }))
      .filter((l) => l.key === 'net_profit' || Math.abs(l.amount) >= 0.005);
    const rank = { profit: 0, adjustment: 1, working_capital: 2, other: 3 } as const;
    ls.sort((x, y) => rank[x.group] - rank[y.group]);
    return {
      key, total: round2(ls.reduce((s, l) => s + l.amount, 0)), lines: ls,
      title: key === 'operating' ? 'Cash flow from operating activities' : key === 'investing' ? 'Cash flow from investing activities' : 'Cash flow from financing activities',
    };
  });

  const cash = accounts.filter(isCash);
  const openingCash = round2(cash.reduce((s, a) => s + (before.get(a.id) ?? 0), 0));
  const change = round2(cash.reduce((s, a) => s + net(a), 0));
  const computedChange = round2(sections.reduce((s, x) => s + x.total, 0));
  const difference = round2(change - computedChange);
  return {
    from, to, netProfit: round2(netProfit), openingCash, closingCash: round2(openingCash + change), netChange: change,
    computedChange, difference, reconciles: Math.abs(difference) < 0.005, sections,
  };
}
