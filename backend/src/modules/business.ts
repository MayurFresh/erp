import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { PERMISSIONS } from '../auth/permissions.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import {
  BUSINESS_TYPES, BUSINESS_TYPE_IDS, COUNTRIES, COUNTRY_CODES, GROUPS, MODULES, MODULE_KEYS, PLANS, PLAN_IDS, TERM_DEFAULTS, TERM_KEYS,
  clampModules, countryOf, defaultModules, planOf, typeOf,
} from '../lib/business-types.ts';
import { AppError, conflict } from '../lib/errors.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { companyJson } from './company.ts';
import { documentRoute } from '../lib/openapi.ts';

/** Creates the role templates of a business type that do not exist yet. Never edits or deletes a role. Returns the names created. */
export async function ensureRoleTemplates(tx: Tx, tenantId: string, typeId: string): Promise<string[]> {
  const created: string[] = [];
  for (const r of typeOf(typeId).roles) {
    const row = await tx.insertInto('roles').values({
      tenant_id: tenantId, name: r.name, description: r.description, is_system: false, permissions: r.permissions,
    })
      // A template named like a built-in role (Accountant) adds its permissions to that role; roles the
      // business made itself are left alone.
      .onConflict((oc) => oc.columns(['tenant_id', 'name'])
        .doUpdateSet({ permissions: sql`array(select distinct unnest(roles.permissions || excluded.permissions) order by 1)` })
        .where('roles.is_system', '=', true))
      .returning(['name', sql<boolean>`xmax = 0`.as('inserted')]).executeTakeFirst();
    if (row?.inserted) created.push(row.name);
  }
  return created;
}

async function activeUsers(tx: Tx, companyId: string): Promise<number> {
  const row = await tx.selectFrom('users as u')
    .select((eb) => eb.fn.countAll<number>().as('n'))
    .where('u.is_active', '=', true)
    .where((eb) => eb.exists(eb.selectFrom('user_roles as ur').select('ur.id').whereRef('ur.user_id', '=', 'u.id').where('ur.company_id', '=', companyId)))
    .executeTakeFirstOrThrow();
  return Number(row.n);
}

/** Refuses when adding users would go over the company's plan limit. */
export const assertUserSlot = (tx: Tx, ctx: RequestContext, adding = 1): Promise<void> => assertCompanySlot(tx, ctx.companyId, adding);

export async function assertCompanySlot(tx: Tx, companyId: string, adding = 1): Promise<void> {
  const company = await tx.selectFrom('companies').select('plan').where('id', '=', companyId).executeTakeFirstOrThrow();
  const plan = planOf(company.plan);
  if (plan.maxUsers === null) return;
  if ((await activeUsers(tx, companyId)) + adding > plan.maxUsers) {
    throw new AppError(409, 'USER_LIMIT',
      `The ${plan.name} plan allows ${plan.maxUsers} user${plan.maxUsers === 1 ? '' : 's'}. Change the plan under Settings, Business profile to add more.`,
      { plan: plan.id, maxUsers: plan.maxUsers });
  }
}

const cleanTerms = (t: Partial<Record<string, string>>): Record<string, string> =>
  Object.fromEntries(Object.entries(t).map(([k, v]) => [k, (v ?? '').trim()]).filter(([, v]) => v));

export const profileBody = z.object({
  businessType: z.enum(BUSINESS_TYPE_IDS as [string, ...string[]]).optional(),
  plan: z.enum(PLAN_IDS as [string, ...string[]]).optional(),
  country: z.string().trim().toUpperCase().length(2).refine((c) => COUNTRY_CODES.includes(c), 'Unknown country').optional(),
  currency: z.string().trim().toUpperCase().regex(/^[A-Z]{3}$/, 'Use a 3-letter currency code').optional(),
  enabledModules: z.array(z.enum(MODULE_KEYS as [string, ...string[]])).max(MODULE_KEYS.length).nullable().optional(),
  terms: z.partialRecord(z.enum(TERM_KEYS as [string, ...string[]]), z.string().trim().max(30)).optional(),
});

export async function businessRoutes(app: FastifyInstance, _deps: AppDeps): Promise<void> {
  app.post('/company/business-profile', async (req) => {
    const ctx = req.ctx;
    ctx.require('company.manage');
    const body = parse(profileBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('companies').selectAll().where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const type = body.businessType ?? before.business_type;
      const plan = body.plan ?? before.plan;
      const country = body.country ?? before.country;
      const countryChanged = country !== before.country;
      const currency = body.currency ?? (countryChanged ? countryOf(country).currency : before.currency);

      if (countryChanged || currency !== before.currency) {
        const invoice = await tx.selectFrom('invoices').select('id').where('company_id', '=', ctx.companyId).limit(1).executeTakeFirst();
        const bill = await tx.selectFrom('purchases').select('id').where('company_id', '=', ctx.companyId).limit(1).executeTakeFirst();
        if (invoice || bill) {
          throw conflict('The country and currency cannot change after invoices or bills exist.', 'CONFLICT',
            countryChanged ? { country: 'Locked' } : { currency: 'Locked' });
        }
      }
      if (plan !== before.plan) {
        const max = planOf(plan).maxUsers;
        const n = await activeUsers(tx, ctx.companyId);
        if (max !== null && n > max) {
          throw new AppError(409, 'USER_LIMIT',
            `The ${planOf(plan).name} plan allows ${max} user${max === 1 ? '' : 's'} and this company has ${n}. Deactivate users first.`,
            { plan, maxUsers: max, users: n });
        }
      }

      const typeChanged = type !== before.business_type;
      let modules: string[] | null;
      if (body.enabledModules) modules = clampModules(body.enabledModules, plan, country);
      else if (body.enabledModules === null || typeChanged || countryChanged) modules = clampModules(defaultModules(type, country), plan, country);
      else modules = before.enabled_modules ? clampModules(before.enabled_modules, plan, country) : null;

      let terms = before.terms as Record<string, string>;
      if (typeChanged) terms = { ...typeOf(type).terms, ...cleanTerms(body.terms ?? {}) };
      else if (body.terms !== undefined) terms = cleanTerms(body.terms);

      // A company outside India has no GST state; 97 is the "other territory" code.
      const stateFix = country !== 'IN' && before.state_code !== '97' ? { state_code: '97', gstin: null } : {};
      const after = await tx.updateTable('companies').set({
        business_type: type, plan, country, currency, enabled_modules: modules, terms: terms as never, ...stateFix,
      }).where('id', '=', ctx.companyId).returningAll().executeTakeFirstOrThrow();
      const rolesCreated = await ensureRoleTemplates(tx, ctx.tenantId, type);
      await writeAudit(tx, auditOf(ctx), 'company', ctx.companyId, 'business_profile', companyJson(before), { ...companyJson(after), rolesCreated });
      return { company: companyJson(after), rolesCreated };
    });
  });
}

/** Public catalogue for signup and the business profile screen. */
export async function businessCatalogueRoutes(app: FastifyInstance): Promise<void> {
  app.get('/business-types', async () => ({
    groups: GROUPS,
    types: BUSINESS_TYPES.map((t) => ({
      id: t.id, name: t.name, group: t.group, description: t.description, icon: t.icon, modules: t.modules,
      roles: t.roles, terms: t.terms, quickActions: t.quickActions,
    })),
    modules: MODULES, plans: PLANS, termDefaults: TERM_DEFAULTS, countries: COUNTRIES,
    permissionCount: PERMISSIONS.length,
  }));
}

documentRoute('POST', '/company/business-profile', { body: profileBody });
