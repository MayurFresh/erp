import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { gstinChecksumOk } from '../src/modules/gst-filing.ts';
import { setoff } from '../src/lib/gst-setoff.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

const z = { igst: 0, cgst: 0, sgst: 0, cess: 0 };
const H = (igst: number, cgst: number, sgst: number, cess = 0) => ({ igst, cgst, sgst, cess });
const mv = (r: ReturnType<typeof setoff>, from: string, to: string) => r.matrix.find((m) => m.from === from && m.to === to)?.amount ?? 0;

describe('set-off rules (unit)', () => {
  it('uses IGST credit across heads and the rest from SGST credit or cash', () => {
    const r = setoff({ liability: H(40, 50, 30), rcm: z, credit: H(100, 0, 20), interest: 0, lateFee: 0, igstSplit: 'cgst_first' });
    expect(mv(r, 'igst', 'igst')).toBe(40);
    expect(mv(r, 'igst', 'cgst')).toBe(50);
    expect(mv(r, 'igst', 'sgst')).toBe(10);
    expect(mv(r, 'sgst', 'sgst')).toBe(20);
    expect(r.cash.total).toBe(0);
    const cashOnly = setoff({ liability: H(40, 50, 30), rcm: z, credit: H(100, 0, 0), interest: 0, lateFee: 0, igstSplit: 'cgst_first' });
    expect(cashOnly.cash.tax.sgst).toBe(20);
    expect(cashOnly.cash.total).toBe(20);
  });
  it('pays RCM, interest and late fee in cash only', () => {
    const r = setoff({ liability: H(0, 100, 100), rcm: H(0, 50, 50), credit: H(500, 500, 500), interest: 70, lateFee: 30, igstSplit: 'cgst_first' });
    expect(r.cash.tax).toMatchObject({ cgst: 50, sgst: 50 });
    expect(r.cash.interest).toBe(70);
    expect(r.cash.lateFee).toBe(30);
    expect(r.cash.total).toBe(200);
  });
  it('handles cess in cash and the sgst_first order', () => {
    const c = setoff({ liability: H(0, 0, 0, 40), rcm: z, credit: H(100, 100, 100, 10), interest: 0, lateFee: 0, igstSplit: 'cgst_first' });
    expect(c.cash.tax.cess).toBe(30);
    const s = setoff({ liability: H(0, 50, 50), rcm: z, credit: H(60, 0, 0), interest: 0, lateFee: 0, igstSplit: 'sgst_first' });
    expect(mv(s, 'igst', 'sgst')).toBe(50);
    expect(mv(s, 'igst', 'cgst')).toBe(10);
    expect(s.cash.tax.cgst).toBe(40);
  });
  it('checks the GSTIN checksum', () => {
    expect(gstinChecksumOk('27AAPFU0939F1ZV')).toBe(true);
    expect(gstinChecksumOk('27AAPFU0939F1ZX')).toBe(false);
  });
});

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Shah Constructions', name: 'Meera Shah', email: uniqueEmail('owner'), password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const claims = JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!;
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse' })).body;
  const item = (await api('POST', '/items', { name: 'Cement', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50 })).body;
  const customer = (await api('POST', '/parties', { type: 'customer', name: 'Local Buyer', stateCode: '24' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Supplier', stateCode: '24' })).body;
  const csv = async (url: string) => {
    const r = await env.app.inject({ method: 'GET', url: `/api/v1${url}`, headers: { authorization: `Bearer ${token}`, 'x-company-id': companyId } });
    return { status: r.statusCode, text: r.body };
  };
  const db = <T>(fn: Parameters<typeof withTenant<T>>[2]) => withTenant(env.db, claims.tid as string, fn);
  const cashBalance = async () => {
    const r = await api('GET', `/accounts/${account('1320').id}/ledger`);
    return (r.body.closingBalance ?? r.body.closing ?? r.body.balance) as number;
  };
  return { api, csv, account, wh, item, customer, vendor, db, cashBalance };
}
type B = Awaited<ReturnType<typeof business>>;
const period = () => todayIst().slice(0, 7);
const sell = (b: B, qty: number) => b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.item.id, qty }] });
const buy = (b: B, qty: number, billDate?: string) =>
  b.api('POST', '/purchases', { locationId: b.wh.id, partyId: b.vendor.id, billDate, supplierInvoiceNo: `S/${Math.random()}`, lines: [{ itemId: b.item.id, qty, rate: 50 }] });

