import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { PERMISSION_KEYS } from '../src/auth/permissions.ts';
import { BUSINESS_TYPES, GROUPS, MODULE_KEYS, PLANS, TERM_KEYS, clampModules, defaultModules } from '../src/lib/business-types.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function signup(extra: Record<string, unknown> = {}) {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Test Biz', name: 'Asha Rao', email: uniqueEmail('biz'), password: 'Secret@123', stateCode: '24', ...extra,
  });
  if (res.status !== 201) return { res };
  const me = await client(env.app, res.body.accessToken)('GET', '/me');
  const companyId = me.body.companies[0].id as string;
  return { res, me: me.body, companyId, api: client(env.app, res.body.accessToken, companyId) };
}

describe('catalogue', () => {
  it('is valid', () => {
    const ids = new Set<string>();
    for (const t of BUSINESS_TYPES) {
      expect(ids.has(t.id)).toBe(false);
      ids.add(t.id);
      expect(GROUPS.some((g) => g.id === t.group)).toBe(true);
      expect(t.roles.length).toBeGreaterThanOrEqual(2);
      expect(new Set(t.roles.map((r) => r.name)).size).toBe(t.roles.length);
      for (const r of t.roles) for (const p of r.permissions) expect(PERMISSION_KEYS).toContain(p);
      for (const m of t.modules) expect(MODULE_KEYS).toContain(m);
      for (const k of Object.keys(t.terms)) expect(TERM_KEYS).toContain(k);
      for (const a of t.quickActions) expect(PERMISSION_KEYS).toContain(a.permission);
    }
    expect(BUSINESS_TYPES.length).toBeGreaterThanOrEqual(50);
    expect(ids.has('restaurant') && ids.has('hospital') && ids.has('advocate') && ids.has('government') && ids.has('pvt_ltd')).toBe(true);
  });

  it('drops Indian tax modules outside India and limits solo', () => {
    expect(defaultModules('kirana', 'IN')).toContain('gst');
    expect(defaultModules('kirana', 'US')).not.toContain('gst');
    expect(clampModules(['sales', 'multi_company', 'controls'], 'solo', 'IN')).toEqual(['sales']);
    expect(PLANS.find((p) => p.id === 'team')!.maxUsers).toBe(10);
  });

  it('is served without signing in', async () => {
    const res = await client(env.app)('GET', '/business-types');
    expect(res.status).toBe(200);
    expect(res.body.types.length).toBe(BUSINESS_TYPES.length);
    expect(res.body.plans.map((p: { id: string }) => p.id)).toEqual(['solo', 'team', 'business', 'enterprise']);
  });
});

describe('signup per type', () => {
  it('creates the type, modules, words and roles for every type', async () => {
    for (const t of BUSINESS_TYPES) {
      const s = await signup({ businessType: t.id, plan: 'business' });
      expect(s.res.status, t.id).toBe(201);
      const c = (await s.api!('GET', '/company')).body;
      expect(c.businessType).toBe(t.id);
      expect(c.enabledModules).toEqual(defaultModules(t.id, 'IN'));
      expect(c.terms).toEqual(t.terms);
      const roles = (await s.api!('GET', '/roles')).body.data.map((r: { name: string }) => r.name);
      for (const r of t.roles) expect(roles, `${t.id}/${r.name}`).toContain(r.name);
      expect(roles).toContain('Owner');
    }
  }, 120_000);

  it('signs up outside India without a state or GSTIN', async () => {
    const s = await signup({ businessType: 'it_services', country: 'US', stateCode: undefined });
    expect(s.res.status).toBe(201);
    const c = (await s.api!('GET', '/company')).body;
    expect(c).toMatchObject({ country: 'US', currency: 'USD', stateCode: '97', gstin: null });
    expect(c.enabledModules).not.toContain('gst');
    // A plain tax rate (VAT, sales tax) is accepted; India still checks the GST rate master.
    const api = s.api!;
    const loc = (await api('GET', '/locations')).body.data[0];
    const item = await api('POST', '/items', { name: 'Burger', unit: 'pc', gstRate: 8.25, salePrice: 100, trackStock: false });
    expect(item.status).toBe(201);
    const party = (await api('POST', '/parties', { type: 'customer', name: 'Guest' })).body;
    const inv = await api('POST', '/invoices', { locationId: loc.id, partyId: party.id, lines: [{ itemId: item.body.id, qty: 2 }] });
    expect(inv.status).toBe(201);
    const inIndia = await signup();
    expect((await inIndia.api!('POST', '/items', { name: 'X', unit: 'pc', gstRate: 8.25, salePrice: 1 })).status).toBe(400);
    const noState = await signup({ stateCode: undefined });
    expect(noState.res.status).toBe(400);
  });
});

