// Platform super admin: the product owner sees and manages every tenant.
// Cross-tenant reads go only through the platform_* security definer functions (migration 021).
// Work inside one tenant uses withTenant for that tenant, so row-level security still applies.
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { withTenant, type Tx } from '../db/database.ts';
import {
  BUSINESS_TYPE_IDS, PLAN_IDS, clampModules, countryOf, defaultModules, planOf,
} from '../lib/business-types.ts';
import { randomToken, sha256Hex } from '../lib/crypto.ts';
import { AppError, conflict, notFound } from '../lib/errors.ts';
import { parse } from '../lib/validate.ts';
import { ensureRoleTemplates } from './business.ts';
import { documentRoute } from '../lib/openapi.ts';

const notAdmin = () => new AppError(403, 'NOT_PLATFORM_ADMIN', 'This area is for platform administrators only.');
const protectedAdmin = (what: string) =>
  new AppError(409, 'PLATFORM_ADMIN_PROTECTED', `${what} belongs to a platform administrator.`);

const idParam = z.object({ id: z.uuid() });
const listQuery = z.object({
  q: z.string().trim().max(100).optional(),
  status: z.enum(['active', 'suspended']).optional(),
  plan: z.enum(PLAN_IDS as [string, ...string[]]).optional(),
  businessType: z.enum(BUSINESS_TYPE_IDS as [string, ...string[]]).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});
const tenantPatch = z.object({
  status: z.enum(['active', 'suspended']).optional(),
  reason: z.string().trim().min(3, 'Give a reason of at least 3 characters').max(500).optional(),
  name: z.string().trim().min(2).max(120).optional(),
}).refine((b) => b.status !== undefined || b.name !== undefined, 'Nothing to change');
const companyPatch = z.object({
  plan: z.enum(PLAN_IDS as [string, ...string[]]).optional(),
  businessType: z.enum(BUSINESS_TYPE_IDS as [string, ...string[]]).optional(),
}).refine((b) => b.plan !== undefined || b.businessType !== undefined, 'Nothing to change');
const auditQuery = z.object({
  limit: z.coerce.number().int().min(1).max(200).default(50),
  before: z.coerce.date().optional(),
  tenantId: z.uuid().optional(),
});

interface TenantRow {
  id: string; name: string; status: string; created_at: Date; suspended_at: Date | null; suspended_reason: string | null;
  company_count: number; user_count: number; active_users: number;
  business_type: string | null; plan: string | null; country: string | null;
  owner_name: string | null; owner_email: string | null; last_sign_in: Date | null; has_platform_admin: boolean;
}

const tenantJson = (t: TenantRow) => ({
  id: t.id, name: t.name, status: t.status, createdAt: t.created_at,
  suspendedAt: t.suspended_at, suspendedReason: t.suspended_reason,
  companyCount: Number(t.company_count), userCount: Number(t.user_count), activeUsers: Number(t.active_users),
  businessType: t.business_type, plan: t.plan, country: t.country,
  ownerName: t.owner_name, ownerEmail: t.owner_email, lastSignInAt: t.last_sign_in,
  hasPlatformAdmin: t.has_platform_admin,
});

/** Throws 403 NOT_PLATFORM_ADMIN unless the caller is a platform admin. Returns the caller's user id. */
async function requireAdmin(req: FastifyRequest): Promise<string> {
  const ctx = req.ctx;
  const row = (await sql<{ ok: boolean }>`select platform_is_admin(${ctx.userId}::uuid) as ok`.execute(ctx.db)).rows[0];
  if (row?.ok !== true) throw notAdmin();
  return ctx.userId;
}

async function allTenants(req: FastifyRequest, admin: string, tenantId: string | null = null): Promise<TenantRow[]> {
  return (await sql<TenantRow>`select * from platform_tenants(${admin}::uuid, ${tenantId}::uuid)`.execute(req.ctx.db)).rows;
}

async function locate(req: FastifyRequest, admin: string, kind: 'company' | 'user', id: string): Promise<string> {
  const row = (await sql<{ t: string | null }>`select platform_locate(${admin}::uuid, ${kind}, ${id}::uuid) as t`.execute(req.ctx.db)).rows[0];
  if (!row?.t) throw notFound(kind === 'user' ? 'User' : 'Company');
  return row.t;
}

const userIsAdmin = async (req: FastifyRequest, admin: string, userId: string) =>
  (await sql<{ ok: boolean }>`select platform_user_is_admin(${admin}::uuid, ${userId}::uuid) as ok`.execute(req.ctx.db)).rows[0]?.ok === true;

