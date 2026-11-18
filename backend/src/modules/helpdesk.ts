import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { registerJobHandler } from '../lib/jobs.ts';
import { notify } from '../lib/notify.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { businessMillis, DEFAULT_HOURS, DEFAULT_SLA, dueAt, type Hours } from '../lib/sla.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { fileRef, requireFiles } from './files.ts';
import { coveringContracts, runContractReminders } from './service-contracts.ts';

/*
 * Helpdesk tickets. Due times are fixed from the settings when a ticket is made (and again when its priority
 * changes). Breach is never stored: it is worked out from the due time and the time of the response or
 * resolution, so it cannot drift.
 */

const PRIORITIES = ['low', 'medium', 'high', 'urgent'] as const;
const STATUSES = ['new', 'open', 'waiting', 'resolved', 'closed'] as const;
type Status = (typeof STATUSES)[number];
const CHANNELS = ['phone', 'email', 'whatsapp', 'walk_in', 'portal'] as const;
const NEXT: Record<Status, Status[]> = {
  new: ['open', 'waiting', 'resolved', 'closed'],
  open: ['waiting', 'resolved', 'closed'],
  waiting: ['open', 'resolved', 'closed'],
  resolved: ['open', 'closed'],
  closed: ['open'],
};
const timeField = z.string().regex(/^([01][0-9]|2[0-3]):[0-5][0-9]$/, 'Use HH:MM');
const slaEntry = z.object({
  firstResponseHours: z.coerce.number().positive().max(2000), resolutionHours: z.coerce.number().positive().max(20000),
});
const settingsBody = z.object({
  hoursMode: z.enum(['24x7', 'business']).optional(),
  workDays: z.array(z.number().int().min(1).max(7)).min(1).max(7).optional(),
  startTime: timeField.optional(), endTime: timeField.optional(),
  autoCloseDays: z.coerce.number().int().min(0).max(90).optional(),
  notifyCustomer: z.boolean().optional(),
  renewalDays: z.coerce.number().int().min(1).max(120).optional(),
  sla: z.object({ low: slaEntry.optional(), medium: slaEntry.optional(), high: slaEntry.optional(), urgent: slaEntry.optional() }).optional(),
});
const createBody = z.object({
  partyId: z.uuid(), subject: z.string().trim().min(1, 'Write a subject').max(200), description: optionalText(5000),
  channel: z.enum(CHANNELS), category: optionalText(60), priority: z.enum(PRIORITIES).default('medium'),
  contactName: optionalText(100), contactPhone: optionalText(20),
  itemId: z.uuid().optional(), serialNo: optionalText(60), invoiceId: z.uuid().optional(), contractId: z.uuid().optional(),
  assigneeId: z.uuid().optional(),
});
const patchBody = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  subject: z.string().trim().min(1).max(200).optional(), description: nullableText(5000), category: nullableText(60),
  priority: z.enum(PRIORITIES).optional(), assigneeId: z.uuid().nullable().optional(),
  itemId: z.uuid().nullable().optional(), serialNo: nullableText(60), invoiceId: z.uuid().nullable().optional(),
  contractId: z.uuid().nullable().optional(), contactName: nullableText(100), contactPhone: nullableText(20),
});
const messageBody = z.object({
  kind: z.enum(['reply', 'note', 'customer']), body: z.string().trim().min(1, 'Write a message').max(5000),
  fileIds: z.array(z.uuid()).max(8).default([]),
});
const statusBody = z.object({ status: z.enum(STATUSES) });
const listQuery = pagingQuery.extend({
  status: z.enum(STATUSES).optional(), priority: z.enum(PRIORITIES).optional(), assigneeId: z.uuid().optional(),
  partyId: z.uuid().optional(), category: z.string().max(60).optional(), channel: z.enum(CHANNELS).optional(),
  open: z.enum(['true', 'false']).optional(), breached: z.enum(['true', 'false']).optional(), mine: z.enum(['true', 'false']).optional(),
});
const rangeQuery = z.object({
  from: z.string().refine(isValidDate).optional(), to: z.string().refine(isValidDate).optional(),
});

