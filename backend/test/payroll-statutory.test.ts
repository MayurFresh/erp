import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { computeLine } from '../src/lib/payroll/compute.ts';
import { ratesInForce, type RateRow } from '../src/lib/payroll/rates.ts';
import {
  bonusFor, encashment, fnfLines, gratuityFigures, gratuitySplit, monthlyWages, noticeAmount, overtimePay, serviceYears, wageRuleActive,
} from '../src/lib/payroll/statutory.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

describe('dated rates', () => {
  const company = (r: Partial<RateRow> & Pick<RateRow, 'kind' | 'effectiveFrom' | 'config'>): RateRow => ({ stateCode: null, source: 'company', ...r });
  it('picks the EPF ceiling in force for the month', () => {
    expect(ratesInForce([], '2026-08-01', null).epf.ceiling).toBe(15000);
    expect(ratesInForce([], '2026-10-01', null).epf.ceiling).toBe(25000);
    expect(ratesInForce([], '2026-10-01', null).esi.ceiling).toBe(21000);
  });
  it('company rows apply from their date; the same date as a built-in row, the company wins', () => {
    const rows = [
      company({ kind: 'epf', effectiveFrom: '2026-01-01', config: { ceiling: 21000, epsCeiling: 21000 } }),
      company({ kind: 'epf', effectiveFrom: '2026-09-17', config: { ceiling: 22000, epsCeiling: 22000 } }),
      company({ kind: 'epf', effectiveFrom: '2027-04-01', config: { ceiling: 30000, epsCeiling: 30000 } }),
    ];
    expect(ratesInForce(rows, '2026-03-01', null).epf.ceiling).toBe(21000);
    expect(ratesInForce(rows, '2026-10-01', null).epf.ceiling).toBe(22000);
    expect(ratesInForce(rows, '2027-05-01', null).epf.ceiling).toBe(30000);
  });
  it('PT and LWF rows are per state', () => {
    const pt = company({ kind: 'pt', stateCode: '27', effectiveFrom: '2027-04-01', config: { periodicity: 'monthly', slabs: [{ from: 0, to: null, amount: 250 }] } });
    expect(ratesInForce([pt], '2026-10-01', '27').pt!.slabs.length).toBeGreaterThan(1);
    expect(ratesInForce([pt], '2027-05-01', '27').pt!.slabs).toEqual([{ from: 0, to: null, amount: 250 }]);
    expect(ratesInForce([pt], '2027-05-01', '29').pt!.slabs.length).toBe(2);
    expect(ratesInForce([], '2026-10-01', '99').pt).toBeNull();
  });
  it('the line uses the dated ceiling', () => {
    const rates = ratesInForce([company({ kind: 'epf', effectiveFrom: '2026-01-01', config: { ceiling: 20000, epsCeiling: 20000, epsBps: 833, edliBps: 50, adminBps: 50, adminMin: 500 } })], '2026-08-01', '27');
    const r = computeLine({ ...lineBase, rates });
    expect(r.pfEmployee).toBe(2400); // 12% of the 20,000 ceiling; the built-in 15,000 would give 1,800
    expect(computeLine({ ...lineBase }).pfEmployee).toBe(1800);
  });
});

const lineBase = {
  monthStart: '2026-08-01', joining: '2020-01-01', sex: 'M', lopDays: 0, divisor: 'calendar' as const, adjustments: [], overrides: [],
  settings: { pfEnabled: true, esiEnabled: true, lwfEnabled: false, ptEnabled: true, pfRate: 12 },
  employee: { pfApplicable: true, pfHigherWage: false, esiApplicable: true, esiCoveredUntil: null, taxRegime: 'new' as const, previousIncome: 0, previousTds: 0 },
  ptStateCode: '27', ytd: { taxable: 0, tds: 0, pt: 0, pfEmployee: 0 },
  components: [
    { componentId: 'b', code: 'BASIC', name: 'Basic', kind: 'earning' as const, amount: 25000, taxable: true, pfWage: true, esiWage: true, proRata: true },
    { componentId: 'h', code: 'HRA', name: 'HRA', kind: 'earning' as const, amount: 5000, taxable: true, pfWage: false, esiWage: true, proRata: true },
  ],
};

