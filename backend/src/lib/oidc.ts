import { createHash } from 'node:crypto';
import { lookup } from 'node:dns/promises';
import { BlockList, isIP } from 'node:net';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { AppError } from './errors.ts';
import { randomToken } from './crypto.ts';

export interface Discovery { issuer: string; authorization_endpoint: string; token_endpoint: string; jwks_uri: string }

/** https only, except for loopback hosts (local identity providers and tests). */
export function issuerAllowed(issuer: string): boolean {
  try {
    const u = new URL(issuer);
    if (u.protocol === 'https:') return true;
    return u.protocol === 'http:' && (u.hostname === '127.0.0.1' || u.hostname === 'localhost');
  } catch { return false; }
}

const fail = (msg: string) => new AppError(400, 'SSO_DISCOVERY_FAILED', msg);

const PRIVATE = new BlockList();
for (const [net, bits] of [['0.0.0.0', 8], ['10.0.0.0', 8], ['100.64.0.0', 10], ['127.0.0.0', 8], ['169.254.0.0', 16],
  ['172.16.0.0', 12], ['192.0.0.0', 24], ['192.168.0.0', 16], ['198.18.0.0', 15], ['224.0.0.0', 4], ['240.0.0.0', 4]] as const) {
  PRIVATE.addSubnet(net, bits, 'ipv4');
}
for (const [net, bits] of [['::', 128], ['::1', 128], ['fc00::', 7], ['fe80::', 10], ['ff00::', 8]] as const) PRIVATE.addSubnet(net, bits, 'ipv6');

/** Loopback, private, link-local, carrier NAT, multicast and reserved ranges, including IPv4 mapped into IPv6. */
export function isPrivateAddress(ip: string): boolean {
  const mapped = /^::ffff:(\d+\.\d+\.\d+\.\d+)$/i.exec(ip)?.[1];
  if (mapped) return PRIVATE.check(mapped, 'ipv4');
  const v = isIP(ip);
  return v === 0 || PRIVATE.check(ip, v === 4 ? 'ipv4' : 'ipv6');
}

/** Stops a tenant admin pointing the server at internal hosts (SSRF). The check runs before each fetch. */
async function assertReachable(url: string, allowPrivate: boolean): Promise<void> {
  if (!issuerAllowed(url)) throw fail('Provider URLs must use https.');
  if (allowPrivate) return;
  const host = new URL(url).hostname.replace(/^\[|\]$/g, '');
  let addrs: { address: string }[];
  try {
    addrs = await lookup(host, { all: true, verbatim: true });
  } catch {
    throw fail(`Could not resolve ${host}.`);
  }
  if (!addrs.length || addrs.some((a) => isPrivateAddress(a.address))) throw fail(`${host} points to a private network address.`);
}

export async function discover(issuer: string, opts: { allowPrivate: boolean }): Promise<Discovery> {
  if (!issuerAllowed(issuer)) throw fail('The issuer must be an https URL.');
  await assertReachable(issuer, opts.allowPrivate);
  let doc: Partial<Discovery>;
  try {
    const res = await fetch(`${issuer.replace(/\/+$/, '')}/.well-known/openid-configuration`, { signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    doc = (await res.json()) as Partial<Discovery>;
  } catch (err) {
    throw fail(`Could not read the provider's discovery document (${(err as Error).message}).`);
  }
  if (!doc.authorization_endpoint || !doc.token_endpoint || !doc.jwks_uri || !doc.issuer) throw fail('The discovery document is incomplete.');
  if (doc.issuer.replace(/\/+$/, '') !== issuer.replace(/\/+$/, '')) throw fail('The discovery document names a different issuer.');
  // The server also calls these two, so they get the same check.
  await assertReachable(doc.token_endpoint, opts.allowPrivate);
  await assertReachable(doc.jwks_uri, opts.allowPrivate);
  return doc as Discovery;
}

export const newPkce = () => {
  const verifier = randomToken(32);
  return { verifier, challenge: createHash('sha256').update(verifier).digest('base64url') };
};

const jwksCache = new Map<string, ReturnType<typeof createRemoteJWKSet>>();

export async function exchangeCode(d: Discovery, p: {
  code: string; redirectUri: string; clientId: string; clientSecret: string | null; verifier: string;
}): Promise<string> {
  const body = new URLSearchParams({
    grant_type: 'authorization_code', code: p.code, redirect_uri: p.redirectUri, client_id: p.clientId, code_verifier: p.verifier,
  });
  if (p.clientSecret) body.set('client_secret', p.clientSecret);
  const res = await fetch(d.token_endpoint, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' }, body, signal: AbortSignal.timeout(10_000),
  });
  const json = (await res.json().catch(() => ({}))) as { id_token?: string };
  if (!res.ok || !json.id_token) throw new Error('token exchange failed');
  return json.id_token;
}

export interface IdClaims { email?: string; email_verified?: boolean | string; name?: string; nonce?: string }

export async function verifyIdToken(d: Discovery, idToken: string, clientId: string, nonce: string): Promise<IdClaims> {
  let jwks = jwksCache.get(d.jwks_uri);
  if (!jwks) { jwks = createRemoteJWKSet(new URL(d.jwks_uri)); jwksCache.set(d.jwks_uri, jwks); }
  const { payload } = await jwtVerify(idToken, jwks, { issuer: d.issuer, audience: clientId });
  if (payload.nonce !== nonce) throw new Error('nonce mismatch');
  return payload as IdClaims;
}
