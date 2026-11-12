import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
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
import { documentRoute } from '../lib/openapi.ts';

/*
 * Practice management for advocates. A matter is visible to its responsible advocate, its team and anyone with
 * legal.manage. Everything under a matter (hearings, tasks, entries, documents, bills) follows that rule.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const FEE_TYPES = ['fixed_stage', 'per_hearing', 'hourly', 'retainer'] as const;
const STATUSES = ['open', 'disposed', 'closed'] as const;
const DISB_TYPES = ['court_fee', 'stamp_duty', 'clerkage', 'other'] as const;
const DISB_LABEL: Record<string, string> = { court_fee: 'Court fee', stamp_duty: 'Stamp duty', clerkage: 'Clerkage', other: 'Expense' };
const round2 = (n: number) => Math.round(n * 100) / 100;
const blankNull = (v: unknown) => (v === '' ? null : v);

const matterFields = {
  title: z.string().trim().min(1, 'Required').max(200),
  clientId: z.uuid(),
  opposingParty: optionalText(200),
  court: optionalText(200),
  caseType: optionalText(100),
  caseNo: optionalText(60),
  caseYear: z.preprocess(blankNull, z.coerce.number().int().min(1900).max(2100).optional()),
  filingDate: z.preprocess(blankNull, dateField.optional()),
  stage: optionalText(100),
  advocateId: z.uuid().optional(),
  teamIds: z.array(z.uuid()).max(30).optional(),
  feeType: z.enum(FEE_TYPES).optional(),
  agreedFee: moneyField.optional(),
  hourlyRate: z.preprocess(blankNull, moneyField.nullable().optional()),
  notes: optionalText(2000),
};
const matterCreate = z.object(matterFields);
const matterPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  title: matterFields.title.optional(),
  clientId: z.uuid().optional(),
  opposingParty: nullableText(200),
  court: nullableText(200),
  caseType: nullableText(100),
  caseNo: nullableText(60),
  caseYear: z.preprocess(blankNull, z.coerce.number().int().min(1900).max(2100).nullable().optional()),
  filingDate: z.preprocess(blankNull, dateField.nullable().optional()),
  stage: nullableText(100),
  status: z.enum(STATUSES).optional(),
  advocateId: z.uuid().optional(),
  teamIds: matterFields.teamIds,
  feeType: z.enum(FEE_TYPES).optional(),
  agreedFee: matterFields.agreedFee,
  hourlyRate: matterFields.hourlyRate,
  notes: nullableText(2000),
});
const matterList = pagingQuery.extend({
  status: z.enum(STATUSES).optional(),
  advocateId: z.uuid().optional(),
  clientId: z.uuid().optional(),
  court: z.string().trim().max(200).optional(),
});

const hearingCreate = z.object({
  hearingDate: dateField,
  court: optionalText(200),
  purpose: optionalText(300),
});
const hearingPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  hearingDate: dateField.optional(),
  court: nullableText(200),
  purpose: nullableText(300),
});
const outcomeBody = z.object({
  outcome: z.string().trim().min(1, 'Write what happened').max(2000),
  nextDate: z.preprocess(blankNull, dateField.nullable().optional()),
  nextPurpose: optionalText(300),
  nextCourt: optionalText(200),
  stage: optionalText(100),
});
const causeQuery = z.object({
  from: dateField.optional(),
  to: dateField.optional(),
  advocateId: z.uuid().optional(),
});

const taskCreate = z.object({
  title: z.string().trim().min(1, 'Required').max(200),
  kind: z.enum(['limitation', 'filing', 'other']).default('other'),
  dueDate: dateField,
  assigneeId: z.uuid().optional(),
  notes: optionalText(1000),
});
const taskPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  title: taskCreate.shape.title.optional(),
  kind: z.enum(['limitation', 'filing', 'other']).optional(),
  dueDate: dateField.optional(),
  assigneeId: z.preprocess(blankNull, z.uuid().nullable().optional()),
  notes: nullableText(1000),
  status: z.enum(['open', 'done']).optional(),
});
const taskList = z.object({
  matterId: z.uuid().optional(),
  assigneeId: z.uuid().optional(),
  status: z.enum(['open', 'done']).optional(),
  overdue: z.enum(['true', 'false']).optional(),
  limit: z.coerce.number().int().min(1).max(500).default(200),
});

const entryBase = {
  entryDate: dateField.optional(),
  description: z.string().trim().min(1, 'Required').max(300),
  billable: z.boolean().optional(),
  userId: z.uuid().optional(),
  hearingId: z.uuid().optional(),
};
const entryCreate = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('time'), minutes: z.coerce.number().int().min(1, 'At least 1 minute').max(1440, 'At most 24 hours'), rate: moneyField.optional(), ...entryBase }),
  z.object({ kind: z.literal('fee'), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), ...entryBase }),
  z.object({ kind: z.literal('disbursement'), disbType: z.enum(DISB_TYPES), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), ...entryBase }),
]);
const entryPatch = z.object({
  entryDate: dateField.optional(),
  description: entryBase.description.optional(),
  billable: z.boolean().optional(),
  minutes: z.coerce.number().int().min(1).max(1440).optional(),
  rate: moneyField.optional(),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero').optional(),
  disbType: z.enum(DISB_TYPES).optional(),
});
const entryList = z.object({
  matterId: z.uuid().optional(),
  userId: z.uuid().optional(),
  billed: z.enum(['true', 'false']).optional(),
  from: dateField.optional(),
  to: dateField.optional(),
  limit: z.coerce.number().int().min(1).max(500).default(200),
});

const billBody = z.object({
  entryIds: z.array(z.uuid()).min(1, 'Choose at least one entry').max(200),
  invoiceDate: dateField.optional(),
  locationId: z.uuid().optional(),
  reverseCharge: z.boolean().optional(),
  notes: optionalText(500),
});
const receiptBody = z.object({
  kind: z.enum(['advance', 'fee']),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  accountId: z.uuid(),
  mode: z.enum(['cash', 'bank', 'upi', 'cheque', 'card']),
  reference: optionalText(60),
  date: dateField.optional(),
  invoiceId: z.uuid().optional(),
  tdsAmount: moneyField.optional(),
});
const docBody = z.object({ fileId: z.uuid(), label: optionalText(200) });
const rateBody = z.object({ hourlyRate: moneyField });

// Helpers ---------------------------------------------------------------------------------------

const canManage = (ctx: RequestContext) => ctx.can('legal.manage');
function needView(ctx: RequestContext) { ctx.require('legal.view', 'legal.work', 'legal.manage'); }
function needWork(ctx: RequestContext) { ctx.require('legal.work', 'legal.manage'); }
function needManage(ctx: RequestContext) { ctx.require('legal.manage'); }

/** SQL condition for matters (alias m) the caller may see. */
function visibleSql(ctx: RequestContext) {
  if (canManage(ctx)) return sql<boolean>`true`;
  return sql<boolean>`(m.advocate_id = ${ctx.userId} or exists (select 1 from legal_matter_team t where t.matter_id = m.id and t.user_id = ${ctx.userId}))`;
}

