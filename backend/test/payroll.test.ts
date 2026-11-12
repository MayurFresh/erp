import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { computeLine } from '../src/lib/payroll/compute.ts';
import { computeEpf, pfCeiling } from '../src/lib/payroll/epf.ts';
import { computeEsi, esiPeriodEnd } from '../src/lib/payroll/esi.ts';
import { countLeaveDays } from '../src/lib/payroll/leave.ts';
import { computeLwf, computePt } from '../src/lib/payroll/pt.ts';
import { prorate } from '../src/lib/payroll/proration.ts';
import { splitCtc, type ComponentDef } from '../src/lib/payroll/structure.ts';
import { monthlyTds } from '../src/lib/payroll/tds.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

describe('provident fund', () => {
  it('caps the wage at the ceiling', () => {
    const r = computeEpf({ pfWage: 30000, ceiling: 15000 });
    expect(r).toMatchObject({ employee: 1800, employerTotal: 1800, eps: 1250, epfEmployer: 550, edli: 75, admin: 75 });
  });
  it('contributes on the full wage when opted higher, with pension still capped', () => {
    const r = computeEpf({ pfWage: 30000, ceiling: 15000, optHigher: true });
    expect(r).toMatchObject({ employee: 3600, employerTotal: 3600, eps: 1250, epfEmployer: 2350 });
  });
  it('under the ceiling uses the wage; no pension share when not eligible', () => {
    expect(computeEpf({ pfWage: 10000, ceiling: 15000 })).toMatchObject({ employee: 1200, eps: 833, epfEmployer: 367 });
    expect(computeEpf({ pfWage: 10000, ceiling: 15000, epsEligible: false })).toMatchObject({ eps: 0, epfEmployer: 1200 });
  });
  it('picks the ceiling by month', () => {
    expect(pfCeiling('2026-08-01')).toBe(15000);
    expect(pfCeiling('2026-10-01')).toBe(25000);
  });
});

describe('ESI', () => {
  it('rounds both shares up', () => {
    expect(computeEsi({ esiWage: 19737, monthStart: '2026-10-01', coveredUntil: null, paidDays: 26 })).toMatchObject({ covered: true, employee: 149, employer: 642 });
    expect(computeEsi({ esiWage: 21000, monthStart: '2026-10-01', coveredUntil: null, paidDays: 26 })).toMatchObject({ employee: 158, employer: 683 });
  });
  it('is not covered above the limit', () => {
    expect(computeEsi({ esiWage: 21001, monthStart: '2026-10-01', coveredUntil: null, paidDays: 26 })).toMatchObject({ covered: false, employee: 0, employer: 0 });
  });
  it('stays covered to the end of the period, then is reassessed', () => {
    expect(computeEsi({ esiWage: 23000, monthStart: '2026-08-01', coveredUntil: '2026-09-30', paidDays: 26 })).toMatchObject({ covered: true, employee: 173, employer: 748 });
    expect(computeEsi({ esiWage: 23000, monthStart: '2026-10-01', coveredUntil: '2026-09-30', paidDays: 26 }).covered).toBe(false);
    expect(esiPeriodEnd('2026-08-01')).toBe('2026-09-30');
    expect(esiPeriodEnd('2026-11-01')).toBe('2027-03-31');
    expect(esiPeriodEnd('2027-01-01')).toBe('2027-03-31');
  });
  it('charges no employee share at a very low daily wage', () => {
    expect(computeEsi({ esiWage: 4000, monthStart: '2026-10-01', coveredUntil: null, paidDays: 26 })).toMatchObject({ employee: 0, employer: 130 });
  });
});

