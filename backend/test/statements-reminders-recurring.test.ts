import { decodeJwt } from 'jose';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.ts';
import { withTenant } from '../src/db/database.ts';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { enqueue, runJobsOnce } from '../src/lib/jobs.ts';
import { setSender, type OutboundMessage } from '../src/lib/notify.ts';
import { slotDate } from '../src/lib/recurrence.ts';
import { reminderSteps, runRecurring, runReminders, type ReminderSettings } from '../src/modules/receivables.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
const sent: OutboundMessage[] = [];
const config = () => loadConfig({ ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, LOG_LEVEL: 'silent' });
const runJobs = async () => { while ((await runJobsOnce({ db: env.db, config: config() })) > 0) { /* drain */ } };

beforeAll(async () => {
  env = await setupTestApp();
  setSender(async (m) => { sent.push(m); return 'test'; }); // nothing leaves the test
});
afterAll(async () => {
  setSender();
  await teardown(env);
});

const PASSWORD = 'Secret@123';
const T = todayIst();

async function biz(name = 'Receivables Co') {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const token = signup.body.accessToken as string;
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const tenantId = decodeJwt(token).tid as string;
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Main', code: 'M1', stateCode: '24' })).body;
  const mkItem = async (sku: string, price: number, trackStock = false) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, hsnCode: '9954', unit: 'nos', gstRate: 18, salePrice: price, purchasePrice: 10, trackStock });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string };
  };
  const service = await mkItem('SRV', 1000);
  const party = async (nameOf: string, extra: object = {}) => {
    const r = await api('POST', '/parties', { type: 'customer', name: nameOf, stateCode: '24', creditDays: 30, ...extra });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string };
  };
  const invoice = async (partyId: string, date: string, qty: number, rate: number) => {
    const r = await api('POST', '/invoices', { locationId: wh.id, partyId, invoiceDate: date, lines: [{ itemId: service.id, qty, rate }] });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string; number: string; total: number; lines: { id: string }[] };
  };
  const tx = <R>(fn: Parameters<typeof withTenant<R>>[2]) => withTenant(env.db, tenantId, fn);
  return { api, companyId, tenantId, wh, service, mkItem, party, invoice, tx, who: { tenantId, companyId } };
}