function matterSelect(tx: Tx, ctx: RequestContext) {
  return tx.selectFrom('legal_matters as m')
    .innerJoin('parties as p', 'p.id', 'm.client_id')
    .innerJoin('users as u', 'u.id', 'm.advocate_id')
    .selectAll('m')
    .select(['p.name as client_name', 'p.gstin as client_gstin', 'u.name as advocate_name'])
    .select(sql<string | null>`(select min(h.hearing_date)::text from legal_hearings h where h.matter_id = m.id and h.status = 'scheduled' and h.hearing_date >= ${todayIst()}::date)`.as('next_hearing_date'))
    .where('m.company_id', '=', ctx.companyId)
    .where(visibleSql(ctx));
}
type MatterRow = Awaited<ReturnType<ReturnType<typeof matterSelect>['executeTakeFirstOrThrow']>>;

async function loadMatterRow(tx: Tx, ctx: RequestContext, id: string): Promise<MatterRow> {
  const row = await matterSelect(tx, ctx).where('m.id', '=', id).executeTakeFirst();
  if (!row) throw notFound('Matter');
  return row;
}

async function teamOf(tx: Tx, matterIds: string[]) {
  if (!matterIds.length) return new Map<string, { id: string; name: string }[]>();
  const rows = await tx.selectFrom('legal_matter_team as t').innerJoin('users as u', 'u.id', 't.user_id')
    .select(['t.matter_id', 'u.id', 'u.name']).where('t.matter_id', 'in', matterIds).orderBy('u.name').execute();
  const map = new Map<string, { id: string; name: string }[]>();
  for (const r of rows) map.set(r.matter_id, [...(map.get(r.matter_id) ?? []), { id: r.id, name: r.name }]);
  return map;
}

const matterJson = (r: MatterRow, team: { id: string; name: string }[] = []) => ({
  id: r.id, matterNo: r.matter_no, title: r.title, clientId: r.client_id, clientName: r.client_name, clientGstin: r.client_gstin,
  opposingParty: r.opposing_party, court: r.court, caseType: r.case_type, caseNo: r.case_no, caseYear: r.case_year,
  filingDate: r.filing_date, stage: r.stage, status: r.status, advocateId: r.advocate_id, advocateName: r.advocate_name, team,
  feeType: r.fee_type, agreedFee: r.agreed_fee, hourlyRate: r.hourly_rate, notes: r.notes, closedAt: r.closed_at,
  nextHearingDate: r.next_hearing_date, createdAt: r.created_at, updatedAt: r.updated_at,
});

/** Every id must be an active user with access to this company. */
async function requireStaff(tx: Tx, ctx: RequestContext, ids: string[], field: string) {
  const unique = [...new Set(ids)];
  if (!unique.length) return;
  const rows = await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id')
    .select('u.id').distinct().where('ur.company_id', '=', ctx.companyId).where('u.is_active', '=', true).where('u.id', 'in', unique).execute();
  if (rows.length !== unique.length) throw badRequest('Choose people who work in this business.', { [field]: 'Not found' });
}

async function requireClient(tx: Tx, ctx: RequestContext, id: string) {
  const p = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!p) throw badRequest('Client not found.', { clientId: 'Not found' });
  if (p.type === 'vendor') throw badRequest('Choose a client, not a vendor.', { clientId: 'Not a client' });
}

async function setTeam(tx: Tx, ctx: RequestContext, matterId: string, ids: string[]) {
  await tx.deleteFrom('legal_matter_team').where('matter_id', '=', matterId).execute();
  const unique = [...new Set(ids)];
  if (unique.length) {
    await tx.insertInto('legal_matter_team').values(unique.map((u) => ({ tenant_id: ctx.tenantId, matter_id: matterId, user_id: u }))).execute();
  }
}

const hearingJson = (h: {
  id: string; matter_id: string; hearing_date: string; court: string | null; purpose: string | null; status: string;
  outcome: string | null; next_hearing_id: string | null; recorded_at: Date | null; updated_at: Date;
}) => ({
  id: h.id, matterId: h.matter_id, hearingDate: h.hearing_date, court: h.court, purpose: h.purpose, status: h.status,
  outcome: h.outcome, nextHearingId: h.next_hearing_id, recordedAt: h.recorded_at, updatedAt: h.updated_at,
});

const taskJson = (t: {
  id: string; matter_id: string; title: string; kind: string; due_date: string; assignee_id: string | null; status: string;
  done_at: Date | null; notes: string | null; updated_at: Date; assignee_name?: string | null; matter_no?: string; matter_title?: string;
}) => ({
  id: t.id, matterId: t.matter_id, matterNo: t.matter_no, matterTitle: t.matter_title, title: t.title, kind: t.kind, dueDate: t.due_date,
  assigneeId: t.assignee_id, assigneeName: t.assignee_name ?? null, status: t.status, doneAt: t.done_at, notes: t.notes,
  overdue: t.status === 'open' && t.due_date < todayIst(), updatedAt: t.updated_at,
});

type EntryRow = {
  id: string; matter_id: string; kind: string; disb_type: string | null; user_id: string; entry_date: string; minutes: number | null;
  rate: number | null; amount: number; billable: boolean; description: string; hearing_id: string | null; invoice_id: string | null;
  updated_at: Date; user_name?: string | null; matter_no?: string; matter_title?: string; invoice_number?: string | null;
};
const entryJson = (e: EntryRow) => ({
  id: e.id, matterId: e.matter_id, matterNo: e.matter_no, matterTitle: e.matter_title, kind: e.kind, disbType: e.disb_type,
  userId: e.user_id, userName: e.user_name ?? null, entryDate: e.entry_date, minutes: e.minutes, rate: e.rate, amount: e.amount,
  billable: e.billable, description: e.description, hearingId: e.hearing_id, invoiceId: e.invoice_id,
  invoiceNumber: e.invoice_number ?? null, billed: e.invoice_id !== null, updatedAt: e.updated_at,
});

