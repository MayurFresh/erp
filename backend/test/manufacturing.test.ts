import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

let keyN = 0;
const key = () => ({ 'idempotency-key': `mfg-test-${Date.now()}-${keyN++}` });

async function plant() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Gujarat Steel Works', name: 'Owner', email: uniqueEmail('mfg'), password: 'Secret@123', stateCode: '24', businessType: 'manufacturer',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const as = async (roleName: string) => {
    const role = roles.find((r) => r.name === roleName);
    expect(role, roleName).toBeTruthy();
    const email = uniqueEmail(roleName.replace(/\W/g, ''));
    expect((await api('POST', '/users', { name: roleName, email, password: 'Secret@123', roleId: role!.id })).status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    return client(env.app, li.body.accessToken, companyId);
  };
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Plant', code: 'PL1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Steel Vendor', stateCode: '24' })).body;
  const customer = (await api('POST', '/parties', { type: 'customer', name: 'Dealer', stateCode: '24' })).body;
  const item = async (name: string, sku: string, purchasePrice = 10) => {
    const r = await api('POST', '/items', { name, sku, hsnCode: '7208', unit: 'nos', gstRate: 18, salePrice: 1000, purchasePrice, trackStock: true });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string };
  };
  const stock = async (itemId: string, qty: number, rate: number) => {
    const r = await api('POST', '/stock/adjustments', { locationId: wh.id, itemId, qty, rate, isOpening: true });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
  };
  const onHand = async (itemId: string) => {
    const r = (await api('GET', `/stock?locationId=${wh.id}`)).body.data as { itemId: string; qty: number; value: number }[];
    const row = r.find((x) => x.itemId === itemId);
    return { qty: row?.qty ?? 0, value: row?.value ?? 0 };
  };
  return { api, as, wh, vendor, customer, item, stock, onHand };
}
type P = Awaited<ReturnType<typeof plant>>;

const mkBom = async (p: P, itemId: string, lines: Record<string, unknown>[], extra: Record<string, unknown> = {}, activate = true) => {
  const r = await p.api('POST', '/manufacturing/boms', { itemId, lines, ...extra });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  if (activate) expect((await p.api('POST', `/manufacturing/boms/${r.body.id}/activate`)).status).toBe(200);
  return r.body as { id: string; version: number };
};

describe('bills of materials', () => {
  it('keeps one active version, locks it, and copies to a new draft', async () => {
    const p = await plant();
    const raw = await p.item('Sheet', 'SH1');
    const fin = await p.item('Frame', 'FR1');
    const v1 = await mkBom(p, fin.id, [{ itemId: raw.id, qty: 2 }]);
    expect(v1.version).toBe(1);
    const v2 = await p.api('POST', '/manufacturing/boms', { itemId: fin.id, lines: [{ itemId: raw.id, qty: 3 }] });
    expect(v2.body.version).toBe(2);
    expect(v2.body.status).toBe('draft');
    const act = await p.api('POST', `/manufacturing/boms/${v2.body.id}/activate`);
    expect(act.body.status).toBe('active');
    const list = (await p.api('GET', `/manufacturing/boms?itemId=${fin.id}`)).body.data as { version: number; status: string }[];
    expect(list.find((b) => b.version === 1)!.status).toBe('archived');
    expect(list.filter((b) => b.status === 'active')).toHaveLength(1);

    const edit = await p.api('PATCH', `/manufacturing/boms/${v2.body.id}`, { outputQty: 2 });
    expect(edit.status).toBe(409);
    expect(edit.body.error.code).toBe('BOM_LOCKED');
    const copy = await p.api('POST', `/manufacturing/boms/${v2.body.id}/copy`);
    expect(copy.status).toBe(201);
    expect(copy.body.version).toBe(3);
    const patched = await p.api('PATCH', `/manufacturing/boms/${copy.body.id}`, { lines: [{ itemId: raw.id, qty: 4, scrapPct: 5 }] });
    expect(patched.body.lines[0].qty).toBe(4);
    expect((await p.api('DELETE', `/manufacturing/boms/${copy.body.id}`)).status).toBe(204);
  });

  it('rejects an item as its own component and a loop between two bills', async () => {
    const p = await plant();
    const a = await p.item('Part A', 'PA');
    const b = await p.item('Part B', 'PB');
    const self = await p.api('POST', '/manufacturing/boms', { itemId: a.id, lines: [{ itemId: a.id, qty: 1 }] });
    expect(self.status).toBe(400);
    await mkBom(p, a.id, [{ itemId: b.id, qty: 1 }]);
    const loop = await p.api('POST', '/manufacturing/boms', { itemId: b.id, lines: [{ itemId: a.id, qty: 1 }] });
    const act = await p.api('POST', `/manufacturing/boms/${loop.body.id}/activate`);
    expect(act.status).toBe(409);
    expect(act.body.error.code).toBe('BOM_CYCLE');
  });

  it('explodes a two-level bill to total raw material with scrap', async () => {
    const p = await plant();
    const steel = await p.item('Steel', 'ST');
    const paint = await p.item('Paint', 'PT');
    const frame = await p.item('Frame', 'FRM');
    const door = await p.item('Door', 'DR');
    await p.stock(steel.id, 100, 10);
    await mkBom(p, frame.id, [{ itemId: steel.id, qty: 5, scrapPct: 10 }], { outputQty: 1 });
    await mkBom(p, door.id, [{ itemId: frame.id, qty: 2 }, { itemId: paint.id, qty: 0.5 }]);
    const ex = (await p.api('GET', `/manufacturing/explode?itemId=${door.id}&qty=10`)).body;
    // 10 doors need 20 frames; 20 frames need 20 x 5 x 1.10 = 110 steel.
    const steelRow = ex.raw.find((r: { itemId: string }) => r.itemId === steel.id);
    expect(steelRow.qty).toBe(110);
    expect(steelRow.onHand).toBe(100);
    expect(ex.raw.find((r: { itemId: string }) => r.itemId === paint.id).qty).toBe(5);
    expect(ex.raw.find((r: { itemId: string }) => r.itemId === frame.id)).toBeUndefined();
    const frameNode = ex.tree.find((n: { itemId: string }) => n.itemId === frame.id);
    expect(frameNode.qty).toBe(20);
    expect(frameNode.children[0].qty).toBe(110);
  });
});

