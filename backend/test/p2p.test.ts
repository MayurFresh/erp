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
const NIL = '00000000-0000-4000-8000-000000000000';

async function biz() {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'P2P Co', name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, signup.body.accessToken, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const role = (n: string) => roles.find((r) => r.name === n)!.id;
  const userAs = async (name: string, roleName: string) => {
    const email = uniqueEmail(name.toLowerCase());
    expect((await api('POST', '/users', { name, email, password: PASSWORD, roleId: role(roleName) })).status).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    return client(env.app, login.body.accessToken, companyId);
  };
  const keeper = await userAs('Kiran', 'Store Keeper');
  const accountant = await userAs('Anita', 'Accountant');
  const admin = await userAs('Adam', 'Company Admin');
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const cement = (await api('POST', '/items', {
    name: 'Cement 50kg', sku: 'CEM-50', barcode: '890100000011', hsnCode: '2523', unit: 'bag', gstRate: 18,
    salePrice: 500, purchasePrice: 400, trackStock: true, reorderLevel: 50,
  })).body;
  const steel = (await api('POST', '/items', {
    name: 'Steel bar 12mm', sku: 'STL-12', barcode: '890100000022', hsnCode: '7214', unit: 'kg', gstRate: 18,
    salePrice: 80, purchasePrice: 60, trackStock: true, reorderLevel: 0,
  })).body;
  expect(cement.id, JSON.stringify(cement)).toBeTruthy();
  return { api, keeper, accountant, admin, role, wh, vendor, cement, steel, token: signup.body.accessToken as string, companyId };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const newPo = async (b: Biz, qty = 100, rate = 400) => {
  const r = await b.api('POST', '/purchase-orders', { locationId: b.wh.id, partyId: b.vendor.id, lines: [{ itemId: b.cement.id, qty, rate }] });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body;
};
const approvedPo = async (b: Biz, qty = 100, rate = 400) => {
  const po = await newPo(b, qty, rate);
  const s = await b.api('POST', `/purchase-orders/${po.id}/submit`);
  expect(s.status, JSON.stringify(s.body)).toBe(200);
  expect(s.body.status).toBe('approved');
  return s.body;
};
const receive = (b: Biz, po: any, acceptedQty: number, extra: object = {}) =>
  b.keeper('POST', '/goods-receipts', { purchaseOrderId: po.id, lines: [{ poLineId: po.lines[0].id, acceptedQty, ...extra }] });
const stockOf = async (b: Biz, itemId: string) => {
  const rows = (await b.api('GET', `/stock?limit=200`)).body.data as { itemId: string; qty: number; value: number }[];
  const r = rows.filter((x) => x.itemId === itemId);
  return { qty: r.reduce((s, x) => s + x.qty, 0), value: Math.round(r.reduce((s, x) => s + x.value, 0) * 100) / 100 };
};
const tbRow = async (b: Biz, code: string) => {
  const tb = (await b.api('GET', '/reports/trial-balance')).body;
  expect(tb.totalDebit).toBe(tb.totalCredit);
  const row = tb.rows.find((r: any) => r.code === code);
  return row ? Math.round((row.debit - row.credit) * 100) / 100 : 0;
};
const bill = (b: Biz, po: any, grn: any, qty: number, extra: Record<string, unknown> = {}, line: Record<string, unknown> = {}) =>
  b.api('POST', '/purchases', {
    locationId: b.wh.id, partyId: b.vendor.id, supplierInvoiceNo: `INV-${Math.random().toString(36).slice(2, 8)}`, ...extra,
    lines: [{ itemId: b.cement.id, qty, grnLineId: grn.lines[0].id, ...line }],
  });

describe('purchase orders and approval', () => {
  it('draft, edit, submit, send', async () => {
    const b = await biz();
    const po = await newPo(b);
    expect(po.status).toBe('draft');
    expect(po.number).toMatch(/^PO\//);
    const edited = await b.api('PUT', `/purchase-orders/${po.id}`, { locationId: b.wh.id, partyId: b.vendor.id, lines: [{ itemId: b.cement.id, qty: 120, rate: 410 }] });
    expect(edited.status).toBe(200);
    expect(edited.body.lines[0].qty).toBe(120);
    const sub = await b.api('POST', `/purchase-orders/${po.id}/submit`);
    expect(sub.body.status).toBe('approved');
    expect((await b.api('PUT', `/purchase-orders/${po.id}`, { locationId: b.wh.id, partyId: b.vendor.id, lines: [{ itemId: b.cement.id, qty: 1 }] })).status).toBe(409);
    const sent = await b.api('POST', `/purchase-orders/${po.id}/send`);
    expect(sent.body.status).toBe('sent');
    const list = await b.api('GET', '/purchase-orders?status=sent&q=Vendor');
    expect(list.body.total).toBe(1);
  });

  it('a matching rule holds the PO until an approver decides', async () => {
    const b = await biz();
    const rule = await b.api('POST', '/approval-rules', { docType: 'purchase_order', name: 'Big POs', minAmount: 20000, levels: [{ approverRoleId: b.role('Company Admin') }] });
    expect(rule.status, JSON.stringify(rule.body)).toBe(201);
    const po = await newPo(b, 100, 400);
    const sub = await b.api('POST', `/purchase-orders/${po.id}/submit`);
    expect(sub.body.status).toBe('pending_approval');
    expect(sub.body.approvalRequestId).toBeTruthy();
    expect((await receive(b, po, 5)).status).toBe(409);
    const done = await b.admin('POST', `/approvals/${sub.body.approvalRequestId}/approve`, { comment: 'ok' });
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    expect((await b.api('GET', `/purchase-orders/${po.id}`)).body.status).toBe('approved');

    const po2 = await newPo(b, 100, 400);
    const sub2 = await b.api('POST', `/purchase-orders/${po2.id}/submit`);
    const rej = await b.admin('POST', `/approvals/${sub2.body.approvalRequestId}/reject`, { comment: 'too much' });
    expect(rej.status, JSON.stringify(rej.body)).toBe(200);
    expect((await b.api('GET', `/purchase-orders/${po2.id}`)).body.status).toBe('draft');
  });

  it('cancels a PO with nothing received', async () => {
    const b = await biz();
    const po = await approvedPo(b);
    const c = await b.api('POST', `/purchase-orders/${po.id}/cancel`, { reason: 'Vendor withdrew' });
    expect(c.status).toBe(200);
    expect(c.body.status).toBe('cancelled');
  });
});

describe('goods receipts', () => {
  it('partial then full receipt, stock and GRNI follow', async () => {
    const b = await biz();
    const po = await approvedPo(b, 100, 400);
    const g1 = await receive(b, po, 60);
    expect(g1.status, JSON.stringify(g1.body)).toBe(201);
    expect(g1.body.number).toMatch(/^GRN\//);
    expect((await b.api('GET', `/purchase-orders/${po.id}`)).body.status).toBe('partially_received');
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 60, value: 24000 });
    expect(await tbRow(b, '2140')).toBe(-24000);
    const g2 = await receive(b, po, 40);
    expect(g2.status).toBe(201);
    const after = (await b.api('GET', `/purchase-orders/${po.id}`)).body;
    expect(after.status).toBe('received');
    expect(after.lines[0].receivedQty).toBe(100);
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 100, value: 40000 });
    expect((await receive(b, after, 1)).status).toBe(409);
  });

  it('blocks over-receipt and honours tolerance', async () => {
    const b = await biz();
    const po = await approvedPo(b, 100);
    const over = await receive(b, po, 101);
    expect(over.status).toBe(400);
    expect(over.body.error.code).toBe('OVER_RECEIPT');
    expect(over.body.error.details.lines[0].allowed).toBe(100);
    expect((await b.api('PUT', '/p2p/settings', { receiptTolerancePct: 5, priceTolerancePct: 0, countApprovalValue: 10000 })).status).toBe(200);
    expect((await receive(b, po, 105)).status).toBe(201);
    expect((await receive(b, (await b.api('GET', `/purchase-orders/${po.id}`)).body, 1)).status).toBe(409);
  });

  it('tracks rejected quantity separately and asks for a reason', async () => {
    const b = await biz();
    const po = await approvedPo(b, 100);
    expect((await receive(b, po, 50, { rejectedQty: 5 })).status).toBe(400);
    const ok = await receive(b, po, 50, { rejectedQty: 5, rejectReason: 'Torn bags' });
    expect(ok.status).toBe(201);
    const got = (await b.api('GET', `/purchase-orders/${po.id}`)).body;
    expect(got.lines[0].receivedQty).toBe(50);
    expect(got.lines[0].rejectedQty).toBe(5);
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 50, value: 20000 });
  });

  it('cancel rules: stock gone, billed, then allowed', async () => {
    const b = await biz();
    const po = await approvedPo(b, 100);
    const g = (await receive(b, po, 100)).body;
    // Sell some so the receipt cannot be reversed.
    const cust = (await b.api('POST', '/parties', { type: 'customer', name: 'Cust', stateCode: '24' })).body;
    const inv = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: cust.id, lines: [{ itemId: b.cement.id, qty: 30 }] });
    expect(inv.status, JSON.stringify(inv.body)).toBe(201);
    const blocked = await b.keeper('POST', `/goods-receipts/${g.id}/cancel`, { reason: 'Wrong PO' });
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('INSUFFICIENT_STOCK');
    await b.api('POST', `/invoices/${inv.body.id}/cancel`, { reason: 'Test' });
    const b1 = await bill(b, po, g, 10);
    expect(b1.status, JSON.stringify(b1.body)).toBe(201);
    const hasBills = await b.keeper('POST', `/goods-receipts/${g.id}/cancel`, { reason: 'Wrong PO' });
    expect(hasBills.body.error.code).toBe('HAS_BILLS');
    await b.api('POST', `/purchases/${b1.body.id}/cancel`, { reason: 'Mistake' });
    const done = await b.keeper('POST', `/goods-receipts/${g.id}/cancel`, { reason: 'Wrong PO' });
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    expect(done.body.status).toBe('cancelled');
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 0, value: 0 });
    expect(await tbRow(b, '2140')).toBe(0);
    expect((await b.api('GET', `/purchase-orders/${po.id}`)).body.status).toBe('approved');
    expect((await b.keeper('POST', `/goods-receipts/${g.id}/cancel`, { reason: 'Again' })).body.error.code).toBe('ALREADY_CANCELLED');
  });
});

