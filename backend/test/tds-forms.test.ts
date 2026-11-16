import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import pg from 'pg';
import { withDatabase } from '../src/db/migrate.ts';
import { formNamesFor, formNamesOn, lateDeductionInterest, lateDepositInterest, lateFilingFee, panValid, partB, periodLabel } from '../src/lib/tds-forms.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

describe('dated form names and figures (pure)', () => {
  it('uses old names before 1 April 2026 and new ones from that date', () => {
    expect(formNamesOn('2026-03-31')).toMatchObject({ salaryReturn: '24Q', nonSalaryReturn: '26Q', salaryCertificate: 'Form 16', nonSalaryCertificate: 'Form 16A' });
    expect(formNamesOn('2026-04-01')).toMatchObject({ salaryReturn: '138', nonSalaryReturn: '140', salaryCertificate: 'Form 130', nonSalaryCertificate: 'Form 131', unconfirmed: true });
    expect(formNamesFor('2025-26').act).toBe('1961');
    expect(periodLabel('2025-26')).toBe('Assessment year 2026-27');
    expect(periodLabel('2026-27')).toBe('Tax year 2026-27');
  });
  it('computes interest and the late fee', () => {
    // 10 May to 20 June is one month and a part month: 2 months at 1.5%
    expect(lateDepositInterest(10_000, '2026-05-10', '2026-06-07', '2026-06-20')).toEqual({ months: 2, interest: 300 });
    expect(lateDepositInterest(10_000, '2026-05-10', '2026-06-07', '2026-06-07')).toEqual({ months: 0, interest: 0 });
    expect(lateDeductionInterest(10_000, '2026-05-10', '2026-06-10')).toBe(100);
    expect(lateDeductionInterest(10_000, '2026-05-10', '2026-06-11')).toBe(200);
    expect(lateFilingFee(10, 10_000)).toBe(2000);
    expect(lateFilingFee(400, 10_000)).toBe(10_000);
  });
  it('checks PAN format', () => {
    expect(panValid('ABCDE1234F')).toBe(true);
    expect(panValid('ABCDE12345')).toBe(false);
    expect(panValid('abcde1234f')).toBe(false);
    expect(panValid(null)).toBe(false);
  });
  it('Form 16 Part B on a hand-checked salary: 18 lakh, new regime', () => {
    // 18,00,000 - 75,000 = 17,25,000. Slabs: 4-8L 5% = 20,000; 8-12L 10% = 40,000; 12-16L 15% = 60,000; 16-17.25L 20% = 25,000 -> 1,45,000. Cess 4% = 5,800. Total 1,50,800.
    const b = partB({ fy: '2026-27', regime: 'new', grossSalary: 1_800_000, taxableSalary: 1_800_000, previousIncome: 0, previousTds: 0, employeePf: 0, professionalTax: 0, tdsThisEmployer: 150_800 });
    expect(b).toMatchObject({ standardDeduction: 75_000, totalIncome: 1_725_000, taxOnIncome: 145_000, rebate: 0, cess: 5_800, netTaxPayable: 150_800, balance: 0 });
  });
  it('gives nil tax up to the rebate limit', () => {
    const b = partB({ fy: '2026-27', regime: 'new', grossSalary: 1_200_000, taxableSalary: 1_200_000, previousIncome: 0, previousTds: 0, employeePf: 0, professionalTax: 0, tdsThisEmployer: 0 });
    expect(b.totalIncome).toBe(1_125_000);
    expect(b.netTaxPayable).toBe(0);
  });
});

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function owner<T>(fn: (c: pg.Client) => Promise<T>): Promise<T> {
  const c = new pg.Client({ connectionString: withDatabase(process.env.DATABASE_ADMIN_URL!, new URL(process.env.TEST_DATABASE_URL!).pathname.slice(1)) });
  await c.connect();
  try { return await fn(c); } finally { await c.end(); }
}

