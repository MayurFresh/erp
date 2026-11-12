// Paid days and pro-rata. A single rule: paid fraction = days in service / days in month, less LOP days / divisor.

export type LopDivisor = 'calendar' | '30' | '26';

export const daysInMonth = (monthStart: string): number => {
  const y = Number(monthStart.slice(0, 4)), m = Number(monthStart.slice(5, 7));
  return new Date(Date.UTC(y, m, 0)).getUTCDate();
};
const dayNo = (iso: string): number => Math.round(Date.parse(`${iso}T00:00:00Z`) / 86400000);

export interface ProrationInput {
  monthStart: string; joining: string; leaving?: string | null; lopDays: number; divisor: LopDivisor;
}
export interface Proration { daysInMonth: number; serviceDays: number; divisorDays: number; fraction: number; paidDays: number }

export function prorate(i: ProrationInput): Proration {
  const dim = daysInMonth(i.monthStart);
  const monthEnd = `${i.monthStart.slice(0, 8)}${String(dim).padStart(2, '0')}`;
  const from = i.joining > i.monthStart ? i.joining : i.monthStart;
  const to = i.leaving && i.leaving < monthEnd ? i.leaving : monthEnd;
  const serviceDays = Math.max(0, dayNo(to) - dayNo(from) + 1);
  const divisorDays = i.divisor === 'calendar' ? dim : Number(i.divisor);
  const raw = serviceDays / dim - i.lopDays / divisorDays;
  const fraction = Math.min(1, Math.max(0, Math.round(raw * 1e6) / 1e6));
  return { daysInMonth: dim, serviceDays, divisorDays, fraction, paidDays: Math.round(fraction * divisorDays * 100) / 100 };
}
