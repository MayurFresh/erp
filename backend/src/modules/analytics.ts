import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { accountTotals, profitLoss } from '../accounting/statements.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, fyStart, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest } from '../lib/errors.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const query = z.object({ from: dateField.optional(), to: dateField.optional() });
const TOP = 8;

/** The equal-length period that ends the day before `from`. */
export function previousPeriod(from: string, to: string) {
  const days = daysBetween(from, to) + 1;
  return { from: addDays(from, -days), to: addDays(from, -1) };
}

/** `YYYY-MM` for every month touched by the range, oldest first. */
function monthsOf(from: string, to: string): string[] {
  const out: string[] = [];
  let y = Number(from.slice(0, 4));
  let m = Number(from.slice(5, 7));
  const last = to.slice(0, 7);
  for (let i = 0; i < 120; i++) {
    const key = `${y}-${String(m).padStart(2, '0')}`;
    out.push(key);
    if (key >= last) break;
    m += 1;
    if (m > 12) { m = 1; y += 1; }
  }
  return out;
}

type Buckets = { notDue: number; d1_30: number; d31_60: number; d61_90: number; d90plus: number; total: number };
const emptyBuckets = (): Buckets => ({ notDue: 0, d1_30: 0, d31_60: 0, d61_90: 0, d90plus: 0, total: 0 });

export async function analyticsRoutes(app: FastifyInstance) {
  app.get('/analytics/overview', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const q = parse(query, req.query);
    const to = q.to ?? todayIst();
    const from = q.from ?? fyStart(to);
    if (from > to) throw badRequest('The start date is after the end date.', { from: 'After end date' });
    if (daysBetween(from, to) > 366 * 3) throw badRequest('Choose a period of up to 3 years.', { from: 'Too long' });
    const prev = previousPeriod(from, to);
    return ctx.tx((tx) => overview(tx, ctx, from, to, prev));
  });
}

