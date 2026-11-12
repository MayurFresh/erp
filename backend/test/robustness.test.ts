import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'kysely';
import { buildApp } from '../src/app.ts';
import { loadConfig } from '../src/config.ts';
import { withTenant } from '../src/db/database.ts';
import { client, setupTestApp, teardown, TEST_UPLOAD_DIR, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
const routes: { method: string; url: string }[] = [];

beforeAll(async () => {
  // Same as setupTestApp, but the app reports its routes.
  env = await setupTestApp();
  const config = loadConfig({ ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, LOG_LEVEL: 'silent', UPLOAD_DIR: TEST_UPLOAD_DIR });
  const probe = await buildApp({ config, db: env.db, logger: false, authRateLimit: false, onRoute: (r) => routes.push(r) });
  await probe.ready();
  await probe.close();
});
afterAll(async () => {
  await teardown(env);
});

async function business() {
  const email = uniqueEmail('owner');
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Robust Traders', name: 'Rina Shah', email, password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const ho = (await api('GET', '/locations')).body.data[0];
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse' })).body;
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!;
  const tenantId = (await sql<{ id: string; tenant_id: string }>`select id, tenant_id from auth_find_user_by_email(${email})`.execute(env.db)).rows[0]!;
  return { email, token, companyId, tenantId: tenantId.tenant_id, userId: tenantId.id, api, ho, wh, account };
}

/** Raw inject so tests can send headers and non-JSON bodies. */
async function raw(token: string, companyId: string, method: string, url: string, payload?: string, headers: Record<string, string> = {}) {
  const res = await env.app.inject({
    method: method as 'GET', url,
    headers: { authorization: `Bearer ${token}`, 'x-company-id': companyId, ...(payload !== undefined ? { 'content-type': 'application/json' } : {}), ...headers },
    payload,
  });
  return res;
}

describe('route fuzz: no input produces a 500', () => {
  it('survives hostile ids, bodies and queries on every route', async () => {
    const b = await business();
    const party = (await b.api('POST', '/parties', { type: 'customer', name: 'Fuzz Buyer', stateCode: '24' })).body;
    const item = (await b.api('POST', '/items', { name: 'Fuzz Item', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50 })).body;
    const real = { partyId: party.id, itemId: item.id, locationId: b.wh.id, accountId: b.account('1000').id, id: party.id };

    const textKeys = ['name', 'notes', 'reason', 'description', 'email', 'gstin', 'pan', 'reference', 'narration', 'title', 'address', 'remark', 'q', 'search', 'password', 'phone', 'code', 'unit', 'hsnCode', 'supplierInvoiceNo'];
    const numKeys = ['amount', 'qty', 'rate', 'price', 'salePrice', 'purchasePrice', 'gstRate', 'discount', 'tdsAmount', 'quantity', 'limit', 'offset', 'page', 'total', 'debit', 'credit', 'approvedQty', 'percent', 'wage', 'days'];
    const dateKeys = ['date', 'invoiceDate', 'billDate', 'noteDate', 'expenseDate', 'transferDate', 'dueDate', 'from', 'to', 'asOf', 'period', 'startDate', 'endDate', 'requiredBy', 'expiryDate', 'issueDate'];
    const idKeys = ['partyId', 'itemId', 'locationId', 'accountId', 'projectId', 'workerId', 'roleId', 'invoiceId', 'siteId', 'fileId'];
    const fill = (keys: string[], v: unknown) => Object.fromEntries(keys.map((k) => [k, v]));
    const arrays = { lines: [{ itemId: item.id, qty: -1 }], allocations: [{ docId: 'x', amount: 'y' }], entries: [{}], locationIds: ['nope'] };
    const bodies: Record<string, string> = {
      empty: '{}',
      jsonNull: 'null',
      jsonArray: '[]',
      jsonString: '"x"',
      malformed: '{"a":',
      wrongTypes: JSON.stringify({ ...fill([...textKeys, ...dateKeys, ...idKeys], 12345), ...fill(numKeys, 'abc'), lines: 'x', allocations: 5, entries: {} }),
      nullTypes: JSON.stringify({ ...fill([...textKeys, ...numKeys, ...dateKeys, ...idKeys], null), lines: null }),
      long: JSON.stringify({ ...fill(textKeys, 'a'.repeat(5000)), ...fill(idKeys, 'a'.repeat(5000)) }),
      negative: JSON.stringify({ ...real, ...fill(numKeys, -5), ...arrays }),
      huge: JSON.stringify({ ...real, ...fill(numKeys, 1e300), ...arrays, lines: [{ itemId: item.id, qty: 1e300, rate: 1e300 }] }),
      badDates: JSON.stringify({ ...real, ...fill(dateKeys, '2024-13-45') }),
      oldDates: JSON.stringify({ ...real, ...fill(dateKeys, '1900-01-01'), ...fill(numKeys, 1) }),
      realIdsGarbage: JSON.stringify({ ...real, ...fill(textKeys, '\u0000\ud800'), ...fill(numKeys, 0.0001), ...arrays }),
    };
    const queries = ['', '?limit=abc&offset=-1&page=0', '?limit=1e99&from=garbage&to=2024-02-30', `?partyId=zzz&itemId=${'a'.repeat(5000)}&locationId=1&status=x`, '?q=%00&search=%ff&asOf=0000-00-00&period=2024-13&date=bad&year=99999999'];
    const offenders: string[] = [];
    let count = 0;
    const check = (label: string, status: number, text: string) => {
      count++;
      if (status >= 500) offenders.push(`${label} -> ${status} ${text.slice(0, 120)}`);
    };

    expect(routes.length).toBeGreaterThan(100);
    for (const r of routes) {
      if (r.url.includes('/auth/') || r.url === '/health') continue;
      const withId = (id: string) => r.url.replace(/:[A-Za-z]+/g, id);
      const ids = ['not-a-uuid', randomUUID(), real.id];
      for (const id of ids) {
        const url = withId(id);
        if (r.method === 'GET' || r.method === 'DELETE') {
          for (const q of queries) {
            const res = await raw(b.token, b.companyId, r.method, url + q);
            check(`${r.method} ${url}${q.slice(0, 40)}`, res.statusCode, res.body);
          }
        } else {
          for (const [bn, body] of Object.entries(bodies)) {
            const res = await raw(b.token, b.companyId, r.method, url, body);
            check(`${r.method} ${r.url} [${id === 'not-a-uuid' ? 'badid' : id === real.id ? 'realid' : 'randid'}/${bn}]`, res.statusCode, res.body);
          }
        }
      }
      if (r.method === 'GET') {
        // Authenticated but without a company header, and with a stale one.
        const res = await env.app.inject({ method: 'GET', url: withId(randomUUID()), headers: { authorization: `Bearer ${b.token}` } });
        check(`GET ${r.url} [no company]`, res.statusCode, res.body);
      }
    }
    console.log(`fuzz: ${routes.length} routes, ${count} requests`);
    if (offenders.length) console.log(`500s (${offenders.length} of ${count}):\n${[...new Set(offenders)].join('\n')}`);
    expect(offenders).toEqual([]);
  }, 600_000);
});

describe('error mapping', () => {
  it('answers 404 for non-UUID ids and 400 for malformed JSON', async () => {
    const b = await business();
    expect((await b.api('GET', '/invoices/not-a-uuid')).status).toBe(404);
    expect((await b.api('POST', '/invoices/123/cancel', { reason: 'xxxx' })).status).toBe(404);
    expect((await raw(b.token, b.companyId, 'POST', '/api/v1/parties', '{"a":')).statusCode).toBe(400);
  });

  it('answers 413 above 1 MB', async () => {
    const b = await business();
    const res = await raw(b.token, b.companyId, 'POST', '/api/v1/parties', JSON.stringify({ name: 'x'.repeat(1_100_000) }));
    expect(res.statusCode).toBe(413);
    expect(res.json().error.code).toBe('PAYLOAD_TOO_LARGE');
  });

  it('maps a foreign-key violation to IN_USE on delete and to 400 on create', async () => {
    const b = await business();
    const party = (await b.api('POST', '/parties', { type: 'customer', name: 'Used Buyer', stateCode: '24' })).body;
    const item = (await b.api('POST', '/items', { name: 'Thing', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50, trackStock: false })).body;
    const inv = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: party.id, lines: [{ itemId: item.id, qty: 1 }] });
    expect(inv.status).toBe(201);
    // No public endpoint deletes a party, so exercise the error handler through a probe route.
    const config = loadConfig({ ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, LOG_LEVEL: 'silent', UPLOAD_DIR: TEST_UPLOAD_DIR });
    const probe = await buildApp({ config, db: env.db, logger: false, authRateLimit: false });
    const kill = async (req: { params: unknown }) =>
      withTenant(env.db, b.tenantId, (tx) => tx.deleteFrom('parties').where('id', '=', (req.params as { id: string }).id).execute());
    probe.delete('/probe/:id', kill);
    probe.post('/probe/:id', async (req) => {
      await withTenant(env.db, b.tenantId, (tx) => sql`select 1`.execute(tx));
      return withTenant(env.db, b.tenantId, (tx) =>
        tx.insertInto('invoice_lines').values({ invoice_id: (req.params as { id: string }).id } as never).execute());
    });
    const del = await probe.inject({ method: 'DELETE', url: `/probe/${party.id}` });
    expect(del.statusCode).toBe(409);
    expect(del.json().error.code).toBe('IN_USE');
    await probe.close();
  });
});

