import { readFile } from 'node:fs/promises';
import pg from 'pg';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { withDatabase } from '../src/db/migrate.ts';
import { addDays, todayIst } from '../src/lib/dates.ts';
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
  const email = uniqueEmail('construction');
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Buildwell Contractors', name: 'Meera Shah', email,
    password: 'Secret@123', stateCode: '27',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const api = client(env.app, res.body.accessToken, me.companies[0].id);
  const site = (await api('POST', '/locations', { type: 'site', name: 'Site A' })).body;
  const otherSite = (await api('POST', '/locations', { type: 'site', name: 'Site B' })).body;
  const accounts = (await api('GET', '/accounts')).body.data as {
    id: string; code: string; systemKey: string | null;
  }[];
  const account = (code: string) => accounts.find((a) => a.code === code)!;
  const ho = (await api('GET', '/locations')).body.data[0] as { id: string };
  return { api, site, otherSite, account, ho, token: res.body.accessToken as string, companyId: me.companies[0].id as string };
}

async function balanceOf(api: Api, code: string) {
  const list = (await api('GET', '/accounts')).body.data as { code: string; balance: number }[];
  return list.find((a) => a.code === code)!.balance;
}

describe('construction labour lifecycle', () => {
  it('runs worker → attendance → draft → approved → paid with one balanced journal', async () => {
    const { api, site, account } = await business();
    const worker = (await api('POST', '/workers', {
      name: 'Ramesh Kumar', phone: '9876543210', trade: 'mason', skill: 'skilled',
      dailyRate: 800, siteId: site.id, joinedOn: '2026-10-01',
    })).body;
    expect(worker).toMatchObject({
      name: 'Ramesh Kumar', trade: 'mason', skill: 'skilled', dailyRate: 800,
      siteId: site.id, siteName: 'Site A', isActive: true,
    });

    const marked = await api('PUT', '/attendance', {
      siteId: site.id,
      date: '2026-10-20',
      entries: [{ workerId: worker.id, status: 'present', otHours: 4 }],
    });
    expect(marked.status).toBe(200);
    expect(marked.body).toMatchObject({ locked: false });
    expect(marked.body.rows).toEqual([expect.objectContaining({
      workerId: worker.id, status: 'present', otHours: 4,
    })]);

    const draft = await api('POST', '/wage-sheets', {
      siteId: site.id, from: '2026-10-20', to: '2026-10-20',
    });
    expect(draft.status).toBe(201);
    expect(draft.body).toMatchObject({
      status: 'draft', totalGross: 1600, totalDeductions: 0, totalNet: 1600,
      rows: [expect.objectContaining({
        workerId: worker.id, presentDays: 1, otHours: 4,
        basic: 800, otAmount: 800, gross: 1600, advance: 0, net: 1600,
      })],
    });
    expect(draft.body.number).toMatch(/^WG\/\d{2}-\d{2}\/00001$/);

    const overlap = await api('POST', '/wage-sheets', {
      siteId: site.id, from: '2026-10-19', to: '2026-10-21',
    });
    expect(overlap.status).toBe(409);
    expect(overlap.body.error.code).toBe('CONFLICT');

    expect((await api('PATCH', `/wage-sheets/${draft.body.id}`, { rows: [{ workerId: worker.id, advance: 200 }] })).status).toBe(400); // none registered yet
    expect((await api('POST', '/labour-advances', { workerId: worker.id, amount: 200, paidFromAccountId: account('1000').id })).status).toBe(201);
    const advanced = await api('PATCH', `/wage-sheets/${draft.body.id}`, {
      rows: [{ workerId: worker.id, advance: 200 }],
    });
    expect(advanced.status).toBe(200);
    expect(advanced.body).toMatchObject({
      totalGross: 1600, totalDeductions: 200, totalNet: 1400,
      rows: [expect.objectContaining({ advance: 200, net: 1400 })],
    });

    const approved = await api('POST', `/wage-sheets/${draft.body.id}/approve`);
    expect(approved.status).toBe(200);
    expect(approved.body.status).toBe('approved');

    const locked = await api('PUT', '/attendance', {
      siteId: site.id,
      date: '2026-10-20',
      entries: [{ workerId: worker.id, status: 'absent' }],
    });
    expect(locked.status).toBe(409);
    expect(locked.body.error.code).toBe('LOCKED');

    const beforePay = await balanceOf(api, '5310');
    expect(beforePay).toBe(0);
    const paid = await api('POST', `/wage-sheets/${draft.body.id}/pay`, {
      paidFromAccountId: account('1000').id,
      date: '2026-10-21',
    });
    expect(paid.status).toBe(200);
    expect(paid.body).toMatchObject({
      status: 'paid', totalGross: 1600, totalDeductions: 200, totalNet: 1400,
      paidFromAccountId: account('1000').id,
    });

    const journals = (await api('GET', '/journals?voucherType=wages')).body.data as {
      voucherId: string; number: string; lines: { accountCode: string; debit: number; credit: number }[];
    }[];
    expect(journals).toHaveLength(1);
    expect(journals[0]).toMatchObject({ voucherId: draft.body.id, number: draft.body.number });
    expect(journals[0]!.lines).toEqual(expect.arrayContaining([
      expect.objectContaining({ accountCode: '5310', debit: 1600, credit: 0 }),
      expect.objectContaining({ accountCode: '1000', debit: 0, credit: 1400 }),
      expect.objectContaining({ accountCode: '1400', debit: 0, credit: 200 }),
    ]));
    expect(await balanceOf(api, '5310')).toBe(1600);
    expect(await balanceOf(api, '1000')).toBe(-1600);
    expect(await balanceOf(api, '1400')).toBe(0);
  });

  it('keeps worker home-site and wage-site scopes independent', async () => {
    const { api, site, otherSite } = await business();
    const worker = (await api('POST', '/workers', {
      name: 'Ganesh Patil', trade: 'helper', dailyRate: 500, siteId: site.id,
    })).body;
    const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
    const supervisor = roles.find((r) => r.name === 'Site Supervisor')!;
    const email = uniqueEmail('supervisor');
    await api('POST', '/users', {
      name: 'Site Supervisor', email, password: 'Secret@123',
      roleId: supervisor.id, locationIds: [site.id],
    });
    const login = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    const scoped = client(env.app, login.body.accessToken);

    const workers = (await scoped('GET', '/workers')).body.data as { id: string }[];
    expect(workers.map((w) => w.id)).toEqual([worker.id]);
    expect((await scoped('GET', `/workers/${worker.id}`)).status).toBe(200);

    const outside = await api('POST', '/workers', {
      name: 'Other Site Worker', trade: 'helper', dailyRate: 500, siteId: otherSite.id,
    });
    expect(outside.status).toBe(201);
    expect((await scoped('GET', `/workers/${outside.body.id}`)).status).toBe(404);
    expect((await scoped('GET', `/attendance?siteId=${otherSite.id}&date=2026-10-20`)).status).toBe(403);
    expect((await scoped('POST', '/wage-sheets', {
      siteId: otherSite.id, from: '2026-10-20', to: '2026-10-20',
    })).status).toBe(403);
  });
});