describe('ledger snapshots and 3B fields', () => {
  it('uses a credit snapshot as opening credit and validates input', async () => {
    const b = await business();
    await buy(b, 100); // so stock exists
    expect((await sell(b, 10)).status).toBe(201); // 90 + 90
    const before = (await b.api('GET', `/gst/setoff?period=${period()}`)).body;
    expect(before.credit.opening).toMatchObject({ cgst: 0 });
    const snap = await b.api('POST', '/gst/ledger-balances', { ledger: 'credit', asOf: addDays(todayIst(), -60), igst: 0, cgst: 1000, sgst: 1000 });
    expect(snap.status).toBe(201);
    expect((await b.api('POST', '/gst/ledger-balances', { ledger: 'bad', asOf: todayIst(), igst: 0, cgst: 0, sgst: 0 })).status).toBe(400);
    const after = (await b.api('GET', `/gst/setoff?period=${period()}`)).body;
    expect(after.credit.opening).toMatchObject({ cgst: 1000, sgst: 1000 });
    expect(after.cash.total).toBe(0);
    expect((await b.api('GET', '/gst/ledger-balances')).body.data).toHaveLength(1);
  });

  it('reverses ITC under Rule 37 after 180 days and reclaims it on payment', async () => {
    const b = await business();
    const old = addDays(todayIst(), -185);
    const rp = addDays(old, 180).slice(0, 7);
    expect((await buy(b, 100, old)).status).toBe(201);
    const rev = (await b.api('GET', `/gst/itc-reversals?period=${rp}`)).body;
    const r = rev.rows.find((x: { kind: string }) => x.kind === 'reversal');
    expect(r).toBeTruthy();
    expect(r.cgst).toBe(450);
    const g3 = (await b.api('GET', `/gst/gstr3b?period=${rp}`)).body;
    expect(g3.itc.reversed.rule37.cgst).toBe(450);
    const csv = await b.csv(`/gst/itc-reversals?period=${rp}&format=csv`);
    expect(csv.status).toBe(200);
    const pay = await b.api('POST', '/payments', { kind: 'payment', partyId: b.vendor.id, accountId: b.account('1010').id, mode: 'bank', amount: 5900, reference: 'NEFT0001' });
    expect(pay.status).toBe(201);
    const rev2 = (await b.api('GET', `/gst/itc-reversals?period=${period()}`)).body;
    expect(rev2.rows.some((x: { kind: string }) => x.kind === 'reclaim')).toBe(true);
    const g3b = (await b.api('GET', `/gst/gstr3b?period=${period()}`)).body;
    expect(g3b.itc.reclaimed.cgst).toBe(450);
  });
});

describe('prefile gate and register', () => {
  it('blocks on a failed sequence check, then records it when acknowledged', async () => {
    const b = await business();
    await buy(b, 100, addDays(todayIst(), -100));
    const body = { returnType: 'gstr1', period: period(), filedOn: todayIst(), arn: 'AA2701260000001' };
    const blocked = await b.api('POST', '/filings', body);
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('PREFILE_FAILED');
    expect(blocked.body.error.details.checks.some((c: { id: string; status: string }) => c.id === 'sequence' && c.status === 'fail')).toBe(true);
    const ok = await b.api('POST', '/filings', { ...body, acknowledgeFailures: true });
    expect(ok.status).toBe(201);
    expect(ok.body.acknowledgedFailures.length).toBeGreaterThan(0);
    expect((await b.api('POST', '/filings', { ...body, acknowledgeFailures: true })).body.error.code).toBe('ALREADY_FILED');
    const list = (await b.api('GET', '/filings?returnType=gstr1&status=filed')).body;
    expect(list.total).toBe(1);
    expect((await b.api('POST', '/filings', { ...body, period: 'nope' })).status).toBe(400);
    const check = (await b.api('GET', `/gst/prefile-check?period=${period()}&return=gstr3b`)).body;
    expect(check.checks.map((c: { id: string }) => c.id)).toContain('gstr1_filed');
    expect(typeof check.canFile).toBe('boolean');
  });
});

