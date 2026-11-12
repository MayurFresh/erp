import { randomUUID } from 'node:crypto';
import { assertTenantActive } from '../lib/tenant-status.ts';
import bcrypt from 'bcryptjs';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { systemAccounts } from '../accounting/accounts.ts';
import { SYSTEM_ROLES } from '../auth/permissions.ts';
import { loadMemberships } from '../auth/context.ts';
import type { Amr } from '../auth/tokens.ts';
import { withTenant, type Tx } from '../db/database.ts';
import { randomToken, sha256Hex, unseal } from '../lib/crypto.ts';
import { AppError, badRequest, conflict, unauthorized } from '../lib/errors.ts';
import { notify } from '../lib/notify.ts';
import { discover, exchangeCode, newPkce, verifyIdToken } from '../lib/oidc.ts';
import { ssoAllowPrivate } from '../config.ts';
import { passwordProblem } from '../lib/password.ts';
import { verifyTotp } from '../lib/totp.ts';
import { gstin, optionalText, stateCode } from '../lib/india.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { companyJson } from './company.ts';
import { assertCompanySlot, ensureRoleTemplates } from './business.ts';
import { BUSINESS_TYPE_IDS, COUNTRY_CODES, PLAN_IDS, clampModules, countryOf, defaultModules, typeOf } from '../lib/business-types.ts';
import { documentRoute } from '../lib/openapi.ts';

const BCRYPT_COST = 10;
// Compared against when an email is unknown, so response time doesn't reveal which emails exist.
const DUMMY_HASH = bcrypt.hashSync('not-a-real-password', BCRYPT_COST);

const email = z.string().trim().toLowerCase().pipe(z.email('Enter a valid email'));
const password = z.string().max(128).superRefine((v, c) => { const p = passwordProblem(v, null); if (p) c.addIssue({ code: 'custom', message: p }); });
const MAX_FAILS = 10;
const LOCK_MS = 15 * 60_000;

/** Applies the password policy (lib/password.ts) as a 400 with details { field: message }. */
export function checkPassword(pw: string, email: string | null, field: string): void {
  const problem = passwordProblem(pw, email);
  if (problem) throw badRequest(problem, { [field]: problem });
}

const signupBody = z.object({
  businessName: z.string().trim().min(2).max(120),
  name: z.string().trim().min(2).max(80),
  email,
  password,
  phone: optionalText(20),
  stateCode: stateCode.optional(),
  gstin: gstin.optional().or(z.literal('').transform(() => undefined)),
  businessType: z.enum(BUSINESS_TYPE_IDS as [string, ...string[]]).default('general'),
  plan: z.enum(PLAN_IDS as [string, ...string[]]).default('business'),
  country: z.string().trim().toUpperCase().length(2).refine((c) => COUNTRY_CODES.includes(c), 'Unknown country').default('IN'),
});
const loginBody = z.object({ email, password: z.string().min(1).max(128) });
const mfaBody = z.object({
  mfaToken: z.string().min(10),
  code: z.string().trim().min(1).max(20).optional(),
  recoveryCode: z.string().trim().min(1).max(20).optional(),
}).refine((b) => (b.code ? 1 : 0) + (b.recoveryCode ? 1 : 0) === 1, 'Send either code or recoveryCode');
const forgotBody = z.object({ email });
const resetBody = z.object({ token: z.string().min(10).max(200), newPassword: password });
const ticketBody = z.object({ ticket: z.string().min(10).max(200) });
const refreshBody = z.object({ refreshToken: z.string().min(10) });

async function userJson(tx: Tx, userId: string) {
  const u = await tx.selectFrom('users').select(['id', 'name', 'email', 'phone']).where('id', '=', userId).executeTakeFirstOrThrow();
  return { id: u.id, name: u.name, email: u.email, phone: u.phone };
}

interface SessionInfo { sid?: string; amr: Amr; ua: string | null; ip: string | null }
const sessionOf = (req: FastifyRequest, amr: Amr, sid?: string): SessionInfo => ({
  sid, amr, ua: (req.headers['user-agent'] ?? '').slice(0, 300) || null, ip: (req.ip ?? '').slice(0, 64) || null,
});

