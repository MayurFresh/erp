import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { contextFor } from '../auth/context.ts';
import { withTenant, type Db, type Tx } from '../db/database.ts';
import { CONNECTORS, connectorById } from '../lib/channels/registry.ts';
import { channelAllowPrivate } from '../lib/channels/http.ts';
import { ChannelError, type ChannelCall, type ChannelConnector, type NormalisedOrder, type StockUpdate } from '../lib/channels/types.ts';
import { seal, unseal } from '../lib/crypto.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { enqueue, registerJobHandler } from '../lib/jobs.ts';
import { parse } from '../lib/validate.ts';
import { assertWebhookUrl } from '../lib/webhooks.ts';
import { auditOf, writeAudit } from './audit.ts';
import { loadConnection } from './channels.ts';
import { processOrder, type Connection } from './channels-flow.ts';
import { documentRoute } from '../lib/openapi.ts';

type Conn = Awaited<ReturnType<typeof loadConnection>>;

const callOf = (credentials: Record<string, string>): ChannelCall => ({ credentials, timeoutMs: 15_000, fetch: globalThis.fetch });

export function liveConnector(provider: string): ChannelConnector | null {
  const c = connectorById(provider);
  return c && c.credentialFields.length > 0 ? c : null;
}

/** Credential values, opened. Never log or return the result. */
function openCredentials(conn: { credentials: string | null }): Record<string, string> | null {
  if (!conn.credentials) return null;
  try { return JSON.parse(unseal(conn.credentials)) as Record<string, string>; } catch { return null; }
}

export const credentialStatus = (conn: { provider: string; credentials: string | null }) => {
  const c = liveConnector(conn.provider);
  const have = openCredentials(conn) ?? {};
  return (c?.credentialFields ?? []).map((f) => ({ key: f.key, label: f.label, secret: f.secret, set: Boolean(have[f.key]) }));
};

/** Records a provider failure on the connection. An auth failure degrades it. */
async function recordFailure(tx: Tx, connId: string, err: ChannelError) {
  await tx.updateTable('channel_connections').set({
    last_error: err.message.slice(0, 300), last_error_at: new Date(), last_check_at: new Date(),
    ...(err.kind === 'auth' ? { status: 'degraded', status_reason: err.message.slice(0, 300) } : {}),
  } as never).where('id', '=', connId).execute();
}

const credBody = z.object({ values: z.record(z.string().min(1).max(40), z.string().trim().min(1, 'Required').max(500)) });
const syncBody = z.object({ what: z.enum(['orders', 'stock']) });

async function validateCredentials(c: ChannelConnector, values: Record<string, string>) {
  const errors: Record<string, string> = {};
  for (const f of c.credentialFields) if (!values[f.key]) errors[f.key] = 'Required';
  for (const k of Object.keys(values)) if (!c.credentialFields.some((f) => f.key === k)) errors[k] = 'Not used by this channel';
  if (Object.keys(errors).length) throw badRequest('Check the credential fields.', errors);
  if (c.id === 'woocommerce') await assertWebhookUrl(values.storeUrl!, channelAllowPrivate());
  if (c.id === 'shopify') {
    const d = values.shopDomain!.trim().replace(/\/+$/, '');
    const ok = /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/i.test(d) || (channelAllowPrivate() && /^https?:\/\/[^/@\s]+$/.test(d));
    if (!ok) throw badRequest('Shop domain must look like yourshop.myshopify.com.', { shopDomain: 'Not a Shopify domain' });
    if (!/^\d+$/.test(values.locationId!)) throw badRequest('Location id is a number.', { locationId: 'Numbers only' });
  }
}

