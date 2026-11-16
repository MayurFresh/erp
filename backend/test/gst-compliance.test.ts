import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { addDays, financialYear, todayIst } from '../src/lib/dates.ts';
import { einvoiceState, ewbValidity, proposeSlab } from '../src/lib/gst-compliance.ts';
import { imsBucket } from '../src/modules/gst-compliance.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Patel Traders', name: 'Owner', email: uniqueEmail('gc'), password: 'Secret@123', stateCode: '24', gstin: '24AAACD1234F1Z5',
  });
  expect(res.status).toBe(201);
  const token = res.body.accessToken as string;
  const claims = JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  const me = (await client(env.app, token)('GET', '/me')).body;
  const api = client(env.app, token, me.companies[0].id);
  const ho = (await api('GET', '/locations')).body.data[0];
  const item = (await api('POST', '/items', { name: 'Cement', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 400, trackStock: false })).body;
  const buyer = (await api('POST', '/parties', { type: 'customer', name: 'Mumbai Infra', gstin: '27AAPFU0939F1ZV', pincode: '400001' })).body;
  const db = <T>(fn: Parameters<typeof withTenant<T>>[2]) => withTenant(env.db, claims.tid as string, fn);
  return { api, ho, item, buyer, db, tenantId: claims.tid as string, companyId: me.companies[0].id as string, userId: claims.sub as string };
}
type B = Awaited<ReturnType<typeof business>>;

const bill = (b: B, partyId: string, no: string, date: string, taxable: number, extra: Record<string, unknown> = {}) => b.db(async (tx) => {
  const r = await tx.insertInto('purchases').values({
    tenant_id: b.tenantId, company_id: b.companyId, location_id: b.ho.id, party_id: partyId, number: `PUR/T/${no}`, supplier_invoice_no: no, supplier_invoice_date: date,
    fy: financialYear(date), bill_date: date, due_date: addDays(date, 30), place_of_supply: '24', supply_type: 'intra', subtotal: taxable, cgst: taxable * 0.09, sgst: taxable * 0.09, igst: 0,
    round_off: 0, total: taxable * 1.18, created_by: b.userId, ...extra,
  } as never).returning('id').executeTakeFirstOrThrow();
  return r.id;
});

describe('pure rules', () => {
  it('classifies e-invoice age', () => {
    expect(einvoiceState('below_10cr', 99)).toBe('na');
    expect(einvoiceState('10cr_plus', 19)).toBe('ok');
    expect(einvoiceState('10cr_plus', 20)).toBe('warn');
    expect(einvoiceState('10cr_plus', 29)).toBe('warn');
    expect(einvoiceState('10cr_plus', 30)).toBe('blocked');
  });
  it('sets e-way validity at 200 km a day, ending at the end of the last day', () => {
    const from = new Date('2026-05-10T06:00:00+05:30');
    expect(ewbValidity(from, 150).days).toBe(1);
    expect(ewbValidity(from, 200).days).toBe(1);
    expect(ewbValidity(from, 201).days).toBe(2);
    expect(ewbValidity(from, 0).days).toBe(1);
    expect(ewbValidity(from, 450).validUntil.toISOString()).toBe(new Date('2026-05-13T23:59:59+05:30').toISOString());
  });
  it('proposes slabs and buckets IMS rows', () => {
    expect(proposeSlab(12, '1905')).toEqual({ proposed: 5, needsCheck: false });
    expect(proposeSlab(28, '2523')).toEqual({ proposed: 18, needsCheck: false });
    expect(proposeSlab(28, '2202 10')).toEqual({ proposed: 40, needsCheck: true });
    expect(proposeSlab(18, null).proposed).toBe(18);
    expect(imsBucket('none', 'p')).toBe('in_books_accepted');
    expect(imsBucket('accept', 'p')).toBe('in_books_accepted');
    expect(imsBucket('reject', 'p')).toBe('in_books_rejected');
    expect(imsBucket('pending', 'p')).toBe('pending');
    expect(imsBucket('none', null)).toBe('not_in_books');
  });
});