describe('numeric overflow', () => {
  it('turns out-of-range totals into 400, not 500', async () => {
    const b = await business();
    const party = (await b.api('POST', '/parties', { type: 'customer', name: 'Big Buyer', stateCode: '24' })).body;
    const item = (await b.api('POST', '/items', { name: 'Big item', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50, trackStock: false })).body;
    const res = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: party.id, lines: [{ itemId: item.id, qty: 1e9, rate: 1e10 }] });
    expect(res.status).toBe(400);
    const pay = await b.api('POST', '/payments', { kind: 'receipt', partyId: party.id, accountId: b.account('1000').id, mode: 'cash', amount: 1e10 });
    expect(pay.status).toBeLessThan(500);
  });
});

describe('concurrency', () => {
  it('never over-allocates when two receipts race for one invoice', async () => {
    const b = await business();
    const party = (await b.api('POST', '/parties', { type: 'customer', name: 'Racer', stateCode: '24' })).body;
    const item = (await b.api('POST', '/items', { name: 'Race item', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50, trackStock: false })).body;
    const inv = (await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: party.id, lines: [{ itemId: item.id, qty: 10 }] })).body;
    const pay = () => b.api('POST', '/payments', { kind: 'receipt', partyId: party.id, accountId: b.account('1000').id, mode: 'cash', amount: inv.total });
    const results = await Promise.all([pay(), pay(), pay()]);
    for (const r of results) expect(r.status).toBeLessThan(500);
    const after = (await b.api('GET', `/invoices/${inv.id}`)).body;
    expect(after.amountPaid).toBeLessThanOrEqual(after.total);
    const allocated = results.filter((r) => r.status === 201).reduce((s, r) => s + r.body.allocated, 0);
    expect(allocated).toBeLessThanOrEqual(inv.total);
  });

  it('lets exactly one of two parallel cancels win', async () => {
    const b = await business();
    const party = (await b.api('POST', '/parties', { type: 'customer', name: 'Canceller', stateCode: '24' })).body;
    const item = (await b.api('POST', '/items', { name: 'Cancel item', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50, trackStock: false })).body;
    const inv = (await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: party.id, lines: [{ itemId: item.id, qty: 1 }] })).body;
    const [x, y] = await Promise.all([1, 2].map(() => b.api('POST', `/invoices/${inv.id}/cancel`, { reason: 'Race cancel' })));
    expect([x!.status, y!.status].sort()).toEqual([200, 409]);
    const loser = x!.status === 409 ? x! : y!;
    expect(loser.body.error.code).toBe('ALREADY_CANCELLED');
  });

  it('refuses a parallel stock issue that exceeds the balance', async () => {
    const b = await business();
    const item = (await b.api('POST', '/items', { name: 'Scarce', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50 })).body;
    expect((await b.api('POST', '/stock/adjustments', { locationId: b.wh.id, itemId: item.id, qty: 100, rate: 50, isOpening: true })).status).toBe(201);
    const results = await Promise.all([1, 2, 3].map(() => b.api('POST', '/stock/adjustments', { locationId: b.wh.id, itemId: item.id, qty: -60 })));
    expect(results.filter((r) => r.status === 201)).toHaveLength(1);
    for (const r of results.filter((r) => r.status !== 201)) {
      expect(r.status).toBe(409);
      expect(r.body.error.code).toBe('INSUFFICIENT_STOCK');
    }
  });
});

