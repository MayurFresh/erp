import { sql } from 'kysely';
import { accountTotals, profitLoss } from '../accounting/statements.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, fyStart, todayIst } from './dates.ts';
import { toCsv } from './csv.ts';
import { scopedLocationIds } from './scope.ts';

export const REPORTS = {
  profit_loss: { label: 'Profit and loss', perm: 'accounts.view', ranged: true },
  sales_register: { label: 'Sales register', perm: 'reports.view', ranged: true },
  receivables_ageing: { label: 'Receivables ageing', perm: 'reports.view', ranged: false },
  stock_valuation: { label: 'Stock valuation', perm: 'items.view_cost', ranged: false },
  gst_summary: { label: 'GST summary', perm: 'reports.view', ranged: true },
  crm_numbers: { label: 'CRM numbers', perm: 'crm.view', ranged: true },
} as const;
export type ReportKey = keyof typeof REPORTS;
export const PERIODS = ['previous_day', 'previous_week', 'previous_month', 'month_to_date', 'fy_to_date'] as const;
export type Period = (typeof PERIODS)[number];

export const defaultPeriod = (frequency: string): Period =>
  frequency === 'daily' ? 'previous_day' : frequency === 'weekly' ? 'previous_week' : 'previous_month';

/** Date range for a period, as of today (India date). */
export function periodRange(period: Period, today = todayIst()): { from: string; to: string } {
  const monthStart = `${today.slice(0, 7)}-01`;
  switch (period) {
    case 'previous_day': { const d = addDays(today, -1); return { from: d, to: d }; }
    case 'previous_week': return { from: addDays(today, -7), to: addDays(today, -1) };
    case 'previous_month': { const to = addDays(monthStart, -1); return { from: `${to.slice(0, 7)}-01`, to }; }
    case 'month_to_date': return { from: monthStart, to: today };
    default: return { from: fyStart(today), to: today };
  }
}

export interface Built { title: string; period: string; header: string[]; rows: unknown[][]; summary: [string, string][]; csv: string }

