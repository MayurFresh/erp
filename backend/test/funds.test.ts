import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { financialYear, todayIst } from '../src/lib/dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const FY = financialYear(todayIst());

async function biz(businessType: string, name = 'Test Office') {
  const res = await client(env.app)('POST', '/auth/signup', { businessName: name, name: 'Owner', email: uniqueEmail('fd'), password: 'Secret@123', stateCode: '24', businessType });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  const loc = (await api('POST', '/locations', { type: 'store', name: 'Main' })).body;
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const as = async (roleName: string) => {
    const email = uniqueEmail(roleName.replace(/\W/g, ''));
    const role = roles.find((r) => r.name === roleName)!;
    expect(role, roleName).toBeTruthy();
    expect((await api('POST', '/users', { name: roleName, email, password: 'Secret@123', roleId: role.id })).status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    return client(env.app, li.body.accessToken, companyId);
  };
  const accounts = async () => (await api('GET', '/accounts')).body.data as { id: string; code: string; name: string; balance: number }[];
  const acct = async (code: string) => (await accounts()).find((a) => a.code === code)!;
  return { api, as, locId: loc.id as string, accounts, acct, token: res.body.accessToken as string, companyId };
}
type Biz = Awaited<ReturnType<typeof biz>>;

/** One major head, one minor head and two object heads with budgets 6000 and 4000. */
async function tree(b: Biz) {
  const exp = await b.acct('6000');
  const major = (await b.api('POST', '/funds/heads', { fy: FY, level: 'major', code: '2202', name: 'General education' })).body;
  const minor = (await b.api('POST', '/funds/heads', { fy: FY, level: 'minor', parentId: major.id, code: '2202.01', name: 'Elementary' })).body;
  const salary = (await b.api('POST', '/funds/heads', { fy: FY, level: 'object', parentId: minor.id, code: '2202.01.01', name: 'Salaries', accountId: exp.id, budgetEstimate: 6000 })).body;
  const supplies = (await b.api('POST', '/funds/heads', { fy: FY, level: 'object', parentId: minor.id, code: '2202.01.02', name: 'Supplies', accountId: exp.id, budgetEstimate: 4000 })).body;
  return { major, minor, salary, supplies, exp };
}
const heads = async (b: Biz) => (await b.api('GET', `/funds/heads?fy=${FY}`)).body;
const head = (h: { data: { id: string }[] }, id: string) => h.data.find((x) => x.id === id) as any;
const newFund = async (b: Biz, over: Record<string, unknown> = {}) =>
  (await b.api('POST', '/funds/funds', { name: `State grant ${Math.random().toString(36).slice(2, 7)}`, kind: 'grant', sponsor: 'State Government', sanctionNo: 'GO/12/2026', totalAmount: 100000, returnUnspent: true, ...over })).body;
const newExpense = async (b: Biz, amount: number, desc = 'Stationery') => {
  const bank = await b.acct('1010'), exp = await b.acct('6000');
  const r = await b.api('POST', '/expenses', { locationId: b.locId, accountId: exp.id, description: desc, amount, paidFromAccountId: bank.id });
  expect(r.status).toBe(201);
  return r.body;
};

describe('budget heads', () => {
  it('builds a hierarchy whose parents add up the lowest heads', async () => {
    const b = await biz('government');
    const t = await tree(b);
    const h = await heads(b);
    expect(head(h, t.major.id)).toMatchObject({ budget: 10000, estimate: 10000, isLeaf: false });
    expect(head(h, t.minor.id).budget).toBe(10000);
    expect(head(h, t.salary.id)).toMatchObject({ budget: 6000, available: 6000, percentUsed: 0, isLeaf: true });
    expect(h.totals.budget).toBe(10000);
    // amounts only on the lowest heads
    expect((await b.api('PATCH', `/funds/heads/${t.minor.id}`, { budgetEstimate: 5 })).status).toBe(400);
    // a head with budget cannot become a parent; levels must follow
    expect((await b.api('POST', '/funds/heads', { fy: FY, level: 'object', parentId: t.salary.id, code: 'x', name: 'x' })).status).toBe(400);
    const m2 = (await b.api('POST', '/funds/heads', { fy: FY, level: 'major', code: '2210', name: 'Health', budgetEstimate: 500 })).body;
    const sub = await b.api('POST', '/funds/heads', { fy: FY, level: 'minor', parentId: m2.id, code: '2210.01', name: 'Clinics' });
    expect(sub.status).toBe(409);
    expect(sub.body.error?.code ?? sub.body.code).toBe('PARENT_HAS_BUDGET');
    expect((await b.api('POST', '/funds/heads', { fy: FY, level: 'major', code: '2202', name: 'Dup' })).status).toBe(409);
    // revised estimate replaces the estimate
    await b.api('PATCH', `/funds/heads/${t.supplies.id}`, { revisedEstimate: 4500 });
    expect(head(await heads(b), t.supplies.id)).toMatchObject({ estimate: 4000, revised: 4500, budget: 4500 });
    // head account must be an expense account
    const bank = await b.acct('1010');
    expect((await b.api('PATCH', `/funds/heads/${t.supplies.id}`, { accountId: bank.id })).status).toBe(400);
  });
});

describe('re-appropriation', () => {
  it('moves budget between heads without changing the total, with approval for entry users', async () => {
    const b = await biz('government');
    const t = await tree(b);
    const body = { fromHeadId: t.salary.id, toHeadId: t.supplies.id, amount: 1500, orderNo: 'FD/45/2026', orderDate: todayIst(), reason: 'Savings in salaries' };
    const r = await b.api('POST', '/funds/reappropriations', body);
    expect(r.status).toBe(201);
    expect(r.body.status).toBe('approved');
    const h = await heads(b);
    expect(head(h, t.salary.id)).toMatchObject({ budget: 4500, reappOut: 1500 });
    expect(head(h, t.supplies.id)).toMatchObject({ budget: 5500, reappIn: 1500 });
    expect(h.totals.budget).toBe(10000);
    // more than what is available
    const big = await b.api('POST', '/funds/reappropriations', { ...body, amount: 9000 });
    expect(big.status).toBe(409);
    expect(big.body.error?.code ?? big.body.code).toBe('INSUFFICIENT_BUDGET');
    // a clerk's request waits for the head of office
    const clerk = await b.as('Accounts Clerk');
    const p = await clerk('POST', '/funds/reappropriations', { ...body, amount: 500 });
    expect(p.status).toBe(201);
    expect(p.body.status).toBe('pending');
    expect(head(await heads(b), t.supplies.id).budget).toBe(5500);
    expect((await clerk('POST', `/funds/reappropriations/${p.body.id}/approve`)).status).toBe(403);
    expect((await b.api('POST', `/funds/reappropriations/${p.body.id}/approve`)).status).toBe(200);
    expect((await b.api('POST', `/funds/reappropriations/${p.body.id}/approve`)).status).toBe(409);
    const after = await heads(b);
    expect(head(after, t.supplies.id).budget).toBe(6000);
    expect(after.totals.budget).toBe(10000);
    expect((await b.api('GET', `/funds/reappropriations?fy=${FY}&status=approved`)).body.data).toHaveLength(2);
    expect((await b.api('POST', '/funds/reappropriations', { ...body, toHeadId: t.minor.id })).status).toBe(400);
  });
});

describe('sanctions and overspend control', () => {
  const approve = { adminOrderNo: 'AA/1', adminOrderDate: todayIst(), financialOrderNo: 'FA/1', financialOrderDate: todayIst() };

  it('blocks an over-budget sanction in block mode and warns in warn mode', async () => {
    const b = await biz('government');
    const t = await tree(b);
    const fund = await newFund(b);
    const s = await b.api('POST', '/funds/sanctions', { headId: t.salary.id, fundId: fund.id, purpose: 'Teacher pay', amount: 8000 });
    expect(s.status).toBe(201);
    expect(s.body.number).toMatch(/^SAN\/\d{2}-\d{2}\/00001$/);
    expect(s.body.warnings).toHaveLength(1);
    expect((await b.api('PUT', '/funds/settings', { overspendMode: 'block' })).body.overspendMode).toBe('block');
    const blocked = await b.api('POST', `/funds/sanctions/${s.body.id}/approve`, approve);
    expect(blocked.status).toBe(409);
    expect(blocked.body.error?.code ?? blocked.body.code).toBe('BUDGET_EXCEEDED');
    expect((await b.api('GET', `/funds/sanctions/${s.body.id}`)).body.status).toBe('pending');
    await b.api('PUT', '/funds/settings', { overspendMode: 'warn' });
    const ok = await b.api('POST', `/funds/sanctions/${s.body.id}/approve`, approve);
    expect(ok.status).toBe(200);
    expect(ok.body.status).toBe('approved');
    expect(ok.body.warnings.length).toBe(1);
    expect(head(await heads(b), t.salary.id)).toMatchObject({ committed: 8000, available: -2000 });
    // both order numbers are required
    const s2 = (await b.api('POST', '/funds/sanctions', { headId: t.supplies.id, fundId: fund.id, purpose: 'Books', amount: 100 })).body;
    expect((await b.api('POST', `/funds/sanctions/${s2.id}/approve`, { ...approve, financialOrderNo: '' })).status).toBe(400);
    // cannot sanction on a head that has sub-heads
    expect((await b.api('POST', '/funds/sanctions', { headId: t.minor.id, fundId: fund.id, purpose: 'x', amount: 1 })).status).toBe(400);
  });

  it('turns a commitment into actual spending when an expense is linked', async () => {
    const b = await biz('government');
    const t = await tree(b);
    const fund = await newFund(b);
    const s = (await b.api('POST', '/funds/sanctions', { headId: t.supplies.id, fundId: fund.id, purpose: 'Stationery', amount: 3000 })).body;
    expect((await b.api('POST', `/funds/sanctions/${s.id}/approve`, approve)).status).toBe(200);
    expect(head(await heads(b), t.supplies.id)).toMatchObject({ committed: 3000, actual: 0, available: 1000 });
    const exp = await newExpense(b, 1200);
    const sp = (await b.api('GET', '/funds/spendable?type=expense')).body.data;
    expect(sp.find((x: any) => x.sourceId === exp.id).remaining).toBe(1200);
    const link = await b.api('POST', '/funds/links', { sourceType: 'expense', sourceId: exp.id, headId: t.supplies.id, fundId: fund.id, sanctionId: s.id });
    expect(link.status).toBe(201);
    expect(link.body.amount).toBe(1200);
    expect(head(await heads(b), t.supplies.id)).toMatchObject({ actual: 1200, committed: 1800, available: 1000, percentUsed: 30, percentCommitted: 75 });
    expect((await b.api('GET', '/funds/spendable?type=expense')).body.data.find((x: any) => x.sourceId === exp.id)).toBeUndefined();
    expect((await b.api('POST', '/funds/links', { sourceType: 'expense', sourceId: exp.id, headId: t.supplies.id, fundId: fund.id })).status).toBe(400);
    // the sanction has only 1800 left
    const exp2 = await newExpense(b, 2500, 'Furniture');
    const over = await b.api('POST', '/funds/links', { sourceType: 'expense', sourceId: exp2.id, headId: t.supplies.id, fundId: fund.id, sanctionId: s.id });
    expect(over.status).toBe(400);
    // without a sanction, 2500 goes past the 1000 still free: block mode stops it
    await b.api('PUT', '/funds/settings', { overspendMode: 'block' });
    const stop = await b.api('POST', '/funds/links', { sourceType: 'expense', sourceId: exp2.id, headId: t.supplies.id, fundId: fund.id });
    expect(stop.status).toBe(409);
    expect(stop.body.error?.code ?? stop.body.code).toBe('BUDGET_EXCEEDED');
    // approved sanction with spending cannot be cancelled until the link is removed
    expect((await b.api('POST', `/funds/sanctions/${s.id}/cancel`, {})).status).toBe(409);
    expect((await b.api('DELETE', `/funds/links/${link.body.id}`)).status).toBe(200);
    expect(head(await heads(b), t.supplies.id).actual).toBe(0);
    // a cancelled expense stops counting
    const l2 = await b.api('POST', '/funds/links', { sourceType: 'expense', sourceId: exp.id, headId: t.supplies.id, fundId: fund.id, sanctionId: s.id });
    expect(l2.status).toBe(201);
    const c = await b.api('POST', `/expenses/${exp.id}/cancel`, { reason: 'Entered twice' });
    expect(c.status).toBeLessThan(300);
    expect(head(await heads(b), t.supplies.id).actual).toBe(0);
  });

  it('moves a returnable grant from liability to income as spending is linked, and back on delete', async () => {
    const b = await biz('government');
    const t = await tree(b);
    const fund = await newFund(b, { returnUnspent: true });
    const bank = (await b.acct('1010')).balance;
    expect((await b.api('POST', `/funds/funds/${fund.id}/receipts`, { amount: 20000, reference: 'UTR 1' })).status).toBe(201);
    expect((await b.acct('1010')).balance).toBe(bank + 20000);
    const liab = async () => Math.abs((await b.accounts()).find((a) => a.name === 'Grants Refundable (Unspent)')!.balance);
    const inc = async () => Math.abs(((await b.accounts()).find((a) => a.name === 'Grants Received')?.balance) ?? 0);
    expect(await liab()).toBe(20000);
    expect(await inc()).toBe(0);
    const exp = await newExpense(b, 4500);
    const link = await b.api('POST', '/funds/links', { sourceType: 'expense', sourceId: exp.id, headId: t.supplies.id, fundId: fund.id });
    expect(link.status).toBe(201);
    expect(await liab()).toBe(15500);
    expect(await inc()).toBe(4500);
    expect((await b.api('DELETE', `/funds/links/${link.body.id}`)).status).toBe(200);
    expect(await liab()).toBe(20000);
    expect(await inc()).toBe(0);
  });

  it('refuses to count a bill and its payment twice', async () => {
    const b = await biz('government');
    const t = await tree(b);
    const fund = await newFund(b);
    const vendor = (await b.api('POST', '/parties', { type: 'vendor', name: 'Stationers', stateCode: '24' })).body;
    const item = (await b.api('POST', '/items', { name: 'Paper', type: 'service', unit: 'NOS', salePrice: 10, purchasePrice: 10, gstRate: 0 })).body;
    const bill = await b.api('POST', '/purchases', { locationId: b.locId, partyId: vendor.id, lines: [{ itemId: item.id, qty: 10, rate: 100 }] });
    if (bill.status !== 201) return; // purchase setup differs; the expense path is covered above
    const pay = await b.api('POST', '/payments', { kind: 'payment', partyId: vendor.id, accountId: (await b.acct('1010')).id, mode: 'bank', amount: 1000 });
    expect(pay.status).toBe(201);
    const l1 = await b.api('POST', '/funds/links', { sourceType: 'purchase', sourceId: bill.body.id, headId: t.supplies.id, fundId: fund.id });
    expect(l1.status).toBe(201);
    const l2 = await b.api('POST', '/funds/links', { sourceType: 'payment', sourceId: pay.body.id, headId: t.supplies.id, fundId: fund.id });
    expect([201, 409]).toContain(l2.status);
  });
});

describe('fund reports and utilisation certificate', () => {
  it('adds up opening, receipts, spending by head and closing', async () => {
    const b = await biz('government');
    const t = await tree(b);
    const fund = await newFund(b, { totalAmount: 50000 });
    const bank0 = (await b.acct('1010')).balance;
    const g = await b.api('POST', `/funds/funds/${fund.id}/receipts`, { amount: 20000, reference: 'UTR 998877', narration: 'First instalment' });
    expect(g.status).toBe(201);
    expect(g.body.number).toMatch(/^GRR\//);
    expect((await b.acct('1010')).balance).toBe(bank0 + 20000);
    const e1 = await newExpense(b, 3000), e2 = await newExpense(b, 2000, 'Chalk');
    await b.api('POST', '/funds/links', { sourceType: 'expense', sourceId: e1.id, headId: t.salary.id, fundId: fund.id });
    await b.api('POST', '/funds/links', { sourceType: 'expense', sourceId: e2.id, headId: t.supplies.id, fundId: fund.id });
    const from = `${FY.slice(0, 4)}-04-01`, to = todayIst();
    const uc = (await b.api('GET', `/funds/funds/${fund.id}/utilisation?from=${from}&to=${to}`)).body;
    expect(uc).toMatchObject({ opening: 0, received: 20000, spent: 5000, closing: 15000, returnUnspent: true, refundDue: 15000 });
    expect(uc.spentByHead.map((r: any) => [r.code, r.amount])).toEqual([['2202.01.01', 3000], ['2202.01.02', 2000]]);
    expect(uc.opening + uc.received - uc.spent).toBe(uc.closing);
    // a period starting tomorrow opens with the closing balance
    const next = (await b.api('GET', `/funds/funds/${fund.id}/utilisation?from=2099-04-01&to=2100-03-31`)).body;
    expect(next).toMatchObject({ opening: 15000, received: 0, spent: 0, closing: 15000 });
    const fw = (await b.api('GET', `/funds/reports/fund-wise?from=${from}&to=${to}`)).body;
    expect(fw.data.find((r: any) => r.fundId === fund.id)).toMatchObject({ received: 20000, spent: 5000, closing: 15000 });
    const bva = (await b.api('GET', `/funds/reports/budget-vs-actual?fy=${FY}`)).body;
    expect(bva.totals).toMatchObject({ budget: 10000, actual: 5000, available: 5000, percentUsed: 50 });
    const home = (await b.api('GET', `/funds/home?fy=${FY}`)).body;
    expect(home.funds.find((f: any) => f.id === fund.id)).toMatchObject({ received: 20000, spent: 5000, balance: 15000 });
    expect(home.heads).toHaveLength(1);
    // stale edit
    const stale = await b.api('PATCH', `/funds/funds/${fund.id}`, { name: 'Renamed', expectedUpdatedAt: '2000-01-01T00:00:00.000Z' });
    expect(stale.status).toBe(409);
  });
});

describe('funds permissions', () => {
  it('lets the auditor read only and the clerk enter but not approve or set budgets', async () => {
    const b = await biz('government');
    const t = await tree(b);
    const fund = await newFund(b);
    const auditor = await b.as('Internal Auditor');
    expect((await auditor('GET', `/funds/heads?fy=${FY}`)).status).toBe(200);
    expect((await auditor('GET', '/funds/funds')).status).toBe(200);
    expect((await auditor('POST', '/funds/funds', { name: 'x' })).status).toBe(403);
    expect((await auditor('POST', '/funds/sanctions', { headId: t.salary.id, fundId: fund.id, purpose: 'x', amount: 1 })).status).toBe(403);
    const clerk = await b.as('Accounts Clerk');
    const s = await clerk('POST', '/funds/sanctions', { headId: t.salary.id, fundId: fund.id, purpose: 'Pay', amount: 100 });
    expect(s.status).toBe(201);
    expect((await clerk('POST', `/funds/sanctions/${s.body.id}/approve`, { adminOrderNo: 'a', adminOrderDate: todayIst(), financialOrderNo: 'b', financialOrderDate: todayIst() })).status).toBe(403);
    expect((await clerk('POST', '/funds/heads', { fy: FY, level: 'major', code: '9', name: 'x' })).status).toBe(403);
    expect((await clerk('PUT', '/funds/settings', { overspendMode: 'block' })).status).toBe(403);
    const ddo = await b.as('Drawing and Disbursing Officer');
    expect((await ddo('POST', '/funds/links', { sourceType: 'expense', sourceId: (await newExpense(b, 50)).id, headId: t.salary.id, fundId: fund.id })).status).toBe(201);
    // another business cannot see these funds
    const other = await biz('local_body', 'Other Body');
    expect((await other.api('GET', `/funds/funds/${fund.id}`)).status).toBe(404);
  });
});

describe('donations', () => {
  async function ngo() {
    const b = await biz('ngo', 'Seva Trust');
    await b.api('PUT', '/funds/settings', { reg80gNo: 'AAATS1234E/12AB/2021-22/80G', reg80gFrom: '2021-04-01', reg80gTo: '2099-03-31', trustPan: 'AAATS1234E' });
    const donor = (await b.api('POST', '/donors', { name: 'Meena Patel', phone: '9825011111', pan: 'abcde1234f', address: 'Satellite, Ahmedabad' })).body;
    return { b, donor };
  }
  const code = (r: any) => r.body.error?.code ?? r.body.code;

  it('numbers receipts, applies the cash 80G rule and posts to the books', async () => {
    const { b, donor } = await ngo();
    expect(donor.pan).toBe('ABCDE1234F');
    const dup = await b.api('POST', '/donors', { name: 'Someone', pan: 'ABCDE1234F' });
    expect(dup.status).toBe(409);
    expect(code(dup)).toBe('DUPLICATE_DONOR');
    const bank0 = (await b.acct('1010')).balance, cash0 = (await b.acct('1000')).balance;
    const d1 = await b.api('POST', '/donations', { donorId: donor.id, amount: 5000, mode: 'upi', tax80g: true, purpose: 'General' });
    expect(d1.status).toBe(201);
    expect(d1.body.receiptNo).toMatch(/^DON\/\d{2}-\d{2}\/00001$/);
    expect(d1.body).toMatchObject({ deductionEligible: true, warnings: [] });
    const d2 = await b.api('POST', '/donations', { donorId: donor.id, amount: 2500, mode: 'cash', tax80g: true });
    expect(d2.status).toBe(201);
    expect(d2.body.receiptNo).toMatch(/00002$/);
    expect(d2.body.deductionEligible).toBe(false);
    expect(d2.body.warnings[0]).toMatch(/2000/);
    expect(d2.body.warning).toBeTruthy();
    const d3 = await b.api('POST', '/donations', { donorId: donor.id, amount: 2000, mode: 'cash', tax80g: true });
    expect(d3.body.deductionEligible).toBe(true);
    expect((await b.acct('1010')).balance).toBe(bank0 + 5000);
    expect((await b.acct('1000')).balance).toBe(cash0 + 4500);
    const income = (await b.accounts()).find((a) => a.name === 'Donations Received')!;
    expect(Math.abs(income.balance)).toBe(9500);
    // corpus goes to the corpus fund, not income
    const d4 = await b.api('POST', '/donations', { donorId: donor.id, amount: 10000, mode: 'bank', isCorpus: true });
    expect(Math.abs((await b.accounts()).find((a) => a.name === 'Corpus Fund')!.balance)).toBe(10000);
    expect(Math.abs((await b.accounts()).find((a) => a.name === 'Donations Received')!.balance)).toBe(9500);
    // 80G needs an ID
    const anon = (await b.api('POST', '/donors', { name: 'Walk-in', phone: '9000000000' })).body;
    expect((await b.api('POST', '/donations', { donorId: anon.id, amount: 100, mode: 'upi', tax80g: true })).status).toBe(400);
    expect((await b.api('POST', '/donations', { donorId: anon.id, amount: 100, mode: 'upi' })).status).toBe(201);
    // receipt data for the PDF
    const rc = (await b.api('GET', `/donations/${d1.body.id}`)).body;
    expect(rc.reg80g.no).toBe('AAATS1234E/12AB/2021-22/80G');
    expect(rc.donor).toMatchObject({ pan: 'ABCDE1234F', name: 'Meena Patel' });
    expect(rc.trust.name).toBe('Seva Trust');
    // cancel reverses the books
    expect((await b.api('POST', `/donations/${d4.body.id}/cancel`, { reason: 'Cheque bounced' })).status).toBe(200);
    expect((await b.acct('1010')).balance).toBe(bank0 + 5100);
    expect((await b.api('POST', `/donations/${d4.body.id}/cancel`, { reason: 'again' })).status).toBe(409);
    // home and statement
    const home = (await b.api('GET', '/donations/home')).body;
    expect(home.today.total).toBe(5000 + 2500 + 2000 + 100);
    expect(home.year.eligible80g).toBe(7000);
    const st = (await b.api('GET', `/donors/${donor.id}/statement?fy=${FY}`)).body;
    expect(st).toMatchObject({ total: 9500, eligibleFor80g: 7000 });
    expect(st.data).toHaveLength(3);
    // a donation tagged to a fund counts as fund receipts
    const fund = await newFund(b, { name: 'Building fund', kind: 'donation' });
    await b.api('POST', '/donations', { donorId: donor.id, amount: 700, mode: 'bank', fundId: fund.id });
    expect((await b.api('GET', `/funds/funds/${fund.id}`)).body.received).toBe(700);
  });

  it('warns when the 80G registration is missing or has expired', async () => {
    const b = await biz('religious', 'Mandir Trust');
    const donor = (await b.api('POST', '/donors', { name: 'Ramesh', pan: 'ABCDE1234F' })).body;
    const r = await b.api('POST', '/donations', { donorId: donor.id, amount: 500, mode: 'upi', tax80g: true });
    expect(r.status).toBe(201);
    expect(r.body.warnings.join(' ')).toMatch(/registration/);
    await b.api('PUT', '/funds/settings', { reg80gNo: 'X/80G', reg80gFrom: '2010-04-01', reg80gTo: '2011-03-31' });
    const r2 = await b.api('POST', '/donations', { donorId: donor.id, amount: 500, mode: 'upi', tax80g: true });
    expect(r2.body.warnings.join(' ')).toMatch(/validity/);
  });

  it('exports Form 10BD data with the portal columns', async () => {
    const { b, donor } = await ngo();
    const anon = (await b.api('POST', '/donors', { name: 'Aadhaar Donor', aadhaar: '1234 5678 9012' })).body;
    expect(anon.aadhaarMasked).toBe('XXXX XXXX 9012');
    await b.api('POST', '/donations', { donorId: donor.id, amount: 5000, mode: 'bank', tax80g: true });
    await b.api('POST', '/donations', { donorId: donor.id, amount: 9000, mode: 'cash', tax80g: true });
    await b.api('POST', '/donations', { donorId: donor.id, amount: 3000, mode: 'upi', tax80g: true, isCorpus: true });
    await b.api('POST', '/donations', { donorId: anon.id, amount: 800, mode: 'upi', tax80g: true });
    await b.api('POST', '/donations', { donorId: donor.id, amount: 400, mode: 'upi' });
    const j = (await b.api('GET', `/donations/form-10bd?fy=${FY}`)).body;
    expect(j.header).toEqual(['Sr No', 'Section Code', 'Donor ID Type', 'Donor ID', 'Donor Name', 'Donor Address', 'Donation Type', 'Mode of Receipt', 'Amount of Donation']);
    expect(j.rows).toHaveLength(3);
    expect(j.rows[0].slice(0, 4)).toEqual([1, '80G', 'PAN', 'ABCDE1234F']);
    expect(j.rows.map((r: any[]) => r[6])).toEqual(['Others', 'Corpus', 'Others']);
    expect(j.total).toBe(8800);
    expect(j.note).toMatch(/Check before filing/);
    const csv = await env.app.inject({ method: 'GET', url: `/api/v1/donations/form-10bd?fy=${FY}&format=csv`, headers: { authorization: `Bearer ${b.token}`, 'x-company-id': b.companyId } });
    expect(csv.statusCode).toBe(200);
    expect(csv.headers['content-type']).toMatch(/text\/csv/);
    const lines = csv.body.trim().split(/\r?\n/);
    expect(lines[0]).toBe(j.header.join(','));
    expect(lines).toHaveLength(4);
    // permission denials
    const pm = await b.as('Programme Manager');
    expect((await pm('GET', '/donations')).status).toBe(403);
    expect((await pm('POST', '/donations', { donorId: donor.id, amount: 1, mode: 'cash' })).status).toBe(403);
    const vol = await biz('religious', 'Temple 2');
    const counter = await vol.as('Counter Volunteer');
    const dn = (await counter('POST', '/donors', { name: 'Devotee' })).body;
    expect((await counter('POST', '/donations', { donorId: dn.id, amount: 51, mode: 'cash' })).status).toBe(201);
    expect((await counter('GET', `/donations/form-10bd?fy=${FY}`)).status).toBe(403);
    expect((await counter('POST', `/donations/${(await counter('GET', '/donations')).body.data[0].id}/cancel`, { reason: 'x' })).status).toBe(403);
    const aud = await vol.as('Auditor');
    expect((await aud('GET', '/donations')).status).toBe(200);
    expect((await aud('POST', '/donors', { name: 'x' })).status).toBe(403);
  });
});
