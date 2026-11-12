import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function biz(businessType: string, name: string) {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner', email: uniqueEmail(businessType), password: 'Secret@123', stateCode: '24', businessType,
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  const loc = (await api('POST', '/locations', { type: 'store', name: 'Main' })).body;
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
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; subtype: string }[];
  const cash = accounts.find((a) => a.subtype === 'cash')!;
  return { api, as, loc, cash, companyId };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const plan = (over: Record<string, unknown> = {}) => ({
  name: 'Monthly', durationUnit: 'months', durationCount: 1, price: 1000, gstRate: 18, joiningFee: 500, freezeDays: 10, ...over,
});
async function enrol(b: Biz, planId: string, over: Record<string, unknown> = {}) {
  const res = await b.api('POST', '/memberships/members', { name: 'Asha Rao', phone: '9825011111', planId, ...over });
  expect(res.status, JSON.stringify(res.body)).toBe(201);
  return res.body;
}
const monthsAgo = (n: number) => addDays(todayIst(), -30 * n);

describe('memberships', () => {
  it('enrols a member with first bill, joining fee and a receipt', async () => {
    const g = await biz('gym', 'Iron Gym');
    const p = (await g.api('POST', '/memberships/plans', plan())).body;
    const out = await enrol(g, p.id, { payment: { accountId: g.cash.id, mode: 'cash', amount: 500 } });
    expect(out.memberNo).toMatch(/^MEM\/\d{2}-\d{2}\/00001$/);
    expect(out.invoice.total).toBe(Math.round(1500 * 1.18));
    const file = (await g.api('GET', `/memberships/members/${out.memberId}`)).body;
    expect(file.status).toBe('active');
    expect(file.subscriptions).toHaveLength(1);
    expect(file.bills).toHaveLength(1);
    expect(file.dueAmount).toBe(out.invoice.total - 500);
    const home = (await g.api('GET', '/memberships/summary')).body;
    expect(home.active).toBe(1);
    expect(home.duesAmount).toBe(out.invoice.total - 500);
  });

  it('renews from the old end date when active and from today when lapsed', async () => {
    const g = await biz('gym', 'Renew Gym');
    const p = (await g.api('POST', '/memberships/plans', plan({ joiningFee: 0, gstRate: 0 }))).body;
    const today = todayIst();
    const a = await enrol(g, p.id, { startDate: today });
    const endA = a.subscription.end_date ?? a.subscription.endDate;
    const r1 = await g.api('POST', `/memberships/members/${a.memberId}/renew`, {});
    expect(r1.status).toBe(201);
    const s1 = r1.body.subscription;
    expect(s1.start_date ?? s1.startDate).toBe(addDays(endA, 1));
    expect(r1.body.invoice.total).toBe(1000);
    // A lapsed member renews from today.
    const b = await enrol(g, p.id, { name: 'Lapsed Lal', phone: '9825022222', startDate: monthsAgo(3) });
    expect((await g.api('GET', `/memberships/members/${b.memberId}`)).body.status).toBe('expired');
    const r2 = await g.api('POST', `/memberships/members/${b.memberId}/renew`, { date: today });
    const s2 = r2.body.subscription;
    expect(s2.start_date ?? s2.startDate).toBe(today);
    expect((await g.api('GET', `/memberships/members/${b.memberId}`)).body.status).toBe('active');
  });

  it('freeze and unfreeze extend the end date within the plan allowance', async () => {
    const g = await biz('gym', 'Freeze Gym');
    const p = (await g.api('POST', '/memberships/plans', plan({ freezeDays: 7, joiningFee: 0 }))).body;
    const m = await enrol(g, p.id);
    const subId = m.subscription.id;
    const endBefore = m.subscription.end_date ?? m.subscription.endDate;
    expect((await g.api('POST', `/memberships/subscriptions/${subId}/freeze`, { date: todayIst() })).status).toBe(200);
    const blocked = await g.api('POST', '/memberships/checkin', { memberNo: m.memberNo });
    expect(blocked.status).toBe(409);
    const un = await g.api('POST', `/memberships/subscriptions/${subId}/unfreeze`, { date: addDays(todayIst(), 4) });
    expect(un.body.extendedDays).toBe(4);
    expect(un.body.endDate).toBe(addDays(endBefore, 4));
    // Only 3 days remain; a longer freeze is capped.
    await g.api('POST', `/memberships/subscriptions/${subId}/freeze`, { date: todayIst() });
    const un2 = await g.api('POST', `/memberships/subscriptions/${subId}/unfreeze`, { date: addDays(todayIst(), 9) });
    expect(un2.body.extendedDays).toBe(3);
    const none = await g.api('POST', `/memberships/subscriptions/${subId}/freeze`, {});
    expect(none.status).toBe(409);
    const noFreezePlan = (await g.api('POST', '/memberships/plans', plan({ name: 'No freeze', freezeDays: 0 }))).body;
    const m2 = await enrol(g, noFreezePlan.id, { name: 'B', phone: '9825033333' });
    expect((await g.api('POST', `/memberships/subscriptions/${m2.subscription.id}/freeze`, {})).status).toBe(409);
  });

  it('checks in by number or phone and refuses an expired member with the reason', async () => {
    const g = await biz('gym', 'Door Gym');
    const p = (await g.api('POST', '/memberships/plans', plan({ joiningFee: 0 }))).body;
    const ok = await enrol(g, p.id);
    const old = await enrol(g, p.id, { name: 'Old Om', phone: '9825044444', startDate: monthsAgo(4) });
    const byPhone = await g.api('POST', '/memberships/checkin', { phone: '9825011111' });
    expect(byPhone.status).toBe(200);
    expect(byPhone.body.ok).toBe(true);
    const again = await g.api('POST', '/memberships/checkin', { memberNo: ok.memberNo.toLowerCase() });
    expect(again.body.repeatToday).toBe(true);
    const refused = await g.api('POST', '/memberships/checkin', { memberNo: old.memberNo });
    expect(refused.status).toBe(409);
    expect(JSON.stringify(refused.body)).toContain('expired on');
    expect((await g.api('POST', '/memberships/checkin', { phone: '0000000000' })).status).toBe(404);
    const visits = (await g.api('GET', '/memberships/visits')).body.data;
    expect(visits).toHaveLength(2);
    const file = (await g.api('GET', `/memberships/members/${ok.memberId}`)).body;
    expect(file.visits).toHaveLength(2);
  });

  it('bills housing society maintenance per sq ft once per period', async () => {
    const s = await biz('housing_society', 'Green Society');
    const p = (await s.api('POST', '/memberships/plans', {
      name: 'Maintenance', billing: 'monthly', rateBasis: 'per_sqft', price: 3, gstRate: 0, joiningFee: 0,
    })).body;
    expect(p.id).toBeTruthy();
    const f1 = await enrol(s, p.id, { name: 'Flat A-101', flatNo: '101', wing: 'A', areaSqft: 1000, occupancy: 'owner', phone: '9825055555' });
    expect(f1.invoice).toBeNull();
    await enrol(s, p.id, { name: 'Flat B-202', flatNo: '202', wing: 'B', areaSqft: 650, occupancy: 'tenant', phone: '9825066666' });
    const period = todayIst().slice(0, 7);
    const pre = (await s.api('GET', `/memberships/bills/preview?kind=maintenance&period=${period}`)).body;
    expect(pre.count).toBe(2);
    const run = await s.api('POST', '/memberships/bills/generate', { kind: 'maintenance', period });
    expect(run.status).toBe(200);
    expect(run.body.created).toBe(2);
    expect(run.body.total).toBe(3000 + 1950);
    const again = await s.api('POST', '/memberships/bills/generate', { kind: 'maintenance', period });
    expect(again.body.created).toBe(0);
    expect((await s.api('GET', `/memberships/bills/preview?kind=maintenance&period=${period}`)).body.count).toBe(0);
    const next = addDays(`${period}-01`, 40).slice(0, 7);
    expect((await s.api('POST', '/memberships/bills/generate', { kind: 'maintenance', period: next })).body.created).toBe(2);
    const invoices = (await s.api('GET', '/invoices?limit=50')).body.data;
    expect(invoices).toHaveLength(4);
    // A flat with no area is skipped, not billed at zero.
    const noArea = await s.api('POST', '/memberships/members', { name: 'X', planId: p.id });
    expect(noArea.status).toBe(400);
    // Dues, reminder text and collection.
    const dues = (await s.api('GET', '/memberships/dues')).body;
    expect(dues.data).toHaveLength(2);
    expect(dues.total).toBe((3000 + 1950) * 2);
    expect(dues.data[0].reminder).toContain('maintenance dues');
    const col = await s.api('POST', `/memberships/members/${f1.memberId}/collect`, { accountId: s.cash.id, mode: 'cash', amount: 4000 });
    expect(col.status).toBe(201);
    expect(col.body.remaining).toBe(2000);
    expect((await s.api('POST', `/memberships/members/${f1.memberId}/collect`, { accountId: s.cash.id, mode: 'cash', amount: 99999 })).status).toBe(400);
  });

  it('runs renewals due once and denies roles without the permission', async () => {
    const g = await biz('gym', 'Due Gym');
    const p = (await g.api('POST', '/memberships/plans', plan({ joiningFee: 0, gstRate: 0 }))).body;
    await enrol(g, p.id, { startDate: addDays(todayIst(), -26) });
    await enrol(g, p.id, { name: 'Fresh', phone: '9825077777' });
    expect((await g.api('GET', '/memberships/bills/preview?kind=renewals')).body.count).toBe(1);
    expect((await g.api('POST', '/memberships/bills/generate', { kind: 'renewals' })).body.created).toBe(1);
    expect((await g.api('POST', '/memberships/bills/generate', { kind: 'renewals' })).body.created).toBe(0);
    const trainer = await g.as('Trainer');
    expect((await trainer.api('POST', '/memberships/checkin', { phone: '9825077777' })).status).toBe(200);
    expect((await trainer.api('GET', '/memberships/members')).status).toBe(200);
    expect((await trainer.api('POST', '/memberships/plans', plan())).status).toBe(403);
    expect((await trainer.api('POST', '/memberships/bills/generate', { kind: 'renewals' })).status).toBe(403);
    const desk = await g.as('Front Desk');
    expect((await desk.api('POST', '/memberships/plans', plan({ name: 'Q' }))).status).toBe(201);
  });
});

