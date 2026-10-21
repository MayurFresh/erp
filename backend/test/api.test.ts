import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'kysely';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;

beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

async function signup(stateCode = '24') {
  const email = uniqueEmail('owner');
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Shree Builders', name: 'Ravi Patel', email, password: 'Secret@123', stateCode,
  });
  expect(res.status).toBe(201);
  const me = await client(env.app, res.body.accessToken)('GET', '/me');
  return { email, auth: res.body, me: me.body, api: client(env.app, res.body.accessToken, me.body.companies[0].id) };
}

describe('auth', () => {
  it('signs up an owner with full access to a new company', async () => {
    const { me, auth } = await signup();
    expect(auth.expiresIn).toBe(900);
    expect(me.user.name).toBe('Ravi Patel');
    expect(me.companies).toHaveLength(1);
    expect(me.companies[0]).toMatchObject({ name: 'Shree Builders', stateCode: '24', locationIds: null });
    expect(me.companies[0].roles.map((r: { name: string }) => r.name)).toEqual(['Owner']);
    expect(me.companies[0].permissions).toContain('roles.manage');
  });

  it('rejects a duplicate email, case-insensitively', async () => {
    const { email } = await signup();
    const res = await client(env.app)('POST', '/auth/signup', {
      businessName: 'Other', name: 'Someone', email: email.toUpperCase(), password: 'Secret@123', stateCode: '24',
    });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('CONFLICT');
  });

  it('validates signup input with field details', async () => {
    const res = await client(env.app)('POST', '/auth/signup', {
      businessName: 'X', name: 'Y', email: 'not-an-email', password: 'short', stateCode: '99',
    });
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('VALIDATION_ERROR');
    expect(Object.keys(res.body.error.details)).toEqual(expect.arrayContaining(['email', 'password', 'stateCode']));
  });

  it('logs in, and refuses a wrong password', async () => {
    const { email } = await signup();
    const bad = await client(env.app)('POST', '/auth/login', { email, password: 'Wrong@123' });
    expect(bad.status).toBe(401);
    const ok = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    expect(ok.status).toBe(200);
    expect(ok.body.user.email).toBe(email);
  });

  it('rotates refresh tokens and ends all sessions when an old one is reused', async () => {
    const { auth } = await signup();
    const first = await client(env.app)('POST', '/auth/refresh', { refreshToken: auth.refreshToken });
    expect(first.status).toBe(200);
    const reuse = await client(env.app)('POST', '/auth/refresh', { refreshToken: auth.refreshToken });
    expect(reuse.status).toBe(401);
    const afterTheft = await client(env.app)('POST', '/auth/refresh', { refreshToken: first.body.refreshToken });
    expect(afterTheft.status).toBe(401);
  });

  it('requires a valid access token', async () => {
    expect((await client(env.app)('GET', '/me')).status).toBe(401);
    expect((await client(env.app, 'garbage')('GET', '/me')).status).toBe(401);
  });
});

