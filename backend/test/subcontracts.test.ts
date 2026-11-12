import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { computeRaBill, defaultTdsPct, lineAmount, pctOf } from '../src/modules/subcontract-common.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

type Api = ReturnType<typeof client>;
const daysAgo = (n: number) => addDays(todayIst(), -n);

async function business(stateCode = '24') {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Sub Builders', name: 'Owner', email: uniqueEmail('sub'), password: 'Secret@123', stateCode,
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, res.body.accessToken, me.companies[0].id);
  const site = (await api('POST', '/locations', { type: 'site', name: 'Site A' })).body;
  const project = (await api('POST', '/projects', { code: 'P1', name: 'Tower', siteIds: [site.id], status: 'active' })).body;
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string; systemKey: string | null }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!.id;
  const byKey = (k: string) => accounts.find((a) => a.systemKey === k)!.id;
  return { api, site, project, account, byKey };
}

async function balanceOf(api: Api, key: string) {
  const list = (await api('GET', '/accounts')).body.data as { systemKey: string | null; balance: number }[];
  return list.find((a) => a.systemKey === key)!.balance;
}

async function workOrder(api: Api, projectId: string, extra: Record<string, unknown> = {}) {
  const party = (await api('POST', '/parties', { type: 'vendor', name: `Subcon ${Math.random()}`, stateCode: '24', pan: 'AAKFS1234C' })).body;
  const res = await api('POST', '/work-orders', {
    projectId, contractorPartyId: party.id, title: 'Labour work', activate: true, retentionPct: 5, advanceRecoveryPct: 10, gstPct: 18,
    lines: [
      { description: 'RCC', unit: 'm3', qty: 100, rate: 2500 },
      { description: 'Plaster', unit: 'm2', qty: 1000, rate: 85.5 },
    ], ...extra,
  });
  expect(res.status).toBe(201);
  return { party, wo: res.body };
}

describe('RA bill maths', () => {
  it('rounds half up in paise', () => {
    expect(lineAmount(0.5, 300.03)).toBe(150.02); // 150.015
    expect(lineAmount(1.333, 100.5)).toBe(133.97); // 133.9665
    expect(pctOf(100.5, 5)).toBe(5.03); // 5.025
    expect(pctOf(0.1, 5)).toBe(0.01); // 0.005
    const calc = computeRaBill({
      gstPct: 18, retentionPct: 5, advanceRecoveryPct: 10, tdsPct: 2, cessPct: 1, intraState: true, advanceBalance: 5,
      lines: [{ prevQty: 0, cumQty: 10.5, qty: 20, rate: 99.99 }],
    });
    expect(calc.gross).toBe(1049.9); // 1049.895
    expect(calc.cgst + calc.sgst).toBe(188.98); // 188.982
    expect(calc.advanceRecovery).toBe(5); // capped at the balance
    expect(calc.netPayable).toBe(round(calc.gross + 188.98 - calc.retention - 5 - calc.tds - calc.cess));
    expect(() => computeRaBill({
      gstPct: 0, retentionPct: 0, advanceRecoveryPct: 0, tdsPct: 0, cessPct: 0, intraState: true, advanceBalance: 0,
      lines: [{ prevQty: 2, cumQty: 1, qty: 5, rate: 1 }],
    })).toThrow();
  });

  it('defaults TDS from the PAN (P/H = 1%, else 2%)', () => {
    expect(defaultTdsPct({ pan: 'ABCPD1234E', gstin: null })).toBe(1);
    expect(defaultTdsPct({ pan: 'ABCHD1234E', gstin: null })).toBe(1);
    expect(defaultTdsPct({ pan: 'AAKFS1234C', gstin: null })).toBe(2);
    expect(defaultTdsPct({ pan: null, gstin: '24ABCPD1234E1Z5' })).toBe(1);
    expect(defaultTdsPct({ pan: null, gstin: null })).toBe(2);
  });
});
const round = (n: number) => Math.round(n * 100) / 100;

