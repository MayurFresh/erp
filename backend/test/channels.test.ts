import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const PASSWORD = 'Secret@123';
let k = 0;
const idem = () => ({ 'idempotency-key': `chan-${Date.now()}-${k++}` });

async function biz(name = 'Online Co') {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24', businessType: 'marketplace',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, signup.body.accessToken, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const userAs = async (roleName: string) => {
    const email = uniqueEmail('u');
    const created = await api('POST', '/users', { name: roleName, email, password: PASSWORD, roleId: roles.find((r) => r.name === roleName)!.id });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    return client(env.app, login.body.accessToken, companyId);
  };
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const mk = async (sku: string, price: number, stock = 20) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, hsnCode: '6907', unit: 'nos', gstRate: 18, salePrice: price, purchasePrice: 60, trackStock: true });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const p = await api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId: r.body.id, qty: stock, rate: 60 }] });
    expect(p.status, JSON.stringify(p.body)).toBe(201);
    return r.body as { id: string };
  };
  const a = await mk('AAA', 100);
  const bundleB = await mk('BBB', 300);
  const conn = (await api('POST', '/channels', { provider: 'manual', name: 'Amazon CSV', locationId: wh.id })).body as { id: string; partyId: string };
  expect(conn.id).toBeTruthy();
  return { api, wh, a, b: bundleB, conn, userAs };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const ordersCsv = (rows: string[][]) =>
  ['order_id,order_date,sku,title,qty,unit_price,discount,ship_state,status', ...rows.map((r) => r.join(','))].join('\n');
const mapSku = (b: Biz, channelSku: string, components: { itemId: string; qty: number }[]) =>
  b.api('POST', `/channels/${b.conn.id}/listings`, { channelSku, components });
const importOrders = (b: Biz, csv: string, dryRun = false) => b.api('POST', `/channels/${b.conn.id}/orders/import`, { csv, dryRun });
const stockOf = async (b: Biz, itemId: string) => {
  const r = await b.api('GET', `/stock?locationId=${b.wh.id}&limit=200`);
  return (r.body.data as { itemId: string; reservedQty: number; availableQty: number }[]).find((x) => x.itemId === itemId)!;
};
const settlementsCsv = (rows: string[][]) => ['settlement_id,payout_date,order_id,type,amount', ...rows.map((r) => r.join(','))].join('\n');
const journals = async (b: Biz) => (await b.api('GET', '/journals?voucherType=settlement')).body.data as
  { lines: { accountCode: string; debit: number; credit: number }[] }[];