const r2 = (n: number) => Math.round(n * 100) / 100;
const num = (v: unknown) => Number(v ?? 0);
const inr = (n: number) => `₹${n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

export async function buildReport(tx: Tx, ctx: RequestContext, report: ReportKey, filters: { period?: string }, frequency: string): Promise<Built> {
  const def = REPORTS[report];
  if (!ctx.can(def.perm) || (report === 'stock_valuation' && !ctx.can('reports.view'))) throw new Error(`The report owner can no longer see ${def.label.toLowerCase()}.`);
  const today = todayIst();
  const period = PERIODS.includes(filters.period as Period) ? (filters.period as Period) : defaultPeriod(frequency);
  const { from, to } = periodRange(period, today);
  const scope = scopedLocationIds(ctx);
  const loc = (col: string) => (scope ? sql`and ${sql.raw(col)} in (${sql.join(scope)})` : sql``);
  const label = def.ranged ? `${from} to ${to}` : `as of ${today}`;
  const out = (header: string[], rows: unknown[][], summary: [string, string][]): Built =>
    ({ title: def.label, period: label, header, rows, summary, csv: toCsv(header, rows) });

  if (report === 'profit_loss') {
    const p = profitLoss(await accountTotals(tx, ctx.companyId, from, to));
    const rows: unknown[][] = [];
    for (const [name, s] of [['Revenue', p.revenue], ['Direct costs', p.cogs], ['Other income', p.otherIncome], ['Expenses', p.expenses]] as const) {
      for (const r of s.rows) rows.push([name, r.name, r.amount]);
    }
    return out(['Section', 'Account', 'Amount'], rows, [['Revenue', inr(p.revenue.total)], ['Gross profit', inr(p.grossProfit)], ['Net profit', inr(p.netProfit)]]);
  }
  if (report === 'sales_register') {
    const rows = (await sql<any>`select v.number, v.invoice_date, p.name, p.gstin, v.subtotal, v.cgst, v.sgst, v.igst, v.total from invoices v
      join parties p on p.id = v.party_id where v.company_id = ${ctx.companyId} and v.status = 'posted'
      and v.invoice_date >= ${from} and v.invoice_date <= ${to} ${loc('v.location_id')} order by v.invoice_date, v.number`.execute(tx)).rows;
    const total = r2(rows.reduce((s, r) => s + num(r.total), 0));
    return out(['Number', 'Date', 'Customer', 'GSTIN', 'Taxable', 'CGST', 'SGST', 'IGST', 'Total'],
      rows.map((r) => [r.number, r.invoice_date, r.name, r.gstin ?? '', num(r.subtotal), num(r.cgst), num(r.sgst), num(r.igst), num(r.total)]),
      [['Invoices', String(rows.length)], ['Total sales', inr(total)]]);
  }
  if (report === 'receivables_ageing') {
    const rows = (await sql<any>`select p.name, v.due_date, v.total - v.amount_paid as due from invoices v join parties p on p.id = v.party_id
      where v.company_id = ${ctx.companyId} and v.status = 'posted' and v.amount_paid < v.total ${loc('v.location_id')}`.execute(tx)).rows;
    const by = new Map<string, number[]>();
    for (const r of rows) {
      const late = daysBetween(r.due_date, today);
      const i = late <= 0 ? 0 : late <= 30 ? 1 : late <= 60 ? 2 : late <= 90 ? 3 : 4;
      const b = by.get(r.name) ?? [0, 0, 0, 0, 0];
      b[i] = r2(b[i]! + num(r.due));
      by.set(r.name, b);
    }
    const data = [...by.entries()].map(([name, b]) => [name, ...b, r2(b.reduce((s, x) => s + x, 0))]).sort((a, b) => num(b[6]) - num(a[6]));
    const total = r2(data.reduce((s, r) => s + num(r[6]), 0));
    const overdue = r2(data.reduce((s, r) => s + num(r[2]) + num(r[3]) + num(r[4]) + num(r[5]), 0));
    return out(['Customer', 'Not due', '1-30 days', '31-60 days', '61-90 days', 'Over 90 days', 'Total'], data,
      [['Receivable', inr(total)], ['Overdue', inr(overdue)]]);
  }
  if (report === 'stock_valuation') {
    const rows = (await sql<any>`select i.name, i.sku, sum(m.qty) as qty, sum(m.value) as value from stock_moves m join items i on i.id = m.item_id
      where m.company_id = ${ctx.companyId} ${loc('m.location_id')} group by i.id, i.name, i.sku order by i.name`.execute(tx)).rows
      .filter((r) => num(r.qty) !== 0 || num(r.value) !== 0);
    const total = r2(rows.reduce((s, r) => s + num(r.value), 0));
    return out(['Item', 'SKU', 'Quantity', 'Value'], rows.map((r) => [r.name, r.sku ?? '', num(r.qty), r2(num(r.value))]),
      [['Items in stock', String(rows.length)], ['Stock value', inr(total)]]);
  }
  if (report === 'gst_summary') {
    const rows = (await sql<any>`select l.gst_rate, sum(l.taxable_value) as taxable, sum(l.cgst) as cgst, sum(l.sgst) as sgst, sum(l.igst) as igst
      from invoice_lines l join invoices v on v.id = l.invoice_id where v.company_id = ${ctx.companyId} and v.status = 'posted'
      and v.invoice_date >= ${from} and v.invoice_date <= ${to} ${loc('v.location_id')} group by l.gst_rate order by l.gst_rate`.execute(tx)).rows;
    const tax = r2(rows.reduce((s, r) => s + num(r.cgst) + num(r.sgst) + num(r.igst), 0));
    const taxable = r2(rows.reduce((s, r) => s + num(r.taxable), 0));
    return out(['GST rate', 'Taxable', 'CGST', 'SGST', 'IGST'], rows.map((r) => [num(r.gst_rate), num(r.taxable), num(r.cgst), num(r.sgst), num(r.igst)]),
      [['Taxable sales', inr(taxable)], ['Output tax', inr(tax)]]);
  }
  // crm_numbers
  const fromTs = `${from}T00:00:00+05:30`;
  const toTs = `${addDays(to, 1)}T00:00:00+05:30`;
  const own = ctx.can('crm.all') ? sql`` : sql`and owner_id = ${ctx.userId}`;
  const g = (await sql<any>`select
    (select count(*) from crm_leads where company_id = ${ctx.companyId} and created_at >= ${fromTs} and created_at < ${toTs} ${own}) as new_leads,
    (select count(*) from crm_leads where company_id = ${ctx.companyId} and status = 'converted' and converted_at >= ${fromTs} and converted_at < ${toTs} ${own}) as converted,
    (select count(*) from crm_deals where company_id = ${ctx.companyId} and status = 'open' ${own}) as open_n,
    (select coalesce(sum(value),0) from crm_deals where company_id = ${ctx.companyId} and status = 'open' ${own}) as open_v,
    (select count(*) from crm_deals where company_id = ${ctx.companyId} and status = 'won' and won_at >= ${fromTs} and won_at < ${toTs} ${own}) as won_n,
    (select coalesce(sum(value),0) from crm_deals where company_id = ${ctx.companyId} and status = 'won' and won_at >= ${fromTs} and won_at < ${toTs} ${own}) as won_v,
    (select count(*) from crm_deals where company_id = ${ctx.companyId} and status = 'lost' and lost_at >= ${fromTs} and lost_at < ${toTs} ${own}) as lost_n`.execute(tx)).rows[0];
  const data: unknown[][] = [['New leads', num(g.new_leads)], ['Leads converted', num(g.converted)], ['Open deals', num(g.open_n)],
    ['Open deal value', num(g.open_v)], ['Deals won', num(g.won_n)], ['Won value', num(g.won_v)], ['Deals lost', num(g.lost_n)]];
  return out(['Measure', 'Value'], data, [['New leads', String(num(g.new_leads))], ['Deals won', `${num(g.won_n)} (${inr(num(g.won_v))})`], ['Open deal value', inr(num(g.open_v))]]);
}

const h = (s: string) => s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c]!);

export function reportHtml(b: Built, company: string): string {
  const cell = (v: unknown) => `<td style="padding:4px 8px;border-bottom:1px solid #e1e4e8;${typeof v === 'number' ? 'text-align:right' : ''}">${h(String(v))}</td>`;
  const body = b.rows.slice(0, 25).map((r) => `<tr>${r.map(cell).join('')}</tr>`).join('');
  return `<div style="font-family:Arial,sans-serif;color:#1a2124;font-size:14px"><h2 style="margin:0 0 4px">${h(b.title)}</h2>`
    + `<p style="margin:0 0 12px;color:#586069">${h(company)}, ${h(b.period)}</p>`
    + `<table style="margin-bottom:12px">${b.summary.map(([k, v]) => `<tr><td style="padding:2px 12px 2px 0">${h(k)}</td><td><b>${h(v)}</b></td></tr>`).join('')}</table>`
    + `<table style="border-collapse:collapse"><tr>${b.header.map((x) => `<th style="text-align:left;padding:4px 8px;border-bottom:2px solid #0b6157">${h(x)}</th>`).join('')}</tr>${body}</table>`
    + `${b.rows.length > 25 ? `<p style="color:#586069">First 25 of ${b.rows.length} rows. The CSV file has all of them.</p>` : ''}</div>`;
}

export const summaryText = (b: Built) => b.summary.map(([k, v]) => `${k}: ${v}`).join('\n');

// Schedule ---------------------------------------------------------------------------------------------------

export interface Schedule { frequency: string; weekday: number | null; monthDay: number | null; time: string }

/** The first due time strictly after `after`, using India time (UTC+5:30, no daylight saving). */
export function nextRunAfter(s: Schedule, after: Date): Date {
  const [hh, mm] = s.time.split(':').map(Number);
  const IST = 5.5 * 3600_000;
  const base = new Date(after.getTime() + IST);
  for (let i = 0; i <= 62; i++) {
    const d = new Date(Date.UTC(base.getUTCFullYear(), base.getUTCMonth(), base.getUTCDate() + i, hh, mm));
    const ok = s.frequency === 'daily' || (s.frequency === 'weekly' && d.getUTCDay() === s.weekday)
      || (s.frequency === 'monthly' && d.getUTCDate() === s.monthDay);
    const at = new Date(d.getTime() - IST);
    if (ok && at.getTime() > after.getTime()) return at;
  }
  throw new Error('No next run');
}
