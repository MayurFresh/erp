import { createHash } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const SELLER = '24AAACD1234F1Z5';

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Demo Traders', name: 'Owner', email: uniqueEmail('ei'), password: 'Secret@123', stateCode: '24', gstin: SELLER,
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, res.body.accessToken, me.companies[0].id);
  const ho = (await api('GET', '/locations')).body.data[0];
  const item = (await api('POST', '/items', { name: 'Cement', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 400, trackStock: false })).body;
  const noHsn = (await api('POST', '/items', { name: 'Odd job', unit: 'nos', gstRate: 18, salePrice: 100, trackStock: false })).body;
  const buyer = (await api('POST', '/parties', { type: 'customer', name: 'Mumbai Infra', gstin: '27AAPFU0939F1ZV', pincode: '400001' })).body;
  const invoice = async (partyId: string, itemId = item.id) =>
    (await api('POST', '/invoices', { locationId: ho.id, partyId, lines: [{ itemId, qty: 10 }] })).body;
  return { api, ho, item, noHsn, buyer, invoice };
}

describe('e-invoice payload', () => {
  it('names the missing data, then builds the IRP JSON', async () => {
    const b = await business();
    const noPin = (await b.api('POST', '/parties', { type: 'customer', name: 'No Pin Ltd', gstin: '27AABCT3518Q1ZW' })).body;
    const inv = await b.invoice(noPin.id, b.noHsn.id);
    const bad = await b.api('GET', `/invoices/${inv.id}/einvoice/payload`);
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('VALIDATION_ERROR');
    expect(Object.keys(bad.body.error.details).sort()).toEqual(['company.pincode', 'lines.0.hsnCode', 'party.pincode']);

    await b.api('PATCH', '/company', { pincode: '380054', address: 'SG Highway, Ahmedabad' });
    const good = await b.invoice(b.buyer.id);
    const res = await b.api('GET', `/invoices/${good.id}/einvoice/payload`);
    expect(res.status).toBe(200);
    expect(res.body).toMatchObject({
      Version: '1.1',
      TranDtls: { TaxSch: 'GST', SupTyp: 'B2B' },
      DocDtls: { Typ: 'INV', No: good.number },
      SellerDtls: { Gstin: SELLER, Pin: 380054, Stcd: '24' },
      BuyerDtls: { Gstin: '27AAPFU0939F1ZV', Pin: 400001, Stcd: '27', Pos: '27' },
      ValDtls: { AssVal: 4000, IgstVal: 720, CgstVal: 0, TotInvVal: 4720 },
    });
    expect(res.body.DocDtls.Dt).toMatch(/^\d{2}\/\d{2}\/\d{4}$/);
    expect(res.body.ItemList[0]).toMatchObject({ SlNo: '1', HsnCd: '2523', Qty: 10, Unit: 'BAG', UnitPrice: 400, AssAmt: 4000, GstRt: 18, IgstAmt: 720, TotItemVal: 4720 });
  });
});

