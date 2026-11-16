import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { moneyField } from '../lib/numbers.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import { defaultLocation, round2 } from './services-common.ts';

/*
 * Timesheets. Hours are saved per user, day and customer. The rate is resolved and saved on the entry when it
 * is written, so a later change of rates does not move amounts already logged. Billing makes one invoice per
 * customer through createInvoice and marks the entries.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const quarter = z.coerce.number().min(0).max(24).refine((v) => Math.abs(v * 4 - Math.round(v * 4)) < 1e-9, 'Use steps of 15 minutes (0.25 hours)');
const task = z.string().trim().min(1, 'Describe the work').max(300);
const entryBody = z.object({
  workDate: dateField, partyId: z.uuid(), hours: quarter.refine((v) => v > 0, 'Must be more than zero'), task,
  billable: z.boolean().default(true), projectId: z.uuid().optional(), matterId: z.uuid().optional(), ticketId: z.uuid().optional(),
  userId: z.uuid().optional(),
});
const entryPatch = z.object({
  workDate: dateField.optional(), partyId: z.uuid().optional(), hours: quarter.refine((v) => v > 0).optional(), task: task.optional(),
  billable: z.boolean().optional(), projectId: z.uuid().nullable().optional(), matterId: z.uuid().nullable().optional(),
  ticketId: z.uuid().nullable().optional(),
});
const weekBody = z.object({
  weekStart: dateField,
  rows: z.array(z.object({
    partyId: z.uuid(), projectId: z.uuid().optional(), matterId: z.uuid().optional(), ticketId: z.uuid().optional(), task,
    billable: z.boolean().default(true), hours: z.array(quarter).length(7),
  })).max(60),
});
const listQuery = z.object({
  userId: z.uuid().optional(), from: dateField.optional(), to: dateField.optional(), partyId: z.uuid().optional(),
  status: z.enum(['draft', 'submitted', 'approved', 'rejected']).optional(), billed: z.enum(['true', 'false']).optional(),
  limit: z.coerce.number().int().min(1).max(500).default(100), offset: z.coerce.number().int().min(0).default(0),
});
const settingsBody = z.object({
  serviceItemId: z.uuid().nullable().optional(), approvalRequired: z.boolean().optional(),
  dailyTargetHours: z.coerce.number().positive().max(24).optional(),
});

// Helpers -----------------------------------------------------------------------------------------

export async function loadTsSettings(tx: Tx, companyId: string) {
  const s = await tx.selectFrom('ts_settings').selectAll().where('company_id', '=', companyId).executeTakeFirst();
  return { serviceItemId: s?.service_item_id ?? null, approvalRequired: s?.approval_required ?? true, dailyTargetHours: Number(s?.daily_target_hours ?? 8) };
}

/** User and customer pair, else the customer alone, else the user's default, else 0. */
export async function resolveRate(tx: Tx, companyId: string, userId: string, partyId: string): Promise<number> {
  const rows = await tx.selectFrom('ts_rates').select(['user_id', 'party_id', 'rate']).where('company_id', '=', companyId)
    .where((eb) => eb.or([eb('user_id', '=', userId), eb('user_id', 'is', null)]))
    .where((eb) => eb.or([eb('party_id', '=', partyId), eb('party_id', 'is', null)])).execute();
  const pick = (u: boolean, p: boolean) => rows.find((r) => (u ? r.user_id === userId : r.user_id === null) && (p ? r.party_id === partyId : r.party_id === null));
  const r = pick(true, true) ?? pick(false, true) ?? pick(true, false);
  return r ? Number(r.rate) : 0;
}

const isMonday = (d: string) => new Date(`${d}T00:00:00Z`).getUTCDay() === 1;
const weekDays = (start: string) => Array.from({ length: 7 }, (_, i) => addDays(start, i));