function entrySelect(tx: Tx) {
  return tx.selectFrom('legal_entries as e')
    .innerJoin('legal_matters as m', 'm.id', 'e.matter_id')
    .innerJoin('users as u', 'u.id', 'e.user_id')
    .leftJoin('invoices as i', 'i.id', 'e.invoice_id')
    .selectAll('e')
    .select(['u.name as user_name', 'm.matter_no', 'm.title as matter_title', 'i.number as invoice_number']);
}

/** A person's hourly rate: their own rate card, else the matter's rate, else zero. */
async function rateFor(tx: Tx, ctx: RequestContext, userId: string, matterRate: number | null) {
  const r = await tx.selectFrom('legal_rates').select('hourly_rate').where('company_id', '=', ctx.companyId).where('user_id', '=', userId).executeTakeFirst();
  return r?.hourly_rate ?? matterRate ?? 0;
}

const FEE_SKU = 'LEGAL-FEE';
const REIMB_SKU = 'LEGAL-REIMB';
/** Service items for fee bills, created on first bill. Reimbursements carry no GST. Reverse charge is a flag on the invoice, not a separate item. */
async function billItem(tx: Tx, ctx: RequestContext, sku: string): Promise<string> {
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId).where(sql`lower(sku)`, '=', sku.toLowerCase()).executeTakeFirst();
  if (found) return found.id;
  const spec = {
    [FEE_SKU]: { name: 'Legal professional fees', hsn: '998212', gst: 18 },
    [REIMB_SKU]: { name: 'Reimbursement of expenses paid on behalf of client', hsn: '998212', gst: 0 },
  }[sku]!;
  const row = await tx.insertInto('items').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, name: spec.name, sku, hsn_code: spec.hsn, unit: 'NOS', gst_rate: spec.gst,
    sale_price: 0, track_stock: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