export async function channelLiveRoutes(app: FastifyInstance) {
  app.route<{ Params: { id: string } }>({ method: ['PUT', 'PATCH'], url: '/channels/:id/credentials', handler: async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(credBody, req.body);
    return ctx.tx(async (tx) => {
      const conn = await loadConnection(tx, ctx, id, true);
      const c = liveConnector(conn.provider);
      if (!c) throw conflict('This channel has no live connection. Import its files instead.', 'NO_LIVE_API');
      await validateCredentials(c, b.values);
      await tx.updateTable('channel_connections').set({
        credentials: seal(JSON.stringify(b.values)), status: 'not_connected', status_reason: 'Credentials saved. Run the check.',
        provider_version: c.version, push_stock: false, updated_at: new Date(),
      } as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'channel', id, 'set_credentials', null, { fields: Object.keys(b.values) });
      return { credentials: credentialStatus(await loadConnection(tx, ctx, id)), status: 'not_connected' };
    });
  } });

  app.delete<{ Params: { id: string } }>('/channels/:id/credentials', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const conn = await loadConnection(tx, ctx, id, true);
      if (!liveConnector(conn.provider)) throw conflict('This channel has no live connection.', 'NO_LIVE_API');
      await tx.updateTable('channel_connections').set({
        credentials: null, status: 'not_connected', status_reason: 'Credentials removed', push_stock: false, cursors: '{}', updated_at: new Date(),
      } as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'channel', id, 'revoke_credentials', null, null);
      return { credentials: credentialStatus(await loadConnection(tx, ctx, id)), status: 'not_connected' };
    });
  });

  app.post<{ Params: { id: string } }>('/channels/:id/check', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const conn = await loadConnection(tx, ctx, id, true);
      const c = liveConnector(conn.provider);
      if (!c?.ping) throw conflict('This channel has no live connection.', 'NO_LIVE_API');
      const cred = openCredentials(conn);
      if (!cred) throw conflict('Save the credentials first.', 'NO_CREDENTIALS');
      try {
        const r = await c.ping(callOf(cred));
        await tx.updateTable('channel_connections').set({
          status: 'connected', status_reason: null, last_check_at: new Date(), last_success_at: new Date(), last_error: null, last_error_at: null,
          updated_at: new Date(),
        } as never).where('id', '=', id).execute();
        return { ok: true, message: r.message, status: 'connected' };
      } catch (err) {
        if (!(err instanceof ChannelError)) throw err;
        const was = conn.status === 'connected' || conn.status === 'degraded';
        await tx.updateTable('channel_connections').set({
          status: was ? 'degraded' : 'not_connected', status_reason: err.message.slice(0, 300), last_check_at: new Date(),
          last_error: err.message.slice(0, 300), last_error_at: new Date(), updated_at: new Date(),
        } as never).where('id', '=', id).execute();
        return { ok: false, message: err.message, code: err.code, status: was ? 'degraded' : 'not_connected' };
      }
    });
  });

  app.post<{ Params: { id: string } }>('/channels/:id/sync', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(syncBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const conn = await loadConnection(tx, ctx, id, true);
      const c = liveConnector(conn.provider);
      if (!c) throw conflict('This channel has no live connection.', 'NO_LIVE_API');
      if (conn.status !== 'connected') throw conflict('Run the check until the channel shows connected.', 'NOT_CONNECTED');
      const who = { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId };
      const stamp = Date.now();
      if (b.what === 'orders') {
        return { jobId: await enqueue(tx, who, 'channel.pull', { connectionId: id }, { dedupeKey: `channel.pull:${id}:manual:${stamp}` }) };
      }
      if (!conn.push_stock) throw conflict('Turn on stock push for this channel first.', 'PUSH_OFF');
      await tx.updateTable('channel_listings').set({ pushed_qty: null } as never).where('connection_id', '=', id).execute();
      return { jobId: await enqueue(tx, who, 'channel.stock', {}, { dedupeKey: `channel.stock:${ctx.companyId}:manual:${stamp}` }) };
    });
    return reply.status(202).send(out);
  });

  app.get<{ Params: { id: string } }>('/channels/:id/health', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const c = await loadConnection(tx, ctx, id);
      const counts = await tx.selectFrom('channel_inbox').select('status').select((eb) => eb.fn.countAll<number>().as('n'))
        .where('connection_id', '=', id).groupBy('status').execute();
      const n = (s: string) => Number(counts.find((r) => r.status === s)?.n ?? 0);
      const unmapped = await tx.selectFrom('channel_unmapped').select((eb) => eb.fn.countAll<number>().as('n')).where('connection_id', '=', id).executeTakeFirstOrThrow();
      const pushErrors = await tx.selectFrom('channel_listings').select((eb) => eb.fn.countAll<number>().as('n'))
        .where('connection_id', '=', id).where('push_error', 'is not', null).executeTakeFirstOrThrow();
      const queued = await tx.selectFrom('jobs').select((eb) => eb.fn.countAll<number>().as('n')).where('company_id', '=', ctx.companyId)
        .where('kind', 'like', 'channel.%').where('status', 'in', ['queued', 'running']).executeTakeFirstOrThrow();
      const live = liveConnector(c.provider);
      return {
        id: c.id, provider: c.provider, status: c.status, statusReason: c.status_reason, live: Boolean(live),
        hasCredentials: Boolean(c.credentials), credentials: credentialStatus(c), pushStock: c.push_stock,
        lastCheckAt: c.last_check_at, lastSuccessAt: c.last_success_at, lastError: c.last_error, lastErrorAt: c.last_error_at,
        webhookRejects: c.webhook_rejects, webhookPath: live ? `/api/v1/webhooks/channels/${c.id}` : null,
        inbox: { received: n('received'), failed: n('failed'), dead: n('dead') }, unmapped: Number(unmapped.n),
        pushErrors: Number(pushErrors.n), queuedJobs: Number(queued.n),
      };
    });
  });
}

