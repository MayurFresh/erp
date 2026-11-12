import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import { webhookAllowPrivate } from '../config.ts';
import { generateApiKey } from '../lib/api-keys.ts';
import { seal } from '../lib/crypto.ts';
import { badRequest, forbidden, notFound } from '../lib/errors.ts';
import { documentRoute } from '../lib/openapi.ts';
import { pagingQuery } from '../lib/paging.ts';
import { parse } from '../lib/validate.ts';
import { assertWebhookUrl, newSecret, queueDelivery, WEBHOOK_EVENTS } from '../lib/webhooks.ts';
import type { AppDeps } from '../app.ts';
import { auditOf, writeAudit } from './audit.ts';
import { profileBody } from './business.ts';

/** Keys and webhooks are managed by people, never by a key. */
function manage(req: { ctx: RequestContext; authInfo: { amr?: string } }): RequestContext {
  if (req.authInfo.amr === 'key') throw forbidden('API keys cannot manage keys or webhooks.');
  req.ctx.require('integrations.manage');
  return req.ctx;
}

const keyBody = z.object({
  name: z.string().trim().min(1, 'Required').max(80),
  roleId: z.uuid(),
  expiresAt: z.iso.datetime().optional(),
});
const events = z.array(z.enum(WEBHOOK_EVENTS).refine((e) => e !== 'webhook.test', 'Not a subscribable event')).min(1, 'Pick at least one event').max(10);
const hookBody = z.object({
  url: z.string().trim().min(8).max(500),
  description: z.string().trim().max(200).optional(),
  events,
});
const hookPatch = hookBody.partial().extend({ isActive: z.boolean().optional() });

const keyJson = (k: { id: string; name: string; prefix: string; role_id: string; expires_at: Date | null; last_used_at: Date | null; revoked_at: Date | null; created_at: Date }, roleName?: string | null) => ({
  id: k.id, name: k.name, prefix: k.prefix, roleId: k.role_id, roleName: roleName ?? null, expiresAt: k.expires_at,
  lastUsedAt: k.last_used_at, revokedAt: k.revoked_at, createdAt: k.created_at,
});