describe('sandbox IRN and e-way bill', () => {
  it('generates, guards and cancels', async () => {
    const b = await business();
    const inv = await b.invoice(b.buyer.id);
    // Not enabled yet.
    expect((await b.api('POST', `/invoices/${inv.id}/einvoice`, {})).status).toBe(409);
    await b.api('PATCH', '/company', { pincode: '380054', einvoiceEnabled: true, einvoiceMode: 'sandbox' });

    // B2C is refused.
    const walkIn = (await b.api('POST', '/parties', { type: 'customer', name: 'Walk-in', stateCode: '24' })).body;
    const b2c = await b.invoice(walkIn.id);
    expect((await b.api('POST', `/invoices/${b2c.id}/einvoice`, {})).status).toBe(400);

    // An e-way bill needs an IRN first.
    const early = await b.api('POST', `/invoices/${inv.id}/ewaybill`, { transportMode: 'road', distanceKm: 300, vehicleNo: 'GJ01AB1234' });
    expect(early.status).toBe(409);

    const gen = await b.api('POST', `/invoices/${inv.id}/einvoice`, {});
    expect(gen.status).toBe(200);
    const e = gen.body.einvoice;
    expect(e.irn).toBe(createHash('sha256').update(`${SELLER}${inv.fy}INV${inv.number}`).digest('hex'));
    expect(e).toMatchObject({ status: 'active', sandbox: true, cancelledAt: null });
    expect(e.ackNo).toMatch(/^\d{15}$/);
    const qr = JSON.parse(Buffer.from(e.signedQrCode, 'base64url').toString());
    expect(qr).toMatchObject({ SellerGstin: SELLER, BuyerGstin: '27AAPFU0939F1ZV', DocNo: inv.number, TotInvVal: 4720, ItemCnt: 1, MainHsnCode: '2523', Irn: e.irn });
    expect((await b.api('POST', `/invoices/${inv.id}/einvoice`, {})).status).toBe(409);

    // IRN_ACTIVE blocks invoice cancellation.
    const blocked = await b.api('POST', `/invoices/${inv.id}/cancel`, { reason: 'Wrong rate' });
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('IRN_ACTIVE');

    // E-way bill: road needs a vehicle; 450 km = 3 days.
    expect((await b.api('POST', `/invoices/${inv.id}/ewaybill`, { transportMode: 'road', distanceKm: 450 })).status).toBe(400);
    const ewb = await b.api('POST', `/invoices/${inv.id}/ewaybill`, { transportMode: 'road', distanceKm: 450, vehicleNo: 'GJ01AB1234' });
    expect(ewb.status).toBe(200);
    expect(ewb.body.ewaybill).toMatchObject({ status: 'active', transportMode: 'road', vehicleNo: 'GJ01AB1234', distanceKm: 450 });
    expect(ewb.body.ewaybill.ewbNo).toMatch(/^\d{12}$/);
    const days = 3;
    const expected = new Date(Date.now() + days * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
    expect(new Date(ewb.body.ewaybill.validUntil).toISOString()).toBe(new Date(`${expected}T23:59:59+05:30`).toISOString());

    // The IRN cannot be cancelled while the e-way bill is active.
    expect((await b.api('POST', `/invoices/${inv.id}/einvoice/cancel`, { reasonCode: '2', remark: 'Typo' })).status).toBe(409);
    const ewbCancel = await b.api('POST', `/invoices/${inv.id}/ewaybill/cancel`, { reasonCode: '4', remark: 'Vehicle changed' });
    expect(ewbCancel.body.ewaybill.status).toBe('cancelled');
    const irnCancel = await b.api('POST', `/invoices/${inv.id}/einvoice/cancel`, { reasonCode: '2', remark: 'Typo' });
    expect(irnCancel.status).toBe(200);
    expect(irnCancel.body.einvoice).toMatchObject({ status: 'cancelled', cancelReason: 'Data entry mistake: Typo' });
    expect(irnCancel.body.einvoice.cancelledAt).not.toBeNull();

    // With no active IRN the invoice can be cancelled.
    expect((await b.api('POST', `/invoices/${inv.id}/cancel`, { reason: 'Wrong rate' })).status).toBe(200);
  });
});

describe('manual mode', () => {
  it('records IRN details and enforces the 24 hour cancel window', async () => {
    const b = await business();
    await b.api('PATCH', '/company', { pincode: '380054', einvoiceEnabled: true, einvoiceMode: 'manual' });
    const inv = await b.invoice(b.buyer.id);
    expect((await b.api('POST', `/invoices/${inv.id}/einvoice`, {})).status).toBe(400);
    expect((await b.api('POST', `/invoices/${inv.id}/einvoice`, { irn: 'abc', ackNo: '1', ackDate: new Date().toISOString(), signedQrCode: 'x' })).status).toBe(400);

    const irn = 'a'.repeat(64);
    const twoDaysAgo = new Date(Date.now() - 2 * 86_400_000).toISOString();
    const res = await b.api('POST', `/invoices/${inv.id}/einvoice`, { irn, ackNo: '112010012345678', ackDate: twoDaysAgo, signedQrCode: 'eyJhbGciOi.signed.qr' });
    expect(res.status).toBe(200);
    expect(res.body.einvoice).toMatchObject({ irn, ackNo: '112010012345678', sandbox: false, status: 'active', signedQrCode: 'eyJhbGciOi.signed.qr' });

    const late = await b.api('POST', `/invoices/${inv.id}/einvoice/cancel`, { reasonCode: '1', remark: 'Duplicate' });
    expect(late.status).toBe(409);
    expect(late.body.error.code).toBe('IRN_CANCEL_WINDOW');

    // Manual e-way bill needs the portal details.
    expect((await b.api('POST', `/invoices/${inv.id}/ewaybill`, { transportMode: 'rail', distanceKm: 100 })).status).toBe(400);
    const now = new Date();
    const ewb = await b.api('POST', `/invoices/${inv.id}/ewaybill`, {
      transportMode: 'rail', distanceKm: 100, ewbNo: '271012345678', ewbDate: now.toISOString(), validUntil: new Date(now.getTime() + 86_400_000).toISOString(),
    });
    expect(ewb.status).toBe(200);
    expect(ewb.body.ewaybill).toMatchObject({ ewbNo: '271012345678', status: 'active', transportMode: 'rail', vehicleNo: null });
  });
});
