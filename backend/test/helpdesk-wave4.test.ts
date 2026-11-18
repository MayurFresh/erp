import { createHmac } from 'node:crypto';
import { sql } from 'kysely';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withTenant } from '../src/db/database.ts';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { setCashfreeFetch, verifySignature, parseEvent } from '../src/lib/gateways/cashfree.ts';
import { businessMillis, dueAt, type Hours } from '../src/lib/sla.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { setCashfreeFetch(undefined); await teardown(env); });

const IST = (s: string) => new Date(`${s}+05:30`);
const biz9: Hours = { mode: 'business', workDays: [1, 2, 3, 4, 5, 6], startTime: '09:00', endTime: '18:00' };

async function biz() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Wave Four Co', name: 'Owner', email: uniqueEmail('w4'), password: 'Secret@123', stateCode: '24', businessType: 'it_services',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  const tid = JSON.parse(Buffer.from((res.body.accessToken as string).split('.')[1]!, 'base64url').toString()).tid as string;
  const loc = (await api('POST', '/locations', { type: 'store', name: 'Main', stateCode: '24' })).body;
  const svc = (await api('POST', '/items', { name: 'Support service', unit: 'NOS', gstRate: 18, hsnCode: '9987', salePrice: 1000, trackStock: false })).body;
  const part = (await api('POST', '/items', { name: 'Fan', unit: 'NOS', gstRate: 18, hsnCode: '8414', salePrice: 500, purchasePrice: 200, trackStock: true })).body;
  const cust = (await api('POST', '/parties', { type: 'customer', name: 'Acme Ltd', stateCode: '24', phone: '9825011111', email: 'a@acme.in' })).body;
  return { api, companyId, tid, loc, svc, part, cust };
}

describe('business time', () => {
  it('counts only working hours between two moments', () => {
    // Monday 16:00 to Tuesday 10:00: 2 hours Monday, 1 hour Tuesday.
    expect(businessMillis(IST('2026-11-16T16:00:00'), IST('2026-11-17T10:00:00'), biz9)).toBe(3 * 3600_000);
    // Saturday 17:00 to Monday 10:00: 1 hour Saturday, Sunday off, 1 hour Monday.
    expect(businessMillis(IST('2026-11-21T17:00:00'), IST('2026-11-23T10:00:00'), biz9)).toBe(2 * 3600_000);
    expect(businessMillis(IST('2026-11-16T10:00:00'), IST('2026-11-16T12:00:00'), { ...biz9, mode: '24x7' })).toBe(2 * 3600_000);
  });
  it('pushes a due time out by the business hours a ticket waited', () => {
    const due = IST('2026-11-16T15:00:00');
    const waited = businessMillis(IST('2026-11-16T14:00:00'), IST('2026-11-17T10:00:00'), biz9) / 3600_000; // 4 + 1 = 5h
    expect(waited).toBe(5);
    expect(dueAt(due, waited, biz9).toISOString()).toBe(IST('2026-11-17T11:00:00').toISOString());
  });
});

describe('SLA pause', () => {
  it('adds the wait to both targets and shows the pause while waiting', async () => {
    const b = await biz();
    await b.api('PUT', '/helpdesk/settings', { hoursMode: '24x7', sla: { high: { firstResponseHours: 2, resolutionHours: 10 } } });
    const t = (await b.api('POST', '/helpdesk/tickets', { partyId: b.cust.id, subject: 'Slow', channel: 'phone', priority: 'high' })).body;
    const before = new Date(t.resolutionDue).getTime();
    const waiting = await b.api('POST', `/helpdesk/tickets/${t.id}/status`, { status: 'waiting' });
    expect(waiting.body.slaPaused).toBe(true);
    // The wait started two hours ago.
    await withTenant(env.db, b.tid, (tx) => sql`update hd_tickets set waiting_since = now() - interval '2 hours' where id = ${t.id}`.execute(tx));
    const mid = (await b.api('GET', `/helpdesk/tickets/${t.id}`)).body;
    expect(new Date(mid.resolutionDue).getTime() - before).toBeCloseTo(2 * 3600_000, -4);
    const open = await b.api('POST', `/helpdesk/tickets/${t.id}/status`, { status: 'open' });
    expect(open.body.slaPaused).toBe(false);
    expect(open.body.pausedMinutes).toBe(120);
    expect(new Date(open.body.resolutionDue).getTime() - before).toBeCloseTo(2 * 3600_000, -4);
    expect(new Date(open.body.firstResponseDue).getTime() - new Date(t.firstResponseDue).getTime()).toBeCloseTo(2 * 3600_000, -4);
    const hist = await withTenant(env.db, b.tid, (tx) => sql<{ status: string }>`select status from hd_status_history where ticket_id = ${t.id} order by at`.execute(tx));
    expect(hist.rows.map((r) => r.status)).toEqual(['new', 'waiting', 'open']);
    // A priority change keeps the paused time.
    const up = await b.api('PATCH', `/helpdesk/tickets/${t.id}`, { priority: 'urgent' });
    expect(up.body.pausedMinutes).toBe(120);
  });
});

