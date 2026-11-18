import { createHmac } from 'node:crypto';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'kysely';
import { withTenant } from '../src/db/database.ts';
import { setGatewayFetch } from '../src/lib/gateways/razorpay.ts';
import { nextRunAfter, periodRange } from '../src/lib/report-builder.ts';
import { setSmsFetch, sendSms } from '../src/lib/sms.ts';
import { loadConfig } from '../src/config.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { setGatewayFetch(undefined); setSmsFetch(undefined); await teardown(env); });

async function biz() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Extras Traders', name: 'Owner', email: uniqueEmail('px'), password: 'Secret@123', stateCode: '24', businessType: 'wholesale',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  const tid = JSON.parse(Buffer.from((res.body.accessToken as string).split('.')[1]!, 'base64url').toString()).tid as string;
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1', stateCode: '24' })).body;
  const cust = (await api('POST', '/parties', { type: 'customer', name: 'Mehta Steel', phone: '9000000050', email: 'mehta@x.in', gstin: '24AAACM1234A1Z5', stateCode: '24' })).body;
  const item = (await api('POST', '/items', { name: 'Steel rod', sku: 'ROD1', hsnCode: '7214', unit: 'nos', gstRate: 18, salePrice: 1000, purchasePrice: 600, trackStock: false })).body;
  const inv = await api('POST', '/invoices', { locationId: wh.id, partyId: cust.id, lines: [{ itemId: item.id, qty: 1 }] });
  expect(inv.status, JSON.stringify(inv.body)).toBe(201);
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; subtype: string; code: string }[];
  const bank = accounts.find((a) => a.subtype === 'bank')!;
  return { api, companyId, tid, roles, ownerId: me.user.id as string, cust, inv: inv.body, bank, wh };
}

describe('schedule maths', () => {
  it('finds the next daily, weekly and monthly time in India time', () => {
    const after = new Date('2026-11-16T03:00:00Z'); // 08:30 IST, Monday
    expect(nextRunAfter({ frequency: 'daily', weekday: null, monthDay: null, time: '08:00' }, after).toISOString()).toBe('2026-11-17T02:30:00.000Z');
    expect(nextRunAfter({ frequency: 'daily', weekday: null, monthDay: null, time: '09:00' }, after).toISOString()).toBe('2026-11-16T03:30:00.000Z');
    expect(nextRunAfter({ frequency: 'weekly', weekday: 1, monthDay: null, time: '08:00' }, after).toISOString()).toBe('2026-11-23T02:30:00.000Z');
    expect(nextRunAfter({ frequency: 'monthly', weekday: null, monthDay: 5, time: '10:00' }, after).toISOString()).toBe('2026-12-05T04:30:00.000Z');
  });
  it('resolves periods', () => {
    expect(periodRange('previous_month', '2026-11-16')).toEqual({ from: '2026-10-01', to: '2026-10-31' });
    expect(periodRange('previous_day', '2026-11-16')).toEqual({ from: '2026-11-15', to: '2026-11-15' });
  });
});