describe('order import', () => {
  it('needs SKU mapping, previews, then creates a confirmed sales order once', async () => {
    const b = await biz();
    const csv = ordersCsv([['#1001', '2026-11-01', 'AMZ-A', 'Plate', '2', '118', '0', '24', 'open']]);
    const preview = await importOrders(b, csv, true);
    expect(preview.status).toBe(200);
    expect(preview.body.orders[0]).toMatchObject({ action: 'blocked', unmappedSkus: ['AMZ-A'] });

    const first = await importOrders(b, csv);
    expect(first.body.summary).toMatchObject({ created: 0, failed: 1 });
    expect(first.body.results[0].errorCode).toBe('UNMAPPED_SKU');
    expect((await b.api('GET', `/channels/${b.conn.id}/unmapped`)).body.data[0]).toMatchObject({ channelSku: 'AMZ-A' });
    expect((await b.api('GET', '/sales-orders')).body.total).toBe(0);

    // Mapping the SKU creates the waiting order.
    const mapped = await mapSku(b, 'AMZ-A', [{ itemId: b.a.id, qty: 1 }]);
    expect(mapped.status, JSON.stringify(mapped.body)).toBe(201);
    expect(mapped.body.ordersCreated).toBe(1);
    const orders = (await b.api('GET', '/sales-orders')).body;
    expect(orders.total).toBe(1);
    expect(orders.data[0]).toMatchObject({ status: 'confirmed', source: 'channel', externalRef: '#1001', total: 236, subtotal: 200 });
    expect((await stockOf(b, b.a.id)).reservedQty).toBe(2);
    expect((await b.api('GET', `/channels/${b.conn.id}/unmapped`)).body.total).toBe(0);

    // Importing the same file again creates nothing.
    const again = await importOrders(b, csv);
    expect(again.body.summary).toMatchObject({ created: 0, duplicates: 1, failed: 0 });
    expect((await b.api('GET', '/sales-orders')).body.total).toBe(1);
    const dry = await importOrders(b, csv, true);
    expect(dry.body.orders[0].action).toBe('duplicate');
    const inbox = (await b.api('GET', '/channels/inbox?status=processed')).body;
    expect(inbox.total).toBe(1);
    expect(inbox.data[0]).toMatchObject({ externalRef: '#1001', salesOrderStatus: 'confirmed' });
  });

  it('splits a bundle across its items and applies line discounts', async () => {
    const b = await biz();
    await mapSku(b, 'COMBO', [{ itemId: b.a.id, qty: 1 }, { itemId: b.b.id, qty: 2 }]);
    const r = await importOrders(b, ordersCsv([['#2001', '2026-11-01', 'COMBO', 'Combo', '1', '767', '0', '24', 'open']]));
    expect(r.body.summary.created, JSON.stringify(r.body)).toBe(1);
    const so = (await b.api('GET', `/sales-orders/${r.body.results[0].salesOrderId}`)).body;
    expect(so.lines).toHaveLength(2);
    const qty = Object.fromEntries(so.lines.map((l: { itemId: string; qtyOrdered: number }) => [l.itemId, l.qtyOrdered]));
    expect(qty[b.b.id]).toBe(2);
    // 767 paid, tax inclusive at 18%: about 650 before tax.
    expect(Math.abs(so.subtotal - 650)).toBeLessThan(0.1);
    expect((await stockOf(b, b.b.id)).reservedQty).toBe(2);
  });

  it('keeps an order as a draft when stock is short, and cancels unshipped orders from a later file', async () => {
    const b = await biz();
    await mapSku(b, 'AMZ-A', [{ itemId: b.a.id, qty: 1 }]);
    const big = await importOrders(b, ordersCsv([['#3001', '2026-11-01', 'AMZ-A', 'Plate', '500', '118', '0', '24', 'open']]));
    expect(big.body.summary).toMatchObject({ created: 1, heldAsDraft: 1 });
    expect((await b.api('GET', `/sales-orders/${big.body.results[0].salesOrderId}`)).body.status).toBe('draft');

    const ok = await importOrders(b, ordersCsv([['#3002', '2026-11-01', 'AMZ-A', 'Plate', '3', '118', '0', '24', 'open']]));
    expect((await stockOf(b, b.a.id)).reservedQty).toBe(3);
    const cancel = await importOrders(b, ordersCsv([['#3002', '2026-11-01', 'AMZ-A', 'Plate', '3', '118', '0', '24', 'cancelled']]));
    expect(cancel.body.summary.cancelled).toBe(1);
    expect((await b.api('GET', `/sales-orders/${ok.body.results[0].salesOrderId}`)).body.status).toBe('cancelled');
    expect((await stockOf(b, b.a.id)).reservedQty).toBe(0);
    // A cancel for an order we never had is ignored, not an error.
    const ghost = await importOrders(b, ordersCsv([['#9999', '2026-11-01', 'AMZ-A', 'Plate', '1', '118', '0', '24', 'cancelled']]));
    expect(ghost.body.summary).toMatchObject({ ignored: 1, failed: 0 });
  });

  it('reports bad rows without stopping the file', async () => {
    const b = await biz();
    await mapSku(b, 'AMZ-A', [{ itemId: b.a.id, qty: 1 }]);
    const r = await importOrders(b, ordersCsv([
      ['#4001', '2026-11-01', 'AMZ-A', 'Plate', '0', '118', '0', '24', 'open'],
      ['#4002', 'not-a-date', 'AMZ-A', 'Plate', '1', '118', '0', '24', 'open'],
      ['#4003', '2026-11-01', 'AMZ-A', 'Plate', '1', '118', '0', '24', 'open'],
    ]));
    expect(r.body.issues).toHaveLength(2);
    expect(r.body.summary.created).toBe(1);
  });
});

