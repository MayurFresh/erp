import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withDatabase } from '../src/db/migrate.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const PASSWORD = 'Secret@123';

async function biz(name: string) {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, signup.body.accessToken, me.companies[0].id as string);
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor', stateCode: '24' })).body;
  const customer = (await api('POST', '/parties', { type: 'customer', name: 'Customer', stateCode: '24' })).body;
  const item = async (sku: string, unit = 'nos', price = 100) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, hsnCode: '6907', unit, gstRate: 18, salePrice: price, purchasePrice: 60, trackStock: true });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string };
  };
  const buy = async (itemId: string, qty: number, rate: number, extra: object = {}) => {
    const r = await api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId, qty, rate, ...extra }] });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string; subtotal: number; lines: Record<string, unknown>[] };
  };
  const sell = async (itemId: string, qty: number, extra: object = {}) => {
    const r = await api('POST', '/invoices', { locationId: wh.id, partyId: customer.id, lines: [{ itemId, qty, ...extra }] });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string; subtotal: number; lines: Record<string, unknown>[] };
  };
  const moves = async (itemId: string) => (await api('GET', `/stock/moves?itemId=${itemId}&limit=100`)).body.data as { qty: number; value: number; refType: string }[];
  return { api, wh, vendor, customer, item, buy, sell, moves };
}

async function owner() {
  const c = new pg.Client({ connectionString: withDatabase(process.env.DATABASE_ADMIN_URL!, new URL(process.env.TEST_DATABASE_URL!).pathname.slice(1)) });
  await c.connect();
  return c;
}

/** The ledger is append-only, so the test owner lifts the guard for the one update. */
async function backdate(c: pg.Client, refId: string, days: number) {
  await c.query('alter table stock_moves disable trigger stock_moves_no_change');
  try { await c.query(`update stock_moves set created_at = now() - make_interval(days => $2) where ref_id = $1`, [refId, days]); }
  finally { await c.query('alter table stock_moves enable trigger stock_moves_no_change'); }
}

describe('weighted average stays the default', () => {
  it('costs an issue at the running average', async () => {
    const b = await biz('Avg Co');
    expect((await b.api('GET', '/stock/valuation-method')).body.method).toBe('average');
    const it = await b.item('AVG');
    await b.buy(it.id, 10, 60);
    await b.buy(it.id, 10, 80);
    await b.sell(it.id, 5);
    const out = (await b.moves(it.id)).find((m) => m.refType === 'invoice')!;
    expect(out.value).toBe(-350);
    const rep = (await b.api('GET', '/reports/stock-valuation')).body;
    expect(rep.method).toBe('average');
    expect(rep.totalValue).toBe(1050);
  });
});

describe('FIFO', () => {
  it('consumes the oldest layers first and can be compared with average', async () => {
    const b = await biz('Fifo Co');
    const it = await b.item('FIF');
    await b.buy(it.id, 10, 60);
    await b.buy(it.id, 10, 80);
    expect((await b.api('PUT', '/stock/valuation-method', { method: 'fifo' })).status).toBe(200);
    expect((await b.api('PUT', '/stock/valuation-method', { method: 'fifo', effectiveFrom: '2020-01-01' })).status).toBe(400);
    await b.sell(it.id, 12);
    const out = (await b.moves(it.id)).find((m) => m.refType === 'invoice')!;
    expect(out.value).toBe(-760); // 10 x 60 + 2 x 80
    const books = (await b.api('GET', '/reports/stock-valuation')).body;
    expect(books.method).toBe('fifo');
    expect(books.comparison).toBe(false);
    expect(books.totalValue).toBe(640); // 8 x 80
    const avg = (await b.api('GET', '/reports/stock-valuation?method=average')).body;
    expect(avg.comparison).toBe(true);
    expect(avg.totalValue).toBe(560); // 8 x 70
    await b.sell(it.id, 8);
    const issued = (await b.moves(it.id)).filter((m) => m.refType === 'invoice').map((m) => m.value).sort((x, y) => x - y);
    expect(issued).toEqual([-760, -640]);
  });

  it('shows FIFO as a comparison on a weighted-average company without changing its books', async () => {
    const b = await biz('Compare Co');
    const it = await b.item('CMP');
    await b.buy(it.id, 10, 60);
    await b.buy(it.id, 10, 80);
    await b.sell(it.id, 12);
    expect((await b.moves(it.id)).find((m) => m.refType === 'invoice')!.value).toBe(-840);
    const fifo = (await b.api('GET', '/reports/stock-valuation?method=fifo')).body;
    expect(fifo.comparison).toBe(true);
    expect(fifo.totalValue).toBe(640);
    expect((await b.api('GET', '/reports/stock-valuation')).body.totalValue).toBe(560);
  });
});