describe('Labour Code wages rule', () => {
  const wl = (basic: number, other: number) => [{ code: 'BASIC', amount: basic, isBasic: true }, { code: 'SPECIAL', amount: other, isBasic: false }];
  it('adds back what the exclusions take above half of pay', () => {
    expect(monthlyWages(wl(15000, 25000), { active: true, percent: 50 })).toMatchObject({ base: 15000, remuneration: 40000, wages: 20000, addback: 5000 });
    expect(monthlyWages(wl(20000, 20000), { active: true, percent: 50 })).toMatchObject({ wages: 20000, addback: 0 });
    expect(monthlyWages(wl(15000, 25000), { active: false, percent: 50 })).toMatchObject({ wages: 15000, addback: 0 });
  });
  it('rule is active from its date only when enabled', () => {
    expect(wageRuleActive({ enabled: true, from: '2025-11-21' }, '2025-11-20')).toBe(false);
    expect(wageRuleActive({ enabled: true, from: '2025-11-21' }, '2026-01-01')).toBe(true);
    expect(wageRuleActive({ enabled: false, from: '2025-11-21' }, '2026-01-01')).toBe(false);
  });
  it('raises the PF wage in the line', () => {
    const comps = [{ ...lineBase.components[0]!, amount: 10000 }, { ...lineBase.components[1]!, amount: 30000 }];
    const off = computeLine({ ...lineBase, components: comps });
    expect(off.pfWage).toBe(10000);
    expect(off.pfEmployee).toBe(1200);
    const on = computeLine({ ...lineBase, components: comps, wageRule: { active: true, percent: 50 } });
    expect(on.pfWage).toBe(20000); // half of 40,000
    expect(on.wageRuleAddback).toBe(10000);
    expect(on.pfEmployee).toBe(1800); // capped at the 15,000 ceiling for August 2026
  });
});

describe('gratuity', () => {
  it('counts a part year over six months as a year', () => {
    expect(serviceYears('2020-01-01', '2026-07-01')).toEqual({ completed: 6, counted: 6 });
    expect(serviceYears('2020-01-01', '2026-07-02')).toEqual({ completed: 6, counted: 7 });
    expect(serviceYears('2020-01-01', '2025-12-31')).toEqual({ completed: 5, counted: 6 });
    expect(serviceYears('2024-01-01', '2023-01-01')).toEqual({ completed: 0, counted: 0 });
  });
  const rules = { years: 5, fixedTermYears: 1, cap: 2000000 };
  it('15/26 x wages x counted years', () => {
    const g = gratuityFigures({ joining: '2020-01-01', asOf: '2026-07-02', wages: 30000, fixedTerm: false, rules });
    expect(g).toMatchObject({ eligible: true, countedYears: 7, accrued: 121154, payable: 121154, taxFree: 121154, taxable: 0 }); // 30000 x 15 x 7 / 26
  });
  it('needs five completed years, or one for fixed-term staff', () => {
    expect(gratuityFigures({ joining: '2022-06-01', asOf: '2026-12-31', wages: 30000, fixedTerm: false, rules })).toMatchObject({ completedYears: 4, eligible: false, payable: 0 });
    expect(gratuityFigures({ joining: '2025-06-01', asOf: '2026-06-01', wages: 30000, fixedTerm: true, rules })).toMatchObject({ completedYears: 1, eligible: true, payable: 17308 }); // 30000x15x1/26
  });
  it('only the part above the cap is taxable', () => {
    expect(gratuitySplit(3461538, 2000000)).toEqual({ taxFree: 2000000, taxable: 1461538 });
    expect(gratuityFigures({ joining: '1990-01-01', asOf: '2020-01-01', wages: 200000, fixedTerm: false, rules })).toMatchObject({ countedYears: 30, payable: 3461538, taxable: 1461538 });
  });
});

