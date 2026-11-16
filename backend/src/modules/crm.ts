import type { FastifyInstance } from 'fastify';
import { sql, type RawBuilder } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import { partyBalances } from '../accounting/ledger.ts';
import type { Tx } from '../db/database.ts';
import { seal, unseal } from '../lib/crypto.ts';
import { addDays, daysBetween, isValidDate, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { gstin as gstinField, nullableText, optionalText, stateCode as stateField } from '../lib/india.ts';
import { IndiamartError, pullIndiamart, type FetchLike } from '../lib/crm/indiamart.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { dropOpenFollowUps, ensureStages, markDealWon, moveDealStage } from './crm-common.ts';

/*
 * Leads, deals, follow-ups, targets and IndiaMART enquiries (module `crm`). See docs/API.md "v1.14".
 * Nothing here posts money. Reads are raw SQL where several tables join; writes use the typed builder.
 */

const round2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100;
const num = (v: unknown) => (v === null || v === undefined ? 0 : Number(v));
const iso = (d: unknown) => (d ? new Date(d as string).toISOString() : null);
const dayStart = (date: string) => new Date(`${date}T00:00:00+05:30`);
const monthStart = (date: string) => `${date.slice(0, 7)}-01`;

const SOURCES = ['walk_in', 'phone', 'website', 'indiamart', 'justdial', 'tradeindia', 'referral', 'whatsapp', 'social', 'other'] as const;
const OPEN_LEAD = ['new', 'contacted', 'qualified'];
const CONTACT_KINDS = ['call', 'meeting', 'visit', 'whatsapp', 'email'];

let indiamartFetch: FetchLike | undefined;
/** Tests replace the network call with a fake. Pass undefined to restore the real one. */
export function setIndiamartFetch(f: FetchLike | undefined) { indiamartFetch = f; }

// Input ------------------------------------------------------------------------------------------

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const monthField = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM');
const blank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? undefined : v);
const phoneField = z.string().trim().min(5, 'Enter a phone number').max(20).regex(/^[0-9+() -]+$/, 'Digits only');
const optPhone = z.preprocess(blank, phoneField.optional());
const nullPhone = z.preprocess((v) => (v === '' ? null : v), phoneField.nullable().optional());
const optEmail = z.preprocess(blank, z.string().trim().max(200).email('Enter a valid email').optional());
const nullEmail = z.preprocess((v) => (v === '' ? null : v), z.string().trim().max(200).email('Enter a valid email').nullable().optional());
const optState = z.preprocess(blank, stateField.optional());
const nullState = z.preprocess((v) => (v === '' ? null : v), stateField.nullable().optional());
const optMoney = z.preprocess(blank, moneyField.optional());
const nullMoney = z.preprocess((v) => (v === '' ? null : v), moneyField.nullable().optional());
const optUuid = z.preprocess(blank, z.uuid().optional());
const nullUuid = z.preprocess((v) => (v === '' ? null : v), z.uuid().nullable().optional());
const optDate = z.preprocess(blank, dateField.optional());
const nullDate = z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional());
const pct = z.coerce.number().min(0).max(100);
/** A moment with an offset, or a bare date (taken as 9 am Indian time). */
const momentField = z.string().trim().transform((v, c) => {
  const s = /^\d{4}-\d{2}-\d{2}$/.test(v) ? `${v}T09:00:00+05:30` : v;
  const d = new Date(s);
  if (Number.isNaN(d.getTime()) || !/^\d{4}-\d{2}-\d{2}T/.test(s)) { c.addIssue({ code: 'custom', message: 'Use an ISO 8601 date and time with offset' }); return z.NEVER; }
  return d;
});

const leadFields = {
  name: z.string().trim().min(1, 'Required').max(120),
  companyName: optionalText(200), phone: optPhone, email: optEmail, city: optionalText(80), stateCode: optState,
  requirement: optionalText(2000), estimatedValue: optMoney, source: z.enum(SOURCES).default('other'),
  sourceRef: optionalText(100), ownerId: optUuid,
};
const leadCreate = z.object({ ...leadFields, force: z.boolean().optional() });
const leadPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: leadFields.name.optional(), companyName: nullableText(200), phone: nullPhone, email: nullEmail, city: nullableText(80),
  stateCode: nullState, requirement: nullableText(2000), estimatedValue: nullMoney, source: z.enum(SOURCES).optional(),
  sourceRef: nullableText(100), ownerId: nullUuid, status: z.enum(['new', 'contacted', 'qualified']).optional(),
});
const leadListQuery = pagingQuery.extend({
  status: z.enum(['new', 'contacted', 'qualified', 'converted', 'lost', 'open']).optional(), source: z.enum(SOURCES).optional(),
  ownerId: z.uuid().optional(), from: dateField.optional(), to: dateField.optional(),
});
const convertBody = z.object({
  partyId: z.uuid().optional(),
  party: z.object({
    name: z.string().trim().min(1).max(200).optional(), phone: optPhone, email: optEmail, gstin: z.preprocess(blank, gstinField.optional()), stateCode: optState,
  }).optional(),
  deal: z.object({ title: z.string().trim().min(1).max(200), value: moneyField, stageId: z.uuid().optional(), expectedClose: optDate }).nullable().optional(),
});
const reasonBody = z.object({ reason: z.string().trim().min(1, 'Give a reason').max(200) });

const dealFields = {
  title: z.string().trim().min(1, 'Required').max(200),
  partyId: optUuid, leadId: optUuid, contactId: optUuid, value: moneyField, probability: z.preprocess(blank, pct.optional()),
  expectedClose: optDate, ownerId: optUuid, notes: optionalText(2000),
};
const dealCreate = z.object({ ...dealFields, stageId: optUuid });
const dealPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  title: dealFields.title.optional(), partyId: nullUuid, leadId: nullUuid, contactId: nullUuid, value: moneyField.optional(),
  probability: z.preprocess((v) => (v === '' ? null : v), pct.nullable().optional()), expectedClose: nullDate, ownerId: nullUuid, notes: nullableText(2000),
});
const dealListQuery = pagingQuery.extend({
  status: z.enum(['open', 'won', 'lost']).default('open'), stageId: z.uuid().optional(), ownerId: z.uuid().optional(), partyId: z.uuid().optional(),
});
const ACT_KINDS = ['call', 'meeting', 'visit', 'task', 'note', 'whatsapp', 'email'] as const;
const actCreate = z.object({
  kind: z.enum(ACT_KINDS), subject: z.string().trim().min(1, 'Required').max(300), notes: optionalText(2000),
  dueAt: z.preprocess(blank, momentField.optional()), doneAt: z.preprocess(blank, momentField.optional()), outcome: optionalText(300),
  durationMin: z.preprocess(blank, z.coerce.number().int().min(0).max(1440).optional()),
  leadId: optUuid, dealId: optUuid, partyId: optUuid, ownerId: optUuid,
});
const actPatch = z.object({
  subject: z.string().trim().min(1).max(300).optional(), notes: nullableText(2000),
  dueAt: z.preprocess((v) => (v === '' ? null : v), momentField.nullable().optional()), ownerId: nullUuid,
});
const actDone = z.object({
  outcome: z.string().trim().min(1, 'Say how it went').max(300), notes: optionalText(2000),
  durationMin: z.preprocess(blank, z.coerce.number().int().min(0).max(1440).optional()),
  next: z.object({ kind: z.enum(ACT_KINDS), subject: z.string().trim().min(1).max(300), dueAt: momentField }).optional(),
});
const actListQuery = pagingQuery.extend({
  leadId: z.uuid().optional(), dealId: z.uuid().optional(), partyId: z.uuid().optional(), ownerId: z.uuid().optional(),
  when: z.enum(['overdue', 'today', 'upcoming', 'done']).optional(),
});
const stagesBody = z.object({
  stages: z.array(z.object({
    id: z.uuid().optional(), name: z.string().trim().min(1, 'Required').max(60), probability: pct, kind: z.enum(['open', 'won', 'lost']),
  })).min(3).max(30),
});
const targetsBody = z.object({ month: monthField, rows: z.array(z.object({ userId: z.uuid().nullable(), amount: moneyField })).max(200) });
const settingsBody = z.object({
  defaultOwnerId: nullUuid, lostReasons: z.array(z.string().trim().min(1).max(60)).min(1).max(20).optional(),
  indiamartKey: z.string().trim().min(8, 'Paste the full key').max(200).nullable().optional(),
});
const contactFields = {
  name: z.string().trim().min(1, 'Required').max(120), designation: optionalText(80), phone: optPhone, email: optEmail,
  isPrimary: z.boolean().optional(), notes: optionalText(500),
};
const contactCreate = z.object(contactFields);
const contactPatch = z.object({
  name: contactFields.name.optional(), designation: nullableText(80), phone: nullPhone, email: nullEmail,
  isPrimary: z.boolean().optional(), notes: nullableText(500),
});

// Access and small helpers -----------------------------------------------------------------------

const canAll = (ctx: RequestContext) => ctx.can('crm.all');
const view = (ctx: RequestContext) => ctx.require('crm.view', 'crm.manage');
const manage = (ctx: RequestContext) => ctx.require('crm.manage');

/** SQL condition on an owner column. Without crm.all a user sees their own records and unowned ones. */
function ownerCond(ctx: RequestContext, col: RawBuilder<unknown>, ownerId?: string): RawBuilder<unknown> | null {
  if (ownerId) {
    if (!canAll(ctx) && ownerId !== ctx.userId) throw forbidden('You can only see your own leads and deals.');
    return sql`${col} = ${ownerId}`;
  }
  return canAll(ctx) ? null : sql`(${col} = ${ctx.userId} or ${col} is null)`;
}
const all = (parts: (RawBuilder<unknown> | null)[]) => sql.join(parts.filter((p): p is RawBuilder<unknown> => !!p), sql` and `);
const col = (name: string) => sql.raw(name);