// Settings ----------------------------------------------------------------------------------------

export interface HdSettings {
  hoursMode: '24x7' | 'business'; workDays: number[]; startTime: string; endTime: string; autoCloseDays: number;
  notifyCustomer: boolean; renewalDays: number;
  sla: Record<string, { firstResponseHours: number; resolutionHours: number }>; updatedAt: Date | null;
}

export async function loadHdSettings(tx: Tx, companyId: string): Promise<HdSettings> {
  const s = await tx.selectFrom('hd_settings').selectAll().where('company_id', '=', companyId).executeTakeFirst();
  const rows = await tx.selectFrom('hd_sla').selectAll().where('company_id', '=', companyId).execute();
  const sla: HdSettings['sla'] = JSON.parse(JSON.stringify(DEFAULT_SLA));
  for (const r of rows) sla[r.priority] = { firstResponseHours: Number(r.first_response_hours), resolutionHours: Number(r.resolution_hours) };
  return {
    hoursMode: (s?.hours_mode as HdSettings['hoursMode']) ?? DEFAULT_HOURS.mode, workDays: s?.work_days ?? DEFAULT_HOURS.workDays,
    startTime: s?.start_time ?? DEFAULT_HOURS.startTime, endTime: s?.end_time ?? DEFAULT_HOURS.endTime,
    autoCloseDays: s?.auto_close_days ?? 7, notifyCustomer: s?.notify_customer ?? true, renewalDays: s?.renewal_days ?? 30,
    sla, updatedAt: s?.updated_at ?? null,
  };
}

const hoursOf = (s: HdSettings): Hours => ({ mode: s.hoursMode, workDays: s.workDays, startTime: s.startTime, endTime: s.endTime });

/** First response and resolution due times for a priority, counted from `from`. */
export function dueTimes(s: HdSettings, priority: string, from: Date, pausedMs = 0) {
  const t = s.sla[priority] ?? DEFAULT_SLA.medium!;
  const extra = pausedMs / 3600_000;
  return { firstResponseDue: dueAt(from, t.firstResponseHours + extra, hoursOf(s)), resolutionDue: dueAt(from, t.resolutionHours + extra, hoursOf(s)) };
}

/** Records a status change and keeps the waiting clock: time waiting on the customer is added to both SLA targets. */
async function applyStatus(tx: Tx, ctx: { tenantId: string; companyId: string; userId: string | null }, t: {
  id: string; status: string; priority: string; created_at: Date; waiting_since: Date | null; paused_ms: string | number;
}, to: Status, set: Record<string, unknown>, now = new Date()) {
  const s = await loadHdSettings(tx, ctx.companyId);
  set.status = to;
  if (to === 'waiting' && t.status !== 'waiting') set.waiting_since = now;
  if (t.status === 'waiting' && to !== 'waiting') {
    const paused = Number(t.paused_ms) + (t.waiting_since ? businessMillis(t.waiting_since, now, hoursOf(s)) : 0);
    const due = dueTimes(s, t.priority, t.created_at, paused);
    set.paused_ms = paused; set.waiting_since = null;
    set.first_response_due = due.firstResponseDue; set.resolution_due = due.resolutionDue;
  }
  await tx.insertInto('hd_status_history').values({ tenant_id: ctx.tenantId, ticket_id: t.id, status: to, at: now, changed_by: ctx.userId }).execute();
}

/** Due times as they stand now: while a ticket waits, the open wait is added too. */
function liveDue(r: { status: string; waiting_since: Date | null; first_response_due: Date; resolution_due: Date }, s: HdSettings | null, now: Date) {
  if (r.status !== 'waiting' || !r.waiting_since || !s) return { first: r.first_response_due, resolution: r.resolution_due };
  const h = businessMillis(r.waiting_since, now, hoursOf(s)) / 3600_000;
  return { first: dueAt(r.first_response_due, h, hoursOf(s)), resolution: dueAt(r.resolution_due, h, hoursOf(s)) };
}

