// Leave day counting. A day counts when it is not a week off and not a holiday.

const toDate = (iso: string) => new Date(`${iso}T00:00:00Z`);
const iso = (d: Date) => d.toISOString().slice(0, 10);

export interface LeaveCountInput { from: string; to: string; halfDay?: boolean; holidays: Set<string>; weekOffs?: number[] }

/** Days of leave in the range. Week offs default to Sunday (0). A half day is one date only and counts 0.5. */
export function countLeaveDays(i: LeaveCountInput): number {
  const off = i.weekOffs ?? [0];
  let n = 0;
  for (let d = toDate(i.from); iso(d) <= i.to; d = new Date(d.getTime() + 86400000)) {
    if (off.includes(d.getUTCDay()) || i.holidays.has(iso(d))) continue;
    n += 1;
  }
  return i.halfDay ? (n > 0 && i.from === i.to ? 0.5 : 0) : n;
}

/** The part of a leave range that falls inside a month, as a new range or null. */
export function clipToMonth(from: string, to: string, monthStart: string): { from: string; to: string } | null {
  const y = Number(monthStart.slice(0, 4)), m = Number(monthStart.slice(5, 7));
  const monthEnd = iso(new Date(Date.UTC(y, m, 0)));
  const f = from > monthStart ? from : monthStart, t = to < monthEnd ? to : monthEnd;
  return f <= t ? { from: f, to: t } : null;
}

/** April-March year that holds a date, named by its start year. */
export const leaveYear = (date: string): number => (Number(date.slice(5, 7)) >= 4 ? Number(date.slice(0, 4)) : Number(date.slice(0, 4)) - 1);