describe('visit parts and signature', () => {
  it('issues stock on completion, swaps parts, and returns it when the visit is cancelled', async () => {
    const b = await biz();
    expect((await b.api('POST', '/stock/adjustments', { locationId: b.loc.id, itemId: b.part.id, qty: 10, rate: 200 })).status).toBe(201);
    const onHand = async () => Number((await withTenant(env.db, b.tid, (tx) => sql<{ q: string }>`select coalesce(sum(qty),0) as q from stock_moves where item_id = ${b.part.id}`.execute(tx))).rows[0]!.q);
    const inventory = async () => Number((await withTenant(env.db, b.tid, (tx) => sql<{ d: string }>`select coalesce(sum(jl.debit - jl.credit),0) as d from journal_lines jl join accounts a on a.id = jl.account_id where a.company_id = ${b.companyId} and a.name = 'Inventory'`.execute(tx))).rows[0]!.d);
    const inv0 = await inventory();
    const start = addDays(todayIst(), -10);
    const c = (await b.api('POST', '/service-contracts', {
      partyId: b.cust.id, title: 'AMC', startDate: start, endDate: addDays(start, 364), value: 1200, billing: 'upfront',
      visitFrequency: 'quarterly', serviceItemId: b.svc.id,
    })).body;
    const visit = c.visits[0];
    const noLoc = await b.api('POST', `/service-contracts/visits/${visit.id}/complete`, { partsUsed: [{ itemId: b.part.id, name: 'Fan', qty: 2 }] });
    expect(noLoc.status).toBe(400);
    const done = await b.api('POST', `/service-contracts/visits/${visit.id}/complete`, {
      locationId: b.loc.id, partsUsed: [{ itemId: b.part.id, name: 'Fan', qty: 2 }, { name: 'Grease', qty: 1 }], signatureName: 'R. Shah',
    });
    expect(done.status, JSON.stringify(done.body)).toBe(200);
    expect(done.body.partsLocationId).toBe(b.loc.id);
    expect(await onHand()).toBe(8);
    expect(await inventory()).toBe(inv0 - 400);

    const swap = await b.api('PATCH', `/service-contracts/visits/${visit.id}/parts`, { locationId: b.loc.id, partsUsed: [{ itemId: b.part.id, name: 'Fan', qty: 3 }] });
    expect(swap.status, JSON.stringify(swap.body)).toBe(200);
    expect(await onHand()).toBe(7);
    const removed = await b.api('PATCH', `/service-contracts/visits/${visit.id}/parts`, { partsUsed: [] });
    expect(removed.status).toBe(200);
    expect(await onHand()).toBe(10);

    await b.api('PATCH', `/service-contracts/visits/${visit.id}/parts`, { locationId: b.loc.id, partsUsed: [{ itemId: b.part.id, name: 'Fan', qty: 4 }] });
    expect(await onHand()).toBe(6);
    const cancelled = await b.api('POST', `/service-contracts/visits/${visit.id}/cancel`, {});
    expect(cancelled.body.status).toBe('cancelled');
    expect(await onHand()).toBe(10);
    expect(await inventory()).toBe(inv0);
    expect((await b.api('POST', `/service-contracts/visits/${visit.id}/cancel`, {})).status).toBe(409);
  });

  it('refuses more parts than are in stock', async () => {
    const b = await biz();
    await b.api('POST', '/stock/adjustments', { locationId: b.loc.id, itemId: b.part.id, qty: 1, rate: 200 });
    const start = addDays(todayIst(), -10);
    const c = (await b.api('POST', '/service-contracts', {
      partyId: b.cust.id, title: 'AMC', startDate: start, endDate: addDays(start, 364), value: 1200, billing: 'upfront', visitFrequency: 'quarterly', serviceItemId: b.svc.id,
    })).body;
    const r = await b.api('POST', `/service-contracts/visits/${c.visits[0].id}/complete`, { locationId: b.loc.id, partsUsed: [{ itemId: b.part.id, name: 'Fan', qty: 5 }] });
    expect(r.status).toBe(409);
  });
});

