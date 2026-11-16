import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

type Api = ReturnType<typeof client>;

async function biz(name: string) {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner One', email: uniqueEmail('fin'), password: 'Secret@123', stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const token = signup.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const api = client(env.app, token, me.companies[0].id as string);
  const accts = (await api('GET', '/accounts')).body.data as { id: string; code: string; subtype: string }[];
  const id = (code: string) => accts.find((a) => a.code === code)!.id;
  return { api, id, token };
}
type Line = [string, 'dr' | 'cr', number];
async function jv(api: Api, date: string, lines: Line[]) {
  const r = await api('POST', '/journals', {
    date, narration: 'Test entry',
    lines: lines.map(([accountId, side, amt]) => ({ accountId, [side === 'dr' ? 'debit' : 'credit']: amt })),
  });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
}
async function newAccount(api: Api, name: string, type: string) {
  const r = await api('POST', '/accounts', { name, type });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body.id as string;
}

describe('cash flow, ratios and budgets on hand-built entries', () => {
  let b: Awaited<ReturnType<typeof biz>>;
  beforeAll(async () => {
    b = await biz('Flow Co');
    const { api, id } = b;
    const loan = await newAccount(api, 'Bank Loan', 'liability');
    const interest = await newAccount(api, 'Interest on Loan', 'expense');
    await jv(api, '2026-04-05', [[id('1010'), 'dr', 100000], [id('3000'), 'cr', 100000]]);
    await jv(api, '2026-04-06', [[id('1200'), 'dr', 40000], [id('2000'), 'cr', 40000]]);
    await jv(api, '2026-04-10', [[id('1100'), 'dr', 50000], [id('4000'), 'cr', 50000]]);
    await jv(api, '2026-04-10', [[id('5000'), 'dr', 30000], [id('1200'), 'cr', 30000]]);
    await jv(api, '2026-04-20', [[id('6000'), 'dr', 5000], [id('1010'), 'cr', 5000]]);
    await jv(api, '2026-05-02', [[id('1010'), 'dr', 20000], [id('1100'), 'cr', 20000]]);
    await jv(api, '2026-05-03', [[id('2000'), 'dr', 10000], [id('1010'), 'cr', 10000]]);
    await jv(api, '2026-05-10', [[id('1500'), 'dr', 30000], [id('1010'), 'cr', 30000]]);
    await jv(api, '2026-06-01', [[id('5400'), 'dr', 3000], [id('1510'), 'cr', 3000]]);
    await jv(api, '2026-06-05', [[id('1010'), 'dr', 25000], [loan, 'cr', 25000]]);
    await jv(api, '2026-06-10', [[interest, 'dr', 1000], [id('1010'), 'cr', 1000]]);
  });

  it('cash flow reconciles to the change in bank and cash', async () => {
    const r = await b.api('GET', '/reports/cash-flow?from=2026-04-01&to=2026-06-30&compare=true');
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const c = r.body.current;
    const sec = (k: string) => c.sections.find((s: { key: string }) => s.key === k);
    const line = (k: string) => c.sections.flatMap((s: { lines: unknown[] }) => s.lines).find((l: { key: string }) => l.key === k);
    expect(c.netProfit).toBe(11000);
    expect(line('dep').amount).toBe(3000);
    expect(line('receivables').amount).toBe(-30000);
    expect(line('inventory').amount).toBe(-10000);
    expect(line('payables').amount).toBe(30000);
    expect(sec('operating').total).toBe(5000);
    expect(sec('investing').total).toBe(-30000);
    expect(sec('financing').total).toBe(124000);
    expect(c.closingCash).toBe(99000);
    expect(c.netChange).toBe(99000);
    expect(c.difference).toBe(0);
    expect(c.reconciles).toBe(true);
    expect(line('loans').accounts[0].name).toBe('Bank Loan');
    expect(r.body.previous.reconciles).toBe(true);
  });

  it('mapping moves an account to another section and still reconciles', async () => {
    const map = (await b.api('GET', '/cash-flow/mapping')).body.data as { accountId: string; name: string; effective: string }[];
    const loan = map.find((m) => m.name === 'Bank Loan')!;
    expect(loan.effective).toBe('financing');
    const set = await b.api('PUT', `/cash-flow/mapping/${loan.accountId}`, { category: 'operating' });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
    const c = (await b.api('GET', '/reports/cash-flow?from=2026-04-01&to=2026-06-30')).body.current;
    expect(c.reconciles).toBe(true);
    expect(c.sections.find((s: { key: string }) => s.key === 'financing').total).toBe(99000);
    await b.api('PUT', `/cash-flow/mapping/${loan.accountId}`, { category: null });
  });

  it('ratios on known figures with formulas', async () => {
    const r = await b.api('GET', '/reports/ratios?from=2026-04-01&to=2026-06-30');
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const v = (k: string) => r.body.current.ratios.find((x: { key: string }) => x.key === k);
    expect(r.body.current.days).toBe(91);
    expect(v('current_ratio').value).toBe(4.63);
    expect(v('quick_ratio').value).toBe(4.3);
    expect(v('debt_equity').value).toBe(0.23);
    expect(v('gross_margin').value).toBe(40);
    expect(v('net_margin').value).toBe(22);
    expect(v('roce').value).toBe(8.82);
    expect(v('inventory_turnover').value).toBe(6);
    expect(v('inventory_days').value).toBe(15.17);
    expect(v('debtor_days').value).toBe(27.3);
    expect(v('creditor_days').value).toBe(45.5);
    expect(v('interest_coverage').value).toBe(12);
    expect(v('current_ratio').formula).toContain('/');
    expect((await b.api('GET', '/reports/ratios?from=2026-04-01&to=2026-06-30&compare=true')).body.previous.ratios).toHaveLength(11);
  });

  it('budget variance, alerts, copy with uplift', async () => {
    const rent = b.id('6000');
    const put = await b.api('PUT', '/budgets', { fy: '2026-27', rows: [
      { accountId: rent, months: { '2026-04': 4000, '2026-05': 4000 } },
      { accountId: b.id('4000'), months: { '2026-04': 60000 } },
    ] });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    const bad = await b.api('PUT', '/budgets', { fy: '2026-27', rows: [{ accountId: b.id('1010'), months: { '2026-04': 1 } }] });
    expect(bad.status).toBe(400);
    const r = await b.api('GET', '/reports/budget-variance?fy=2026-27&month=2026-04');
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    const row = r.body.rows.find((x: { code: string }) => x.code === '6000');
    expect(row.month).toMatchObject({ budget: 4000, actual: 5000, variance: 1000, percentUsed: 125 });
    expect(row.status).toBe('over');
    expect(r.body.alerts.some((a: { name: string; level: string }) => a.name === 'Rent' && a.level === 'over')).toBe(true);
    const ytd = (await b.api('GET', '/reports/budget-variance?fy=2026-27&month=2026-05')).body.rows.find((x: { code: string }) => x.code === '6000');
    expect(ytd.ytd).toMatchObject({ budget: 8000, actual: 5000, percentUsed: 62.5 });
    expect((await b.api('POST', '/budgets/copy', { fromFy: '2026-27', toFy: '2027-28', upliftPercent: 10 })).body.copied).toBe(3);
    const copied = (await b.api('GET', '/budgets?fy=2027-28')).body.data.find((x: { code: string }) => x.code === '6000');
    expect(copied.months['2027-04']).toBe(4400);
    expect((await b.api('POST', '/budgets/copy', { fromFy: '2026-27', toFy: '2027-28' })).status).toBe(409);
    expect((await b.api('POST', '/budgets/copy', { fromFy: '2026-27', toFy: '2027-28', replace: true })).status).toBe(200);
  });
});

