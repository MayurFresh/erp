import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

const PASSWORD = 'Secret@123';

async function biz() {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Price Co', name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const token = signup.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const email = uniqueEmail('u');
  await api('POST', '/users', { name: 'Clerk', email, password: PASSWORD, roleId: roles.find((r) => r.name === 'Sales Executive')!.id });
  const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
  const sales = client(env.app, login.body.accessToken, companyId);
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1', stateCode: '24' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor', stateCode: '24' })).body;
  const cust = async (name: string) => (await api('POST', '/parties', { type: 'customer', name, stateCode: '24' })).body;
  const mk = async (sku: string, price: number) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, hsnCode: '6907', unit: 'nos', gstRate: 18, salePrice: price, purchasePrice: 50, trackStock: true });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string };
  };
  const a = await mk('A1', 100);
  const b = await mk('B1', 200);
  const buy = await api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId: a.id, qty: 500, rate: 50 }, { itemId: b.id, qty: 500, rate: 50 }] });
  expect(buy.status, JSON.stringify(buy.body)).toBe(201);
  return { api, sales, wh, a, b, cust };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const resolve = async (x: Biz, partyId: string | undefined, itemId: string, qty = 1, date?: string) => {
  const q = new URLSearchParams({ itemId, qty: String(qty), ...(partyId ? { partyId } : {}), ...(date ? { date } : {}) });
  const r = await x.api('GET', `/prices/resolve?${q}`);
  expect(r.status, JSON.stringify(r.body)).toBe(200);
  return r.body;
};

