import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import { decodeJwt, exportJWK, generateKeyPair, SignJWT } from 'jose';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.ts';
import { withTenant } from '../src/db/database.ts';
import { GspError, type GspAdapter } from '../src/lib/gsp/types.ts';
import { registerGspAdapter, setGspBackoff } from '../src/lib/gsp/registry.ts';
import { enqueue, registerJobHandler, runJobsOnce } from '../src/lib/jobs.ts';
import { notify, setSender, type OutboundMessage } from '../src/lib/notify.ts';
import { totpAt } from '../src/lib/totp.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
const sent: OutboundMessage[] = [];
const config = () => loadConfig({ ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, LOG_LEVEL: 'silent' });
const runJobs = async () => { while ((await runJobsOnce({ db: env.db, config: config() })) > 0) { /* drain */ } };

beforeAll(async () => {
  env = await setupTestApp();
  setSender(async (m) => { sent.push(m); return 'test'; });
});
afterAll(async () => {
  setSender();
  await teardown(env);
});

const PASSWORD = 'Secret@123';
const anon = () => client(env.app);

async function signup(email = uniqueEmail('owner'), businessName = 'Platform Co') {
  const res = await anon()('POST', '/auth/signup', { businessName, name: 'Owner One', email, password: PASSWORD, stateCode: '24' });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  return { email, token, refreshToken: res.body.refreshToken as string, companyId, api: client(env.app, token, companyId), tenantId: decodeJwt(token).tid as string, userId: decodeJwt(token).sub as string };
}
type Biz = Awaited<ReturnType<typeof signup>>;

async function addUser(b: Biz, roleName = 'Accountant') {
  const roles = (await b.api('GET', '/roles')).body.data as { id: string; name: string }[];
  const email = uniqueEmail('user');
  const created = await b.api('POST', '/users', { name: 'Anita', email, password: PASSWORD, roleId: roles.find((r) => r.name === roleName)!.id });
  expect(created.status).toBe(201);
  return { email, id: created.body.id as string };
}

describe('password policy and lockout', () => {
  it('rejects weak passwords at signup and on change', async () => {
    const body = (password: string) => ({ businessName: 'Weak Co', name: 'Weak One', email: uniqueEmail('weak'), password, stateCode: '24' });
    for (const bad of ['short1', 'longpasswordnodigits', '12345678901', 'Password123']) {
      const res = await anon()('POST', '/auth/signup', body(bad));
      expect(res.status).toBe(400);
      expect(res.body.error.details.password).toBeTruthy();
    }
    const email = 'jaswinder@test.in';
    expect((await anon()('POST', '/auth/signup', { ...body('Jaswinder99'), email })).status).toBe(400);
    const b = await signup();
    const change = await b.api('POST', '/me/password', { currentPassword: PASSWORD, newPassword: 'abcdefgh' });
    expect(change.status).toBe(400);
  });

  it('locks after 10 failures, even for the right password, and an admin can unlock', async () => {
    const b = await signup();
    const u = await addUser(b);
    for (let i = 0; i < 10; i++) {
      expect((await anon()('POST', '/auth/login', { email: u.email, password: 'Wrong@1234' })).status).toBe(401);
    }
    const locked = await anon()('POST', '/auth/login', { email: u.email, password: PASSWORD });
    expect(locked.status).toBe(423);
    expect(locked.body.error.code).toBe('ACCOUNT_LOCKED');
    expect((await b.api('POST', `/users/${u.id}/unlock`)).status).toBe(204);
    expect((await anon()('POST', '/auth/login', { email: u.email, password: PASSWORD })).status).toBe(200);
    expect((await anon()('POST', '/auth/login', { email: 'nobody@test.in', password: 'Wrong@1234' })).status).toBe(401);
  });
});

