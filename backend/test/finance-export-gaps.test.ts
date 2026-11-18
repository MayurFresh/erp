import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { todayIst } from '../src/lib/dates.ts';
import { countryCode, supplyTypeOf } from '../src/lib/einvoice-payload.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const today = todayIst();

async function biz() {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Gap Co', name: 'Owner One', email: uniqueEmail('owner'), password: 'Secret@123', stateCode: '24', gstin: '24AAACD1234F1Z5',
  });
  expect(signup.status).toBe(201);
  const token = signup.body.accessToken as string;
  const claims = JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  await api('PATCH', '/company', { pincode: '380054', address: 'SG Highway, Ahmedabad' });
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1', stateCode: '24' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const local = (await api('POST', '/parties', { type: 'customer', name: 'Local Buyer', stateCode: '24' })).body;
  const abroad = (await api('POST', '/parties', { type: 'customer', name: 'Overseas Buyer', stateCode: '24' })).body;
  const sez = (await api('POST', '/parties', { type: 'customer', name: 'SEZ Unit', stateCode: '27', gstin: '27AAPFU0939F1ZV', pincode: '400001' })).body;
  const mk = async (sku: string, price: number) => (await api('POST', '/items', { name: `Item ${sku}`, sku, hsnCode: '6907', unit: 'nos', gstRate: 18, salePrice: price, purchasePrice: 60, trackStock: true })).body;
  const goods = await mk('GD1', 100);
  const scrap = await mk('SC1', 1000);
  const buy = await api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId: goods.id, qty: 100, rate: 60 }, { itemId: scrap.id, qty: 100, rate: 60 }] });
  expect(buy.status, JSON.stringify(buy.body)).toBe(201);
  const balance = (accountName: string) => withTenant(env.db, claims.tid as string, async (tx: any) => {
    const r = await tx.selectFrom('journal_lines as jl').innerJoin('accounts as a', 'a.id', 'jl.account_id').select((eb: any) => [eb.fn.sum('jl.debit').as('d'), eb.fn.sum('jl.credit').as('c')])
      .where('a.company_id', '=', companyId).where('a.name', '=', accountName).executeTakeFirst();
    return Math.round((Number(r.d ?? 0) - Number(r.c ?? 0)) * 100) / 100;
  });
  return { api, wh, vendor, local, abroad, sez, goods, scrap, balance, bill: buy.body };
}

describe('e-invoice supply types', () => {
  it('maps categories to NIC supply types', () => {
    expect(supplyTypeOf('export_igst')).toBe('EXPWP');
    expect(supplyTypeOf('export_lut')).toBe('EXPWOP');
    expect(supplyTypeOf('sez_igst')).toBe('SEZWP');
    expect(supplyTypeOf('sez_lut')).toBe('SEZWOP');
    expect(supplyTypeOf(null)).toBe('B2B');
    expect(countryCode('United States')).toBe('US');
    expect(countryCode('de')).toBe('DE');
    expect(countryCode('Atlantis')).toBeNull();
    expect(countryCode('Brazil')).toBe('BR');
    expect(countryCode('ke')).toBe('KE');
    expect(countryCode('zz')).toBeNull();
    expect(countryCode('Viet Nam')).toBe('VN');
  });

  it('builds EXPWP with ExpDtls and SEZWP for a SEZ unit', async () => {
    const b = await biz();
    await b.api('GET', '/fx/currencies');
    await b.api('POST', '/fx/rates', { code: 'USD', date: today, rate: 80 });
    const inv = await b.api('POST', '/invoices', {
      locationId: b.wh.id, partyId: b.abroad.id, currency: { code: 'USD' },
      exportInfo: { category: 'export_igst', shippingBillNo: 'SB1234567', shippingBillDate: today, portCode: 'INMUN1', country: 'United States' },
      lines: [{ itemId: b.goods.id, qty: 10, rate: 2 }],
    });
    expect(inv.status, JSON.stringify(inv.body)).toBe(201);
    const res = await b.api('GET', `/invoices/${inv.body.id}/einvoice/payload`);
    expect(res.status, JSON.stringify(res.body)).toBe(200);
    expect(res.body.TranDtls.SupTyp).toBe('EXPWP');
    expect(res.body.BuyerDtls).toMatchObject({ Gstin: 'URP', Pos: '96', Stcd: '96', Pin: 999999 });
    expect(res.body.ExpDtls).toMatchObject({ ShipBNo: 'SB1234567', Port: 'INMUN1', RefClm: 'Y', ForCur: 'USD', CntCode: 'US' });
    expect(res.body.ExpDtls.ShipBDt).toMatch(/^\d{2}\/\d{2}\/\d{4}$/);

    const sez = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.sez.id, exportInfo: { category: 'sez_igst' }, lines: [{ itemId: b.goods.id, qty: 1, rate: 100 }] });
    expect(sez.status, JSON.stringify(sez.body)).toBe(201);
    const r2 = await b.api('GET', `/invoices/${sez.body.id}/einvoice/payload`);
    expect(r2.status, JSON.stringify(r2.body)).toBe(200);
    expect(r2.body.TranDtls.SupTyp).toBe('SEZWP');
    expect(r2.body.BuyerDtls.Gstin).toBe('27AAPFU0939F1ZV');
  });
});

