import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

const today = () => todayIst();

async function firm() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Shah and Associates', name: 'Owner', email: uniqueEmail('lg'), password: 'Secret@123', stateCode: '24', businessType: 'advocate',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  await api('POST', '/locations', { type: 'store', name: 'Office' });
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const as = async (roleName: string) => {
    const email = uniqueEmail(roleName.replace(/\W/g, ''));
    const role = roles.find((r) => r.name === roleName)!;
    expect(role, roleName).toBeTruthy();
    const made = await api('POST', '/users', { name: roleName, email, password: 'Secret@123', roleId: role.id });
    expect(made.status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    return { api: client(env.app, li.body.accessToken, companyId), userId: made.body.id as string };
  };
  const client1 = (await api('POST', '/parties', { type: 'customer', name: 'Mehta Traders', stateCode: '27', gstin: '27AAPFU0939F1ZV' })).body;
  const client2 = (await api('POST', '/parties', { type: 'customer', name: 'Ravi Patel', stateCode: '24' })).body;
  return { api, as, companyId, client1, client2 };
}
type Firm = Awaited<ReturnType<typeof firm>>;

const matterBody = (f: Firm, over: Record<string, unknown> = {}) => ({
  title: 'Mehta Traders v. Shree Steel', clientId: f.client1.id, opposingParty: 'Shree Steel Ltd', court: 'City Civil Court, Ahmedabad',
  caseType: 'Civil Suit', caseNo: 'CS 412', caseYear: 2026, stage: 'Notice', feeType: 'hourly', hourlyRate: 3000, ...over,
});

describe('legal matters and visibility', () => {
  it('creates a numbered matter and limits visibility to the team and managers', async () => {
    const f = await firm();
    const assoc = await f.as('Associate');
    const other = await f.as('Associate');
    const created = await f.api('POST', '/legal/matters', matterBody(f, { advocateId: assoc.userId }));
    expect(created.status).toBe(201);
    expect(created.body.matterNo).toMatch(/^MAT\/\d{2}-\d{2}\/00001$/);
    const second = await f.api('POST', '/legal/matters', matterBody(f, { title: 'Second', teamIds: [other.userId] }));
    expect(second.body.matterNo).toMatch(/00002$/);

    const mine = await assoc.api('GET', '/legal/matters');
    expect(mine.body.data.map((m: { id: string }) => m.id)).toEqual([created.body.id]);
    expect((await assoc.api('GET', `/legal/matters/${second.body.id}`)).status).toBe(404);
    expect((await other.api('GET', `/legal/matters/${second.body.id}`)).status).toBe(200);
    expect((await other.api('GET', `/legal/matters/${created.body.id}`)).status).toBe(404);
    expect((await f.api('GET', '/legal/matters')).body.total).toBe(2);
    // An associate who creates a matter becomes its advocate.
    const own = await assoc.api('POST', '/legal/matters', matterBody(f, { title: 'Own', advocateId: other.userId }));
    expect(own.status).toBe(201);
    expect(own.body.advocateId).toBe(assoc.userId);
    expect((await f.api('GET', '/legal/matters?status=disposed')).body.total).toBe(0);
    const vendor = (await f.api('POST', '/parties', { type: 'vendor', name: 'Stationer' })).body;
    expect((await f.api('POST', '/legal/matters', matterBody(f, { clientId: vendor.id }))).status).toBe(400);
  });

  it('updates a matter, rejects stale edits and sets closed_at', async () => {
    const f = await firm();
    const m = (await f.api('POST', '/legal/matters', matterBody(f))).body;
    const ok = await f.api('PATCH', `/legal/matters/${m.id}`, { stage: 'Evidence', expectedUpdatedAt: m.updatedAt });
    expect(ok.status).toBe(200);
    expect(ok.body.stage).toBe('Evidence');
    const stale = await f.api('PATCH', `/legal/matters/${m.id}`, { stage: 'Arguments', expectedUpdatedAt: m.updatedAt });
    expect(stale.status).toBe(409);
    const closed = await f.api('PATCH', `/legal/matters/${m.id}`, { status: 'disposed' });
    expect(closed.body.closedAt).toBeTruthy();
  });
});

