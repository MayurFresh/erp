// GST late fee, caps and interest (API v1.6 §2). Every figure is UNVERIFIED until a CA checks it against the notification.

export const GST_PENALTIES = {
  lateFeePerDay: { value: 50, verified: false },
  lateFeePerDayNil: { value: 20, verified: false },
  /** Cap by last year's turnover (rupees). */
  caps: [
    { upTo: 15_000_000, cap: 2000, verified: false },
    { upTo: 50_000_000, cap: 5000, verified: false },
    { upTo: Infinity, cap: 10_000, verified: false },
  ],
  nilCap: { value: 500, verified: false },
  interestPctPerYear: { value: 18, verified: false },
} as const;

export const UNVERIFIED_PENALTY_FIGURES = [
  'GST late fee: Rs 50 a day (Rs 20 for a nil return)',
  'GST late fee caps: Rs 2,000 / 5,000 / 10,000 by turnover, Rs 500 for nil',
  'GST interest: 18% a year on the cash tax',
];

/** Late fee in rupees for `daysLate` days. */
export function gstLateFee(daysLate: number, nil: boolean, lastYearTurnover: number): number {
  if (daysLate <= 0) return 0;
  const perDay = nil ? GST_PENALTIES.lateFeePerDayNil.value : GST_PENALTIES.lateFeePerDay.value;
  const cap = nil ? GST_PENALTIES.nilCap.value : GST_PENALTIES.caps.find((c) => lastYearTurnover <= c.upTo)!.cap;
  return Math.min(cap, daysLate * perDay);
}

/** Interest in rupees on `cashTax` (rupees) for `daysLate` days. */
export function gstInterest(cashTax: number, daysLate: number): number {
  if (daysLate <= 0 || cashTax <= 0) return 0;
  return Math.round((cashTax * GST_PENALTIES.interestPctPerYear.value * daysLate) / 365);
}

/** Thresholds for GSTR-9 (rupees of annual turnover). */
export const GSTR9_MANDATORY_ABOVE = 20_000_000;
export const GSTR9C_ABOVE = 50_000_000;
