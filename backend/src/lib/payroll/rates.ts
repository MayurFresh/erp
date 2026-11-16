// Dated statutory rates. Built-in rows live here; a company adds its own rows (payroll_rate_rows) from the settings screen.
// For a pay month the row with the latest effective_from on or before the first of the month is in force.
// NEEDS A CA CHECK: see the "source" notes below before real filing.
import { ESI_EMPLOYEE_BPS, ESI_EMPLOYER_BPS, ESI_DAILY_EXEMPT } from './esi.ts';
import { ADMIN_BPS, ADMIN_MINIMUM, EDLI_BPS, EPS_BPS, PF_CEILINGS } from './epf.ts';
import { LWF_RULES, PT_RULES, type PtRule } from './pt.ts';
import { ESI_CEILINGS } from './esi.ts';

export type RateKind = 'epf' | 'esi' | 'pt' | 'lwf';
export interface EpfRate { ceiling: number; epsCeiling: number; epsBps: number; edliBps: number; adminBps: number; adminMin: number }
export interface EsiRate { ceiling: number; employeeBps: number; employerBps: number; dailyExempt: number }
export interface PtRate { periodicity: 'monthly' | 'half_yearly'; deductMonths?: number[]; monthOverride?: PtRule['monthOverride']; slabs: PtRule['slabs'] }
export interface LwfRate { employee: number; employer: number; months: number[] }
export interface RateRow { id?: string | null; kind: RateKind; stateCode: string | null; effectiveFrom: string; config: Record<string, unknown>; note?: string | null; source: 'built_in' | 'company' }

const BEGIN = '2000-01-01';

export const BUILT_IN_RATES: RateRow[] = [
  // EPF wage ceiling 15,000 until 16 Sep 2026, 25,000 from 17 Sep 2026 (S.O. 5109(E), reported by secondary sources; Gazette text not read).
  ...PF_CEILINGS.map((c): RateRow => ({
    kind: 'epf', stateCode: null, effectiveFrom: c.from === '2000-01-01' ? BEGIN : c.from, source: 'built_in',
    config: { ceiling: c.ceiling, epsCeiling: c.ceiling, epsBps: EPS_BPS, edliBps: EDLI_BPS, adminBps: ADMIN_BPS, adminMin: ADMIN_MINIMUM },
    note: c.ceiling === 25000 ? 'S.O. 5109(E) dated 17 Sep 2026, from secondary sources' : 'Long-standing ceiling',
  })),
  ...ESI_CEILINGS.map((c): RateRow => ({
    kind: 'esi', stateCode: null, effectiveFrom: BEGIN, source: 'built_in',
    config: { ceiling: c.ceiling, employeeBps: ESI_EMPLOYEE_BPS, employerBps: ESI_EMPLOYER_BPS, dailyExempt: ESI_DAILY_EXEMPT },
    note: 'ESI ceiling stays 21,000',
  })),
  ...PT_RULES.map((r): RateRow => ({
    kind: 'pt', stateCode: r.stateCode, effectiveFrom: BEGIN, source: 'built_in',
    config: { periodicity: r.periodicity, deductMonths: r.deductMonths, monthOverride: r.monthOverride, slabs: r.slabs }, note: r.note || 'Unverified against the state notification',
  })),
  ...LWF_RULES.map((r): RateRow => ({
    kind: 'lwf', stateCode: r.stateCode, effectiveFrom: BEGIN, source: 'built_in',
    config: { employee: r.employee, employer: r.employer, months: r.months }, note: 'Unverified against the state notification',
  })),
];

/** The row in force for a month, or null. Company rows win over built-in rows with the same date. */
export function rateRowFor(rows: RateRow[], kind: RateKind, monthStart: string, stateCode?: string | null): RateRow | null {
  const pool = rows.filter((r) => r.kind === kind && r.effectiveFrom <= monthStart && (kind === 'epf' || kind === 'esi' || r.stateCode === (stateCode ?? null)));
  if (!pool.length) return null;
  return pool.map((r, i) => ({ r, i })).sort((a, b) => (a.r.effectiveFrom === b.r.effectiveFrom ? (a.r.source === b.r.source ? a.i - b.i : a.r.source === 'built_in' ? -1 : 1) : a.r.effectiveFrom < b.r.effectiveFrom ? -1 : 1)).at(-1)!.r;
}

export interface RatesInForce { epf: EpfRate; esi: EsiRate; pt: PtRate | null; lwf: LwfRate | null }
export function ratesInForce(company: RateRow[], monthStart: string, stateCode: string | null): RatesInForce {
  const all = [...BUILT_IN_RATES, ...company];
  const get = <T>(k: RateKind, st?: string | null) => (rateRowFor(all, k, monthStart, st)?.config ?? null) as T | null;
  return {
    epf: get<EpfRate>('epf')!, esi: get<EsiRate>('esi')!, pt: get<PtRate>('pt', stateCode), lwf: get<LwfRate>('lwf', stateCode),
  };
}

/** A PT table as the rule shape computePt reads. */
export const ptRuleOf = (stateCode: string, rate: PtRate): PtRule => ({
  stateCode, state: PT_RULES.find((r) => r.stateCode === stateCode)?.state ?? `State ${stateCode}`, periodicity: rate.periodicity,
  deductMonths: rate.deductMonths, monthOverride: rate.monthOverride, slabs: rate.slabs, note: '', verified: false,
});