describe('party statement', () => {
  it('matches hand-checked balances, ageing and interest', async () => {
    const b = await biz();
    const acme = await b.party('Acme Traders');
    const a = await b.invoice(acme.id, addDays(T, -100), 1, 1000); // 1180, due T-70
    const bb = await b.invoice(acme.id, addDays(T, -40), 2, 1000); // 2360, due T-10
    await b.invoice(acme.id, addDays(T, -5), 1, 500); // 590, due T+25
    expect(a.total).toBe(1180);
    const accounts = (await b.api('GET', '/accounts')).body.data as { id: string; subtype: string }[];
    const cash = accounts.find((x) => x.subtype === 'cash')!;
    const rec = await b.api('POST', '/payments', {
      kind: 'receipt', partyId: acme.id, date: addDays(T, -20), accountId: cash.id, mode: 'cash', amount: 1000, allocations: [{ docId: a.id, amount: 1000 }],
    });
    expect(rec.status, JSON.stringify(rec.body)).toBe(201);
    const detail = (await b.api('GET', `/invoices/${bb.id}`)).body;
    const cn = await b.api('POST', '/credit-notes', { invoiceId: bb.id, noteDate: addDays(T, -15), reason: 'Return of one', lines: [{ invoiceLineId: detail.lines[0].id, qty: 1 }] });
    expect(cn.status, JSON.stringify(cn.body)).toBe(201);

    const s = (await b.api('GET', `/parties/${acme.id}/statement?from=${addDays(T, -60)}&to=${T}`)).body;
    expect(s.openingBalance).toBe(1180);
    expect(s.lines.map((l: { type: string; debit: number; credit: number; balance: number }) => [l.type, l.debit, l.credit, l.balance])).toEqual([
      ['sales', 2360, 0, 3540], ['receipt', 0, 1000, 2540], ['credit_note', 0, 1180, 1360], ['sales', 590, 0, 1950],
    ]);
    expect(s.lines[0].dueDate).toBe(addDays(T, -10));
    expect(s.lines[1].dueDate).toBeNull();
    expect(s.totalDebit).toBe(2950);
    expect(s.totalCredit).toBe(2180);
    expect(s.closingBalance).toBe(1950);
    expect(s.openBills).toHaveLength(3);
    expect(s.ageing).toMatchObject({ basis: 'receivable', notDue: 590, d1_30: 1180, d31_60: 0, d61_90: 180, d90plus: 0, total: 1950 });
    expect(s.openTotal).toBe(s.closingBalance);
    expect(s.interestTotal).toBe(0);
    expect(s.openBills.every((x: { interestDue: number | null }) => x.interestDue === null)).toBe(true);
    expect(s.payablesAgeing).toBeNull();

    // 18% a year: 180 for 70 days and 1180 for 10 days; the not-due bill pays none.
    expect((await b.api('PATCH', '/reminders/settings', { overdueInterestPct: 18 })).status).toBe(200);
    const s2 = (await b.api('GET', `/parties/${acme.id}/statement?from=${addDays(T, -60)}&to=${T}`)).body;
    const interest = Object.fromEntries(s2.openBills.map((x: { amountDue: number; interestDue: number }) => [x.amountDue, x.interestDue]));
    expect(interest[180]).toBe(6.21);
    expect(interest[1180]).toBe(5.82);
    expect(interest[590]).toBe(0);
    expect(s2.interestTotal).toBe(12.03);
    expect(s2.overdueInterestPct).toBe(18);

    // As of an earlier date the later invoice is not on it and fewer days are overdue.
    const early = (await b.api('GET', `/parties/${acme.id}/statement?from=${addDays(T, -200)}&to=${addDays(T, -50)}`)).body;
    expect(early.openingBalance).toBe(0);
    expect(early.closingBalance).toBe(1180);
    expect(early.openBills.map((x: { number: string }) => x.number)).toContain(a.number);
    expect((await b.api('GET', `/parties/${'00000000-0000-4000-8000-000000000000'}/statement`)).status).toBe(404);
  });

  it('ages vendor bills on the payable side', async () => {
    const b = await biz('Vendor Statement Co');
    const vendor = (await b.api('POST', '/parties', { type: 'vendor', name: 'Supplier One', stateCode: '24', creditDays: 30 })).body;
    const goods = await b.mkItem('GD1', 100, true);
    const bill = await b.api('POST', '/purchases', {
      locationId: b.wh.id, partyId: vendor.id, billDate: addDays(T, -50), supplierInvoiceNo: 'S-1',
      lines: [{ itemId: goods.id, qty: 10, rate: 100 }],
    });
    expect(bill.status, JSON.stringify(bill.body)).toBe(201);
    const s = (await b.api('GET', `/parties/${vendor.id}/statement?from=${addDays(T, -90)}&to=${T}`)).body;
    expect(s.ageing.basis).toBe('payable');
    expect(s.openBills).toHaveLength(1);
    expect(s.openBills[0]).toMatchObject({ type: 'purchase', dueDate: addDays(T, -20), daysOverdue: 20, interestDue: null });
    expect(s.ageing.d1_30).toBe(s.openBills[0].amountDue);
    expect(s.closingBalance).toBe(-s.openBills[0].amountDue);
    expect(s.lines[0].type).toBe('purchase');
    expect(s.lines[0].dueDate).toBe(addDays(T, -20));
  });
});

