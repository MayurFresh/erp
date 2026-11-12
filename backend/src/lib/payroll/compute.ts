// One employee's payroll line for one month, as a pure function. NEEDS A CA CHECK: verify current rates before real filing.
// Order: paid days, earnings, adjustments, PF, ESI, PT, LWF, other deductions, TDS, net.
import { computeEpf, pfCeiling } from './epf.ts';
import { computeEsi } from './esi.ts';
import { roundRupee, round2 } from './money.ts';
import { computeLwf, computePt } from './pt.ts';
import { prorate, type LopDivisor } from './proration.ts';
import { monthIndex, monthlyTds } from './tds.ts';

export interface EarningInput {
  componentId: string; code: string; name: string; kind: 'earning' | 'deduction'; amount: number;
  taxable: boolean; pfWage: boolean; esiWage: boolean; proRata: boolean;
}
export interface AdjustmentInput { id?: string; kind: 'earning' | 'deduction'; label: string; amount: number; taxable: boolean; reason?: string | null }
export type OverrideField = 'lop_days' | 'pf_employee' | 'esi_employee' | 'pt' | 'lwf_employee' | 'tds';
export interface OverrideInput { field: OverrideField; value: number; reason: string }

export interface LineInput {
  monthStart: string;
  joining: string; leaving?: string | null;
  sex?: string | null;
  lopDays: number;
  divisor: LopDivisor;
  components: EarningInput[];
  adjustments: AdjustmentInput[];
  overrides: OverrideInput[];
  settings: { pfEnabled: boolean; esiEnabled: boolean; lwfEnabled: boolean; ptEnabled: boolean; pfRate: number };
  employee: {
    pfApplicable: boolean; pfHigherWage: boolean; esiApplicable: boolean; esiCoveredUntil: string | null;
    taxRegime: 'new' | 'old'; previousIncome: number; previousTds: number;
  };
  ptStateCode: string | null;
  /** Taxable pay and TDS from earlier live lines of the same tax year. */
  ytd: { taxable: number; tds: number; pt: number; pfEmployee: number };
}

export interface LineResult {
  workingDays: number; paidDays: number; lopDays: number;
  earnings: { componentId: string; code: string; name: string; amount: number; full: number; taxable: boolean }[];
  adjustments: AdjustmentInput[];
  otherDeductions: { label: string; amount: number }[];
  gross: number; taxableGross: number; pfWage: number; esiWage: number;
  pfEmployee: number; pfEps: number; pfEpfEmployer: number; pfEdli: number; pfAdmin: number;
  esiEmployee: number; esiEmployer: number; esiCoveredUntil: string | null;
  pt: number; lwfEmployee: number; lwfEmployer: number; tds: number; tdsWorking: unknown;
  otherDedTotal: number; net: number; employerCost: number;
  overrides: OverrideInput[]; warnings: string[];
}

const ov = (list: OverrideInput[], f: OverrideField) => list.find((o) => o.field === f);