describe('year-end close', () => {
  it('moves profit to equity, locks, and reopens', async () => {
    const { api, id } = await biz('Close Co');
    await jv(api, '2026-01-10', [[id('1010'), 'dr', 10000], [id('4000'), 'cr', 10000]]);
    await jv(api, '2026-02-10', [[id('6000'), 'dr', 2000], [id('1010'), 'cr', 2000]]);
    const prev = (await api('GET', '/year-end/preview?fy=2025-26')).body;
    expect(prev).toMatchObject({ income: 10000, expenses: 2000, profit: 8000, canClose: true, willCreateEquityAccount: true });
    expect((await api('GET', '/year-end/preview?fy=2026-27')).body.canClose).toBe(false);
    const close = await api('POST', '/year-end/close', { fy: '2025-26' });
    expect(close.status, JSON.stringify(close.body)).toBe(200);
    expect(close.body.profit).toBe(8000);
    // The year still reports its profit; the trial balance carries it in equity.
    const pl = (await api('GET', '/reports/profit-loss?from=2025-04-01&to=2026-03-31')).body;
    expect(pl.netProfit).toBe(8000);
    const tb = (await api('GET', '/reports/trial-balance?asOf=2026-06-30')).body;
    expect(tb.rows.find((r: { code: string }) => r.code === '4000')).toBeUndefined();
    expect(tb.rows.find((r: { code: string }) => r.code === '3200').credit).toBe(8000);
    expect(tb.totalDebit).toBe(tb.totalCredit);
    // Locked.
    const late = await api('POST', '/journals', { date: '2026-03-15', narration: 'Late', lines: [{ accountId: id('6000'), debit: 1 }, { accountId: id('1010'), credit: 1 }] });
    expect(late.status).toBe(409);
    expect((await api('POST', '/year-end/close', { fy: '2025-26' })).status).toBe(409);
    // Next year locked: cannot reopen.
    await api('PATCH', '/company', { booksLockedUntil: '2026-06-30' });
    expect((await api('POST', `/year-end/${close.body.id}/reopen`)).status).toBe(409);
    await api('PATCH', '/company', { booksLockedUntil: '2026-03-31' });
    const re = await api('POST', `/year-end/${close.body.id}/reopen`);
    expect(re.status, JSON.stringify(re.body)).toBe(200);
    expect(re.body.status).toBe('reopened');
    const tb2 = (await api('GET', '/reports/trial-balance?asOf=2026-06-30')).body;
    expect(tb2.rows.find((r: { code: string }) => r.code === '4000').credit).toBe(10000);
    expect((await api('POST', '/journals', { date: '2026-03-15', narration: 'Open again', lines: [{ accountId: id('6000'), debit: 1 }, { accountId: id('1010'), credit: 1 }] })).status).toBe(201);
  });
});

