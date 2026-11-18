import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { foreclosureQuote } from '../src/modules/loans.ts';
import { capLoanDeductions } from '../src/lib/payroll/loan-cap.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

const PW = 'Secret@123';
let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

describe('pure rules', () => {
  it('quotes foreclosure interest to the date', () => {
    const open = [{ dueMonth: '2026-10-01', principal: 1880, interest: 120 }, { dueMonth: '2026-11-01', principal: 1900, interest: 100 }];
    expect(foreclosureQuote(open, '2026-10-16')).toEqual({ principal: 3780, interest: 61.94, total: 3841.94 });
    expect(foreclosureQuote(open, '2026-11-30')).toEqual({ principal: 3780, interest: 220, total: 4000 });
    expect(foreclosureQuote(open, '2026-09-30').interest).toBe(0);
  });
  it('cuts loan deductions from the last one', () => {
    const adj = [{ id: 'a', kind: 'deduction' as const, label: 'L1', amount: 3000, taxable: false }, { id: 'b', kind: 'deduction' as const, label: 'L2', amount: 2000, taxable: false }];
    const r = capLoanDeductions(adj, new Set(['a', 'b']), -2500);
    expect(r.adjustments.map((a) => a.amount)).toEqual([2500]);
    expect(r.cuts.map((c) => c.cut)).toEqual([2000, 500]);
    expect(capLoanDeductions(adj, new Set(['a']), 10).cuts).toEqual([]);
  });
});