describe('two-factor sign-in', () => {
  it('sets up, enables, signs in with a code and a recovery code, regenerates and disables', async () => {
    const b = await signup();
    expect((await b.api('GET', '/me/security')).body).toMatchObject({ twoFactorEnabled: false, recoveryCodesLeft: 0 });
    const setup = (await b.api('POST', '/me/2fa/setup', {})).body;
    expect(setup.otpauthUri).toContain('otpauth://totp/Progen:');
    const bad = await b.api('POST', '/me/2fa/enable', { code: '000000' });
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('MFA_INVALID');
    const enabled = await b.api('POST', '/me/2fa/enable', { code: totpAt(setup.secret) });
    expect(enabled.status).toBe(200);
    const codes = enabled.body.recoveryCodes as string[];
    expect(codes).toHaveLength(10);
    expect(codes[0]).toMatch(/^[a-z0-9]{4}-[a-z0-9]{4}$/);
    expect((await b.api('POST', '/me/2fa/setup', {})).status).toBe(409);
    expect((await b.api('GET', '/me/security')).body).toMatchObject({ twoFactorEnabled: true, recoveryCodesLeft: 10 });

    // Password alone gives no tokens.
    const login = await anon()('POST', '/auth/login', { email: b.email, password: PASSWORD });
    expect(login.status).toBe(200);
    expect(login.body.mfaRequired).toBe(true);
    expect(login.body.accessToken).toBeUndefined();
    const wrong = await anon()('POST', '/auth/login/mfa', { mfaToken: login.body.mfaToken, code: '123456' });
    expect(wrong.status).toBe(401);
    expect(wrong.body.error.code).toBe('MFA_INVALID');
    // The step used to enable is spent; the next one is accepted.
    const ok = await anon()('POST', '/auth/login/mfa', { mfaToken: login.body.mfaToken, code: totpAt(setup.secret, Date.now() + 30_000) });
    expect(ok.status).toBe(200);
    expect(ok.body.accessToken).toBeTruthy();
    expect((await client(env.app, ok.body.accessToken)('GET', '/me')).status).toBe(200);
    // The same code cannot be replayed.
    const again = await anon()('POST', '/auth/login', { email: b.email, password: PASSWORD });
    const replay = await anon()('POST', '/auth/login/mfa', { mfaToken: again.body.mfaToken, code: totpAt(setup.secret, Date.now() + 30_000) });
    expect(replay.status).toBe(401);

    // A recovery code works once.
    const viaRecovery = await anon()('POST', '/auth/login/mfa', { mfaToken: again.body.mfaToken, recoveryCode: codes[0] });
    expect(viaRecovery.status).toBe(200);
    const third = await anon()('POST', '/auth/login', { email: b.email, password: PASSWORD });
    expect((await anon()('POST', '/auth/login/mfa', { mfaToken: third.body.mfaToken, recoveryCode: codes[0] })).status).toBe(401);

    // New codes replace the old ones.
    const fresh = await b.api('POST', '/me/2fa/recovery-codes', { password: PASSWORD, code: codes[1] });
    expect(fresh.status).toBe(200);
    const next = fresh.body.recoveryCodes as string[];
    expect((await b.api('POST', '/me/2fa/recovery-codes', { password: PASSWORD, code: codes[2] })).status).toBe(400);
    expect((await b.api('POST', '/me/2fa/disable', { password: 'Wrong@1234', code: next[0] })).status).toBe(400);
    expect((await b.api('POST', '/me/2fa/disable', { password: PASSWORD, code: next[0] })).status).toBe(204);
    const plain = await anon()('POST', '/auth/login', { email: b.email, password: PASSWORD });
    expect(plain.body.accessToken).toBeTruthy();
    await runJobs();
    expect(sent.filter((m) => m.to === b.email && m.template === 'mfa_changed').length).toBe(2);
  });

  it('stops an mfaToken after 5 wrong codes, requires 2FA when the company says so, and lets an admin reset', async () => {
    const b = await signup();
    const setup = (await b.api('POST', '/me/2fa/setup', {})).body;
    await b.api('POST', '/me/2fa/enable', { code: totpAt(setup.secret) });
    const login = await anon()('POST', '/auth/login', { email: b.email, password: PASSWORD });
    for (let i = 0; i < 5; i++) {
      expect((await anon()('POST', '/auth/login/mfa', { mfaToken: login.body.mfaToken, code: '111111' })).status).toBe(401);
    }
    const dead = await anon()('POST', '/auth/login/mfa', { mfaToken: login.body.mfaToken, code: totpAt(setup.secret, Date.now() + 30_000) });
    expect(dead.status).toBe(401);
    expect(dead.body.error.code).toBe('UNAUTHORIZED');

    // Company requires 2FA: a user without it is held at enrolment.
    const owner = await signup();
    const os = (await owner.api('POST', '/me/2fa/setup', {})).body;
    await owner.api('POST', '/me/2fa/enable', { code: totpAt(os.secret) });
    const u = await addUser(owner);
    const userLogin = (await anon()('POST', '/auth/login', { email: u.email, password: PASSWORD })).body;
    const asUser = client(env.app, userLogin.accessToken, owner.companyId);
    expect((await asUser('PATCH', '/company', { require2fa: true })).status).toBe(403);
    expect((await owner.api('PATCH', '/company', { require2fa: true })).body.require2fa).toBe(true);
    expect((await asUser('GET', '/items')).body.error.code).toBe('MFA_ENROLMENT_REQUIRED');
    expect((await asUser('GET', '/me')).body.user.mustEnrol2fa).toBe(true);
    expect((await asUser('GET', '/me/security')).status).toBe(200);
    // The owner cannot switch 2FA off while required, but can reset another user.
    const s2 = (await asUser('POST', '/me/2fa/setup', {})).body;
    expect((await asUser('POST', '/me/2fa/enable', { code: totpAt(s2.secret) })).status).toBe(200);
    expect((await asUser('GET', '/items')).status).toBe(200);
    expect((await owner.api('POST', `/users/${u.id}/2fa/reset`)).status).toBe(204);
    expect((await anon()('POST', '/auth/login', { email: u.email, password: PASSWORD })).body.mfaRequired).toBeUndefined();
  });
});

