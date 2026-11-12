import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { requireFiles } from './files.ts';
import { createInvoice } from './invoices.ts';
import { createPayment } from './payments.ts';
import { addMonths, defaultLocation, round2 } from './services-common.ts';
import { documentRoute } from '../lib/openapi.ts';

/*
 * Memberships: plans, members (a gym member, or a flat in a housing society), subscriptions, recurring bills,
 * dues and door check-in. Bills are ordinary invoices created through createInvoice; receipts go through
 * createPayment. A bill run records one mem_bills row per subscription and period, so repeating a run is safe.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const periodField = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM');
const blank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? undefined : v);
const phoneField = z.string().trim().min(5, 'Enter a phone number').max(20).regex(/^[0-9+() -]+$/, 'Digits only');
const optPhone = z.preprocess(blank, phoneField.optional());

const planFields = {
  name: z.string().trim().min(1, 'Required').max(120),
  billing: z.enum(['upfront', 'monthly']),
  rateBasis: z.enum(['fixed', 'per_sqft']),
  durationUnit: z.enum(['months', 'days']),
  durationCount: z.coerce.number().int().min(1).max(3650),
  price: moneyField,
  gstRate: z.coerce.number().min(0).max(100),
  joiningFee: moneyField,
  freezeDays: z.coerce.number().int().min(0).max(365),
  isActive: z.boolean(),
};
const planCreate = z.object({
  ...planFields,
  billing: planFields.billing.default('upfront'), rateBasis: planFields.rateBasis.default('fixed'),
  durationUnit: planFields.durationUnit.default('months'), durationCount: planFields.durationCount.default(1),
  gstRate: planFields.gstRate.default(18), joiningFee: planFields.joiningFee.default(0),
  freezeDays: planFields.freezeDays.default(0), isActive: planFields.isActive.default(true),
});
const planPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: planFields.name.optional(), price: planFields.price.optional(), joiningFee: planFields.joiningFee.optional(),
  freezeDays: planFields.freezeDays.optional(), isActive: planFields.isActive.optional(),
});

const payBody = z.object({
  accountId: z.uuid(), mode: z.enum(['cash', 'bank', 'upi', 'cheque', 'card']),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), reference: optionalText(60),
});
const memberFields = {
  name: z.string().trim().min(1, 'Required').max(200),
  phone: optPhone,
  emergencyName: optionalText(100), emergencyPhone: optPhone,
  photoFileId: z.preprocess(blank, z.uuid().optional()),
  flatNo: optionalText(30), wing: optionalText(30),
  areaSqft: z.preprocess(blank, z.coerce.number().positive().max(1e6).optional()),
  occupancy: z.preprocess(blank, z.enum(['owner', 'tenant']).optional()),
  notes: optionalText(1000),
};
const memberCreate = z.object({
  ...memberFields,
  planId: z.uuid(), startDate: dateField.optional(), price: moneyField.optional(),
  locationId: z.uuid().optional(), bill: z.boolean().default(true), payment: payBody.optional(),
});
const memberPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: memberFields.name.optional(), phone: z.preprocess((v) => (v === '' ? null : v), phoneField.nullable().optional()),
  emergencyName: nullableText(100), emergencyPhone: z.preprocess((v) => (v === '' ? null : v), phoneField.nullable().optional()),
  photoFileId: z.preprocess((v) => (v === '' ? null : v), z.uuid().nullable().optional()),
  flatNo: nullableText(30), wing: nullableText(30),
  areaSqft: z.preprocess((v) => (v === '' ? null : v), z.coerce.number().positive().max(1e6).nullable().optional()),
  occupancy: z.preprocess((v) => (v === '' ? null : v), z.enum(['owner', 'tenant']).nullable().optional()),
  notes: nullableText(1000), isActive: z.boolean().optional(),
});
const renewBody = z.object({
  planId: z.uuid().optional(), date: dateField.optional(), price: moneyField.optional(),
  locationId: z.uuid().optional(), bill: z.boolean().default(true), payment: payBody.optional(),
});
const freezeBody = z.object({ date: dateField.optional() });
const collectBody = payBody.extend({ locationId: z.uuid().optional() });
const runBody = z.object({ kind: z.enum(['maintenance', 'renewals']), period: periodField.optional(), locationId: z.uuid().optional() });
const runQuery = z.object({ kind: z.enum(['maintenance', 'renewals']), period: periodField.optional() });
const checkinBody = z.object({ memberNo: z.string().trim().max(40).optional(), phone: z.string().trim().max(20).optional() })
  .refine((b) => b.memberNo || b.phone, { message: 'Give a member number or phone', path: ['memberNo'] });
const listQuery = pagingQuery.extend({ status: z.enum(['active', 'expiring', 'expired', 'frozen', 'none']).optional() });

type PlanRow = Awaited<ReturnType<typeof loadPlan>>;

// Helpers ---------------------------------------------------------------------------------------

async function loadPlan(tx: Tx, ctx: RequestContext, id: string) {
  const row = await tx.selectFrom('mem_plans as p').innerJoin('items as i', 'i.id', 'p.item_id')
    .select(['p.id', 'p.item_id', 'p.name', 'p.billing', 'p.rate_basis', 'p.duration_unit', 'p.duration_count', 'p.price',
      'p.joining_fee', 'p.freeze_days', 'p.is_active', 'p.updated_at', 'i.gst_rate'])
    .where('p.id', '=', id).where('p.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row) throw notFound('Plan');
  return row;
}
const planJson = (p: PlanRow) => ({
  id: p.id, name: p.name, billing: p.billing, rateBasis: p.rate_basis, durationUnit: p.duration_unit, durationCount: p.duration_count,
  price: p.price, gstRate: p.gst_rate, joiningFee: p.joining_fee, freezeDays: p.freeze_days, isActive: p.is_active, updatedAt: p.updated_at,
});

async function loadMember(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('mem_members').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Member');
  return row;
}

/** End date of a term that begins on `start`: the last day covered. */
function termEnd(start: string, unit: string, count: number): string {
  return unit === 'days' ? addDays(start, count - 1) : addDays(addMonths(start, count), -1);
}

