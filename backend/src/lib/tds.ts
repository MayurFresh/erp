// TDS calculation and deduction rows (API v1.4 §2). Rates and thresholds come from tds_sections, never from code.

import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear } from './dates.ts';
import { badRequest, conflict } from './errors.ts';

export type TdsReason = 'below_threshold' | 'single' | 'aggregate' | 'excess' | 'no_pan' | 'lower_rate';
export interface TdsCalc {
  sectionId: string; sectionCode: string; rate: number; gross: number; base: number; amount: number;
  fyGross: number; threshold: number | null; reason: TdsReason;
}
export interface TdsCalcInput { partyId: string; sectionId: string; date: string; gross: number; excludeSourceId?: string | null }

const paise = (n: number) => Math.round(n * 100);
const rupees = (p: number) => p / 100;

/** base × rate ÷ 100, rounded half-up to the paisa. */
export function tdsAmountOf(base: number, rate: number): number {
  const p = (BigInt(paise(base)) * BigInt(Math.round(rate * 100)) * 2n + 10_000n) / 20_000n;
  return Number(p) / 100;
}

/** The 4th PAN letter: P (individual) or H (HUF) use the individual rate. */
const isIndividualPan = (pan: string) => pan[3] === 'P' || pan[3] === 'H';

export async function loadSection(tx: Tx, sectionId: string, date: string) {
  const s = await tx.selectFrom('tds_sections').selectAll().where('id', '=', sectionId).executeTakeFirst();
  if (!s) throw badRequest('TDS section not found.', { tdsSectionId: 'Not found' });
  if (!s.is_active || s.effective_from > date || (s.effective_to && s.effective_to < date)) {
    throw badRequest(`TDS section ${s.code} is not in force on ${date}.`, { tdsSectionId: 'Not in force on this date' });
  }
  return s;
}

export async function calcTds(tx: Tx, companyId: string, i: TdsCalcInput): Promise<TdsCalc> {
  const party = await tx.selectFrom('parties').select(['id', 'pan']).where('id', '=', i.partyId).where('company_id', '=', companyId).executeTakeFirst();
  if (!party) throw badRequest('Party not found.', { partyId: 'Not found' });
  const s = await loadSection(tx, i.sectionId, i.date);
  const fy = financialYear(i.date);
  let pq = tx.selectFrom('tds_deductions').select(['gross', 'base'])
    .where('company_id', '=', companyId).where('party_id', '=', i.partyId).where('section_code', '=', s.code)
    .where('fy', '=', fy).where('status', '=', 'active');
  if (i.excludeSourceId) pq = pq.where('source_id', '<>', i.excludeSourceId);
  const prior = await pq.execute();
  const priorGross = prior.reduce((a, r) => a + paise(r.gross), 0);
  const priorBase = prior.reduce((a, r) => a + paise(r.base), 0);
  const gross = paise(i.gross);
  const fyGross = priorGross + gross;
  const undeducted = priorGross - priorBase;

  const noPan = !party.pan;
  const rate = noPan ? s.rate_no_pan : isIndividualPan(party.pan!) ? s.rate_individual : s.rate_other;
  const aggT = s.threshold_aggregate === null ? null : paise(s.threshold_aggregate);
  const singT = s.threshold_single === null ? null : paise(s.threshold_single);

  let base = 0;
  let reason: TdsReason = 'below_threshold';
  if (s.aggregate_mode === 'excess') {
    const t = aggT ?? 0;
    base = Math.max(0, fyGross - t) - Math.max(0, priorGross - t);
    reason = base > 0 ? 'excess' : 'below_threshold';
  } else if (aggT !== null && fyGross > aggT) {
    base = gross + undeducted;
    reason = 'aggregate';
  } else if (singT !== null && gross > singT) {
    base = gross;
    reason = 'single';
  }
  const amount = tdsAmountOf(rupees(base), rate);
  if (noPan && base > 0) reason = 'no_pan';
  return {
    sectionId: s.id, sectionCode: s.code, rate, gross: i.gross, base: rupees(base), amount, fyGross: rupees(fyGross),
    threshold: s.threshold_aggregate ?? s.threshold_single, reason,
  };
}

export interface DeductionInput {
  sourceType: 'purchase' | 'expense' | 'ra_bill'; sourceId: string; number: string; date: string; partyId: string;
  sectionId: string | null; sectionCode: string; gross: number; base: number; rate: number; amount: number;
}

/** Writes the tds_deductions row of a posted document (even with amount 0). */
export async function insertDeduction(tx: Tx, ctx: RequestContext, d: DeductionInput): Promise<void> {
  const party = await tx.selectFrom('parties').select('pan').where('id', '=', d.partyId).executeTakeFirst();
  await tx.insertInto('tds_deductions').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, source_type: d.sourceType, source_id: d.sourceId, number: d.number,
    party_id: d.partyId, pan: party?.pan ?? null, section_id: d.sectionId, section_code: d.sectionCode, fy: financialYear(d.date),
    deduction_date: d.date, gross: d.gross, base: d.base, rate: d.rate, amount: d.amount,
  }).execute();
}

/** Marks the document's deduction cancelled; 409 TDS_DEPOSITED when it is already in a challan. */
export async function cancelDeduction(tx: Tx, sourceType: string, sourceId: string): Promise<void> {
  const rows = await tx.selectFrom('tds_deductions').select(['id', 'challan_id'])
    .where('source_type', '=', sourceType).where('source_id', '=', sourceId).where('status', '=', 'active').execute();
  if (rows.some((r) => r.challan_id)) {
    throw conflict('The TDS on this document is already in a challan. Cancel the challan first.', 'TDS_DEPOSITED');
  }
  if (rows.length) {
    await tx.updateTable('tds_deductions').set({ status: 'cancelled' })
      .where('source_type', '=', sourceType).where('source_id', '=', sourceId).where('status', '=', 'active').execute();
  }
}