describe('payment reminders', () => {
  const settings = (over: Partial<ReminderSettings> = {}): ReminderSettings => ({
    enabled: true, daysBefore: 3, onDueDate: true, repeatEveryDays: 7, maxRepeats: 2, channels: ['email', 'whatsapp'], overdueInterestPct: 0, updatedAt: null, ...over,
  });

  it('lists the steps of an invoice', () => {
    expect(reminderSteps(settings(), '2026-06-10')).toEqual([
      { step: 'before', date: '2026-06-07' }, { step: 'due', date: '2026-06-10' },
      { step: 'after_1', date: '2026-06-17' }, { step: 'after_2', date: '2026-06-24' },
    ]);
    expect(reminderSteps(settings({ daysBefore: null, onDueDate: false, maxRepeats: 0 }), '2026-06-10')).toEqual([]);
  });

  it('follows the schedule, never sends a step twice and skips opted-out parties', async () => {
    const b = await biz('Reminder Co');
    const mail = { email: 'buyer@test.in', phone: '9820012345' };
    const buyer = await b.party('Buyer One', { ...mail, creditDays: 10 });
    const optedOut = await b.party('Opted Out', { email: 'no@test.in', creditDays: 10 });
    const nobody = await b.party('No Contact', { creditDays: 10 });
    const inv1 = await b.invoice(buyer.id, addDays(T, -40), 1, 1000); // due T-30
    const inv2 = await b.invoice(buyer.id, addDays(T, -40), 1, 500); // same day, same due date
    await b.invoice(optedOut.id, addDays(T, -40), 1, 1000);
    await b.invoice(nobody.id, addDays(T, -40), 1, 1000);
    expect((await b.api('PATCH', `/parties/${optedOut.id}/reminders`, { doNotRemind: true })).status).toBe(200);
    expect(((await b.api('GET', '/reminders/excluded')).body.data as { partyId: string }[]).map((x) => x.partyId)).toEqual([optedOut.id]);

    // Off by default: the run does nothing.
    expect((await b.api('POST', '/reminders/run')).body).toMatchObject({ enabled: false, queued: 0 });
    const saved = await b.api('PATCH', '/reminders/settings', { enabled: true, daysBefore: 3, onDueDate: true, repeatEveryDays: 7, maxRepeats: 2, channels: ['email', 'whatsapp'] });
    expect(saved.body).toMatchObject({ enabled: true, daysBefore: 3, maxRepeats: 2 });
    expect((await b.api('PATCH', '/reminders/settings', { channels: [] })).status).toBe(400);

    const due = addDays(T, -30);
    const run = (date: string) => b.tx((tx) => runReminders(tx, b.who, date));
    const count = () => b.tx((tx) => tx.selectFrom('reminder_log').select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow()).then((r) => Number(r.n));
    const outbox = () => b.tx((tx) => tx.selectFrom('notification_outbox').select(['channel', 'party_id', 'status']).where('template', '=', 'payment_reminder').execute());

    // A day before the first step: nothing.
    expect(await run(addDays(due, -4))).toMatchObject({ queued: 0, parties: 0 });
    // Three days before due: the buyer gets one email and one WhatsApp for both invoices; the other two parties get none or a skip.
    const first = await run(addDays(due, -3));
    expect(first).toMatchObject({ enabled: true, parties: 2, invoices: 3, queued: 1, skipped: 1 });
    let box = await outbox();
    expect(box.filter((o) => o.party_id === buyer.id).map((o) => o.channel).sort()).toEqual(['email', 'whatsapp']);
    expect(box.some((o) => o.party_id === optedOut.id)).toBe(false);
    expect(box.some((o) => o.party_id === nobody.id)).toBe(false);
    const log = (await b.api('GET', '/reminders/log')).body;
    expect(log.total).toBe(3);
    expect(log.data.find((l: { partyName: string }) => l.partyName === 'No Contact')).toMatchObject({ status: 'skipped', note: 'No email or phone', delivery: 'none' });
    expect(log.data.find((l: { invoiceNumber: string }) => l.invoiceNumber === inv1.number)).toMatchObject({ step: 'before', stepLabel: 'Before due date', status: 'queued', amount: 1180 + 590 });

    // The same day again, and the day after, send nothing new.
    expect(await run(addDays(due, -3))).toMatchObject({ queued: 0, parties: 0 });
    expect(await run(addDays(due, -2))).toMatchObject({ queued: 0, parties: 0 });
    expect(await count()).toBe(3);

    // Due date, then 7 days after, then 14 days after, then no more (maxRepeats 2).
    expect(await run(due)).toMatchObject({ queued: 1, skipped: 1 });
    expect(await run(due)).toMatchObject({ queued: 0 });
    expect(await run(addDays(due, 7))).toMatchObject({ queued: 1 });
    expect(await run(addDays(due, 14))).toMatchObject({ queued: 1 });
    expect(await run(addDays(due, 21))).toMatchObject({ queued: 0, parties: 0 });
    expect(await run(addDays(due, 22))).toMatchObject({ queued: 0, parties: 0 });
    box = await outbox();
    expect(box.filter((o) => o.party_id === buyer.id && o.channel === 'email')).toHaveLength(4);
    const steps = await b.tx((tx) => tx.selectFrom('reminder_log').select('step').where('invoice_id', '=', inv2.id).execute());
    expect(steps.map((s) => s.step).sort()).toEqual(['after_1', 'after_2', 'before', 'due']);

    // The unique key is the last guard: the same invoice and step cannot be logged twice.
    await expect(b.tx((tx) => tx.insertInto('reminder_log').values({
      tenant_id: b.tenantId, company_id: b.companyId, party_id: buyer.id, invoice_id: inv1.id, step: 'due', step_date: due, run_date: T, status: 'queued',
    }).execute())).rejects.toThrow();

    // Delivery goes through the stub, never to a real provider.
    sent.length = 0;
    await runJobs();
    expect(sent.filter((m) => m.to === 'buyer@test.in' && m.template === 'payment_reminder').length).toBeGreaterThanOrEqual(4);
    expect(sent.some((m) => m.to === 'no@test.in')).toBe(false);
  });

  it('catches up a step missed by a few days and pays attention to payment', async () => {
    const b = await biz('Catch Up Co');
    const p = await b.party('Late Payer', { email: 'late@test.in', creditDays: 10 });
    const paid = await b.party('Paid Up', { email: 'paid@test.in', creditDays: 10 });
    const fresh = await b.party('Cash Buyer', { email: 'fresh@test.in', creditDays: 0 });
    await b.invoice(p.id, addDays(T, -30), 1, 1000); // due T-20
    const settled = await b.invoice(paid.id, addDays(T, -30), 1, 1000);
    await b.invoice(fresh.id, T, 1, 1000); // due today, created today
    const cash = ((await b.api('GET', '/accounts')).body.data as { id: string; subtype: string }[]).find((x) => x.subtype === 'cash')!;
    expect((await b.api('POST', '/payments', { kind: 'receipt', partyId: paid.id, accountId: cash.id, mode: 'cash', amount: settled.total })).status).toBe(201);
    await b.api('PATCH', '/reminders/settings', { enabled: true, daysBefore: null, onDueDate: true, repeatEveryDays: 30, maxRepeats: 0, channels: ['email'] });
    const run = (date: string) => b.tx((tx) => runReminders(tx, b.who, date));
    // The due date was 2 days ago; the run is late but within the catch-up window.
    expect(await run(addDays(T, -18))).toMatchObject({ queued: 1, parties: 1 });
    // Today the cash invoice is due, but a reminder on the day it was made would be noise.
    expect(await run(T)).toMatchObject({ queued: 0, parties: 0 });
    // Through the route, the same logic is idempotent.
    expect((await b.api('POST', '/reminders/run')).body).toMatchObject({ enabled: true, queued: 0 });
  });

  it('runs through the daily job handler and needs the right permission', async () => {
    const b = await biz('Job Reminder Co');
    const p = await b.party('Job Buyer', { email: 'job@test.in', creditDays: 5 });
    await b.invoice(p.id, addDays(T, -9), 1, 1000); // due T-4: 'due' step is 4 days back, outside the catch-up window
    await b.invoice(p.id, addDays(T, -5), 1, 1000); // due T: 'due' step is today
    await b.api('PATCH', '/reminders/settings', { enabled: true, daysBefore: null, onDueDate: true, maxRepeats: 0, channels: ['email'] });
    sent.length = 0;
    await b.tx((tx) => enqueue(tx, { tenantId: b.tenantId, companyId: b.companyId, userId: null }, 'reminders.run', { day: T }));
    await runJobs();
    expect(sent.filter((m) => m.to === 'job@test.in' && m.template === 'payment_reminder')).toHaveLength(1);
    const log = (await b.api('GET', '/reminders/log')).body;
    expect(log.total).toBe(1);
    const viewer = (await b.api('POST', '/roles', { name: 'Viewer', permissions: ['invoices.view', 'parties.view'] })).body;
    const email = uniqueEmail('v');
    await b.api('POST', '/users', { name: 'Viewer', email, password: PASSWORD, roleId: viewer.id });
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    const v = client(env.app, login.body.accessToken, b.companyId);
    expect((await v('GET', '/reminders/settings')).status).toBe(403);
    expect((await v('POST', '/reminders/run')).status).toBe(403);
    expect((await v('PATCH', `/parties/${p.id}/reminders`, { doNotRemind: true })).status).toBe(403);
  });
});