/** Raw GET for CSV bodies: the shared client parses JSON only. */
async function raw(b: { token: string; companyId: string }, url: string) {
  const res = await env.app.inject({ method: 'GET', url: `/api/v1${url}`, headers: { authorization: `Bearer ${b.token}`, 'x-company-id': b.companyId } });
  return { status: res.statusCode, text: res.body };
}

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', { businessName: 'Forms Test', name: 'Owner', email: uniqueEmail('tf'), password: 'Secret@123', stateCode: '27', businessType: 'pvt_ltd' });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  expect((await api('PATCH', '/company', { tan: 'MUMP12345E', pan: 'AAACF1234C' })).status).toBe(200);
  return { api, companyId, token: res.body.accessToken as string };
}

describe('section map', () => {
  it('shows the old reference before 1 April 2026 and the new one after, and lets a company edit a row', async () => {
    const { api } = await business();
    const before = (await api('GET', '/tds/section-map?date=2026-03-31')).body;
    const after = (await api('GET', '/tds/section-map?date=2026-04-01')).body;
    const row = (b: any) => b.data.find((r: any) => r.oldCode === '194J(b)');
    expect(row(before).reference).toBe('s.194J(b)');
    expect(row(after).reference).toBe('s.393(1) Sl. 6(iii)');
    expect(row(after).confirmed).toBe(false);
    expect(after.forms.nonSalaryReturn).toBe('140');
    const edited = await api('PATCH', `/tds/section-map/${row(after).id}`, { newSection: 's.393(1) Sl. 6(iii) (checked)', confirmed: true });
    expect(edited.status).toBe(200);
    expect(edited.body).toMatchObject({ confirmed: true, system: false });
    const again = (await api('GET', '/tds/section-map?date=2026-04-01')).body;
    expect(row(again)).toMatchObject({ reference: 's.393(1) Sl. 6(iii) (checked)', system: false });
    expect(again.data.filter((r: any) => r.oldCode === '194J(b)')).toHaveLength(1);
  });
  it('updates the rent threshold to a yearly 6 lakh', async () => {
    const { api } = await business();
    const s = (await api('GET', '/tds-sections')).body.data.find((x: any) => x.code === '194I(b)');
    expect(s.thresholdAggregate).toBe(600000);
  });
});

