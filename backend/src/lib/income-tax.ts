// Income-tax rates, slabs, limits and the tax maths (API v1.6 §6, §8). Every figure is effective-dated and carries
// `verified`. Change a rate here, nowhere else. Research: docs/research/self-filing-income-tax.md.

export type Regime = 'new' | 'old';
export type Age = 'below60' | '60to80' | 'above80';
export type Entity = 'individual' | 'huf' | 'firm' | 'llp' | 'company' | 'other';

export interface Slab { from: number; to: number | null; rate: number }
export interface Surcharge { above: number; rate: number }

export interface Dated { id: string; label: string; effectiveFrom: string; verified: boolean }

export interface RegimeConfig extends Dated {
  regime: Regime;
  slabs: Record<Age, Slab[]>;
  rebate: { limit: number; max: number };
  salaryStandardDeduction: number;
  surcharge: Surcharge[];
  cessPct: number;
  /** Old-regime deduction caps. */
  caps?: { s80c: number; s80d: Record<Age, number>; homeLoanInterest: number };
}

const L = 100_000;
const CR = 10_000_000;

const newSlabs: Slab[] = [
  { from: 0, to: 4 * L, rate: 0 }, { from: 4 * L, to: 8 * L, rate: 5 }, { from: 8 * L, to: 12 * L, rate: 10 },
  { from: 12 * L, to: 16 * L, rate: 15 }, { from: 16 * L, to: 20 * L, rate: 20 }, { from: 20 * L, to: 24 * L, rate: 25 },
  { from: 24 * L, to: null, rate: 30 },
];
const oldSlabs = (exempt: number): Slab[] => [
  { from: 0, to: exempt, rate: 0 },
  ...(exempt < 5 * L ? [{ from: exempt, to: 5 * L, rate: 5 }] : []),
  { from: 5 * L, to: 10 * L, rate: 20 },
  { from: 10 * L, to: null, rate: 30 },
];

export const REGIMES: RegimeConfig[] = [
  {
    id: 'regime_new', label: 'New regime slabs, rebate and surcharge', effectiveFrom: '2026-04-01', verified: false, regime: 'new',
    slabs: { below60: newSlabs, '60to80': newSlabs, above80: newSlabs },
    rebate: { limit: 12 * L, max: 60_000 }, salaryStandardDeduction: 75_000,
    surcharge: [{ above: 50 * L, rate: 10 }, { above: CR, rate: 15 }, { above: 2 * CR, rate: 25 }], cessPct: 4,
  },
  {
    id: 'regime_old', label: 'Old regime slabs, rebate and surcharge', effectiveFrom: '2026-04-01', verified: false, regime: 'old',
    slabs: { below60: oldSlabs(2.5 * L), '60to80': oldSlabs(3 * L), above80: oldSlabs(5 * L) },
    rebate: { limit: 5 * L, max: 12_500 }, salaryStandardDeduction: 50_000,
    surcharge: [{ above: 50 * L, rate: 10 }, { above: CR, rate: 15 }, { above: 2 * CR, rate: 25 }, { above: 5 * CR, rate: 37 }], cessPct: 4,
    caps: { s80c: 150_000, s80d: { below60: 25_000, '60to80': 50_000, above80: 50_000 }, homeLoanInterest: 200_000 },
  },
];

export interface EntityRates extends Dated { firm: number; llp: number; company: number; companyConcessional: number; other: number; cessPct: number }
export const ENTITY_RATES: EntityRates[] = [
  { id: 'entity_rates', label: 'Firm, LLP and company tax rates', effectiveFrom: '2026-04-01', verified: false, firm: 30, llp: 30, company: 25, companyConcessional: 22, other: 30, cessPct: 4 },
];

export interface PresumptiveRules extends Dated {
  business: { limit: number; limitMostlyDigital: number; digitalPct: number; cashPct: number };
  profession: { limit: number; limitMostlyDigital: number; pct: number };
  /** Cash share of receipts (percent) at or below which the higher limit applies. */
  maxCashSharePct: number;
}
export const PRESUMPTIVE: PresumptiveRules[] = [
  {
    id: 'presumptive', label: 'Presumptive taxation limits and deemed rates', effectiveFrom: '2026-04-01', verified: false,
    business: { limit: 2 * CR, limitMostlyDigital: 3 * CR, digitalPct: 6, cashPct: 8 },
    profession: { limit: 50 * L, limitMostlyDigital: 75 * L, pct: 50 },
    maxCashSharePct: 5,
  },
];

