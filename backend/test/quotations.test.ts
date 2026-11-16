import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { ensureStages } from '../src/modules/crm-common.ts';
import { withTenant } from '../src/db/database.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => {
  env = await setupTestApp();
});
afterAll(async () => {
  await teardown(env);
});

const PASSWORD = 'Secret@123';

async function biz(name = 'Quote Co') {
  const signup = await client(env.app)('POST', '/auth/signup', {
    businessName: name, name: 'Owner One', email: uniqueEmail('owner'), password: PASSWORD, stateCode: '24',
  });
  expect(signup.status, JSON.stringify(signup.body)).toBe(201);
  const token = signup.body.accessToken as string;
  const claims = JSON.parse(Buffer.from(token.split('.')[1]!, 'base64url').toString());
  const me = (await client(env.app, token)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, token, companyId);
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const userWith = async (roleId: string) => {
    const email = uniqueEmail('u');
    const created = await api('POST', '/users', { name: 'Someone', email, password: PASSWORD, roleId });
    expect(created.status, JSON.stringify(created.body)).toBe(201);
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    return client(env.app, login.body.accessToken, companyId);
  };
  const sales = await userWith(roles.find((r) => r.name === 'Sales Executive')!.id);
  const quoteOnly = (await api('POST', '/roles', { name: 'Quoter', permissions: ['quotations.view', 'quotations.manage', 'parties.view', 'items.view'] })).body;
  const quoter = await userWith(quoteOnly.id);
  const wh = (await api('POST', '/locations', { type: 'warehouse', name: 'Warehouse', code: 'WH1', stateCode: '24' })).body;
  const vendor = (await api('POST', '/parties', { type: 'vendor', name: 'Vendor One', stateCode: '24' })).body;
  const local = (await api('POST', '/parties', { type: 'customer', name: 'Local Buyer', stateCode: '24' })).body;
  const far = (await api('POST', '/parties', { type: 'customer', name: 'Far Buyer', stateCode: '27' })).body;
  const mk = async (sku: string, price: number, trackStock: boolean) => {
    const r = await api('POST', '/items', { name: `Item ${sku}`, sku, hsnCode: '6907', unit: 'nos', gstRate: 18, salePrice: price, purchasePrice: 60, trackStock });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    return r.body as { id: string };
  };
  const goods = await mk('GD1', 100, true);
  const goods2 = await mk('GD2', 250, true);
  const service = await mk('SV1', 1000, false);
  const buy = await api('POST', '/purchases', { locationId: wh.id, partyId: vendor.id, lines: [{ itemId: goods.id, qty: 50, rate: 60 }, { itemId: goods2.id, qty: 50, rate: 60 }] });
  expect(buy.status, JSON.stringify(buy.body)).toBe(201);
  const deal = async (partyId: string) => withTenant(env.db, claims.tid as string, async (tx) => {
    const stages = await ensureStages(tx, { tenantId: claims.tid, companyId } as never);
    const first = stages.find((s) => s.kind === 'open')!;
    return (await tx.insertInto('crm_deals').values({
      tenant_id: claims.tid, company_id: companyId, title: 'Big order', party_id: partyId, stage_id: first.id, value: 0,
    }).returning(['id', 'stage_id']).executeTakeFirstOrThrow());
  });
  const dealState = async (id: string) => withTenant(env.db, claims.tid as string, async (tx) => {
    const d = await tx.selectFrom('crm_deals as d').innerJoin('crm_stages as s', 's.id', 'd.stage_id')
      .select(['d.status', 'd.value', 's.name as stage', 's.sort']).where('d.id', '=', id).executeTakeFirstOrThrow();
    return { ...d, value: Number(d.value) };
  });
  return { api, sales, quoter, wh, local, far, goods, goods2, service, deal, dealState };
}
type Biz = Awaited<ReturnType<typeof biz>>;

const make = async (b: Biz, extra: Record<string, unknown> = {}, lines?: unknown[]) => {
  const r = await b.api('POST', '/quotations', {
    locationId: b.wh.id, partyId: b.local.id, lines: lines ?? [{ itemId: b.goods.id, qty: 2 }], ...extra,
  });
  expect(r.status, JSON.stringify(r.body)).toBe(201);
  return r.body;
};

