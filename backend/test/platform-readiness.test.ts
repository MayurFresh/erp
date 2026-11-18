import { createServer, type Server } from 'node:http';
import type { AddressInfo } from 'node:net';
import fc from 'fast-check';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'kysely';
import { buildApp } from '../src/app.ts';
import { loadConfig } from '../src/config.ts';
import { withTenant } from '../src/db/database.ts';
import { runJobsOnce } from '../src/lib/jobs.ts';
import { signPayload } from '../src/lib/webhooks.ts';
import { buildOpenApi } from '../src/lib/openapi.ts';
import { MODULE_ROUTES, moduleForRoute } from '../src/lib/entitlements.ts';
import { MODULE_KEYS } from '../src/lib/business-types.ts';
import { TEST_UPLOAD_DIR, client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
const baseEnv = () => ({ ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, LOG_LEVEL: 'silent', UPLOAD_DIR: TEST_UPLOAD_DIR });
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const tenantOf = (token: string) => JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString()).tid as string;

async function signup(extra: Record<string, unknown> = {}) {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Platform Traders', name: 'Pia Shah', email: uniqueEmail('plat'), password: 'Secret@123', stateCode: '24', ...extra,
  });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  return { token, tenantId: tenantOf(token), companyId, api: client(env.app, token, companyId) };
}
type S = Awaited<ReturnType<typeof signup>>;

describe('stock_moves is append-only', () => {
  it('blocks update and delete, allows insert', async () => {
    const s = await signup();
    const loc = (await s.api('GET', '/locations')).body.data[0];
    const item = await s.api('POST', '/items', { name: 'Bolt', unit: 'nos', gstRate: 18, salePrice: 10, purchasePrice: 5 });
    expect(item.status).toBe(201);
    const adj = await s.api('POST', '/stock/adjustments', { locationId: loc.id, itemId: item.body.id, qty: 5, isOpening: true });
    expect(adj.status).toBe(201);
    await expect(withTenant(env.db, s.tenantId, (tx) => sql`update stock_moves set qty = qty + 1`.execute(tx))).rejects.toThrow(/append-only/);
    await expect(withTenant(env.db, s.tenantId, (tx) => sql`delete from stock_moves`.execute(tx))).rejects.toThrow(/append-only/);
    const n = await withTenant(env.db, s.tenantId, (tx) => sql<{ n: number }>`select count(*)::int as n from stock_moves`.execute(tx));
    expect(n.rows[0]!.n).toBeGreaterThan(0);
  });
});

describe('module entitlements', () => {
  it('maps only real module keys', () => {
    for (const m of Object.values(MODULE_ROUTES)) expect(MODULE_KEYS).toContain(m);
    expect(moduleForRoute('/api/v1/clinic/patients/:id')).toBe('clinic');
    expect(moduleForRoute('/api/v1/invoices')).toBeNull();
    expect(moduleForRoute('/api/v1/company/business-profile')).toBeNull();
  });

  it('returns MODULE_DISABLED until the company enables the module', async () => {
    const s = await signup();
    const company = (await s.api('GET', '/company')).body;
    const enabled = (company.enabledModules as string[]).filter((m) => m !== 'clinic');
    expect((await s.api('POST', '/company/business-profile', { enabledModules: enabled })).status).toBe(200);
    const blocked = await s.api('GET', '/clinic/patients');
    expect(blocked.status).toBe(403);
    expect(blocked.body.error.code).toBe('MODULE_DISABLED');
    // Always-open routes still answer.
    expect((await s.api('GET', '/me')).status).toBe(200);
    expect((await s.api('GET', '/company')).status).toBe(200);
    expect((await s.api('GET', '/items')).status).toBe(200);

    const on = await s.api('POST', '/company/business-profile', { enabledModules: [...enabled, 'clinic'] });
    expect(on.status).toBe(200);
    expect((await s.api('GET', '/clinic/patients')).status).toBe(200);
    const off = await s.api('POST', '/company/business-profile', { enabledModules: enabled });
    expect(off.status).toBe(200);
    expect((await s.api('GET', '/clinic/patients')).body.error.code).toBe('MODULE_DISABLED');
  });

  it('uses the business type defaults when the module list is null', async () => {
    const s = await signup({ businessType: 'clinic' });
    await withTenant(env.db, s.tenantId, (tx) => sql`update companies set enabled_modules = null`.execute(tx));
    expect((await s.api('GET', '/clinic/patients')).status).toBe(200);
    expect((await s.api('GET', '/restaurant/menu')).body.error.code).toBe('MODULE_DISABLED');
  });
});

