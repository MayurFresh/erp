// MSME delayed-payment interest (MSMED Act s.16): compound interest with monthly rests at 3 x the RBI bank rate.

import { daysBetween } from './dates.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;

/** `date` plus n calendar months, clamped to the month's last day (Jan 31 + 1 = Feb 28/29). */
export function addMonths(date: string, n: number): string {
  const idx = Number(date.slice(0, 4)) * 12 + (Number(date.slice(5, 7)) - 1) + n;
  const y = Math.floor(idx / 12);
  const m = (idx % 12) + 1;
  const last = new Date(Date.UTC(y, m, 0)).getUTCDate();
  const d = Math.min(Number(date.slice(8, 10)), last);
  return `${y}-${String(m).padStart(2, '0')}-${String(d).padStart(2, '0')}`;
}

/**
 * Interest on `unpaid` overdue since `dueDate`, as of `asOf`. Each full month adds `balance x 3 x rate / 1200`;
 * a part month adds the same for days / 30. Null when the bank rate is unknown; 0 when not yet overdue.
 */
export function msmeInterest(unpaid: number, dueDate: string, asOf: string, bankRate: number | null): number | null {
  if (bankRate === null || bankRate === undefined) return null;
  if (asOf <= dueDate || unpaid <= 0) return 0;
  const monthly = (3 * bankRate) / 1200;
  let months = 0;
  while (addMonths(dueDate, months + 1) <= asOf) months++;
  let balance = unpaid;
  for (let i = 0; i < months; i++) balance += balance * monthly;
  const days = daysBetween(addMonths(dueDate, months), asOf);
  balance += balance * monthly * (days / 30);
  return round2(balance - unpaid);
}
