// Business dates follow Indian time regardless of where the server runs.
const IST = 'Asia/Kolkata';

/** Today's date in India as YYYY-MM-DD. */
export function todayIst(now: Date = new Date()): string {
  return now.toLocaleDateString('en-CA', { timeZone: IST });
}

/** Financial year label for a YYYY-MM-DD date: April–March, e.g. "2026-27". */
export function financialYear(date: string): string {
  const year = Number(date.slice(0, 4));
  const month = Number(date.slice(5, 7));
  const start = month >= 4 ? year : year - 1;
  return `${start}-${String((start + 1) % 100).padStart(2, '0')}`;
}

/** Invoice number such as INV/26-27/00001 (max 16 characters, as GST rules require). */
export function invoiceNumber(fy: string, seq: number): string {
  return `INV/${fy.slice(2)}/${String(seq).padStart(5, '0')}`;
}

export function isValidDate(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const d = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === value;
}

/** Adds whole days to a YYYY-MM-DD date. */
export function addDays(date: string, days: number): string {
  const d = new Date(`${date}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Days from `from` to `to` (both YYYY-MM-DD); negative if `to` is earlier. */
export function daysBetween(from: string, to: string): number {
  return Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / 86_400_000);
}

/** First day of the financial year containing `date`. */
export function fyStart(date: string): string {
  return `${financialYear(date).slice(0, 4)}-04-01`;
}
