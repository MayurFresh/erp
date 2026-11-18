import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { addDays, financialYear, todayIst } from '../src/lib/dates.ts';
import { fyMonths, tdsDepositDue } from '../src/lib/due-dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Tax Co', name: 'Meera Shah', email: uniqueEmail('owner'), password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const claims = JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const accounts = async () => (await api('GET', '/accounts')).body.data as any[];
  const bank = (await accounts()).find((a) => a.code === '1010');
  const balance = async (code: string) => (await accounts()).find((a) => a.code === code).balance as number;
  const text = async (url: string) => {
    const r = await env.app.inject({ method: 'GET', url: `/api/v1${url}`, headers: { authorization: `Bearer ${token}`, 'x-company-id': companyId } });
    return { status: r.statusCode, text: r.body, headers: r.headers };
  };
  const db = <T>(fn: Parameters<typeof withTenant<T>>[2]) => withTenant(env.db, claims.tid as string, fn);
  return { api, bank, balance, text, db, companyId, tenantId: claims.tid as string };
}
const rp = { name: 'Rajesh Kumar', designation: 'Director', pan: 'ABCPK1234D', mobile: '9876543210', email: 'r@example.com' };
const quarterOf = (date: string) => Math.floor(((Number(date.slice(5, 7)) + 8) % 12) / 3) + 1;

describe('company fields', () => {
  it('validates PAN and mobile of the responsible person', async () => {
    const b = await business();
    expect((await b.api('PATCH', '/company', { responsiblePerson: { ...rp, pan: 'BAD' } })).status).toBe(400);
    expect((await b.api('PATCH', '/company', { responsiblePerson: { ...rp, mobile: '12345' } })).status).toBe(400);
    const ok = await b.api('PATCH', '/company', { constitution: 'private_company', itrForm: 'itr6', responsiblePerson: rp });
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({ constitution: 'private_company', itrForm: 'itr6', responsiblePerson: rp });
    expect((await b.api('PATCH', '/company', { responsiblePerson: null })).body.responsiblePerson).toBeNull();
  });
});

describe('tax payments', () => {
  it('journals to advance tax and cancels', async () => {
    const b = await business();
    const fy = financialYear(todayIst());
    const body = { kind: 'advance_tax', taxYear: fy, date: todayIst(), amount: 25000, bsrCode: '0510308', challanSerial: '00123', paidFromAccountId: b.bank.id };
    const r = await b.api('POST', '/tax/payments', body);
    expect(r.status).toBe(201);
    expect(r.body.number).toMatch(/^ITP/);
    expect(r.body.cin).toBe(`0510308${todayIst().replaceAll('-', '')}00123`);
    expect(await b.balance('1010')).toBe(-25000);
    expect((await b.api('POST', '/tax/payments', { ...body, bsrCode: '12' })).status).toBe(400);
    const list = await b.api('GET', `/tax/payments?taxYear=${fy}`);
    expect(list.body.total).toBe(1);
    const c = await b.api('POST', `/tax/payments/${r.body.id}/cancel`, { reason: 'wrong year' });
    expect(c.status).toBe(200);
    expect(c.body.status).toBe('cancelled');
    expect(await b.balance('1010')).toBe(0);
    expect((await b.api('POST', `/tax/payments/${r.body.id}/cancel`, { reason: 'again' })).status).toBe(409);
  });
});

