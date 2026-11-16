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

async function biz() {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Limit Co', name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24', businessType: 'kirana',
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
  const sales = await userAs('Sana', 'Sales Executive');
  const admin = await userAs('Adam', 'Company Admin');
  const shop = (await api('POST', '/locations', { type: 'store', name: 'Shop', code: 'S1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Wholesaler', stateCode: '24' })).body;
  const item = (await api('POST', '/items', { name: 'Rice 10kg', sku: 'RICE', hsnCode: '1006', unit: 'bag', gstRate: 18, salePrice: 500, purchasePrice: 300, trackStock: true })).body;
  expect((await api('POST', '/purchases', { locationId: shop.id, partyId: vendor.id, lines: [{ itemId: item.id, qty: 200, rate: 300 }] })).status).toBe(201);
  const customer = async (limit: number, name = 'Credit Buyer') =>
    (await api('POST', '/parties', { type: 'customer', name, stateCode: '24', creditLimit: limit })).body as { id: string };
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string }[];
  return { api, sales, admin, shop, item, customer, cash: accounts.find((a) => a.code === '1000')!.id };
}
type Biz = Awaited<ReturnType<typeof biz>>;

// 10 bags at 500 + 18% GST = 5,900.
const invoiceBody = (b: Biz, partyId: string, qty = 10, extra: object = {}) =>
  ({ locationId: b.shop.id, partyId, lines: [{ itemId: b.item.id, qty, rate: 500 }], ...extra });
const orderBody = (b: Biz, partyId: string, qty = 10, extra: object = {}) =>
  ({ locationId: b.shop.id, partyId, lines: [{ itemId: b.item.id, qty, rate: 500 }], ...extra });

describe('credit limit on invoices', () => {
  it('refuses an invoice that takes the customer over the limit, with the figures', async () => {
    const b = await biz();
    const c = await b.customer(10000);
    expect((await b.api('POST', '/invoices', invoiceBody(b, c.id))).status).toBe(201);
    const second = await b.api('POST', '/invoices', invoiceBody(b, c.id));
    expect(second.status).toBe(409);
    expect(second.body.error.code).toBe('CREDIT_LIMIT_EXCEEDED');
    expect(second.body.error.details).toEqual({ creditLimit: 10000, owes: 5900, thisDocument: 5900, over: 1800 });
    // Nothing was saved.
    expect((await b.api('GET', `/invoices?partyId=${c.id}`)).body.total).toBe(1);
    // A smaller bill that fits is fine: 5,900 + 4,100 = 10,000 exactly (7 bags = 4,130 is over, 6 bags = 3,540 fits).
    expect((await b.api('POST', '/invoices', invoiceBody(b, c.id, 6))).status).toBe(201);
    const exact = await b.api('POST', '/invoices', invoiceBody(b, c.id, 1));
    expect(exact.status).toBe(409);
    expect(exact.body.error.details.owes).toBe(9440);
  });

  it('counts receipts, and treats a limit of zero as no limit', async () => {
    const b = await biz();
    const c = await b.customer(7000);
    expect((await b.api('POST', '/invoices', invoiceBody(b, c.id))).status).toBe(201);
    expect((await b.api('POST', '/invoices', invoiceBody(b, c.id))).status).toBe(409);
    expect((await b.api('POST', '/payments', { kind: 'receipt', partyId: c.id, accountId: b.cash, mode: 'cash', amount: 5900 })).status).toBe(201);
    expect((await b.api('POST', '/invoices', invoiceBody(b, c.id))).status).toBe(201);
    const free = await b.customer(0, 'No Limit Buyer');
    for (let i = 0; i < 3; i += 1) expect((await b.api('POST', '/invoices', invoiceBody(b, free.id))).status).toBe(201);
  });

  it('lets only holders of parties.credit_override bill anyway, and audits it', async () => {
    const b = await biz();
    const c = await b.customer(6000);
    expect((await b.api('POST', '/invoices', invoiceBody(b, c.id))).status).toBe(201);
    const asSales = await b.sales('POST', '/invoices', invoiceBody(b, c.id, 10, { allowOverLimit: true }));
    expect(asSales.status).toBe(403);
    expect((await b.sales('POST', '/invoices', invoiceBody(b, c.id))).body.error.code).toBe('CREDIT_LIMIT_EXCEEDED');
    const asAdmin = await b.admin('POST', '/invoices', invoiceBody(b, c.id, 10, { allowOverLimit: true }));
    expect(asAdmin.status, JSON.stringify(asAdmin.body)).toBe(201);
    const audit = (await b.api('GET', `/audit?entity=party&entityId=${c.id}`)).body.data as { action: string; after: any }[];
    expect(audit.map((a) => a.action)).toContain('credit_override');
    const row = audit.find((a) => a.action === 'credit_override')!;
    expect(JSON.parse(typeof row.after === 'string' ? row.after : JSON.stringify(row.after))).toMatchObject({ creditLimit: 6000, owes: 5900, over: 5800 });
    // The flag does nothing when the bill is within the limit.
    const roomy = await b.customer(50000, 'Roomy');
    expect((await b.sales('POST', '/invoices', invoiceBody(b, roomy.id, 10, { allowOverLimit: true }))).status).toBe(201);
  });

  it('owner roles hold the permission by default and sales and accounts roles do not', async () => {
    const b = await biz();
    const roles = (await b.api('GET', '/roles')).body.data as { name: string; permissions: string[] }[];
    const holders = roles.filter((r) => r.permissions?.includes('parties.credit_override')).map((r) => r.name).sort();
    expect(holders).toContain('Owner');
    expect(holders).toContain('Company Admin');
    expect(holders).not.toContain('Sales Executive');
    expect(holders).not.toContain('Accountant');
  });
});

