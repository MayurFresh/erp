import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { loadConfig } from '../src/config.ts';
import { runJobsOnce } from '../src/lib/jobs.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

type Api = ReturnType<typeof client>;
const PASSWORD = 'Secret@123';

async function biz() {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Controls Co', name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const me = (await client(env.app, signup.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, signup.body.accessToken, companyId);
  const ownerId = me.user?.id ?? me.id;
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const role = (n: string) => roles.find((r) => r.name === n)!.id;
  const userAs = async (name: string, roleName: string) => {
    const email = uniqueEmail(name.toLowerCase());
    const created = await api('POST', '/users', { name, email, password: PASSWORD, roleId: role(roleName) });
    expect(created.status).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    expect(login.status).toBe(200);
    return { api: client(env.app, login.body.accessToken, companyId), id: created.body.id as string };
  };
  const accountant = await userAs('Anita', 'Accountant');
  const admin = await userAs('Adam', 'Company Admin');
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1' })).body;
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; code: string; type: string }[];
  const acct = (code: string) => accounts.find((a) => a.code === code)!.id;
  const service = (await api('POST', '/items', { name: 'Service', sku: 'SRV', hsnCode: '9954', unit: 'job', gstRate: 18, salePrice: 1000, purchasePrice: 1000, trackStock: false })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const customer = (await api('POST', '/parties', { type: 'customer', name: 'Customer One', stateCode: '24' })).body;
  return { token: signup.body.accessToken as string, api, ownerId: ownerId as string, role, accountant, admin, wh, acct, service, vendor, customer, companyId };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const rule = (b: Biz, docType: string, levels: object[], extra: Record<string, unknown> = {}) =>
  b.api('POST', '/approval-rules', { docType, name: `${docType} rule`, minAmount: 1000, levels, ...extra });

const bodies = (b: Biz) => ({
  purchase: ['POST', '/purchases', { locationId: b.wh.id, partyId: b.vendor.id, lines: [{ itemId: b.service.id, qty: 1, rate: 5000 }] }],
  payment: ['POST', '/payments', { kind: 'payment', partyId: b.vendor.id, accountId: b.acct('1010'), amount: 7000, mode: 'bank' }],
  expense: ['POST', '/expenses', { locationId: b.wh.id, accountId: b.acct('6000'), description: 'Rent', amount: 4000, paidFromAccountId: b.acct('1010') }],
  journal: ['POST', '/journals', { narration: 'Capital intro', lines: [
    { accountId: b.acct('1010'), debit: 9000 }, { accountId: b.acct('3000'), credit: 9000 }] }],
} as Record<string, ['POST', string, object]>);

async function invoiceAndNote(b: Biz) {
  const inv = (await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.service.id, qty: 5, rate: 1000 }] })).body;
  return ['POST', '/credit-notes', { invoiceId: inv.id, reason: 'Service credit', lines: [{ invoiceLineId: inv.lines[0].id, qty: 2 }] }] as ['POST', string, object];
}

describe('approval rules', () => {
  it('creates, lists, edits and deactivates rules', async () => {
    const b = await biz();
    const created = await rule(b, 'payment', [{ approverRoleId: b.role('Owner') }]);
    expect(created.status).toBe(201);
    expect(created.body).toMatchObject({ docType: 'payment', minAmount: 1000, isActive: true, levels: [{ level: 1, label: 'Owner' }] });

    const patched = await b.api('PATCH', `/approval-rules/${created.body.id}`, {
      name: 'Big payments', minAmount: 2500, levels: [{ approverRoleId: b.role('Company Admin') }, { approverUserId: b.ownerId }],
    });
    expect(patched.status).toBe(200);
    expect(patched.body.levels).toHaveLength(2);
    expect(patched.body.levels[0].label).toBe('Company Admin');
    expect(patched.body).toMatchObject({ name: 'Big payments', minAmount: 2500 });

    const list = await b.api('GET', '/approval-rules?docType=payment');
    expect(list.body.data).toHaveLength(1);
    expect((await b.api('DELETE', `/approval-rules/${created.body.id}`)).status).toBe(204);
    expect((await b.api('GET', '/approval-rules')).body.data[0].isActive).toBe(false);
  });

  it('validates levels and needs approvals.manage', async () => {
    const b = await biz();
    expect((await rule(b, 'payment', [])).status).toBe(400);
    const six = Array.from({ length: 6 }, () => ({ approverRoleId: b.role('Owner') }));
    expect((await rule(b, 'payment', six)).status).toBe(400);
    expect((await rule(b, 'payment', [{ approverRoleId: '00000000-0000-4000-8000-000000000000' }])).status).toBe(400);
    expect((await rule(b, 'payment', [{ approverRoleId: b.role('Owner') }], { locationId: '00000000-0000-4000-8000-000000000000' })).status).toBe(400);
    expect((await b.accountant.api('POST', '/approval-rules', { docType: 'payment', name: 'x', minAmount: 1, levels: [{ approverRoleId: b.role('Owner') }] })).status).toBe(403);
  });
});