describe('three-way match', () => {
  it('billing from a receipt does not count stock or inventory twice', async () => {
    const b = await biz();
    const po = await approvedPo(b, 100, 400);
    const g = (await receive(b, po, 100)).body;
    const inventoryBefore = await tbRow(b, '1200');
    const r = await bill(b, po, g, 100);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(r.body.purchaseOrderId).toBe(po.id);
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 100, value: 40000 });
    expect(await tbRow(b, '1200')).toBe(inventoryBefore);
    expect(await tbRow(b, '2140')).toBe(0);
    const after = (await b.api('GET', `/purchase-orders/${po.id}`)).body;
    expect(after.status).toBe('closed');
    expect(after.lines[0].billedQty).toBe(100);
  });

  it('blocks over-billing', async () => {
    const b = await biz();
    const po = await approvedPo(b, 100);
    const g = (await receive(b, po, 40)).body;
    const r = await bill(b, po, g, 41);
    expect(r.status).toBe(400);
    expect(r.body.error.code).toBe('OVER_BILLED');
    expect((await bill(b, po, g, 40)).status).toBe(201);
    expect((await bill(b, po, g, 1)).body.error.code).toBe('OVER_BILLED');
  });

  it('price variance blocks, override needs permission and posts to variance', async () => {
    const b = await biz();
    const po = await approvedPo(b, 100, 400);
    const g = (await receive(b, po, 100)).body;
    const blocked = await bill(b, po, g, 50, {}, { rate: 420 });
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('PRICE_VARIANCE');
    expect(blocked.body.error.details.lines[0].variancePct).toBe(5);
    const denied = await b.accountant('POST', '/purchases', {
      locationId: b.wh.id, partyId: b.vendor.id, supplierInvoiceNo: 'ACC-1', acceptVariance: true,
      lines: [{ itemId: b.cement.id, qty: 50, rate: 420, grnLineId: g.lines[0].id }],
    });
    expect(denied.status).toBe(403);
    const ok = await bill(b, po, g, 50, { acceptVariance: true }, { rate: 420 });
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(ok.body.varianceAccepted).toBe(true);
    expect(await tbRow(b, '5110')).toBe(1000);
    expect(await tbRow(b, '2140')).toBe(-20000);
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 100, value: 40000 });
  });

  it('cancelling the bill releases the receipt', async () => {
    const b = await biz();
    const po = await approvedPo(b, 100);
    const g = (await receive(b, po, 100)).body;
    const r = await bill(b, po, g, 100);
    expect((await b.api('POST', `/purchases/${r.body.id}/cancel`, { reason: 'Wrong bill' })).status).toBe(200);
    expect(await tbRow(b, '2140')).toBe(-40000);
    expect((await b.api('GET', `/purchase-orders/${po.id}`)).body.status).toBe('received');
    expect((await bill(b, po, g, 100)).status).toBe(201);
  });
});

