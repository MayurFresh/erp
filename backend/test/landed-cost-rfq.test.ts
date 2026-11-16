import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { allocate } from '../src/modules/landed-cost.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

const sum = (a: number[]) => Math.round(a.reduce((s, x) => s + x, 0) * 100) / 100;

async function biz() {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'LC Co', name: 'Owner One', email: uniqueEmail('owner'), password: 'Secret@123', stateCode: '24',
  });
  expect(signup.status).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, signup.body.accessToken, me.companies[0].id as string);
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const vendor2 = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor Two', stateCode: '24' })).body;
  const mk = async (name: string, sku: string) => (await api('POST', '/items', {
    name, sku, hsnCode: '2523', unit: 'nos', gstRate: 18, salePrice: 500, purchasePrice: 100, trackStock: true,
  })).body;
  const [a, b, c, d] = [await mk('Item A', 'LA'), await mk('Item B', 'LB'), await mk('Item C', 'LC'), await mk('Item D', 'LD')];
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string }[];
  const account = (code: string) => accounts.find((x) => x.code === code)!;
  return { api, wh, vendor, vendor2, a, b, c, d, account };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const buy = async (b: Biz, lines: [any, number, number][]) => {
  const r = await b.api('POST', '/purchases', {
    locationId: b.wh.id, partyId: b.vendor.id, lines: lines.map(([i, qty, rate]) => ({ itemId: i.id, qty, rate })),
  });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body;
};
const stockOf = async (b: Biz, itemId: string) => {
  const rows = (await b.api('GET', '/stock?limit=200')).body.data as { itemId: string; qty: number; value: number }[];
  const r = rows.filter((x) => x.itemId === itemId);
  return { qty: r.reduce((s, x) => s + x.qty, 0), value: Math.round(r.reduce((s, x) => s + x.value, 0) * 100) / 100 };
};
const tbRow = async (b: Biz, code: string) => {
  const tb = (await b.api('GET', '/reports/trial-balance')).body;
  expect(tb.totalDebit).toBe(tb.totalCredit);
  const row = tb.rows.find((r: any) => r.code === code);
  return row ? Math.round((row.debit - row.credit) * 100) / 100 : 0;
};

describe('allocate', () => {
  it('adds up to the total and gives the remainder to the largest line', () => {
    const v = allocate(100, [1000, 1000, 300]);
    expect(sum(v)).toBe(100);
    expect(v).toEqual([43.49, 43.47, 13.04]);
    expect(allocate(100, [10, 20, 30])).toEqual([16.66, 33.33, 50.01]);
    expect(allocate(100, [1, 1, 2])).toEqual([25, 25, 50]);
    expect(allocate(50, [0, 0])).toEqual([0, 0]);
  });
});

