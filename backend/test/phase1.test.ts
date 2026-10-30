import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;

beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

type Api = ReturnType<typeof client>;

async function business() {
  const email = uniqueEmail('owner');
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Patel Traders', name: 'Kiran Patel', email, password: 'Secret@123', stateCode: '24',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, res.body.accessToken, me.companies[0].id);
  const ho = (await api('GET', '/locations')).body.data[0];
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse' })).body;
  const site = (await api('POST', '/locations', { type: 'site', name: 'Site A' })).body;
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string; systemKey: string | null; balance: number }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!;
  return { email, api, ho, wh, site, account, companyId: me.companies[0].id as string };
}

async function balanceOf(api: Api, code: string) {
  const list = (await api('GET', '/accounts')).body.data as { code: string; balance: number }[];
  return list.find((a) => a.code === code)!.balance;
}

describe('a full business cycle keeps the books exact', () => {
  it('posts every document correctly and ties stock to the ledger', async () => {
    const { api, wh, site, account } = await business();
    const item = (await api('POST', '/items', { name: 'Cement', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50 })).body;

    // Opening stock 100 @ 50.
    const opening = await api('POST', '/stock/adjustments', { locationId: wh.id, itemId: item.id, qty: 100, rate: 50, isOpening: true });
    expect(opening.status).toBe(201);
    expect(opening.body).toMatchObject({ refType: 'opening', value: 5000 });

    // Purchase 50 @ 60 from another state: IGST input.
    const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Mumbai Supplier', gstin: '27AAPFU0939F1ZV', creditDays: 30 })).body;
    const bill = await api('POST', '/purchases', {
      locationId: wh.id, partyId: vendor.id, supplierInvoiceNo: 'MS/778', lines: [{ itemId: item.id, qty: 50, rate: 60 }],
    });
    expect(bill.status).toBe(201);
    expect(bill.body).toMatchObject({ supplyType: 'inter', subtotal: 3000, igst: 540, total: 3540, paymentStatus: 'unpaid', amountDue: 3540 });
    expect(bill.body.number).toMatch(/^PUR\/\d{2}-\d{2}\/00001$/);
    expect((await api('GET', `/items/${item.id}`)).body.avgCost).toBe(53.33);

    // Sale 30 @ 100 within the state; cost of goods at the 53.3333 average.
    const customer = (await api('POST', '/parties', { type: 'customer', name: 'Local Buyer', stateCode: '24', creditDays: 15 })).body;
    const invoice = (await api('POST', '/invoices', { locationId: wh.id, partyId: customer.id, lines: [{ itemId: item.id, qty: 30 }] })).body;
    expect(invoice).toMatchObject({ total: 3540, cgst: 270, sgst: 270, paymentStatus: 'unpaid' });
    expect(invoice.dueDate > invoice.invoiceDate).toBe(true);

    // Partial receipt, allocated automatically.
    const receipt = await api('POST', '/payments', { kind: 'receipt', partyId: customer.id, accountId: account('1000').id, mode: 'cash', amount: 2000 });
    expect(receipt.status).toBe(201);
    expect(receipt.body).toMatchObject({ allocated: 2000, unallocated: 0, number: expect.stringMatching(/^RCT\//) });
    expect((await api('GET', `/invoices/${invoice.id}`)).body).toMatchObject({ amountPaid: 2000, amountDue: 1540, paymentStatus: 'partial' });
    const ids = async (query: string) => (await api('GET', `/invoices?${query}`)).body.data.map((v: { id: string }) => v.id);
    expect(await ids(`partyId=${customer.id}&paymentStatus=partial`)).toEqual([invoice.id]);
    expect(await ids(`partyId=${customer.id}&paymentStatus=unpaid`)).toEqual([]);

    // Return 5 bags: restocked at the cost they left at.
    const line = (await api('GET', `/invoices/${invoice.id}`)).body.lines[0];
    const note = await api('POST', '/credit-notes', { invoiceId: invoice.id, reason: 'Damaged bags', lines: [{ invoiceLineId: line.id, qty: 5 }] });
    expect(note.status).toBe(201);
    expect(note.body).toMatchObject({ subtotal: 500, cgst: 45, sgst: 45, total: 590, restock: true });
    const afterReturn = (await api('GET', `/invoices/${invoice.id}`)).body;
    expect(afterReturn).toMatchObject({ amountPaid: 2590, amountDue: 950 });
    expect(afterReturn.lines[0].returnedQty).toBe(5);
    expect(afterReturn.settlements.map((s: { kind: string }) => s.kind).sort()).toEqual(['credit_note', 'receipt']);
    const tooMuch = await api('POST', '/credit-notes', { invoiceId: invoice.id, reason: 'Again', lines: [{ invoiceLineId: line.id, qty: 26 }] });
    expect(tooMuch.status).toBe(400);

    // Transfer 20 to the site: in transit until received.
    const transfer = await api('POST', '/transfers', { fromLocationId: wh.id, toLocationId: site.id, lines: [{ itemId: item.id, qty: 20 }] });
    expect(transfer.status).toBe(201);
    expect(transfer.body).toMatchObject({ status: 'in_transit', totalValue: 1066.67 });
    expect(await balanceOf(api, '1210')).toBe(1066.67);
    const siteBefore = (await api('GET', `/stock?locationId=${site.id}`)).body.data;
    expect(siteBefore).toHaveLength(0);
    const received = await api('POST', `/transfers/${transfer.body.id}/receive`);
    expect(received.body.status).toBe('received');
    expect((await api('GET', `/stock?locationId=${site.id}`)).body.data[0]).toMatchObject({ qty: 20, value: 1066.67 });
    expect(await balanceOf(api, '1210')).toBe(0);

    // Rent with GST, paid in cash.
    const expense = await api('POST', '/expenses', {
      locationId: wh.id, accountId: account('6000').id, description: 'October rent', amount: 1000, gstRate: 18, paidFromAccountId: account('1000').id,
    });
    expect(expense.status).toBe(201);
    expect(expense.body).toMatchObject({ cgst: 90, sgst: 90, total: 1180, accountName: 'Rent' });

    // Pay the vendor in full from the bank.
    const payment = await api('POST', '/payments', { kind: 'payment', partyId: vendor.id, accountId: account('1010').id, mode: 'bank', amount: 3540, reference: 'NEFT123' });
    expect(payment.body).toMatchObject({ allocated: 3540, allocations: [{ docNumber: bill.body.number, amount: 3540 }] });
    expect((await api('GET', `/purchases/${bill.body.id}`)).body.paymentStatus).toBe('paid');

    // Ledger balances.
    expect(await balanceOf(api, '1000')).toBe(820);
    expect(await balanceOf(api, '1010')).toBe(-3540);
    expect(await balanceOf(api, '1100')).toBe(950);
    expect(await balanceOf(api, '2000')).toBe(0);
    expect(await balanceOf(api, '1200')).toBe(6666.67);

    // Inventory account equals the stock ledger's value.
    const valuation = (await api('GET', '/reports/stock-valuation')).body;
    expect(valuation.totalValue).toBe(6666.67);
    expect(valuation.rows[0]).toMatchObject({ qty: 125, avgCost: 53.33 });

    const tb = (await api('GET', '/reports/trial-balance')).body;
    expect(tb.totalDebit).toBe(tb.totalCredit);

    const pl = (await api('GET', '/reports/profit-loss')).body;
    expect(pl.revenue.total).toBe(2500);
    expect(pl.cogs.total).toBe(1333.33);
    expect(pl.grossProfit).toBe(1166.67);
    expect(pl.expenses.rows).toEqual([expect.objectContaining({ name: 'Rent', amount: 1000 })]);
    expect(pl.netProfit).toBe(166.67);

    const bs = (await api('GET', '/reports/balance-sheet')).body;
    expect(bs.totalAssets).toBe(5616.67);
    expect(bs.totalLiabilitiesAndEquity).toBe(5616.67);
    expect(bs.equity.rows).toContainEqual(expect.objectContaining({ name: 'Profit & Loss', amount: 166.67 }));

    const gst = (await api('GET', '/reports/gst-summary')).body;
    expect(gst.outward.byRate).toEqual([{ gstRate: 18, taxable: 3000, cgst: 270, sgst: 270, igst: 0 }]);
    expect(gst.outward.b2c).toEqual({ count: 1, taxable: 3000, tax: 540 });
    expect(gst.outward.net).toMatchObject({ taxable: 2500, cgst: 225, sgst: 225 });
    expect(gst.inward.total).toMatchObject({ taxable: 4000, cgst: 90, sgst: 90, igst: 540 });
    expect(gst.netPayable).toEqual({ cgst: 135, sgst: 135, igst: -540, total: -270 });
    expect(gst.hsn).toEqual([{ hsnCode: '2523', unit: 'bag', qty: 25, taxable: 2500, cgst: 225, sgst: 225, igst: 0 }]);

    const ageing = (await api('GET', '/reports/ageing?type=receivables')).body;
    expect(ageing.rows).toEqual([expect.objectContaining({ partyName: 'Local Buyer', notDue: 950, total: 950 })]);

    const statement = (await api('GET', `/parties/${customer.id}/statement`)).body;
    expect(statement.closingBalance).toBe(950);
    expect(statement.lines.map((l: { voucherType: string }) => l.voucherType)).toEqual(['sales', 'receipt', 'credit_note']);
    expect((await api('GET', `/parties/${customer.id}`)).body.balance).toBe(950);

    const dash = (await api('GET', '/dashboard')).body;
    expect(dash).toMatchObject({ receivables: 950, payables: 0, cashAndBank: -2720, purchasesThisMonth: 3540 });

    const sales = (await api('GET', '/reports/sales-register')).body;
    expect(sales.totals).toEqual({ taxable: 3000, cgst: 270, sgst: 270, igst: 0, total: 3540 });
    const dayBook = (await api('GET', '/journals')).body;
    expect(dayBook.total).toBeGreaterThanOrEqual(9);
  });
});

describe('cancellations reverse cleanly', () => {
  it('requires settlements to be cancelled first and restores everything', async () => {
    const { api, wh, account } = await business();
    const item = (await api('POST', '/items', { name: 'Tiles', unit: 'box', gstRate: 18, salePrice: 500, purchasePrice: 400 })).body;
    await api('POST', '/stock/adjustments', { locationId: wh.id, itemId: item.id, qty: 10, rate: 400, isOpening: true });
    const customer = (await api('POST', '/parties', { type: 'customer', name: 'Buyer', stateCode: '24' })).body;
    const invoice = (await api('POST', '/invoices', { locationId: wh.id, partyId: customer.id, lines: [{ itemId: item.id, qty: 2 }] })).body;
    const receipt = (await api('POST', '/payments', { kind: 'receipt', partyId: customer.id, accountId: account('1000').id, mode: 'upi', amount: 500 })).body;

    const blocked = await api('POST', `/invoices/${invoice.id}/cancel`, { reason: 'Mistake' });
    expect(blocked.status).toBe(409);
    expect(blocked.body.error.code).toBe('HAS_SETTLEMENTS');

    expect((await api('POST', `/payments/${receipt.id}/cancel`, { reason: 'Bounced' })).body.status).toBe('cancelled');
    expect((await api('GET', `/invoices/${invoice.id}`)).body.amountPaid).toBe(0);
    expect((await api('POST', `/invoices/${invoice.id}/cancel`, { reason: 'Mistake' })).status).toBe(200);

    expect(await balanceOf(api, '1100')).toBe(0);
    expect(await balanceOf(api, '1000')).toBe(0);
    expect(await balanceOf(api, '1200')).toBe(4000);
    expect((await api('GET', '/reports/profit-loss')).body.netProfit).toBe(0);
    const tb = (await api('GET', '/reports/trial-balance')).body;
    expect(tb.totalDebit).toBe(tb.totalCredit);
  });

  it('refuses to cancel a bill whose stock is already sold', async () => {
    const { api, wh } = await business();
    const item = (await api('POST', '/items', { name: 'Paint', unit: 'ltr', gstRate: 18, salePrice: 300, purchasePrice: 200 })).body;
    const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Paint Co', stateCode: '24' })).body;
    const customer = (await api('POST', '/parties', { type: 'customer', name: 'Painter', stateCode: '24' })).body;
    const bill = (await api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId: item.id, qty: 10 }] })).body;
    expect(bill).toMatchObject({ supplyType: 'intra', cgst: 180, sgst: 180, total: 2360 });
    await api('POST', '/invoices', { locationId: wh.id, partyId: customer.id, lines: [{ itemId: item.id, qty: 8 }] });
    const res = await api('POST', `/purchases/${bill.id}/cancel`, { reason: 'Wrong vendor' });
    expect(res.status).toBe(409);
    expect(res.body.error.code).toBe('INSUFFICIENT_STOCK');
  });

  it('cancels a transfer in transit and a manual journal', async () => {
    const { api, wh, site, account } = await business();
    const item = (await api('POST', '/items', { name: 'Steel', unit: 'kg', gstRate: 18, salePrice: 70, purchasePrice: 60 })).body;
    await api('POST', '/stock/adjustments', { locationId: wh.id, itemId: item.id, qty: 100, rate: 60, isOpening: true });
    const t = (await api('POST', '/transfers', { fromLocationId: wh.id, toLocationId: site.id, lines: [{ itemId: item.id, qty: 40 }] })).body;
    expect((await api('GET', `/stock?locationId=${wh.id}`)).body.data[0].qty).toBe(60);
    expect((await api('POST', `/transfers/${t.id}/cancel`, { reason: 'Truck unavailable' })).body.status).toBe('cancelled');
    expect((await api('GET', `/stock?locationId=${wh.id}`)).body.data[0].qty).toBe(100);
    expect((await api('POST', `/transfers/${t.id}/receive`)).status).toBe(409);
    expect(await balanceOf(api, '1210')).toBe(0);

    const unbalanced = await api('POST', '/journals', { narration: 'Capital', lines: [
      { accountId: account('1010').id, debit: 100000 }, { accountId: account('3000').id, credit: 90000 }] });
    expect(unbalanced.status).toBe(400);
    const both = await api('POST', '/journals', { narration: 'Bad', lines: [
      { accountId: account('1010').id, debit: 5, credit: 5 }, { accountId: account('3000').id, credit: 5 }] });
    expect(both.status).toBe(400);
    const jv = await api('POST', '/journals', { narration: 'Capital introduced', lines: [
      { accountId: account('1010').id, debit: 100000 }, { accountId: account('3000').id, credit: 100000 }] });
    expect(jv.status).toBe(201);
    expect(jv.body.number).toMatch(/^JV\//);
    expect(await balanceOf(api, '1010')).toBe(100000);
    const reversal = await api('POST', `/journals/${jv.body.id}/cancel`, { reason: 'Entered twice' });
    expect(reversal.status).toBe(200);
    expect(reversal.body).toMatchObject({ isReversal: true, reversesId: jv.body.id, reversedById: null });
    expect((await api('GET', `/journals/${jv.body.id}`)).body).toMatchObject({ reversesId: null, reversedById: reversal.body.id });
    expect((await api('POST', `/journals/${jv.body.id}/cancel`, { reason: 'Again' })).status).toBe(409);
    expect(await balanceOf(api, '1010')).toBe(0);
  });
});