describe('approval flow', () => {
  it('holds each covered document as a request and creates it on final approval', async () => {
    const b = await biz();
    const note = await invoiceAndNote(b);
    for (const t of ['purchase', 'payment', 'expense', 'journal', 'credit_note']) {
      expect((await rule(b, t, [{ approverRoleId: b.role('Owner') }])).status).toBe(201);
    }
    const all = { ...bodies(b), credit_note: note };
    const requests: Record<string, string> = {};
    for (const [t, [m, url, body]] of Object.entries(all)) {
      const res = await b.accountant.api(m, url, body);
      expect(res.status, t).toBe(202);
      expect(res.body.approvalRequest).toMatchObject({ docType: t, status: 'pending', currentLevel: 1, totalLevels: 1 });
      expect(res.body.approvalRequest.number).toMatch(/^APR/);
      requests[t] = res.body.approvalRequest.id;
    }
    // Nothing was created yet.
    expect((await b.api('GET', '/purchases')).body.total).toBe(0);
    expect((await b.api('GET', '/payments')).body.total).toBe(0);
    expect((await b.api('GET', '/expenses')).body.total).toBe(0);
    expect((await b.api('GET', '/credit-notes')).body.total).toBe(0);
    expect((await b.api('GET', '/journals?limit=100')).body.data.filter((e: any) => e.voucherType === 'journal')).toHaveLength(0);

    expect((await b.api('GET', '/approvals/count')).body).toEqual({ awaitingMe: 5, mine: 0 });
    expect((await b.accountant.api('GET', '/approvals/count')).body).toEqual({ awaitingMe: 0, mine: 5 });
    const awaiting = (await b.api('GET', '/approvals')).body;
    expect(awaiting.total).toBe(5);

    for (const [t, id] of Object.entries(requests)) {
      const done = await b.api('POST', `/approvals/${id}/approve`, { comment: 'ok' });
      expect(done.status, t).toBe(200);
      expect(done.body.status).toBe('approved');
      expect(done.body.document.id).toBeTruthy();
      expect(done.body.actions.map((a: any) => a.action)).toEqual(['submitted', 'approved']);
    }
    // Created as the requester, with journals.
    const purchase = (await b.api('GET', '/purchases')).body.data[0];
    expect(purchase.createdBy.name).toBe('Anita');
    expect((await b.api('GET', '/payments')).body.total).toBe(1);
    expect((await b.api('GET', '/expenses')).body.total).toBe(1);
    expect((await b.api('GET', '/credit-notes')).body.total).toBe(1);
    expect((await b.api('GET', '/journals?limit=100')).body.data.filter((e: any) => e.voucherType === 'journal')).toHaveLength(1);
    const tb = (await b.api('GET', '/reports/trial-balance')).body;
    expect(tb.totalDebit).toBe(tb.totalCredit);
    expect((await b.accountant.api('GET', '/approvals?scope=mine&status=approved')).body.total).toBe(5);
  });

  it('creates documents below the threshold at once and never gates receipts', async () => {
    const b = await biz();
    await rule(b, 'payment', [{ approverRoleId: b.role('Owner') }], { minAmount: 10000 });
    const small = await b.accountant.api('POST', '/payments', { kind: 'payment', partyId: b.vendor.id, accountId: b.acct('1010'), amount: 7000, mode: 'bank' });
    expect(small.status).toBe(201);
    const receipt = await b.accountant.api('POST', '/payments', { kind: 'receipt', partyId: b.customer.id, accountId: b.acct('1010'), amount: 50000, mode: 'bank' });
    expect(receipt.status).toBe(201);
    const big = await b.accountant.api('POST', '/payments', { kind: 'payment', partyId: b.vendor.id, accountId: b.acct('1010'), amount: 10000, mode: 'bank' });
    expect(big.status).toBe(202);
    // A request that would fail is refused now, not queued.
    const bad = await b.accountant.api('POST', '/payments', { kind: 'payment', partyId: b.customer.id, accountId: b.acct('1010'), amount: 20000, mode: 'bank' });
    expect(bad.status).toBe(400);
  });

  it('walks multi-level approvals in order and refuses the wrong approver', async () => {
    const b = await biz();
    await rule(b, 'payment', [{ approverRoleId: b.role('Company Admin') }, { approverRoleId: b.role('Owner') }]);
    const sub = await b.accountant.api(...bodies(b).payment!);
    expect(sub.status).toBe(202);
    const id = sub.body.approvalRequest.id;
    expect(sub.body.approvalRequest.levels.map((l: any) => l.label)).toEqual(['Company Admin', 'Owner']);

    expect((await b.api('GET', '/approvals')).body.total).toBe(0);
    expect((await b.admin.api('GET', '/approvals')).body.total).toBe(1);
    const early = await b.api('POST', `/approvals/${id}/approve`, {});
    expect(early.status).toBe(403);

    const l1 = await b.admin.api('POST', `/approvals/${id}/approve`, { comment: 'level 1' });
    expect(l1.status).toBe(200);
    expect(l1.body).toMatchObject({ status: 'pending', currentLevel: 2 });
    expect((await b.api('GET', '/payments')).body.total).toBe(0);
    expect((await b.admin.api('GET', '/approvals')).body.total).toBe(0);
    expect((await b.api('GET', '/approvals')).body.total).toBe(1);

    const l2 = await b.api('POST', `/approvals/${id}/approve`, {});
    expect(l2.status).toBe(200);
    expect(l2.body.status).toBe('approved');
    expect((await b.api('GET', '/payments')).body.total).toBe(1);
    const again = await b.api('POST', `/approvals/${id}/approve`, {});
    expect(again.status).toBe(409);
    expect(again.body.error.code).toBe('NOT_PENDING');
  });

  it('stops one person approving two levels and the requester approving their own request', async () => {
    const b = await biz();
    await rule(b, 'expense', [{ approverRoleId: b.role('Owner') }, { approverRoleId: b.role('Owner') }]);
    const sub = await b.accountant.api(...bodies(b).expense!);
    const id = sub.body.approvalRequest.id;
    expect((await b.api('POST', `/approvals/${id}/approve`, {})).status).toBe(200);
    const second = await b.api('POST', `/approvals/${id}/approve`, {});
    expect(second.status).toBe(403);
    expect(second.body.error.code).toBe('ALREADY_ACTED');

    const mine = await b.api(...bodies(b).expense!);
    expect(mine.status).toBe(202);
    const own = await b.api('POST', `/approvals/${mine.body.approvalRequest.id}/approve`, {});
    expect(own.status).toBe(403);
    expect(own.body.error.code).toBe('SELF_APPROVAL');
    expect((await b.api('POST', `/approvals/${mine.body.approvalRequest.id}/reject`, { comment: 'nope' })).status).toBe(403);
  });

  it('rejects with a reason and lets only the requester cancel', async () => {
    const b = await biz();
    await rule(b, 'journal', [{ approverRoleId: b.role('Owner') }]);
    const first = (await b.accountant.api(...bodies(b).journal!)).body.approvalRequest.id;
    expect((await b.api('POST', `/approvals/${first}/reject`, {})).status).toBe(400);
    const rej = await b.api('POST', `/approvals/${first}/reject`, { comment: 'Wrong accounts' });
    expect(rej.status).toBe(200);
    expect(rej.body.status).toBe('rejected');
    expect(rej.body.actions.at(-1)).toMatchObject({ action: 'rejected', comment: 'Wrong accounts' });
    expect((await b.api('POST', `/approvals/${first}/approve`, {})).status).toBe(409);
    expect((await b.api('GET', '/journals?limit=100')).body.data.filter((e: any) => e.voucherType === 'journal')).toHaveLength(0);

    const second = (await b.accountant.api(...bodies(b).journal!)).body.approvalRequest.id;
    expect((await b.api('POST', `/approvals/${second}/cancel`, {})).status).toBe(404);
    const cancelled = await b.accountant.api('POST', `/approvals/${second}/cancel`, {});
    expect(cancelled.status).toBe(200);
    expect(cancelled.body.status).toBe('cancelled');
    expect((await b.accountant.api('POST', `/approvals/${second}/cancel`, {})).status).toBe(409);
    expect((await b.api('GET', '/approvals/count')).body.awaitingMe).toBe(0);
  });

  it('re-validates at final approval and keeps the request pending when it fails', async () => {
    const b = await biz();
    await rule(b, 'expense', [{ approverRoleId: b.role('Owner') }]);
    const sub = await b.accountant.api(...bodies(b).expense!);
    const id = sub.body.approvalRequest.id;
    expect((await b.api('PATCH', '/company', { booksLockedUntil: new Date().toISOString().slice(0, 10) })).status).toBe(200);
    const res = await b.api('POST', `/approvals/${id}/approve`, {});
    expect(res.status).toBe(409);
    const after = await b.api('GET', `/approvals/${id}`);
    expect(after.body).toMatchObject({ status: 'pending', currentLevel: 1 });
    expect(after.body.actions.map((a: any) => a.action)).toEqual(['submitted']);
    expect((await b.api('GET', '/expenses')).body.total).toBe(0);
  });

  it('shows a request only to people involved or with approvals.view', async () => {
    const b = await biz();
    await rule(b, 'payment', [{ approverRoleId: b.role('Owner') }]);
    const id = (await b.accountant.api(...bodies(b).payment!)).body.approvalRequest.id;
    expect((await b.accountant.api('GET', `/approvals/${id}`)).status).toBe(200);
    expect((await b.api('GET', `/approvals/${id}`)).body.canAct).toBe(true);
    expect((await b.accountant.api('GET', `/approvals/${id}`)).body.canAct).toBe(false);
    expect((await b.accountant.api('GET', '/approvals?scope=all')).status).toBe(200);
    expect((await b.admin.api('GET', '/approvals?scope=all')).status).toBe(200);
    expect((await b.api('GET', '/approvals/00000000-0000-4000-8000-000000000000')).status).toBe(404);
  });
});

