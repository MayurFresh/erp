import type { Tx } from '../db/database.ts';
import { addDays, daysBetween } from '../lib/dates.ts';
import { defaultCategory, isCash, isInterestExpense, loadAccounts, type CfCategory } from './cashflow.ts';
import { accountTotals, profitLoss, type AccountTotal } from './statements.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;

export interface Ratio {
  key: string; label: string; group: 'liquidity' | 'leverage' | 'profitability' | 'efficiency';
  unit: 'times' | 'percent' | 'days'; value: number | null; formula: string; inputs: Record<string, number>;
}
export interface RatioSet { from: string; to: string; days: number; ratios: Ratio[] }

const div = (a: number, b: number): number | null => (Math.abs(b) < 0.005 ? null : round2(a / b));

interface Balances {
  currentAssets: number; inventory: number; receivables: number; payables: number; currentLiabilities: number;
  debt: number; netWorth: number; totalAssets: number;
}

function balancesAt(totals: AccountTotal[], accounts: Awaited<ReturnType<typeof loadAccounts>>, mapping: Map<string, CfCategory>): Balances {
  const byId = new Map(totals.map((t) => [t.id, t]));
  const b: Balances = { currentAssets: 0, inventory: 0, receivables: 0, payables: 0, currentLiabilities: 0, debt: 0, netWorth: 0, totalAssets: 0 };
  let profit = 0;
  for (const a of accounts) {
    const t = byId.get(a.id);
    const bal = t ? t.d - t.c : 0;
    if (a.type === 'income' || a.type === 'expense') { profit -= bal; continue; }
    const cat = mapping.get(a.id) ?? defaultCategory(a);
    if (a.type === 'asset') {
      b.totalAssets += bal;
      if (isCash(a) || cat === 'operating') b.currentAssets += bal;
      if (a.subtype === 'inventory') b.inventory += bal;
      if (a.subtype === 'receivables') b.receivables += bal;
    } else if (a.type === 'liability') {
      if (cat === 'financing') b.debt -= bal; else b.currentLiabilities -= bal;
      if (a.subtype === 'payables') b.payables -= bal;
    } else b.netWorth -= bal;
  }
  b.netWorth += profit;
  return b;
}

export async function buildRatios(tx: Tx, companyId: string, from: string, to: string, mapping: Map<string, CfCategory>): Promise<RatioSet> {
  const accounts = await loadAccounts(tx, companyId);
  const days = daysBetween(from, to) + 1;
  const closing = balancesAt(await accountTotals(tx, companyId, null, to), accounts, mapping);
  const opening = balancesAt(await accountTotals(tx, companyId, null, addDays(from, -1)), accounts, mapping);
  const periodTotals = await accountTotals(tx, companyId, from, to);
  const pl = profitLoss(periodTotals);
  const interest = round2(periodTotals.filter((t) => isInterestExpense({ ...t, subtype: '' })).reduce((s, a) => s + a.d - a.c, 0));
  const revenue = pl.revenue.total;
  const cogs = pl.cogs.total;
  const ebit = round2(pl.netProfit + interest);
  const capitalEmployed = round2(closing.totalAssets - closing.currentLiabilities);
  const avgInv = round2((opening.inventory + closing.inventory) / 2);
  const avgRec = round2((opening.receivables + closing.receivables) / 2);
  const avgPay = round2((opening.payables + closing.payables) / 2);
  const turnover = div(cogs, avgInv);

  const r = (key: string, label: string, group: Ratio['group'], unit: Ratio['unit'], value: number | null, formula: string, inputs: Record<string, number>): Ratio =>
    ({ key, label, group, unit, value, formula, inputs: Object.fromEntries(Object.entries(inputs).map(([k, v]) => [k, round2(v)])) });
  const pct = (a: number, b: number) => (Math.abs(b) < 0.005 ? null : round2((a / b) * 100));

  return {
    from, to, days,
    ratios: [
      r('current_ratio', 'Current ratio', 'liquidity', 'times', div(closing.currentAssets, closing.currentLiabilities),
        'Current assets / current liabilities', { currentAssets: closing.currentAssets, currentLiabilities: closing.currentLiabilities }),
      r('quick_ratio', 'Quick ratio', 'liquidity', 'times', div(closing.currentAssets - closing.inventory, closing.currentLiabilities),
        '(Current assets - inventory) / current liabilities', { currentAssets: closing.currentAssets, inventory: closing.inventory, currentLiabilities: closing.currentLiabilities }),
      r('debt_equity', 'Debt to equity', 'leverage', 'times', div(closing.debt, closing.netWorth),
        'Loans and borrowings / owner funds (capital plus profit)', { debt: closing.debt, ownerFunds: closing.netWorth }),
      r('gross_margin', 'Gross margin', 'profitability', 'percent', pct(pl.grossProfit, revenue),
        '(Sales - cost of goods sold) / sales x 100', { sales: revenue, costOfGoodsSold: cogs, grossProfit: pl.grossProfit }),
      r('net_margin', 'Net margin', 'profitability', 'percent', pct(pl.netProfit, revenue),
        'Net profit / sales x 100', { netProfit: pl.netProfit, sales: revenue }),
      r('roce', 'Return on capital employed', 'profitability', 'percent', pct(ebit, capitalEmployed),
        '(Net profit + interest) / (total assets - current liabilities) x 100', { ebit, capitalEmployed }),
      r('inventory_turnover', 'Inventory turnover', 'efficiency', 'times', turnover,
        'Cost of goods sold / average inventory', { costOfGoodsSold: cogs, averageInventory: avgInv }),
      r('inventory_days', 'Inventory days', 'efficiency', 'days', Math.abs(cogs) < 0.005 || Math.abs(avgInv) < 0.005 ? null : round2((days * avgInv) / cogs),
        'Days in period / inventory turnover', { days, inventoryTurnover: turnover ?? 0 }),
      r('debtor_days', 'Debtor days', 'efficiency', 'days', (() => { return Math.abs(revenue) < 0.005 ? null : round2((avgRec / revenue) * days); })(),
        'Average receivables / sales x days in period', { averageReceivables: avgRec, sales: revenue, days }),
      r('creditor_days', 'Creditor days', 'efficiency', 'days', (() => { return Math.abs(cogs) < 0.005 ? null : round2((avgPay / cogs) * days); })(),
        'Average payables / cost of goods sold x days in period', { averagePayables: avgPay, costOfGoodsSold: cogs, days }),
      r('interest_coverage', 'Interest coverage', 'leverage', 'times', div(ebit, interest),
        '(Net profit + interest) / interest expense', { ebit, interest }),
    ],
  };
}
