import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withDatabase } from '../src/db/migrate.ts';
import { seedPlatformAdmin, SUPERADMIN_EMAIL } from '../src/db/seed-platform-admin.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
let ownerUrl: string;
const PW = 'Secret@123';
beforeAll(async () => {
  env = await setupTestApp();
  ownerUrl = withDatabase(process.env.DATABASE_ADMIN_URL!, new URL(process.env.TEST_DATABASE_URL!).pathname.slice(1));
});
afterAll(async () => { await teardown(env); });

async function signup(businessType = 'kirana', extra: Record<string, unknown> = {}) {
  const email = uniqueEmail('biz');
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: `Biz ${email}`, name: 'Asha Rao', email, password: PW, stateCode: '24', businessType, ...extra,
  });
  expect(res.status).toBe(201);
  const me = await client(env.app, res.body.accessToken)('GET', '/me');
  return {
    email, token: res.body.accessToken as string, refresh: res.body.refreshToken as string, userId: res.body.user.id as string,
    companyId: me.body.companies[0].id as string, tenantName: `Biz ${email}`,
  };
}
const login = (email: string, password = PW) => client(env.app)('POST', '/auth/login', { email, password });
async function superAdmin() {
  await seedPlatformAdmin(ownerUrl, PW);
  const res = await login(SUPERADMIN_EMAIL);
  expect(res.status).toBe(200);
  return client(env.app, res.body.accessToken);
}
const owner = async <T>(fn: (c: pg.Client) => Promise<T>) => {
  const c = new pg.Client({ connectionString: ownerUrl });
  await c.connect();
  try { return await fn(c); } finally { await c.end(); }
};

