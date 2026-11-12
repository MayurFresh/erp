import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import pg from 'pg';
import { withDatabase } from '../src/db/migrate.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

type Api = ReturnType<typeof client>;

/** Direct owner connection, for rows the API does not let a test write (challans). */
async function owner<T>(fn: (c: pg.Client) => Promise<T>): Promise<T> {
  const c = new pg.Client({ connectionString: withDatabase(process.env.DATABASE_ADMIN_URL!, new URL(process.env.TEST_DATABASE_URL!).pathname.slice(1)) });
  await c.connect();
  try { return await fn(c); } finally { await c.end(); }
}

async function business() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Patel Traders', name: 'Kiran Patel', email: uniqueEmail('owner'), password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, res.body.accessToken, me.companies[0].id);
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse' })).body;
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string; balance: number }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!;
  const sections = (await api('GET', '/tds-sections')).body.data as { id: string; code: string }[];
  const section = (code: string) => sections.find((s) => s.code === code)!.id;
  const service = (await api('POST', '/items', { name: 'Service', hsnCode: '9954', unit: 'job', gstRate: 18, salePrice: 1000, purchasePrice: 1000, trackStock: false })).body;
  const vendor = async (name: string, extra: Record<string, unknown> = {}) =>
    (await api('POST', '/parties', { type: 'vendor', name, stateCode: '24', ...extra })).body;
  const purchase = (partyId: string, rate: number, extra: Record<string, unknown> = {}) =>
    api('POST', '/purchases', { locationId: wh.id, partyId, lines: [{ itemId: service.id, qty: 1, rate }], ...extra });
  return { api, wh, account, section, service, vendor, purchase, companyId: me.companies[0].id as string };
}

async function balanced(api: Api) {
  const tb = (await api('GET', '/reports/trial-balance')).body;
  expect(tb.totalDebit).toBe(tb.totalCredit);
}
async function bal(api: Api, code: string) {
  const list = (await api('GET', '/accounts')).body.data as { code: string; balance: number }[];
  return Math.abs(list.find((a) => a.code === code)!.balance);
}

describe('GST rate master', () => {
  it('rejects 12% on goods today but accepts 5%, and 12% services', async () => {
    const { api } = await business();
    const bad = await api('POST', '/items', { name: 'Bricks', hsnCode: '6901', unit: 'nos', gstRate: 12, salePrice: 10 });
    expect(bad.status).toBe(400);
    expect(bad.body.error.code).toBe('VALIDATION_ERROR');
    expect(bad.body.error.details.gstRate).toContain('12%');
    expect((await api('POST', '/items', { name: 'Bricks', hsnCode: '6901', unit: 'nos', gstRate: 5, salePrice: 10 })).status).toBe(201);
    expect((await api('POST', '/items', { name: 'Concessional', hsnCode: '9954', unit: 'job', gstRate: 12, salePrice: 10 })).status).toBe(201);

    const goods = (await api('GET', '/gst-rates?kind=goods')).body.data as { rate: number }[];
    expect(goods.map((r) => r.rate)).not.toContain(12);
    expect(goods.map((r) => r.rate)).toContain(18);
    const legacy = (await api('GET', '/gst-rates?date=2025-01-01&includeLegacy=true')).body.data as { rate: number }[];
    expect(legacy.map((r) => r.rate)).toContain(28);

    const exp = await api('POST', '/expenses', { locationId: (await api('GET', '/locations')).body.data[0].id,
      accountId: (await api('GET', '/accounts')).body.data.find((a: { code: string }) => a.code === '6040').id,
      description: 'Odd rate', amount: 100, gstRate: 7, paidFromAccountId: (await api('GET', '/accounts')).body.data.find((a: { code: string }) => a.code === '1000').id });
    expect(exp.status).toBe(400);
  });

  it('lets a business add a rate and protects system rows', async () => {
    const { api } = await business();
    const created = await api('POST', '/gst-rates', { rate: 7.5, kind: 'any', label: 'Custom', effectiveFrom: '2026-01-01' });
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ rate: 7.5, isSystem: false });
    expect((await api('PATCH', `/gst-rates/${created.body.id}`, { effectiveTo: '2026-12-31' })).body.effectiveTo).toBe('2026-12-31');
    const system = (await api('GET', '/gst-rates')).body.data[0];
    expect((await api('PATCH', `/gst-rates/${system.id}`, { effectiveTo: '2030-01-01' })).status).toBe(403);
  });
});