function assertVisible(ctx: RequestContext, ownerId: string | null, what: string) {
  if (!canAll(ctx) && ownerId && ownerId !== ctx.userId) throw notFound(what);
}
function assertCanAssign(ctx: RequestContext, ownerId: string | undefined | null) {
  if (ownerId && !canAll(ctx) && ownerId !== ctx.userId) throw forbidden('Only people with access to everyone\'s records can assign to someone else.');
}
async function assertUser(tx: Tx, ownerId: string | undefined | null) {
  if (!ownerId) return;
  const u = await tx.selectFrom('users').select('id').where('id', '=', ownerId).where('is_active', '=', true).executeTakeFirst();
  if (!u) throw badRequest('That owner was not found.', { ownerId: 'Not found' });
}

async function settingsRow(tx: Tx, ctx: RequestContext) {
  await tx.insertInto('crm_settings').values({ company_id: ctx.companyId, tenant_id: ctx.tenantId })
    .onConflict((oc) => oc.column('company_id').doNothing()).execute();
  return tx.selectFrom('crm_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirstOrThrow();
}

async function defaultOwner(tx: Tx, ctx: RequestContext): Promise<string> {
  return (await settingsRow(tx, ctx)).default_owner_id ?? ctx.userId;
}

/** Owes, overdue and oldest overdue days per party, from the ledger and the same posted-invoice rules as /reports/ageing. */
export type PartyBalance = { owes: number; overdue: number; oldestOverdueDays: number };
async function balancesOf(tx: Tx, ctx: RequestContext, partyIds: (string | null)[]): Promise<Map<string, PartyBalance>> {
  const ids = [...new Set(partyIds.filter((x): x is string => !!x))];
  const out = new Map<string, PartyBalance>();
  if (!ids.length) return out;
  const today = todayIst();
  const owes = await partyBalances(tx, ctx.companyId, ids);
  const od = await sql<{ party_id: string; due: string; due_date: string }>`
    select party_id, (total - amount_paid) as due, due_date::text as due_date from invoices
    where company_id = ${ctx.companyId} and status = 'posted' and amount_paid < total and due_date < ${today}::date
      and party_id = any(${ids}::uuid[])`.execute(tx);
  for (const id of ids) out.set(id, { owes: round2(owes.get(id) ?? 0), overdue: 0, oldestOverdueDays: 0 });
  for (const r of od.rows) {
    const b = out.get(r.party_id)!;
    b.overdue = round2(b.overdue + num(r.due));
    b.oldestOverdueDays = Math.max(b.oldestOverdueDays, daysBetween(r.due_date, today));
  }
  return out;
}

// JSON shapes ------------------------------------------------------------------------------------

type NextFollow = { id: string; kind: string; subject: string; dueAt: string | null };

async function nextFollowUps(tx: Tx, ctx: RequestContext, key: 'lead_id' | 'deal_id', ids: string[]): Promise<Map<string, NextFollow>> {
  const out = new Map<string, NextFollow>();
  if (!ids.length) return out;
  const rows = await sql<{ id: string; kind: string; subject: string; due_at: Date | null; ref: string }>`
    select distinct on (${col(key)}) id, kind, subject, due_at, ${col(key)} as ref from crm_activities
    where company_id = ${ctx.companyId} and done_at is null and ${col(key)} = any(${ids}::uuid[])
    order by ${col(key)}, due_at nulls last, created_at`.execute(tx);
  for (const r of rows.rows) out.set(r.ref, { id: r.id, kind: r.kind, subject: r.subject, dueAt: iso(r.due_at) });
  return out;
}

const LEAD_SQL = sql`select l.*, u.name as owner_name, p.name as party_name from crm_leads l
  left join users u on u.id = l.owner_id left join parties p on p.id = l.party_id`;
type LeadRow = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

function leadJson(r: LeadRow, next: NextFollow | null) {
  return {
    id: r.id, name: r.name, companyName: r.company_name, phone: r.phone, email: r.email, city: r.city, stateCode: r.state_code,
    requirement: r.requirement, estimatedValue: r.estimated_value === null ? null : num(r.estimated_value), source: r.source,
    sourceRef: r.source_ref, ownerId: r.owner_id, ownerName: r.owner_name ?? null, status: r.status, lostReason: r.lost_reason,
    partyId: r.party_id, partyName: r.party_name ?? null, dealId: r.deal_id, firstContactAt: iso(r.first_contact_at),
    convertedAt: iso(r.converted_at), nextFollowUp: next, createdAt: iso(r.created_at), updatedAt: r.updated_at,
  };
}
async function leadsJson(tx: Tx, ctx: RequestContext, rows: LeadRow[]) {
  const nf = await nextFollowUps(tx, ctx, 'lead_id', rows.map((r) => r.id));
  return rows.map((r) => leadJson(r, nf.get(r.id) ?? null));
}
async function loadLead(tx: Tx, ctx: RequestContext, id: string, lock = false): Promise<LeadRow> {
  const row = await sql<LeadRow>`${LEAD_SQL} where l.id = ${id} and l.company_id = ${ctx.companyId} ${lock ? sql`for update of l` : sql``}`.execute(tx);
  const r = row.rows[0];
  if (!r) throw notFound('Lead');
  assertVisible(ctx, r.owner_id, 'Lead');
  return r;
}
async function leadOut(tx: Tx, ctx: RequestContext, id: string) {
  return (await leadsJson(tx, ctx, [await loadLead(tx, ctx, id)]))[0]!;
}

const DEAL_SQL = sql`select d.*, s.name as stage_name, s.kind as stage_kind, s.probability as stage_prob, p.name as party_name,
  u.name as owner_name, (select count(*) from quotations q where q.deal_id = d.id) as qcount
  from crm_deals d join crm_stages s on s.id = d.stage_id left join parties p on p.id = d.party_id left join users u on u.id = d.owner_id`;

function dealJson(r: LeadRow, next: NextFollow | null, bal: PartyBalance | null) {
  const eff = r.probability === null ? num(r.stage_prob) : num(r.probability);
  const value = num(r.value);
  return {
    id: r.id, title: r.title, partyId: r.party_id, partyName: r.party_name ?? null, contactId: r.contact_id, leadId: r.lead_id,
    stageId: r.stage_id, stageName: r.stage_name, stageKind: r.stage_kind, value, probability: r.probability === null ? null : num(r.probability),
    effectiveProbability: eff, weightedValue: round2((value * eff) / 100), expectedClose: r.expected_close, ownerId: r.owner_id,
    ownerName: r.owner_name ?? null, status: r.status, lostReason: r.lost_reason, wonAt: iso(r.won_at), lostAt: iso(r.lost_at),
    stageChangedAt: iso(r.stage_changed_at), daysInStage: Math.max(0, Math.floor((Date.now() - new Date(r.stage_changed_at).getTime()) / 86_400_000)),
    notes: r.notes, nextFollowUp: next, followUpOverdue: !!next?.dueAt && new Date(next.dueAt).getTime() < Date.now(),
    partyBalance: bal, quotationCount: num(r.qcount), createdAt: iso(r.created_at), updatedAt: r.updated_at,
  };
}
async function dealsJson(tx: Tx, ctx: RequestContext, rows: LeadRow[]) {
  const nf = await nextFollowUps(tx, ctx, 'deal_id', rows.map((r) => r.id));
  const bal = await balancesOf(tx, ctx, rows.map((r) => r.party_id));
  return rows.map((r) => dealJson(r, nf.get(r.id) ?? null, r.party_id ? bal.get(r.party_id) ?? null : null));
}
async function loadDeal(tx: Tx, ctx: RequestContext, id: string, lock = false): Promise<LeadRow> {
  if (lock) await sql`select 1 from crm_deals where id = ${id} and company_id = ${ctx.companyId} for update`.execute(tx);
  const row = await sql<LeadRow>`${DEAL_SQL} where d.id = ${id} and d.company_id = ${ctx.companyId}`.execute(tx);
  const r = row.rows[0];
  if (!r) throw notFound('Deal');
  assertVisible(ctx, r.owner_id, 'Deal');
  return r;
}
async function dealOut(tx: Tx, ctx: RequestContext, id: string) {
  return (await dealsJson(tx, ctx, [await loadDeal(tx, ctx, id)]))[0]!;
}

const ACT_SQL = sql`select a.*, l.name as lead_name, d.title as deal_title, p.name as party_name, d.value as deal_value,
  l.estimated_value as lead_value, l.source as lead_source, coalesce(l.phone, p.phone) as phone, u.name as owner_name,
  coalesce(a.party_id, d.party_id, l.party_id) as eff_party
  from crm_activities a left join crm_leads l on l.id = a.lead_id left join crm_deals d on d.id = a.deal_id
  left join parties p on p.id = coalesce(a.party_id, d.party_id, l.party_id) left join users u on u.id = a.owner_id`;

function activityJson(r: LeadRow) {
  const done = !!r.done_at;
  const value = r.deal_value ?? r.lead_value;
  return {
    id: r.id, kind: r.kind, subject: r.subject, notes: r.notes, dueAt: iso(r.due_at), doneAt: iso(r.done_at), outcome: r.outcome,
    durationMin: r.duration_min, leadId: r.lead_id, dealId: r.deal_id, partyId: r.party_id,
    title: r.lead_name ?? r.deal_title ?? r.party_name ?? null, value: value === null || value === undefined ? null : num(value),
    source: r.lead_source ?? null, phone: r.phone ?? null, ownerId: r.owner_id, ownerName: r.owner_name ?? null,
    overdue: !done && !!r.due_at && new Date(r.due_at).getTime() < Date.now(), createdAt: iso(r.created_at),
  };
}
async function loadActivity(tx: Tx, ctx: RequestContext, id: string, lock = false): Promise<LeadRow> {
  if (lock) await sql`select 1 from crm_activities where id = ${id} and company_id = ${ctx.companyId} for update`.execute(tx);
  const row = await sql<LeadRow>`${ACT_SQL} where a.id = ${id} and a.company_id = ${ctx.companyId}`.execute(tx);
  const r = row.rows[0];
  if (!r) throw notFound('Follow-up');
  assertVisible(ctx, r.owner_id, 'Follow-up');
  return r;
}
async function activitiesJson(tx: Tx, ctx: RequestContext, rows: LeadRow[], withBalance = false) {
  const bal = withBalance ? await balancesOf(tx, ctx, rows.map((r) => r.eff_party)) : null;
  return rows.map((r) => ({ ...activityJson(r), ...(bal ? { partyBalance: r.eff_party ? bal.get(r.eff_party) ?? null : null } : {}) }));
}

// Shared writes ----------------------------------------------------------------------------------

/** A done call, meeting, visit, WhatsApp or email on an open lead marks first contact once and moves a new lead to contacted. */
async function applyFirstContact(tx: Tx, ctx: RequestContext, leadId: string | null, kind: string, at: Date) {
  if (!leadId || !CONTACT_KINDS.includes(kind)) return;
  await sql`update crm_leads set first_contact_at = coalesce(first_contact_at, ${at}),
      status = case when status = 'new' then 'contacted' else status end
    where id = ${leadId} and company_id = ${ctx.companyId} and status in ('new','contacted','qualified')`.execute(tx);
}

async function firstOpenStage(tx: Tx, ctx: RequestContext) {
  const s = (await ensureStages(tx, ctx)).find((x) => x.kind === 'open' && x.is_active);
  if (!s) throw badRequest('Add an open stage in the pipeline settings first.');
  return s;
}

async function insertDeal(tx: Tx, ctx: RequestContext, d: {
  title: string; partyId?: string | null; leadId?: string | null; contactId?: string | null; stageId?: string; value: number;
  probability?: number | null; expectedClose?: string | null; ownerId?: string | null; notes?: string | null;
}) {
  const stages = await ensureStages(tx, ctx);
  const stage = d.stageId ? stages.find((s) => s.id === d.stageId) : await firstOpenStage(tx, ctx);
  if (!stage || stage.kind !== 'open' || !stage.is_active) throw badRequest('Choose an open stage.', { stageId: 'Use an open stage' });
  const row = await tx.insertInto('crm_deals').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, title: d.title, party_id: d.partyId ?? null, contact_id: d.contactId ?? null,
    lead_id: d.leadId ?? null, stage_id: stage.id, value: d.value, probability: d.probability ?? null, expected_close: d.expectedClose ?? null,
    owner_id: d.ownerId ?? null, notes: d.notes ?? null, created_by: ctx.userId,
  }).returning('id').executeTakeFirstOrThrow();
  await tx.insertInto('crm_deal_stage_history').values({
    tenant_id: ctx.tenantId, deal_id: row.id, from_stage_id: null, to_stage_id: stage.id, changed_by: ctx.userId,
  }).execute();
  return row.id;
}