describe('OpenAPI', () => {
  it('serves an OpenAPI 3.1 document without sign-in', async () => {
    const res = await env.app.inject({ method: 'GET', url: '/api/v1/openapi.json' });
    expect(res.statusCode).toBe(200);
    const doc = JSON.parse(res.body);
    expect(doc.openapi).toBe('3.1.0');
    expect(Object.keys(doc.paths).length).toBeGreaterThan(300);
    expect(doc.paths['/invoices'].post).toBeTruthy();
    expect(doc.paths['/items/{id}']).toBeTruthy();
    expect(doc.paths['/clinic/patients'].get['x-module']).toBe('clinic');
    const keyBody = doc.paths['/api-keys'].post.requestBody.content['application/json'].schema;
    expect(keyBody.properties.name.type).toBe('string');
    expect(keyBody.required).toContain('roleId');
    expect(doc.paths['/auth/login'].post.security).toEqual([]);
  });

  it('builds from a plain route list', () => {
    const doc = buildOpenApi([{ method: 'GET', url: '/api/v1/things/:id' }]) as { paths: Record<string, Record<string, { parameters: { name: string }[] }>> };
    expect(doc.paths['/things/{id}']!.get!.parameters[0]!.name).toBe('id');
  });
});

describe('API keys', () => {
  async function makeKey(s: S, roleName: string, extra: Record<string, unknown> = {}) {
    const roles = (await s.api('GET', '/roles')).body.data as { id: string; name: string }[];
    const role = roles.find((r) => r.name === roleName)!;
    const res = await s.api('POST', '/api-keys', { name: 'Integration', roleId: role.id, ...extra });
    return { res, role };
  }

  it('is shown once, stored hashed, and signs requests in with the role permissions', async () => {
    const s = await signup();
    const { res } = await makeKey(s, 'Sales Executive');
    expect(res.status).toBe(201);
    const key = res.body.key as string;
    expect(key.startsWith('pk_')).toBe(true);
    const list = (await s.api('GET', '/api-keys')).body.data;
    expect(list).toHaveLength(1);
    expect(JSON.stringify(list)).not.toContain(key);
    const stored = await withTenant(env.db, s.tenantId, (tx) => sql<{ key_hash: string }>`select key_hash from api_keys`.execute(tx));
    expect(stored.rows[0]!.key_hash).not.toContain(key);

    const viaKey = client(env.app, key);
    expect((await viaKey('GET', '/items')).status).toBe(200);
    expect((await viaKey('GET', '/me')).status).toBe(200);
    expect((await s.api('GET', '/api-keys')).body.data[0].lastUsedAt).not.toBeNull();
    // Scope: Sales Executive cannot create items or manage keys.
    expect((await viaKey('POST', '/items', { name: 'X', unit: 'nos', gstRate: 18, salePrice: 1, purchasePrice: 1 })).status).toBe(403);
    expect((await viaKey('GET', '/api-keys')).status).toBe(403);
    expect((await viaKey('GET', '/items', undefined, { 'x-company-id': '11111111-1111-4111-8111-111111111111' })).status).toBe(401);
  });

  it('can be revoked, and a wrong key is refused', async () => {
    const s = await signup();
    const { res } = await makeKey(s, 'Sales Executive');
    const viaKey = client(env.app, res.body.key);
    expect((await viaKey('GET', '/items')).status).toBe(200);
    const revoked = await s.api('POST', `/api-keys/${res.body.id}/revoke`);
    expect(revoked.status).toBe(200);
    expect(revoked.body.revokedAt).not.toBeNull();
    expect((await viaKey('GET', '/items')).status).toBe(401);
    expect((await client(env.app, 'pk_notarealkey')('GET', '/items')).status).toBe(401);
    expect((await s.api('POST', `/api-keys/${res.body.id}/revoke`)).status).toBe(404);
  });

  it('refuses roles that manage users or integrations, an expired key, and keys from another company', async () => {
    const s = await signup();
    const { res } = await makeKey(s, 'Company Admin');
    expect(res.status).toBe(400);
    const past = await makeKey(s, 'Sales Executive', { expiresAt: new Date(Date.now() + 60_000).toISOString() });
    expect(past.res.status).toBe(201);
    await withTenant(env.db, s.tenantId, (tx) => sql`update api_keys set expires_at = now() - interval '1 minute'`.execute(tx));
    expect((await client(env.app, past.res.body.key)('GET', '/items')).status).toBe(401);
    const other = await signup();
    const mine = await makeKey(s, 'Sales Executive');
    // The key is not a token for the other company's data.
    const items = (await client(env.app, mine.res.body.key)('GET', '/items')).body.data;
    expect(items).toHaveLength(0);
    expect((await other.api('GET', '/api-keys')).body.data).toHaveLength(0);
  });
});