describe('professional tax', () => {
  const pt = (stateCode: string, monthlyGross: number, month: number, sex = 'M') => computePt({ stateCode, monthlyGross, month, sex }).amount;
  it('Maharashtra: slabs, women, and the February rule', () => {
    expect(pt('27', 7000, 10)).toBe(0);
    expect(pt('27', 8000, 10)).toBe(175);
    expect(pt('27', 20000, 10)).toBe(200);
    expect(pt('27', 20000, 2)).toBe(300);
    expect(pt('27', 8000, 2)).toBe(175);
    expect(pt('27', 20000, 10, 'F')).toBe(0);
    expect(pt('27', 30000, 2, 'F')).toBe(300);
    // A year of a 200 slab adds to 2,500.
    expect([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12].reduce((s, m) => s + pt('27', 20000, m), 0)).toBe(2500);
  });
  it('Karnataka, West Bengal, Telangana, Andhra Pradesh and Gujarat', () => {
    expect(pt('29', 24999, 10)).toBe(0);
    expect(pt('29', 30000, 10)).toBe(200);
    expect(pt('29', 30000, 2)).toBe(300);
    expect(pt('19', 12000, 10)).toBe(110);
    expect(pt('19', 45000, 10)).toBe(200);
    expect(pt('36', 18000, 10)).toBe(150);
    expect(pt('37', 25000, 10)).toBe(200);
    expect(pt('24', 11999, 10)).toBe(0);
    expect(pt('24', 12000, 10)).toBe(200);
  });
  it('Tamil Nadu is half-yearly, deducted in September and March', () => {
    expect(pt('33', 20000, 9)).toBe(1250);
    expect(pt('33', 20000, 10)).toBe(0);
    expect(pt('33', 4000, 3)).toBe(135);
  });
  it('states without a table pay nothing; LWF applies only in its months', () => {
    expect(pt('07', 90000, 10)).toBe(0);
    expect(computeLwf('27', 6)).toEqual({ employee: 25, employer: 75 });
    expect(computeLwf('27', 7)).toEqual({ employee: 0, employer: 0 });
  });
});

describe('days and pro-rata', () => {
  it('LOP by each divisor', () => {
    expect(prorate({ monthStart: '2026-10-01', joining: '2020-01-01', lopDays: 2, divisor: 'calendar' }).fraction).toBeCloseTo(29 / 31, 5);
    expect(prorate({ monthStart: '2026-10-01', joining: '2020-01-01', lopDays: 2, divisor: '30' }).fraction).toBeCloseTo(28 / 30, 5);
    expect(prorate({ monthStart: '2026-10-01', joining: '2020-01-01', lopDays: 2, divisor: '26' }).fraction).toBeCloseTo(1 - 2 / 26, 5);
  });
  it('mid-month joining and leaving', () => {
    expect(prorate({ monthStart: '2026-10-01', joining: '2026-10-11', lopDays: 0, divisor: 'calendar' })).toMatchObject({ serviceDays: 21 });
    expect(prorate({ monthStart: '2026-10-01', joining: '2026-10-11', lopDays: 0, divisor: 'calendar' }).fraction).toBeCloseTo(21 / 31, 5);
    expect(prorate({ monthStart: '2026-11-01', joining: '2020-01-01', leaving: '2026-11-15', lopDays: 0, divisor: 'calendar' }).fraction).toBeCloseTo(0.5, 5);
    expect(prorate({ monthStart: '2026-11-01', joining: '2026-12-01', lopDays: 0, divisor: 'calendar' }).fraction).toBe(0);
  });
  it('counts leave days without weekly offs and holidays', () => {
    const hol = new Set(['2026-10-08']);
    expect(countLeaveDays({ from: '2026-10-05', to: '2026-10-11', holidays: hol })).toBe(5);
    expect(countLeaveDays({ from: '2026-10-05', to: '2026-10-05', halfDay: true, holidays: hol })).toBe(0.5);
    expect(countLeaveDays({ from: '2026-10-11', to: '2026-10-11', holidays: hol })).toBe(0);
  });
});

