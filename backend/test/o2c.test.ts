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

async function biz(name = 'O2C Co') {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, signup.body.accessToken, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const userAs = async (n: string, roleName: string) => {
    const email = uniqueEmail(n.toLowerCase());
    const created = await api('POST', '/users', { name: n, email, password: PASSWORD, roleId: roles.find((r) => r.name === roleName)!.id });
    expect(created.status).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    return client(env.app, login.body.accessToken, companyId);
  };
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const customer = (await api('POST', '/parties', { type: 'customer', name: 'Customer One', stateCode: '24' })).body;
  const mk = async (sku: string, barcode: string, price = 100) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, barcode, hsnCode: '6907', unit: 'nos', gstRate: 18, salePrice: price, purchasePrice: 60, trackStock: true });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string };
  };
  const a = await mk('AAA', '890100000001');
  const bItem = await mk('BBB', '890100000002', 200);
  const stock = async (itemId: string, qty: number) => {
    const r = await api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId, qty, rate: 60 }] });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
  };
  await stock(a.id, 10);
  await stock(bItem.id, 10);
  const keeper = await userAs('Kiran', 'Store Keeper');
  const sales = await userAs('Sana', 'Sales Executive');
  const accountant = await userAs('Anita', 'Accountant');
  return { api, wh, customer, a, b: bItem, keeper, sales, accountant, stock };
}
type Biz = Awaited<ReturnType<typeof biz>>;

let n = 0;
const sid = () => `scan-${Date.now()}-${n++}`;
let key = 0;
const idem = () => `key-${Date.now()}-${key++}`;

async function order(b: Biz, lines: { itemId: string; qty: number; allowBackorder?: boolean }[], confirm = true) {
  const r = await b.api('POST', '/sales-orders', { locationId: b.wh.id, partyId: b.customer.id, lines });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  if (confirm) {
    const c = await b.api('POST', `/sales-orders/${r.body.id}/confirm`);
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    return c.body;
  }
  return r.body;
}

async function pickAll(b: Biz, ord: { id: string }, scans: { code: string; qty: number }[]) {
  const pl = await b.keeper('POST', '/pick-lists', { locationId: b.wh.id, orderIds: [ord.id] });
  expect(pl.status, JSON.stringify(pl.body)).toBe(201);
  for (const s of scans) {
    const r = await b.keeper('POST', `/pick-lists/${pl.body.id}/scan`, { scanId: sid(), code: s.code, qty: s.qty });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
  }
  return pl.body.id as string;
}

const onHand = async (b: Biz, itemId: string) => {
  const r = await b.api('GET', `/stock?locationId=${b.wh.id}&limit=200`);
  const row = (r.body.data as { itemId: string; qty?: number; onHand?: number; reservedQty: number; availableQty: number }[]).find((x) => x.itemId === itemId);
  return row!;
};