describe('webhooks', () => {
  let server: Server;
  let url: string;
  const received: { headers: Record<string, string | string[] | undefined>; body: string }[] = [];
  let respond = 200;
  beforeAll(async () => {
    server = createServer((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', () => {
        received.push({ headers: req.headers, body });
        res.statusCode = respond;
        res.end('ok');
      });
    });
    await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
    url = `http://127.0.0.1:${(server.address() as AddressInfo).port}/hook`;
  });
  afterAll(() => { server.close(); });

  const deps = () => ({ db: env.db, config: loadConfig({ ...baseEnv(), WEBHOOK_ALLOW_PRIVATE: 'true' }) });

  it('signs payloads with HMAC-SHA256 over timestamp and body', () => {
    const sig = signPayload('whsec_x', '{"a":1}', 1700000000);
    expect(sig).toMatch(/^t=1700000000,v1=[0-9a-f]{64}$/);
    expect(sig).toBe(signPayload('whsec_x', '{"a":1}', 1700000000));
    expect(sig).not.toBe(signPayload('whsec_y', '{"a":1}', 1700000000));
  });

  it('blocks private, loopback and plain http targets in production mode', async () => {
    const strict = await buildApp({ config: loadConfig({ ...baseEnv(), WEBHOOK_ALLOW_PRIVATE: 'false' }), db: env.db, logger: false, authRateLimit: false });
    try {
      const s = await signup();
      const api = client(strict, s.token, s.companyId);
      for (const bad of ['https://127.0.0.1/hook', 'https://10.0.0.5/hook', 'https://169.254.169.254/latest', 'https://[::1]/hook', 'http://93.184.216.34/hook', 'https://user:pw@93.184.216.34/h']) {
        const res = await api('POST', '/webhooks', { url: bad, events: ['invoice.created'] });
        expect(res.status, bad).toBe(400);
      }
      const ok = await api('POST', '/webhooks', { url: 'https://93.184.216.34/hook', events: ['invoice.created'] });
      expect(ok.status).toBe(201);
    } finally {
      await strict.close();
    }
  });

  it('delivers a signed event, then logs retries with backoff until it succeeds', async () => {
    const s = await signup();
    const created = await s.api('POST', '/webhooks', { url, events: ['invoice.created', 'payment.received'], description: 'ERP sync' });
    expect(created.status).toBe(201);
    const secret = created.body.secret as string;
    expect(secret.startsWith('whsec_')).toBe(true);
    expect((await s.api('GET', '/webhooks')).body.data[0].secret).toBeUndefined();

    // A real event: an invoice creates a delivery.
    const loc = (await s.api('GET', '/locations')).body.data[0];
    const item = (await s.api('POST', '/items', { name: 'Pipe', unit: 'nos', gstRate: 18, salePrice: 100, purchasePrice: 50, trackStock: false })).body;
    const cust = (await s.api('POST', '/parties', { type: 'customer', name: 'Buyer', stateCode: '24' })).body;
    received.length = 0;
    respond = 500;
    const inv = await s.api('POST', '/invoices', { locationId: loc.id, partyId: cust.id, lines: [{ itemId: item.id, qty: 1 }] });
    expect(inv.status).toBe(201);

    expect(await runJobsOnce(deps())).toBeGreaterThan(0);
    let log = (await s.api('GET', `/webhooks/${created.body.id}/deliveries`)).body.data;
    expect(log).toHaveLength(1);
    expect(log[0]).toMatchObject({ event: 'invoice.created', status: 'retrying', attempts: 1, responseStatus: 500 });
    expect(new Date(log[0].nextAttemptAt).getTime()).toBeGreaterThan(Date.now());

    // The backoff has passed; the endpoint is healthy again.
    respond = 200;
    await withTenant(env.db, s.tenantId, (tx) => sql`update jobs set run_after = now() where kind = 'webhook.deliver' and status = 'queued'`.execute(tx));
    expect(await runJobsOnce(deps())).toBeGreaterThan(0);
    log = (await s.api('GET', `/webhooks/${created.body.id}/deliveries`)).body.data;
    expect(log[0]).toMatchObject({ status: 'delivered', attempts: 2, responseStatus: 200 });

    const last = received.at(-1)!;
    expect(last.headers['x-onematrix-event']).toBe('invoice.created');
    const sig = String(last.headers['x-onematrix-signature']);
    const t = Number(/t=(\d+)/.exec(sig)![1]);
    expect(sig).toBe(signPayload(secret, last.body, t));
    const payload = JSON.parse(last.body);
    expect(payload).toMatchObject({ event: 'invoice.created', data: { id: inv.body.id, number: inv.body.number } });
  });

  it('gives up after the last attempt and can resend', async () => {
    const s = await signup();
    const hook = (await s.api('POST', '/webhooks', { url, events: ['order.created'] })).body;
    respond = 503;
    const test = await s.api('POST', `/webhooks/${hook.id}/test`);
    expect(test.status).toBe(202);
    for (let i = 0; i < 5; i++) {
      await withTenant(env.db, s.tenantId, (tx) => sql`update jobs set run_after = now() where kind = 'webhook.deliver' and status = 'queued'`.execute(tx));
      await runJobsOnce(deps());
    }
    const log = (await s.api('GET', `/webhooks/${hook.id}/deliveries`)).body.data;
    expect(log[0]).toMatchObject({ event: 'webhook.test', status: 'failed', attempts: 5 });
    respond = 200;
    const again = await s.api('POST', `/webhooks/deliveries/${log[0].id}/resend`);
    expect(again.status).toBe(202);
    await runJobsOnce(deps());
    const after = (await s.api('GET', `/webhooks/${hook.id}/deliveries`)).body.data;
    expect(after[0].status).toBe('delivered');
    expect((await s.api('DELETE', `/webhooks/${hook.id}`)).status).toBe(204);
  });
});