async function issueTokens(tx: Tx, deps: AppDeps, tenantId: string, userId: string, s: SessionInfo) {
  const sid = s.sid ?? randomUUID();
  const accessToken = await deps.tokens.signAccess({ tenantId, userId, sid, amr: s.amr });
  const refresh = await deps.tokens.signRefresh({ tenantId, userId, sid, amr: s.amr });
  await tx
    .insertInto('refresh_tokens')
    .values({
      id: refresh.jti, session_id: sid, tenant_id: tenantId, user_id: userId, expires_at: refresh.expiresAt,
      user_agent: s.ua, ip: s.ip, last_used_at: new Date(), amr: s.amr,
    })
    .execute();
  return {
    accessToken,
    refreshToken: refresh.token,
    expiresIn: deps.tokens.accessTtlSeconds,
    user: await userJson(tx, userId),
  };
}

type Fail = { kind: 'locked'; until: Date } | { kind: 'bad' } | { kind: 'inactive' };
const lockedError = (until: Date) => new AppError(423, 'ACCOUNT_LOCKED',
  'Too many failed attempts. This account is locked for 15 minutes.', { lockedUntil: until.toISOString() });

/** Counts a failed attempt and locks the account at MAX_FAILS. Runs inside the caller's transaction. */
async function recordFailure(tx: Tx, userId: string, current: number) {
  const fails = current + 1;
  if (fails >= MAX_FAILS) {
    await tx.updateTable('users').set({ failed_logins: 0, locked_until: new Date(Date.now() + LOCK_MS) }).where('id', '=', userId).execute();
  } else {
    await tx.updateTable('users').set({ failed_logins: fails }).where('id', '=', userId).execute();
  }
}

const clearFailures = (tx: Tx, userId: string) =>
  tx.updateTable('users').set({ failed_logins: 0, locked_until: null }).where('id', '=', userId).execute();

type SsoRow = { id: string; tenant_id: string; name: string; enforce: boolean };

/** 403 SSO_REQUIRED when the email's domain enforces SSO, unless the user holds security.manage somewhere (break-glass). */
async function assertPasswordAllowed(deps: AppDeps, emailAddr: string, user: { id: string; tenant_id: string } | undefined) {
  const domain = emailAddr.split('@')[1] ?? '';
  const rows = (await sql<SsoRow>`select * from auth_find_sso_by_domain(${domain})`.execute(deps.db)).rows;
  const enforced = rows.find((r) => r.enforce);
  if (!enforced) return;
  if (user && user.tenant_id === enforced.tenant_id) {
    const { memberships } = await withTenant(deps.db, user.tenant_id, (tx) => loadMemberships(tx, user.id)).catch(() => ({ memberships: [] }));
    if (memberships.some((m) => m.permissions.has('security.manage'))) return;
  }
  throw new AppError(403, 'SSO_REQUIRED', 'Your organisation requires single sign-on.', { providerId: enforced.id });
}

