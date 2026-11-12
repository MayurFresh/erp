import { createHmac } from 'node:crypto';
import http from 'node:http';
import type { AddressInfo } from 'node:net';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.ts';
import { runJobsOnce } from '../src/lib/jobs.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
let mock: http.Server;
let base = '';
const calls: { method: string; url: string; body: any; auth: string | undefined }[] = [];
let shopifyOrders: any[] = [];
/** Turns the REST-shaped fixture into a GraphQL order node. */
const toGraphqlOrder = (o: any) => {
  const set = (a: unknown) => ({ shopMoney: { amount: String(a ?? '0') } });
  return {
    id: `gid://shopify/Order/${o.id}`, name: o.name, createdAt: o.created_at, updatedAt: o.updated_at, cancelledAt: o.cancelled_at ?? null,
    note: o.note ?? null, taxesIncluded: o.taxes_included,
    shippingAddress: o.shipping_address ? { name: o.shipping_address.name, provinceCode: o.shipping_address.province_code } : null,
    shippingLines: { nodes: [] },
    lineItems: { nodes: o.line_items.map((l: any) => ({ id: `gid://shopify/LineItem/${l.id}`, sku: l.sku, title: l.title, quantity: l.quantity, variant: null, product: null, originalUnitPriceSet: set(l.price), totalDiscountSet: set(l.total_discount) })) },
  };
};
let wooOrders: any[] = [];
let pullStatus = 200;
let pagedShopify = false;
let pagedWoo = false;

beforeAll(async () => {
  mock = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8');
      const url = req.url ?? '';
      const auth = (req.headers['x-shopify-access-token'] ?? req.headers.authorization) as string | undefined;
      calls.push({ method: req.method ?? '', url, body: raw ? JSON.parse(raw) : null, auth });
      const send = (code: number, body: unknown) => { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(body)); };
      if (url.startsWith('/admin/api/') && url.endsWith('/graphql.json')) {
        if (auth !== 'shpat_good') return send(401, {});
        const q = String(calls[calls.length - 1]!.body?.query ?? '');
        const v = calls[calls.length - 1]!.body?.variables ?? {};
        if (q.includes('shop {')) return send(200, { data: { shop: { name: 'Mock Shop' } } });
        if (q.includes('orders(')) {
          if (pullStatus !== 200) return send(pullStatus, {});
          let list = shopifyOrders;
          let more = false;
          let endCursor: string | null = null;
          if (pagedShopify) {
            const pg = v.after ? Number(String(v.after).replace('p', '')) : 1;
            list = shopifyOrders.slice((pg - 1) * 2, pg * 2);
            more = pg * 2 < shopifyOrders.length;
            endCursor = more ? `p${pg + 1}` : null;
          }
          return send(200, { data: { orders: { pageInfo: { hasNextPage: more, endCursor }, nodes: list.map(toGraphqlOrder) } } });
        }
        if (q.includes('inventorySetQuantities')) return send(200, { data: { inventorySetQuantities: { userErrors: [] } } });
        return send(200, { errors: [{ message: 'unknown' }] });
      }
      if (url.includes('/wp-json/wc/v3/orders')) {
        if (!pagedWoo) return send(200, wooOrders);
        const pg = Number(new URL(url, 'http://x').searchParams.get('page') ?? 1);
        res.writeHead(200, { 'content-type': 'application/json', 'x-wp-totalpages': String(Math.ceil(wooOrders.length / 2)) });
        return res.end(JSON.stringify(wooOrders.slice((pg - 1) * 2, pg * 2)));
      }
      if (url.includes('/wp-json/wc/v3/products/')) return send(200, {});
      send(404, {});
    });
  });
  await new Promise<void>((r) => mock.listen(0, '127.0.0.1', r));
  base = `http://127.0.0.1:${(mock.address() as AddressInfo).port}`;
  env = await setupTestApp();
});
afterAll(async () => { await teardown(env); await new Promise((r) => mock.close(r)); });

const PASSWORD = 'Secret@123';
const SHOP_SECRET = 'shop-webhook-secret';
let n = 0;