describe('quotations', () => {
  it('creates with stock and service items, intra-state split, default validity', async () => {
    const b = await biz();
    const q = await make(b, { quoteDate: '2026-11-01' }, [{ itemId: b.goods.id, qty: 2 }, { itemId: b.service.id, qty: 1, rate: 500 }]);
    expect(q.number).toMatch(/^QTN\/26-27\/00001$/);
    expect(q.status).toBe('draft');
    expect(q.kind).toBe('quotation');
    expect(q.validUntil).toBe('2026-11-16');
    expect(q.subtotal).toBe(700);
    expect(q.taxSplit).toEqual({ cgst: 63, sgst: 63, igst: 0 });
    expect(q.taxTotal).toBe(126);
    expect(q.total).toBe(826);
    expect(q.lines).toHaveLength(2);
    expect(q.lines[0]).toMatchObject({ lineNo: 1, itemName: 'Item GD1', taxable: 200, tax: 36, total: 236, rate: 100, gstRate: 18 });
    expect(q.expired).toBe(false);
    expect(q.createdBy.name).toBe('Owner One');
  });

  it('splits inter-state as IGST', async () => {
    const b = await biz();
    const q = await make(b, { partyId: b.far.id });
    expect(q.placeOfSupply).toBe('27');
    expect(q.taxSplit).toEqual({ cgst: 0, sgst: 0, igst: 36 });
    expect(q.total).toBe(236);
  });

  it('applies percent and fixed discounts like invoices', async () => {
    const b = await biz();
    const q = await make(b, {}, [
      { itemId: b.goods.id, qty: 3, discountPct: 10 },
      { itemId: b.goods2.id, qty: 2, discountAmount: 75 },
    ]);
    expect(q.lines[0]).toMatchObject({ taxable: 270, discountPct: 10 });
    expect(q.lines[1]).toMatchObject({ taxable: 425, discountAmount: 75, discountPct: 15 });
    expect(q.subtotal).toBe(695);
    const bad = await b.api('POST', '/quotations', { locationId: b.wh.id, partyId: b.local.id, lines: [{ itemId: b.goods.id, qty: 1, discountAmount: 500 }] });
    expect(bad.status).toBe(400);
    const both = await b.api('POST', '/quotations', { locationId: b.wh.id, partyId: b.local.id, lines: [{ itemId: b.goods.id, qty: 1, discountAmount: 5, discountPct: 5 }] });
    expect(both.status).toBe(400);
  });

  it('numbers proforma separately', async () => {
    const b = await biz();
    const q1 = await make(b);
    const p1 = await make(b, { kind: 'proforma' });
    const q2 = await make(b);
    expect(q1.number).toMatch(/QTN\/\d\d-\d\d\/00001$/);
    expect(q2.number).toMatch(/QTN\/\d\d-\d\d\/00002$/);
    expect(p1.number).toMatch(/^PI\/\d\d-\d\d\/00001$/);
    expect(p1.kind).toBe('proforma');
  });

  it('edits while draft or sent, rejects stale edits and locked states', async () => {
    const b = await biz();
    const q = await make(b);
    const stale = await b.api('PATCH', `/quotations/${q.id}`, { notes: 'x', expectedUpdatedAt: '2020-01-01T00:00:00.000Z' });
    expect(stale.status).toBe(409);
    expect(stale.body.error.code).toBe('STALE_EDIT');
    const ok = await b.api('PATCH', `/quotations/${q.id}`, { notes: 'Net 30', expectedUpdatedAt: q.updatedAt, lines: [{ itemId: b.goods.id, qty: 5 }] });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body.notes).toBe('Net 30');
    expect(ok.body.subtotal).toBe(500);
    expect(ok.body.number).toBe(q.number);
    const sent = await b.api('POST', `/quotations/${q.id}/send`);
    expect(sent.status).toBe(200);
    expect(sent.body.status).toBe('sent');
    expect(sent.body.sentAt).toBeTruthy();
    const again = await b.api('PATCH', `/quotations/${q.id}`, { terms: 'Valid' });
    expect(again.status).toBe(200);
    const kind = await b.api('PATCH', `/quotations/${q.id}`, { kind: 'proforma' });
    expect(kind.status).toBe(400);
    await b.api('POST', `/quotations/${q.id}/cancel`);
    const locked = await b.api('PATCH', `/quotations/${q.id}`, { notes: 'late' });
    expect(locked.status).toBe(409);
    expect(locked.body.error.code).toBe('QUOTATION_LOCKED');
  });

  it('runs the send, accept, decline and cancel flow', async () => {
    const b = await biz();
    const a = await make(b);
    expect((await b.api('POST', `/quotations/${a.id}/send`)).body.status).toBe('sent');
    const acc = await b.api('POST', `/quotations/${a.id}/accept`);
    expect(acc.body.status).toBe('accepted');
    expect(acc.body.acceptedAt).toBeTruthy();
    expect((await b.api('PATCH', `/quotations/${a.id}`, { notes: 'x' })).body.error.code).toBe('QUOTATION_LOCKED');

    const d = await make(b);
    const noReason = await b.api('POST', `/quotations/${d.id}/decline`, {});
    expect(noReason.status).toBe(400);
    const dec = await b.api('POST', `/quotations/${d.id}/decline`, { reason: 'Too costly' });
    expect(dec.body).toMatchObject({ status: 'declined', declineReason: 'Too costly' });
    expect(dec.body.declinedAt).toBeTruthy();
    expect((await b.api('POST', `/quotations/${d.id}/send`)).status).toBe(409);
    expect((await b.api('POST', `/quotations/${d.id}/convert`, { to: 'invoice' })).body.error.code).toBe('QUOTATION_LOCKED');

    const c = await make(b);
    expect((await b.api('POST', `/quotations/${c.id}/cancel`)).body.status).toBe('cancelled');
    expect((await b.api('POST', `/quotations/${c.id}/cancel`)).status).toBe(409);
  });

  it('revises into a new draft and cancels the old one', async () => {
    const b = await biz();
    const q = await make(b, { kind: 'proforma', notes: 'keep me' }, [{ itemId: b.goods.id, qty: 4, discountAmount: 40 }]);
    await b.api('POST', `/quotations/${q.id}/send`);
    const r = await b.api('POST', `/quotations/${q.id}/revise`);
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    expect(r.body).toMatchObject({ status: 'draft', kind: 'proforma', revisionOf: q.id, notes: 'keep me', total: q.total });
    expect(r.body.number).not.toBe(q.number);
    expect(r.body.number).toMatch(/^PI\//);
    expect(r.body.lines[0]).toMatchObject({ qty: 4, discountAmount: 40 });
    const old = await b.api('GET', `/quotations/${q.id}`);
    expect(old.body.status).toBe('cancelled');
    expect((await b.api('POST', `/quotations/${q.id}/revise`)).body.error.code).toBe('QUOTATION_LOCKED');
  });

  it('flags expired drafts and sent quotes only', async () => {
    const b = await biz();
    const q = await make(b, { quoteDate: '2026-01-01', validUntil: '2026-01-10' });
    expect(q.expired).toBe(true);
    const list = await b.api('GET', '/quotations');
    expect(list.body.data.find((x: { id: string }) => x.id === q.id).expired).toBe(true);
    await b.api('POST', `/quotations/${q.id}/accept`);
    expect((await b.api('GET', `/quotations/${q.id}`)).body.expired).toBe(false);
    const open = await make(b, { validUntil: null });
    expect(open.validUntil).toBeNull();
    expect(open.expired).toBe(false);
  });

  it('converts to an invoice with the same total, and marks the deal won', async () => {
    const b = await biz();
    const deal = await b.deal(b.far.id);
    const q = await make(b, { partyId: b.far.id, dealId: deal.id }, [
      { itemId: b.goods.id, qty: 3, discountPct: 12.5 },
      { itemId: b.goods2.id, qty: 2, discountAmount: 33.33 },
      { itemId: b.service.id, qty: 1, rate: 999.99 },
    ]);
    const moved = await b.dealState(deal.id);
    expect(moved.stage).toBe('Quotation sent');
    const r = await b.api('POST', `/quotations/${q.id}/convert`, { to: 'invoice' });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.salesOrderId).toBeNull();
    expect(r.body.quotation.status).toBe('converted');
    expect(r.body.quotation.invoiceId).toBe(r.body.invoiceId);
    const inv = (await b.api('GET', `/invoices/${r.body.invoiceId}`)).body;
    expect(inv.total).toBe(q.total);
    expect(inv.subtotal).toBe(q.subtotal);
    expect(inv.taxTotal).toBe(q.taxTotal);
    expect(inv.igst).toBe(q.taxSplit.igst);
    expect(inv.lines.map((l: { taxableValue: number }) => l.taxableValue)).toEqual(q.lines.map((l: { taxable: number }) => l.taxable));
    expect(await b.dealState(deal.id)).toMatchObject({ status: 'won', stage: 'Won', value: q.total });
    expect((await b.api('POST', `/quotations/${q.id}/convert`, { to: 'invoice' })).body.error.code).toBe('QUOTATION_LOCKED');
  });

  it('refuses an invoice when the quotation was made for another place of supply', async () => {
    const b = await biz();
    const q = await make(b, { partyId: b.far.id, placeOfSupply: '29' });
    expect(q.taxSplit.igst).toBeGreaterThan(0);
    const r = await b.api('POST', `/quotations/${q.id}/convert`, { to: 'invoice' });
    expect(r.status).toBe(409);
    expect(r.body.error.code).toBe('PLACE_OF_SUPPLY_DIFFERS');
    expect((await b.api('GET', `/quotations/${q.id}`)).body.status).toBe('draft');
  });

  it('converts to a sales order, and refuses service lines', async () => {
    const b = await biz();
    const withService = await make(b, {}, [{ itemId: b.goods.id, qty: 1 }, { itemId: b.service.id, qty: 1 }]);
    const no = await b.api('POST', `/quotations/${withService.id}/convert`, { to: 'sales_order' });
    expect(no.status).toBe(409);
    expect(no.body.error.code).toBe('NOT_STOCK_ITEMS');
    expect((await b.api('GET', `/quotations/${withService.id}`)).body.status).toBe('draft');

    const q = await make(b, {}, [{ itemId: b.goods.id, qty: 4, discountPct: 10 }]);
    const r = await b.api('POST', `/quotations/${q.id}/convert`, { to: 'sales_order' });
    expect(r.status, JSON.stringify(r.body)).toBe(200);
    expect(r.body.invoiceId).toBeNull();
    const so = (await b.api('GET', `/sales-orders/${r.body.salesOrderId}`)).body;
    expect(so.total).toBe(q.total);
    expect(so.lines[0]).toMatchObject({ qtyOrdered: 4, discountPct: 10 });
    expect(r.body.quotation).toMatchObject({ status: 'converted', salesOrderId: r.body.salesOrderId });
  });

  it('needs the second permission to convert', async () => {
    const b = await biz();
    const q = await make(b);
    const noSo = await b.quoter('POST', `/quotations/${q.id}/convert`, { to: 'sales_order' });
    expect(noSo.status).toBe(403);
    const noInv = await b.quoter('POST', `/quotations/${q.id}/convert`, { to: 'invoice' });
    expect(noInv.status).toBe(403);
    expect((await b.api('GET', `/quotations/${q.id}`)).body.status).toBe('draft');
    expect((await b.quoter('GET', `/quotations/${q.id}`)).status).toBe(200);
    const viaSales = await b.sales('POST', `/quotations/${q.id}/convert`, { to: 'invoice' });
    expect(viaSales.status, JSON.stringify(viaSales.body)).toBe(200);
  });

  it('needs quotations.manage to write', async () => {
    const b = await biz();
    const viewer = await b.api('GET', '/roles');
    const auditorId = (viewer.body.data as { id: string; name: string }[]).find((r) => r.name === 'Auditor')!.id;
    const email = uniqueEmail('aud');
    await b.api('POST', '/users', { name: 'Aud', email, password: PASSWORD, roleId: auditorId });
    const login = await client(env.app)('POST', '/auth/login', { email, password: PASSWORD });
    const me = (await client(env.app, login.body.accessToken)('GET', '/me')).body;
    const aud = client(env.app, login.body.accessToken, me.companies[0].id);
    expect((await aud('GET', '/quotations')).status).toBe(200);
    const w = await aud('POST', '/quotations', { locationId: b.wh.id, partyId: b.local.id, lines: [{ itemId: b.goods.id, qty: 1 }] });
    expect(w.status).toBe(403);
  });

  it('lists with filters', async () => {
    const b = await biz();
    const deal = await b.deal(b.local.id);
    const q1 = await make(b, { quoteDate: '2026-10-01', dealId: deal.id });
    const q2 = await make(b, { quoteDate: '2026-11-05', partyId: b.far.id, kind: 'proforma' });
    await b.api('POST', `/quotations/${q2.id}/send`);
    const ids = async (qs: string) => ((await b.api('GET', `/quotations?${qs}`)).body.data as { id: string }[]).map((x) => x.id);
    expect(await ids('')).toEqual([q2.id, q1.id]);
    expect(await ids('status=sent')).toEqual([q2.id]);
    expect(await ids('kind=quotation')).toEqual([q1.id]);
    expect(await ids(`partyId=${b.far.id}`)).toEqual([q2.id]);
    expect(await ids(`dealId=${deal.id}`)).toEqual([q1.id]);
    expect(await ids('from=2026-11-01')).toEqual([q2.id]);
    expect(await ids('to=2026-10-31')).toEqual([q1.id]);
    expect((await b.api('GET', '/quotations')).body.total).toBe(2);
  });

  it('rejects unknown deals, vendors and inactive references', async () => {
    const b = await biz();
    const vendor = await b.api('POST', '/quotations', { locationId: b.wh.id, partyId: '00000000-0000-4000-8000-000000000001', lines: [{ itemId: b.goods.id, qty: 1 }] });
    expect(vendor.status).toBe(400);
    const dealBad = await b.api('POST', '/quotations', { locationId: b.wh.id, partyId: b.local.id, dealId: '00000000-0000-4000-8000-000000000001', lines: [{ itemId: b.goods.id, qty: 1 }] });
    expect(dealBad.status).toBe(400);
    const empty = await b.api('POST', '/quotations', { locationId: b.wh.id, partyId: b.local.id, lines: [] });
    expect(empty.status).toBe(400);
  });
});