const last10 = (p: string | null | undefined) => (p ? p.replace(/\D/g, '').slice(-10) : '');

// Routes -----------------------------------------------------------------------------------------

export async function crmRoutes(app: FastifyInstance) {
  // Settings, stages, targets, owners ---------------------------------------------------------

  const settingsOut = async (tx: Tx, ctx: RequestContext) => {
    const s = await settingsRow(tx, ctx);
    return {
      defaultOwnerId: s.default_owner_id, lostReasons: s.lost_reasons, hasIndiamartKey: !!s.indiamart_key_sealed,
      indiamartLastPullAt: iso(s.indiamart_last_pull_at), indiamartLastError: s.indiamart_last_error,
    };
  };

  app.get('/crm/settings', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    return ctx.tx((tx) => settingsOut(tx, ctx));
  });

  app.patch('/crm/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('crm.settings');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      await settingsRow(tx, ctx);
      await assertUser(tx, b.defaultOwnerId);
      const set: Record<string, unknown> = {};
      if (b.defaultOwnerId !== undefined) set.default_owner_id = b.defaultOwnerId;
      if (b.lostReasons) set.lost_reasons = [...new Set(b.lostReasons)];
      if (b.indiamartKey !== undefined) {
        set.indiamart_key_sealed = b.indiamartKey === null ? null : seal(b.indiamartKey);
        set.indiamart_last_error = null;
      }
      if (Object.keys(set).length) await tx.updateTable('crm_settings').set(set as never).where('company_id', '=', ctx.companyId).execute();
      await writeAudit(tx, auditOf(ctx), 'crm_settings', ctx.companyId, 'update', null, { fields: Object.keys(set) });
      return settingsOut(tx, ctx);
    });
  });

  app.get('/crm/stages', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    return ctx.tx(async (tx) => ({ data: (await ensureStages(tx, ctx)).map(stageJson) }));
  });

  const putStages = async (req: { ctx: RequestContext; body: unknown }) => {
    const ctx = req.ctx;
    ctx.require('crm.settings');
    const b = parse(stagesBody, req.body);
    const names = b.stages.map((s) => s.name.toLowerCase());
    if (new Set(names).size !== names.length) throw badRequest('Stage names must be different from each other.', { stages: 'Duplicate name' });
    const count = (k: string) => b.stages.filter((s) => s.kind === k).length;
    if (count('won') !== 1 || count('lost') !== 1) throw badRequest('Keep exactly one Won stage and one Lost stage.', { stages: 'Need one won and one lost' });
    if (count('open') < 1) throw badRequest('Keep at least one open stage.', { stages: 'Need an open stage' });
    return ctx.tx(async (tx) => {
      const existing = await ensureStages(tx, ctx);
      const byId = new Map(existing.map((s) => [s.id, s]));
      for (const s of b.stages) if (s.id && !byId.has(s.id)) throw badRequest('A stage in the list was not found. Reload and try again.', { stages: 'Unknown stage' });
      const used = async (id: string) => {
        const d = await tx.selectFrom('crm_deals').select('id').where('stage_id', '=', id).limit(1).executeTakeFirst();
        if (d) return true;
        return !!(await tx.selectFrom('crm_deal_stage_history').select('id').where((eb) => eb.or([eb('to_stage_id', '=', id), eb('from_stage_id', '=', id)])).limit(1).executeTakeFirst());
      };
      for (const s of b.stages) {
        const old = s.id ? byId.get(s.id) : undefined;
        if (old && old.kind !== s.kind && await used(old.id)) throw badRequest(`Stage "${old.name}" has deals and cannot change its kind.`, { stages: 'Kind locked' });
      }
      // Free the names first so reordering and renaming cannot clash on the unique name.
      await sql`update crm_stages set name = id::text where company_id = ${ctx.companyId}`.execute(tx);
      const keep = new Set<string>();
      let sort = 1;
      for (const s of b.stages) {
        if (s.id) {
          keep.add(s.id);
          await tx.updateTable('crm_stages').set({ name: s.name, probability: s.probability, kind: s.kind, sort: sort++, is_active: true })
            .where('id', '=', s.id).execute();
        } else {
          await tx.insertInto('crm_stages').values({
            tenant_id: ctx.tenantId, company_id: ctx.companyId, name: s.name, probability: s.probability, kind: s.kind, sort: sort++,
          }).execute();
        }
      }
      for (const o of existing) {
        if (keep.has(o.id)) continue;
        if (await used(o.id)) {
          await tx.updateTable('crm_stages').set({ name: `${o.name.slice(0, 48)} (old ${o.id.slice(0, 4)})`, sort: sort++, is_active: false }).where('id', '=', o.id).execute();
        } else {
          await tx.deleteFrom('crm_stages').where('id', '=', o.id).execute();
        }
      }
      await writeAudit(tx, auditOf(ctx), 'crm_stages', ctx.companyId, 'update', null, { stages: b.stages.map((s) => s.name) });
      return { data: (await ensureStages(tx, ctx)).map(stageJson) };
    });
  };
  app.put('/crm/stages', putStages as never);
  app.patch('/crm/stages', putStages as never);

  app.get('/crm/targets', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const q = parse(z.object({ month: monthField.optional() }), req.query);
    const month = q.month ?? todayIst().slice(0, 7);
    return ctx.tx(async (tx) => {
      const rows = await sql<{ user_id: string | null; name: string | null; amount: string }>`
        select t.user_id, u.name, t.amount from crm_targets t left join users u on u.id = t.user_id
        where t.company_id = ${ctx.companyId} and t.month = ${`${month}-01`}::date order by (t.user_id is not null), u.name`.execute(tx);
      return { month, rows: rows.rows.map((r) => ({ userId: r.user_id, userName: r.user_id ? r.name ?? '' : 'Company', amount: num(r.amount) })) };
    });
  });

  const putTargets = async (req: { ctx: RequestContext; body: unknown }) => {
    const ctx = req.ctx;
    ctx.require('crm.settings');
    const b = parse(targetsBody, req.body);
    const month = `${b.month}-01`;
    return ctx.tx(async (tx) => {
      for (const r of b.rows) {
        await assertUser(tx, r.userId);
        let find = tx.selectFrom('crm_targets').select('id').where('company_id', '=', ctx.companyId).where('month', '=', month);
        find = r.userId ? find.where('user_id', '=', r.userId) : find.where('user_id', 'is', null);
        const ex = await find.executeTakeFirst();
        if (r.amount === 0) { if (ex) await tx.deleteFrom('crm_targets').where('id', '=', ex.id).execute(); continue; }
        if (ex) await tx.updateTable('crm_targets').set({ amount: r.amount }).where('id', '=', ex.id).execute();
        else await tx.insertInto('crm_targets').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, user_id: r.userId, month, amount: r.amount }).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'crm_targets', null, 'update', null, { month: b.month, rows: b.rows.length });
      const rows = await sql<{ user_id: string | null; name: string | null; amount: string }>`
        select t.user_id, u.name, t.amount from crm_targets t left join users u on u.id = t.user_id
        where t.company_id = ${ctx.companyId} and t.month = ${month}::date order by (t.user_id is not null), u.name`.execute(tx);
      return { month: b.month, rows: rows.rows.map((r) => ({ userId: r.user_id, userName: r.user_id ? r.name ?? '' : 'Company', amount: num(r.amount) })) };
    });
  };
  app.put('/crm/targets', putTargets as never);
  app.patch('/crm/targets', putTargets as never);

  app.get('/crm/owners', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const today = todayIst();
    return ctx.tx(async (tx) => {
      const rows = await sql<{ id: string; name: string }>`
        select distinct u.id, u.name from users u join user_roles ur on ur.user_id = u.id join roles r on r.id = ur.role_id
        where ur.company_id = ${ctx.companyId} and u.is_active and 'crm.manage' = any(r.permissions)
          and (ur.valid_from is null or ur.valid_from <= ${today}::date) and (ur.valid_to is null or ur.valid_to >= ${today}::date)
        order by u.name`.execute(tx);
      return { data: rows.rows };
    });
  });

  // Leads -------------------------------------------------------------------------------------

  app.get('/crm/leads', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const q = parse(leadListQuery, req.query);
    return ctx.tx(async (tx) => {
      const where = all([
        sql`l.company_id = ${ctx.companyId}`, ownerCond(ctx, col('l.owner_id'), q.ownerId),
        q.status === 'open' ? sql`l.status in ('new','contacted','qualified')` : q.status ? sql`l.status = ${q.status}` : null,
        q.source ? sql`l.source = ${q.source}` : null,
        q.from ? sql`l.created_at >= ${dayStart(q.from)}` : null, q.to ? sql`l.created_at < ${dayStart(addDays(q.to, 1))}` : null,
        q.q ? sql`(l.name ilike ${likeTerm(q.q)} or l.company_name ilike ${likeTerm(q.q)} or l.phone ilike ${likeTerm(q.q)} or l.email ilike ${likeTerm(q.q)})` : null,
      ]);
      const total = await sql<{ n: string }>`select count(*) as n from crm_leads l where ${where}`.execute(tx);
      const rows = await sql<LeadRow>`${LEAD_SQL} where ${where} order by l.created_at desc limit ${q.limit} offset ${q.offset}`.execute(tx);
      return { data: await leadsJson(tx, ctx, rows.rows), total: num(total.rows[0]!.n) };
    });
  });

  app.post('/crm/leads', async (req, reply) => {
    const ctx = req.ctx;
    manage(ctx);
    const b = parse(leadCreate, req.body);
    if (!b.phone && !b.email) throw badRequest('Add a phone number or an email.', { phone: 'Add a phone or an email' });
    assertCanAssign(ctx, b.ownerId);
    const out = await ctx.tx(async (tx) => {
      await assertUser(tx, b.ownerId);
      if (!b.force) {
        const dup = await findDuplicate(tx, ctx, b.phone, b.email);
        if (dup) throw conflict('An open lead with this phone or email already exists. Open it, or save again to add a second lead.', 'DUPLICATE_LEAD', { existing: dup });
      }
      const row = await tx.insertInto('crm_leads').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, company_name: b.companyName ?? null, phone: b.phone ?? null,
        email: b.email ?? null, city: b.city ?? null, state_code: b.stateCode ?? null, requirement: b.requirement ?? null,
        estimated_value: b.estimatedValue ?? null, source: b.source, source_ref: b.sourceRef ?? null,
        owner_id: b.ownerId ?? await defaultOwner(tx, ctx), created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'crm_lead', row.id, 'create', null, { name: b.name, source: b.source });
      return leadOut(tx, ctx, row.id);
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/crm/leads/:id', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const lead = await loadLead(tx, ctx, id);
      const acts = await sql<LeadRow>`${ACT_SQL} where a.lead_id = ${id} and a.company_id = ${ctx.companyId} order by coalesce(a.done_at, a.due_at, a.created_at) desc`.execute(tx);
      const phone = last10(lead.phone);
      const matches = await sql<{ id: string; name: string; phone: string | null; gstin: string | null }>`
        select id, name, phone, gstin from parties where company_id = ${ctx.companyId} and type in ('customer','both') and (
          (${phone} <> '' and right(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 10) = ${phone})
          or (${lead.email ?? null}::text is not null and lower(email) = lower(${lead.email ?? null}::text))
          or (${lead.company_name ?? null}::text is not null and lower(name) = lower(${lead.company_name ?? null}::text)))
        order by name limit 10`.execute(tx);
      const bal = await balancesOf(tx, ctx, matches.rows.map((m) => m.id));
      return {
        ...(await leadsJson(tx, ctx, [lead]))[0]!, activities: acts.rows.map(activityJson),
        matches: matches.rows.map((m) => ({ partyId: m.id, name: m.name, phone: m.phone, gstin: m.gstin, balance: bal.get(m.id)?.owes ?? 0 })),
      };
    });
  });

  app.patch<{ Params: { id: string } }>('/crm/leads/:id', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(leadPatch, req.body);
    assertCanAssign(ctx, b.ownerId);
    return ctx.tx(async (tx) => {
      const before = await loadLead(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'lead');
      if (!OPEN_LEAD.includes(before.status)) throw conflict('This lead is closed. Reopen it to make changes.', 'LEAD_CLOSED');
      await assertUser(tx, b.ownerId);
      const phone = b.phone === undefined ? before.phone : b.phone;
      const email = b.email === undefined ? before.email : b.email;
      if (!phone && !email) throw badRequest('Keep a phone number or an email.', { phone: 'Add a phone or an email' });
      const set = {
        name: b.name, company_name: b.companyName, phone: b.phone, email: b.email, city: b.city, state_code: b.stateCode,
        requirement: b.requirement, estimated_value: b.estimatedValue, source: b.source, source_ref: b.sourceRef, owner_id: b.ownerId, status: b.status,
      };
      const changes = Object.fromEntries(Object.entries(set).filter(([, v]) => v !== undefined));
      if (Object.keys(changes).length) await tx.updateTable('crm_leads').set(changes as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'crm_lead', id, 'update', null, { fields: Object.keys(changes) });
      return leadOut(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/crm/leads/:id/convert', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(convertBody, req.body);
    if (b.partyId && b.party) throw badRequest('Give either an existing customer or new customer details, not both.', { party: 'Choose one' });
    return ctx.tx(async (tx) => {
      const lead = await loadLead(tx, ctx, id, true);
      if (!OPEN_LEAD.includes(lead.status)) throw conflict('This lead is already converted or lost.', 'LEAD_CLOSED');
      let partyId: string;
      if (b.partyId) {
        const p = await tx.selectFrom('parties').select('id').where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p) throw badRequest('Customer not found.', { partyId: 'Not found' });
        partyId = p.id;
      } else {
        const p = b.party ?? {};
        const g = p.gstin ?? null;
        const created = await tx.insertInto('parties').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: p.name ?? lead.company_name ?? lead.name,
          phone: p.phone ?? lead.phone ?? null, email: p.email ?? lead.email ?? null, gstin: g, state_code: p.stateCode ?? (g ? g.slice(0, 2) : lead.state_code ?? null),
          address: lead.city ?? null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
        }).returning('id').executeTakeFirstOrThrow();
        partyId = created.id;
        await writeAudit(tx, auditOf(ctx), 'party', partyId, 'create', null, { name: p.name ?? lead.name, fromLead: id });
      }
      let dealId: string | null = null;
      if (b.deal !== null) {
        const d = b.deal ?? { title: lead.requirement ? `${lead.name}: ${String(lead.requirement).slice(0, 80)}` : lead.name, value: num(lead.estimated_value) };
        dealId = await insertDeal(tx, ctx, {
          title: d.title, partyId, leadId: id, value: d.value, stageId: (d as { stageId?: string }).stageId,
          expectedClose: (d as { expectedClose?: string }).expectedClose, ownerId: lead.owner_id ?? ctx.userId,
        });
        await tx.updateTable('crm_activities').set({ deal_id: dealId, lead_id: null }).where('lead_id', '=', id).where('done_at', 'is', null).execute();
      }
      await tx.updateTable('crm_leads').set({ status: 'converted', party_id: partyId, deal_id: dealId, converted_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'crm_lead', id, 'convert', null, { partyId, dealId });
      return { lead: await leadOut(tx, ctx, id), partyId, dealId };
    });
  });

  app.post<{ Params: { id: string } }>('/crm/leads/:id/lost', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(reasonBody, req.body);
    return ctx.tx(async (tx) => {
      const lead = await loadLead(tx, ctx, id, true);
      if (!OPEN_LEAD.includes(lead.status)) throw conflict('This lead is already converted or lost.', 'LEAD_CLOSED');
      await tx.updateTable('crm_leads').set({ status: 'lost', lost_reason: b.reason }).where('id', '=', id).execute();
      await dropOpenFollowUps(tx, ctx, { leadId: id });
      await writeAudit(tx, auditOf(ctx), 'crm_lead', id, 'lost', null, { reason: b.reason });
      return leadOut(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/crm/leads/:id/reopen', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const lead = await loadLead(tx, ctx, id, true);
      if (lead.status !== 'lost') throw conflict('Only a lost lead can be reopened.', 'LEAD_NOT_LOST');
      await tx.updateTable('crm_leads').set({ status: 'contacted', lost_reason: null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'crm_lead', id, 'reopen', null, null);
      return leadOut(tx, ctx, id);
    });
  });

  // Deals -------------------------------------------------------------------------------------

  app.get('/crm/deals', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const q = parse(dealListQuery, req.query);
    return ctx.tx(async (tx) => {
      const where = all([
        sql`d.company_id = ${ctx.companyId}`, sql`d.status = ${q.status}`, ownerCond(ctx, col('d.owner_id'), q.ownerId),
        q.stageId ? sql`d.stage_id = ${q.stageId}` : null, q.partyId ? sql`d.party_id = ${q.partyId}` : null,
        q.q ? sql`(d.title ilike ${likeTerm(q.q)} or p.name ilike ${likeTerm(q.q)})` : null,
      ]);
      const total = await sql<{ n: string }>`select count(*) as n from crm_deals d left join parties p on p.id = d.party_id where ${where}`.execute(tx);
      const rows = await sql<LeadRow>`${DEAL_SQL}
        left join lateral (select due_at from crm_activities x where x.deal_id = d.id and x.done_at is null order by due_at nulls last limit 1) nf on true
        where ${where} order by nf.due_at nulls last, d.value desc, d.created_at desc limit ${q.limit} offset ${q.offset}`.execute(tx);
      return { data: await dealsJson(tx, ctx, rows.rows), total: num(total.rows[0]!.n) };
    });
  });

  app.get('/crm/pipeline', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const q = parse(z.object({ ownerId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      const stages = (await ensureStages(tx, ctx)).filter((s) => s.kind === 'open' && s.is_active);
      const rows = await sql<{ stage_id: string; n: string; value: string; weighted: string }>`
        select d.stage_id, count(*) as n, coalesce(sum(d.value), 0) as value,
          coalesce(sum(d.value * coalesce(d.probability, s.probability) / 100), 0) as weighted
        from crm_deals d join crm_stages s on s.id = d.stage_id
        where ${all([sql`d.company_id = ${ctx.companyId}`, sql`d.status = 'open'`, ownerCond(ctx, col('d.owner_id'), q.ownerId)])}
        group by d.stage_id`.execute(tx);
      const by = new Map(rows.rows.map((r) => [r.stage_id, r]));
      const out = stages.map((s) => {
        const r = by.get(s.id);
        return { stageId: s.id, name: s.name, probability: s.probability, count: num(r?.n), value: round2(num(r?.value)), weightedValue: round2(num(r?.weighted)) };
      });
      // Deals in a retired stage still count in the totals.
      const all2 = rows.rows;
      return {
        openCount: all2.reduce((s, r) => s + num(r.n), 0), openValue: round2(all2.reduce((s, r) => s + num(r.value), 0)),
        weightedValue: round2(all2.reduce((s, r) => s + num(r.weighted), 0)), stages: out,
      };
    });
  });

  app.post('/crm/deals', async (req, reply) => {
    const ctx = req.ctx;
    manage(ctx);
    const b = parse(dealCreate, req.body);
    if (!b.partyId && !b.leadId) throw badRequest('Choose a customer or a lead for this deal.', { partyId: 'Choose a customer or a lead' });
    assertCanAssign(ctx, b.ownerId);
    const out = await ctx.tx(async (tx) => {
      await assertUser(tx, b.ownerId);
      if (b.partyId) {
        if (!await tx.selectFrom('parties').select('id').where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst()) throw badRequest('Customer not found.', { partyId: 'Not found' });
      }
      if (b.leadId) await loadLead(tx, ctx, b.leadId);
      if (b.contactId) {
        const c = await tx.selectFrom('party_contacts').select('party_id').where('id', '=', b.contactId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!c || (b.partyId && c.party_id !== b.partyId)) throw badRequest('Contact person not found for this customer.', { contactId: 'Not found' });
      }
      const id = await insertDeal(tx, ctx, { ...b, ownerId: b.ownerId ?? await defaultOwner(tx, ctx) });
      await writeAudit(tx, auditOf(ctx), 'crm_deal', id, 'create', null, { title: b.title, value: b.value });
      return dealOut(tx, ctx, id);
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/crm/deals/:id', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const deal = await loadDeal(tx, ctx, id);
      const acts = await sql<LeadRow>`${ACT_SQL} where a.deal_id = ${id} and a.company_id = ${ctx.companyId} order by coalesce(a.done_at, a.due_at, a.created_at) desc`.execute(tx);
      const quotes = await sql<LeadRow>`select id, number, kind, status, total, quote_date::text as quote_date from quotations
        where deal_id = ${id} and company_id = ${ctx.companyId} order by created_at desc`.execute(tx);
      const hist = await sql<{ from_stage: string | null; to_stage: string; changed_at: Date; changed_by: string | null }>`
        select f.name as from_stage, t.name as to_stage, h.changed_at, u.name as changed_by from crm_deal_stage_history h
        left join crm_stages f on f.id = h.from_stage_id join crm_stages t on t.id = h.to_stage_id left join users u on u.id = h.changed_by
        where h.deal_id = ${id} order by h.changed_at desc`.execute(tx);
      return {
        ...(await dealsJson(tx, ctx, [deal]))[0]!, activities: acts.rows.map(activityJson),
        quotations: quotes.rows.map((r) => ({ id: r.id, number: r.number, kind: r.kind, status: r.status, total: num(r.total), quoteDate: r.quote_date })),
        stageHistory: hist.rows.map((h) => ({ fromStage: h.from_stage, toStage: h.to_stage, changedAt: iso(h.changed_at), changedBy: h.changed_by })),
      };
    });
  });

  app.patch<{ Params: { id: string } }>('/crm/deals/:id', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(dealPatch, req.body);
    assertCanAssign(ctx, b.ownerId);
    return ctx.tx(async (tx) => {
      const before = await loadDeal(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'deal');
      if (before.status !== 'open') throw conflict('This deal is closed. Reopen it to make changes.', 'DEAL_CLOSED');
      await assertUser(tx, b.ownerId);
      const partyId = b.partyId === undefined ? before.party_id : b.partyId;
      const leadId = b.leadId === undefined ? before.lead_id : b.leadId;
      if (!partyId && !leadId) throw badRequest('A deal needs a customer or a lead.', { partyId: 'Required' });
      const set = {
        title: b.title, party_id: b.partyId, lead_id: b.leadId, contact_id: b.contactId, value: b.value, probability: b.probability,
        expected_close: b.expectedClose, owner_id: b.ownerId, notes: b.notes,
      };
      const changes = Object.fromEntries(Object.entries(set).filter(([, v]) => v !== undefined));
      if (Object.keys(changes).length) await tx.updateTable('crm_deals').set(changes as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'crm_deal', id, 'update', null, { fields: Object.keys(changes) });
      return dealOut(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/crm/deals/:id/stage', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ stageId: z.uuid() }), req.body);
    return ctx.tx(async (tx) => {
      const deal = await loadDeal(tx, ctx, id, true);
      if (deal.status !== 'open') throw conflict('This deal is closed. Reopen it first.', 'DEAL_CLOSED');
      const stage = (await ensureStages(tx, ctx)).find((s) => s.id === b.stageId);
      if (!stage) throw badRequest('Stage not found.', { stageId: 'Not found' });
      if (stage.kind !== 'open') throw badRequest('Use Mark won or Mark lost to close a deal.', { stageId: 'Open stages only' });
      if (!stage.is_active) throw badRequest('That stage is no longer in use.', { stageId: 'Inactive' });
      if (stage.id !== deal.stage_id) {
        await moveDealStage(tx, ctx, deal as never, stage.id);
        await writeAudit(tx, auditOf(ctx), 'crm_deal', id, 'stage', null, { from: deal.stage_name, to: stage.name });
      }
      return dealOut(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/crm/deals/:id/won', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ value: optMoney }), req.body);
    return ctx.tx(async (tx) => {
      const deal = await loadDeal(tx, ctx, id, true);
      if (deal.status !== 'open') throw conflict('This deal is already closed.', 'DEAL_CLOSED');
      if (!await markDealWon(tx, ctx, id, b.value)) throw conflict('This deal is already closed.', 'DEAL_CLOSED');
      await writeAudit(tx, auditOf(ctx), 'crm_deal', id, 'won', null, { value: b.value ?? num(deal.value) });
      return dealOut(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/crm/deals/:id/lost', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(reasonBody, req.body);
    return ctx.tx(async (tx) => {
      const deal = await loadDeal(tx, ctx, id, true);
      if (deal.status !== 'open') throw conflict('This deal is already closed.', 'DEAL_CLOSED');
      const lost = (await ensureStages(tx, ctx)).find((s) => s.kind === 'lost')!;
      await moveDealStage(tx, ctx, deal as never, lost.id, { status: 'lost', lost_reason: b.reason, lost_at: new Date() });
      await dropOpenFollowUps(tx, ctx, { dealId: id });
      await writeAudit(tx, auditOf(ctx), 'crm_deal', id, 'lost', null, { reason: b.reason });
      return dealOut(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/crm/deals/:id/reopen', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const deal = await loadDeal(tx, ctx, id, true);
      if (deal.status === 'open') throw conflict('This deal is already open.', 'DEAL_OPEN');
      const stages = await ensureStages(tx, ctx);
      const prev = await sql<{ from_stage_id: string | null }>`select from_stage_id from crm_deal_stage_history
        where deal_id = ${id} and to_stage_id = ${deal.stage_id} order by changed_at desc limit 1`.execute(tx);
      const back = stages.find((s) => s.id === prev.rows[0]?.from_stage_id && s.kind === 'open' && s.is_active) ?? await firstOpenStage(tx, ctx);
      await moveDealStage(tx, ctx, deal as never, back.id, { status: 'open', won_at: null, lost_at: null, lost_reason: null });
      await writeAudit(tx, auditOf(ctx), 'crm_deal', id, 'reopen', null, { stage: back.name });
      return dealOut(tx, ctx, id);
    });
  });

  // Follow-ups --------------------------------------------------------------------------------

  app.get('/crm/activities', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const q = parse(actListQuery, req.query);
    const today = todayIst();
    const start = dayStart(today);
    const end = dayStart(addDays(today, 1));
    return ctx.tx(async (tx) => {
      const when = q.when === 'overdue' ? sql`a.done_at is null and a.due_at < now()`
        : q.when === 'today' ? sql`a.done_at is null and a.due_at >= ${start} and a.due_at < ${end}`
          : q.when === 'upcoming' ? sql`a.done_at is null and a.due_at >= ${end}` : q.when === 'done' ? sql`a.done_at is not null` : null;
      const where = all([
        sql`a.company_id = ${ctx.companyId}`, ownerCond(ctx, col('a.owner_id'), q.ownerId), when,
        q.leadId ? sql`a.lead_id = ${q.leadId}` : null, q.dealId ? sql`a.deal_id = ${q.dealId}` : null,
        q.partyId ? sql`coalesce(a.party_id, d.party_id, l.party_id) = ${q.partyId}` : null,
        q.q ? sql`a.subject ilike ${likeTerm(q.q)}` : null,
      ]);
      const total = await sql<{ n: string }>`select count(*) as n from crm_activities a left join crm_leads l on l.id = a.lead_id
        left join crm_deals d on d.id = a.deal_id where ${where}`.execute(tx);
      const order = q.when === 'done' ? sql`a.done_at desc` : sql`a.due_at nulls last, a.created_at desc`;
      const rows = await sql<LeadRow>`${ACT_SQL} where ${where} order by ${order} limit ${q.limit} offset ${q.offset}`.execute(tx);
      return { data: await activitiesJson(tx, ctx, rows.rows), total: num(total.rows[0]!.n) };
    });
  });

  app.post('/crm/activities', async (req, reply) => {
    const ctx = req.ctx;
    manage(ctx);
    const b = parse(actCreate, req.body);
    if (!b.leadId && !b.dealId && !b.partyId) throw badRequest('Link the follow-up to a lead, a deal or a customer.', { leadId: 'Choose one' });
    assertCanAssign(ctx, b.ownerId);
    const out = await ctx.tx(async (tx) => {
      await assertUser(tx, b.ownerId);
      const owner = b.ownerId ?? ctx.userId;
      const done = b.kind === 'note' || !!b.doneAt;
      let leadStatus: string | null = null;
      if (b.leadId) { const l = await loadLead(tx, ctx, b.leadId); leadStatus = l.status; }
      if (b.dealId) {
        const d = await loadDeal(tx, ctx, b.dealId);
        if (d.status !== 'open' && !done) throw conflict('This deal is closed, so it cannot get a new follow-up.', 'DEAL_CLOSED');
      }
      if (b.leadId && !done && leadStatus && !OPEN_LEAD.includes(leadStatus)) throw conflict('This lead is closed, so it cannot get a new follow-up.', 'LEAD_CLOSED');
      if (b.partyId && !await tx.selectFrom('parties').select('id').where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst()) {
        throw badRequest('Customer not found.', { partyId: 'Not found' });
      }
      const doneAt = done ? (b.doneAt ?? new Date()) : null;
      if (!done && !b.dueAt) throw badRequest('Set when this follow-up is due.', { dueAt: 'Required' });
      const row = await tx.insertInto('crm_activities').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: b.kind, subject: b.subject, notes: b.notes ?? null, due_at: b.dueAt ?? null,
        done_at: doneAt, outcome: b.outcome ?? null, duration_min: b.durationMin ?? null, lead_id: b.leadId ?? null, deal_id: b.dealId ?? null,
        party_id: b.partyId ?? null, owner_id: owner, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      if (doneAt) await applyFirstContact(tx, ctx, b.leadId ?? null, b.kind, doneAt);
      await writeAudit(tx, auditOf(ctx), 'crm_activity', row.id, 'create', null, { kind: b.kind, subject: b.subject });
      return activityJson(await loadActivity(tx, ctx, row.id));
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/crm/activities/:id', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(actPatch, req.body);
    assertCanAssign(ctx, b.ownerId);
    return ctx.tx(async (tx) => {
      const a = await loadActivity(tx, ctx, id, true);
      if (a.done_at) throw conflict('This follow-up is already done.', 'ALREADY_DONE');
      await assertUser(tx, b.ownerId);
      if (b.dueAt === null) throw badRequest('A follow-up needs a due date.', { dueAt: 'Required' });
      const set = { subject: b.subject, notes: b.notes, due_at: b.dueAt, owner_id: b.ownerId };
      const changes = Object.fromEntries(Object.entries(set).filter(([, v]) => v !== undefined));
      if (Object.keys(changes).length) await tx.updateTable('crm_activities').set(changes as never).where('id', '=', id).execute();
      return activityJson(await loadActivity(tx, ctx, id));
    });
  });

  app.delete<{ Params: { id: string } }>('/crm/activities/:id', async (req, reply) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const a = await loadActivity(tx, ctx, id, true);
      if (a.done_at) throw conflict('A done follow-up stays in the history.', 'ALREADY_DONE');
      await tx.deleteFrom('crm_activities').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'crm_activity', id, 'delete', null, null);
    });
    return reply.status(204).send();
  });

  app.post<{ Params: { id: string } }>('/crm/activities/:id/done', async (req) => {
    const ctx = req.ctx;
    manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(actDone, req.body);
    return ctx.tx(async (tx) => {
      const a = await loadActivity(tx, ctx, id, true);
      if (a.done_at) throw conflict('This follow-up is already done.', 'ALREADY_DONE');
      const now = new Date();
      await tx.updateTable('crm_activities').set({
        done_at: now, outcome: b.outcome, notes: b.notes ?? a.notes, duration_min: b.durationMin ?? a.duration_min,
      }).where('id', '=', id).execute();
      await applyFirstContact(tx, ctx, a.lead_id, a.kind, now);
      let next = null;
      if (b.next) {
        const row = await tx.insertInto('crm_activities').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: b.next.kind, subject: b.next.subject, due_at: b.next.dueAt,
          lead_id: a.lead_id, deal_id: a.deal_id, party_id: a.party_id, owner_id: a.owner_id ?? ctx.userId, created_by: ctx.userId,
        }).returning('id').executeTakeFirstOrThrow();
        next = activityJson(await loadActivity(tx, ctx, row.id));
      }
      await writeAudit(tx, auditOf(ctx), 'crm_activity', id, 'done', null, { outcome: b.outcome });
      return { done: activityJson(await loadActivity(tx, ctx, id)), next };
    });
  });

  // Today and numbers -------------------------------------------------------------------------

  app.get('/crm/today', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const q = parse(z.object({ ownerId: z.union([z.uuid(), z.literal('all')]).optional() }), req.query);
    let owner: string | null = ctx.userId;
    if (q.ownerId === 'all') { if (!canAll(ctx)) throw forbidden('You can only see your own work.'); owner = null; }
    else if (q.ownerId) { if (!canAll(ctx) && q.ownerId !== ctx.userId) throw forbidden('You can only see your own work.'); owner = q.ownerId; }
    const today = todayIst();
    const start = dayStart(today);
    const end = dayStart(addDays(today, 1));
    const weekEnd = dayStart(addDays(today, 8));
    const month = today.slice(0, 7);
    return ctx.tx(async (tx) => {
      const base = (extra: RawBuilder<unknown>) => sql<LeadRow>`${ACT_SQL} where ${all([sql`a.company_id = ${ctx.companyId}`, sql`a.done_at is null`,
        owner ? sql`a.owner_id = ${owner}` : null, extra])} order by a.due_at, a.created_at`;
      const overdue = (await base(sql`a.due_at < now()`).execute(tx)).rows;
      const todayRows = (await base(sql`a.due_at >= now() and a.due_at >= ${start} and a.due_at < ${end}`).execute(tx)).rows;
      const upcoming = (await sql<LeadRow>`${base(sql`a.due_at >= ${end} and a.due_at < ${weekEnd}`)} limit 20`.execute(tx)).rows;
      const nl = await sql<{ n: string }>`select count(*) as n from crm_leads l where l.company_id = ${ctx.companyId}
        and l.created_at >= now() - interval '24 hours' and l.status in ('new','contacted','qualified') ${owner ? sql`and l.owner_id = ${owner}` : sql``}
        and not exists (select 1 from crm_activities a where a.lead_id = l.id and a.done_at is not null)`.execute(tx);
      const m = await monthNumbers(tx, ctx, month, owner);
      return {
        counts: { dueToday: todayRows.length, overdue: overdue.length, newLeads: num(nl.rows[0]!.n) },
        overdue: await activitiesJson(tx, ctx, overdue, true), today: await activitiesJson(tx, ctx, todayRows, true),
        upcoming: await activitiesJson(tx, ctx, upcoming, true), month: m,
      };
    });
  });

  app.get('/crm/stats', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const q = parse(z.object({ from: dateField.optional(), to: dateField.optional(), ownerId: z.uuid().optional() }), req.query);
    const today = todayIst();
    const from = q.from ?? monthStart(today);
    const to = q.to ?? today;
    if (to < from) throw badRequest('The end date is before the start date.', { to: 'Before start' });
    const fromTs = dayStart(from);
    const toTs = dayStart(addDays(to, 1));
    return ctx.tx(async (tx) => {
      const own = (c: string) => ownerCond(ctx, col(c), q.ownerId);
      const stages = await ensureStages(tx, ctx);
      const open = await sql<{ n: string; v: string; w: string }>`select count(*) as n, coalesce(sum(d.value),0) as v,
        coalesce(sum(d.value * coalesce(d.probability, s.probability) / 100),0) as w from crm_deals d join crm_stages s on s.id = d.stage_id
        where ${all([sql`d.company_id = ${ctx.companyId}`, sql`d.status = 'open'`, own('d.owner_id')])}`.execute(tx);
      const won = await sql<{ n: string; v: string; days: string | null }>`select count(*) as n, coalesce(sum(d.value),0) as v,
        avg(extract(epoch from (d.won_at - d.created_at)) / 86400) as days from crm_deals d
        where ${all([sql`d.company_id = ${ctx.companyId}`, sql`d.status = 'won'`, sql`d.won_at >= ${fromTs}`, sql`d.won_at < ${toTs}`, own('d.owner_id')])}`.execute(tx);
      const lost = await sql<{ reason: string | null; n: string }>`select d.lost_reason as reason, count(*) as n from crm_deals d
        where ${all([sql`d.company_id = ${ctx.companyId}`, sql`d.status = 'lost'`, sql`d.lost_at >= ${fromTs}`, sql`d.lost_at < ${toTs}`, own('d.owner_id')])}
        group by d.lost_reason order by count(*) desc, d.lost_reason`.execute(tx);
      const lostCount = lost.rows.reduce((s, r) => s + num(r.n), 0);
      const wonCount = num(won.rows[0]!.n);
      const wonValue = round2(num(won.rows[0]!.v));
      const openValue = round2(num(open.rows[0]!.v));
      // Targets for the months the range touches: the user's own, or the company's.
      const tgt = await sql<{ amount: string }>`select amount from crm_targets where company_id = ${ctx.companyId}
        and month >= ${monthStart(from)}::date and month <= ${monthStart(to)}::date
        and ${q.ownerId ? sql`user_id = ${q.ownerId}` : !canAll(ctx) ? sql`user_id = ${ctx.userId}` : sql`user_id is null`}`.execute(tx);
      const target = round2(tgt.rows.reduce((s, r) => s + num(r.amount), 0));
      const gap = round2(Math.max(target - wonValue, 0));
      const resp = await sql<{ h: string | null }>`select avg(extract(epoch from (l.first_contact_at - l.created_at)) / 3600) as h from crm_leads l
        where ${all([sql`l.company_id = ${ctx.companyId}`, sql`l.created_at >= ${fromTs}`, sql`l.created_at < ${toTs}`, sql`l.first_contact_at is not null`, own('l.owner_id')])}`.execute(tx);
      const bySource = await sql<{ source: string; n: string; c: string }>`select l.source, count(*) as n, count(*) filter (where l.status = 'converted') as c from crm_leads l
        where ${all([sql`l.company_id = ${ctx.companyId}`, sql`l.created_at >= ${fromTs}`, sql`l.created_at < ${toTs}`, own('l.owner_id')])}
        group by l.source order by count(*) desc, l.source`.execute(tx);
      // Stage conversion from history rows: a deal "advanced" when a later row goes to a later stage or to won.
      const hist = await sql<{ deal_id: string; to_stage_id: string; changed_at: Date }>`select h.deal_id, h.to_stage_id, h.changed_at from crm_deal_stage_history h
        join crm_deals d on d.id = h.deal_id where ${all([sql`d.company_id = ${ctx.companyId}`, own('d.owner_id')])}
        and h.deal_id in (select deal_id from crm_deal_stage_history where changed_at >= ${fromTs} and changed_at < ${toTs})
        order by h.deal_id, h.changed_at`.execute(tx);
      const sortOf = new Map(stages.map((s) => [s.id, s]));
      const perDeal = new Map<string, { to: string; at: number }[]>();
      for (const h of hist.rows) (perDeal.get(h.deal_id) ?? perDeal.set(h.deal_id, []).get(h.deal_id)!).push({ to: h.to_stage_id, at: new Date(h.changed_at).getTime() });
      const conv = new Map(stages.filter((s) => s.kind === 'open').map((s) => [s.id, { entered: new Set<string>(), advanced: new Set<string>() }]));
      for (const [dealId, rows] of perDeal) {
        rows.forEach((r, i) => {
          const st = sortOf.get(r.to);
          const c = conv.get(r.to);
          if (!st || !c || r.at < fromTs.getTime() || r.at >= toTs.getTime()) return;
          c.entered.add(dealId);
          if (rows.some((x, j) => j > i && x.at >= r.at && (sortOf.get(x.to)?.kind === 'won' || (sortOf.get(x.to)?.kind === 'open' && sortOf.get(x.to)!.sort > st.sort)))) c.advanced.add(dealId);
        });
      }
      const stageConversion = stages.filter((s) => s.kind === 'open' && s.is_active || (conv.get(s.id)?.entered.size ?? 0) > 0).filter((s) => s.kind === 'open').map((s) => {
        const c = conv.get(s.id)!;
        return { stageId: s.id, name: s.name, entered: c.entered.size, advanced: c.advanced.size, rate: c.entered.size ? round2((c.advanced.size / c.entered.size) * 100) : null };
      });
      let byOwner: unknown = undefined;
      if (canAll(ctx)) {
        const bo = await sql<{ owner_id: string | null; name: string | null; wv: string; wc: string; ov: string }>`select d.owner_id, u.name,
          coalesce(sum(d.value) filter (where d.status = 'won' and d.won_at >= ${fromTs} and d.won_at < ${toTs}), 0) as wv,
          count(*) filter (where d.status = 'won' and d.won_at >= ${fromTs} and d.won_at < ${toTs}) as wc,
          coalesce(sum(d.value) filter (where d.status = 'open'), 0) as ov
          from crm_deals d left join users u on u.id = d.owner_id where d.company_id = ${ctx.companyId} ${q.ownerId ? sql`and d.owner_id = ${q.ownerId}` : sql``}
          group by d.owner_id, u.name order by 3 desc, u.name`.execute(tx);
        byOwner = bo.rows.map((r) => ({ ownerId: r.owner_id, name: r.name ?? 'Unassigned', wonValue: round2(num(r.wv)), wonCount: num(r.wc), openValue: round2(num(r.ov)) }));
      }
      return {
        from, to, openCount: num(open.rows[0]!.n), openValue, weightedValue: round2(num(open.rows[0]!.w)), wonCount, wonValue, lostCount,
        winRate: wonCount + lostCount ? round2((wonCount / (wonCount + lostCount)) * 100) : null,
        avgDealSize: wonCount ? round2(wonValue / wonCount) : null,
        avgCycleDays: wonCount && won.rows[0]!.days !== null ? round2(num(won.rows[0]!.days)) : null,
        target, achievement: wonValue, gap, achievementPct: target > 0 ? round2((wonValue / target) * 100) : null,
        coverage: gap > 0 ? round2(openValue / gap) : null,
        avgResponseHours: resp.rows[0]!.h === null ? null : round2(num(resp.rows[0]!.h)),
        stageConversion,
        bySource: bySource.rows.map((r) => ({ source: r.source, leads: num(r.n), converted: num(r.c), rate: num(r.n) ? round2((num(r.c) / num(r.n)) * 100) : null })),
        lostReasons: lost.rows.map((r) => ({ reason: r.reason ?? 'No reason given', count: num(r.n) })),
        ...(byOwner ? { byOwner } : {}),
      };
    });
  });

  app.get<{ Params: { id: string } }>('/crm/parties/:id/overview', async (req) => {
    const ctx = req.ctx;
    view(ctx);
    const id = parse(z.uuid(), req.params.id);
    const today = todayIst();
    return ctx.tx(async (tx) => {
      const party = await tx.selectFrom('parties').select(['id', 'name', 'phone', 'email', 'gstin', 'credit_limit'])
        .where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw notFound('Customer');
      const bal = (await balancesOf(tx, ctx, [id])).get(id)!;
      const since = addDays(today, -365);
      const s12 = await sql<{ s: string; last: string | null }>`select coalesce(sum(total) filter (where invoice_date >= ${since}::date), 0) as s, max(invoice_date)::text as last
        from invoices where company_id = ${ctx.companyId} and party_id = ${id} and status = 'posted'`.execute(tx);
      const pay = await sql<{ days: string | null }>`select avg(p.last_pay - i.invoice_date) as days from invoices i join lateral (
          select max(pm.payment_date) as last_pay from payment_allocations pa join payments pm on pm.id = pa.payment_id
          where pa.doc_type = 'invoice' and pa.doc_id = i.id and pm.status = 'posted') p on true
        where i.company_id = ${ctx.companyId} and i.party_id = ${id} and i.status = 'posted' and i.amount_paid >= i.total
          and i.invoice_date >= ${since}::date and p.last_pay is not null`.execute(tx);
      const dealRows = await sql<LeadRow>`${DEAL_SQL} where d.company_id = ${ctx.companyId} and d.party_id = ${id} and d.status = 'open'
        and ${ownerCond(ctx, col('d.owner_id')) ?? sql`true`} order by d.value desc`.execute(tx);
      const contacts = await contactsOf(tx, ctx, id);
      const limit = num(party.credit_limit);
      const tl = await sql<{ at: Date | string; kind: string; title: string; detail: string | null; ref: string; amount: string | null }>`
        select * from (
          select l.created_at as at, 'lead' as kind, l.name as title, l.requirement as detail, l.id::text as ref, l.estimated_value as amount
            from crm_leads l where l.company_id = ${ctx.companyId} and l.party_id = ${id}
          union all select coalesce(a.done_at, a.created_at), 'activity', a.subject, coalesce(a.outcome, a.kind), a.id::text, null
            from crm_activities a left join crm_deals d on d.id = a.deal_id left join crm_leads l on l.id = a.lead_id
            where a.company_id = ${ctx.companyId} and coalesce(a.party_id, d.party_id, l.party_id) = ${id}
          union all select d.created_at, 'deal', d.title, d.status, d.id::text, d.value from crm_deals d where d.company_id = ${ctx.companyId} and d.party_id = ${id}
          union all select q.created_at, 'quotation', q.number, q.status, q.id::text, q.total from quotations q where q.company_id = ${ctx.companyId} and q.party_id = ${id}
          union all select i.invoice_date::timestamp at time zone 'Asia/Kolkata', 'invoice', i.number, i.status, i.id::text, i.total
            from invoices i where i.company_id = ${ctx.companyId} and i.party_id = ${id} and i.status = 'posted'
          union all select pm.payment_date::timestamp at time zone 'Asia/Kolkata', 'payment', pm.number, pm.mode, pm.id::text, pm.amount
            from payments pm where pm.company_id = ${ctx.companyId} and pm.party_id = ${id} and pm.kind = 'receipt' and pm.status = 'posted'
          union all select n.note_date::timestamp at time zone 'Asia/Kolkata', 'credit_note', n.number, n.reason, n.id::text, n.total
            from credit_notes n where n.company_id = ${ctx.companyId} and n.party_id = ${id} and n.status = 'posted'
        ) t order by at desc limit 60`.execute(tx);
      return {
        party: { id: party.id, name: party.name, phone: party.phone, email: party.email, gstin: party.gstin },
        owes: bal.owes, overdue: bal.overdue, oldestOverdueDays: bal.oldestOverdueDays, creditLimit: limit,
        creditUsedPct: limit > 0 ? round2((bal.owes / limit) * 100) : null, sales12m: round2(num(s12.rows[0]!.s)),
        avgDaysToPay: pay.rows[0]!.days === null ? null : round2(num(pay.rows[0]!.days)), lastInvoiceDate: s12.rows[0]!.last,
        openDeals: await dealsJson(tx, ctx, dealRows.rows), contacts,
        timeline: tl.rows.map((r) => ({ at: iso(r.at), kind: r.kind, title: r.title, detail: r.detail, refId: r.ref, amount: r.amount === null ? null : num(r.amount) })),
      };
    });
  });

  // IndiaMART ---------------------------------------------------------------------------------

  app.post('/crm/indiamart/pull', async (req) => {
    const ctx = req.ctx;
    ctx.require('crm.settings');
    const now = new Date();
    // Claim the pull first so two clicks cannot run together; the previous time comes back if the pull fails.
    const claim = await ctx.tx(async (tx) => {
      const s = await sql<{ key: string | null; last: Date | null }>`select indiamart_key_sealed as key, indiamart_last_pull_at as last from crm_settings
        where company_id = ${ctx.companyId} for update`.execute(tx);
      const row = s.rows[0];
      if (!row?.key) throw conflict('Save your IndiaMART key in the CRM settings first.', 'NO_INDIAMART_KEY');
      if (row.last && now.getTime() - new Date(row.last).getTime() < 5 * 60_000) {
        throw new AppError(429, 'TOO_SOON', 'IndiaMART allows one pull every 5 minutes. Try again shortly.');
      }
      await tx.updateTable('crm_settings').set({ indiamart_last_pull_at: now }).where('company_id', '=', ctx.companyId).execute();
      return { key: row.key, last: row.last ? new Date(row.last) : null };
    });
    const earliest = new Date(now.getTime() - 7 * 86_400_000);
    // Start a little before the last pull; repeats are dropped by the enquiry id.
    const from = claim.last ? new Date(Math.max(claim.last.getTime() - 5 * 60_000, earliest.getTime())) : earliest;
    let leads;
    try {
      leads = await pullIndiamart(unseal(claim.key), from, now, indiamartFetch);
    } catch (e) {
      const message = (e instanceof IndiamartError ? e.message : 'IndiaMART could not be reached. Try again later.').slice(0, 500);
      await ctx.tx((tx) => tx.updateTable('crm_settings').set({ indiamart_last_pull_at: claim.last, indiamart_last_error: message })
        .where('company_id', '=', ctx.companyId).execute());
      throw new AppError(502, 'INDIAMART_ERROR', message);
    }
    return ctx.tx(async (tx) => {
      const owner = await defaultOwner(tx, ctx);
      let added = 0;
      for (const l of leads) {
        const row = await tx.insertInto('crm_leads').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, name: l.name, company_name: l.companyName, phone: l.phone, email: l.email,
          city: l.city, state_code: l.stateCode, requirement: l.requirement, source: 'indiamart', source_ref: l.uniqueId, owner_id: owner, created_by: ctx.userId,
        }).onConflict((oc) => oc.columns(['company_id', 'source', 'source_ref']).where('source_ref', 'is not', null).doNothing()).returning('id').executeTakeFirst();
        if (row) added++;
      }
      await tx.updateTable('crm_settings').set({ indiamart_last_pull_at: now, indiamart_last_error: null }).where('company_id', '=', ctx.companyId).execute();
      await writeAudit(tx, auditOf(ctx), 'crm_indiamart', null, 'pull', null, { added, skipped: leads.length - added });
      return { added, skipped: leads.length - added, lastPullAt: now.toISOString() };
    });
  });
}

