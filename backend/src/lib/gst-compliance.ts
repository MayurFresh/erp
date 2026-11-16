// Dated GST compliance rules: e-invoice reporting window, e-way bill limits, item rate history, slab review.
// Sources are listed in docs/API.md "GST compliance updates".

import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, todayIst } from './dates.ts';

export const EINVOICE_WINDOW_DAYS = 30;
export const EINVOICE_WARN_FROM_DAY = 20;
export const EWB_MAX_DOC_AGE_DAYS = 180;
export const EWB_KM_PER_DAY = 200;
export const SLAB_EFFECTIVE_FROM = '2025-09-22';
export const RATE_HISTORY_START = '2017-07-01';

export type EinvoiceState = 'ok' | 'warn' | 'blocked' | 'na';

/** State of an unreported invoice: warn from day 20, blocked from day 30 of age. The portal's own example (invoice dated
 * 1 April, last day 30 April) counts the invoice date as day 1, so age 29 is the last allowed day. Not applicable below 10 crore. */
export function einvoiceState(band: string, ageDays: number): EinvoiceState {
  if (band !== '10cr_plus') return 'na';
  if (ageDays >= EINVOICE_WINDOW_DAYS) return 'blocked';
  return ageDays >= EINVOICE_WARN_FROM_DAY ? 'warn' : 'ok';
}

export const documentAge = (docDate: string, today = todayIst()) => daysBetween(docDate, today);

/** Validity of an e-way bill: 1 day per 200 km or part (min 1), ending at 23:59:59 IST of the last day. */
export function ewbValidity(from: Date, distanceKm: number) {
  const days = Math.max(1, Math.ceil(distanceKm / EWB_KM_PER_DAY));
  const lastDay = addDays(todayIst(from), days);
  return { days, validUntil: new Date(`${lastDay}T23:59:59+05:30`) };
}

/** Rate of an item on a date from its history; null when the item has no history row on or before that date. */
export async function itemRateOn(tx: Tx, itemId: string, date: string): Promise<number | null> {
  const r = await tx.selectFrom('item_gst_rates').select('rate').where('item_id', '=', itemId)
    .where('effective_from', '<=', date).orderBy('effective_from', 'desc').limit(1).executeTakeFirst();
  return r ? Number(r.rate) : null;
}

/** Items with their rate on `date` (history first, else the item's own rate). */
export async function withDatedRates<T extends { id: string; gst_rate: number }>(tx: Tx, items: T[], date: string): Promise<T[]> {
  if (!items.length) return items;
  const rows = await tx.selectFrom('item_gst_rates').select(['item_id', 'rate', 'effective_from'])
    .where('item_id', 'in', items.map((i) => i.id)).where('effective_from', '<=', date).orderBy('effective_from', 'desc').execute();
  const first = new Map<string, number>();
  for (const r of rows) if (!first.has(r.item_id)) first.set(r.item_id, Number(r.rate));
  return items.map((i) => (first.has(i.id) ? { ...i, gst_rate: first.get(i.id)! } : i));
}

const CHECK_HSN = ['2202', '2402', '2403', '2106', '8703', '2401'];

/** Proposed rate under the 22 Sep 2025 slabs. Never applied without the user's choice. */
export function proposeSlab(current: number, hsn: string | null) {
  const needsCheck = current === 28 && !!hsn && CHECK_HSN.some((p) => hsn.startsWith(p));
  if (current === 12) return { proposed: 5, needsCheck: false };
  if (current === 28) return { proposed: needsCheck ? 40 : 18, needsCheck };
  return { proposed: current, needsCheck: false };
}
