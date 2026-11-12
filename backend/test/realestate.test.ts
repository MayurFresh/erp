import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

type Api = ReturnType<typeof client>;

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Heights Builders', name: 'Owner', email: uniqueEmail('re'), password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, res.body.accessToken, me.companies[0].id);
  const site = (await api('POST', '/locations', { type: 'site', name: 'Heights Site' })).body;
  const project = (await api('POST', '/projects', { code: 'R1', name: 'Heights', siteIds: [site.id] })).body;
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string; systemKey: string | null }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!;
  const plan = (await api('POST', '/payment-plans', {
    projectId: project.id, name: 'CLP', stages: [10, 20, 15, 15, 15, 15, 10].map((pct, i) => ({ name: `Stage ${i + 1}`, pct })),
  })).body;
  const customer = (await api('POST', '/parties', { type: 'customer', name: 'Flat Buyer', stateCode: '24' })).body;
  return { api, site, project, plan, customer, account };
}

async function book(api: Api, b: Awaited<ReturnType<typeof business>>, code: string, agreementValue = 1_000_000, gstPct = 5) {
  const unit = (await api('POST', '/units', { projectId: b.project.id, code, unitType: '2 BHK', carpetArea: 70, listPrice: agreementValue })).body;
  const res = await api('POST', '/bookings', { unitId: unit.id, customerPartyId: b.customer.id, paymentPlanId: b.plan.id, agreementValue, gstPct });
  expect(res.status).toBe(201);
  return { unit, booking: res.body };
}

async function journalOf(api: Api, voucherType: string, number: string) {
  const list = (await api('GET', `/journals?voucherType=${voucherType}&q=${encodeURIComponent(number)}`)).body.data as
    { isReversal: boolean; lines: { accountCode: string; debit: number; credit: number }[] }[];
  return list;
}

describe('units and payment plans', () => {
  it('validates plans, bulk-creates units and rejects duplicate codes', async () => {
    const b = await business();
    const bad = await b.api('POST', '/payment-plans', { projectId: b.project.id, name: 'Bad', stages: [{ name: 'a', pct: 50 }, { name: 'b', pct: 49.99 }] });
    expect(bad.status).toBe(400);
    const bulk = await b.api('POST', '/units', { projectId: b.project.id, units: [
      { code: 'A-101', wing: 'A', floor: 1, unitType: '2 BHK', carpetArea: 70.5 },
      { code: 'A-102', wing: 'A', floor: 1, unitType: '3 BHK', carpetArea: 90 },
    ] });
    expect(bulk.status).toBe(201);
    expect(bulk.body.total).toBe(2);
    expect((await b.api('POST', '/units', { projectId: b.project.id, code: 'a-101', unitType: '2 BHK', carpetArea: 70 })).status).toBe(409);
    const unit = bulk.body.data[0];
    expect((await b.api('PATCH', `/units/${unit.id}`, { status: 'hold' })).body.status).toBe('hold');
    expect((await b.api('PATCH', `/units/${unit.id}`, { status: 'booked' })).status).toBe(409);
    const list = (await b.api('GET', `/units?projectId=${b.project.id}&wing=A`)).body;
    expect(list.data.map((u: { code: string }) => u.code)).toEqual(['A-101', 'A-102']);
  });
});

