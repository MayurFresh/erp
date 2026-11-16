import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

const PASSWORD = 'Secret@123';
const today = () => new Date(Date.now() + 5.5 * 3600_000).toISOString().slice(0, 10);

async function biz() {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Returns Co', name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, signup.body.accessToken, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const userAs = async (name: string, roleName: string) => {
    const email = uniqueEmail(name.toLowerCase());
    expect((await api('POST', '/users', { name, email, password: PASSWORD, roleId: roles.find((r) => r.name === roleName)!.id })).status).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    return client(env.app, login.body.accessToken, companyId);
  };
  const keeper = await userAs('Kiran', 'Store Keeper');
  const accountant = await userAs('Anita', 'Accountant');
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const farVendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor Far', stateCode: '27' })).body;
  const customer = (await api('POST', '/parties', { type: 'customer', name: 'Buyer', stateCode: '24' })).body;
  const cement = (await api('POST', '/items', {
    name: 'Cement 50kg', sku: 'CEM-50', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 500, purchasePrice: 400, trackStock: true,
  })).body;
  const freight = (await api('POST', '/items', {
    name: 'Freight service', sku: 'FRT', hsnCode: '9965', unit: 'job', gstRate: 18, salePrice: 0, purchasePrice: 1000, trackStock: false,
  })).body;
  expect(cement.id, JSON.stringify(cement)).toBeTruthy();
  return { api, keeper, accountant, wh, vendor, farVendor, customer, cement, freight };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const bill = async (b: Biz, qty = 10, extra: Record<string, unknown> = {}, partyId?: string, itemId?: string) => {
  const r = await b.api('POST', '/purchases', {
    locationId: b.wh.id, partyId: partyId ?? b.vendor.id, supplierInvoiceNo: 'S-1',
    lines: [{ itemId: itemId ?? b.cement.id, qty, rate: itemId === b.freight.id ? 1000 : 400 }], ...extra,
  });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body;
};
const ret = (b: Biz, body: Record<string, unknown>, who: 'api' | 'keeper' | 'accountant' = 'api') => b[who]('POST', '/purchase-returns', body);
const goods = async (b: Biz, p: any, qty: number, who: 'api' | 'accountant' = 'api') =>
  ret(b, { purchaseId: p.id, kind: 'goods', reason: 'Damaged on arrival', lines: [{ purchaseLineId: p.lines[0].id, qty }] }, who);
const stockOf = async (b: Biz) => {
  const rows = (await b.api('GET', '/stock?limit=200')).body.data as { itemId: string; qty: number; value: number }[];
  const r = rows.filter((x) => x.itemId === b.cement.id);
  return { qty: r.reduce((s, x) => s + x.qty, 0), value: Math.round(r.reduce((s, x) => s + x.value, 0) * 100) / 100 };
};
const tb = async (b: Biz) => {
  const t = (await b.api('GET', '/reports/trial-balance')).body;
  expect(t.totalDebit).toBe(t.totalCredit);
  return (code: string) => {
    const row = t.rows.find((r: any) => r.code === code);
    return row ? Math.round((row.debit - row.credit) * 100) / 100 : 0;
  };
};
const owed = async (b: Biz, partyId: string) => (await b.api('GET', `/parties/${partyId}/outstanding`)).body.balance as number;
const itc = async (b: Biz) => (await b.api('GET', `/gst/gstr3b?period=${today().slice(0, 7)}`)).body.itc;