describe('sales flow', () => {
  it('runs location → item → stock → party → invoice → cancel with correct GST and numbering', async () => {
    const { api } = await signup('24');
    const site = await api('POST', '/locations', { type: 'site', name: 'Site A — Tower 1', code: 'SA1' });
    expect(site.status).toBe(201);
    expect(site.body.stateCode).toBe('24');

    const item = await api('POST', '/items', {
      name: 'Cement OPC 53', sku: 'CEM-53', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 80,
    });
    expect(item.status).toBe(201);
    expect(item.body.purchasePrice).toBe(80);
    const dupSku = await api('POST', '/items', { name: 'Again', sku: 'cem-53', unit: 'bag', gstRate: 18, salePrice: 1 });
    expect(dupSku.status).toBe(409);

    expect((await api('POST', '/stock/adjustments', { locationId: site.body.id, itemId: item.body.id, qty: 10, rate: 80 })).status).toBe(201);
    const over = await api('POST', '/stock/adjustments', { locationId: site.body.id, itemId: item.body.id, qty: -20 });
    expect(over.status).toBe(409);
    expect(over.body.error.code).toBe('INSUFFICIENT_STOCK');

    const outOfState = await api('POST', '/parties', { type: 'customer', name: 'Mumbai Infra', gstin: '27AAPFU0939F1ZV' });
    expect(outOfState.status).toBe(201);
    expect(outOfState.body.stateCode).toBe('27');
    const local = await api('POST', '/parties', { type: 'customer', name: 'Local Buyer', stateCode: '24' });

    const preview = await api('POST', '/invoices/preview', {
      locationId: site.body.id, partyId: outOfState.body.id, lines: [{ itemId: item.body.id, qty: 2 }],
    });
    expect(preview.status).toBe(200);
    expect(preview.body).toMatchObject({ id: null, number: null, supplyType: 'inter', igst: 36, cgst: 0, total: 236 });

    const inv1 = await api('POST', '/invoices', {
      locationId: site.body.id, partyId: local.body.id, lines: [{ itemId: item.body.id, qty: 2 }],
    });
    expect(inv1.status).toBe(201);
    expect(inv1.body).toMatchObject({ supplyType: 'intra', cgst: 18, sgst: 18, igst: 0, total: 236, status: 'posted' });
    expect(inv1.body.number).toMatch(/^INV\/\d{2}-\d{2}\/00001$/);
    expect(inv1.body.lines).toHaveLength(1);

    // A failed sale must not consume a number.
    const tooMany = await api('POST', '/invoices', {
      locationId: site.body.id, partyId: local.body.id, lines: [{ itemId: item.body.id, qty: 50 }],
    });
    expect(tooMany.status).toBe(409);
    expect(tooMany.body.error.code).toBe('INSUFFICIENT_STOCK');

    const inv2 = await api('POST', '/invoices', {
      locationId: site.body.id, partyId: outOfState.body.id, lines: [{ itemId: item.body.id, qty: 1, discountPct: 10 }],
    });
    expect(inv2.body.number).toMatch(/00002$/);

    const stock = await api('GET', `/stock?locationId=${site.body.id}`);
    expect(stock.body.data[0]).toMatchObject({ qty: 7, value: 560 });

    const cancelled = await api('POST', `/invoices/${inv1.body.id}/cancel`, { reason: 'Wrong customer' });
    expect(cancelled.status).toBe(200);
    expect(cancelled.body.status).toBe('cancelled');
    expect((await api('POST', `/invoices/${inv1.body.id}/cancel`, { reason: 'Again' })).body.error.code).toBe('ALREADY_CANCELLED');
    expect((await api('GET', `/stock?locationId=${site.body.id}`)).body.data[0].qty).toBe(9);

    const list = await api('GET', '/invoices');
    expect(list.body.total).toBe(2);
    expect(list.body.data[0].lines).toBeUndefined();

    const dash = await api('GET', '/dashboard');
    expect(dash.status).toBe(200);
    expect(dash.body.invoicesThisMonth).toBe(1);
    expect(dash.body.salesThisMonth).toBe(inv2.body.total);
    expect(dash.body.topItems[0].name).toBe('Cement OPC 53');

    const audit = await api('GET', `/audit?entity=invoice&entityId=${inv1.body.id}`);
    expect(audit.body.data.map((a: { action: string }) => a.action)).toEqual(['cancel', 'create']);
  });
});

describe('roles and location scope', () => {
  it('limits a site supervisor to their site and hides costs', async () => {
    const { api } = await signup();
    const ho = (await api('GET', '/locations')).body.data[0];
    const siteA = (await api('POST', '/locations', { type: 'site', name: 'Site A' })).body;
    const item = (await api('POST', '/items', { name: 'Steel TMT 12mm', unit: 'kg', gstRate: 18, salePrice: 70, purchasePrice: 60 })).body;
    await api('POST', '/stock/adjustments', { locationId: siteA.id, itemId: item.id, qty: 100 });
    await api('POST', '/stock/adjustments', { locationId: ho.id, itemId: item.id, qty: 500 });

    const roles = (await api('GET', '/roles')).body.data;
    const supervisorRole = roles.find((r: { name: string }) => r.name === 'Site Supervisor');
    const email = uniqueEmail('supervisor');
    const created = await api('POST', '/users', {
      name: 'Suresh', email, password: 'Secret@123', roleId: supervisorRole.id, locationIds: [siteA.id],
    });
    expect(created.status).toBe(201);
    expect(created.body.assignments[0]).toMatchObject({ roleName: 'Site Supervisor', locationIds: [siteA.id] });

    const login = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    const sup = client(env.app, login.body.accessToken);
    const me = (await sup('GET', '/me')).body;
    expect(me.companies[0].locationIds).toEqual([siteA.id]);
    expect(me.companies[0].permissions).not.toContain('invoices.view');

    expect((await sup('GET', '/invoices')).status).toBe(403);
    const locations = (await sup('GET', '/locations')).body;
    expect(locations.data.map((l: { id: string }) => l.id)).toEqual([siteA.id]);
    const stock = (await sup('GET', '/stock')).body;
    expect(stock.data).toHaveLength(1);
    expect(stock.data[0]).toMatchObject({ locationId: siteA.id, qty: 100 });
    expect(stock.data[0].value).toBeUndefined();
    expect((await sup('GET', `/items/${item.id}`)).body.purchasePrice).toBeUndefined();
    expect((await sup('POST', '/stock/adjustments', { locationId: ho.id, itemId: item.id, qty: -1 })).status).toBe(403);
    expect((await sup('POST', '/stock/adjustments', { locationId: siteA.id, itemId: item.id, qty: -1 })).status).toBe(201);
  });

  it('stops users from granting more access than they have', async () => {
    const { api } = await signup();
    const roles = (await api('GET', '/roles')).body.data;
    const adminRole = roles.find((r: { name: string }) => r.name === 'Company Admin');
    const ownerRole = roles.find((r: { name: string }) => r.name === 'Owner');
    const email = uniqueEmail('admin');
    await api('POST', '/users', { name: 'Anil', email, password: 'Secret@123', roleId: adminRole.id });
    const login = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    const admin = client(env.app, login.body.accessToken);
    const escalate = await admin('POST', '/users', { name: 'Evil', email: uniqueEmail('evil'), password: 'Secret@123', roleId: ownerRole.id });
    expect(escalate.status).toBe(403);
    const fine = await admin('POST', '/users', { name: 'Nina', email: uniqueEmail('nina'), password: 'Secret@123', roleId: adminRole.id });
    expect(fine.status).toBe(201);
  });
});