describe('password reset', () => {
  it('emails a one-time link, enforces the policy and ends sessions', async () => {
    const b = await signup();
    sent.length = 0;
    expect((await anon()('POST', '/auth/password/forgot', { email: 'ghost@test.in' })).status).toBe(204);
    expect((await anon()('POST', '/auth/password/forgot', { email: b.email })).status).toBe(204);
    await runJobs();
    const mail = sent.find((m) => m.to === b.email && m.template === 'password_reset');
    expect(mail).toBeTruthy();
    expect(sent.some((m) => m.to === 'ghost@test.in')).toBe(false);
    const token = /token=([A-Za-z0-9_-]+)/.exec(mail!.body)![1]!;
    expect((await anon()('POST', '/auth/password/reset', { token, newPassword: 'abcdefgh' })).status).toBe(400);
    expect((await anon()('POST', '/auth/password/reset', { token: 'n'.repeat(43), newPassword: 'Fresh#Pass42' })).body.error.code).toBe('RESET_TOKEN_INVALID');
    expect((await anon()('POST', '/auth/password/reset', { token, newPassword: 'Fresh#Pass42' })).status).toBe(204);
    expect((await anon()('POST', '/auth/password/reset', { token, newPassword: 'Another#Pass42' })).body.error.code).toBe('RESET_TOKEN_INVALID');
    expect((await anon()('POST', '/auth/login', { email: b.email, password: PASSWORD })).status).toBe(401);
    expect((await anon()('POST', '/auth/login', { email: b.email, password: 'Fresh#Pass42' })).status).toBe(200);
    expect((await b.api('GET', '/me')).status).toBe(401);
  });
});

describe('sessions', () => {
  it('lists, revokes one and revokes the others', async () => {
    const b = await signup();
    const second = (await anon()('POST', '/auth/login', { email: b.email, password: PASSWORD })).body;
    const third = (await anon()('POST', '/auth/login', { email: b.email, password: PASSWORD })).body;
    const list = (await b.api('GET', '/me/sessions')).body.data as { id: string; current: boolean; method: string }[];
    expect(list).toHaveLength(3);
    expect(list.filter((s) => s.current)).toHaveLength(1);
    expect(list[0]!.method).toBe('password');
    const sidOf = (t: string) => decodeJwt(t).sid as string;
    const asSecond = client(env.app, second.accessToken, b.companyId);
    expect((await b.api('DELETE', `/me/sessions/${sidOf(second.accessToken)}`)).status).toBe(204);
    const gone = await asSecond('GET', '/me');
    expect(gone.status).toBe(401);
    expect(gone.body.error.code).toBe('SESSION_REVOKED');
    expect((await b.api('DELETE', `/me/sessions/${sidOf(second.accessToken)}`)).status).toBe(404);
    expect((await b.api('POST', '/me/sessions/revoke-others')).status).toBe(204);
    expect((await client(env.app, third.accessToken, b.companyId)('GET', '/me')).status).toBe(401);
    expect((await b.api('GET', '/me')).status).toBe(200);
    expect(((await b.api('GET', '/me/sessions')).body.data as unknown[]).length).toBe(1);
    // A refresh keeps the session id.
    const rotated = (await anon()('POST', '/auth/refresh', { refreshToken: b.refreshToken })).body;
    expect(sidOf(rotated.accessToken)).toBe(sidOf(b.token));
  });
});