describe('reorder suggestions', () => {
  it('lists items at or below the level and creates draft POs by vendor', async () => {
    const b = await biz();
    // A bill for the vendor so a last vendor exists, plus stock below the level.
    const direct = await b.api('POST', '/purchases', {
      locationId: b.wh.id, partyId: b.vendor.id, supplierInvoiceNo: 'D-1', lines: [{ itemId: b.cement.id, qty: 20, rate: 390 }],
    });
    expect(direct.status, JSON.stringify(direct.body)).toBe(201);
    const s = await b.api('GET', `/reorder-suggestions?locationId=${b.wh.id}`);
    expect(s.status).toBe(200);
    const row = s.body.data.find((x: any) => x.itemId === b.cement.id);
    expect(row.onHand).toBe(20);
    expect(row.position).toBe(20);
    expect(row.suggestedQty).toBe(80);
    expect(row.lastVendorId).toBe(b.vendor.id);
    expect(s.body.data.find((x: any) => x.itemId === b.steel.id)).toBeUndefined();

    const made = await b.api('POST', '/reorder-suggestions/purchase-orders', { selections: [{ itemId: b.cement.id, locationId: b.wh.id, qty: 80 }] });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    expect(made.body.data).toHaveLength(1);
    expect(made.body.data[0].status).toBe('draft');
    expect(made.body.data[0].partyId).toBe(b.vendor.id);
    // Open PO quantity moves the position, so the suggestion disappears once approved.
    await b.api('POST', `/purchase-orders/${made.body.data[0].id}/submit`);
    const again = await b.api('GET', `/reorder-suggestions?locationId=${b.wh.id}`);
    expect(again.body.data.find((x: any) => x.itemId === b.cement.id)).toBeUndefined();
    expect((await b.api('POST', '/reorder-suggestions/purchase-orders', { selections: [{ itemId: b.steel.id, locationId: b.wh.id, qty: 5 }] })).status).toBe(400);
  });
});