async function line(p: P) {
  const sub = await p.item('Sub assembly', 'SUB');
  const bolt = await p.item('Bolt', 'BLT');
  const fin = await p.item('Cabinet', 'CAB');
  await p.stock(sub.id, 50, 100);
  await p.stock(bolt.id, 200, 20);
  const wc = (await p.api('POST', '/manufacturing/work-centres', { name: 'Assembly', hourlyCost: 120 })).body;
  expect((await p.api('PUT', '/manufacturing/settings', { overheadPct: 10 })).status).toBe(200);
  const bom = await mkBom(p, fin.id, [{ itemId: sub.id, qty: 1 }, { itemId: bolt.id, qty: 3 }],
    { steps: [{ operation: 'Assemble', workCentreId: wc.id, minutesPerUnit: 60 }] });
  return { sub, bolt, fin, wc, bom };
}

describe('production orders', () => {
  it('issues material once, costs output, handles partial output and closes with variance', async () => {
    const p = await plant();
    const { sub, bolt, fin } = await line(p);
    const created = await p.api('POST', '/manufacturing/orders', { itemId: fin.id, qty: 10, locationId: p.wh.id });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const id = created.body.id as string;
    expect(created.body.status).toBe('draft');
    expect(created.body.materials.map((m: { plannedQty: number }) => m.plannedQty).sort((a: number, b: number) => a - b)).toEqual([10, 30]);
    expect((await p.api('POST', `/manufacturing/orders/${id}/issue`, { all: true })).status).toBe(409);

    expect((await p.api('POST', `/manufacturing/orders/${id}/release`)).body.status).toBe('released');
    const issueKey = key();
    const first = await p.api('POST', `/manufacturing/orders/${id}/issue`, { all: true }, issueKey);
    expect(first.status, JSON.stringify(first.body)).toBe(200);
    const again = await p.api('POST', `/manufacturing/orders/${id}/issue`, { all: true }, issueKey);
    expect(again.status).toBe(200);
    expect((await p.onHand(sub.id)).qty).toBe(40);
    expect((await p.onHand(bolt.id)).qty).toBe(170);
    const third = await p.api('POST', `/manufacturing/orders/${id}/issue`, { all: true }, key());
    expect(third.status).toBe(409);
    expect(third.body.error.code).toBe('NOTHING_TO_ISSUE');
    expect(first.body.status).toBe('in_progress');

    // Output 4 of 10: share 0.4 of 1600 material = 640, labour 4 x 120 = 480, overhead 10% of 1120 = 112.
    const o1 = await p.api('POST', `/manufacturing/orders/${id}/output`, { goodQty: 4 });
    expect(o1.status, JSON.stringify(o1.body)).toBe(200);
    expect(o1.body.outputs[0].unitCost).toBe(308);
    expect(o1.body.outputs[0].value).toBe(1232);
    expect(await p.onHand(fin.id)).toEqual({ qty: 4, value: 1232 });

    // Three more bolts are needed; they cost 60 and fall into the next output.
    expect((await p.api('POST', `/manufacturing/orders/${id}/issue`, { lines: [{ itemId: bolt.id, qty: 3 }] })).status).toBe(200);
    const o2 = await p.api('POST', `/manufacturing/orders/${id}/output`, { goodQty: 5, rejectedQty: 1, byProducts: [] });
    expect(o2.status).toBe(200);
    // Material left 960 + 60 = 1020; labour 6 x 120 = 720; overhead 10% of 1740 = 174; total 1914 over 5 good units.
    expect(o2.body.outputs[1].value).toBe(1914);
    expect(o2.body.outputs[1].unitCost).toBe(382.8);
    expect(o2.body.goodQty).toBe(9);
    expect(o2.body.rejectedQty).toBe(1);
    expect(o2.body.cost.total).toBe(3146);
    expect(await p.onHand(fin.id)).toEqual({ qty: 9, value: 3146 });

    const closed = await p.api('POST', `/manufacturing/orders/${id}/close`, { note: 'Done' });
    expect(closed.status).toBe(200);
    expect(closed.body.status).toBe('completed');
    expect(closed.body.variance.yieldPct).toBe(90);
    const bv = closed.body.variance.lines.find((l: { itemId: string }) => l.itemId === bolt.id);
    expect(bv.expectedQty).toBe(30);
    expect(bv.actualQty).toBe(33);
    expect(bv.varianceQty).toBe(3);
    expect(bv.varianceValue).toBe(60);
    expect((await p.api('POST', `/manufacturing/orders/${id}/output`, { goodQty: 1 })).body.error.code).toBe('ORDER_NOT_OPEN');
  });

  it('returns unused material at issue cost and writes off the rest on close', async () => {
    const p = await plant();
    const { sub, bolt, fin } = await line(p);
    const id = (await p.api('POST', '/manufacturing/orders', { itemId: fin.id, qty: 4, locationId: p.wh.id })).body.id as string;
    await p.api('POST', `/manufacturing/orders/${id}/release`);
    await p.api('POST', `/manufacturing/orders/${id}/issue`, { all: true });
    const ret = await p.api('POST', `/manufacturing/orders/${id}/return`, { lines: [{ itemId: sub.id, qty: 1 }] });
    expect(ret.status, JSON.stringify(ret.body)).toBe(200);
    expect((await p.onHand(sub.id)).qty).toBe(47);
    const tooMuch = await p.api('POST', `/manufacturing/orders/${id}/return`, { lines: [{ itemId: bolt.id, qty: 100 }] });
    expect(tooMuch.body.error.code).toBe('RETURN_TOO_MUCH');
    // 2 of 4 planned units made: that output takes half of what is in WIP.
    await p.api('POST', `/manufacturing/orders/${id}/output`, { goodQty: 2 });
    const closed = await p.api('POST', `/manufacturing/orders/${id}/close`, {});
    // Issued 4x100 + 12x20 = 640, returned 100: net 540 in WIP. Output took 540 x 2/4 = 270, 270 written off.
    expect(closed.body.cost.material).toBe(270);
    expect(closed.body.cost.lossValue).toBe(270);
    const wip = (await p.api('GET', '/accounts')).body.data.find((a: { systemKey?: string }) => a.systemKey === 'wip');
    expect(wip.balance).toBe(0);
  });

  it('refuses issue beyond stock, and cancel after activity', async () => {
    const p = await plant();
    const { sub, fin } = await line(p);
    const id = (await p.api('POST', '/manufacturing/orders', { itemId: fin.id, qty: 100, locationId: p.wh.id })).body.id as string;
    await p.api('POST', `/manufacturing/orders/${id}/release`);
    const over = await p.api('POST', `/manufacturing/orders/${id}/issue`, { all: true });
    expect(over.status).toBe(409);
    expect(over.body.error.code).toBe('INSUFFICIENT_STOCK');
    expect((await p.onHand(sub.id)).qty).toBe(50);
    await p.api('POST', `/manufacturing/orders/${id}/issue`, { lines: [{ itemId: sub.id, qty: 5 }] });
    const cancel = await p.api('POST', `/manufacturing/orders/${id}/cancel`, { reason: 'Customer changed mind' });
    expect(cancel.body.error.code).toBe('HAS_ACTIVITY');
    await p.api('POST', `/manufacturing/orders/${id}/return`, { lines: [{ itemId: sub.id, qty: 5 }] });
    expect((await p.api('POST', `/manufacturing/orders/${id}/cancel`, { reason: 'Customer changed mind' })).body.status).toBe('cancelled');
  });

  it('records inspections within the good output', async () => {
    const p = await plant();
    const { fin } = await line(p);
    const id = (await p.api('POST', '/manufacturing/orders', { itemId: fin.id, qty: 2, locationId: p.wh.id })).body.id as string;
    await p.api('POST', `/manufacturing/orders/${id}/release`);
    await p.api('POST', `/manufacturing/orders/${id}/issue`, { all: true });
    await p.api('POST', `/manufacturing/orders/${id}/output`, { goodQty: 2 });
    const ok = await p.api('POST', `/manufacturing/orders/${id}/inspections`, { passQty: 1, reworkQty: 1, rejectQty: 0, note: 'Scratch on door' });
    expect(ok.status).toBe(201);
    expect(ok.body.inspections[0].reworkQty).toBe(1);
    const more = await p.api('POST', `/manufacturing/orders/${id}/inspections`, { passQty: 1, reworkQty: 0, rejectQty: 1, note: 'Extra' });
    expect(more.body.error.code).toBe('INSPECTION_TOO_MUCH');
  });
});