describe('statutory bonus', () => {
  const rules = { pct: 8.33, eligibilityCeiling: 21000, calcCeiling: 7000, minimumWage: 0, minDays: 30 };
  it('uses the 7,000 calculation ceiling', () => {
    expect(bonusFor({ monthlyWage: 15000, monthsPaid: 12, daysWorked: 312, rules })).toMatchObject({ eligible: true, calcWage: 7000, amount: 6997 }); // 7000 x 12 x 8.33%
  });
  it('uses the minimum wage when higher', () => {
    expect(bonusFor({ monthlyWage: 15000, monthsPaid: 12, daysWorked: 312, rules: { ...rules, minimumWage: 9000 } }).amount).toBe(8996);
  });
  it('maximum rate and a wage below the ceiling', () => {
    expect(bonusFor({ monthlyWage: 15000, monthsPaid: 12, daysWorked: 312, rules: { ...rules, pct: 20 } }).amount).toBe(16800);
    expect(bonusFor({ monthlyWage: 5000, monthsPaid: 12, daysWorked: 312, rules }).amount).toBe(4998);
  });
  it('is not paid above 21,000 or under 30 days', () => {
    expect(bonusFor({ monthlyWage: 21001, monthsPaid: 12, daysWorked: 312, rules })).toMatchObject({ eligible: false, amount: 0 });
    expect(bonusFor({ monthlyWage: 21000, monthsPaid: 12, daysWorked: 312, rules }).eligible).toBe(true);
    expect(bonusFor({ monthlyWage: 10000, monthsPaid: 0.6, daysWorked: 20, rules }).eligible).toBe(false);
  });
});

describe('leave encashment, overtime, notice', () => {
  it('encashes up to the maximum at wages / 30', () => {
    expect(encashment({ balance: 12, maxDays: 10, wages: 30000 })).toMatchObject({ days: 10, amount: 10000 });
    expect(encashment({ balance: 4, maxDays: 10, wages: 30000 })).toMatchObject({ days: 4, amount: 4000 });
    expect(encashment({ balance: 7.5, maxDays: 10, wages: 26000 }).amount).toBe(6500);
    expect(encashment({ balance: 5, maxDays: 0, wages: 26000 }).amount).toBe(0);
  });
  it('overtime pays twice the hourly rate', () => {
    expect(overtimePay({ wages: 26000, divisorDays: 26, hoursPerDay: 8, hours: 5, multiplier: 2 })).toBe(1250);
    expect(overtimePay({ wages: 26000, divisorDays: 30, hoursPerDay: 8, hours: 5, multiplier: 2 })).toBe(1083);
    expect(overtimePay({ wages: 26000, divisorDays: 30, hoursPerDay: 8, hours: 0, multiplier: 2 })).toBe(0);
  });
  it('notice shortfall is days x monthly gross / 30', () => {
    expect(noticeAmount({ required: 30, served: 20, mode: 'recover', monthlyGross: 45000 })).toEqual({ shortDays: 10, amount: 15000 });
    expect(noticeAmount({ required: 30, served: 30, mode: 'recover', monthlyGross: 45000 }).amount).toBe(0);
    expect(noticeAmount({ required: 30, served: 20, mode: 'none', monthlyGross: 45000 }).amount).toBe(0);
  });
  it('full and final lines split the taxable part', () => {
    const lines = fnfLines({ gratuity: { payable: 2500000, cap: 2000000 }, leave: { amount: 100000, exempt: true, cap: 2500000 }, bonus: 583, notice: { mode: 'recover', amount: 15000 }, extra: [] });
    expect(lines).toEqual([
      { kind: 'earning', label: 'Gratuity', amount: 2000000, taxable: false },
      { kind: 'earning', label: 'Gratuity above the tax-free limit', amount: 500000, taxable: true },
      { kind: 'earning', label: 'Leave encashment', amount: 100000, taxable: false },
      { kind: 'earning', label: 'Statutory bonus (pro rata)', amount: 583, taxable: true },
      { kind: 'deduction', label: 'Notice period shortfall recovery', amount: 15000, taxable: false },
    ]);
  });
});

