import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function restaurant() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Spice Route', name: 'Owner', email: uniqueEmail('rs'), password: 'Secret@123', stateCode: '24', businessType: 'restaurant',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const as = async (roleName: string) => {
    const email = uniqueEmail(roleName.replace(/\W/g, ''));
    const role = roles.find((r) => r.name === roleName)!;
    expect(role, roleName).toBeTruthy();
    const made = await api('POST', '/users', { name: roleName, email, password: 'Secret@123', roleId: role.id });
    expect(made.status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    return client(env.app, li.body.accessToken, companyId);
  };
  const cat = (await api('POST', '/restaurant/categories', { name: 'Mains', sortOrder: 1 })).body;
  const mk = async (name: string, salePrice: number, gstRate: number, station: string, extra: Record<string, unknown> = {}) =>
    (await api('POST', '/restaurant/menu', { newItem: { name, salePrice, gstRate }, categoryId: cat.id, station, diet: 'veg', ...extra })).body;
  const paneer = await mk('Paneer Tikka', 200, 5, 'Tandoor', { shortName: 'PNR TIKKA' });
  const dal = await mk('Dal Tadka', 150, 5, 'Main');
  const cola = await mk('Cola', 100, 18, 'Bar');
  const area = (await api('POST', '/restaurant/areas', { name: 'Ground floor', sortOrder: 1 })).body;
  const t1 = (await api('POST', '/restaurant/tables', { areaId: area.id, name: 'T1', seats: 4, sortOrder: 1 })).body;
  const t2 = (await api('POST', '/restaurant/tables', { areaId: area.id, name: 'T2', seats: 2, sortOrder: 2 })).body;
  const t3 = (await api('POST', '/restaurant/tables', { areaId: area.id, name: 'T3', seats: 6, sortOrder: 3 })).body;
  return { api, as, cat, paneer, dal, cola, area, t1, t2, t3 };
}
type R = Awaited<ReturnType<typeof restaurant>>;

const dineIn = async (r: R, tableId: string, lines: { itemId: string; qty?: number; note?: string }[] = []) => {
  const res = await r.api('POST', '/restaurant/orders', { kind: 'dine_in', tableId, covers: 2, lines });
  expect(res.status).toBe(201);
  return res.body;
};

describe('menu and floor setup', () => {
  it('creates menu entries, floor and shows tables as free', async () => {
    const r = await restaurant();
    expect(r.paneer.station).toBe('Tandoor');
    expect(r.paneer.price).toBe(200);
    expect((await r.api('POST', '/restaurant/categories', { name: 'mains' })).status).toBe(409);
    expect((await r.api('POST', '/restaurant/menu', { itemId: r.paneer.itemId })).status).toBe(409);

    const menu = (await r.api('GET', '/restaurant/menu?q=dal')).body;
    expect(menu.data.map((m: { name: string }) => m.name)).toEqual(['Dal Tadka']);

    const off = await r.api('PATCH', `/restaurant/menu/${r.dal.itemId}`, { available: false });
    expect(off.body.available).toBe(false);
    expect((await r.api('GET', '/restaurant/menu?available=true')).body.total).toBe(2);

    const floor = (await r.api('GET', '/restaurant/floor')).body;
    expect(floor.areas).toHaveLength(1);
    expect(floor.areas[0].tables.map((t: { name: string; status: string }) => [t.name, t.status])).toEqual([['T1', 'free'], ['T2', 'free'], ['T3', 'free']]);
    expect((await r.api('POST', '/restaurant/tables', { areaId: r.area.id, name: 't1' })).status).toBe(409);
    expect((await r.api('DELETE', `/restaurant/areas/${r.area.id}`)).status).toBe(409);

    const set = await r.api('PATCH', '/restaurant/settings', { serviceChargePct: 10 });
    expect(set.body.serviceChargePct).toBe(10);
    expect((await r.api('GET', '/restaurant/settings')).body.stations).toEqual(['Bar', 'Main', 'Tandoor']);
  });

  it('keeps setup to managers and lets captain and kitchen flip availability', async () => {
    const r = await restaurant();
    const captain = await r.as('Captain');
    const kitchen = await r.as('Kitchen');
    expect((await captain('POST', '/restaurant/categories', { name: 'Starters' })).status).toBe(403);
    expect((await captain('PATCH', `/restaurant/menu/${r.dal.itemId}`, { station: 'Bar' })).status).toBe(403);
    expect((await captain('PATCH', `/restaurant/menu/${r.dal.itemId}`, { available: false })).status).toBe(200);
    expect((await kitchen('PATCH', `/restaurant/menu/${r.dal.itemId}`, { available: true })).status).toBe(200);
    expect((await kitchen('POST', '/restaurant/orders', { kind: 'takeaway' })).status).toBe(403);
    expect((await captain('GET', '/restaurant/floor')).status).toBe(200);
    expect((await captain('PATCH', '/restaurant/settings', { serviceChargePct: 5 })).status).toBe(403);
  });
});