export async function integrationRoutes(app: FastifyInstance, deps: AppDeps) {
  const allowPrivate = webhookAllowPrivate(deps.config);

  // API keys -----------------------------------------------------------------------------------
  app.get('/api-keys', async (req) => {
    const ctx = manage(req);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('api_keys as k').innerJoin('roles as r', 'r.id', 'k.role_id').selectAll('k')
        .select('r.name as role_name').where('k.company_id', '=', ctx.companyId).orderBy('k.created_at', 'desc').execute();
      return { data: rows.map((k) => keyJson(k, k.role_name)) };
    });
  });

  app.post('/api-keys', async (req, reply) => {
    const ctx = manage(req);
    const body = parse(keyBody, req.body);
    const made = generateApiKey();
    const out = await ctx.tx(async (tx) => {
      const role = await tx.selectFrom('roles').select(['id', 'name', 'permissions']).where('id', '=', body.roleId).executeTakeFirst();
      if (!role) throw notFound('Role');
      // A key can never do more than the person who made it.
      const extra = role.permissions.filter((p) => !ctx.can(p));
      if (extra.length) throw badRequest('That role has permissions you do not have, so a key cannot use it.', { roleId: 'Too powerful' });
      if (role.permissions.some((p) => p === 'integrations.manage' || p === 'roles.manage' || p === 'security.manage' || p === 'users.manage')) {
        throw badRequest('Pick a role without user, role, security or integration management.', { roleId: 'Too powerful' });
      }
      const row = await tx.insertInto('api_keys').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: body.name, prefix: made.prefix, key_hash: made.hash,
        role_id: role.id, created_by: ctx.userId, expires_at: body.expiresAt ? new Date(body.expiresAt) : null,
      }).returning(['id', 'name', 'prefix', 'role_id', 'expires_at', 'last_used_at', 'revoked_at', 'created_at']).executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'api_key', row.id, 'create', null, { name: body.name, roleId: role.id });
      return { ...keyJson(row, role.name), key: made.key };
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/api-keys/:id/revoke', async (req) => {
    const ctx = manage(req);
    return ctx.tx(async (tx) => {
      const row = await tx.updateTable('api_keys').set({ revoked_at: new Date() }).where('id', '=', req.params.id)
        .where('company_id', '=', ctx.companyId).where('revoked_at', 'is', null)
        .returning(['id', 'name', 'prefix', 'role_id', 'expires_at', 'last_used_at', 'revoked_at', 'created_at']).executeTakeFirst();
      if (!row) throw notFound('API key');
      await writeAudit(tx, auditOf(ctx), 'api_key', row.id, 'revoke', null, { name: row.name });
      return keyJson(row);
    });
  });

  // Webhooks -----------------------------------------------------------------------------------
  const hookJson = (h: { id: string; url: string; description: string | null; events: string[]; is_active: boolean; created_at: Date; updated_at: Date }) => ({
    id: h.id, url: h.url, description: h.description, events: h.events, isActive: h.is_active, createdAt: h.created_at, updatedAt: h.updated_at,
  });

  app.get('/webhooks/events', async (req) => {
    manage(req);
    return { data: WEBHOOK_EVENTS.filter((e) => e !== 'webhook.test') };
  });

  app.get('/webhooks', async (req) => {
    const ctx = manage(req);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('webhook_endpoints').selectAll().where('company_id', '=', ctx.companyId).orderBy('created_at', 'desc').execute();
      const last = rows.length ? await tx.selectFrom('webhook_deliveries').select(['endpoint_id', 'status', 'created_at'])
        .where('endpoint_id', 'in', rows.map((r) => r.id)).orderBy('created_at', 'desc').execute() : [];
      return { data: rows.map((h) => ({ ...hookJson(h), lastDelivery: last.find((d) => d.endpoint_id === h.id) ?? null })) };
    });
  });

  app.post('/webhooks', async (req, reply) => {
    const ctx = manage(req);
    const body = parse(hookBody, req.body);
    await assertWebhookUrl(body.url, allowPrivate);
    const secret = newSecret();
    const out = await ctx.tx(async (tx) => {
      const row = await tx.insertInto('webhook_endpoints').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, url: body.url, description: body.description ?? null,
        secret_sealed: seal(secret), events: body.events, created_by: ctx.userId,
      }).returning(['id', 'url', 'description', 'events', 'is_active', 'created_at', 'updated_at']).executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'webhook', row.id, 'create', null, { url: body.url, events: body.events });
      return { ...hookJson(row), secret };
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/webhooks/:id', async (req) => {
    const ctx = manage(req);
    const body = parse(hookPatch, req.body);
    if (body.url) await assertWebhookUrl(body.url, allowPrivate);
    return ctx.tx(async (tx) => {
      const set = {
        ...(body.url !== undefined ? { url: body.url } : {}), ...(body.description !== undefined ? { description: body.description } : {}),
        ...(body.events ? { events: body.events } : {}), ...(body.isActive !== undefined ? { is_active: body.isActive } : {}),
      };
      if (!Object.keys(set).length) throw badRequest('Nothing to change.');
      const row = await tx.updateTable('webhook_endpoints').set(set).where('id', '=', req.params.id).where('company_id', '=', ctx.companyId)
        .returning(['id', 'url', 'description', 'events', 'is_active', 'created_at', 'updated_at']).executeTakeFirst();
      if (!row) throw notFound('Webhook');
      await writeAudit(tx, auditOf(ctx), 'webhook', row.id, 'update', null, set);
      return hookJson(row);
    });
  });

  app.post<{ Params: { id: string } }>('/webhooks/:id/rotate-secret', async (req) => {
    const ctx = manage(req);
    const secret = newSecret();
    return ctx.tx(async (tx) => {
      const row = await tx.updateTable('webhook_endpoints').set({ secret_sealed: seal(secret) }).where('id', '=', req.params.id)
        .where('company_id', '=', ctx.companyId).returning('id').executeTakeFirst();
      if (!row) throw notFound('Webhook');
      await writeAudit(tx, auditOf(ctx), 'webhook', row.id, 'rotate_secret', null, null);
      return { id: row.id, secret };
    });
  });

  app.delete<{ Params: { id: string } }>('/webhooks/:id', async (req, reply) => {
    const ctx = manage(req);
    await ctx.tx(async (tx) => {
      const row = await tx.deleteFrom('webhook_endpoints').where('id', '=', req.params.id).where('company_id', '=', ctx.companyId)
        .returning(['id', 'url']).executeTakeFirst();
      if (!row) throw notFound('Webhook');
      await writeAudit(tx, auditOf(ctx), 'webhook', row.id, 'delete', null, { url: row.url });
    });
    return reply.status(204).send();
  });

  app.post<{ Params: { id: string } }>('/webhooks/:id/test', async (req, reply) => {
    const ctx = manage(req);
    const id = await ctx.tx(async (tx) => {
      const ep = await tx.selectFrom('webhook_endpoints').select('id').where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!ep) throw notFound('Webhook');
      return queueDelivery(tx, ctx, ep.id, 'webhook.test', { message: 'This is a test delivery from Progen.' });
    });
    return reply.status(202).send({ deliveryId: id });
  });

  app.get<{ Params: { id: string } }>('/webhooks/:id/deliveries', async (req) => {
    const ctx = manage(req);
    const q = parse(pagingQuery, req.query);
    return ctx.tx(async (tx) => {
      const ep = await tx.selectFrom('webhook_endpoints').select('id').where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!ep) throw notFound('Webhook');
      const base = tx.selectFrom('webhook_deliveries').where('endpoint_id', '=', ep.id);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        total,
        data: rows.map((d) => ({
          id: d.id, event: d.event, status: d.status, attempts: d.attempts, responseStatus: d.response_status, error: d.error,
          nextAttemptAt: d.next_attempt_at, deliveredAt: d.delivered_at, createdAt: d.created_at,
        })),
      };
    });
  });

  /** Sends a past delivery again as a new delivery. */
  app.post<{ Params: { id: string } }>('/webhooks/deliveries/:id/resend', async (req, reply) => {
    const ctx = manage(req);
    const id = await ctx.tx(async (tx) => {
      const d = await tx.selectFrom('webhook_deliveries as d').innerJoin('webhook_endpoints as e', 'e.id', 'd.endpoint_id')
        .select(['d.endpoint_id', 'd.event', 'd.payload']).where('d.id', '=', req.params.id).where('e.company_id', '=', ctx.companyId).executeTakeFirst();
      if (!d) throw notFound('Delivery');
      const p = (typeof d.payload === 'string' ? JSON.parse(d.payload) : d.payload) as { data?: Record<string, unknown> };
      return queueDelivery(tx, ctx, d.endpoint_id, d.event as never, p.data ?? {});
    });
    return reply.status(202).send({ deliveryId: id });
  });
}

documentRoute('POST', '/api-keys', { summary: 'Create an API key. The key is returned once.', body: keyBody });
documentRoute('POST', '/webhooks', { summary: 'Create a webhook. The signing secret is returned once.', body: hookBody });
documentRoute('PATCH', '/webhooks/:id', { summary: 'Change a webhook', body: hookPatch });
documentRoute('GET', '/webhooks/:id/deliveries', { summary: 'Delivery log of a webhook', query: pagingQuery });
documentRoute('POST', '/company/business-profile', { summary: 'Change business type, plan, modules and words', body: profileBody });
