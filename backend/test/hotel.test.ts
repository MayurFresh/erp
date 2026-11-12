import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { roomNightGstRate } from '../src/modules/hotel.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const today = () => todayIst();
const day = (n: number) => addDays(todayIst(), n);

async function hotel() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Lake View Inn', name: 'Owner', email: uniqueEmail('ht'), password: 'Secret@123', stateCode: '24', businessType: 'hotel',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  await api('POST', '/locations', { type: 'store', name: 'Main' });
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
  const mk = async (path: string, body: object) => { const r = await api('POST', path, body); expect(r.status, JSON.stringify(r.body)).toBe(201); return r.body; };
  const economy = await mk('/hotel/room-types', { name: 'Economy', baseTariff: 900, baseOccupancy: 2, maxOccupancy: 3, extraPersonCharge: 300 });
  const deluxe = await mk('/hotel/room-types', { name: 'Deluxe', baseTariff: 2500, baseOccupancy: 2, maxOccupancy: 3, extraPersonCharge: 500 });
  const suite = await mk('/hotel/room-types', { name: 'Suite', baseTariff: 9000, baseOccupancy: 2, maxOccupancy: 4, extraPersonCharge: 800 });
  const r001 = await mk('/hotel/rooms', { roomTypeId: economy.id, number: '001', floor: 'G' });
  const r101 = await mk('/hotel/rooms', { roomTypeId: deluxe.id, number: '101', floor: '1' });
  const r102 = await mk('/hotel/rooms', { roomTypeId: deluxe.id, number: '102', floor: '1' });
  const r201 = await mk('/hotel/rooms', { roomTypeId: suite.id, number: '201', floor: '2' });
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; subtype: string }[];
  const cash = accounts.find((a) => a.subtype === 'cash')!.id;
  return { api, as, mk, companyId, economy, deluxe, suite, r001, r101, r102, r201, cash };
}
type H = Awaited<ReturnType<typeof hotel>>;

const guest = (over: Record<string, unknown> = {}) => ({
  name: 'Ravi Shah', phone: '9825012345', address: 'Navrangpura, Ahmedabad', idType: 'aadhaar', idNumber: '1234 5678 9012', ...over,
});
const book = (h: H, rooms: object[], over: Record<string, unknown> = {}) => h.api('POST', '/hotel/reservations', {
  guest: { name: 'Ravi Shah', phone: '9825012345' }, arrival: today(), departure: day(2), rooms, source: 'walk_in', ...over,
});
async function stayIn(h: H, rooms: { typeId: string; roomId: string }[], over: Record<string, unknown> = {}) {
  const r = await book(h, rooms.map((x) => ({ roomTypeId: x.typeId, roomId: x.roomId, adults: 2 })), over);
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  const ci = await h.api('POST', `/hotel/reservations/${r.body.id}/check-in`, {
    rooms: r.body.rooms.map((x: { id: string }) => ({ id: x.id, guest: guest() })),
  });
  expect(ci.status, JSON.stringify(ci.body)).toBe(200);
  return ci.body;
}

describe('hotel tariff slab', () => {
  it('picks 0, 5 and 18 percent at the slab edges', () => {
    expect(roomNightGstRate(900)).toBe(0);
    expect(roomNightGstRate(1000)).toBe(0);
    expect(roomNightGstRate(1001)).toBe(5);
    expect(roomNightGstRate(7500)).toBe(5);
    expect(roomNightGstRate(7501)).toBe(18);
  });
});