describe('orders and kitchen tickets', () => {
  it('sends only the new lines each time, one ticket per station, and is idempotent', async () => {
    const r = await restaurant();
    const o = await dineIn(r, r.t1.id, [{ itemId: r.paneer.itemId, qty: 2, note: 'less spicy' }, { itemId: r.cola.itemId }]);
    expect(o.lines.every((l: { state: string }) => l.state === 'draft')).toBe(true);

    const first = (await r.api('POST', `/restaurant/orders/${o.id}/send-kot`)).body;
    expect(first.newKotIds).toHaveLength(2);
    const kots = first.order.kots as { kotNo: number; station: string }[];
    expect(new Set(kots.map((k) => k.kotNo)).size).toBe(1);
    expect(kots.map((k) => k.station).sort()).toEqual(['Bar', 'Tandoor']);

    // Nothing new: nothing sent.
    expect((await r.api('POST', `/restaurant/orders/${o.id}/send-kot`)).body.newKotIds).toEqual([]);

    const add = await r.api('POST', `/restaurant/orders/${o.id}/lines`, { items: [{ itemId: r.dal.itemId, qty: 1 }] });
    expect(add.status).toBe(201);
    const second = (await r.api('POST', `/restaurant/orders/${o.id}/send-kot`)).body;
    expect(second.newKotIds).toHaveLength(1);
    const all = second.order.kots as { kotNo: number; station: string }[];
    expect(all).toHaveLength(3);
    const newest = all.find((k) => k.station === 'Main')!;
    expect(newest.kotNo).toBe(kots[0]!.kotNo + 1);
    const dalLine = second.order.lines.find((l: { name: string }) => l.name === 'Dal Tadka');
    expect(dalLine.kotNo).toBe(newest.kotNo);

    const board = (await r.api('GET', '/restaurant/kots?station=Tandoor')).body.data;
    expect(board).toHaveLength(1);
    expect(board[0].lines[0]).toMatchObject({ name: 'PNR TIKKA', qty: 2, note: 'less spicy' });
    expect(board[0].tableName).toBe('T1');

    // A second order on the same table is refused; the running amount shows on the floor.
    const busy = await r.api('POST', '/restaurant/orders', { kind: 'dine_in', tableId: r.t1.id });
    expect(busy.status).toBe(409);
    expect(busy.body.error.code).toBe('TABLE_BUSY');
    const floor = (await r.api('GET', '/restaurant/floor')).body;
    const t1 = floor.areas[0].tables[0];
    expect(t1.status).toBe('occupied');
    expect(t1.order.amount).toBeGreaterThan(0);

    // Unavailable items cannot be added.
    await r.api('PATCH', `/restaurant/menu/${r.dal.itemId}`, { available: false });
    const no = await r.api('POST', `/restaurant/orders/${o.id}/lines`, { items: [{ itemId: r.dal.itemId }] });
    expect(no.status).toBe(409);
    expect(no.body.error.code).toBe('ITEM_UNAVAILABLE');
  });

  it('cancels unsent lines freely and sent lines only with a manager and a reason', async () => {
    const r = await restaurant();
    const captain = await r.as('Captain');
    const o = await dineIn(r, r.t1.id, [{ itemId: r.paneer.itemId }, { itemId: r.dal.itemId }]);
    const [a, b] = o.lines;
    const gone = await captain('POST', `/restaurant/orders/${o.id}/lines/${b.id}/cancel`, {});
    expect(gone.status).toBe(200);
    expect(gone.body.lines).toHaveLength(1);

    await r.api('POST', `/restaurant/orders/${o.id}/send-kot`);
    expect((await captain('POST', `/restaurant/orders/${o.id}/lines/${a.id}/cancel`, { reason: 'Guest changed mind' })).status).toBe(403);
    const noReason = await r.api('POST', `/restaurant/orders/${o.id}/lines/${a.id}/cancel`, {});
    expect(noReason.status).toBe(400);
    const ok = await r.api('POST', `/restaurant/orders/${o.id}/lines/${a.id}/cancel`, { reason: 'Guest changed mind' });
    expect(ok.status).toBe(200);
    expect(ok.body.lines[0]).toMatchObject({ state: 'cancelled', cancelReason: 'Guest changed mind' });
    expect(ok.body.bill.total).toBe(0);
    expect(ok.body.kots[0].status).toBe('cancelled');

    const audit = (await r.api('GET', '/audit?entity=restaurant_order_line')).body;
    expect(JSON.stringify(audit)).toContain('Guest changed mind');
  });

  it('moves an order to a free table and merges two tables', async () => {
    const r = await restaurant();
    const a = await dineIn(r, r.t1.id, [{ itemId: r.paneer.itemId }]);
    const b = await dineIn(r, r.t2.id, [{ itemId: r.dal.itemId }]);
    await r.api('POST', `/restaurant/orders/${b.id}/send-kot`);

    const busy = await r.api('POST', `/restaurant/orders/${a.id}/move`, { tableId: r.t2.id });
    expect(busy.status).toBe(409);
    const moved = await r.api('POST', `/restaurant/orders/${a.id}/move`, { tableId: r.t3.id });
    expect(moved.body.tableName).toBe('T3');

    const merged = await r.api('POST', `/restaurant/orders/${a.id}/merge`, { fromOrderId: b.id });
    expect(merged.status).toBe(200);
    expect(merged.body.lines).toHaveLength(2);
    expect(merged.body.kots).toHaveLength(1);
    expect(merged.body.covers).toBe(4);
    const src = (await r.api('GET', `/restaurant/orders/${b.id}`)).body;
    expect(src.status).toBe('cancelled');
    const floor = (await r.api('GET', '/restaurant/floor')).body.areas[0].tables;
    expect(floor.map((t: { status: string }) => t.status)).toEqual(['free', 'free', 'occupied']);
  });

  it('runs takeaway and delivery orders without a table', async () => {
    const r = await restaurant();
    expect((await r.api('POST', '/restaurant/orders', { kind: 'delivery', customerName: 'Anil' })).status).toBe(400);
    const d = await r.api('POST', '/restaurant/orders', { kind: 'delivery', customerName: 'Anil', customerPhone: '9825000000', deliveryAddress: 'Satellite' });
    expect(d.status).toBe(201);
    expect((await r.api('POST', '/restaurant/orders', { kind: 'takeaway', tableId: r.t1.id })).status).toBe(400);
    await r.api('POST', '/restaurant/orders', { kind: 'takeaway', customerName: 'Sana' });
    const list = (await r.api('GET', '/restaurant/orders?status=active&kind=delivery')).body;
    expect(list.data).toHaveLength(1);
    expect(list.data[0].customerPhone).toBe('9825000000');
  });
});

