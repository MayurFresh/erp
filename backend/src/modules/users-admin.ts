import bcrypt from 'bcryptjs';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { PERMISSION_KEYS } from '../auth/permissions.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { userRows } from './users.ts';

const patchUserBody = z.object({
  name: z.string().trim().min(2).max(80).optional(),
  phone: nullableText(20),
  isActive: z.boolean().optional(),
  roleId: z.uuid().optional(),
  locationIds: z.array(z.uuid()).max(500).nullable().optional(),
});
const passwordBody = z.object({ password: z.string().min(8, 'Use at least 8 characters').max(128) });
const patchRoleBody = z.object({
  name: z.string().trim().min(2).max(60).optional(),
  description: optionalText(200),
  permissions: z.array(z.string()).max(PERMISSION_KEYS.length)
    .refine((ps) => ps.every((p) => PERMISSION_KEYS.includes(p)), 'Unknown permission').optional(),
});

/** The user's role rows in the active company, with the permissions they grant. */
async function memberRoles(tx: Tx, ctx: RequestContext, userId: string) {
  return tx.selectFrom('user_roles as ur').innerJoin('roles as r', 'r.id', 'ur.role_id')
    .select(['ur.id', 'r.name', 'r.permissions', 'ur.location_ids'])
    .where('ur.user_id', '=', userId).where('ur.company_id', '=', ctx.companyId).execute();
}

/** Callers may only manage users whose access is within their own. */
function requireNotMorePowerful(ctx: RequestContext, roles: { permissions: string[] }[]) {
  const extra = roles.flatMap((r) => r.permissions).filter((p) => !ctx.can(p));
  if (extra.length) throw forbidden('This user has access you do not have, so you cannot change them.');
}

async function activeOwners(tx: Tx, ctx: RequestContext, exceptUserId: string): Promise<number> {
  const row = await tx.selectFrom('user_roles as ur').innerJoin('roles as r', 'r.id', 'ur.role_id')
    .innerJoin('users as u', 'u.id', 'ur.user_id')
    .select((eb) => eb.fn.count<number>('ur.user_id').distinct().as('n'))
    .where('ur.company_id', '=', ctx.companyId).where('r.is_system', '=', true).where('r.name', '=', 'Owner')
    .where('u.is_active', '=', true).where('ur.user_id', '!=', exceptUserId)
    .executeTakeFirstOrThrow();
  return Number(row.n);
}

export async function userAdminRoutes(app: FastifyInstance) {
  app.patch<{ Params: { id: string } }>('/users/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('users.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchUserBody, req.body);
    return ctx.tx(async (tx) => {
      const current = await memberRoles(tx, ctx, id);
      if (!current.length) throw notFound('User');
      requireNotMorePowerful(ctx, current);
      const isOwner = current.some((r) => r.name === 'Owner');

      if (body.isActive === false && id === ctx.userId) throw badRequest('You cannot deactivate yourself.', { isActive: 'Not allowed' });

      let newRole: { id: string; name: string; permissions: string[]; is_system: boolean } | undefined;
      if (body.roleId) {
        newRole = await tx.selectFrom('roles').select(['id', 'name', 'permissions', 'is_system']).where('id', '=', body.roleId).executeTakeFirst();
        if (!newRole) throw badRequest('Role not found.', { roleId: 'Not found' });
        const missing = newRole.permissions.filter((p) => !ctx.can(p));
        if (missing.length) throw forbidden(`You cannot assign a role with more access than your own (${missing.join(', ')}).`);
      }
      const losingOwner = isOwner && (body.isActive === false || (newRole && !(newRole.is_system && newRole.name === 'Owner')));
      if (losingOwner && (await activeOwners(tx, ctx, id)) === 0) {
        throw conflict('Every company needs at least one active Owner.', 'CONFLICT');
      }

      const changes = Object.fromEntries(Object.entries({ name: body.name, phone: body.phone, is_active: body.isActive })
        .filter(([, v]) => v !== undefined));
      if (Object.keys(changes).length) await tx.updateTable('users').set(changes).where('id', '=', id).execute();
      if (body.isActive === false) {
        await tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('user_id', '=', id).where('revoked_at', 'is', null).execute();
      }

      if (body.roleId !== undefined || body.locationIds !== undefined) {
        const roleId = newRole?.id ?? (await tx.selectFrom('user_roles').select('role_id').where('id', '=', current[0]!.id).executeTakeFirstOrThrow()).role_id;
        let locationIds = body.locationIds !== undefined ? body.locationIds : current[0]!.location_ids;
        const own = ctx.company.locationIds;
        if (own !== null && (locationIds === null || locationIds.some((l) => !own.includes(l)))) {
          throw forbidden('You can only give access to your own locations.');
        }
        if (locationIds !== null) {
          locationIds = [...new Set(locationIds)];
          if (!locationIds.length) throw badRequest('Choose at least one location.', { locationIds: 'Required' });
          const found = await tx.selectFrom('locations').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', locationIds).execute();
          if (found.length !== locationIds.length) throw badRequest('One or more locations were not found.', { locationIds: 'Not found' });
        }
        await tx.deleteFrom('user_roles').where('user_id', '=', id).where('company_id', '=', ctx.companyId).execute();
        await tx.insertInto('user_roles').values({
          tenant_id: ctx.tenantId, user_id: id, role_id: roleId, company_id: ctx.companyId, location_ids: locationIds,
          valid_from: null, valid_to: null,
        }).execute();
      }
      const after = (await userRows(tx, ctx, [id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'user', id, 'update', { roles: current.map((r) => r.name) }, after);
      return after;
    });
  });

  app.post<{ Params: { id: string } }>('/users/:id/password', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('users.manage');
    const id = parse(z.uuid(), req.params.id);
    const { password } = parse(passwordBody, req.body);
    const hash = await bcrypt.hash(password, 10);
    await ctx.tx(async (tx) => {
      const current = await memberRoles(tx, ctx, id);
      if (!current.length) throw notFound('User');
      requireNotMorePowerful(ctx, current);
      await tx.updateTable('users').set({ password_hash: hash }).where('id', '=', id).execute();
      await tx.updateTable('refresh_tokens').set({ revoked_at: new Date() }).where('user_id', '=', id).where('revoked_at', 'is', null).execute();
      await writeAudit(tx, auditOf(ctx), 'user', id, 'reset_password');
    });
    return reply.status(204).send();
  });

  app.patch<{ Params: { id: string } }>('/roles/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('roles.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchRoleBody, req.body);
    try {
      return await ctx.tx(async (tx) => {
        const before = await tx.selectFrom('roles').selectAll().where('id', '=', id).executeTakeFirst();
        if (!before) throw notFound('Role');
        if (before.is_system) throw forbidden('Built-in roles cannot be changed. Create a new role instead.');
        const changes = Object.fromEntries(Object.entries({
          name: body.name, description: body.description, permissions: body.permissions ? [...new Set(body.permissions)] : undefined,
        }).filter(([, v]) => v !== undefined));
        const after = Object.keys(changes).length
          ? await tx.updateTable('roles').set(changes).where('id', '=', id).returningAll().executeTakeFirstOrThrow()
          : before;
        await writeAudit(tx, auditOf(ctx), 'role', id, 'update', { name: before.name, permissions: before.permissions },
          { name: after.name, permissions: after.permissions });
        return { id: after.id, name: after.name, description: after.description, isSystem: after.is_system, permissions: after.permissions };
      });
    } catch (err) {
      if ((err as { code?: string }).code === '23505') throw conflict('A role with this name already exists.');
      throw err;
    }
  });
}