describe('order to cash', () => {
  it('runs the happy path from order to closed return', async () => {
    const b = await biz();
    const o = await order(b, [{ itemId: b.a.id, qty: 3 }, { itemId: b.b.id, qty: 2 }]);
    expect(o.status).toBe('confirmed');
    expect((await onHand(b, b.a.id)).reservedQty).toBe(3);
    expect((await onHand(b, b.a.id)).availableQty).toBe(7);

    const listId = await pickAll(b, o, [{ code: '890100000001', qty: 3 }, { code: 'bbb', qty: 2 }]);
    const done = await b.keeper('POST', `/pick-lists/${listId}/complete`);
    expect(done.body.status).toBe('completed');

    const pack = await b.keeper('POST', `/sales-orders/${o.id}/pack`, {});
    expect(pack.status, JSON.stringify(pack.body)).toBe(200);
    expect(pack.body.status).toBe('packed');
    expect(pack.body.packVerified).toBe(true);

    const d = await b.keeper('POST', `/sales-orders/${o.id}/dispatch`, { courier: 'Delhivery', awb: 'AWB1' }, { 'idempotency-key': idem() });
    expect(d.status, JSON.stringify(d.body)).toBe(201);
    expect(d.body.status).toBe('booked');
    expect(d.body.invoice.number).toBeTruthy();
    const after = (await b.api('GET', `/sales-orders/${o.id}`)).body;
    expect(after.status).toBe('dispatched');
    expect((await onHand(b, b.a.id)).reservedQty).toBe(0);

    for (const status of ['in_transit', 'rto_initiated', 'rto_delivered']) {
      const s = await b.keeper('POST', `/shipments/${d.body.id}/status`, { status });
      expect(s.status, JSON.stringify(s.body)).toBe(200);
    }
    const returns = (await b.api('GET', `/sales-returns?orderId=${o.id}`)).body.data;
    expect(returns).toHaveLength(1);
    expect(returns[0]).toMatchObject({ type: 'rto', status: 'requested' });
    const rid = returns[0].id as string;
    const full = (await b.keeper('POST', `/sales-returns/${rid}/receive`, {})).body;
    expect(full.status).toBe('received');
    const insp = await b.keeper('POST', `/sales-returns/${rid}/inspect`, {
      lines: full.lines.map((l: { id: string }, i: number) => ({ lineId: l.id, disposition: i === 0 ? 'restock' : 'damaged' })),
    });
    expect(insp.status, JSON.stringify(insp.body)).toBe(200);
    const closed = await b.keeper('POST', `/sales-returns/${rid}/close`);
    expect(closed.status, JSON.stringify(closed.body)).toBe(200);
    expect(closed.body.status).toBe('closed');
    expect(closed.body.creditNoteId).toBeTruthy();
    // Only the restocked line came back to the shelf; the damaged one did not.
    const restocked = full.lines[0] as { itemId: string; qty: number };
    const damaged = full.lines[1] as { itemId: string; qty: number };
    expect((await onHand(b, restocked.itemId)).availableQty).toBe(10);
    expect((await onHand(b, damaged.itemId)).availableQty).toBe(10 - damaged.qty);
  });

  it('lets only one of two orders reserve the last unit', async () => {
    const b = await biz();
    const mk = () => b.api('POST', '/sales-orders', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.a.id, qty: 6 }] });
    const [o1, o2] = await Promise.all([mk(), mk()]);
    const res = await Promise.all([b.api('POST', `/sales-orders/${o1.body.id}/confirm`), b.api('POST', `/sales-orders/${o2.body.id}/confirm`)]);
    const codes = res.map((r) => r.status).sort();
    expect(codes).toEqual([200, 409]);
    expect(res.find((r) => r.status === 409)!.body.error.code).toBe('INSUFFICIENT_STOCK');
    expect((await onHand(b, b.a.id)).reservedQty).toBe(6);
  });

  it('dispatches once when the same request is repeated', async () => {
    const b = await biz();
    const o = await order(b, [{ itemId: b.a.id, qty: 2 }]);
    await pickAll(b, o, [{ code: 'AAA', qty: 2 }]);
    await b.keeper('POST', `/sales-orders/${o.id}/pack`, {});
    const k = idem();
    const [x, y] = await Promise.all([
      b.keeper('POST', `/sales-orders/${o.id}/dispatch`, {}, { 'idempotency-key': k }),
      b.keeper('POST', `/sales-orders/${o.id}/dispatch`, {}, { 'idempotency-key': k }),
    ]);
    expect([x.status, y.status].filter((s) => s === 201).length).toBeGreaterThanOrEqual(1);
    const again = await b.keeper('POST', `/sales-orders/${o.id}/dispatch`, {}, { 'idempotency-key': idem() });
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('ILLEGAL_TRANSITION');
    const shipments = (await b.api('GET', `/shipments?orderId=${o.id}`)).body.data;
    expect(shipments).toHaveLength(1);
    const invoices = (await b.api('GET', '/invoices?limit=50')).body.data as { number: string }[];
    expect(invoices).toHaveLength(1);
  });

  it('rejects unknown and wrong barcodes, over picks and repeats a scan safely', async () => {
    const b = await biz();
    const o = await order(b, [{ itemId: b.a.id, qty: 2 }]);
    const pl = (await b.keeper('POST', '/pick-lists', { locationId: b.wh.id, orderIds: [o.id] })).body;
    const scan = (body: object) => b.keeper('POST', `/pick-lists/${pl.id}/scan`, body);
    const unknown = await scan({ scanId: sid(), code: 'nope-123' });
    expect(unknown.status).toBe(400);
    expect(unknown.body.error.code).toBe('UNKNOWN_BARCODE');
    const wrong = await scan({ scanId: sid(), code: '890100000002' });
    expect(wrong.status).toBe(400);
    expect(wrong.body.error.code).toBe('WRONG_ITEM');
    const over = await scan({ scanId: sid(), code: 'AAA', qty: 3 });
    expect(over.status).toBe(400);
    expect(over.body.error.code).toBe('OVER_PICK');

    const id = sid();
    const first = await scan({ scanId: id, code: 'AAA' });
    const second = await scan({ scanId: id, code: 'AAA' });
    expect(first.body.duplicate).toBe(false);
    expect(second.body.duplicate).toBe(true);
    const detail = (await b.api('GET', `/pick-lists/${pl.id}`)).body;
    expect(detail.totalPicked).toBe(1);
    const stored = (await b.api('GET', `/sales-orders/${o.id}`)).body;
    expect(stored.lines[0].qtyPicked).toBe(1);

    const packOver = await b.keeper('POST', `/sales-orders/${o.id}/pack-scans`, { scanId: sid(), code: 'AAA', qty: 2 });
    expect(packOver.status).toBe(400);
    expect(packOver.body.error.code).toBe('OVER_PACK');
    const packWrong = await b.keeper('POST', `/sales-orders/${o.id}/pack-scans`, { scanId: sid(), code: '890100000002' });
    expect(packWrong.body.error.code).toBe('WRONG_ITEM');
  });

  it('refuses to dispatch when picked and packed differ', async () => {
    const b = await biz();
    const o = await order(b, [{ itemId: b.a.id, qty: 2 }]);
    await pickAll(b, o, [{ code: 'AAA', qty: 2 }]);
    await b.keeper('POST', `/sales-orders/${o.id}/pack-scans`, { scanId: sid(), code: 'AAA', qty: 1 });
    const d = await b.keeper('POST', `/sales-orders/${o.id}/dispatch`, {}, { 'idempotency-key': idem() });
    expect(d.status).toBe(409);
    expect(d.body.error.code).toBe('PACK_INCOMPLETE');
  });

  it('refuses returns beyond what was sold', async () => {
    const b = await biz();
    const o = await order(b, [{ itemId: b.a.id, qty: 2 }]);
    await pickAll(b, o, [{ code: 'AAA', qty: 2 }]);
    await b.keeper('POST', `/sales-orders/${o.id}/pack`, {});
    const d = await b.keeper('POST', `/sales-orders/${o.id}/dispatch`, {}, { 'idempotency-key': idem() });
    expect(d.status).toBe(201);
    const lineId = (await b.api('GET', `/sales-orders/${o.id}`)).body.lines[0].id as string;
    const ok = await b.keeper('POST', '/sales-returns', { orderId: o.id, reason: 'Customer changed mind', lines: [{ orderLineId: lineId, qty: 1 }] });
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    const bad = await b.keeper('POST', '/sales-returns', { orderId: o.id, reason: 'Customer changed mind', lines: [{ orderLineId: lineId, qty: 2 }] });
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('RETURN_EXCEEDS_SOLD');
    expect(bad.body.error.details).toMatchObject({ lineIndex: 0, returnable: 1 });
  });

  it('releases reservations on cancel and blocks illegal moves', async () => {
    const b = await biz();
    const o = await order(b, [{ itemId: b.a.id, qty: 4 }]);
    expect((await onHand(b, b.a.id)).availableQty).toBe(6);
    const c = await b.api('POST', `/sales-orders/${o.id}/cancel`, { reason: 'Customer cancelled' });
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    expect(c.body.status).toBe('cancelled');
    expect((await onHand(b, b.a.id)).availableQty).toBe(10);
    const again = await b.api('POST', `/sales-orders/${o.id}/confirm`);
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('ILLEGAL_TRANSITION');
    const edit = await b.api('PATCH', `/sales-orders/${o.id}`, { notes: 'x' });
    expect(edit.status).toBe(409);
  });

  it('keeps a plain invoice from taking reserved stock', async () => {
    const b = await biz();
    await order(b, [{ itemId: b.a.id, qty: 8 }]);
    const inv = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.a.id, qty: 3 }] });
    expect(inv.status).toBe(409);
    expect(inv.body.error.code).toBe('INSUFFICIENT_STOCK');
    expect(inv.body.error.details).toMatchObject({ available: 2, reserved: 8, onHand: 10 });
    const ok = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.a.id, qty: 2 }] });
    expect(ok.status).toBe(201);
  });

  it('enforces permissions', async () => {
    const b = await biz();
    const o = await order(b, [{ itemId: b.a.id, qty: 1 }]);
    expect((await b.keeper('POST', '/sales-orders', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.a.id, qty: 1 }] })).status).toBe(403);
    expect((await b.sales('POST', '/pick-lists', { locationId: b.wh.id, orderIds: [o.id] })).status).toBe(403);
    expect((await b.sales('GET', `/sales-orders/${o.id}`)).status).toBe(200);
    expect((await b.accountant('POST', `/sales-orders/${o.id}/cancel`, { reason: 'No reason' })).status).toBe(403);
    expect((await b.sales('POST', '/sales-returns', { invoiceId: o.id, reason: 'abc', lines: [] })).status).toBe(403);
  });

  it('hides another business order', async () => {
    const b = await biz('Alpha Co');
    const other = await biz('Beta Co');
    const o = await order(b, [{ itemId: b.a.id, qty: 1 }]);
    for (const [m, u] of [['GET', `/sales-orders/${o.id}`], ['POST', `/sales-orders/${o.id}/confirm`], ['POST', `/sales-orders/${o.id}/pack`]] as const) {
      expect((await other.api(m, u, {})).status, u).toBe(404);
    }
    expect((await other.api('GET', '/sales-orders')).body.total).toBe(0);
  });
});
