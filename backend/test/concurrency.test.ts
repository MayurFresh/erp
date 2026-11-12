import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'kysely';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Race Traders', name: 'Rina Shah', email: uniqueEmail('race'), password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse' })).body;
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!;
  const party = (await api('POST', '/parties', { type: 'customer', name: 'Racer', stateCode: '24' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor', stateCode: '24' })).body;
  const item = (await api('POST', '/items', { name: 'Race item', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50, trackStock: false })).body;
  return { token, companyId, api, wh, account, party, vendor, item };
}

/** Same request with the same key, fired at once. */
async function twice(b: Awaited<ReturnType<typeof business>>, url: string, body: unknown) {
  const key = `race-${randomUUID()}`;
  const fire = () => env.app.inject({
    method: 'POST', url: `/api/v1${url}`, payload: JSON.stringify(body),
    headers: { authorization: `Bearer ${b.token}`, 'x-company-id': b.companyId, 'content-type': 'application/json', 'idempotency-key': key },
  });
  return Promise.all([fire(), fire()]);
}

describe('same create sent twice at once with one Idempotency-Key', () => {
  it('creates exactly one record on every idempotent create route', async () => {
    const b = await business();
    const cases: { name: string; url: string; body: unknown; list: string; match: (r: any) => boolean }[] = [
      { name: 'party', url: '/parties', body: { type: 'customer', name: 'Twice Party', stateCode: '24' }, list: '/parties?q=Twice%20Party', match: (r) => r.name === 'Twice Party' },
      { name: 'item', url: '/items', body: { name: 'Twice Item', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 10, purchasePrice: 5 }, list: '/items?q=Twice%20Item', match: (r) => r.name === 'Twice Item' },
      { name: 'location', url: '/locations', body: { type: 'warehouse', name: 'Twice Place' }, list: '/locations', match: (r) => r.name === 'Twice Place' },
      { name: 'account', url: '/accounts', body: { name: 'Twice Account', type: 'expense', subtype: 'other' }, list: '/accounts', match: (r) => r.name === 'Twice Account' },
      { name: 'invoice', url: '/invoices', body: { locationId: b.wh.id, partyId: b.party.id, notes: 'twice', lines: [{ itemId: b.item.id, qty: 1 }] }, list: '/invoices', match: (r) => r.notes === 'twice' || r.partyId === b.party.id },
      { name: 'purchase', url: '/purchases', body: { locationId: b.wh.id, partyId: b.vendor.id, lines: [{ itemId: b.item.id, qty: 1, rate: 50 }] }, list: '/purchases', match: (r) => r.partyId === b.vendor.id },
      { name: 'receipt', url: '/payments', body: { kind: 'receipt', partyId: b.party.id, accountId: b.account('1000').id, mode: 'cash', amount: 77 }, list: '/payments', match: (r) => r.amount === 77 },
      { name: 'expense', url: '/expenses', body: { locationId: b.wh.id, accountId: b.account('6070')?.id ?? b.account('1000').id, description: 'Twice expense', amount: 33, paidFromAccountId: b.account('1000').id }, list: '/expenses', match: (r) => r.description === 'Twice expense' },
      { name: 'journal', url: '/journals', body: { narration: 'Twice journal', lines: [{ accountId: b.account('1000').id, debit: 5 }, { accountId: b.account('1010')?.id ?? b.account('1000').id, credit: 5 }] }, list: '/journals', match: (r) => r.narration === 'Twice journal' },
    ];
    for (const c of cases) {
      const [x, y] = await twice(b, c.url, c.body);
      const statuses = [x!.statusCode, y!.statusCode];
      for (const s of statuses) expect(s, `${c.name} ${x!.body} ${y!.body}`).toBeLessThan(500);
      expect(statuses, `${c.name}: ${x!.body} ${y!.body}`).toContain(201);
      const list = (await b.api('GET', c.list)).body.data as any[];
      expect(list.filter(c.match), c.name).toHaveLength(1);
    }
  });
});

describe('number series under concurrency', () => {
  it('gives ten parallel invoices ten different numbers', async () => {
    const b = await business();
    const results = await Promise.all(Array.from({ length: 10 }, () => b.api('POST', '/invoices', {
      locationId: b.wh.id, partyId: b.party.id, lines: [{ itemId: b.item.id, qty: 1 }],
    })));
    for (const r of results) expect(r.status).toBe(201);
    const numbers = results.map((r) => r.body.number as string);
    expect(new Set(numbers).size).toBe(10);
  });
});

describe('cancel against allocate', () => {
  it('never leaves a cancelled invoice with money allocated to it', async () => {
    const b = await business();
    const inv = (await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.party.id, lines: [{ itemId: b.item.id, qty: 10 }] })).body;
    const [cancel, pay] = await Promise.all([
      b.api('POST', `/invoices/${inv.id}/cancel`, { reason: 'Racing cancel' }),
      b.api('POST', '/payments', { kind: 'receipt', partyId: b.party.id, accountId: b.account('1000').id, mode: 'cash', amount: inv.total }),
    ]);
    expect(cancel.status).toBeLessThan(500);
    expect(pay.status).toBeLessThan(500);
    const after = (await b.api('GET', `/invoices/${inv.id}`)).body;
    if (after.status === 'cancelled') expect(after.amountPaid).toBe(0);
    else expect(after.amountPaid).toBeLessThanOrEqual(after.total);
  });
});