describe('TDS calculation', () => {
  it('defers below the threshold, then catches up on the aggregate', async () => {
    const { api, section, vendor, purchase } = await business();
    const v = await vendor('Mehta & Associates', { pan: 'AAAPM1234C', tdsSectionId: section('194J(a)') });
    expect(v).toMatchObject({ tdsSectionCode: '194J(a)' });

    const first = await purchase(v.id, 30000);
    expect(first.status).toBe(201);
    expect(first.body).toMatchObject({ tdsSectionCode: '194J(a)', tdsBase: 0, tdsAmount: 0, netPayable: first.body.total });

    const today = first.body.billDate;
    const preview = (await api('POST', '/tds/preview', { partyId: v.id, sectionId: section('194J(a)'), date: today, gross: 30000 })).body;
    expect(preview).toMatchObject({ reason: 'aggregate', base: 60000, amount: 6000, fyGross: 60000, rate: 10 });

    const second = await purchase(v.id, 30000);
    expect(second.body).toMatchObject({ tdsBase: 60000, tdsRate: 10, tdsAmount: 6000, total: 35400, netPayable: 29400, amountDue: 29400, paymentStatus: 'unpaid' });

    // Cancelling the second bill frees its deduction, so a re-preview excluding nothing is below threshold again.
    expect((await api('POST', `/purchases/${second.body.id}/cancel`, { reason: 'entered twice' })).status).toBe(200);
    const rows = await owner((c) => c.query('select status, amount from tds_deductions where source_id = $1', [second.body.id]));
    expect(rows.rows).toEqual([{ status: 'cancelled', amount: 6000 }]);
    await balanced(api);
  });

  it('applies 194Q only to the excess over the aggregate', async () => {
    const { api, section, vendor, purchase } = await business();
    const v = await vendor('Big Steel Ltd', { pan: 'AAACB1234C' });
    const sid = section('194Q');
    const a = await purchase(v.id, 4_000_000, { tdsSectionId: sid });
    expect(a.body).toMatchObject({ tdsBase: 0, tdsAmount: 0 });
    const b = await purchase(v.id, 2_000_000, { tdsSectionId: sid });
    expect(b.body).toMatchObject({ tdsBase: 1_000_000, tdsRate: 0.1, tdsAmount: 1000 });
    const c = await purchase(v.id, 1_000_000, { tdsSectionId: sid });
    expect(c.body).toMatchObject({ tdsBase: 1_000_000, tdsAmount: 1000 });
  });

  it('uses the individual, other and no-PAN rates', async () => {
    const { api, section, vendor } = await business();
    const date = new Date().toISOString().slice(0, 10);
    const prev = async (partyId: string, code: string, gross: number) =>
      (await api('POST', '/tds/preview', { partyId, sectionId: section(code), date, gross })).body;
    const person = await vendor('Ramesh', { pan: 'AAAPM1234C' });
    const firm = await vendor('Shree Firm', { pan: 'AAAFS1234C' });
    const nopan = await vendor('Cash Vendor');
    expect(await prev(person.id, '194C', 40000)).toMatchObject({ rate: 1, amount: 400, reason: 'single' });
    expect(await prev(firm.id, '194C', 40000)).toMatchObject({ rate: 2, amount: 800 });
    expect(await prev(nopan.id, '194J(a)', 60000)).toMatchObject({ rate: 20, amount: 12000, reason: 'no_pan' });
    expect(await prev(person.id, '194C', 20000)).toMatchObject({ base: 0, amount: 0, reason: 'below_threshold' });
  });
});