// Ticket JSON -------------------------------------------------------------------------------------

function slaState(due: Date, doneAt: Date | null, now: Date) {
  if (doneAt) return { state: doneAt.getTime() <= due.getTime() ? 'met' : 'breached', minutesLeft: null };
  return { state: now.getTime() > due.getTime() ? 'breached' : 'pending', minutesLeft: Math.round((due.getTime() - now.getTime()) / 60000) };
}

function ticketQuery(tx: Tx) {
  return tx.selectFrom('hd_tickets as t').innerJoin('parties as p', 'p.id', 't.party_id')
    .leftJoin('items as i', 'i.id', 't.item_id').leftJoin('invoices as inv', 'inv.id', 't.invoice_id')
    .leftJoin('service_contracts as c', 'c.id', 't.contract_id').leftJoin('users as a', 'a.id', 't.assignee_id')
    .innerJoin('users as cb', 'cb.id', 't.created_by')
    .selectAll('t')
    .select(['p.name as party_name', 'i.name as item_name', 'inv.number as invoice_number', 'c.number as contract_number',
      'c.status as contract_status', 'c.end_date as contract_end', 'a.name as assignee_name', 'cb.name as created_by_name']);
}
type TicketRow = Awaited<ReturnType<ReturnType<typeof ticketQuery>['executeTakeFirstOrThrow']>>;

