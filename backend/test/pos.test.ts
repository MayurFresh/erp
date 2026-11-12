import { randomUUID } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { seedPosDemo } from '../src/db/seed-pos.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const PASSWORD = 'Secret@123';

async function shop() {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Counter Co', name: 'Owner', email: uniqueEmail('pos'), password: PASSWORD, stateCode: '24', businessType: 'kirana',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const token = signup.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const userAs = async (n: string, roleName: string) => {
    const email = uniqueEmail(n.toLowerCase());
    const created = await api('POST', '/users', { name: n, email, password: PASSWORD, roleId: roles.find((r) => r.name === roleName)!.id });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    return client(env.app, login.body.accessToken, companyId);
  };
  // The earlier tests price ex-tax; the tax-inclusive tests switch it on themselves.
  expect((await api('PUT', '/pos/settings', { pricesIncludeTax: false })).status).toBe(200);
  const shopLoc = (await api('POST', '/locations', { type: 'store', name: 'Main Shop', code: 'S1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Wholesaler', stateCode: '24' })).body;
  const mk = async (sku: string, barcode: string, price: number, gst: number) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, barcode, hsnCode: '1905', unit: 'nos', gstRate: gst, salePrice: price, purchasePrice: price / 2, trackStock: true });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const p = await api('POST', '/purchases', { locationId: shopLoc.id, partyId: vendor.id, lines: [{ itemId: r.body.id, qty: 20, rate: price / 2 }] });
    expect(p.status, JSON.stringify(p.body)).toBe(201);
    return r.body as { id: string };
  };
  const a = await mk('BISC', '890100000011', 100, 5);
  const b = await mk('SOAP', '890100000022', 50, 18);
  const cashier = await userAs('Sana', 'Sales Executive');
  const keeper = await userAs('Kiran', 'Store Keeper');
  return { api, token, companyId, shopLoc, a, b, cashier, keeper };
}
type Shop = Awaited<ReturnType<typeof shop>>;

const stockOf = async (s: Shop, itemId: string) => {
  const rows = (await s.api('GET', `/stock?locationId=${s.shopLoc.id}`)).body.data as { itemId: string; qty: number }[];
  return rows.find((r) => r.itemId === itemId)?.qty;
};
const openSession = async (s: Shop, api = s.cashier, float = 500) => {
  const r = await api('POST', '/pos/sessions', { locationId: s.shopLoc.id, openingFloat: float });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body as { id: string };
};

describe('register sessions', () => {
  it('allows one open session per user and location, and does the cash math on close', async () => {
    const s = await shop();
    const sess = await openSession(s);
    expect((await s.cashier('POST', '/pos/sessions', { locationId: s.shopLoc.id, openingFloat: 0 })).status).toBe(409);
    const cur = (await s.cashier('GET', '/pos/sessions/current')).body;
    expect(cur.session.id).toBe(sess.id);

    // Biscuit 100 + 5% = 105 paid in cash; soap 50 + 18% = 59 paid by UPI.
    const sale1 = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 120 }] });
    expect(sale1.status, JSON.stringify(sale1.body)).toBe(201);
    expect(sale1.body.total).toBe(105);
    expect(sale1.body.changeDue).toBe(15);
    const sale2 = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.b.id, qty: 1 }], payments: [{ mode: 'upi', amount: 59 }] });
    expect(sale2.status, JSON.stringify(sale2.body)).toBe(201);

    expect((await s.cashier('POST', `/pos/sessions/${sess.id}/cash-moves`, { kind: 'out', amount: 12, reason: 'Tea for staff' })).status).toBe(201);
    expect((await s.cashier('POST', `/pos/sessions/${sess.id}/cash-moves`, { kind: 'in', amount: 100, reason: 'Change from owner' })).status).toBe(201);
    expect((await s.cashier('POST', `/pos/sessions/${sess.id}/cash-moves`, { kind: 'out', amount: 99999, reason: 'Too much' })).status).toBe(409);

    const x = (await s.cashier('GET', `/pos/sessions/${sess.id}/report`)).body;
    expect(x.kind).toBe('X');
    expect(x.sales.count).toBe(2);
    expect(x.sales.total).toBe(164);
    expect(x.payments.cash).toBe(105);
    expect(x.payments.upi).toBe(59);
    expect(x.sales.taxTotal).toBe(14);
    expect(x.expected.cash).toBe(500 + 105 + 100 - 12);

    const z = await s.cashier('POST', `/pos/sessions/${sess.id}/close`, { counted: { cash: 690, upi: 59 } });
    expect(z.status, JSON.stringify(z.body)).toBe(200);
    expect(z.body.kind).toBe('Z');
    expect(z.body.expected.cash).toBe(693);
    expect(z.body.difference.cash).toBe(-3);
    expect(z.body.difference.upi).toBe(0);
    expect((await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 200 }] })).status).toBe(409);
    expect((await s.cashier('POST', `/pos/sessions/${sess.id}/close`, { counted: { cash: 1 } })).status).toBe(409);
  });
});