describe('goods returns', () => {
  it('full return reverses stock, tax and the vendor balance, and cancelling brings it all back', async () => {
    const b = await biz();
    const p = await bill(b, 10);
    expect(p.total).toBe(4720);
    expect(await owed(b, b.vendor.id)).toBe(-4720);

    const r = await goods(b, p, 10);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(r.body).toMatchObject({ kind: 'goods', status: 'posted', subtotal: 4000, cgst: 360, sgst: 360, igst: 0, total: 4720, appliedAmount: 4720, stockValue: 4000, supplyType: 'intra' });
    expect(r.body.number).toMatch(/^DN\//);
    expect(r.body.lines[0]).toMatchObject({ qty: 10, taxableValue: 4000, stockValue: 4000 });

    expect(await stockOf(b)).toEqual({ qty: 0, value: 0 });
    expect(await owed(b, b.vendor.id)).toBe(0);
    const t = await tb(b);
    expect([t('2000'), t('1200'), t('1300'), t('1301')]).toEqual([0, 0, 0, 0]);
    const after = (await b.api('GET', `/purchases/${p.id}`)).body;
    expect(after).toMatchObject({ amountPaid: 4720, amountDue: 0, paymentStatus: 'paid' });
    expect(after.settlements).toEqual([expect.objectContaining({ kind: 'debit_note', number: r.body.number, amount: 4720 })]);
    expect((await b.api('GET', '/reports/ageing?type=payables')).body.rows).toEqual([]);

    const blocked = await b.api('POST', `/purchases/${p.id}/cancel`, { reason: 'Mistake' });
    expect(blocked.status).toBe(409);
    expect(['HAS_RETURNS', 'HAS_SETTLEMENTS']).toContain(blocked.body.error.code);

    const c = await b.accountant('POST', `/purchase-returns/${r.body.id}/cancel`, { reason: 'Vendor changed mind' });
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    expect(c.body.status).toBe('cancelled');
    expect(await stockOf(b)).toEqual({ qty: 10, value: 4000 });
    expect(await owed(b, b.vendor.id)).toBe(-4720);
    const t2 = await tb(b);
    expect([t2('2000'), t2('1200'), t2('1300'), t2('1301')]).toEqual([-4720, 4000, 360, 360]);
    expect((await b.api('GET', `/purchases/${p.id}`)).body).toMatchObject({ amountPaid: 0, amountDue: 4720 });
    expect((await b.api('POST', `/purchase-returns/${r.body.id}/cancel`, { reason: 'Again please' })).status).toBe(409);
    // The line can be returned again after the cancel.
    expect((await goods(b, p, 10)).status).toBe(201);
  });

  it('partial returns, the last one takes the remainder, and over-returns are refused', async () => {
    const b = await biz();
    const p = await bill(b, 10);
    const r1 = await goods(b, p, 4);
    expect(r1.body).toMatchObject({ subtotal: 1600, cgst: 144, sgst: 144, total: 1888, stockValue: 1600 });
    expect(await stockOf(b)).toEqual({ qty: 6, value: 2400 });
    expect(await owed(b, b.vendor.id)).toBe(-2832);

    const over = await goods(b, p, 7);
    expect(over.status).toBe(409);
    expect(over.body.error.code).toBe('OVER_RETURN');
    expect(over.body.error.details).toMatchObject({ lineNo: 1, billed: 10, returned: 4, left: 6 });
    expect((await goods(b, p, 6)).body).toMatchObject({ subtotal: 2400, total: 2832 });
    expect((await goods(b, p, 1)).body.error.code).toBe('OVER_RETURN');
    expect(await owed(b, b.vendor.id)).toBe(0);
    const list = (await b.api('GET', `/purchase-returns?purchaseId=${p.id}`)).body;
    expect(list.total).toBe(2);
    expect((await b.api('GET', `/purchase-returns/${r1.body.id}`)).body.lines).toHaveLength(1);
  });

  it('refuses goods that are no longer on hand', async () => {
    const b = await biz();
    const p = await bill(b, 10);
    const sale = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.cement.id, qty: 8, rate: 500 }] });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    const r = await goods(b, p, 5);
    expect(r.status).toBe(409);
    expect(r.body.error.code).toBe('INSUFFICIENT_STOCK');
    expect((await goods(b, p, 2)).status).toBe(201);
  });

  it('inter-state bills reverse IGST', async () => {
    const b = await biz();
    const p = await bill(b, 10, {}, b.farVendor.id);
    expect(p).toMatchObject({ igst: 720, cgst: 0 });
    const r = await goods(b, p, 5);
    expect(r.body).toMatchObject({ supplyType: 'inter', subtotal: 2000, igst: 360, cgst: 0, sgst: 0, total: 2360 });
    const t = await tb(b);
    expect(t('1302')).toBe(360);
    expect(await owed(b, b.farVendor.id)).toBe(-2360);
  });

  it('non-stock items return without moving stock', async () => {
    const b = await biz();
    const p = await bill(b, 2, {}, undefined, b.freight.id);
    const r = await goods(b, p, 1);
    expect(r.body).toMatchObject({ subtotal: 1000, total: 1180, stockValue: 0 });
    const t = await tb(b);
    expect(t('5100')).toBe(1000);
    expect(t('1200')).toBe(0);
  });

  it('TDS comes back in proportion', async () => {
    const b = await biz();
    const sections = (await b.api('GET', '/tds-sections')).body.data as { id: string; code: string }[];
    const sec = sections.find((s) => s.code === '194J(a)')!;
    const v = (await b.api('POST', '/parties', { type: 'vendor', name: 'Consultant', stateCode: '24', pan: 'AAAPM1234C', tdsSectionId: sec.id })).body;
    const p = await bill(b, 250, {}, v.id);
    expect(p.tdsAmount).toBe(10000);
    expect(await owed(b, v.id)).toBe(-(p.total - 10000));
    const r = await goods(b, p, 125);
    expect(r.body).toMatchObject({ subtotal: 50000, tdsReversed: 5000 });
    expect(await owed(b, v.id)).toBe(-(p.total - 10000) / 2);
    const rest = await goods(b, p, 125);
    expect(rest.body.tdsReversed).toBe(5000);
    expect(await owed(b, v.id)).toBe(0);
    const t = await tb(b);
    expect(t('2110')).toBe(0);
  });
});