describe('IMS', () => {
  it('excludes rejected and pending documents from 3B credit and shows the buckets', async () => {
    const b = await business();
    const sup = (await b.api('POST', '/parties', { type: 'vendor', name: 'ITC Supplier', stateCode: '24', gstin: '24AAACS1234A1ZK' })).body;
    const today = todayIst();
    const period = today.slice(0, 7);
    for (const [no, amt] of [['A-1', 1000], ['A-2', 2000], ['A-3', 3000]] as const) await bill(b, sup.id, no, today, amt);
    const d = today.split('-').reverse().join('/');
    const csv = ['gstin,docType,docNo,docDate,taxable,igst,cgst,sgst',
      ...[['A-1', 1000], ['A-2', 2000], ['A-3', 3000]].map(([n, t]) => `24AAACS1234A1ZK,invoice,${n},${d},${t},0,${Number(t) * 0.09},${Number(t) * 0.09}`),
      `24AAACS1234A1ZK,invoice,Z-9,${d},500,0,45,45`].join('\n');
    expect((await b.api('POST', '/gst/2b-imports', { period, csv })).status).toBe(201);

    const before = (await b.api('GET', `/gst/gstr3b?period=${period}`)).body;
    expect(before.itc.others.cgst).toBe(540);
    const ims = (await b.api('GET', `/gst/ims?period=${period}`)).body;
    expect(ims.summary.inBooksAccepted.count).toBe(3);
    expect(ims.summary.notInBooks.count).toBe(1);
    expect(ims.summary.deemedAccepted).toBe(4);
    const id = (no: string) => ims.rows.find((r: any) => r.docNo === no).id as string;

    const noReason = await b.api('POST', '/gst/ims/actions', { ids: [id('A-2')], action: 'reject' });
    expect(noReason.status).toBe(400);
    expect((await b.api('POST', '/gst/ims/actions', { ids: [id('A-2')], action: 'reject', reason: 'Goods not received' })).body).toEqual({ updated: 1 });
    expect((await b.api('POST', '/gst/ims/actions', { ids: [id('A-3')], action: 'pending', reason: 'Awaiting credit note' })).body).toEqual({ updated: 1 });
    expect((await b.api('POST', '/gst/ims/actions', { ids: [id('A-1')], action: 'accept' })).body).toEqual({ updated: 1 });

    const after = (await b.api('GET', `/gst/ims?period=${period}`)).body;
    expect(after.summary.inBooksAccepted).toMatchObject({ count: 1, itc: 180 });
    expect(after.summary.inBooksRejected).toMatchObject({ count: 1, itc: 360 });
    expect(after.summary.pending).toMatchObject({ count: 1, itc: 540 });
    expect(after.rows.find((r: any) => r.docNo === 'A-2')).toMatchObject({ bucket: 'in_books_rejected', imsReason: 'Goods not received', deemed: false });
    expect((await b.api('GET', `/gst/ims?period=${period}&bucket=pending`)).body.rows).toHaveLength(1);

    const g = (await b.api('GET', `/gst/gstr3b?period=${period}`)).body;
    expect(g.itc.others).toMatchObject({ cgst: 90, sgst: 90 });
    expect(g.itc.imsExcluded.cgst).toBe(450);
    expect(g.warnings.join(' ')).toContain('IMS');

    // Back to deemed accepted: the credit returns.
    await b.api('POST', '/gst/ims/actions', { ids: [id('A-2'), id('A-3')], action: 'none' });
    expect((await b.api('GET', `/gst/gstr3b?period=${period}`)).body.itc.others.cgst).toBe(540);
  });
});

describe('e-invoice window and e-way bill age', () => {
  it('refuses IRN after 30 days at 10 crore and lists unreported invoices', async () => {
    const b = await business();
    await b.api('PATCH', '/company', { pincode: '380054', address: 'SG Highway', einvoiceEnabled: true, einvoiceMode: 'sandbox', aatoBand: '10cr_plus' });
    const mk = async (daysAgo: number) => {
      const inv = (await b.api('POST', '/invoices', { locationId: b.ho.id, partyId: b.buyer.id, invoiceDate: addDays(todayIst(), -daysAgo), lines: [{ itemId: b.item.id, qty: 1 }] })).body;
      expect(inv.id).toBeTruthy();
      return inv;
    };
    const fresh = await mk(2), warn = await mk(25), old = await mk(40);
    const list = (await b.api('GET', '/gst/einvoice/unreported')).body;
    expect(list.band).toBe('10cr_plus');
    expect(list.counts).toEqual({ ok: 1, warn: 1, blocked: 1 });
    expect(list.rows[0]).toMatchObject({ invoiceId: old.id, ageDays: 40, state: 'blocked' });

    const refused = await b.api('POST', `/invoices/${old.id}/einvoice`, {});
    expect(refused.status).toBe(409);
    expect(refused.body.error.code).toBe('EINVOICE_WINDOW_PASSED');
    expect((await b.api('POST', `/invoices/${warn.id}/einvoice`, {})).status).toBe(200);
    expect((await b.api('POST', `/invoices/${fresh.id}/einvoice`, {})).status).toBe(200);
    expect((await b.api('GET', '/gst/einvoice/unreported')).body.rows).toHaveLength(1);

    await b.api('PATCH', '/company', { aatoBand: 'below_10cr' });
    const low = (await b.api('GET', '/gst/einvoice/unreported')).body;
    expect(low.rows[0].state).toBe('na');
    expect((await b.api('POST', `/invoices/${old.id}/einvoice`, {})).status).toBe(200);
  });

  it('refuses an e-way bill for a document older than 180 days', async () => {
    const b = await business();
    await b.api('PATCH', '/company', { pincode: '380054', address: 'SG Highway', einvoiceEnabled: true, einvoiceMode: 'sandbox' });
    const inv = (await b.api('POST', '/invoices', { locationId: b.ho.id, partyId: b.buyer.id, invoiceDate: addDays(todayIst(), -200), lines: [{ itemId: b.item.id, qty: 1 }] })).body;
    expect((await b.api('POST', `/invoices/${inv.id}/einvoice`, {})).status).toBe(200);
    const r = await b.api('POST', `/invoices/${inv.id}/ewaybill`, { transportMode: 'road', distanceKm: 100, vehicleNo: 'GJ01AB1234' });
    expect(r.status).toBe(409);
    expect(r.body.error.code).toBe('EWB_DOCUMENT_TOO_OLD');
    const v = (await b.api('GET', '/gst/ewaybill-validity?date=2026-05-10&distanceKm=450')).body;
    expect(v.days).toBe(3);
  });
});