describe('global search', () => {
  it('finds parties, items and invoices, and respects permissions', async () => {
    const b = await biz();
    const r = await b.api('GET', '/search?q=meh');
    expect(r.status).toBe(200);
    const kinds = (r.body.groups as any[]).map((g) => g.kind);
    expect(kinds).toContain('party');
    expect((r.body.groups as any[]).find((g) => g.kind === 'party').items[0].route).toBe(`/parties/${b.cust.id}`);
    const inv = await b.api('GET', `/search?q=${encodeURIComponent(b.inv.number)}`);
    expect((inv.body.groups as any[]).find((g) => g.kind === 'invoice').items[0].id).toBe(b.inv.id);
    expect(((await b.api('GET', '/search?q=ROD')).body.groups as any[]).some((g) => g.kind === 'item')).toBe(true);
    expect(((await b.api('GET', '/search?q=24AAACM')).body.groups as any[]).some((g) => g.kind === 'party')).toBe(true);
    expect((await b.api('GET', '/search?q=m')).body.groups).toEqual([]);
    // Prefix match ranks before contains.
    await b.api('POST', '/parties', { type: 'customer', name: 'Zed Steel Mehta', stateCode: '24' });
    const ranked = ((await b.api('GET', '/search?q=mehta')).body.groups as any[]).find((g) => g.kind === 'party').items;
    expect(ranked[0].title).toBe('Mehta Steel');
    // A role with parties only sees no invoice group.
    const role = (await b.api('POST', '/roles', { name: 'PartiesOnly', permissions: ['parties.view'] })).body;
    const email = uniqueEmail('po');
    expect((await b.api('POST', '/users', { name: 'Parties only', email, password: 'Secret@123', roleId: role.id })).status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    const lim = client(env.app, li.body.accessToken, b.companyId);
    const lr = await lim('GET', '/search?q=meh');
    expect((lr.body.groups as any[]).map((g) => g.kind)).toEqual(['party']);
  });
});

describe('scheduled reports', () => {
  it('validates, runs now into the outbox with an attachment, and lists history', async () => {
    const b = await biz();
    expect((await b.api('POST', '/scheduled-reports', { name: 'X', report: 'sales_register', frequency: 'weekly', time: '08:00', recipientEmails: ['a@x.in'] })).status).toBe(400);
    expect((await b.api('POST', '/scheduled-reports', { name: 'X', report: 'sales_register', frequency: 'daily', time: '08:00' })).status).toBe(400);
    const made = await b.api('POST', '/scheduled-reports', {
      name: 'Daily sales', report: 'sales_register', frequency: 'daily', time: '08:00', filters: { period: 'month_to_date' },
      recipientEmails: ['boss@x.in'], recipientUserIds: [b.ownerId],
    });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    expect(made.body.nextRunAt).toBeTruthy();
    const run = await b.api('POST', `/scheduled-reports/${made.body.id}/run`);
    expect(run.status, JSON.stringify(run.body)).toBe(200);
    expect(run.body.status).toBe('sent');
    expect(run.body.recipients).toBe(2);
    expect(run.body.rowCount).toBe(1);
    const out = await withTenant(env.db, b.tid, (tx) => sql<any>`select * from notification_outbox where template = 'scheduled_report' and company_id = ${b.companyId}`.execute(tx));
    expect(out.rows).toHaveLength(2);
    const d = out.rows[0].data;
    expect(d.attachments[0].filename).toMatch(/\.csv$/);
    expect(d.attachments[0].content).toContain('Steel');
    expect(d.html).toContain('Sales register');
    const hist = await b.api('GET', `/scheduled-reports/${made.body.id}/runs`);
    expect(hist.body.data).toHaveLength(1);
    const upd = await b.api('PATCH', `/scheduled-reports/${made.body.id}`, { isActive: false });
    expect(upd.body.nextRunAt).toBeNull();
    for (const report of ['profit_loss', 'receivables_ageing', 'stock_valuation', 'gst_summary', 'crm_numbers']) {
      const m = await b.api('POST', '/scheduled-reports', { name: report, report, frequency: 'monthly', monthDay: 3, time: '07:30', recipientEmails: ['c@x.in'] });
      expect(m.status, report + JSON.stringify(m.body)).toBe(201);
      const r = await b.api('POST', `/scheduled-reports/${m.body.id}/run`);
      expect(r.body.status, report + JSON.stringify(r.body)).toBe('sent');
    }
    expect((await b.api('DELETE', `/scheduled-reports/${made.body.id}`)).status).toBe(204);
  });

  it('the scheduler queues a due report once', async () => {
    const b = await biz();
    const made = await b.api('POST', '/scheduled-reports', { name: 'D', report: 'gst_summary', frequency: 'daily', time: '08:00', recipientEmails: ['a@x.in'] });
    await withTenant(env.db, b.tid, (tx) => sql`update scheduled_reports set next_run_at = now() - interval '1 minute' where id = ${made.body.id}`.execute(tx));
    await sql`select scheduled_reports_enqueue()`.execute(env.db);
    await sql`select scheduled_reports_enqueue()`.execute(env.db);
    const jobs = await withTenant(env.db, b.tid, (tx) => sql<any>`select * from jobs where kind = 'report.scheduled' and payload->>'reportId' = ${made.body.id}`.execute(tx));
    expect(jobs.rows).toHaveLength(1);
  });
});

describe('sms', () => {
  it('stores DLT settings, queues an sms and sends through the adapters', async () => {
    const b = await biz();
    expect((await b.api('PATCH', '/sms/settings', { templates: { password_reset: { dltTemplateId: '1107123456789' } } })).status).toBe(400);
    const set = await b.api('PATCH', '/sms/settings', {
      enabled: true, dltEntityId: '1101234567890', senderId: 'ONEMTX',
      templates: { payment_link: { dltTemplateId: '1107123456789', text: 'Pay {#var#} for {#var#}: {#var#}' } },
    });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
    expect(set.body.driver).toBe('log');
    expect(set.body.templates.find((t: any) => t.template === 'payment_link').dltTemplateId).toBe('1107123456789');
    expect((await b.api('POST', '/sms/test', { phone: '9000000050' })).status).toBe(200);
    // Outbox row through notify.
    const { notify } = await import('../src/lib/notify.ts');
    const ids = await withTenant(env.db, b.tid, (tx) => notify(tx, { tenantId: b.tid, companyId: b.companyId }, {
      to: { phone: '9000000050', email: null, channels: ['sms'] }, template: 'payment_link',
      data: { partyName: 'M', invoiceNumber: 'I1', companyName: 'C', amount: 10, url: 'https://x.test/p', smsVars: ['M', 'I1', 'https://x.test/p'] },
    }));
    expect(ids).toHaveLength(1);
    const row = await withTenant(env.db, b.tid, (tx) => sql<any>`select channel, data from notification_outbox where id = ${ids[0]}`.execute(tx));
    expect(row.rows[0].channel).toBe('sms');
    expect(row.rows[0].data.dlt.templateId).toBe('1107123456789');
    // Templates that cannot use SMS are not queued.
    const none = await withTenant(env.db, b.tid, (tx) => notify(tx, { tenantId: b.tid, companyId: b.companyId }, {
      to: { phone: '9000000050', channels: ['sms'] }, template: 'recurring_invoice', data: { partyName: 'M', invoiceNumber: 'I', companyName: 'C', total: 1, invoiceDate: '2026-01-01' },
    }));
    expect(none).toHaveLength(0);

    const calls: { url: string; body: any; headers: any }[] = [];
    setSmsFetch((async (url: string, init: any) => { calls.push({ url, body: JSON.parse(init.body), headers: init.headers }); return new Response('{"type":"success","message":"abc"}', { status: 200 }); }) as never);
    const cfg = loadConfig({ ...process.env, SMS_DRIVER: 'msg91', SMS_AUTH_KEY: 'k' });
    expect(await sendSms({ to: '9000000050', text: 't', dlt: { templateId: 'T1' }, variables: ['a', 'b'] }, cfg)).toBe('abc');
    expect(calls[0]!.body).toEqual({ flow_id: 'T1', template_id: 'T1', short_url: '0', recipients: [{ mobiles: '919000000050', VAR1: 'a', VAR2: 'b' }] });
    expect(calls[0]!.headers.authkey).toBe('k');
    const cfg2 = loadConfig({ ...process.env, SMS_DRIVER: 'http', SMS_HTTP_URL: 'https://sms.test/send', SMS_HTTP_BODY: '{"to":"{to}","m":"{message}","t":"{templateId}"}' });
    await sendSms({ to: '9000000050', text: 'hi "x"', dlt: { templateId: 'T2' } }, cfg2);
    expect(calls[1]!.body).toEqual({ to: '919000000050', m: 'hi "x"', t: 'T2' });
    setSmsFetch(undefined);
  });
});

describe('online payment links', () => {
  const SECRET = 'whsec_test_123456';
  const sign = (raw: string, secret = SECRET) => createHmac('sha256', secret).update(raw).digest('hex');

  it('creates a link, takes a signed paid webhook once, posts the fee and refuses bad signatures', async () => {
    const b = await biz();
    // Not set up yet.
    expect((await b.api('POST', `/invoices/${b.inv.id}/payment-links`, {})).status).toBe(409);
    const seen: any[] = [];
    setGatewayFetch((async (url: string, init: any) => {
      seen.push({ url, init });
      return new Response(JSON.stringify({ id: 'plink_TEST1', short_url: 'https://rzp.io/i/abc', status: 'created' }), { status: 200 });
    }) as never);
    expect((await b.api('PATCH', '/payment-gateways/razorpay', { isActive: true })).status).toBe(400);
    const set = await b.api('PATCH', '/payment-gateways/razorpay', {
      keyId: 'rzp_test_abc12345', keySecret: 'secretsecret1', webhookSecret: SECRET, accountId: b.bank.id, isActive: true,
    });
    expect(set.status, JSON.stringify(set.body)).toBe(200);
    expect(set.body.mode).toBe('test');
    expect(JSON.stringify(set.body)).not.toContain('secretsecret1');
    const gw = (await b.api('GET', '/payment-gateways')).body.data[0];
    expect(gw.webhookUrl).toContain(`/webhooks/payment-gateways/${gw.id}`);

    const made = await b.api('POST', `/invoices/${b.inv.id}/payment-links`, { expiresInDays: 3 });
    expect(made.status, JSON.stringify(made.body)).toBe(201);
    expect(made.body.shortUrl).toBe('https://rzp.io/i/abc');
    expect(made.body.whatsappUrl).toContain('https://wa.me/919000000050');
    const sent = JSON.parse(seen[0].init.body);
    expect(sent.amount).toBe(Math.round(b.inv.total * 100));
    expect(sent.currency).toBe('INR');
    expect(sent.customer.contact).toBe('+919000000050');
    expect(seen[0].init.headers.Authorization).toBe(`Basic ${Buffer.from('rzp_test_abc12345:secretsecret1').toString('base64')}`);
    // Same open link is returned again.
    expect((await b.api('POST', `/invoices/${b.inv.id}/payment-links`, {})).body.id).toBe(made.body.id);
    expect((await b.api('POST', `/payment-links/${made.body.id}/send`, { channels: ['email', 'whatsapp'] })).body.queued).toBe(2);

    const event = JSON.stringify({
      event: 'payment_link.paid',
      payload: {
        payment_link: { entity: { id: 'plink_TEST1', reference_id: 'x', amount_paid: Math.round(b.inv.total * 100) } },
        payment: { entity: { id: 'pay_ABC1', amount: Math.round(b.inv.total * 100), fee: 2360, tax: 360 } },
      },
    });
    const url = `/api/v1/webhooks/payment-gateways/${gw.id}`;
    const post = (raw: string, sig: string) => env.app.inject({ method: 'POST', url, headers: { 'content-type': 'application/json', 'x-razorpay-signature': sig }, payload: raw });
    const bad = await post(event, sign(event, 'wrong-secret'));
    expect(bad.statusCode).toBe(401);
    expect((await b.api('GET', `/invoices/${b.inv.id}`)).body.amountPaid).toBe(0);
    const ok = await post(event, sign(event));
    expect(ok.statusCode, ok.body).toBe(200);
    expect(ok.json().result).toBe('recorded');
    const again = await post(event, sign(event));
    expect(again.json().result).toBe('duplicate');

    const inv = (await b.api('GET', `/invoices/${b.inv.id}`)).body;
    expect(inv.amountPaid).toBe(b.inv.total);
    const link = (await b.api('GET', `/payment-links/${made.body.id}`)).body;
    expect(link.status).toBe('paid');
    expect(link.fee).toBe(23.6);
    expect(link.paymentId).toBeTruthy();
    const pays = (await b.api('GET', '/payments?kind=receipt')).body.data as any[];
    expect(pays).toHaveLength(1);
    expect(pays[0].mode).toBe('upi');
    expect(pays[0].reference).toBe('pay_ABC1');
    const charges = await withTenant(env.db, b.tid, (tx) => sql<any>`select sum(jl.debit)::float8 as d from journal_lines jl join accounts a on a.id = jl.account_id
      where a.company_id = ${b.companyId} and a.code = '6070'`.execute(tx));
    expect(charges.rows[0].d).toBe(23.6);
    const list = await b.api('GET', '/payment-links?status=paid');
    expect(list.body.total).toBe(1);
    // Nothing is due now.
    expect((await b.api('POST', `/invoices/${b.inv.id}/payment-links`, {})).status).toBe(409);
    setGatewayFetch(undefined);
  });

  it('refuses a provider error cleanly', async () => {
    const b = await biz();
    setGatewayFetch((async () => new Response(JSON.stringify({ error: { description: 'Authentication failed' } }), { status: 401 })) as never);
    await b.api('PATCH', '/payment-gateways/razorpay', { keyId: 'rzp_test_abc12345', keySecret: 'secretsecret1', webhookSecret: SECRET, accountId: b.bank.id, isActive: true });
    const r = await b.api('POST', `/invoices/${b.inv.id}/payment-links`, {});
    expect(r.status).toBe(502);
    expect(r.body.error.code).toBe('GATEWAY_ERROR');
    expect((await b.api('GET', '/payment-links')).body.total).toBe(0);
    setGatewayFetch(undefined);
  });
});