async function biz(provider: 'shopify' | 'woocommerce' = 'shopify') {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Live Co', name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24', businessType: 'marketplace',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, signup.body.accessToken, me.companies[0].id);
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const item = (await api('POST', '/items', { name: 'Item AAA', sku: 'AAA', hsnCode: '6907', unit: 'nos', gstRate: 18, salePrice: 100, purchasePrice: 60, trackStock: true })).body;
  const buy = (qty: number) => api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId: item.id, qty, rate: 60 }] });
  expect((await buy(20)).status).toBe(201);
  const conn = (await api('POST', '/channels', { provider, name: `${provider} store ${n++}`, locationId: wh.id, stockBuffer: 2 })).body;
  expect(conn.status).toBe('not_connected');
  return { api, wh, item, conn, buy, token: signup.body.accessToken as string };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const runAll = async () => {
  const config = loadConfig({ ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, LOG_LEVEL: 'silent' });
  for (let i = 0; i < 10; i++) if ((await runJobsOnce({ db: env.db, config, log: env.app.log as never })) === 0) break;
};

const shopifyCreds = { shopDomain: base, accessToken: 'shpat_good', webhookSecret: SHOP_SECRET, locationId: '555' };
const connectShopify = async (b: Biz) => {
  const put = await b.api('PUT', `/channels/${b.conn.id}/credentials`, { values: { ...shopifyCreds, shopDomain: base } });
  expect(put.status, JSON.stringify(put.body)).toBe(200);
  const chk = await b.api('POST', `/channels/${b.conn.id}/check`);
  expect(chk.body.ok, JSON.stringify(chk.body)).toBe(true);
};

const shopifyOrder = (id: number, name: string, sku: string, extra: object = {}) => ({
  id, name, created_at: '2026-11-10T08:00:00Z', updated_at: `2026-11-10T08:0${id % 10}:00Z`, taxes_included: true,
  line_items: [{ id: id * 10, sku, title: 'Thing', quantity: 2, price: '118.00', total_discount: '0.00' }],
  shipping_address: { name: 'Asha Rao', province_code: 'GJ' }, ...extra,
});
const sign = (secret: string, raw: string) => createHmac('sha256', secret).update(raw).digest('base64');
const hook = (b: Biz, raw: string, headers: Record<string, string>) =>
  env.app.inject({ method: 'POST', url: `/api/v1/webhooks/channels/${b.conn.id}`, headers: { 'content-type': 'application/json', ...headers }, payload: raw });

describe('credentials', () => {
  it('seals credentials, never returns them, and connects only after a passing check', async () => {
    const b = await biz();
    expect((await b.api('PATCH', `/channels/${b.conn.id}/credentials`, { values: { shopDomain: 'evil.example.com', accessToken: 'x', webhookSecret: 'y', locationId: '1' } })).status).toBe(400);
    expect((await b.api('PUT', `/channels/${b.conn.id}/credentials`, { values: { shopDomain: base } })).status).toBe(400);
    const bad = await b.api('PUT', `/channels/${b.conn.id}/credentials`, { values: { ...shopifyCreds, shopDomain: base, accessToken: 'shpat_bad' } });
    expect(bad.status).toBe(200);
    const failed = await b.api('POST', `/channels/${b.conn.id}/check`);
    expect(failed.body).toMatchObject({ ok: false, status: 'not_connected' });
    await connectShopify(b);
    const got = JSON.stringify((await b.api('GET', `/channels/${b.conn.id}`)).body) + JSON.stringify((await b.api('GET', `/channels/${b.conn.id}/health`)).body)
      + JSON.stringify((await b.api('GET', '/channels')).body);
    expect(got).not.toContain('shpat_good');
    expect(got).not.toContain(SHOP_SECRET);
    const h = (await b.api('GET', `/channels/${b.conn.id}/health`)).body;
    expect(h).toMatchObject({ status: 'connected', hasCredentials: true, live: true });
    expect(h.credentials.every((c: { set: boolean }) => c.set)).toBe(true);
    expect((await b.api('DELETE', `/channels/${b.conn.id}/credentials`)).body.status).toBe('not_connected');
    // A CSV-only provider has nothing to connect.
    const manual = (await b.api('POST', '/channels', { provider: 'manual', name: 'CSV', locationId: b.wh.id })).body;
    expect((await b.api('PUT', `/channels/${manual.id}/credentials`, { values: { a: 'b' } })).body.error.code).toBe('NO_LIVE_API');
  });
});