function ticketJson(r: TicketRow, now = new Date(), s: HdSettings | null = null) {
  const done = r.resolved_at ?? r.closed_at;
  const live = liveDue(r, s, now);
  return {
    id: r.id, number: r.number, partyId: r.party_id, partyName: r.party_name, contactName: r.contact_name, contactPhone: r.contact_phone,
    subject: r.subject, description: r.description, channel: r.channel, category: r.category, priority: r.priority, status: r.status,
    itemId: r.item_id, itemName: r.item_name, serialNo: r.serial_no, invoiceId: r.invoice_id, invoiceNumber: r.invoice_number,
    contractId: r.contract_id, contractNumber: r.contract_number,
    covered: !!r.contract_id && r.contract_status === 'active' && String(r.contract_end) >= todayIst(),
    assigneeId: r.assignee_id, assigneeName: r.assignee_name,
    firstResponseDue: live.first, resolutionDue: live.resolution, slaPaused: r.status === 'waiting', pausedMinutes: Math.round(Number(r.paused_ms) / 60000), firstResponseAt: r.first_response_at,
    resolvedAt: r.resolved_at, closedAt: r.closed_at,
    response: slaState(live.first, r.first_response_at, now), resolution: slaState(live.resolution, done, now),
    createdBy: { id: r.created_by, name: r.created_by_name }, createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

async function loadTicket(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  const row = await ticketQuery(tx).where('t.id', '=', id).where('t.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row) throw notFound('Ticket');
  if (lock) await tx.selectFrom('hd_tickets').select('id').where('id', '=', id).forUpdate().execute();
  return row;
}

async function detail(tx: Tx, ctx: RequestContext, id: string) {
  const t = await loadTicket(tx, ctx, id);
  const msgs = await tx.selectFrom('hd_messages as m').leftJoin('users as u', 'u.id', 'm.author_id')
    .select(['m.id', 'm.kind', 'm.body', 'm.author_id', 'u.name as author_name', 'm.file_ids', 'm.created_at'])
    .where('m.ticket_id', '=', id).orderBy('m.created_at').orderBy('m.id').execute();
  const fileIds = [...new Set(msgs.flatMap((m) => m.file_ids))];
  const files = fileIds.length ? await tx.selectFrom('files').select(['id', 'name', 'mime_type', 'size']).where('id', 'in', fileIds).execute() : [];
  return {
    ...ticketJson(t, new Date(), await loadHdSettings(tx, ctx.companyId)),
    messages: msgs.map((m) => ({
      id: m.id, kind: m.kind, body: m.body, author: m.author_id ? { id: m.author_id, name: m.author_name } : null,
      files: m.file_ids.map((f) => files.find((x) => x.id === f)).filter(Boolean).map((f) => fileRef(f!)), createdAt: m.created_at,
    })),
  };
}

async function addMessage(tx: Tx, ctx: { tenantId: string; userId: string | null }, ticketId: string, kind: string, body: string, fileIds: string[] = []) {
  await tx.insertInto('hd_messages').values({
    tenant_id: ctx.tenantId, ticket_id: ticketId, kind, body, author_id: kind === 'system' ? null : ctx.userId, file_ids: fileIds,
  }).execute();
}

/** Queues a message to the ticket's customer through the notification outbox (when the setting is on). */
async function tellCustomer(tx: Tx, who: { tenantId: string; companyId: string }, ticketId: string, headline: string, message?: string) {
  const s = await loadHdSettings(tx, who.companyId);
  if (!s.notifyCustomer) return;
  const t = await tx.selectFrom('hd_tickets as t').innerJoin('parties as p', 'p.id', 't.party_id')
    .select(['t.number', 't.subject', 'p.id as party_id', 'p.name', 'p.email', 'p.phone']).where('t.id', '=', ticketId).executeTakeFirst();
  const co = await tx.selectFrom('companies').select('name').where('id', '=', who.companyId).executeTakeFirst();
  if (!t) return;
  await notify(tx, who, {
    to: { email: t.email, phone: t.phone, partyId: t.party_id }, template: 'ticket_update',
    data: { number: t.number, subject: t.subject, partyName: t.name, companyName: co?.name ?? '', headline, message: message ?? '' },
  });
}

async function requireStaff(tx: Tx, ctx: RequestContext, id: string) {
  const r = await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id').select('u.id')
    .where('ur.company_id', '=', ctx.companyId).where('u.is_active', '=', true).where('u.id', '=', id).executeTakeFirst();
  if (!r) throw badRequest('Choose a person who works in this business.', { assigneeId: 'Not found' });
}

// Daily job ---------------------------------------------------------------------------------------

/** Closes tickets resolved more than autoCloseDays ago and sends contract renewal reminders. */
export async function runHelpdeskDaily(tx: Tx, who: { tenantId: string; companyId: string }, today: string) {
  const s = await loadHdSettings(tx, who.companyId);
  let closed = 0;
  if (s.autoCloseDays > 0) {
    const cutoff = new Date(Date.now() - s.autoCloseDays * 86_400_000);
    const rows = await tx.selectFrom('hd_tickets').select('id').where('company_id', '=', who.companyId)
      .where('status', '=', 'resolved').where('resolved_at', '<', cutoff).forUpdate().execute();
    for (const r of rows) {
      await tx.updateTable('hd_tickets').set({ status: 'closed', closed_at: new Date() }).where('id', '=', r.id).execute();
      await tx.insertInto('hd_status_history').values({ tenant_id: who.tenantId, ticket_id: r.id, status: 'closed' }).execute();
      await addMessage(tx, { tenantId: who.tenantId, userId: null }, r.id, 'system', `Closed automatically after ${s.autoCloseDays} days resolved.`);
      closed += 1;
    }
  }
  const reminders = await runContractReminders(tx, who, today, s.renewalDays);
  return { closed, reminders };
}

registerJobHandler('helpdesk.daily', async (tx, job) => {
  if (!job.company_id) return {};
  return runHelpdeskDaily(tx, { tenantId: job.tenant_id, companyId: job.company_id }, todayIst());
});

// Routes ------------------------------------------------------------------------------------------

export async function helpdeskRoutes(app: FastifyInstance): Promise<void> {
  app.get('/helpdesk/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.view', 'helpdesk.manage', 'helpdesk.settings');
    return ctx.tx((tx) => loadHdSettings(tx, ctx.companyId));
  });

  const saveSettings = async (req: { ctx: RequestContext; body: unknown }) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.settings');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadHdSettings(tx, ctx.companyId);
      const start = b.startTime ?? before.startTime;
      const end = b.endTime ?? before.endTime;
      if ((b.hoursMode ?? before.hoursMode) === 'business' && end <= start) {
        throw badRequest('Closing time must be after opening time.', { endTime: 'After opening' });
      }
      const values = {
        hours_mode: b.hoursMode, work_days: b.workDays ? [...new Set(b.workDays)].sort() : undefined, start_time: b.startTime,
        end_time: b.endTime, auto_close_days: b.autoCloseDays, notify_customer: b.notifyCustomer, renewal_days: b.renewalDays,
      };
      const set = Object.fromEntries(Object.entries(values).filter(([, v]) => v !== undefined));
      await tx.insertInto('hd_settings').values({ company_id: ctx.companyId, tenant_id: ctx.tenantId, ...set } as never)
        .onConflict((oc) => oc.column('company_id').doUpdateSet({ ...set, updated_at: new Date() } as never)).execute();
      for (const [p, v] of Object.entries(b.sla ?? {})) {
        if (!v) continue;
        await tx.insertInto('hd_sla').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, priority: p, first_response_hours: v.firstResponseHours, resolution_hours: v.resolutionHours,
        }).onConflict((oc) => oc.columns(['company_id', 'priority']).doUpdateSet({
          first_response_hours: v.firstResponseHours, resolution_hours: v.resolutionHours,
        })).execute();
      }
      const after = await loadHdSettings(tx, ctx.companyId);
      await writeAudit(tx, auditOf(ctx), 'helpdesk_settings', ctx.companyId, 'update', before, after);
      return after;
    });
  };
  app.put('/helpdesk/settings', saveSettings);
  app.patch('/helpdesk/settings', saveSettings);

  app.get('/helpdesk/tickets', async (req) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.view', 'helpdesk.manage');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = ticketQuery(tx).where('t.company_id', '=', ctx.companyId);
      if (q.status) base = base.where('t.status', '=', q.status);
      if (q.priority) base = base.where('t.priority', '=', q.priority);
      if (q.assigneeId) base = base.where('t.assignee_id', '=', q.assigneeId);
      if (q.mine === 'true') base = base.where('t.assignee_id', '=', ctx.userId);
      if (q.partyId) base = base.where('t.party_id', '=', q.partyId);
      if (q.category) base = base.where('t.category', '=', q.category);
      if (q.channel) base = base.where('t.channel', '=', q.channel);
      if (q.open === 'true') base = base.where('t.status', 'not in', ['resolved', 'closed']);
      if (q.open === 'false') base = base.where('t.status', 'in', ['resolved', 'closed']);
      if (q.breached === 'true') {
        base = base.where(sql<boolean>`((t.first_response_at is null and t.first_response_due < now())
          or t.first_response_at > t.first_response_due
          or (coalesce(t.resolved_at, t.closed_at) is null and t.resolution_due < now())
          or coalesce(t.resolved_at, t.closed_at) > t.resolution_due)`);
      }
      if (q.q) {
        const like = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('t.number', 'ilike', like), eb('t.subject', 'ilike', like), eb('p.name', 'ilike', like), eb('t.serial_no', 'ilike', like)]));
      }
      const total = await base.clearSelect().select(sql<number>`count(*)::int`.as('n')).executeTakeFirstOrThrow();
      const rows = await base.clearSelect().selectAll('t')
        .select(['p.name as party_name', 'i.name as item_name', 'inv.number as invoice_number', 'c.number as contract_number',
          'c.status as contract_status', 'c.end_date as contract_end', 'a.name as assignee_name', 'cb.name as created_by_name'])
        .orderBy(sql`(t.status in ('resolved','closed'))`).orderBy('t.resolution_due').orderBy('t.number')
        .limit(q.limit).offset(q.offset).execute();
      const now = new Date();
      const hs = await loadHdSettings(tx, ctx.companyId);
      return { data: rows.map((r) => ticketJson(r, now, hs)), total: total.n };
    });
  });

  app.post('/helpdesk/tickets', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.manage');
    const b = parse(createBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const party = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw badRequest('Customer not found.', { partyId: 'Not found' });
      if (party.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });
      if (b.assigneeId) await requireStaff(tx, ctx, b.assigneeId);
      if (b.itemId) {
        const it = await tx.selectFrom('items').select('id').where('id', '=', b.itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!it) throw badRequest('Item not found.', { itemId: 'Not found' });
      }
      if (b.invoiceId) {
        const inv = await tx.selectFrom('invoices').select('id').where('id', '=', b.invoiceId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!inv) throw badRequest('Invoice not found.', { invoiceId: 'Not found' });
      }
      let contractId = b.contractId ?? null;
      if (contractId) {
        const c = await tx.selectFrom('service_contracts').select('id').where('id', '=', contractId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!c) throw badRequest('Contract not found.', { contractId: 'Not found' });
      } else if (b.serialNo || b.itemId) {
        const found = await coveringContracts(tx, ctx.companyId, { partyId: b.partyId, serialNo: b.serialNo, itemId: b.itemId, on: todayIst() });
        contractId = found[0]?.id ?? null;
      }
      const s = await loadHdSettings(tx, ctx.companyId);
      const now = new Date();
      const due = dueTimes(s, b.priority, now);
      const number = await nextNumber(tx, ctx, 'ticket', financialYear(todayIst()));
      const row = await tx.insertInto('hd_tickets').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, party_id: b.partyId, contact_name: b.contactName ?? null,
        contact_phone: b.contactPhone ?? null, subject: b.subject, description: b.description ?? null, channel: b.channel,
        category: b.category ?? null, priority: b.priority, item_id: b.itemId ?? null, serial_no: b.serialNo ?? null,
        invoice_id: b.invoiceId ?? null, contract_id: contractId, assignee_id: b.assigneeId ?? null,
        first_response_due: due.firstResponseDue, resolution_due: due.resolutionDue, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('hd_status_history').values({ tenant_id: ctx.tenantId, ticket_id: row.id, status: 'new', changed_by: ctx.userId }).execute();
      if (contractId) {
        await tx.insertInto('service_contract_links').values({ tenant_id: ctx.tenantId, contract_id: contractId, ref_type: 'ticket', ref_id: row.id })
          .onConflict((oc) => oc.doNothing()).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'ticket', row.id, 'create', null, { number, partyId: b.partyId, priority: b.priority });
      await tellCustomer(tx, ctx, row.id, 'has been logged', 'We have received your request and will respond soon.');
      return detail(tx, ctx, row.id);
    });
    return reply.code(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/helpdesk/tickets/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.view', 'helpdesk.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => detail(tx, ctx, id));
  });

  app.patch<{ Params: { id: string } }>('/helpdesk/tickets/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const t = await loadTicket(tx, ctx, id, true);
      assertFresh(t.updated_at, b.expectedUpdatedAt, 'ticket');
      if (b.assigneeId) await requireStaff(tx, ctx, b.assigneeId);
      const set: Record<string, unknown> = {};
      const map: Record<string, string> = {
        subject: 'subject', description: 'description', category: 'category', assigneeId: 'assignee_id', itemId: 'item_id',
        serialNo: 'serial_no', invoiceId: 'invoice_id', contractId: 'contract_id', contactName: 'contact_name', contactPhone: 'contact_phone',
      };
      for (const [k, col] of Object.entries(map)) if ((b as Record<string, unknown>)[k] !== undefined) set[col] = (b as Record<string, unknown>)[k];
      if (b.priority && b.priority !== t.priority) {
        const s = await loadHdSettings(tx, ctx.companyId);
        const due = dueTimes(s, b.priority, t.created_at, Number(t.paused_ms));
        set.priority = b.priority; set.first_response_due = due.firstResponseDue; set.resolution_due = due.resolutionDue;
      }
      if (typeof set.contract_id === 'string') {
        const c = await tx.selectFrom('service_contracts').select('id').where('id', '=', set.contract_id).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!c) throw badRequest('Contract not found.', { contractId: 'Not found' });
        await tx.insertInto('service_contract_links').values({ tenant_id: ctx.tenantId, contract_id: set.contract_id, ref_type: 'ticket', ref_id: id })
          .onConflict((oc) => oc.doNothing()).execute();
      }
      if (Object.keys(set).length) await tx.updateTable('hd_tickets').set(set as never).where('id', '=', id).execute();
      if (b.assigneeId !== undefined && b.assigneeId !== t.assignee_id) {
        await addMessage(tx, ctx, id, 'system', b.assigneeId ? 'Ticket assigned.' : 'Ticket unassigned.');
      }
      await writeAudit(tx, auditOf(ctx), 'ticket', id, 'update', null, set);
      return detail(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/helpdesk/tickets/:id/messages', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(messageBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const t = await loadTicket(tx, ctx, id, true);
      if (t.status === 'closed') throw conflict('This ticket is closed. Reopen it first.', 'CLOSED');
      await requireFiles(tx, b.fileIds.map((f) => ({ id: f, field: 'fileIds' })), false);
      await addMessage(tx, ctx, id, b.kind, b.body, b.fileIds);
      const set: Record<string, unknown> = {};
      if (b.kind === 'reply') {
        if (!t.first_response_at) set.first_response_at = new Date();
        if (t.status === 'new') await applyStatus(tx, ctx, t, 'open', set);
      }
      if (b.kind === 'customer' && t.status === 'waiting') await applyStatus(tx, ctx, t, 'open', set);
      if (Object.keys(set).length) await tx.updateTable('hd_tickets').set(set as never).where('id', '=', id).execute();
      else await tx.updateTable('hd_tickets').set({ updated_at: new Date() }).where('id', '=', id).execute();
      if (b.kind === 'reply') await tellCustomer(tx, ctx, id, 'has a new reply', b.body);
      return detail(tx, ctx, id);
    });
    return reply.code(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/helpdesk/tickets/:id/status', async (req) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.manage');
    const id = parse(z.uuid(), req.params.id);
    const { status } = parse(statusBody, req.body);
    return ctx.tx(async (tx) => {
      const t = await loadTicket(tx, ctx, id, true);
      const from = t.status as Status;
      if (!NEXT[from].includes(status)) {
        throw conflict(`A ticket that is ${from} cannot move to ${status}.`, 'BAD_TRANSITION', { from, to: status, allowed: NEXT[from] });
      }
      const set: Record<string, unknown> = {};
      await applyStatus(tx, ctx, t, status, set);
      if (status === 'resolved') set.resolved_at = new Date();
      if (status === 'closed') set.closed_at = new Date();
      if (status === 'open') { set.closed_at = null; set.resolved_at = null; }
      await tx.updateTable('hd_tickets').set(set as never).where('id', '=', id).execute();
      await addMessage(tx, ctx, id, 'system', `Status changed from ${from} to ${status}.`);
      await writeAudit(tx, auditOf(ctx), 'ticket', id, 'status', { status: from }, { status });
      if (status === 'resolved') await tellCustomer(tx, ctx, id, 'has been resolved');
      return detail(tx, ctx, id);
    });
  });

  app.post('/helpdesk/run', async (req) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.manage');
    return ctx.tx((tx) => runHelpdeskDaily(tx, ctx, todayIst()));
  });

  app.get('/helpdesk/reports/summary', async (req) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.view');
    const q = parse(rangeQuery, req.query);
    const to = q.to ?? todayIst();
    const from = q.from ?? new Date(Date.parse(to) - 29 * 86_400_000).toISOString().slice(0, 10);
    return ctx.tx(async (tx) => {
      const rows = await ticketQuery(tx).where('t.company_id', '=', ctx.companyId)
        .where(sql<boolean>`(t.created_at at time zone 'Asia/Kolkata')::date between ${from}::date and ${to}::date`).execute();
      const now = new Date();
      const hrs = (a: Date, b: Date) => (a.getTime() - b.getTime()) / 3_600_000;
      const avg = (xs: number[]) => (xs.length ? Math.round((xs.reduce((s, x) => s + x, 0) / xs.length) * 100) / 100 : null);
      const buckets = [['0-1d', 0, 1], ['2-3d', 2, 3], ['4-7d', 4, 7], ['8-14d', 8, 14], ['15d+', 15, 1e9]] as const;
      const open = rows.filter((r) => r.status !== 'resolved' && r.status !== 'closed');
      const openByAge = buckets.map(([bucket, lo, hi]) => ({
        bucket, count: open.filter((r) => { const d = Math.floor(hrs(now, r.created_at) / 24); return d >= lo && d <= hi; }).length,
      }));
      const hdSettings = await loadHdSettings(tx, ctx.companyId);
      const breachList: { id: string; number: string; subject: string; partyName: string; kind: string; dueAt: Date }[] = [];
      let response = 0; let resolution = 0;
      for (const r of rows) {
        const j = ticketJson(r, now, hdSettings);
        const base = { id: r.id, number: r.number, subject: r.subject, partyName: r.party_name };
        if (j.response.state === 'breached') { response += 1; breachList.push({ ...base, kind: 'response', dueAt: r.first_response_due }); }
        if (j.resolution.state === 'breached') { resolution += 1; breachList.push({ ...base, kind: 'resolution', dueAt: r.resolution_due }); }
      }
      const resTimes = rows.filter((r) => r.resolved_at ?? r.closed_at).map((r) => hrs((r.resolved_at ?? r.closed_at)!, r.created_at));
      const respTimes = rows.filter((r) => r.first_response_at).map((r) => hrs(r.first_response_at!, r.created_at));
      const group = <K extends string>(key: (r: TicketRow) => K) => {
        const m = new Map<K, TicketRow[]>();
        for (const r of rows) m.set(key(r), [...(m.get(key(r)) ?? []), r]);
        return m;
      };
      const byCategory = [...group((r) => r.category ?? 'Uncategorised')].map(([category, rs]) => ({
        category, total: rs.length, open: rs.filter((r) => r.status !== 'resolved' && r.status !== 'closed').length,
        breached: rs.filter((r) => ticketJson(r, now, hdSettings).resolution.state === 'breached' || ticketJson(r, now, hdSettings).response.state === 'breached').length,
      })).sort((a, b) => b.total - a.total);
      const byAgent = [...group((r) => (r.assignee_id ?? '') as string)].map(([assigneeId, rs]) => ({
        assigneeId: assigneeId || null, name: rs[0]!.assignee_name ?? 'Unassigned', total: rs.length,
        open: rs.filter((r) => r.status !== 'resolved' && r.status !== 'closed').length,
        resolved: rs.filter((r) => r.resolved_at ?? r.closed_at).length,
        avgResolutionHours: avg(rs.filter((r) => r.resolved_at ?? r.closed_at).map((r) => hrs((r.resolved_at ?? r.closed_at)!, r.created_at))),
      })).sort((a, b) => b.total - a.total);
      return {
        from, to, openByAge, breaches: { response, resolution, tickets: breachList },
        avgFirstResponseHours: avg(respTimes), avgResolutionHours: avg(resTimes), byCategory, byAgent,
      };
    });
  });

  // Staff to pick from
  app.get('/helpdesk/staff', async (req) => {
    const ctx = req.ctx;
    ctx.require('helpdesk.view', 'helpdesk.manage', 'service_contracts.view', 'service_contracts.manage', 'timesheets.log', 'timesheets.view');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id').select(['u.id', 'u.name']).distinct()
        .where('ur.company_id', '=', ctx.companyId).where('u.is_active', '=', true).orderBy('u.name').execute();
      return { data: rows };
    });
  });
}
