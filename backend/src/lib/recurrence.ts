import { addDays } from './dates.ts';

export type Frequency = 'weekly' | 'monthly' | 'quarterly' | 'half_yearly' | 'yearly';
export const FREQUENCIES: Frequency[] = ['weekly', 'monthly', 'quarterly', 'half_yearly', 'yearly'];

export interface Schedule { frequency: Frequency; startDate: string; dayOfMonth: number | null }

const MONTHS: Record<Exclude<Frequency, 'weekly'>, number> = { monthly: 1, quarterly: 3, half_yearly: 6, yearly: 12 };

const lastDay = (year: number, month1: number) => new Date(Date.UTC(year, month1, 0)).getUTCDate();

/** The date in the month `monthsFromStart` after the start date's month, with the day clamped to the month's length. */
function inMonth(startDate: string, monthsFromStart: number, dom: number): string {
  const total = Number(startDate.slice(0, 4)) * 12 + (Number(startDate.slice(5, 7)) - 1) + monthsFromStart;
  const year = Math.floor(total / 12);
  const month1 = (total % 12) + 1;
  const day = Math.min(dom, lastDay(year, month1));
  return `${String(year).padStart(4, '0')}-${String(month1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
}

/**
 * Date of period number `n` (0 is the first). Weekly repeats every 7 days from the start date. Longer
 * frequencies fall on `dayOfMonth` (default: the start date's day); a month without that day uses its last day.
 * Each date is worked out from the start, so a 31st does not drift to the 28th after February.
 */
export function slotDate(s: Schedule, n: number): string {
  if (s.frequency === 'weekly') return addDays(s.startDate, 7 * n);
  const step = MONTHS[s.frequency];
  const dom = s.dayOfMonth ?? Number(s.startDate.slice(8, 10));
  const shift = inMonth(s.startDate, 0, dom) < s.startDate ? step : 0;
  return inMonth(s.startDate, shift + n * step, dom);
}

/** First period number at or after `n` whose date is on or after `from`. */
export function firstSlotFrom(s: Schedule, n: number, from: string): number {
  let i = n;
  while (slotDate(s, i) < from && i < n + 20000) i += 1;
  return i;
}