describe('stock counts', () => {
  async function stocked(b: Biz) {
    const po = await approvedPo(b, 100, 400);
    await receive(b, po, 100);
  }

  it('scans, handles a movement during the count, and posts the variance', async () => {
    const b = await biz();
    await stocked(b);
    const c = await b.keeper('POST', '/stock-counts', { locationId: b.wh.id });
    expect(c.status, JSON.stringify(c.body)).toBe(201);
    expect(c.body.lines[0].expectedQty).toBe(100);
    expect((await b.keeper('POST', '/stock-counts', { locationId: b.wh.id })).body.error.code).toBe('COUNT_OPEN');
    // Ten bags leave after the snapshot.
    const cust = (await b.api('POST', '/parties', { type: 'customer', name: 'Cust', stateCode: '24' })).body;
    expect((await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: cust.id, lines: [{ itemId: b.cement.id, qty: 10 }] })).status).toBe(201);
    const s1 = await b.keeper('POST', `/stock-counts/${c.body.id}/scans`, { scanId: 's1', code: '890100000011', qty: 85 });
    expect(s1.status, JSON.stringify(s1.body)).toBe(200);
    expect(s1.body.duplicate).toBe(false);
    expect(s1.body.line.movedSince).toBe(-10);
    expect(s1.body.line.expectedNow).toBe(90);
    expect(s1.body.line.varianceQty).toBe(-5);
    const dup = await b.keeper('POST', `/stock-counts/${c.body.id}/scans`, { scanId: 's1', code: 'cem-50', qty: 85 });
    expect(dup.body.duplicate).toBe(true);
    expect(dup.body.line.countedQty).toBe(85);
    const s2 = await b.keeper('POST', `/stock-counts/${c.body.id}/scans`, { code: 'CEM-50' });
    expect(s2.body.line.countedQty).toBe(86);
    const set = await b.keeper('POST', `/stock-counts/${c.body.id}/scans`, { itemId: b.cement.id, qty: 85, mode: 'set' });
    expect(set.body.line.countedQty).toBe(85);
    expect((await b.keeper('POST', `/stock-counts/${c.body.id}/scans`, { code: 'NOPE-0000' })).body.error.code).toBe('UNKNOWN_BARCODE');

    const posted = await b.keeper('POST', `/stock-counts/${c.body.id}/post`, {});
    expect(posted.status, JSON.stringify(posted.body)).toBe(200);
    expect(posted.body.status).toBe('posted');
    expect(posted.body.varianceValue).toBeUndefined();
    expect((await b.api('GET', `/stock-counts/${c.body.id}`)).body.varianceValue).toBe(-2000);
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 85, value: 34000 });
    expect(await tbRow(b, '5200')).toBe(2000);
    expect((await b.keeper('POST', `/stock-counts/${c.body.id}/post`, {})).body.error.code).toBe('NOT_OPEN');
    expect((await b.keeper('POST', `/stock-counts/${c.body.id}/scans`, { code: 'CEM-50' })).body.error.code).toBe('NOT_OPEN');
  });

  it('a variance above the threshold needs the approve permission', async () => {
    const b = await biz();
    await stocked(b);
    const c = (await b.keeper('POST', '/stock-counts', { locationId: b.wh.id })).body;
    await b.keeper('POST', `/stock-counts/${c.id}/scans`, { itemId: b.cement.id, qty: 50, mode: 'set' });
    const denied = await b.keeper('POST', `/stock-counts/${c.id}/post`, {});
    expect(denied.status).toBe(403);
    expect(denied.body.error.code).toBe('COUNT_APPROVAL_REQUIRED');
    expect(denied.body.error.details.varianceValue).toBe(20000);
    expect(denied.body.error.details.thresholdValue).toBe(10000);
    const ok = await b.api('POST', `/stock-counts/${c.id}/post`, {});
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 50, value: 20000 });
  });

  it('selected scope refuses other items, uncounted lines can be zeroed, gains post to income', async () => {
    const b = await biz();
    await stocked(b);
    const c = (await b.keeper('POST', '/stock-counts', { locationId: b.wh.id, itemIds: [b.cement.id] })).body;
    expect(c.scope).toBe('selected');
    const nope = await b.keeper('POST', `/stock-counts/${c.id}/scans`, { itemId: b.steel.id });
    expect(nope.status).toBe(400);
    await b.keeper('POST', `/stock-counts/${c.id}/scans`, { itemId: b.cement.id, qty: 102, mode: 'set' });
    const posted = await b.keeper('POST', `/stock-counts/${c.id}/post`, {});
    expect(posted.status).toBe(200);
    expect(await stockOf(b, b.cement.id)).toEqual({ qty: 102, value: 40800 });
    expect(await tbRow(b, '4900')).toBe(-800);
    const c2 = (await b.keeper('POST', '/stock-counts', { locationId: b.wh.id })).body;
    expect((await b.keeper('POST', `/stock-counts/${c2.id}/cancel`, { reason: 'Started by mistake' })).body.status).toBe('cancelled');
  });
});

