import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { financialYear, todayIst } from '../src/lib/dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const PASSWORD = 'Secret@123';
const today = todayIst();

async function biz(name: string) {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const token = signup.body.accessToken as string;
  const claims = JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1', stateCode: '24' })).body;
  const wh2 = (await api('POST', '/locations', { type: 'warehouse', name: 'Second', code: 'WH2', stateCode: '24' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const local = (await api('POST', '/parties', { type: 'customer', name: 'Local Buyer', stateCode: '24' })).body;
  const buyer = (await api('POST', '/parties', { type: 'customer', name: 'Overseas Buyer', stateCode: '24' })).body;
  const sezUnit = (await api('POST', '/parties', { type: 'customer', name: 'SEZ Unit', stateCode: '27', gstin: '27AAAAA0000A1Z5' })).body;
  const mk = async (sku: string, price: number, track = true) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, hsnCode: '6907', unit: 'nos', gstRate: 18, salePrice: price, purchasePrice: 60, trackStock: track });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string };
  };
  const goods = await mk('GD1', 100);
  const scrap = await mk('SC1', 1000);
  const buy = await api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId: goods.id, qty: 100, rate: 60 }, { itemId: scrap.id, qty: 100, rate: 60 }] });
  expect(buy.status, JSON.stringify(buy.body)).toBe(201);
  const bank = (await api('GET', '/accounts?subtype=bank')).body;
  const bankId = (bank.data ?? bank).find((a: any) => a.subtype === 'bank').id as string;
  const q = <T>(fn: (tx: any) => Promise<T>) => withTenant(env.db, claims.tid as string, fn);
  const qty = (itemId: string, locId: string) => q(async (tx) => Number((await tx.selectFrom('stock_moves').select((eb: any) => eb.fn.sum('qty').as('s'))
    .where('item_id', '=', itemId).where('location_id', '=', locId).executeTakeFirst()).s ?? 0));
  const balance = (accountName: string) => q(async (tx) => {
    const r = await tx.selectFrom('journal_lines as jl').innerJoin('accounts as a', 'a.id', 'jl.account_id').select((eb: any) => [eb.fn.sum('jl.debit').as('d'), eb.fn.sum('jl.credit').as('c')])
      .where('a.company_id', '=', companyId).where('a.name', '=', accountName).executeTakeFirst();
    return Math.round((Number(r.d ?? 0) - Number(r.c ?? 0)) * 100) / 100;
  });
  return { api, wh, wh2, vendor, local, buyer, sezUnit, goods, scrap, bankId, qty, balance, q };
}

