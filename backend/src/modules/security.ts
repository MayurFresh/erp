import bcrypt from 'bcryptjs';
import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { seal, sha256Hex, unseal } from '../lib/crypto.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { notify } from '../lib/notify.ts';
import { discover, issuerAllowed } from '../lib/oidc.ts';
import { ssoAllowPrivate } from '../config.ts';
import { newRecoveryCodes, newTotpSecret, verifyTotp } from '../lib/totp.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { memberRoles, requireNotMorePowerful } from './users-admin.ts';
import { documentRoute } from '../lib/openapi.ts';

const mfaInvalid = () => new AppError(400, 'MFA_INVALID', 'Incorrect code', { code: 'Incorrect code' });
const codeBody = z.object({ code: z.string().trim().min(1).max(20) });
const confirmBody = z.object({ password: z.string().min(1).max(128), code: z.string().trim().min(1).max(20) });

type UserRow = { two_factor_secret_enc: string | null; two_factor_last_step: number | null; recovery_codes: string[] };

/** Checks a TOTP code or a recovery code. Returns what to store, or null when it is wrong. */
function checkSecondFactor(u: UserRow, code: string): { step?: number; recovery?: string[] } | null {
  if (!u.two_factor_secret_enc) return null;
  if (/^\d{6}$/.test(code)) {
    const step = verifyTotp(unseal(u.two_factor_secret_enc), code, u.two_factor_last_step);
    return step === null ? null : { step };
  }
  const h = sha256Hex(code.trim().toLowerCase());
  return u.recovery_codes.includes(h) ? { recovery: u.recovery_codes.filter((c) => c !== h) } : null;
}

const mintCodes = () => {
  const codes = newRecoveryCodes(10);
  return { codes, hashes: codes.map((c) => sha256Hex(c)) };
};

async function mfaChanged(tx: Tx, ctx: RequestContext, userId: string, enabled: boolean, by: string | null) {
  const u = await tx.selectFrom('users').select('name').where('id', '=', userId).executeTakeFirstOrThrow();
  await notify(tx, { tenantId: ctx.tenantId, companyId: null }, { userIds: [userId], template: 'mfa_changed', data: { name: u.name, enabled, by } });
}

// ---- SSO providers ----

const PUBLIC_DOMAINS = new Set(['gmail.com', 'googlemail.com', 'yahoo.com', 'yahoo.co.in', 'outlook.com', 'hotmail.com', 'live.com',
  'rediffmail.com', 'icloud.com', 'proton.me', 'protonmail.com', 'aol.com', 'zoho.com']);
const DOMAIN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/;
const domainField = z.string().trim().toLowerCase().regex(DOMAIN, 'Enter a domain such as example.com');
const providerFields = {
  name: z.string().trim().min(1).max(80),
  issuer: z.string().trim().max(300).refine(issuerAllowed, 'The issuer must be an https URL'),
  clientId: z.string().trim().min(1).max(300),
  emailDomains: z.array(domainField).min(1).max(10),
  enforce: z.boolean(),
  autoProvision: z.boolean(),
  defaultCompanyId: z.uuid().nullable(),
  defaultRoleId: z.uuid().nullable(),
};
const createProvider = z.object({
  ...providerFields, clientSecret: z.string().min(1).max(500),
  enforce: providerFields.enforce.optional(), autoProvision: providerFields.autoProvision.optional(),
  defaultCompanyId: providerFields.defaultCompanyId.optional(), defaultRoleId: providerFields.defaultRoleId.optional(),
});
const patchProvider = z.object({ ...providerFields, clientSecret: z.string().min(1).max(500) }).partial();

const loadProvider = (tx: Tx, id: string) => tx.selectFrom('sso_providers').selectAll().where('id', '=', id).executeTakeFirst();
type ProviderRow = NonNullable<Awaited<ReturnType<typeof loadProvider>>>;
const providerJson = (p: ProviderRow) => ({
  id: p.id, name: p.name, issuer: p.issuer, clientId: p.client_id, hasClientSecret: !!p.client_secret_enc,
  emailDomains: p.email_domains, enforce: p.enforce, autoProvision: p.auto_provision,
  defaultCompanyId: p.default_company_id, defaultRoleId: p.default_role_id, isActive: p.is_active,
  createdAt: p.created_at, updatedAt: p.updated_at,
});

async function checkDomains(deps: AppDeps, domains: string[], selfId: string | null) {
  for (const d of domains) {
    if (PUBLIC_DOMAINS.has(d)) throw badRequest(`${d} is a public mail domain and cannot be tied to single sign-on.`, { emailDomains: `${d} is a public mail domain` });
    const taken = (await sql<{ id: string }>`select * from auth_find_sso_by_domain(${d})`.execute(deps.db)).rows.find((r) => r.id !== selfId);
    if (taken) throw conflict(`${d} is already used by another sign-in provider.`, 'SSO_DOMAIN_TAKEN', { emailDomains: `${d} is taken` });
  }
}