describe('credit limit on sales orders', () => {
  it('checks orders, and counts open orders against later invoices', async () => {
    const b = await biz();
    const c = await b.customer(10000);
    const o1 = await b.api('POST', '/sales-orders', orderBody(b, c.id));
    expect(o1.status, JSON.stringify(o1.body)).toBe(201);
    const o2 = await b.api('POST', '/sales-orders', orderBody(b, c.id));
    expect(o2.status).toBe(409);
    expect(o2.body.error).toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED', details: { creditLimit: 10000, owes: 5900, thisDocument: 5900, over: 1800 } });
    const inv = await b.api('POST', '/invoices', invoiceBody(b, c.id));
    expect(inv.status).toBe(409);
    expect(inv.body.error.details.owes).toBe(5900);
    // A cancelled order stops counting.
    expect((await b.api('POST', `/sales-orders/${o1.body.id}/cancel`, { reason: 'Customer withdrew' })).status).toBe(200);
    expect((await b.api('POST', '/invoices', invoiceBody(b, c.id))).status).toBe(201);
  });

  it('override works on orders for holders only', async () => {
    const b = await biz();
    const c = await b.customer(1000);
    expect((await b.sales('POST', '/sales-orders', orderBody(b, c.id, 10, { allowOverLimit: true }))).status).toBe(403);
    const ok = await b.admin('POST', '/sales-orders', orderBody(b, c.id, 10, { allowOverLimit: true }));
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
  });
});

describe('quotation convert', () => {
  it('is checked against the quotation total, with the same override', async () => {
    const b = await biz();
    const c = await b.customer(1000);
    const q = await b.api('POST', '/quotations', { locationId: b.shop.id, partyId: c.id, lines: [{ itemId: b.item.id, qty: 10, rate: 500 }] });
    expect(q.status, JSON.stringify(q.body)).toBe(201);
    const blocked = await b.api('POST', `/quotations/${q.body.id}/convert`, { to: 'invoice' });
    expect(blocked.status).toBe(409);
    expect(blocked.body.error).toMatchObject({ code: 'CREDIT_LIMIT_EXCEEDED', details: { creditLimit: 1000, owes: 0, thisDocument: 5900, over: 4900 } });
    expect((await b.api('GET', `/quotations/${q.body.id}`)).body.status).not.toBe('converted');
    expect((await b.api('POST', `/quotations/${q.body.id}/convert`, { to: 'sales_order', allowOverLimit: true })).status).toBe(200);
  });
});

describe('flows that are not blocked', () => {
  it('counter billing to a customer over the limit still posts', async () => {
    const b = await biz();
    const c = await b.customer(100);
    const sess = await b.api('POST', '/pos/sessions', { locationId: b.shop.id, openingFloat: 0 });
    expect(sess.status, JSON.stringify(sess.body)).toBe(201);
    const sale = await b.api('POST', '/pos/sales', {
      sessionId: sess.body.id, partyId: c.id, lines: [{ itemId: b.item.id, qty: 10 }], payments: [{ mode: 'cash', amount: 5900 }],
    });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
  });
});