describe('work orders and RA bills', () => {
  it('runs advance → bill → approve → pay with balanced journals, then cancels cleanly', async () => {
    const { api, project, account, byKey } = await business();
    const party = (await api('POST', '/parties', { type: 'vendor', name: 'Individual Subcon', stateCode: '24', pan: 'ABCPD1234E' })).body;
    const wo = (await api('POST', '/work-orders', {
      projectId: project.id, contractorPartyId: party.id, title: 'T', activate: true,
      lines: [{ description: 'RCC', unit: 'm3', qty: 100, rate: 2500 }, { description: 'Plaster', unit: 'm2', qty: 1000, rate: 85.5 }],
    })).body;
    expect(wo).toMatchObject({ tdsPct: 1, retentionPct: 5, gstPct: 18, status: 'active', totalValue: 335500 });
    expect(wo.number).toMatch(/^WO\/\d{2}-\d{2}\/00001$/);

    const ca = await api('POST', `/work-orders/${wo.id}/advances`, { amount: 20000, paidFromAccountId: account('1010') });
    expect(ca.status).toBe(201);
    await api('PATCH', `/work-orders/${wo.id}`, { advanceRecoveryPct: 10 });
    expect((await api('GET', `/work-orders/${wo.id}`)).body.advance).toEqual({ paid: 20000, recovered: 0, balance: 20000 });

    const tpl = (await api('GET', `/work-orders/${wo.id}/ra-bill-template`)).body;
    expect(tpl).toMatchObject({ billSeq: 1, status: 'draft', gross: 0 });
    const [l1, l2] = tpl.lines as { workOrderLineId: string }[];
    const bill = (await api('POST', '/ra-bills', {
      workOrderId: wo.id, date: daysAgo(3), submit: true,
      lines: [{ workOrderLineId: l1!.workOrderLineId, cumQty: 10.5 }, { workOrderLineId: l2!.workOrderLineId, cumQty: 333.333 }],
    })).body;
    // 10.5 × 2500 = 26250; 333.333 × 85.5 = 28499.9715 → 28499.97
    expect(bill).toMatchObject({
      status: 'submitted', billSeq: 1, gross: 54749.97, cgst: 4927.49, sgst: 4927.5, igst: 0, invoiceTotal: 64604.96,
      retention: 2737.5, advanceRecovery: 5475, tds: 547.5, cess: 0, totalDeductions: 8760, netPayable: 55844.96,
      paymentStatus: 'unpaid', amountDue: 0,
    });
    expect((await api('POST', '/ra-bills', { workOrderId: wo.id, lines: [] })).status).toBe(409); // one open bill at a time

    expect((await api('POST', `/ra-bills/${bill.id}/approve`)).body.status).toBe('approved');
    expect(await balanceOf(api, 'payables')).toBe(-55844.96);
    expect(await balanceOf(api, 'retention_payable')).toBe(-2737.5);
    expect(await balanceOf(api, 'tds_payable')).toBe(-547.5);
    expect(await balanceOf(api, 'contractor_advances')).toBe(20000 - 5475);
    expect(await balanceOf(api, 'subcontract_cost')).toBe(54749.97);
    expect(await balanceOf(api, 'input_cgst')).toBe(4927.49);
    const tb = (await api('GET', '/journals?voucherType=ra_bill')).body;
    expect(tb.total).toBe(1);
    const entry = tb.data[0];
    const sum = (k: 'debit' | 'credit') => round(entry.lines.reduce((s: number, l: { debit: number; credit: number }) => s + l[k], 0));
    expect(sum('debit')).toBe(sum('credit'));

    const wo2 = (await api('GET', `/work-orders/${wo.id}`)).body;
    expect(wo2).toMatchObject({ billedGross: 54749.97, advance: { paid: 20000, recovered: 5475, balance: 14525 }, retention: { held: 2737.5, released: 0, balance: 2737.5 } });
    expect(wo2.lines[0].billedQty).toBe(10.5);

    // Payments allocate to the RA bill automatically and keep amountPaid in step.
    const out = (await api('GET', `/parties/${party.id}/outstanding`)).body;
    expect(out.purchases).toEqual([expect.objectContaining({ id: bill.id, docType: 'ra_bill', total: 55844.96, amountDue: 55844.96 })]);
    const pay = (await api('POST', '/payments', { kind: 'payment', partyId: party.id, accountId: account('1010'), mode: 'bank', amount: 30000 })).body;
    expect(pay.allocations).toEqual([expect.objectContaining({ docType: 'ra_bill', docId: bill.id, amount: 30000, docNumber: bill.number })]);
    expect((await api('GET', `/ra-bills/${bill.id}`)).body).toMatchObject({ amountPaid: 30000, amountDue: 25844.96, paymentStatus: 'partial' });
    expect((await api('POST', `/ra-bills/${bill.id}/cancel`, { reason: 'Wrong quantity' })).status).toBe(409);
    const manual = await api('POST', '/payments', {
      kind: 'payment', partyId: party.id, accountId: account('1010'), mode: 'bank', amount: 25844.96, allocations: [{ docId: bill.id, amount: 25844.96 }],
    });
    expect(manual.status).toBe(201);
    expect((await api('GET', `/ra-bills/${bill.id}`)).body.paymentStatus).toBe('paid');
    expect((await api('GET', `/parties/${party.id}/outstanding`)).body.purchases).toEqual([]);
    expect((await api('POST', `/payments/${manual.body.id}/cancel`, { reason: 'Bounced' })).status).toBe(200);
    expect((await api('POST', `/payments/${pay.id}/cancel`, { reason: 'Bounced' })).status).toBe(200);
    expect((await api('GET', `/ra-bills/${bill.id}`)).body).toMatchObject({ amountPaid: 0, paymentStatus: 'unpaid', amountDue: 55844.96 });

    // Ageing counts the RA bill as a payable.
    const ageing = (await api('GET', '/reports/ageing?type=payables')).body;
    expect(ageing.totals.total).toBe(55844.96);

    // Project costs include the approved bill's gross.
    expect((await api('GET', `/projects/${project.id}/costs`)).body.actual).toMatchObject({ subcontract: 54749.97 });

    // Retention release and cancelling the latest approved bill.
    expect((await api('POST', `/work-orders/${wo.id}/retention-releases`, { amount: 3000 })).status).toBe(400);
    expect((await api('POST', `/work-orders/${wo.id}/retention-releases`, { amount: 1000 })).status).toBe(201);
    expect((await api('POST', `/ra-bills/${bill.id}/cancel`, { reason: 'Wrong quantity' })).status).toBe(409); // retention already released
    expect(await balanceOf(api, 'retention_payable')).toBe(-1737.5);
  });

  it('cancels an unpaid approved bill with a reversal and validates quantities', async () => {
    const { api, project } = await business();
    const { wo } = await workOrder(api, project.id);
    const [a, b] = wo.lines as { id: string }[];
    expect((await api('POST', '/ra-bills', { workOrderId: wo.id, lines: [{ workOrderLineId: a!.id, cumQty: 101 }] })).status).toBe(400);
    const bill = (await api('POST', '/ra-bills', { workOrderId: wo.id, lines: [{ workOrderLineId: a!.id, cumQty: 10 }], submit: true })).body;
    expect(bill.gross).toBe(25000);
    expect((await api('POST', `/ra-bills/${bill.id}/reject`, { reason: 'x' })).status).toBe(400);
    expect((await api('POST', `/ra-bills/${bill.id}/reject`, { reason: 'Check measurements' })).body).toMatchObject({ status: 'draft', rejectReason: 'Check measurements' });
    const patched = (await api('PATCH', `/ra-bills/${bill.id}`, { lines: [{ workOrderLineId: a!.id, cumQty: 10 }, { workOrderLineId: b!.id, cumQty: 100 }], otherDeduction: 100, otherDeductionNote: 'Cement recovery' })).body;
    expect(patched.gross).toBe(33550);
    expect(patched.otherDeduction).toBe(100);
    expect((await api('PATCH', `/ra-bills/${bill.id}`, { retention: 99999999 })).status).toBe(400);
    await api('POST', `/ra-bills/${bill.id}/submit`);
    await api('POST', `/ra-bills/${bill.id}/approve`);
    expect(await balanceOf(api, 'other_income')).toBe(-100);
    const next = (await api('POST', '/ra-bills', { workOrderId: wo.id, lines: [{ workOrderLineId: a!.id, cumQty: 5 }] }));
    expect(next.status).toBe(400); // below prevQty
    const cancelled = await api('POST', `/ra-bills/${bill.id}/cancel`, { reason: 'Billed twice' });
    expect(cancelled.body.status).toBe('cancelled');
    expect(await balanceOf(api, 'payables')).toBe(0);
    expect(await balanceOf(api, 'subcontract_cost')).toBe(0);
    expect((await api('GET', `/work-orders/${wo.id}`)).body.billedGross).toBe(0);
    // Cancelled bills keep their number, so the next bill is #2.
    expect((await api('GET', `/work-orders/${wo.id}/ra-bill-template`)).body.billSeq).toBe(2);
  });

  it('uses IGST for an out-of-state contractor and books GST to cost when ITC is not eligible', async () => {
    const { api, project } = await business();
    const party = (await api('POST', '/parties', { type: 'vendor', name: 'Gujarat Subcon', stateCode: '27' })).body;
    const wo = (await api('POST', '/work-orders', {
      projectId: project.id, contractorPartyId: party.id, title: 'T', activate: true, itcEligible: false, retentionPct: 0, tdsPct: 0, gstPct: 12,
      lines: [{ description: 'Work', unit: 'nos', qty: 10, rate: 1000 }],
    })).body;
    const bill = (await api('POST', '/ra-bills', { workOrderId: wo.id, submit: true, lines: [{ workOrderLineId: wo.lines[0].id, cumQty: 10 }] })).body;
    expect(bill).toMatchObject({ gross: 10000, cgst: 0, sgst: 0, igst: 1200, netPayable: 11200 });
    await api('POST', `/ra-bills/${bill.id}/approve`);
    expect(await balanceOf(api, 'subcontract_cost')).toBe(11200);
    expect(await balanceOf(api, 'input_igst')).toBe(0);
    expect((await api('GET', `/projects/${project.id}/costs`)).body.actual.subcontract).toBe(11200);
  });

  it('restricts work order changes and cancellation', async () => {
    const { api, project, account } = await business();
    const { wo } = await workOrder(api, project.id);
    await api('POST', `/work-orders/${wo.id}/advances`, { amount: 100, paidFromAccountId: account('1000') });
    expect((await api('POST', `/work-orders/${wo.id}/cancel`, { reason: 'Changed plan' })).status).toBe(409);
    const adv = (await api('GET', `/work-orders/${wo.id}/advances`)).body.data[0];
    expect((await api('POST', `/contractor-advances/${adv.id}/cancel`, { reason: 'Mistake' })).status).toBe(200);
    expect((await api('PATCH', `/work-orders/${wo.id}`, { title: 'Renamed', retentionPct: 7 })).body).toMatchObject({ title: 'Renamed', retentionPct: 7 });
    const bill = (await api('POST', '/ra-bills', { workOrderId: wo.id, lines: [{ workOrderLineId: wo.lines[0].id, cumQty: 1 }] })).body;
    expect((await api('PATCH', `/work-orders/${wo.id}`, { retentionPct: 3 })).status).toBe(409);
    expect((await api('POST', `/work-orders/${wo.id}/close`)).status).toBe(409);
    await api('POST', `/ra-bills/${bill.id}/cancel`, { reason: 'x1' });
    expect((await api('POST', `/work-orders/${wo.id}/cancel`, { reason: 'Changed plan' })).body.status).toBe('cancelled');
  });
});