describe('access and tenancy', () => {
  it('needs permissions', async () => {
    const b = await biz();
    const po = await newPo(b);
    expect((await b.keeper('POST', '/purchase-orders', { locationId: b.wh.id, partyId: b.vendor.id, lines: [{ itemId: b.cement.id, qty: 1 }] })).status).toBe(403);
    expect((await b.keeper('POST', `/purchase-orders/${po.id}/submit`)).status).toBe(403);
    expect((await b.accountant('POST', '/goods-receipts', { purchaseOrderId: po.id, lines: [{ poLineId: po.lines[0].id, acceptedQty: 1 }] })).status).toBe(403);
    expect((await b.accountant('POST', '/stock-counts', { locationId: b.wh.id })).status).toBe(403);
    expect((await b.accountant('PUT', '/p2p/settings', { receiptTolerancePct: 1, priceTolerancePct: 1, countApprovalValue: 1 })).status).toBe(200);
    expect((await b.keeper('PUT', '/p2p/settings', { receiptTolerancePct: 1, priceTolerancePct: 1, countApprovalValue: 1 })).status).toBe(403);
  });

  it("another tenant's records are 404", async () => {
    const a = await biz();
    const other = await biz();
    const po = await approvedPo(a);
    const g = (await receive(a, po, 10)).body;
    const c = (await a.keeper('POST', '/stock-counts', { locationId: a.wh.id })).body;
    expect((await other.api('GET', `/purchase-orders/${po.id}`)).status).toBe(404);
    expect((await other.api('POST', `/purchase-orders/${po.id}/cancel`, { reason: 'Nope nope' })).status).toBe(404);
    expect((await other.api('GET', `/goods-receipts/${g.id}`)).status).toBe(404);
    expect((await other.api('POST', '/goods-receipts', { purchaseOrderId: po.id, lines: [{ poLineId: po.lines[0].id, acceptedQty: 1 }] })).status).toBe(404);
    expect((await other.api('GET', `/stock-counts/${c.id}`)).status).toBe(404);
    expect((await other.api('POST', `/stock-counts/${c.id}/scans`, { code: 'CEM-50' })).status).toBe(404);
    expect((await other.api('GET', `/purchase-orders/${NIL}`)).status).toBe(404);
  });
});

