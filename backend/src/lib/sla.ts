/*
 * SLA due times. In 24x7 mode a target is plain elapsed hours. In business mode the clock runs only on the
 * working days and between the start and end time, in IST, so a ticket raised after closing starts counting
 * at the next opening.
 */

export interface Hours { mode: '24x7' | 'business'; workDays: number[]; startTime: string; endTime: string }

export const DEFAULT_HOURS: Hours = { mode: 'business', workDays: [1, 2, 3, 4, 5, 6], startTime: '09:00', endTime: '18:00' };

const IST_MS = 5.5 * 3600_000;
const DAY_MS = 86_400_000;
const minutesOf = (hhmm: string) => Number(hhmm.slice(0, 2)) * 60 + Number(hhmm.slice(3, 5));

/** The moment `hours` of service time after `start`. */
export function dueAt(start: Date, hours: number, cfg: Hours): Date {
  if (cfg.mode === '24x7') return new Date(start.getTime() + hours * 3600_000);
  const open = minutesOf(cfg.startTime) * 60_000;
  const close = minutesOf(cfg.endTime) * 60_000;
  if (close <= open || !cfg.workDays.length) return new Date(start.getTime() + hours * 3600_000);
  let remaining = hours * 3600_000;
  let local = start.getTime() + IST_MS; // IST wall clock held as a UTC timestamp
  let dayStart = Math.floor(local / DAY_MS) * DAY_MS;
  for (let i = 0; i < 800; i += 1) {
    const dow = new Date(dayStart).getUTCDay() || 7; // 1 = Monday .. 7 = Sunday
    if (cfg.workDays.includes(dow)) {
      const from = Math.max(local, dayStart + open);
      const to = dayStart + close;
      if (from < to) {
        if (remaining <= to - from) return new Date(from + remaining - IST_MS);
        remaining -= to - from;
      }
    }
    dayStart += DAY_MS;
    local = dayStart;
  }
  return new Date(start.getTime() + hours * 3600_000);
}

export const DEFAULT_SLA: Record<string, { firstResponseHours: number; resolutionHours: number }> = {
  low: { firstResponseHours: 24, resolutionHours: 120 },
  medium: { firstResponseHours: 8, resolutionHours: 48 },
  high: { firstResponseHours: 4, resolutionHours: 24 },
  urgent: { firstResponseHours: 1, resolutionHours: 8 },
};