describe('pricing', () => {
  it('uses the item price with no party, list or scheme', async () => {
    const x = await biz();
    const p = await x.cust('Plain');
    const r = await resolve(x, p.id, x.a.id, 3);
    expect(r).toMatchObject({ rate: 100, discountPct: 0, source: 'item', priceListName: null, freeQty: 0, freeItemId: null });
  });

  it('applies a percent list, a fixed list row and quantity slabs', async () => {
    const x = await biz();
    const pct = (await x.api('POST', '/price-lists', { name: 'Dealer', mode: 'percent', adjustPct: -10 })).body;
    const fixed = (await x.api('POST', '/price-lists', { name: 'Wholesale', mode: 'fixed' })).body;
    expect((await x.api('POST', '/price-lists', { name: 'dealer', mode: 'fixed' })).status).toBe(409);
    const put = await x.api('PUT', `/price-lists/${fixed.id}/items`, { items: [
      { itemId: x.a.id, rate: 90 }, { itemId: x.a.id, minQty: 10, rate: 80 }, { itemId: x.a.id, minQty: 50, rate: 70 },
    ] });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    const dealer = await x.cust('Dealer Dan');
    const whole = await x.cust('Wholesale Wes');
    expect((await x.api('PATCH', `/parties/${dealer.id}`, { priceListId: pct.id })).body.priceListId).toBe(pct.id);
    await x.api('PATCH', `/parties/${whole.id}`, { priceListId: fixed.id });

    expect(await resolve(x, dealer.id, x.a.id)).toMatchObject({ rate: 90, source: 'price_list', priceListName: 'Dealer' });
    expect(await resolve(x, dealer.id, x.b.id)).toMatchObject({ rate: 180 });
    expect(await resolve(x, whole.id, x.a.id, 1)).toMatchObject({ rate: 90, priceListName: 'Wholesale' });
    expect(await resolve(x, whole.id, x.a.id, 9.5)).toMatchObject({ rate: 90 });
    expect(await resolve(x, whole.id, x.a.id, 10)).toMatchObject({ rate: 80 });
    expect(await resolve(x, whole.id, x.a.id, 75)).toMatchObject({ rate: 70 });
    // a fixed list does not price items it does not list
    expect(await resolve(x, whole.id, x.b.id)).toMatchObject({ rate: 200, source: 'item', priceListName: null });
    const detail = (await x.api('GET', `/price-lists/${fixed.id}`)).body;
    expect(detail.items).toHaveLength(3);
    expect((await x.api('DELETE', `/price-lists/${fixed.id}`)).status).toBe(409);
  });

  it('honours list validity dates and the active flag', async () => {
    const x = await biz();
    const list = (await x.api('POST', '/price-lists', { name: 'Festival', mode: 'percent', adjustPct: -20, validFrom: '2026-10-01', validTo: '2026-10-31' })).body;
    const p = await x.cust('Festive');
    await x.api('PATCH', `/parties/${p.id}`, { priceListId: list.id });
    expect(await resolve(x, p.id, x.a.id, 1, '2026-10-15')).toMatchObject({ rate: 80, source: 'price_list' });
    expect(await resolve(x, p.id, x.a.id, 1, '2026-11-01')).toMatchObject({ rate: 100, source: 'item' });
    expect(await resolve(x, p.id, x.a.id, 1, '2026-09-30')).toMatchObject({ rate: 100 });
    await x.api('PATCH', `/price-lists/${list.id}`, { isActive: false });
    expect(await resolve(x, p.id, x.a.id, 1, '2026-10-15')).toMatchObject({ rate: 100 });
    expect((await x.api('POST', '/price-lists', { name: 'Bad', mode: 'fixed', validFrom: '2026-10-05', validTo: '2026-10-01' })).status).toBe(400);
  });

  it('lets a customer price override the list, with slabs and dates', async () => {
    const x = await biz();
    const list = (await x.api('POST', '/price-lists', { name: 'Dealer', mode: 'percent', adjustPct: -10 })).body;
    const p = await x.cust('Special');
    await x.api('PATCH', `/parties/${p.id}`, { priceListId: list.id });
    const put = await x.api('PUT', '/customer-prices', { partyId: p.id, items: [
      { itemId: x.a.id, rate: 85 }, { itemId: x.a.id, minQty: 20, rate: 75, validTo: '2026-12-31' },
    ] });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    expect(await resolve(x, p.id, x.a.id, 1, '2026-11-13')).toMatchObject({ rate: 85, source: 'customer', priceListName: null });
    expect(await resolve(x, p.id, x.a.id, 20, '2026-11-13')).toMatchObject({ rate: 75, source: 'customer' });
    // slab expired: the open slab still applies
    expect(await resolve(x, p.id, x.a.id, 20, '2027-01-05')).toMatchObject({ rate: 85 });
    // other item still uses the list
    expect(await resolve(x, p.id, x.b.id)).toMatchObject({ rate: 180, source: 'price_list' });
    const got = (await x.api('GET', `/customer-prices?partyId=${p.id}`)).body.data;
    expect(got).toHaveLength(2);
    expect((await x.api('PUT', '/customer-prices', { partyId: p.id, items: [{ itemId: x.a.id, rate: 1 }, { itemId: x.a.id, rate: 2 }] })).status).toBe(400);
  });

  it('gives free quantity and slab discounts from schemes', async () => {
    const x = await biz();
    const p = await x.cust('Scheme Buyer');
    const free = await x.api('POST', '/price-schemes', { name: 'Buy 10 get 1', kind: 'free_qty', itemId: x.a.id, buyQty: 10, freeQty: 1 });
    expect(free.status, JSON.stringify(free.body)).toBe(201);
    const other = await x.api('POST', '/price-schemes', { name: 'Buy 5 B get 1 A', kind: 'free_qty', itemId: x.b.id, buyQty: 5, freeQty: 1, freeItemId: x.a.id });
    expect(other.status).toBe(201);
    await x.api('POST', '/price-schemes', { name: 'Slab 5', kind: 'slab_discount', itemId: x.a.id, minQty: 20, discountPct: 5 });
    await x.api('POST', '/price-schemes', { name: 'Slab 10', kind: 'slab_discount', itemId: x.a.id, minQty: 50, discountPct: 10, validTo: '2026-12-31' });
    expect(await resolve(x, p.id, x.a.id, 9)).toMatchObject({ freeQty: 0, discountPct: 0, source: 'item' });
    expect(await resolve(x, p.id, x.a.id, 25)).toMatchObject({ freeQty: 2, freeItemId: x.a.id, discountPct: 5, source: 'scheme', rate: 100 });
    expect(await resolve(x, p.id, x.a.id, 50, '2026-11-13')).toMatchObject({ freeQty: 5, discountPct: 10 });
    expect(await resolve(x, p.id, x.a.id, 50, '2027-02-01')).toMatchObject({ discountPct: 5 });
    expect(await resolve(x, p.id, x.b.id, 12)).toMatchObject({ freeQty: 2, freeItemId: x.a.id });
    expect((await x.api('POST', '/price-schemes', { name: 'Broken', kind: 'free_qty', itemId: x.a.id })).status).toBe(400);
    const list = (await x.api('GET', '/price-schemes')).body.data;
    expect(list).toHaveLength(4);
    const patched = await x.api('PATCH', `/price-schemes/${free.body.id}`, { isActive: false });
    expect(patched.body.isActive).toBe(false);
    expect(await resolve(x, p.id, x.a.id, 10)).toMatchObject({ freeQty: 0 });
    expect((await x.api('DELETE', `/price-schemes/${other.body.id}`)).status).toBe(204);
  });

  it('resolves many lines in one call', async () => {
    const x = await biz();
    const list = (await x.api('POST', '/price-lists', { name: 'Dealer', mode: 'percent', adjustPct: 10 })).body;
    const p = await x.cust('Batch');
    await x.api('PATCH', `/parties/${p.id}`, { priceListId: list.id });
    const r = await x.api('POST', '/prices/resolve', { partyId: p.id, lines: [{ itemId: x.a.id, qty: 1 }, { itemId: x.b.id }] });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.data.map((d: { rate: number }) => d.rate)).toEqual([110, 220]);
    expect((await x.api('POST', '/prices/resolve', { lines: [] })).status).toBe(400);
  });

  it('fills a missing rate on invoices, sales orders and quotations; an explicit rate wins', async () => {
    const x = await biz();
    const list = (await x.api('POST', '/price-lists', { name: 'Dealer', mode: 'percent', adjustPct: -10 })).body;
    const p = await x.cust('Dealer Doc');
    await x.api('PATCH', `/parties/${p.id}`, { priceListId: list.id });
    await x.api('PUT', '/customer-prices', { partyId: p.id, items: [{ itemId: x.b.id, rate: 150 }] });
    const lines = [{ itemId: x.a.id, qty: 2 }, { itemId: x.b.id, qty: 1 }, { itemId: x.a.id, qty: 1, rate: 99 }];
    const inv = await x.api('POST', '/invoices', { locationId: x.wh.id, partyId: p.id, lines });
    expect(inv.status, JSON.stringify(inv.body)).toBe(201);
    expect(inv.body.lines.map((l: { rate: number }) => l.rate)).toEqual([90, 150, 99]);
    const so = await x.api('POST', '/sales-orders', { locationId: x.wh.id, partyId: p.id, lines });
    expect(so.status, JSON.stringify(so.body)).toBe(201);
    expect(so.body.lines.map((l: { rate: number }) => l.rate)).toEqual([90, 150, 99]);
    const q = await x.api('POST', '/quotations', { locationId: x.wh.id, partyId: p.id, lines });
    expect(q.status, JSON.stringify(q.body)).toBe(201);
    expect(q.body.lines.map((l: { rate: number }) => l.rate)).toEqual([90, 150, 99]);
  });

  it('limits editing to pricing.manage and reading to items.view', async () => {
    const x = await biz();
    expect((await x.sales('POST', '/price-lists', { name: 'Nope', mode: 'fixed' })).status).toBe(403);
    expect((await x.sales('GET', '/price-lists')).status).toBe(200);
    expect((await x.sales('POST', '/price-schemes', { name: 'No', kind: 'slab_discount', itemId: x.a.id, minQty: 5, discountPct: 5 })).status).toBe(403);
  });
});
