import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import type { AppDeps } from '../app.ts';
import { badRequest, forbidden, notFound } from '../lib/errors.ts';
import { gstin, nullableText, stateCode } from '../lib/india.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { companyJson } from './company.ts';
import { documentRoute } from '../lib/openapi.ts';

const blankToNull = (v: unknown) => (v === '' ? null : v);
const createBody = z.object({
  name: z.string().trim().min(2).max(120),
  legalName: nullableText(160),
  stateCode,
  gstin: z.preprocess(blankToNull, gstin.nullable().optional()),
  pan: z.preprocess(blankToNull, z.string().trim().toUpperCase().regex(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'Invalid PAN').nullable().optional()),
  copyAccountsFrom: z.uuid().optional(),
});

/** Creating and listing companies (v1.7 section 11). */
export async function companiesRoutes(app: FastifyInstance, _deps: AppDeps): Promise<void> {
  app.post('/companies', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('companies.create');
    const b = parse(createBody, req.body);
    if (b.gstin && b.gstin.slice(0, 2) !== b.stateCode) {
      throw badRequest('GSTIN does not match the state.', { gstin: 'Does not match the state' });
    }
    if (b.copyAccountsFrom) {
      const src = ctx.memberships.find((m) => m.companyId === b.copyAccountsFrom);
      if (!src) throw forbidden('You are not a member of that company.');
      if (!src.permissions.has('accounts.view')) throw forbidden();
    }
    const row = await ctx.tx(async (tx) => {
      const c = await tx.insertInto('companies').values({
        tenant_id: ctx.tenantId, name: b.name, legal_name: b.legalName ?? null, gstin: b.gstin ?? null,
        state_code: b.stateCode, pan: b.pan ?? (b.gstin ? b.gstin.slice(2, 12) : null), address: null,
      }).returningAll().executeTakeFirstOrThrow();
      await tx.insertInto('locations').values({
        tenant_id: ctx.tenantId, company_id: c.id, parent_id: null, type: 'branch', name: 'Head Office', code: 'HO',
        state_code: b.stateCode, address: null,
      }).execute();
      const owner = await tx.selectFrom('roles').select('id').where('name', '=', 'Owner').where('is_system', '=', true).executeTakeFirst();
      if (!owner) throw notFound('Owner role');
      await tx.insertInto('user_roles').values({
        tenant_id: ctx.tenantId, user_id: ctx.userId, role_id: owner.id, company_id: c.id, location_ids: null, valid_from: null, valid_to: null,
      }).execute();
      await systemAccounts(tx, { tenantId: ctx.tenantId, companyId: c.id });
      if (b.copyAccountsFrom) {
        const accs = await tx.selectFrom('accounts').select(['code', 'name', 'type', 'subtype'])
          .where('company_id', '=', b.copyAccountsFrom).where('is_system', '=', false).where('is_active', '=', true).execute();
        if (accs.length) {
          await tx.insertInto('accounts').values(accs.map((a) => ({
            tenant_id: ctx.tenantId, company_id: c.id, code: a.code, name: a.name, type: a.type, subtype: a.subtype, is_system: false,
          }))).onConflict((oc) => oc.doNothing()).execute();
        }
      }
      await writeAudit(tx, { ...auditOf(ctx), companyId: c.id }, 'company', c.id, 'create', null, { name: c.name, stateCode: c.state_code });
      return c;
    });
    return reply.status(201).send(companyJson(row));
  });

  app.get('/companies', async (req) => {
    const ctx = req.ctx;
    return ctx.tx(async (tx) => {
      const ids = ctx.memberships.map((m) => m.companyId);
      if (!ids.length) return { data: [] };
      const rows = await tx.selectFrom('companies').selectAll().where('id', 'in', ids).orderBy('created_at').execute();
      return {
        data: rows.map((c) => ({
          ...companyJson(c),
          roles: ctx.memberships.find((m) => m.companyId === c.id)?.roles ?? [],
        })),
      };
    });
  });
}

documentRoute('POST', '/companies', { body: createBody });