describe('tenant isolation', () => {
  it('never shows one business the data of another', async () => {
    const a = await signup();
    const b = await signup();
    const itemA = (await a.api('POST', '/items', { name: 'Secret item', unit: 'pcs', gstRate: 5, salePrice: 10 })).body;

    expect((await b.api('GET', '/items')).body.total).toBe(0);
    expect((await b.api('GET', `/items/${itemA.id}`)).status).toBe(404);
    const crossCompany = client(env.app, b.auth.accessToken, a.me.companies[0].id);
    expect((await crossCompany('GET', '/items')).status).toBe(403);
  });

  it('enforces isolation in the database itself, not only in code', async () => {
    const withoutTenant = await sql<{ n: number }>`select count(*)::int as n from items`.execute(env.db);
    expect(withoutTenant.rows[0]!.n).toBe(0);
    const someTenant = await sql<{ n: number }>`select count(*)::int as n from tenants`.execute(env.db);
    expect(someTenant.rows[0]!.n).toBe(0);
  });
});

describe('editing records', () => {
  it('clears optional fields with null or "" and tolerates empty edits', async () => {
    const { api } = await signup('24');
    const party = (await api('POST', '/parties', { type: 'customer', name: 'Mumbai Infra', gstin: '27AAPFU0939F1ZV', phone: '98200' })).body;
    const cleared = await api('PATCH', `/parties/${party.id}`, { gstin: null, phone: '' });
    expect(cleared.status).toBe(200);
    expect(cleared.body).toMatchObject({ gstin: null, phone: null, stateCode: '27' });
    const mismatch = await api('PATCH', `/parties/${party.id}`, { gstin: '24AABCP1234C1Z9', stateCode: '27' });
    expect(mismatch.status).toBe(400);
    const registered = await api('PATCH', `/parties/${party.id}`, { gstin: '24AABCP1234C1Z9' });
    expect(registered.body.stateCode).toBe('24');
    expect((await api('PATCH', `/parties/${party.id}`, {})).status).toBe(200);

    const loc = (await api('POST', '/locations', { type: 'site', name: 'Site B', code: 'SB', address: 'Somewhere' })).body;
    const locCleared = await api('PATCH', `/locations/${loc.id}`, { code: '', address: null });
    expect(locCleared.body).toMatchObject({ code: null, address: null, name: 'Site B' });
    expect((await api('PATCH', `/locations/${loc.id}`, {})).status).toBe(200);

    const item = (await api('POST', '/items', { name: 'Tile', sku: 'T1', hsnCode: '6907', unit: 'box', gstRate: 18, salePrice: 10 })).body;
    const itemCleared = await api('PATCH', `/items/${item.id}`, { sku: null, hsnCode: '' });
    expect(itemCleared.body).toMatchObject({ sku: null, hsnCode: null });
  });

  it('treats a malformed refresh token as signed out', async () => {
    const res = await client(env.app)('POST', '/auth/refresh', { refreshToken: 'x' });
    expect(res.status).toBe(401);
  });
});