function stageJson(s: { id: string; name: string; probability: number; kind: string; sort: number; is_active: boolean }) {
  return { id: s.id, name: s.name, probability: s.probability, kind: s.kind, sort: s.sort, isActive: s.is_active };
}

async function findDuplicate(tx: Tx, ctx: RequestContext, phone: string | undefined | null, email: string | undefined | null) {
  const p = last10(phone);
  const r = await sql<{ id: string; name: string; status: string }>`select id, name, status from crm_leads where company_id = ${ctx.companyId}
    and status in ('new','contacted','qualified') and (
      (${p} <> '' and right(regexp_replace(coalesce(phone,''), '\D', '', 'g'), 10) = ${p})
      or (${email ?? null}::text is not null and lower(email) = lower(${email ?? null}::text)))
    order by created_at desc limit 1`.execute(tx);
  return r.rows[0] ?? null;
}

/** This month's target, wins and open pipeline for one owner, or the whole company when owner is null. */
async function monthNumbers(tx: Tx, ctx: RequestContext, month: string, owner: string | null) {
  const start = dayStart(`${month}-01`);
  const end = dayStart(addDays(`${month}-01`, 32).slice(0, 7) + '-01');
  const won = await sql<{ v: string }>`select coalesce(sum(value), 0) as v from crm_deals where company_id = ${ctx.companyId} and status = 'won'
    and won_at >= ${start} and won_at < ${end} ${owner ? sql`and owner_id = ${owner}` : sql``}`.execute(tx);
  const open = await sql<{ n: string; v: string; w: string }>`select count(*) as n, coalesce(sum(d.value), 0) as v,
    coalesce(sum(d.value * coalesce(d.probability, s.probability) / 100), 0) as w from crm_deals d join crm_stages s on s.id = d.stage_id
    where d.company_id = ${ctx.companyId} and d.status = 'open' ${owner ? sql`and d.owner_id = ${owner}` : sql``}`.execute(tx);
  const t = await sql<{ amount: string }>`select amount from crm_targets where company_id = ${ctx.companyId} and month = ${`${month}-01`}::date
    and ${owner ? sql`user_id = ${owner}` : sql`user_id is null`}`.execute(tx);
  return {
    month, target: round2(num(t.rows[0]?.amount)), won: round2(num(won.rows[0]!.v)), openCount: num(open.rows[0]!.n),
    openValue: round2(num(open.rows[0]!.v)), weightedValue: round2(num(open.rows[0]!.w)),
  };
}