describe('hearings and the diary', () => {
  it('recording an outcome with a next date creates the next hearing, once', async () => {
    const f = await firm();
    const m = (await f.api('POST', '/legal/matters', matterBody(f))).body;
    const h = (await f.api('POST', `/legal/matters/${m.id}/hearings`, { hearingDate: today(), purpose: 'Written statement' })).body;
    expect(h.court).toBe('City Civil Court, Ahmedabad');
    const next = addDays(today(), 21);
    const res = await f.api('POST', `/legal/hearings/${h.id}/outcome`, { outcome: 'Time granted', nextDate: next, nextPurpose: 'Issues' });
    expect(res.status).toBe(200);
    expect(res.body.hearing.status).toBe('held');
    expect(res.body.next.hearingDate).toBe(next);
    expect(res.body.next.purpose).toBe('Issues');
    expect(res.body.warning).toBeNull();
    const again = await f.api('POST', `/legal/hearings/${h.id}/outcome`, { outcome: 'Again', nextDate: next });
    expect(again.status).toBe(409);
    const detail = (await f.api('GET', `/legal/matters/${m.id}`)).body;
    expect(detail.hearings).toHaveLength(2);
    expect(detail.nextHearingDate).toBe(next);
    const before = await f.api('POST', `/legal/hearings/${res.body.next.id}/outcome`, { outcome: 'x', nextDate: today() });
    expect(before.status).toBe(400);
  });

  it('cause list covers a date range, home lists matters without a next date', async () => {
    const f = await firm();
    const a = (await f.api('POST', '/legal/matters', matterBody(f, { title: 'A' }))).body;
    const b = (await f.api('POST', '/legal/matters', matterBody(f, { title: 'B' }))).body;
    const c = (await f.api('POST', '/legal/matters', matterBody(f, { title: 'C' }))).body;
    await f.api('POST', `/legal/matters/${a.id}/hearings`, { hearingDate: today(), purpose: 'Arguments' });
    await f.api('POST', `/legal/matters/${b.id}/hearings`, { hearingDate: addDays(today(), 1) });
    await f.api('POST', `/legal/matters/${c.id}/hearings`, { hearingDate: addDays(today(), 9) });
    const list = await f.api('GET', '/legal/cause-list');
    expect(list.body.data.map((h: { matterTitle: string }) => h.matterTitle)).toEqual(['A', 'B']);
    const one = await f.api('GET', `/legal/cause-list?from=${addDays(today(), 9)}&to=${addDays(today(), 9)}`);
    expect(one.body.data).toHaveLength(1);
    const d = await f.api('POST', '/legal/matters', matterBody(f, { title: 'D no date' }));
    const past = (await f.api('POST', `/legal/matters/${a.id}/hearings`, { hearingDate: addDays(today(), -3) })).body;
    const home = (await f.api('GET', '/legal/home')).body;
    expect(home.hearings).toHaveLength(2);
    expect(home.withoutNextDate.map((m: { id: string }) => m.id)).toEqual([d.body.id]);
    expect(home.pendingOutcome.map((h: { id: string }) => h.id)).toEqual([past.id]);
  });
});

describe('tasks', () => {
  it('lists overdue tasks and closes them', async () => {
    const f = await firm();
    const assoc = await f.as('Associate');
    const m = (await f.api('POST', '/legal/matters', matterBody(f, { teamIds: [assoc.userId] }))).body;
    const late = await assoc.api('POST', `/legal/matters/${m.id}/tasks`, { title: 'File written statement', kind: 'filing', dueDate: addDays(today(), -2), assigneeId: assoc.userId });
    expect(late.status).toBe(201);
    expect(late.body.overdue).toBe(true);
    await f.api('POST', `/legal/matters/${m.id}/tasks`, { title: 'Limitation for appeal', kind: 'limitation', dueDate: addDays(today(), 30) });
    const overdue = await assoc.api('GET', '/legal/tasks?overdue=true');
    expect(overdue.body.data.map((t: { title: string }) => t.title)).toEqual(['File written statement']);
    expect((await f.api('GET', '/legal/home')).body.deadlines).toHaveLength(1);
    const done = await assoc.api('PATCH', `/legal/tasks/${late.body.id}`, { status: 'done' });
    expect(done.body.doneAt).toBeTruthy();
    expect((await assoc.api('GET', '/legal/tasks?overdue=true')).body.data).toHaveLength(0);
  });
});