/** Public: providers call this. Signature first, then store, then a job. */
export async function channelWebhookRoutes(app: FastifyInstance, db: Db) {
  app.addContentTypeParser('application/json', { parseAs: 'buffer' }, (_req, body, done) => done(null, body));
  app.post<{ Params: { connectionId: string } }>('/webhooks/channels/:connectionId',
    { bodyLimit: 1024 * 1024, config: { rateLimit: { max: 120, timeWindow: '1 minute' } } },
    async (req, reply) => {
      const id = z.uuid().safeParse(req.params.connectionId);
      if (!id.success) throw notFound('Channel');
      const target = (await sql<{ tenant_id: string; company_id: string; provider: string; status: string; credentials: string | null; created_by: string }>
        `select * from channel_webhook_target(${id.data}::uuid)`.execute(db)).rows[0];
      const c = target ? liveConnector(target.provider) : null;
      if (!target || !c?.verifyWebhook || !target.credentials || ['disabled', 'suspended', 'not_connected'].includes(target.status)) throw notFound('Channel');
      const cred = openCredentials(target);
      const raw = Buffer.isBuffer(req.body) ? req.body : Buffer.from('');
      const hit = cred ? c.verifyWebhook(raw, req.headers as Record<string, string | undefined>, cred) : null;
      if (!hit) {
        await sql`select channel_webhook_reject(${id.data}::uuid)`.execute(db);
        return reply.status(401).send({ error: { code: 'BAD_SIGNATURE', message: 'The signature did not match.' } });
      }
      let payload: unknown;
      try { payload = JSON.parse(raw.toString('utf8')); } catch { throw badRequest('The body is not JSON.'); }
      await withTenant(db, target.tenant_id, async (tx) => {
        const row = await tx.insertInto('channel_inbox').values({
          tenant_id: target.tenant_id, company_id: target.company_id, connection_id: id.data, event_id: hit.eventId.slice(0, 150),
          topic: hit.topic.slice(0, 60), source: 'webhook', payload: JSON.stringify(payload),
        }).onConflict((oc) => oc.columns(['connection_id', 'event_id']).doNothing()).returning('id').executeTakeFirst();
        if (row) {
          await enqueue(tx, { tenantId: target.tenant_id, companyId: target.company_id, userId: target.created_by }, 'channel.event',
            { inboxId: row.id }, { dedupeKey: `channel.event:${row.id}`, maxAttempts: 5 });
        }
      });
      await sql`select channel_webhook_accept(${id.data}::uuid)`.execute(db);
      return reply.send({ ok: true });
    });
}

// Jobs -------------------------------------------------------------------------------------------------------

const asConnection = (c: Conn) => c as unknown as Connection;

/** Stores events from a pull and queues each for processing. */
async function storePulled(tx: Tx, conn: Conn, events: { eventId: string; topic: string; payload: unknown }[]) {
  for (const e of events) {
    const row = await tx.insertInto('channel_inbox').values({
      tenant_id: conn.tenant_id, company_id: conn.company_id, connection_id: conn.id, event_id: e.eventId.slice(0, 150),
      topic: e.topic.slice(0, 60), source: 'poll', payload: JSON.stringify(e.payload),
    }).onConflict((oc) => oc.columns(['connection_id', 'event_id']).doNothing()).returning('id').executeTakeFirst();
    if (row) {
      await enqueue(tx, { tenantId: conn.tenant_id, companyId: conn.company_id, userId: conn.created_by }, 'channel.event',
        { inboxId: row.id }, { dedupeKey: `channel.event:${row.id}`, maxAttempts: 5 });
    }
  }
}