describe('labour advances', () => {
  it('caps wage recovery at 50% of gross and recovers oldest first', async () => {
    const { api, site, account } = await business();
    const w = (await api('POST', '/workers', { name: 'Anil', trade: 'mason', dailyRate: 1000, siteId: site.id })).body;
    await api('PUT', '/attendance', { siteId: site.id, date: daysAgo(3), entries: [{ workerId: w.id, status: 'present' }, ] });
    await api('PUT', '/attendance', { siteId: site.id, date: daysAgo(2), entries: [{ workerId: w.id, status: 'present' }] });
    const a1 = (await api('POST', '/labour-advances', { workerId: w.id, date: daysAgo(10), amount: 600, paidFromAccountId: account('1000') })).body;
    const a2 = (await api('POST', '/labour-advances', { workerId: w.id, date: daysAgo(5), amount: 700, paidFromAccountId: account('1000') })).body;
    expect(a1.number).toMatch(/^LA\//);
    expect(a1).toMatchObject({ balance: 600, status: 'open', siteId: site.id });
    expect((await api('GET', `/workers/${w.id}`)).body.advanceBalance).toBe(1300);

    const sheet = (await api('POST', '/wage-sheets', { siteId: site.id, from: daysAgo(3), to: daysAgo(2) })).body;
    expect(sheet.rows[0]).toMatchObject({ gross: 2000, advance: 1000, advanceBalance: 1300, net: 1000 }); // 50% cap
    expect((await api('PATCH', `/wage-sheets/${sheet.id}`, { rows: [{ workerId: w.id, advance: 1000.01 }] })).status).toBe(400);
    expect((await api('PATCH', `/wage-sheets/${sheet.id}`, { rows: [{ workerId: w.id, advance: 900 }] })).status).toBe(200);
    expect((await api('POST', `/wage-sheets/${sheet.id}/recompute`)).body.rows[0].advance).toBe(900); // kept within cap
    await api('POST', `/wage-sheets/${sheet.id}/approve`);
    expect((await api('POST', `/wage-sheets/${sheet.id}/pay`, { paidFromAccountId: account('1000') })).status).toBe(200);

    const d1 = (await api('GET', `/labour-advances/${a1.id}`)).body;
    const d2 = (await api('GET', `/labour-advances/${a2.id}`)).body;
    expect(d1).toMatchObject({ recovered: 600, balance: 0, status: 'recovered' });
    expect(d1.recoveries).toEqual([expect.objectContaining({ wageSheetId: sheet.id, amount: 600 })]);
    expect(d2).toMatchObject({ recovered: 300, balance: 400, status: 'open' });
    expect((await api('GET', `/workers/${w.id}`)).body.advanceBalance).toBe(400);
    expect((await api('POST', `/labour-advances/${a2.id}/cancel`, { reason: 'Mistake' })).status).toBe(409);
    expect((await api('GET', '/labour-advances?status=recovered')).body.total).toBe(1);
    expect(await balanceOf(api, 'labour_advances')).toBe(400);
  });

  it('blocks paying when the advance balance has dropped, and cancels an untouched advance', async () => {
    const { api, site, account } = await business();
    const w = (await api('POST', '/workers', { name: 'Babu', trade: 'helper', dailyRate: 1000, siteId: site.id })).body;
    await api('PUT', '/attendance', { siteId: site.id, date: daysAgo(2), entries: [{ workerId: w.id, status: 'present' }] });
    const a = (await api('POST', '/labour-advances', { workerId: w.id, amount: 400, paidFromAccountId: account('1000') })).body;
    const sheet = (await api('POST', '/wage-sheets', { siteId: site.id, from: daysAgo(2), to: daysAgo(2) })).body;
    expect(sheet.rows[0].advance).toBe(400);
    await api('POST', `/wage-sheets/${sheet.id}/approve`);
    expect((await api('POST', `/labour-advances/${a.id}/cancel`, { reason: 'Entered by mistake' })).body.status).toBe('cancelled');
    expect(await balanceOf(api, 'labour_advances')).toBe(0);
    const pay = await api('POST', `/wage-sheets/${sheet.id}/pay`, { paidFromAccountId: account('1000') });
    expect(pay.status).toBe(409);
  });
});