describe('credit note reverses TCS', () => {
  it('hands back TCS in proportion to the goods returned', async () => {
    const b = await biz();
    const natures = (await b.api('GET', '/tcs/natures')).body.data as any[];
    await b.api('PUT', '/tcs/items/' + b.scrap.id, { natureId: natures.find((n) => n.code === 'scrap').id });
    await b.api('PUT', '/export/settings', { tcsEnabled: true });
    const inv = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.local.id, lines: [{ itemId: b.scrap.id, qty: 10, rate: 1000 }] });
    expect(inv.body.ext.tcsAmount).toBe(500);
    expect(await b.balance('TCS Payable')).toBe(-500);
    const full = await b.api('GET', `/invoices/${inv.body.id}`);
    const lineId = full.body.lines[0].id as string;
    const cn = await b.api('POST', '/credit-notes', { invoiceId: inv.body.id, reason: 'Half returned', lines: [{ invoiceLineId: lineId, qty: 5 }] });
    expect(cn.status, JSON.stringify(cn.body)).toBe(201);
    expect(cn.body.total).toBe(5900);
    expect(cn.body.tcsReversed).toBe(250);
    expect(await b.balance('TCS Payable')).toBe(-250);
    const rest = await b.api('POST', '/credit-notes', { invoiceId: inv.body.id, reason: 'Rest returned', lines: [{ invoiceLineId: lineId, qty: 5 }] });
    expect(rest.status, JSON.stringify(rest.body)).toBe(201);
    expect(await b.balance('TCS Payable')).toBe(0);
    expect(await b.balance('Accounts Receivable')).toBe(0);
    const cancel = await b.api('POST', `/credit-notes/${rest.body.id}/cancel`, { reason: 'Mistake entered' });
    expect(cancel.status).toBe(200);
    expect(await b.balance('TCS Payable')).toBe(-250);
  });
});

describe('foreign payables revaluation', () => {
  it('posts the unrealised loss and reverses it the next day', async () => {
    const b = await biz();
    expect((await b.api('PUT', `/fx/payables/${b.bill.id}`, { currency: 'USD', rate: 80 })).status).toBe(200);
    const open = await b.api('GET', '/fx/payables');
    expect(open.body.data).toHaveLength(1);
    const total = open.body.data[0].inrOutstanding as number;
    const prev = await b.api('POST', '/fx/payables/revaluation/preview', { asOf: today, rates: { USD: 84 } });
    expect(prev.status, JSON.stringify(prev.body)).toBe(200);
    const expected = Math.round((total / 80 * 84 - total) * 100) / 100;
    expect(prev.body.total).toBe(expected);
    const before = await b.balance('Accounts Payable');
    const rev = await b.api('POST', '/fx/payables/revaluation', { asOf: today, rates: { USD: 84 } });
    expect(rev.status, JSON.stringify(rev.body)).toBe(201);
    expect(await b.balance('Accounts Payable')).toBe(before);
    expect((await b.api('POST', '/fx/payables/revaluation', { asOf: today, rates: { USD: 84 } })).status).toBe(409);
    const list = await b.api('GET', '/fx/revaluations');
    expect(list.body.data[0].kind).toBe('payable');
  });
});

describe('landed cost sources', () => {
  it('lists unallocated expenses and bills and blocks reuse', async () => {
    const b = await biz();
    const accounts = (await b.api('GET', '/accounts')).body.data as { id: string; code: string; type: string }[];
    const exp = await b.api('POST', '/expenses', { locationId: b.wh.id, accountId: (accounts.find((a) => a.code === '6070') ?? accounts.find((a) => a.code.startsWith('6'))!).id, description: 'Freight inward', amount: 300, paidFromAccountId: accounts.find((a) => a.code === '1000')!.id });
    expect(exp.status, JSON.stringify(exp.body)).toBe(201);
    const list = await b.api('GET', '/landed-costs/sources?type=expense');
    expect(list.body.data.map((x: any) => x.id)).toContain(exp.body.id);
    const bills = await b.api('GET', '/landed-costs/sources?type=vendor_bill&q=Vendor');
    expect(bills.body.data[0].id).toBe(b.bill.id);
    const make = (amount: number) => b.api('POST', '/landed-costs', { basis: 'qty', docs: [{ docType: 'purchase', docId: b.bill.id }], charges: [{ kind: 'freight', amount, sourceType: 'expense', sourceId: exp.body.id }] });
    const twice = await b.api('POST', '/landed-costs', { basis: 'qty', docs: [{ docType: 'purchase', docId: b.bill.id }], charges: [
      { kind: 'freight', amount: 100, sourceType: 'expense', sourceId: exp.body.id }, { kind: 'handling', amount: 100, sourceType: 'expense', sourceId: exp.body.id }] });
    expect(twice.status).toBe(400);
    expect((await make(300)).status).toBe(201);
    expect((await make(10)).status).toBe(409);
    const after = await b.api('GET', '/landed-costs/sources?type=expense');
    expect(after.body.data.map((x: any) => x.id)).not.toContain(exp.body.id);
  });
});