describe('TDS on salary', () => {
  it('projects the year on the new regime and spreads the tax', () => {
    const m = 17_29_368 / 12;
    const r = monthlyTds({ regime: 'new', taxYear: '2026-27', month: 4, ytdTaxable: 0, thisMonthTaxable: m, recurringTaxable: m, tdsDeductedSoFar: 0 });
    expect(r.working.taxable).toBeCloseTo(16_54_368, 0);
    expect(r.working.annualTax).toBe(136110);
    expect(r.tds).toBe(11343);
  });
  it('is nil under the rebate', () => {
    const m = 8_46_684 / 12;
    expect(monthlyTds({ regime: 'new', taxYear: '2026-27', month: 4, ytdTaxable: 0, thisMonthTaxable: m, recurringTaxable: m, tdsDeductedSoFar: 0 }).tds).toBe(0);
  });
  it('gives marginal relief just above the rebate limit', () => {
    const m = 12_85_000 / 12;
    const r = monthlyTds({ regime: 'new', taxYear: '2026-27', month: 4, ytdTaxable: 0, thisMonthTaxable: m, recurringTaxable: m, tdsDeductedSoFar: 0 });
    expect(r.working.annualTax).toBe(10400);
  });
  it('the last month takes what is left', () => {
    const m = 17_29_368 / 12;
    const r = monthlyTds({ regime: 'new', taxYear: '2026-27', month: 3, ytdTaxable: m * 11, thisMonthTaxable: m, recurringTaxable: m, tdsDeductedSoFar: 11343 * 11 });
    expect(r.tds).toBe(136110 - 11343 * 11);
  });
});

describe('structure and the line calculation', () => {
  const defs: ComponentDef[] = [
    { id: 'b', code: 'BASIC', name: 'Basic', kind: 'earning', calc: 'fixed', percent: null, isBasic: true },
    { id: 'h', code: 'HRA', name: 'HRA', kind: 'earning', calc: 'pct_basic', percent: 40, isBasic: false },
    { id: 's', code: 'SPECIAL', name: 'Special', kind: 'earning', calc: 'fixed', percent: null, isBasic: false },
  ];
  it('splits a CTC with the balance in the special allowance', () => {
    const a = splitCtc(defs, 600000, 50);
    expect(a.b).toBe(25000);
    expect(a.h).toBe(10000);
    expect(a.b! + a.h! + a.s!).toBe(50000);
  });

  const base = {
    monthStart: '2026-10-01', joining: '2020-01-01', sex: 'M', lopDays: 0, divisor: 'calendar' as const, adjustments: [], overrides: [],
    settings: { pfEnabled: true, esiEnabled: true, lwfEnabled: false, ptEnabled: true, pfRate: 12 },
    employee: { pfApplicable: true, pfHigherWage: false, esiApplicable: true, esiCoveredUntil: null, taxRegime: 'new' as const, previousIncome: 0, previousTds: 0 },
    ptStateCode: '27', ytd: { taxable: 0, tds: 0, pt: 0, pfEmployee: 0 },
    components: [
      { componentId: 'b', code: 'BASIC', name: 'Basic', kind: 'earning' as const, amount: 20000, taxable: true, pfWage: true, esiWage: true, proRata: true },
      { componentId: 'h', code: 'HRA', name: 'HRA', kind: 'earning' as const, amount: 8000, taxable: true, pfWage: false, esiWage: true, proRata: true },
    ],
  };
  it('reduces pay for LOP', () => {
    const r = computeLine({ ...base, lopDays: 2 });
    expect(r.earnings.map((e) => e.amount)).toEqual([18710, 7484]);
    expect(r.gross).toBe(26194);
  });
  it('pays a mid-month joiner for the days in service', () => {
    const r = computeLine({ ...base, joining: '2026-10-11' });
    expect(r.earnings[0]!.amount).toBe(Math.floor(20000 * 21 / 31 + 0.5));
    expect(r.paidDays).toBe(21);
  });
  it('net equals gross less deductions and an override needs to be applied after the calculation', () => {
    const r = computeLine(base);
    expect(r.pfEmployee).toBe(2400);
    expect(r.pt).toBe(200);
    expect(r.esiEmployee).toBe(0); // gross 28000 is above the ESI limit
    expect(r.net).toBe(28000 - 2400 - 200);
    const o = computeLine({ ...base, overrides: [{ field: 'pt', value: 0, reason: 'Exempt' }] });
    expect(o.pt).toBe(0);
    expect(o.net).toBe(28000 - 2400);
  });
  it('adds one-time earnings and deductions', () => {
    const r = computeLine({ ...base, adjustments: [{ kind: 'earning', label: 'Bonus', amount: 5000, taxable: true }, { kind: 'deduction', label: 'Advance recovery', amount: 1000, taxable: false }] });
    expect(r.gross).toBe(33000);
    expect(r.net).toBe(33000 - 2400 - 200 - 1000);
  });
});