describe('bookings and demands', () => {
  it('splits stages with the remainder on the last stage', async () => {
    const b = await business();
    const plan = (await b.api('POST', '/payment-plans', { projectId: b.project.id, name: 'Thirds', stages: [
      { name: 'One', pct: 33.33 }, { name: 'Two', pct: 33.33 }, { name: 'Three', pct: 33.34 }] })).body;
    const unit = (await b.api('POST', '/units', { projectId: b.project.id, code: 'T-1', unitType: '1 BHK', carpetArea: 40 })).body;
    const res = await b.api('POST', '/bookings', { unitId: unit.id, customerPartyId: b.customer.id, paymentPlanId: plan.id, agreementValue: 1000003 });
    expect(res.status).toBe(201);
    const amounts = res.body.stages.map((s: { amount: number }) => s.amount);
    expect(amounts).toEqual([333301, 333301, 333401]);
    expect(amounts.reduce((s: number, a: number) => s + a, 0)).toBe(1000003);
    expect(res.body.number).toMatch(/^BKG\/\d{2}-\d{2}\/00001$/);
    expect(res.body.gstPct).toBe(5);
    // The unit is taken now.
    expect((await b.api('GET', `/units/${unit.id}`)).body).toMatchObject({ status: 'booked', bookingId: res.body.id });
    const again = await b.api('POST', '/bookings', { unitId: unit.id, customerPartyId: b.customer.id, paymentPlanId: plan.id, agreementValue: 1000003 });
    expect(again.status).toBe(409);
    // Changing the value re-splits.
    const patched = await b.api('PATCH', `/bookings/${res.body.id}`, { agreementValue: 100 });
    expect(patched.body.stages.map((s: { amount: number }) => s.amount)).toEqual([33.33, 33.33, 33.34]);
  });

  it('allows only 10% before the agreement, then posts the demand journal with GST', async () => {
    const b = await business();
    const { booking } = await book(b.api, b, 'D-1');
    const [s1, s2] = booking.stages;
    const demand = await b.api('POST', `/bookings/${booking.id}/demands`, { stageIds: [s1.id] });
    expect(demand.status).toBe(201);
    expect(demand.body).toMatchObject({ amount: 100000, cgst: 2500, sgst: 2500, total: 105000, amountDue: 105000, paymentStatus: 'unpaid', status: 'open' });
    expect(demand.body.number).toMatch(/^DMD\//);
    expect(demand.body.stages).toHaveLength(1);

    const j = (await journalOf(b.api, 'demand', demand.body.number))[0]!;
    const by = (code: string) => j.lines.find((l) => l.accountCode === code)!;
    expect(by('1100').debit).toBe(105000);
    expect(by('2300').credit).toBe(100000);
    expect(by('2100').credit).toBe(2500);
    expect(by('2101').credit).toBe(2500);

    const over = await b.api('POST', `/bookings/${booking.id}/demands`, { stageIds: [s2.id] });
    expect(over.status).toBe(409);
    expect(over.body.error.code).toBe('AGREEMENT_REQUIRED');
    // The same stage cannot be demanded twice.
    expect((await b.api('POST', `/bookings/${booking.id}/demands`, { stageIds: [s1.id] })).status).toBe(409);

    // Value and GST are locked once a demand exists.
    expect((await b.api('PATCH', `/bookings/${booking.id}`, { gstPct: 1 })).status).toBe(409);

    // After the agreement the next stage is allowed.
    const ag = await b.api('POST', `/bookings/${booking.id}/agreement`, { agreementNo: 'AFS/001', agreementDate: '2026-10-01' });
    expect(ag.body.status).toBe('agreement');
    const d2 = await b.api('POST', `/bookings/${booking.id}/demands`, { stageIds: [s2.id] });
    expect(d2.status).toBe(201);
    const full = (await b.api('GET', `/bookings/${booking.id}`)).body;
    expect(full.totals).toMatchObject({ demanded: 300000, gst: 15000, received: 0, due: 315000, undemanded: 700000 });
    expect(full.stages[0]).toMatchObject({ demandId: demand.body.id, demandNumber: demand.body.number });
  });

  it('cancels a demand, reversing the journal and freeing the stage', async () => {
    const b = await business();
    const { booking } = await book(b.api, b, 'D-2');
    const demand = (await b.api('POST', `/bookings/${booking.id}/demands`, { stageIds: [booking.stages[0].id] })).body;
    const cancelled = await b.api('POST', `/demands/${demand.id}/cancel`, { reason: 'Raised by mistake' });
    expect(cancelled.status).toBe(200);
    expect(cancelled.body).toMatchObject({ status: 'cancelled', amountDue: 0 });
    const entries = await journalOf(b.api, 'demand', demand.number);
    expect(entries).toHaveLength(2);
    expect(entries.some((e) => e.isReversal)).toBe(true);
    expect((await b.api('GET', `/bookings/${booking.id}`)).body.stages[0].demandId).toBeNull();
    expect((await b.api('POST', `/demands/${demand.id}/cancel`, { reason: 'again please' })).status).toBe(409);
  });

  it('records possession only when every stage is demanded, and moves the revenue', async () => {
    const b = await business();
    const { booking, unit } = await book(b.api, b, 'P-1', 100000, 0);
    expect((await b.api('POST', `/bookings/${booking.id}/possession`, { date: '2026-10-20' })).status).toBe(409);
    await b.api('POST', `/bookings/${booking.id}/agreement`, { agreementNo: 'AFS/9', agreementDate: '2026-10-01' });
    expect((await b.api('POST', `/bookings/${booking.id}/possession`, { date: '2026-10-20' })).status).toBe(409);
    const all = await b.api('POST', `/bookings/${booking.id}/demands`, { stageIds: booking.stages.map((s: { id: string }) => s.id) });
    expect(all.status).toBe(201);
    expect(all.body).toMatchObject({ amount: 100000, cgst: 0, sgst: 0, total: 100000 });

    const pos = await b.api('POST', `/bookings/${booking.id}/possession`, { date: '2026-10-20' });
    expect(pos.status).toBe(200);
    expect(pos.body).toMatchObject({ status: 'possession', possessionDate: '2026-10-20' });
    expect((await b.api('GET', `/units/${unit.id}`)).body.status).toBe('possession');
    const j = (await journalOf(b.api, 'possession', booking.number))[0]!;
    expect(j.lines.find((l) => l.accountCode === '2300')!.debit).toBe(100000);
    expect(j.lines.find((l) => l.accountCode === '4100')!.credit).toBe(100000);

    // After possession nothing can be undone.
    expect((await b.api('POST', `/demands/${all.body.id}/cancel`, { reason: 'too late now' })).status).toBe(409);
    expect((await b.api('POST', `/bookings/${booking.id}/cancel`, { reason: 'too late now' })).status).toBe(409);
  });

  it('cancels a booking: demands reversed, unit available again', async () => {
    const b = await business();
    const { booking, unit } = await book(b.api, b, 'C-1');
    const demand = (await b.api('POST', `/bookings/${booking.id}/demands`, { stageIds: [booking.stages[0].id] })).body;
    const res = await b.api('POST', `/bookings/${booking.id}/cancel`, { reason: 'Customer withdrew' });
    expect(res.status).toBe(200);
    expect(res.body.status).toBe('cancelled');
    expect((await b.api('GET', `/demands/${demand.id}`)).body.status).toBe('cancelled');
    expect((await b.api('GET', `/units/${unit.id}`)).body).toMatchObject({ status: 'available', bookingId: null });
    // The unit can be sold again.
    const rebook = await b.api('POST', '/bookings', { unitId: unit.id, customerPartyId: b.customer.id, paymentPlanId: b.plan.id, agreementValue: 900000 });
    expect(rebook.status).toBe(201);
    const list = (await b.api('GET', `/demands?bookingId=${booking.id}`)).body;
    expect(list.total).toBe(1);
  });

  it('rejects a vendor as customer and an inactive plan', async () => {
    const b = await business();
    const unit = (await b.api('POST', '/units', { projectId: b.project.id, code: 'V-1', unitType: '2 BHK', carpetArea: 70, listPrice: 500000 })).body;
    const vendor = (await b.api('POST', '/parties', { type: 'vendor', name: 'Some Vendor' })).body;
    expect((await b.api('POST', '/bookings', { unitId: unit.id, customerPartyId: vendor.id, paymentPlanId: b.plan.id })).status).toBe(400);
    await b.api('PATCH', `/payment-plans/${b.plan.id}`, { isActive: false });
    expect((await b.api('POST', '/bookings', { unitId: unit.id, customerPartyId: b.customer.id, paymentPlanId: b.plan.id })).status).toBe(400);
  });
});

describe('receipts and RERA', () => {
  it('applies receipts to demands and reports the 70% account', async () => {
    const b = await business();
    const rera = (await b.api('POST', '/accounts', { name: 'RERA Collection A/c', type: 'asset', subtype: 'bank' })).body;
    const patched = await b.api('PATCH', `/projects/${b.project.id}`, { reraRegNo: 'P51700012345', reraAccountId: rera.id });
    expect(patched.body).toMatchObject({ reraRegNo: 'P51700012345', reraAccountId: rera.id });
    // The RERA account must be a bank account.
    expect((await b.api('PATCH', `/projects/${b.project.id}`, { reraAccountId: b.account('4000').id })).status).toBe(400);

    const { booking } = await book(b.api, b, 'R-1');
    const demand = (await b.api('POST', `/bookings/${booking.id}/demands`, { stageIds: [booking.stages[0].id] })).body;
    const receipt = await b.api('POST', '/payments', { kind: 'receipt', partyId: b.customer.id, accountId: b.account('1010').id, mode: 'bank', amount: 52500 });
    expect(receipt.status).toBe(201);
    expect(receipt.body.allocated).toBe(52500);

    expect((await b.api('GET', `/demands/${demand.id}`)).body).toMatchObject({ amountPaid: 52500, amountDue: 52500, paymentStatus: 'partial' });
    expect((await b.api('GET', `/bookings/${booking.id}`)).body.totals).toMatchObject({ received: 52500, due: 52500 });
    // A part-paid demand cannot be cancelled, nor can its booking.
    expect((await b.api('POST', `/demands/${demand.id}/cancel`, { reason: 'try anyway' })).status).toBe(409);
    expect((await b.api('POST', `/bookings/${booking.id}/cancel`, { reason: 'try anyway' })).status).toBe(409);

    // 52,500 received, of which 5% GST on 105% = 2,500 -> 50,000 collections, 35,000 required.
    let r = (await b.api('GET', `/projects/${b.project.id}/rera`)).body;
    expect(r).toMatchObject({ reraRegNo: 'P51700012345', reraAccountName: 'RERA Collection A/c', collections: 50000, required: 35000, deposited: 0, shortfall: 35000 });

    await b.api('POST', '/journals', { narration: 'Move to RERA account', lines: [
      { accountId: rera.id, debit: 40000 }, { accountId: b.account('1010').id, credit: 40000 }] });
    r = (await b.api('GET', `/projects/${b.project.id}/rera`)).body;
    expect(r).toMatchObject({ deposited: 40000, withdrawn: 0, balance: 40000, shortfall: 0 });
  });
});