export async function authRoutes(app: FastifyInstance, deps: AppDeps, perMinute: number | false) {
  const sso = { allowPrivate: ssoAllowPrivate(deps.config) };
  const limited = perMinute === false ? {} : { config: { rateLimit: { max: perMinute, timeWindow: '1 minute' } } };

  app.post('/auth/signup', limited, async (req, reply) => {
    const parsed = parse(signupBody, req.body);
    const india = parsed.country === 'IN';
    if (india && !parsed.stateCode) throw badRequest('Choose your state.', { stateCode: 'Required' });
    // Outside India there is no GST state or GSTIN; 97 is the "other territory" code.
    const body = { ...parsed, stateCode: india ? parsed.stateCode! : '97', gstin: india ? parsed.gstin : undefined };
    const profile = typeOf(body.businessType);
    if (body.gstin && body.gstin.slice(0, 2) !== body.stateCode) {
      throw badRequest('GSTIN does not match the selected state.', { gstin: 'GSTIN does not match the selected state' });
    }
    checkPassword(body.password, body.email, 'password');
    const tenantId = randomUUID();
    const passwordHash = await bcrypt.hash(body.password, BCRYPT_COST);
    try {
      const result = await withTenant(deps.db, tenantId, async (tx) => {
        await tx.insertInto('tenants').values({ id: tenantId, name: body.businessName }).execute();
        const company = await tx
          .insertInto('companies')
          .values({
            tenant_id: tenantId, name: body.businessName, legal_name: null, gstin: body.gstin ?? null,
            state_code: body.stateCode, pan: body.gstin ? body.gstin.slice(2, 12) : null, address: null,
            business_type: body.businessType, plan: body.plan, country: body.country, currency: countryOf(body.country).currency,
            enabled_modules: clampModules(defaultModules(body.businessType, body.country), body.plan, body.country),
            terms: profile.terms as never,
          })
          .returning('id')
          .executeTakeFirstOrThrow();
        await tx
          .insertInto('locations')
          .values({ tenant_id: tenantId, company_id: company.id, parent_id: null, type: 'branch', name: 'Head Office',
            code: 'HO', state_code: body.stateCode, address: null })
          .execute();
        const roles = await tx
          .insertInto('roles')
          .values(SYSTEM_ROLES.map((r) => ({ tenant_id: tenantId, name: r.name, description: r.description, is_system: true, permissions: r.permissions })))
          .returning(['id', 'name'])
          .execute();
        await ensureRoleTemplates(tx, tenantId, body.businessType);
        const user = await tx
          .insertInto('users')
          .values({ tenant_id: tenantId, name: body.name, email: body.email, phone: body.phone ?? null, password_hash: passwordHash })
          .returning('id')
          .executeTakeFirstOrThrow();
        const owner = roles.find((r) => r.name === 'Owner')!;
        await tx
          .insertInto('user_roles')
          .values({ tenant_id: tenantId, user_id: user.id, role_id: owner.id, company_id: company.id, location_ids: null, valid_from: null, valid_to: null })
          .execute();
        await systemAccounts(tx, { tenantId, companyId: company.id });
        await writeAudit(tx, { tenantId, userId: user.id, companyId: company.id }, 'company', company.id, 'signup', null,
          { businessName: body.businessName, stateCode: body.stateCode, businessType: body.businessType, plan: body.plan, country: body.country });
        return issueTokens(tx, deps, tenantId, user.id, sessionOf(req, 'pwd'));
      });
      return reply.status(201).send(result);
    } catch (err) {
      if ((err as { code?: string }).code === '23505') throw conflict('This email is already registered. Please sign in.');
      throw err;
    }
  });

  app.post('/auth/login', limited, async (req) => {
    const body = parse(loginBody, req.body);
    const found = await sql<{ id: string; tenant_id: string; password_hash: string; is_active: boolean }>`
      select * from auth_find_user_by_email(${body.email})`.execute(deps.db);
    const user = found.rows[0];
    await assertPasswordAllowed(deps, body.email, user);
    if (!user) {
      await bcrypt.compare(body.password, DUMMY_HASH);
      throw unauthorized('Email or password is incorrect.');
    }
    const out = await withTenant(deps.db, user.tenant_id, async (tx) => {
      const u = await tx.selectFrom('users').select(['failed_logins', 'locked_until', 'is_active', 'two_factor_enabled_at'])
        .where('id', '=', user.id).forUpdate().executeTakeFirstOrThrow();
      if (u.locked_until && u.locked_until > new Date()) return { kind: 'locked', until: u.locked_until } as Fail;
      if (!(await bcrypt.compare(body.password, user.password_hash))) {
        await recordFailure(tx, user.id, u.failed_logins);
        return { kind: 'bad' } as Fail;
      }
      if (!u.is_active) return { kind: 'inactive' } as Fail;
      await assertTenantActive(tx, user.tenant_id);
      if (u.two_factor_enabled_at) {
        const challengeId = randomUUID();
        await tx.insertInto('mfa_challenges').values({
          id: challengeId, tenant_id: user.tenant_id, user_id: user.id, expires_at: new Date(Date.now() + 5 * 60_000),
        }).execute();
        return { mfa: await deps.tokens.signMfa({ tenantId: user.tenant_id, userId: user.id, challengeId }) };
      }
      await clearFailures(tx, user.id);
      return { tokens: await issueTokens(tx, deps, user.tenant_id, user.id, sessionOf(req, 'pwd')) };
    });
    if ('kind' in out) {
      if (out.kind === 'locked') throw lockedError(out.until);
      if (out.kind === 'inactive') throw unauthorized('This account has been deactivated.');
      throw unauthorized('Email or password is incorrect.');
    }
    if ('mfa' in out) return { mfaRequired: true, mfaToken: out.mfa, methods: ['totp', 'recovery'] };
    return out.tokens;
  });

  app.post('/auth/login/mfa', limited, async (req) => {
    const body = parse(mfaBody, req.body);
    const claims = await deps.tokens.verifyMfa(body.mfaToken);
    const out = await withTenant(deps.db, claims.tenantId, async (tx) => {
      const ch = await tx.selectFrom('mfa_challenges').selectAll().where('id', '=', claims.challengeId).forUpdate().executeTakeFirst();
      if (!ch || ch.user_id !== claims.userId || ch.used_at || ch.expires_at < new Date() || ch.attempts >= 5) return { kind: 'token' as const };
      const u = await tx.selectFrom('users').selectAll().where('id', '=', claims.userId).forUpdate().executeTakeFirstOrThrow();
      if (u.locked_until && u.locked_until > new Date()) return { kind: 'locked' as const, until: u.locked_until };
      if (!u.is_active) return { kind: 'inactive' as const };
      await assertTenantActive(tx, claims.tenantId);
      let ok = false;
      let step: number | null = null;
      let remaining: string[] | null = null;
      if (u.two_factor_secret_enc) {
        if (body.code) {
          step = verifyTotp(unseal(u.two_factor_secret_enc), body.code, u.two_factor_last_step);
          ok = step !== null;
        } else {
          const h = sha256Hex(body.recoveryCode!.trim().toLowerCase());
          if (u.recovery_codes.includes(h)) { ok = true; remaining = u.recovery_codes.filter((c) => c !== h); }
        }
      }
      if (!ok) {
        await tx.updateTable('mfa_challenges').set({ attempts: ch.attempts + 1 }).where('id', '=', ch.id).execute();
        await recordFailure(tx, u.id, u.failed_logins);
        return { kind: 'bad' as const };
      }
      await tx.updateTable('mfa_challenges').set({ used_at: new Date() }).where('id', '=', ch.id).execute();
      await tx.updateTable('users').set({
        failed_logins: 0, locked_until: null,
        ...(step !== null ? { two_factor_last_step: step } : {}),
        ...(remaining ? { recovery_codes: remaining } : {}),
      }).where('id', '=', u.id).execute();
      return { kind: 'ok' as const, tokens: await issueTokens(tx, deps, claims.tenantId, u.id, sessionOf(req, 'mfa')) };
    });
    if (out.kind === 'token') throw unauthorized('Sign in again.');
    if (out.kind === 'locked') throw lockedError(out.until);
    if (out.kind === 'inactive') throw unauthorized('This account has been deactivated.');
    if (out.kind === 'bad') throw new AppError(401, 'MFA_INVALID', 'That code is incorrect or was already used.');
    return out.tokens;
  });

  app.post('/auth/password/forgot', perMinute === false ? {} : { config: { rateLimit: { max: 5, timeWindow: '1 minute' } } }, async (req, reply) => {
    const body = parse(forgotBody, req.body);
    const found = await sql<{ id: string; tenant_id: string; is_active: boolean }>`
      select * from auth_find_user_by_email(${body.email})`.execute(deps.db);
    const user = found.rows[0];
    await assertPasswordAllowed(deps, body.email, user);
    if (user?.is_active) {
      await withTenant(deps.db, user.tenant_id, async (tx) => {
        await tx.updateTable('password_resets').set({ used_at: new Date() }).where('user_id', '=', user.id).where('used_at', 'is', null).execute();
        const token = randomToken(32);
        await tx.insertInto('password_resets').values({
          tenant_id: user.tenant_id, user_id: user.id, token_hash: sha256Hex(token), expires_at: new Date(Date.now() + 30 * 60_000),
        }).execute();
        const u = await tx.selectFrom('users').select('name').where('id', '=', user.id).executeTakeFirstOrThrow();
        await notify(tx, { tenantId: user.tenant_id, companyId: null }, {
          userIds: [user.id], template: 'password_reset',
          data: { name: u.name, link: `${deps.config.APP_URL}/#/reset-password?token=${token}` },
        });
      });
    }
    return reply.status(204).send();
  });

  app.post('/auth/password/reset', limited, async (req, reply) => {
    const body = parse(resetBody, req.body);
    const invalid = () => new AppError(400, 'RESET_TOKEN_INVALID', 'This reset link is invalid or has expired. Ask for a new one.');
    const row = (await sql<{ id: string; tenant_id: string; user_id: string; expires_at: Date; used_at: Date | null }>`
      select * from auth_find_password_reset(${sha256Hex(body.token)})`.execute(deps.db)).rows[0];
    if (!row || row.used_at || row.expires_at < new Date()) throw invalid();
    await withTenant(deps.db, row.tenant_id, async (tx) => {
      const taken = await tx.updateTable('password_resets').set({ used_at: new Date() })
        .where('id', '=', row.id).where('used_at', 'is', null).returning('id').executeTakeFirst();
      if (!taken) throw invalid();
      const u = await tx.selectFrom('users').select('email').where('id', '=', row.user_id).executeTakeFirstOrThrow();
      checkPassword(body.newPassword, u.email, 'newPassword');
      await tx.updateTable('users').set({
        password_hash: await bcrypt.hash(body.newPassword, BCRYPT_COST), password_changed_at: new Date(), failed_logins: 0, locked_until: null,
      }).where('id', '=', row.user_id).execute();
      await tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('user_id', '=', row.user_id).where('revoked_at', 'is', null).execute();
      await writeAudit(tx, { tenantId: row.tenant_id, userId: row.user_id, companyId: null }, 'user', row.user_id, 'password_reset');
    });
    return reply.status(204).send();
  });

  // ---- Single sign-on (OIDC) ----

  const returnToOk = (v: string) => {
    const base = deps.config.APP_URL;
    return v === base || (v.startsWith(base) && ['/', '?', '#'].includes(v[base.length]!));
  };
  const ssoRedirect = (returnTo: string, fragment: string) => `${returnTo.split('#')[0]}#/${fragment}`;

  app.get('/auth/sso/discover', limited, async (req) => {
    const { email: addr } = parse(z.object({ email }), req.query);
    const rows = (await sql<SsoRow>`select * from auth_find_sso_by_domain(${addr.split('@')[1] ?? ''})`.execute(deps.db)).rows;
    return { providers: rows.map((r) => ({ id: r.id, name: r.name })), enforced: rows.some((r) => r.enforce) };
  });

  app.get<{ Params: { id: string } }>('/auth/sso/:id/start', async (req, reply) => {
    const { returnTo } = parse(z.object({ returnTo: z.string().max(500).optional() }), req.query);
    const to = returnTo ?? deps.config.APP_URL;
    if (!returnToOk(to)) throw badRequest('returnTo must be inside the app.', { returnTo: 'Not allowed' });
    const found = (await sql<{ id: string; tenant_id: string; issuer: string; client_id: string; is_active: boolean }>`
      select * from auth_find_sso_provider(${req.params.id})`.execute(deps.db)).rows[0];
    if (!found || !found.is_active) throw new AppError(404, 'NOT_FOUND', 'Sign-in provider not found.');
    const d = await discover(found.issuer, sso);
    const pkce = newPkce();
    const state = randomToken(24);
    const nonce = randomToken(16);
    await withTenant(deps.db, found.tenant_id, (tx) => tx.insertInto('sso_states').values({
      state, tenant_id: found.tenant_id, provider_id: found.id, nonce, code_verifier: pkce.verifier, return_to: to,
      expires_at: new Date(Date.now() + 10 * 60_000),
    }).execute());
    const url = new URL(d.authorization_endpoint);
    url.search = new URLSearchParams({
      response_type: 'code', client_id: found.client_id, redirect_uri: `${deps.config.PUBLIC_API_URL}/api/v1/auth/sso/callback`,
      scope: 'openid email profile', state, nonce, code_challenge: pkce.challenge, code_challenge_method: 'S256',
    }).toString();
    return reply.redirect(url.toString(), 302);
  });

  app.get('/auth/sso/callback', async (req, reply) => {
    const q = (req.query ?? {}) as { code?: string; state?: string; error?: string };
    const back = (returnTo: string, code: string) => reply.redirect(ssoRedirect(returnTo, `login?ssoError=${code}`), 302);
    const st = q.state
      ? (await sql<{ tenant_id: string; provider_id: string; nonce: string; code_verifier: string; return_to: string; expires_at: Date }>`
          select * from auth_take_sso_state(${q.state})`.execute(deps.db)).rows[0]
      : undefined;
    if (!st || st.expires_at < new Date()) return back(deps.config.APP_URL, 'SSO_STATE_INVALID');
    if (q.error || !q.code) return back(st.return_to, 'SSO_IDP_ERROR');

    const provider = await withTenant(deps.db, st.tenant_id, (tx) =>
      tx.selectFrom('sso_providers').selectAll().where('id', '=', st.provider_id).executeTakeFirst());
    if (!provider || !provider.is_active) return back(st.return_to, 'SSO_IDP_ERROR');

    let claims;
    try {
      const d = await discover(provider.issuer, sso);
      let idToken: string;
      try {
        idToken = await exchangeCode(d, {
          code: q.code, redirectUri: `${deps.config.PUBLIC_API_URL}/api/v1/auth/sso/callback`, clientId: provider.client_id,
          clientSecret: provider.client_secret_enc ? unseal(provider.client_secret_enc) : null, verifier: st.code_verifier,
        });
      } catch { return back(st.return_to, 'SSO_IDP_ERROR'); }
      claims = await verifyIdToken(d, idToken, provider.client_id, st.nonce);
    } catch { return back(st.return_to, 'SSO_TOKEN_INVALID'); }
    const mail = typeof claims.email === 'string' ? claims.email.trim().toLowerCase() : '';
    if (!mail || claims.email_verified === false || claims.email_verified === 'false') return back(st.return_to, 'SSO_TOKEN_INVALID');
    if (!provider.email_domains.includes(mail.split('@')[1] ?? '')) return back(st.return_to, 'SSO_DOMAIN_MISMATCH');

    const result = await withTenant(deps.db, st.tenant_id, async (tx) => {
      let u = await tx.selectFrom('users').select(['id', 'is_active']).where(sql<string>`lower(email)`, '=', mail).executeTakeFirst();
      if (!u) {
        if (!provider.auto_provision || !provider.default_role_id || !provider.default_company_id) return 'SSO_NO_ACCOUNT';
        try { await assertCompanySlot(tx, provider.default_company_id); } catch (e) {
          if (e instanceof AppError && e.code === 'USER_LIMIT') return 'SSO_USER_LIMIT';
          throw e;
        }
        const created = await tx.insertInto('users').values({
          tenant_id: st.tenant_id, name: (claims.name ?? mail.split('@')[0]!).slice(0, 80), email: mail, phone: null,
          password_hash: '!sso-account-no-password',
        }).returning(['id', 'is_active']).executeTakeFirstOrThrow();
        await tx.insertInto('user_roles').values({
          tenant_id: st.tenant_id, user_id: created.id, role_id: provider.default_role_id, company_id: provider.default_company_id,
          location_ids: null, valid_from: null, valid_to: null,
        }).execute();
        await writeAudit(tx, { tenantId: st.tenant_id, userId: created.id, companyId: provider.default_company_id }, 'user', created.id, 'sso_provision', null, { email: mail });
        u = created;
      }
      if (!u.is_active) return 'ACCOUNT_DISABLED';
      const ts = await tx.selectFrom('tenants').select('status').where('id', '=', st.tenant_id).executeTakeFirst();
      if (ts && ts.status !== 'active') return 'ACCOUNT_SUSPENDED';
      const ticket = randomToken(32);
      await tx.insertInto('sso_tickets').values({
        tenant_id: st.tenant_id, ticket_hash: sha256Hex(ticket), user_id: u.id, provider_id: provider.id, expires_at: new Date(Date.now() + 60_000),
      }).execute();
      return { ticket };
    });
    if (typeof result === 'string') return back(st.return_to, result);
    return reply.redirect(ssoRedirect(st.return_to, `sso/done?ticket=${result.ticket}`), 302);
  });

  app.post('/auth/sso/redeem', limited, async (req) => {
    const { ticket } = parse(ticketBody, req.body);
    const t = (await sql<{ tenant_id: string; user_id: string }>`select * from auth_take_sso_ticket(${sha256Hex(ticket)})`.execute(deps.db)).rows[0];
    if (!t) throw new AppError(401, 'SSO_TICKET_INVALID', 'This sign-in link has expired. Try again.');
    return withTenant(deps.db, t.tenant_id, async (tx) => {
      const u = await tx.selectFrom('users').select('is_active').where('id', '=', t.user_id).executeTakeFirst();
      if (!u?.is_active) throw unauthorized('This account has been deactivated.');
      await assertTenantActive(tx, t.tenant_id);
      return issueTokens(tx, deps, t.tenant_id, t.user_id, sessionOf(req, 'sso'));
    });
  });

  app.post('/auth/refresh', limited, async (req) => {
    const parsed = refreshBody.safeParse(req.body ?? {});
    if (!parsed.success) throw unauthorized('Session expired. Please sign in again.');
    const { refreshToken } = parsed.data;
    const claims = await deps.tokens.verifyRefresh(refreshToken);
    const result = await withTenant(deps.db, claims.tenantId, async (tx) => {
      const row = await tx.selectFrom('refresh_tokens').selectAll().where('id', '=', claims.jti).forUpdate().executeTakeFirst();
      if (!row || row.user_id !== claims.userId) throw unauthorized('Session expired. Please sign in again.');
      if (row.revoked_at) {
        // A used token came back: assume it was stolen and end every session of this user.
        // Returned rather than thrown so the revocation commits.
        await tx.updateTable('refresh_tokens').set({ revoked_at: new Date() })
          .where('user_id', '=', row.user_id).where('revoked_at', 'is', null).execute();
        return null;
      }
      if (row.expires_at < new Date()) throw unauthorized('Session expired. Please sign in again.');
      const user = await tx.selectFrom('users').select('is_active').where('id', '=', row.user_id).executeTakeFirst();
      if (!user?.is_active) throw unauthorized('This account has been deactivated.');
      await assertTenantActive(tx, claims.tenantId);
      await tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('id', '=', row.id).execute();
      return issueTokens(tx, deps, claims.tenantId, claims.userId, sessionOf(req, row.amr as Amr, row.session_id));
    });
    if (!result) throw unauthorized('Session expired. Please sign in again.');
    return result;
  });

  app.post('/auth/logout', async (req, reply) => {
    const { refreshToken } = parse(refreshBody, req.body);
    try {
      const claims = await deps.tokens.verifyRefresh(refreshToken);
      await withTenant(deps.db, claims.tenantId, (tx) =>
        tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('id', '=', claims.jti).execute(),
      );
    } catch {
      // Logging out with an invalid or expired token is still a successful logout.
    }
    return reply.status(204).send();
  });
}