/** Status of a member from the latest subscription row. */
function statusExpr(today: string) {
  const soon = addDays(today, 7);
  return sql<string>`case
    when s.id is null then 'none'
    when s.status = 'frozen' then 'frozen'
    when s.end_date is null then 'active'
    when s.end_date < ${today}::date then 'expired'
    when s.end_date <= ${soon}::date then 'expiring'
    else 'active' end`;
}

function memberSelect(tx: Tx, ctx: RequestContext, today: string) {
  return tx.selectFrom('mem_members as m')
    .leftJoinLateral(
      (eb) => eb.selectFrom('mem_subscriptions as x').selectAll('x')
        .whereRef('x.member_id', '=', 'm.id').where('x.status', '!=', 'cancelled')
        .orderBy(sql`x.end_date desc nulls first`).orderBy('x.created_at', 'desc').limit(1).as('s'),
      (j) => j.onTrue())
    .leftJoin('mem_plans as p', 'p.id', 's.plan_id')
    .select(['m.id', 'm.member_no', 'm.name', 'm.phone', 'm.flat_no', 'm.wing', 'm.area_sqft', 'm.occupancy', 'm.is_active', 'm.party_id',
      'm.photo_file_id', 'm.updated_at', 's.id as sub_id', 's.end_date', 's.start_date', 'p.name as plan_name', 'p.id as plan_id'])
    .select(statusExpr(today).as('mstatus'))
    .where('m.company_id', '=', ctx.companyId);
}
type MemberRow = Awaited<ReturnType<ReturnType<typeof memberSelect>['execute']>>[number];

const memberBrief = (r: MemberRow) => ({
  id: r.id, memberNo: r.member_no, name: r.name, phone: r.phone, flatNo: r.flat_no, wing: r.wing, areaSqft: r.area_sqft,
  occupancy: r.occupancy, isActive: r.is_active, photoFileId: r.photo_file_id, status: r.mstatus,
  plan: r.plan_id ? { id: r.plan_id, name: r.plan_name } : null, startDate: r.start_date, endDate: r.end_date,
  daysLeft: r.end_date ? daysBetween(todayIst(), r.end_date) : null,
});

async function dueOf(tx: Tx, ctx: RequestContext, partyId: string) {
  const rows = await tx.selectFrom('invoices').select(['id', 'number', 'invoice_date', 'total', 'amount_paid'])
    .where('company_id', '=', ctx.companyId).where('party_id', '=', partyId).where('status', '=', 'posted')
    .orderBy('invoice_date').orderBy('created_at').execute();
  const open = rows.map((r) => ({ ...r, due: round2(r.total - r.amount_paid) })).filter((r) => r.due > 0.004);
  return { open, total: round2(open.reduce((s, r) => s + r.due, 0)) };
}

async function chargeItem(tx: Tx, ctx: RequestContext, kind: 'join', gstRate: number): Promise<string> {
  const sku = `MEM-JOIN-${gstRate}`;
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId).where(sql`lower(sku)`, '=', sku.toLowerCase()).executeTakeFirst();
  if (found) return found.id;
  const row = await tx.insertInto('items').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, name: kind === 'join' ? `Joining fee (${gstRate}%)` : 'Charge', sku, hsn_code: '999799',
    unit: 'NOS', gst_rate: gstRate, sale_price: 0, track_stock: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

type Line = { itemId: string; qty: number; rate: number; description: string };

async function billMember(ctx: RequestContext, tx: Tx, member: { id: string; party_id: string }, lines: Line[],
  note: string, locationId: string | undefined, link?: { subscriptionId: string; period: string }) {
  const invoice = await createInvoice(ctx, tx, {
    locationId: await defaultLocation(tx, ctx, locationId), partyId: member.party_id, invoiceDate: todayIst(), lines,
    notes: note, custom: undefined,
  } as never);
  if (link) {
    await tx.insertInto('mem_bills').values({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, member_id: member.id, subscription_id: link.subscriptionId,
      period: link.period, invoice_id: invoice.id,
    }).execute();
  }
  return invoice;
}