/** Writes the platform audit row in the same transaction as the change. */
async function audit(tx: Tx, admin: string, action: string, tenantId: string | null, type: string, target: string | null, detail: object = {}) {
  await sql`select platform_audit_write(${admin}::uuid, ${action}, ${tenantId}::uuid, ${type}, ${target}, ${JSON.stringify(detail)}::jsonb)`.execute(tx);
}

const tally = (rows: (string | null)[]) => {
  const m = new Map<string, number>();
  for (const r of rows) m.set(r ?? 'none', (m.get(r ?? 'none') ?? 0) + 1);
  return [...m.entries()].map(([key, count]) => ({ key, count })).sort((a, b) => b.count - a.count);
};

export async function platformAdminRoutes(app: FastifyInstance, deps: AppDeps) {
  app.get('/platform/overview', async (req) => {
    const admin = await requireAdmin(req);
    const rows = await allTenants(req, admin);
    const active30 = (await sql<{ n: number }>`select platform_active_users(${admin}::uuid, 30) as n`.execute(req.ctx.db)).rows[0]!.n;
    const now = new Date();
    const months: { month: string; count: number }[] = [];
    for (let i = 11; i >= 0; i--) {
      const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - i, 1));
      months.push({ month: d.toISOString().slice(0, 7), count: 0 });
    }
    for (const t of rows) {
      const m = months.find((x) => x.month === t.created_at.toISOString().slice(0, 7));
      if (m) m.count++;
    }
    return {
      tenants: rows.length,
      activeTenants: rows.filter((t) => t.status === 'active').length,
      suspendedTenants: rows.filter((t) => t.status === 'suspended').length,
      users: rows.reduce((n, t) => n + Number(t.user_count), 0),
      companies: rows.reduce((n, t) => n + Number(t.company_count), 0),
      usersSignedInLast30Days: Number(active30),
      byBusinessType: tally(rows.map((t) => t.business_type)),
      byPlan: tally(rows.map((t) => t.plan)),
      byCountry: tally(rows.map((t) => t.country)),
      signupsByMonth: months,
    };
  });

  app.get('/platform/tenants', async (req) => {
    const admin = await requireAdmin(req);
    const q = parse(listQuery, req.query);
    const needle = q.q?.toLowerCase();
    const rows = (await allTenants(req, admin)).filter((t) =>
      (!q.status || t.status === q.status) && (!q.plan || t.plan === q.plan) && (!q.businessType || t.business_type === q.businessType)
      && (!needle || [t.name, t.owner_email, t.owner_name].some((s) => s?.toLowerCase().includes(needle))));
    return { data: rows.slice(q.offset, q.offset + q.limit).map(tenantJson), total: rows.length };
  });

  app.get('/platform/tenants/:id', async (req) => {
    const admin = await requireAdmin(req);
    const { id } = parse(idParam, req.params);
    const tenant = (await allTenants(req, admin, id))[0];
    if (!tenant) throw notFound('Account');
    const detail = await withTenant(req.ctx.db, id, async (tx) => {
      const companies = await tx.selectFrom('companies').select(['id', 'name', 'business_type', 'plan', 'country', 'currency', 'enabled_modules', 'created_at'])
        .orderBy('created_at').execute();
      const users = await tx.selectFrom('users').select(['id', 'name', 'email', 'is_active', 'locked_until', 'two_factor_enabled_at', 'created_at'])
        .orderBy('created_at').execute();
      const assignments = await tx.selectFrom('user_roles as ur').innerJoin('roles as r', 'r.id', 'ur.role_id')
        .select(['ur.user_id', 'ur.company_id', 'r.name as role_name']).execute();
      const seen = await tx.selectFrom('refresh_tokens').select(['user_id', (eb) => eb.fn.max('created_at').as('last')])
        .groupBy('user_id').execute();
      const invoices = await tx.selectFrom('invoices').select(['company_id', (eb) => eb.fn.countAll<number>().as('n')]).groupBy('company_id').execute();
      const parties = await tx.selectFrom('parties').select(['company_id', (eb) => eb.fn.countAll<number>().as('n')]).groupBy('company_id').execute();
      const items = await tx.selectFrom('items').select(['company_id', (eb) => eb.fn.countAll<number>().as('n')]).groupBy('company_id').execute();
      return { companies, users, assignments, seen, invoices, parties, items };
    });
    const nOf = (rows: { company_id: string; n: number }[], cid: string) => Number(rows.find((r) => r.company_id === cid)?.n ?? 0);
    const adminIds = new Set(
      (await Promise.all(detail.users.map(async (u) => [u.id, await userIsAdmin(req, admin, u.id)] as const))).filter(([, a]) => a).map(([i]) => i));
    return {
      tenant: tenantJson(tenant),
      companies: detail.companies.map((c) => ({
        id: c.id, name: c.name, businessType: c.business_type, plan: c.plan, country: c.country, currency: c.currency,
        enabledModules: c.enabled_modules, createdAt: c.created_at,
        counts: { invoices: nOf(detail.invoices, c.id), parties: nOf(detail.parties, c.id), items: nOf(detail.items, c.id) },
      })),
      users: detail.users.map((u) => ({
        id: u.id, name: u.name, email: u.email, isActive: u.is_active,
        isLocked: !!u.locked_until && u.locked_until > new Date(), lockedUntil: u.locked_until,
        twoFactor: !!u.two_factor_enabled_at, createdAt: u.created_at,
        lastSignInAt: detail.seen.find((s) => s.user_id === u.id)?.last ?? null,
        isPlatformAdmin: adminIds.has(u.id),
        roles: detail.assignments.filter((a) => a.user_id === u.id).map((a) => ({ companyId: a.company_id, role: a.role_name })),
      })),
    };
  });

  app.patch('/platform/tenants/:id', async (req) => {
    const admin = await requireAdmin(req);
    const { id } = parse(idParam, req.params);
    const body = parse(tenantPatch, req.body);
    const tenant = (await allTenants(req, admin, id))[0];
    if (!tenant) throw notFound('Account');
    if (body.status === 'suspended') {
      if (tenant.has_platform_admin) throw protectedAdmin('This account');
      if (!body.reason) throw new AppError(400, 'VALIDATION_ERROR', 'Give a reason for suspending.', { reason: 'Required' });
    }
    await withTenant(req.ctx.db, id, async (tx) => {
      const set: Record<string, unknown> = {};
      if (body.name) set.name = body.name;
      if (body.status === 'suspended') Object.assign(set, { status: 'suspended', suspended_at: new Date(), suspended_reason: body.reason });
      if (body.status === 'active') Object.assign(set, { status: 'active', suspended_at: null, suspended_reason: null });
      await tx.updateTable('tenants').set(set).where('id', '=', id).execute();
      if (body.name && body.name !== tenant.name) await audit(tx, admin, 'tenant_rename', id, 'tenant', id, { from: tenant.name, to: body.name });
      if (body.status && body.status !== tenant.status) {
        await audit(tx, admin, body.status === 'suspended' ? 'tenant_suspend' : 'tenant_activate', id, 'tenant', id,
          body.status === 'suspended' ? { reason: body.reason } : {});
      }
    });
    return tenantJson((await allTenants(req, admin, id))[0]!);
  });

  app.patch('/platform/companies/:id', async (req) => {
    const admin = await requireAdmin(req);
    const { id } = parse(idParam, req.params);
    const body = parse(companyPatch, req.body);
    const tenantId = await locate(req, admin, 'company', id);
    return withTenant(req.ctx.db, tenantId, async (tx) => {
      const before = await tx.selectFrom('companies').select(['id', 'name', 'business_type', 'plan', 'country', 'enabled_modules'])
        .where('id', '=', id).executeTakeFirstOrThrow();
      const type = body.businessType ?? before.business_type;
      const plan = body.plan ?? before.plan;
      if (plan !== before.plan) {
        const max = planOf(plan).maxUsers;
        const n = Number((await tx.selectFrom('users as u').select((eb) => eb.fn.countAll<number>().as('n')).where('u.is_active', '=', true)
          .where((eb) => eb.exists(eb.selectFrom('user_roles as ur').select('ur.id').whereRef('ur.user_id', '=', 'u.id').where('ur.company_id', '=', id)))
          .executeTakeFirstOrThrow()).n);
        if (max !== null && n > max) {
          throw new AppError(409, 'USER_LIMIT', `The ${planOf(plan).name} plan allows ${max} user${max === 1 ? '' : 's'} and this company has ${n}.`,
            { plan, maxUsers: max, users: n });
        }
      }
      const typeChanged = type !== before.business_type;
      const modules = typeChanged || !before.enabled_modules
        ? clampModules(defaultModules(type, before.country), plan, before.country)
        : clampModules(before.enabled_modules, plan, before.country);
      await tx.updateTable('companies').set({ business_type: type, plan, enabled_modules: modules }).where('id', '=', id).execute();
      const rolesCreated = typeChanged ? await ensureRoleTemplates(tx, tenantId, type) : [];
      await audit(tx, admin, 'company_update', tenantId, 'company', id, {
        name: before.name, from: { businessType: before.business_type, plan: before.plan }, to: { businessType: type, plan }, rolesCreated,
      });
      return { id, businessType: type, plan, country: before.country, enabledModules: modules, rolesCreated, currency: countryOf(before.country).currency };
    });
  });

  // ---- Users ----

  const userAction = (
    path: string,
    action: string,
    run: (tx: Tx, userId: string, tenantId: string, admin: string, req: FastifyRequest) => Promise<Record<string, unknown> | void>,
    guard?: (req: FastifyRequest, admin: string, userId: string) => Promise<void>,
  ) => app.post(`/platform/users/:id/${path}`, async (req, reply) => {
    const admin = await requireAdmin(req);
    const { id } = parse(idParam, req.params);
    const tenantId = await locate(req, admin, 'user', id);
    if (guard) await guard(req, admin, id);
    const out = await withTenant(req.ctx.db, tenantId, async (tx) => {
      const extra = await run(tx, id, tenantId, admin, req);
      await audit(tx, admin, action, tenantId, 'user', id);
      return extra;
    });
    return out ? out : reply.status(204).send();
  });

  const refuseAdminTarget = (what: string) => async (req: FastifyRequest, admin: string, userId: string) => {
    if (await userIsAdmin(req, admin, userId)) throw protectedAdmin(what);
  };
  const revokeAll = (tx: Tx, userId: string) =>
    tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('user_id', '=', userId).where('revoked_at', 'is', null).execute();

  userAction('deactivate', 'user_deactivate', async (tx, id) => {
    await tx.updateTable('users').set({ is_active: false }).where('id', '=', id).execute();
    await revokeAll(tx, id);
  }, refuseAdminTarget('This user'));

  userAction('activate', 'user_activate', async (tx, id) => {
    await tx.updateTable('users').set({ is_active: true }).where('id', '=', id).execute();
  });

  userAction('unlock', 'user_unlock', async (tx, id) => {
    await tx.updateTable('users').set({ failed_logins: 0, locked_until: null }).where('id', '=', id).execute();
  });

  userAction('sign-out', 'user_sign_out', async (tx, id) => { await revokeAll(tx, id); });

  // Creates the same kind of reset token as /auth/password/forgot and hands the link to the admin to share.
  app.post('/platform/users/:id/reset-link', async (req) => {
    const admin = await requireAdmin(req);
    const { id } = parse(idParam, req.params);
    const tenantId = await locate(req, admin, 'user', id);
    if (await userIsAdmin(req, admin, id)) throw protectedAdmin('This user');
    return withTenant(req.ctx.db, tenantId, async (tx) => {
      const u = await tx.selectFrom('users').select(['is_active', 'email']).where('id', '=', id).executeTakeFirstOrThrow();
      if (!u.is_active) throw conflict('This user is deactivated. Activate them first.');
      await tx.updateTable('password_resets').set({ used_at: new Date() }).where('user_id', '=', id).where('used_at', 'is', null).execute();
      const token = randomToken(32);
      const expiresAt = new Date(Date.now() + 2 * 60 * 60_000);
      await tx.insertInto('password_resets').values({ tenant_id: tenantId, user_id: id, token_hash: sha256Hex(token), expires_at: expiresAt }).execute();
      await audit(tx, admin, 'user_reset_link', tenantId, 'user', id, { email: u.email });
      return { link: `${deps.config.APP_URL}/#/reset-password?token=${token}`, expiresAt };
    });
  });

  app.get('/platform/audit', async (req) => {
    const admin = await requireAdmin(req);
    const q = parse(auditQuery, req.query);
    const rows = (await sql<{
      id: string; admin_user_id: string; admin_name: string; action: string; tenant_id: string | null; tenant_name: string | null;
      target_type: string; target_id: string | null; detail: unknown; created_at: Date;
    }>`select * from platform_audit_list(${admin}::uuid, ${q.limit}, ${q.before ?? null}::timestamptz, ${q.tenantId ?? null}::uuid)`.execute(req.ctx.db)).rows;
    return {
      data: rows.map((r) => ({
        id: r.id, adminUserId: r.admin_user_id, adminName: r.admin_name, action: r.action, tenantId: r.tenant_id, tenantName: r.tenant_name,
        targetType: r.target_type, targetId: r.target_id, detail: r.detail, createdAt: r.created_at,
      })),
      next: rows.length === q.limit ? rows[rows.length - 1]!.created_at : null,
    };
  });
}

documentRoute('PATCH', '/platform/tenants/:id', { body: tenantPatch });
documentRoute('PATCH', '/platform/companies/:id', { body: companyPatch });