const changePasswordBody = z.object({ currentPassword: z.string().min(1).max(128), newPassword: password });

export async function meRoutes(app: FastifyInstance) {
  app.post('/me/password', async (req, reply) => {
    const ctx = req.ctx;
    const body = parse(changePasswordBody, req.body);
    await ctx.tx(async (tx) => {
      const u = await tx.selectFrom('users').select(['password_hash', 'email']).where('id', '=', ctx.userId).executeTakeFirstOrThrow();
      if (!(await bcrypt.compare(body.currentPassword, u.password_hash))) {
        throw badRequest('Current password is incorrect.', { currentPassword: 'Incorrect' });
      }
      checkPassword(body.newPassword, u.email, 'newPassword');
      await tx.updateTable('users').set({ password_hash: await bcrypt.hash(body.newPassword, BCRYPT_COST), password_changed_at: new Date() }).where('id', '=', ctx.userId).execute();
      await writeAudit(tx, auditOf(ctx), 'user', ctx.userId, 'change_password');
    });
    return reply.status(204).send();
  });

  app.get('/me', async (req) => {
    const ctx = req.ctx;
    const isPlatformAdmin = (await sql<{ ok: boolean }>`select platform_is_admin(${ctx.userId}::uuid) as ok`.execute(ctx.db)).rows[0]?.ok === true;
    return ctx.tx(async (tx) => {
      const user = { ...(await userJson(tx, ctx.userId)), mustEnrol2fa: req.authInfo?.mustEnrol2fa ?? false };
      const ids = ctx.memberships.map((m) => m.companyId);
      const companies = ids.length
        ? await tx.selectFrom('companies').selectAll().where('id', 'in', ids).execute()
        : [];
      return {
        user,
        isPlatformAdmin,
        companies: ctx.memberships.map((m) => {
          const c = companies.find((x) => x.id === m.companyId)!;
          return { ...companyJson(c), roles: m.roles, permissions: [...m.permissions].sort(), locationIds: m.locationIds };
        }),
      };
    });
  });
}

documentRoute('POST', '/auth/signup', { body: signupBody });
documentRoute('POST', '/auth/login', { body: loginBody });
documentRoute('POST', '/auth/login/mfa', { body: mfaBody });
documentRoute('POST', '/auth/password/forgot', { body: forgotBody });
documentRoute('POST', '/auth/password/reset', { body: resetBody });
documentRoute('POST', '/auth/sso/redeem', { body: ticketBody });
documentRoute('POST', '/auth/logout', { body: refreshBody });
documentRoute('POST', '/me/password', { body: changePasswordBody });