// API ---------------------------------------------------------------------------------------------

describe('payroll through the API', () => {
  let env: TestEnv;
  beforeAll(async () => { env = await setupTestApp(); });
  afterAll(async () => { await teardown(env); });

  async function biz() {
    const res = await client(env.app)('POST', '/auth/signup', { businessName: 'Payroll Test', name: 'Owner', email: uniqueEmail('pr'), password: 'Secret@123', stateCode: '27', businessType: 'pvt_ltd' });
    expect(res.status).toBe(201);
    const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
    const companyId = me.companies[0].id as string;
    const api = client(env.app, res.body.accessToken, companyId);
    const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
    const mkUser = async (roleId: string, label: string) => {
      const email = uniqueEmail(label);
      const u = await api('POST', '/users', { name: label, email, password: 'Secret@123', roleId });
      expect(u.status).toBe(201);
      const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
      return { api: client(env.app, li.body.accessToken, companyId), userId: u.body.id as string };
    };
    const asRole = (name: string) => mkUser(roles.find((r) => r.name === name)!.id, name.replace(/\W/g, ''));
    const customRole = async (name: string, permissions: string[]) => {
      const r = await api('POST', '/roles', { name, permissions });
      expect(r.status).toBe(201);
      return mkUser(r.body.id, name.replace(/\W/g, ''));
    };
    const raw = (url: string) => env.app.inject({ method: 'GET', url: `/api/v1${url}`, headers: { authorization: `Bearer ${res.body.accessToken}`, 'x-company-id': companyId } });
    const accounts = async () => (await api('GET', '/accounts')).body.data as { code: string; name: string; balance: number }[];
    return { api, asRole, customRole, accounts, raw };
  }

  const MONTH = '2026-10';
  let ctx: Awaited<ReturnType<typeof biz>>;
  let hr: Awaited<ReturnType<typeof biz>>['api'];
  let empA: any, empB: any, run: any;

  it('HR Manager role has the payroll permissions but cannot approve', async () => {
    ctx = await biz();
    const h = await ctx.asRole('HR Manager');
    hr = h.api;
    expect((await hr('GET', '/payroll/components')).status).toBe(200);
    expect((await hr('POST', '/payroll/runs/00000000-0000-0000-0000-000000000001/approve')).status).toBe(403);
  });

  it('creates employees with generated codes and masks the Aadhaar', async () => {
    const a = await hr('POST', '/employees', { name: 'Asha Patil', joiningDate: '2024-04-01', sex: 'F', pan: 'ABCDE1234F', aadhaar: '123456789012', uan: '100200300400', bankAccount: '556677889900', bankIfsc: 'HDFC0001234', bankName: 'HDFC Bank', department: 'Finance' });
    expect(a.status).toBe(201);
    expect(a.body.code).toBe('E0001');
    expect(a.body.aadhaarMasked).toBe('XXXX XXXX 9012');
    expect(JSON.stringify(a.body)).not.toContain('123456789012');
    empA = a.body;
    const b = await hr('POST', '/employees', { name: 'Ravi Kumar', joiningDate: '2024-04-01', sex: 'M', esiNumber: '1234567890', department: 'Stores' });
    expect(b.body.code).toBe('E0002');
    empB = b.body;
    expect((await hr('POST', '/employees', { name: 'Bad', joiningDate: '2024-04-01', pan: 'nope' })).status).toBe(400);
  });

  it('keeps salary revisions as history', async () => {
    const lines = async (basic: number) => {
      const comps = (await hr('GET', '/payroll/components')).body.data as { id: string; code: string }[];
      return [{ componentId: comps.find((c) => c.code === 'BASIC')!.id, amount: basic }, { componentId: comps.find((c) => c.code === 'SPECIAL')!.id, amount: 10000 }];
    };
    expect((await hr('POST', `/employees/${empA.id}/salary`, { effectiveFrom: '2024-04-01', lines: await lines(15000) })).status).toBe(201);
    const rev = await hr('POST', `/employees/${empA.id}/salary`, { effectiveFrom: '2026-04-01', lines: await lines(20000) });
    expect(rev.status).toBe(201);
    expect(rev.body.monthlyGross).toBe(20000 + 8000 + 10000); // HRA is 40% of basic
    expect((await hr('POST', `/employees/${empA.id}/salary`, { effectiveFrom: '2026-04-01', lines: await lines(21000) })).status).toBe(409);
    const hist = (await hr('GET', `/employees/${empA.id}/salary`)).body;
    expect(hist.total).toBe(2);
    expect(hist.data[0].effectiveFrom).toBe('2026-04-01');
    // B: ESI applies, gross 18000
    const comps = (await hr('GET', '/payroll/components')).body.data as { id: string; code: string }[];
    const rb = await hr('POST', `/employees/${empB.id}/salary`, { effectiveFrom: '2024-04-01', lines: [{ componentId: comps.find((c) => c.code === 'BASIC')!.id, amount: 12000 }, { componentId: comps.find((c) => c.code === 'SPECIAL')!.id, amount: 1000 }] });
    expect(rb.body.monthlyGross).toBe(12000 + 4800 + 1000);
  });

  it('computes a run with the statutory figures', async () => {
    const c = await hr('POST', '/payroll/runs', { month: MONTH });
    expect(c.status).toBe(201);
    run = c.body;
    const r = (await hr('POST', `/payroll/runs/${run.id}/compute`)).body;
    expect(r.status).toBe('computed');
    const a = r.lines.find((l: any) => l.code === 'E0001');
    const b = r.lines.find((l: any) => l.code === 'E0002');
    expect(a.gross).toBe(38000);
    expect(a.pfEmployee).toBe(2400); // PF wage is the basic only, 20,000
    expect(a.esiEmployee).toBe(0); // above the ESI limit
    expect(a.pt).toBe(200); // a woman above 25,000 pays the 200 slab
    expect(a.net).toBe(38000 - 2400 - 200);
    expect(a.tds).toBe(0);
    expect(b.gross).toBe(17800);
    expect(b.pfEmployee).toBe(1440);
    expect(b.esiEmployee).toBe(134);
    expect(b.esiEmployer).toBe(579);
    expect(b.pt).toBe(200);
    expect(r.gross).toBe(55800);
    expect(r.net).toBe(a.net + b.net);
  });

  it('applies LOP from approved unpaid leave, and attendance entered by hand', async () => {
    const put = await hr('PUT', '/attendance-summaries', { month: `${MONTH}-01`.slice(0, 7), rows: [{ employeeId: empB.id, presentDays: 29, lopDays: 2 }] });
    expect(put.status).toBe(200);
    const r = (await hr('POST', `/payroll/runs/${run.id}/compute`)).body;
    const b = r.lines.find((l: any) => l.code === 'E0002');
    expect(b.lopDays).toBe(2);
    expect(b.paidDays).toBe(29);
    expect(b.gross).toBe(Math.floor(12000 * 29 / 31 + 0.5) + Math.floor(4800 * 29 / 31 + 0.5) + Math.floor(1000 * 29 / 31 + 0.5));
  });

  it('daily register rewrites month totals and feeds the run', async () => {
    const d = (n: number) => `${MONTH}-${String(n).padStart(2, '0')}`;
    const put = await hr('PUT', '/attendance-days', { month: MONTH, rows: [{ employeeId: empB.id, days: [
      { day: d(1), status: 'present' }, { day: d(2), status: 'absent' }, { day: d(3), status: 'absent' }, { day: d(4), status: 'leave' }, { day: d(5), status: 'week_off' } ] }] });
    expect(put.status).toBe(200);
    expect(put.body.data).toHaveLength(5);
    const sums = (await hr('GET', `/attendance-summaries?month=${MONTH}`)).body.data.find((x: any) => x.employeeId === empB.id);
    expect(sums).toMatchObject({ presentDays: 1, paidLeaveDays: 1, lopDays: 2, source: 'register' });
    expect((await hr('PUT', '/attendance-days', { month: MONTH, rows: [{ employeeId: empB.id, days: [{ day: '2020-01-01', status: 'present' }] }] })).status).toBe(400);
    const b = (await hr('POST', `/payroll/runs/${run.id}/compute`)).body.lines.find((l: any) => l.code === 'E0002');
    expect(b.lopDays).toBe(2);
  });

  it('needs a reason for an override and keeps it through a recompute', async () => {
    expect((await hr('POST', `/payroll/runs/${run.id}/overrides`, { employeeId: empB.id, field: 'pt', value: 0, reason: '' })).status).toBe(400);
    const o = await hr('POST', `/payroll/runs/${run.id}/overrides`, { employeeId: empB.id, field: 'pt', value: 0, reason: 'Exempt by order' });
    expect(o.status).toBe(201);
    let b = o.body.lines.find((l: any) => l.code === 'E0002');
    expect(b.pt).toBe(0);
    expect(b.overrides[0]).toMatchObject({ field: 'pt', reason: 'Exempt by order' });
    b = (await hr('POST', `/payroll/runs/${run.id}/compute`)).body.lines.find((l: any) => l.code === 'E0002');
    expect(b.pt).toBe(0);
    const del = await hr('DELETE', `/payroll/runs/${run.id}/overrides/${empB.id}/pt`);
    expect(del.body.lines.find((l: any) => l.code === 'E0002').pt).toBe(200);
  });

  it('adds a bonus and an advance recovery for one run', async () => {
    const bonus = await hr('POST', `/payroll/runs/${run.id}/adjustments`, { employeeId: empA.id, kind: 'earning', label: 'Diwali bonus', amount: 5000 });
    expect(bonus.status).toBe(201);
    const rec = await hr('POST', `/payroll/runs/${run.id}/adjustments`, { employeeId: empA.id, kind: 'deduction', label: 'Advance recovery', amount: 1000 });
    const a = rec.body.lines.find((l: any) => l.code === 'E0001');
    expect(a.gross).toBe(43000);
    expect(a.otherDeductionsTotal).toBe(1000);
    expect(a.net).toBe(43000 - 2400 - 200 - 1000 - a.tds);
    // Drop the bonus again so later figures are simple.
    for (const adj of rec.body.adjustments) await hr('DELETE', `/payroll/runs/${run.id}/adjustments/${adj.id}`);
  });

  it('the maker cannot approve their own run', async () => {
    const owner = ctx.api;
    const mine = await owner('POST', '/payroll/runs', { month: '2026-09' });
    expect(mine.status).toBe(201);
    await owner('POST', `/payroll/runs/${mine.body.id}/compute`);
    const res = await owner('POST', `/payroll/runs/${mine.body.id}/approve`);
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('SELF_APPROVAL');
    await owner('POST', `/payroll/runs/${mine.body.id}/cancel`);
  });

  it('approves, posts a balanced journal and pays out', async () => {
    const before = (await hr('GET', `/payroll/runs/${run.id}`)).body;
    const ok = await ctx.api('POST', `/payroll/runs/${run.id}/approve`);
    expect(ok.status).toBe(200);
    expect(ok.body.status).toBe('approved');
    expect(ok.body.accrualEntryId).toBeTruthy();
    const acc = await ctx.accounts();
    const bal = (name: string) => acc.find((a) => a.name === name)?.balance ?? 0;
    expect(bal('Net Salary Payable')).toBeCloseTo(-before.net, 2);
    const lineSum = (k: string) => before.lines.reduce((s: number, l: any) => s + l[k], 0);
    expect(bal('PF Payable')).toBeCloseTo(-(lineSum('pfEmployee') + lineSum('pfEps') + lineSum('pfEpfEmployer') + lineSum('pfEdli') + lineSum('pfAdmin')), 2);
    expect(bal('ESI Payable')).toBeCloseTo(-(lineSum('esiEmployee') + lineSum('esiEmployer')), 2);
    expect(bal('Professional Tax Payable')).toBeCloseTo(-lineSum('pt'), 2);
    // Every debit and credit across the books must match.
    expect(acc.reduce((s, a) => s + a.balance, 0)).toBeCloseTo(0, 2);
    // Approved runs are locked.
    expect((await hr('POST', `/payroll/runs/${run.id}/compute`)).status).toBe(409);
    expect((await ctx.api('POST', `/payroll/runs/${run.id}/pay`, {})).status).toBe(200);
    const after = await ctx.accounts();
    expect(after.find((a) => a.name === 'Net Salary Payable')?.balance).toBeCloseTo(0, 2);
    expect((await ctx.api('GET', `/payroll/runs/${run.id}`)).body.status).toBe('posted');
  });

  it('refuses to run a month again once it has a run', async () => {
    const again = await hr('POST', '/payroll/runs', { month: MONTH });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('RUN_EXISTS');
  });

  it('payslip figures match the run', async () => {
    const list = (await ctx.api('GET', `/payroll/payslips?employeeId=${empA.id}`)).body;
    expect(list.total).toBe(1);
    const slip = (await ctx.api('GET', `/payroll/payslips/${list.data[0].id}`)).body;
    const line = (await ctx.api('GET', `/payroll/runs/${run.id}`)).body.lines.find((l: any) => l.code === 'E0001');
    expect(slip.net).toBe(line.net);
    expect(slip.gross).toBe(line.gross);
    expect(slip.earnings.reduce((s: number, e: any) => s + e.amount, 0)).toBe(line.gross);
    expect(slip.deductions.reduce((s: number, d: any) => s + d.amount, 0)).toBeCloseTo(slip.totalDeductions, 2);
    expect(slip.gross - slip.totalDeductions).toBeCloseTo(slip.net, 2);
    expect(slip.employee.bankAccount).toBe('XXXXXXXX9900');
    expect(slip.ytd.net).toBe(slip.net);
  });

  it('builds the statutory files', async () => {
    const st = (await ctx.api('GET', `/payroll/runs/${run.id}/statutory`)).body;
    expect(st.pf.members).toBe(2);
    expect(st.pf.admin).toBe(500); // the establishment minimum
    expect(st.pt[0]).toMatchObject({ stateCode: '27', employees: 2, amount: 400 });
    // Ravi has no UAN and no bank details.
    const ecr = await ctx.api('GET', `/payroll/runs/${run.id}/files/ecr`);
    expect(ecr.status).toBe(409);
    const bank = await ctx.api('GET', `/payroll/runs/${run.id}/files/bank`);
    expect(bank.status).toBe(409);
    expect((await ctx.api('PATCH', `/employees/${empB.id}`, { uan: '100200300411', bankAccount: '9988776655', bankIfsc: 'SBIN0001234', bankName: 'SBI' })).status).toBe(200);
  });

  it('sends the files as text', async () => {
    const res = await ctx.raw(`/payroll/runs/${run.id}/files/ecr`);
    expect(res.statusCode).toBe(200);
    expect(res.body).toContain('#~#');
    expect(res.body.split('\n').filter(Boolean)).toHaveLength(2);
    const bank = await ctx.raw(`/payroll/runs/${run.id}/files/bank`);
    expect(bank.body).toContain('Employee code,Name,Account number,IFSC');
    expect((await ctx.raw(`/payroll/runs/${run.id}/files/esi`)).statusCode).toBe(200);
    expect((await ctx.raw(`/payroll/runs/${run.id}/files/pt`)).body).toContain('Maharashtra');
  });

  it('leave: apply, approve, balance, own leave and shortfalls', async () => {
    const self = await ctx.customRole('Staff self', ['payroll.self', 'dashboard.view']);
    expect((await hr('PATCH', `/employees/${empA.id}`, { userId: self.userId })).status).toBe(200);
    const types = (await self.api('GET', '/leave-types')).body.data as { id: string; code: string }[];
    const cl = types.find((t) => t.code === 'CL')!;
    const apply = await self.api('POST', '/leave-applications', { leaveTypeId: cl.id, fromDate: '2026-11-16', toDate: '2026-11-17', reason: 'Family event' });
    expect(apply.status).toBe(201);
    expect(apply.body.days).toBe(2);
    expect(apply.body.status).toBe('pending');
    // Cannot decide own, cannot approve without permission.
    expect((await self.api('POST', `/leave-applications/${apply.body.id}/approve`)).status).toBe(403);
    // Overlap and shortfall.
    expect((await self.api('POST', '/leave-applications', { leaveTypeId: cl.id, fromDate: '2026-11-17', toDate: '2026-11-18' })).status).toBe(409);
    const big = await self.api('POST', '/leave-applications', { leaveTypeId: cl.id, fromDate: '2026-12-01', toDate: '2026-12-31' });
    expect(big.status).toBe(409);
    expect(big.body.error.code).toBe('INSUFFICIENT_LEAVE');
    const ok = await hr('POST', `/leave-applications/${apply.body.id}/approve`, {});
    expect(ok.status).toBe(200);
    expect(ok.body.status).toBe('approved');
    const bal = (await self.api('GET', `/employees/${empA.id}/leave-balances?fy=2026`)).body.data.find((b: any) => b.code === 'CL');
    expect(bal).toMatchObject({ quota: 8, taken: 2, balance: 6 });
    // An approved unpaid leave becomes loss of pay in the next run.
    const lop = types.find((t) => t.code === 'LOP')!;
    expect((await self.api('POST', '/leave-applications', { leaveTypeId: lop.id, fromDate: '2026-11-02', toDate: '2026-11-03' })).status).toBe(201);
    const mine = (await self.api('GET', '/leave-applications')).body;
    expect(mine.total).toBe(2);
  });

  it('self service sees only own payslips', async () => {
    const self = await ctx.customRole('Staff own', ['payroll.self']);
    expect((await self.api('GET', '/payroll/payslips')).body.total).toBe(0); // not linked yet
    await hr('PATCH', `/employees/${empB.id}`, { userId: self.userId });
    const mine = (await self.api('GET', '/payroll/payslips')).body;
    expect(mine.total).toBe(1);
    expect(mine.data[0].employeeId).toBe(empB.id);
    const all = (await ctx.api('GET', `/payroll/payslips?employeeId=${empA.id}`)).body.data[0];
    expect((await self.api('GET', `/payroll/payslips/${all.id}`)).status).toBe(404);
    expect((await self.api('GET', `/payroll/payslips/${mine.data[0].id}`)).status).toBe(200);
    expect((await self.api('GET', '/payroll/runs')).status).toBe(403);
    expect((await self.api('GET', '/employees')).status).toBe(403);
    expect((await self.api('GET', `/employees/${empA.id}/salary`)).status).toBe(403);
    expect((await self.api('GET', `/employees/${empB.id}/salary`)).status).toBe(200);
  });

  it('hides pay from people without payroll.view and denies others', async () => {
    const clerk = await ctx.customRole('People only', ['payroll.employees']);
    const list = (await clerk.api('GET', '/employees')).body;
    expect(list.total).toBe(2);
    expect(list.data[0]).not.toHaveProperty('monthlyGross');
    expect((await clerk.api('GET', '/payroll/runs')).status).toBe(403);
    expect((await clerk.api('POST', '/payroll/runs', { month: '2026-08' })).status).toBe(403);
    const withPay = (await hr('GET', '/employees')).body;
    expect(withPay.data.find((e: any) => e.code === 'E0001').monthlyGross).toBe(38000);
    const nobody = await ctx.customRole('No payroll', ['dashboard.view']);
    expect((await nobody.api('GET', '/employees')).status).toBe(403);
    expect((await nobody.api('GET', '/hr/summary')).status).toBe(403);
    expect((await nobody.api('GET', '/leave-types')).status).toBe(403);
  });

  it('the HR home summarises people and the month', async () => {
    const s = (await hr('GET', '/hr/summary')).body;
    expect(s.headCount).toBe(2);
    expect(s.pendingLeave).toBeGreaterThanOrEqual(1);
  });
});