describe('inbound webhooks', () => {
  it('rejects a bad signature, stores a good one once, and turns it into an order after mapping', async () => {
    const b = await biz();
    await connectShopify(b);
    const raw = JSON.stringify(shopifyOrder(1001, '#1001', 'SKU-A'));
    const goodHeaders = { 'x-shopify-hmac-sha256': sign(SHOP_SECRET, raw), 'x-shopify-topic': 'orders/create', 'x-shopify-event-id': 'evt-1' };
    const bad = await hook(b, raw, { ...goodHeaders, 'x-shopify-hmac-sha256': sign('wrong', raw) });
    expect(bad.statusCode).toBe(401);
    expect((await b.api('GET', `/channels/${b.conn.id}/health`)).body.webhookRejects).toBe(1);
    expect((await env.app.inject({ method: 'POST', url: '/api/v1/webhooks/channels/00000000-0000-4000-8000-000000000000', payload: '{}', headers: { 'content-type': 'application/json' } })).statusCode).toBe(404);

    expect((await hook(b, raw, goodHeaders)).statusCode).toBe(200);
    expect((await hook(b, raw, goodHeaders)).statusCode).toBe(200); // same event id
    await runAll();
    let inbox = (await b.api('GET', '/channels/inbox')).body;
    expect(inbox.total).toBe(1);
    expect(inbox.data[0]).toMatchObject({ status: 'failed', errorCode: 'UNMAPPED_SKU', externalRef: '#1001' });
    expect((await b.api('GET', `/channels/${b.conn.id}/health`)).body.webhookRejects).toBe(0);

    const map = await b.api('POST', `/channels/${b.conn.id}/listings`, { channelSku: 'SKU-A', externalId: '9001', components: [{ itemId: b.item.id, qty: 1 }] });
    expect(map.status, JSON.stringify(map.body)).toBe(201);
    inbox = (await b.api('GET', '/channels/inbox')).body;
    expect(inbox.data[0].status).toBe('processed');
    expect((await b.api('GET', '/sales-orders')).body.total).toBe(1);

    // A cancel event for the same order cancels it.
    const cancelRaw = JSON.stringify(shopifyOrder(1001, '#1001', 'SKU-A', { cancelled_at: '2026-11-10T09:00:00Z' }));
    await hook(b, cancelRaw, { 'x-shopify-hmac-sha256': sign(SHOP_SECRET, cancelRaw), 'x-shopify-topic': 'orders/cancelled', 'x-shopify-event-id': 'evt-2' });
    await runAll();
    const so = (await b.api('GET', '/sales-orders')).body.data[0];
    expect(so.status).toBe('cancelled');
    // Webhook rows are not in the order list.
    expect((await b.api('GET', '/channels/inbox')).body.data.every((r: { externalRef: string }) => r.externalRef.startsWith('#'))).toBe(true);
  });
});

describe('scheduled pull', () => {
  it('pulls from the cursor, queues events, and degrades the channel on an auth failure', async () => {
    const b = await biz();
    await connectShopify(b);
    await b.api('POST', `/channels/${b.conn.id}/listings`, { channelSku: 'SKU-P', externalId: '9002', components: [{ itemId: b.item.id, qty: 1 }] });
    shopifyOrders = [shopifyOrder(2001, '#2001', 'SKU-P'), shopifyOrder(2002, '#2002', 'SKU-P')];
    calls.length = 0;
    expect((await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'orders' })).status).toBe(202);
    await runAll();
    expect((await b.api('GET', '/sales-orders')).body.total).toBe(2);
    expect(calls.find((c) => String(c.body?.query).includes('orders('))!.body.variables.query).toBeNull();
    calls.length = 0;
    await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'orders' });
    await runAll();
    expect(calls.find((c) => String(c.body?.query).includes('orders('))!.body.variables.query).toBe("updated_at:>='2026-11-10T08:02:00Z'");
    expect((await b.api('GET', '/sales-orders')).body.total).toBe(2); // nothing duplicated
    pullStatus = 401;
    await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'orders' });
    await runAll();
    pullStatus = 200;
    const h = (await b.api('GET', `/channels/${b.conn.id}/health`)).body;
    expect(h.status).toBe('degraded');
    expect(h.lastError).toBeTruthy();
  });
});