describe('demo data', () => {
  it('seedP2p builds every state', async () => {
    const { seedP2p } = await import('../src/db/seed-p2p.ts');
    const b = await biz();
    const mk = async (name: string, sku: string, price: number, level: number) =>
      (await b.api('POST', '/items', { name, sku, hsnCode: '2523', unit: 'nos', gstRate: 18, salePrice: price * 1.2, purchasePrice: price, trackStock: true, reorderLevel: level })).body;
    const tiles = await mk('Tiles', 'TIL-VT22', 540, 40);
    const cement = await mk('Cement', 'CEM-OPC53', 335, 100);
    const sand = await mk('Sand', 'SAND-R', 1200, 10);
    await mk('Wire', 'WIR-15', 1180, 15);
    for (const i of [cement, sand, tiles]) {
      await b.api('POST', '/stock/adjustments', { locationId: b.wh.id, itemId: i.id, qty: 20, isOpening: true });
    }
    const accEmail = uniqueEmail('accountant.demo');
    expect((await b.api('POST', '/users', { name: 'Anita', email: accEmail, password: PASSWORD, roleId: b.role('Accountant') })).status).toBe(201);
    const wrap = (c: ReturnType<typeof client>) => async (m: any, u: string, body?: unknown) => (await c(m, u, body)).body;
    await seedP2p({
      api: wrap(b.api),
      as: async (email) => {
        const login = await client(env.app)('POST', '/auth/login', { email: email === 'accountant@demo.in' ? accEmail : email, password: PASSWORD });
        return wrap(client(env.app, login.body.accessToken, b.companyId));
      },
      runJobs: async () => {},
    });
    const all = (await b.api('GET', '/purchase-orders?limit=50')).body.data as { status: string }[];
    expect(new Set(all.map((p) => p.status))).toEqual(new Set(['pending_approval', 'sent', 'partially_received', 'closed', 'draft']));
    const counts = (await b.api('GET', '/stock-counts')).body.data as { status: string }[];
    expect(counts.map((c) => c.status)).toEqual(['posted']);
  });
});