function entryQuery(tx: Tx) {
  return tx.selectFrom('ts_entries as e').innerJoin('users as u', 'u.id', 'e.user_id').innerJoin('parties as p', 'p.id', 'e.party_id')
    .leftJoin('projects as pr', 'pr.id', 'e.project_id').leftJoin('hd_tickets as t', 't.id', 'e.ticket_id')
    .selectAll('e').select(['u.name as user_name', 'p.name as party_name', 'pr.name as project_name', 't.number as ticket_number']);
}
type EntryRow = Awaited<ReturnType<ReturnType<typeof entryQuery>['executeTakeFirstOrThrow']>>;
function entryJson(e: EntryRow) {
  const hours = Number(e.hours); const rate = Number(e.rate);
  return {
    id: e.id, userId: e.user_id, userName: e.user_name, workDate: e.work_date, partyId: e.party_id, partyName: e.party_name,
    projectId: e.project_id, projectName: e.project_name, matterId: e.matter_id, ticketId: e.ticket_id, ticketNumber: e.ticket_number,
    task: e.task, hours, billable: e.billable, rate, amount: e.billable ? round2(hours * rate) : 0, status: e.status,
    rejectReason: e.reject_reason, submittedAt: e.submitted_at, approvedBy: e.approved_by, approvedAt: e.approved_at,
    invoiceId: e.invoice_id, billedAt: e.billed_at,
  };
}

async function checkRefs(tx: Tx, ctx: RequestContext, b: { partyId: string; projectId?: string | null; matterId?: string | null; ticketId?: string | null }) {
  const p = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!p) throw badRequest('Customer not found.', { partyId: 'Not found' });
  if (p.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });
  const chk = async (table: 'projects' | 'legal_matters' | 'hd_tickets', id: string | null | undefined, field: string) => {
    if (!id) return;
    const r = await tx.selectFrom(table).select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!r) throw badRequest('Not found.', { [field]: 'Not found' });
  };
  await chk('projects', b.projectId, 'projectId');
  await chk('legal_matters', b.matterId, 'matterId');
  await chk('hd_tickets', b.ticketId, 'ticketId');
}

/** A person's day total, in hours, for the days given (optionally leaving some entries out). */
async function dayTotals(tx: Tx, companyId: string, userId: string, dates: string[], exceptIds: string[] = []) {
  let q = tx.selectFrom('ts_entries').select(['work_date', sql<number>`sum(hours)::float8`.as('h')]).where('company_id', '=', companyId)
    .where('user_id', '=', userId).where('work_date', 'in', dates).where('status', '!=', 'rejected');
  if (exceptIds.length) q = q.where('id', 'not in', exceptIds);
  const rows = await q.groupBy('work_date').execute();
  return new Map(rows.map((r) => [String(r.work_date), r.h]));
}

const isOwner = (ctx: RequestContext) => ctx.company.roles.some((r) => r.name === 'Owner');
const seesAll = (ctx: RequestContext) => ctx.can('timesheets.view');

async function weekJson(tx: Tx, ctx: RequestContext, userId: string, weekStart: string) {
  const days = weekDays(weekStart);
  const rows = await entryQuery(tx).where('e.company_id', '=', ctx.companyId).where('e.user_id', '=', userId)
    .where('e.work_date', '>=', weekStart).where('e.work_date', '<=', days[6]!).orderBy('p.name').orderBy('e.task').execute();
  const groups = new Map<string, { head: EntryRow; cells: { id: string | null; date: string; hours: number; status: string | null }[] }>();
  for (const e of rows) {
    const key = [e.party_id, e.project_id, e.matter_id, e.ticket_id, e.task, e.billable].join('|');
    const g = groups.get(key) ?? { head: e, cells: days.map((d) => ({ id: null, date: d, hours: 0, status: null })) };
    const cell = g.cells[daysBetween(weekStart, String(e.work_date))]!;
    cell.id ??= e.id; cell.hours = Number(cell.hours) + Number(e.hours); cell.status = e.status;
    groups.set(key, g);
  }
  const out = [...groups.values()].map(({ head, cells }) => ({
    partyId: head.party_id, partyName: head.party_name, projectId: head.project_id, matterId: head.matter_id, ticketId: head.ticket_id,
    task: head.task, billable: head.billable, entries: cells, total: cells.reduce((s, c) => s + c.hours, 0),
  }));
  const dayTotal = days.map((_, i) => out.reduce((s, r) => s + r.entries[i]!.hours, 0));
  const states = new Set(rows.map((e) => e.status));
  const status = states.size === 0 ? 'draft' : states.size === 1 ? [...states][0]! : 'mixed';
  return { weekStart, days, rows: out, dayTotals: dayTotal, total: dayTotal.reduce((s, x) => s + x, 0), status };
}

