import type { z } from 'zod';
import { badRequest } from './errors.ts';

/** Parses input with a zod schema, turning problems into a 400 with a field → message map. */
export function parse<S extends z.ZodType>(schema: S, input: unknown): z.infer<S> {
  const result = schema.safeParse(input ?? {});
  if (result.success) return result.data;
  const details: Record<string, string> = {};
  for (const issue of result.error.issues) {
    const key = issue.path.join('.') || '_';
    details[key] ??= issue.message;
  }
  const first = Object.entries(details)[0];
  throw badRequest(first ? `${first[0]}: ${first[1]}` : 'Invalid input.', details);
}

// Shared field rules (v1.5 input limits). Money, quantity and percent live in numbers.ts; text helpers in india.ts.
import { z as zod } from 'zod';
import { addDays, isValidDate, todayIst } from './dates.ts';

export { moneyField as money, qtyField as qty, percentField as pct } from './numbers.ts';

/** Document date: YYYY-MM-DD between 2000-01-01 and today + 365 days. */
export const docDate = zod
  .string()
  .refine(isValidDate, 'Use YYYY-MM-DD')
  .refine((v) => v >= '2000-01-01' && v <= addDays(todayIst(), 365), 'Date must be between 2000-01-01 and one year from today');

/** Name or title: trimmed, 1 to 200 characters. */
export const name = zod.string().trim().min(1, 'Required').max(200, 'At most 200 characters');

/** Notes or narration: at most 2000 characters. */
export const notes = zod.string().trim().max(2000, 'At most 2000 characters');