async function userWithPermissions(
  api: Api,
  name: string,
  permissions: string[],
  locationIds: string[],
) {
  const role = (await api('POST', '/roles', { name, permissions })).body;
  const email = uniqueEmail(name.toLowerCase().replace(/\s+/g, '-'));
  const created = await api('POST', '/users', {
    name: `${name} User`,
    email,
    password: 'Secret@123',
    roleId: role.id,
    locationIds,
  });
  expect(created.status).toBe(201);
  const login = await client(env.app)('POST', '/auth/login', {
    email,
    password: 'Secret@123',
  });
  expect(login.status).toBe(200);
  return client(env.app, login.body.accessToken);
}

describe('construction indent review lifecycle', () => {
  it('edits drafts and rejected indents, then resubmits them', async () => {
    const { api, site } = await business();
    const item = (await api('POST', '/items', {
      name: 'Cement', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 80,
    })).body;
    const creator = await userWithPermissions(
      api,
      'Indent Creator',
      ['indents.view', 'indents.create'],
      [site.id],
    );
    const otherCreator = await userWithPermissions(
      api,
      'Other Indent Creator',
      ['indents.view', 'indents.create'],
      [site.id],
    );
    const viewer = await userWithPermissions(
      api,
      'Indent Viewer',
      ['indents.view'],
      [site.id],
    );

    const created = await creator('POST', '/indents', {
      locationId: site.id,
      requiredBy: '2026-11-01',
      notes: 'Original request',
      lines: [{ itemId: item.id, qty: 5 }],
    });
    expect(created.status).toBe(201);
    const id = created.body.id as string;

    const invalid = await creator('PUT', `/indents/${id}`, {
      locationId: site.id,
      lines: [{ itemId: item.id, qty: 0 }],
    });
    expect(invalid.status).toBe(400);
    expect(invalid.body.error.code).toBe('VALIDATION_ERROR');

    const edited = await creator('PUT', `/indents/${id}`, {
      locationId: site.id,
      requiredBy: '2026-11-02',
      notes: 'Revised request',
      lines: [{ itemId: item.id, qty: 7 }],
    });
    expect(edited.status).toBe(200);
    expect(edited.body).toMatchObject({
      status: 'draft',
      requiredBy: '2026-11-02',
      notes: 'Revised request',
      lines: [expect.objectContaining({ itemId: item.id, qty: 7 })],
    });

    expect((await viewer('PUT', `/indents/${id}`, {
      locationId: site.id,
      lines: [{ itemId: item.id, qty: 8 }],
    })).status).toBe(403);
    expect((await otherCreator('PUT', `/indents/${id}`, {
      locationId: site.id,
      lines: [{ itemId: item.id, qty: 8 }],
    })).status).toBe(403);

    expect((await creator('POST', `/indents/${id}/submit`)).body.status).toBe('submitted');
    const submittedEdit = await creator('PUT', `/indents/${id}`, {
      locationId: site.id,
      lines: [{ itemId: item.id, qty: 8 }],
    });
    expect(submittedEdit.status).toBe(409);
    expect(submittedEdit.body.error.code).toBe('CONFLICT');

    const rejected = await api('POST', `/indents/${id}/reject`, {
      reason: 'Use a revised quantity',
    });
    expect(rejected.status).toBe(200);
    expect(rejected.body).toMatchObject({
      status: 'rejected',
      rejectReason: 'Use a revised quantity',
    });

    const rejectedEdit = await creator('PUT', `/indents/${id}`, {
      locationId: site.id,
      notes: 'Corrected after review',
      lines: [{ itemId: item.id, qty: 8 }],
    });
    expect(rejectedEdit.status).toBe(200);
    expect(rejectedEdit.body).toMatchObject({
      status: 'rejected',
      notes: 'Corrected after review',
      lines: [expect.objectContaining({ qty: 8 })],
    });

    const resubmitted = await creator('POST', `/indents/${id}/submit`);
    expect(resubmitted.status).toBe(200);
    expect(resubmitted.body).toMatchObject({
      status: 'submitted',
      rejectReason: null,
    });

    const audit = await api('GET', `/audit?entity=indent&entityId=${id}`);
    expect(audit.body.data.map((entry: { action: string }) => entry.action)).toEqual(
      expect.arrayContaining(['create', 'update', 'submit', 'reject']),
    );
  });
});