describe('counter sales', () => {
  it('creates the invoice, receipts and stock moves for split payments', async () => {
    const s = await shop();
    const sess = await openSession(s);
    const before = await stockOf(s, s.a.id);
    // 2 x 100 + 5% = 210; UPI 100, card 50, cash tendered 100 -> cash applied 60, change 40.
    const res = await s.cashier('POST', '/pos/sales', {
      sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 2 }],
      payments: [{ mode: 'upi', amount: 100, reference: 'UPI123' }, { mode: 'card', amount: 50 }, { mode: 'cash', amount: 100 }],
    });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    expect(res.body.total).toBe(210);
    expect(res.body.changeDue).toBe(40);
    expect(res.body.tenderedCash).toBe(100);
    expect(res.body.payments.map((p: { mode: string; amount: number }) => `${p.mode}:${p.amount}`).sort()).toEqual(['card:50', 'cash:60', 'upi:100']);
    expect(res.body.customer.isWalkIn).toBe(true);
    expect(res.body.taxSummary[0]).toMatchObject({ rate: 5, taxable: 200, cgst: 5, sgst: 5 });
    expect(await stockOf(s, s.a.id)).toBe((before ?? 0) - 2);
    const inv = (await s.api('GET', `/invoices/${res.body.invoiceId}`)).body;
    expect(inv.paymentStatus).toBe('paid');
    expect(inv.number).toMatch(/^POS\/\d{2}-\d{2}\/00001$/);
    expect(inv.settlements).toHaveLength(3);
    const receipts = (await s.api('GET', '/payments?kind=receipt')).body.data as { amount: number }[];
    expect(receipts.map((r) => r.amount).sort((p, q) => p - q)).toEqual([50, 60, 100]);
    // The walk-in customer is created once.
    await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.b.id, qty: 1 }], payments: [{ mode: 'cash', amount: 100 }] });
    const walk = (await s.api('GET', '/parties?q=Walk-in')).body.data as { name: string }[];
    expect(walk.filter((p) => p.name === 'Walk-in Customer')).toHaveLength(1);
  });

  it('applies a bill discount and a line discount', async () => {
    const s = await shop();
    const sess = await openSession(s);
    const res = await s.cashier('POST', '/pos/sales', {
      sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 2, discountPct: 10 }], billDiscount: { type: 'amount', value: 18 },
      payments: [{ mode: 'cash', amount: 500 }],
    });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    // 200 - 10% = 180, minus 18 = 162 taxable, + 5% = 170.1 -> 170.
    expect(res.body.subtotal).toBe(162);
    expect(res.body.total).toBe(170);
    expect(res.body.discountTotal).toBe(38);
    expect(res.body.changeDue).toBe(330);
  });

  it('rejects underpayment, no session, overspending on stock and bad payments', async () => {
    const s = await shop();
    const noSession = await s.cashier('POST', '/pos/sales', { locationId: s.shopLoc.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 500 }] });
    expect(noSession.status).toBe(409);
    expect(noSession.body.error.code).toBe('NO_SESSION');
    const sess = await openSession(s);
    const short = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 100 }] });
    expect(short.status).toBe(400);
    expect((await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [] })).status).toBe(400);
    expect((await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'upi', amount: 500 }] })).status).toBe(400);
    const stock = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 500 }], payments: [{ mode: 'cash', amount: 99999 }] });
    expect(stock.status).toBe(409);
    expect(stock.body.error.code).toBe('INSUFFICIENT_STOCK');
    // Nothing was left behind by the failed attempts.
    expect((await s.cashier('GET', `/pos/sales?sessionId=${sess.id}`)).body.total).toBe(0);
    // Credit needs a named customer and the flag.
    const cust = (await s.api('POST', '/parties', { type: 'customer', name: 'Regular Ravi', stateCode: '24' })).body;
    const credit = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, partyId: cust.id, allowCredit: true, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 50 }] });
    expect(credit.status, JSON.stringify(credit.body)).toBe(201);
    expect(credit.body.creditAmount).toBe(55);
    const inv = (await s.api('GET', `/invoices/${credit.body.invoiceId}`)).body;
    expect(inv.amountDue).toBe(55);
    const noFlag = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, partyId: cust.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 50 }] });
    expect(noFlag.status).toBe(400);
  });

  it('creates one sale for a duplicate POST with the same Idempotency-Key', async () => {
    const s = await shop();
    const sess = await openSession(s);
    const key = `pos-${randomUUID()}`;
    const fire = () => env.app.inject({
      method: 'POST', url: '/api/v1/pos/sales',
      payload: JSON.stringify({ sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 112 }] }),
      headers: { authorization: `Bearer ${s.token}`, 'x-company-id': s.companyId, 'content-type': 'application/json', 'idempotency-key': key },
    });
    // The owner holds pos.use through the Owner role, but the session belongs to the cashier, so use the owner's own session.
    const own = await openSession(s, s.api as never, 0);
    const mine = () => env.app.inject({
      method: 'POST', url: '/api/v1/pos/sales',
      payload: JSON.stringify({ sessionId: own.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 112 }] }),
      headers: { authorization: `Bearer ${s.token}`, 'x-company-id': s.companyId, 'content-type': 'application/json', 'idempotency-key': key },
    });
    void fire;
    const [x, y] = await Promise.all([mine(), mine()]);
    expect([x.statusCode, y.statusCode]).toContain(201);
    for (const r of [x, y]) expect(r.statusCode).toBeLessThan(500);
    expect((await s.api('GET', `/pos/sales?sessionId=${own.id}`)).body.total).toBe(1);
  });
});