describe('hotel booking', () => {
  it('rejects an overlapping booking of a room and counts availability per type', async () => {
    const h = await hotel();
    const a = await book(h, [{ roomTypeId: h.deluxe.id, roomId: h.r101.id, adults: 2 }], { arrival: day(1), departure: day(3) });
    expect(a.status, JSON.stringify(a.body)).toBe(201);
    expect(a.body.number).toMatch(/^RSV\//);
    const clash = await book(h, [{ roomTypeId: h.deluxe.id, roomId: h.r101.id, adults: 1 }], { arrival: day(2), departure: day(4) });
    expect(clash.status).toBe(409);
    expect(clash.body.error?.code ?? clash.body.code).toBe('ROOM_TAKEN');
    // Back to back is fine: the next guest arrives the day the first leaves.
    const next = await book(h, [{ roomTypeId: h.deluxe.id, roomId: h.r101.id, adults: 1 }], { arrival: day(3), departure: day(4) });
    expect(next.status).toBe(201);

    const av = (await h.api('GET', `/hotel/availability?from=${day(1)}&to=${day(4)}`)).body;
    const dlx = av.types.find((t: { name: string }) => t.name === 'Deluxe');
    expect(dlx.total).toBe(2);
    expect(dlx.byDate.map((d: { available: number }) => d.available)).toEqual([1, 1, 1]);
    expect(dlx.byDate.map((d: { booked: number }) => d.booked)).toEqual([1, 1, 1]);

    // By type: one more fits, the second does not.
    const one = await book(h, [{ roomTypeId: h.deluxe.id, adults: 2 }], { arrival: day(1), departure: day(3) });
    expect(one.status).toBe(201);
    const full = await book(h, [{ roomTypeId: h.deluxe.id, adults: 2 }], { arrival: day(2), departure: day(3) });
    expect(full.status).toBe(409);
    expect(full.body.error?.code ?? full.body.code).toBe('NO_AVAILABILITY');
    const tooMany = await book(h, [{ roomTypeId: h.deluxe.id, adults: 3, children: 1 }]);
    expect(tooMany.status).toBe(400);
    expect((await book(h, [{ roomTypeId: h.deluxe.id, adults: 2 }], { arrival: day(-1) })).status).toBe(400);

    // Cancelling frees the nights.
    const cancel = await h.api('POST', `/hotel/reservations/${one.body.id}/cancel`, { reason: 'Guest changed plans' });
    expect(cancel.status).toBe(200);
    expect(cancel.body.status).toBe('cancelled');
    expect((await book(h, [{ roomTypeId: h.deluxe.id, adults: 2 }], { arrival: day(2), departure: day(3) })).status).toBe(201);
  });

  it('keeps tentative bookings, confirms them and records an advance through payments', async () => {
    const h = await hotel();
    const r = await book(h, [{ roomTypeId: h.suite.id, adults: 2 }], {
      arrival: day(5), departure: day(7), status: 'tentative', source: 'ota', sourceName: 'MakeMyTrip',
      advance: { accountId: h.cash, mode: 'cash', amount: 3000 },
    });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(r.body.status).toBe('tentative');
    expect(r.body.advance).toBe(3000);
    expect((await h.api('POST', `/hotel/reservations/${r.body.id}/confirm`)).body.status).toBe('confirmed');
    expect((await h.api('POST', `/hotel/reservations/${r.body.id}/confirm`)).status).toBe(409);
    const receipts = (await h.api('GET', '/payments?kind=receipt')).body.data as { amount: number; unallocated: number }[];
    expect(receipts.some((p) => p.amount === 3000)).toBe(true);
  });
});

describe('hotel stay and check-out', () => {
  it('refunds part of the advance on cancel through a payment', async () => {
    const h = await hotel();
    const r = await book(h, [{ roomTypeId: h.suite.id, adults: 2 }], { advance: { accountId: h.cash, mode: 'cash', amount: 3000 } });
    expect(r.status).toBe(201);
    const over = await h.api('POST', `/hotel/reservations/${r.body.id}/cancel`, { reason: 'Guest changed plans', refund: { accountId: h.cash, mode: 'cash', amount: 3500 } });
    expect(over.status).toBe(400);
    const c = await h.api('POST', `/hotel/reservations/${r.body.id}/cancel`, { reason: 'Guest changed plans', refund: { accountId: h.cash, mode: 'cash', amount: 2000 } });
    expect(c.status, JSON.stringify(c.body)).toBe(200);
    expect(c.body.advanceHeld).toBe(1000);
  });

  it('checks in, posts night charges once per date, bills one invoice, applies the advance and frees the room as dirty', async () => {
    const h = await hotel();
    const r = await book(h, [{ roomTypeId: h.deluxe.id, roomId: h.r101.id, adults: 2 }], { advance: { accountId: h.cash, mode: 'cash', amount: 1000 } });
    expect(r.status).toBe(201);
    const x = r.body.rooms[0].id;

    // A dirty room cannot take a guest.
    await h.api('PATCH', `/hotel/rooms/${h.r101.id}/status`, { status: 'dirty' });
    const notReady = await h.api('POST', `/hotel/reservations/${r.body.id}/check-in`, { rooms: [{ id: x, guest: guest() }] });
    expect(notReady.status).toBe(409);
    expect(notReady.body.error?.code ?? notReady.body.code).toBe('ROOM_NOT_READY');
    await h.api('PATCH', `/hotel/rooms/${h.r101.id}/status`, { status: 'clean' });

    // A foreign guest needs passport and visa details.
    const noVisa = await h.api('POST', `/hotel/reservations/${r.body.id}/check-in`, { rooms: [{ id: x, guest: guest({ nationality: 'British', idType: 'passport', idNumber: 'P123' }) }] });
    expect(noVisa.status).toBe(400);
    const ci = await h.api('POST', `/hotel/reservations/${r.body.id}/check-in`, { rooms: [{ id: x, guest: guest() }] });
    expect(ci.status, JSON.stringify(ci.body)).toBe(200);
    expect(ci.body.status).toBe('checked_in');
    expect(ci.body.rooms[0].guest.idNumber).toBe('1234 5678 9012');

    // The first night was posted at check-in; posting again for the same date adds nothing.
    expect((await h.api('POST', '/hotel/night-charges', { date: today() })).body.posted).toBe(0);
    expect((await h.api('POST', '/hotel/night-charges', {})).body.posted).toBe(0);
    expect((await h.api('POST', '/hotel/night-charges', { date: day(1) })).status).toBe(400);
    const rooms = (await h.api('GET', '/hotel/rooms')).body.data as { number: string; occupied: boolean }[];
    expect(rooms.find((q) => q.number === '101')!.occupied).toBe(true);

    // Extra charge: laundry 200 at 18 percent.
    const ch = await h.api('POST', `/hotel/reservations/${r.body.id}/charges`, { chargeType: 'laundry', description: 'Laundry', rate: 200 });
    expect(ch.status, JSON.stringify(ch.body)).toBe(201);
    const t = ch.body.totals;
    expect(t.subtotal).toBe(2700);
    expect(t.tax).toBe(161);
    expect(t.total).toBe(2861);
    expect(t.paid).toBe(1000);
    expect(t.balance).toBe(1861);

    // Balance due blocks check-out; paying it completes.
    const short = await h.api('POST', `/hotel/reservations/${r.body.id}/check-out`, {});
    expect(short.status).toBe(409);
    expect(short.body.error?.code ?? short.body.code).toBe('BALANCE_DUE');
    expect((await h.api('GET', `/hotel/reservations/${r.body.id}`)).body.status).toBe('checked_in');
    const out = await h.api('POST', `/hotel/reservations/${r.body.id}/check-out`, { payment: { accountId: h.cash, mode: 'upi', amount: 1861 } });
    expect(out.status, JSON.stringify(out.body)).toBe(200);
    expect(out.body.invoice.total).toBe(2861);
    expect(out.body.reservation.status).toBe('checked_out');
    const inv = (await h.api('GET', `/invoices/${out.body.invoice.id}`)).body;
    expect(inv.total).toBe(2861);
    expect(inv.amountPaid).toBe(2861);
    expect(inv.lines).toHaveLength(2);
    const room = (await h.api('GET', '/hotel/rooms')).body.data.find((q: { number: string }) => q.number === '101');
    expect(room.status).toBe('dirty');
    expect(room.occupied).toBe(false);
    expect((await h.api('POST', `/hotel/reservations/${r.body.id}/check-out`, {})).status).toBe(409);
    // The room can be sold again straight away.
    expect((await book(h, [{ roomTypeId: h.deluxe.id, roomId: h.r101.id, adults: 1 }], { arrival: today(), departure: day(1) })).status).toBe(201);
  });

  it('bills each room night at the slab for its own tariff', async () => {
    const h = await hotel();
    const st = await stayIn(h, [
      { typeId: h.economy.id, roomId: h.r001.id }, { typeId: h.deluxe.id, roomId: h.r102.id }, { typeId: h.suite.id, roomId: h.r201.id },
    ], { departure: day(1) });
    const f = (await h.api('GET', `/hotel/reservations/${st.id}/folio`)).body;
    expect(f.lines.map((l: { gstRate: number }) => l.gstRate).sort((a: number, b: number) => a - b)).toEqual([0, 5, 18]);
    const out = await h.api('POST', `/hotel/reservations/${st.id}/check-out`, { payment: { accountId: h.cash, mode: 'cash', amount: 14145 } });
    expect(out.status, JSON.stringify(out.body)).toBe(200);
    expect(out.body.invoice.total).toBe(14145);
    const inv = (await h.api('GET', `/invoices/${out.body.invoice.id}`)).body;
    expect(inv.lines.map((l: { gstRate: number }) => l.gstRate).sort((a: number, b: number) => a - b)).toEqual([0, 5, 18]);
  });

  it('uses the override tariff and adds the extra person charge', async () => {
    const h = await hotel();
    const a = await stayIn(h, [{ typeId: h.deluxe.id, roomId: h.r101.id }], { overrideTariff: 1500, departure: day(1) });
    expect((await h.api('GET', `/hotel/reservations/${a.id}/folio`)).body.lines[0].rate).toBe(1500);
    const r = await book(h, [{ roomTypeId: h.deluxe.id, roomId: h.r102.id, adults: 2, children: 1 }], { departure: day(1) });
    await h.api('POST', `/hotel/reservations/${r.body.id}/check-in`, { rooms: [{ id: r.body.rooms[0].id, guest: guest() }] });
    expect((await h.api('GET', `/hotel/reservations/${r.body.id}/folio`)).body.lines[0].rate).toBe(3000);
  });

  it('backs tax out of the tariff when prices include tax', async () => {
    const h = await hotel();
    expect((await h.api('PATCH', '/hotel/settings', { pricesIncludeTax: true })).body.pricesIncludeTax).toBe(true);
    const st = await stayIn(h, [{ typeId: h.deluxe.id, roomId: h.r101.id }], { departure: day(1) });
    const out = await h.api('POST', `/hotel/reservations/${st.id}/check-out`, { payment: { accountId: h.cash, mode: 'cash', amount: 2500 } });
    expect(out.status, JSON.stringify(out.body)).toBe(200);
    expect(out.body.invoice.total).toBe(2500);
  });

  it('lets only managers discount, and the discount reaches the invoice', async () => {
    const h = await hotel();
    const fo = await h.as('Front Office');
    const st = await stayIn(h, [{ typeId: h.deluxe.id, roomId: h.r101.id }], { departure: day(1) });
    expect((await fo('POST', `/hotel/reservations/${st.id}/charges`, { chargeType: 'discount', description: 'Loyalty', rate: 250 })).status).toBe(403);
    const d = await h.api('POST', `/hotel/reservations/${st.id}/charges`, { chargeType: 'discount', description: 'Loyalty', rate: 250 });
    expect(d.status, JSON.stringify(d.body)).toBe(201);
    expect(d.body.totals.discount).toBe(250);
    // 2250 taxable at 5 percent = 2362.50, which rounds to 2363.
    const out = await fo('POST', `/hotel/reservations/${st.id}/check-out`, { payment: { accountId: h.cash, mode: 'cash', amount: 2363 } });
    expect(out.status, JSON.stringify(out.body)).toBe(200);
    expect(out.body.invoice.total).toBe(2363);
  });
});

describe('hotel housekeeping and permissions', () => {
  it('walks a room dirty to clean to inspected and guards the order', async () => {
    const h = await hotel();
    const hk = await h.as('Housekeeping');
    const id = h.r101.id;
    expect((await hk('PATCH', `/hotel/rooms/${id}/status`, { status: 'dirty' })).body.status).toBe('dirty');
    expect((await hk('PATCH', `/hotel/rooms/${id}/status`, { status: 'inspected' })).status).toBe(409);
    expect((await hk('PATCH', `/hotel/rooms/${id}/status`, { status: 'clean' })).body.status).toBe('clean');
    expect((await hk('PATCH', `/hotel/rooms/${id}/status`, { status: 'inspected' })).body.status).toBe('inspected');
    expect((await hk('PATCH', `/hotel/rooms/${id}/status`, { status: 'out_of_order' })).status).toBe(400);
    const ooo = await hk('PATCH', `/hotel/rooms/${id}/status`, { status: 'out_of_order', reason: 'Leaking tap' });
    expect(ooo.body.status).toBe('out_of_order');
    expect(ooo.body.statusReason).toBe('Leaking tap');
    expect((await hk('PATCH', `/hotel/rooms/${id}/status`, { status: 'clean' })).status).toBe(409);
    expect((await hk('PATCH', `/hotel/rooms/${id}/status`, { status: 'dirty' })).body.status).toBe('dirty');
    // Out of order rooms are not sellable.
    await hk('PATCH', `/hotel/rooms/${h.r102.id}/status`, { status: 'out_of_order', reason: 'Painting' });
    const av = (await h.api('GET', `/hotel/availability?from=${day(1)}&to=${day(2)}`)).body;
    expect(av.types.find((t: { name: string }) => t.name === 'Deluxe').total).toBe(1);
  });

  it('denies each role what it should not do', async () => {
    const h = await hotel();
    const hk = await h.as('Housekeeping');
    const fo = await h.as('Front Office');
    const acc = await h.as('Accounts');
    expect((await hk('GET', '/hotel/rooms')).status).toBe(200);
    expect((await hk('POST', '/hotel/reservations', {})).status).toBe(403);
    expect((await hk('POST', '/hotel/room-types', { name: 'X', baseTariff: 1 })).status).toBe(403);
    expect((await fo('POST', '/hotel/room-types', { name: 'X', baseTariff: 1 })).status).toBe(403);
    expect((await fo('PATCH', `/hotel/rooms/${h.r101.id}/status`, { status: 'dirty' })).status).toBe(403);
    expect((await fo('PATCH', '/hotel/settings', { pricesIncludeTax: true })).status).toBe(403);
    expect((await acc('GET', '/hotel/reports/occupancy?from=' + today() + '&to=' + today())).status).toBe(200);
    expect((await acc('POST', '/hotel/night-charges', {})).status).toBe(403);
    const r = await fo('POST', '/hotel/reservations', {
      guest: { name: 'Mina', phone: '9800000000' }, arrival: day(1), departure: day(2), rooms: [{ roomTypeId: h.suite.id, adults: 2 }],
    });
    expect(r.status).toBe(201);
    const nobody = client(env.app);
    expect((await nobody('GET', '/hotel/rooms')).status).toBe(401);
  });
});

describe('hotel board and reports', () => {
  it('shows today, the room board, occupancy and the guest register', async () => {
    const h = await hotel();
    await book(h, [{ roomTypeId: h.suite.id, adults: 2 }], { guest: { name: 'Arrival Guest', phone: '9800011111' }, departure: day(1) });
    const st = await stayIn(h, [{ typeId: h.deluxe.id, roomId: h.r101.id }], { guest: { name: 'Inhouse Guest', phone: '9800022222' } });
    const t = (await h.api('GET', '/hotel/today')).body;
    expect(t.arrivals).toHaveLength(1);
    expect(t.inHouse).toHaveLength(1);
    expect(t.occupied).toBe(1);
    expect(t.totalRooms).toBe(4);
    const board = (await h.api('GET', '/hotel/board?days=14')).body;
    expect(board.dates).toHaveLength(14);
    const row = board.rooms.find((q: { number: string }) => q.number === '101');
    expect(row.stays[0].reservationId).toBe(st.id);
    expect(board.unassigned).toHaveLength(1);

    const rep = (await h.api('GET', `/hotel/reports/occupancy?from=${today()}&to=${today()}`)).body;
    expect(rep.rows[0]).toMatchObject({ available: 4, sold: 1, revenue: 2500, occupancyPct: 25, adr: 2500, revpar: 625 });
    const reg = (await h.api('GET', `/hotel/reports/guest-register?from=${today()}&to=${today()}`)).body.data;
    expect(reg).toHaveLength(1);
    expect(reg[0]).toMatchObject({ room: '101', name: 'Ravi Shah', idType: 'aadhaar', nationality: 'Indian' });
  });
});
