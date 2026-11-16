// Professional tax and labour welfare fund tables. NEEDS A CA CHECK: every row is UNVERIFIED against the state
// notification (docs/research/payroll-hr.md sections 4 and 5). Verify current rates before real filing.
// State codes are GST state codes.

export interface PtSlab { from: number; to: number | null; amount: number; sex?: 'M' | 'F' }
export interface PtRule {
  stateCode: string; state: string; periodicity: 'monthly' | 'half_yearly';
  /** Months (1-12) in which half-yearly tax is deducted. */
  deductMonths?: number[];
  /** Per-month amount instead of the slab amount, for a slab that has one (Maharashtra and Karnataka February). */
  monthOverride?: { month: number; amount: number; minSlabAmount: number }[];
  slabs: PtSlab[];
  note: string; verified: false;
}

const slabs = (rows: [number, number | null, number][]): PtSlab[] => rows.map(([from, to, amount]) => ({ from, to, amount }));

export const PT_RULES: PtRule[] = [
  {
    stateCode: '27', state: 'Maharashtra', periodicity: 'monthly', verified: false,
    // Women pay nothing up to 25,000. February is 300 so the year adds to 2,500.
    slabs: [
      { from: 0, to: 7500, amount: 0, sex: 'M' }, { from: 7501, to: 10000, amount: 175, sex: 'M' }, { from: 10001, to: null, amount: 200, sex: 'M' },
      { from: 0, to: 25000, amount: 0, sex: 'F' }, { from: 25001, to: null, amount: 200, sex: 'F' },
    ],
    monthOverride: [{ month: 2, amount: 300, minSlabAmount: 200 }],
    note: 'February is 300 for the 200 slab.',
  },
  {
    stateCode: '29', state: 'Karnataka', periodicity: 'monthly', verified: false,
    slabs: slabs([[0, 24999, 0], [25000, null, 200]]), monthOverride: [{ month: 2, amount: 300, minSlabAmount: 200 }],
    note: 'Sources disagree on a middle slab; the 25,000 threshold is used.',
  },
  { stateCode: '19', state: 'West Bengal', periodicity: 'monthly', verified: false, slabs: slabs([[0, 10000, 0], [10001, 15000, 110], [15001, 25000, 130], [25001, 40000, 150], [40001, null, 200]]), note: '' },
  { stateCode: '36', state: 'Telangana', periodicity: 'monthly', verified: false, slabs: slabs([[0, 15000, 0], [15001, 20000, 150], [20001, null, 200]]), note: '' },
  { stateCode: '37', state: 'Andhra Pradesh', periodicity: 'monthly', verified: false, slabs: slabs([[0, 15000, 0], [15001, 20000, 150], [20001, null, 200]]), note: '' },
  { stateCode: '24', state: 'Gujarat', periodicity: 'monthly', verified: false, slabs: slabs([[0, 11999, 0], [12000, null, 200]]), note: 'Older sources show 80 and 150 steps.' },
  {
    stateCode: '33', state: 'Tamil Nadu', periodicity: 'half_yearly', deductMonths: [3, 9], verified: false,
    // Slabs are on half-yearly pay. Deducted in March and September.
    slabs: slabs([[0, 21000, 0], [21001, 30000, 135], [30001, 45000, 315], [45001, 60000, 690], [60001, 75000, 1025], [75001, null, 1250]]),
    note: 'Half-yearly slabs; the monthly gross is multiplied by 6.',
  },
];

export const ptRuleFor = (stateCode: string | null | undefined): PtRule | undefined => PT_RULES.find((r) => r.stateCode === stateCode);

export interface PtInput { stateCode: string | null | undefined; monthlyGross: number; month: number; sex?: string | null; rule?: PtRule | null }
export interface PtResult { amount: number; rule: PtRule | null }

/** Professional tax to deduct this month. Unknown states and states without PT give 0. */
export function computePt(i: PtInput): PtResult {
  const rule = i.rule ?? ptRuleFor(i.stateCode) ?? null;
  if (!rule) return { amount: 0, rule: null };
  const basis = rule.periodicity === 'half_yearly' ? i.monthlyGross * 6 : i.monthlyGross;
  if (rule.periodicity === 'half_yearly' && !rule.deductMonths!.includes(i.month)) return { amount: 0, rule };
  const sexSlabs = rule.slabs.filter((s) => s.sex === (i.sex === 'F' ? 'F' : 'M'));
  const pool = sexSlabs.length ? sexSlabs : rule.slabs;
  const b = Math.ceil(basis - 1e-9);
  const slab = pool.find((s) => b >= s.from && (s.to === null || b <= s.to));
  if (!slab) return { amount: 0, rule };
  const over = rule.monthOverride?.find((o) => o.month === i.month && slab.amount === o.minSlabAmount);
  return { amount: over ? over.amount : slab.amount, rule };
}

// Labour welfare fund. Optional per company (payroll_settings.lwf_enabled). UNVERIFIED amounts.
export interface LwfRule { stateCode: string; state: string; employee: number; employer: number; months: number[]; verified: false }
export const LWF_RULES: LwfRule[] = [
  { stateCode: '27', state: 'Maharashtra', employee: 25, employer: 75, months: [6, 12], verified: false },
  { stateCode: '29', state: 'Karnataka', employee: 50, employer: 100, months: [12], verified: false },
  { stateCode: '24', state: 'Gujarat', employee: 6, employer: 12, months: [6, 12], verified: false },
  { stateCode: '37', state: 'Andhra Pradesh', employee: 30, employer: 70, months: [12], verified: false },
];
export function computeLwf(stateCode: string | null | undefined, month: number, rule?: { employee: number; employer: number; months: number[] } | null): { employee: number; employer: number } {
  const r = rule ?? LWF_RULES.find((x) => x.stateCode === stateCode);
  return r && r.months.includes(month) ? { employee: r.employee, employer: r.employer } : { employee: 0, employer: 0 };
}