async function overview(tx: Tx, ctx: RequestContext, from: string, to: string, prev: { from: string; to: string }) {
  const co = ctx.companyId;
  const scope = scopedLocationIds(ctx);
  const seeProfit = ctx.can('accounts.view');
  const seeCost = ctx.can('items.view_cost');
  const seeMoney = ctx.can('accounts.view') || ctx.can('payments.view');

  // ---- document totals (ex-tax), location scoped ---------------------------------------------
  const sumInvoices = async (a: string, b: string) => {
    let q = tx.selectFrom('invoices').where('company_id', '=', co).where('status', '=', 'posted')
      .where('invoice_date', '>=', a).where('invoice_date', '<=', b);
    if (scope) q = q.where('location_id', 'in', scope);
    const r = await q.select((eb) => eb.fn.coalesce(eb.fn.sum<number>('subtotal'), eb.lit(0)).as('t')).executeTakeFirstOrThrow();
    let c = tx.selectFrom('credit_notes').where('company_id', '=', co).where('status', '=', 'posted')
      .where('note_date', '>=', a).where('note_date', '<=', b);
    if (scope) c = c.where('location_id', 'in', scope);
    const cn = await c.select((eb) => eb.fn.coalesce(eb.fn.sum<number>('subtotal'), eb.lit(0)).as('t')).executeTakeFirstOrThrow();
    return round2(Number(r.t) - Number(cn.t));
  };
  const sumPurchases = async (a: string, b: string) => {
    let q = tx.selectFrom('purchases').where('company_id', '=', co).where('status', '=', 'posted')
      .where('bill_date', '>=', a).where('bill_date', '<=', b);
    if (scope) q = q.where('location_id', 'in', scope);
    return round2(Number((await q.select((eb) => eb.fn.coalesce(eb.fn.sum<number>('subtotal'), eb.lit(0)).as('t')).executeTakeFirstOrThrow()).t));
  };
  const sumExpenses = async (a: string, b: string) => {
    let q = tx.selectFrom('expenses').where('company_id', '=', co).where('status', '=', 'posted')
      .where('expense_date', '>=', a).where('expense_date', '<=', b);
    if (scope) q = q.where('location_id', 'in', scope);
    return round2(Number((await q.select((eb) => eb.fn.coalesce(eb.fn.sum<number>('amount'), eb.lit(0)).as('t')).executeTakeFirstOrThrow()).t));
  };
  const sumPayments = async (kind: 'receipt' | 'payment', a: string, b: string) => {
    const r = await tx.selectFrom('payments').where('company_id', '=', co).where('status', '=', 'posted').where('kind', '=', kind)
      .where('payment_date', '>=', a).where('payment_date', '<=', b)
      .select((eb) => eb.fn.coalesce(eb.fn.sum<number>('amount'), eb.lit(0)).as('t')).executeTakeFirstOrThrow();
    return round2(Number(r.t));
  };

  // Ledger balances at a date (company wide, so only for people who may see the books).
  const acc = seeProfit || seeMoney ? await systemAccounts(tx, ctx) : null;
  const balancesAt = async (date: string) => {
    if (!acc) return null;
    const rows = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
      .innerJoin('accounts as a', 'a.id', 'jl.account_id')
      .select((eb) => ['a.id', 'a.subtype', eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
      .where('je.company_id', '=', co).where('a.company_id', '=', co).where('je.entry_date', '<=', date)
      .where((eb) => eb.or([eb('a.id', 'in', [acc.receivables, acc.payables]), eb('a.subtype', 'in', ['cash', 'bank'])]))
      .groupBy(['a.id', 'a.subtype']).execute();
    const bal = (f: (r: (typeof rows)[number]) => boolean) => round2(rows.filter(f).reduce((s, r) => s + Number(r.d) - Number(r.c), 0));
    return {
      receivables: bal((r) => r.id === acc.receivables),
      payables: -bal((r) => r.id === acc.payables),
      cashAndBank: bal((r) => r.subtype === 'cash' || r.subtype === 'bank'),
    };
  };
  const stockAt = async (date: string) => {
    let q = tx.selectFrom('stock_moves').where('company_id', '=', co).where('created_at', '<', new Date(`${addDays(date, 1)}T00:00:00+05:30`));
    if (scope) q = q.where('location_id', 'in', scope);
    return round2(Number((await q.select((eb) => eb.fn.coalesce(eb.fn.sum<number>('value'), eb.lit(0)).as('t')).executeTakeFirstOrThrow()).t));
  };

  const kpisFor = async (a: string, b: string) => {
    const k: Record<string, number> = {
      sales: await sumInvoices(a, b),
      purchases: await sumPurchases(a, b),
      expenses: await sumExpenses(a, b),
    };
    if (seeMoney) {
      k.collections = await sumPayments('receipt', a, b);
      k.payments = await sumPayments('payment', a, b);
      Object.assign(k, await balancesAt(b));
    }
    if (seeProfit) {
      const pl = profitLoss(await accountTotals(tx, co, a, b));
      k.grossProfit = pl.grossProfit;
      k.netProfit = pl.netProfit;
    }
    if (seeCost) k.stockValue = await stockAt(b);
    return k;
  };
  const current = await kpisFor(from, to);
  const previous = await kpisFor(prev.from, prev.to);

  // ---- monthly trend --------------------------------------------------------------------------
  const months = monthsOf(from, to);
  const monthlyOf = async (table: 'invoices' | 'purchases' | 'expenses' | 'credit_notes') => {
    const dateCol = { invoices: 'invoice_date', purchases: 'bill_date', expenses: 'expense_date', credit_notes: 'note_date' }[table];
    const amountCol = table === 'expenses' ? 'amount' : 'subtotal';
    let q = tx.selectFrom(table as 'invoices').where('company_id', '=', co).where('status', '=', 'posted')
      .where(dateCol as 'invoice_date', '>=', from).where(dateCol as 'invoice_date', '<=', to);
    if (scope) q = q.where('location_id', 'in', scope);
    const rows = await q.select([sql<string>`to_char(${sql.ref(dateCol)}::date, 'YYYY-MM')`.as('m'),
      (eb) => eb.fn.sum<number>(amountCol as 'subtotal').as('t')]).groupBy('m').execute();
    return new Map(rows.map((r) => [r.m, Number(r.t)]));
  };
  const [mSales, mCredit, mPurchases, mExpenses] = await Promise.all([
    monthlyOf('invoices'), monthlyOf('credit_notes'), monthlyOf('purchases'), monthlyOf('expenses'),
  ]);
  const trend = months.map((m) => ({
    month: m,
    sales: round2((mSales.get(m) ?? 0) - (mCredit.get(m) ?? 0)),
    purchases: round2(mPurchases.get(m) ?? 0),
    expenses: round2(mExpenses.get(m) ?? 0),
  }));

  // ---- cash in and out ------------------------------------------------------------------------
  let cashFlow: { month: string; cashIn: number; cashOut: number }[] | undefined;
  if (seeMoney) {
    const rows = await tx.selectFrom('payments').where('company_id', '=', co).where('status', '=', 'posted')
      .where('payment_date', '>=', from).where('payment_date', '<=', to)
      .select([sql<string>`to_char(payment_date::date, 'YYYY-MM')`.as('m'), 'kind', (eb) => eb.fn.sum<number>('amount').as('t')])
      .groupBy(['m', 'kind']).execute();
    const get = (m: string, kind: string) => Number(rows.find((r) => r.m === m && r.kind === kind)?.t ?? 0);
    cashFlow = months.map((m) => ({ month: m, cashIn: round2(get(m, 'receipt')), cashOut: round2(get(m, 'payment')) }));
  }

  // ---- rankings ---------------------------------------------------------------------------------
  let cq = tx.selectFrom('invoices as v').innerJoin('parties as p', 'p.id', 'v.party_id')
    .where('v.company_id', '=', co).where('v.status', '=', 'posted').where('v.invoice_date', '>=', from).where('v.invoice_date', '<=', to);
  if (scope) cq = cq.where('v.location_id', 'in', scope);
  const custRows = await cq.groupBy(['p.id', 'p.name'])
    .select((eb) => ['p.id', 'p.name', eb.fn.sum<number>('v.subtotal').as('amount'), eb.fn.countAll<number>().as('invoices')])
    .orderBy('amount', 'desc').limit(TOP).execute();
  const salesTotal = round2(Number((await (() => {
    let q = tx.selectFrom('invoices').where('company_id', '=', co).where('status', '=', 'posted').where('invoice_date', '>=', from).where('invoice_date', '<=', to);
    if (scope) q = q.where('location_id', 'in', scope);
    return q.select((eb) => eb.fn.coalesce(eb.fn.sum<number>('subtotal'), eb.lit(0)).as('t')).executeTakeFirstOrThrow();
  })()).t));
  const topCustomers = custRows.map((r) => ({
    partyId: r.id, name: r.name, amount: round2(Number(r.amount)), invoices: Number(r.invoices),
    share: salesTotal > 0 ? Math.round((Number(r.amount) / salesTotal) * 1000) / 10 : 0,
  }));

  let iq = tx.selectFrom('invoice_lines as il').innerJoin('invoices as v', 'v.id', 'il.invoice_id').innerJoin('items as i', 'i.id', 'il.item_id')
    .where('v.company_id', '=', co).where('v.status', '=', 'posted').where('v.invoice_date', '>=', from).where('v.invoice_date', '<=', to);
  if (scope) iq = iq.where('v.location_id', 'in', scope);
  const itemRows = await iq.groupBy(['il.item_id', 'i.name', 'i.unit'])
    .select((eb) => ['il.item_id', 'i.name', 'i.unit', eb.fn.sum<number>('il.qty').as('qty'), eb.fn.sum<number>('il.taxable_value').as('amount')])
    .orderBy('amount', 'desc').limit(TOP).execute();
  const topItems = itemRows.map((r) => ({ itemId: r.item_id, name: r.name, unit: r.unit, qty: Number(r.qty), amount: round2(Number(r.amount)) }));

  let lq = tx.selectFrom('invoices as v').innerJoin('locations as l', 'l.id', 'v.location_id')
    .where('v.company_id', '=', co).where('v.status', '=', 'posted').where('v.invoice_date', '>=', from).where('v.invoice_date', '<=', to);
  if (scope) lq = lq.where('v.location_id', 'in', scope);
  const locRows = await lq.groupBy(['l.id', 'l.name'])
    .select((eb) => ['l.id', 'l.name', eb.fn.sum<number>('v.subtotal').as('amount')]).orderBy('amount', 'desc').execute();
  const salesByLocation = locRows.map((r) => ({ locationId: r.id, name: r.name, amount: round2(Number(r.amount)) }));

  let eq = tx.selectFrom('expenses as e').innerJoin('accounts as a', 'a.id', 'e.account_id')
    .where('e.company_id', '=', co).where('e.status', '=', 'posted').where('e.expense_date', '>=', from).where('e.expense_date', '<=', to);
  if (scope) eq = eq.where('e.location_id', 'in', scope);
  const expRows = await eq.groupBy(['a.id', 'a.name'])
    .select((eb) => ['a.id', 'a.name', eb.fn.sum<number>('e.amount').as('amount')]).orderBy('amount', 'desc').execute();
  const expensesByCategory = expRows.map((r) => ({ accountId: r.id, category: r.name, amount: round2(Number(r.amount)) }));

  // ---- ageing as of the end date --------------------------------------------------------------
  const bucketsOf = (docs: { due_date: string; open: number }[]) => {
    const b = emptyBuckets();
    for (const d of docs) {
      const late = daysBetween(d.due_date, to);
      const key: keyof Buckets = late <= 0 ? 'notDue' : late <= 30 ? 'd1_30' : late <= 60 ? 'd31_60' : late <= 90 ? 'd61_90' : 'd90plus';
      b[key] = round2(b[key] + d.open);
      b.total = round2(b.total + d.open);
    }
    return b;
  };
  let rq = tx.selectFrom('invoices').where('company_id', '=', co).where('status', '=', 'posted').where('invoice_date', '<=', to)
    .whereRef('amount_paid', '<', 'total');
  if (scope) rq = rq.where('location_id', 'in', scope);
  const rec = await rq.select(['due_date', 'total', 'amount_paid']).execute();
  let pq = tx.selectFrom('purchases').where('company_id', '=', co).where('status', '=', 'posted').where('bill_date', '<=', to)
    .whereRef('amount_paid', '<', 'net_payable');
  if (scope) pq = pq.where('location_id', 'in', scope);
  const pay = await pq.select(['due_date', 'net_payable', 'amount_paid']).execute();
  const ageing = {
    receivables: bucketsOf(rec.map((r) => ({ due_date: r.due_date, open: Number(r.total) - Number(r.amount_paid) }))),
    payables: bucketsOf(pay.map((r) => ({ due_date: r.due_date, open: Number(r.net_payable) - Number(r.amount_paid) }))),
  };

  return {
    from, to, previousFrom: prev.from, previousTo: prev.to,
    kpis: { current, previous },
    trend,
    ...(cashFlow ? { cashFlow } : {}),
    topCustomers, topItems, salesByLocation, expensesByCategory, ageing,
  };
}
