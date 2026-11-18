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


describe('stock age across a transfer', () => {
  it('keeps the source layer dates at the destination and in FIFO cost', async () => {
    const b = await biz('Transfer Age Co');
    const it = await b.item('AGE');
    const old = await b.buy(it.id, 10, 60);
    const fresh = await b.buy(it.id, 5, 80);
    const c = await owner();
    try {
      await backdate(c, old.id, 45);
      await backdate(c, fresh.id, 5);
    } finally { await c.end(); }
    const shopRes = await b.api('POST', '/locations', { type: 'warehouse', name: 'Shop', code: 'SH1' });
    expect(shopRes.status, JSON.stringify(shopRes.body)).toBe(201);
    const shop = shopRes.body;
    const tr = await b.api('POST', '/transfers', { fromLocationId: b.wh.id, toLocationId: shop.id, lines: [{ itemId: it.id, qty: 12 }] });
    expect(tr.status, JSON.stringify(tr.body)).toBe(201);
    expect((await b.api('POST', `/transfers/${tr.body.id}/receive`)).status).toBe(200);
    const rep = (await b.api('GET', `/reports/stock-ageing?locationId=${shop.id}`)).body;
    const row = rep.rows.find((r: { itemId: string }) => r.itemId === it.id);
    // 10 from the 45-day layer, 2 from the 5-day layer: the transfer does not make it new stock.
    expect(row.buckets.map((x: { qty: number }) => x.qty)).toEqual([2, 10, 0, 0, 0]);
    expect(row.qty).toBe(12);
    const left = (await b.api('GET', `/reports/stock-ageing?locationId=${b.wh.id}`)).body.rows.find((r: { itemId: string }) => r.itemId === it.id);
    expect(left.buckets.map((x: { qty: number }) => x.qty)).toEqual([3, 0, 0, 0, 0]);
    const ins = (await b.moves(it.id)).filter((m) => m.refType === 'transfer_in');
    expect(ins.reduce((s, m) => s + m.qty, 0)).toBe(12);
    expect(ins.reduce((s, m) => s + m.value, 0)).toBeCloseTo(800, 2); // average cost: 12 x 66.67
  });

  it('keeps FIFO cost right after a transfer', async () => {
    const b = await biz('Transfer Fifo Co');
    const it = await b.item('TF');
    const old = await b.buy(it.id, 10, 60);
    await b.buy(it.id, 5, 80);
    const c = await owner();
    try { await backdate(c, old.id, 45); } finally { await c.end(); }
    expect((await b.api('PUT', '/stock/valuation-method', { method: 'fifo' })).status).toBe(200);
    const shop = (await b.api('POST', '/locations', { type: 'warehouse', name: 'Shop', code: 'SH2' })).body;
    const tr = await b.api('POST', '/transfers', { fromLocationId: b.wh.id, toLocationId: shop.id, lines: [{ itemId: it.id, qty: 12 }] });
    expect(tr.status, JSON.stringify(tr.body)).toBe(201);
    await b.api('POST', `/transfers/${tr.body.id}/receive`);
    const sale = await b.api('POST', '/invoices', { locationId: shop.id, partyId: b.customer.id, lines: [{ itemId: it.id, qty: 11 }] });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    const out = (await b.moves(it.id)).find((m) => m.refType === 'invoice')!;
    expect(out.value).toBe(-(10 * 60 + 1 * 80));
  });

});

describe('MRP on items', () => {
  it('saves, returns and clears the MRP', async () => {
    const b = await biz('Mrp Co');
    const it = await b.item('MRP');
    expect((await b.api('GET', `/items/${it.id}`)).body.mrp).toBeNull();
    const up = await b.api('PATCH', `/items/${it.id}`, { mrp: 129.5 });
    expect(up.status, JSON.stringify(up.body)).toBe(200);
    expect(up.body.mrp).toBe(129.5);
    const made = await b.api('POST', '/items', { name: 'With MRP', sku: 'M2', unit: 'nos', gstRate: 18, salePrice: 90, mrp: 100, trackStock: true });
    expect(made.body.mrp).toBe(100);
    expect((await b.api('PATCH', `/items/${it.id}`, { mrp: null })).body.mrp).toBeNull();
  });
});

describe('quotation convert keeps the entered unit', () => {
  it('copies unit and quantity onto the invoice and the sales order', async () => {
    const b = await biz('Quote Unit Co');
    const it = await b.item('QU');
    await b.buy(it.id, 100, 50);
    await b.api('PUT', `/items/${it.id}/units`, { units: [{ name: 'box', factor: 12 }] });
    for (const to of ['invoice', 'sales_order']) {
      const q = await b.api('POST', '/quotations', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: it.id, qty: 2, rate: 1200, unit: 'box' }] });
      expect(q.status, JSON.stringify(q.body)).toBe(201);
      expect(q.body.lines[0].qty).toBe(24);
      const conv = await b.api('POST', `/quotations/${q.body.id}/convert`, { to });
      expect(conv.status, JSON.stringify(conv.body)).toBeLessThan(300);
      const doc = to === 'invoice'
        ? (await b.api('GET', `/invoices/${conv.body.invoiceId ?? conv.body.invoice?.id}`)).body
        : (await b.api('GET', `/sales-orders/${conv.body.salesOrderId ?? conv.body.salesOrder?.id}`)).body;
      expect(doc.lines[0].qty ?? doc.lines[0].qtyOrdered).toBe(24);
      expect(doc.lines[0].enteredUnit).toBe('box');
      expect(doc.lines[0].enteredQty).toBe(2);
    }
  });
});

describe('purchase order lines in an alternate unit', () => {
  it('stores base quantity and the entered unit', async () => {
    const b = await biz('Po Unit Co');
    const it = await b.item('POU');
    await b.api('PUT', `/items/${it.id}/units`, { units: [{ name: 'box', factor: 12 }] });
    const r = await b.api('POST', '/purchase-orders', { locationId: b.wh.id, partyId: b.vendor.id, lines: [{ itemId: it.id, qty: 3, rate: 600, unit: 'box' }] });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const l = r.body.lines[0];
    expect(l.qty).toBe(36);
    expect(l.rate).toBe(50);
    expect(l.enteredUnit).toBe('box');
    expect(l.enteredQty).toBe(3);
    expect(l.enteredRate).toBe(600);
  });
});

describe('previews return the entered unit', () => {
  it('invoice and purchase order previews', async () => {
    const b = await biz('Preview Unit Co');
    const it = await b.item('PRV');
    await b.api('PUT', `/items/${it.id}/units`, { units: [{ name: 'box', factor: 12 }] });
    const line = { itemId: it.id, qty: 2, rate: 600, unit: 'box' };
    const inv = await b.api('POST', '/invoices/preview', { locationId: b.wh.id, partyId: b.customer.id, lines: [line] });
    expect(inv.status, JSON.stringify(inv.body)).toBe(200);
    expect(inv.body.lines[0]).toMatchObject({ qty: 24, enteredUnit: 'box', enteredQty: 2, enteredRate: 600 });
    const po = await b.api('POST', '/purchase-orders/preview', { locationId: b.wh.id, partyId: b.vendor.id, lines: [line] });
    expect(po.status, JSON.stringify(po.body)).toBe(200);
    expect(po.body.lines[0]).toMatchObject({ qty: 24, enteredUnit: 'box', enteredQty: 2 });
  });
});