describe('business profile', () => {
  it('applies twice safely and never removes roles', async () => {
    const s = await signup({ businessType: 'general' });
    const api = s.api!;
    const first = await api('POST', '/company/business-profile', { businessType: 'restaurant' });
    expect(first.status).toBe(200);
    expect(first.body.rolesCreated).toContain('Captain');
    expect(first.body.company.terms.customer).toBe('Guest');

    const custom = (await api('POST', '/roles', { name: 'Night Auditor', permissions: ['reports.view'] })).body;
    const rolesBefore = (await api('GET', '/roles')).body.data;
    const second = await api('POST', '/company/business-profile', { businessType: 'restaurant' });
    expect(second.status).toBe(200);
    expect(second.body.rolesCreated).toEqual([]);
    const third = await api('POST', '/company/business-profile', { businessType: 'hospital' });
    expect(third.body.rolesCreated).toContain('Doctor');
    const rolesAfter = (await api('GET', '/roles')).body.data;
    for (const r of rolesBefore) {
      const now = rolesAfter.find((x: { id: string }) => x.id === r.id);
      expect(now, r.name).toBeTruthy();
      expect(now.permissions).toEqual(r.permissions);
    }
    expect(rolesAfter.some((r: { id: string }) => r.id === custom.id)).toBe(true);
    // The owner still holds the Owner role.
    const me = (await client(env.app, s.res.body.accessToken)('GET', '/me')).body;
    expect(me.companies[0].roles.map((r: { name: string }) => r.name)).toEqual(['Owner']);
  });

  it('saves modules and renamed words, and needs company.manage', async () => {
    const s = await signup();
    const ok = await s.api!('POST', '/company/business-profile', { enabledModules: ['sales', 'reports'], terms: { customer: 'Client ' } });
    expect(ok.body.company.enabledModules).toEqual(['sales', 'reports']);
    expect(ok.body.company.terms).toEqual({ customer: 'Client' });
    const bad = await s.api!('POST', '/company/business-profile', { enabledModules: ['nope'] });
    expect(bad.status).toBe(400);
    const roles = (await s.api!('GET', '/roles')).body.data;
    const auditor = roles.find((r: { name: string }) => r.name === 'Auditor');
    const login = await client(env.app)('POST', '/auth/signup', { businessName: 'x biz', name: 'Xx Yy', email: uniqueEmail('x'), password: 'Secret@123', stateCode: '24' });
    expect(login.status).toBe(201);
    const email = uniqueEmail('aud');
    await s.api!('POST', '/users', { name: 'Aud Itor', email, password: 'Secret@123', roleId: auditor.id });
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    const me = await client(env.app, li.body.accessToken)('GET', '/me');
    const aud = client(env.app, li.body.accessToken, me.body.companies[0].id);
    expect((await aud('POST', '/company/business-profile', { businessType: 'kirana' })).status).toBe(403);
  });

  it('locks country and currency once an invoice exists', async () => {
    const s = await signup();
    const api = s.api!;
    const loc = (await api('GET', '/locations')).body.data[0];
    const item = (await api('POST', '/items', { name: 'Consulting', unit: 'hr', gstRate: 18, salePrice: 1000, trackStock: false })).body;
    const party = (await api('POST', '/parties', { type: 'customer', name: 'Buyer', stateCode: '24' })).body;
    expect((await api('POST', '/company/business-profile', { currency: 'USD' })).status).toBe(200);
    expect((await api('POST', '/company/business-profile', { currency: 'INR' })).status).toBe(200);
    const inv = await api('POST', '/invoices', { locationId: loc.id, partyId: party.id, lines: [{ itemId: item.id, qty: 1 }] });
    expect(inv.status).toBe(201);
    expect((await api('POST', '/company/business-profile', { currency: 'USD' })).status).toBe(409);
    expect((await api('POST', '/company/business-profile', { country: 'US' })).status).toBe(409);
    expect((await api('POST', '/company/business-profile', { businessType: 'kirana' })).status).toBe(200);
  });

  it('enforces the plan user limit', async () => {
    const s = await signup({ plan: 'solo' });
    const api = s.api!;
    const role = (await api('GET', '/roles')).body.data.find((r: { name: string }) => r.name === 'Auditor');
    const add = (n: string) => api('POST', '/users', { name: 'Extra User', email: uniqueEmail(n), password: 'Secret@123', roleId: role.id });
    const blocked = await add('solo');
    expect(blocked.status).toBe(409);
    expect(blocked.body.error?.code ?? blocked.body.code).toBe('USER_LIMIT');
    expect((await api('POST', '/company/business-profile', { plan: 'team' })).status).toBe(200);
    expect((await add('team')).status).toBe(201);
    // Cannot drop to solo while two users are active.
    expect((await api('POST', '/company/business-profile', { plan: 'solo' })).status).toBe(409);
  });

  it('keeps one tenant from reading or changing another', async () => {
    const a = await signup({ businessType: 'advocate' });
    const b = await signup({ businessType: 'kirana' });
    const rolesB = (await b.api!('GET', '/roles')).body.data.map((r: { name: string }) => r.name);
    expect(rolesB).not.toContain('Managing Partner');
    expect((await a.api!('GET', '/company')).body.businessType).toBe('advocate');
    expect((await b.api!('GET', '/company')).body.businessType).toBe('kirana');
    // Someone else's company id in the header is refused.
    const cross = client(env.app, a.res.body.accessToken, b.companyId);
    expect((await cross('POST', '/company/business-profile', { businessType: 'gym' })).status).toBeGreaterThanOrEqual(400);
    expect((await b.api!('GET', '/company')).body.businessType).toBe('kirana');
  });
});