describe('price returns', () => {
  it('reduce the bill and the tax without moving stock', async () => {
    const b = await biz();
    const p = await bill(b, 10);
    const r = await ret(b, { purchaseId: p.id, kind: 'price', reason: 'Quality discount', lines: [{ purchaseLineId: p.lines[0].id, amount: 500 }] });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(r.body).toMatchObject({ kind: 'price', subtotal: 500, cgst: 45, sgst: 45, total: 590, stockValue: 0, appliedAmount: 590 });
    expect(await stockOf(b)).toEqual({ qty: 10, value: 4000 });
    expect(await owed(b, b.vendor.id)).toBe(-4130);
    const t = await tb(b);
    expect(t('5110')).toBe(-500);
    expect(t('1300')).toBe(315);
    expect((await b.api('GET', '/reports/ageing?type=payables')).body.totals.total).toBe(4130);

    const over = await ret(b, { purchaseId: p.id, kind: 'price', reason: 'More', lines: [{ purchaseLineId: p.lines[0].id, amount: 3501 }] });
    expect(over.status).toBe(409);
    expect(over.body.error.code).toBe('OVER_RETURN');
    expect((await ret(b, { purchaseId: p.id, kind: 'price', reason: 'More', lines: [{ purchaseLineId: p.lines[0].id, qty: 1 }] })).status).toBe(400);
  });
});