async function checkDefaults(tx: Tx, p: { autoProvision: boolean; defaultCompanyId: string | null; defaultRoleId: string | null }) {
  if (!p.autoProvision) return;
  if (!p.defaultCompanyId || !p.defaultRoleId) {
    throw badRequest('Choose the default company and role for new users.', { defaultRoleId: 'Required with auto-provision' });
  }
  const c = await tx.selectFrom('companies').select('id').where('id', '=', p.defaultCompanyId).executeTakeFirst();
  const r = await tx.selectFrom('roles').select('id').where('id', '=', p.defaultRoleId).executeTakeFirst();
  if (!c) throw badRequest('Company not found.', { defaultCompanyId: 'Not found' });
  if (!r) throw badRequest('Role not found.', { defaultRoleId: 'Not found' });
}

/** 2FA, sessions, admin 2FA reset/unlock, SSO providers (v1.7 section 1, 3, 4). */
export async function securityRoutes(app: FastifyInstance, deps: AppDeps): Promise<void> {
  const sso = { allowPrivate: ssoAllowPrivate(deps.config) };
  app.get('/me/security', async (req) => {
    const ctx = req.ctx;
    return ctx.tx(async (tx) => {
      const u = await tx.selectFrom('users').select(['two_factor_enabled_at', 'recovery_codes', 'password_changed_at'])
        .where('id', '=', ctx.userId).executeTakeFirstOrThrow();
      return {
        twoFactorEnabled: !!u.two_factor_enabled_at, twoFactorEnabledAt: u.two_factor_enabled_at,
        recoveryCodesLeft: u.two_factor_enabled_at ? u.recovery_codes.length : 0,
        mustEnrol2fa: req.authInfo.mustEnrol2fa, passwordChangedAt: u.password_changed_at,
      };
    });
  });

  app.post('/me/2fa/setup', async (req) => {
    const ctx = req.ctx;
    return ctx.tx(async (tx) => {
      const u = await tx.selectFrom('users').select(['email', 'two_factor_enabled_at']).where('id', '=', ctx.userId).forUpdate().executeTakeFirstOrThrow();
      if (u.two_factor_enabled_at) throw conflict('Two-factor sign-in is already on.', 'MFA_ALREADY_ENABLED');
      const secret = newTotpSecret();
      await tx.updateTable('users').set({ two_factor_pending_enc: seal(secret) }).where('id', '=', ctx.userId).execute();
      return {
        secret,
        otpauthUri: `otpauth://totp/Progen:${encodeURIComponent(u.email)}?secret=${secret}&issuer=Progen&digits=6&period=30`,
      };
    });
  });

  app.post('/me/2fa/enable', async (req) => {
    const ctx = req.ctx;
    const { code } = parse(codeBody, req.body);
    return ctx.tx(async (tx) => {
      const u = await tx.selectFrom('users').select(['two_factor_pending_enc', 'two_factor_enabled_at']).where('id', '=', ctx.userId).forUpdate().executeTakeFirstOrThrow();
      if (u.two_factor_enabled_at) throw conflict('Two-factor sign-in is already on.', 'MFA_ALREADY_ENABLED');
      if (!u.two_factor_pending_enc) throw badRequest('Start the setup first.', { code: 'No setup in progress' });
      const step = verifyTotp(unseal(u.two_factor_pending_enc), code, null);
      if (step === null) throw mfaInvalid();
      const { codes, hashes } = mintCodes();
      await tx.updateTable('users').set({
        two_factor_secret_enc: u.two_factor_pending_enc, two_factor_pending_enc: null, two_factor_enabled_at: new Date(),
        two_factor_last_step: step, recovery_codes: hashes,
      }).where('id', '=', ctx.userId).execute();
      await writeAudit(tx, auditOf(ctx), 'user', ctx.userId, '2fa_enable');
      await mfaChanged(tx, ctx, ctx.userId, true, null);
      return { recoveryCodes: codes };
    });
  });

  /** Password and a TOTP or recovery code: the guard for turning 2FA off and for new recovery codes. */
  async function confirmed(tx: Tx, ctx: RequestContext, body: z.infer<typeof confirmBody>) {
    const u = await tx.selectFrom('users').selectAll().where('id', '=', ctx.userId).forUpdate().executeTakeFirstOrThrow();
    if (!u.two_factor_enabled_at) throw badRequest('Two-factor sign-in is not on.', { code: 'Not enabled' });
    if (!(await bcrypt.compare(body.password, u.password_hash))) throw badRequest('Password is incorrect.', { password: 'Incorrect' });
    const ok = checkSecondFactor(u, body.code);
    if (!ok) throw mfaInvalid();
    return { u, ok };
  }

  app.post('/me/2fa/disable', async (req, reply) => {
    const ctx = req.ctx;
    const body = parse(confirmBody, req.body);
    await ctx.tx(async (tx) => {
      await confirmed(tx, ctx, body);
      const required = await tx.selectFrom('companies').select('id').where('id', 'in', ctx.memberships.map((m) => m.companyId))
        .where('require_2fa', '=', true).limit(1).executeTakeFirst();
      if (required) throw conflict('A company you belong to requires two-factor sign-in.', 'MFA_REQUIRED_BY_COMPANY');
      await tx.updateTable('users').set({
        two_factor_secret_enc: null, two_factor_pending_enc: null, two_factor_enabled_at: null, two_factor_last_step: null, recovery_codes: [],
      }).where('id', '=', ctx.userId).execute();
      await writeAudit(tx, auditOf(ctx), 'user', ctx.userId, '2fa_disable');
      await mfaChanged(tx, ctx, ctx.userId, false, null);
    });
    return reply.status(204).send();
  });

  app.post('/me/2fa/recovery-codes', async (req) => {
    const ctx = req.ctx;
    const body = parse(confirmBody, req.body);
    return ctx.tx(async (tx) => {
      const { ok } = await confirmed(tx, ctx, body);
      const { codes, hashes } = mintCodes();
      await tx.updateTable('users').set({
        recovery_codes: hashes, ...(ok.step !== undefined ? { two_factor_last_step: ok.step } : {}),
      }).where('id', '=', ctx.userId).execute();
      await writeAudit(tx, auditOf(ctx), 'user', ctx.userId, '2fa_recovery_codes');
      return { recoveryCodes: codes };
    });
  });

  app.post<{ Params: { id: string } }>('/users/:id/2fa/reset', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('users.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const roles = await memberRoles(tx, ctx, id);
      if (!roles.length) throw notFound('User');
      requireNotMorePowerful(ctx, roles);
      await tx.updateTable('users').set({
        two_factor_secret_enc: null, two_factor_pending_enc: null, two_factor_enabled_at: null, two_factor_last_step: null, recovery_codes: [],
      }).where('id', '=', id).execute();
      await tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('user_id', '=', id).where('revoked_at', 'is', null).execute();
      await writeAudit(tx, auditOf(ctx), 'user', id, '2fa_reset');
      await mfaChanged(tx, ctx, id, false, ctx.userName);
    });
    return reply.status(204).send();
  });

  app.post<{ Params: { id: string } }>('/users/:id/unlock', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('users.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const roles = await memberRoles(tx, ctx, id);
      if (!roles.length) throw notFound('User');
      await tx.updateTable('users').set({ failed_logins: 0, locked_until: null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'user', id, 'unlock');
    });
    return reply.status(204).send();
  });

  // ---- Sessions ----

  app.get('/me/sessions', async (req) => {
    const ctx = req.ctx;
    return ctx.tx(async (tx) => {
      const live = await tx.selectFrom('refresh_tokens').select('session_id').distinct()
        .where('user_id', '=', ctx.userId).where('revoked_at', 'is', null).where('expires_at', '>', new Date()).execute();
      if (!live.length) return { data: [] };
      const rows = await tx.selectFrom('refresh_tokens').selectAll().where('user_id', '=', ctx.userId)
        .where('session_id', 'in', live.map((r) => r.session_id)).orderBy('created_at').execute();
      const by = new Map<string, typeof rows>();
      for (const r of rows) by.set(r.session_id, [...(by.get(r.session_id) ?? []), r]);
      const METHOD: Record<string, string> = { pwd: 'password', mfa: 'mfa', sso: 'sso' };
      const data = [...by.entries()].map(([sid, rs]) => {
        const last = rs[rs.length - 1]!;
        return {
          id: sid, userAgent: last.user_agent, ip: last.ip, startedAt: rs[0]!.created_at,
          lastUsedAt: last.last_used_at ?? last.created_at, method: METHOD[last.amr] ?? 'password',
          current: sid === req.authInfo.sid,
        };
      });
      data.sort((a, b) => new Date(b.lastUsedAt).getTime() - new Date(a.lastUsedAt).getTime());
      return { data };
    });
  });

  app.delete<{ Params: { id: string } }>('/me/sessions/:id', async (req, reply) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const r = await tx.updateTable('refresh_tokens').set({ revoked_at: new Date() })
        .where('user_id', '=', ctx.userId).where('session_id', '=', id).where('revoked_at', 'is', null).returning('id').execute();
      if (!r.length) throw notFound('Session');
    });
    return reply.status(204).send();
  });

  app.post('/me/sessions/revoke-others', async (req, reply) => {
    const ctx = req.ctx;
    await ctx.tx(async (tx) => {
      let q = tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('user_id', '=', ctx.userId).where('revoked_at', 'is', null);
      if (req.authInfo.sid) q = q.where('session_id', '<>', req.authInfo.sid);
      await q.execute();
    });
    return reply.status(204).send();
  });

  // ---- SSO providers ----

  app.get('/sso-providers', async (req) => {
    const ctx = req.ctx;
    ctx.require('security.manage');
    return ctx.tx(async (tx) => ({
      data: (await tx.selectFrom('sso_providers').selectAll().orderBy('created_at').execute()).map(providerJson),
    }));
  });

  app.post('/sso-providers', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('security.manage');
    const b = parse(createProvider, req.body);
    await discover(b.issuer, sso);
    await checkDomains(deps, b.emailDomains, null);
    const row = await ctx.tx(async (tx) => {
      const autoProvision = b.autoProvision ?? false;
      const defaults = { autoProvision, defaultCompanyId: b.defaultCompanyId ?? null, defaultRoleId: b.defaultRoleId ?? null };
      await checkDefaults(tx, defaults);
      const p = await tx.insertInto('sso_providers').values({
        tenant_id: ctx.tenantId, name: b.name, issuer: b.issuer.replace(/\/+$/, ''), client_id: b.clientId, client_secret_enc: seal(b.clientSecret),
        email_domains: b.emailDomains, enforce: b.enforce ?? false, auto_provision: autoProvision,
        default_company_id: defaults.defaultCompanyId, default_role_id: defaults.defaultRoleId, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'sso_provider', p.id, 'create', null, { name: p.name, issuer: p.issuer, domains: p.email_domains });
      return p;
    });
    return reply.status(201).send(providerJson(row));
  });

  app.patch<{ Params: { id: string } }>('/sso-providers/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('security.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchProvider, req.body);
    if (b.issuer) await discover(b.issuer, sso);
    if (b.emailDomains) await checkDomains(deps, b.emailDomains, id);
    return ctx.tx(async (tx) => {
      const before = await loadProvider(tx, id);
      if (!before) throw notFound('Provider');
      const next = {
        autoProvision: b.autoProvision ?? before.auto_provision,
        defaultCompanyId: b.defaultCompanyId !== undefined ? b.defaultCompanyId : before.default_company_id,
        defaultRoleId: b.defaultRoleId !== undefined ? b.defaultRoleId : before.default_role_id,
      };
      await checkDefaults(tx, next);
      const after = await tx.updateTable('sso_providers').set({
        ...(b.name !== undefined ? { name: b.name } : {}),
        ...(b.issuer !== undefined ? { issuer: b.issuer.replace(/\/+$/, '') } : {}),
        ...(b.clientId !== undefined ? { client_id: b.clientId } : {}),
        ...(b.clientSecret !== undefined ? { client_secret_enc: seal(b.clientSecret) } : {}),
        ...(b.emailDomains !== undefined ? { email_domains: b.emailDomains } : {}),
        ...(b.enforce !== undefined ? { enforce: b.enforce } : {}),
        auto_provision: next.autoProvision, default_company_id: next.defaultCompanyId, default_role_id: next.defaultRoleId,
        updated_at: new Date(),
      }).where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'sso_provider', id, 'update', providerJson(before), providerJson(after));
      return providerJson(after);
    });
  });

  app.post<{ Params: { id: string } }>('/sso-providers/:id/test', async (req) => {
    const ctx = req.ctx;
    ctx.require('security.manage');
    const id = parse(z.uuid(), req.params.id);
    const p = await ctx.tx((tx) => loadProvider(tx, id));
    if (!p) throw notFound('Provider');
    try {
      const d = await discover(p.issuer, sso);
      return { ok: true, message: 'Discovery succeeded.', authorizationEndpoint: d.authorization_endpoint, tokenEndpoint: d.token_endpoint, jwksUri: d.jwks_uri };
    } catch (err) {
      return { ok: false, message: (err as Error).message, authorizationEndpoint: null, tokenEndpoint: null, jwksUri: null };
    }
  });

  app.delete<{ Params: { id: string } }>('/sso-providers/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('security.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const r = await tx.updateTable('sso_providers').set({ is_active: false, updated_at: new Date() }).where('id', '=', id).returning('id').executeTakeFirst();
      if (!r) throw notFound('Provider');
      await writeAudit(tx, auditOf(ctx), 'sso_provider', id, 'deactivate');
    });
    return reply.status(204).send();
  });
}

documentRoute('POST', '/me/2fa/enable', { body: codeBody });
documentRoute('POST', '/me/2fa/disable', { body: confirmBody });
documentRoute('POST', '/me/2fa/recovery-codes', { body: confirmBody });
documentRoute('POST', '/sso-providers', { body: createProvider });
documentRoute('PATCH', '/sso-providers/:id', { body: patchProvider });