describe('single sign-on', () => {
  let idp: Server;
  let issuer: string;
  let kp: Awaited<ReturnType<typeof generateKeyPair>>;
  const state = { nonce: '', email: '', emailVerified: true, clientId: 'progen-client' };

  beforeAll(async () => {
    kp = await generateKeyPair('RS256');
    const jwk = { ...(await exportJWK(kp.publicKey)), kid: 'k1', alg: 'RS256', use: 'sig' };
    idp = createServer((req, res) => {
      const url = new URL(req.url ?? '/', issuer);
      const json = (o: unknown) => { res.setHeader('content-type', 'application/json'); res.end(JSON.stringify(o)); };
      if (url.pathname === '/.well-known/openid-configuration') {
        return json({ issuer, authorization_endpoint: `${issuer}/authorize`, token_endpoint: `${issuer}/token`, jwks_uri: `${issuer}/jwks` });
      }
      if (url.pathname === '/jwks') return json({ keys: [jwk] });
      if (url.pathname === '/token') {
        void new SignJWT({ email: state.email, email_verified: state.emailVerified, name: 'Sso Person', nonce: state.nonce })
          .setProtectedHeader({ alg: 'RS256', kid: 'k1' }).setIssuer(issuer).setAudience(state.clientId).setSubject('sub-1')
          .setIssuedAt().setExpirationTime('5m').sign(kp.privateKey).then((id_token) => json({ id_token, access_token: 'x', token_type: 'Bearer' }));
        return;
      }
      res.statusCode = 404; res.end();
    });
    await new Promise<void>((r) => idp.listen(0, '127.0.0.1', r));
    issuer = `http://127.0.0.1:${(idp.address() as AddressInfo).port}`;
  });
  afterAll(() => { idp.close(); });

  it('signs in through the identity provider and rejects a bad state', async () => {
    const domain = `acme-${Date.now()}.test`;
    const b = await signup(`boss@${domain}`);
    const create = (body: object) => b.api('POST', '/sso-providers', { name: 'Acme IdP', issuer, clientId: state.clientId, clientSecret: 's3cret', emailDomains: [domain], ...body });
    expect((await create({ emailDomains: ['gmail.com'] })).status).toBe(400);
    expect((await create({ issuer: 'http://127.0.0.1:1' })).body.error.code).toBe('SSO_DISCOVERY_FAILED');
    expect((await create({ autoProvision: true })).status).toBe(400);
    const made = await create({});
    expect(made.status).toBe(201);
    expect(made.body.hasClientSecret).toBe(true);
    expect(made.body.clientSecret).toBeUndefined();
    const other = await signup();
    expect((await other.api('POST', '/sso-providers', { name: 'Dup', issuer, clientId: 'c', clientSecret: 's', emailDomains: [domain] })).body.error.code).toBe('SSO_DOMAIN_TAKEN');
    expect((await b.api('POST', `/sso-providers/${made.body.id}/test`)).body.ok).toBe(true);
    expect((await anon()('GET', `/auth/sso/discover?email=boss@${domain}`)).body).toMatchObject({ providers: [{ id: made.body.id }], enforced: false });

    const start = await env.app.inject({ method: 'GET', url: `/api/v1/auth/sso/${made.body.id}/start` });
    expect(start.statusCode).toBe(302);
    const loc = new URL(start.headers.location as string);
    expect(loc.origin).toBe(issuer);
    expect(loc.searchParams.get('code_challenge_method')).toBe('S256');
    state.nonce = loc.searchParams.get('nonce')!;
    state.email = `boss@${domain}`;
    const cb = await env.app.inject({ method: 'GET', url: `/api/v1/auth/sso/callback?code=abc&state=${loc.searchParams.get('state')}` });
    expect(cb.statusCode).toBe(302);
    const ticket = /ticket=([^&]+)/.exec(cb.headers.location as string)![1]!;
    const redeemed = await anon()('POST', '/auth/sso/redeem', { ticket });
    expect(redeemed.status).toBe(200);
    expect(decodeJwt(redeemed.body.accessToken).amr).toBe('sso');
    expect((await client(env.app, redeemed.body.accessToken)('GET', '/me')).body.user.email).toBe(`boss@${domain}`);
    expect((await anon()('POST', '/auth/sso/redeem', { ticket })).body.error.code).toBe('SSO_TICKET_INVALID');

    const bad = await env.app.inject({ method: 'GET', url: '/api/v1/auth/sso/callback?code=abc&state=bogus' });
    expect(bad.statusCode).toBe(302);
    expect(bad.headers.location).toContain('ssoError=SSO_STATE_INVALID');

    // An unverified email is refused.
    const s2 = await env.app.inject({ method: 'GET', url: `/api/v1/auth/sso/${made.body.id}/start` });
    const l2 = new URL(s2.headers.location as string);
    state.nonce = l2.searchParams.get('nonce')!;
    state.emailVerified = false;
    const unv = await env.app.inject({ method: 'GET', url: `/api/v1/auth/sso/callback?code=abc&state=${l2.searchParams.get('state')}` });
    state.emailVerified = true;
    expect(unv.headers.location).toContain('ssoError=SSO_TOKEN_INVALID');

    // Enforced SSO blocks passwords for other users of the domain but not for a security manager.
    const staff = await b.api('POST', '/users', { name: 'Staff', email: `staff@${domain}`, password: PASSWORD, roleId: ((await b.api('GET', '/roles')).body.data as { id: string; name: string }[]).find((r) => r.name === 'Accountant')!.id });
    expect(staff.status).toBe(201);
    expect((await b.api('PATCH', `/sso-providers/${made.body.id}`, { enforce: true })).body.enforce).toBe(true);
    expect((await anon()('POST', '/auth/login', { email: `staff@${domain}`, password: PASSWORD })).body.error.code).toBe('SSO_REQUIRED');
    expect((await anon()('POST', '/auth/login', { email: `boss@${domain}`, password: PASSWORD })).status).toBe(200);
    expect((await b.api('DELETE', `/sso-providers/${made.body.id}`)).status).toBe(204);
    expect((await anon()('POST', '/auth/login', { email: `staff@${domain}`, password: PASSWORD })).status).toBe(200);
  });

  it('does not auto-provision past the plan user limit', async () => {
    const domain = `solo-${Date.now()}.test`;
    const b = await signup(`boss@${domain}`);
    const roleId = ((await b.api('GET', '/roles')).body.data as { id: string; name: string }[]).find((r) => r.name === 'Accountant')!.id;
    expect((await b.api('POST', '/company/business-profile', { plan: 'solo' })).status).toBe(200);
    const made = await b.api('POST', '/sso-providers', {
      name: 'Solo IdP', issuer, clientId: state.clientId, clientSecret: 's3cret', emailDomains: [domain],
      autoProvision: true, defaultCompanyId: b.companyId, defaultRoleId: roleId,
    });
    expect(made.status).toBe(201);
    const start = await env.app.inject({ method: 'GET', url: `/api/v1/auth/sso/${made.body.id}/start` });
    const loc = new URL(start.headers.location as string);
    state.nonce = loc.searchParams.get('nonce')!;
    state.email = `new@${domain}`;
    const cb = await env.app.inject({ method: 'GET', url: `/api/v1/auth/sso/callback?code=abc&state=${loc.searchParams.get('state')}` });
    expect(cb.headers.location).toContain('ssoError=SSO_USER_LIMIT');
    expect((await b.api('GET', '/users')).body.data.some((u: { email: string }) => u.email === state.email)).toBe(false);

    // With room on the plan the same sign-in creates the user.
    expect((await b.api('POST', '/company/business-profile', { plan: 'team' })).status).toBe(200);
    const s2 = await env.app.inject({ method: 'GET', url: `/api/v1/auth/sso/${made.body.id}/start` });
    const l2 = new URL(s2.headers.location as string);
    state.nonce = l2.searchParams.get('nonce')!;
    const ok = await env.app.inject({ method: 'GET', url: `/api/v1/auth/sso/callback?code=abc&state=${l2.searchParams.get('state')}` });
    expect(ok.headers.location).toContain('ticket=');
  });
});