describe('construction DPR review lifecycle', () => {
  it('rejects a submitted DPR and lets its creator resubmit it', async () => {
    const { api, site } = await business();
    const creator = await userWithPermissions(
      api,
      'DPR Creator',
      ['dpr.view', 'dpr.create'],
      [site.id],
    );
    const approver = await userWithPermissions(
      api,
      'DPR Approver',
      ['dpr.view', 'dpr.approve'],
      [site.id],
    );
    const viewer = await userWithPermissions(
      api,
      'DPR Viewer',
      ['dpr.view'],
      [site.id],
    );

    const created = await creator('POST', '/dprs', {
      locationId: site.id,
      date: '2026-10-20',
      summary: 'Foundation work completed',
      workDone: [{ description: 'Foundation', qty: 10, unit: 'm3' }],
    });
    expect(created.status).toBe(201);
    const id = created.body.id as string;

    const earlyReject = await approver('POST', `/dprs/${id}/reject`, {
      reason: 'Not ready for review',
    });
    expect(earlyReject.status).toBe(409);
    expect(earlyReject.body.error.code).toBe('CONFLICT');

    expect((await creator('POST', `/dprs/${id}/submit`)).body.status).toBe('submitted');
    expect((await viewer('POST', `/dprs/${id}/reject`, {
      reason: 'Viewer cannot reject',
    })).status).toBe(403);
    expect((await client(env.app)('POST', `/dprs/${id}/reject`, {
      reason: 'Unauthenticated request',
    })).status).toBe(401);

    const missingReason = await approver('POST', `/dprs/${id}/reject`, {});
    expect(missingReason.status).toBe(400);
    expect(missingReason.body.error.code).toBe('VALIDATION_ERROR');

    const rejected = await approver('POST', `/dprs/${id}/reject`, {
      reason: 'Add the concrete mix details',
    });
    expect(rejected.status).toBe(200);
    expect(rejected.body).toMatchObject({
      status: 'rejected',
      rejectReason: 'Add the concrete mix details',
      rejectedBy: expect.objectContaining({ name: 'DPR Approver User' }),
    });

    // A rejected DPR can be corrected; it stays rejected until it is resubmitted.
    expect((await viewer('PATCH', `/dprs/${id}`, { summary: 'Viewer edit' })).status).toBe(403);
    const corrected = await creator('PATCH', `/dprs/${id}`, {
      summary: 'Foundation work completed with M20 mix',
      workDone: [{ description: 'Foundation (M20)', qty: 10, unit: 'm3' }],
    });
    expect(corrected.status).toBe(200);
    expect(corrected.body).toMatchObject({
      status: 'rejected',
      summary: 'Foundation work completed with M20 mix',
      rejectReason: 'Add the concrete mix details',
      workDone: [expect.objectContaining({ description: 'Foundation (M20)' })],
    });

    const resubmitted = await creator('POST', `/dprs/${id}/submit`);
    expect(resubmitted.status).toBe(200);
    expect(resubmitted.body).toMatchObject({
      status: 'submitted',
      rejectReason: null,
      rejectedAt: null,
      rejectedBy: null,
    });
    expect((await creator('PATCH', `/dprs/${id}`, { summary: 'Too late' })).status).toBe(409);

    // Rejected again, then corrected and resubmitted in one PATCH.
    await approver('POST', `/dprs/${id}/reject`, { reason: 'Attach the cube test result' });
    const patchedAndSubmitted = await creator('PATCH', `/dprs/${id}`, {
      hindrances: 'Cube test report awaited from lab', submit: true,
    });
    expect(patchedAndSubmitted.status).toBe(200);
    expect(patchedAndSubmitted.body).toMatchObject({
      status: 'submitted', hindrances: 'Cube test report awaited from lab',
      rejectReason: null, rejectedAt: null, rejectedBy: null,
    });
    expect((await approver('POST', `/dprs/${id}/approve`)).body.status).toBe('approved');
    expect((await creator('PATCH', `/dprs/${id}`, { summary: 'After approval' })).status).toBe(409);

    const audit = await api('GET', `/audit?entity=dpr&entityId=${id}`);
    expect(audit.body.data.map((entry: { action: string }) => entry.action)).toEqual(
      expect.arrayContaining(['create', 'submit', 'reject']),
    );
  });
});

// ---------------------------------------------------------------------------------------------
// Projects, BOQ, indents, issues, files, DPR progress, costs and wage maths.

const daysAgo = (n: number) => addDays(todayIst(), -n);

async function scopedUser(api: Api, roleName: string, locationIds: string[]) {
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const email = uniqueEmail(roleName.toLowerCase().replace(/\s+/g, '-'));
  const created = await api('POST', '/users', {
    name: roleName, email, password: 'Secret@123', roleId: roles.find((r) => r.name === roleName)!.id, locationIds,
  });
  expect(created.status).toBe(201);
  const login = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
  return client(env.app, login.body.accessToken);
}

async function trialBalanced(api: Api) {
  const tb = (await api('GET', '/reports/trial-balance')).body;
  expect(tb.totalDebit).toBe(tb.totalCredit);
}

const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');

/** POSTs one file to /files as a real multipart/form-data body. */
async function upload(token: string, bytes: Buffer, filename: string, contentType: string, field = 'file') {
  const boundary = `----onematrix${Math.random().toString(16).slice(2)}`;
  const payload = Buffer.concat([
    Buffer.from(`--${boundary}\r\nContent-Disposition: form-data; name="${field}"; filename="${filename}"\r\n`
      + `Content-Type: ${contentType}\r\n\r\n`),
    bytes,
    Buffer.from(`\r\n--${boundary}--\r\n`),
  ]);
  const res = await env.app.inject({
    method: 'POST', url: '/api/v1/files', payload,
    headers: { authorization: `Bearer ${token}`, 'content-type': `multipart/form-data; boundary=${boundary}` },
  });
  return { status: res.statusCode, body: res.json() };
}