describe('calculators', () => {
  it('regime: 12 lakh is nil after rebate, 15 lakh differs', async () => {
    const b = await business();
    const a = await b.api('POST', '/tax/calc/regime', { taxYear: '2026-27', age: 'below60', business: 1200000 });
    expect(a.status).toBe(200);
    expect(a.body.new.total).toBe(0);
    expect(a.body.unverified.length).toBeGreaterThan(0);
    const c = await b.api('POST', '/tax/calc/regime', { taxYear: '2026-27', age: 'below60', business: 1500000 });
    expect(c.body.new.total).toBe(109200);
    expect(c.body.old.total).toBe(273000);
    expect(c.body).toMatchObject({ better: 'new', saving: 163800 });
    const d = await b.api('POST', '/tax/calc/regime', { taxYear: '2026-27', age: 'below60', business: 1500000, deductions: { s80c: 500000 } });
    expect(d.body.old.taxable).toBe(1350000);
  });

  it('presumptive limits depend on the cash share', async () => {
    const b = await business();
    const p = (digital: number, cash: number) => b.api('POST', '/tax/calc/presumptive', { taxYear: '2026-27', kind: 'business', digitalReceipts: digital, cashReceipts: cash });
    const low = await p(15_000_0000 / 10, 0);
    expect(low.body).toMatchObject({ eligible: true, limit: 30_000_000, deemedIncome: 900000 });
    const mid = await p(28_500_000, 1_500_000);
    expect(mid.body).toMatchObject({ eligible: true, limit: 30_000_000 });
    const high = await p(22_500_000, 2_500_000);
    expect(high.body).toMatchObject({ eligible: false, limit: 20_000_000 });
    const risk = await b.api('POST', '/tax/calc/presumptive', { taxYear: '2026-27', kind: 'business', digitalReceipts: 1_000_000, cashReceipts: 0, declaredProfit: 10000 });
    expect(risk.body.declaredBelowDeemed).toBe(true);
    expect(risk.body.auditRisk).toBeTruthy();
  });

  it('advance tax: schedule and interest on a shortfall', async () => {
    const b = await business();
    const r = await b.api('GET', '/tax/advance-tax?taxYear=2026-27&estimatedIncome=2000000&regime=new');
    expect(r.status).toBe(200);
    expect(r.body.netTax).toBe(208000);
    expect(r.body.required).toBe(true);
    expect(r.body.instalments).toHaveLength(4);
    expect(r.body.instalments[0]).toMatchObject({ cumulativePct: 15, cumulativeDue: 31200, paidByDate: 0, shortfall: 31200 });
    expect(r.body.instalments[0].interest425).toBeCloseTo(936, 2);
    const pre = await b.api('GET', '/tax/advance-tax?taxYear=2026-27&estimatedIncome=2000000&presumptive=true');
    expect(pre.body.instalments).toHaveLength(1);
    const small = await b.api('GET', '/tax/advance-tax?taxYear=2026-27&estimatedIncome=500000');
    expect(small.body.required).toBe(false);
  });
});

describe('ITR pack and CA check', () => {
  it('pack net profit equals the books', async () => {
    const b = await business();
    const put = addDays(todayIst(), -100);
    await b.api('POST', '/fixed-assets', { name: 'Laptop', blockCode: 'computer', bookMethod: 'slm', usefulLifeYears: 5, cost: 100000, purchaseDate: put, putToUseDate: put, sourceAccountId: b.bank.id });
    expect((await b.api('POST', '/fixed-assets/depreciation-runs', { toDate: addDays(todayIst(), -5) })).status).toBe(201);
    const fy = financialYear(todayIst());
    const pack = await b.api('GET', `/tax/itr-pack?taxYear=${fy}&form=itr3`);
    expect(pack.status).toBe(200);
    const from = `${fy.slice(0, 4)}-04-01`;
    const to = `${Number(fy.slice(0, 4)) + 1}-03-31`;
    const pl = (await b.api('GET', `/reports/profit-loss?from=${from}&to=${to}`)).body;
    expect(pack.body.pnl.netProfit).toBe(pl.netProfit);
    expect(pack.body.pnl.netProfit).toBeLessThan(0);
    expect(pack.body.pnl.depreciationBooks).toBeGreaterThan(0);
    expect(pack.body.adjustments.some((a: any) => a.label === 'Book depreciation')).toBe(true);
    expect(pack.body.steps.length).toBeGreaterThan(3);
    const csv = await b.text(`/tax/itr-pack?taxYear=${fy}&format=csv`);
    expect(csv.status).toBe(200);
    expect(csv.headers['content-type']).toContain('text/csv');
  });

  it('ca-required: company audit by constitution, tax audit by turnover', async () => {
    const b = await business();
    const fy = financialYear(todayIst());
    const base = await b.api('GET', `/tax/ca-required?taxYear=${fy}`);
    expect(base.status).toBe(200);
    expect(base.body.needed).toBe(false);
    await b.api('PATCH', '/company', { constitution: 'private_company' });
    const co = await b.api('GET', `/tax/ca-required?taxYear=${fy}`);
    expect(co.body.needed).toBe(true);
    expect(co.body.items.map((i: any) => i.id)).toContain('company_audit');

    const wh = (await b.api('POST', '/locations', { type: 'warehouse', name: 'WH' })).body;
    const item = (await b.api('POST', '/items', { name: 'Gold bar', hsnCode: '7108', unit: 'nos', gstRate: 3, salePrice: 150000000, purchasePrice: 100 })).body;
    const sup = (await b.api('POST', '/parties', { type: 'vendor', name: 'Mint', stateCode: '24' })).body;
    await b.api('POST', '/purchases', { locationId: wh.id, partyId: sup.id, lines: [{ itemId: item.id, qty: 1, rate: 100 }] });
    const cust = (await b.api('POST', '/parties', { type: 'customer', name: 'Big Buyer', stateCode: '24' })).body;
    const inv = await b.api('POST', '/invoices', { locationId: wh.id, partyId: cust.id, lines: [{ itemId: item.id, qty: 1 }] });
    expect(inv.status).toBe(201);
    const big = await b.api('GET', `/tax/ca-required?taxYear=${fy}`);
    expect(big.body.items.map((i: any) => i.id)).toContain('tax_audit');
    expect(big.body.figures.turnover).toBe(150000000);
  });
});