describe('delivery challans', () => {
  it('moves stock out on challan, takes returns and bills the rest', async () => {
    const b = await biz('Challan Co');
    const make = await b.api('POST', '/delivery-challans', {
      locationId: b.wh.id, reason: 'supply_on_approval', partyId: b.local.id, vehicleNo: 'GJ01AB1234',
      lines: [{ itemId: b.goods.id, qty: 10, rate: 100 }],
    });
    expect(make.status, JSON.stringify(make.body)).toBe(201);
    const ch = make.body;
    expect(ch.number).toMatch(/^DC\//);
    expect(ch.taxableTotal).toBe(1000);
    expect(ch.taxTotal).toBe(180);
    expect(await b.qty(b.goods.id, b.wh.id)).toBe(90);
    expect(await b.balance('Stock out on Challan')).toBe(600);

    const ret = await b.api('POST', `/delivery-challans/${ch.id}/return`, { lines: [{ lineId: ch.lines[0].id, qty: 3 }] });
    expect(ret.status, JSON.stringify(ret.body)).toBe(200);
    expect(ret.body.status).toBe('partly_closed');
    expect(await b.qty(b.goods.id, b.wh.id)).toBe(93);
    expect((await b.api('POST', `/delivery-challans/${ch.id}/return`, { lines: [{ lineId: ch.lines[0].id, qty: 9 }] })).status).toBe(400);

    const conv = await b.api('POST', `/delivery-challans/${ch.id}/invoice`, { lines: [{ lineId: ch.lines[0].id, qty: 4 }] });
    expect(conv.status, JSON.stringify(conv.body)).toBe(201);
    expect(conv.body.invoice.subtotal).toBe(400);
    expect(conv.body.challan.lines[0].pendingQty).toBe(3);
    expect(await b.qty(b.goods.id, b.wh.id)).toBe(93);

    const last = await b.api('POST', `/delivery-challans/${ch.id}/return`, { lines: [{ lineId: ch.lines[0].id, qty: 3 }] });
    expect(last.body.status).toBe('closed');
    expect(await b.balance('Stock out on Challan')).toBe(0);
    expect((await b.api('POST', `/delivery-challans/${ch.id}/cancel`, { reason: 'Entered wrong' })).status).toBe(409);
  });

  it('transfers between locations, blocks billing a job work challan and cancels', async () => {
    const b = await biz('Transfer Co');
    const t = await b.api('POST', '/delivery-challans', { locationId: b.wh.id, toLocationId: b.wh2.id, reason: 'branch_transfer', lines: [{ itemId: b.goods.id, qty: 5 }] });
    expect(t.status, JSON.stringify(t.body)).toBe(201);
    expect(await b.qty(b.goods.id, b.wh.id)).toBe(95);
    expect(await b.qty(b.goods.id, b.wh2.id)).toBe(5);
    expect((await b.api('POST', `/delivery-challans/${t.body.id}/cancel`, { reason: 'Changed plan' })).body.status).toBe('cancelled');
    expect(await b.qty(b.goods.id, b.wh.id)).toBe(100);
    expect(await b.qty(b.goods.id, b.wh2.id)).toBe(0);

    const j = await b.api('POST', '/delivery-challans', { locationId: b.wh.id, reason: 'job_work', partyId: b.local.id, lines: [{ itemId: b.goods.id, qty: 5 }] });
    expect(j.status).toBe(201);
    expect((await b.api('POST', `/delivery-challans/${j.body.id}/invoice`, {})).status).toBe(400);
    expect((await b.api('POST', '/delivery-challans', { locationId: b.wh.id, reason: 'other', lines: [{ itemId: b.goods.id, qty: 1 }] })).status).toBe(400);
    expect((await b.api('POST', '/delivery-challans', { locationId: b.wh.id, reason: 'other', partyId: b.local.id, lines: [{ itemId: b.goods.id, qty: 500 }] })).status).toBe(409);
  });
});

describe('export and SEZ invoices', () => {
  it('refuses LUT without a valid LUT, then bills without tax; IGST export charges tax', async () => {
    const b = await biz('Export Co');
    const body = (category: string, partyId = b.buyer.id) => ({
      locationId: b.wh.id, partyId, exportInfo: { category, shippingBillNo: 'SB123', shippingBillDate: today, portCode: 'INMUN1', country: 'United States' },
      lines: [{ itemId: b.goods.id, qty: 10, rate: 100 }],
    });
    const refused = await b.api('POST', '/invoices', body('export_lut'));
    expect(refused.status).toBe(400);
    expect(JSON.stringify(refused.body)).toContain('Letter of Undertaking');

    const lut = await b.api('POST', '/export/luts', { fy: financialYear(today), lutNo: 'AD240000000001A', validFrom: `${today.slice(0, 4)}-01-01`, validTo: `${Number(today.slice(0, 4)) + 1}-12-31` });
    expect(lut.status, JSON.stringify(lut.body)).toBe(201);
    const ok = await b.api('POST', '/invoices', body('export_lut'));
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(ok.body.taxTotal).toBe(0);
    expect(ok.body.total).toBe(1000);
    expect(ok.body.placeOfSupply).toBe('96');
    expect(ok.body.ext.declaration).toContain('UNDER BOND OR LETTER OF UNDERTAKING WITHOUT PAYMENT');
    expect(ok.body.ext.lutNo).toBe('AD240000000001A');

    const withTax = await b.api('POST', '/invoices', body('export_igst'));
    expect(withTax.status, JSON.stringify(withTax.body)).toBe(201);
    expect(withTax.body.igst).toBe(180);
    expect(withTax.body.cgst).toBe(0);
    expect(withTax.body.total).toBe(1180);
    expect(withTax.body.ext.declaration).toContain('ON PAYMENT OF INTEGRATED TAX');

    const sez = await b.api('POST', '/invoices', body('sez_igst', b.sezUnit.id));
    expect(sez.status, JSON.stringify(sez.body)).toBe(201);
    expect(sez.body.igst).toBe(180);
    expect((await b.api('POST', '/invoices', body('sez_igst', b.local.id))).status).toBe(400);
    const normal = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.local.id, lines: [{ itemId: b.goods.id, qty: 1, rate: 100 }] });
    expect(normal.status).toBe(201);
    expect(normal.body.ext).toBeNull();

    const g = await b.api('GET', `/gst/gstr1?period=${today.slice(0, 7)}`);
    expect(g.status, JSON.stringify(g.body)).toBe(200);
    const r = g.body;
    expect(r.exp.map((e: any) => e.exportType).sort()).toEqual(['WOPAY', 'WPAY']);
    expect(r.exp[0].shippingBillNo).toBe('SB123');
    expect(r.sez).toHaveLength(1);
    expect(r.sez[0].invTyp).toBe('SEWP');
    expect(r.b2b).toHaveLength(0);
    expect(r.b2cs.reduce((s: number, x: any) => s + x.taxable, 0)).toBe(100);
    expect(r.variance).toEqual({ igst: 0, cgst: 0, sgst: 0 });

    const b3 = await b.api('GET', `/gst/gstr3b?period=${today.slice(0, 7)}`);
    expect(b3.status, JSON.stringify(b3.body)).toBe(200);
    expect(b3.body.zeroRated.taxable).toBe(3000);
    expect(b3.body.zeroRated.igst).toBe(360);
  });
});