describe('platform admin', () => {
  it('refuses every /platform route to a normal user', async () => {
    const a = await signup();
    const api = client(env.app, a.token, a.companyId);
    const id = '00000000-0000-4000-8000-000000000001';
    const calls: [Parameters<typeof api>[0], string, unknown?][] = [
      ['GET', '/platform/overview'], ['GET', '/platform/tenants'], ['GET', `/platform/tenants/${id}`],
      ['PATCH', `/platform/tenants/${id}`, { name: 'x y' }], ['PATCH', `/platform/companies/${id}`, { plan: 'team' }],
      ['POST', `/platform/users/${a.userId}/deactivate`], ['POST', `/platform/users/${a.userId}/activate`],
      ['POST', `/platform/users/${a.userId}/unlock`], ['POST', `/platform/users/${a.userId}/sign-out`],
      ['POST', `/platform/users/${a.userId}/reset-link`], ['GET', '/platform/audit'],
    ];
    for (const [m, url, body] of calls) {
      const res = await api(m, url, body);
      expect(res.status, `${m} ${url}`).toBe(403);
      expect(res.body.error.code).toBe('NOT_PLATFORM_ADMIN');
    }
    // Still signed in and unharmed.
    expect((await api('GET', '/me')).body.isPlatformAdmin).toBe(false);
    // Not signed in at all.
    expect((await client(env.app)('GET', '/platform/overview')).status).toBe(401);
  });

  it('closes the platform tables and functions to the app role', async () => {
    const a = await signup();
    const { sql } = await import('kysely');
    await expect(sql`select * from platform_admins`.execute(env.db)).rejects.toThrow(/permission denied/);
    await expect(sql`insert into platform_admins (user_id) values (${a.userId})`.execute(env.db)).rejects.toThrow(/permission denied/);
    await expect(sql`select * from platform_audit`.execute(env.db)).rejects.toThrow();
    await expect(sql`select * from platform_tenants(${a.userId}::uuid)`.execute(env.db)).rejects.toThrow(/not a platform admin/);
  });

  it('signs in without a company and sees tenants of every business type', async () => {
    const t1 = await signup('kirana');
    const t2 = await signup('restaurant');
    const t3 = await signup('hospital', { country: 'AE', stateCode: undefined });
    const api = await superAdmin();
    const me = await api('GET', '/me');
    expect(me.status).toBe(200);
    expect(me.body.isPlatformAdmin).toBe(true);
    expect(me.body.companies).toEqual([]);

    const list = await api('GET', '/platform/tenants?limit=100');
    expect(list.status).toBe(200);
    const names = list.body.data.map((t: { name: string }) => t.name);
    for (const t of [t1, t2, t3]) expect(names).toContain(t.tenantName);
    const row = list.body.data.find((t: { name: string }) => t.name === t3.tenantName);
    expect(row).toMatchObject({ businessType: 'hospital', country: 'AE', status: 'active', companyCount: 1, userCount: 1, ownerEmail: t3.email });
    expect(row.lastSignInAt).toBeTruthy();

    expect((await api('GET', '/platform/tenants?businessType=restaurant')).body.data.every((t: { businessType: string }) => t.businessType === 'restaurant')).toBe(true);
    expect((await api('GET', `/platform/tenants?q=${encodeURIComponent(t2.email)}`)).body.total).toBe(1);

    const ov = await api('GET', '/platform/overview');
    expect(ov.body.tenants).toBeGreaterThanOrEqual(4);
    expect(ov.body.signupsByMonth).toHaveLength(12);
    expect(ov.body.byBusinessType.map((b: { key: string }) => b.key)).toContain('restaurant');
    expect(ov.body.usersSignedInLast30Days).toBeGreaterThanOrEqual(4);

    const detail = await api('GET', `/platform/tenants/${row.id}`);
    expect(detail.body.companies[0]).toMatchObject({ id: t3.companyId, businessType: 'hospital', counts: { invoices: 0 } });
    expect(detail.body.users[0]).toMatchObject({ email: t3.email, isActive: true, isLocked: false, twoFactor: false });
    expect(detail.body.users[0].roles[0].role).toBe('Owner');
    expect((await api('GET', `/platform/tenants/00000000-0000-4000-8000-000000000009`)).status).toBe(404);
    expect((await api('GET', '/platform/tenants/not-a-uuid')).status).toBe(404);
  });

  it('keeps tenant data isolated for normal users', async () => {
    const a = await signup();
    const b = await signup();
    const apiA = client(env.app, a.token, a.companyId);
    const seen = await apiA('GET', '/me');
    expect(seen.body.companies).toHaveLength(1);
    expect((await client(env.app, a.token, b.companyId)('GET', '/me')).status).toBe(401);
  });

  it('suspends and reactivates a tenant, blocking sign-in and live sessions', async () => {
    const a = await signup();
    const api = await superAdmin();
    const id = (await api('GET', `/platform/tenants?q=${encodeURIComponent(a.email)}`)).body.data[0].id as string;

    expect((await api('PATCH', `/platform/tenants/${id}`, { status: 'suspended' })).status).toBe(400);
    const sus = await api('PATCH', `/platform/tenants/${id}`, { status: 'suspended', reason: 'Unpaid invoice' });
    expect(sus.status).toBe(200);
    expect(sus.body).toMatchObject({ status: 'suspended', suspendedReason: 'Unpaid invoice' });

    const blocked = await login(a.email);
    expect(blocked.status).toBe(403);
    expect(blocked.body.error.code).toBe('ACCOUNT_SUSPENDED');
    // A wrong password still looks like a wrong password.
    expect((await login(a.email, 'Wrong@12345')).status).toBe(401);
    const live = await client(env.app, a.token, a.companyId)('GET', '/me');
    expect(live.status).toBe(403);
    expect(live.body.error.code).toBe('ACCOUNT_SUSPENDED');
    const refreshed = await client(env.app)('POST', '/auth/refresh', { refreshToken: a.refresh });
    expect(refreshed.status).toBe(403);
    expect(refreshed.body.error.code).toBe('ACCOUNT_SUSPENDED');

    expect((await api('PATCH', `/platform/tenants/${id}`, { status: 'active' })).body.status).toBe('active');
    expect((await login(a.email)).status).toBe(200);
    expect((await client(env.app, a.token, a.companyId)('GET', '/me')).status).toBe(200);

    expect((await api('PATCH', `/platform/tenants/${id}`, { name: 'Renamed Co' })).body.name).toBe('Renamed Co');
    const log = await api('GET', '/platform/audit');
    const actions = log.body.data.filter((r: { tenantId: string }) => r.tenantId === id).map((r: { action: string }) => r.action);
    expect(actions).toEqual(expect.arrayContaining(['tenant_suspend', 'tenant_activate', 'tenant_rename']));
    const suspendRow = log.body.data.find((r: { action: string; tenantId: string }) => r.action === 'tenant_suspend' && r.tenantId === id);
    expect(suspendRow).toMatchObject({ adminName: 'Platform Admin', detail: { reason: 'Unpaid invoice' } });
  });

  it('changes plan and business type and re-clamps modules', async () => {
    const a = await signup('kirana', { plan: 'team' });
    const api = await superAdmin();
    const before = await client(env.app, a.token, a.companyId)('GET', '/me');
    expect(before.body.companies[0].plan).toBe('team');
    const solo = await api('PATCH', `/platform/companies/${a.companyId}`, { plan: 'solo' });
    expect(solo.status).toBe(200);
    expect(solo.body.plan).toBe('solo');
    const allowed = ['sales', 'purchases', 'inventory', 'gst', 'tds', 'income_tax', 'einvoice', 'fixed_assets', 'accounting', 'reports'];
    expect(solo.body.enabledModules.every((m: string) => allowed.includes(m))).toBe(true);
    const typed = await api('PATCH', `/platform/companies/${a.companyId}`, { businessType: 'restaurant', plan: 'business' });
    expect(typed.body).toMatchObject({ businessType: 'restaurant', plan: 'business' });
    expect(typed.body.rolesCreated.length).toBeGreaterThan(0);
    const after = await client(env.app, a.token, a.companyId)('GET', '/me');
    expect(after.body.companies[0].businessType).toBe('restaurant');
    expect((await api('PATCH', `/platform/companies/${a.companyId}`, { plan: 'gold' })).status).toBe(400);
    expect((await api('PATCH', `/platform/companies/00000000-0000-4000-8000-000000000009`, { plan: 'team' })).status).toBe(404);
  });

  it('deactivates, activates, unlocks, signs out and issues a reset link', async () => {
    const a = await signup();
    const api = await superAdmin();

    // Lock the account with failed attempts.
    for (let i = 0; i < 10; i++) await login(a.email, 'Wrong@12345');
    expect((await login(a.email)).status).toBe(423);
    expect((await api('POST', `/platform/users/${a.userId}/unlock`)).status).toBe(204);
    expect((await login(a.email)).status).toBe(200);

    // Sign out: the old session stops working.
    const s = await login(a.email);
    const mine = client(env.app, s.body.accessToken, a.companyId);
    expect((await mine('GET', '/me')).status).toBe(200);
    expect((await api('POST', `/platform/users/${a.userId}/sign-out`)).status).toBe(204);
    expect((await mine('GET', '/me')).status).toBe(401);

    // Reset link works once and sets a new password.
    const link = await api('POST', `/platform/users/${a.userId}/reset-link`);
    expect(link.status).toBe(200);
    const token = new URL(link.body.link.replace('/#/', '/')).searchParams.get('token')!;
    expect(token.length).toBeGreaterThan(20);
    const reset = await client(env.app)('POST', '/auth/password/reset', { token, newPassword: 'Fresh@12345' });
    expect(reset.status).toBe(204);
    expect((await login(a.email, 'Fresh@12345')).status).toBe(200);
    expect((await client(env.app)('POST', '/auth/password/reset', { token, newPassword: 'Other@12345' })).status).toBe(400);

    // Deactivate and activate.
    expect((await api('POST', `/platform/users/${a.userId}/deactivate`)).status).toBe(204);
    expect((await login(a.email, 'Fresh@12345')).status).toBe(401);
    expect((await api('POST', `/platform/users/${a.userId}/reset-link`)).status).toBe(409);
    expect((await api('POST', `/platform/users/${a.userId}/activate`)).status).toBe(204);
    expect((await login(a.email, 'Fresh@12345')).status).toBe(200);

    expect((await api('POST', `/platform/users/00000000-0000-4000-8000-000000000009/unlock`)).status).toBe(404);
    const actions = (await api('GET', '/platform/audit?limit=100')).body.data
      .filter((r: { targetId: string }) => r.targetId === a.userId).map((r: { action: string }) => r.action);
    expect(actions).toEqual(expect.arrayContaining(['user_unlock', 'user_sign_out', 'user_reset_link', 'user_deactivate', 'user_activate']));
    // The reset token itself is never written to the audit trail.
    expect(JSON.stringify((await api('GET', '/platform/audit?limit=100')).body)).not.toContain(token);
  });

  it('protects platform admins and their own tenant', async () => {
    const api = await superAdmin();
    const me = await api('GET', '/me');
    const adminId = me.body.user.id as string;
    const tenants = (await api('GET', '/platform/tenants?q=Progen Platform')).body.data;
    const own = tenants.find((t: { name: string }) => t.name === 'Progen Platform');
    expect(own.hasPlatformAdmin).toBe(true);
    for (const url of ['deactivate', 'reset-link']) {
      const res = await api('POST', `/platform/users/${adminId}/${url}`);
      expect(res.status).toBe(409);
      expect(res.body.error.code).toBe('PLATFORM_ADMIN_PROTECTED');
    }
    const sus = await api('PATCH', `/platform/tenants/${own.id}`, { status: 'suspended', reason: 'Testing' });
    expect(sus.status).toBe(409);
    expect(sus.body.error.code).toBe('PLATFORM_ADMIN_PROTECTED');
    expect((await api('GET', '/me')).status).toBe(200);
  });

  it('stops being an admin when the grant is revoked', async () => {
    const api = await superAdmin();
    expect((await api('GET', '/platform/overview')).status).toBe(200);
    await owner((c) => c.query(`delete from platform_admins`));
    const res = await api('GET', '/platform/overview');
    expect(res.status).toBe(403);
    expect((await api('GET', '/me')).body.isPlatformAdmin).toBe(false);
  });
});
