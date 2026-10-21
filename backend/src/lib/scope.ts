import type { RequestContext } from '../auth/context.ts';

const NIL = '00000000-0000-0000-0000-000000000000';

/**
 * Location ids the caller may see, or null for all. An empty scope becomes a
 * list that matches nothing, so `where in` stays valid SQL.
 */
export function scopedLocationIds(ctx: RequestContext): string[] | null {
  const ids = ctx.company.locationIds;
  if (ids === null) return null;
  return ids.length ? ids : [NIL];
}