describe('order to invoice and settlement', () => {
  async function shipped(b: Biz, ref: string, qty = 2) {
    const csv = ordersCsv([[ref, '2026-11-01', 'AMZ-A', 'Plate', String(qty), '118', '0', '24', 'open']]);
    await mapSku(b, 'AMZ-A', [{ itemId: b.a.id, qty: 1 }]).catch(() => null);
    const imp = await importOrders(b, csv);
    const orderId = imp.body.results[0].salesOrderId as string;
    const pl = await b.api('POST', '/pick-lists', { locationId: b.wh.id, orderIds: [orderId] });
    expect(pl.status, JSON.stringify(pl.body)).toBe(201);
    const scan = await b.api('POST', `/pick-lists/${pl.body.id}/scan`, { scanId: `s-${Date.now()}-${k++}`, code: 'AAA', qty });
    expect(scan.status, JSON.stringify(scan.body)).toBe(200);
    expect((await b.api('POST', `/pick-lists/${pl.body.id}/complete`)).status).toBe(200);
    expect((await b.api('POST', `/sales-orders/${orderId}/pack`, {})).status).toBe(200);
    const d = await b.api('POST', `/sales-orders/${orderId}/dispatch`, { courier: 'Self' }, idem());
    expect(d.status, JSON.stringify(d.body)).toBe(201);
    return { orderId, invoiceTotal: d.body.invoice.total as number };
  }

  it('invoices the order through dispatch, then posts a settlement with fees, TCS and TDS as a balanced journal', async () => {
    const b = await biz();
    const s = await shipped(b, '#5001');
    expect(s.invoiceTotal).toBe(236);
    expect((await b.api('GET', `/sales-orders/${s.orderId}`)).body.status).toBe('dispatched');

    const csv = settlementsCsv([
      ['SET-1', '2026-11-08', '#5001', 'Principal', '236'], ['SET-1', '2026-11-08', '#5001', 'Commission', '-20'],
      ['SET-1', '2026-11-08', '#5001', 'GST on fees', '-3.6'], ['SET-1', '2026-11-08', '#5001', 'TCS', '-2'],
      ['SET-1', '2026-11-08', '#5001', 'TDS', '-0.2'], ['SET-1', '2026-11-08', '', 'Net payout', '210.2'],
    ]);
    const prev = await b.api('POST', `/channels/${b.conn.id}/settlements/import`, { csv, dryRun: true });
    expect(prev.body.settlements[0]).toMatchObject({ status: 'matched', payout: 210.2, difference: 0 });
    const imp = await b.api('POST', `/channels/${b.conn.id}/settlements/import`, { csv });
    expect(imp.status, JSON.stringify(imp.body)).toBe(200);
    const id = imp.body.settlements[0].settlementId as string;
    // Same file again: no second settlement.
    expect((await b.api('POST', `/channels/${b.conn.id}/settlements/import`, { csv })).body.summary).toMatchObject({ created: 0, duplicates: 1 });
    expect((await b.api('GET', '/channels/settlements')).body.total).toBe(1);

    const rec = (await b.api('GET', `/channels/settlements/${id}`)).body;
    expect(rec.orders[0]).toMatchObject({ orderRef: '#5001', expected: 236, received: 236, difference: 0, matched: true });
    expect(rec.statutory.tcs.received).toBe(-2);
    expect(rec.statutory.tcs.expected).toBe(-1); // 0.5% of 200 taxable value
    expect(rec.statutory.tcs.difference).toBe(-1);

    const posted = await b.api('POST', `/channels/settlements/${id}/post`, {});
    expect(posted.status, JSON.stringify(posted.body)).toBe(200);
    expect(posted.body.status).toBe('posted');
    const j = await journals(b);
    expect(j).toHaveLength(1);
    const lines = j[0]!.lines;
    expect(lines.reduce((a, l) => a + l.debit, 0)).toBeCloseTo(lines.reduce((a, l) => a + l.credit, 0), 2);
    const by = (code: string) => lines.filter((l) => l.accountCode === code).reduce((a, l) => a + l.debit - l.credit, 0);
    expect(by('1010')).toBeCloseTo(210.2, 2);
    expect(by('1100')).toBeCloseTo(-236, 2);
    expect(by('6100')).toBeCloseTo(20, 2);
    expect(by('1302')).toBeCloseTo(3.6, 2);
    expect(by('1311')).toBeCloseTo(2, 2);
    expect(by('1310')).toBeCloseTo(0.2, 2);
    expect((await b.api('POST', `/channels/settlements/${id}/post`, {})).status).toBe(409);
  });

  it('blocks posting when the payout does not match the lines, and flags orders not found', async () => {
    const b = await biz();
    const csv = settlementsCsv([
      ['SET-2', '2026-11-08', '#7001', 'Principal', '100'], ['SET-2', '2026-11-08', '#7001', 'Commission', '-10'],
      ['SET-2', '2026-11-08', '', 'Net payout', '95'],
    ]);
    const imp = await b.api('POST', `/channels/${b.conn.id}/settlements/import`, { csv });
    expect(imp.body.settlements[0]).toMatchObject({ status: 'unbalanced', difference: 5, unmatchedOrderRefs: ['#7001'] });
    const post = await b.api('POST', `/channels/settlements/${imp.body.settlements[0].settlementId}/post`, {});
    expect(post.status).toBe(409);
    expect(post.body.error.code).toBe('UNBALANCED_SETTLEMENT');
    expect(await journals(b)).toHaveLength(0);
    const bad = await b.api('POST', `/channels/${b.conn.id}/settlements/import`, { csv: settlementsCsv([['S3', '2026-11-08', '', 'Mystery fee', '-5']]) });
    expect(bad.body.issues[0].message).toMatch(/not a known line type/);
    expect(bad.body.settlements[0]?.lineCount ?? 0).toBe(0);
  });

  it('handles returns: refund lines debit receivables and a custom label maps through aliases', async () => {
    const b = await biz();
    await b.api('PATCH', `/channels/${b.conn.id}`, { settlementAliases: { 'return shipping': 'shipping' } });
    const csv = settlementsCsv([
      ['SET-4', '2026-11-09', '#8001', 'Refund', '-118'], ['SET-4', '2026-11-09', '#8001', 'Return shipping', '-40'],
      ['SET-4', '2026-11-09', '#8000', 'Principal', '500'],
    ]);
    const imp = await b.api('POST', `/channels/${b.conn.id}/settlements/import`, { csv });
    expect(imp.body.settlements[0].payout).toBe(342);
    const id = imp.body.settlements[0].settlementId as string;
    expect((await b.api('POST', `/channels/settlements/${id}/post`, {})).status).toBe(200);
    const lines = (await journals(b))[0]!.lines;
    const by = (code: string) => lines.filter((l) => l.accountCode === code).reduce((a, l) => a + l.debit - l.credit, 0);
    expect(by('1100')).toBeCloseTo(-382, 2); // 500 collected less 118 refunded, and 0 from the fee
    expect(by('6100')).toBeCloseTo(40, 2);
    expect(by('1010')).toBeCloseTo(342, 2);
  });
});

