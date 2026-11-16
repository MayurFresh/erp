import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { buildSchedule } from '../src/modules/loans.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

const PW = 'Secret@123';
let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function biz() {
  const res = await client(env.app)('POST', '/auth/signup', { businessName: 'Claims Co', name: 'Owner', email: uniqueEmail('cl'), password: PW, stateCode: '27', businessType: 'pvt_ltd' });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const owner = client(env.app, res.body.accessToken, companyId);
  const roles = (await owner('GET', '/roles')).body.data as { id: string; name: string }[];
  const mk = async (permissions: string[] | null, roleName?: string) => {
    const roleId = roleName ? roles.find((r) => r.name === roleName)!.id : (await owner('POST', '/roles', { name: `R${Math.random()}`, permissions })).body.id;
    const email = uniqueEmail('u');
    const u = await owner('POST', '/users', { name: 'Staff', email, password: PW, roleId });
    expect(u.status, JSON.stringify(u.body)).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: PW });
    return { api: client(env.app, li.body.accessToken, companyId), userId: u.body.id as string };
  };
  return { owner, mk };
}

const MONTH = '2026-10';

describe('schedule', () => {
  it('builds a reducing balance schedule that sums to the principal', () => {
    const s = buildSchedule(12000, 12, 2000, '2026-10-01');
    expect(s.reduce((a, r) => a + r.principal, 0)).toBeCloseTo(12000, 2);
    expect(s[0]).toMatchObject({ interest: 120, principal: 1880, dueMonth: '2026-10-01' });
    expect(buildSchedule(6000, 0, 2000, '2026-10-01').map((r) => r.amount)).toEqual([2000, 2000, 2000]);
    expect(() => buildSchedule(100000, 24, 1000, '2026-10-01')).toThrow();
  });
});

