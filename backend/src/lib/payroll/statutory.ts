// Gratuity, statutory bonus, leave encashment, overtime, notice pay and full-and-final adjustments, as pure functions.
// NEEDS A CA CHECK. Sources and confirmation status are listed in docs/API.md "Statutory payroll".
import type { AdjustmentInput } from './compute.ts';
import { round2, roundRupee } from './money.ts';

// Labour Codes wages -------------------------------------------------------------------------------

export interface WageLine { code: string; amount: number; isBasic: boolean }
/**
 * Monthly wages for gratuity, leave encashment and overtime: basic plus DA. When the Code on Wages rule is active the
 * wages are at least `percent` of total remuneration (anything excluded above 50% is added back).
 */
export function monthlyWages(lines: WageLine[], rule: { active: boolean; percent: number }): { base: number; remuneration: number; wages: number; addback: number } {
  const remuneration = round2(lines.reduce((s, l) => s + l.amount, 0));
  const base = round2(lines.filter((l) => l.isBasic || l.code === 'DA').reduce((s, l) => s + l.amount, 0));
  const floor = rule.active ? round2((remuneration * rule.percent) / 100) : 0;
  const wages = Math.max(base, floor);
  return { base, remuneration, wages, addback: round2(wages - base) };
}
/** Is the Labour Code wages rule in force for a date? */
export const wageRuleActive = (s: { enabled: boolean; from: string } | null | undefined, date: string): boolean => !!s?.enabled && s.from <= date;

// Gratuity -------------------------------------------------------------------------------------------

const addYears = (iso: string, n: number): string => {
  const d = new Date(`${iso}T00:00:00Z`); d.setUTCFullYear(d.getUTCFullYear() + n); return d.toISOString().slice(0, 10);
};
const addMonths = (iso: string, n: number): string => {
  const d = new Date(`${iso}T00:00:00Z`); const day = d.getUTCDate(); d.setUTCDate(1); d.setUTCMonth(d.getUTCMonth() + n);
  const last = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate(); d.setUTCDate(Math.min(day, last));
  return d.toISOString().slice(0, 10);
};
/** Completed years of service, and the years counted for the formula: a part year of more than six months counts as a year. */
export function serviceYears(joining: string, asOf: string): { completed: number; counted: number } {
  if (asOf < joining) return { completed: 0, counted: 0 };
  let y = 0;
  while (addYears(joining, y + 1) <= asOf) y += 1;
  const sixMonths = addMonths(addYears(joining, y), 6);
  return { completed: y, counted: asOf > sixMonths ? y + 1 : y };
}
export interface GratuityRules { years: number; fixedTermYears: number; cap: number }
export function gratuityEligible(completedYears: number, fixedTerm: boolean, r: Pick<GratuityRules, 'years' | 'fixedTermYears'>): boolean {
  return completedYears >= (fixedTerm ? r.fixedTermYears : r.years);
}
/** 15/26 x last drawn wages x counted years, to the rupee. */
export const gratuityFormula = (wages: number, countedYears: number): number => roundRupee((wages * 15 * countedYears) / 26);
/** Amount up to the cap is tax free; the rest is taxable salary. */
export function gratuitySplit(amount: number, cap: number): { taxFree: number; taxable: number } {
  const taxFree = Math.min(amount, cap);
  return { taxFree, taxable: round2(amount - taxFree) };
}
export interface GratuityFigures { completedYears: number; countedYears: number; eligible: boolean; accrued: number; payable: number; taxFree: number; taxable: number }
export function gratuityFigures(i: { joining: string; asOf: string; wages: number; fixedTerm: boolean; rules: GratuityRules }): GratuityFigures {
  const { completed, counted } = serviceYears(i.joining, i.asOf);
  const eligible = gratuityEligible(completed, i.fixedTerm, i.rules);
  const accrued = gratuityFormula(i.wages, counted);
  const payable = eligible ? accrued : 0;
  return { completedYears: completed, countedYears: counted, eligible, accrued, payable, ...gratuitySplit(payable, i.rules.cap) };
}

// Statutory bonus ------------------------------------------------------------------------------------