describe('alternate units', () => {
  it('sets units and rejects clashes', async () => {
    const b = await biz('Unit Co');
    const it = await b.item('PEN');
    const ok = await b.api('PUT', `/items/${it.id}/units`, { units: [{ name: 'box', factor: 12 }], defaultSaleUnit: 'box', defaultPurchaseUnit: 'box' });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body.units[0].factor).toBe(12);
    expect(ok.body.defaultSaleUnit).toBe('box');
    expect((await b.api('PUT', `/items/${it.id}/units`, { units: [{ name: 'NOS', factor: 2 }] })).status).toBe(400);
    expect((await b.api('PUT', `/items/${it.id}/units`, { units: [{ name: 'box', factor: 12 }], defaultSaleUnit: 'crate' })).status).toBe(400);
  });

  it('converts quantity and rate on invoices, purchases, sales orders and quotations', async () => {
    const b = await biz('Convert Co');
    const it = await b.item('BOX');
    await b.api('PUT', `/items/${it.id}/units`, { units: [{ name: 'box', factor: 12 }] });

    const bill = await b.buy(it.id, 2, 600, { unit: 'box' });
    expect(bill.lines[0]).toMatchObject({ qty: 24, rate: 50, enteredUnit: 'box', enteredQty: 2, enteredRate: 600 });
    expect((await b.moves(it.id))[0]!.qty).toBe(24);

    const inv = await b.sell(it.id, 1, { unit: 'box', rate: 1200 });
    expect(inv.lines[0]).toMatchObject({ qty: 12, rate: 100, enteredUnit: 'box', enteredQty: 1, enteredRate: 1200 });
    expect(inv.subtotal).toBe(1200);

    const so = await b.api('POST', '/sales-orders', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: it.id, qty: 1, unit: 'box', rate: 1200 }] });
    expect(so.status, JSON.stringify(so.body)).toBe(201);
    const soGet = (await b.api('GET', `/sales-orders/${so.body.id}`)).body;
    expect(soGet.lines[0]).toMatchObject({ qtyOrdered: 12, rate: 100, enteredUnit: 'box', enteredQty: 1 });

    const q = await b.api('POST', '/quotations', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: it.id, qty: 3, unit: 'box', rate: 1200 }] });
    expect(q.status, JSON.stringify(q.body)).toBe(201);
    const qGet = (await b.api('GET', `/quotations/${q.body.id}`)).body;
    expect(qGet.lines[0]).toMatchObject({ qty: 36, rate: 100, enteredUnit: 'box', enteredQty: 3 });
    expect(qGet.subtotal).toBe(3600);

    const plain = await b.sell(it.id, 1);
    expect(plain.lines[0]).toMatchObject({ qty: 1, enteredUnit: null });
    const bad = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: it.id, qty: 1, unit: 'crate' }] });
    expect(bad.status).toBe(400);
  });

  it('keeps the total exact when the converted rate has more than two decimals', async () => {
    const b = await biz('Odd Co');
    const it = await b.item('ODD');
    await b.api('PUT', `/items/${it.id}/units`, { units: [{ name: 'box', factor: 12 }] });
    const bill = await b.buy(it.id, 1, 100, { unit: 'box' });
    expect(bill.lines[0]).toMatchObject({ qty: 12, rate: 8.3333 });
    expect(bill.subtotal).toBe(100);
  });
});

describe('ageing and slow-moving', () => {
  it('buckets the receipt layers that are left', async () => {
    const b = await biz('Age Co');
    const it = await b.item('AGE');
    const old = await b.buy(it.id, 10, 10);
    const mid = await b.buy(it.id, 5, 20);
    await b.buy(it.id, 3, 30);
    const c = await owner();
    try {
      await backdate(c, old.id, 200);
      await backdate(c, mid.id, 45);
    } finally { await c.end(); }
    await b.sell(it.id, 4);
    const rep = (await b.api('GET', '/reports/stock-ageing')).body;
    expect(rep.buckets).toEqual(['0-30', '31-60', '61-90', '91-180', '180+']);
    const row = rep.rows.find((r: { itemId: string }) => r.itemId === it.id);
    expect(row.buckets.map((x: { qty: number }) => x.qty)).toEqual([3, 5, 0, 0, 6]);
    expect(row.buckets[4].value).toBe(60);
    expect(row.buckets[1].value).toBe(100);
    expect(row.value).toBe(60 + 100 + 90);
    expect(rep.totals.qty).toBe(14);
  });

  it('lists non-moving and slow-moving items', async () => {
    const b = await biz('Slow Co');
    const idle = await b.item('IDLE');
    const slow = await b.item('SLOW');
    const fast = await b.item('FAST');
    const stale = await b.item('STALE');
    for (const i of [idle, slow, fast, stale]) await b.buy(i.id, 10, 10);
    await b.sell(slow.id, 1);
    await b.sell(fast.id, 9);
    const old = await b.sell(stale.id, 1);
    const c = await owner();
    try { await backdate(c, old.id, 200); } finally { await c.end(); }
    const non = (await b.api('GET', '/reports/stock-movement?mode=non_moving&days=90')).body.rows.map((r: { itemId: string }) => r.itemId);
    expect(non).toContain(idle.id);
    expect(non).toContain(stale.id);
    expect(non).not.toContain(slow.id);
    expect(non).not.toContain(fast.id);
    const slowRows = (await b.api('GET', '/reports/stock-movement?mode=slow_moving&days=90&coverDays=180')).body.rows;
    expect(slowRows.map((r: { itemId: string }) => r.itemId)).toEqual([slow.id]);
    expect(slowRows[0].coverDays).toBe(810);
  });
});
