import { conflict } from './errors.ts';

/**
 * Optimistic edit check. When the client sends `expectedUpdatedAt` and the
 * row changed since, answer 409 STALE_EDIT so nobody overwrites another
 * person's edit unseen. Without it the edit goes through (older clients).
 */
export function assertFresh(current: Date | string | null | undefined, expected: string | undefined, what = 'record') {
  if (!expected || !current) return;
  const a = new Date(current).getTime();
  const b = new Date(expected).getTime();
  if (Number.isNaN(b)) return;
  // The database keeps microseconds; JSON carries milliseconds.
  if (Math.abs(a - b) < 1) return;
  throw conflict(`Someone else changed this ${what} while you were editing. Reload to see the latest version.`, 'STALE_EDIT');
}