export interface BonusRules { pct: number; eligibilityCeiling: number; calcCeiling: number; minimumWage: number; minDays: number }
export const BONUS_MIN_PCT = 8.33, BONUS_MAX_PCT = 20;
export function bonusFor(i: { monthlyWage: number; monthsPaid: number; daysWorked: number; rules: BonusRules }): { eligible: boolean; reason: string | null; calcWage: number; amount: number } {
  const r = i.rules;
  const calcWage = Math.min(i.monthlyWage, Math.max(r.calcCeiling, r.minimumWage));
  if (i.monthlyWage > r.eligibilityCeiling) return { eligible: false, reason: 'Wage is above the eligibility ceiling', calcWage, amount: 0 };
  if (i.daysWorked < r.minDays) return { eligible: false, reason: `Worked fewer than ${r.minDays} days`, calcWage, amount: 0 };
  return { eligible: true, reason: null, calcWage, amount: roundRupee((calcWage * i.monthsPaid * r.pct) / 100) };
}

// Leave encashment -----------------------------------------------------------------------------------

export const ENCASHMENT_DIVISOR = 30;
export function encashment(i: { balance: number; maxDays: number; wages: number }): { days: number; rate: number; amount: number } {
  const days = Math.max(0, Math.min(i.balance, i.maxDays));
  const rate = round2(i.wages / ENCASHMENT_DIVISOR);
  return { days, rate, amount: roundRupee((i.wages * days) / ENCASHMENT_DIVISOR) };
}

// Overtime -------------------------------------------------------------------------------------------

/** Hourly rate = wages / days in the pay month / hours per day. Overtime pays the rate times the multiplier (2 by default). */
export function overtimePay(i: { wages: number; divisorDays: number; hoursPerDay: number; hours: number; multiplier: number }): number {
  if (i.hours <= 0) return 0;
  return roundRupee((i.wages / i.divisorDays / i.hoursPerDay) * i.hours * i.multiplier);
}

// Notice period --------------------------------------------------------------------------------------

export function noticeAmount(i: { required: number; served: number; mode: 'none' | 'recover' | 'payout'; monthlyGross: number }): { shortDays: number; amount: number } {
  const shortDays = Math.max(0, i.required - i.served);
  if (i.mode === 'none' || shortDays === 0) return { shortDays, amount: 0 };
  return { shortDays, amount: roundRupee((i.monthlyGross * shortDays) / 30) };
}

// Full and final adjustments --------------------------------------------------------------------------

export interface FnfLine { kind: 'earning' | 'deduction'; label: string; amount: number; taxable: boolean }
export interface FnfParts {
  gratuity: { payable: number; cap: number };
  leave: { amount: number; exempt: boolean; cap: number };
  bonus: number;
  notice: { mode: 'none' | 'recover' | 'payout'; amount: number };
  extra: FnfLine[];
}
/** The one-time lines that go into the exit month's pay: only the taxable part feeds TDS. */
export function fnfLines(p: FnfParts): FnfLine[] {
  const out: FnfLine[] = [];
  if (p.gratuity.payable > 0) {
    const g = gratuitySplit(p.gratuity.payable, p.gratuity.cap);
    if (g.taxFree > 0) out.push({ kind: 'earning', label: 'Gratuity', amount: g.taxFree, taxable: false });
    if (g.taxable > 0) out.push({ kind: 'earning', label: 'Gratuity above the tax-free limit', amount: g.taxable, taxable: true });
  }
  if (p.leave.amount > 0) {
    const free = p.leave.exempt ? Math.min(p.leave.amount, p.leave.cap) : 0;
    if (free > 0) out.push({ kind: 'earning', label: 'Leave encashment', amount: free, taxable: false });
    if (p.leave.amount - free > 0) out.push({ kind: 'earning', label: free > 0 ? 'Leave encashment above the tax-free limit' : 'Leave encashment', amount: round2(p.leave.amount - free), taxable: true });
  }
  if (p.bonus > 0) out.push({ kind: 'earning', label: 'Statutory bonus (pro rata)', amount: p.bonus, taxable: true });
  if (p.notice.amount > 0) {
    out.push(p.notice.mode === 'payout'
      ? { kind: 'earning', label: 'Pay in lieu of notice', amount: p.notice.amount, taxable: true }
      : { kind: 'deduction', label: 'Notice period shortfall recovery', amount: p.notice.amount, taxable: false });
  }
  for (const x of p.extra) if (x.amount > 0) out.push(x);
  return out;
}
export const toAdjustments = (lines: FnfLine[]): AdjustmentInput[] => lines.map((l) => ({ kind: l.kind, label: l.label, amount: l.amount, taxable: l.taxable }));