describe('landed cost', () => {
  it('allocates by value, quantity and weight', async () => {
    const b = await biz();
    const bill = await buy(b, [[b.a, 10, 100], [b.b, 20, 50], [b.c, 30, 10]]);
    const base = {
      docs: [{ docType: 'purchase', docId: bill.id }],
      charges: [{ kind: 'freight', amount: 100, creditAccountId: b.account('1000').id }],
    };
    const byValue = await b.api('POST', '/landed-costs/preview', { ...base, basis: 'value' });
    expect(byValue.status, JSON.stringify(byValue.body)).toBe(200);
    expect(sum(byValue.body.lines.map((l: any) => l.allocated))).toBe(100);
    expect(byValue.body.lines.map((l: any) => l.allocated)).toEqual([43.49, 43.47, 13.04]);
    expect(byValue.body.id).toBeNull();

    const byQty = await b.api('POST', '/landed-costs/preview', { ...base, basis: 'qty' });
    expect(byQty.body.lines.map((l: any) => l.allocated)).toEqual([16.66, 33.33, 50.01]);

    const noWeights = await b.api('POST', '/landed-costs/preview', { ...base, basis: 'weight' });
    expect(noWeights.status).toBe(400);
    const w = bill.lines.map((l: any, i: number) => ({ docLineId: l.id, weight: [1, 1, 2][i] }));
    const byWeight = await b.api('POST', '/landed-costs/preview', { ...base, basis: 'weight', weights: w });
    expect(byWeight.body.lines.map((l: any) => l.allocated)).toEqual([25, 25, 50]);
    expect(byWeight.body.lines[2].landedUnitCost).toBe(11.6667);
  });

  it('splits sold quantity to cost of goods sold, posts the journal and cancels fully', async () => {
    const b = await biz();
    const bill = await buy(b, [[b.d, 10, 100]]);
    const sale = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: (await b.api('POST', '/parties', { type: 'customer', name: 'Cust', stateCode: '24' })).body.id, lines: [{ itemId: b.d.id, qty: 4 }] });
    expect(sale.status, JSON.stringify(sale.body)).toBe(201);
    const before = await stockOf(b, b.d.id);
    expect(before).toEqual({ qty: 6, value: 600 });
    const inv0 = await tbRow(b, '1200');
    const cogs0 = await tbRow(b, '5000');
    const cash0 = await tbRow(b, '1000');

    const made = await b.api('POST', '/landed-costs', {
      basis: 'value', docs: [{ docType: 'purchase', docId: bill.id }],
      charges: [
        { kind: 'freight', amount: 150, creditAccountId: b.account('1000').id },
        { kind: 'customs_duty', amount: 50, igstAmount: 18, creditAccountId: b.account('1000').id },
      ],
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    expect(made.body).toMatchObject({ status: 'posted', chargesTotal: 200, igstTotal: 18, inventoryTotal: 120, cogsTotal: 80 });
    expect(made.body.lines[0]).toMatchObject({ onHandPct: 60, allocated: 200, toInventory: 120, toCogs: 80, landedUnitCost: 120 });
    expect(await stockOf(b, b.d.id)).toEqual({ qty: 6, value: 720 });
    expect(await tbRow(b, '1200') - inv0).toBe(120);
    expect(await tbRow(b, '5000') - cogs0).toBe(80);
    expect(await tbRow(b, '1000') - cash0).toBe(-218);

    const report = await b.api('GET', `/landed-costs/report?docId=${bill.id}`);
    expect(report.body.data).toHaveLength(1);
    expect(report.body.data[0]).toMatchObject({ docNumber: bill.number, allocated: 200, landedValue: 1200, landedUnitCost: 120 });
    expect(report.body.totals.allocated).toBe(200);

    const cancel = await b.api('POST', `/landed-costs/${made.body.id}/cancel`, { reason: 'Wrong bill' });
    expect(cancel.status, JSON.stringify(cancel.body)).toBe(200);
    expect(cancel.body.status).toBe('cancelled');
    expect(await stockOf(b, b.d.id)).toEqual({ qty: 6, value: 600 });
    expect(await tbRow(b, '1200')).toBe(inv0);
    expect(await tbRow(b, '5000')).toBe(cogs0);
    expect(await tbRow(b, '1000')).toBe(cash0);
    expect((await b.api('POST', `/landed-costs/${made.body.id}/cancel`, { reason: 'Again' })).body.error.code).toBe('ALREADY_CANCELLED');
    expect((await b.api('GET', '/landed-costs/report')).body.data).toHaveLength(0);
    expect((await b.api('GET', '/landed-costs?status=cancelled')).body.total).toBe(1);
  });

  it('takes the charge from an expense once and rejects a missing credit side', async () => {
    const b = await biz();
    const bill = await buy(b, [[b.a, 10, 100]]);
    const exp = await b.api('POST', '/expenses', {
      locationId: b.wh.id, accountId: (b.account('6070') ?? b.account('1000')).id, description: 'Freight inward', amount: 300,
      paidFromAccountId: b.account('1000').id,
    });
    expect(exp.status, JSON.stringify(exp.body)).toBe(201);
    const body = (amount: number) => ({
      basis: 'qty', docs: [{ docType: 'purchase', docId: bill.id }],
      charges: [{ kind: 'freight', amount, sourceType: 'expense', sourceId: exp.body.id }],
    });
    expect((await b.api('POST', '/landed-costs', body(400))).status).toBe(400);
    const ok = await b.api('POST', '/landed-costs', body(300));
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(await stockOf(b, b.a.id)).toEqual({ qty: 10, value: 1300 });
    const again = await b.api('POST', '/landed-costs', body(100));
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('SOURCE_USED');
    const none = await b.api('POST', '/landed-costs', { basis: 'qty', docs: [{ docType: 'purchase', docId: bill.id }], charges: [{ kind: 'freight', amount: 10 }] });
    expect(none.status).toBe(400);
  });
});

