import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest } from '../lib/errors.ts';

export const round2 = (n: number) => Math.round(n * 100) / 100;
export const round3 = (n: number) => Math.round(n * 1000) / 1000;

/** Adds calendar months to a YYYY-MM-DD date, keeping the day or the last day of a shorter month. */
export function addMonths(date: string, months: number): string {
  const y = Number(date.slice(0, 4));
  const m = Number(date.slice(5, 7)) - 1 + months;
  const day = Number(date.slice(8, 10));
  const last = new Date(Date.UTC(y + Math.floor(m / 12), ((m % 12) + 12) % 12 + 1, 0)).getUTCDate();
  const out = new Date(Date.UTC(y + Math.floor(m / 12), ((m % 12) + 12) % 12, Math.min(day, last)));
  return out.toISOString().slice(0, 10);
}

/** The location a bill goes to when the caller does not name one: the first active location they can use. */
export async function defaultLocation(tx: Tx, ctx: RequestContext, wanted?: string): Promise<string> {
  if (wanted) { ctx.requireLocation(wanted); return wanted; }
  const locs = await tx.selectFrom('locations').select('id').where('company_id', '=', ctx.companyId)
    .where('is_active', '=', true).orderBy('created_at').execute();
  const id = locs.find((l) => ctx.canAccessLocation(l.id))?.id;
  if (!id) throw badRequest('Add a location before billing.', { locationId: 'Required' });
  return id;
}