describe('TDS file-ready statement', () => {
  async function withDeduction(b: Awaited<ReturnType<typeof business>>, date: string, challan: boolean) {
    const v = (await b.api('POST', '/parties', { type: 'vendor', name: 'Raj Contractor', stateCode: '24' })).body;
    const fy = financialYear(date);
    const id = await b.db(async (tx) => {
      const sec = await tx.selectFrom('tds_sections').select(['id']).where('code', '=', '194C').executeTakeFirstOrThrow();
      const r = await tx.insertInto('tds_deductions').values({
        tenant_id: b.tenantId, company_id: b.companyId, source_type: 'purchase', source_id: crypto.randomUUID(), number: 'PUR/T/1', party_id: v.id, pan: 'ABCPK1234D',
        section_id: sec.id, section_code: '194C', fy, deduction_date: date, gross: 50000, base: 50000, rate: 1, amount: 500,
      }).returning('id').executeTakeFirstOrThrow();
      return r.id;
    });
    if (challan) {
      const c = await b.api('POST', '/tds/challans', { depositDate: todayIst(), bsrCode: '0510308', challanSerial: '00431', paidFromAccountId: b.bank.id, taxAmount: 500, deductionIds: [id] });
      expect(c.status).toBe(201);
    }
    return { fy, quarter: quarterOf(date) };
  }

  it('blocks the .txt without TAN, responsible person and challan', async () => {
    const b = await business();
    const { fy, quarter } = await withDeduction(b, addDays(todayIst(), -3), false);
    const pre = await b.api('GET', `/tds/prefile-check?fy=${fy}&quarter=${quarter}`);
    expect(pre.status).toBe(200);
    expect(pre.body.canFile).toBe(false);
    const ids = pre.body.checks.filter((c: any) => c.status === 'fail').map((c: any) => c.id);
    expect(ids).toEqual(expect.arrayContaining(['tan', 'responsible_person', 'unchallaned']));
    const txt = await b.api('GET', `/tds/statement?fy=${fy}&quarter=${quarter}&format=txt`);
    expect(txt.status).toBe(409);
    expect(txt.body.error.code).toBe('PREFILE_FAILED');
  });

  it('produces FH/BH/CD/DD lines when ready', async () => {
    const b = await business();
    const { fy, quarter } = await withDeduction(b, addDays(todayIst(), -3), true);
    expect((await b.api('PATCH', '/company', { tan: 'PUNE12345A', responsiblePerson: rp })).status).toBe(200);
    const pre = await b.api('GET', `/tds/prefile-check?fy=${fy}&quarter=${quarter}`);
    expect(pre.body.canFile).toBe(true);
    const txt = await b.text(`/tds/statement?fy=${fy}&quarter=${quarter}&format=txt`);
    expect(txt.status).toBe(200);
    expect(txt.headers['content-type']).toContain('text/plain');
    expect(txt.headers['content-disposition']).toContain(`PUNE12345A_140_${fy}_Q${quarter}.txt`);
    const lines = txt.text.split('\r\n').filter(Boolean);
    expect(lines[0]).toBe('#ONEMATRIX BETA: validate with FVU before upload');
    expect(lines.map((l) => l.split('^')[0])).toEqual(['#ONEMATRIX BETA: validate with FVU before upload', 'FH', 'BH', 'CD', 'DD']);
  });

  it('defaults: interest on a late deposit', async () => {
    const b = await business();
    const date = addDays(todayIst(), -100);
    const { fy } = await withDeduction(b, date, false);
    const d = await b.api('GET', `/tds/defaults?fy=${fy}`);
    expect(d.status).toBe(200);
    const month = fyMonths(fy).find((m) => m === date.slice(0, 7))!;
    const row = d.body.deposits.find((x: any) => x.month === month);
    expect(row.dueDate).toBe(tdsDepositDue(month));
    expect(row.monthsLate).toBeGreaterThanOrEqual(3);
    expect(row.interest).toBeCloseTo(500 * 0.015 * row.monthsLate, 2);
    expect(d.body.totals.interest).toBe(row.interest);
    expect(d.body.unverified.length).toBeGreaterThan(0);
    expect(d.body.statements).toHaveLength(4);
  });
});