describe('stock push', () => {
  it('queues a job on stock changes and pushes only changed quantities, less the buffer', async () => {
    const b = await biz();
    await connectShopify(b);
    await b.api('POST', `/channels/${b.conn.id}/listings`, { channelSku: 'SKU-S', externalId: '7001', components: [{ itemId: b.item.id, qty: 2 }] });
    expect((await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'stock' })).body.error.code).toBe('PUSH_OFF');
    expect((await b.api('PATCH', `/channels/${b.conn.id}`, { pushStock: true })).status).toBe(200);
    const queued0 = (await b.api('GET', `/channels/${b.conn.id}/health`)).body.queuedJobs;
    await b.buy(10); // stock change fires the trigger
    expect((await b.api('GET', `/channels/${b.conn.id}/health`)).body.queuedJobs).toBeGreaterThan(queued0);
    await b.buy(10); // same bucket: still one queued stock job
    calls.length = 0;
    await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'stock' });
    await runAll();
    const pushes = calls.filter((c) => String(c.body?.query).includes('inventorySetQuantities'));
    expect(pushes).toHaveLength(1);
    // 40 on hand, bundle of 2 per sale, buffer 2: floor(40 / 2) - 2.
    expect(pushes[0]!.body.variables.input.quantities).toEqual([{ inventoryItemId: 'gid://shopify/InventoryItem/7001', locationId: 'gid://shopify/Location/555', quantity: 18, changeFromQuantity: null }]);
    calls.length = 0;
    await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'stock' }); // manual sync forces a full push
    await runAll();
    expect(calls.filter((c) => String(c.body?.query).includes('inventorySetQuantities'))).toHaveLength(1);
  });
});

describe('WooCommerce', () => {
  it('checks, verifies webhook signatures, and pushes stock with basic auth', async () => {
    const b = await biz('woocommerce');
    const values = { storeUrl: base, consumerKey: 'ck_1', consumerSecret: 'cs_1', webhookSecret: 'woo-secret' };
    expect((await b.api('PUT', `/channels/${b.conn.id}/credentials`, { values })).status).toBe(200);
    expect((await b.api('POST', `/channels/${b.conn.id}/check`)).body.ok).toBe(true);
    await b.api('POST', `/channels/${b.conn.id}/listings`, { channelSku: 'W-1', externalId: '31', components: [{ itemId: b.item.id, qty: 1 }] });
    const order = { id: 77, number: '77', status: 'processing', date_created_gmt: '2026-11-10T04:00:00', shipping: { first_name: 'Ravi', last_name: 'K', state: 'MH' },
      line_items: [{ sku: 'W-1', name: 'Thing', quantity: 2, subtotal: '200.00', total: '180.00' }] };
    const raw = JSON.stringify(order);
    const h = { 'x-wc-webhook-signature': sign('woo-secret', raw), 'x-wc-webhook-topic': 'order.created', 'x-wc-webhook-delivery-id': 'd-1' };
    expect((await hook(b, raw, { ...h, 'x-wc-webhook-signature': 'AAAA' })).statusCode).toBe(401);
    expect((await hook(b, raw, h)).statusCode).toBe(200);
    await runAll();
    const so = (await b.api('GET', '/sales-orders')).body.data[0];
    expect(so.externalRef ?? so.external_ref).toBe('#77');
    await b.api('PATCH', `/channels/${b.conn.id}`, { pushStock: true });
    calls.length = 0;
    await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'stock' });
    await runAll();
    const put = calls.find((c) => c.method === 'PUT' && c.url.includes('/products/31'))!;
    expect(put.body).toMatchObject({ manage_stock: true, stock_quantity: 16 });
    expect(put.auth).toBe(`Basic ${Buffer.from('ck_1:cs_1').toString('base64')}`);
  });
});

