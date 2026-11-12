// Employees' State Insurance. NEEDS A CA CHECK: verify current rates and the wage ceiling before real filing.
// Source: docs/research/payroll-hr.md section 3. Ceiling 21,000, employee 0.75%, employer 3.25%, each rounded UP to the rupee.
import { ceilRupee } from './money.ts';

export const ESI_CEILINGS: { from: string; ceiling: number }[] = [{ from: '2000-01-01', ceiling: 21000 }];
export const esiCeiling = (monthStart: string): number => [...ESI_CEILINGS].reverse().find((c) => c.from <= monthStart)!.ceiling;

export const ESI_EMPLOYEE_BPS = 75;
export const ESI_EMPLOYER_BPS = 325;
/** An employee earning no more than this per day pays no employee share. */
export const ESI_DAILY_EXEMPT = 176;

/** Contribution periods run 1 Apr to 30 Sep and 1 Oct to 31 Mar. Returns the last day of the one holding `monthStart`. */
export function esiPeriodEnd(monthStart: string): string {
  const y = Number(monthStart.slice(0, 4)), m = Number(monthStart.slice(5, 7));
  if (m >= 4 && m <= 9) return `${y}-09-30`;
  return m >= 10 ? `${y + 1}-03-31` : `${y}-03-31`;
}

export interface EsiInput {
  /** Gross wages this month that count for ESI. */
  esiWage: number;
  monthStart: string;
  /** Saved on the employee: covered through this date from an earlier month. */
  coveredUntil: string | null;
  paidDays: number;
  ceiling?: number;
}
export interface EsiResult { covered: boolean; coveredUntil: string | null; employee: number; employer: number }

/**
 * Coverage is stateful: someone covered at the start of a period stays covered to its end even if wages rise above the ceiling.
 * A new period is covered only when the wage is within the ceiling.
 */
export function computeEsi(i: EsiInput): EsiResult {
  const ceiling = i.ceiling ?? esiCeiling(i.monthStart);
  const stillCovered = !!i.coveredUntil && i.coveredUntil >= i.monthStart && i.coveredUntil >= i.monthStart;
  const covered = stillCovered || (i.esiWage > 0 && i.esiWage <= ceiling);
  if (!covered) return { covered: false, coveredUntil: null, employee: 0, employer: 0 };
  const coveredUntil = stillCovered ? i.coveredUntil : esiPeriodEnd(i.monthStart);
  const daily = i.paidDays > 0 ? i.esiWage / i.paidDays : 0;
  return {
    covered: true, coveredUntil,
    employee: daily <= ESI_DAILY_EXEMPT ? 0 : ceilRupee((i.esiWage * ESI_EMPLOYEE_BPS) / 10000),
    employer: ceilRupee((i.esiWage * ESI_EMPLOYER_BPS) / 10000),
  };
}