registerJobHandler('channel.event', async (tx, job, deps) => {
  const { inboxId } = job.payload as { inboxId: string };
  const row = await tx.selectFrom('channel_inbox').selectAll().where('id', '=', inboxId).forUpdate().executeTakeFirst();
  if (!row || row.status === 'processed' || row.status === 'ignored') return { skipped: true };
  const conn = await tx.selectFrom('channel_connections').selectAll().where('id', '=', row.connection_id).executeTakeFirst();
  const c = conn ? liveConnector(conn.provider) : null;
  if (!conn || !c?.normaliseOrder) {
    await tx.updateTable('channel_inbox').set({ status: 'ignored', error: 'Channel is gone.', updated_at: new Date() } as never).where('id', '=', inboxId).execute();
    return { ignored: true };
  }
  const ctx = await contextFor(tx, deps.db, conn.tenant_id, conn.created_by, conn.company_id);
  if (!ctx) {
    await tx.updateTable('channel_inbox').set({ status: 'failed', error_code: 'NO_ACCESS', error: 'The user who connected this channel no longer has access.', updated_at: new Date() } as never).where('id', '=', inboxId).execute();
    return { failed: true };
  }
  const order: NormalisedOrder | null = c.normaliseOrder(row.topic, row.payload);
  if (!order) {
    await tx.updateTable('channel_inbox').set({ status: 'ignored', updated_at: new Date(), attempts: row.attempts + 1 } as never).where('id', '=', inboxId).execute();
    return { ignored: true };
  }
  const out = await processOrder(tx, ctx, asConnection(conn), order, row.source === 'poll' ? 'poll' : 'webhook');
  await tx.updateTable('channel_inbox').set({
    status: 'processed', sales_order_id: out.salesOrderId, error: out.message, error_code: out.errorCode, attempts: row.attempts + 1, updated_at: new Date(),
  } as never).where('id', '=', inboxId).execute();
  await tx.updateTable('channel_connections').set({ last_success_at: new Date() } as never).where('id', '=', conn.id).execute();
  return { action: out.action };
}, {
  // Out of attempts: keep the event visible as dead.
  onFailure: async (tx, job, error, final) => {
    if (!final) return;
    const { inboxId } = job.payload as { inboxId: string };
    await tx.updateTable('channel_inbox').set({ status: 'dead', error: error.message.slice(0, 300), updated_at: new Date() } as never).where('id', '=', inboxId).execute();
  },
});

/** Daily: drops finished webhook and poll events after 90 days. Failed and dead events stay for review. */
registerJobHandler('cleanup.channels', async (tx, job) => {
  if (!job.company_id) return { skipped: true };
  const old = new Date(Date.now() - 90 * 86_400_000);
  const r = await tx.deleteFrom('channel_inbox').where('company_id', '=', job.company_id)
    .where('status', 'in', ['processed', 'ignored']).where('source', '!=', 'csv').where('updated_at', '<', old).execute();
  return { deleted: Number(r[0]?.numDeletedRows ?? 0) };
});

/** Most pages one pull run follows; the saved cursor lets the next run continue. */
export const MAX_PULL_PAGES = 20;

registerJobHandler('channel.pull', async (tx, job) => {
  const { connectionId } = job.payload as { connectionId: string };
  const conn = await tx.selectFrom('channel_connections').selectAll().where('id', '=', connectionId).forUpdate().executeTakeFirst();
  const c = conn ? liveConnector(conn.provider) : null;
  if (!conn || !c?.pullOrders || conn.status !== 'connected') return { skipped: true };
  const cred = openCredentials(conn);
  if (!cred) return { skipped: true };
  let cursor: string | null = conn.cursors?.orders ?? null;
  let stored = 0;
  try {
    for (let page = 0; page < MAX_PULL_PAGES; page++) {
      const r = await c.pullOrders(callOf(cred), cursor);
      await storePulled(tx, conn, r.events);
      stored += r.events.length;
      const moved = r.cursor !== cursor;
      cursor = r.cursor;
      if (!r.events.length || !moved || r.more === false) break;
    }
  } catch (err) {
    if (!(err instanceof ChannelError)) throw err;
    if (err.kind === 'transient' || err.kind === 'rate_limited') throw err;
    await recordFailure(tx, conn.id, err);
    return { failed: err.code };
  }
  await tx.updateTable('channel_connections').set({
    cursors: JSON.stringify({ ...(conn.cursors ?? {}), ...(cursor ? { orders: cursor } : {}) }), last_check_at: new Date(), last_success_at: new Date(),
    last_error: null, last_error_at: null,
  } as never).where('id', '=', conn.id).execute();
  return { stored };
});