describe('Form 16 / 130 and the salary return', () => {
  it('builds Part A and Part B from payroll and files Q4 annual details', async () => {
    const biz = await business();
    const { api, companyId } = biz;
    const emp = (await api('POST', '/employees', { name: 'Asha Patil', joiningDate: '2024-04-01', sex: 'F', pan: 'ABCDE1234F' })).body;
    expect(emp.id).toBeTruthy();
    const tdsOf = (i: number) => (i === 11 ? 12_563 : 12_567);
    await owner(async (c) => {
      const t = (await c.query('select tenant_id from companies where id=$1', [companyId])).rows[0].tenant_id;
      for (let i = 0; i < 12; i++) {
        const d = new Date(Date.UTC(2026, 3 + i, 1)).toISOString().slice(0, 10);
        const run = (await c.query(`insert into payroll_runs (tenant_id, company_id, number, month, status) values ($1,$2,$3,$4,'posted') returning id`, [t, companyId, `PR-${i}`, d])).rows[0].id;
        await c.query(`insert into payroll_lines (tenant_id, run_id, company_id, employee_id, month, working_days, paid_days, gross, taxable_gross, tds, net)
          values ($1,$2,$3,$4,$5,30,30,150000,150000,$6,137433)`, [t, run, companyId, emp.id, d, tdsOf(i)]);
      }
    });
    const f = await api('GET', `/tds/form16?fy=2026-27&employeeId=${emp.id}`);
    expect(f.status).toBe(200);
    expect(f.body.form).toBe('Form 130');
    expect(f.body.periodLabel).toBe('Tax year 2026-27');
    expect(f.body.partB).toMatchObject({ grossSalary: 1_800_000, totalIncome: 1_725_000, taxOnIncome: 145_000, cess: 5_800, netTaxPayable: 150_800, tdsTotal: 150_800, balance: 0 });
    expect(f.body.partA.quarters.map((q: any) => q.deducted)).toEqual([37_701, 37_701, 37_701, 37_697]);
    expect(f.body.partA.totalDeposited).toBe(0);
    expect(f.body.warnings.join(' ')).toContain('no salary challan');

    // challan amount must equal the payroll TDS of the month
    expect((await api('POST', '/tds/salary-challans', { month: '2026-04', depositDate: '2026-05-05', bsrCode: '0510308', challanSerial: '00123', amount: 100 })).status).toBe(400);
    expect((await api('POST', '/tds/salary-challans', { month: '2026-04', depositDate: '2026-05-05', bsrCode: '0510308', challanSerial: '00123', amount: 12_567 })).status).toBe(201);
    expect((await api('POST', '/tds/salary-challans', { month: '2026-04', depositDate: '2026-05-05', bsrCode: '0510308', challanSerial: '00124', amount: 12_567 })).status).toBe(409);
    const f2 = (await api('GET', `/tds/form16?fy=2026-27&employeeId=${emp.id}`)).body;
    expect(f2.partA.quarters[0].deposited).toBe(12_567);
    expect(f2.partA.deposits[0]).toMatchObject({ month: '2026-04', bsrCode: '0510308', challanSerial: '00123', tds: 12_567 });

    const q1 = (await api('GET', '/tds/returns?fy=2026-27&quarter=1&kind=salary&today=2026-08-10')).body;
    expect(q1.form).toBe('138');
    expect(q1.totalTds).toBe(37_701);
    expect(q1.checks.find((c: any) => c.id === 'challan_link').status).toBe('fail');
    expect(q1.lateFee).toMatchObject({ daysLate: 10, lateFee: 2000 });
    expect(q1.deductees[0].annual).toBeNull();
    const q4 = (await api('GET', '/tds/returns?fy=2026-27&quarter=4&kind=salary&today=2027-04-01')).body;
    expect(q4.deductees[0].annual.netTaxPayable).toBe(150_800);
    const csv = await raw(biz, '/tds/returns?fy=2026-27&quarter=4&kind=salary&format=csv');
    expect(csv.status).toBe(200);
    expect(csv.text).toContain('ANNUAL');

    const gen = await api('POST', '/tds/certificates/generate', { kind: 'salary', fy: '2026-27' });
    expect(gen.status).toBe(201);
    expect(gen.body.count).toBe(1);
    expect(gen.body.data[0].number).toBe('SAL/2026-27/0001');
    const regen = await api('POST', '/tds/certificates/generate', { kind: 'salary', fy: '2026-27', employeeId: emp.id });
    expect(regen.body.data[0].number).toBe('SAL/2026-27/0001');
    expect((await api('GET', '/tds/certificates?kind=salary&fy=2026-27')).body.data).toHaveLength(1);
  });
});

