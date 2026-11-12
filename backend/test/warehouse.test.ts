import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { seedWarehouseDemo } from '../src/db/seed-warehouse.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function shop(businessType = 'medical_store') {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Store Co', name: 'Owner', email: uniqueEmail('wh'), password: 'Secret@123', stateCode: '24', businessType,
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const token = signup.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const loc = (await api('POST', '/locations', { type: 'warehouse', name: 'Main Store', code: 'W1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Supplier', stateCode: '24' })).body;
  const customer = (await api('POST', '/parties', { type: 'customer', name: 'Patient', stateCode: '24' })).body;
  const mk = async (sku: string, qty: number) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, hsnCode: '3004', unit: 'nos', gstRate: 5, salePrice: 20, purchasePrice: 10, trackStock: true });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    const p = await api('POST', '/purchases', { locationId: loc.id, partyId: vendor.id, lines: [{ itemId: r.body.id, qty, rate: 10 }] });
    expect(p.status, JSON.stringify(p.body)).toBe(201);
    return r.body.id as string;
  };
  return { api, loc: loc.id as string, vendor, customer, mk, companyId, token };
}
const day = (n: number) => new Date(Date.now() + n * 86400000 + 5.5 * 3600000).toISOString().slice(0, 10);

describe('warehouse', () => {
  it('is on for medical stores and refused for a type without it', async () => {
    const s = await shop();
    expect((await s.api('GET', '/warehouse/settings')).status).toBe(200);
    const k = await shop('freelancer');
    expect((await k.api('GET', '/warehouse/settings')).status).toBe(403);
  });

  it('runs bins, batches, FEFO picking, expiry and putaway', async () => {
    const s = await shop();
    const item = await s.mk('MED1', 100);
    const { api, loc } = s;
    expect((await api('PUT', '/warehouse/settings', { expiryWarnDays: 60 })).body.expiryWarnDays).toBe(60);
    expect((await api('PATCH', '/warehouse/settings', { fefo: true })).status).toBe(200);
    const a1 = (await api('POST', '/warehouse/bins', { locationId: loc, code: 'A1', capacityQty: 60 })).body;
    const a2 = (await api('POST', '/warehouse/bins', { locationId: loc, code: 'A2' })).body;
    const q = (await api('POST', '/warehouse/bins', { locationId: loc, code: 'Q', kind: 'quarantine' })).body;
    expect((await api('POST', '/warehouse/bins', { locationId: loc, code: 'A1' })).status).toBe(409);

    await api('PUT', `/warehouse/items/${item}`, { tracking: 'batch' });
    // batch required
    expect((await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, binId: a1.id, qty: 10 })).status).toBe(400);
    const late = await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, binId: a1.id, qty: 40, batch: { batchNo: 'LATE', expiryDate: day(300) } });
    expect(late.status, JSON.stringify(late.body)).toBe(201);
    const soon = await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, binId: a2.id, qty: 30, batch: { batchNo: 'SOON', expiryDate: day(20) } });
    expect(soon.status).toBe(201);
    // capacity and unassigned limits
    expect((await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, binId: a1.id, qty: 30, batch: { batchNo: 'LATE' } })).body.error.code).toBe('BIN_FULL');
    expect((await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, binId: a2.id, qty: 40, batch: { batchNo: 'X', expiryDate: day(90) } })).body.error.code).toBe('INSUFFICIENT_STOCK');
    expect((await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, qty: 5, batch: { batchNo: 'OLD', expiryDate: day(-3) } })).status).toBe(400);

    const stock = (await api('GET', `/warehouse/stock?locationId=${loc}&itemId=${item}`)).body;
    expect(stock.summary).toMatchObject({ onHand: 100, tagged: 70, unassigned: 30 });
    const fefo = (await api('GET', `/warehouse/fefo?locationId=${loc}&itemId=${item}&qty=50`)).body;
    expect(fefo.candidates[0].batchNo).toBe('SOON');
    expect(fefo.plan.map((p: { batchNo: string; qty: number }) => [p.batchNo, p.qty])).toEqual([['SOON', 30], ['LATE', 20]]);
    expect((await api('GET', `/warehouse/expiry?days=30&locationId=${loc}`)).body.data.map((r: { batchNo: string }) => r.batchNo)).toEqual(['SOON']);

    const pick = await api('POST', '/warehouse/picks', { locationId: loc, lines: [{ itemId: item, qty: 35 }] });
    expect(pick.status, JSON.stringify(pick.body)).toBe(201);
    expect(pick.body.lines[0].allocations.map((a: { batchNo: string; qty: number }) => [a.batchNo, a.qty])).toEqual([['SOON', 30], ['LATE', 5]]);
    expect((await api('POST', '/warehouse/picks', { locationId: loc, lines: [{ itemId: item, qty: 99 }] })).body.error.code).toBe('INSUFFICIENT_BIN_STOCK');

    // putaway: move and capacity
    const mv = await api('POST', '/warehouse/putaway', { locationId: loc, itemId: item, fromBinId: a1.id, toBinId: a2.id, batchId: late.body.batchId, qty: 15 });
    expect(mv.status, JSON.stringify(mv.body)).toBe(201);
    expect((await api('POST', '/warehouse/putaway', { locationId: loc, itemId: item, fromBinId: a1.id, toBinId: a2.id, batchId: late.body.batchId, qty: 99 })).body.error.code).toBe('INSUFFICIENT_BIN_STOCK');
    const bins = (await api('GET', `/warehouse/bins?locationId=${loc}`)).body.data;
    expect(bins.find((b: { code: string }) => b.code === 'A1').heldQty).toBe(20);
    expect((await api('PATCH', `/warehouse/bins/${a2.id}`, { isActive: false })).body.error.code).toBe('BIN_NOT_EMPTY');
    expect(q.kind).toBe('quarantine');

    // expired batch: set expiry in the past, auto picks skip it, explicit pick refuses
    expect((await api('PATCH', `/warehouse/batches/${late.body.batchId}`, { expiryDate: day(-1) })).status).toBe(200);
    const r = await api('POST', '/warehouse/picks', { locationId: loc, lines: [{ itemId: item, qty: 1, batchId: late.body.batchId }] });
    expect(r.body.error.code).toBe('BATCH_EXPIRED');
    expect((await api('POST', '/warehouse/picks', { locationId: loc, lines: [{ itemId: item, qty: 1 }] })).body.error.code).toBe('INSUFFICIENT_BIN_STOCK');
    expect((await api('POST', '/warehouse/putaway', { locationId: loc, itemId: item, fromBinId: a2.id, toBinId: a1.id, batchId: late.body.batchId, qty: 1 })).body.error.code).toBe('BATCH_EXPIRED');
    expect((await api('POST', '/warehouse/putaway', { locationId: loc, itemId: item, fromBinId: a2.id, toBinId: q.id, batchId: late.body.batchId, qty: 1 })).status).toBe(201);
  });

  it('tracks serial numbers and leaves billing untouched', async () => {
    const s = await shop('electronics');
    const item = await s.mk('PH1', 5);
    const { api, loc } = s;
    await api('PATCH', `/warehouse/items/${item}`, { tracking: 'serial' });
    expect((await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, qty: 3, serialNos: ['S1', 'S2'] })).status).toBe(400);
    const rc = await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, qty: 3, serialNos: ['S1', 'S2', 'S3'], warrantyUntil: day(365) });
    expect(rc.status, JSON.stringify(rc.body)).toBe(201);
    expect((await api('POST', '/warehouse/receipts', { locationId: loc, itemId: item, qty: 1, serialNos: ['S1'] })).body.error.code).toBe('DUPLICATE_SERIAL');
    expect((await api('POST', '/warehouse/picks', { locationId: loc, lines: [{ itemId: item, qty: 2 }] })).status).toBe(400);
    const pk = await api('POST', '/warehouse/picks', { locationId: loc, lines: [{ itemId: item, qty: 2, serialNos: ['S1', 'S2'] }] });
    expect(pk.status, JSON.stringify(pk.body)).toBe(201);
    expect((await api('POST', '/warehouse/picks', { locationId: loc, lines: [{ itemId: item, qty: 1, serialNos: ['S1'] }] })).body.error.code).toBe('SERIAL_NOT_AVAILABLE');
    const list = (await api('GET', `/warehouse/serials?itemId=${item}&status=issued`)).body;
    expect(list.total).toBe(2);
    // a plain invoice still works with no bin or serial, and stock is untouched by the sub-ledger
    const inv = await api('POST', '/invoices', { locationId: loc, partyId: s.customer.id, lines: [{ itemId: item, qty: 1, rate: 20 }] });
    expect(inv.status, JSON.stringify(inv.body)).toBe(201);
    const st = (await api('GET', `/stock?locationId=${loc}`)).body.data.find((r: { itemId: string }) => r.itemId === item);
    expect(st.qty).toBe(4);
  });

  it('seeds a demo store room', async () => {
    const s = await shop();
    const claims = JSON.parse(Buffer.from(s.token.split('.')[1]!, 'base64url').toString());
    const out = await withTenant(env.db, claims.tid, (tx) => seedWarehouseDemo(tx, { tenantId: claims.tid, companyId: s.companyId, userId: claims.sub }));
    const ex = (await s.api('GET', `/warehouse/expiry?days=30&locationId=${out.locationId}`)).body;
    expect(ex.data.length).toBe(1);
  });

  it('puts purchases into the default bin and sells first expiry first', async () => {
    const s = await shop();
    const bin = (await s.api('POST', '/warehouse/bins', { locationId: s.loc, code: 'R1' })).body;
    const item = (await s.api('POST', '/items', { name: 'Tracked', sku: 'TRK1', hsnCode: '3004', unit: 'nos', gstRate: 5, salePrice: 20, purchasePrice: 10, trackStock: true })).body.id as string;
    const plain = await s.mk('PLN1', 5);
    expect((await s.api('PUT', `/warehouse/items/${item}`, { tracking: 'batch', defaultBinId: bin.id })).body.defaultBinId).toBe(bin.id);
    const noBatch = await s.api('POST', '/purchases', { locationId: s.loc, partyId: s.vendor.id, lines: [{ itemId: item, qty: 5, rate: 10 }] });
    expect(noBatch.status).toBe(400);
    for (const [no, d, q] of [['L-LATE', 200, 10], ['L-SOON', 30, 4]] as const) {
      const r = await s.api('POST', '/purchases', { locationId: s.loc, partyId: s.vendor.id, lines: [{ itemId: item, qty: q, rate: 10, batchNo: no, expiry: day(d) }] });
      expect(r.status, JSON.stringify(r.body)).toBe(201);
    }
    const st = (await s.api('GET', `/warehouse/stock?locationId=${s.loc}&itemId=${item}`)).body;
    expect(st.summary).toMatchObject({ onHand: 14, tagged: 14, unassigned: 0 });
    // Sale of 6 takes the 4 near expiry first, then 2 of the later batch.
    const inv = await s.api('POST', '/invoices', { locationId: s.loc, partyId: s.customer.id, lines: [{ itemId: item, qty: 6 }, { itemId: plain, qty: 1 }] });
    expect(inv.status, JSON.stringify(inv.body)).toBe(201);
    const moves = (await s.api('GET', `/warehouse/moves?locationId=${s.loc}&itemId=${item}`)).body.data.filter((m: { kind: string }) => m.kind === 'pick');
    expect(moves.map((m: { qty: number }) => m.qty).sort((a: number, b: number) => a - b)).toEqual([-4, -2]);
    expect((await s.api('GET', `/warehouse/stock?locationId=${s.loc}&itemId=${item}`)).body.summary.tagged).toBe(8);
    // An item without a rule is not touched.
    expect((await s.api('GET', `/warehouse/moves?locationId=${s.loc}&itemId=${plain}`)).body.data.length).toBe(0);
  });

  it('bills a pick list through the invoice service once', async () => {
    const s = await shop();
    const bin = (await s.api('POST', '/warehouse/bins', { locationId: s.loc, code: 'P1' })).body;
    const item = await s.mk('PK1', 10);
    await s.api('POST', '/warehouse/receipts', { locationId: s.loc, itemId: item, binId: bin.id, qty: 10 });
    const pick = await s.api('POST', '/warehouse/picks', { locationId: s.loc, lines: [{ itemId: item, qty: 3 }] });
    expect(pick.status).toBe(201);
    const sale = await s.api('POST', `/warehouse/picks/${pick.body.refId}/invoice`, { partyId: s.customer.id });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    expect(sale.body.invoice.lines[0].qty).toBe(3);
    expect((await s.api('GET', `/warehouse/stock?locationId=${s.loc}&itemId=${item}`)).body.summary.tagged).toBe(7);
    const again = await s.api('POST', `/warehouse/picks/${pick.body.refId}/invoice`, { partyId: s.customer.id });
    expect(again.status).toBe(409);
  });

  it('puts bin stock back on cancel and return, and frees a billed pick', async () => {
    const s = await shop();
    const bin = (await s.api('POST', '/warehouse/bins', { locationId: s.loc, code: 'C1' })).body;
    const item = (await s.api('POST', '/items', { name: 'Cx', sku: 'CX1', hsnCode: '3004', unit: 'nos', gstRate: 5, salePrice: 20, purchasePrice: 10, trackStock: true })).body.id as string;
    await s.api('PUT', `/warehouse/items/${item}`, { tracking: 'batch', defaultBinId: bin.id });
    const pur = await s.api('POST', '/purchases', { locationId: s.loc, partyId: s.vendor.id, lines: [{ itemId: item, qty: 10, rate: 10, batchNo: 'B1', expiry: day(100) }] });
    const tagged = async () => (await s.api('GET', `/warehouse/stock?locationId=${s.loc}&itemId=${item}`)).body.summary.tagged;
    expect(await tagged()).toBe(10);
    const inv = await s.api('POST', '/invoices', { locationId: s.loc, partyId: s.customer.id, lines: [{ itemId: item, qty: 6 }] });
    expect(await tagged()).toBe(4);
    // Partial return puts 2 back.
    const ret = await s.api('POST', '/credit-notes', { invoiceId: inv.body.id, reason: 'Returned', lines: [{ invoiceLineId: inv.body.lines[0].id, qty: 2 }] });
    expect(ret.status, JSON.stringify(ret.body)).toBe(201);
    expect(await tagged()).toBe(6);
    const inv2 = await s.api('POST', '/invoices', { locationId: s.loc, partyId: s.customer.id, lines: [{ itemId: item, qty: 3 }] });
    const t2 = await tagged();
    expect((await s.api('POST', `/invoices/${inv2.body.id}/cancel`, { reason: 'Mistake entry' })).status).toBe(200);
    expect(await tagged()).toBe(t2 + 3);
    // Pick sale: cancelling frees the pick to be billed again.
    const before = await tagged();
    const pick = await s.api('POST', '/warehouse/picks', { locationId: s.loc, lines: [{ itemId: item, qty: 2 }] });
    const sale = await s.api('POST', `/warehouse/picks/${pick.body.refId}/invoice`, { partyId: s.customer.id });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    expect((await s.api('POST', `/invoices/${sale.body.invoice.id}/cancel`, { reason: 'Mistake entry' })).status).toBe(200);
    expect(await tagged()).toBe(before);
    expect((await s.api('POST', `/warehouse/picks/${pick.body.refId}/invoice`, { partyId: s.customer.id })).status).toBe(201);
    // Cancelling the purchase takes out what the bins still hold of it.
    const rest = await s.api('POST', `/invoices/${inv.body.id}/cancel`, { reason: 'Mistake entry' });
    expect(rest.status).toBeLessThan(500);
    expect(pur.status).toBe(201);
    const p2 = await s.api('POST', '/purchases', { locationId: s.loc, partyId: s.vendor.id, lines: [{ itemId: item, qty: 5, rate: 10, batchNo: 'B2', expiry: day(120) }] });
    expect(p2.status, JSON.stringify(p2.body)).toBe(201);
    const t3 = await tagged();
    expect((await s.api('POST', `/purchases/${p2.body.id}/cancel`, { reason: 'Wrong bill' })).status).toBe(200);
    expect(await tagged()).toBe(t3 - 5);
  });

  it('refuses to cancel a purchase whose received serials were already sold', async () => {
    const s = await shop();
    const bin = (await s.api('POST', '/warehouse/bins', { locationId: s.loc, code: 'V1' })).body;
    const ser = (await s.api('POST', '/items', { name: 'Serial sold', sku: 'SER8', hsnCode: '8517', unit: 'nos', gstRate: 18, salePrice: 90, purchasePrice: 50, trackStock: true })).body.id as string;
    await s.api('PUT', `/warehouse/items/${ser}`, { tracking: 'serial', defaultBinId: bin.id });
    const p = await s.api('POST', '/purchases', { locationId: s.loc, partyId: s.vendor.id, lines: [{ itemId: ser, qty: 2, rate: 50, serials: ['SD-A', 'SD-B'] }] });
    expect(p.status, JSON.stringify(p.body)).toBe(201);
    const pk = await s.api('POST', '/warehouse/picks', { locationId: s.loc, lines: [{ itemId: ser, qty: 1, serialNos: ['SD-A'] }] });
    expect(pk.status, JSON.stringify(pk.body)).toBe(201);
    const stockBefore = (await s.api('GET', `/warehouse/stock?locationId=${s.loc}&itemId=${ser}`)).body;
    const serialsBefore = (await s.api('GET', `/warehouse/serials?itemId=${ser}`)).body.data;
    const cancel = await s.api('POST', `/purchases/${p.body.id}/cancel`, { reason: 'Wrong bill' });
    expect(cancel.status, JSON.stringify(cancel.body)).toBe(409);
    expect((await s.api('GET', `/purchases/${p.body.id}`)).body.status).not.toBe('cancelled');
    expect((await s.api('GET', `/warehouse/stock?locationId=${s.loc}&itemId=${ser}`)).body).toEqual(stockBefore);
    expect((await s.api('GET', `/warehouse/serials?itemId=${ser}`)).body.data).toEqual(serialsBefore);
  });

  it('undoes a return in the bins and retires serials of a cancelled purchase', async () => {
    const s = await shop();
    const bin = (await s.api('POST', '/warehouse/bins', { locationId: s.loc, code: 'U1' })).body;
    const item = (await s.api('POST', '/items', { name: 'Ux', sku: 'UX1', hsnCode: '3004', unit: 'nos', gstRate: 5, salePrice: 20, purchasePrice: 10, trackStock: true })).body.id as string;
    await s.api('PUT', `/warehouse/items/${item}`, { tracking: 'batch', defaultBinId: bin.id });
    await s.api('POST', '/purchases', { locationId: s.loc, partyId: s.vendor.id, lines: [{ itemId: item, qty: 10, rate: 10, batchNo: 'U-1' }] });
    const tagged = async () => (await s.api('GET', `/warehouse/stock?locationId=${s.loc}&itemId=${item}`)).body.summary.tagged;
    const inv = await s.api('POST', '/invoices', { locationId: s.loc, partyId: s.customer.id, lines: [{ itemId: item, qty: 6 }] });
    const ret = await s.api('POST', '/credit-notes', { invoiceId: inv.body.id, reason: 'Returned', lines: [{ invoiceLineId: inv.body.lines[0].id, qty: 2 }] });
    expect(await tagged()).toBe(6);
    expect((await s.api('POST', `/credit-notes/${ret.body.id}/cancel`, { reason: 'Undo return' })).status).toBe(200);
    expect(await tagged()).toBe(4);
    // Returned units sold again: the cancel is refused.
    const ret2 = await s.api('POST', '/credit-notes', { invoiceId: inv.body.id, reason: 'Returned', lines: [{ invoiceLineId: inv.body.lines[0].id, qty: 2 }] });
    await s.api('POST', '/invoices', { locationId: s.loc, partyId: s.customer.id, lines: [{ itemId: item, qty: 6 }] });
    expect((await s.api('POST', `/credit-notes/${ret2.body.id}/cancel`, { reason: 'Undo return' })).status).toBe(409);

    const ser = (await s.api('POST', '/items', { name: 'Serialled', sku: 'SER9', hsnCode: '8517', unit: 'nos', gstRate: 18, salePrice: 90, purchasePrice: 50, trackStock: true })).body.id as string;
    await s.api('PUT', `/warehouse/items/${ser}`, { tracking: 'serial', defaultBinId: bin.id });
    const p = await s.api('POST', '/purchases', { locationId: s.loc, partyId: s.vendor.id, lines: [{ itemId: ser, qty: 2, rate: 50, serials: ['SN-A', 'SN-B'] }] });
    expect(p.status, JSON.stringify(p.body)).toBe(201);
    expect((await s.api('POST', `/purchases/${p.body.id}/cancel`, { reason: 'Wrong bill' })).status).toBe(200);
    const left = (await s.api('GET', `/warehouse/serials?itemId=${ser}&status=in_stock`)).body.data;
    expect(left.length).toBe(0);
  });
});