describe('jobs', () => {
  it('lists, retries a failed job and rejects retrying anything else', async () => {
    const b = await signup();
    let fail = true;
    registerJobHandler('test.flaky', async () => { if (fail) throw new Error('boom'); return { ok: true }; });
    const jobId = await withTenant(env.db, b.tenantId, (tx) => enqueue(tx, { tenantId: b.tenantId, companyId: b.companyId, userId: b.userId }, 'test.flaky', {}, { maxAttempts: 1 }));
    await runJobs();
    const failed = (await b.api('GET', `/jobs?status=failed&kind=test.flaky`)).body;
    expect(failed.total).toBe(1);
    expect(failed.data[0]).toMatchObject({ id: jobId, status: 'failed', error: 'boom', attempts: 1, createdBy: { id: b.userId } });
    const u = await addUser(b);
    const asUser = client(env.app, (await anon()('POST', '/auth/login', { email: u.email, password: PASSWORD })).body.accessToken, b.companyId);
    expect((await asUser('GET', '/jobs')).status).toBe(403);
    fail = false;
    const retried = await b.api('POST', `/jobs/${jobId}/retry`);
    expect(retried.status).toBe(200);
    expect(retried.body).toMatchObject({ status: 'queued', attempts: 0, error: null });
    expect((await b.api('POST', `/jobs/${jobId}/retry`)).body.error.code).toBe('CONFLICT');
    await runJobs();
    expect((await b.api('GET', `/jobs/${jobId}`)).body).toMatchObject({ status: 'done', result: { ok: true } });
    expect((await b.api('POST', `/jobs/${jobId}/retry`)).status).toBe(409);
  });
});