describe('Form 16A / 131 and the 26Q / 140 return', () => {
  it('builds a certificate per deductee and quarter and reports interest, fee and PAN problems', async () => {
    const biz = await business();
    const { api, companyId } = biz;
    const mk = async (name: string, pan: string | null) => (await api('POST', '/parties', { type: 'vendor', name, stateCode: '27', ...(pan ? { pan } : {}) })).body;
    const good = await mk('Sharma Associates', 'ABCDE1234F');
    const nopan = await mk('No Pan Co', null);
    const ids: string[] = [];
    await owner(async (c) => {
      const t = (await c.query('select tenant_id from companies where id=$1', [companyId])).rows[0].tenant_id;
      const add = async (party: string, pan: string | null, date: string, fy: string, no: string, amount: number) => {
        const r = await c.query(`insert into tds_deductions (tenant_id, company_id, source_type, source_id, number, party_id, pan, section_code, fy, deduction_date, gross, base, rate, amount)
          values ($1,$2,'purchase',gen_random_uuid(),$3,$4,$5,'194J(b)',$6,$7,$8,$8,10,$9) returning id`, [t, companyId, no, party, pan, fy, date, amount * 10, amount]);
        ids.push(r.rows[0].id);
      };
      await add(good.id, 'ABCDE1234F', '2026-05-10', '2026-27', 'P1', 10_000);
      await add(nopan.id, null, '2026-05-12', '2026-27', 'P2', 500);
      await add(good.id, 'ABCDE1234F', '2026-03-10', '2025-26', 'P0', 2_000);
    });
    const bank = await owner(async (c) => (await c.query(`select id from accounts where company_id=$1 and subtype in ('bank','cash') limit 1`, [companyId])).rows[0].id as string);
    const ch = await api('POST', '/tds/challans', { depositDate: '2026-06-20', bsrCode: '0510308', challanSerial: '00456', paidFromAccountId: bank, deductionIds: [ids[0]] });
    expect(ch.status).toBe(201);

    const a = (await api('GET', `/tds/form16a?fy=2026-27&quarter=1&partyId=${good.id}`)).body.data;
    expect(a).toHaveLength(1);
    expect(a[0].form).toBe('Form 131');
    expect(a[0]).toMatchObject({ totalDeducted: 10_000, totalDeposited: 10_000 });
    expect(a[0].rows[0].section).toBe('s.393(1) Sl. 6(iii)');
    expect(a[0].challans[0]).toMatchObject({ bsrCode: '0510308', challanSerial: '00456', tds: 10_000 });
    const all = (await api('GET', '/tds/form16a?fy=2026-27&quarter=1')).body.data;
    expect(all).toHaveLength(2);
    expect(all.find((x: any) => x.deductee.name === 'No Pan Co').warnings.join(' ')).toContain('PAN is missing');
    const old = (await api('GET', '/tds/form16a?fy=2025-26&quarter=4')).body.data;
    expect(old[0].form).toBe('Form 16A');
    expect(old[0].rows[0].section).toBe('s.194J(b)');

    const gen = await api('POST', '/tds/certificates/generate', { kind: 'non_salary', fy: '2026-27', quarter: 1 });
    expect(gen.status).toBe(201);
    expect(gen.body.count).toBe(2);
    expect(gen.body.form).toBe('Form 131');

    const r = (await api('GET', '/tds/returns?fy=2026-27&quarter=1&kind=non_salary&today=2026-08-10')).body;
    expect(r.form).toBe('140');
    expect(r.totalTds).toBe(10_500);
    expect(r.rows[0]).toMatchObject({ pan: 'ABCDE1234F', tds: 10_000, bsrCode: '0510308', lateInterest: 300 });
    expect(r.lateFee).toMatchObject({ dueDate: '2026-07-31', daysLate: 10, lateFee: 2000 });
    expect(r.checks.find((c: any) => c.id === 'unchallaned').status).toBe('fail');
    expect(r.canFile).toBe(false);
    const q4old = (await api('GET', '/tds/returns?fy=2025-26&quarter=4&kind=non_salary')).body;
    expect(q4old.form).toBe('26Q');
    const csv = await raw(biz, '/tds/returns?fy=2026-27&quarter=1&kind=non_salary&format=csv');
    expect(csv.status).toBe(200);
    expect(csv.text).toContain('ABCDE1234F');
  });
  it('calculates interest on request', async () => {
    const { api } = await business();
    const d = await api('POST', '/tds/interest-calc', { kind: 'late_deposit', tax: 10_000, dueOn: '2026-05-10', onDate: '2026-06-20' });
    expect(d.body).toMatchObject({ months: 2, interest: 300 });
    expect((await api('POST', '/tds/interest-calc', { kind: 'late_filing', tax: 3_000, daysLate: 30 })).body.lateFee).toBe(3_000);
  });
});