describe('request for quotation', () => {
  it('compares quotes, picks per line and creates one order per vendor', async () => {
    const b = await biz();
    const created = await b.api('POST', '/rfqs', {
      locationId: b.wh.id, vendorIds: [b.vendor.id, b.vendor2.id],
      lines: [{ itemId: b.a.id, qty: 10 }, { itemId: b.b.id, qty: 20 }],
    });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const rfq = created.body;
    expect(rfq.status).toBe('draft');
    expect(rfq.number).toMatch(/^RFQ\//);
    const [l1, l2] = rfq.lines;
    const early = await b.api('PUT', `/rfqs/${rfq.id}/quotes`, { partyId: b.vendor.id, quotes: [] });
    expect(early.status).toBe(409);

    const sent = await b.api('POST', `/rfqs/${rfq.id}/send`);
    expect(sent.body.status).toBe('sent');
    expect(sent.body.vendors.every((v: any) => v.sentAt)).toBe(true);

    const q1 = await b.api('PUT', `/rfqs/${rfq.id}/quotes`, { partyId: b.vendor.id, quotes: [
      { lineId: l1.id, rate: 100, gstRate: 18, leadDays: 7, paymentTerms: '30 days' },
      { lineId: l2.id, rate: 50, discountPct: 10, gstRate: 18, leadDays: 3 },
    ] });
    expect(q1.status, JSON.stringify(q1.body)).toBe(200);
    expect(q1.body.status).toBe('quotes_received');
    const q2 = await b.api('PUT', `/rfqs/${rfq.id}/quotes`, { partyId: b.vendor2.id, quotes: [
      { lineId: l1.id, rate: 95, gstRate: 18, leadDays: 10 },
      { lineId: l2.id, rate: 60, gstRate: 18, leadDays: 2 },
    ] });
    const lines = q2.body.lines;
    const quote = (li: number, party: string) => lines[li].quotes.find((q: any) => q.partyId === party);
    expect(quote(0, b.vendor2.id)).toMatchObject({ taxable: 950, total: 1121, isLowest: true, isFastest: false });
    expect(quote(0, b.vendor.id)).toMatchObject({ total: 1180, isLowest: false, isFastest: true });
    expect(quote(1, b.vendor.id)).toMatchObject({ taxable: 900, total: 1062, isLowest: true, isFastest: false });
    expect(quote(1, b.vendor2.id)).toMatchObject({ isLowest: false, isFastest: true });

    const bad = await b.api('PUT', `/rfqs/${rfq.id}/choices`, { choices: [{ lineId: l1.id, partyId: NIL }] });
    expect(bad.status).toBe(400);
    const picked = await b.api('PUT', `/rfqs/${rfq.id}/choices`, { mode: 'lowest' });
    expect(picked.status, JSON.stringify(picked.body)).toBe(200);
    expect(picked.body.lines.map((l: any) => l.chosenPartyId)).toEqual([b.vendor2.id, b.vendor.id]);

    const conv = await b.api('POST', `/rfqs/${rfq.id}/convert`);
    expect(conv.status, JSON.stringify(conv.body)).toBe(200);
    expect(conv.body.status).toBe('closed');
    expect(conv.body.purchaseOrders).toHaveLength(2);
    const po = (await b.api('GET', `/purchase-orders/${conv.body.lines[0].purchaseOrderId}`)).body;
    expect(po).toMatchObject({ partyId: b.vendor2.id, status: 'draft' });
    expect(po.lines[0]).toMatchObject({ qty: 10, rate: 95 });
    const po2 = (await b.api('GET', `/purchase-orders/${conv.body.lines[1].purchaseOrderId}`)).body;
    expect(po2.lines[0]).toMatchObject({ qty: 20, rate: 50, discountPct: 10 });
    expect((await b.api('POST', `/rfqs/${rfq.id}/convert`)).status).toBe(409);
  });

  it('edits and deletes only drafts, and lists by status', async () => {
    const b = await biz();
    const r = await b.api('POST', '/rfqs', { locationId: b.wh.id, vendorIds: [b.vendor.id], lines: [{ itemId: b.a.id, qty: 5 }] });
    const upd = await b.api('PUT', `/rfqs/${r.body.id}`, { locationId: b.wh.id, vendorIds: [b.vendor.id], lines: [{ itemId: b.a.id, qty: 8 }] });
    expect(upd.body.lines[0].qty).toBe(8);
    expect((await b.api('GET', '/rfqs?status=draft')).body.total).toBe(1);
    await b.api('POST', `/rfqs/${r.body.id}/send`);
    expect((await b.api('PUT', `/rfqs/${r.body.id}`, { locationId: b.wh.id, vendorIds: [b.vendor.id], lines: [{ itemId: b.a.id, qty: 9 }] })).status).toBe(409);
    expect((await b.api('DELETE', `/rfqs/${r.body.id}`)).status).toBe(409);
    expect((await b.api('POST', `/rfqs/${r.body.id}/close`)).body.status).toBe('closed');
    const none = await b.api('POST', '/rfqs', { locationId: b.wh.id, vendorIds: [b.vendor.id] });
    expect(none.status).toBe(400);
  });
});

const NIL = '00000000-0000-4000-8000-000000000000';
