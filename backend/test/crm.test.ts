import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'kysely';
import { withTenant } from '../src/db/database.ts';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { seedCrmDemo } from '../src/db/seed-crm.ts';
import { setIndiamartFetch } from '../src/modules/crm.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { setIndiamartFetch(undefined); await teardown(env); });

async function biz(businessType = 'wholesale', name = 'Shree Traders') {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner', email: uniqueEmail('crm'), password: 'Secret@123', stateCode: '24', businessType,
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  const tenantId = JSON.parse(Buffer.from((res.body.accessToken as string).split('.')[1]!, 'base64url').toString()).tid as string;
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const as = async (roleName: string) => {
    const email = uniqueEmail(roleName.replace(/\W/g, ''));
    const made = await api('POST', '/users', { name: roleName, email, password: 'Secret@123', roleId: roles.find((r) => r.name === roleName)!.id });
    expect(made.status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    return { api: client(env.app, li.body.accessToken, companyId), userId: made.body.id as string };
  };
  return { api, as, companyId, ownerId: me.user.id as string, tenantId };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const today = todayIst();
const at = (date: string, hhmm = '10:00') => `${date}T${hhmm}:00+05:30`;
const lead = (over: Record<string, unknown> = {}) => ({ name: 'Ravi Kumar', phone: '9000000001', source: 'walk_in', ...over });
async function newLead(b: Biz, over: Record<string, unknown> = {}) {
  const r = await b.api('POST', '/crm/leads', lead(over));
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body;
}
async function newParty(b: Biz, name = 'Mehta Steel', over: Record<string, unknown> = {}) {
  const r = await b.api('POST', '/parties', { name, type: 'customer', phone: '9000000050', stateCode: '24', creditDays: 30, ...over });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body;
}
async function newDeal(b: Biz, partyId: string, over: Record<string, unknown> = {}) {
  const r = await b.api('POST', '/crm/deals', { title: 'Steel order', partyId, value: 100000, ...over });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body;
}
const stagesOf = async (b: Biz) => (await b.api('GET', '/crm/stages')).body.data as { id: string; name: string; kind: string; probability: number; isActive: boolean }[];
const stageId = (s: { id: string; name: string }[], name: string) => s.find((x) => x.name === name)!.id;

describe('crm leads', () => {
  it('creates a lead, blocks duplicates and allows force', async () => {
    const b = await biz();
    const l = await newLead(b);
    expect(l.status).toBe('new');
    expect(l.ownerId).toBeTruthy();
    expect((await b.api('POST', '/crm/leads', { name: 'No contact' })).status).toBe(400);
    const dup = await b.api('POST', '/crm/leads', lead({ name: 'Ravi K', phone: '+91 90000 00001' }));
    expect(dup.status).toBe(409);
    expect(dup.body.error.code).toBe('DUPLICATE_LEAD');
    expect(dup.body.error.details.existing.id).toBe(l.id);
    const byMail = await newLead(b, { name: 'Mail Lead', phone: undefined, email: 'a@x.in' });
    expect((await b.api('POST', '/crm/leads', { name: 'Other', email: 'A@X.IN' })).status).toBe(409);
    expect(byMail.email).toBe('a@x.in');
    expect((await b.api('POST', '/crm/leads', lead({ force: true }))).status).toBe(201);
    const list = (await b.api('GET', '/crm/leads?status=open')).body;
    expect(list.total).toBe(3);
  });

  it('shows only own and unowned leads without crm.all', async () => {
    const b = await biz();
    const rep = await b.as('Sales Executive');
    const mine = (await rep.api('POST', '/crm/leads', lead({ phone: '9000000002' }))).body;
    expect(mine.ownerId).toBe(rep.userId);
    await newLead(b, { phone: '9000000003', ownerId: b.ownerId });
    const seen = (await rep.api('GET', '/crm/leads')).body;
    expect(seen.data.map((x: { id: string }) => x.id)).toEqual([mine.id]);
    expect((await rep.api('GET', `/crm/leads?ownerId=${b.ownerId}`)).status).toBe(403);
    expect((await rep.api('POST', '/crm/leads', lead({ phone: '9000000004', ownerId: b.ownerId }))).status).toBe(403);
    expect((await b.api('GET', '/crm/leads')).body.total).toBe(2);
    expect((await rep.api('GET', '/crm/today?ownerId=all')).status).toBe(403);
    expect((await rep.api('GET', '/crm/settings')).status).toBe(200);
    expect((await rep.api('PATCH', '/crm/settings', { lostReasons: ['x'] })).status).toBe(403);
  });

  it('edits with stale check and blocks closed leads', async () => {
    const b = await biz();
    const l = await newLead(b);
    const ok = await b.api('PATCH', `/crm/leads/${l.id}`, { status: 'qualified', city: 'Surat', expectedUpdatedAt: l.updatedAt });
    expect(ok.status).toBe(200);
    expect(ok.body.status).toBe('qualified');
    const stale = await b.api('PATCH', `/crm/leads/${l.id}`, { city: 'Vapi', expectedUpdatedAt: l.updatedAt });
    expect(stale.body.error.code).toBe('STALE_EDIT');
    await b.api('POST', `/crm/leads/${l.id}/lost`, { reason: 'No budget' });
    const closed = await b.api('PATCH', `/crm/leads/${l.id}`, { city: 'Vapi' });
    expect(closed.status).toBe(409);
    expect(closed.body.error.code).toBe('LEAD_CLOSED');
  });

  it('converts to a new customer with a deal and moves open follow-ups', async () => {
    const b = await biz();
    const l = await newLead(b, { companyName: 'Ravi Enterprises', email: 'ravi@x.in', estimatedValue: 75000 });
    const fu = (await b.api('POST', '/crm/activities', { kind: 'call', subject: 'Call back', dueAt: at(addDays(today, 1)), leadId: l.id })).body;
    const detail = (await b.api('GET', `/crm/leads/${l.id}`)).body;
    expect(detail.activities).toHaveLength(1);
    expect(detail.nextFollowUp.id).toBe(fu.id);
    const out = await b.api('POST', `/crm/leads/${l.id}/convert`, { deal: { title: 'Pipes', value: 75000 } });
    expect(out.status, JSON.stringify(out.body)).toBe(200);
    expect(out.body.lead.status).toBe('converted');
    expect(out.body.lead.partyId).toBe(out.body.partyId);
    const party = (await b.api('GET', `/parties/${out.body.partyId}`)).body;
    expect(party.name).toBe('Ravi Enterprises');
    expect(party.phone).toBe('9000000001');
    const deal = (await b.api('GET', `/crm/deals/${out.body.dealId}`)).body;
    expect(deal.stageName).toBe('New');
    expect(deal.activities.map((a: { id: string }) => a.id)).toEqual([fu.id]);
    expect(deal.nextFollowUp.id).toBe(fu.id);
    expect(deal.stageHistory).toHaveLength(1);
    expect((await b.api('POST', `/crm/leads/${l.id}/convert`, {})).body.error.code).toBe('LEAD_CLOSED');
  });

  it('converts onto an existing customer without a deal and lists matches', async () => {
    const b = await biz();
    const p = await newParty(b, 'Mehta Steel', { phone: '9000000050' });
    const l = await newLead(b, { name: 'Mr Mehta', phone: '90000 00050' });
    const d = (await b.api('GET', `/crm/leads/${l.id}`)).body;
    expect(d.matches.map((m: { partyId: string }) => m.partyId)).toEqual([p.id]);
    const out = await b.api('POST', `/crm/leads/${l.id}/convert`, { partyId: p.id, deal: null });
    expect(out.body.partyId).toBe(p.id);
    expect(out.body.dealId).toBeNull();
    expect((await b.api('GET', '/parties?q=Mehta')).body.total).toBe(1);
  });

  it('marks lost, drops open follow-ups and reopens as contacted', async () => {
    const b = await biz();
    const l = await newLead(b);
    await b.api('POST', '/crm/activities', { kind: 'call', subject: 'Chase', dueAt: at(addDays(today, 2)), leadId: l.id });
    const doneOne = (await b.api('POST', '/crm/activities', { kind: 'note', subject: 'Met at expo', leadId: l.id })).body;
    expect(doneOne.doneAt).toBeTruthy();
    const lost = await b.api('POST', `/crm/leads/${l.id}/lost`, { reason: 'Price too high' });
    expect(lost.body.status).toBe('lost');
    expect(lost.body.nextFollowUp).toBeNull();
    const rest = (await b.api('GET', `/crm/activities?leadId=${l.id}`)).body;
    expect(rest.total).toBe(1);
    const re = await b.api('POST', `/crm/leads/${l.id}/reopen`);
    expect(re.body.status).toBe('contacted');
    expect(re.body.lostReason).toBeNull();
    expect((await b.api('POST', `/crm/leads/${l.id}/reopen`)).status).toBe(409);
  });
});

describe('crm deals', () => {
  it('moves stages with history and refuses closing stages', async () => {
    const b = await biz();
    const p = await newParty(b);
    const st = await stagesOf(b);
    expect(st.map((s) => [s.name, s.probability, s.kind])).toEqual([
      ['New', 10, 'open'], ['Contacted', 20, 'open'], ['Quotation sent', 50, 'open'], ['Negotiation', 70, 'open'], ['Won', 100, 'won'], ['Lost', 0, 'lost']]);
    const d = await newDeal(b, p.id, { value: 200000 });
    expect(d.effectiveProbability).toBe(10);
    expect(d.weightedValue).toBe(20000);
    const mv = await b.api('POST', `/crm/deals/${d.id}/stage`, { stageId: stageId(st, 'Negotiation') });
    expect(mv.body.stageName).toBe('Negotiation');
    expect(mv.body.weightedValue).toBe(140000);
    expect((await b.api('POST', `/crm/deals/${d.id}/stage`, { stageId: stageId(st, 'Won') })).status).toBe(400);
    expect((await b.api('POST', `/crm/deals/${d.id}/stage`, { stageId: stageId(st, 'Lost') })).status).toBe(400);
    const full = (await b.api('GET', `/crm/deals/${d.id}`)).body;
    expect(full.stageHistory.map((h: { toStage: string }) => h.toStage)).toEqual(['Negotiation', 'New']);
    expect(full.stageHistory[0].fromStage).toBe('New');
    expect(full.partyBalance).toEqual({ owes: 0, overdue: 0, oldestOverdueDays: 0 });
    expect((await b.api('POST', '/crm/deals', { title: 'x', value: 5 })).status).toBe(400);
  });

  it('wins, loses and reopens, deleting open follow-ups when closed', async () => {
    const b = await biz();
    const p = await newParty(b);
    const st = await stagesOf(b);
    const d = await newDeal(b, p.id, { value: 50000, stageId: stageId(st, 'Contacted') });
    const fu = (await b.api('POST', '/crm/activities', { kind: 'call', subject: 'Follow', dueAt: at(addDays(today, 1)), dealId: d.id })).body;
    const won = await b.api('POST', `/crm/deals/${d.id}/won`, { value: 55000 });
    expect(won.body.status).toBe('won');
    expect(won.body.value).toBe(55000);
    expect(won.body.stageKind).toBe('won');
    expect((await b.api('GET', `/crm/activities?dealId=${d.id}`)).body.total).toBe(0);
    expect((await b.api('PATCH', `/crm/deals/${d.id}`, { notes: 'x' })).body.error.code).toBe('DEAL_CLOSED');
    expect((await b.api('POST', `/crm/deals/${d.id}/lost`, { reason: 'x' })).body.error.code).toBe('DEAL_CLOSED');
    const re = await b.api('POST', `/crm/deals/${d.id}/reopen`);
    expect(re.body.status).toBe('open');
    expect(re.body.stageName).toBe('Contacted');
    expect(re.body.wonAt).toBeNull();
    const lost = await b.api('POST', `/crm/deals/${d.id}/lost`, { reason: 'No budget' });
    expect(lost.body.status).toBe('lost');
    expect(lost.body.lostReason).toBe('No budget');
    expect(fu.id).toBeTruthy();
    const hist = (await b.api('GET', `/crm/deals/${d.id}`)).body.stageHistory.map((h: { toStage: string }) => h.toStage);
    expect(hist).toEqual(['Lost', 'Contacted', 'Won', 'Contacted']);
    expect((await b.api('GET', '/crm/deals')).body.total).toBe(0);
    expect((await b.api('GET', '/crm/deals?status=lost')).body.total).toBe(1);
  });
});

describe('crm follow-ups', () => {
  it('applies the first-contact rule once and chains the next follow-up', async () => {
    const b = await biz();
    const l = await newLead(b);
    const task = (await b.api('POST', '/crm/activities', { kind: 'task', subject: 'Prepare', dueAt: at(addDays(today, 1)), leadId: l.id })).body;
    await b.api('POST', `/crm/activities/${task.id}/done`, { outcome: 'Prepared' });
    expect((await b.api('GET', `/crm/leads/${l.id}`)).body.status).toBe('new');
    const call = (await b.api('POST', '/crm/activities', { kind: 'call', subject: 'Intro call', dueAt: at(today, '23:00'), leadId: l.id })).body;
    const res = await b.api('POST', `/crm/activities/${call.id}/done`, {
      outcome: 'Wants a quote', durationMin: 6, next: { kind: 'visit', subject: 'Site visit', dueAt: at(addDays(today, 3)) },
    });
    expect(res.status).toBe(200);
    expect(res.body.done.doneAt).toBeTruthy();
    expect(res.body.next.leadId).toBe(l.id);
    const after = (await b.api('GET', `/crm/leads/${l.id}`)).body;
    expect(after.status).toBe('contacted');
    const first = after.firstContactAt;
    expect(first).toBeTruthy();
    expect(after.nextFollowUp.subject).toBe('Site visit');
    expect((await b.api('POST', `/crm/activities/${call.id}/done`, { outcome: 'again' })).body.error.code).toBe('ALREADY_DONE');
    const call2 = (await b.api('POST', '/crm/activities', { kind: 'whatsapp', subject: 'Sent catalogue', doneAt: new Date().toISOString(), leadId: l.id })).body;
    expect(call2.doneAt).toBeTruthy();
    expect((await b.api('GET', `/crm/leads/${l.id}`)).body.firstContactAt).toBe(first);
    expect((await b.api('PATCH', `/crm/activities/${call.id}`, { subject: 'x' })).body.error.code).toBe('ALREADY_DONE');
    expect((await b.api('DELETE', `/crm/activities/${call.id}`)).status).toBe(409);
    expect((await b.api('DELETE', `/crm/activities/${res.body.next.id}`)).status).toBe(204);
    expect((await b.api('POST', '/crm/activities', { kind: 'call', subject: 'no ref', dueAt: at(today) })).status).toBe(400);
  });

  it('sorts follow-ups into overdue, today and upcoming by Indian time', async () => {
    const b = await biz();
    const l = await newLead(b);
    const mk = async (subject: string, dueAt: string) =>
      (await b.api('POST', '/crm/activities', { kind: 'call', subject, dueAt, leadId: l.id })).body;
    await mk('late 1', at(addDays(today, -1), '10:00'));
    await mk('late 2', at(addDays(today, -3), '10:00'));
    await mk('now 1', at(today, '23:59'));
    await mk('soon 1', at(addDays(today, 1), '10:00'));
    await mk('soon 2', at(addDays(today, 6), '10:00'));
    await mk('far', at(addDays(today, 20), '10:00'));
    const g = async (when: string) => (await b.api('GET', `/crm/activities?when=${when}`)).body;
    expect((await g('overdue')).total).toBe(2);
    expect((await g('today')).total).toBe(1);
    expect((await g('upcoming')).total).toBe(3);
    const t = (await b.api('GET', '/crm/today')).body;
    expect(t.counts.overdue).toBe(2);
    expect(t.counts.dueToday).toBe(1);
    expect(t.overdue.map((a: { subject: string }) => a.subject)).toEqual(['late 2', 'late 1']);
    expect(t.overdue[0].overdue).toBe(true);
    expect(t.today[0].title).toBe('Ravi Kumar');
    expect(t.upcoming.map((a: { subject: string }) => a.subject)).toEqual(['soon 1', 'soon 2']);
    expect(t.counts.newLeads).toBe(1);
    expect(t.month.month).toBe(today.slice(0, 7));
  });
});

describe('crm numbers', () => {
  it('computes pipeline and stats on a hand-checked fixture', async () => {
    const b = await biz();
    const p = await newParty(b);
    const st = await stagesOf(b);
    const S = (n: string) => stageId(st, n);
    const A = await newDeal(b, p.id, { title: 'A', value: 100000 });
    const B = await newDeal(b, p.id, { title: 'B', value: 200000 });
    await b.api('POST', `/crm/deals/${B.id}/stage`, { stageId: S('Negotiation') });
    await newDeal(b, p.id, { title: 'C', value: 50000, stageId: S('Contacted'), probability: 40 });
    const D = await newDeal(b, p.id, { title: 'D', value: 80000 });
    const E = await newDeal(b, p.id, { title: 'E', value: 30000 });
    const F = await newDeal(b, p.id, { title: 'F', value: 60000 });
    await b.api('POST', `/crm/deals/${D.id}/won`, {});
    await b.api('POST', `/crm/deals/${E.id}/won`, { value: 40000 });
    await b.api('POST', `/crm/deals/${F.id}/lost`, { reason: 'Price too high' });
    expect(A.id).toBeTruthy();

    const pipe = (await b.api('GET', '/crm/pipeline')).body;
    expect(pipe.openCount).toBe(3);
    expect(pipe.openValue).toBe(350000);
    expect(pipe.weightedValue).toBe(10000 + 140000 + 20000);
    expect(pipe.stages.map((s: { name: string; count: number; value: number; weightedValue: number }) => [s.name, s.count, s.value, s.weightedValue])).toEqual([
      ['New', 1, 100000, 10000], ['Contacted', 1, 50000, 20000], ['Quotation sent', 0, 0, 0], ['Negotiation', 1, 200000, 140000]]);

    // Leads: two justdial (one converted without a deal), one walk-in, first contact on one.
    const l1 = await newLead(b, { phone: '9000000011', source: 'justdial' });
    await newLead(b, { phone: '9000000012', source: 'justdial' });
    await newLead(b, { phone: '9000000013', source: 'walk_in' });
    await b.api('POST', '/crm/activities', { kind: 'call', subject: 'Called', doneAt: new Date().toISOString(), leadId: l1.id });
    await b.api('POST', `/crm/leads/${l1.id}/convert`, { partyId: p.id, deal: null });
    const month = today.slice(0, 7);
    expect((await b.api('PUT', '/crm/targets', { month, rows: [{ userId: null, amount: 200000 }] })).status).toBe(200);

    const s = (await b.api('GET', '/crm/stats')).body;
    expect([s.openCount, s.openValue, s.weightedValue]).toEqual([3, 350000, 170000]);
    expect([s.wonCount, s.wonValue, s.lostCount]).toEqual([2, 120000, 1]);
    expect(s.winRate).toBe(66.67);
    expect(s.avgDealSize).toBe(60000);
    expect(s.avgCycleDays).toBeGreaterThanOrEqual(0);
    expect(s.avgCycleDays).toBeLessThan(1);
    expect([s.target, s.achievement, s.gap, s.achievementPct]).toEqual([200000, 120000, 80000, 60]);
    expect(s.coverage).toBe(4.38);
    expect(s.avgResponseHours).toBeGreaterThanOrEqual(0);
    expect(s.avgResponseHours).toBeLessThan(1);
    const conv = Object.fromEntries(s.stageConversion.map((c: { name: string }) => [c.name, c]));
    expect([conv['New'].entered, conv['New'].advanced, conv['New'].rate]).toEqual([5, 3, 60]);
    expect([conv['Contacted'].entered, conv['Contacted'].advanced, conv['Contacted'].rate]).toEqual([1, 0, 0]);
    expect([conv['Negotiation'].entered, conv['Negotiation'].advanced]).toEqual([1, 0]);
    expect(conv['Quotation sent'].rate).toBeNull();
    expect(s.bySource).toEqual([
      { source: 'justdial', leads: 2, converted: 1, rate: 50 }, { source: 'walk_in', leads: 1, converted: 0, rate: 0 }]);
    expect(s.lostReasons).toEqual([{ reason: 'Price too high', count: 1 }]);
    expect(s.byOwner).toHaveLength(1);
    expect(s.byOwner[0]).toMatchObject({ wonValue: 120000, wonCount: 2, openValue: 350000 });

    const lastMonth = (await b.api('GET', `/crm/stats?from=${addDays(today, -90)}&to=${addDays(today, -60)}`)).body;
    expect([lastMonth.wonCount, lastMonth.winRate, lastMonth.avgDealSize, lastMonth.target, lastMonth.gap, lastMonth.coverage]).toEqual([0, null, null, 0, 0, null]);
    const t = (await b.api('GET', '/crm/today?ownerId=all')).body.month;
    expect([t.target, t.won, t.openCount, t.openValue, t.weightedValue]).toEqual([200000, 120000, 3, 350000, 170000]);
  });

  it('overview shows balance, overdue days, days to pay and a timeline', async () => {
    const b = await biz();
    const p = await newParty(b, 'Patel Pipes', { creditLimit: 5000 });
    const loc = (await b.api('POST', '/locations', { type: 'store', name: 'Main' })).body;
    const item = (await b.api('POST', '/items', { name: 'Consulting', unit: 'NOS', gstRate: 18, hsnCode: '9983', salePrice: 1000, trackStock: false })).body;
    const accounts = (await b.api('GET', '/accounts')).body.data as { id: string; subtype: string }[];
    const cash = accounts.find((a) => a.subtype === 'cash')!;
    const inv = async (daysAgo: number) => {
      const r = await b.api('POST', '/invoices', { locationId: loc.id, partyId: p.id, invoiceDate: addDays(today, -daysAgo), lines: [{ itemId: item.id, qty: 1, rate: 1000 }] });
      expect(r.status, JSON.stringify(r.body)).toBe(201);
      return r.body;
    };
    const i1 = await inv(40);
    const i2 = await inv(20);
    const rc = (amount: number, docId: string) => b.api('POST', '/payments', {
      kind: 'receipt', partyId: p.id, accountId: cash.id, mode: 'cash', amount, allocations: [{ docType: 'invoice', docId, amount }] });
    expect((await rc(500, i1.id)).status).toBe(201);
    expect((await rc(1180, i2.id)).status).toBe(201);
    const deal = await newDeal(b, p.id);
    await b.api('POST', '/crm/activities', { kind: 'call', subject: 'Reminder call', doneAt: new Date().toISOString(), dealId: deal.id });
    await b.api('POST', `/parties/${p.id}/contacts`, { name: 'Anil Patel', isPrimary: true });
    const o = (await b.api('GET', `/crm/parties/${p.id}/overview`)).body;
    expect(o.party.name).toBe('Patel Pipes');
    expect([o.owes, o.overdue, o.oldestOverdueDays]).toEqual([680, 680, 10]);
    expect(o.creditLimit).toBe(5000);
    expect(o.creditUsedPct).toBe(13.6);
    expect(o.sales12m).toBe(2360);
    expect(o.avgDaysToPay).toBe(20);
    expect(o.lastInvoiceDate).toBe(addDays(today, -20));
    expect(o.openDeals).toHaveLength(1);
    expect(o.openDeals[0].partyBalance.overdue).toBe(680);
    expect(o.contacts).toHaveLength(1);
    const kinds = o.timeline.map((t: { kind: string }) => t.kind);
    expect(new Set(kinds)).toEqual(new Set(['deal', 'activity', 'invoice', 'payment']));
    const dates = o.timeline.map((t: { at: string }) => t.at);
    expect([...dates].sort().reverse()).toEqual(dates);
    expect((await b.api('GET', `/crm/deals/${deal.id}`)).body.partyBalance.owes).toBe(680);
    expect((await b.api('GET', '/crm/parties/00000000-0000-4000-8000-000000000000/overview')).status).toBe(404);
  });
});

describe('crm contacts, stages, targets, settings', () => {
  it('keeps one primary contact', async () => {
    const b = await biz();
    const p = await newParty(b);
    const a = (await b.api('POST', `/parties/${p.id}/contacts`, { name: 'Asha', phone: '9000000061', isPrimary: true })).body;
    const c = (await b.api('POST', `/parties/${p.id}/contacts`, { name: 'Bina', designation: 'Accounts' })).body;
    expect(c.isPrimary).toBe(false);
    let list = (await b.api('GET', `/parties/${p.id}/contacts`)).body.data;
    expect(list.map((x: { name: string }) => x.name)).toEqual(['Asha', 'Bina']);
    const sw = await b.api('PATCH', `/parties/${p.id}/contacts/${c.id}`, { isPrimary: true, email: 'bina@x.in' });
    expect(sw.body.isPrimary).toBe(true);
    list = (await b.api('GET', `/parties/${p.id}/contacts`)).body.data;
    expect(list.map((x: { name: string; isPrimary: boolean }) => [x.name, x.isPrimary])).toEqual([['Bina', true], ['Asha', false]]);
    const third = (await b.api('POST', `/parties/${p.id}/contacts`, { name: 'Chetan', isPrimary: true })).body;
    list = (await b.api('GET', `/parties/${p.id}/contacts`)).body.data;
    expect(list.filter((x: { isPrimary: boolean }) => x.isPrimary).map((x: { id: string }) => x.id)).toEqual([third.id]);
    expect((await b.api('DELETE', `/parties/${p.id}/contacts/${a.id}`)).status).toBe(204);
    expect((await b.api('DELETE', `/parties/${p.id}/contacts/${a.id}`)).status).toBe(404);
    const rep = await b.as('Sales Executive');
    expect((await rep.api('GET', `/parties/${p.id}/contacts`)).status).toBe(200);
    expect((await rep.api('POST', `/parties/${p.id}/contacts`, { name: 'No' })).status).toBe(403);
  });

  it('replaces stages under the rules and retires stages that have deals', async () => {
    const b = await biz();
    const p = await newParty(b);
    const st = await stagesOf(b);
    const d = await newDeal(b, p.id, { stageId: stageId(st, 'Contacted') });
    const keep = (n: string, over: Record<string, unknown> = {}) => { const s = st.find((x) => x.name === n)!; return { id: s.id, name: s.name, probability: s.probability, kind: s.kind, ...over }; };
    const bad = (stages: unknown[]) => b.api('PUT', '/crm/stages', { stages });
    expect((await bad([keep('New'), keep('Contacted'), keep('Won')])).status).toBe(400);
    expect((await bad([keep('Won'), keep('Lost'), keep('Won', { id: undefined, name: 'Won 2' })])).status).toBe(400);
    expect((await bad([keep('New'), keep('Won'), keep('Lost'), keep('Contacted', { kind: 'lost' })])).status).toBe(400);
    expect((await bad([keep('New'), keep('Won'), keep('Lost'), { name: 'new', probability: 5, kind: 'open' }])).status).toBe(400);
    const ok = await b.api('PATCH', '/crm/stages', { stages: [
      keep('Contacted', { name: 'Qualified', probability: 30 }), keep('New'), { name: 'Demo', probability: 60, kind: 'open' }, keep('Won'), keep('Lost')] });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    const names = ok.body.data.map((s: { name: string; isActive: boolean }) => [s.name, s.isActive]);
    expect(names.slice(0, 5)).toEqual([['Qualified', true], ['New', true], ['Demo', true], ['Won', true], ['Lost', true]]);
    // Quotation sent and Negotiation had no deals, so they are gone.
    expect(names).toHaveLength(5);
    expect((await b.api('GET', `/crm/deals/${d.id}`)).body.stageName).toBe('Qualified');
    // Leave out the stage that holds a deal: it is kept but inactive.
    const out = await b.api('PUT', '/crm/stages', { stages: [keep('New'), { id: ok.body.data[2].id, name: 'Demo', probability: 60, kind: 'open' }, keep('Won'), keep('Lost')]
      .map((s: Record<string, unknown>) => ({ ...s, id: s.id ?? undefined })) });
    expect(out.status, JSON.stringify(out.body)).toBe(200);
    const retired = out.body.data.find((s: { isActive: boolean }) => !s.isActive);
    expect(retired.name).toContain('Qualified');
    expect((await b.api('GET', '/crm/pipeline')).body.stages.map((s: { name: string }) => s.name)).toEqual(['New', 'Demo']);
    expect((await b.api('GET', '/crm/pipeline')).body.openCount).toBe(1);
    expect((await b.api('POST', `/crm/deals/${d.id}/stage`, { stageId: retired.id })).status).toBe(400);
  });

  it('upserts and removes targets', async () => {
    const b = await biz();
    const rep = await b.as('Sales Executive');
    const month = '2026-12';
    const put = await b.api('PUT', '/crm/targets', { month, rows: [{ userId: null, amount: 500000 }, { userId: rep.userId, amount: 150000 }] });
    expect(put.status).toBe(200);
    expect(put.body.rows.map((r: { userId: string | null; amount: number }) => [r.userId, r.amount])).toEqual([[null, 500000], [rep.userId, 150000]]);
    expect(put.body.rows[0].userName).toBe('Company');
    const again = await b.api('PATCH', '/crm/targets', { month, rows: [{ userId: null, amount: 600000 }, { userId: rep.userId, amount: 0 }] });
    expect(again.body.rows).toEqual([{ userId: null, userName: 'Company', amount: 600000 }]);
    expect((await b.api('GET', `/crm/targets?month=${month}`)).body.rows).toHaveLength(1);
    expect((await b.api('GET', '/crm/targets?month=2027-01')).body.rows).toHaveLength(0);
    expect((await rep.api('PUT', '/crm/targets', { month, rows: [] })).status).toBe(403);
    const owners = (await b.api('GET', '/crm/owners')).body.data.map((o: { id: string }) => o.id);
    expect(owners).toContain(rep.userId);
    expect(owners).toContain(b.ownerId);
  });

  it('seals the IndiaMART key and never returns it', async () => {
    const b = await biz();
    const first = (await b.api('GET', '/crm/settings')).body;
    expect(first.hasIndiamartKey).toBe(false);
    expect(first.lostReasons.length).toBeGreaterThan(0);
    const secret = 'mR8xKq2LzPj9TnVwA7Yc';
    const set = await b.api('PATCH', '/crm/settings', { indiamartKey: secret, lostReasons: ['Too costly', 'Went elsewhere'], defaultOwnerId: b.ownerId });
    expect(set.status).toBe(200);
    expect(set.body.hasIndiamartKey).toBe(true);
    expect(JSON.stringify(set.body)).not.toContain(secret);
    expect(JSON.stringify((await b.api('GET', '/crm/settings')).body)).not.toContain(secret);
    const stored = await withTenant(env.db, b.tenantId, async (tx) =>
      (await sql<{ k: string }>`select indiamart_key_sealed as k from crm_settings where company_id = ${b.companyId}`.execute(tx)).rows[0]!.k);
    expect(stored).toMatch(/^v1\./);
    expect(stored).not.toContain(secret);
    expect((await b.api('PATCH', '/crm/settings', { lostReasons: [] })).status).toBe(400);
    const off = await b.api('PATCH', '/crm/settings', { indiamartKey: null });
    expect(off.body.hasIndiamartKey).toBe(false);
  });
});

describe('crm IndiaMART pull', () => {
  const reply = (obj: unknown) => async () => ({ ok: true, status: 200, text: async () => JSON.stringify(obj) });
  it('adds, dedupes, throttles and saves errors', async () => {
    const b = await biz();
    const urls: string[] = [];
    expect((await b.api('POST', '/crm/indiamart/pull')).body.error.code).toBe('NO_INDIAMART_KEY');
    await b.api('PATCH', '/crm/settings', { indiamartKey: 'abcdefgh12345678' });
    const rows = [
      { UNIQUE_QUERY_ID: 'Q100', SENDER_NAME: 'Kiran Shah', SENDER_MOBILE: '+91-9000000071', SENDER_EMAIL: '', SENDER_COMPANY: 'Shah Pumps',
        SENDER_CITY: 'Rajkot', SENDER_STATE: 'Gujarat', QUERY_PRODUCT_NAME: 'Submersible pump', QUERY_MESSAGE: 'Need 10 pumps' },
      { UNIQUE_QUERY_ID: 'Q101', SENDER_MOBILE: '9000000072', QUERY_MESSAGE: 'Price list please' },
    ];
    setIndiamartFetch(async (url) => { urls.push(url); return reply({ CODE: 200, STATUS: 'SUCCESS', TOTAL_RECORDS: 2, RESPONSE: rows })(); });
    const r1 = await b.api('POST', '/crm/indiamart/pull');
    expect(r1.status, JSON.stringify(r1.body)).toBe(200);
    expect([r1.body.added, r1.body.skipped]).toEqual([2, 0]);
    expect(urls[0]).toContain('mapi.indiamart.com/wservce/crm/crmListing/v2/');
    expect(urls[0]).toContain('glusr_crm_key=abcdefgh12345678');
    expect(urls[0]).toMatch(/start_time=\d{2}-\d{2}-\d{4}\d{2}%3A\d{2}%3A\d{2}/);
    const leads = (await b.api('GET', '/crm/leads?source=indiamart')).body.data;
    expect(leads).toHaveLength(2);
    const kiran = leads.find((l: { sourceRef: string }) => l.sourceRef === 'Q100');
    expect(kiran).toMatchObject({ name: 'Kiran Shah', companyName: 'Shah Pumps', city: 'Rajkot', stateCode: '24', email: null });
    expect(kiran.requirement).toContain('Submersible pump');
    expect(leads.find((l: { sourceRef: string }) => l.sourceRef === 'Q101').name).toBe('IndiaMART Buyer');
    expect((await b.api('GET', '/crm/settings')).body.indiamartLastPullAt).toBeTruthy();
    // Within five minutes.
    const soon = await b.api('POST', '/crm/indiamart/pull');
    expect(soon.status).toBe(429);
    expect(soon.body.error.code).toBe('TOO_SOON');
    // Age the last pull, then repeat: both skipped.
    const age = (mins: number) => withTenant(env.db, b.tenantId, async (tx) => {
      await sql`update crm_settings set indiamart_last_pull_at = now() - ${`${mins} minutes`}::interval where company_id = ${b.companyId}`.execute(tx);
    });
    await age(10);
    const r2 = await b.api('POST', '/crm/indiamart/pull');
    expect([r2.body.added, r2.body.skipped]).toEqual([0, 2]);
    // Errors from IndiaMART come back as 502 and are saved; the pull time stays put so no window is lost.
    await age(10);
    const before = (await b.api('GET', '/crm/settings')).body.indiamartLastPullAt;
    setIndiamartFetch(reply({ CODE: 401, STATUS: 'FAILURE', MESSAGE: 'Incorrect key supplied' }));
    const bad = await b.api('POST', '/crm/indiamart/pull');
    expect(bad.status).toBe(502);
    expect(bad.body.error.code).toBe('INDIAMART_ERROR');
    expect(bad.body.error.message).toContain('Incorrect key');
    const s = (await b.api('GET', '/crm/settings')).body;
    expect(s.indiamartLastError).toContain('Incorrect key');
    expect(s.indiamartLastPullAt).toBe(before);
    // No leads in the window is fine.
    setIndiamartFetch(reply({ CODE: 204, STATUS: 'SUCCESS', MESSAGE: 'No leads', RESPONSE: [] }));
    const none = await b.api('POST', '/crm/indiamart/pull');
    expect([none.status, none.body.added]).toEqual([200, 0]);
    expect((await b.api('GET', '/crm/settings')).body.indiamartLastError).toBeNull();
    const rep = await b.as('Sales Executive');
    expect((await rep.api('POST', '/crm/indiamart/pull')).status).toBe(403);
    setIndiamartFetch(undefined);
  });
});

describe('crm module gate', () => {
  it('returns MODULE_DISABLED when the company has not enabled crm, but contacts stay open', async () => {
    const b = await biz();
    const company = (await b.api('GET', '/company')).body;
    const enabled = (company.enabledModules as string[]).filter((m) => m !== 'crm');
    expect((await b.api('POST', '/company/business-profile', { enabledModules: enabled })).status).toBe(200);
    const blocked = await b.api('GET', '/crm/leads');
    expect(blocked.status).toBe(403);
    expect(blocked.body.error.code).toBe('MODULE_DISABLED');
    const p = await newParty(b);
    expect((await b.api('GET', `/parties/${p.id}/contacts`)).status).toBe(200);
    expect((await b.api('POST', '/company/business-profile', { enabledModules: [...enabled, 'crm'] })).status).toBe(200);
    expect((await b.api('GET', '/crm/leads')).status).toBe(200);
  });
});

describe('crm demo seed', () => {
  it('makes believable sample data and is safe to run twice', async () => {
    const b = await biz();
    const run = () => withTenant(env.db, b.tenantId, (tx) => seedCrmDemo(tx, { tenantId: b.tenantId, companyId: b.companyId, userId: b.ownerId }));
    await run();
    await run();
    expect((await b.api('GET', '/crm/leads')).body.total).toBe(8);
    const t = (await b.api('GET', '/crm/today')).body;
    expect([t.counts.overdue, t.counts.dueToday]).toEqual([2, 3]);
    const s = (await b.api('GET', '/crm/stats')).body;
    expect([s.openCount, s.wonCount, s.lostCount, s.target]).toEqual([3, 2, 1, 500000]);
    expect((await b.api('GET', '/crm/pipeline')).body.openValue).toBe(36000 + 245000 + 620000);
  });
});
