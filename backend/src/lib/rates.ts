// GST rate master (API v1.4 §1): a rate is valid for a line when a gst_rates row (system or the tenant's,
// RLS shows both) has that rate, covers the date and has kind 'any' or the line's kind.

import type { Tx } from '../db/database.ts';
import { badRequest } from './errors.ts';

export type RateKind = 'goods' | 'services';

/** SAC codes (services) start with 99; everything else is goods. */
export const rateKind = (hsn: string | null | undefined): RateKind => (hsn?.trim().startsWith('99') ? 'services' : 'goods');

/** Rates valid on `date`. With `kind` null, rows of any kind count (expenses). */
export async function validRates(tx: Tx, date: string, kind: RateKind | null): Promise<Set<number>> {
  let q = tx.selectFrom('gst_rates').select('rate')
    .where('effective_from', '<=', date)
    .where((eb) => eb.or([eb('effective_to', 'is', null), eb('effective_to', '>=', date)]));
  if (kind) q = q.where('kind', 'in', ['any', kind]);
  return new Set((await q.execute()).map((r) => Number(r.rate)));
}

export interface RateCheck { rate: number; hsn?: string | null; field: string; label?: string; anyKind?: boolean }

/** Throws one 400 naming every line whose rate is not valid on `date`. */
export async function assertGstRates(tx: Tx, date: string, checks: RateCheck[]): Promise<void> {
  if (!checks.length) return;
  const cache = new Map<string, Set<number>>();
  const details: Record<string, string> = {};
  for (const c of checks) {
    const kind = c.anyKind ? null : rateKind(c.hsn);
    const key = kind ?? 'all';
    if (!cache.has(key)) cache.set(key, await validRates(tx, date, kind));
    if (!cache.get(key)!.has(Number(c.rate))) {
      details[c.field] = `${c.label ? `${c.label}: ` : ''}${c.rate}% is not a GST rate on ${date}${kind ? ` for ${kind}` : ''}. Update the rate.`;
    }
  }
  const first = Object.values(details)[0];
  if (first) throw badRequest(first, details);
}