// Contact persons --------------------------------------------------------------------------------

async function contactsOf(tx: Tx, ctx: RequestContext, partyId: string) {
  const rows = await tx.selectFrom('party_contacts').selectAll().where('party_id', '=', partyId).where('company_id', '=', ctx.companyId)
    .orderBy('is_primary', 'desc').orderBy('name').execute();
  return rows.map(contactJson);
}
const contactJson = (c: { id: string; name: string; designation: string | null; phone: string | null; email: string | null; is_primary: boolean; notes: string | null }) => ({
  id: c.id, name: c.name, designation: c.designation, phone: c.phone, email: c.email, isPrimary: c.is_primary, notes: c.notes,
});

/** Contact persons on a party (core). */
export async function partyContactRoutes(app: FastifyInstance) {
  const needParty = async (tx: Tx, ctx: RequestContext, id: string) => {
    if (!await tx.selectFrom('parties').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst()) throw notFound('Party');
  };
  const clearPrimary = (tx: Tx, partyId: string, except: string) =>
    tx.updateTable('party_contacts').set({ is_primary: false }).where('party_id', '=', partyId).where('id', '!=', except).execute();

  app.get<{ Params: { id: string } }>('/parties/:id/contacts', async (req) => {
    const ctx = req.ctx;
    ctx.require('parties.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => { await needParty(tx, ctx, id); return { data: await contactsOf(tx, ctx, id) }; });
  });

  app.post<{ Params: { id: string } }>('/parties/:id/contacts', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('parties.edit');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(contactCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      await needParty(tx, ctx, id);
      const row = await tx.insertInto('party_contacts').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, party_id: id, name: b.name, designation: b.designation ?? null, phone: b.phone ?? null,
        email: b.email ?? null, is_primary: !!b.isPrimary, notes: b.notes ?? null,
      }).returning('id').executeTakeFirstOrThrow();
      if (b.isPrimary) await clearPrimary(tx, id, row.id);
      await writeAudit(tx, auditOf(ctx), 'party_contact', row.id, 'create', null, { partyId: id, name: b.name });
      return contactsOf(tx, ctx, id).then((list) => list.find((c) => c.id === row.id)!);
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string; contactId: string } }>('/parties/:id/contacts/:contactId', async (req) => {
    const ctx = req.ctx;
    ctx.require('parties.edit');
    const id = parse(z.uuid(), req.params.id);
    const contactId = parse(z.uuid(), req.params.contactId);
    const b = parse(contactPatch, req.body);
    return ctx.tx(async (tx) => {
      const c = await tx.selectFrom('party_contacts').select('id').where('id', '=', contactId).where('party_id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!c) throw notFound('Contact person');
      const set = { name: b.name, designation: b.designation, phone: b.phone, email: b.email, is_primary: b.isPrimary, notes: b.notes };
      const changes = Object.fromEntries(Object.entries(set).filter(([, v]) => v !== undefined));
      if (Object.keys(changes).length) await tx.updateTable('party_contacts').set(changes as never).where('id', '=', contactId).execute();
      if (b.isPrimary) await clearPrimary(tx, id, contactId);
      await writeAudit(tx, auditOf(ctx), 'party_contact', contactId, 'update', null, { fields: Object.keys(changes) });
      return (await contactsOf(tx, ctx, id)).find((x) => x.id === contactId)!;
    });
  });

  app.delete<{ Params: { id: string; contactId: string } }>('/parties/:id/contacts/:contactId', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('parties.edit');
    const id = parse(z.uuid(), req.params.id);
    const contactId = parse(z.uuid(), req.params.contactId);
    await ctx.tx(async (tx) => {
      const res = await tx.deleteFrom('party_contacts').where('id', '=', contactId).where('party_id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!res.numDeletedRows) throw notFound('Contact person');
      await writeAudit(tx, auditOf(ctx), 'party_contact', contactId, 'delete', null, null);
    });
    return reply.status(204).send();
  });
}
