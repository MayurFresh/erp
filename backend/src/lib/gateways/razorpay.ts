import { createHmac, timingSafeEqual } from 'node:crypto';

export interface GatewayCreds { keyId: string; keySecret: string; webhookSecret: string }

type FetchFn = typeof fetch;
let override: FetchFn | null = null;
/** Tests replace the network call; call with no argument to restore it. */
export function setGatewayFetch(f?: FetchFn): void {
  override = f ?? null;
}

export class GatewayError extends Error {
  status: number;
  constructor(message: string, status: number) { super(message); this.status = status; }
}

const BASE = 'https://api.razorpay.com/v1';
const auth = (c: GatewayCreds) => `Basic ${Buffer.from(`${c.keyId}:${c.keySecret}`).toString('base64')}`;

async function call(c: GatewayCreds, method: string, path: string, body?: object) {
  const res = await (override ?? fetch)(`${BASE}${path}`, {
    method, headers: { Authorization: auth(c), 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(15_000),
  });
  const json = await res.json().catch(() => ({})) as any;
  if (!res.ok) throw new GatewayError(String(json?.error?.description ?? `Razorpay answered ${res.status}`).slice(0, 300), res.status);
  return json;
}

export const isTestMode = (c: { keyId: string }) => c.keyId.startsWith('rzp_test_');

export interface LinkInput {
  amountPaise: number; referenceId: string; description: string; expireBy: number;
  customer: { name?: string | null; contact?: string | null; email?: string | null };
  /** Razorpay itself sends the SMS or email when true; we send our own, so this stays false. */
  notify?: { sms: boolean; email: boolean };
}

/** Razorpay Payment Links: POST /v1/payment_links, amounts in paise, basic auth with the key pair. */
export async function createPaymentLink(c: GatewayCreds, i: LinkInput): Promise<{ id: string; shortUrl: string; status: string }> {
  const customer: Record<string, string> = {};
  if (i.customer.name) customer.name = i.customer.name.slice(0, 100);
  const digits = i.customer.contact?.replace(/\D/g, '') ?? '';
  if (digits) customer.contact = digits.length === 10 ? `+91${digits}` : `+${digits}`;
  if (i.customer.email) customer.email = i.customer.email;
  const j = await call(c, 'POST', '/payment_links', {
    amount: i.amountPaise, currency: 'INR', accept_partial: false, reference_id: i.referenceId, description: i.description.slice(0, 2048),
    customer, notify: i.notify ?? { sms: false, email: false }, reminder_enable: false, expire_by: i.expireBy,
  });
  return { id: j.id, shortUrl: j.short_url, status: j.status };
}

export async function cancelPaymentLink(c: GatewayCreds, linkId: string): Promise<void> {
  await call(c, 'POST', `/payment_links/${encodeURIComponent(linkId)}/cancel`);
}

/** X-Razorpay-Signature is the hex HMAC SHA256 of the raw request body, keyed with the webhook secret. */
export function verifySignature(raw: Buffer, signature: string | undefined, secret: string): boolean {
  if (!signature || !secret) return false;
  const want = createHmac('sha256', secret).update(raw).digest('hex');
  const a = Buffer.from(want);
  const b = Buffer.from(signature.trim());
  return a.length === b.length && timingSafeEqual(a, b);
}

export interface GatewayEvent {
  event: string; linkId: string | null; referenceId: string | null; paymentId: string | null;
  amount: number | null; fee: number | null;
}

/** Reads payment_link.* events. Amounts are rupees; fee is the fee plus tax Razorpay reports, when it reports one. */
export function parseEvent(payload: any): GatewayEvent {
  const link = payload?.payload?.payment_link?.entity;
  const pay = payload?.payload?.payment?.entity;
  const paise = (v: unknown) => (typeof v === 'number' ? Math.round(v) / 100 : null);
  return {
    event: String(payload?.event ?? ''), linkId: link?.id ?? null, referenceId: link?.reference_id ?? null,
    paymentId: pay?.id ?? null, amount: paise(pay?.amount ?? link?.amount_paid), fee: paise(pay?.fee),
  };
}