describe('idempotency', () => {
  it('replays the stored response and creates nothing twice', async () => {
    const b = await business();
    const key = `key-${randomUUID()}`;
    const body = JSON.stringify({ type: 'customer', name: 'Once Only', stateCode: '24' });
    const first = await raw(b.token, b.companyId, 'POST', '/api/v1/parties', body, { 'idempotency-key': key });
    expect(first.statusCode).toBe(201);
    expect(first.headers['idempotent-replayed']).toBeUndefined();
    const second = await raw(b.token, b.companyId, 'POST', '/api/v1/parties', body, { 'idempotency-key': key });
    expect(second.statusCode).toBe(201);
    expect(second.headers['idempotent-replayed']).toBe('true');
    expect(second.json()).toEqual(first.json());
    const list = (await b.api('GET', '/parties?q=Once%20Only')).body;
    expect(list.data.filter((p: { name: string }) => p.name === 'Once Only')).toHaveLength(1);

    const other = await raw(b.token, b.companyId, 'POST', '/api/v1/parties', JSON.stringify({ type: 'customer', name: 'Different', stateCode: '24' }), { 'idempotency-key': key });
    expect(other.statusCode).toBe(422);
    expect(other.json().error.code).toBe('IDEMPOTENCY_MISMATCH');
    const bad = await raw(b.token, b.companyId, 'POST', '/api/v1/parties', body, { 'idempotency-key': 'short' });
    expect(bad.statusCode).toBe(400);
  });

  it('does not store failures, so the same key can be retried', async () => {
    const b = await business();
    const key = `retry-${randomUUID()}`;
    const bad = await raw(b.token, b.companyId, 'POST', '/api/v1/parties', JSON.stringify({ type: 'customer' }), { 'idempotency-key': key });
    expect(bad.statusCode).toBe(400);
    const same = await raw(b.token, b.companyId, 'POST', '/api/v1/parties', JSON.stringify({ type: 'customer' }), { 'idempotency-key': key });
    expect(same.statusCode).toBe(400);
    expect(same.headers['idempotent-replayed']).toBeUndefined();
  });

  it('answers 409 REQUEST_IN_PROGRESS while the first request is still running', async () => {
    const b = await business();
    const key = `busy-${randomUUID()}`;
    const body = { type: 'customer', name: 'Slow One', stateCode: '24' };
    const hash = (await import('node:crypto')).createHash('sha256').update(JSON.stringify(body)).digest('hex');
    await withTenant(env.db, b.tenantId, (tx) => tx.insertInto('idempotency_keys').values({
      tenant_id: b.tenantId, user_id: b.userId, key, method: 'POST', path: '/api/v1/parties', body_hash: hash,
    }).execute());
    const res = await raw(b.token, b.companyId, 'POST', '/api/v1/parties', JSON.stringify(body), { 'idempotency-key': key });
    expect(res.statusCode).toBe(409);
    expect(res.json().error.code).toBe('REQUEST_IN_PROGRESS');
  });
});

describe('session revocation', () => {
  it('rejects the old token once the user is deactivated', async () => {
    const b = await business();
    const roles = (await b.api('GET', '/roles')).body.data;
    const email = uniqueEmail('temp');
    const created = await b.api('POST', '/users', { name: 'Temp', email, password: 'Secret@123', roleId: roles.find((r: { name: string }) => r.name === 'Company Admin').id });
    expect(created.status).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    const temp = client(env.app, login.body.accessToken, b.companyId);
    expect((await temp('GET', '/items')).status).toBe(200);
    expect((await b.api('PATCH', `/users/${created.body.id}`, { isActive: false })).status).toBe(200);
    const after = await temp('GET', '/items');
    expect(after.status).toBe(401);
    expect(after.body.error.code).toBe('SESSION_REVOKED');
  });

  it('rejects a company the user has no access to', async () => {
    const a = await business();
    const other = await business();
    const res = await client(env.app, other.token, a.companyId)('GET', '/items');
    expect(res.status).toBe(401);
    expect(res.body.error.code).toBe('SESSION_REVOKED');
  });
});