describe('time, expenses and billing', () => {
  it('records time at the rate card, keeps entries private to the matter, and edits only unbilled entries', async () => {
    const f = await firm();
    const assoc = await f.as('Associate');
    const m = (await f.api('POST', '/legal/matters', matterBody(f, { teamIds: [assoc.userId], hourlyRate: 2000 }))).body;
    const t1 = await assoc.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'time', minutes: 90, description: 'Drafting plaint' });
    expect(t1.status).toBe(201);
    expect(t1.body.rate).toBe(2000);
    expect(t1.body.amount).toBe(3000);
    expect((await f.api('PUT', `/legal/rates/${assoc.userId}`, { hourlyRate: 1000 })).status).toBe(200);
    const t2 = await assoc.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'time', minutes: 30, description: 'Call' });
    expect(t2.body.amount).toBe(500);
    expect((await assoc.api('PUT', `/legal/rates/${assoc.userId}`, { hourlyRate: 1 })).status).toBe(403);
    expect((await assoc.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'time', minutes: 0, description: 'x' })).status).toBe(400);
    const fix = await assoc.api('PATCH', `/legal/entries/${t2.body.id}`, { minutes: 60 });
    expect(fix.body.amount).toBe(1000);
    // Associates cannot bill.
    expect((await assoc.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [t1.body.id] })).status).toBe(403);
    const list = await assoc.api('GET', `/legal/entries?matterId=${m.id}&billed=false`);
    expect(list.body.data).toHaveLength(2);
  });

  it('bills selected entries into one invoice, marks them billed, and refuses to bill twice', async () => {
    const f = await firm();
    const m = (await f.api('POST', '/legal/matters', matterBody(f, { hourlyRate: 2000 }))).body;
    const time = (await f.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'time', minutes: 120, description: 'Conference', rate: 2500 })).body;
    const fee = (await f.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'fee', amount: 5000, description: 'Drafting fee' })).body;
    const court = (await f.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'disbursement', disbType: 'court_fee', amount: 500, description: 'Filing fee' })).body;
    const private_ = (await f.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'time', minutes: 10, description: 'Admin', billable: false })).body;
    expect(time.amount).toBe(5000);
    expect((await f.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [private_.id] })).status).toBe(400);

    const bill = await f.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [time.id, fee.id, court.id] });
    expect(bill.status).toBe(201);
    // Fees 10,000 at 18% GST = 11,800, plus 500 reimbursed with no GST.
    expect(bill.body.invoice.subtotal).toBe(10500);
    expect(bill.body.invoice.taxTotal).toBe(1800);
    expect(bill.body.invoice.total).toBe(12300);
    expect(bill.body.invoice.lines).toHaveLength(3);
    expect(bill.body.invoice.lines.find((l: { gstRate: number }) => l.gstRate === 0).taxableValue).toBe(500);

    const entries = (await f.api('GET', `/legal/entries?matterId=${m.id}&billed=true`)).body.data;
    expect(entries).toHaveLength(3);
    expect(entries[0].invoiceNumber).toBe(bill.body.invoice.number);
    const again = await f.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [fee.id] });
    expect(again.status).toBe(409);
    expect(again.body.error?.code ?? again.body.code).toBe('ALREADY_BILLED');
    expect((await f.api('PATCH', `/legal/entries/${fee.id}`, { amount: 1 })).status).toBe(409);
    expect((await f.api('DELETE', `/legal/entries/${fee.id}`)).status).toBe(409);

    const bills = (await f.api('GET', `/legal/matters/${m.id}/bills`)).body;
    expect(bills.bills).toHaveLength(1);
    // Simultaneous bills of the same entry: only one wins.
    const e2 = (await f.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'fee', amount: 1000, description: 'Appearance' })).body;
    const both = await Promise.all([f.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [e2.id] }), f.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [e2.id] })]);
    expect(both.map((r) => r.status).sort()).toEqual([201, 409]);
  });

  it('records advance and fee receipts, and bills under reverse charge without GST', async () => {
    const f = await firm();
    const m = (await f.api('POST', '/legal/matters', matterBody(f))).body;
    const cash = ((await f.api('GET', '/accounts')).body.data as { id: string; subtype: string }[]).find((a) => a.subtype === 'cash')!;
    const adv = await f.api('POST', `/legal/matters/${m.id}/receipts`, { kind: 'advance', amount: 20000, accountId: cash.id, mode: 'cash' });
    expect(adv.status).toBe(201);
    expect(adv.body.allocations ?? []).toHaveLength(0);
    const fee = (await f.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'fee', amount: 10000, description: 'Retainer fee' })).body;
    const bill = await f.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [fee.id], reverseCharge: true });
    expect(bill.status).toBe(201);
    expect(bill.body.invoice.taxTotal).toBe(0);
    expect(bill.body.invoice.total).toBe(10000);
    expect(bill.body.invoice).toMatchObject({ reverseCharge: true, rcmTax: 1800 });
    const rec = await f.api('POST', `/legal/matters/${m.id}/receipts`, { kind: 'fee', amount: 4000, accountId: cash.id, mode: 'cash', invoiceId: bill.body.invoice.id });
    expect(rec.status).toBe(201);
    const detail = (await f.api('GET', `/legal/matters/${m.id}`)).body;
    expect(detail.summary.advanceReceived).toBe(20000);
    expect(detail.summary.billedTotal).toBe(10000);
    expect(detail.summary.billedPaid).toBe(4000);
    expect((await f.api('POST', `/legal/matters/${m.id}/receipts`, { kind: 'fee', amount: 1, accountId: cash.id, mode: 'cash' })).status).toBe(400);
    // The second client has no GSTIN, so reverse charge is refused.
    const m2 = (await f.api('POST', '/legal/matters', matterBody(f, { clientId: f.client2.id }))).body;
    const e = (await f.api('POST', `/legal/matters/${m2.id}/entries`, { kind: 'fee', amount: 100, description: 'x' })).body;
    expect((await f.api('POST', `/legal/matters/${m2.id}/bill`, { entryIds: [e.id], reverseCharge: true })).status).toBe(400);
  });

  it('adds an appearance fee for per-hearing matters when the outcome is recorded', async () => {
    const f = await firm();
    const m = (await f.api('POST', '/legal/matters', matterBody(f, { feeType: 'per_hearing', agreedFee: 2500, hourlyRate: undefined }))).body;
    const h = (await f.api('POST', `/legal/matters/${m.id}/hearings`, { hearingDate: today(), purpose: 'Evidence' })).body;
    const r = await f.api('POST', `/legal/hearings/${h.id}/outcome`, { outcome: 'Witness examined' });
    expect(r.body.feeEntryId).toBeTruthy();
    expect(r.body.warning).toMatch(/No next date/);
    const e = (await f.api('GET', `/legal/entries?matterId=${m.id}`)).body.data;
    expect(e[0].amount).toBe(2500);
  });
});