// Routes ------------------------------------------------------------------------------------------

export async function timesheetRoutes(app: FastifyInstance): Promise<void> {
  const own = (ctx: RequestContext) => ctx.require('timesheets.log', 'timesheets.view', 'timesheets.approve', 'timesheets.bill');

  app.get('/timesheets/staff', async (req) => {
    const ctx = req.ctx; own(ctx);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id').select(['u.id', 'u.name']).distinct()
        .where('ur.company_id', '=', ctx.companyId).where('u.is_active', '=', true).orderBy('u.name').execute();
      return { data: rows };
    });
  });

  app.get('/timesheets/entries', async (req) => {
    const ctx = req.ctx; own(ctx);
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      const userId = seesAll(ctx) ? q.userId : ctx.userId;
      let base = entryQuery(tx).where('e.company_id', '=', ctx.companyId);
      let cnt = tx.selectFrom('ts_entries as e').select(sql<number>`count(*)::int`.as('n')).where('e.company_id', '=', ctx.companyId);
      if (userId) { base = base.where('e.user_id', '=', userId); cnt = cnt.where('e.user_id', '=', userId); }
      if (q.from) { base = base.where('e.work_date', '>=', q.from); cnt = cnt.where('e.work_date', '>=', q.from); }
      if (q.to) { base = base.where('e.work_date', '<=', q.to); cnt = cnt.where('e.work_date', '<=', q.to); }
      if (q.partyId) { base = base.where('e.party_id', '=', q.partyId); cnt = cnt.where('e.party_id', '=', q.partyId); }
      if (q.status) { base = base.where('e.status', '=', q.status); cnt = cnt.where('e.status', '=', q.status); }
      if (q.billed === 'true') { base = base.where('e.invoice_id', 'is not', null); cnt = cnt.where('e.invoice_id', 'is not', null); }
      if (q.billed === 'false') { base = base.where('e.invoice_id', 'is', null); cnt = cnt.where('e.invoice_id', 'is', null); }
      const total = await cnt.executeTakeFirstOrThrow();
      const rows = await base.orderBy('e.work_date', 'desc').orderBy('e.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(entryJson), total: total.n };
    });
  });

  app.post('/timesheets/entries', async (req, reply) => {
    const ctx = req.ctx; ctx.require('timesheets.log');
    const b = parse(entryBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const userId = b.userId ?? ctx.userId;
      if (userId !== ctx.userId && !(ctx.can('timesheets.view') && ctx.can('timesheets.approve'))) throw forbidden();
      if (b.workDate > addDays(todayIst(), 1)) throw badRequest('Hours cannot be logged for a future date.', { workDate: 'Not in the future' });
      await checkRefs(tx, ctx, b);
      const totals = await dayTotals(tx, ctx.companyId, userId, [b.workDate]);
      if ((totals.get(b.workDate) ?? 0) + b.hours > 24) throw badRequest('That makes more than 24 hours for the day.', { hours: 'Over 24 hours in a day' });
      const rate = await resolveRate(tx, ctx.companyId, userId, b.partyId);
      const row = await tx.insertInto('ts_entries').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, user_id: userId, work_date: b.workDate, party_id: b.partyId,
        project_id: b.projectId ?? null, matter_id: b.matterId ?? null, ticket_id: b.ticketId ?? null, task: b.task, hours: b.hours,
        billable: b.billable, rate,
      }).returning('id').executeTakeFirstOrThrow();
      return entryJson(await entryQuery(tx).where('e.id', '=', row.id).executeTakeFirstOrThrow());
    });
    return reply.code(201).send(out);
  });

  const editable = async (tx: Tx, ctx: RequestContext, id: string) => {
    const e = await tx.selectFrom('ts_entries').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
    if (!e || (e.user_id !== ctx.userId && !seesAll(ctx))) throw notFound('Entry');
    if (e.user_id !== ctx.userId) throw forbidden();
    if (e.status !== 'draft' && e.status !== 'rejected') throw conflict('Submitted hours cannot be changed.', 'LOCKED');
    return e;
  };

  app.patch<{ Params: { id: string } }>('/timesheets/entries/:id', async (req) => {
    const ctx = req.ctx; ctx.require('timesheets.log');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(entryPatch, req.body);
    return ctx.tx(async (tx) => {
      const e = await editable(tx, ctx, id);
      const partyId = b.partyId ?? e.party_id;
      await checkRefs(tx, ctx, { partyId, projectId: b.projectId, matterId: b.matterId, ticketId: b.ticketId });
      const date = b.workDate ?? String(e.work_date);
      const hours = b.hours ?? Number(e.hours);
      const totals = await dayTotals(tx, ctx.companyId, e.user_id, [date], [id]);
      if ((totals.get(date) ?? 0) + hours > 24) throw badRequest('That makes more than 24 hours for the day.', { hours: 'Over 24 hours in a day' });
      const set: Record<string, unknown> = { status: 'draft', reject_reason: null };
      if (b.workDate) set.work_date = b.workDate;
      if (b.partyId) set.party_id = b.partyId;
      if (b.hours) set.hours = b.hours;
      if (b.task) set.task = b.task;
      if (b.billable !== undefined) set.billable = b.billable;
      for (const [k, c] of [['projectId', 'project_id'], ['matterId', 'matter_id'], ['ticketId', 'ticket_id']] as const) {
        if (b[k] !== undefined) set[c] = b[k];
      }
      set.rate = await resolveRate(tx, ctx.companyId, e.user_id, partyId);
      await tx.updateTable('ts_entries').set(set as never).where('id', '=', id).execute();
      return entryJson(await entryQuery(tx).where('e.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.delete<{ Params: { id: string } }>('/timesheets/entries/:id', async (req, reply) => {
    const ctx = req.ctx; ctx.require('timesheets.log');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => { await editable(tx, ctx, id); await tx.deleteFrom('ts_entries').where('id', '=', id).execute(); });
    return reply.code(204).send();
  });

  app.get('/timesheets/week', async (req) => {
    const ctx = req.ctx; own(ctx);
    const q = parse(z.object({ weekStart: dateField, userId: z.uuid().optional() }), req.query);
    if (!isMonday(q.weekStart)) throw badRequest('A week starts on a Monday.', { weekStart: 'Use a Monday' });
    const userId = q.userId && seesAll(ctx) ? q.userId : ctx.userId;
    return ctx.tx((tx) => weekJson(tx, ctx, userId, q.weekStart));
  });

  const saveWeek = async (req: { ctx: RequestContext; body: unknown }) => {
    const ctx = req.ctx; ctx.require('timesheets.log');
    const b = parse(weekBody, req.body);
    if (!isMonday(b.weekStart)) throw badRequest('A week starts on a Monday.', { weekStart: 'Use a Monday' });
    return ctx.tx(async (tx) => {
      const days = weekDays(b.weekStart);
      const today = addDays(todayIst(), 1);
      await tx.deleteFrom('ts_entries').where('company_id', '=', ctx.companyId).where('user_id', '=', ctx.userId)
        .where('work_date', 'in', days).where('status', 'in', ['draft', 'rejected']).execute();
      const locked = await dayTotals(tx, ctx.companyId, ctx.userId, days);
      const add = days.map(() => 0);
      const rates = new Map<string, number>();
      for (const row of b.rows) {
        await checkRefs(tx, ctx, row);
        if (!rates.has(row.partyId)) rates.set(row.partyId, await resolveRate(tx, ctx.companyId, ctx.userId, row.partyId));
        const values = row.hours.flatMap((h, i) => {
          if (h <= 0) return [];
          if (days[i]! > today) throw badRequest('Hours cannot be logged for a future date.', { hours: 'Not in the future' });
          add[i] = add[i]! + h;
          if ((locked.get(days[i]!) ?? 0) + add[i]! > 24) throw badRequest('That makes more than 24 hours for a day.', { hours: 'Over 24 hours in a day' });
          return [{
            tenant_id: ctx.tenantId, company_id: ctx.companyId, user_id: ctx.userId, work_date: days[i]!, party_id: row.partyId,
            project_id: row.projectId ?? null, matter_id: row.matterId ?? null, ticket_id: row.ticketId ?? null, task: row.task,
            hours: h, billable: row.billable, rate: rates.get(row.partyId)!,
          }];
        });
        if (values.length) await tx.insertInto('ts_entries').values(values).execute();
      }
      return weekJson(tx, ctx, ctx.userId, b.weekStart);
    });
  };
  app.put('/timesheets/week', saveWeek);
  app.patch('/timesheets/week', saveWeek);

  app.post('/timesheets/submit', async (req) => {
    const ctx = req.ctx; ctx.require('timesheets.log');
    const b = parse(z.object({ weekStart: dateField.optional(), ids: z.array(z.uuid()).max(500).optional() })
      .refine((v) => v.weekStart || v.ids?.length, 'Give a week or entries'), req.body);
    return ctx.tx(async (tx) => {
      const settings = await loadTsSettings(tx, ctx.companyId);
      let q = tx.selectFrom('ts_entries').select('id').where('company_id', '=', ctx.companyId).where('user_id', '=', ctx.userId)
        .where('status', 'in', ['draft', 'rejected']).forUpdate();
      if (b.ids?.length) q = q.where('id', 'in', b.ids);
      else {
        if (!isMonday(b.weekStart!)) throw badRequest('A week starts on a Monday.', { weekStart: 'Use a Monday' });
        q = q.where('work_date', '>=', b.weekStart!).where('work_date', '<=', addDays(b.weekStart!, 6));
      }
      const ids = (await q.execute()).map((r) => r.id);
      if (!ids.length) throw conflict('There are no hours to submit.', 'NOTHING_TO_SUBMIT');
      const now = new Date();
      await tx.updateTable('ts_entries').set(settings.approvalRequired
        ? { status: 'submitted', submitted_at: now, reject_reason: null }
        : { status: 'approved', submitted_at: now, approved_at: now, approved_by: ctx.userId, reject_reason: null } as never)
        .where('id', 'in', ids).execute();
      return { submitted: ids.length, status: settings.approvalRequired ? 'submitted' : 'approved' };
    });
  });

  app.post('/timesheets/approve', async (req) => {
    const ctx = req.ctx; ctx.require('timesheets.approve');
    const b = parse(z.object({ ids: z.array(z.uuid()).min(1).max(500) }), req.body);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('ts_entries').select(['id', 'user_id']).where('company_id', '=', ctx.companyId)
        .where('id', 'in', b.ids).where('status', '=', 'submitted').forUpdate().execute();
      if (!rows.length) throw conflict('Nothing submitted to approve.', 'NOTHING_TO_APPROVE');
      if (rows.some((r) => r.user_id === ctx.userId) && !isOwner(ctx)) throw forbidden('You cannot approve your own hours.');
      await tx.updateTable('ts_entries').set({ status: 'approved', approved_by: ctx.userId, approved_at: new Date() })
        .where('id', 'in', rows.map((r) => r.id)).execute();
      await writeAudit(tx, auditOf(ctx), 'timesheet', null, 'approve', null, { count: rows.length });
      return { approved: rows.length };
    });
  });

  app.post('/timesheets/reject', async (req) => {
    const ctx = req.ctx; ctx.require('timesheets.approve');
    const b = parse(z.object({ ids: z.array(z.uuid()).min(1).max(500), reason: z.string().trim().min(1, 'Give a reason').max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('ts_entries').select('id').where('company_id', '=', ctx.companyId)
        .where('id', 'in', b.ids).where('status', '=', 'submitted').forUpdate().execute();
      if (!rows.length) throw conflict('Nothing submitted to reject.', 'NOTHING_TO_APPROVE');
      await tx.updateTable('ts_entries').set({ status: 'rejected', reject_reason: b.reason }).where('id', 'in', rows.map((r) => r.id)).execute();
      return { rejected: rows.length };
    });
  });

  // Rates and settings
  app.get('/timesheets/rates', async (req) => {
    const ctx = req.ctx; ctx.require('timesheets.bill', 'timesheets.view');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('ts_rates as r').leftJoin('users as u', 'u.id', 'r.user_id').leftJoin('parties as p', 'p.id', 'r.party_id')
        .select(['r.id', 'r.user_id', 'u.name as user_name', 'r.party_id', 'p.name as party_name', 'r.rate']).where('r.company_id', '=', ctx.companyId)
        .orderBy('u.name').orderBy('p.name').execute();
      return { data: rows.map((r) => ({ id: r.id, userId: r.user_id, userName: r.user_name, partyId: r.party_id, partyName: r.party_name, rate: Number(r.rate) })) };
    });
  });

  app.post('/timesheets/rates', async (req, reply) => {
    const ctx = req.ctx; ctx.require('timesheets.bill');
    const b = parse(z.object({ userId: z.uuid().optional(), partyId: z.uuid().optional(), rate: moneyField })
      .refine((v) => v.userId || v.partyId, 'Choose a person, a customer or both'), req.body);
    const out = await ctx.tx(async (tx) => {
      let q = tx.selectFrom('ts_rates').select('id').where('company_id', '=', ctx.companyId);
      q = b.userId ? q.where('user_id', '=', b.userId) : q.where('user_id', 'is', null);
      q = b.partyId ? q.where('party_id', '=', b.partyId) : q.where('party_id', 'is', null);
      const have = await q.executeTakeFirst();
      let id: string;
      if (have) { await tx.updateTable('ts_rates').set({ rate: b.rate }).where('id', '=', have.id).execute(); id = have.id; }
      else {
        id = (await tx.insertInto('ts_rates').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, user_id: b.userId ?? null,
          party_id: b.partyId ?? null, rate: b.rate }).returning('id').executeTakeFirstOrThrow()).id;
      }
      return { id, userId: b.userId ?? null, partyId: b.partyId ?? null, rate: b.rate };
    });
    return reply.code(201).send(out);
  });

  app.delete<{ Params: { id: string } }>('/timesheets/rates/:id', async (req, reply) => {
    const ctx = req.ctx; ctx.require('timesheets.bill');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx((tx) => tx.deleteFrom('ts_rates').where('id', '=', id).where('company_id', '=', ctx.companyId).execute());
    return reply.code(204).send();
  });

  app.get('/timesheets/settings', async (req) => {
    const ctx = req.ctx; own(ctx);
    return ctx.tx((tx) => loadTsSettings(tx, ctx.companyId));
  });
  const saveSettings = async (req: { ctx: RequestContext; body: unknown }) => {
    const ctx = req.ctx; ctx.require('timesheets.bill');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      if (b.serviceItemId) {
        const it = await tx.selectFrom('items').select('id').where('id', '=', b.serviceItemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!it) throw badRequest('Item not found.', { serviceItemId: 'Not found' });
      }
      const values = { service_item_id: b.serviceItemId, approval_required: b.approvalRequired, daily_target_hours: b.dailyTargetHours };
      const set = Object.fromEntries(Object.entries(values).filter(([, v]) => v !== undefined));
      await tx.insertInto('ts_settings').values({ company_id: ctx.companyId, tenant_id: ctx.tenantId, ...set } as never)
        .onConflict((oc) => oc.column('company_id').doUpdateSet({ ...set, updated_at: new Date() } as never)).execute();
      return loadTsSettings(tx, ctx.companyId);
    });
  };
  app.put('/timesheets/settings', saveSettings);
  app.patch('/timesheets/settings', saveSettings);

  // Billing
  const unbilledRows = (tx: Tx, companyId: string) => tx.selectFrom('ts_entries as e').innerJoin('parties as p', 'p.id', 'e.party_id')
    .select(['e.id', 'e.party_id', 'p.name as party_name', 'e.task', 'e.hours', 'e.rate'])
    .where('e.company_id', '=', companyId).where('e.status', '=', 'approved').where('e.billable', '=', true).where('e.invoice_id', 'is', null);

  app.get('/timesheets/unbilled', async (req) => {
    const ctx = req.ctx; ctx.require('timesheets.bill');
    const q = parse(z.object({ partyId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = unbilledRows(tx, ctx.companyId);
      if (q.partyId) base = base.where('e.party_id', '=', q.partyId);
      const rows = await base.orderBy('p.name').execute();
      const m = new Map<string, { partyId: string; partyName: string; hours: number; amount: number; entries: number }>();
      for (const r of rows) {
        const g = m.get(r.party_id) ?? { partyId: r.party_id, partyName: r.party_name, hours: 0, amount: 0, entries: 0 };
        g.hours += Number(r.hours); g.amount = round2(g.amount + Number(r.hours) * Number(r.rate)); g.entries += 1;
        m.set(r.party_id, g);
      }
      return { data: [...m.values()] };
    });
  });

  app.post('/timesheets/bill', async (req) => {
    const ctx = req.ctx; ctx.require('timesheets.bill', 'invoices.create');
    if (!ctx.can('timesheets.bill') || !ctx.can('invoices.create')) throw forbidden();
    const b = parse(z.object({
      partyIds: z.array(z.uuid()).max(200).optional(), entryIds: z.array(z.uuid()).max(2000).optional(),
      invoiceDate: dateField.optional(), locationId: z.uuid().optional(),
    }), req.body);
    return ctx.tx(async (tx) => {
      const settings = await loadTsSettings(tx, ctx.companyId);
      if (!settings.serviceItemId) throw badRequest('Choose the service item used to bill time in the timesheet settings.', { serviceItemId: 'Required' });
      const location = await defaultLocation(tx, ctx, b.locationId);
      let q = unbilledRows(tx, ctx.companyId).forUpdate('e').orderBy('e.party_id').orderBy('e.task');
      if (b.partyIds?.length) q = q.where('e.party_id', 'in', b.partyIds);
      if (b.entryIds?.length) q = q.where('e.id', 'in', b.entryIds);
      const rows = await q.execute();
      const byParty = new Map<string, typeof rows>();
      for (const r of rows) byParty.set(r.party_id, [...(byParty.get(r.party_id) ?? []), r]);
      const invoices: { partyId: string; invoiceId: string; number: string; total: number; entries: number }[] = [];
      const skipped: { partyId: string; reason: string }[] = [];
      for (const [partyId, list] of byParty) {
        const priced = list.filter((r) => Number(r.rate) > 0);
        if (!priced.length) { skipped.push({ partyId, reason: 'No rate' }); continue; }
        const lines = new Map<string, { task: string; rate: number; hours: number }>();
        for (const r of priced) {
          const k = `${r.task}|${r.rate}`;
          const l = lines.get(k) ?? { task: r.task, rate: Number(r.rate), hours: 0 };
          l.hours = Math.round((l.hours + Number(r.hours)) * 100) / 100;
          lines.set(k, l);
        }
        const inv = await createInvoice(ctx, tx, {
          locationId: location, partyId, invoiceDate: b.invoiceDate,
          lines: [...lines.values()].map((l) => ({ itemId: settings.serviceItemId, qty: l.hours, rate: l.rate, description: l.task })),
          notes: 'Time billed from timesheets',
        } as never) as { id: string; number: string; total: number };
        await tx.updateTable('ts_entries').set({ invoice_id: inv.id, billed_at: new Date() }).where('id', 'in', priced.map((r) => r.id)).execute();
        invoices.push({ partyId, invoiceId: inv.id, number: inv.number, total: inv.total, entries: priced.length });
      }
      await writeAudit(tx, auditOf(ctx), 'timesheet', null, 'bill', null, { invoices: invoices.length });
      return { invoices, skipped };
    });
  });

  app.get('/timesheets/reports/utilisation', async (req) => {
    const ctx = req.ctx; ctx.require('timesheets.view');
    const q = parse(z.object({ from: dateField.optional(), to: dateField.optional(), userId: z.uuid().optional() }), req.query);
    const to = q.to ?? todayIst();
    const from = q.from ?? addDays(to, -29);
    return ctx.tx(async (tx) => {
      const settings = await loadTsSettings(tx, ctx.companyId);
      let base = entryQuery(tx).where('e.company_id', '=', ctx.companyId).where('e.work_date', '>=', from).where('e.work_date', '<=', to)
        .where('e.status', '!=', 'rejected');
      if (q.userId) base = base.where('e.user_id', '=', q.userId);
      const rows = await base.execute();
      let workDays = 0;
      for (let d = from; d <= to; d = addDays(d, 1)) if (new Date(`${d}T00:00:00Z`).getUTCDay() !== 0) workDays += 1;
      const targetHours = workDays * settings.dailyTargetHours;
      const users = new Map<string, { userId: string; name: string; totalHours: number; billableHours: number; billedHours: number; unbilledAmount: number }>();
      const customers = new Map<string, { partyId: string; name: string; hours: number; billableHours: number; amount: number }>();
      for (const e of rows) {
        const h = Number(e.hours);
        const u = users.get(e.user_id) ?? { userId: e.user_id, name: e.user_name, totalHours: 0, billableHours: 0, billedHours: 0, unbilledAmount: 0 };
        u.totalHours += h;
        if (e.billable) u.billableHours += h;
        if (e.invoice_id) u.billedHours += h;
        else if (e.billable && e.status === 'approved') u.unbilledAmount = round2(u.unbilledAmount + h * Number(e.rate));
        users.set(e.user_id, u);
        const c = customers.get(e.party_id) ?? { partyId: e.party_id, name: e.party_name, hours: 0, billableHours: 0, amount: 0 };
        c.hours += h;
        if (e.billable) { c.billableHours += h; c.amount = round2(c.amount + h * Number(e.rate)); }
        customers.set(e.party_id, c);
      }
      const ulist = [...users.values()].map((u) => ({ ...u, utilisationPct: u.totalHours ? Math.round((u.billableHours / u.totalHours) * 1000) / 10 : 0, targetHours }))
        .sort((a, b) => b.totalHours - a.totalHours);
      const sum = (f: (u: (typeof ulist)[number]) => number) => ulist.reduce((s, u) => s + f(u), 0);
      const totalHours = sum((u) => u.totalHours); const billableHours = sum((u) => u.billableHours);
      return {
        from, to, targetHours, users: ulist, customers: [...customers.values()].sort((a, b) => b.hours - a.hours),
        totals: { totalHours, billableHours, utilisationPct: totalHours ? Math.round((billableHours / totalHours) * 1000) / 10 : 0,
          billedHours: sum((u) => u.billedHours), unbilledAmount: round2(sum((u) => u.unbilledAmount)) },
      };
    });
  });
}
