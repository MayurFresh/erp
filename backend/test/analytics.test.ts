import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const PASSWORD = 'Secret@123';

async function biz(name: string) {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, signup.body.accessToken, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const userAs = async (roleName: string) => {
    const email = uniqueEmail('u');
    const c = await api('POST', '/users', { name: roleName, email, password: PASSWORD, roleId: roles.find((r) => r.name === roleName)!.id });
    expect(c.status).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    return client(env.app, login.body.accessToken, companyId);
  };
  return { api, userAs };
}

async function withSales(name: string) {
  const b = await biz(name);
  const wh = (await b.api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const vendor = (await b.api('POST', '/parties', { type: 'vendor', name: 'Vendor', stateCode: '24' })).body;
  const customer = (await b.api('POST', '/parties', { type: 'customer', name: `${name} Customer`, stateCode: '24' })).body;
  const item = (await b.api('POST', '/items', { name: 'Tile', sku: 'T1', hsnCode: '6907', unit: 'nos', gstRate: 18, salePrice: 100, purchasePrice: 60, trackStock: true })).body;
  expect((await b.api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId: item.id, qty: 20, rate: 60 }] })).status).toBe(201);
  expect((await b.api('POST', '/invoices', { locationId: wh.id, partyId: customer.id, lines: [{ itemId: item.id, qty: 5 }] })).status).toBe(201);
  return b;
}

describe('analytics overview', () => {
  it('returns an empty but well-formed result for a new company', async () => {
    const b = await biz('Empty Co');
    const r = await b.api('GET', '/analytics/overview');
    expect(r.status).toBe(200);
    expect(r.body.kpis.current.sales).toBe(0);
    expect(r.body.kpis.previous.sales).toBe(0);
    expect(r.body.topCustomers).toEqual([]);
    expect(r.body.ageing.receivables.total).toBe(0);
    expect(r.body.trend.length).toBeGreaterThan(0);
  });

  it('totals the period and ranks customers', async () => {
    const b = await withSales('Alpha');
    const r = await b.api('GET', '/analytics/overview');
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.kpis.current.sales).toBe(500);
    expect(r.body.kpis.current.purchases).toBe(1200);
    expect(r.body.topCustomers[0]).toMatchObject({ name: 'Alpha Customer', amount: 500, share: 100 });
    expect(r.body.topItems[0]).toMatchObject({ name: 'Tile', qty: 5 });
    expect(r.body.ageing.receivables.total).toBeGreaterThan(0);
    expect(r.body.kpis.current.stockValue).toBeDefined();
  });

  it('isolates companies and validates the range', async () => {
    const a = await withSales('Beta');
    const other = await biz('Gamma');
    const r = await other.api('GET', '/analytics/overview');
    expect(r.body.kpis.current.sales).toBe(0);
    expect(r.body.topCustomers).toEqual([]);
    expect((await a.api('GET', '/analytics/overview?from=2030-01-01&to=2029-01-01')).status).toBe(400);
    expect((await a.api('GET', '/analytics/overview?from=bad')).status).toBe(400);
  });

  it('hides cost and profit fields from roles without them', async () => {
    const b = await withSales('Delta');
    // Project Manager holds reports.view but not accounts.view, payments.view or items.view_cost.
    const pm = await b.userAs('Project Manager');
    const r = await pm('GET', '/analytics/overview');
    expect(r.status).toBe(200);
    expect(r.body.kpis.current.netProfit).toBeUndefined();
    expect(r.body.kpis.current.stockValue).toBeUndefined();
    expect(r.body.kpis.current.receivables).toBeUndefined();
    const owner = await b.api('GET', '/analytics/overview');
    expect(owner.body.kpis.current.netProfit).toBeDefined();
  });

  it('refuses roles without reports.view', async () => {
    const b = await withSales('Eps');
    const keeper = await b.userAs('Store Keeper');
    expect((await keeper('GET', '/analytics/overview')).status).toBe(403);
    const sales = await b.userAs('Sales Executive');
    expect((await sales('GET', '/analytics/overview')).status).toBe(403);
  });
});