describe('statutory payroll through the API', () => {
  let env: TestEnv;
  beforeAll(async () => { env = await setupTestApp(); });
  afterAll(async () => { await teardown(env); });

  it('runs overtime, the wages rule, bonus, encashment, gratuity and a settlement', async () => {
    const su = await client(env.app)('POST', '/auth/signup', { businessName: 'Statutory Test', name: 'Owner', email: uniqueEmail('st'), password: 'Secret@123', stateCode: '27', businessType: 'pvt_ltd' });
    expect(su.status).toBe(201);
    const companyId = (await client(env.app, su.body.accessToken)('GET', '/me')).body.companies[0].id as string;
    const api = client(env.app, su.body.accessToken, companyId);
    const role = await api('POST', '/roles', { name: 'Approver', permissions: ['payroll.view', 'payroll.approve'] });
    const email = uniqueEmail('apr');
    expect((await api('POST', '/users', { name: 'Approver', email, password: 'Secret@123', roleId: role.body.id })).status).toBe(201);
    const apr = client(env.app, (await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' })).body.accessToken, companyId);

    const comps = (await api('GET', '/payroll/components')).body.data as { id: string; code: string }[];
    const cid = (code: string) => comps.find((c) => c.code === code)!.id;
    const mk = async (name: string, joiningDate: string, basic: number, special: number) => {
      const e = await api('POST', '/employees', { name, joiningDate, sex: 'M' });
      expect(e.status).toBe(201);
      expect((await api('POST', `/employees/${e.body.id}/salary`, { effectiveFrom: joiningDate, lines: [{ componentId: cid('BASIC'), amount: basic }, { componentId: cid('SPECIAL'), amount: special }] })).status).toBe(201);
      return e.body.id as string;
    };
    const F = await mk('Exit Person', '2018-04-01', 30000, 10000);
    const G = await mk('Shift Worker', '2024-04-01', 26000, 1000);
    const H = await mk('Low Basic', '2024-04-01', 10000, 30000);
    const J = await mk('Bonus Person', '2024-04-01', 12000, 2000);

    // settings
    expect((await api('PUT', '/payroll/statutory/settings', { bonusPct: 5 })).status).toBe(400);
    const st = await api('PUT', '/payroll/statutory/settings', { minimumWage: 0, bonusPct: 8.33 });
    expect(st.body).toMatchObject({ wagesRuleEnabled: false, gratuityCap: 2000000, bonusCalcCeiling: 7000 });
    // rates
    const rate = await api('POST', '/payroll/statutory/rates', { kind: 'esi', effectiveFrom: '2027-04-01', config: { ceiling: 25000 } });
    expect(rate.status).toBe(201);
    expect((await api('POST', '/payroll/statutory/rates', { kind: 'esi', effectiveFrom: '2027-04-01', config: { ceiling: 26000 } })).status).toBe(409);
    const rates = (await api('GET', '/payroll/statutory/rates?month=2027-05')).body;
    expect(rates.inForce.esi.ceiling).toBe(25000);
    expect((await api('GET', '/payroll/statutory/rates?month=2026-10')).body.inForce.epf.ceiling).toBe(25000);
    expect((await api('DELETE', `/payroll/statutory/rates/${rate.body.id}`)).status).toBe(200);

    // overtime
    const sh = await api('POST', '/payroll/shifts', { name: 'Day', startTime: '09:00', endTime: '18:00', breakMinutes: 60 });
    expect(sh.status).toBe(201);
    expect((await api('PUT', '/payroll/shift-log', { employeeId: G, entries: [{ day: '2026-10-05', shiftId: sh.body.id, otHours: 2 }, { day: '2026-10-06', shiftId: sh.body.id, otHours: 3 }] })).status).toBe(200);
    const run = (await api('POST', '/payroll/runs', { month: '2026-10' })).body;
    let r = (await api('POST', `/payroll/runs/${run.id}/compute`)).body;
    const lineOf = (code: string) => r.lines.find((l: any) => l.name === code);
    const ot = lineOf('Shift Worker').adjustments.find((a: any) => a.label === 'Overtime');
    expect(ot.amount).toBe(1048); // 26000 / 31 / 8 x 5 x 2
    expect(lineOf('Low Basic').pfEmployee).toBe(1200);

    // wages rule
    expect((await api('PUT', '/payroll/statutory/settings', { wagesRuleEnabled: true, wagesRuleFrom: '2025-11-21' })).status).toBe(200);
    r = (await api('POST', `/payroll/runs/${run.id}/compute`)).body;
    expect(lineOf('Low Basic').pfEmployee).toBe(2640); // 12% of 22,000 (half of 44,000)
    const wr = (await api('GET', `/payroll/runs/${run.id}/wage-rule`)).body;
    expect(wr.affected.map((a: any) => a.name)).toEqual(['Low Basic']);
    expect(wr.affected[0].addback).toBe(12000);
    expect((await api('PUT', '/payroll/statutory/settings', { wagesRuleEnabled: false })).status).toBe(200);

    // bonus
    const pv = (await api('GET', '/payroll/bonus/preview?fy=2026')).body;
    const jb = pv.data.find((d: any) => d.name === 'Bonus Person');
    expect(jb).toMatchObject({ eligible: true, calcWage: 7000, amount: 583 });
    expect(pv.data.find((d: any) => d.name === 'Exit Person')).toMatchObject({ eligible: false });
    const br = await api('POST', '/payroll/bonus/run', { fy: 2026, runId: run.id });
    expect(br.body.posted).toBeGreaterThan(0);
    expect((await api('POST', '/payroll/bonus/run', { fy: 2026, runId: run.id })).body.posted).toBe(0);
    r = (await api('GET', `/payroll/runs/${run.id}`)).body;
    expect(lineOf('Bonus Person').adjustments.some((a: any) => a.label.startsWith('Statutory bonus') && a.amount === 583)).toBe(true);

    // encashment
    const lts = (await api('GET', '/payroll/leave-encashment/types')).body.data as any[];
    const el = lts.find((t) => t.code === 'EL');
    expect((await api('PUT', `/payroll/leave-encashment/types/${el.leaveTypeId}`, { encashable: true, maxDays: 5 })).status).toBe(200);
    const lop = lts.find((t) => t.code === 'LOP');
    expect((await api('PUT', `/payroll/leave-encashment/types/${lop.leaveTypeId}`, { encashable: true, maxDays: 5 })).status).toBe(400);
    const ep = (await api('GET', '/payroll/leave-encashment/preview?fy=2026')).body;
    expect(ep.data.find((d: any) => d.name === 'Bonus Person')).toMatchObject({ days: 5, amount: 2000 }); // 12000 x 5 / 30
    const er = await api('POST', '/payroll/leave-encashment/run', { fy: 2026, runId: run.id });
    expect(er.body.employees).toBe(4);
    expect((await api('GET', '/payroll/leave-encashment/preview?fy=2026')).body.data).toHaveLength(0);

    // gratuity report
    const gr = (await api('GET', '/payroll/gratuity/report?month=2026-10')).body;
    const f = gr.data.find((d: any) => d.name === 'Exit Person');
    expect(f).toMatchObject({ wages: 30000, completedYears: 8, countedYears: 9, eligible: true, payable: 155769 }); // 30000 x 15 x 9 / 26
    expect(gr.data.find((d: any) => d.name === 'Low Basic').eligible).toBe(false);

    // full and final
    const body = { employeeId: F, exitDate: '2026-11-10', noticeRequiredDays: 30, noticeServedDays: 20, noticeMode: 'recover', extraLines: [{ kind: 'earning', label: 'Reimbursement', amount: 1000, taxable: false }] };
    const pre = await api('POST', '/payroll/fnf/preview', body);
    expect(pre.status).toBe(200);
    expect(pre.body.result.gratuity).toMatchObject({ payable: 155769, taxFree: 155769, taxable: 0 });
    expect(pre.body.result.notice).toMatchObject({ shortDays: 10, amount: 17333 }); // 52000 / 30 x 10
    expect(pre.body.result.line.earnings[0].amount).toBe(10000); // basic for 10 of 30 days
    expect(pre.body.net).toBe(Math.round((pre.body.gross - pre.body.deductions) * 100) / 100);
    const c = await api('POST', '/payroll/fnf', body);
    expect(c.status).toBe(201);
    expect((await api('POST', '/payroll/fnf', body)).status).toBe(409);
    expect((await api('POST', `/payroll/fnf/${c.body.id}/approve`)).status).toBe(403);
    const ap = await apr('POST', `/payroll/fnf/${c.body.id}/approve`);
    expect(ap.status).toBe(200);
    expect(ap.body.status).toBe('approved');
    const emp = (await api('GET', `/employees/${F}`)).body;
    expect(emp).toMatchObject({ status: 'left', leavingDate: '2026-11-10' });
    expect((await apr('POST', `/payroll/fnf/${c.body.id}/pay`, {})).body.status).toBe('paid');
    expect((await api('GET', `/payroll/fnf/${c.body.id}`)).body.company.name).toBeTruthy();
  });
});