describe('projects and BOQ', () => {
  it('links each site to one project, scopes projects by site and manages BOQ lines', async () => {
    const { api, site, otherSite } = await business();
    const warehouse = (await api('POST', '/locations', { type: 'warehouse', name: 'Store Yard' })).body;
    const client1 = (await api('POST', '/parties', { type: 'customer', name: 'Skyline Developers', stateCode: '27' })).body;

    const p1 = await api('POST', '/projects', {
      code: 'P-001', name: 'Skyline Tower', clientPartyId: client1.id, siteIds: [site.id],
      startDate: daysAgo(60), contractValue: 50000000,
    });
    expect(p1.status).toBe(201);
    expect(p1.body).toMatchObject({
      code: 'P-001', status: 'planning', clientName: 'Skyline Developers', contractValue: 50000000,
      sites: [{ id: site.id, name: 'Site A' }], budgetTotal: 0, progressPct: 0,
    });
    expect((await api('GET', '/locations')).body.data.find((l: { id: string }) => l.id === site.id).projectId).toBe(p1.body.id);

    const taken = await api('POST', '/projects', { code: 'P-002', name: 'Second', siteIds: [site.id] });
    expect(taken.status).toBe(409);
    expect(taken.body.error.code).toBe('CONFLICT');
    expect((await api('POST', '/projects', { code: 'P-002', name: 'Second', siteIds: [warehouse.id] })).status).toBe(400);
    expect((await api('POST', '/projects', { code: 'p-001', name: 'Same code' })).status).toBe(409);
    const p2 = (await api('POST', '/projects', { code: 'P-002', name: 'Riverside Villas', siteIds: [otherSite.id] })).body;

    const badDates = await api('PATCH', `/projects/${p1.body.id}`, { endDate: daysAgo(90) });
    expect(badDates.status).toBe(400);
    const active = await api('PATCH', `/projects/${p1.body.id}`, { status: 'active', address: 'Baner, Pune' });
    expect(active.body).toMatchObject({ status: 'active', address: 'Baner, Pune' });
    expect((await api('GET', '/projects?status=active')).body.data.map((p: { id: string }) => p.id)).toEqual([p1.body.id]);

    // BOQ: bulk and single create, duplicate codes, ordering, edit and delete.
    const bulk = await api('POST', `/projects/${p1.body.id}/boq`, { lines: [
      { code: '1.1', description: 'Excavation in ordinary soil', unit: 'm3', qty: 100, rate: 250, labourBudget: 20000, otherBudget: 5000 },
      { code: '2.1', description: 'PCC 1:4:8 below footings', unit: 'm3', qty: 20, rate: 4500, materialBudget: 60000, labourBudget: 20000 },
      { code: '3.1', description: 'RCC M25 in columns', unit: 'm3', qty: 50, rate: 8000, materialBudget: 300000, labourBudget: 80000 },
    ] });
    expect(bulk.status).toBe(201);
    expect(bulk.body.total).toBe(3);
    expect(bulk.body.data[2]).toMatchObject({ code: '3.1', amount: 400000, executedQty: 0, progressPct: 0, sortOrder: 3 });
    expect((await api('POST', `/projects/${p1.body.id}/boq`, { lines: [
      { code: '9.1', description: 'A', unit: 'nos', qty: 1, rate: 1 }, { code: '9.1', description: 'B', unit: 'nos', qty: 1, rate: 1 },
    ] })).status).toBe(400);
    expect((await api('POST', `/projects/${p1.body.id}/boq`, { code: '2.1', description: 'Again', unit: 'm3', qty: 1, rate: 1 })).status).toBe(409);
    expect((await api('POST', `/projects/${p1.body.id}/boq`, { code: '9.9', description: 'Zero', unit: 'm3', qty: 0, rate: 1 })).status).toBe(400);

    const single = await api('POST', `/projects/${p1.body.id}/boq`, { code: '4.1', description: 'Brickwork 230 mm', unit: 'm3', qty: 10, rate: 5000 });
    expect(single.status).toBe(201);
    expect(single.body).toMatchObject({ code: '4.1', amount: 50000, sortOrder: 4 });
    expect((await api('GET', `/projects/${p1.body.id}`)).body.budgetTotal).toBe(565000);

    const edited = await api('PATCH', `/boq/${single.body.id}`, { qty: 12, sortOrder: 0 });
    expect(edited.body).toMatchObject({ qty: 12, amount: 60000, sortOrder: 0 });
    const list = (await api('GET', `/projects/${p1.body.id}/boq`)).body;
    expect(list.total).toBe(4);
    expect(list.data.map((l: { code: string }) => l.code)).toEqual(['4.1', '1.1', '2.1', '3.1']);
    expect((await api('GET', `/projects/${p1.body.id}/boq?q=rcc&limit=1`)).body).toMatchObject({ total: 1, data: [{ code: '3.1' }] });

    const del = await api('DELETE', `/boq/${single.body.id}`);
    expect(del.status).toBe(204);
    expect((await api('GET', `/projects/${p1.body.id}/boq`)).body.total).toBe(3);

    // A BOQ line used by an indent cannot be deleted; lines of another project are refused.
    const item = (await api('POST', '/items', { name: 'Cement', unit: 'bag', gstRate: 18, salePrice: 400, purchasePrice: 350 })).body;
    const excavation = bulk.body.data[0];
    const p2Line = (await api('POST', `/projects/${p2.id}/boq`, { code: '1.1', description: 'Excavation', unit: 'm3', qty: 5, rate: 200 })).body;
    expect((await api('POST', '/indents', { locationId: site.id, lines: [{ itemId: item.id, qty: 5, boqLineId: p2Line.id }] })).status).toBe(400);
    expect((await api('POST', '/indents', { locationId: site.id, lines: [{ itemId: item.id, qty: 5, boqLineId: excavation.id }] })).status).toBe(201);
    const inUse = await api('DELETE', `/boq/${excavation.id}`);
    expect(inUse.status).toBe(409);
    expect(inUse.body.error.code).toBe('IN_USE');

    // A site supervisor of Site A sees only the project of Site A.
    const sup = await scopedUser(api, 'Site Supervisor', [site.id]);
    const seen = (await sup('GET', '/projects')).body;
    expect(seen).toMatchObject({ total: 1, data: [{ id: p1.body.id }] });
    expect((await sup('GET', `/projects/${p2.id}`)).status).toBe(404);
    expect((await sup('GET', `/projects/${p1.body.id}/boq`)).body.total).toBe(3);
    expect((await sup('POST', `/projects/${p1.body.id}/boq`, { code: '8.1', description: 'X', unit: 'm3', qty: 1, rate: 1 })).status).toBe(403);

    const pm = (await api('GET', '/roles')).body.data.find((r: { name: string }) => r.name === 'Project Manager');
    expect(pm.permissions).toEqual(expect.arrayContaining(['boq.manage', 'indents.approve', 'dpr.approve', 'wages.manage']));
  });
});