describe('kitchen display', () => {
  it('advances a ticket new, preparing, ready, served and never backwards', async () => {
    const r = await restaurant();
    const kitchen = await r.as('Kitchen');
    const captain = await r.as('Captain');
    const o = await dineIn(r, r.t1.id, [{ itemId: r.dal.itemId }, { itemId: r.dal.itemId, qty: 2 }]);
    const sent = (await r.api('POST', `/restaurant/orders/${o.id}/send-kot`)).body;
    const kotId = sent.newKotIds[0] as string;

    const board = (await kitchen('GET', '/restaurant/kots?station=Main&status=new,preparing')).body.data;
    expect(board).toHaveLength(1);
    expect((await captain('PATCH', `/restaurant/kots/${kotId}/status`, { status: 'preparing' })).status).toBe(403);

    const lineId = board[0].lines[0].id as string;
    const one = await kitchen('PATCH', `/restaurant/kot-lines/${lineId}/status`, { status: 'preparing' });
    expect(one.body.status).toBe('preparing');
    expect((await kitchen('PATCH', `/restaurant/kots/${kotId}/status`, { status: 'ready' })).body.status).toBe('ready');
    expect((await kitchen('PATCH', `/restaurant/kots/${kotId}/status`, { status: 'preparing' })).status).toBe(409);
    const ready = (await r.api('GET', '/restaurant/floor')).body.areas[0].tables[0].order;
    expect(ready.readyLines).toBe(2);

    expect((await captain('PATCH', `/restaurant/kots/${kotId}/status`, { status: 'served' })).body.status).toBe('served');
    expect((await kitchen('GET', '/restaurant/kots?station=Main')).body.data).toHaveLength(0);
    expect((await kitchen('GET', '/restaurant/kots?status=served')).body.data).toHaveLength(1);
  });
});