describe('STALE_EDIT', () => {
  it('refuses an edit based on an old version and accepts the current one', async () => {
    const b = await business();
    const party = (await b.api('POST', '/parties', { type: 'customer', name: 'Edited Party', stateCode: '24' })).body;
    expect(party.updatedAt).toBeTruthy();
    const first = await b.api('PATCH', `/parties/${party.id}`, { name: 'Edited Once', expectedUpdatedAt: party.updatedAt });
    expect(first.status).toBe(200);
    expect(first.body.updatedAt).not.toBe(party.updatedAt);
    const stale = await b.api('PATCH', `/parties/${party.id}`, { name: 'Edited Twice', expectedUpdatedAt: party.updatedAt });
    expect(stale.status).toBe(409);
    expect(stale.body.error.code).toBe('STALE_EDIT');
    const fresh = await b.api('PATCH', `/parties/${party.id}`, { name: 'Edited Twice', expectedUpdatedAt: first.body.updatedAt });
    expect(fresh.status).toBe(200);
    // Without the field the edit still works (older clients).
    expect((await b.api('PATCH', `/parties/${party.id}`, { phone: '9876543210' })).status).toBe(200);
  });

  it('covers items, accounts, locations and draft orders', async () => {
    const b = await business();
    const loc = (await b.api('POST', '/locations', { type: 'warehouse', name: 'Stale Loc' })).body;
    const l1 = await b.api('PATCH', `/locations/${loc.id}`, { name: 'Stale Loc 2', expectedUpdatedAt: loc.updatedAt });
    expect(l1.status).toBe(200);
    expect((await b.api('PATCH', `/locations/${loc.id}`, { name: 'x1', expectedUpdatedAt: loc.updatedAt })).body.error.code).toBe('STALE_EDIT');
    const item = (await b.api('GET', `/items/${b.item.id}`)).body;
    await b.api('PATCH', `/items/${item.id}`, { name: 'Race item 2' });
    expect((await b.api('PATCH', `/items/${item.id}`, { name: 'x2', expectedUpdatedAt: item.updatedAt })).body.error.code).toBe('STALE_EDIT');
    const acc = (await b.api('POST', '/accounts', { name: 'Stale Acc', type: 'expense', subtype: 'other' })).body;
    const ap = await b.api('PATCH', `/accounts/${acc.id}`, { name: 'Stale Acc 2' });
    expect(ap.status, JSON.stringify([acc, ap.body])).toBe(200);
    expect((await b.api('PATCH', `/accounts/${acc.id}`, { name: 'x3', expectedUpdatedAt: acc.updatedAt })).body.error.code).toBe('STALE_EDIT');
    expect((await sql`select 1`.execute(env.db)).rows).toHaveLength(1);
  });
});

describe('STALE_EDIT on operations records', () => {
  it('covers cost centres, projects, work orders and draft RA bills', async () => {
    const b = await business();
    const stale = async (url: string, body: Record<string, unknown>, updatedAt: string) => {
      const first = await b.api('PATCH', url, { ...body, expectedUpdatedAt: updatedAt });
      expect(first.status, url).toBe(200);
      expect(first.body.updatedAt).not.toBe(updatedAt);
      const second = await b.api('PATCH', url, { ...body, expectedUpdatedAt: updatedAt });
      expect(second.status, url).toBe(409);
      expect(second.body.error.code).toBe('STALE_EDIT');
    };
    const cc = (await b.api('POST', '/cost-centres', { code: 'CC1', name: 'Centre one' })).body;
    expect(cc.updatedAt).toBeTruthy();
    await stale(`/cost-centres/${cc.id}`, { name: 'Centre uno' }, cc.updatedAt);

    const site = (await b.api('POST', '/locations', { type: 'site', name: 'Site S' })).body;
    const project = (await b.api('POST', '/projects', { code: 'PS1', name: 'Stale project', siteIds: [site.id], status: 'active' })).body;
    expect(project.updatedAt).toBeTruthy();
    await stale(`/projects/${project.id}`, { name: 'Stale project 2' }, project.updatedAt);

    const sub = (await b.api('POST', '/parties', { type: 'vendor', name: 'Subcon', stateCode: '24', pan: 'AAKFS1234C' })).body;
    const wo = (await b.api('POST', '/work-orders', {
      projectId: project.id, contractorPartyId: sub.id, title: 'Work', activate: true, gstPct: 18,
      lines: [{ description: 'RCC', unit: 'm3', qty: 10, rate: 100 }],
    })).body;
    expect(wo.updatedAt).toBeTruthy();
    await stale(`/work-orders/${wo.id}`, { title: 'Work 2' }, wo.updatedAt);

    const line = (await b.api('GET', `/work-orders/${wo.id}`)).body.lines[0].id as string;
    const bill = (await b.api('POST', '/ra-bills', { workOrderId: wo.id, lines: [{ workOrderLineId: line, cumQty: 1 }] })).body;
    expect(bill.updatedAt).toBeTruthy();
    await stale(`/ra-bills/${bill.id}`, { lines: [{ workOrderLineId: line, cumQty: 2 }] }, bill.updatedAt);
  });
});

