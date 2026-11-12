import { z } from 'zod';

/** GST state codes (01–38, plus 97 Other Territory). */
const STATE_CODES = new Set([
  ...Array.from({ length: 38 }, (_, i) => String(i + 1).padStart(2, '0')),
  '97',
]);

export const GSTIN_PATTERN = /^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$/;

export const stateCode = z.string().trim().refine((v) => STATE_CODES.has(v), 'Must be a valid 2-digit GST state code');

const CHECK_CHARS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';

/** GSTIN check digit (mod-36 weighted sum of the first 14 characters). */
export function gstinChecksumValid(g: string): boolean {
  if (g.length !== 15) return false;
  let sum = 0;
  for (let i = 0; i < 14; i++) {
    const v = CHECK_CHARS.indexOf(g[i]!);
    if (v < 0) return false;
    const product = v * (i % 2 === 0 ? 1 : 2);
    sum += Math.floor(product / 36) + (product % 36);
  }
  return CHECK_CHARS[(36 - (sum % 36)) % 36] === g[14];
}

/**
 * The check digit is enforced in production (or with ENFORCE_GSTIN_CHECKSUM=1).
 * Demo data and many fixtures use made-up numbers, so development and tests skip it.
 */
const checksumOn = () => process.env.ENFORCE_GSTIN_CHECKSUM === '1' ||
  (process.env.NODE_ENV === 'production' && process.env.ENFORCE_GSTIN_CHECKSUM !== '0');

/** Format and state only; the check digit is verified by `assertGstinChecksum` on create and on change. */
export const gstinFormat = z
  .string()
  .trim()
  .transform((v) => v.toUpperCase())
  .refine((v) => GSTIN_PATTERN.test(v) && STATE_CODES.has(v.slice(0, 2)), 'Invalid GSTIN');

export const gstin = gstinFormat
  .refine((v) => !checksumOn() || gstinChecksumValid(v), 'Invalid GSTIN: the last character does not match the others');

/** For edits: a GSTIN that is unchanged from the saved one is not re-checked, so older data can still be saved. */
export function gstinChangeOk(next: string | null | undefined, saved: string | null | undefined): boolean {
  if (!next || !checksumOn()) return true;
  if (saved && saved.toUpperCase() === next.toUpperCase()) return true;
  return gstinChecksumValid(next);
}

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