describe('notifications', () => {
  it('keeps in-app rows, preferences and the outbox', async () => {
    const b = await signup();
    await withTenant(env.db, b.tenantId, (tx) => notify(tx, { tenantId: b.tenantId, companyId: b.companyId }, {
      userIds: [b.userId], template: 'import_finished', data: { kind: 'items', status: 'done', rows: 3 }, link: '/imports',
    }));
    const list = (await b.api('GET', '/notifications')).body;
    expect(list.total).toBe(1);
    expect(list.unread).toBe(1);
    expect(list.data[0]).toMatchObject({ template: 'import_finished', link: '/imports', readAt: null });
    expect((await b.api('GET', '/notifications/unread-count')).body.unread).toBe(1);
    expect((await b.api('POST', `/notifications/${list.data[0].id}/read`)).status).toBe(204);
    expect((await b.api('GET', '/notifications/unread-count')).body.unread).toBe(0);
    expect((await b.api('GET', '/notifications?unread=true')).body.total).toBe(0);
    expect((await b.api('POST', '/notifications/read-all')).status).toBe(204);

    const prefs = (await b.api('GET', '/me/notification-prefs')).body.data as { template: string; email: boolean; mandatory: boolean; whatsapp: boolean | null }[];
    expect(prefs.find((p) => p.template === 'password_reset')).toMatchObject({ email: true, mandatory: true, whatsapp: null });
    expect(prefs.find((p) => p.template === 'compliance_digest')!.email).toBe(false);
    expect((await b.api('PATCH', '/me/notification-prefs', { prefs: [{ template: 'password_reset', email: false }] })).status).toBe(400);
    const patched = (await b.api('PATCH', '/me/notification-prefs', { prefs: [{ template: 'compliance_digest', email: true }, { template: 'approval_decided', email: false }] })).body.data as typeof prefs;
    expect(patched.find((p) => p.template === 'compliance_digest')!.email).toBe(true);
    expect(patched.find((p) => p.template === 'approval_decided')!.email).toBe(false);

    sent.length = 0;
    await anon()('POST', '/auth/password/forgot', { email: b.email });
    await runJobs();
    const outbox = (await b.api('GET', '/notifications/outbox?status=sent&channel=email')).body;
    expect(outbox.data.some((r: { template: string; to: string }) => r.template === 'password_reset' && r.to === b.email)).toBe(true);
    const asUser = client(env.app, (await anon()('POST', '/auth/login', { email: (await addUser(b)).email, password: PASSWORD })).body.accessToken, b.companyId);
    expect((await asUser('GET', '/notifications/outbox')).status).toBe(403);
  });

  it('sends a payment reminder once a day', async () => {
    const b = await signup();
    const wh = (await b.api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
    const item = (await b.api('POST', '/items', { name: 'Service', sku: 'SRV', hsnCode: '9954', unit: 'job', gstRate: 18, salePrice: 1000, purchasePrice: 1000, trackStock: false })).body;
    const noContact = (await b.api('POST', '/parties', { type: 'customer', name: 'No Contact', stateCode: '24' })).body;
    const party = (await b.api('POST', '/parties', { type: 'customer', name: 'Customer One', stateCode: '24', email: 'cust@test.in', phone: '9820012345' })).body;
    expect((await b.api('POST', `/parties/${party.id}/remind`, { channel: 'email' })).body.error.code).toBe('VALIDATION_ERROR');
    expect((await b.api('POST', `/parties/${noContact.id}/remind`, { channel: 'email' })).status).toBe(400);
    expect((await b.api('POST', '/invoices', { locationId: wh.id, partyId: party.id, lines: [{ itemId: item.id, qty: 2, rate: 1000 }] })).status).toBe(201);
    sent.length = 0;
    const res = await b.api('POST', `/parties/${party.id}/remind`, { channel: 'email' });
    expect(res.status).toBe(202);
    expect(res.body.outboxId).toBeTruthy();
    const again = await b.api('POST', `/parties/${party.id}/remind`, { channel: 'email' });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('TOO_SOON');
    await runJobs();
    const mail = sent.find((m) => m.to === 'cust@test.in');
    expect(mail?.template).toBe('payment_reminder');
    expect(mail?.body).toContain('2,360');
    // The other channel is a separate reminder.
    expect((await b.api('POST', `/parties/${party.id}/remind`, { channel: 'whatsapp' })).status).toBe(202);
  });
});

describe('several companies', () => {
  it('creates a company, posts and cancels an inter-company entry and consolidates', async () => {
    const b = await signup(uniqueEmail('group'), 'Group Co');
    const made = await b.api('POST', '/companies', { name: 'Second Co LLP', stateCode: '24' });
    expect(made.status).toBe(201);
    const second = client(env.app, b.token, made.body.id);
    const mine = (await b.api('GET', '/companies')).body.data as { id: string; roles: { name: string }[] }[];
    expect(mine).toHaveLength(2);
    expect(mine.find((c) => c.id === made.body.id)!.roles[0]!.name).toBe('Owner');
    expect((await second('GET', '/locations')).body.data.length).toBeGreaterThan(0);

    const acct = async (api: typeof b.api, code: string) => ((await api('GET', '/accounts')).body.data as { id: string; code: string }[]).find((a) => a.code === code)!.id;
    const [bank, rent, recv] = [await acct(b.api, '1010'), await acct(second, '6000'), await acct(b.api, '1100')];
    const entry = (body: object = {}) => b.api('POST', '/intercompany-entries', {
      date: new Date().toISOString().slice(0, 10), amount: 5000, narration: 'Rent paid for the second company',
      from: { companyId: b.companyId, accountId: bank }, to: { companyId: made.body.id, accountId: rent }, ...body,
    });
    expect((await entry({ from: { companyId: b.companyId, accountId: recv } })).status).toBe(400);
    expect((await entry({ to: { companyId: b.companyId, accountId: rent } })).status).toBe(400);
    const posted = await entry();
    expect(posted.status).toBe(201);
    expect(posted.body).toMatchObject({ amount: 5000, status: 'posted', from: { companyName: 'Group Co' }, to: { companyName: 'Second Co LLP' } });
    expect(posted.body.number).toMatch(/^ICE\//);

    expect((await b.api('GET', '/intercompany-entries')).body.total).toBe(1);
    expect((await second('GET', '/intercompany-entries')).body.total).toBe(1);
    const mineRep = (await b.api('GET', '/reports/intercompany')).body;
    expect(mineRep).toMatchObject({ accountBalance: 5000, unexplained: 0, rows: [{ companyId: made.body.id, balance: 5000 }] });
    expect((await second('GET', '/reports/intercompany')).body.rows[0]).toMatchObject({ companyId: b.companyId, balance: -5000 });

    const ids = `${b.companyId},${made.body.id}`;
    const tb = (await b.api('GET', `/reports/consolidated/trial-balance?companyIds=${ids}`)).body;
    expect(tb.totalDebit).toBe(tb.totalCredit);
    expect(tb.totalDebit).toBe(5000);
    expect(tb.eliminations.intercompany).toBe(5000);
    expect(tb.companies.map((c: { name: string }) => c.name)).toEqual(['Group Co', 'Second Co LLP']);
    expect(tb.rows.find((r: { code: string }) => r.code === '1295')).toBeUndefined();
    const bankRow = tb.rows.find((r: { code: string }) => r.code === '1010');
    expect(bankRow.byCompany).toEqual({ [b.companyId]: -5000, [made.body.id]: 0 });
    const pl = (await b.api('GET', `/reports/consolidated/profit-loss?companyIds=${ids}`)).body;
    expect(pl.netProfit).toBe(-5000);
    const bs = (await b.api('GET', `/reports/consolidated/balance-sheet?companyIds=${ids}`)).body;
    expect(bs.totalAssets).toBe(bs.totalLiabilitiesAndEquity);
    expect((await b.api('GET', `/reports/consolidated/trial-balance?companyIds=${b.companyId},00000000-0000-4000-8000-000000000000`)).status).toBe(403);
    expect((await b.api('GET', `/reports/consolidated/trial-balance?companyIds=${b.companyId}`)).status).toBe(400);

    const cancelled = await b.api('POST', `/intercompany-entries/${posted.body.id}/cancel`, { reason: 'Posted by mistake' });
    expect(cancelled.status).toBe(200);
    expect(cancelled.body).toMatchObject({ status: 'cancelled', cancelReason: 'Posted by mistake' });
    expect((await b.api('POST', `/intercompany-entries/${posted.body.id}/cancel`, { reason: 'Again please' })).status).toBe(409);
    expect((await b.api('GET', '/reports/intercompany')).body.accountBalance).toBe(0);
    const empty = (await b.api('GET', `/reports/consolidated/trial-balance?companyIds=${ids}`)).body;
    expect(empty.rows).toEqual([]);
  });
});

describe('GSP adapter', () => {
  afterEach(() => setGspBackoff([1000, 3000]));

  it('uses the sandbox for GSTR-1 upload and refuses manual mode', async () => {
    const b = await signup();
    const body = { period: new Date().toISOString().slice(0, 7), acknowledgeFailures: true };
    expect((await b.api('POST', '/gst/gstr1/upload', body)).status).toBe(501);
    expect((await b.api('PATCH', '/company/gsp', { mode: 'sandbox' })).body.mode).toBe('sandbox');
    expect((await b.api('GET', '/company')).body.einvoiceMode).toBe('sandbox');
    expect((await b.api('POST', '/company/gsp/test')).body.ok).toBe(true);
    const up = await b.api('POST', '/gst/gstr1/upload', body);
    expect(up.status).toBe(201);
    expect(up.body).toMatchObject({ kind: 'gstr1', provider: 'sandbox', status: 'saved', period: body.period });
    expect(up.body.reference).toMatch(/^SBX-/);
    expect((await b.api('GET', `/gst/submissions?period=${body.period}`)).body.data).toHaveLength(1);
    expect((await b.api('PATCH', '/company/gsp', { provider: 'sandbox' })).status).toBe(400);
  });

  it('seals provider credentials and maps provider failures to 502 and 503', async () => {
    let mode: 'ok' | 'down' | 'reject' = 'ok';
    let calls = 0;
    const fake: GspAdapter = {
      id: 'fakegsp', name: 'Fake GSP', capabilities: new Set(['gstr1_save'] as const),
      credentialFields: [{ key: 'clientId', label: 'Client ID', secret: false }, { key: 'clientSecret', label: 'Client secret', secret: true }],
      ping: async (c) => ({ ok: c.credentials.clientSecret === 'shh', message: 'pong' }),
      generateIrn: async () => { throw new Error('unused'); }, cancelIrn: async () => { throw new Error('unused'); },
      generateEwb: async () => { throw new Error('unused'); }, cancelEwb: async () => { throw new Error('unused'); },
      saveGstr1: async () => {
        calls++;
        if (mode === 'down') throw new GspError('TIMEOUT', 'timed out', true);
        if (mode === 'reject') throw new GspError('E123', 'invalid period', false);
        return { reference: 'FAKE-1', status: 'saved' };
      },
    };
    registerGspAdapter(fake);
    setGspBackoff([1, 1]);
    const b = await signup();
    const period = new Date().toISOString().slice(0, 7);
    const upload = () => b.api('POST', '/gst/gstr1/upload', { period, acknowledgeFailures: true });
    expect((await b.api('PATCH', '/company/gsp', { mode: 'gsp' })).status).toBe(200);
    expect((await upload()).body.error.code).toBe('GSP_NOT_CONFIGURED');
    const saved = await b.api('PATCH', '/company/gsp', { provider: 'fakegsp', credentials: { clientId: 'cid', clientSecret: 'shh' } });
    expect(saved.status).toBe(200);
    expect(saved.body.credentials).toEqual({ clientId: 'cid', clientSecret: null });
    expect(saved.body.savedSecrets).toEqual(['clientSecret']);
    expect(saved.body.providers.map((p: { id: string }) => p.id)).toContain('fakegsp');
    expect((await b.api('PATCH', '/company/gsp', { credentials: { nope: 'x' } })).status).toBe(400);
    // A secret left out is kept.
    expect((await b.api('PATCH', '/company/gsp', { credentials: { clientId: 'cid2' } })).body.savedSecrets).toEqual(['clientSecret']);
    // Needs a GSTIN to call a provider.
    expect((await upload()).body.error.code).toBe('GSP_NOT_CONFIGURED');
    expect((await b.api('PATCH', '/company', { gstin: '24AAACS1234A1ZK' })).status).toBe(200);
    expect((await b.api('POST', '/company/gsp/test')).body).toEqual({ ok: true, message: 'pong' });
    expect((await upload()).body).toMatchObject({ provider: 'fakegsp', reference: 'FAKE-1' });
    mode = 'down';
    calls = 0;
    const down = await upload();
    expect(down.status).toBe(503);
    expect(down.body.error.code).toBe('GSP_UNAVAILABLE');
    expect(calls).toBe(3);
    mode = 'reject';
    const rej = await upload();
    expect(rej.status).toBe(502);
    expect(rej.body.error.code).toBe('GSP_ERROR');
    expect(rej.body.error.details).toMatchObject({ providerCode: 'E123' });
    expect(((await b.api('GET', `/gst/submissions?period=${period}`)).body.data as unknown[]).length).toBe(1);
    // Clearing the secret.
    expect((await b.api('PATCH', '/company/gsp', { credentials: { clientSecret: null } })).body.savedSecrets).toEqual([]);
  });
});