describe('multi-currency', () => {
  it('posts a foreign invoice in rupees, books realised gain and loss, and revalues', async () => {
    const b = await biz('Currency Co');
    const cur = await b.api('GET', '/fx/currencies');
    expect(cur.body.data.map((c: any) => c.code)).toContain('USD');
    expect((await b.api('POST', '/fx/rates', { code: 'USD', date: today, rate: 80, note: 'Manual' })).status).toBe(201);
    expect((await b.api('GET', `/fx/rates/latest?code=USD&date=${today}`)).body.rate).toBe(80);

    // 100 nos at USD 2 = USD 200 = INR 16,000 taxable; export under IGST: 18% = 2,880.
    const inv = await b.api('POST', '/invoices', {
      locationId: b.wh.id, partyId: b.buyer.id, currency: { code: 'USD' },
      exportInfo: { category: 'export_igst' }, lines: [{ itemId: b.goods.id, qty: 100, rate: 2 }],
    });
    expect(inv.status, JSON.stringify(inv.body)).toBe(201);
    expect(inv.body.subtotal).toBe(16000);
    expect(inv.body.total).toBe(18880);
    expect(inv.body.ext.currencyCode).toBe('USD');
    expect(inv.body.ext.exchangeRate).toBe(80);
    expect(inv.body.ext.fcTotal).toBe(236);
    expect(await b.balance('Accounts Receivable')).toBe(18880);

    const bad = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.buyer.id, currency: { code: 'CHF', rate: 90 }, lines: [{ itemId: b.goods.id, qty: 1, rate: 1 }] });
    expect(bad.status).toBe(400);

    const open = await b.api('GET', `/fx/outstanding?partyId=${b.buyer.id}&currency=USD`);
    expect(open.body.data[0].fcOutstanding).toBe(236);

    // Receive USD 100 at 82: gain of 100 x (82 - 80) = 200.
    const rc = await b.api('POST', '/fx/receipts', { partyId: b.buyer.id, accountId: b.bankId, currency: 'USD', fcAmount: 100, rate: 82 });
    expect(rc.status, JSON.stringify(rc.body)).toBe(201);
    expect(rc.body.fx.inrReceived).toBe(8200);
    expect(rc.body.fx.inrCleared).toBe(8000);
    expect(rc.body.fx.gainLoss).toBe(200);
    expect(await b.balance('Exchange Rate Gain or Loss')).toBe(-200);
    expect(await b.balance('Accounts Receivable')).toBe(10880);

    // Revalue the remaining USD 136 at 85: carrying 10,880 becomes 11,560, an adjustment of 680, reversed next day.
    const prev = await b.api('POST', '/fx/revaluation/preview', { asOf: today, rates: { USD: 85 } });
    expect(prev.body.total).toBe(680);
    const rev = await b.api('POST', '/fx/revaluation', { asOf: today, rates: { USD: 85 } });
    expect(rev.status, JSON.stringify(rev.body)).toBe(201);
    expect(await b.balance('Accounts Receivable')).toBe(10880);
    expect(await b.balance('Exchange Rate Gain or Loss')).toBe(-200);
    expect((await b.api('POST', '/fx/revaluation', { asOf: today, rates: { USD: 85 } })).status).toBe(409);

    // Settle the rest at 78: USD 136 clears INR 10,880 and receives 10,608, a loss of 272.
    const rest = await b.api('POST', '/fx/receipts', { partyId: b.buyer.id, accountId: b.bankId, currency: 'USD', fcAmount: 136, rate: 78 });
    expect(rest.status, JSON.stringify(rest.body)).toBe(201);
    expect(rest.body.fx.gainLoss).toBe(-272);
    expect(await b.balance('Accounts Receivable')).toBe(0);
    expect(await b.balance('Exchange Rate Gain or Loss')).toBe(72);
    const full = await b.api('GET', `/invoices/${inv.body.id}`);
    expect(full.body.paymentStatus ?? full.body.status).toBeTruthy();
  });
});