describe('custom fields', () => {
  it('manages definitions', async () => {
    const b = await biz();
    const f = await b.api('POST', '/custom-fields', { entity: 'item', key: 'brand', label: 'Brand', type: 'text', showOnPrint: true });
    expect(f.status).toBe(201);
    expect(f.body).toMatchObject({ key: 'brand', type: 'text', showOnPrint: true, isActive: true });
    expect((await b.api('POST', '/custom-fields', { entity: 'item', key: 'brand', label: 'Again', type: 'text' })).status).toBe(409);
    expect((await b.api('POST', '/custom-fields', { entity: 'party', key: 'region', label: 'Region', type: 'select' })).status).toBe(400);
    expect((await b.api('POST', '/custom-fields', { entity: 'party', key: 'Bad Key', label: 'x', type: 'text' })).status).toBe(400);
    const patched = await b.api('PATCH', `/custom-fields/${f.body.id}`, { label: 'Make', required: false });
    expect(patched.body.label).toBe('Make');
    expect((await b.api('GET', '/custom-fields?entity=item')).body.data).toHaveLength(1);
    expect((await b.accountant.api('POST', '/custom-fields', { entity: 'item', key: 'zz', label: 'x', type: 'text' })).status).toBe(403);
  });

  it('validates values on items, parties, invoices, purchases and projects, and exports them', async () => {
    const b = await biz();
    await b.api('POST', '/custom-fields', { entity: 'item', key: 'brand', label: 'Brand', type: 'text', required: true });
    await b.api('POST', '/custom-fields', { entity: 'party', key: 'region', label: 'Region', type: 'select', options: ['North', 'South'] });
    await b.api('POST', '/custom-fields', { entity: 'invoice', key: 'po_number', label: 'PO number', type: 'text' });
    await b.api('POST', '/custom-fields', { entity: 'purchase', key: 'grn', label: 'GRN', type: 'number' });
    await b.api('POST', '/custom-fields', { entity: 'project', key: 'zone', label: 'Zone', type: 'text' });

    const item = { name: 'Widget', hsnCode: '9954', unit: 'nos', gstRate: 18, salePrice: 10, trackStock: false };
    expect((await b.api('POST', '/items', item)).status).toBe(400); // brand is required
    expect((await b.api('POST', '/items', { ...item, custom: { brand: 'Acme', nope: 'x' } })).status).toBe(400);
    const ok = await b.api('POST', '/items', { ...item, custom: { brand: 'Acme' } });
    expect(ok.status).toBe(201);
    expect(ok.body.custom).toEqual({ brand: 'Acme' });
    const upd = await b.api('PATCH', `/items/${ok.body.id}`, { custom: { brand: 'Zen' } });
    expect(upd.body.custom).toEqual({ brand: 'Zen' });
    expect((await b.api('PATCH', `/items/${ok.body.id}`, { custom: { brand: null } })).status).toBe(400);

    expect((await b.api('POST', '/parties', { type: 'customer', name: 'P1', custom: { region: 'West' } })).status).toBe(400);
    const party = await b.api('POST', '/parties', { type: 'customer', name: 'P2', stateCode: '24', custom: { region: 'North' } });
    expect(party.status).toBe(201);
    expect(party.body.custom).toEqual({ region: 'North' });

    const inv = await b.api('POST', '/invoices', {
      locationId: b.wh.id, partyId: party.body.id, custom: { po_number: 'PO-1' }, lines: [{ itemId: b.service.id, qty: 1, rate: 100 }],
    });
    expect(inv.status).toBe(201);
    expect(inv.body.custom).toEqual({ po_number: 'PO-1' });
    expect((await b.api('GET', `/invoices/${inv.body.id}`)).body.custom).toEqual({ po_number: 'PO-1' });

    const pur = await b.api('POST', '/purchases', {
      locationId: b.wh.id, partyId: b.vendor.id, custom: { grn: 'abc' }, lines: [{ itemId: b.service.id, qty: 1, rate: 100 }],
    });
    expect(pur.status).toBe(400);
    const pur2 = await b.api('POST', '/purchases', {
      locationId: b.wh.id, partyId: b.vendor.id, custom: { grn: 77 }, lines: [{ itemId: b.service.id, qty: 1, rate: 100 }],
    });
    expect(pur2.status).toBe(201);
    expect(pur2.body.custom).toEqual({ grn: 77 });

    const proj = await b.api('POST', '/projects', { name: 'Tower', locationId: b.wh.id, custom: { zone: 'A' } });
    if (proj.status === 201) expect(proj.body.custom).toEqual({ zone: 'A' });

    const csv = async (d: string) => {
      const res = await env.app.inject({ method: 'GET', url: `/api/v1/export/${d}`, headers: { authorization: (b.api as any).__none ?? '' } });
      return res;
    };
    void csv;
  });

  it('adds custom columns to the CSV export', async () => {
    const signup = await client(env.app)('POST', '/auth/signup', {
      businessName: 'Export Co', name: 'Owner', email: uniqueEmail('exp'), password: PASSWORD, stateCode: '24',
    });
    const token = signup.body.accessToken as string;
    const me = (await client(env.app, token)('GET', '/me')).body;
    const api = client(env.app, token, me.companies[0].id);
    await api('POST', '/custom-fields', { entity: 'item', key: 'brand', label: 'Brand', type: 'text' });
    await api('POST', '/items', { name: 'Widget', hsnCode: '9954', unit: 'nos', gstRate: 18, salePrice: 10, trackStock: false, custom: { brand: 'Acme' } });
    const res = await env.app.inject({
      method: 'GET', url: '/api/v1/export/items', headers: { authorization: `Bearer ${token}`, 'x-company-id': me.companies[0].id },
    });
    expect(res.statusCode).toBe(200);
    const lines = res.body.trim().split('\n');
    expect(lines[0]).toContain('Brand');
    expect(lines[1]).toContain('Acme');
  });
});