// Property tests -----------------------------------------------------------------------------------

describe('invariants', () => {
  it('journals balance and stock replays to the current balance for random document sequences', async () => {
    const s = await signup();
    const loc = (await s.api('GET', '/locations')).body.data[0];
    const accounts = (await s.api('GET', '/accounts')).body.data as { id: string; code: string }[];
    const cash = accounts.find((a) => a.code === '1000')!;
    const customer = (await s.api('POST', '/parties', { type: 'customer', name: 'Prop Buyer', stateCode: '24' })).body;
    let n = 0;

    type Op = { t: 'adjust'; qty: number } | { t: 'sell'; qty: number } | { t: 'cancel' } | { t: 'credit'; qty: number } | { t: 'receipt'; amount: number };
    const op = fc.oneof(
      fc.record({ t: fc.constant('adjust' as const), qty: fc.integer({ min: 1, max: 40 }) }),
      fc.record({ t: fc.constant('sell' as const), qty: fc.integer({ min: 1, max: 30 }) }),
      fc.record({ t: fc.constant('cancel' as const) }),
      fc.record({ t: fc.constant('credit' as const), qty: fc.integer({ min: 1, max: 5 }) }),
      fc.record({ t: fc.constant('receipt' as const), amount: fc.integer({ min: 1, max: 900 }) }),
    ) as fc.Arbitrary<Op>;

    await fc.assert(fc.asyncProperty(fc.array(op, { minLength: 1, maxLength: 7 }), async (ops) => {
      const item = (await s.api('POST', '/items', { name: `Prop ${n++}`, unit: 'nos', gstRate: 18, salePrice: 100, purchasePrice: 60 })).body;
      await s.api('POST', '/stock/adjustments', { locationId: loc.id, itemId: item.id, qty: 10, rate: 60, isOpening: true });
      let expected = 10;
      const live: { id: string; qty: number; lineId: string; credited: number }[] = [];
      for (const o of ops) {
        if (o.t === 'adjust') {
          const r = await s.api('POST', '/stock/adjustments', { locationId: loc.id, itemId: item.id, qty: o.qty, rate: 60 });
          expect(r.status).toBe(201);
          expected += o.qty;
        } else if (o.t === 'sell') {
          const r = await s.api('POST', '/invoices', { locationId: loc.id, partyId: customer.id, lines: [{ itemId: item.id, qty: o.qty }] });
          if (o.qty <= expected) {
            expect(r.status).toBe(201);
            expected -= o.qty;
            live.push({ id: r.body.id, qty: o.qty, lineId: r.body.lines[0].id, credited: 0 });
          } else {
            expect(r.status).toBeGreaterThanOrEqual(400);
          }
        } else if (o.t === 'cancel') {
          const inv = live.find((i) => i.credited === 0);
          if (!inv) continue;
          const r = await s.api('POST', `/invoices/${inv.id}/cancel`, { reason: 'Property test' });
          expect(r.status).toBe(200);
          expected += inv.qty;
          live.splice(live.indexOf(inv), 1);
        } else if (o.t === 'credit') {
          const inv = live.find((i) => i.qty - i.credited >= o.qty);
          if (!inv) continue;
          const r = await s.api('POST', '/credit-notes', { invoiceId: inv.id, reason: 'Property return', restock: true, lines: [{ invoiceLineId: inv.lineId, qty: o.qty }] });
          expect(r.status).toBe(201);
          inv.credited += o.qty;
          expected += o.qty;
        } else {
          const r = await s.api('POST', '/payments', { kind: 'receipt', partyId: customer.id, accountId: cash.id, mode: 'cash', amount: o.amount });
          expect(r.status).toBe(201);
        }
      }
      // Every journal entry balances, and so does the whole book.
      const bad = await withTenant(env.db, s.tenantId, (tx) => sql<{ n: number }>`
        select count(*)::int as n from (select entry_id from journal_lines group by entry_id having sum(debit) <> sum(credit)) x`.execute(tx));
      expect(bad.rows[0]!.n).toBe(0);
      const total = await withTenant(env.db, s.tenantId, (tx) => sql<{ d: string; c: string }>`select coalesce(sum(debit),0) d, coalesce(sum(credit),0) c from journal_lines`.execute(tx));
      expect(Number(total.rows[0]!.d)).toBeCloseTo(Number(total.rows[0]!.c), 2);
      // Replaying the moves gives the balance the API reports, and the model agrees.
      const replay = await withTenant(env.db, s.tenantId, (tx) => sql<{ q: string }>`select coalesce(sum(qty),0) q from stock_moves where item_id = ${item.id}`.execute(tx));
      const balance = (await s.api('GET', `/stock?q=${encodeURIComponent(item.name)}`)).body.data as { qty: number }[];
      expect(Number(replay.rows[0]!.q)).toBe(expected);
      expect(balance.reduce((a, b) => a + Number(b.qty), 0)).toBe(expected);
    }), { numRuns: 12, seed: 20261112 });
  }, 120_000);
});
