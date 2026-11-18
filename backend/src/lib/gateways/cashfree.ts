import { createHmac, timingSafeEqual } from 'node:crypto';
import { GatewayError, type GatewayCreds, type GatewayEvent, type LinkInput } from './razorpay.ts';

/*
 * Cashfree Payment Links (https://www.cashfree.com/docs/api-reference/payments/latest/payment-links/create).
 * Not yet run against a real Cashfree account; the shapes follow the published docs.
 * keyId is the app id (x-client-id), keySecret the secret key (x-client-secret). Webhooks are signed with the
 * same secret key, so webhookSecret is not used.
 */

type FetchFn = typeof fetch;
let override: FetchFn | null = null;
/** Tests replace the network call; call with no argument to restore it. */
export function setCashfreeFetch(f?: FetchFn): void {
  override = f ?? null;
}

const API_VERSION = '2025-01-01';
/** Cashfree test app ids start with TEST; those talk to the sandbox host. */
export const isTestMode = (c: { keyId: string }) => c.keyId.toUpperCase().startsWith('TEST');
const base = (c: { keyId: string }) => (isTestMode(c) ? 'https://sandbox.cashfree.com/pg' : 'https://api.cashfree.com/pg');

async function call(c: GatewayCreds, method: string, path: string, body?: object) {
  const res = await (override ?? fetch)(`${base(c)}${path}`, {
    method,
    headers: { 'x-client-id': c.keyId, 'x-client-secret': c.keySecret, 'x-api-version': API_VERSION, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(15_000),
  });
  const json = await res.json().catch(() => ({})) as any;
  if (!res.ok) throw new GatewayError(String(json?.message ?? `Cashfree answered ${res.status}`).slice(0, 300), res.status);
  return json;
}

/** POST /pg/links. Amounts are rupees. The link id is our reference. Cashfree needs a customer phone. */
export async function createPaymentLink(c: GatewayCreds, i: LinkInput): Promise<{ id: string; shortUrl: string; status: string }> {
  const digits = i.customer.contact?.replace(/\D/g, '') ?? '';
  const phone = digits.length > 10 ? digits.slice(-10) : digits;
  if (phone.length !== 10) throw new GatewayError('Cashfree needs the customer\'s 10 digit phone number.', 400);
  const customer: Record<string, string> = { customer_phone: phone };
  if (i.customer.name) customer.customer_name = i.customer.name.slice(0, 100);
  if (i.customer.email) customer.customer_email = i.customer.email;
  const j = await call(c, 'POST', '/links', {
    link_id: i.referenceId, link_amount: i.amountPaise / 100, link_currency: 'INR', link_purpose: i.description.slice(0, 500),
    customer_details: customer, link_partial_payments: false, link_expiry_time: new Date(i.expireBy * 1000).toISOString(),
    link_notify: { send_sms: false, send_email: false },
  });
  return { id: i.referenceId, shortUrl: j.link_url, status: String(j.link_status ?? 'ACTIVE') };
}

export async function cancelPaymentLink(c: GatewayCreds, linkId: string): Promise<void> {
  await call(c, 'POST', `/links/${encodeURIComponent(linkId)}/cancel`);
}

/** Link status by our link id (GET /pg/links/{link_id}). */
export async function fetchPaymentLink(c: GatewayCreds, linkId: string): Promise<{ status: string; amountPaid: number }> {
  const j = await call(c, 'GET', `/links/${encodeURIComponent(linkId)}`);
  return { status: String(j.link_status ?? ''), amountPaid: Number(j.link_amount_paid ?? 0) };
}

/**
 * x-webhook-signature is base64(HMAC-SHA256(x-webhook-timestamp + raw body, secret key)). The docs show the
 * timestamp and body joined with no separator in code samples; the reference text shows a dot. Both are accepted.
 */
export function verifySignature(raw: Buffer, signature: string | undefined, timestamp: string | undefined, secret: string): boolean {
  if (!signature || !timestamp || !secret) return false;
  const got = Buffer.from(signature.trim());
  for (const sep of ['', '.']) {
    const want = Buffer.from(createHmac('sha256', secret).update(timestamp + sep).update(raw).digest('base64'));
    if (want.length === got.length && timingSafeEqual(want, got)) return true;
  }
  return false;
}

/** Reads PAYMENT_LINK_EVENT. A paid link carries order.transaction_id, which is the provider payment id. */
export function parseEvent(payload: any): GatewayEvent {
  const d = payload?.data ?? {};
  const status = String(d.link_status ?? '');
  const event = status === 'PAID' ? 'payment_link.paid' : status === 'EXPIRED' ? 'payment_link.expired'
    : status === 'CANCELLED' ? 'payment_link.cancelled' : `payment_link.${status.toLowerCase() || 'unknown'}`;
  const tx = d.order?.transaction_id;
  const amount = Number(d.order?.order_amount ?? d.link_amount_paid);
  return {
    event: payload?.type === 'PAYMENT_LINK_EVENT' ? event : '', linkId: d.link_id ?? null, referenceId: d.link_id ?? null,
    paymentId: tx != null ? `cf_${tx}` : null, amount: Number.isFinite(amount) ? amount : null, fee: null,
  };
}
