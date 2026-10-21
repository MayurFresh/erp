import bcrypt from 'bcryptjs';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { PERMISSIONS, PERMISSION_KEYS } from '../auth/permissions.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest, conflict, forbidden } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const roleBody = z.object({
  name: z.string().trim().min(2).max(60),
  description: optionalText(200),
  permissions: z.array(z.string()).max(PERMISSION_KEYS.length)
    .refine((ps) => ps.every((p) => PERMISSION_KEYS.includes(p)), 'Unknown permission'),
});
const userBody = z.object({
  name: z.string().trim().min(2).max(80),
  email: z.string().trim().toLowerCase().pipe(z.email('Enter a valid email')),
  phone: optionalText(20),
  password: z.string().min(8, 'Use at least 8 characters').max(128),
  roleId: z.uuid(),
  locationIds: z.array(z.uuid()).max(500).nullable().optional(),
});

export async function userRows(tx: Tx, ctx: RequestContext, userIds: string[]) {
  if (!userIds.length) return [];
  const users = await tx.selectFrom('users').select(['id', 'name', 'email', 'phone', 'is_active'])
    .where('id', 'in', userIds).orderBy('name').execute();
  const assignments = await tx.selectFrom('user_roles as ur').innerJoin('roles as r', 'r.id', 'ur.role_id')
    .select(['ur.user_id', 'ur.role_id', 'r.name as role_name', 'ur.location_ids'])
    .where('ur.user_id', 'in', userIds).where('ur.company_id', '=', ctx.companyId).execute();
  return users.map((u) => ({
    id: u.id, name: u.name, email: u.email, phone: u.phone, isActive: u.is_active,
    assignments: assignments.filter((a) => a.user_id === u.id)
      .map((a) => ({ roleId: a.role_id, roleName: a.role_name, locationIds: a.location_ids })),
  }));
}

export async function userRoutes(app: FastifyInstance) {
  app.get('/permissions', async (req) => {
    req.ctx.require('roles.manage', 'users.manage');
    return PERMISSIONS;
  });

  app.get('/roles', async (req) => {
    const ctx = req.ctx;
    ctx.require('users.manage', 'roles.manage');
    const rows = await ctx.tx((tx) => tx.selectFrom('roles').selectAll().orderBy('is_system', 'desc').orderBy('name').execute());
    return {
      data: rows.map((r) => ({ id: r.id, name: r.name, description: r.description, isSystem: r.is_system, permissions: r.permissions })),
      total: rows.length,
    };
  });

  app.post('/roles', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('roles.manage');
    const body = parse(roleBody, req.body);
    try {
      const role = await ctx.tx(async (tx) => {
        const r = await tx.insertInto('roles').values({
          tenant_id: ctx.tenantId, name: body.name, description: body.description ?? null, is_system: false,
          permissions: [...new Set(body.permissions)],
        }).returningAll().executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'role', r.id, 'create', null, { name: r.name, permissions: r.permissions });
        return r;
      });
      return reply.status(201).send({ id: role.id, name: role.name, description: role.description, isSystem: role.is_system, permissions: role.permissions });
    } catch (err) {
      if ((err as { code?: string }).code === '23505') throw conflict('A role with this name already exists.');
      throw err;
    }
  });

  app.get('/users', async (req) => {
    const ctx = req.ctx;
    ctx.require('users.manage');
    const q = parse(pagingQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('users as u')
        .where((eb) => eb.exists(eb.selectFrom('user_roles as ur').select('ur.id')
          .whereRef('ur.user_id', '=', 'u.id').where('ur.company_id', '=', ctx.companyId)));
      if (q.q) base = base.where((eb) => eb.or([eb('u.name', 'ilike', likeTerm(q.q!)), eb('u.email', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('u.id').orderBy('u.name').limit(q.limit).offset(q.offset).execute();
      return { data: await userRows(tx, ctx, ids.map((r) => r.id)), total };
    });
  });

  app.post('/users', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('users.manage');
    const body = parse(userBody, req.body);
    const passwordHash = await bcrypt.hash(body.password, 10);
    try {
      const row = await ctx.tx(async (tx) => {
        const role = await tx.selectFrom('roles').selectAll().where('id', '=', body.roleId).executeTakeFirst();
        if (!role) throw badRequest('Role not found.', { roleId: 'Not found' });
        // Nobody can hand out access they don't have themselves.
        const missing = role.permissions.filter((p) => !ctx.can(p));
        if (missing.length) throw forbidden(`You cannot assign a role with more access than your own (${missing.join(', ')}).`);

        let locationIds = body.locationIds ?? null;
        const own = ctx.company.locationIds;
        if (own !== null) {
          if (locationIds === null) throw forbidden('You can only give access to your own locations.');
          if (locationIds.some((id) => !own.includes(id))) throw forbidden('You can only give access to your own locations.');
        }
        if (locationIds !== null) {
          locationIds = [...new Set(locationIds)];
          if (!locationIds.length) throw badRequest('Choose at least one location.', { locationIds: 'Required' });
          const found = await tx.selectFrom('locations').select('id')
            .where('company_id', '=', ctx.companyId).where('id', 'in', locationIds).execute();
          if (found.length !== locationIds.length) throw badRequest('One or more locations were not found.', { locationIds: 'Not found' });
        }

        const user = await tx.insertInto('users').values({
          tenant_id: ctx.tenantId, name: body.name, email: body.email, phone: body.phone ?? null, password_hash: passwordHash,
        }).returning('id').executeTakeFirstOrThrow();
        await tx.insertInto('user_roles').values({
          tenant_id: ctx.tenantId, user_id: user.id, role_id: role.id, company_id: ctx.companyId, location_ids: locationIds,
          valid_from: null, valid_to: null,
        }).execute();
        await writeAudit(tx, auditOf(ctx), 'user', user.id, 'create', null,
          { name: body.name, email: body.email, role: role.name, locationIds });
        return (await userRows(tx, ctx, [user.id]))[0]!;
      });
      return reply.status(201).send(row);
    } catch (err) {
      if ((err as { code?: string }).code === '23505') throw conflict('This email is already registered.', 'CONFLICT', { email: 'Already registered' });
      throw err;
    }
  });
}