// Job cards ---------------------------------------------------------------------------------

async function garage() {
  const b = await biz('garage', 'Fix-It Garage');
  const part = (await b.api('POST', '/items', { name: 'Brake pad', unit: 'NOS', gstRate: 18, hsnCode: '8708', salePrice: 800, purchasePrice: 500, trackStock: true })).body;
  const labour = (await b.api('POST', '/items', { name: 'Brake service', unit: 'NOS', gstRate: 18, hsnCode: '9987', salePrice: 300, trackStock: false })).body;
  const firstLoc = ((await b.api('GET', '/locations')).body.data as { id: string }[])[0]!;
  expect((await b.api('POST', '/stock/adjustments', { locationId: firstLoc.id, itemId: part.id, qty: 10, rate: 500 })).status).toBe(201);
  const stockOf = async () => ((await b.api('GET', `/stock/moves?itemId=${part.id}&limit=200`)).body.data as { qty: number }[]).reduce((s, m) => s + Number(m.qty), 0);
  return { ...b, part, labour, stockOf };
}
const jobBody = (over: Record<string, unknown> = {}) => ({
  kind: 'vehicle', vehicleNo: 'gj01ab1234', make: 'Maruti', model: 'Swift', odometer: 42000,
  customer: { name: 'Karan Shah', phone: '9825012345' }, complaints: 'Brake noise', accessories: 'Spare wheel', ...over,
});