describe('gratuity provision, loan cap and foreclosure through the API', () => {
  let owner: ReturnType<typeof client>, hr: ReturnType<typeof client>;
  let bank: string, basicId: string;
  const bal = async (name: string) => ((await owner('GET', '/accounts')).body.data as any[]).find((a) => a.name === name)?.balance ?? 0;
  const hire = async (name: string, joiningDate: string, basic: number) => {
    const e = await hr('POST', '/employees', { name, joiningDate, sex: 'M' });
    expect(e.status, JSON.stringify(e.body)).toBe(201);
    const s = await hr('POST', `/employees/${e.body.id}/salary`, { effectiveFrom: joiningDate, lines: [{ componentId: basicId, amount: basic }] });
    expect(s.status, JSON.stringify(s.body)).toBe(201);
    return e.body.id as string;
  };

  it('sets up the company', async () => {
    const res = await client(env.app)('POST', '/auth/signup', { businessName: 'Gratuity Co', name: 'Owner', email: uniqueEmail('gr'), password: PW, stateCode: '27', businessType: 'pvt_ltd' });
    expect(res.status).toBe(201);
    const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
    const companyId = me.companies[0].id as string;
    owner = client(env.app, res.body.accessToken, companyId);
    const roles = (await owner('GET', '/roles')).body.data as { id: string; name: string }[];
    const email = uniqueEmail('hr');
    expect((await owner('POST', '/users', { name: 'HR', email, password: PW, roleId: roles.find((r) => r.name === 'HR Manager')!.id })).status).toBe(201);
    hr = client(env.app, (await client(env.app)('POST', '/auth/login', { email, password: PW })).body.accessToken, companyId);
    bank = ((await owner('GET', '/accounts')).body.data as any[]).find((a) => a.subtype === 'bank').id;
    basicId = ((await hr('GET', '/payroll/components')).body.data as any[]).find((c) => c.code === 'BASIC').id;
  });

  it('provides for everyone, flags under five years and posts once per date', async () => {
    await hire('Anil Kumar', '2018-04-01', 30000);
    await hire('Bela Shah', '2025-01-01', 20000);
    const t = (await hr('GET', '/payroll/gratuity/provision?asOf=2026-10-31')).body;
    const a = t.data.find((r: any) => r.name === 'Anil Kumar'), b = t.data.find((r: any) => r.name === 'Bela Shah');
    expect(a).toMatchObject({ completedYears: 8, countedYears: 9, provision: 155769, underYears: false });
    expect(b).toMatchObject({ completedYears: 1, countedYears: 2, provision: 23077, underYears: true });
    expect(t.totals).toMatchObject({ provision: 178846, underYears: 23077, balance: 0, toPost: 178846 });
    expect((await hr('POST', '/payroll/gratuity/provision', { asOf: '2026-10-31' })).status).toBe(403); // payroll.approve needed
    const p = await owner('POST', '/payroll/gratuity/provision', { asOf: '2026-10-31' });
    expect(p.status, JSON.stringify(p.body)).toBe(201);
    expect(p.body).toMatchObject({ posted: 178846, priorBalance: 0, total: 178846 });
    expect((await owner('POST', '/payroll/gratuity/provision', { asOf: '2026-10-31' })).status).toBe(409);
    expect(await bal('Gratuity Payable')).toBeCloseTo(-178846, 2);
    expect(await bal('Gratuity Expense')).toBeCloseTo(178846, 2);
    const again = (await hr('GET', '/payroll/gratuity/provision?asOf=2026-10-31')).body;
    expect(again.totals.toPost).toBe(0);
    expect(again.posted).not.toBeNull();
  });

  it('posts only the change and respects the cap', async () => {
    expect((await owner('PUT', '/payroll/statutory/settings', { gratuityCap: 100000 })).status).toBe(200);
    const t = (await hr('GET', '/payroll/gratuity/provision?asOf=2026-11-15')).body;
    expect(t.data.find((r: any) => r.name === 'Anil Kumar')).toMatchObject({ provision: 100000, capped: true, formula: 155769 });
    const p = await owner('POST', '/payroll/gratuity/provision', { asOf: '2026-11-15' });
    expect(p.status, JSON.stringify(p.body)).toBe(201);
    expect(p.body.posted).toBe(-55769 + 0); // 123077 total less 178846 booked
    expect(await bal('Gratuity Payable')).toBeCloseTo(-123077, 2);
    expect(t.totals.changeSinceLast).toBe(-55769);
  });

  it('caps loan recovery at net pay and keeps the rest due', async () => {
    const empId = await hire('Chitra Rao', '2024-04-01', 10000);
    const loan = await hr('POST', '/loans', { employeeId: empId, kind: 'advance', purpose: 'Medical', amount: 30000, instalment: 20000, startMonth: '2026-10', accountId: bank });
    expect(loan.status, JSON.stringify(loan.body)).toBe(201);
    const run = (await hr('POST', '/payroll/runs', { month: '2026-10' })).body;
    const computed = (await hr('POST', `/payroll/runs/${run.id}/compute`)).body;
    const line = computed.lines.find((l: any) => l.employeeId === empId);
    expect(line.net, JSON.stringify(line)).toBe(0);
    expect(line.otherDeductionsTotal).toBeLessThan(20000);
    expect(line.warnings.some((w: string) => w.includes('stays due'))).toBe(true);
    expect((await owner('POST', `/payroll/runs/${run.id}/approve`)).status).toBe(200);
    const d = (await hr('GET', `/loans/${loan.body.id}`)).body;
    const first = d.schedule[0];
    expect(first.status).toBe('due');
    expect(first.paidAmount).toBeCloseTo(line.otherDeductionsTotal, 2);
    expect(first.paidAmount + first.amount).toBeCloseTo(20000, 2);
    expect(d.outstanding).toBeCloseTo(30000 - line.otherDeductionsTotal, 2);
    expect(d.recovered).toBeCloseTo(line.otherDeductionsTotal, 2);
    expect(await bal('Employee Loans and Advances')).toBeCloseTo(30000 - line.otherDeductionsTotal, 2);
  });

  it('forecloses with interest accrued to the date', async () => {
    const empId = await hire('Dev Patel', '2024-04-01', 50000);
    const loan = (await hr('POST', '/loans', { employeeId: empId, kind: 'loan', purpose: 'Bike', amount: 12000, instalment: 2000, interestRate: 12, startMonth: '2026-11', accountId: bank })).body;
    const q = await hr('GET', `/loans/${loan.id}/foreclosure?payDate=2026-11-15`);
    expect(q.status, JSON.stringify(q.body)).toBe(200);
    expect(q.body).toMatchObject({ principal: 12000, interest: 60 }); // 120 x 15/30
    const interestBefore = await bal('Interest on Employee Loans');
    const f = await hr('POST', `/loans/${loan.id}/foreclose`, { accountId: bank, payDate: '2026-11-15' });
    expect(f.status, JSON.stringify(f.body)).toBe(200);
    expect(f.body).toMatchObject({ status: 'foreclosed', foreclosePrincipal: 12000, forecloseInterest: 60, forecloseAmount: 12060 });
    expect(await bal('Interest on Employee Loans')).toBeCloseTo(interestBefore - 60, 2);
  });
});
