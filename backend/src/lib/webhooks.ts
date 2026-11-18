import { createHmac, randomBytes } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { sql } from 'kysely';
import { webhookAllowPrivate } from '../config.ts';
import type { Tx } from '../db/database.ts';
import { unseal } from './crypto.ts';
import { badRequest } from './errors.ts';
import { enqueue, registerJobHandler } from './jobs.ts';
import { isPrivateAddress } from './oidc.ts';

/** Events a company can subscribe to. `webhook.test` is sent by the Send test button. */
export const WEBHOOK_EVENTS = ['invoice.created', 'payment.received', 'order.created', 'webhook.test'] as const;
export type WebhookEvent = (typeof WEBHOOK_EVENTS)[number];

/** Attempts per delivery. The job runner waits 30 s, 60 s, 120 s, 240 s between them. */
export const WEBHOOK_MAX_ATTEMPTS = 5;

export const newSecret = () => `whsec_${randomBytes(24).toString('base64url')}`;

/** `t=<unix seconds>,v1=<hex hmac-sha256 of "<t>.<body>">`. Receivers should reject old timestamps. */
export function signPayload(secret: string, body: string, at = Math.floor(Date.now() / 1000)): string {
  return `t=${at},v1=${createHmac('sha256', secret).update(`${at}.${body}`).digest('hex')}`;
}

/** Throws a 400 for URLs the server must not call: not https, with credentials, or on a private network. */
export async function assertWebhookUrl(raw: string, allowPrivate: boolean): Promise<void> {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    throw badRequest('Enter a full URL, for example https://example.com/hooks.', { url: 'Not a URL' });
  }
  if (u.username || u.password) throw badRequest('Put credentials in the secret, not in the URL.', { url: 'No credentials' });
  if (u.protocol !== 'https:' && !(allowPrivate && u.protocol === 'http:')) throw badRequest('Webhook URLs must use https.', { url: 'Use https' });
  if (allowPrivate) return;
  const host = u.hostname.replace(/^\[|\]$/g, '');
  let addrs: { address: string }[];
  try {
    addrs = await lookup(host, { all: true, verbatim: true });
  } catch {
    throw badRequest(`Could not resolve ${host}.`, { url: 'Host not found' });
  }
  if (!addrs.length || addrs.some((a) => isPrivateAddress(a.address))) {
    throw badRequest('That address is on a private network, so it cannot be called.', { url: 'Private address' });
  }
}

/** Queues a delivery for every active endpoint of the company that listens for the event. Same transaction as the change. */
export async function emitEvent(
  tx: Tx, who: { tenantId: string; companyId: string; userId?: string | null }, event: WebhookEvent, data: Record<string, unknown>,
): Promise<number> {
  const endpoints = await tx.selectFrom('webhook_endpoints').select('id').where('company_id', '=', who.companyId)
    .where('is_active', '=', true).where(sql<boolean>`${event} = any(events)`).execute();
  for (const e of endpoints) await queueDelivery(tx, who, e.id, event, data);
  return endpoints.length;
}

export async function queueDelivery(
  tx: Tx, who: { tenantId: string; companyId: string; userId?: string | null }, endpointId: string, event: WebhookEvent, data: Record<string, unknown>,
): Promise<string> {
  const row = await tx.insertInto('webhook_deliveries').values({
    tenant_id: who.tenantId, endpoint_id: endpointId, event, payload: JSON.stringify({ event, createdAt: new Date().toISOString(), data }),
    status: 'pending',
  }).returning('id').executeTakeFirstOrThrow();
  await enqueue(tx, { tenantId: who.tenantId, companyId: who.companyId, userId: who.userId ?? null }, 'webhook.deliver',
    { deliveryId: row.id }, { maxAttempts: WEBHOOK_MAX_ATTEMPTS, dedupeKey: `webhook:${row.id}` });
  return row.id;
}

registerJobHandler('webhook.deliver', async (tx, job, deps) => {
  const { deliveryId } = job.payload as { deliveryId: string };
  const d = await tx.selectFrom('webhook_deliveries').selectAll().where('id', '=', deliveryId).forUpdate().executeTakeFirst();
  if (!d || d.status === 'delivered') return { skipped: true };
  const ep = await tx.selectFrom('webhook_endpoints').select(['url', 'secret_sealed', 'is_active']).where('id', '=', d.endpoint_id).executeTakeFirst();
  if (!ep || !ep.is_active) {
    await tx.updateTable('webhook_deliveries').set({ status: 'failed', error: 'Endpoint removed or turned off' }).where('id', '=', d.id).execute();
    return { skipped: true };
  }
  const allowPrivate = webhookAllowPrivate(deps.config);
  await assertWebhookUrl(ep.url, allowPrivate);
  const body = typeof d.payload === 'string' ? d.payload : JSON.stringify(d.payload);
  const res = await fetch(ep.url, {
    method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(10_000),
    headers: {
      'content-type': 'application/json', 'user-agent': 'OneMatrix-Webhooks/1',
      'x-onematrix-event': d.event, 'x-onematrix-delivery': d.id, 'x-onematrix-signature': signPayload(unseal(ep.secret_sealed), body),
    },
    body,
  });
  await res.arrayBuffer().catch(() => null);
  if (res.status < 200 || res.status >= 300) throw new Error(`Endpoint answered ${res.status}`);
  await tx.updateTable('webhook_deliveries').set({
    status: 'delivered', attempts: job.attempts, response_status: res.status, error: null, delivered_at: new Date(), next_attempt_at: null,
  }).where('id', '=', d.id).execute();
  return { status: res.status };
}, {
  onFailure: async (tx, job, error, final) => {
    const { deliveryId } = job.payload as { deliveryId: string };
    const m = /answered (\d+)/.exec(error.message);
    await tx.updateTable('webhook_deliveries').set({
      status: final ? 'failed' : 'retrying', attempts: job.attempts, error: error.message.slice(0, 500),
      response_status: m ? Number(m[1]) : null,
      next_attempt_at: final ? null : new Date(Date.now() + 30_000 * 2 ** Math.max(0, job.attempts - 1)),
    }).where('id', '=', deliveryId).execute();
  },
});