describe('bill and settlement', () => {
  async function ready(r: R) {
    await r.api('PATCH', '/restaurant/settings', { serviceChargePct: 10 });
    const o = await dineIn(r, r.t1.id, [{ itemId: r.paneer.itemId, qty: 2 }, { itemId: r.cola.itemId }]);
    await r.api('POST', `/restaurant/orders/${o.id}/send-kot`);
    return o.id as string;
  }

  it('freezes the lines once the bill is printed, until a manager reopens it', async () => {
    const r = await restaurant();
    const captain = await r.as('Captain');
    const id = await ready(r);
    const printed = await captain('POST', `/restaurant/orders/${id}/print-bill`, {});
    expect(printed.status).toBe(200);
    expect(printed.body.status).toBe('bill_printed');
    expect(printed.body.bill.serviceCharge).toBe(50);
    expect(printed.body.bill.total).toBe(591);
    expect((await r.api('GET', '/restaurant/floor')).body.areas[0].tables[0].status).toBe('bill_printed');

    const add = await captain('POST', `/restaurant/orders/${id}/lines`, { items: [{ itemId: r.dal.itemId }] });
    expect(add.status).toBe(409);
    expect(add.body.error.code).toBe('BILL_PRINTED');
    expect((await captain('POST', `/restaurant/orders/${id}/reopen`)).status).toBe(403);
    expect((await r.api('POST', `/restaurant/orders/${id}/reopen`)).body.status).toBe('open');
    expect((await captain('POST', `/restaurant/orders/${id}/lines`, { items: [{ itemId: r.dal.itemId }] })).status).toBe(201);
  });

  it('takes a discount as an amount', async () => {
    const r = await restaurant();
    const id = await ready(r);
    expect((await r.api('POST', `/restaurant/orders/${id}/print-bill`, { discountAmount: 50, discountPct: 5, discountReason: 'x' })).status).toBe(400);
    const ok = await r.api('POST', `/restaurant/orders/${id}/print-bill`, { discountAmount: 50, discountReason: 'Regular guest' });
    expect(ok.status).toBe(200);
    expect(ok.body.bill.discount).toBe(50);
    expect(ok.body.discountPct).toBe(10);
  });

  it('needs the manager permission and a reason for a discount', async () => {
    const r = await restaurant();
    const captain = await r.as('Captain');
    const id = await ready(r);
    expect((await captain('POST', `/restaurant/orders/${id}/print-bill`, { discountPct: 10, discountReason: 'Regular' })).status).toBe(403);
    expect((await r.api('POST', `/restaurant/orders/${id}/print-bill`, { discountPct: 10 })).status).toBe(400);
    const ok = await r.api('POST', `/restaurant/orders/${id}/print-bill`, { discountPct: 10, discountReason: 'Regular guest' });
    expect(ok.status).toBe(200);
    expect(ok.body.bill.discount).toBe(50);
    expect(ok.body.bill.total).toBeLessThan(591);
  });

  it('refuses charge to room when no guest is checked in to that room', async () => {
    const r = await restaurant();
    const id = await ready(r);
    const res = await r.api('POST', `/restaurant/orders/${id}/settle`, { chargeToRoom: { roomNumber: '999' } });
    expect(res.status).toBe(409);
    expect(res.body.error?.code ?? res.body.code).toBe('NO_OPEN_FOLIO');
    expect((await r.api('POST', `/restaurant/orders/${id}/settle`, { payments: [] })).status).toBe(400);
  });

  it('charges a settled bill to the guest room: the folio gets the charge and no restaurant invoice is made', async () => {
    const res = await client(env.app)('POST', '/auth/signup', {
      businessName: 'Lake View Inn', name: 'Owner', email: uniqueEmail('rh'), password: 'Secret@123', stateCode: '24', businessType: 'hotel',
    });
    expect(res.status).toBe(201);
    const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
    const api = client(env.app, res.body.accessToken, me.companies[0].id as string);
    await api('POST', '/locations', { type: 'store', name: 'Main' });
    const rt = (await api('POST', '/hotel/room-types', { name: 'Deluxe', baseTariff: 2500, baseOccupancy: 2, maxOccupancy: 3, extraPersonCharge: 500 })).body;
    const room = (await api('POST', '/hotel/rooms', { roomTypeId: rt.id, number: '101', floor: '1' })).body;
    const today = todayIst();
    const bk = await api('POST', '/hotel/reservations', {
      guest: { name: 'Ravi Shah', phone: '9825012345' }, arrival: today, departure: addDays(today, 2), source: 'walk_in',
      rooms: [{ roomTypeId: rt.id, roomId: room.id, adults: 2 }],
    });
    expect(bk.status, JSON.stringify(bk.body)).toBe(201);
    const ci = await api('POST', `/hotel/reservations/${bk.body.id}/check-in`, {
      rooms: bk.body.rooms.map((x: { id: string }) => ({ id: x.id, guest: { name: 'Ravi Shah', phone: '9825012345', address: 'Ahmedabad', idType: 'aadhaar', idNumber: '1234 5678 9012' } })),
    });
    expect(ci.status, JSON.stringify(ci.body)).toBe(200);

    const cat = (await api('POST', '/restaurant/categories', { name: 'Mains', sortOrder: 1 })).body;
    const dal = (await api('POST', '/restaurant/menu', { newItem: { name: 'Dal Tadka', salePrice: 150, gstRate: 5 }, categoryId: cat.id, station: 'Main', diet: 'veg' })).body;
    const area = (await api('POST', '/restaurant/areas', { name: 'Ground', sortOrder: 1 })).body;
    const tbl = (await api('POST', '/restaurant/tables', { areaId: area.id, name: 'T1', seats: 4, sortOrder: 1 })).body;
    const o = (await api('POST', '/restaurant/orders', { kind: 'dine_in', tableId: tbl.id, covers: 2, lines: [{ itemId: dal.itemId, qty: 2 }] })).body;
    expect((await api('POST', `/restaurant/orders/${o.id}/send-kot`)).status).toBeLessThan(300);
    const before = (await api('GET', `/hotel/reservations/${bk.body.id}/folio`)).body.lines.length;

    const done = await api('POST', `/restaurant/orders/${o.id}/settle`, { chargeToRoom: { roomNumber: '101' } });
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    expect(done.body.invoice).toBeNull();
    expect(done.body.receipts).toEqual([]);
    expect(done.body.order.status).toBe('settled');
    expect(done.body.folio).toMatchObject({ reservationId: bk.body.id, amount: 300 });
    const folio = (await api('GET', `/hotel/reservations/${bk.body.id}/folio`)).body;
    expect(folio.lines.length).toBe(before + 1);
    expect(folio.lines.find((l: any) => l.id === done.body.folio.lineId)).toMatchObject({ rate: 300 });
    expect((await api('GET', '/restaurant/floor')).body.areas[0].tables[0].status).toBe('free');
  });

  it('posts a fixed discount to the paisa, split over the lines', async () => {
    const r = await restaurant();
    const o = await dineIn(r, r.t1.id, [{ itemId: r.paneer.itemId, qty: 1 }, { itemId: r.dal.itemId, qty: 1 }, { itemId: r.cola.itemId, qty: 1 }]);
    await r.api('POST', `/restaurant/orders/${o.id}/send-kot`);
    const pb = await r.api('POST', `/restaurant/orders/${o.id}/print-bill`, { discountAmount: 33.33, discountReason: 'Regular guest' });
    expect(pb.status).toBe(200);
    expect(pb.body.bill.discount).toBe(33.33);
    expect(pb.body.bill.discountAmount).toBe(33.33);
    const done = await r.api('POST', `/restaurant/orders/${o.id}/settle`, { payments: [{ mode: 'cash', amount: pb.body.bill.total }] });
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    const inv = (await r.api('GET', `/invoices/${done.body.invoice.id}`)).body;
    expect(inv.subtotal).toBe(450 - 33.33);
    expect(done.body.invoice.total).toBe(pb.body.bill.total);
  });

  it('settles into a tax invoice and split receipts and frees the table', async () => {
    const r = await restaurant();
    const captain = await r.as('Captain');
    const cashier = await r.as('Cashier');
    const id = await ready(r);

    const body = { payments: [{ mode: 'cash', amount: 300 }, { mode: 'upi', amount: 291, reference: 'UPI123' }] };
    expect((await captain('POST', `/restaurant/orders/${id}/settle`, body)).status).toBe(403);
    const short = await cashier('POST', `/restaurant/orders/${id}/settle`, { payments: [{ mode: 'cash', amount: 500 }] });
    expect(short.status).toBe(400);

    const done = await cashier('POST', `/restaurant/orders/${id}/settle`, body);
    expect(done.status).toBe(200);
    expect(done.body.invoice.total).toBe(591);
    expect(done.body.receipts).toHaveLength(2);
    expect(done.body.order.status).toBe('settled');

    const inv = (await r.api('GET', `/invoices/${done.body.invoice.id}`)).body;
    expect(inv.subtotal).toBe(550);
    expect(inv.taxTotal + inv.roundOff).toBeCloseTo(41, 2);
    expect(inv.cgst).toBe(20.25);
    expect(inv.lines).toHaveLength(3);
    expect(inv.settlements).toHaveLength(2);
    expect(inv.partyName).toBe('Walk-in guest');
    expect(inv.amountPaid ?? inv.amount_paid).toBe(591);

    expect((await r.api('GET', '/restaurant/floor')).body.areas[0].tables[0].status).toBe('free');
    expect((await cashier('POST', `/restaurant/orders/${id}/settle`, body)).status).toBe(409);
    // The table can be used again.
    expect((await r.api('POST', '/restaurant/orders', { kind: 'dine_in', tableId: r.t1.id })).status).toBe(201);
  });

  it('refuses to settle lines that were not sent to the kitchen', async () => {
    const r = await restaurant();
    const o = await dineIn(r, r.t2.id, [{ itemId: r.dal.itemId }]);
    const res = await r.api('POST', `/restaurant/orders/${o.id}/settle`, { payments: [{ mode: 'cash', amount: 158 }] });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('UNSENT_LINES');
  });
});
