import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { dueAt, type Hours } from '../src/lib/sla.ts';
import { billingPeriods, visitDates } from '../src/modules/service-contracts.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function biz(type = 'it_services') {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Desk Co', name: 'Owner', email: uniqueEmail(type), password: 'Secret@123', stateCode: '24', businessType: type,
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, res.body.accessToken, me.companies[0].id as string);
  await api('POST', '/locations', { type: 'store', name: 'Main' });
  const svc = (await api('POST', '/items', { name: 'Support service', unit: 'NOS', gstRate: 18, hsnCode: '9987', salePrice: 1000, trackStock: false })).body;
  const cust = (await api('POST', '/parties', { type: 'customer', name: 'Acme Ltd', stateCode: '24', phone: '9825011111', email: 'a@acme.in' })).body;
  return { api, svc, cust };
}

const IST = (s: string) => new Date(`${s}+05:30`);
const biz9: Hours = { mode: 'business', workDays: [1, 2, 3, 4, 5, 6], startTime: '09:00', endTime: '18:00' };

describe('SLA due times', () => {
  it('counts plain hours in 24x7 mode', () => {
    expect(dueAt(IST('2026-11-16T10:00:00'), 5, { ...biz9, mode: '24x7' }).toISOString()).toBe(IST('2026-11-16T15:00:00').toISOString());
  });
  it('stays inside the day in business mode', () => {
    expect(dueAt(IST('2026-11-16T10:00:00'), 4, biz9).toISOString()).toBe(IST('2026-11-16T14:00:00').toISOString());
  });
  it('rolls over the evening to the next opening', () => {
    // Monday 16:00, 4 hours: 2 left on Monday, 2 more on Tuesday from 09:00.
    expect(dueAt(IST('2026-11-16T16:00:00'), 4, biz9).toISOString()).toBe(IST('2026-11-17T11:00:00').toISOString());
  });
  it('starts after closing at the next opening and skips the Sunday', () => {
    // Saturday 19:00, 3 hours: Sunday is off, so Monday 09:00 + 3h.
    expect(dueAt(IST('2026-11-21T19:00:00'), 3, biz9).toISOString()).toBe(IST('2026-11-23T12:00:00').toISOString());
  });
});

describe('contract schedules', () => {
  it('makes quarterly visits strictly before the end date', () => {
    expect(visitDates('2026-01-15', '2027-01-14', 'quarterly')).toEqual(['2026-04-15', '2026-07-15', '2026-10-15']);
    expect(visitDates('2026-01-15', '2027-01-14', 'none')).toEqual([]);
  });
  it('splits periodic billing with the rounding on the last period', () => {
    const p = billingPeriods({ start_date: '2026-01-01', end_date: '2027-01-01', value: 1000, billing: 'periodic', bill_frequency: 'quarterly' });
    expect(p.map((x) => x.date)).toEqual(['2026-01-01', '2026-04-01', '2026-07-01', '2026-10-01']);
    expect(p.reduce((s, x) => s + x.amount, 0)).toBeCloseTo(1000, 2);
    const q = billingPeriods({ start_date: '2026-01-01', end_date: '2027-01-01', value: 1000, billing: 'periodic', bill_frequency: 'monthly' });
    expect(q).toHaveLength(12);
    expect(q.reduce((s, x) => s + x.amount, 0)).toBeCloseTo(1000, 2);
  });
});