const money = (n: number) => `Rs ${n.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

async function unbilledTotals(tx: Tx, matterId: string) {
  const rows = await tx.selectFrom('legal_entries').select(['kind', 'billable']).select((eb) => eb.fn.sum<string>('amount').as('amount'))
    .where('matter_id', '=', matterId).where('invoice_id', 'is', null).groupBy(['kind', 'billable']).execute();
  const out = { time: 0, fee: 0, disbursement: 0, nonBillable: 0 };
  for (const r of rows) {
    if (!r.billable) out.nonBillable = round2(out.nonBillable + Number(r.amount));
    else out[r.kind as 'time' | 'fee' | 'disbursement'] = round2(Number(r.amount));
  }
  return out;
}

// Routes ----------------------------------------------------------------------------------------

export async function legalRoutes(app: FastifyInstance) {
  // Staff to pick from ------------------------------------------------------------------------
  app.get('/legal/staff', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id')
        .select(['u.id', 'u.name']).distinct().where('ur.company_id', '=', ctx.companyId).where('u.is_active', '=', true).orderBy('u.name').execute();
      return { data: rows };
    });
  });

  // Home --------------------------------------------------------------------------------------
  app.get('/legal/home', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const today = todayIst();
    const tomorrow = addDays(today, 1);
    return ctx.tx(async (tx) => {
      const hearings = await causeList(tx, ctx, today, tomorrow);
      const pending = await tx.selectFrom('legal_hearings as h').innerJoin('legal_matters as m', 'm.id', 'h.matter_id')
        .innerJoin('parties as p', 'p.id', 'm.client_id')
        .select(['h.id', 'h.matter_id', 'h.hearing_date', 'h.court', 'h.purpose', 'm.matter_no', 'm.title', 'p.name as client_name'])
        .where('h.company_id', '=', ctx.companyId).where('h.status', '=', 'scheduled').where('h.hearing_date', '<', today)
        .where(visibleSql(ctx)).where('m.status', '=', 'open').orderBy('h.hearing_date', 'desc').limit(50).execute();
      const tasks = await tx.selectFrom('legal_tasks as t').innerJoin('legal_matters as m', 'm.id', 't.matter_id')
        .leftJoin('users as a', 'a.id', 't.assignee_id').selectAll('t')
        .select(['a.name as assignee_name', 'm.matter_no', 'm.title as matter_title'])
        .where('t.company_id', '=', ctx.companyId).where('t.status', '=', 'open').where('t.due_date', '<=', addDays(today, 14))
        .where(visibleSql(ctx)).orderBy('t.due_date').limit(100).execute();
      const noDate = await matterSelect(tx, ctx).where('m.status', '=', 'open')
        .where(sql<boolean>`not exists (select 1 from legal_hearings h where h.matter_id = m.id and h.status = 'scheduled' and h.hearing_date >= ${today}::date)`)
        .orderBy('m.created_at', 'desc').limit(100).execute();
      return {
        today, tomorrow, hearings,
        pendingOutcome: pending.map((h) => ({
          id: h.id, matterId: h.matter_id, matterNo: h.matter_no, matterTitle: h.title, clientName: h.client_name,
          hearingDate: h.hearing_date, court: h.court, purpose: h.purpose,
        })),
        deadlines: tasks.map(taskJson),
        withoutNextDate: noDate.map((r) => matterJson(r)),
      };
    });
  });

  // Matters -----------------------------------------------------------------------------------
  app.get('/legal/matters', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const q = parse(matterList, req.query);
    return ctx.tx(async (tx) => {
      let base = matterSelect(tx, ctx);
      if (q.status) base = base.where('m.status', '=', q.status);
      if (q.advocateId) base = base.where('m.advocate_id', '=', q.advocateId);
      if (q.clientId) base = base.where('m.client_id', '=', q.clientId);
      if (q.court) base = base.where('m.court', 'ilike', likeTerm(q.court));
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('m.title', 'ilike', t), eb('m.matter_no', 'ilike', t), eb('m.case_no', 'ilike', t),
          eb('p.name', 'ilike', t), eb('m.opposing_party', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('m.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      const teams = await teamOf(tx, rows.map((r) => r.id));
      return { data: rows.map((r) => matterJson(r, teams.get(r.id))), total };
    });
  });

  app.post('/legal/matters', async (req, reply) => {
    const ctx = req.ctx;
    needWork(ctx);
    const b = parse(matterCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      await requireClient(tx, ctx, b.clientId);
      const advocateId = canManage(ctx) ? (b.advocateId ?? ctx.userId) : ctx.userId;
      const team = [...new Set(b.teamIds ?? [])];
      await requireStaff(tx, ctx, [advocateId, ...team], 'teamIds');
      if (b.feeType === 'hourly' && b.agreedFee) throw badRequest('Hourly matters use an hourly rate, not an agreed fee.', { agreedFee: 'Not used for hourly' });
      const number = await nextNumber(tx, ctx, 'matter', financialYear(todayIst()));
      const row = await tx.insertInto('legal_matters').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_no: number, title: b.title, client_id: b.clientId,
        opposing_party: b.opposingParty ?? null, court: b.court ?? null, case_type: b.caseType ?? null, case_no: b.caseNo ?? null,
        case_year: b.caseYear ?? null, filing_date: b.filingDate ?? null, stage: b.stage ?? null, advocate_id: advocateId,
        fee_type: b.feeType ?? 'hourly', agreed_fee: b.agreedFee ?? 0, hourly_rate: b.hourlyRate ?? null, notes: b.notes ?? null,
        created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await setTeam(tx, ctx, row.id, team);
      await writeAudit(tx, auditOf(ctx), 'legal_matter', row.id, 'create', null, { matterNo: number, title: b.title, clientId: b.clientId });
      const m = await loadMatterRow(tx, ctx, row.id);
      return matterJson(m, (await teamOf(tx, [row.id])).get(row.id));
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/legal/matters/:id', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const m = await loadMatterRow(tx, ctx, id);
      const team = (await teamOf(tx, [id])).get(id);
      const hearings = await tx.selectFrom('legal_hearings').selectAll().where('matter_id', '=', id).orderBy('hearing_date', 'desc').execute();
      const openTasks = await tx.selectFrom('legal_tasks').select((eb) => eb.fn.countAll<number>().as('n')).where('matter_id', '=', id).where('status', '=', 'open').executeTakeFirstOrThrow();
      const billed = await tx.selectFrom('legal_bills as b').innerJoin('invoices as i', 'i.id', 'b.invoice_id')
        .select([sql<string>`coalesce(sum(i.total) filter (where i.status = 'posted'), 0)`.as('total'),
          sql<string>`coalesce(sum(i.amount_paid) filter (where i.status = 'posted'), 0)`.as('paid')])
        .where('b.matter_id', '=', id).executeTakeFirstOrThrow();
      const adv = await tx.selectFrom('legal_receipts as r').innerJoin('payments as p', 'p.id', 'r.payment_id')
        .select(sql<string>`coalesce(sum(p.amount), 0)`.as('amount')).where('r.matter_id', '=', id).where('r.kind', '=', 'advance').where('p.status', '=', 'posted').executeTakeFirstOrThrow();
      return {
        ...matterJson(m, team),
        hearings: hearings.map(hearingJson),
        summary: {
          unbilled: await unbilledTotals(tx, id), openTasks: Number(openTasks.n), billedTotal: round2(Number(billed.total)),
          billedPaid: round2(Number(billed.paid)), advanceReceived: round2(Number(adv.amount)),
        },
      };
    });
  });

  app.patch<{ Params: { id: string } }>('/legal/matters/:id', async (req) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(matterPatch, req.body);
    return ctx.tx(async (tx) => {
      const m = await loadMatterRow(tx, ctx, id);
      assertFresh(m.updated_at, b.expectedUpdatedAt, 'matter');
      const mine = m.advocate_id === ctx.userId;
      // Team members may update case details; only the advocate or a manager changes people and fees.
      const restricted = b.advocateId !== undefined || b.teamIds !== undefined || b.feeType !== undefined || b.agreedFee !== undefined || b.hourlyRate !== undefined || b.clientId !== undefined;
      if (restricted && !canManage(ctx) && !mine) throw badRequest('Only the responsible advocate or a manager can change people, client or fees.', { _: 'Not allowed' });
      if (b.advocateId !== undefined && !canManage(ctx)) throw badRequest('Only a manager can reassign the matter.', { advocateId: 'Not allowed' });
      if (b.clientId) await requireClient(tx, ctx, b.clientId);
      if (b.advocateId) await requireStaff(tx, ctx, [b.advocateId], 'advocateId');
      if (b.teamIds) await requireStaff(tx, ctx, b.teamIds, 'teamIds');
      const changes = definedOnly({
        title: b.title, client_id: b.clientId, opposing_party: b.opposingParty, court: b.court, case_type: b.caseType, case_no: b.caseNo,
        case_year: b.caseYear, filing_date: b.filingDate, stage: b.stage, status: b.status, advocate_id: b.advocateId,
        fee_type: b.feeType, agreed_fee: b.agreedFee, hourly_rate: b.hourlyRate, notes: b.notes,
        closed_at: b.status === undefined ? undefined : b.status === 'open' ? null : (m.closed_at ?? new Date()),
      });
      if (Object.keys(changes).length) await tx.updateTable('legal_matters').set(changes).where('id', '=', id).execute();
      if (b.teamIds) await setTeam(tx, ctx, id, b.teamIds);
      await writeAudit(tx, auditOf(ctx), 'legal_matter', id, 'update', null, { fields: Object.keys(changes).concat(b.teamIds ? ['team'] : []) });
      // The caller may lose sight of the matter by reassigning it; report from the manager's view only when still visible.
      const fresh = await loadMatterRow(tx, ctx, id).catch(() => null);
      if (!fresh) return { id };
      return matterJson(fresh, (await teamOf(tx, [id])).get(id));
    });
  });

  // Hearings and the court diary --------------------------------------------------------------
  async function causeListRows(tx: Tx, ctx: RequestContext, from: string, to: string, advocateId?: string) {
    let q = tx.selectFrom('legal_hearings as h').innerJoin('legal_matters as m', 'm.id', 'h.matter_id')
      .innerJoin('parties as p', 'p.id', 'm.client_id').innerJoin('users as u', 'u.id', 'm.advocate_id')
      .select(['h.id', 'h.matter_id', 'h.hearing_date', 'h.court', 'h.purpose', 'h.status', 'm.matter_no', 'm.title', 'm.case_no',
        'm.case_year', 'm.stage', 'm.court as matter_court', 'p.name as client_name', 'u.name as advocate_name', 'm.advocate_id'])
      .where('h.company_id', '=', ctx.companyId).where('h.status', '=', 'scheduled')
      .where('h.hearing_date', '>=', from).where('h.hearing_date', '<=', to).where('m.status', '=', 'open').where(visibleSql(ctx));
    if (advocateId) q = q.where('m.advocate_id', '=', advocateId);
    return q.orderBy('h.hearing_date').orderBy('h.court').orderBy('m.matter_no').execute();
  }
  const causeList = async (tx: Tx, ctx: RequestContext, from: string, to: string, advocateId?: string) =>
    (await causeListRows(tx, ctx, from, to, advocateId)).map((h) => ({
      id: h.id, matterId: h.matter_id, matterNo: h.matter_no, matterTitle: h.title, caseNo: h.case_no, caseYear: h.case_year,
      stage: h.stage, clientName: h.client_name, advocateId: h.advocate_id, advocateName: h.advocate_name,
      hearingDate: h.hearing_date, court: h.court ?? h.matter_court, purpose: h.purpose,
    }));

  app.get('/legal/cause-list', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const q = parse(causeQuery, req.query);
    const from = q.from ?? todayIst();
    const to = q.to ?? addDays(from, 1);
    if (to < from) throw badRequest('The end date is before the start date.', { to: 'Before start' });
    if (new Date(to).getTime() - new Date(from).getTime() > 62 * 86400000) throw badRequest('Choose a range of at most 62 days.', { to: 'Too long' });
    return ctx.tx(async (tx) => ({ from, to, data: await causeList(tx, ctx, from, to, q.advocateId) }));
  });

  app.post<{ Params: { id: string } }>('/legal/matters/:id/hearings', async (req, reply) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(hearingCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const m = await loadMatterRow(tx, ctx, id);
      if (m.status !== 'open') throw conflict('This matter is not open.', 'MATTER_CLOSED');
      const row = await tx.insertInto('legal_hearings').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_id: id, hearing_date: b.hearingDate, court: b.court ?? m.court,
        purpose: b.purpose ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'legal_hearing', row.id, 'create', null, { matterId: id, hearingDate: b.hearingDate });
      return hearingJson(row);
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/legal/matters/:id/hearings', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await loadMatterRow(tx, ctx, id);
      const rows = await tx.selectFrom('legal_hearings').selectAll().where('matter_id', '=', id).orderBy('hearing_date', 'desc').execute();
      return { data: rows.map(hearingJson) };
    });
  });

  async function loadHearing(tx: Tx, ctx: RequestContext, id: string, lock = false) {
    let q = tx.selectFrom('legal_hearings').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
    if (lock) q = q.forUpdate();
    const h = await q.executeTakeFirst();
    if (!h) throw notFound('Hearing');
    const m = await loadMatterRow(tx, ctx, h.matter_id);
    return { h, m };
  }

  app.patch<{ Params: { id: string } }>('/legal/hearings/:id', async (req) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(hearingPatch, req.body);
    return ctx.tx(async (tx) => {
      const { h } = await loadHearing(tx, ctx, id, true);
      assertFresh(h.updated_at, b.expectedUpdatedAt, 'hearing');
      if (h.status !== 'scheduled') throw conflict('This hearing already has an outcome.', 'ALREADY_RECORDED');
      const changes = definedOnly({ hearing_date: b.hearingDate, court: b.court, purpose: b.purpose });
      if (Object.keys(changes).length) await tx.updateTable('legal_hearings').set(changes).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'legal_hearing', id, 'update', null, { fields: Object.keys(changes) });
      return hearingJson(await tx.selectFrom('legal_hearings').selectAll().where('id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.post<{ Params: { id: string } }>('/legal/hearings/:id/outcome', async (req) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(outcomeBody, req.body);
    return ctx.tx(async (tx) => {
      const { h, m } = await loadHearing(tx, ctx, id, true);
      if (h.status !== 'scheduled') throw conflict('The outcome of this hearing is already recorded.', 'ALREADY_RECORDED');
      if (b.nextDate && b.nextDate < h.hearing_date) throw badRequest('The next date is before this hearing.', { nextDate: 'Before this hearing' });
      let nextId: string | null = null;
      if (b.nextDate) {
        const next = await tx.insertInto('legal_hearings').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_id: h.matter_id, hearing_date: b.nextDate,
          court: b.nextCourt ?? h.court, purpose: b.nextPurpose ?? null, created_by: ctx.userId,
        }).returning('id').executeTakeFirstOrThrow();
        nextId = next.id;
      }
      await tx.updateTable('legal_hearings').set({
        status: 'held', outcome: b.outcome, next_hearing_id: nextId, recorded_by: ctx.userId, recorded_at: new Date(),
      }).where('id', '=', id).execute();
      if (b.stage) await tx.updateTable('legal_matters').set({ stage: b.stage }).where('id', '=', h.matter_id).execute();
      let fee = null;
      if (m.fee_type === 'per_hearing' && m.agreed_fee > 0) {
        const e = await tx.insertInto('legal_entries').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_id: h.matter_id, kind: 'fee', user_id: m.advocate_id,
          entry_date: h.hearing_date, amount: m.agreed_fee, billable: true, hearing_id: id,
          description: `Appearance fee, ${h.purpose ?? 'hearing'} on ${h.hearing_date}`.slice(0, 300),
        }).returning('id').executeTakeFirstOrThrow();
        fee = e.id;
      }
      await writeAudit(tx, auditOf(ctx), 'legal_hearing', id, 'outcome', null, { nextDate: b.nextDate ?? null, nextHearingId: nextId, feeEntryId: fee });
      const done = await tx.selectFrom('legal_hearings').selectAll().where('id', '=', id).executeTakeFirstOrThrow();
      const next = nextId ? await tx.selectFrom('legal_hearings').selectAll().where('id', '=', nextId).executeTakeFirstOrThrow() : null;
      return { hearing: hearingJson(done), next: next ? hearingJson(next) : null, feeEntryId: fee, warning: next ? null : 'No next date is set for this matter.' };
    });
  });

  // Tasks and deadlines -----------------------------------------------------------------------
  app.get('/legal/tasks', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const q = parse(taskList, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('legal_tasks as t').innerJoin('legal_matters as m', 'm.id', 't.matter_id')
        .leftJoin('users as a', 'a.id', 't.assignee_id').selectAll('t')
        .select(['a.name as assignee_name', 'm.matter_no', 'm.title as matter_title'])
        .where('t.company_id', '=', ctx.companyId).where(visibleSql(ctx));
      if (q.matterId) base = base.where('t.matter_id', '=', q.matterId);
      if (q.assigneeId) base = base.where('t.assignee_id', '=', q.assigneeId);
      if (q.status) base = base.where('t.status', '=', q.status);
      if (q.overdue === 'true') base = base.where('t.status', '=', 'open').where('t.due_date', '<', todayIst());
      const rows = await base.orderBy('t.due_date').limit(q.limit).execute();
      return { data: rows.map(taskJson) };
    });
  });

  app.post<{ Params: { id: string } }>('/legal/matters/:id/tasks', async (req, reply) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(taskCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      await loadMatterRow(tx, ctx, id);
      if (b.assigneeId) await requireStaff(tx, ctx, [b.assigneeId], 'assigneeId');
      const row = await tx.insertInto('legal_tasks').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_id: id, title: b.title, kind: b.kind, due_date: b.dueDate,
        assignee_id: b.assigneeId ?? null, notes: b.notes ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'legal_task', row.id, 'create', null, { matterId: id, dueDate: b.dueDate });
      return taskJson(row);
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/legal/tasks/:id', async (req) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(taskPatch, req.body);
    return ctx.tx(async (tx) => {
      const t = await tx.selectFrom('legal_tasks').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!t) throw notFound('Task');
      await loadMatterRow(tx, ctx, t.matter_id);
      assertFresh(t.updated_at, b.expectedUpdatedAt, 'task');
      if (b.assigneeId) await requireStaff(tx, ctx, [b.assigneeId], 'assigneeId');
      const changes = definedOnly({
        title: b.title, kind: b.kind, due_date: b.dueDate, assignee_id: b.assigneeId, notes: b.notes, status: b.status,
        done_at: b.status === undefined ? undefined : b.status === 'done' ? (t.done_at ?? new Date()) : null,
      });
      if (Object.keys(changes).length) await tx.updateTable('legal_tasks').set(changes).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'legal_task', id, 'update', null, { fields: Object.keys(changes) });
      return taskJson(await tx.selectFrom('legal_tasks').selectAll().where('id', '=', id).executeTakeFirstOrThrow());
    });
  });

  // Time and expense entries ------------------------------------------------------------------
  app.get('/legal/entries', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const q = parse(entryList, req.query);
    return ctx.tx(async (tx) => {
      let base = entrySelect(tx).where('e.company_id', '=', ctx.companyId).where(visibleSql(ctx));
      if (q.matterId) base = base.where('e.matter_id', '=', q.matterId);
      if (q.userId) base = base.where('e.user_id', '=', q.userId);
      if (q.billed === 'true') base = base.where('e.invoice_id', 'is not', null);
      if (q.billed === 'false') base = base.where('e.invoice_id', 'is', null);
      if (q.from) base = base.where('e.entry_date', '>=', q.from);
      if (q.to) base = base.where('e.entry_date', '<=', q.to);
      const rows = await base.orderBy('e.entry_date', 'desc').orderBy('e.created_at', 'desc').limit(q.limit).execute();
      return { data: rows.map(entryJson) };
    });
  });

  app.post<{ Params: { id: string } }>('/legal/matters/:id/entries', async (req, reply) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(entryCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const m = await loadMatterRow(tx, ctx, id);
      if (m.status === 'closed') throw conflict('This matter is closed.', 'MATTER_CLOSED');
      if (b.userId && b.userId !== ctx.userId && !canManage(ctx)) throw badRequest('You can only enter your own time.', { userId: 'Not allowed' });
      if (b.kind === 'fee' && !canManage(ctx) && m.advocate_id !== ctx.userId) throw badRequest('Only the responsible advocate or a manager adds fees.', { kind: 'Not allowed' });
      const userId = b.userId ?? ctx.userId;
      await requireStaff(tx, ctx, [userId], 'userId');
      const date = b.entryDate ?? todayIst();
      if (date > todayIst()) throw badRequest('The date cannot be in the future.', { entryDate: 'In the future' });
      if (b.hearingId) {
        const hh = await tx.selectFrom('legal_hearings').select('id').where('id', '=', b.hearingId).where('matter_id', '=', id).executeTakeFirst();
        if (!hh) throw badRequest('Hearing not found on this matter.', { hearingId: 'Not found' });
      }
      let minutes: number | null = null, rate: number | null = null, amount: number, disb: string | null = null;
      if (b.kind === 'time') {
        minutes = b.minutes;
        rate = b.rate ?? await rateFor(tx, ctx, userId, m.hourly_rate);
        amount = round2(minutes * rate / 60);
      } else {
        amount = b.amount;
        if (b.kind === 'disbursement') disb = b.disbType;
      }
      const row = await tx.insertInto('legal_entries').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_id: id, kind: b.kind, disb_type: disb, user_id: userId,
        entry_date: date, minutes, rate, amount, billable: b.billable ?? true, description: b.description, hearing_id: b.hearingId ?? null,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'legal_entry', row.id, 'create', null, { matterId: id, kind: b.kind, amount });
      return entryJson(await entrySelect(tx).where('e.id', '=', row.id).executeTakeFirstOrThrow());
    });
    return reply.status(201).send(out);
  });

  async function loadEntry(tx: Tx, ctx: RequestContext, id: string) {
    const e = await tx.selectFrom('legal_entries').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
    if (!e) throw notFound('Entry');
    await loadMatterRow(tx, ctx, e.matter_id);
    if (e.invoice_id) throw conflict('This entry is already on a bill.', 'ALREADY_BILLED');
    if (e.user_id !== ctx.userId && !canManage(ctx)) throw badRequest('Only the person who made this entry or a manager can change it.', { _: 'Not allowed' });
    return e;
  }

  app.patch<{ Params: { id: string } }>('/legal/entries/:id', async (req) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(entryPatch, req.body);
    return ctx.tx(async (tx) => {
      const e = await loadEntry(tx, ctx, id);
      if (b.entryDate && b.entryDate > todayIst()) throw badRequest('The date cannot be in the future.', { entryDate: 'In the future' });
      const changes: Record<string, unknown> = definedOnly({ entry_date: b.entryDate, description: b.description, billable: b.billable });
      if (e.kind === 'time') {
        const minutes = b.minutes ?? e.minutes!;
        const rate = b.rate ?? e.rate ?? 0;
        Object.assign(changes, { minutes, rate, amount: round2(minutes * rate / 60) });
      } else if (b.amount !== undefined) changes.amount = b.amount;
      if (e.kind === 'disbursement' && b.disbType) changes.disb_type = b.disbType;
      if (Object.keys(changes).length) await tx.updateTable('legal_entries').set(changes).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'legal_entry', id, 'update', null, { fields: Object.keys(changes) });
      return entryJson(await entrySelect(tx).where('e.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.delete<{ Params: { id: string } }>('/legal/entries/:id', async (req, reply) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const e = await loadEntry(tx, ctx, id);
      await tx.deleteFrom('legal_entries').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'legal_entry', id, 'delete', null, { matterId: e.matter_id, kind: e.kind, amount: e.amount });
    });
    return reply.status(204).send();
  });

  // Rates -------------------------------------------------------------------------------------
  app.get('/legal/rates', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id')
        .leftJoin('legal_rates as r', (j) => j.onRef('r.user_id', '=', 'u.id').on('r.company_id', '=', ctx.companyId))
        .select(['u.id', 'u.name', 'r.hourly_rate']).distinct().where('ur.company_id', '=', ctx.companyId).where('u.is_active', '=', true).orderBy('u.name').execute();
      return { data: rows.map((r) => ({ userId: r.id, name: r.name, hourlyRate: r.hourly_rate })) };
    });
  });

  const setRate = async (req: { ctx: RequestContext; params: { userId: string }; body: unknown }) => {
    const ctx = req.ctx;
    needManage(ctx);
    const userId = parse(z.uuid(), req.params.userId);
    const b = parse(rateBody, req.body);
    return ctx.tx(async (tx) => {
      await requireStaff(tx, ctx, [userId], 'userId');
      await tx.insertInto('legal_rates').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, user_id: userId, hourly_rate: b.hourlyRate })
        .onConflict((oc) => oc.columns(['company_id', 'user_id']).doUpdateSet({ hourly_rate: b.hourlyRate, updated_at: new Date() })).execute();
      await writeAudit(tx, auditOf(ctx), 'legal_rate', userId, 'set', null, { hourlyRate: b.hourlyRate });
      return { userId, hourlyRate: b.hourlyRate };
    });
  };
  app.put<{ Params: { userId: string } }>('/legal/rates/:userId', async (req) => setRate(req));
  app.patch<{ Params: { userId: string } }>('/legal/rates/:userId', async (req) => setRate(req));

  // Documents ---------------------------------------------------------------------------------
  app.get<{ Params: { id: string } }>('/legal/matters/:id/documents', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await loadMatterRow(tx, ctx, id);
      const rows = await tx.selectFrom('legal_documents as d').innerJoin('files as f', 'f.id', 'd.file_id')
        .select(['d.id', 'd.label', 'd.created_at', 'f.id as file_id', 'f.name', 'f.mime_type', 'f.size']).where('d.matter_id', '=', id).orderBy('d.created_at', 'desc').execute();
      return { data: rows.map((r) => ({ id: r.id, label: r.label, fileId: r.file_id, name: r.name, mimeType: r.mime_type, size: r.size, url: `/api/v1/files/${r.file_id}`, createdAt: r.created_at })) };
    });
  });

  app.post<{ Params: { id: string } }>('/legal/matters/:id/documents', async (req, reply) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(docBody, req.body);
    const out = await ctx.tx(async (tx) => {
      await loadMatterRow(tx, ctx, id);
      await requireFiles(tx, [{ id: b.fileId, field: 'fileId' }], false);
      const dup = await tx.selectFrom('legal_documents').select('id').where('matter_id', '=', id).where('file_id', '=', b.fileId).executeTakeFirst();
      if (dup) throw conflict('This file is already attached.', 'DUPLICATE');
      const row = await tx.insertInto('legal_documents').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_id: id, file_id: b.fileId, label: b.label ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'legal_document', row.id, 'create', null, { matterId: id, fileId: b.fileId });
      return { id: row.id, fileId: b.fileId, label: b.label ?? null };
    });
    return reply.status(201).send(out);
  });

  app.delete<{ Params: { id: string } }>('/legal/documents/:id', async (req, reply) => {
    const ctx = req.ctx;
    needWork(ctx);
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const d = await tx.selectFrom('legal_documents').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!d) throw notFound('Document');
      await loadMatterRow(tx, ctx, d.matter_id);
      await tx.deleteFrom('legal_documents').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'legal_document', id, 'delete', null, { matterId: d.matter_id });
    });
    return reply.status(204).send();
  });

  // Billing and receipts ----------------------------------------------------------------------
  app.post<{ Params: { id: string } }>('/legal/matters/:id/bill', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(billBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const m = await loadMatterRow(tx, ctx, id);
      const ids = [...new Set(b.entryIds)];
      // Lock the entries so two bills cannot take the same one.
      const entries = await tx.selectFrom('legal_entries').selectAll().where('company_id', '=', ctx.companyId).where('matter_id', '=', id)
        .where('id', 'in', ids).orderBy('entry_date').orderBy('created_at').forUpdate().execute();
      if (entries.length !== ids.length) throw badRequest('Some entries were not found on this matter.', { entryIds: 'Not found' });
      if (entries.some((e) => e.invoice_id)) throw conflict('One or more entries are already billed.', 'ALREADY_BILLED');
      if (entries.some((e) => !e.billable)) throw badRequest('Non-billable entries cannot be billed.', { entryIds: 'Not billable' });
      const rc = b.reverseCharge === true;
      if (rc && !m.client_gstin) throw badRequest('Reverse charge applies when the client is a registered business. Add the client GSTIN first.', { reverseCharge: 'Client has no GSTIN' });

      const feeItem = await billItem(tx, ctx, FEE_SKU);
      const reimbItem = await billItem(tx, ctx, REIMB_SKU);
      const lines = entries.map((e) => {
        if (e.kind === 'disbursement') {
          return { itemId: reimbItem, qty: 1, rate: e.amount, description: `${DISB_LABEL[e.disb_type ?? 'other']}: ${e.description} (${e.entry_date})`.slice(0, 300) };
        }
        const hrs = e.kind === 'time' ? ` (${Math.floor(e.minutes! / 60)}h ${String(e.minutes! % 60).padStart(2, '0')}m at ${money(e.rate ?? 0)}/h)` : '';
        return { itemId: feeItem, qty: 1, rate: e.amount, description: `${e.description}${hrs}`.slice(0, 300) };
      });

      let locationId = b.locationId;
      if (!locationId) {
        const locs = await tx.selectFrom('locations').select('id').where('company_id', '=', ctx.companyId).where('is_active', '=', true).orderBy('created_at').execute();
        locationId = locs.find((l) => ctx.canAccessLocation(l.id))?.id;
        if (!locationId) throw badRequest('Add a location before billing.', { locationId: 'Required' });
      }
      const note = [`Matter ${m.matter_no}: ${m.title}`, m.case_no ? `Case ${m.case_no}${m.case_year ? `/${m.case_year}` : ''}` : '',
        b.notes ?? ''].filter(Boolean).join('. ');
      const invoice = await createInvoice(ctx, tx, {
        locationId, partyId: m.client_id, invoiceDate: b.invoiceDate, lines, notes: note.slice(0, 1000), custom: undefined, reverseCharge: rc,
      } as never);
      await tx.updateTable('legal_entries').set({ invoice_id: invoice.id }).where('id', 'in', ids).execute();
      await tx.insertInto('legal_bills').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_id: id, invoice_id: invoice.id, reverse_charge: rc, created_by: ctx.userId,
      }).execute();
      await writeAudit(tx, auditOf(ctx), 'legal_matter', id, 'bill', null, { invoiceId: invoice.id, entries: ids.length, reverseCharge: rc });
      return { invoice, reverseCharge: rc, entriesBilled: ids.length };
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/legal/matters/:id/bills', async (req) => {
    const ctx = req.ctx;
    needView(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await loadMatterRow(tx, ctx, id);
      const bills = await tx.selectFrom('legal_bills as b').innerJoin('invoices as i', 'i.id', 'b.invoice_id')
        .select(['i.id', 'i.number', 'i.invoice_date', 'i.total', 'i.amount_paid', 'i.status', 'b.reverse_charge'])
        .where('b.matter_id', '=', id).orderBy('i.invoice_date', 'desc').execute();
      const receipts = await tx.selectFrom('legal_receipts as r').innerJoin('payments as p', 'p.id', 'r.payment_id')
        .select(['p.id', 'p.number', 'p.payment_date', 'p.amount', 'p.status', 'r.kind', 'r.invoice_id']).where('r.matter_id', '=', id).orderBy('p.payment_date', 'desc').execute();
      return {
        bills: bills.map((i) => ({ invoiceId: i.id, number: i.number, invoiceDate: i.invoice_date, total: i.total, amountPaid: i.amount_paid, status: i.status, reverseCharge: i.reverse_charge })),
        receipts: receipts.map((r) => ({ paymentId: r.id, number: r.number, date: r.payment_date, amount: r.amount, status: r.status, kind: r.kind, invoiceId: r.invoice_id })),
      };
    });
  });

  app.post<{ Params: { id: string } }>('/legal/matters/:id/receipts', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(receiptBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const m = await loadMatterRow(tx, ctx, id);
      if (b.kind === 'fee') {
        if (!b.invoiceId) throw badRequest('Choose the fee bill this receipt is for.', { invoiceId: 'Required' });
        const bill = await tx.selectFrom('legal_bills').select('id').where('matter_id', '=', id).where('invoice_id', '=', b.invoiceId).executeTakeFirst();
        if (!bill) throw badRequest('That bill does not belong to this matter.', { invoiceId: 'Not found' });
      } else if (b.invoiceId) throw badRequest('An advance is not tied to a bill.', { invoiceId: 'Not allowed for advances' });
      // An explicit empty list keeps an advance unallocated, so it stays as credit and is not spread over other bills.
      const payment = await createPayment(ctx, tx, {
        kind: 'receipt', partyId: m.client_id, date: b.date, accountId: b.accountId, mode: b.mode, reference: b.reference, amount: b.amount,
        tdsAmount: b.tdsAmount, notes: `${b.kind === 'advance' ? 'Advance' : 'Fee'} for ${m.matter_no}`,
        allocations: b.kind === 'fee' ? [{ docId: b.invoiceId!, amount: round2(b.amount + (b.tdsAmount ?? 0)) }] : [],
      } as never);
      await tx.insertInto('legal_receipts').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, matter_id: id, payment_id: payment.id, invoice_id: b.invoiceId ?? null,
        kind: b.kind, created_by: ctx.userId,
      }).execute();
      await writeAudit(tx, auditOf(ctx), 'legal_matter', id, 'receipt', null, { paymentId: payment.id, kind: b.kind, amount: b.amount });
      return payment;
    });
    return reply.status(201).send(out);
  });
}

documentRoute('POST', '/legal/matters', { body: matterCreate });
documentRoute('PATCH', '/legal/matters/:id', { body: matterPatch });
documentRoute('POST', '/legal/matters/:id/hearings', { body: hearingCreate });
documentRoute('PATCH', '/legal/hearings/:id', { body: hearingPatch });
documentRoute('POST', '/legal/hearings/:id/outcome', { body: outcomeBody });
documentRoute('POST', '/legal/matters/:id/tasks', { body: taskCreate });
documentRoute('PATCH', '/legal/tasks/:id', { body: taskPatch });
documentRoute('POST', '/legal/matters/:id/entries', { body: entryCreate });
documentRoute('PATCH', '/legal/entries/:id', { body: entryPatch });
documentRoute('DELETE', '/legal/entries/:id', { body: rateBody });
documentRoute('POST', '/legal/matters/:id/documents', { body: docBody });
documentRoute('POST', '/legal/matters/:id/bill', { body: billBody });
documentRoute('POST', '/legal/matters/:id/receipts', { body: receiptBody });