async function receive(ctx: RequestContext, tx: Tx, partyId: string, pay: z.infer<typeof payBody>, allocs: { docId: string; amount: number }[], note: string) {
  return createPayment(ctx, tx, {
    kind: 'receipt', partyId, date: undefined, accountId: pay.accountId, mode: pay.mode, reference: pay.reference,
    amount: pay.amount, tdsAmount: undefined, notes: note, allocations: allocs,
  } as never);
}

/** Lines for one billing of a plan. A per sq ft plan bills the flat's area at the rate. */
function planLine(plan: { item_id: string; name: string; rate_basis: string }, member: { area_sqft: number | null; flat_no: string | null }, price: number, label: string): Line {
  if (plan.rate_basis === 'per_sqft') {
    if (!member.area_sqft) throw badRequest('Add the flat area in sq ft first.', { areaSqft: 'Required' });
    return { itemId: plan.item_id, qty: Number(member.area_sqft), rate: price, description: `${plan.name} ${label}, ${member.area_sqft} sq ft` };
  }
  return { itemId: plan.item_id, qty: 1, rate: price, description: `${plan.name} ${label}` };
}

async function addSubscription(ctx: RequestContext, tx: Tx, memberId: string, plan: PlanRow, start: string, price: number) {
  const end = plan.billing === 'monthly' ? null : termEnd(start, plan.duration_unit, plan.duration_count);
  const row = await tx.insertInto('mem_subscriptions').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, member_id: memberId, plan_id: plan.id, start_date: start, end_date: end,
    price, created_by: ctx.userId,
  }).returning(['id', 'start_date', 'end_date']).executeTakeFirstOrThrow();
  return row;
}

async function latestSub(tx: Tx, memberId: string) {
  return tx.selectFrom('mem_subscriptions').selectAll().where('member_id', '=', memberId).where('status', '!=', 'cancelled')
    .orderBy(sql`end_date desc nulls first`).orderBy('created_at', 'desc').limit(1).executeTakeFirst();
}

/** Renews from the old end date, or from today when the membership has lapsed. */
async function renewMember(ctx: RequestContext, tx: Tx, member: Awaited<ReturnType<typeof loadMember>>,
  o: { planId?: string; date?: string; price?: number; bill: boolean; locationId?: string; payment?: z.infer<typeof payBody> }) {
  const today = o.date ?? todayIst();
  const last = await latestSub(tx, member.id);
  const plan = await loadPlan(tx, ctx, o.planId ?? last?.plan_id ?? (() => { throw badRequest('Choose a plan.', { planId: 'Required' }); })());
  if (!plan.is_active) throw badRequest('This plan is not active.', { planId: 'Inactive' });
  if (last?.status === 'frozen') throw conflict('End the freeze before renewing.', 'FROZEN');
  const start = last?.end_date && last.end_date >= today ? addDays(last.end_date, 1) : today;
  const price = o.price ?? plan.price;
  const sub = await addSubscription(ctx, tx, member.id, plan, start, price);
  let invoice = null;
  let payment = null;
  if (o.bill && plan.billing === 'upfront') {
    invoice = await billMember(ctx, tx, member, [planLine(plan, member, price, `${sub.start_date} to ${sub.end_date}`)],
      `Renewal ${member.member_no}`, o.locationId, { subscriptionId: sub.id, period: `renew:${sub.start_date}` });
  }
  if (o.payment) {
    if (!invoice) throw badRequest('There is no bill to pay against.', { payment: 'No bill' });
    payment = await receive(ctx, tx, member.party_id, { ...o.payment, amount: Math.min(o.payment.amount, invoice.total) },
      [{ docId: invoice.id, amount: Math.min(o.payment.amount, invoice.total) }], `Membership ${member.member_no}`);
  }
  await writeAudit(tx, auditOf(ctx), 'mem_member', member.id, 'renew', null, { subscriptionId: sub.id, start: sub.start_date, end: sub.end_date });
  return { subscription: sub, invoice, payment };
}

function reminderText(company: string, name: string, flat: string | null, due: number, society: boolean) {
  const what = society ? `maintenance dues${flat ? ` for flat ${flat}` : ''}` : 'membership dues';
  return `Dear ${name}, your ${what} of Rs ${due.toFixed(2)} at ${company} are pending. Please pay at the earliest. Thank you.`;
}

function needDesk(ctx: RequestContext) { ctx.require('memberships.manage'); }
function needView(ctx: RequestContext) { ctx.require('memberships.view', 'memberships.manage'); }

// Routes ----------------------------------------------------------------------------------------

