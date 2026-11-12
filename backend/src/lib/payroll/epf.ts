// Provident fund (EPF, EPS, EDLI). NEEDS A CA CHECK: verify current rates and ceilings before real filing.
// Source: docs/research/payroll-hr.md section 2. Rates and the ceiling are UNVERIFIED against EPFO circulars.
import { roundRupee } from './money.ts';

/** Wage ceiling by date. Effective-dated so an old month still uses the ceiling in force then. */
export const PF_CEILINGS: { from: string; ceiling: number }[] = [
  { from: '2000-01-01', ceiling: 15000 },
  { from: '2026-09-17', ceiling: 25000 },
];
/** The ceiling for a payroll month, chosen by the first day of the month (a split month is not pro-rated here). */
export function pfCeiling(monthStart: string): number {
  return [...PF_CEILINGS].reverse().find((c) => c.from <= monthStart)!.ceiling;
}

/** Basis points: 1200 = 12%. */
export const EPS_BPS = 833;
export const EDLI_BPS = 50;
export const ADMIN_BPS = 50;
export const ADMIN_MINIMUM = 500;

export interface EpfInput {
  /** Earned wages that count for PF this month (after pro-rata). */
  pfWage: number;
  ceiling: number;
  /** The employee and employer agreed to contribute on the full wage, not the ceiling. */
  optHigher?: boolean;
  /** 12 normally; 10 for notified establishments. */
  ratePct?: number;
  /** A new joiner above the ceiling has no pension (EPS) share. */
  epsEligible?: boolean;
}
export interface EpfResult {
  epfWage: number; epsWage: number;
  employee: number; eps: number; epfEmployer: number; employerTotal: number; edli: number; admin: number;
}

export function computeEpf(i: EpfInput): EpfResult {
  const pct = Math.round((i.ratePct ?? 12) * 100);
  const wage = i.optHigher ? i.pfWage : Math.min(i.pfWage, i.ceiling);
  const epsWage = Math.min(i.pfWage, i.ceiling);
  const employee = roundRupee((wage * pct) / 10000);
  const employerTotal = roundRupee((wage * pct) / 10000);
  const eps = i.epsEligible === false ? 0 : Math.min(employerTotal, roundRupee((epsWage * EPS_BPS) / 10000));
  return {
    epfWage: wage, epsWage, employee, eps, epfEmployer: employerTotal - eps, employerTotal,
    edli: roundRupee((epsWage * EDLI_BPS) / 10000), admin: roundRupee((wage * ADMIN_BPS) / 10000),
  };
}

/** Admin charge for the whole establishment: 0.5% of PF wages, at least 500 when anyone contributed. */
export const establishmentAdmin = (lineAdminTotal: number, contributors: number): number =>
  contributors > 0 ? Math.max(ADMIN_MINIMUM, roundRupee(lineAdminTotal)) : 0;
