// Form names by period, TDS interest and fee figures, PAN checks and the Form 16 Part B computation.
// Everything about the Income-tax Act 2025 (forms, section numbers, interest and fee sections) is UNCONFIRMED:
// the official text was not reachable when this was written. Names come from several secondary reports of the
// Income-tax Rules 2026. Rates of interest and fee are carried over from the 1961 Act.

import { individualTax, individualTaxable, regimeConfig, type Regime } from './income-tax.ts';

/** First day the Income-tax Act 2025 and Rules 2026 apply. */
export const NEW_ACT_FROM = '2026-04-01';

export interface FormNames {
  act: '1961' | '2025';
  salaryReturn: string; nonSalaryReturn: string; nonResidentReturn: string; tcsReturn: string;
  salaryCertificate: string; nonSalaryCertificate: string; annualStatement: string;
  periodWord: 'Assessment year' | 'Tax year';
  unconfirmed: boolean;
}

const OLD_NAMES: FormNames = {
  act: '1961', salaryReturn: '24Q', nonSalaryReturn: '26Q', nonResidentReturn: '27Q', tcsReturn: '27EQ',
  salaryCertificate: 'Form 16', nonSalaryCertificate: 'Form 16A', annualStatement: 'Form 26AS', periodWord: 'Assessment year', unconfirmed: false,
};
const NEW_NAMES: FormNames = {
  act: '2025', salaryReturn: '138', nonSalaryReturn: '140', nonResidentReturn: '144', tcsReturn: '143',
  salaryCertificate: 'Form 130', nonSalaryCertificate: 'Form 131', annualStatement: 'Form 168', periodWord: 'Tax year', unconfirmed: true,
};

/** Form names for a date. */
export const formNamesOn = (date: string): FormNames => (date >= NEW_ACT_FROM ? NEW_NAMES : OLD_NAMES);
/** Form names for a financial year such as '2026-27' (by its first day). */
export const formNamesFor = (fy: string): FormNames => formNamesOn(`${fy.slice(0, 4)}-04-01`);

/** 'Tax year 2026-27' for the new Act, 'Assessment year 2026-27' (the year after) for the old one. */
export function periodLabel(fy: string): string {
  const n = formNamesFor(fy);
  if (n.act === '2025') return `Tax year ${fy}`;
  const y = Number(fy.slice(0, 4)) + 1;
  return `Assessment year ${y}-${String((y + 1) % 100).padStart(2, '0')}`;
}

export const PAN_RE = /^[A-Z]{5}[0-9]{4}[A-Z]$/;
/** Format only (5 letters, 4 digits, 1 letter), the same check as the database. */
export const panValid = (pan: string | null | undefined): boolean => !!pan && PAN_RE.test(pan);

const round2 = (n: number) => Math.round(n * 100) / 100;

/** Whole months, a part month counted as a month, from `from` to `to`. 0 when `to` is not after `from`. */
export function monthsOrPart(from: string, to: string): number {
  if (to <= from) return 0;
  const m = (Number(to.slice(0, 4)) - Number(from.slice(0, 4))) * 12 + Number(to.slice(5, 7)) - Number(from.slice(5, 7));
  return Math.max(1, to.slice(8, 10) > from.slice(8, 10) ? m + 1 : m);
}

export interface InterestRule { lateDeductionPct: number; lateDepositPct: number; lateFeePerDay: number; verified: boolean; label: string }
export const TDS_INTEREST: InterestRule = {
  lateDeductionPct: 1, lateDepositPct: 1.5, lateFeePerDay: 200, verified: false,
  label: 'Late deduction 1% a month, late deposit 1.5% a month (both per month or part), late statement fee Rs 200 a day up to the TDS. 1961 Act ss.201(1A) and 234E; section numbers under the 2025 Act not confirmed.',
};

/** Interest for a late deduction: tax not deducted by the date it was due, deducted on `deductedOn`. */
export const lateDeductionInterest = (tax: number, dueOn: string, deductedOn: string) =>
  round2((tax * TDS_INTEREST.lateDeductionPct * monthsOrPart(dueOn, deductedOn)) / 100);

