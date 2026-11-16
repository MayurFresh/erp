// Database readers shared by payroll runs and the statutory module.
import type { Tx } from '../../db/database.ts';
import type { RateRow } from './rates.ts';
import { wageRuleActive } from './statutory.ts';

export interface StatSettings {
  wagesRuleEnabled: boolean; wagesRuleFrom: string; wagesRulePercent: number; minimumWage: number;
  bonusPct: number; bonusEligibilityCeiling: number; bonusCalcCeiling: number; bonusMinDays: number;
  gratuityYears: number; gratuityFixedTermYears: number; gratuityCap: number; leaveExemptCap: number;
  otMultiplier: number; hoursPerDay: number;
}
export const STAT_DEFAULTS: StatSettings = {
  wagesRuleEnabled: false, wagesRuleFrom: '2025-11-21', wagesRulePercent: 50, minimumWage: 0,
  bonusPct: 8.33, bonusEligibilityCeiling: 21000, bonusCalcCeiling: 7000, bonusMinDays: 30,
  gratuityYears: 5, gratuityFixedTermYears: 1, gratuityCap: 2000000, leaveExemptCap: 2500000, otMultiplier: 2, hoursPerDay: 8,
};

export async function loadStatSettings(tx: Tx, companyId: string): Promise<StatSettings> {
  const r = await tx.selectFrom('payroll_statutory_settings').selectAll().where('company_id', '=', companyId).executeTakeFirst();
  if (!r) return { ...STAT_DEFAULTS };
  return {
    wagesRuleEnabled: r.wages_rule_enabled, wagesRuleFrom: r.wages_rule_from, wagesRulePercent: r.wages_rule_percent, minimumWage: r.minimum_wage,
    bonusPct: r.bonus_pct, bonusEligibilityCeiling: r.bonus_eligibility_ceiling, bonusCalcCeiling: r.bonus_calc_ceiling, bonusMinDays: r.bonus_min_days,
    gratuityYears: r.gratuity_years, gratuityFixedTermYears: r.gratuity_fixed_term_years, gratuityCap: r.gratuity_cap, leaveExemptCap: r.leave_exempt_cap,
    otMultiplier: r.ot_multiplier, hoursPerDay: r.hours_per_day,
  };
}
export const wageRuleFor = (s: StatSettings, date: string) => ({ active: wageRuleActive({ enabled: s.wagesRuleEnabled, from: s.wagesRuleFrom }, date), percent: s.wagesRulePercent });

export async function companyRateRows(tx: Tx, companyId: string): Promise<RateRow[]> {
  const rows = await tx.selectFrom('payroll_rate_rows').selectAll().where('company_id', '=', companyId).orderBy('effective_from').execute();
  return rows.map((r) => ({ id: r.id, kind: r.kind as RateRow['kind'], stateCode: r.state_code, effectiveFrom: r.effective_from, config: r.config as Record<string, unknown>, note: r.note, source: 'company' as const }));
}

/** component id -> basic flag, for working out wages from a salary structure. */
export async function basicFlags(tx: Tx, companyId: string): Promise<Map<string, boolean>> {
  const rows = await tx.selectFrom('salary_components').select(['id', 'is_basic']).where('company_id', '=', companyId).execute();
  return new Map(rows.map((r) => [r.id, r.is_basic]));
}

/** Overtime hours per employee for a month. */
export async function overtimeHours(tx: Tx, companyId: string, monthStart: string): Promise<Map<string, number>> {
  const end = `${monthStart.slice(0, 8)}${String(new Date(Date.UTC(Number(monthStart.slice(0, 4)), Number(monthStart.slice(5, 7)), 0)).getUTCDate()).padStart(2, '0')}`;
  const rows = await tx.selectFrom('shift_logs').select(['employee_id', 'ot_hours']).where('company_id', '=', companyId).where('day', '>=', monthStart).where('day', '<=', end).where('ot_hours', '>', 0).execute();
  const m = new Map<string, number>();
  for (const r of rows) m.set(r.employee_id, Math.round(((m.get(r.employee_id) ?? 0) + r.ot_hours) * 100) / 100);
  return m;
}
