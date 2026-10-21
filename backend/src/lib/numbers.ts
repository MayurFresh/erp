import { z } from 'zod';

const hasDecimals = (v: number, places: number) => {
  const scaled = v * 10 ** places;
  return Math.abs(scaled - Math.round(scaled)) < 1e-6;
};

/** Rupee amount, 0 to ₹1,000 crore, at most 2 decimals. */
export const moneyField = z.coerce.number().min(0).max(1e10).refine((v) => hasDecimals(v, 2), 'At most 2 decimals');

/** Quantity up to 3 decimals; sign rules are added by each caller. */
export const qtyField = z.coerce.number().refine((v) => Math.abs(v) <= 1e9, 'Too large').refine((v) => hasDecimals(v, 3), 'At most 3 decimals');

/** Percentage 0–100 with at most 2 decimals. */
export const percentField = z.coerce.number().min(0).max(100).refine((v) => hasDecimals(v, 2), 'At most 2 decimals');
