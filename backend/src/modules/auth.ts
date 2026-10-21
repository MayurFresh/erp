import { randomUUID } from 'node:crypto';
import bcrypt from 'bcryptjs';
import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { systemAccounts } from '../accounting/accounts.ts';
import { SYSTEM_ROLES } from '../auth/permissions.ts';
import { withTenant, type Tx } from '../db/database.ts';
import { badRequest, conflict, unauthorized } from '../lib/errors.ts';
import { gstin, optionalText, stateCode } from '../lib/india.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { companyJson } from './company.ts';

const BCRYPT_COST = 10;
// Compared against when an email is unknown, so response time doesn't reveal which emails exist.
const DUMMY_HASH = bcrypt.hashSync('not-a-real-password', BCRYPT_COST);

const email = z.string().trim().toLowerCase().pipe(z.email('Enter a valid email'));
const password = z.string().min(8, 'Use at least 8 characters').max(128);

const signupBody = z.object({
  businessName: z.string().trim().min(2).max(120),
  name: z.string().trim().min(2).max(80),
  email,
  password,
  phone: optionalText(20),
  stateCode,
  gstin: gstin.optional().or(z.literal('').transform(() => undefined)),
});
const loginBody = z.object({ email, password: z.string().min(1).max(128) });
const refreshBody = z.object({ refreshToken: z.string().min(10) });

async function userJson(tx: Tx, userId: string) {
  const u = await tx.selectFrom('users').select(['id', 'name', 'email', 'phone']).where('id', '=', userId).executeTakeFirstOrThrow();
  return { id: u.id, name: u.name, email: u.email, phone: u.phone };
}

async function issueTokens(tx: Tx, deps: AppDeps, tenantId: string, userId: string) {
  const accessToken = await deps.tokens.signAccess({ tenantId, userId });
  const refresh = await deps.tokens.signRefresh({ tenantId, userId });
  await tx
    .insertInto('refresh_tokens')
    .values({ id: refresh.jti, tenant_id: tenantId, user_id: userId, expires_at: refresh.expiresAt })
    .execute();
  return {
    accessToken,
    refreshToken: refresh.token,
    expiresIn: deps.tokens.accessTtlSeconds,
    user: await userJson(tx, userId),
  };
}

export async function authRoutes(app: FastifyInstance, deps: AppDeps, perMinute: number | false) {
  const limited = perMinute === false ? {} : { config: { rateLimit: { max: perMinute, timeWindow: '1 minute' } } };

  app.post('/auth/signup', limited, async (req, reply) => {
    const body = parse(signupBody, req.body);
    if (body.gstin && body.gstin.slice(0, 2) !== body.stateCode) {
      throw badRequest('GSTIN does not match the selected state.', { gstin: 'GSTIN does not match the selected state' });
    }
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
          { businessName: body.businessName, stateCode: body.stateCode });
        return issueTokens(tx, deps, tenantId, user.id);
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
    const ok = await bcrypt.compare(body.password, user?.password_hash ?? DUMMY_HASH);
    if (!user || !ok) throw unauthorized('Email or password is incorrect.');
    if (!user.is_active) throw unauthorized('This account has been deactivated.');
    return withTenant(deps.db, user.tenant_id, (tx) => issueTokens(tx, deps, user.tenant_id, user.id));
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
      await tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('id', '=', row.id).execute();
      return issueTokens(tx, deps, claims.tenantId, claims.userId);
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
      const u = await tx.selectFrom('users').select('password_hash').where('id', '=', ctx.userId).executeTakeFirstOrThrow();
      if (!(await bcrypt.compare(body.currentPassword, u.password_hash))) {
        throw badRequest('Current password is incorrect.', { currentPassword: 'Incorrect' });
      }
      await tx.updateTable('users').set({ password_hash: await bcrypt.hash(body.newPassword, BCRYPT_COST) }).where('id', '=', ctx.userId).execute();
      await writeAudit(tx, auditOf(ctx), 'user', ctx.userId, 'change_password');
    });
    return reply.status(204).send();
  });

  app.get('/me', async (req) => {
    const ctx = req.ctx;
    return ctx.tx(async (tx) => {
      const user = await userJson(tx, ctx.userId);
      const ids = ctx.memberships.map((m) => m.companyId);
      const companies = ids.length
        ? await tx.selectFrom('companies').selectAll().where('id', 'in', ids).execute()
        : [];
      return {
        user,
        companies: ctx.memberships.map((m) => {
          const c = companies.find((x) => x.id === m.companyId)!;
          return { ...companyJson(c), roles: m.roles, permissions: [...m.permissions].sort(), locationIds: m.locationIds };
        }),
      };
    });
  });
}