describe('cost centres', () => {
  it('manages cost centres', async () => {
    const b = await biz();
    const ret = await b.api('POST', '/cost-centres', { code: 'RET', name: 'Retail' });
    expect(ret.status).toBe(201);
    expect((await b.api('POST', '/cost-centres', { code: 'ret', name: 'Dup' })).status).toBe(409);
    const child = await b.api('POST', '/cost-centres', { code: 'RET-N', name: 'Retail North', parentId: ret.body.id });
    expect(child.body.parentId).toBe(ret.body.id);
    expect((await b.api('PATCH', `/cost-centres/${ret.body.id}`, { parentId: child.body.id })).status).toBe(400);
    expect((await b.api('PATCH', `/cost-centres/${child.body.id}`, { isActive: false })).status).toBe(200);
    expect((await b.api('GET', '/cost-centres')).body.data).toHaveLength(1);
    expect((await b.api('GET', '/cost-centres?includeInactive=true')).body.data).toHaveLength(2);
    expect((await client(env.app)('POST', '/cost-centres', { code: 'X', name: 'X' })).status).toBe(401);
  });

  it('tags documents, reports by cost centre and filters the P&L', async () => {
    const b = await biz();
    const ret = (await b.api('POST', '/cost-centres', { code: 'RET', name: 'Retail' })).body;
    const prj = (await b.api('POST', '/cost-centres', { code: 'PRJ', name: 'Projects' })).body;
    const inv = await b.api('POST', '/invoices', {
      locationId: b.wh.id, partyId: b.customer.id, costCentreId: ret.id, lines: [{ itemId: b.service.id, qty: 10, rate: 1000 }],
    });
    expect(inv.status).toBe(201);
    expect(inv.body.costCentreId).toBe(ret.id);
    await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, costCentreId: prj.id, lines: [{ itemId: b.service.id, qty: 4, rate: 1000 }] });
    await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.service.id, qty: 1, rate: 1000 }] });
    const exp = await b.api('POST', '/expenses', {
      locationId: b.wh.id, accountId: b.acct('6000'), description: 'Rent', amount: 3000, paidFromAccountId: b.acct('1010'), costCentreId: ret.id,
    });
    expect(exp.body.costCentreId).toBe(ret.id);
    const pur = await b.api('POST', '/purchases', { locationId: b.wh.id, partyId: b.vendor.id, costCentreId: prj.id, lines: [{ itemId: b.service.id, qty: 1, rate: 2000 }] });
    expect(pur.body.costCentreId).toBe(prj.id);
    expect((await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, costCentreId: '00000000-0000-4000-8000-000000000000', lines: [{ itemId: b.service.id, qty: 1 }] })).status).toBe(400);

    const rep = (await b.api('GET', '/reports/cost-centres')).body;
    const row = (code: string) => rep.rows.find((r: any) => r.code === code);
    expect(row('RET')).toMatchObject({ income: 10000, expense: 3000, net: 7000 });
    expect(row('PRJ').income).toBe(4000);
    expect(rep.rows.find((r: any) => r.costCentreId === null)?.income).toBe(1000);
    expect(rep.totals.income).toBe(15000);

    const pl = (await b.api('GET', `/reports/profit-loss?costCentreId=${ret.id}`)).body;
    expect(pl.revenue.total).toBe(10000);
    expect(pl.netProfit).toBe(7000);
    expect((await b.api('GET', '/reports/profit-loss')).body.revenue.total).toBe(15000);
  });

  it('tags manual journal lines and enforces costCentreRequired', async () => {
    const b = await biz();
    const cc = (await b.api('POST', '/cost-centres', { code: 'HO', name: 'Head office' })).body;
    const lines = (centre: string | null, onBalanceSheet = false) => [
      { accountId: b.acct('6000'), debit: 500, costCentreId: onBalanceSheet ? undefined : centre },
      { accountId: b.acct('1010'), credit: 500, costCentreId: onBalanceSheet ? centre : undefined },
    ];
    const ok = await b.api('POST', '/journals', { narration: 'Tagged cost', lines: lines(cc.id) });
    expect(ok.status).toBe(201);
    expect(ok.body.lines[0].costCentreId).toBe(cc.id);
    expect(ok.body.lines[1].costCentreId).toBeNull();
    expect((await b.api('POST', '/journals', { narration: 'Bad tag', lines: lines(cc.id, true) })).status).toBe(400);

    expect((await b.api('PATCH', '/company', { costCentreRequired: true })).status).toBe(200);
    const missing = await b.api('POST', '/journals', { narration: 'Untagged', lines: lines(null) });
    expect(missing.status).toBe(400);
    const inv = await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, lines: [{ itemId: b.service.id, qty: 1 }] });
    expect(inv.status).toBe(400);
    expect(inv.body.error.details.costCentreId).toBe('Required');
    expect((await b.api('POST', '/expenses', { locationId: b.wh.id, accountId: b.acct('6000'), description: 'Rent', amount: 100, paidFromAccountId: b.acct('1010') })).status).toBe(400);
    expect((await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, costCentreId: cc.id, lines: [{ itemId: b.service.id, qty: 1 }] })).status).toBe(201);
  });

  it('defaults a credit note to its invoice cost centre', async () => {
    const b = await biz();
    const cc = (await b.api('POST', '/cost-centres', { code: 'RET', name: 'Retail' })).body;
    const inv = (await b.api('POST', '/invoices', { locationId: b.wh.id, partyId: b.customer.id, costCentreId: cc.id, lines: [{ itemId: b.service.id, qty: 5, rate: 1000 }] })).body;
    const note = await b.api('POST', '/credit-notes', { invoiceId: inv.id, reason: 'Return', lines: [{ invoiceLineId: inv.lines[0].id, qty: 2 }] });
    expect(note.status).toBe(201);
    expect(note.body.costCentreId).toBe(cc.id);
    const rep = (await b.api('GET', '/reports/cost-centres')).body;
    expect(rep.rows.find((r: any) => r.code === 'RET').income).toBe(3000);
  });
});