export function computeLine(i: LineInput): LineResult {
  const warnings: string[] = [];
  const month = Number(i.monthStart.slice(5, 7));
  const lopOv = ov(i.overrides, 'lop_days');
  const lopDays = lopOv ? lopOv.value : i.lopDays;
  const pr = prorate({ monthStart: i.monthStart, joining: i.joining, leaving: i.leaving, lopDays, divisor: i.divisor });

  // Earnings, pro-rated for days not paid.
  const earnings = i.components.filter((c) => c.kind === 'earning').map((c) => ({
    componentId: c.componentId, code: c.code, name: c.name, taxable: c.taxable, full: c.amount,
    amount: c.proRata ? roundRupee(c.amount * pr.fraction) : c.amount,
  }));
  const adjEarn = i.adjustments.filter((a) => a.kind === 'earning');
  const adjDed = i.adjustments.filter((a) => a.kind === 'deduction');
  const flag = (id: string, key: 'pfWage' | 'esiWage') => i.components.find((c) => c.componentId === id)![key];
  const sumOf = (pick: (e: (typeof earnings)[number]) => boolean) => earnings.filter(pick).reduce((s, e) => s + e.amount, 0);
  const earnTotal = sumOf(() => true);
  const adjTotal = adjEarn.reduce((s, a) => s + a.amount, 0);
  const gross = round2(earnTotal + adjTotal);
  const taxableGross = round2(sumOf((e) => e.taxable) + adjEarn.filter((a) => a.taxable).reduce((s, a) => s + a.amount, 0));
  const pfWage = sumOf((e) => flag(e.componentId, 'pfWage'));
  const esiWage = sumOf((e) => flag(e.componentId, 'esiWage'));

  // PF
  let pfEmployee = 0, pfEps = 0, pfEpfEmployer = 0, pfEdli = 0, pfAdmin = 0;
  if (i.settings.pfEnabled && i.employee.pfApplicable && pfWage > 0) {
    const ceiling = pfCeiling(i.monthStart);
    const e = computeEpf({ pfWage, ceiling, optHigher: i.employee.pfHigherWage, ratePct: i.settings.pfRate });
    pfEmployee = e.employee; pfEps = e.eps; pfEpfEmployer = e.epfEmployer; pfEdli = e.edli; pfAdmin = e.admin;
  }
  // ESI
  let esiEmployee = 0, esiEmployer = 0, esiCoveredUntil = i.employee.esiCoveredUntil;
  if (i.settings.esiEnabled && i.employee.esiApplicable) {
    const e = computeEsi({ esiWage, monthStart: i.monthStart, coveredUntil: i.employee.esiCoveredUntil, paidDays: pr.paidDays || 1 });
    esiEmployee = e.employee; esiEmployer = e.employer; esiCoveredUntil = e.coveredUntil ?? i.employee.esiCoveredUntil;
  }
  // PT and LWF follow the work state.
  const pt = i.settings.ptEnabled ? computePt({ stateCode: i.ptStateCode, monthlyGross: gross, month, sex: i.sex }).amount : 0;
  const lwf = i.settings.lwfEnabled ? computeLwf(i.ptStateCode, month) : { employee: 0, employer: 0 };

  let ptF = pt, lwfEmp = lwf.employee;
  const o = { pf: ov(i.overrides, 'pf_employee'), esi: ov(i.overrides, 'esi_employee'), pt: ov(i.overrides, 'pt'), lwf: ov(i.overrides, 'lwf_employee') };
  if (o.pf) pfEmployee = o.pf.value;
  if (o.esi) esiEmployee = o.esi.value;
  if (o.pt) ptF = o.pt.value;
  if (o.lwf) lwfEmp = o.lwf.value;

  // Recurring deduction components and one-time deductions.
  const otherDeductions = [
    ...i.components.filter((c) => c.kind === 'deduction' && c.amount > 0).map((c) => ({ label: c.name, amount: c.amount })),
    ...adjDed.map((a) => ({ label: a.label, amount: a.amount })),
  ];
  const otherDedTotal = round2(otherDeductions.reduce((s, d) => s + d.amount, 0));

  // TDS last, because the other figures change taxable pay under the old regime.
  const taxYear = (month >= 4 ? Number(i.monthStart.slice(0, 4)) : Number(i.monthStart.slice(0, 4)) - 1);
  const fy = `${taxYear}-${String((taxYear + 1) % 100).padStart(2, '0')}`;
  const leaveMonths = i.leaving && i.leaving.slice(0, 7) >= i.monthStart.slice(0, 7)
    ? Math.min(12, ((Number(i.leaving.slice(5, 7)) - month + 12) % 12) + 1) : undefined;
  const recurringTaxable = i.components.filter((c) => c.kind === 'earning' && c.taxable).reduce((s, c) => s + c.amount, 0);
  const left = leaveMonths ?? 12 - monthIndex(month);
  const tdsCalc = monthlyTds({
    regime: i.employee.taxRegime, taxYear: fy, month, ytdTaxable: i.ytd.taxable, thisMonthTaxable: taxableGross, recurringTaxable,
    previousIncome: i.employee.previousIncome, previousTds: i.employee.previousTds, tdsDeductedSoFar: i.ytd.tds, monthsLeft: leaveMonths,
    employeePfYear: i.ytd.pfEmployee + pfEmployee * left, ptYear: i.ytd.pt + ptF * left,
  });
  let tds = tdsCalc.tds;
  const tdsOv = ov(i.overrides, 'tds');
  if (tdsOv) tds = tdsOv.value;

  const deductionsBeforeTds = pfEmployee + esiEmployee + ptF + lwfEmp + otherDedTotal;
  if (!tdsOv && tds > Math.max(0, gross - deductionsBeforeTds)) {
    tds = Math.max(0, gross - deductionsBeforeTds);
    warnings.push('TDS was limited to the pay left after other deductions.');
  }
  const net = round2(gross - deductionsBeforeTds - tds);
  if (net < 0) warnings.push('Net pay is below zero.');
  if (gross > 0 && (deductionsBeforeTds + tds) / gross > 0.5) warnings.push('Deductions are more than half of gross pay.');
  if (pr.serviceDays === 0) warnings.push('Not in service this month.');

  const employerCost = round2(gross + pfEps + pfEpfEmployer + pfEdli + pfAdmin + esiEmployer + lwf.employer);
  return {
    workingDays: pr.divisorDays, paidDays: pr.paidDays, lopDays, earnings, adjustments: i.adjustments, otherDeductions,
    gross, taxableGross, pfWage, esiWage, pfEmployee, pfEps, pfEpfEmployer, pfEdli, pfAdmin,
    esiEmployee, esiEmployer, esiCoveredUntil, pt: ptF, lwfEmployee: lwfEmp, lwfEmployer: lwf.employer, tds, tdsWorking: tdsCalc.working,
    otherDedTotal, net, employerCost, overrides: i.overrides, warnings,
  };
}