export interface AdvanceTaxRules extends Dated {
  minNetTax: number;
  /** s.425 interest: percent a month, and months charged on each instalment (the last one for March is 1). */
  interest425PctPerMonth: number; interest425Months: number[];
  /** s.424 interest: percent a month on the unpaid tax when advance tax paid is below `thresholdPct`; months April to the return month. */
  interest424PctPerMonth: number; interest424ThresholdPct: number; interest424Months: number;
}
export const ADVANCE_TAX: AdvanceTaxRules[] = [
  {
    id: 'advance_tax', label: 'Advance tax liability and interest (s.424, s.425)', effectiveFrom: '2026-04-01', verified: false, minNetTax: 10_000,
    interest425PctPerMonth: 1, interest425Months: [3, 3, 3, 1], interest424PctPerMonth: 1, interest424ThresholdPct: 90, interest424Months: 4,
  },
];

export interface CaRules extends Dated {
  taxAuditTurnover: number; taxAuditTurnoverMostlyDigital: number; maxCashSharePct: number; gst9cTurnover: number;
}
export const CA_RULES: CaRules[] = [
  { id: 'ca_rules', label: 'Tax audit and GSTR-9C thresholds', effectiveFrom: '2026-04-01', verified: false, taxAuditTurnover: CR, taxAuditTurnoverMostlyDigital: 10 * CR, maxCashSharePct: 5, gst9cTurnover: 5 * CR },
];

export interface TdsDefaultRules extends Dated { interestPctPerMonth: number; lateFeePerDay: number }
export const TDS_DEFAULTS: TdsDefaultRules[] = [
  { id: 'tds_defaults', label: 'TDS late deposit interest (1.5% a month) and s.427 late fee (Rs 200 a day)', effectiveFrom: '2026-04-01', verified: false, interestPctPerMonth: 1.5, lateFeePerDay: 200 },
];

/** Cash payments above this are flagged in the ITR pack (s.40A(3) equivalent). */
export const CASH_PAYMENT_LIMIT = 10_000;

/** The rule in force at the start of `taxYear` ('2026-27'); the earliest rule if none is yet in force. */
export function pickRule<T extends Dated>(rules: T[], taxYear: string): T {
  const at = `${taxYear.slice(0, 4)}-04-01`;
  const sorted = [...rules].sort((a, b) => a.effectiveFrom.localeCompare(b.effectiveFrom));
  return [...sorted].reverse().find((r) => r.effectiveFrom <= at) ?? sorted[0]!;
}

export const entityOf = (constitution: string | null): Entity => {
  switch (constitution) {
    case 'huf': return 'huf';
    case 'partnership': return 'firm';
    case 'llp': return 'llp';
    case 'private_company': case 'public_company': return 'company';
    case 'trust': case 'other': return 'other';
    default: return 'individual'; // proprietorship, or not set
  }
};

const round2 = (n: number) => Math.round(n * 100) / 100;

export interface TaxCalc {
  taxable: number;
  slabs: { from: number; to: number | null; rate: number; tax: number }[];
  baseTax: number; rebate: number; surcharge: number; cess: number; total: number;
}
export interface Calculated { calc: TaxCalc; unverified: string[] }

const unverifiedOf = (...rules: Dated[]) => rules.filter((r) => !r.verified).map((r) => r.label);

