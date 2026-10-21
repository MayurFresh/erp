import { z } from 'zod';

/** GST state codes (01–38, plus 97 Other Territory). */
const STATE_CODES = new Set([
  ...Array.from({ length: 38 }, (_, i) => String(i + 1).padStart(2, '0')),
  '97',
]);

export const GSTIN_PATTERN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;

export const stateCode = z.string().trim().refine((v) => STATE_CODES.has(v), 'Must be a valid 2-digit GST state code');

export const gstin = z
  .string()
  .trim()
  .transform((v) => v.toUpperCase())
  .refine((v) => GSTIN_PATTERN.test(v) && STATE_CODES.has(v.slice(0, 2)), 'Invalid GSTIN');

/** Empty strings become undefined so optional fields can be cleared from forms. */
export const optionalText = (max = 500) =>
  z.preprocess((v) => (typeof v === 'string' && v.trim() === '' ? undefined : v), z.string().trim().max(max).optional());

/**
 * For PATCH bodies: a string sets the field, null or "" clears it, absent leaves it unchanged.
 */
export const nullableText = (max = 500) =>
  z.preprocess((v) => (typeof v === 'string' && v.trim() === '' ? null : v), z.string().trim().max(max).nullable().optional());

/** Drops undefined keys so an update only touches fields that were sent. */
export function definedOnly<T extends Record<string, unknown>>(obj: T): Partial<T> {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== undefined)) as Partial<T>;
}