describe('PMT-06 payments and 3B set-off', () => {
  it('posts the payment journal and cancels it', async () => {
    const b = await business();
    const pay = await b.api('POST', '/gst/payments', { date: todayIst(), paidFromAccountId: b.account('1010').id, igst: 0, cgst: 100, sgst: 100, cin: 'CIN123' });
    expect(pay.status).toBe(201);
    expect(pay.body.total).toBe(200);
    expect(pay.body.number).toMatch(/^GPM\//);
    expect(await b.cashBalance()).toBe(200);
    const bad = await b.api('POST', '/gst/payments', { date: todayIst(), paidFromAccountId: b.account('1010').id, igst: 0, cgst: 0, sgst: 0 });
    expect(bad.status).toBe(400);
    const cancel = await b.api('POST', `/gst/payments/${pay.body.id}/cancel`, { reason: 'Wrong amount' });
    expect(cancel.status).toBe(200);
    expect(cancel.body.status).toBe('cancelled');
    expect(await b.cashBalance()).toBe(0);
    expect((await b.api('POST', `/gst/payments/${pay.body.id}/cancel`, { reason: 'Again' })).status).toBe(409);
    expect((await b.api('GET', '/gst/payments')).body.total).toBe(1);
  });

  it('refuses a set-off without cash, posts it after a payment, and cancel reverses it', async () => {
    const b = await business();
    await buy(b, 10); // input 45 + 45
    expect((await sell(b, 10)).status).toBe(201); // output 90 + 90
    const so = (await b.api('GET', `/gst/setoff?period=${period()}`)).body;
    expect(so.cash.tax).toMatchObject({ cgst: 45, sgst: 45 });
    expect(so.shortfall.total).toBe(90);
    const g1 = await b.api('POST', '/filings', { returnType: 'gstr1', period: period(), filedOn: todayIst() });
    expect(g1.status).toBe(201);
    const body = { returnType: 'gstr3b', period: period(), filedOn: todayIst(), postSetoff: true, acknowledgeFailures: true };
    const short = await b.api('POST', '/filings', body);
    expect(short.status).toBe(409);
    expect(short.body.error.code).toBe('CASH_SHORTFALL');
    expect(short.body.error.details.shortfall).toMatchObject({ cgst: 45, sgst: 45, igst: 0 });
    const pay = await b.api('POST', '/gst/payments', { date: todayIst(), paidFromAccountId: b.account('1010').id, igst: 0, cgst: 45, sgst: 45 });
    expect(pay.status).toBe(201);
    const filed = await b.api('POST', '/filings', body);
    expect(filed.status).toBe(201);
    expect(filed.body.setoffEntryId).toBeTruthy();
    expect(await b.cashBalance()).toBe(0);
    const lines = await b.db(async (tx) => tx.selectFrom('journal_lines').select(['debit', 'credit', 'account_id']).where('entry_id', '=', filed.body.setoffEntryId).execute());
    const on = (code: string) => lines.filter((l) => l.account_id === b.account(code).id).reduce((s, l) => s + l.debit - l.credit, 0);
    expect(on('1320')).toBe(-90);
    // payment is now needed by the set-off
    expect((await b.api('POST', `/gst/payments/${pay.body.id}/cancel`, { reason: 'Oops' })).body.error.code).toBe('IN_USE');
    const cancel = await b.api('POST', `/filings/${filed.body.id}/cancel`, { reason: 'Filed wrongly' });
    expect(cancel.status).toBe(200);
    expect(cancel.body.status).toBe('cancelled');
    expect(await b.cashBalance()).toBe(90);
    expect((await b.api('POST', `/filings/${filed.body.id}/cancel`, { reason: 'Again please' })).status).toBe(409);
  });
  it('files a nil 3B with postSetoff and no journal, and cancels it', async () => {
    const b = await business();
    const filed = await b.api('POST', '/filings', { returnType: 'gstr3b', period: period(), filedOn: todayIst(), postSetoff: true, acknowledgeFailures: true });
    expect(filed.status).toBe(201);
    expect(filed.body.setoffEntryId).toBeNull();
    expect((await b.api('POST', `/filings/${filed.body.id}/cancel`, { reason: 'Nil return refiled' })).status).toBe(200);
  });
});

describe('calendar, alerts and GSTR-9', () => {
  it('lists the calendar and drops filed returns from alerts', async () => {
    const b = await business();
    await sell(b, 1);
    const cal = (await b.api('GET', '/filings/calendar')).body;
    expect(cal.rows.some((r: { returnType: string }) => r.returnType === 'gstr3b')).toBe(true);
    expect(cal.rows.filter((r: { returnType: string }) => r.returnType === 'advance_tax')).toHaveLength(4);
    expect((await b.api('GET', '/filings/calendar?fy=bad')).status).toBe(400);
    const alerts = async () => (await b.api('GET', '/compliance/alerts?days=60')).body.data as { kind: string; title: string }[];
    const before = (await alerts()).filter((a) => a.kind === 'gstr1_due');
    expect(before.length).toBeGreaterThan(0);
    const periods = before.map((a) => /for (\d{4}-\d{2})/.exec(a.title)![1]!);
    for (const p of periods) {
      const r = await b.api('POST', '/filings', { returnType: 'gstr1', period: p, filedOn: todayIst(), acknowledgeFailures: true });
      expect(r.status).toBe(201);
    }
    expect((await alerts()).filter((a) => a.kind === 'gstr1_due')).toHaveLength(0);
    const filedRow = (await b.api('GET', '/filings/calendar')).body.rows.find((r: { returnType: string; status: string }) => r.returnType === 'gstr1' && r.status === 'filed');
    expect(filedRow?.filingId).toBeTruthy();
  });

  it('returns the GSTR-9 shape', async () => {
    const b = await business();
    await buy(b, 100);
    await sell(b, 10);
    const y = Number(todayIst().slice(0, 4)) - (todayIst().slice(5, 7) < '04' ? 1 : 0);
    const fy = `${y}-${String((y + 1) % 100).padStart(2, '0')}`;
    const g = await b.api('GET', `/gst/gstr9?fy=${fy}`);
    expect(g.status).toBe(200);
    expect(g.body.tables.t4.b2c.taxable).toBe(1000);
    expect(g.body.tables.t6.others.cgst).toBe(450);
    expect(Array.isArray(g.body.tables.t17)).toBe(true);
    expect(g.body.monthly).toHaveLength(12);
    expect(g.body.mandatory).toBe(false);
    const gcsv = await b.csv(`/gst/gstr9?fy=${fy}&format=csv`);
    expect(gcsv.status).toBe(200);
    expect(gcsv.text).toContain('Table 4');
    expect((await b.api('GET', '/gst/gstr9?fy=2026')).status).toBe(400);
  });
});