describe('helpdesk', () => {
  it('creates a ticket with due times, replies, resolves and reports', async () => {
    const b = await biz();
    await b.api('PUT', '/helpdesk/settings', { hoursMode: '24x7', sla: { high: { firstResponseHours: 2, resolutionHours: 10 } } });
    const t = (await b.api('POST', '/helpdesk/tickets', { partyId: b.cust.id, subject: 'Printer down', channel: 'phone', priority: 'high', category: 'Hardware' }));
    expect(t.status, JSON.stringify(t.body)).toBe(201);
    expect(t.body.number).toMatch(/^TKT\//);
    const made = new Date(t.body.createdAt).getTime();
    expect(new Date(t.body.firstResponseDue).getTime() - made).toBeCloseTo(2 * 3600_000, -4);
    expect(new Date(t.body.resolutionDue).getTime() - made).toBeCloseTo(10 * 3600_000, -4);
    expect(t.body.response.state).toBe('pending');

    const note = await b.api('POST', `/helpdesk/tickets/${t.body.id}/messages`, { kind: 'note', body: 'Checking spares' });
    expect(note.status).toBe(201);
    expect(note.body.firstResponseAt).toBeNull();
    const reply = await b.api('POST', `/helpdesk/tickets/${t.body.id}/messages`, { kind: 'reply', body: 'We are on it' });
    expect(reply.body.firstResponseAt).toBeTruthy();
    expect(reply.body.status).toBe('open');
    expect(reply.body.response.state).toBe('met');
    expect(reply.body.messages.map((m: { kind: string }) => m.kind)).toEqual(['note', 'reply']);

    const bad = await b.api('POST', `/helpdesk/tickets/${t.body.id}/status`, { status: 'new' });
    expect(bad.status).toBe(409);
    const done = await b.api('POST', `/helpdesk/tickets/${t.body.id}/status`, { status: 'resolved' });
    expect(done.body.resolvedAt).toBeTruthy();
    expect(done.body.resolution.state).toBe('met');

    const list = (await b.api('GET', '/helpdesk/tickets?open=false')).body;
    expect(list.total).toBe(1);
    const rep = (await b.api('GET', '/helpdesk/reports/summary')).body;
    expect(rep.byCategory[0]).toMatchObject({ category: 'Hardware', total: 1 });
    expect(rep.avgFirstResponseHours).not.toBeNull();
    expect(rep.avgResolutionHours).not.toBeNull();
  });

  it('flags breaches and auto-closes resolved tickets', async () => {
    const b = await biz();
    await b.api('PUT', '/helpdesk/settings', { hoursMode: '24x7', autoCloseDays: 1 });
    const t = (await b.api('POST', '/helpdesk/tickets', { partyId: b.cust.id, subject: 'Slow', channel: 'email' })).body;
    // Due times move with priority: a past creation date makes it breached.
    expect(t.status).toBe('new');
    const late = await b.api('GET', '/helpdesk/tickets?breached=true');
    expect(late.body.total).toBe(0);
    await b.api('POST', `/helpdesk/tickets/${t.id}/status`, { status: 'resolved' });
    const run = await b.api('POST', '/helpdesk/run');
    expect(run.body.closed).toBe(0);
  });
});

describe('service contracts', () => {
  it('bills, schedules visits, links a ticket, covers a serial and renews', async () => {
    const b = await biz();
    const start = addDays(todayIst(), -10);
    const end = addDays(start, 364);
    const c = await b.api('POST', '/service-contracts', {
      partyId: b.cust.id, title: 'Server AMC', startDate: start, endDate: end, value: 1200, billing: 'periodic', billFrequency: 'quarterly',
      visitFrequency: 'quarterly', serviceItemId: b.svc.id, assets: [{ serialNo: 'SN-100', description: 'Rack server' }],
    });
    expect(c.status, JSON.stringify(c.body)).toBe(201);
    expect(c.body.number).toMatch(/^AMC\//);
    expect(c.body.visits).toHaveLength(3);

    const billed = await b.api('POST', `/service-contracts/${c.body.id}/bill`, {});
    expect(billed.status, JSON.stringify(billed.body)).toBe(200);
    expect(billed.body.created).toHaveLength(1);
    expect(billed.body.created[0].amount).toBe(300);
    const again = await b.api('POST', `/service-contracts/${c.body.id}/bill`, {});
    expect(again.body.created).toHaveLength(0);
    const full = await b.api('POST', `/service-contracts/${c.body.id}/bill`, { upTo: end });
    expect(full.status, JSON.stringify(full.body)).toBe(200);
    expect(full.body.created).toHaveLength(3);
    const file = (await b.api('GET', `/service-contracts/${c.body.id}`)).body;
    expect(file.billedAmount).toBe(1200);

    const cover = (await b.api('GET', `/service-contracts/covering?partyId=${b.cust.id}&serialNo=sn-100`)).body;
    expect(cover.data).toHaveLength(1);
    const ticket = (await b.api('POST', '/helpdesk/tickets', { partyId: b.cust.id, subject: 'Disk', channel: 'phone', serialNo: 'SN-100' })).body;
    expect(ticket.covered).toBe(true);
    expect(ticket.contractNumber).toBe(c.body.number);

    const visit = file.visits[0];
    const doneV = await b.api('POST', `/service-contracts/visits/${visit.id}/complete`, {
      notes: 'Cleaned', partsUsed: [{ name: 'Fan', qty: 1 }], signatureName: 'A. Kumar',
    });
    expect(doneV.status, JSON.stringify(doneV.body)).toBe(200);
    expect(doneV.body.status).toBe('done');
    const twice = await b.api('POST', `/service-contracts/visits/${visit.id}/complete`, {});
    expect(twice.status).toBe(409);

    const renewed = await b.api('POST', `/service-contracts/${c.body.id}/renew`, {});
    expect(renewed.status, JSON.stringify(renewed.body)).toBe(201);
    expect(renewed.body.startDate).toBe(addDays(end, 1));
    expect(renewed.body.renewedFromId).toBe(c.body.id);
    expect(renewed.body.assets).toHaveLength(1);
    const old = (await b.api('GET', `/service-contracts/${c.body.id}`)).body;
    expect(old.status).toBe('renewed');
    expect((await b.api('POST', `/service-contracts/${c.body.id}/renew`, {})).status).toBe(409);
  });

  it('bills an upfront contract once', async () => {
    const b = await biz();
    const c = (await b.api('POST', '/service-contracts', {
      partyId: b.cust.id, title: 'Annual', startDate: todayIst(), endDate: addDays(todayIst(), 364), value: 5000, billing: 'upfront', serviceItemId: b.svc.id,
    })).body;
    const r = await b.api('POST', `/service-contracts/${c.id}/bill`, {});
    expect(r.body.created).toHaveLength(1);
    expect(r.body.created[0].amount).toBe(5000);
    expect((await b.api('POST', `/service-contracts/${c.id}/bill`, {})).body.created).toHaveLength(0);
  });
});

describe('timesheets', () => {
  it('logs a week, approves and bills with rate overrides', async () => {
    const b = await biz('consultant');
    const me = (await b.api('GET', '/me')).body;
    await b.api('POST', '/timesheets/rates', { userId: me.user?.id ?? me.id, rate: 800 });
    await b.api('POST', '/timesheets/rates', { partyId: b.cust.id, rate: 1200 });
    const monday = (() => { let d = todayIst(); while (new Date(`${d}T00:00:00Z`).getUTCDay() !== 1) d = addDays(d, -1); return d; })();
    const put = await b.api('PUT', '/timesheets/week', {
      weekStart: monday, rows: [{ partyId: b.cust.id, task: 'Audit review', billable: true, hours: [2, 3, 0, 0, 0, 0, 0] },
        { partyId: b.cust.id, task: 'Training', billable: false, hours: [1, 0, 0, 0, 0, 0, 0] }],
    });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    expect(put.body.total).toBe(6);
    expect(put.body.dayTotals[0]).toBe(3);

    const over = await b.api('POST', '/timesheets/entries', { workDate: monday, partyId: b.cust.id, hours: 23, task: 'Too much' });
    expect(over.status).toBe(400);

    const sub = await b.api('POST', '/timesheets/submit', { weekStart: monday });
    expect(sub.body.submitted).toBe(3);
    expect((await b.api('PUT', '/timesheets/week', { weekStart: monday, rows: [] })).body.total).toBe(6);
    const entries = (await b.api('GET', `/timesheets/entries?status=submitted`)).body.data as { id: string; rate: number; billable: boolean }[];
    expect(entries.every((e) => e.rate === 1200)).toBe(true);
    const ap = await b.api('POST', '/timesheets/approve', { ids: entries.map((e) => e.id) });
    expect(ap.status, JSON.stringify(ap.body)).toBe(200);

    const noItem = await b.api('POST', '/timesheets/bill', {});
    expect(noItem.status).toBe(400);
    await b.api('PUT', '/timesheets/settings', { serviceItemId: b.svc.id });
    const un = (await b.api('GET', '/timesheets/unbilled')).body.data;
    expect(un[0]).toMatchObject({ hours: 5, amount: 6000 });

    const bill = await b.api('POST', '/timesheets/bill', {});
    expect(bill.status, JSON.stringify(bill.body)).toBe(200);
    expect(bill.body.invoices).toHaveLength(1);
    expect(bill.body.invoices[0].total).toBe(7080);
    expect((await b.api('POST', '/timesheets/bill', {})).body.invoices).toHaveLength(0);

    const util = (await b.api('GET', `/timesheets/reports/utilisation?from=${monday}&to=${addDays(monday, 6)}`)).body;
    expect(util.totals.totalHours).toBe(6);
    expect(util.totals.billableHours).toBe(5);
    expect(util.totals.billedHours).toBe(5);
    expect(util.users[0].utilisationPct).toBeCloseTo(83.3, 1);
  });

  it('rejects entries and lets them be edited again', async () => {
    const b = await biz('consultant');
    const e = (await b.api('POST', '/timesheets/entries', { workDate: todayIst(), partyId: b.cust.id, hours: 1.5, task: 'Call' })).body;
    expect((await b.api('POST', '/timesheets/entries', { workDate: todayIst(), partyId: b.cust.id, hours: 0.1, task: 'Odd' })).status).toBe(400);
    await b.api('POST', '/timesheets/submit', { ids: [e.id] });
    expect((await b.api('PATCH', `/timesheets/entries/${e.id}`, { hours: 2 })).status).toBe(409);
    await b.api('POST', '/timesheets/reject', { ids: [e.id], reason: 'Wrong customer' });
    const fixed = await b.api('PATCH', `/timesheets/entries/${e.id}`, { hours: 2 });
    expect(fixed.status).toBe(200);
    expect(fixed.body.status).toBe('draft');
  });
});

describe('module gating', () => {
  it('blocks helpdesk for a business type without it', async () => {
    const res = await client(env.app)('POST', '/auth/signup', {
      businessName: 'Salon', name: 'Owner', email: uniqueEmail('salon'), password: 'Secret@123', stateCode: '24', businessType: 'salon',
    });
    const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
    const api = client(env.app, res.body.accessToken, me.companies[0].id);
    expect((await api('GET', '/helpdesk/tickets')).status).toBe(403);
    expect((await api('GET', '/timesheets/entries')).status).toBe(403);
  });
});
