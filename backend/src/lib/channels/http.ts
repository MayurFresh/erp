import { createHmac, timingSafeEqual } from 'node:crypto';
import { ChannelError, type ChannelCall } from './types.ts';

/** Whether store addresses on private networks are accepted (tests and local development only). Set once from config. */
let allowPrivate = false;
export const setChannelHostPolicy = (v: boolean) => { allowPrivate = v; };
export const channelAllowPrivate = () => allowPrivate;

/** ISO 3166-2:IN subdivision code to GST state code. */
const STATE_BY_ISO: Record<string, string> = {
  JK: '01', HP: '02', PB: '03', CH: '04', UT: '05', UK: '05', HR: '06', DL: '07', RJ: '08', UP: '09', BR: '10', SK: '11', AR: '12',
  NL: '13', MN: '14', MZ: '15', TR: '16', ML: '17', AS: '18', WB: '19', JH: '20', OR: '21', OD: '21', CG: '22', CT: '22', MP: '23',
  GJ: '24', DH: '26', DD: '26', DN: '26', MH: '27', KA: '29', GA: '30', LD: '31', KL: '32', TN: '33', PY: '34', AN: '35', TS: '36',
  TG: '36', AP: '37', LA: '38',
};
export const gstStateFromIso = (code: string | null | undefined): string | null => (code ? STATE_BY_ISO[code.trim().toUpperCase()] ?? null : null);

/** Today's date in IST from an ISO timestamp. */
export function istDate(iso: string | null | undefined): string {
  const t = iso ? Date.parse(iso) : NaN;
  const d = new Date((Number.isNaN(t) ? Date.now() : t) + 5.5 * 3600_000);
  return d.toISOString().slice(0, 10);
}

export function hmacBase64(secret: string, raw: Buffer): string {
  return createHmac('sha256', secret).update(raw).digest('base64');
}

export function safeEqual(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

/**
 * One JSON request with a timeout. Maps the status to a ChannelError kind. Error messages never include the request
 * headers or the response body, so credentials and customer data stay out of logs.
 */
export async function channelJson(
  c: ChannelCall, method: string, url: string, headers: Record<string, string>, body?: unknown,
): Promise<{ json: any; headers: Headers }> {
  let res: Response;
  try {
    res = await c.fetch(url, {
      method, redirect: 'error', signal: AbortSignal.timeout(c.timeoutMs),
      headers: { accept: 'application/json', ...(body === undefined ? {} : { 'content-type': 'application/json' }), ...headers },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
  } catch (err) {
    const timedOut = err instanceof Error && (err.name === 'TimeoutError' || err.name === 'AbortError');
    throw new ChannelError(timedOut ? 'TIMEOUT' : 'NETWORK', timedOut ? 'The store did not answer in time.' : 'Could not reach the store.', 'transient');
  }
  if (res.status === 401 || res.status === 403) throw new ChannelError('AUTH', 'The store refused the credentials.', 'auth');
  if (res.status === 429) {
    const secs = Number(res.headers.get('retry-after'));
    throw new ChannelError('RATE_LIMITED', 'The store is limiting requests.', 'rate_limited', Number.isFinite(secs) && secs > 0 ? secs * 1000 : 2000);
  }
  if (res.status >= 500) throw new ChannelError('UPSTREAM', `The store had an error (${res.status}).`, 'transient');
  if (!res.ok) throw new ChannelError('REJECTED', `The store rejected the request (${res.status}).`, 'permanent');
  const text = await res.text();
  let json: unknown = null;
  if (text) {
    try { json = JSON.parse(text); } catch { throw new ChannelError('BAD_RESPONSE', 'The store sent an answer that is not JSON.', 'permanent'); }
  }
  return { json, headers: res.headers };
}