describe('material planning', () => {
  it('works out shortages from sales orders, stock and open purchase orders', async () => {
    const p = await plant();
    const a = await p.item('Raw A', 'RA', 5);
    const b = await p.item('Raw B', 'RB', 7);
    const sub = await p.item('Sub S', 'SS');
    const fin = await p.item('Final F', 'FF');
    await mkBom(p, sub.id, [{ itemId: a.id, qty: 2 }]);
    await mkBom(p, fin.id, [{ itemId: sub.id, qty: 1 }, { itemId: b.id, qty: 3 }]);
    await p.stock(a.id, 15, 5);
    await p.stock(b.id, 20, 7);
    const so = await p.api('POST', '/sales-orders', { locationId: p.wh.id, partyId: p.customer.id, lines: [{ itemId: fin.id, qty: 20, allowBackorder: true }] });
    expect(so.status, JSON.stringify(so.body)).toBe(201);
    expect((await p.api('POST', `/sales-orders/${so.body.id}/confirm`)).status).toBe(200);
    const po = await p.api('POST', '/purchase-orders', { locationId: p.wh.id, partyId: p.vendor.id, lines: [{ itemId: b.id, qty: 10, rate: 7 }] });
    expect(po.status).toBe(201);
    await p.api('POST', `/purchase-orders/${po.body.id}/submit`);
    await p.api('POST', `/purchase-orders/${po.body.id}/send`);

    const mrp = (await p.api('GET', '/manufacturing/mrp')).body;
    // 20 finals need 20 subs (40 of A) and 60 of B.
    const rowA = mrp.shortages.find((r: { itemId: string }) => r.itemId === a.id);
    const rowB = mrp.shortages.find((r: { itemId: string }) => r.itemId === b.id);
    expect(rowA).toMatchObject({ required: 40, onHand: 15, onOrder: 0, shortage: 25 });
    expect(rowB).toMatchObject({ required: 60, onHand: 20, onOrder: 10, shortage: 30 });
    expect(mrp.shortagesCount).toBe(2);
    expect((await p.api('GET', '/manufacturing/home')).body.shortagesCount).toBe(2);

    const raised = await p.api('POST', '/manufacturing/mrp/purchase-order', {
      partyId: p.vendor.id, locationId: p.wh.id, lines: [{ itemId: a.id, qty: 25 }, { itemId: b.id, qty: 30 }],
    });
    expect(raised.status, JSON.stringify(raised.body)).toBe(201);
    expect(raised.body.status).toBe('draft');
  });
});