export async function membershipRoutes(app: FastifyInstance) {
  // Plans -------------------------------------------------------------------------------------

  app.get('/memberships/plans', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('mem_plans as p').innerJoin('items as i', 'i.id', 'p.item_id')
        .select(['p.id', 'p.item_id', 'p.name', 'p.billing', 'p.rate_basis', 'p.duration_unit', 'p.duration_count', 'p.price',
          'p.joining_fee', 'p.freeze_days', 'p.is_active', 'p.updated_at', 'i.gst_rate'])
        .where('p.company_id', '=', ctx.companyId).orderBy('p.is_active', 'desc').orderBy('p.name').execute();
      return { data: rows.map(planJson) };
    });
  });

  app.post('/memberships/plans', async (req, reply) => {
    const ctx = req.ctx;
    needDesk(ctx);
    const b = parse(planCreate, req.body);
    if (b.rateBasis === 'per_sqft' && b.billing !== 'monthly') throw badRequest('A rate per sq ft is billed monthly.', { billing: 'Use monthly' });
    const out = await ctx.tx(async (tx) => {
      const item = await tx.insertInto('items').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, sku: `MEM-${crypto.randomUUID().slice(0, 8).toUpperCase()}`,
        hsn_code: '999799', unit: b.rateBasis === 'per_sqft' ? 'SQFT' : 'NOS', gst_rate: b.gstRate, sale_price: b.price, track_stock: false,
      }).returning('id').executeTakeFirstOrThrow();
      const row = await tx.insertInto('mem_plans').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: item.id, name: b.name, billing: b.billing, rate_basis: b.rateBasis,
        duration_unit: b.durationUnit, duration_count: b.durationCount, price: b.price, joining_fee: b.joiningFee,
        freeze_days: b.freezeDays, is_active: b.isActive,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'mem_plan', row.id, 'create', null, { name: b.name });
      return planJson(await loadPlan(tx, ctx, row.id));
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/memberships/plans/:id', async (req) => {
    const ctx = req.ctx;
    needDesk(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(planPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadPlan(tx, ctx, id);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'plan');
      const changes = definedOnly({ name: b.name, price: b.price, joining_fee: b.joiningFee, freeze_days: b.freezeDays, is_active: b.isActive });
      if (Object.keys(changes).length) await tx.updateTable('mem_plans').set(changes as never).where('id', '=', id).execute();
      if (b.name !== undefined || b.price !== undefined) {
        await tx.updateTable('items').set(definedOnly({ name: b.name, sale_price: b.price }) as never).where('id', '=', before.item_id).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'mem_plan', id, 'update', null, { fields: Object.keys(changes) });
      return planJson(await loadPlan(tx, ctx, id));
    });
  });

  // Home --------------------------------------------------------------------------------------

  app.get('/memberships/summary', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const today = todayIst();
    return ctx.tx(async (tx) => {
      const rows = await memberSelect(tx, ctx, today).where('m.is_active', '=', true).execute();
      const count = (s: string) => rows.filter((r) => r.mstatus === s).length;
      const visits = await tx.selectFrom('mem_visits').select((eb) => eb.fn.countAll<number>().as('n'))
        .where('company_id', '=', ctx.companyId).where('visit_date', '=', today).executeTakeFirstOrThrow();
      const dues = await tx.selectFrom('invoices as i').innerJoin('mem_members as m', 'm.party_id', 'i.party_id')
        .select([sql<number>`count(distinct m.id)`.as('members'), sql<number>`coalesce(sum(i.total - i.amount_paid), 0)`.as('amount')])
        .where('i.company_id', '=', ctx.companyId).where('i.status', '=', 'posted').where(sql<boolean>`i.total - i.amount_paid > 0.004`).executeTakeFirstOrThrow();
      return {
        today, active: count('active') + count('expiring'), expiring: count('expiring'), expired: count('expired'),
        frozen: count('frozen'), noPlan: count('none'), total: rows.length, visitsToday: Number(visits.n),
        duesMembers: Number(dues.members), duesAmount: round2(Number(dues.amount)),
      };
    });
  });

  // Members -----------------------------------------------------------------------------------

  app.get('/memberships/members', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const q = parse(listQuery, req.query);
    const today = todayIst();
    return ctx.tx(async (tx) => {
      let base = memberSelect(tx, ctx, today);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('m.name', 'ilike', t), eb('m.phone', 'ilike', t), eb('m.member_no', 'ilike', t), eb('m.flat_no', 'ilike', t)]));
      }
      if (q.status) base = base.where(statusExpr(today), '=', q.status);
      const all = await base.orderBy('m.name').orderBy('m.member_no').execute();
      return { total: all.length, data: all.slice(q.offset, q.offset + q.limit).map(memberBrief) };
    });
  });

  app.post('/memberships/members', async (req, reply) => {
    const ctx = req.ctx;
    needDesk(ctx);
    const b = parse(memberCreate, req.body);
    if (b.bill) ctx.require('invoices.create');
    if (b.payment) ctx.require('payments.create');
    const out = await ctx.tx(async (tx) => {
      const plan = await loadPlan(tx, ctx, b.planId);
      if (!plan.is_active) throw badRequest('This plan is not active.', { planId: 'Inactive' });
      if (plan.rate_basis === 'per_sqft' && !b.areaSqft) throw badRequest('Add the flat area in sq ft.', { areaSqft: 'Required' });
      if (b.photoFileId) await requireFiles(tx, [{ id: b.photoFileId, field: 'photoFileId' }], true);
      const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const party = await tx.insertInto('parties').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: b.name, phone: b.phone ?? null,
        address: b.flatNo ? `${b.wing ? `${b.wing} ` : ''}${b.flatNo}` : null, state_code: company.state_code, gstin: null,
        email: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
      }).returning('id').executeTakeFirstOrThrow();
      const memberNo = await nextNumber(tx, ctx, 'member', financialYear(todayIst()));
      const m = await tx.insertInto('mem_members').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, party_id: party.id, member_no: memberNo, name: b.name, phone: b.phone ?? null,
        emergency_name: b.emergencyName ?? null, emergency_phone: b.emergencyPhone ?? null, photo_file_id: b.photoFileId ?? null,
        flat_no: b.flatNo ?? null, wing: b.wing ?? null, area_sqft: b.areaSqft ?? null, occupancy: b.occupancy ?? null,
        notes: b.notes ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const member = await loadMember(tx, ctx, m.id);
      const start = b.startDate ?? todayIst();
      const price = b.price ?? plan.price;
      const sub = await addSubscription(ctx, tx, member.id, plan, start, price);
      let invoice = null;
      let payment = null;
      if (b.bill) {
        const lines: Line[] = [];
        if (plan.billing === 'upfront') lines.push(planLine(plan, member, price, `${sub.start_date} to ${sub.end_date}`));
        if (plan.joining_fee > 0) lines.push({ itemId: await chargeItem(tx, ctx, 'join', plan.gst_rate), qty: 1, rate: plan.joining_fee, description: 'Joining fee' });
        if (lines.length) invoice = await billMember(ctx, tx, member, lines, `Enrolment ${memberNo}`, b.locationId, { subscriptionId: sub.id, period: 'start' });
      }
      if (b.payment) {
        if (!invoice) throw badRequest('There is no bill to pay against.', { payment: 'No bill' });
        const amt = Math.min(b.payment.amount, invoice.total);
        payment = await receive(ctx, tx, party.id, { ...b.payment, amount: amt }, [{ docId: invoice.id, amount: amt }], `Membership ${memberNo}`);
      }
      await writeAudit(tx, auditOf(ctx), 'mem_member', member.id, 'create', null, { memberNo, planId: plan.id });
      return { memberId: member.id, memberNo, subscription: sub, invoice, payment };
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/memberships/members/:id', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const m = await loadMember(tx, ctx, id);
      const brief = (await memberSelect(tx, ctx, todayIst()).where('m.id', '=', id).executeTakeFirstOrThrow());
      const subs = await tx.selectFrom('mem_subscriptions as s').innerJoin('mem_plans as p', 'p.id', 's.plan_id')
        .select(['s.id', 's.plan_id', 'p.name as plan_name', 'p.freeze_days', 's.start_date', 's.end_date', 's.price', 's.status', 's.frozen_from', 's.freeze_days_used'])
        .where('s.member_id', '=', id).orderBy('s.start_date', 'desc').orderBy('s.created_at', 'desc').execute();
      const bills = await tx.selectFrom('mem_bills as b').innerJoin('invoices as i', 'i.id', 'b.invoice_id')
        .select(['i.id as invoice_id', 'i.number', 'i.invoice_date', 'i.total', 'i.amount_paid', 'i.status', 'b.period'])
        .where('b.member_id', '=', id).orderBy('i.invoice_date', 'desc').limit(60).execute();
      const visits = await tx.selectFrom('mem_visits').select(['id', 'visit_date', 'visited_at']).where('member_id', '=', id)
        .orderBy('visited_at', 'desc').limit(30).execute();
      const due = await dueOf(tx, ctx, m.party_id);
      return {
        ...memberBrief(brief), partyId: m.party_id, emergencyName: m.emergency_name, emergencyPhone: m.emergency_phone, notes: m.notes,
        subscriptions: subs.map((s) => ({
          id: s.id, planId: s.plan_id, planName: s.plan_name, startDate: s.start_date, endDate: s.end_date, price: s.price, status: s.status,
          frozenFrom: s.frozen_from, freezeDaysUsed: s.freeze_days_used, freezeDaysAllowed: s.freeze_days,
        })),
        bills: bills.map((x) => ({ invoiceId: x.invoice_id, number: x.number, date: x.invoice_date, total: x.total, amountPaid: x.amount_paid, status: x.status, period: x.period })),
        visits: visits.map((v) => ({ id: v.id, date: v.visit_date, at: v.visited_at })),
        dueAmount: due.total, dueInvoices: due.open.map((d) => ({ id: d.id, number: d.number, date: d.invoice_date, due: d.due })),
      };
    });
  });

  app.patch<{ Params: { id: string } }>('/memberships/members/:id', async (req) => {
    const ctx = req.ctx;
    needDesk(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(memberPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadMember(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'member');
      if (b.photoFileId) await requireFiles(tx, [{ id: b.photoFileId, field: 'photoFileId' }], true);
      const changes = definedOnly({
        name: b.name, phone: b.phone, emergency_name: b.emergencyName, emergency_phone: b.emergencyPhone, photo_file_id: b.photoFileId,
        flat_no: b.flatNo, wing: b.wing, area_sqft: b.areaSqft, occupancy: b.occupancy, notes: b.notes, is_active: b.isActive,
      });
      if (Object.keys(changes).length) await tx.updateTable('mem_members').set(changes as never).where('id', '=', id).execute();
      if (b.name !== undefined || b.phone !== undefined) {
        await tx.updateTable('parties').set(definedOnly({ name: b.name, phone: b.phone }) as never).where('id', '=', before.party_id).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'mem_member', id, 'update', null, { fields: Object.keys(changes) });
      const row = await memberSelect(tx, ctx, todayIst()).where('m.id', '=', id).executeTakeFirstOrThrow();
      return { ...memberBrief(row), updatedAt: row.updated_at };
    });
  });

  app.post<{ Params: { id: string } }>('/memberships/members/:id/renew', async (req, reply) => {
    const ctx = req.ctx;
    needDesk(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(renewBody, req.body);
    if (b.bill) ctx.require('invoices.create');
    if (b.payment) ctx.require('payments.create');
    const out = await ctx.tx(async (tx) => renewMember(ctx, tx, await loadMember(tx, ctx, id, true), b));
    return reply.status(201).send(out);
  });

  // Freeze ------------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/memberships/subscriptions/:id/freeze', async (req) => {
    const ctx = req.ctx;
    needDesk(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(freezeBody, req.body ?? {});
    return ctx.tx(async (tx) => {
      const s = await tx.selectFrom('mem_subscriptions as s').innerJoin('mem_plans as p', 'p.id', 's.plan_id')
        .select(['s.id', 's.status', 's.freeze_days_used', 'p.freeze_days']).where('s.id', '=', id).where('s.company_id', '=', ctx.companyId).forUpdate('s').executeTakeFirst();
      if (!s) throw notFound('Subscription');
      if (s.status !== 'active') throw conflict(s.status === 'frozen' ? 'Already frozen.' : 'Only an active subscription can be frozen.', 'BAD_STATE');
      if (s.freeze_days - s.freeze_days_used <= 0) throw conflict('This plan has no freeze days left.', 'NO_FREEZE_DAYS', { allowed: s.freeze_days, used: s.freeze_days_used });
      await tx.updateTable('mem_subscriptions').set({ status: 'frozen', frozen_from: b.date ?? todayIst() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mem_subscription', id, 'freeze', null, {});
      return { id, status: 'frozen', daysLeft: s.freeze_days - s.freeze_days_used };
    });
  });

  app.post<{ Params: { id: string } }>('/memberships/subscriptions/:id/unfreeze', async (req) => {
    const ctx = req.ctx;
    needDesk(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(freezeBody, req.body ?? {});
    return ctx.tx(async (tx) => {
      const s = await tx.selectFrom('mem_subscriptions as s').innerJoin('mem_plans as p', 'p.id', 's.plan_id')
        .select(['s.id', 's.status', 's.frozen_from', 's.end_date', 's.freeze_days_used', 'p.freeze_days']).where('s.id', '=', id).where('s.company_id', '=', ctx.companyId).forUpdate('s').executeTakeFirst();
      if (!s) throw notFound('Subscription');
      if (s.status !== 'frozen' || !s.frozen_from) throw conflict('This subscription is not frozen.', 'BAD_STATE');
      const days = Math.max(daysBetween(s.frozen_from, b.date ?? todayIst()), 0);
      const room = Math.max(s.freeze_days - s.freeze_days_used, 0);
      const extend = Math.min(days, room);
      const end = s.end_date ? addDays(s.end_date, extend) : null;
      await tx.updateTable('mem_subscriptions').set({
        status: 'active', frozen_from: null, end_date: end, freeze_days_used: s.freeze_days_used + extend,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'mem_subscription', id, 'unfreeze', null, { days, extended: extend });
      return { id, status: 'active', frozenDays: days, extendedDays: extend, endDate: end };
    });
  });

  // Dues and collection -----------------------------------------------------------------------

  app.get('/memberships/dues', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    return ctx.tx(async (tx) => {
      const company = await tx.selectFrom('companies').select(['name', 'business_type']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const rows = await tx.selectFrom('invoices as i').innerJoin('mem_members as m', 'm.party_id', 'i.party_id')
        .select(['m.id', 'm.member_no', 'm.name', 'm.phone', 'm.flat_no', 'm.wing',
          sql<number>`sum(i.total - i.amount_paid)`.as('due'), sql<string>`min(i.invoice_date)`.as('oldest'), sql<number>`count(*)`.as('bills')])
        .where('i.company_id', '=', ctx.companyId).where('i.status', '=', 'posted').where(sql<boolean>`i.total - i.amount_paid > 0.004`)
        .groupBy(['m.id', 'm.member_no', 'm.name', 'm.phone', 'm.flat_no', 'm.wing']).orderBy(sql`sum(i.total - i.amount_paid)`, 'desc').execute();
      const society = company.business_type === 'housing_society';
      const data = rows.map((r) => ({
        memberId: r.id, memberNo: r.member_no, name: r.name, phone: r.phone, flatNo: r.flat_no, wing: r.wing, due: round2(Number(r.due)),
        oldest: r.oldest, bills: Number(r.bills), reminder: reminderText(company.name, r.name, r.flat_no, Number(r.due), society),
      }));
      return { total: round2(data.reduce((s, d) => s + d.due, 0)), data };
    });
  });

  app.post<{ Params: { id: string } }>('/memberships/members/:id/collect', async (req, reply) => {
    const ctx = req.ctx;
    needDesk(ctx);
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(collectBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const m = await loadMember(tx, ctx, id, true);
      const due = await dueOf(tx, ctx, m.party_id);
      if (b.amount > due.total + 0.004) throw badRequest(`Dues are only ${due.total.toFixed(2)}.`, { amount: 'More than dues' });
      let left = b.amount;
      const allocs: { docId: string; amount: number }[] = [];
      for (const inv of due.open) {
        if (left <= 0.004) break;
        const take = round2(Math.min(left, inv.due));
        allocs.push({ docId: inv.id, amount: take });
        left = round2(left - take);
      }
      const payment = await receive(ctx, tx, m.party_id, b, allocs, `Dues ${m.member_no}`);
      await writeAudit(tx, auditOf(ctx), 'mem_member', id, 'collect', null, { amount: b.amount });
      return { payment, remaining: round2(due.total - b.amount) };
    });
    return reply.status(201).send(out);
  });

  // Recurring bills ---------------------------------------------------------------------------

  /** The subscriptions a run would bill, with the reason for any it skips. */
  async function runCandidates(tx: Tx, ctx: RequestContext, kind: 'maintenance' | 'renewals', period: string) {
    const today = todayIst();
    if (kind === 'maintenance') {
      const first = `${period}-01`;
      const lastDay = addDays(addMonths(first, 1), -1);
      const rows = await tx.selectFrom('mem_subscriptions as s').innerJoin('mem_plans as p', 'p.id', 's.plan_id').innerJoin('mem_members as m', 'm.id', 's.member_id')
        .leftJoin('mem_bills as b', (j) => j.onRef('b.subscription_id', '=', 's.id').on('b.period', '=', period))
        .select(['s.id as sub_id', 's.price', 'm.id as member_id', 'm.area_sqft', 'm.flat_no', 'm.party_id', 'm.member_no', 'p.rate_basis', 'p.item_id', 'p.name as plan_name', 'b.id as billed'])
        .where('s.company_id', '=', ctx.companyId).where('p.billing', '=', 'monthly').where('s.status', '=', 'active').where('m.is_active', '=', true)
        .where('s.start_date', '<=', lastDay).where((eb) => eb.or([eb('s.end_date', 'is', null), eb('s.end_date', '>=', first)]))
        .orderBy('m.member_no').execute();
      return rows.map((r) => ({
        ...r, key: period, label: `${period}`,
        skip: r.billed ? 'already billed' : r.rate_basis === 'per_sqft' && !r.area_sqft ? 'no area on file' : null,
      }));
    }
    const soon = addDays(today, 7);
    const members = await memberSelect(tx, ctx, today).where('m.is_active', '=', true).execute();
    return members.filter((r) => r.sub_id && (r.mstatus === 'expiring' || r.mstatus === 'expired') && r.end_date && r.end_date <= soon)
      .map((r) => ({ sub_id: r.sub_id!, member_id: r.id, party_id: r.party_id, member_no: r.member_no, plan_name: r.plan_name, skip: null as string | null, label: r.end_date! }));
  }

  app.get('/memberships/bills/preview', async (req) => {
    const ctx = req.ctx;
    needDesk(ctx);
    const q = parse(runQuery, req.query);
    const period = q.period ?? todayIst().slice(0, 7);
    return ctx.tx(async (tx) => {
      const rows = await runCandidates(tx, ctx, q.kind, period);
      const billable = rows.filter((r) => !r.skip);
      return {
        kind: q.kind, period, count: billable.length, alreadyBilled: rows.filter((r) => r.skip === 'already billed').length,
        skipped: rows.filter((r) => r.skip && r.skip !== 'already billed').map((r) => ({ memberNo: r.member_no, reason: r.skip })),
      };
    });
  });

  app.post('/memberships/bills/generate', async (req) => {
    const ctx = req.ctx;
    needDesk(ctx);
    ctx.require('invoices.create');
    const b = parse(runBody, req.body);
    const period = b.period ?? todayIst().slice(0, 7);
    return ctx.tx(async (tx) => {
      const rows = (await runCandidates(tx, ctx, b.kind, period)).filter((r) => !r.skip);
      let created = 0;
      let total = 0;
      for (const r of rows) {
        const member = await loadMember(tx, ctx, r.member_id, true);
        if (b.kind === 'maintenance') {
          const sub = await tx.selectFrom('mem_subscriptions as s').innerJoin('mem_plans as p', 'p.id', 's.plan_id')
            .select(['s.id', 's.price', 'p.item_id', 'p.name', 'p.rate_basis']).where('s.id', '=', r.sub_id).executeTakeFirstOrThrow();
          const line = planLine(sub, member, sub.price, period);
          const inv = await billMember(ctx, tx, member, [line], `${sub.name} ${period}`, b.locationId, { subscriptionId: sub.id, period });
          total += inv.total;
        } else {
          const out = await renewMember(ctx, tx, member, { bill: true, locationId: b.locationId });
          total += out.invoice?.total ?? 0;
        }
        created += 1;
      }
      await writeAudit(tx, auditOf(ctx), 'mem_bill_run', null, 'generate', null, { kind: b.kind, period, created });
      return { kind: b.kind, period, created, total: round2(total) };
    });
  });

  // Check-in ----------------------------------------------------------------------------------

  app.post('/memberships/checkin', async (req) => {
    const ctx = req.ctx;
    ctx.require('memberships.checkin', 'memberships.manage');
    const b = parse(checkinBody, req.body);
    const today = todayIst();
    return ctx.tx(async (tx) => {
      let q = tx.selectFrom('mem_members').selectAll().where('company_id', '=', ctx.companyId);
      q = b.memberNo ? q.where(sql`lower(member_no)`, '=', b.memberNo.toLowerCase()) : q.where('phone', '=', b.phone!);
      const found = await q.limit(5).execute();
      if (!found.length) throw notFound('Member');
      if (found.length > 1) throw badRequest('More than one member has this phone. Use the member number.', { phone: 'Not unique' });
      const m = found[0]!;
      const refuse = (reason: string, code: string) => conflict(reason, code, { memberId: m.id, memberNo: m.member_no, name: m.name });
      if (!m.is_active) throw refuse('This member is inactive.', 'MEMBER_INACTIVE');
      const subs = await tx.selectFrom('mem_subscriptions').select(['status', 'start_date', 'end_date', 'frozen_from'])
        .where('member_id', '=', m.id).where('status', '!=', 'cancelled').execute();
      const covering = subs.find((s) => s.status === 'active' && s.start_date <= today && (!s.end_date || s.end_date >= today));
      if (!covering) {
        const frozen = subs.find((s) => s.status === 'frozen');
        if (frozen) throw refuse(`Membership is frozen${frozen.frozen_from ? ` since ${frozen.frozen_from}` : ''}.`, 'MEMBERSHIP_FROZEN');
        const ends = subs.map((s) => s.end_date).filter((e): e is string => !!e).sort();
        const lastEnd = ends[ends.length - 1];
        if (lastEnd && lastEnd < today) throw refuse(`Membership expired on ${lastEnd} (${daysBetween(lastEnd, today)} days ago).`, 'MEMBERSHIP_EXPIRED');
        if (subs.length) throw refuse(`Membership starts on ${subs.map((s) => s.start_date).sort()[0]}.`, 'MEMBERSHIP_NOT_STARTED');
        throw refuse('This member has no plan.', 'NO_PLAN');
      }
      const dup = await tx.selectFrom('mem_visits').select('id').where('member_id', '=', m.id).where('visit_date', '=', today).executeTakeFirst();
      await tx.insertInto('mem_visits').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, member_id: m.id, visit_date: today, checked_by: ctx.userId }).execute();
      const left = covering.end_date ? daysBetween(today, covering.end_date) : null;
      return {
        ok: true, memberId: m.id, memberNo: m.member_no, name: m.name, endDate: covering.end_date, daysLeft: left,
        expiringSoon: left !== null && left <= 7, repeatToday: !!dup,
      };
    });
  });

  app.get('/memberships/visits', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const q = parse(z.object({ date: dateField.optional() }), req.query);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('mem_visits as v').innerJoin('mem_members as m', 'm.id', 'v.member_id')
        .select(['v.id', 'v.visited_at', 'm.id as member_id', 'm.member_no', 'm.name'])
        .where('v.company_id', '=', ctx.companyId).where('v.visit_date', '=', q.date ?? todayIst()).orderBy('v.visited_at', 'desc').limit(200).execute();
      return { data: rows.map((r) => ({ id: r.id, at: r.visited_at, memberId: r.member_id, memberNo: r.member_no, name: r.name })) };
    });
  });
}

documentRoute('POST', '/memberships/plans', { body: planCreate });
documentRoute('PATCH', '/memberships/plans/:id', { body: planPatch });
documentRoute('POST', '/memberships/members', { body: memberCreate });
documentRoute('PATCH', '/memberships/members/:id', { body: memberPatch });
documentRoute('POST', '/memberships/members/:id/renew', { body: renewBody });
documentRoute('POST', '/memberships/members/:id/collect', { body: collectBody });
documentRoute('POST', '/memberships/bills/generate', { body: runBody });
documentRoute('POST', '/memberships/checkin', { body: checkinBody });
