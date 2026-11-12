// Small rounding helpers for payroll. All amounts are rupees with at most 2 decimals.

/** Nearest rupee, halves go up. */
export const roundRupee = (n: number): number => Math.floor(n + 0.5 + 1e-9);
/** Round up to the next rupee, ignoring float noise. */
export const ceilRupee = (n: number): number => Math.ceil(n - 1e-9);
export const round2 = (n: number): number => Math.round((n + Number.EPSILON) * 100) / 100;