describe('job work outward', () => {
  it('sends material, receives part back with scrap, and tracks the balance', async () => {
    const p = await plant();
    const raw = await p.item('Casting', 'CST');
    const done = await p.item('Machined casting', 'MCST');
    await p.stock(raw.id, 100, 40);
    const sent = await p.api('POST', '/manufacturing/jobwork', {
      partyId: p.vendor.id, locationId: p.wh.id, process: 'Machining', lines: [{ itemId: raw.id, returnItemId: done.id, qty: 100 }],
    });
    expect(sent.status, JSON.stringify(sent.body)).toBe(201);
    expect(sent.body.number).toMatch(/^JWC\//);
    expect((await p.onHand(raw.id)).qty).toBe(0);
    const id = sent.body.id as string;
    const lineId = sent.body.lines[0].id as string;
    expect((await p.api('POST', `/manufacturing/jobwork/${id}/cancel`, { reason: 'x ok' })).status).toBe(200);
    expect((await p.onHand(raw.id)).qty).toBe(100);

    const s2 = await p.api('POST', '/manufacturing/jobwork', {
      partyId: p.vendor.id, locationId: p.wh.id, process: 'Machining', lines: [{ itemId: raw.id, returnItemId: done.id, qty: 100 }],
    });
    const id2 = s2.body.id as string;
    const l2 = s2.body.lines[0].id as string;
    const r1 = await p.api('POST', `/manufacturing/jobwork/${id2}/receive`, { lines: [{ lineId: l2, qtyReceived: 60, qtyScrap: 10 }] });
    expect(r1.status, JSON.stringify(r1.body)).toBe(200);
    expect(r1.body.status).toBe('partially_returned');
    expect(r1.body.lines[0].qtyPending).toBe(30);
    expect(await p.onHand(done.id)).toEqual({ qty: 60, value: 2400 });
    const over = await p.api('POST', `/manufacturing/jobwork/${id2}/receive`, { lines: [{ lineId: l2, qtyReceived: 31 }] });
    expect(over.body.error.code).toBe('OVER_RECEIPT');
    expect((await p.api('POST', `/manufacturing/jobwork/${id2}/cancel`, { reason: 'too late' })).status).toBe(409);

    const itc = (await p.api('GET', '/manufacturing/jobwork/itc04')).body;
    expect(itc.note).toMatch(/Check before filing/);
    const row = itc.rows.find((r: { item: string }) => r.item === 'Casting');
    expect(row).toMatchObject({ qtySent: 100, qtyReceived: 60, qtyScrap: 10, qtyPending: 30, overdue: false });

    const r2 = await p.api('POST', `/manufacturing/jobwork/${id2}/receive`, { lines: [{ lineId: l2, qtyReceived: 30 }] });
    expect(r2.body.status).toBe('returned');
    expect(await p.onHand(done.id)).toEqual({ qty: 90, value: 3600 });
    expect(lineId).toBeTruthy();
  });
});

describe('permissions', () => {
  it('limits each role to its own work', async () => {
    const p = await plant();
    const { fin, sub } = await line(p);
    const supervisor = await p.as('Production Supervisor');
    const store = await p.as('Store');
    const quality = await p.as('Quality');
    const manager = await p.as('Production Manager');

    expect((await supervisor('POST', '/manufacturing/boms', { itemId: fin.id, lines: [{ itemId: sub.id, qty: 1 }] })).status).toBe(403);
    const made = await supervisor('POST', '/manufacturing/orders', { itemId: fin.id, qty: 3, locationId: p.wh.id });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    const id = made.body.id as string;
    expect((await supervisor('POST', `/manufacturing/orders/${id}/release`)).status).toBe(200);
    expect((await store('POST', `/manufacturing/orders/${id}/output`, { goodQty: 1 })).status).toBe(403);
    expect((await store('POST', `/manufacturing/orders/${id}/issue`, { all: true })).status).toBe(200);
    expect((await store('GET', '/manufacturing/orders')).status).toBe(200);
    expect((await supervisor('POST', `/manufacturing/orders/${id}/output`, { goodQty: 3 })).status).toBe(200);
    expect((await supervisor('POST', `/manufacturing/orders/${id}/close`, {})).status).toBe(403);
    expect((await quality('POST', `/manufacturing/orders/${id}/output`, { goodQty: 1 })).status).toBe(403);
    expect((await quality('POST', `/manufacturing/orders/${id}/inspections`, { passQty: 3, reworkQty: 0, rejectQty: 0, note: 'All good' })).status).toBe(201);
    expect((await store('POST', `/manufacturing/orders/${id}/inspections`, { passQty: 1, reworkQty: 0, rejectQty: 0, note: 'x' })).status).toBe(403);
    expect((await quality('PUT', '/manufacturing/settings', { overheadPct: 5 })).status).toBe(403);
    expect((await manager('POST', `/manufacturing/orders/${id}/close`, {})).status).toBe(200);
    const view = await quality('GET', `/manufacturing/orders/${id}`);
    expect(view.body.cost).toBeUndefined();
    const mv = await manager('GET', `/manufacturing/orders/${id}`);
    expect(mv.body.cost.total).toBeGreaterThan(0);
  });
});