describe('recurring invoices', () => {
  it('works out month-end, quarter and leap-year dates', () => {
    const m = (start: string, dom: number | null = null) => (n: number) => slotDate({ frequency: 'monthly', startDate: start, dayOfMonth: dom }, n);
    const a = m('2026-01-31');
    expect([0, 1, 2, 3, 4].map(a)).toEqual(['2026-01-31', '2026-02-28', '2026-03-31', '2026-04-30', '2026-05-31']);
    expect(m('2027-12-31')(2)).toBe('2028-02-29');
    expect([0, 1, 2].map(m('2026-02-10', 31))).toEqual(['2026-02-28', '2026-03-31', '2026-04-30']);
    expect([0, 1].map(m('2026-01-10', 5))).toEqual(['2026-02-05', '2026-03-05']); // the 5th of January is already past
    expect([0, 1, 2].map(m('2026-11-20', 5))).toEqual(['2026-12-05', '2027-01-05', '2027-02-05']);
    const q = (n: number) => slotDate({ frequency: 'quarterly', startDate: '2026-01-15', dayOfMonth: null }, n);
    expect([0, 1, 2, 3, 4].map(q)).toEqual(['2026-01-15', '2026-04-15', '2026-07-15', '2026-10-15', '2027-01-15']);
    const h = (n: number) => slotDate({ frequency: 'half_yearly', startDate: '2026-08-31', dayOfMonth: null }, n);
    expect([0, 1, 2].map(h)).toEqual(['2026-08-31', '2027-02-28', '2027-08-31']);
    const y = (n: number) => slotDate({ frequency: 'yearly', startDate: '2024-02-29', dayOfMonth: null }, n);
    expect([0, 1, 4].map(y)).toEqual(['2024-02-29', '2025-02-28', '2028-02-29']);
    const w = (n: number) => slotDate({ frequency: 'weekly', startDate: '2026-12-28', dayOfMonth: null }, n);
    expect([0, 1, 2].map(w)).toEqual(['2026-12-28', '2027-01-04', '2027-01-11']);
  });

  const lines = (itemId: string, rate = 1000) => [{ itemId, qty: 1, rate }];

  it('bills each period once, advances the date and is safe to re-run', async () => {
    const b = await biz('Recurring Co');
    const tenant = await b.party('Tenant A', { creditDays: 15 });
    const body = { name: 'Shop rent', partyId: tenant.id, locationId: b.wh.id, lines: lines(b.service.id, 25000), frequency: 'weekly', startDate: addDays(T, -20), notes: 'Rent' };
    const made = await b.api('POST', '/recurring-invoices', body);
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    expect(made.body).toMatchObject({ status: 'active', nextDate: addDays(T, -20), runsDone: 0, partyName: 'Tenant A', createdBy: { name: 'Owner One' } });
    expect(made.body.lines[0]).toMatchObject({ itemName: 'Item SRV', qty: 1, rate: 25000 });
    const id = made.body.id as string;

    const run = await b.api('POST', '/recurring-invoices/run');
    expect(run.status).toBe(200);
    expect(run.body.created.map((c: { period: string }) => c.period)).toEqual([addDays(T, -20), addDays(T, -13), addDays(T, -6)]);
    expect(run.body.errors).toEqual([]);
    const detail = (await b.api('GET', `/recurring-invoices/${id}`)).body;
    expect(detail).toMatchObject({ runsDone: 3, nextDate: addDays(T, 1), status: 'active', lastError: null });
    expect(detail.invoices.map((i: { period: string }) => i.period)).toEqual([addDays(T, -6), addDays(T, -13), addDays(T, -20)]);
    expect(detail.invoices[0]).toMatchObject({ invoiceDate: addDays(T, -6), total: 29500 });
    expect(detail.upcoming[0]).toBe(addDays(T, 1));
    const inv = (await b.api('GET', `/invoices/${detail.invoices[0].invoiceId}`)).body;
    expect(inv.dueDate).toBe(addDays(T, 9)); // customer's 15 credit days from the period

    // Re-running creates nothing, and the unique key blocks a second invoice for a period.
    expect((await b.api('POST', '/recurring-invoices/run')).body.created).toEqual([]);
    await expect(b.tx((tx) => tx.insertInto('recurring_invoice_runs').values({
      tenant_id: b.tenantId, company_id: b.companyId, template_id: id, period: addDays(T, -6), invoice_id: detail.invoices[0].invoiceId,
    }).execute())).rejects.toThrow();
    // Direct re-run with a rewound pointer still creates no duplicate.
    await b.tx((tx) => tx.updateTable('recurring_invoices').set({ slot_no: 2, next_date: addDays(T, -6), runs_done: 2 }).where('id', '=', id).execute());
    const again = await b.tx((tx) => runRecurring(tx, env.db, b.who, T));
    expect(again.created).toEqual([]);
    expect((await b.api('GET', `/recurring-invoices/${id}`)).body).toMatchObject({ nextDate: addDays(T, 1), invoices: expect.any(Array) });
    expect((await b.api('GET', `/recurring-invoices/${id}`)).body.invoices).toHaveLength(3);

    // The schedule is locked after the first invoice; other fields are not.
    expect((await b.api('PATCH', `/recurring-invoices/${id}`, { frequency: 'monthly' })).body.error.code).toBe('SCHEDULE_LOCKED');
    expect((await b.api('PATCH', `/recurring-invoices/${id}`, { name: 'Shop rent 2' })).body.name).toBe('Shop rent 2');
    const list = (await b.api('GET', '/recurring-invoices?status=active')).body;
    expect(list.total).toBe(1);
  });

  it('bills month ends on the last day of short months', async () => {
    const b = await biz('Month End Co');
    const p = await b.party('Retainer Client');
    const year = Number(T.slice(0, 4)) - 1;
    const made = await b.api('POST', '/recurring-invoices', {
      name: 'Retainer', partyId: p.id, locationId: b.wh.id, lines: lines(b.service.id), frequency: 'monthly', startDate: `${year}-01-31`, maxRuns: 4,
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    const run = (await b.api('POST', '/recurring-invoices/run')).body;
    const feb = new Date(Date.UTC(year, 2, 0)).getUTCDate();
    expect(run.created.map((c: { period: string }) => c.period)).toEqual([`${year}-01-31`, `${year}-02-${feb}`, `${year}-03-31`, `${year}-04-30`]);
    const after = (await b.api('GET', `/recurring-invoices/${made.body.id}`)).body;
    expect(after).toMatchObject({ status: 'ended', nextDate: null, runsDone: 4 });
    expect(after.invoices.map((i: { invoiceDate: string }) => i.invoiceDate).reverse()).toEqual(run.created.map((c: { period: string }) => c.period));
    expect((await b.api('PATCH', `/recurring-invoices/${made.body.id}`, { name: 'x' })).body.error.code).toBe('TEMPLATE_ENDED');
  });

  it('stops at the end date, pauses, resumes without back-billing and ends', async () => {
    const b = await biz('Lifecycle Co');
    const p = await b.party('Maintenance Client');
    const mk = (extra: object) => b.api('POST', '/recurring-invoices', { name: 'AMC', partyId: p.id, locationId: b.wh.id, lines: lines(b.service.id), frequency: 'weekly', ...extra });
    // End date: periods T-30 and T-23 only (T-16 is after T-20).
    const limited = await mk({ startDate: addDays(T, -30), endDate: addDays(T, -20) });
    expect(limited.status).toBe(201);
    const r1 = (await b.api('POST', '/recurring-invoices/run')).body;
    expect(r1.created.map((c: { period: string }) => c.period)).toEqual([addDays(T, -30), addDays(T, -23)]);
    expect((await b.api('GET', `/recurring-invoices/${limited.body.id}`)).body).toMatchObject({ status: 'ended', nextDate: null });
    expect((await b.api('POST', '/recurring-invoices', { name: 'Bad', partyId: p.id, locationId: b.wh.id, lines: lines(b.service.id), frequency: 'weekly', startDate: T, endDate: addDays(T, -1) })).status).toBe(400);
    expect((await mk({ startDate: T, dayOfMonth: 5 })).status).toBe(400);

    // Pause: a due template is not billed; resume skips what was missed.
    const live = await mk({ startDate: addDays(T, -3) });
    const id = live.body.id as string;
    expect((await b.api('POST', `/recurring-invoices/${id}/pause`)).body.status).toBe('paused');
    expect((await b.api('POST', `/recurring-invoices/${id}/pause`)).status).toBe(409);
    expect((await b.api('POST', '/recurring-invoices/run')).body.created).toEqual([]);
    const resumed = (await b.api('POST', `/recurring-invoices/${id}/resume`)).body;
    expect(resumed).toMatchObject({ status: 'active', nextDate: addDays(T, 4), runsDone: 0 });
    expect((await b.api('POST', '/recurring-invoices/run')).body.created).toEqual([]);
    expect((await b.api('POST', `/recurring-invoices/${id}/resume`)).status).toBe(409);
    expect((await b.api('POST', `/recurring-invoices/${id}/end`)).body).toMatchObject({ status: 'ended', nextDate: null });
    expect((await b.api('POST', `/recurring-invoices/${id}/end`)).status).toBe(409);
    expect((await b.api('POST', `/recurring-invoices/${id}/pause`)).status).toBe(409);
  });

  it('records an error on one template and carries on with the rest; auto-send queues the invoice', async () => {
    const b = await biz('Mixed Co');
    const p = await b.party('Mixed Client', { email: 'mixed@test.in' });
    const stock = await b.mkItem('STK', 100, true);
    const bad = await b.api('POST', '/recurring-invoices', {
      name: 'No stock', partyId: p.id, locationId: b.wh.id, lines: [{ itemId: stock.id, qty: 5, rate: 100 }], frequency: 'weekly', startDate: addDays(T, -1),
    });
    const good = await b.api('POST', '/recurring-invoices', {
      name: 'Sent plan', partyId: p.id, locationId: b.wh.id, lines: lines(b.service.id), frequency: 'weekly', startDate: addDays(T, -1), autoSend: true, sendChannels: ['email'],
    });
    expect(bad.status).toBe(201);
    sent.length = 0;
    const run = (await b.api('POST', '/recurring-invoices/run')).body;
    expect(run.templates).toBe(2);
    expect(run.created).toHaveLength(1);
    expect(run.errors).toHaveLength(1);
    expect(run.errors[0].name).toBe('No stock');
    const badAfter = (await b.api('GET', `/recurring-invoices/${bad.body.id}`)).body;
    expect(badAfter.lastError).toBeTruthy();
    expect(badAfter).toMatchObject({ nextDate: addDays(T, -1), runsDone: 0, status: 'active' });
    expect((await b.api('GET', `/recurring-invoices/${good.body.id}`)).body.runsDone).toBe(1);
    await runJobs();
    const mail = sent.filter((m) => m.to === 'mixed@test.in');
    expect(mail).toHaveLength(1);
    expect(mail[0]!.template).toBe('recurring_invoice');
    expect(mail[0]!.body).toContain(run.created[0].number);
  });

  it('runs through the daily job handler and checks permissions and input', async () => {
    const b = await biz('Job Recurring Co');
    const p = await b.party('Job Client');
    const vendor = (await b.api('POST', '/parties', { type: 'vendor', name: 'A Vendor', stateCode: '24' })).body;
    const base = { name: 'Plan', locationId: b.wh.id, lines: lines(b.service.id), frequency: 'monthly', startDate: addDays(T, -2) };
    expect((await b.api('POST', '/recurring-invoices', { ...base, partyId: vendor.id })).status).toBe(400);
    expect((await b.api('POST', '/recurring-invoices', { ...base, partyId: p.id, lines: [] })).status).toBe(400);
    expect((await b.api('POST', '/recurring-invoices', { ...base, partyId: p.id, lines: [{ itemId: '00000000-0000-4000-8000-000000000000', qty: 1 }] })).status).toBe(400);
    const made = await b.api('POST', '/recurring-invoices', { ...base, partyId: p.id });
    expect(made.status).toBe(201);
    await b.tx((tx) => enqueue(tx, { tenantId: b.tenantId, companyId: b.companyId, userId: null }, 'recurring.run', { day: T }));
    await runJobs();
    expect((await b.api('GET', `/recurring-invoices/${made.body.id}`)).body).toMatchObject({ runsDone: 1 });
    const viewer = (await b.api('POST', '/roles', { name: 'Reader', permissions: ['invoices.view'] })).body;
    const email = uniqueEmail('r');
    await b.api('POST', '/users', { name: 'Reader', email, password: PASSWORD, roleId: viewer.id });
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    const v = client(env.app, login.body.accessToken, b.companyId);
    expect((await v('GET', '/recurring-invoices')).status).toBe(200);
    expect((await v('GET', `/recurring-invoices/${made.body.id}`)).status).toBe(200);
    expect((await v('POST', '/recurring-invoices', { ...base, partyId: p.id })).status).toBe(403);
    expect((await v('POST', `/recurring-invoices/${made.body.id}/pause`)).status).toBe(403);
    expect((await v('POST', '/recurring-invoices/run')).status).toBe(403);
  });
});