describe('indent fulfilment', () => {
  it('fulfils approved quantities through a received transfer and a posted purchase', async () => {
    const { api, site, account } = await business();
    const warehouse = (await api('POST', '/locations', { type: 'warehouse', name: 'Central Store' })).body;
    const cement = (await api('POST', '/items', { name: 'Cement', unit: 'bag', gstRate: 18, salePrice: 400, purchasePrice: 300 })).body;
    const steel = (await api('POST', '/items', { name: 'TMT 12 mm', unit: 'kg', gstRate: 18, salePrice: 70, purchasePrice: 60 })).body;
    await api('POST', '/stock/adjustments', { locationId: warehouse.id, itemId: cement.id, qty: 100, rate: 300, isOpening: true });
    const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Pune Steel', stateCode: '27' })).body;

    const indent = await api('POST', '/indents', {
      locationId: site.id, requiredBy: todayIst(), submit: true,
      lines: [{ itemId: cement.id, qty: 50 }, { itemId: steel.id, qty: 20 }],
    });
    expect(indent.status).toBe(201);
    expect(indent.body).toMatchObject({ status: 'submitted', locationId: site.id });
    expect(indent.body.number).toMatch(/^IND\/\d{2}-\d{2}\/00001$/);
    const [cementLine, steelLine] = indent.body.lines;

    expect((await api('POST', '/transfers', { fromLocationId: warehouse.id, toLocationId: site.id, indentId: indent.body.id,
      lines: [{ itemId: cement.id, qty: 10 }] })).status).toBe(400); // not approved yet
    const tooMuch = await api('POST', `/indents/${indent.body.id}/approve`, { lines: [{ lineId: cementLine.id, approvedQty: 60 }] });
    expect(tooMuch.status).toBe(400);
    const approved = await api('POST', `/indents/${indent.body.id}/approve`, { lines: [{ lineId: cementLine.id, approvedQty: 40 }] });
    expect(approved.body).toMatchObject({ status: 'approved', isFulfilled: false });
    expect(approved.body.lines).toEqual([
      expect.objectContaining({ id: cementLine.id, qty: 50, approvedQty: 40, fulfilledQty: 0 }),
      expect.objectContaining({ id: steelLine.id, qty: 20, approvedQty: 20, fulfilledQty: 0 }),
    ]);

    // The transfer must go to the indent's location; it counts only once received.
    expect((await api('POST', '/transfers', { fromLocationId: site.id, toLocationId: warehouse.id, indentId: indent.body.id,
      lines: [{ itemId: cement.id, qty: 1 }] })).status).toBe(400);
    const transfer = (await api('POST', '/transfers', { fromLocationId: warehouse.id, toLocationId: site.id, indentId: indent.body.id,
      lines: [{ itemId: cement.id, qty: 30 }] })).body;
    expect(transfer.indentId).toBe(indent.body.id);
    expect((await api('GET', `/indents/${indent.body.id}`)).body.lines[0].fulfilledQty).toBe(0);
    await api('POST', `/transfers/${transfer.id}/receive`);
    expect((await api('GET', `/indents/${indent.body.id}`)).body.lines[0].fulfilledQty).toBe(30);

    // The purchase fills the rest, capped at the approved quantity.
    const bill = await api('POST', '/purchases', { locationId: site.id, partyId: vendor.id, indentId: indent.body.id,
      lines: [{ itemId: cement.id, qty: 20, rate: 310 }, { itemId: steel.id, qty: 25, rate: 62 }] });
    expect(bill.status).toBe(201);
    expect(bill.body.indentId).toBe(indent.body.id);
    const full = (await api('GET', `/indents/${indent.body.id}`)).body;
    expect(full).toMatchObject({ status: 'approved', isFulfilled: true });
    expect(full.lines.map((l: { fulfilledQty: number }) => l.fulfilledQty)).toEqual([40, 20]);

    // Cancelling the purchase takes back what it delivered.
    expect((await api('POST', `/purchases/${bill.body.id}/cancel`, { reason: 'Wrong rate' })).status).toBe(200);
    const after = (await api('GET', `/indents/${indent.body.id}`)).body;
    expect(after).toMatchObject({ isFulfilled: false });
    expect(after.lines.map((l: { fulfilledQty: number }) => l.fulfilledQty)).toEqual([30, 0]);

    expect((await api('GET', `/indents?status=approved&locationId=${site.id}`)).body.total).toBe(1);
    expect((await api('POST', `/indents/${indent.body.id}/close`)).body.status).toBe('closed');
    expect((await api('POST', '/purchases', { locationId: site.id, partyId: vendor.id, indentId: indent.body.id,
      lines: [{ itemId: steel.id, qty: 1 }] })).status).toBe(400);
    expect((await api('POST', `/indents/${indent.body.id}/close`)).status).toBe(409);
    void account;
    await trialBalanced(api);
  });
});

describe('material issue to work', () => {
  it('issues at average cost to Material Consumed, and cancelling restores stock and books', async () => {
    const { api, site } = await business();
    const cement = (await api('POST', '/items', { name: 'Cement', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50 })).body;
    const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Cement Depot', stateCode: '27' })).body;
    await api('POST', '/stock/adjustments', { locationId: site.id, itemId: cement.id, qty: 100, rate: 50, isOpening: true });
    await api('POST', '/purchases', { locationId: site.id, partyId: vendor.id, lines: [{ itemId: cement.id, qty: 50, rate: 60 }] });
    expect(await balanceOf(api, '1200')).toBe(8000);

    const tooMuch = await api('POST', '/issues', { locationId: site.id, lines: [{ itemId: cement.id, qty: 151 }] });
    expect(tooMuch.status).toBe(409);
    expect(tooMuch.body.error.code).toBe('INSUFFICIENT_STOCK');

    const issued = await api('POST', '/issues', { locationId: site.id, notes: 'Footing F1 to F6', lines: [{ itemId: cement.id, qty: 30 }] });
    expect(issued.status).toBe(201);
    expect(issued.body.number).toMatch(/^ISS\/\d{2}-\d{2}\/00001$/);
    expect(issued.body).toMatchObject({ status: 'posted', totalValue: 1600,
      lines: [{ itemId: cement.id, qty: 30, costRate: 53.3333, value: 1600 }] });

    const journal = (await api('GET', '/journals?voucherType=issue')).body.data;
    expect(journal).toHaveLength(1);
    expect(journal[0].lines).toEqual(expect.arrayContaining([
      expect.objectContaining({ accountCode: '5300', debit: 1600, credit: 0 }),
      expect.objectContaining({ accountCode: '1200', debit: 0, credit: 1600 }),
    ]));
    const moves = (await api('GET', `/stock/moves?locationId=${site.id}`)).body.data;
    expect(moves[0]).toMatchObject({ refType: 'issue', qty: -30, value: -1600 });
    expect((await api('GET', `/stock?locationId=${site.id}`)).body.data[0]).toMatchObject({ qty: 120, value: 6400 });
    expect(await balanceOf(api, '5300')).toBe(1600);
    // Inventory account still equals the stock ledger's value.
    expect(await balanceOf(api, '1200')).toBe((await api('GET', '/reports/stock-valuation')).body.totalValue);

    const cancelled = await api('POST', `/issues/${issued.body.id}/cancel`, { reason: 'Issued to the wrong footing' });
    expect(cancelled.body.status).toBe('cancelled');
    expect((await api('POST', `/issues/${issued.body.id}/cancel`, { reason: 'Again' })).body.error.code).toBe('ALREADY_CANCELLED');
    expect((await api('GET', `/stock/moves?locationId=${site.id}`)).body.data[0]).toMatchObject({ refType: 'issue_cancel', qty: 30, value: 1600 });
    expect((await api('GET', `/stock?locationId=${site.id}`)).body.data[0]).toMatchObject({ qty: 150, value: 8000 });
    expect(await balanceOf(api, '5300')).toBe(0);
    expect(await balanceOf(api, '1200')).toBe(8000);
    expect((await api('GET', '/reports/stock-valuation')).body.totalValue).toBe(8000);
    expect((await api('GET', `/issues?status=cancelled&locationId=${site.id}`)).body.total).toBe(1);

    // Without items.view_cost the values are absent.
    const sup = await scopedUser(api, 'Site Supervisor', [site.id]);
    const hidden = (await sup('GET', `/issues/${issued.body.id}`)).body;
    expect(hidden.totalValue).toBeUndefined();
    expect(hidden.lines[0].value).toBeUndefined();
    await trialBalanced(api);
  });
});