describe('job cards', () => {
  it('numbers a job, uppercases the vehicle number and follows the status rules', async () => {
    const g = await garage();
    const res = await g.api('POST', '/job-cards', jobBody());
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    const job = res.body;
    expect(job.number).toMatch(/^JOB\/\d{2}-\d{2}\/00001$/);
    expect(job.vehicleNo).toBe('GJ01AB1234');
    expect(job.status).toBe('received');
    expect((await g.api('POST', '/job-cards', jobBody({ vehicleNo: undefined }))).status).toBe(400);
    const st = (status: string, extra: Record<string, unknown> = {}) => g.api('POST', `/job-cards/${job.id}/status`, { status, ...extra });
    expect((await st('estimate_sent')).status).toBe(400);
    expect((await st('in_progress')).status).toBe(409);
    expect((await st('ready')).status).toBe(409);
    await g.api('POST', `/job-cards/${job.id}/lines`, { kind: 'labour', itemId: g.labour.id, qty: 1 });
    const sent = await st('estimate_sent');
    expect(sent.body.estimateSentAt).toBeTruthy();
    expect((await st('in_progress')).status).toBe(409);
    const ok = await st('approved', { approvedBy: 'Karan on phone' });
    expect(ok.body.approvedAt).toBeTruthy();
    expect(ok.body.approvedBy).toBe('Karan on phone');
    // Changing the estimate after approval needs approval again.
    const edit = await g.api('POST', `/job-cards/${job.id}/lines`, { kind: 'part', itemId: g.part.id, qty: 2 });
    expect(edit.body.status).toBe('estimate_sent');
    expect(edit.body.approvedAt).toBeNull();
    await st('approved');
    expect((await st('in_progress')).body.status).toBe('in_progress');
    expect((await st('cancelled')).status).toBe(400);
    expect((await st('delivered')).status).toBe(409);
    expect((await st('ready')).body.status).toBe('ready');
    expect((await st('delivered')).status).toBe(409);
  });

  it('issues parts once, reduces stock once at billing, and totals match', async () => {
    const g = await garage();
    const job = (await g.api('POST', '/job-cards', jobBody())).body;
    const jid = job.id;
    await g.api('POST', `/job-cards/${jid}/lines`, { kind: 'part', itemId: g.part.id, qty: 2 });
    await g.api('POST', `/job-cards/${jid}/lines`, { kind: 'labour', itemId: g.labour.id, qty: 1, rate: 350 });
    const est = (await g.api('GET', `/job-cards/${jid}`)).body;
    expect(est.totals.parts).toBe(1600);
    expect(est.totals.labour).toBe(350);
    expect(est.totals.total).toBe(Math.round(1950 * 1.18));
    expect((await g.api('POST', `/job-cards/${jid}/issue`, {})).status).toBe(409);
    const go = async (status: string) => g.api('POST', `/job-cards/${jid}/status`, { status });
    await go('estimate_sent'); await go('approved'); await go('in_progress');
    const issued = await g.api('POST', `/job-cards/${jid}/issue`, {});
    expect(issued.body.issuedNow).toBe(1);
    const twice = await g.api('POST', `/job-cards/${jid}/issue`, {});
    expect(twice.body.issuedNow).toBe(0);
    expect(twice.body.alreadyIssued).toBe(1);
    const partLine = twice.body.lines.find((l: { kind: string }) => l.kind === 'part');
    expect((await g.api('DELETE', `/job-cards/${jid}/lines/${partLine.id}`)).status).toBe(409);
    expect(await g.stockOf()).toBe(10);
    // A second job cannot take stock already held for the first.
    const j2 = (await g.api('POST', '/job-cards', jobBody({ vehicleNo: 'GJ05XX9999' }))).body;
    await g.api('POST', `/job-cards/${j2.id}/lines`, { kind: 'part', itemId: g.part.id, qty: 9 });
    await g.api('POST', `/job-cards/${j2.id}/status`, { status: 'estimate_sent' });
    await g.api('POST', `/job-cards/${j2.id}/status`, { status: 'approved' });
    await g.api('POST', `/job-cards/${j2.id}/status`, { status: 'in_progress' });
    const short = await g.api('POST', `/job-cards/${j2.id}/issue`, {});
    expect(short.status).toBe(409);
    expect(JSON.stringify(short.body)).toContain('INSUFFICIENT_STOCK');
    // Bill only when ready.
    expect((await g.api('POST', `/job-cards/${jid}/bill`, {})).status).toBe(409);
    await go('ready');
    const bill = await g.api('POST', `/job-cards/${jid}/bill`, { payment: { accountId: g.cash.id, mode: 'cash', amount: 1000 } });
    expect(bill.status, JSON.stringify(bill.body)).toBe(201);
    expect(bill.body.invoice.total).toBe(est.totals.total);
    expect(await g.stockOf()).toBe(8);
    expect((await g.api('POST', `/job-cards/${jid}/bill`, {})).status).toBe(409);
    expect(await g.stockOf()).toBe(8);
    const after = (await g.api('GET', `/job-cards/${jid}`)).body;
    expect(after.invoice.balance).toBe(est.totals.total - 1000);
    expect(after.statusMessage).toContain('ready for collection');
    expect(after.statusMessage).toContain('Balance');
    const rec = await g.api('POST', `/job-cards/${jid}/receipt`, { accountId: g.cash.id, mode: 'upi', amount: est.totals.total - 1000 });
    expect(rec.status).toBe(201);
    expect(rec.body.balance).toBe(0);
    expect((await g.api('POST', `/job-cards/${jid}/receipt`, { accountId: g.cash.id, mode: 'cash', amount: 1 })).status).toBe(400);
    expect((await go('delivered')).body.status).toBe('delivered');
    expect((await g.api('POST', `/job-cards/${jid}/status`, { status: 'cancelled', reason: 'late' })).status).toBe(409);
  });

  it('shows technicians only their own jobs and enforces permissions', async () => {
    const g = await garage();
    const tech = await g.as('Technician');
    const advisor = await g.as('Service Advisor');
    const mine = (await advisor.api('POST', '/job-cards', jobBody({ technicianId: tech.userId }))).body;
    const other = (await advisor.api('POST', '/job-cards', jobBody({ vehicleNo: 'GJ09ZZ0001' }))).body;
    expect(mine.technician.id).toBe(tech.userId);
    const list = (await tech.api('GET', '/job-cards')).body;
    expect(list.data.map((j: { id: string }) => j.id)).toEqual([mine.id]);
    expect((await tech.api('GET', `/job-cards/${other.id}`)).status).toBe(404);
    expect((await tech.api('POST', '/job-cards', jobBody())).status).toBe(403);
    expect((await tech.api('POST', `/job-cards/${mine.id}/status`, { status: 'estimate_sent' })).status).toBe(403);
    await advisor.api('POST', `/job-cards/${mine.id}/lines`, { kind: 'part', itemId: g.part.id, qty: 1 });
    await advisor.api('POST', `/job-cards/${mine.id}/status`, { status: 'estimate_sent' });
    await advisor.api('POST', `/job-cards/${mine.id}/status`, { status: 'approved' });
    expect((await tech.api('POST', `/job-cards/${mine.id}/status`, { status: 'in_progress' })).status).toBe(200);
    expect((await tech.api('POST', `/job-cards/${mine.id}/issue`, {})).status).toBe(200);
    expect((await tech.api('POST', `/job-cards/${mine.id}/bill`, {})).status).toBe(403);
    expect((await tech.api('POST', `/job-cards/${other.id}/issue`, {})).status).toBe(404);
    const board = (await advisor.api('GET', '/job-cards?open=true')).body;
    expect(board.data).toHaveLength(2);
    expect(board.counts.in_progress).toBe(1);
    const techs = (await advisor.api('GET', '/job-cards/technicians')).body.data;
    expect(techs.some((t: { id: string }) => t.id === tech.userId)).toBe(true);
    // A device job needs no vehicle number.
    const dev = await advisor.api('POST', '/job-cards', { kind: 'device', make: 'Samsung', model: 'A54', serialNo: '356789012345678', customer: { name: 'Z', phone: '9825099999' }, complaints: 'Screen' });
    expect(dev.status).toBe(201);
    expect(dev.body.asset).toContain('S/N 356789012345678');
  });
});