describe('permissions', () => {
  it('denies channel work to roles without it', async () => {
    const b = await biz();
    const sales = await b.userAs('Sales Executive');
    const keeper = await b.userAs('Store Keeper');
    const accountant = await b.userAs('Accountant');
    expect((await sales('GET', '/channels')).status).toBe(200);
    expect((await sales('POST', '/channels', { provider: 'manual', name: 'X', locationId: b.wh.id })).status).toBe(403);
    expect((await sales('POST', `/channels/${b.conn.id}/orders/import`, { csv: 'a' })).status).toBe(403);
    expect((await keeper('GET', '/channels')).status).toBe(403);
    expect((await keeper('GET', '/channels/inbox')).status).toBe(403);
    expect((await accountant('POST', `/channels/${b.conn.id}/listings`, { channelSku: 'Z', components: [{ itemId: b.a.id, qty: 1 }] })).status).toBe(403);
    const csv = settlementsCsv([['S9', '2026-11-08', '', 'Principal', '10']]);
    expect((await sales('POST', `/channels/${b.conn.id}/settlements/import`, { csv })).status).toBe(403);
    const imp = await accountant('POST', `/channels/${b.conn.id}/settlements/import`, { csv });
    expect(imp.status, JSON.stringify(imp.body)).toBe(200);
    expect((await sales('POST', `/channels/settlements/${imp.body.settlements[0].settlementId}/post`, {})).status).toBe(403);
  });

  it('stops other companies reading a channel', async () => {
    const b = await biz();
    const other = await biz('Other Co');
    expect((await other.api('GET', `/channels/${b.conn.id}`)).status).toBe(404);
    expect((await other.api('GET', '/channels')).body.total).toBe(1);
  });
});