describe('reverse charge, GSTR-3B and rules', () => {
  it('a reverse-charge bill reverses its RCM entries', async () => {
    const b = await biz();
    const p = await bill(b, 10, { reverseCharge: true });
    expect(p).toMatchObject({ total: 4000, reverseCharge: true });
    const before = await tb(b);
    expect([before('2130'), before('1300')]).toEqual([-720, 360]);
    const r = await goods(b, p, 5);
    expect(r.body).toMatchObject({ reverseCharge: true, subtotal: 2000, cgst: 180, sgst: 180, total: 2000 });
    const t = await tb(b);
    expect([t('2130'), t('1300'), t('1301')]).toEqual([-360, 180, 180]);
    expect(await owed(b, b.vendor.id)).toBe(-2000);
    const g = await itc(b);
    expect(g.rcm).toMatchObject({ taxable: 2000, cgst: 180, sgst: 180 });
  });

  it('reduces GSTR-3B input credit, and cancelling restores it', async () => {
    const b = await biz();
    const p = await bill(b, 10);
    expect((await itc(b)).others).toMatchObject({ taxable: 4000, cgst: 360, sgst: 360 });
    const r = await goods(b, p, 4);
    expect((await itc(b)).others).toMatchObject({ taxable: 2400, cgst: 216, sgst: 216 });
    expect((await itc(b)).net).toMatchObject({ cgst: 216, sgst: 216 });
    await b.api('POST', `/purchase-returns/${r.body.id}/cancel`, { reason: 'Reversed' });
    expect((await itc(b)).others).toMatchObject({ taxable: 4000, cgst: 360, sgst: 360 });
  });

  it('a return on a paid bill leaves a debit balance with the vendor', async () => {
    const b = await biz();
    const p = await bill(b, 10);
    const accounts = (await b.api('GET', '/accounts')).body.data as { id: string; code: string }[];
    const pay = await b.api('POST', '/payments', { kind: 'payment', partyId: b.vendor.id, accountId: accounts.find((x) => x.code === '1010')!.id, mode: 'bank', amount: 4720 });
    expect(pay.status, JSON.stringify(pay.body)).toBe(201);
    const r = await goods(b, p, 10);
    expect(r.body).toMatchObject({ total: 4720, appliedAmount: 0 });
    expect(await owed(b, b.vendor.id)).toBe(4720);
  });

  it('cancelled bills cannot be returned; locked periods are refused', async () => {
    const b = await biz();
    const gone = await bill(b, 3);
    expect((await b.api('POST', `/purchases/${gone.id}/cancel`, { reason: 'Entered twice' })).status).toBe(200);
    const r0 = await goods(b, gone, 1);
    expect(r0.status).toBe(409);
    expect(r0.body.error.code).toBe('BILL_CANCELLED');

    const p = await bill(b, 10);
    const early = await ret(b, { purchaseId: p.id, kind: 'goods', reason: 'Too early', returnDate: '2000-01-01', lines: [{ purchaseLineId: p.lines[0].id, qty: 1 }] });
    expect(early.status).toBe(400);
    const ok = await goods(b, p, 1);
    expect(ok.status).toBe(201);
    expect((await b.api('PATCH', '/company', { booksLockedUntil: today() })).status).toBe(200);
    const locked = await goods(b, p, 1);
    expect(locked.status).toBe(409);
    expect(locked.body.error.code).toBe('PERIOD_LOCKED');
    const cancel = await b.api('POST', `/purchase-returns/${ok.body.id}/cancel`, { reason: 'Locked now' });
    expect(cancel.status).toBe(409);
    expect(cancel.body.error.code).toBe('PERIOD_LOCKED');
  });

  it('checks permissions and writes audit rows', async () => {
    const b = await biz();
    const p = await bill(b, 10);
    expect((await goods(b, p, 1, 'keeper' as any)).status).toBe(403);
    expect((await b.keeper('GET', '/purchase-returns')).status).toBe(200);
    const r = await goods(b, p, 1, 'accountant');
    expect(r.status).toBe(201);
    expect((await b.accountant('GET', `/purchase-returns/${r.body.id}`)).status).toBe(200);
    expect((await b.api('POST', `/purchase-returns/${r.body.id}/cancel`, { reason: 'x' })).status).toBe(400);
    expect((await b.api('POST', `/purchase-returns/${r.body.id}/cancel`, { reason: 'Wrong item' })).status).toBe(200);
    const audit = (await b.api('GET', '/audit?entity=purchase_return')).body;
    expect(audit.data.map((a: any) => a.action).sort()).toEqual(['cancel', 'create']);
    expect((await b.api('GET', '/purchase-returns?status=cancelled')).body.total).toBe(1);
    expect((await b.api('GET', '/purchase-returns?q=Vendor')).body.total).toBe(1);
  });
});