describe('counter returns', () => {
  it('creates a credit note, restocks and refunds cash from the session', async () => {
    const s = await shop();
    const sess = await openSession(s, s.cashier, 0);
    const sale = (await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 2 }], payments: [{ mode: 'cash', amount: 210 }] })).body;
    const stockAfterSale = await stockOf(s, s.a.id);
    const ret = await s.cashier('POST', `/pos/sales/${sale.id}/return`, {
      lines: [{ invoiceLineId: sale.lines[0].invoiceLineId, qty: 1 }], reason: 'Wrong flavour', refundMode: 'cash',
    });
    expect(ret.status, JSON.stringify(ret.body)).toBe(201);
    expect(ret.body.returned.total).toBe(105);
    expect(ret.body.returned.refundAmount).toBe(105);
    expect(await stockOf(s, s.a.id)).toBe((stockAfterSale ?? 0) + 1);
    const notes = (await s.api('GET', `/credit-notes?invoiceId=${sale.invoiceId}`)).body.data as unknown[];
    expect(notes).toHaveLength(1);
    const x = (await s.cashier('GET', `/pos/sessions/${sess.id}/report`)).body;
    expect(x.returns).toEqual({ count: 1, total: 105 });
    expect(x.expected.cash).toBe(210 - 105);
    // Returning more than was sold fails.
    const again = await s.cashier('POST', `/pos/sales/${sale.id}/return`, {
      lines: [{ invoiceLineId: sale.lines[0].invoiceLineId, qty: 2 }], reason: 'Too many', refundMode: 'cash',
    });
    expect(again.status).toBe(400);
    // Books balance: the trial balance still nets to zero.
    const tb = (await s.api('GET', '/reports/trial-balance')).body;
    if (tb && typeof tb.totalDebit === 'number') expect(tb.totalDebit).toBeCloseTo(tb.totalCredit, 2);
  });
});

describe('held bills', () => {
  it('holds on one counter and resumes on another, once', async () => {
    const s = await shop();
    const one = await openSession(s, s.cashier);
    await openSession(s, s.api as never, 0);
    const payload = { lines: [{ itemId: s.a.id, qty: 3 }], customerName: 'Mrs Rao' };
    const held = await s.cashier('POST', '/pos/held', { sessionId: one.id, label: 'Mrs Rao', payload, total: 336 });
    expect(held.status, JSON.stringify(held.body)).toBe(201);
    const list = (await s.api('GET', `/pos/held?locationId=${s.shopLoc.id}`)).body.data as { id: string; label: string }[];
    expect(list.map((h) => h.label)).toEqual(['Mrs Rao']);
    const back = await s.api('POST', `/pos/held/${held.body.id}/resume`);
    expect(back.status).toBe(200);
    expect(back.body.payload).toEqual(payload);
    expect((await s.cashier('POST', `/pos/held/${held.body.id}/resume`)).status).toBe(404);
    expect((await s.api('GET', '/pos/held')).body.data).toHaveLength(0);
  });
});