describe('payment allocation rules', () => {
  it('validates allocations and keeps advances on the party', async () => {
    const { api, wh, account } = await business();
    const item = (await api('POST', '/items', { name: 'Labour', unit: 'day', gstRate: 18, salePrice: 1000, trackStock: false })).body;
    const customer = (await api('POST', '/parties', { type: 'customer', name: 'Client', stateCode: '24' })).body;
    const vendorOnly = (await api('POST', '/parties', { type: 'vendor', name: 'Supplier', stateCode: '24' })).body;
    const inv = (await api('POST', '/invoices', { locationId: wh.id, partyId: customer.id, lines: [{ itemId: item.id, qty: 1 }] })).body;
    expect(inv.total).toBe(1180);

    const cash = account('1000').id;
    expect((await api('POST', '/payments', { kind: 'receipt', partyId: vendorOnly.id, accountId: cash, mode: 'cash', amount: 10 })).status).toBe(400);
    expect((await api('POST', '/payments', { kind: 'receipt', partyId: customer.id, accountId: account('1100').id, mode: 'cash', amount: 10 })).status).toBe(400);
    expect((await api('POST', '/payments', { kind: 'receipt', partyId: customer.id, accountId: cash, mode: 'cash', amount: 2000,
      allocations: [{ docId: inv.id, amount: 1500 }] })).status).toBe(400);
    expect((await api('POST', '/payments', { kind: 'receipt', partyId: customer.id, accountId: cash, mode: 'cash', amount: 100,
      allocations: [{ docId: inv.id, amount: 500 }] })).status).toBe(400);

    const advance = (await api('POST', '/payments', { kind: 'receipt', partyId: customer.id, accountId: cash, mode: 'cash', amount: 2000 })).body;
    expect(advance).toMatchObject({ allocated: 1180, unallocated: 820 });
    const outstanding = (await api('GET', `/parties/${customer.id}/outstanding`)).body;
    expect(outstanding).toMatchObject({ balance: -820, invoices: [] });
  });
});