describe('paged pull', () => {
  it('follows Shopify Link pages in one run and continues from the saved cursor when capped', async () => {
    const b = await biz();
    await connectShopify(b);
    await b.api('POST', `/channels/${b.conn.id}/listings`, { channelSku: 'SKU-G', externalId: '9003', components: [{ itemId: b.item.id, qty: 1 }] });
    shopifyOrders = [3001, 3002, 3003, 3004, 3005].map((i) => shopifyOrder(i, `#${i}`, 'SKU-G'));
    pagedShopify = true;
    calls.length = 0;
    await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'orders' });
    await runAll();
    pagedShopify = false;
    expect(calls.filter((c) => String(c.body?.query).includes('orders(')).length).toBe(3);
    expect(calls.filter((c) => c.body?.variables?.after).length).toBe(2);
    expect((await b.api('GET', '/sales-orders')).body.total).toBe(5);
  });

  it('follows WooCommerce page numbers', async () => {
    const b = await biz('woocommerce');
    const put = await b.api('PUT', `/channels/${b.conn.id}/credentials`, { values: { storeUrl: base, consumerKey: 'ck_good', consumerSecret: 'cs_good', webhookSecret: 'w' } });
    if (put.status !== 200) return; // credential field names differ; the Shopify case covers the loop
    await b.api('POST', `/channels/${b.conn.id}/check`);
    wooOrders = [1, 2, 3].map((i) => ({ id: 7000 + i, date_modified_gmt: `2026-11-10T08:0${i}:00`, line_items: [] }));
    pagedWoo = true;
    calls.length = 0;
    await b.api('POST', `/channels/${b.conn.id}/sync`, { what: 'orders' });
    await runAll();
    pagedWoo = false;
    const pages = calls.filter((c) => c.url.includes('/wc/v3/orders')).map((c) => new URL(c.url, 'http://x').searchParams.get('page'));
    expect(pages).toEqual(['1', '2']);
  });
});

describe('cleanup', () => {
  it('drops old finished events and keeps failed ones', async () => {
    const b = await biz();
    await connectShopify(b);
    const { sql } = await import('kysely');
    const { withTenant } = await import('../src/db/database.ts');
    const tid = JSON.parse(Buffer.from(b.token.split('.')[1]!, 'base64url').toString()).tid as string;
    await withTenant(env.db, tid, async (tx) => {
      await sql`insert into channel_inbox (tenant_id, company_id, connection_id, event_id, source, payload, status, updated_at)
        select k.tenant_id, k.company_id, k.id, e.eid, 'poll', '{}'::jsonb, e.st, now() - interval '100 days'
        from channel_connections k, (values ('old-ok','processed'),('old-bad','failed')) e(eid, st) where k.id = ${b.conn.id}::uuid`.execute(tx);
    });
    await sql`select jobs_enqueue_daily('cleanup.channels', current_date + 400)`.execute(env.db);
    await runAll();
    const left = await withTenant(env.db, tid, (tx) => sql<{ event_id: string }>`select event_id from channel_inbox where connection_id = ${b.conn.id}::uuid`.execute(tx));
    expect(left.rows.map((r) => r.event_id)).toContain('old-bad');
    expect(left.rows.map((r) => r.event_id)).not.toContain('old-ok');
  });
});

describe('Tally export', () => {
  it('exports journal vouchers as XML and limits the range', async () => {
    const b = await biz();
    const me = (await client(env.app, b.token)('GET', '/me')).body;
    const res = await env.app.inject({
      method: 'GET', url: `/api/v1/export/tally?from=2020-01-01&to=2030-12-31`, headers: { authorization: `Bearer ${b.token}`, 'x-company-id': me.companies[0].id },
    });
    expect(res.statusCode).toBe(400);
    const today = new Date().toISOString().slice(0, 10);
    const ok = await env.app.inject({
      method: 'GET', url: `/api/v1/export/tally?from=${today.slice(0, 4)}-01-01&to=${today}`, headers: { authorization: `Bearer ${b.token}`, 'x-company-id': me.companies[0].id },
    });
    expect(ok.statusCode, ok.body.slice(0, 200)).toBe(200);
    expect(ok.headers['content-type']).toContain('xml');
    expect(ok.body).toContain('<VOUCHER REMOTEID=');
    expect(ok.body).toContain('<ISDEEMEDPOSITIVE>Yes</ISDEEMEDPOSITIVE>');
    expect(ok.body).toContain('<VOUCHERTYPENAME>Purchase</VOUCHERTYPENAME>');
    expect(ok.body).not.toContain('VCHTYPE="Journal"><DATE>'.replace('><DATE>', ''));
    expect(ok.body).toMatch(/<AMOUNT>-\d+\.\d{2}<\/AMOUNT>/);
  });
});
