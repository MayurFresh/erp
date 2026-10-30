// Pure depreciation maths: book (SLM / WDV) and the income-tax block method (API v1.6 §7). No database access.

const round2 = (n: number) => Math.round(n * 100) / 100;

/** An asset put to use for fewer days than this in the year gets half the block rate (UNVERIFIED for the new Act). */
export const HALF_RATE_DAYS = 180;
/** WDV needs a residual above zero to have a rate; below this share it is taken as 1% for the rate only. */
const MIN_WDV_RESIDUAL_PCT = 1;

export interface BookAsset {
  method: 'slm' | 'wdv'; cost: number; residualPct: number; lifeYears: number;
  /** Opening plus charged accumulated depreciation so far. */
  accumulated: number;
}

export const residualOf = (cost: number, residualPct: number) => round2((cost * residualPct) / 100);

/** WDV rate as a fraction: 1 − (residual ÷ cost)^(1 ÷ life). */
export function wdvRate(cost: number, residualPct: number, lifeYears: number): number {
  const share = Math.max(residualPct, MIN_WDV_RESIDUAL_PCT) / 100;
  return 1 - Math.pow(share, 1 / lifeYears);
}

/** Book depreciation for `days`, never taking the book value below the residual. */
export function bookDepreciation(a: BookAsset, days: number): number {
  const residual = residualOf(a.cost, a.residualPct);
  const room = Math.max(0, round2(a.cost - a.accumulated - residual));
  if (room <= 0 || days <= 0) return 0;
  const raw = a.method === 'slm'
    ? ((a.cost - residual) / a.lifeYears) * (days / 365)
    : (a.cost - a.accumulated) * wdvRate(a.cost, a.residualPct, a.lifeYears) * (days / 365);
  return Math.min(round2(raw), room);
}

export interface BlockInput {
  /** Percent, e.g. 15. */
  rate: number; opening: number; additionsFull: number; additionsHalf: number; saleValue: number;
}
export interface BlockResult {
  openingWdv: number; additionsFull: number; additionsHalf: number; saleValue: number;
  depreciation: number; closingWdv: number; shortTermGain: number;
}

/**
 * Income-tax block depreciation. The sale value is set first against opening plus full additions, then against the
 * half-year additions. A sale above the whole block is a short-term gain and the block closes at nil.
 */
export function blockDepreciation(b: BlockInput): BlockResult {
  const base = b.opening + b.additionsFull;
  const afterSale = base - b.saleValue;
  const excess = Math.max(0, -afterSale); // sale left over after the opening and full additions
  const fullBase = Math.max(0, afterSale);
  const halfLeft = Math.max(0, b.additionsHalf - excess);
  const gain = Math.max(0, excess - b.additionsHalf);
  const depreciation = round2((fullBase * b.rate) / 100 + (halfLeft * b.rate) / 200);
  const closing = Math.max(0, round2(fullBase + halfLeft - depreciation));
  return {
    openingWdv: round2(b.opening), additionsFull: round2(b.additionsFull), additionsHalf: round2(b.additionsHalf),
    saleValue: round2(b.saleValue), depreciation, closingWdv: closing, shortTermGain: round2(gain),
  };
}