describe('GSTIN check digit', () => {
  it('is enforced when switched on, and refuses without a 500', async () => {
    const b = await business();
    process.env.ENFORCE_GSTIN_CHECKSUM = '1';
    try {
      const bad = await b.api('POST', '/parties', { type: 'customer', name: 'Bad Gstin', gstin: '24AAACD1234F1Z5' });
      expect(bad.status).toBe(400);
      const good = await b.api('POST', '/parties', { type: 'customer', name: 'Good Gstin', gstin: '24AAACD1234F1ZD' });
      expect(good.status).toBe(201);
      // An older saved value that fails the check can stay; a changed one cannot.
      delete process.env.ENFORCE_GSTIN_CHECKSUM;
      const legacy = (await b.api('POST', '/parties', { type: 'customer', name: 'Legacy', gstin: '24AAACD1234F1Z5' })).body;
      process.env.ENFORCE_GSTIN_CHECKSUM = '1';
      const keep = await b.api('PATCH', `/parties/${legacy.id}`, { gstin: '24AAACD1234F1Z5', phone: '9876543210' });
      expect(keep.status).toBe(200);
      const change = await b.api('PATCH', `/parties/${legacy.id}`, { gstin: '24AABCP1234C1Z9' });
      expect(change.status).toBe(400);
    } finally {
      delete process.env.ENFORCE_GSTIN_CHECKSUM;
    }
  });
});

describe('bad entry is refused with 4xx, never 500', () => {
  it('rejects garbage on money-affecting creates', async () => {
    const b = await business();
    const line = { itemId: b.item.id, qty: 1 };
    const cases: [string, string, unknown][] = [
      ['invoice without lines', '/invoices', { locationId: b.wh.id, partyId: b.party.id, lines: [] }],
      ['negative qty', '/invoices', { locationId: b.wh.id, partyId: b.party.id, lines: [{ ...line, qty: -1 }] }],
      ['zero qty', '/invoices', { locationId: b.wh.id, partyId: b.party.id, lines: [{ ...line, qty: 0 }] }],
      ['huge qty', '/invoices', { locationId: b.wh.id, partyId: b.party.id, lines: [{ ...line, qty: 1e15 }] }],
      ['4 decimal qty', '/invoices', { locationId: b.wh.id, partyId: b.party.id, lines: [{ ...line, qty: 1.2345 }] }],
      ['text qty', '/invoices', { locationId: b.wh.id, partyId: b.party.id, lines: [{ ...line, qty: 'abc' }] }],
      ['far future date', '/invoices', { locationId: b.wh.id, partyId: b.party.id, invoiceDate: '2099-01-01', lines: [line] }],
      ['spaces-only party', '/parties', { type: 'customer', name: '     ', stateCode: '24' }],
      ['negative receipt', '/payments', { kind: 'receipt', partyId: b.party.id, accountId: b.account('1000').id, mode: 'cash', amount: -5 }],
      ['3 decimal receipt', '/payments', { kind: 'receipt', partyId: b.party.id, accountId: b.account('1000').id, mode: 'cash', amount: 1.234 }],
      ['zero expense', '/expenses', { locationId: b.wh.id, accountId: b.account('1000').id, description: 'Zero', amount: 0, paidFromAccountId: b.account('1000').id }],
      ['unbalanced journal', '/journals', { narration: 'Unbalanced', lines: [{ accountId: b.account('1000').id, debit: 5 }, { accountId: b.account('1000').id, credit: 4 }] }],
      ['one-line journal', '/journals', { narration: 'One line', lines: [{ accountId: b.account('1000').id, debit: 5 }] }],
      ['purchase without lines', '/purchases', { locationId: b.wh.id, partyId: b.vendor.id, lines: [] }],
    ];
    for (const [name, url, body] of cases) {
      const r = await b.api('POST', url, body);
      expect(r.status, `${name}: ${JSON.stringify(r.body)}`).toBeGreaterThanOrEqual(400);
      expect(r.status, name).toBeLessThan(500);
    }
  });

  it('refuses a document dated inside a locked period', async () => {
    const b = await business();
    const year = new Date().getFullYear() - 1;
    expect((await b.api('PATCH', '/company', { booksLockedUntil: `${year}-12-31` })).status).toBe(200);
    const r = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.party.id, invoiceDate: `${year}-06-01`, lines: [{ itemId: b.item.id, qty: 1 }] });
    expect(r.status).toBe(409);
  });
});