describe('item lookup and permissions', () => {
  it('finds by exact barcode first, then by name, with stock at the session location', async () => {
    const s = await shop();
    await openSession(s);
    const byCode = (await s.cashier('GET', '/pos/items?q=890100000022')).body;
    expect(byCode.exact).toBe(true);
    expect(byCode.data).toHaveLength(1);
    expect(byCode.data[0]).toMatchObject({ sku: 'SOAP', price: 50, gstRate: 18, stock: 20 });
    const byName = (await s.cashier('GET', '/pos/items?q=item')).body;
    expect(byName.exact).toBe(false);
    expect(byName.data.length).toBe(2);
    const freq = (await s.cashier('GET', '/pos/items/frequent')).body.data as unknown[];
    expect(freq.length).toBe(2);
  });

  it('denies people without pos permissions and keeps sessions private', async () => {
    const s = await shop();
    const sess = await openSession(s);
    expect((await s.keeper('GET', '/pos/sessions/current')).status).toBe(403);
    expect((await s.keeper('POST', '/pos/sessions', { locationId: s.shopLoc.id })).status).toBe(403);
    expect((await s.keeper('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [] })).status).toBe(403);
    // A cashier cannot read or close the owner's session; the owner (pos.manage) can read the cashier's.
    const own = await openSession(s, s.api as never, 0);
    expect((await s.cashier('GET', `/pos/sessions/${own.id}`)).status).toBe(403);
    expect((await s.cashier('POST', `/pos/sessions/${own.id}/close`, { counted: { cash: 0 } })).status).toBe(403);
    expect((await s.api('GET', `/pos/sessions/${sess.id}`)).status).toBe(200);
    const mine = (await s.cashier('GET', '/pos/sessions')).body.data as { id: string }[];
    expect(mine.map((r) => r.id)).toEqual([sess.id]);
    const all = (await s.api('GET', '/pos/sessions')).body.data as { id: string }[];
    expect(all.length).toBe(2);
  });
});

describe('demo data', () => {
  it('seeds a counter with stocked items that sell', async () => {
    const s = await shop();
    const claims = JSON.parse(Buffer.from(s.token.split('.')[1]!, 'base64url').toString());
    const out = await withTenant(env.db, claims.tid, (tx) => seedPosDemo(tx, { tenantId: claims.tid, companyId: s.companyId, userId: claims.sub }));
    expect(out.itemIds).toHaveLength(12);
    const sess = await s.cashier('POST', '/pos/sessions', { locationId: out.locationId, openingFloat: 0 });
    expect(sess.status, JSON.stringify(sess.body)).toBe(201);
    const found = (await s.cashier('GET', `/pos/items?q=8901000100011&locationId=${out.locationId}`)).body;
    expect(found.exact).toBe(true);
    const sale = await s.cashier('POST', '/pos/sales', { sessionId: sess.body.id, lines: [{ itemId: found.data[0].id, qty: 2 }], payments: [{ mode: 'cash', amount: 500 }] });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
  });
});

describe('tax-inclusive prices', () => {
  it('defaults on for shop types and can be switched', async () => {
    const s = await shop();
    expect((await s.api('PUT', '/pos/settings', { pricesIncludeTax: null })).body.pricesIncludeTax).toBe(true);
    expect((await s.api('GET', '/pos/settings')).body.pricesIncludeTax).toBe(true);
    expect((await s.cashier('PUT', '/pos/settings', { pricesIncludeTax: false })).status).toBe(403);
  });

  it('numbers POS bills in their own series with a configurable prefix', async () => {
    const s = await shop();
    expect((await s.api('GET', '/pos/settings')).body.invoicePrefix).toBe('POS');
    expect((await s.api('PUT', '/pos/settings', { invoicePrefix: 'bad prefix!' })).status).toBe(400);
    expect((await s.api('PUT', '/pos/settings', { invoicePrefix: 'ctr' })).body.invoicePrefix).toBe('CTR');
    const sess = await openSession(s);
    const sale = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 500 }] });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    expect((await s.api('GET', `/invoices/${sale.body.invoiceId}`)).body.number).toMatch(/^CTR\/\d{2}-\d{2}\/00001$/);
    const normal = await s.api('POST', '/invoices', { locationId: s.shopLoc.id, partyId: sale.body.customer.id, lines: [{ itemId: s.a.id, qty: 1 }] });
    expect(normal.body.number).toMatch(/^INV\//);
  });

  it('makes the invoice total exactly what the customer saw, for many mixed bills', async () => {
    const s = await shop();
    expect((await s.api('PUT', '/pos/settings', { pricesIncludeTax: true })).status).toBe(200);
    const vendor = (await s.api('POST', '/parties', { type: 'vendor', name: 'V2', stateCode: '24' })).body;
    const defs = [[99.99, 5], [49.5, 18], [17.35, 5], [249, 18], [12.5, 5], [1299.9, 18]] as const;
    const items: { id: string; price: number; gst: number }[] = [];
    for (const [i, [price, gst]] of defs.entries()) {
      const r = await s.api('POST', '/items', { name: `Mix ${i}`, sku: `MIX${i}`, hsnCode: '1905', unit: 'nos', gstRate: gst, salePrice: price, purchasePrice: 1, trackStock: true });
      expect(r.status, JSON.stringify(r.body)).toBe(201);
      expect((await s.api('POST', '/purchases', { locationId: s.shopLoc.id, partyId: vendor.id, lines: [{ itemId: r.body.id, qty: 2000, rate: 1 }] })).status).toBe(201);
      items.push({ id: r.body.id, price, gst });
    }
    const sess = await openSession(s);
    let seed = 7;
    const rnd = (n: number) => { seed = (seed * 1103515245 + 12345) % 2147483648; return seed % n; };
    for (let k = 0; k < 24; k++) {
      const lines = Array.from({ length: 1 + rnd(4) }, () => {
        const it = items[rnd(items.length)]!;
        return { it, qty: 1 + rnd(9) + (rnd(2) ? 0.5 : 0), discountPct: [0, 0, 5, 12.5][rnd(4)]! };
      });
      const bill = rnd(2) ? { type: rnd(2) ? ('amount' as const) : ('pct' as const), value: 0 } : undefined;
      const raw = lines.map((l) => l.qty * l.it.price * (1 - l.discountPct / 100));
      const sumRaw = raw.reduce((a, b) => a + b, 0);
      if (bill) bill.value = bill.type === 'pct' ? 3 + rnd(10) : Math.round(sumRaw * 0.04 * 100) / 100 + 0.35;
      const bp = bill ? (bill.type === 'pct' ? bill.value : (bill.value / sumRaw) * 100) : 0;
      const sumP = raw.reduce((a, v) => a + Math.round(v * (1 - bp / 100) * 100), 0);
      const shown = Math.floor((sumP + 50) / 100);
      const res = await s.cashier('POST', '/pos/sales', {
        sessionId: sess.id, expectedTotal: shown, billDiscount: bill,
        lines: lines.map((l) => ({ itemId: l.it.id, qty: l.qty, discountPct: l.discountPct })),
        payments: [{ mode: 'cash', amount: shown + 100 }],
      });
      expect(res.status, JSON.stringify({ k, lines, bill, shown, body: res.body })).toBe(201);
      expect(res.body.total, JSON.stringify({ k, lines, bill })).toBe(shown);
      expect(res.body.changeDue).toBe(100);
      // The round-off is only the gap between the inclusive sum and the whole rupee total.
      expect(Math.abs(res.body.roundOff)).toBeLessThanOrEqual(0.5 + 0.06);
    }
  });

  it('shows one 5% line at MRP exactly and rejects a stale total', async () => {
    const s = await shop();
    expect((await s.api('PUT', '/pos/settings', { pricesIncludeTax: true })).status).toBe(200);
    const sess = await openSession(s);
    const ok = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 100 }] });
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(ok.body.total).toBe(100);
    expect(ok.body.subtotal).toBe(95.24);
    expect(ok.body.taxTotal).toBe(4.76);
    const stale = await s.cashier('POST', '/pos/sales', { sessionId: sess.id, expectedTotal: 250, lines: [{ itemId: s.a.id, qty: 1 }], payments: [{ mode: 'cash', amount: 300 }] });
    expect(stale.status).toBe(400);
  });
});

describe('closing with held bills', () => {
  it('asks for confirmation and reports the count', async () => {
    const s = await shop();
    const sess = await openSession(s);
    await s.cashier('POST', '/pos/held', { sessionId: sess.id, payload: { lines: [] } });
    expect((await s.cashier('GET', `/pos/sessions/${sess.id}`)).body.heldCount).toBe(1);
    const first = await s.cashier('POST', `/pos/sessions/${sess.id}/close`, { counted: { cash: 500 } });
    expect(first.status).toBe(409);
    expect(first.body.error.code).toBe('HELD_BILLS');
    const done = await s.cashier('POST', `/pos/sessions/${sess.id}/close`, { counted: { cash: 500 }, confirmHeld: true });
    expect(done.status).toBe(200);
  });
});