/** Quantity a listing may show: the least over its components of (on hand - reserved) / qty, less the buffer, never below 0. */
export async function listingAvailability(tx: Tx, conn: Conn) {
  const rows = await tx.selectFrom('channel_listings as l').innerJoin('channel_listing_components as k', 'k.listing_id', 'l.id')
    .innerJoin('items as i', 'i.id', 'k.item_id')
    .select(['l.id', 'l.channel_sku', 'l.external_id', 'l.pushed_qty', 'k.item_id', 'k.qty', 'i.track_stock'])
    .where('l.connection_id', '=', conn.id).where('l.is_active', '=', true).execute();
  const itemIds = [...new Set(rows.map((r) => r.item_id))];
  if (!itemIds.length) return [];
  const onHand = await tx.selectFrom('stock_moves').select('item_id').select((eb) => eb.fn.sum<number>('qty').as('q'))
    .where('company_id', '=', conn.company_id).where('location_id', '=', conn.location_id).where('item_id', 'in', itemIds).groupBy('item_id').execute();
  const held = await tx.selectFrom('stock_reservations').select('item_id').select((eb) => eb.fn.sum<number>('qty').as('q'))
    .where('company_id', '=', conn.company_id).where('location_id', '=', conn.location_id).where('status', '=', 'active')
    .where('item_id', 'in', itemIds).groupBy('item_id').execute();
  const free = (itemId: string) => Number(onHand.find((r) => r.item_id === itemId)?.q ?? 0) - Number(held.find((r) => r.item_id === itemId)?.q ?? 0);
  const byListing = new Map<string, typeof rows>();
  for (const r of rows) byListing.set(r.id, [...(byListing.get(r.id) ?? []), r]);
  const out: { id: string; sku: string; externalId: string | null; pushedQty: number | null; qty: number | null }[] = [];
  for (const [id, parts] of byListing) {
    const first = parts[0]!;
    // Items that do not track stock have no count to publish.
    const qty = parts.some((p) => !p.track_stock) ? null
      : Math.max(0, Math.floor(Math.min(...parts.map((p) => free(p.item_id) / Number(p.qty))) - Number(conn.stock_buffer) + 1e-9));
    out.push({ id, sku: first.channel_sku, externalId: first.external_id, pushedQty: first.pushed_qty === null ? null : Number(first.pushed_qty), qty });
  }
  return out;
}

registerJobHandler('channel.stock', async (tx, job) => {
  if (!job.company_id) return { skipped: true };
  const conns = await tx.selectFrom('channel_connections').selectAll().where('company_id', '=', job.company_id)
    .where('push_stock', '=', true).where('status', '=', 'connected').forUpdate().execute();
  let pushed = 0;
  for (const conn of conns) {
    const c = liveConnector(conn.provider);
    const cred = openCredentials(conn);
    if (!c?.pushStock || !cred) continue;
    const changed = (await listingAvailability(tx, conn)).filter((l) => l.qty !== null && l.qty !== l.pushedQty);
    for (let i = 0; i < changed.length; i += 50) {
      const batch = changed.slice(i, i + 50);
      const updates: StockUpdate[] = batch.map((l) => ({ sku: l.sku, externalId: l.externalId, qty: l.qty! }));
      try {
        const res = await c.pushStock(callOf(cred), updates);
        for (const l of batch) {
          const r = res.find((x) => x.sku === l.sku);
          await tx.updateTable('channel_listings').set(r?.ok
            ? { pushed_qty: l.qty!, pushed_at: new Date(), push_error: null }
            : { push_error: (r?.error ?? 'No answer for this listing.').slice(0, 300) } as never).where('id', '=', l.id).execute();
          if (r?.ok) pushed += 1;
        }
      } catch (err) {
        if (!(err instanceof ChannelError)) throw err;
        if (err.kind === 'transient' || err.kind === 'rate_limited') throw err;
        await recordFailure(tx, conn.id, err);
        break;
      }
    }
  }
  return { pushed };
});

documentRoute('PUT', '/channels/:id/credentials', { body: credBody });
documentRoute('PATCH', '/channels/:id/credentials', { body: credBody });
documentRoute('POST', '/channels/:id/sync', { body: syncBody });