describe('purchases, expenses and receipts', () => {
  it('books a purchase with TDS and reverse charge, balanced', async () => {
    const { api, section, vendor, purchase, account } = await business();
    const v = await vendor('Kiran Contractor', { pan: 'AAAPK1234C', tdsSectionId: section('194C') });
    const res = await purchase(v.id, 100000, { reverseCharge: true });
    expect(res.status).toBe(201);
    expect(res.body).toMatchObject({
      subtotal: 100000, cgst: 9000, sgst: 9000, taxTotal: 18000, total: 100000, tdsBase: 100000, tdsRate: 1, tdsAmount: 1000,
      netPayable: 99000, amountDue: 99000, reverseCharge: true,
    });
    expect(res.body.rcmSelfInvoiceNo).toMatch(/^RCM\//);
    expect(await bal(api, '2130')).toBe(18000);
    expect(await bal(api, '2110')).toBe(1000);
    expect(await bal(api, account('2000').code)).toBe(99000);
    await balanced(api);

    // A payment settles the net amount only.
    const pay = await api('POST', '/payments', { kind: 'payment', partyId: v.id, accountId: account('1010').id, mode: 'bank', amount: 99000 });
    expect(pay.status).toBe(201);
    expect((await api('GET', `/purchases/${res.body.id}`)).body).toMatchObject({ amountDue: 0, paymentStatus: 'paid' });
  });

  it('sets the MSME due date and enforces 45 days', async () => {
    const { api, vendor, purchase } = await business();
    const bad = await api('POST', '/parties', { type: 'vendor', name: 'Micro One', msmeCategory: 'micro', creditDays: 60 });
    expect(bad.status).toBe(400);
    expect(bad.body.error.message).toContain('45 days');
    expect((await api('POST', '/parties', { type: 'vendor', name: 'Micro Two', msmeCategory: 'micro', creditDays: 400 })).status).toBe(400);
    const ok = await vendor('Micro Three', { msmeCategory: 'small', creditDays: 30, udyamNo: 'UDYAM-GJ-01-0001234' });
    expect(ok).toMatchObject({ msmeCategory: 'small', udyamNo: 'UDYAM-GJ-01-0001234' });
    expect((await api('PATCH', `/parties/${ok.id}`, { creditDays: 90 })).status).toBe(400);
    const bill = await purchase(ok.id, 1000, { billDate: '2026-09-01' });
    expect(bill.body).toMatchObject({ msmeDueDate: '2026-10-01', msmeCategory: 'small' });
  });

  it('books an expense with TDS and an RCM expense', async () => {
    const { api, section, vendor, account } = await business();
    const ho = (await api('GET', '/locations')).body.data[0];
    const ca = await vendor('Mehta CA', { pan: 'AAAPM1234C', tdsSectionId: section('194J(a)') });
    const exp = await api('POST', '/expenses', { locationId: ho.id, accountId: account('6060').id, partyId: ca.id, description: 'Audit fees',
      amount: 60000, gstRate: 18, paidFromAccountId: account('1010').id });
    expect(exp.status).toBe(201);
    expect(exp.body).toMatchObject({ tdsSectionCode: '194J(a)', tdsBase: 60000, tdsRate: 10, tdsAmount: 6000, total: 70800, netPaid: 64800 });
    expect(await bal(api, '2110')).toBe(6000);

    const gta = await vendor('Roadways');
    const rcm = await api('POST', '/expenses', { locationId: ho.id, accountId: account('6030').id, partyId: gta.id, description: 'GTA freight',
      amount: 20000, gstRate: 5, reverseCharge: true, paidFromAccountId: account('1010').id });
    expect(rcm.body).toMatchObject({ total: 20000, tdsAmount: 0, netPaid: 20000, reverseCharge: true });
    expect(rcm.body.rcmSelfInvoiceNo).toMatch(/^RCM\//);
    expect(await bal(api, '2130')).toBe(1000);
    await balanced(api);

    const noParty = await api('POST', '/expenses', { locationId: ho.id, accountId: account('6030').id, description: 'x', amount: 10,
      reverseCharge: true, paidFromAccountId: account('1000').id });
    expect(noParty.status).toBe(400);
    expect((await api('POST', `/expenses/${exp.body.id}/cancel`, { reason: 'wrong head' })).status).toBe(200);
    await balanced(api);
  });

  it('settles an invoice with a receipt that has TDS deducted by the customer', async () => {
    const { api, wh, service, account } = await business();
    const cust = (await api('POST', '/parties', { type: 'customer', name: 'Patel Constructions', stateCode: '24' })).body;
    const inv = (await api('POST', '/invoices', { locationId: wh.id, partyId: cust.id, lines: [{ itemId: service.id, qty: 1, rate: 1000 }] })).body;
    expect(inv.total).toBe(1180);
    const rec = await api('POST', '/payments', { kind: 'receipt', partyId: cust.id, accountId: account('1010').id, mode: 'bank', amount: 1000, tdsAmount: 180 });
    expect(rec.status).toBe(201);
    expect(rec.body).toMatchObject({ amount: 1000, tdsAmount: 180, allocated: 1180, unallocated: 0 });
    expect((await api('GET', `/invoices/${inv.id}`)).body.paymentStatus).toBe('paid');
    expect(await bal(api, '1310')).toBe(180);
    await balanced(api);
    const over = await api('POST', '/payments', { kind: 'receipt', partyId: cust.id, accountId: account('1010').id, mode: 'bank', amount: 10, tdsAmount: 1,
      allocations: [{ docId: inv.id, amount: 11 }] });
    expect(over.status).toBe(400);
    const vend = (await api('POST', '/parties', { type: 'vendor', name: 'V' })).body;
    expect((await api('POST', '/payments', { kind: 'payment', partyId: vend.id, accountId: account('1010').id, mode: 'bank', amount: 10, tdsAmount: 1 })).status).toBe(400);
    expect((await api('POST', `/payments/${rec.body.id}/cancel`, { reason: 'bounced' })).status).toBe(200);
    expect(await bal(api, '1310')).toBe(0);
  });
});

describe('period lock and deposited TDS', () => {
  it('blocks posting and cancelling inside a locked period', async () => {
    const { api, account } = await business();
    const ho = (await api('GET', '/locations')).body.data[0];
    const expense = (amount: number) => api('POST', '/expenses', { locationId: ho.id, accountId: account('6040').id, description: 'Stationery', amount, paidFromAccountId: account('1000').id });
    const first = await expense(100);
    expect(first.status).toBe(201);
    const today = first.body.expenseDate as string;
    const lock = await api('PATCH', '/company', { booksLockedUntil: today });
    expect(lock.body.booksLockedUntil).toBe(today);
    const blocked = await expense(200);
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('PERIOD_LOCKED');
    expect(blocked.body.error.details).toMatchObject({ lockedUntil: today });
    const cancel = await api('POST', `/expenses/${first.body.id}/cancel`, { reason: 'mistake' });
    expect(cancel.status).toBe(409);
    expect(cancel.body.error.code).toBe('PERIOD_LOCKED');
    expect((await api('PATCH', '/company', { booksLockedUntil: null })).body.booksLockedUntil).toBeNull();
    expect((await expense(200)).status).toBe(201);
  });

  it('keeps company statutory fields and refuses to cancel deposited TDS', async () => {
    const { api, section, vendor, purchase, companyId } = await business();
    const co = await api('PATCH', '/company', { tan: 'MUMP12345E', msmeBankRate: 6.25, gstFiling: 'quarterly' });
    expect(co.body).toMatchObject({ tan: 'MUMP12345E', msmeBankRate: 6.25, gstFiling: 'quarterly', booksLockedUntil: null });

    const v = await vendor('Kiran Contractor', { pan: 'AAAPK1234C', tdsSectionId: section('194C') });
    const bill = await purchase(v.id, 100000);
    expect(bill.body.tdsAmount).toBe(1000);
    await owner(async (c) => {
      const { tenant_id: tenant } = (await c.query('select tenant_id from companies where id = $1', [companyId])).rows[0];
      const user = (await c.query('select id from users where tenant_id = $1 limit 1', [tenant])).rows[0].id;
      const acct = (await c.query('select id from accounts where company_id = $1 limit 1', [companyId])).rows[0].id;
      const ch = (await c.query(
        `insert into tds_challans (tenant_id, company_id, number, deposit_date, bsr_code, challan_serial, tax_amount, total, paid_from_account_id, created_by)
         values ($1, $2, 'TDC/T/00001', current_date, '1234567', '00001', 1000, 1000, $3, $4) returning id`, [tenant, companyId, acct, user])).rows[0].id;
      await c.query('update tds_deductions set challan_id = $1 where source_id = $2', [ch, bill.body.id]);
    });
    const res = await api('POST', `/purchases/${bill.body.id}/cancel`, { reason: 'wrong bill' });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('TDS_DEPOSITED');
  });
});