describe('csv import', () => {
  const job = async (api: Api, id: string) => (await api('GET', `/imports/${id}`)).body;
  const run = () => runJobsOnce({ db: env.db, config: loadConfig({ ...process.env, DATABASE_URL: process.env.TEST_DATABASE_URL, LOG_LEVEL: 'silent' }), log: env.app.log as never });
  const commit = async (api: Api, id: string) => {
    const res = await api('POST', `/imports/${id}/commit`);
    expect(res.status).toBe(202);
    expect(res.body.status).toBe('queued');
    for (let i = 0; i < 5; i++) await run();
    return job(api, id);
  };

  it('serves templates', async () => {
    const b = await biz();
    const t = await env.app.inject({ method: 'GET', url: '/api/v1/imports/templates/items', headers: { authorization: `Bearer ${b.token}`, 'x-company-id': b.companyId } });
    expect(t.statusCode).toBe(200);
    expect(t.headers['content-type']).toContain('text/csv');
    expect(t.body.split('\n')[0]).toContain('name');
    expect((await b.api('GET', '/imports/templates/bogus')).status).toBe(400);
  });

  it('imports items, with a failing row first and then fixed', async () => {
    const b = await biz();
    await b.api('POST', '/custom-fields', { entity: 'item', key: 'brand', label: 'Brand', type: 'text' });
    const header = 'Name, SKU, HSN, Unit, GST Rate, Sale Price, Purchase Price, Track Stock, custom.brand\n';
    const bad = await b.api('POST', '/imports', { kind: 'items', fileName: 'items.csv', csv: `${header}Bolt,BLT,7318,nos,18,5,3,yes,Fasco\nNut,NUT,7318,nos,17,2,1,yes,\n,NUT2,7318,nos,18,2,1,maybe,\nBolt,BLT,7318,nos,18,5,3,yes,\n` });
    expect(bad.status).toBe(201);
    expect(bad.body).toMatchObject({ status: 'invalid', totalRows: 4, validRows: 1 });
    const cols = bad.body.errors.map((e: any) => `${e.row}:${e.column}`);
    expect(cols).toContain('2:gstRate');
    expect(cols).toContain('3:name');
    expect(cols).toContain('3:trackStock');
    expect(cols).toContain('4:sku');
    expect((await b.api('POST', `/imports/${bad.body.id}/commit`)).status).toBe(409);

    // Tab separated, as pasted from Excel.
    const tsv = 'name\tunit\tgstRate\tsku\ncustom.brand\n'.split('\n')[0] + '\n';
    void tsv;
    const good = await b.api('POST', '/imports', { kind: 'items', csv: `name\tsku\thsn\tunit\tgstRate\tsalePrice\tcustom.brand\nBolt\tBLT\t7318\tnos\t18\t5\tFasco\nNut\tNUT\t7318\tnos\t18\t2\t\n` });
    expect(good.body).toMatchObject({ status: 'validated', totalRows: 2, validRows: 2 });
    expect(good.body.preview).toHaveLength(2);
    expect((await b.api('GET', '/items')).body.total).toBe(1); // only the service item; nothing written yet
    const done = await commit(b.api, good.body.id);
    expect(done, JSON.stringify(done)).toMatchObject({ status: 'done', result: { created: 2, updated: 0, skipped: 0 } });
    expect(done.finishedAt).toBeTruthy();
    const items = (await b.api('GET', '/items?limit=50')).body.data as any[];
    expect(items.find((i) => i.sku === 'BLT').custom).toEqual({ brand: 'Fasco' });
    expect((await b.api('GET', '/imports')).body.total).toBe(2);

    // Same file again: already exists, unless updateExisting.
    const dup = await b.api('POST', '/imports', { kind: 'items', csv: 'name,sku,unit,gstRate,salePrice\nBolt,BLT,nos,18,6\n' });
    expect(dup.body.status).toBe('invalid');
    expect(dup.body.errors[0].message).toMatch(/exists/i);
    const upd = await b.api('POST', '/imports', { kind: 'items', csv: 'name,sku,unit,gstRate,salePrice\nBolt,BLT,nos,18,6\n', options: { updateExisting: true } });
    expect(upd.body.status).toBe('validated');
    expect((await commit(b.api, upd.body.id)).result).toEqual({ created: 0, updated: 1, skipped: 0 });
    expect(((await b.api('GET', '/items?limit=50')).body.data as any[]).find((i) => i.sku === 'BLT').salePrice).toBe(6);
  });

  it('imports parties with opening balances', async () => {
    const b = await biz();
    await b.api('POST', '/custom-fields', { entity: 'party', key: 'region', label: 'Region', type: 'select', options: ['North', 'South'] });
    const csv = 'type,name,gstin,stateCode,creditDays,openingBalance,openingType,custom.region\n'
      + 'customer,Alpha Traders,,24,30,25000,dr,North\nvendor,Beta Steels,,27,45,18000,cr,South\nboth,Gamma,,24,,,,\n';
    expect((await b.api('POST', '/imports', { kind: 'parties', csv })).body.status).toBe('invalid'); // asOf missing
    const v = await b.api('POST', '/imports', { kind: 'parties', csv, options: { asOf: new Date().toISOString().slice(0, 10) } });
    expect(v.body.status).toBe('validated');
    const done = await commit(b.api, v.body.id);
    expect(done.result, JSON.stringify(done)).toBeTruthy();
    expect(done.result.created).toBe(3);
    const parties = (await b.api('GET', '/parties?limit=50')).body.data as any[];
    const alpha = parties.find((p) => p.name === 'Alpha Traders');
    expect(alpha.custom).toEqual({ region: 'North' });
    expect(alpha.balance).toBe(25000);
    expect(parties.find((p) => p.name === 'Beta Steels').balance).toBe(-18000);
    const tb = (await b.api('GET', '/reports/trial-balance')).body;
    expect(tb.totalDebit).toBe(tb.totalCredit);

    const again = await b.api('POST', '/imports', { kind: 'parties', csv: 'type,name,openingBalance,openingType\ncustomer,Alpha Traders,500,dr\n', options: { asOf: new Date().toISOString().slice(0, 10), updateExisting: true } });
    expect(again.body.status).toBe('invalid');
    expect(again.body.errors[0].message).toMatch(/opening balance/i);
  });

  it('imports opening stock and account balances', async () => {
    const b = await biz();
    const today = new Date().toISOString().slice(0, 10);
    const stock = (await b.api('POST', '/items', { name: 'Cement', sku: 'CEM', hsnCode: '2523', unit: 'bag', gstRate: 18, salePrice: 400, purchasePrice: 300 })).body;
    const csv = 'sku,itemName,locationCode,qty,rate\nCEM,,WH1,100,310\n';
    expect((await b.api('POST', '/imports', { kind: 'opening_stock', csv })).body.status).toBe('invalid'); // asOf missing
    const bad = await b.api('POST', '/imports', { kind: 'opening_stock', csv: 'sku,itemName,locationCode,qty,rate\nCEM,,NOPE,0,5\nSRV,,WH1,1,5\n', options: { asOf: today } });
    expect(bad.body.status).toBe('invalid');
    expect(bad.body.errors.map((e: any) => `${e.row}:${e.column}`)).toEqual(expect.arrayContaining(['1:locationCode', '1:qty', '2:sku']));
    const v = await b.api('POST', '/imports', { kind: 'opening_stock', csv, options: { asOf: today } });
    expect(v.body.status).toBe('validated');
    expect((await commit(b.api, v.body.id)).result.created).toBe(1);
    const pos = (await b.api('GET', '/stock')).body;
    expect(JSON.stringify(pos)).toContain('310');
    void stock;
    expect((await b.api('GET', '/accounts')).body.data.find((a: any) => a.code === '1200').balance).toBe(31000);

    const ab = 'accountCode,debit,credit\n1010,50000,\n1100,100,\n3000,,20000\n';
    const refused = await b.api('POST', '/imports', { kind: 'account_balances', csv: ab, options: { asOf: today } });
    expect(refused.body.status).toBe('invalid');
    expect(refused.body.errors).toHaveLength(1);
    expect(refused.body.errors[0]).toMatchObject({ row: 2, column: 'accountCode' });
    const okCsv = 'accountCode,debit,credit\n1010,50000,\n3000,,20000\n';
    const v2 = await b.api('POST', '/imports', { kind: 'account_balances', csv: okCsv, options: { asOf: today } });
    expect(v2.body.status).toBe('validated');
    expect((await commit(b.api, v2.body.id)).status).toBe('done');
    const accts = (await b.api('GET', '/accounts')).body.data as any[];
    expect(accts.find((a) => a.code === '1010').balance).toBe(50000);
    const tb = (await b.api('GET', '/reports/trial-balance')).body;
    expect(tb.totalDebit).toBe(tb.totalCredit);
  });

  it('checks permissions, empty files and size', async () => {
    const b = await biz();
    const body = { kind: 'items', csv: 'name,unit,gstRate\nA,nos,18\n' };
    expect((await b.accountant.api('POST', '/imports', body)).status).toBe(403); // no items.create
    expect((await b.api('POST', '/imports', { kind: 'items', csv: 'name,unit,gstRate\n' })).status).toBe(400);
    expect((await b.api('POST', '/imports', { kind: 'items', csv: 'name,unit\nA,nos\n' })).body.status).toBe('invalid'); // missing column
    expect((await b.api('POST', '/imports', { kind: 'nope', csv: 'a' })).status).toBe(400);
    const huge = await b.api('POST', '/imports', { kind: 'items', csv: `name,unit,gstRate\n${'x'.repeat(2.5 * 1024 * 1024)}` });
    expect(huge.status).toBe(400);
    const tooBig = await b.api('POST', '/imports', { kind: 'items', csv: `name,unit,gstRate\n${'x'.repeat(3.2 * 1024 * 1024)}` });
    expect(tooBig.status).toBe(413);
    expect(tooBig.body.error.code).toBe('PAYLOAD_TOO_LARGE');
  });

  it('fails the whole commit when a row no longer validates', async () => {
    const b = await biz();
    const v = await b.api('POST', '/imports', { kind: 'items', csv: 'name,sku,unit,gstRate\nOne,ONE,nos,18\nTwo,TWO,nos,18\n' });
    expect(v.body.status).toBe('validated');
    await b.api('POST', '/items', { name: 'Two', sku: 'TWO', hsnCode: '9954', unit: 'nos', gstRate: 18, salePrice: 1, trackStock: false });
    const done = await commit(b.api, v.body.id);
    expect(done.status).toBe('failed');
    expect(done.error).toMatch(/no longer validates/i);
    expect(((await b.api('GET', '/items?limit=50')).body.data as any[]).filter((i) => i.sku === 'ONE')).toHaveLength(0);
  });
});