describe('administration', () => {
  it('edits the company profile with GST rules', async () => {
    const { api, wh } = await business();
    const ok = await api('PATCH', '/company', { address: '12 Ring Road, Surat', bankName: 'HDFC Bank', bankAccountNo: '50100012345678',
      bankIfsc: 'HDFC0000123', upiId: 'patel@hdfcbank', invoiceTerms: 'Goods once sold will not be taken back.', gstin: '24AABCP1234C1Z9' });
    expect(ok.status).toBe(200);
    expect(ok.body).toMatchObject({ pan: 'AABCP1234C', bankIfsc: 'HDFC0000123', upiId: 'patel@hdfcbank' });
    expect((await api('PATCH', '/company', { gstin: '27AAPFU0939F1ZV' })).status).toBe(400);
    expect((await api('PATCH', '/company', { bankIfsc: 'BAD' })).status).toBe(400);
    expect((await api('GET', '/company')).body.address).toBe('12 Ring Road, Surat');

    const item = (await api('POST', '/items', { name: 'X', unit: 'pcs', gstRate: 5, salePrice: 10, trackStock: false })).body;
    const party = (await api('POST', '/parties', { type: 'customer', name: 'Y', stateCode: '24' })).body;
    await api('POST', '/invoices', { locationId: wh.id, partyId: party.id, lines: [{ itemId: item.id, qty: 1 }] });
    expect((await api('PATCH', '/company', { stateCode: '27', gstin: null })).status).toBe(409);
  });

  it('manages users, roles and passwords safely', async () => {
    const { api, email } = await business();
    const me = (await api('GET', '/me')).body;
    const ownerId = me.user.id;
    const roles = (await api('GET', '/roles')).body.data as { id: string; name: string; isSystem: boolean }[];
    const role = (n: string) => roles.find((r) => r.name === n)!.id;

    expect((await api('PATCH', `/users/${ownerId}`, { isActive: false })).status).toBe(400);
    expect((await api('PATCH', `/users/${ownerId}`, { roleId: role('Accountant') })).status).toBe(409);

    const adminEmail = uniqueEmail('admin');
    const admin = (await api('POST', '/users', { name: 'Admin', email: adminEmail, password: 'Secret@123', roleId: role('Company Admin') })).body;
    const adminLogin = await client(env.app)('POST', '/auth/login', { email: adminEmail, password: 'Secret@123' });
    const asAdmin = client(env.app, adminLogin.body.accessToken);
    expect((await asAdmin('PATCH', `/users/${ownerId}`, { name: 'Hacked' })).status).toBe(403);
    expect((await asAdmin('POST', `/users/${ownerId}/password`, { password: 'Hacked@123' })).status).toBe(403);

    const sales = (await api('POST', '/users', { name: 'Sam', email: uniqueEmail('sam'), password: 'Secret@123', roleId: role('Sales Executive') })).body;
    const updated = await asAdmin('PATCH', `/users/${sales.id}`, { name: 'Sameer', roleId: role('Accountant') });
    expect(updated.status).toBe(200);
    expect(updated.body).toMatchObject({ name: 'Sameer', assignments: [{ roleName: 'Accountant', locationIds: null }] });
    expect((await api('PATCH', `/users/${admin.id}`, { isActive: false })).body.isActive).toBe(false);
    expect((await client(env.app)('POST', '/auth/login', { email: adminEmail, password: 'Secret@123' })).status).toBe(401);

    expect((await api('POST', '/me/password', { currentPassword: 'Wrong@123', newPassword: 'Newer@1234' })).status).toBe(400);
    expect((await api('POST', '/me/password', { currentPassword: 'Secret@123', newPassword: 'Newer@1234' })).status).toBe(204);
    expect((await client(env.app)('POST', '/auth/login', { email, password: 'Newer@1234' })).status).toBe(200);

    expect((await api('PATCH', `/roles/${role('Owner')}`, { name: 'Boss' })).status).toBe(403);
    const custom = (await api('POST', '/roles', { name: 'Billing Clerk', permissions: ['invoices.view', 'invoices.create'] })).body;
    const edited = await api('PATCH', `/roles/${custom.id}`, { permissions: ['invoices.view', 'invoices.create', 'payments.create'] });
    expect(edited.body.permissions).toContain('payments.create');
  });

  it('limits account pickers and reports by role', async () => {
    const { api, wh, site } = await business();
    const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
    const salesEmail = uniqueEmail('sales');
    await api('POST', '/users', { name: 'Sales', email: salesEmail, password: 'Secret@123', roleId: roles.find((r) => r.name === 'Sales Executive')!.id });
    const s = await client(env.app)('POST', '/auth/login', { email: salesEmail, password: 'Secret@123' });
    const sales = client(env.app, s.body.accessToken);
    const picker = (await sales('GET', '/accounts')).body.data as { subtype: string; type: string; balance: number }[];
    expect(picker.length).toBeGreaterThan(0);
    expect(picker.every((a) => ['cash', 'bank'].includes(a.subtype) || a.type === 'expense')).toBe(true);
    expect(picker.every((a) => a.balance === 0)).toBe(true);
    expect((await sales('GET', '/reports/trial-balance')).status).toBe(403);
    expect((await sales('GET', '/reports/gst-summary')).status).toBe(403);
    expect((await sales('GET', '/dashboard')).body.receivables).toBe(0);

    // A site supervisor receives transfers to their site only.
    const supEmail = uniqueEmail('sup');
    await api('POST', '/users', { name: 'Sup', email: supEmail, password: 'Secret@123',
      roleId: roles.find((r) => r.name === 'Site Supervisor')!.id, locationIds: [site.id] });
    const item = (await api('POST', '/items', { name: 'Bricks', unit: 'nos', gstRate: 5, salePrice: 9, purchasePrice: 7 })).body;
    await api('POST', '/stock/adjustments', { locationId: wh.id, itemId: item.id, qty: 1000, isOpening: true });
    const toSite = (await api('POST', '/transfers', { fromLocationId: wh.id, toLocationId: site.id, lines: [{ itemId: item.id, qty: 100 }] })).body;
    const sup = client(env.app, (await client(env.app)('POST', '/auth/login', { email: supEmail, password: 'Secret@123' })).body.accessToken);
    expect((await sup('GET', '/transfers')).body.data.map((t: { id: string }) => t.id)).toEqual([toSite.id]);
    expect((await sup('POST', `/transfers/${toSite.id}/receive`)).body.status).toBe('received');
    const back = (await sup('POST', '/transfers', { fromLocationId: site.id, toLocationId: wh.id, lines: [{ itemId: item.id, qty: 10 }] })).body;
    expect((await sup('POST', `/transfers/${back.id}/receive`)).status).toBe(403);
  });
});