describe('claims and loans through the API', () => {
  let b: Awaited<ReturnType<typeof biz>>;
  let emp: any, staff: Awaited<ReturnType<typeof b.mk>>, approver: Awaited<ReturnType<typeof b.mk>>, hr: Awaited<ReturnType<typeof b.mk>>;
  let bank: string;
  const bal = async (name: string) => ((await b.owner('GET', '/accounts')).body.data as any[]).find((a) => a.name === name)?.balance ?? 0;

  it('sets up an employee linked to a login', async () => {
    b = await biz();
    staff = await b.mk(['payroll.self']);
    approver = await b.mk(['claims.approve']);
    hr = await b.mk(null, 'HR Manager');
    const e = await hr.api('POST', '/employees', { name: 'Meera Rao', joiningDate: '2024-04-01', sex: 'F', userId: staff.userId });
    expect(e.status, JSON.stringify(e.body)).toBe(201);
    emp = e.body;
    const comps = (await hr.api('GET', '/payroll/components')).body.data as { id: string; code: string }[];
    const s = await hr.api('POST', `/employees/${emp.id}/salary`, { effectiveFrom: '2024-04-01', lines: [{ componentId: comps.find((c) => c.code === 'BASIC')!.id, amount: 30000 }] });
    expect(s.status, JSON.stringify(s.body)).toBe(201);
    const accs = (await b.owner('GET', '/accounts')).body.data as any[];
    bank = accs.find((a) => a.subtype === 'bank')!.id;
  });

  let cats: any[];
  it('creates default categories and enforces limits', async () => {
    cats = (await staff.api('GET', '/claims/categories')).body.data;
    expect(cats.length).toBeGreaterThan(3);
    expect((await staff.api('POST', '/claims/categories', { name: 'X' })).status).toBe(403);
    const travel = cats.find((c) => c.name === 'Travel');
    const p = await hr.api('PATCH', `/claims/categories/${travel.id}`, { perClaimLimit: 1000, monthlyLimit: 1500 });
    expect(p.status, JSON.stringify(p.body)).toBe(200);
    const line = (amount: number) => ({ categoryId: travel.id, expenseDate: '2026-10-05', description: 'Cab', amount });
    const over = await staff.api('POST', '/claims', { purpose: 'Client visit', lines: [line(1200)], submit: true });
    expect(over.status).toBe(400);
    const ok = await staff.api('POST', '/claims', { purpose: 'Client visit', lines: [line(900)], submit: true });
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(ok.body.status).toBe('submitted');
    const month = await staff.api('POST', '/claims', { purpose: 'Second', lines: [line(700)], submit: true });
    expect(month.status).toBe(400);
    await hr.api('PATCH', `/claims/categories/${travel.id}`, { perClaimLimit: null, monthlyLimit: null });
    await staff.api('DELETE', `/claims/${ok.body.id}`); // submitted, refused
    const rej = await approver.api('POST', `/claims/${ok.body.id}/reject`, { note: 'Not needed' });
    expect(rej.body.status).toBe('rejected');
  });

  it('refuses self approval and posts figures with GST', async () => {
    const stationery = cats.find((c) => c.name === 'Stationery'); // input credit allowed
    const meals = cats.find((c) => c.name === 'Meals');
    const mk = (submit = true) => staff.api('POST', '/claims', { purpose: 'Office items', submit, lines: [
      { categoryId: stationery.id, expenseDate: '2026-10-06', description: 'Paper', amount: 1180, gstAmount: 180, vendorGstin: '27AAAAA0000A1Z5' },
      { categoryId: meals.id, expenseDate: '2026-10-06', description: 'Lunch', amount: 500, gstAmount: 25, vendorGstin: '27AAAAA0000A1Z5' },
    ] });
    const c = (await mk()).body;
    expect(c.total).toBe(1680);
    expect(c.itcTotal).toBe(180);
    expect(c.lines[1].itcEligible).toBe(false);
    expect((await staff.api('POST', `/claims/${c.id}/approve`, {})).status).toBe(403);
    const both = await b.mk(['claims.approve', 'payroll.self']);
    expect((await both.api('POST', `/claims/${c.id}/approve`, {})).status).toBe(200);
    expect(await bal('Input CGST')).toBeCloseTo(90, 2);
    expect(await bal('Input SGST')).toBeCloseTo(90, 2);
    expect(await bal('Claims - Stationery')).toBeCloseTo(1000, 2);
    expect(await bal('Claims - Meals')).toBeCloseTo(500, 2);
    expect(await bal('Employee Reimbursements Payable')).toBeCloseTo(-1680, 2);
    expect((await approver.api('POST', `/claims/${c.id}/settle`, { mode: 'pay_now', accountId: bank })).status).toBe(403);
    const paid = await hr.api('POST', `/claims/${c.id}/settle`, { mode: 'pay_now', accountId: bank });
    expect(paid.body.status).toBe('paid');
    expect(await bal('Employee Reimbursements Payable')).toBeCloseTo(0, 2);
    // interstate GSTIN goes to IGST
    const d = (await staff.api('POST', '/claims', { purpose: 'Far vendor', submit: true, lines: [{ categoryId: stationery.id, expenseDate: '2026-10-07', description: 'Ink', amount: 118, gstAmount: 18, vendorGstin: '29AAAAA0000A1Z5' }] })).body;
    expect((await approver.api('POST', `/claims/${d.id}/approve`, { mode: 'payroll' })).status).toBe(403); // settling needs claims.manage
    expect((await approver.api('POST', `/claims/${d.id}/approve`, {})).status).toBe(200);
    expect(await bal('Input IGST')).toBeCloseTo(18, 2);
  });

  it('own claims only for staff, summary for managers', async () => {
    const mine = (await staff.api('GET', '/claims')).body;
    expect(mine.total).toBeGreaterThan(0);
    const other = await b.mk(['payroll.self']);
    expect((await other.api('GET', '/claims')).body.total).toBe(0);
    expect((await other.api('POST', '/claims', { purpose: 'No employee', lines: [{ categoryId: cats[0].id, expenseDate: '2026-10-01', description: 'x', amount: 10 }] })).status).toBe(400);
    const sum = await hr.api('GET', '/claims/summary?groupBy=category');
    expect(sum.status).toBe(200);
    expect(sum.body.data.length).toBeGreaterThan(0);
    expect((await staff.api('GET', '/claims/summary')).status).toBe(403);
  });

  it('pays a reimbursement and a loan EMI through payroll', async () => {
    const meals = cats.find((c) => c.name === 'Meals');
    const c = (await staff.api('POST', '/claims', { purpose: 'Team lunch', submit: true, lines: [{ categoryId: meals.id, expenseDate: '2026-10-08', description: 'Lunch', amount: 800 }] })).body;
    expect((await approver.api('POST', `/claims/${c.id}/approve`, {})).status).toBe(200);
    expect((await hr.api('POST', `/claims/${c.id}/settle`, { mode: 'payroll' })).status).toBe(200);

    const loan = await hr.api('POST', '/loans', { employeeId: emp.id, kind: 'loan', purpose: 'Bike', amount: 30000, instalment: 2000, interestRate: 12, startMonth: MONTH, accountId: bank });
    expect(loan.status, JSON.stringify(loan.body)).toBe(201);
    expect(loan.body.caReview).toBe(true);
    expect(loan.body.perquisiteNote).toContain('CA review');
    expect(await bal('Employee Loans and Advances')).toBeCloseTo(30000, 2);
    const detail = (await hr.api('GET', `/loans/${loan.body.id}`)).body;
    const first = detail.schedule[0];

    const run = (await hr.api('POST', '/payroll/runs', { month: MONTH })).body;
    const computed = (await hr.api('POST', `/payroll/runs/${run.id}/compute`)).body;
    const labels = computed.adjustments.map((a: any) => `${a.kind}:${a.label.split(' ')[0]}`);
    expect(labels).toContain('earning:Expense');
    expect(labels).toContain('deduction:Loan');
    const line = computed.lines.find((l: any) => l.employeeId === emp.id);
    expect(line.otherDeductionsTotal).toBe(first.amount);
    expect(computed.adjustments.find((a: any) => a.kind === 'earning')).toMatchObject({ amount: 800, taxable: false });

    expect((await b.owner('POST', `/payroll/runs/${run.id}/approve`)).status).toBe(200);
    const after = (await hr.api('GET', `/loans/${loan.body.id}`)).body;
    expect(after.schedule[0].status).toBe('recovered');
    expect(after.outstandingPrincipal).toBeCloseTo(30000 - first.principal, 2);
    expect((await hr.api('GET', `/claims/${c.id}`)).body.status).toBe('paid');
    expect(await bal('Employee Reimbursements Payable')).toBeCloseTo(-118, 2); // only the unsettled IGST claim is left
    expect(await bal('Interest on Employee Loans')).toBeCloseTo(-first.interest, 2);
    expect(await bal('Employee Loans and Advances')).toBeCloseTo(30000 - first.principal, 2);
    const all = ((await b.owner('GET', '/accounts')).body.data as any[]).reduce((s, a) => s + a.balance, 0);
    expect(all).toBeCloseTo(0, 2);

    const sum = (await staff.api('GET', `/employees/${emp.id}/loans`)).body;
    expect(sum.loans).toHaveLength(1);
    expect(sum.outstandingPrincipal).toBeCloseTo(30000 - first.principal, 2);
  });

  it('pauses, releases a cancelled run, and forecloses', async () => {
    const loan = (await hr.api('GET', '/loans?status=active')).body.data[0];
    expect((await hr.api('POST', `/loans/${loan.id}/pause`)).body.status).toBe('paused');
    const r1 = (await hr.api('POST', '/payroll/runs', { month: '2026-09' })).body;
    expect((await hr.api('GET', `/payroll/runs/${r1.id}`)).body.adjustments).toHaveLength(0);
    await hr.api('POST', `/payroll/runs/${r1.id}/cancel`);
    expect((await hr.api('POST', `/loans/${loan.id}/resume`)).body.status).toBe('active');
    const r2 = (await hr.api('POST', '/payroll/runs', { month: '2026-11' })).body;
    const d2 = (await hr.api('GET', `/payroll/runs/${r2.id}`)).body;
    expect(d2.adjustments).toHaveLength(1);
    expect((await hr.api('POST', `/loans/${loan.id}/foreclose`, { accountId: bank })).status).toBe(409);
    await hr.api('POST', `/payroll/runs/${r2.id}/cancel`);
    const f = await hr.api('POST', `/loans/${loan.id}/foreclose`, { accountId: bank });
    expect(f.status, JSON.stringify(f.body)).toBe(200);
    expect(f.body.status).toBe('foreclosed');
    expect(f.body.outstanding).toBe(0);
    expect(await bal('Employee Loans and Advances')).toBeCloseTo(0, 2);
    expect((await hr.api('GET', `/employees/${emp.id}/loans`)).body.loans).toHaveLength(0);
  });

  it('keeps loans from staff without the permission', async () => {
    expect((await staff.api('POST', '/loans', { employeeId: emp.id, kind: 'advance', purpose: 'x', amount: 1000, instalment: 500, startMonth: MONTH })).status).toBe(403);
    expect((await approver.api('GET', '/loans')).status).toBe(403);
  });
});