describe('GST rate history and slab review', () => {
  it('prices old invoices at the old rate and keeps the choice item by item', async () => {
    const b = await business();
    const twelve = (await b.api('POST', '/items', { name: 'Biscuits', hsnCode: '1905', unit: 'box', gstRate: 18, salePrice: 100, trackStock: false })).body;
    const kept = (await b.api('POST', '/items', { name: 'Jam', hsnCode: '2007', unit: 'jar', gstRate: 18, salePrice: 100, trackStock: false })).body;
    await b.db(async (tx) => { await tx.updateTable('items').set({ gst_rate: 12 }).where('id', 'in', [twelve.id, kept.id]).execute(); });

    const review = (await b.api('GET', '/gst/slab-review')).body;
    expect(review.effectiveFrom).toBe('2025-09-22');
    expect(review.rows.map((r: any) => [r.name, r.currentRate, r.proposedRate, r.reviewed]).sort()).toEqual([['Biscuits', 12, 5, false], ['Jam', 12, 5, false]]);
    // Nothing changed without the user's choice.
    expect((await b.api('GET', `/items/${twelve.id}/gst-rates`)).body).toMatchObject({ currentRate: 12, data: [] });

    const apply = await b.api('POST', '/gst/slab-review/apply', { effectiveFrom: '2025-09-22', items: [{ itemId: twelve.id, newRate: 5 }, { itemId: kept.id, newRate: 12 }] });
    expect(apply.body).toEqual({ applied: 2 });
    const hist = (await b.api('GET', `/items/${twelve.id}/gst-rates`)).body;
    expect(hist.currentRate).toBe(5);
    expect(hist.data.map((r: any) => [r.effectiveFrom, r.rate])).toEqual([['2025-09-22', 5], ['2017-07-01', 12]]);
    expect((await b.api('GET', '/gst/slab-review')).body.rows.every((r: any) => r.reviewed)).toBe(true);

    const old = (await b.api('POST', '/invoices', { locationId: b.ho.id, partyId: b.buyer.id, invoiceDate: '2025-08-01', lines: [{ itemId: twelve.id, qty: 10 }] })).body;
    expect(old.lines[0].gstRate).toBe(12);
    const now = (await b.api('POST', '/invoices', { locationId: b.ho.id, partyId: b.buyer.id, lines: [{ itemId: twelve.id, qty: 10 }] })).body;
    expect(now.lines[0].gstRate).toBe(5);
    const dup = await b.api('POST', `/items/${twelve.id}/gst-rates`, { rate: 18, effectiveFrom: '2025-09-22' });
    expect(dup.status).toBe(409);
  });
});

describe('Section 43B(h)', () => {
  it('totals micro and small dues beyond the limit at 31 March and feeds the ITR pack', async () => {
    const b = await business();
    const micro = (await b.api('POST', '/parties', { type: 'vendor', name: 'Micro Co', stateCode: '24', udyamNo: 'UDYAM-GJ-01-0001234', msmeCategory: 'micro' })).body;
    const medium = (await b.api('POST', '/parties', { type: 'vendor', name: 'Medium Co', stateCode: '24', msmeCategory: 'medium' })).body;
    await bill(b, micro.id, 'M-late', '2026-01-01', 10000, { msme_due_date: '2026-01-16' });
    await bill(b, micro.id, 'M-ok', '2026-03-25', 5000, { msme_due_date: '2026-04-09' });
    await bill(b, medium.id, 'X-late', '2026-01-01', 7000);
    const r = (await b.api('GET', '/reports/msme-43bh?taxYear=2025-26')).body;
    expect(r.asOf).toBe('2026-03-31');
    expect(r.rows).toHaveLength(1);
    expect(r.rows[0]).toMatchObject({ number: 'PUR/T/M-late', outstanding: 11800, daysOverdue: 74 });
    expect(r.total).toBe(11800);
    const pack = (await b.api('GET', '/tax/itr-pack?taxYear=2025-26')).body;
    expect(pack.section43bh).toBe(11800);
    expect(pack.adjustments.find((a: any) => a.label.includes('43B(h)'))).toMatchObject({ kind: 'add', amount: 11800 });
  });
});