describe('cheques', () => {
  it('post-dated received cheque: clear then bounce reverses the receipt and charges the customer', async () => {
    const { api, id } = await biz('Cheque Co');
    const bank = id('1010');
    const cust = (await api('POST', '/parties', { type: 'customer', name: 'Payer', stateCode: '24' })).body.id as string;
    const mk = async (no: string, date = '2026-04-10') => {
      const r = await api('POST', '/cheques', { direction: 'received', bankAccountId: bank, chequeNo: no, chequeDate: date, partyId: cust, amount: 7000 });
      expect(r.status, JSON.stringify(r.body)).toBe(201);
      return r.body.id as string;
    };
    const balance = async () => (await api('GET', '/accounts')).body.data.find((a: { code: string }) => a.code === '1010').balance as number;
    const future = await mk('900001', '2099-01-01');
    const c1 = await mk('900002');
    const due = (await api('GET', '/cheques/due-today')).body.data.map((x: { id: string }) => x.id);
    expect(due).toContain(c1);
    expect(due).not.toContain(future);
    expect((await api('POST', `/cheques/${c1}/deposit`, {})).body.status).toBe('deposited');
    const cleared = await api('POST', `/cheques/${c1}/clear`, {});
    expect(cleared.body.status).toBe('cleared');
    expect(await balance()).toBe(7000);
    const bounce = await api('POST', `/cheques/${c1}/bounce`, { reason: 'Funds insufficient', bankCharges: 300, recoverFromParty: true });
    expect(bounce.status, JSON.stringify(bounce.body)).toBe(200);
    expect(bounce.body.status).toBe('bounced');
    expect(await balance()).toBe(-300);
    expect((await api('GET', `/parties/${cust}/outstanding`)).body.balance).toBe(300);
    expect((await api('GET', `/payments/${cleared.body.paymentId}`)).body.status).toBe('cancelled');
    expect((await api('POST', `/cheques/${c1}/clear`, {})).status).toBe(409);
    // Bounce before it was cleared posts nothing.
    const c2 = await mk('900003');
    expect((await api('POST', `/cheques/${c2}/bounce`, { reason: 'Stopped by drawer' })).body.status).toBe('bounced');
    expect(await balance()).toBe(-300);
  });

  it('cheque book, leaf from a payment, print data and layout', async () => {
    const { api, id } = await biz('Book Co');
    const bank = id('1010');
    await api('POST', '/journals', { date: '2026-04-01', narration: 'Funds', lines: [{ accountId: bank, debit: 50000 }, { accountId: id('3000'), credit: 50000 }] });
    const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Supplier', stateCode: '24' })).body.id as string;
    const book = await api('POST', '/cheque-books', { accountId: bank, fromNo: 100001, toNo: 100010 });
    expect(book.status, JSON.stringify(book.body)).toBe(201);
    expect((await api('POST', '/cheque-books', { accountId: bank, fromNo: 100005, toNo: 100020 })).status).toBe(409);
    const pay = await api('POST', '/payments', { kind: 'payment', partyId: vendor, accountId: bank, mode: 'cheque', amount: 2000, date: '2026-04-15' });
    expect(pay.status, JSON.stringify(pay.body)).toBe(201);
    const ch = await api('POST', `/payments/${pay.body.id}/cheque`, {});
    expect(ch.status, JSON.stringify(ch.body)).toBe(201);
    expect(ch.body.chequeNo).toBe('100001');
    expect((await api('POST', `/payments/${pay.body.id}/cheque`, {})).status).toBe(409);
    const reg = (await api('GET', `/cheque-books/${book.body.id}/register`)).body.leaves;
    expect(reg[0]).toMatchObject({ no: '100001', status: 'issued', amount: 2000 });
    expect(reg[1].status).toBe('unused');
    const pr = (await api('GET', `/cheques/${ch.body.id}/print`)).body;
    expect(pr).toMatchObject({ chequeNo: '100001', dateText: '15042026', payee: 'Supplier', amountText: '2000.00', acPayee: true });
    expect(pr.layout.isDefault).toBe(true);
    const lay = { ...pr.layout, date: { x: 150, y: 12 } };
    delete lay.isDefault;
    expect((await api('PUT', `/bank-accounts/${bank}/cheque-layout`, lay)).status).toBe(200);
    expect((await api('GET', `/bank-accounts/${bank}/cheque-layout`)).body).toMatchObject({ isDefault: false, date: { x: 150, y: 12 } });
    // A bounced issued cheque puts the payment back.
    const bn = await api('POST', `/cheques/${ch.body.id}/bounce`, { reason: 'Dishonoured' });
    expect(bn.body.status).toBe('bounced');
    expect((await api('GET', `/payments/${pay.body.id}`)).body.status).toBe('cancelled');
  });
});
