// Statutory due dates (API v1.4 §5, §8) as data. Change a rule here, nowhere else.

import { addDays } from './dates.ts';

export const DUE_DAY = {
  tdsDeposit: 7, // of the next month
  tdsDepositMarch: { month: 4, day: 30 }, // March deductions: 30 April
  gstr1Monthly: 11,
  gstr1Quarterly: 13,
  gstr3bMonthly: 20,
  gstr3bQuarterly: 22, // 22nd or 24th by state: UNVERIFIED
} as const;

/** Form 140 (new Act TDS statement): quarter → [month offset from FY start year, month, day]. */
export const FORM_140_DUE: Record<1 | 2 | 3 | 4, { yearOffset: 0 | 1; month: number; day: number }> = {
  1: { yearOffset: 0, month: 7, day: 31 },
  2: { yearOffset: 0, month: 10, day: 31 },
  3: { yearOffset: 1, month: 1, day: 31 },
  4: { yearOffset: 1, month: 5, day: 31 },
};

const pad = (n: number) => String(n).padStart(2, '0');

/** Adds months to a YYYY-MM period string. */
export function addPeriodMonths(period: string, n: number): string {
  const idx = Number(period.slice(0, 4)) * 12 + (Number(period.slice(5, 7)) - 1) + n;
  return `${Math.floor(idx / 12)}-${pad((idx % 12) + 1)}`;
}

const dayOfNextMonth = (period: string, day: number) => `${addPeriodMonths(period, 1)}-${pad(day)}`;

/** TDS deposit due date for deductions made in `month` (YYYY-MM). */
export function tdsDepositDue(month: string): string {
  if (month.slice(5, 7) === '03') return `${month.slice(0, 4)}-${pad(DUE_DAY.tdsDepositMarch.month)}-${pad(DUE_DAY.tdsDepositMarch.day)}`;
  return dayOfNextMonth(month, DUE_DAY.tdsDeposit);
}

/** Form 140 filing date for quarter 1..4 of a financial year such as '2026-27'. */
export function form140Due(fy: string, quarter: 1 | 2 | 3 | 4): string {
  const r = FORM_140_DUE[quarter];
  return `${Number(fy.slice(0, 4)) + r.yearOffset}-${pad(r.month)}-${pad(r.day)}`;
}

/** Quarter (calendar) end month of a YYYY-MM period, as YYYY-MM. */
const quarterEnd = (period: string) => addPeriodMonths(period, (3 - (Number(period.slice(5, 7)) % 3)) % 3);

/** GSTR-1 due date for a return period; quarterly filers file after the calendar quarter. */
export function gstr1Due(period: string, filing: 'monthly' | 'quarterly'): string {
  return filing === 'quarterly' ? dayOfNextMonth(quarterEnd(period), DUE_DAY.gstr1Quarterly) : dayOfNextMonth(period, DUE_DAY.gstr1Monthly);
}

export function gstr3bDue(period: string, filing: 'monthly' | 'quarterly'): string {
  return filing === 'quarterly' ? dayOfNextMonth(quarterEnd(period), DUE_DAY.gstr3bQuarterly) : dayOfNextMonth(period, DUE_DAY.gstr3bMonthly);
}

/** FY label ('2026-27') to its twelve YYYY-MM months, April first. */
export function fyMonths(fy: string): string[] {
  const start = `${fy.slice(0, 4)}-04`;
  return Array.from({ length: 12 }, (_, i) => addPeriodMonths(start, i));
}

/** Date range of quarter 1..4 of a financial year. */
export function quarterRange(fy: string, quarter: number): { from: string; to: string } {
  const months = fyMonths(fy).slice((quarter - 1) * 3, quarter * 3);
  return { from: `${months[0]}-01`, to: monthEnd(months[2]!) };
}

/** Last day of a YYYY-MM month. */
export function monthEnd(period: string): string {
  return addDays(`${addPeriodMonths(period, 1)}-01`, -1);
}

/** Advance-tax instalments for a tax year such as '2026-27' (cumulative share of the year's tax). UNVERIFIED beyond 15%. */
export const ADVANCE_TAX_INSTALMENTS = [
  { month: 6, day: 15, cumulativePct: 15 },
  { month: 9, day: 15, cumulativePct: 45 },
  { month: 12, day: 15, cumulativePct: 75 },
  { month: 3, day: 15, cumulativePct: 100 },
] as const;

export function advanceTaxDates(taxYear: string, presumptive = false): { dueDate: string; cumulativePct: number }[] {
  const start = Number(taxYear.slice(0, 4));
  const rows = ADVANCE_TAX_INSTALMENTS.map((i) => ({
    dueDate: `${i.month < 4 ? start + 1 : start}-${pad(i.month)}-${pad(i.day)}`,
    cumulativePct: presumptive ? (i.month === 3 ? 100 : 0) : i.cumulativePct,
  }));
  return presumptive ? rows.filter((r) => r.cumulativePct === 100) : rows;
}

/** Return period used in the filing register for a monthly period: quarterly filers use the quarter's last month. */
export function gstReturnPeriod(period: string, filing: 'monthly' | 'quarterly'): string {
  return filing === 'quarterly' ? quarterEnd(period) : period;
}

/** PMT-06 (QRMP monthly challan) is due on the 25th of the next month. */
export const PMT06_DUE_DAY = 25;
export function pmt06Due(period: string): string {
  return dayOfNextMonth(period, PMT06_DUE_DAY);
}

/** GSTR-9 is due on 31 December after the financial year ends. */
export function gstr9Due(fy: string): string {
  return `${Number(fy.slice(0, 4)) + 1}-12-31`;
}

/** Financial year of a YYYY-MM period. */
export function fyOfPeriod(period: string): string {
  const y = Number(period.slice(0, 4));
  const start = Number(period.slice(5, 7)) >= 4 ? y : y - 1;
  return `${start}-${pad((start + 1) % 100)}`;
}

/** True for the months of a quarter that carry a PMT-06 (months 1 and 2). Quarters end in June, September, December and March. */
export const isPmt06Month = (period: string) => Number(period.slice(5, 7)) % 3 !== 0;

/** GST returns can be filed up to three years after the due date. */
export const GST_TIME_BAR_YEARS = 3;
export function addYearsToDate(date: string, years: number): string {
  return `${Number(date.slice(0, 4)) + years}${date.slice(4)}`;
}