describe('file uploads', () => {
  it('accepts real images and PDFs only, up to 10 MB, within the business', async () => {
    const { api, site, token } = await business();
    const ok = await upload(token, PNG, '../../etc/site photo.png', 'image/png');
    expect(ok.status).toBe(201);
    expect(ok.body).toMatchObject({ name: 'site photo.png', mimeType: 'image/png', size: PNG.length, url: `/api/v1/files/${ok.body.id}` });

    const fetched = await env.app.inject({ method: 'GET', url: ok.body.url, headers: { authorization: `Bearer ${token}` } });
    expect(fetched.statusCode).toBe(200);
    expect(fetched.headers['content-type']).toBe('image/png');
    expect(fetched.rawPayload.equals(PNG)).toBe(true);

    const pdf = await upload(token, Buffer.from('%PDF-1.4\n%âã\n1 0 obj\n<<>>\nendobj\n'), 'challan.pdf', 'application/pdf');
    expect(pdf.body).toMatchObject({ mimeType: 'application/pdf' });

    // The claimed type does not matter: the first bytes do.
    const fake = await upload(token, Buffer.from('<script>alert(1)</script>'), 'photo.png', 'image/png');
    expect(fake.status).toBe(400);
    expect(fake.body.error.code).toBe('VALIDATION_ERROR');
    const big = Buffer.alloc(10 * 1024 * 1024 + 1);
    PNG.copy(big);
    const tooBig = await upload(token, big, 'huge.png', 'image/png');
    expect(tooBig.status).toBe(400);
    expect(tooBig.body.error.details).toMatchObject({ file: 'Larger than 10 MB' });
    expect((await upload(token, PNG, 'x.png', 'image/png', 'photo')).status).toBe(400);
    expect((await api('POST', '/files', { file: 'not multipart' })).status).toBe(400);

    // PDFs cannot be DPR photos; images can.
    expect((await api('POST', '/dprs', { locationId: site.id, photos: [{ fileId: pdf.body.id }] })).status).toBe(400);
    const dpr = await api('POST', '/dprs', { locationId: site.id, photos: [{ fileId: ok.body.id, caption: 'Column casting' }] });
    expect(dpr.status).toBe(201);
    expect(dpr.body.photos).toEqual([{ fileId: ok.body.id, url: ok.body.url, caption: 'Column casting' }]);

    // Another business cannot read the file or use it.
    const other = await business();
    const cross = await env.app.inject({ method: 'GET', url: ok.body.url, headers: { authorization: `Bearer ${other.token}` } });
    expect(cross.statusCode).toBe(404);
    expect((await other.api('POST', '/dprs', { locationId: other.site.id, photos: [{ fileId: ok.body.id }] })).status).toBe(400);
  });
});

describe('daily progress reports', () => {
  it('counts approved work towards BOQ progress and finds the previous DPR', async () => {
    const { api, site, otherSite } = await business();
    const project = (await api('POST', '/projects', { code: 'DPR-1', name: 'Tower', siteIds: [site.id] })).body;
    const other = (await api('POST', '/projects', { code: 'DPR-2', name: 'Villas', siteIds: [otherSite.id] })).body;
    const [exc, pcc] = (await api('POST', `/projects/${project.id}/boq`, { lines: [
      { code: '1.1', description: 'Excavation', unit: 'm3', qty: 100, rate: 250 },
      { code: '2.1', description: 'PCC', unit: 'm3', qty: 20, rate: 4500 },
    ] })).body.data;
    const foreign = (await api('POST', `/projects/${other.id}/boq`, { code: '1.1', description: 'X', unit: 'm3', qty: 1, rate: 1 })).body;

    expect((await api('GET', `/dprs/previous?locationId=${site.id}`)).status).toBe(404);
    expect((await api('POST', '/dprs', { locationId: site.id, date: addDays(todayIst(), 1) })).status).toBe(400);
    expect((await api('POST', '/dprs', { locationId: site.id, workDone: [{ boqLineId: foreign.id, description: 'X', qty: 1 }] })).status).toBe(400);

    const first = await api('POST', '/dprs', {
      locationId: site.id, date: daysAgo(2), weather: 'Sunny', summary: 'Excavation for grid A–C', submit: true,
      workDone: [{ boqLineId: exc.id, description: 'Excavation grid A–C', qty: 40 }],
      labour: [{ trade: 'helper', count: 12 }], equipment: [{ name: 'JCB 3DX', hours: 6.5 }],
    });
    expect(first.status).toBe(201);
    expect(first.body).toMatchObject({
      status: 'submitted', projectId: project.id, date: daysAgo(2),
      workDone: [{ boqLineId: exc.id, boqCode: '1.1', qty: 40, unit: 'm3' }],
      labour: [{ trade: 'helper', count: 12 }], equipment: [{ name: 'JCB 3DX', hours: 6.5 }],
    });
    const dup = await api('POST', '/dprs', { locationId: site.id, date: daysAgo(2) });
    expect(dup.status).toBe(409);
    expect(dup.body.error.code).toBe('CONFLICT');

    // Submitted work does not count until approved.
    expect((await api('GET', `/projects/${project.id}/boq`)).body.data[0].executedQty).toBe(0);
    expect((await api('POST', `/dprs/${first.body.id}/approve`)).body.status).toBe('approved');
    const boq = (await api('GET', `/projects/${project.id}/boq`)).body.data;
    expect(boq[0]).toMatchObject({ executedQty: 40, progressPct: 40 });
    expect((await api('GET', `/projects/${project.id}`)).body.progressPct).toBe(8.7); // 25,000 × 40% of 1,15,000

    const second = (await api('POST', '/dprs', { locationId: site.id, date: daysAgo(1), workDone: [
      { boqLineId: exc.id, description: 'Excavation grid D–F', qty: 80 },
      { boqLineId: pcc.id, description: 'PCC footings F1–F4', qty: 5 },
    ] })).body;
    expect((await api('GET', `/dprs/previous?locationId=${site.id}`)).body.id).toBe(second.id);
    expect((await api('POST', `/dprs/${second.id}/approve`)).status).toBe(409); // still a draft
    await api('POST', `/dprs/${second.id}/submit`);
    await api('POST', `/dprs/${second.id}/approve`);
    const progressed = (await api('GET', `/projects/${project.id}/boq`)).body.data;
    expect(progressed[0]).toMatchObject({ executedQty: 120, progressPct: 100 }); // capped at 100
    expect(progressed[1]).toMatchObject({ executedQty: 5, progressPct: 25 });
    expect((await api('GET', `/projects/${project.id}`)).body.progressPct).toBe(41.3); // (25,000 + 22,500) ÷ 1,15,000

    const list = (await api('GET', `/dprs?projectId=${project.id}&status=approved`)).body;
    expect(list.data.map((d: { id: string }) => d.id)).toEqual([second.id, first.body.id]);
    const sup = await scopedUser(api, 'Site Supervisor', [otherSite.id]);
    expect((await sup('GET', `/dprs/${first.body.id}`)).status).toBe(404);
    expect((await sup('GET', `/dprs/previous?locationId=${site.id}`)).status).toBe(403);
  });
});