/** Taxable income of an individual or HUF under a regime, after the standard deduction and (old regime) deductions. */
export function individualTaxable(
  regime: RegimeConfig, age: Age,
  i: { salary: number; business: number; otherIncome: number; deductions?: { s80c?: number; s80d?: number; homeLoanInterest?: number; other?: number } },
): number {
  const std = Math.min(i.salary, regime.salaryStandardDeduction);
  let taxable = i.salary - std + i.business + i.otherIncome;
  if (regime.regime === 'old' && regime.caps) {
    const d = i.deductions ?? {};
    taxable -= Math.min(d.s80c ?? 0, regime.caps.s80c) + Math.min(d.s80d ?? 0, regime.caps.s80d[age])
      + Math.min(d.homeLoanInterest ?? 0, regime.caps.homeLoanInterest) + (d.other ?? 0);
  }
  return Math.max(0, round2(taxable));
}

/** Tax on an individual's or HUF's taxable income. Marginal relief is ignored. */
export function individualTax(regime: RegimeConfig, age: Age, taxable: number): Calculated {
  const rows = regime.slabs[age].map((s) => {
    const top = s.to ?? Infinity;
    const part = Math.max(0, Math.min(taxable, top) - s.from);
    return { from: s.from, to: s.to, rate: s.rate, tax: round2((part * s.rate) / 100) };
  });
  const slabs = rows.filter((r) => taxable > r.from);
  const baseTax = round2(slabs.reduce((s, r) => s + r.tax, 0));
  const rebate = taxable <= regime.rebate.limit ? Math.min(baseTax, regime.rebate.max) : 0;
  const net = baseTax - rebate;
  const sur = [...regime.surcharge].reverse().find((s) => taxable > s.above);
  const surcharge = sur ? round2((net * sur.rate) / 100) : 0;
  const cess = round2(((net + surcharge) * regime.cessPct) / 100);
  return { calc: { taxable, slabs, baseTax, rebate, surcharge, cess, total: round2(net + surcharge + cess) }, unverified: unverifiedOf(regime) };
}

/** Flat-rate tax for a firm, LLP, company or other entity. Surcharge and marginal relief are not computed. */
export function entityTax(entity: Exclude<Entity, 'individual' | 'huf'>, taxYear: string, taxable: number, concessionalCompany = false): Calculated {
  const r = pickRule(ENTITY_RATES, taxYear);
  const rate = entity === 'company' ? (concessionalCompany ? r.companyConcessional : r.company) : r[entity];
  const baseTax = round2((taxable * rate) / 100);
  const cess = round2((baseTax * r.cessPct) / 100);
  return {
    calc: { taxable, slabs: [{ from: 0, to: null, rate, tax: baseTax }], baseTax, rebate: 0, surcharge: 0, cess, total: round2(baseTax + cess) },
    unverified: unverifiedOf(r),
  };
}

export const regimeConfig = (regime: Regime, taxYear: string) => pickRule(REGIMES.filter((r) => r.regime === regime), taxYear);

/** Presumptive scheme check for a business or profession. */
export function presumptiveCheck(
  taxYear: string, kind: 'business' | 'profession', digital: number, cash: number, declaredProfit?: number,
) {
  const r = pickRule(PRESUMPTIVE, taxYear);
  const total = digital + cash;
  const cashPct = total > 0 ? (cash / total) * 100 : 0;
  const mostlyDigital = cashPct <= r.maxCashSharePct;
  const rule = kind === 'business' ? r.business : r.profession;
  const limit = mostlyDigital ? rule.limitMostlyDigital : rule.limit;
  const deemedIncome = kind === 'business'
    ? round2((digital * r.business.digitalPct) / 100 + (cash * r.business.cashPct) / 100)
    : round2((total * r.profession.pct) / 100);
  const eligible = total <= limit;
  const declaredBelowDeemed = declaredProfit !== undefined && declaredProfit < deemedIncome;
  const notes = [
    mostlyDigital ? `Cash is ${round2(cashPct)}% of receipts, so the higher limit applies.` : `Cash is ${round2(cashPct)}% of receipts, so the lower limit applies.`,
    eligible ? 'Receipts are within the limit.' : 'Receipts are above the limit, so this scheme is not available.',
    'Advance tax is a single payment by 15 March.',
  ];
  return {
    eligible, limit, deemedIncome, declaredBelowDeemed,
    auditRisk: declaredBelowDeemed ? 'Declaring a profit below the deemed rate can need a tax audit (disputed under the new Act).' : null,
    notes, unverified: unverifiedOf(r),
  };
}