describe('TCS on sales', () => {
  it('is off until switched on, then adds TCS on top of the total and reports it', async () => {
    const b = await biz('Tcs Co');
    const plain = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.local.id, lines: [{ itemId: b.scrap.id, qty: 10, rate: 1000 }] });
    expect(plain.body.total).toBe(11800);
    expect(plain.body.ext).toBeNull();

    const natures = (await b.api('GET', '/tcs/natures')).body.data as any[];
    const scrapN = natures.find((n) => n.code === 'scrap');
    expect(scrapN.rate).toBe(1);
    expect(natures.some((n) => /1H/.test(n.sectionOld))).toBe(false);
    expect((await b.api('PUT', '/tcs/items/' + b.scrap.id, { natureId: scrapN.id })).status).toBe(200);
    expect((await b.api('PUT', '/export/settings', { tcsEnabled: true })).status).toBe(200);

    // The buyer has no PAN, so 206CC lifts the rate to 5% (twice 1% is below 5%): 5% of 10,000 = 500.
    const inv = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.local.id, lines: [{ itemId: b.scrap.id, qty: 10, rate: 1000 }] });
    expect(inv.status, JSON.stringify(inv.body)).toBe(201);
    expect(inv.body.subtotal).toBe(10000);
    expect(inv.body.taxTotal).toBe(1800);
    expect(inv.body.ext.tcsAmount).toBe(500);
    expect(inv.body.total).toBe(12300);
    expect(await b.balance('TCS Payable')).toBe(-500);

    const off = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.local.id, tcs: { off: true }, lines: [{ itemId: b.scrap.id, qty: 1, rate: 1000 }] });
    expect(off.body.ext).toBeNull();
    const other = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.local.id, lines: [{ itemId: b.goods.id, qty: 1, rate: 100 }] });
    expect(other.body.ext).toBeNull();

    const rep = await b.api('GET', `/tcs/report?from=${today.slice(0, 7)}-01&to=${today}`);
    expect(rep.status, JSON.stringify(rep.body)).toBe(200);
    expect(rep.body.total).toBe(500);
    expect(rep.body.data).toHaveLength(1);
    expect(rep.body.missingPan).toBe(1);
  });
});