describe('project costs', () => {
  it('adds up issued material, approved wages and site expenses against the BOQ budget', async () => {
    const { api, site, ho, account } = await business();
    const project = (await api('POST', '/projects', { code: 'C-1', name: 'Costed Tower', siteIds: [site.id], startDate: daysAgo(30) })).body;
    const [line1] = (await api('POST', `/projects/${project.id}/boq`, { lines: [
      { code: '1', description: 'Footings', unit: 'm3', qty: 10, rate: 1000, materialBudget: 5000, labourBudget: 3000, otherBudget: 1000 },
      { code: '2', description: 'Columns', unit: 'm3', qty: 5, rate: 2000, materialBudget: 8000, labourBudget: 1000 },
    ] })).body.data;
    const cement = (await api('POST', '/items', { name: 'Cement', unit: 'bag', gstRate: 18, salePrice: 100, purchasePrice: 50 })).body;
    await api('POST', '/stock/adjustments', { locationId: site.id, itemId: cement.id, qty: 100, rate: 50, isOpening: true });
    await api('POST', '/issues', { locationId: site.id, boqLineId: line1.id, lines: [{ itemId: cement.id, qty: 20 }] }); // 1,000
    await api('POST', '/issues', { locationId: site.id, lines: [{ itemId: cement.id, qty: 10 }] }); // 500
    const undone = (await api('POST', '/issues', { locationId: site.id, lines: [{ itemId: cement.id, qty: 4 }] })).body;
    await api('POST', `/issues/${undone.id}/cancel`, { reason: 'Not used' });

    const worker = (await api('POST', '/workers', { name: 'Sunil', trade: 'mason', dailyRate: 800, siteId: site.id })).body;
    await api('PUT', '/attendance', { siteId: site.id, date: daysAgo(3), entries: [{ workerId: worker.id, status: 'present' }] });
    await api('PUT', '/attendance', { siteId: site.id, date: daysAgo(2), entries: [{ workerId: worker.id, status: 'present', otHours: 2 }] });
    await api('PUT', '/attendance', { siteId: site.id, date: daysAgo(1), entries: [{ workerId: worker.id, status: 'present' }] });
    const sheet = (await api('POST', '/wage-sheets', { siteId: site.id, from: daysAgo(3), to: daysAgo(2) })).body;
    expect(sheet.totalGross).toBe(2000); // 2 days × 800 + 2 h × 800 ÷ 8 × 2
    await api('POST', `/wage-sheets/${sheet.id}/approve`);
    await api('POST', '/wage-sheets', { siteId: site.id, from: daysAgo(1), to: daysAgo(1) }); // draft: not a cost yet

    await api('POST', '/expenses', { locationId: site.id, accountId: account('6030').id, description: 'Crane hire',
      amount: 1200, gstRate: 18, paidFromAccountId: account('1000').id });
    await api('POST', '/expenses', { locationId: ho.id, accountId: account('6040').id, description: 'Stationery',
      amount: 300, paidFromAccountId: account('1000').id });

    const costs = (await api('GET', `/projects/${project.id}/costs`)).body;
    expect(costs).toMatchObject({
      projectId: project.id, from: daysAgo(30), to: todayIst(),
      budget: { material: 13000, labour: 4000, other: 1000, total: 18000 },
      actual: { material: 1500, labour: 2000, expenses: 1200, total: 4700 },
    });
    expect(costs.byBoqLine).toEqual([
      expect.objectContaining({ code: '1', materialBudget: 5000, materialActual: 1000 }),
      expect.objectContaining({ code: '2', materialBudget: 8000, materialActual: 0 }),
    ]);
    const recent = (await api('GET', `/projects/${project.id}/costs?from=${daysAgo(1)}`)).body;
    expect(recent.actual).toEqual({ material: 1500, labour: 0, expenses: 1200, subcontract: 0, total: 2700 });

    const sup = await scopedUser(api, 'Site Supervisor', [site.id]);
    expect((await sup('GET', `/projects/${project.id}/costs`)).body.actual).toEqual({ material: 0, labour: 2000, expenses: 1200, subcontract: 0, total: 3200 });
  });
});