describe('permissions and documents', () => {
  it('denies by permission and role', async () => {
    const f = await firm();
    const clerk = await f.as('Clerk');
    const accounts = await f.as('Accounts');
    const partner = await f.as('Senior Advocate');
    const m = (await f.api('POST', '/legal/matters', matterBody(f, { teamIds: [clerk.userId] }))).body;
    expect((await clerk.api('GET', '/legal/rates')).status).toBe(403);
    const e = (await clerk.api('POST', `/legal/matters/${m.id}/entries`, { kind: 'disbursement', disbType: 'clerkage', amount: 200, description: 'Clerk fee' })).body;
    expect((await clerk.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [e.id] })).status).toBe(403);
    expect((await clerk.api('POST', `/legal/matters/${m.id}/receipts`, { kind: 'advance', amount: 1, accountId: m.id, mode: 'cash' })).status).toBe(403);
    expect((await accounts.api('GET', `/legal/matters/${m.id}`)).status).toBe(200);
    expect((await accounts.api('POST', `/legal/matters/${m.id}/bill`, { entryIds: [e.id] })).status).toBe(201);
    expect((await partner.api('GET', '/legal/matters')).body.total).toBe(1);
    const cashier = await f.api('POST', '/roles', { name: 'No legal', permissions: ['dashboard.view'] });
    const email = uniqueEmail('nl');
    const u = await f.api('POST', '/users', { name: 'NL', email, password: 'Secret@123', roleId: cashier.body.id });
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    const nl = client(env.app, li.body.accessToken, f.companyId);
    expect(u.status).toBe(201);
    expect((await nl('GET', '/legal/home')).status).toBe(403);
    expect((await nl('POST', '/legal/matters', matterBody(f))).status).toBe(403);
  });

  it('attaches an uploaded file to a matter', async () => {
    const f = await firm();
    const m = (await f.api('POST', '/legal/matters', matterBody(f))).body;
    const missing = await f.api('POST', `/legal/matters/${m.id}/documents`, { fileId: '00000000-0000-4000-8000-000000000000' });
    expect(missing.status).toBe(400);
    expect((await f.api('GET', `/legal/matters/${m.id}/documents`)).body.data).toEqual([]);
  });
});