/** Interest for a late deposit: counted from the deduction date; nothing when deposited by the due date. */
export function lateDepositInterest(tax: number, deductedOn: string, dueOn: string, depositedOn: string) {
  if (depositedOn <= dueOn) return { months: 0, interest: 0 };
  const months = monthsOrPart(deductedOn, depositedOn);
  return { months, interest: round2((tax * TDS_INTEREST.lateDepositPct * months) / 100) };
}

/** Late statement fee: per day, never more than the tax in the statement. */
export const lateFilingFee = (daysLate: number, tds: number) => round2(Math.min(Math.max(0, daysLate) * TDS_INTEREST.lateFeePerDay, tds));

export interface PartBInput {
  fy: string; regime: Regime;
  grossSalary: number; taxableSalary: number; previousIncome: number; previousTds: number;
  employeePf: number; professionalTax: number; tdsThisEmployer: number;
}
export interface PartB {
  regime: Regime; grossSalary: number; nonTaxableAllowances: number; salaryThisEmployer: number; previousEmployerIncome: number;
  totalSalary: number; exemptions: number; standardDeduction: number; professionalTax: number; incomeFromSalary: number;
  chapterVIA: { label: string; amount: number }[]; totalIncome: number;
  slabs: { from: number; to: number | null; rate: number; tax: number }[];
  taxOnIncome: number; rebate: number; surcharge: number; cess: number; marginalRelief: number; relief89: number;
  netTaxPayable: number; tdsThisEmployer: number; tdsPreviousEmployer: number; tdsTotal: number; balance: number; unverified: string[];
}

/** Form 16 Part B / Form 130 tax computation. Matches the payroll TDS method: only PF (80C) and professional tax are deducted, and only in the old regime. */
export function partB(i: PartBInput): PartB {
  const cfg = regimeConfig(i.regime, i.fy);
  const totalSalary = round2(i.taxableSalary + i.previousIncome);
  const old = i.regime === 'old';
  const standard = Math.min(totalSalary, cfg.salaryStandardDeduction);
  const pt = old ? i.professionalTax : 0;
  const s80c = old ? Math.min(i.employeePf, cfg.caps?.s80c ?? 0) : 0;
  const taxable = individualTaxable(cfg, 'below60', {
    salary: totalSalary, business: 0, otherIncome: 0, deductions: old ? { s80c: i.employeePf, other: i.professionalTax } : undefined,
  });
  const calc = individualTax(cfg, 'below60', taxable);
  let total = calc.calc.total;
  let marginalRelief = 0;
  const over = taxable - cfg.rebate.limit;
  if (over > 0 && taxable <= 5_000_000 && calc.calc.baseTax > over) {
    const capped = round2(over * (1 + cfg.cessPct / 100));
    marginalRelief = round2(total - capped);
    total = capped;
  }
  const net = Math.round(total / 10) * 10;
  const tdsTotal = round2(i.tdsThisEmployer + i.previousTds);
  return {
    regime: i.regime, grossSalary: i.grossSalary, nonTaxableAllowances: round2(i.grossSalary - i.taxableSalary),
    salaryThisEmployer: i.taxableSalary, previousEmployerIncome: i.previousIncome, totalSalary, exemptions: 0,
    standardDeduction: standard, professionalTax: pt, incomeFromSalary: round2(totalSalary - standard - pt),
    chapterVIA: s80c ? [{ label: 'Provident fund (80C or its 2025 Act equivalent)', amount: s80c }] : [], totalIncome: taxable,
    slabs: calc.calc.slabs, taxOnIncome: calc.calc.baseTax, rebate: calc.calc.rebate, surcharge: calc.calc.surcharge, cess: calc.calc.cess,
    marginalRelief, relief89: 0, netTaxPayable: net, tdsThisEmployer: i.tdsThisEmployer, tdsPreviousEmployer: i.previousTds,
    tdsTotal, balance: round2(net - tdsTotal), unverified: calc.unverified,
  };
}