describe('wage maths and attendance locks', () => {
  it('computes half days and overtime to the paisa, recovers advances and locks the period', async () => {
    const { api, site, account } = await business();
    const worker = async (name: string, dailyRate: number) =>
      (await api('POST', '/workers', { name, trade: 'mason', dailyRate, siteId: site.id })).body.id as string;
    const anil = await worker('Anil', 650);
    const babu = await worker('Babu', 300.03);
    const chetan = await worker('Chetan', 733.33);
    const mark = (n: number, entries: unknown[]) => api('PUT', '/attendance', { siteId: site.id, date: daysAgo(n), entries });
    await mark(6, [{ workerId: anil, status: 'present' }, { workerId: chetan, status: 'present', otHours: 1.5 }]);
    await mark(5, [{ workerId: anil, status: 'present', otHours: 3 }, { workerId: babu, status: 'half_day' }]);
    await mark(4, [{ workerId: anil, status: 'half_day' }]);
    await mark(3, [{ workerId: anil, status: 'present' }]);
    await mark(2, [{ workerId: anil, status: 'absent' }]);
    expect((await mark(0, [{ workerId: anil, status: 'present' }])).status).toBe(200);
    expect((await api('PUT', '/attendance', { siteId: site.id, date: addDays(todayIst(), 1), entries: [] })).status).toBe(400);

    // An advance of 500 paid to Anil earlier in cash.
    expect((await api('POST', '/labour-advances', { workerId: anil, amount: 500, paidFromAccountId: account('1000').id, notes: 'Advance to Anil' })).status).toBe(201);

    const sheet = (await api('POST', '/wage-sheets', { siteId: site.id, from: daysAgo(6), to: daysAgo(2) })).body;
    const row = (id: string) => sheet.rows.find((r: { workerId: string }) => r.workerId === id);
    expect(row(anil)).toMatchObject({ presentDays: 3.5, otHours: 3, basic: 2275, otAmount: 487.5, gross: 2762.5 });
    expect(row(babu)).toMatchObject({ presentDays: 0.5, basic: 150.02, otAmount: 0, gross: 150.02 }); // 150.015 rounds up
    expect(row(chetan)).toMatchObject({ presentDays: 1, otHours: 1.5, basic: 733.33, otAmount: 275, gross: 1008.33 }); // 274.99875
    expect(sheet.totalGross).toBe(3920.85);

    expect((await api('PATCH', `/wage-sheets/${sheet.id}`, { rows: [{ workerId: babu, advance: 200 }] })).status).toBe(400);
    const withAdvance = (await api('PATCH', `/wage-sheets/${sheet.id}`, { rows: [{ workerId: anil, advance: 500 }] })).body;
    expect(withAdvance).toMatchObject({ totalGross: 3920.85, totalDeductions: 500, totalNet: 3420.85 });
    const recomputed = (await api('POST', `/wage-sheets/${sheet.id}/recompute`)).body;
    expect(recomputed.rows.find((r: { workerId: string }) => r.workerId === anil)).toMatchObject({ advance: 500, net: 2262.5 });

    // Approval locks the period's attendance; dates outside it stay open.
    expect((await api('GET', `/attendance?siteId=${site.id}&date=${daysAgo(4)}`)).body.locked).toBe(false);
    expect((await api('POST', `/wage-sheets/${sheet.id}/approve`)).body.status).toBe('approved');
    const att = (await api('GET', `/attendance?siteId=${site.id}&date=${daysAgo(4)}`)).body;
    expect(att).toMatchObject({ locked: true });
    expect(att.rows.find((r: { workerId: string }) => r.workerId === anil)).toMatchObject({ status: 'half_day', otHours: 0 });
    const locked = await mark(4, [{ workerId: anil, status: 'present' }]);
    expect(locked.status).toBe(409);
    expect(locked.body.error.code).toBe('LOCKED');
    expect((await mark(1, [{ workerId: anil, status: 'present' }])).status).toBe(200);
    expect((await api('PATCH', `/wage-sheets/${sheet.id}`, { rows: [{ workerId: anil, advance: 0 }] })).status).toBe(409);

    // Cancelling an approved sheet unlocks its period.
    const extra = (await api('POST', '/wage-sheets', { siteId: site.id, from: daysAgo(1), to: daysAgo(0) })).body;
    await api('POST', `/wage-sheets/${extra.id}/approve`);
    expect((await mark(1, [{ workerId: anil, status: 'half_day' }])).status).toBe(409);
    expect((await api('POST', `/wage-sheets/${extra.id}/cancel`, { reason: 'Prepared too early' })).body.status).toBe('cancelled');
    expect((await mark(1, [{ workerId: anil, status: 'half_day' }])).status).toBe(200);

    // Paying posts Dr Site Labour Wages gross / Cr bank net / Cr Labour Advances.
    const paid = await api('POST', `/wage-sheets/${sheet.id}/pay`, { paidFromAccountId: account('1010').id });
    expect(paid.body).toMatchObject({ status: 'paid', paidFromAccountId: account('1010').id });
    expect(await balanceOf(api, '5310')).toBe(3920.85);
    expect(await balanceOf(api, '1010')).toBe(-3420.85);
    expect(await balanceOf(api, '1400')).toBe(0);
    expect((await api('POST', `/wage-sheets/${sheet.id}/cancel`, { reason: 'Too late' })).status).toBe(409);
    expect((await api('GET', `/wage-sheets?siteId=${site.id}&status=paid`)).body).toMatchObject({ total: 1, data: [{ id: sheet.id }] });
    await trialBalanced(api);
  });
});

describe('construction system accounts', () => {
  it('moves a system account to the next free code when a company already uses the standard one', async () => {
    const { api, companyId } = await business();
    const testUrl = new URL(process.env.TEST_DATABASE_URL!);
    const owner = new pg.Client({ connectionString: withDatabase(process.env.DATABASE_ADMIN_URL!, testUrl.pathname.slice(1)) });
    await owner.connect();
    try {
      // As if the company had made its own accounts 1400 and 5300 before the construction pack existed.
      await owner.query(`update accounts set system_key = null, is_system = false, name = 'Staff Loans'
        where company_id = $1 and code = '1400'`, [companyId]);
      await owner.query(`update accounts set system_key = null, is_system = false, name = 'Packing Material'
        where company_id = $1 and code = '5300'`, [companyId]);
      await owner.query(`insert into accounts (tenant_id, company_id, code, name, type, subtype)
        select tenant_id, company_id, '5301', 'Freight Inward', 'expense', 'other' from accounts where company_id = $1 limit 1`, [companyId]);
      // Migration 005 backfills Labour Advances; the app fills in whatever is still missing.
      await owner.query(await readFile(new URL('../src/db/migrations/005_backfill_system_accounts.sql', import.meta.url), 'utf8'));
      const backfilled = await owner.query(`select code from accounts where company_id = $1 and system_key = 'labour_advances'`, [companyId]);
      expect(backfilled.rows).toEqual([{ code: '1401' }]);
      await owner.query(`update accounts set system_key = null, is_system = false, name = 'Old Advances'
        where company_id = $1 and code = '1401'`, [companyId]);
      await owner.query(`delete from accounts where company_id = $1 and system_key = 'material_consumed'`, [companyId]);
    } finally {
      await owner.end();
    }
    const accounts = (await api('GET', '/accounts')).body.data as { code: string; name: string; systemKey: string | null }[];
    const key = (k: string) => accounts.find((a) => a.systemKey === k);
    expect(key('labour_advances')).toMatchObject({ code: '1402', name: 'Labour Advances' });
    expect(key('material_consumed')).toMatchObject({ code: '5302', name: 'Material Consumed at Sites' });
    expect(accounts.find((a) => a.code === '1400')).toMatchObject({ name: 'Staff Loans', systemKey: null });
  });
});
