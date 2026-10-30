import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import type { LocationTable } from '../db/schema.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText, stateCode } from '../lib/india.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import type { Selectable } from 'kysely';

const TYPES = ['branch', 'site', 'warehouse', 'department', 'store', 'office'] as const;

const listQuery = pagingQuery.extend({ all: z.enum(['true', 'false']).optional() });

const pincodeField = z.string().trim().regex(/^[1-9][0-9]{5}$/, 'Pincode must be 6 digits');
const createBody = z.object({
  type: z.enum(TYPES),
  name: z.string().trim().min(1).max(120),
  code: optionalText(30),
  stateCode: stateCode.optional(),
  address: optionalText(500),
  pincode: pincodeField.optional(),
  parentId: z.uuid().nullable().optional(),
});
const patchBody = z.object({
  type: z.enum(TYPES).optional(),
  name: z.string().trim().min(1).max(120).optional(),
  code: nullableText(30),
  stateCode: stateCode.optional(),
  address: nullableText(500),
  pincode: z.preprocess((v) => (v === '' ? null : v), pincodeField.nullable().optional()),
  parentId: z.uuid().nullable().optional(),
  isActive: z.boolean().optional(),
});

export const locationJson = (l: Selectable<LocationTable>) => ({
  id: l.id, companyId: l.company_id, parentId: l.parent_id, type: l.type, name: l.name, code: l.code,
  stateCode: l.state_code, address: l.address, pincode: l.pincode, isActive: l.is_active, projectId: l.project_id, createdAt: l.created_at,
});

/** Loads a location of the active company that the caller may access. */
export async function getLocation(tx: Tx, ctx: RequestContext, id: string) {
  const loc = await tx.selectFrom('locations').selectAll()
    .where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!loc) throw notFound('Location');
  ctx.requireLocation(loc.id);
  return loc;
}

async function checkParent(tx: Tx, ctx: RequestContext, parentId: string | null | undefined, selfId?: string) {
  if (!parentId) return;
  if (parentId === selfId) throw badRequest('A location cannot be its own parent.', { parentId: 'Invalid parent' });
  const parent = await tx.selectFrom('locations').select('id')
    .where('id', '=', parentId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!parent) throw badRequest('Parent location not found.', { parentId: 'Not found' });
}

export async function locationRoutes(app: FastifyInstance) {
  app.get('/locations', async (req) => {
    const ctx = req.ctx;
    ctx.require('locations.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('locations').where('company_id', '=', ctx.companyId);
      // `all=true` lets a scoped user who can create transfers pick any active destination.
      const all = q.all === 'true' && ctx.can('transfers.create');
      const scope = all ? null : scopedLocationIds(ctx);
      if (scope) base = base.where('id', 'in', scope);
      if (all) base = base.where('is_active', '=', true);
      if (q.q) base = base.where((eb) => eb.or([eb('name', 'ilike', likeTerm(q.q!)), eb('code', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('created_at').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(locationJson), total };
    });
  });

  app.post('/locations', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('locations.manage');
    const body = parse(createBody, req.body);
    const created = await ctx.tx(async (tx) => {
      await checkParent(tx, ctx, body.parentId);
      const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const loc = await tx.insertInto('locations').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, parent_id: body.parentId ?? null, type: body.type,
        name: body.name, code: body.code ?? null, state_code: body.stateCode ?? company.state_code, address: body.address ?? null, pincode: body.pincode ?? null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'location', loc.id, 'create', null, locationJson(loc));
      return loc;
    });
    return reply.status(201).send(locationJson(created));
  });

  app.patch<{ Params: { id: string } }>('/locations/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('locations.manage');
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await getLocation(tx, ctx, req.params.id);
      await checkParent(tx, ctx, body.parentId, before.id);
      if (before.project_id && body.type && body.type !== 'site') {
        throw conflict('This site belongs to a project. Remove it from the project before changing its type.', 'CONFLICT');
      }
      const changes = definedOnly({
        type: body.type, name: body.name, code: body.code, state_code: body.stateCode, address: body.address, pincode: body.pincode,
        parent_id: body.parentId, is_active: body.isActive,
      });
      if (!Object.keys(changes).length) return locationJson(before);
      const after = await tx.updateTable('locations').set(changes)
        .where('id', '=', before.id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'location', after.id, 'update', locationJson(before), locationJson(after));
      return locationJson(after);
    });
  });
}
