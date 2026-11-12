// Monthly TDS on salary, projected for the year. NEEDS A CA CHECK: verify current slabs and the s.392 method.
// Slabs, rebate, cess and the standard deduction come from lib/income-tax.ts; only the projection and marginal relief live here.
import { individualTax, individualTaxable, regimeConfig, type Regime } from '../income-tax.ts';
import { roundRupee } from './money.ts';

export interface TdsInput {
  regime: Regime;
  /** Tax year such as '2026-27'. */
  taxYear: string;
  /** Payroll month, 1-12. */
  month: number;
  /** Taxable salary of this employer already counted in earlier months of the year. */
  ytdTaxable: number;
  /** Taxable pay for this month. */
  thisMonthTaxable: number;
  /** The month's recurring taxable pay, used for the months still to come. */
  recurringTaxable: number;
  /** Salary and TDS from a previous employer in the same year. */
  previousIncome?: number;
  previousTds?: number;
  tdsDeductedSoFar: number;
  /** Months left in this employer's year including this one; fewer when the employee leaves. */
  monthsLeft?: number;
  /** Old regime only. */
  employeePfYear?: number;
  ptYear?: number;
}
export interface TdsResult {
  tds: number;
  working: {
    annualSalary: number; taxable: number; annualTax: number; deductedSoFar: number; previousTds: number;
    monthsLeft: number; regime: Regime; unverified: string[];
  };
}

/** Months from April: April is 0, March is 11. */
export const monthIndex = (month: number): number => (month - 4 + 12) % 12;

export function monthlyTds(i: TdsInput): TdsResult {
  const left = i.monthsLeft ?? 12 - monthIndex(i.month);
  const annualSalary = i.ytdTaxable + i.thisMonthTaxable + i.recurringTaxable * Math.max(0, left - 1) + (i.previousIncome ?? 0);
  const cfg = regimeConfig(i.regime, i.taxYear);
  const taxable = individualTaxable(cfg, 'below60', {
    salary: annualSalary, business: 0, otherIncome: 0,
    deductions: i.regime === 'old' ? { s80c: i.employeePfYear ?? 0, other: i.ptYear ?? 0 } : undefined,
  });
  const calc = individualTax(cfg, 'below60', taxable);
  let total = calc.calc.total;
  // Marginal relief just above the rebate limit: tax cannot exceed the income above the limit.
  const over = taxable - cfg.rebate.limit;
  if (over > 0 && taxable <= 5_000_000 && calc.calc.baseTax > over) total = Math.round(over * (1 + cfg.cessPct / 100) * 100) / 100;
  const annualTax = Math.round(total / 10) * 10;
  const remaining = annualTax - i.tdsDeductedSoFar - (i.previousTds ?? 0);
  const tds = Math.max(0, roundRupee(remaining / Math.max(1, left)));
  return {
    tds,
    working: {
      annualSalary: Math.round(annualSalary * 100) / 100, taxable, annualTax, deductedSoFar: i.tdsDeductedSoFar,
      previousTds: i.previousTds ?? 0, monthsLeft: left, regime: i.regime, unverified: calc.unverified,
    },
  };
}