describe('Cashfree payment links', () => {
  const SECRET = 'cf_secret_abcdef123456';
  const sign = (ts: string, raw: string, secret = SECRET) => createHmac('sha256', secret).update(ts + raw).digest('base64');

  it('checks the signature and reads the event', () => {
    const raw = Buffer.from('{"a":1}');
    expect(verifySignature(raw, sign('1700000000', '{"a":1}'), '1700000000', SECRET)).toBe(true);
    expect(verifySignature(raw, sign('1700000000', '{"a":2}'), '1700000000', SECRET)).toBe(false);
    expect(verifySignature(raw, undefined, '1700000000', SECRET)).toBe(false);
    const ev = parseEvent({ type: 'PAYMENT_LINK_EVENT', data: { link_id: 'abc', link_status: 'PAID', order: { order_amount: '1180.00', transaction_id: 99 } } });
    expect(ev).toMatchObject({ event: 'payment_link.paid', linkId: 'abc', paymentId: 'cf_99', amount: 1180 });
  });

  it('creates a link, records one receipt per payment and ignores repeats', async () => {
    const b = await biz();
    const bank = ((await b.api('GET', '/accounts')).body.data as { id: string; subtype: string }[]).find((a) => a.subtype === 'bank')!;
    const inv = (await b.api('POST', '/invoices', { locationId: b.loc.id, partyId: b.cust.id, lines: [{ itemId: b.svc.id, qty: 1 }] })).body;
    const seen: { url: string; init: any }[] = [];
    setCashfreeFetch((async (url: string, init: any) => {
      seen.push({ url, init });
      return new Response(JSON.stringify({ cf_link_id: 5, link_url: 'https://payments-test.cashfree.com/links/abc', link_status: 'ACTIVE' }), { status: 200 });
    }) as never);
    const set = await b.api('PATCH', '/payment-gateways/cashfree', { keyId: 'TEST1234abcd', keySecret: SECRET, accountId: bank.id, isActive: true });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
    expect(set.body.provider).toBe('cashfree');
    expect(set.body.mode).toBe('test');
    expect(JSON.stringify(set.body)).not.toContain(SECRET);
    const gws = (await b.api('GET', '/payment-gateways')).body.data as any[];
    const gw = gws.find((g) => g.provider === 'cashfree');

    const made = await b.api('POST', `/invoices/${inv.id}/payment-links`, {});
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    expect(made.body.shortUrl).toContain('cashfree.com');
    expect(seen[0]!.url).toBe('https://sandbox.cashfree.com/pg/links');
    expect(seen[0]!.init.headers['x-client-id']).toBe('TEST1234abcd');
    expect(seen[0]!.init.headers['x-client-secret']).toBe(SECRET);
    const sent = JSON.parse(seen[0]!.init.body);
    expect(sent.link_amount).toBe(inv.total);
    expect(sent.customer_details.customer_phone).toBe('9825011111');
    const linkId = sent.link_id as string;

    const raw = JSON.stringify({
      type: 'PAYMENT_LINK_EVENT', version: 1,
      data: { link_id: linkId, link_status: 'PAID', link_amount_paid: String(inv.total), order: { order_amount: String(inv.total), transaction_id: 7001, transaction_status: 'SUCCESS' } },
    });
    const url = `/api/v1/webhooks/payment-gateways/${gw.id}`;
    const post = (body: string, signature: string, ts = '1763000000') => env.app.inject({
      method: 'POST', url, headers: { 'content-type': 'application/json', 'x-webhook-signature': signature, 'x-webhook-timestamp': ts }, payload: body,
    });
    expect((await post(raw, sign('1763000000', raw, 'wrong'))).statusCode).toBe(401);
    const ok = await post(raw, sign('1763000000', raw));
    expect(ok.statusCode, ok.body).toBe(200);
    expect(ok.json().result).toBe('recorded');
    expect((await post(raw, sign('1763000000', raw))).json().result).toBe('duplicate');
    expect((await b.api('GET', `/invoices/${inv.id}`)).body.amountPaid).toBe(inv.total);
    const pays = (await b.api('GET', '/payments?kind=receipt')).body.data as any[];
    expect(pays).toHaveLength(1);
    expect(pays[0].reference).toBe('cf_7001');
    expect((await b.api('GET', `/payment-links/${made.body.id}`)).body.status).toBe('paid');
  });
});
