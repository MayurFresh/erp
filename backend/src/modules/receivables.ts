import { sql } from 'kysely';
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { contextFor, type RequestContext } from '../auth/context.ts';
import type { Db, Tx } from '../db/database.ts';
import { addDays, isValidDate, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { registerJobHandler } from '../lib/jobs.ts';
import { notify } from '../lib/notify.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { documentRoute } from '../lib/openapi.ts';
import { FREQUENCIES, firstSlotFrom, slotDate, type Schedule } from '../lib/recurrence.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import { getLocation } from './locations.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const channelList = z.array(z.enum(['email', 'whatsapp'])).max(2).transform((c) => [...new Set(c)]);
const pageQuery = z.object({ limit: z.coerce.number().int().min(1).max(200).default(50), offset: z.coerce.number().int().min(0).default(0) });
type Who = { tenantId: string; companyId: string };

// ---------------------------------------------------------------------------------------------
// Payment reminders
// ---------------------------------------------------------------------------------------------

/** A step that was missed by a few days (job down, party skipped for the day) is still sent. */
const CATCH_UP_DAYS = 3;

export interface ReminderSettings {
  enabled: boolean; daysBefore: number | null; onDueDate: boolean; repeatEveryDays: number; maxRepeats: number;
  channels: ('email' | 'whatsapp')[]; overdueInterestPct: number; updatedAt: Date | null;
}

const DEFAULT_SETTINGS: ReminderSettings = {
  enabled: false, daysBefore: 3, onDueDate: true, repeatEveryDays: 7, maxRepeats: 3, channels: ['email', 'whatsapp'],
  overdueInterestPct: 0, updatedAt: null,
};

async function loadSettings(tx: Tx, companyId: string): Promise<ReminderSettings> {
  const r = await tx.selectFrom('receivable_settings').selectAll().where('company_id', '=', companyId).executeTakeFirst();
  if (!r) return { ...DEFAULT_SETTINGS };
  return {
    enabled: r.reminders_enabled, daysBefore: r.days_before, onDueDate: r.on_due_date, repeatEveryDays: r.repeat_every_days,
    maxRepeats: r.max_repeats, channels: r.channels as ReminderSettings['channels'], overdueInterestPct: Number(r.overdue_interest_pct),
    updatedAt: r.updated_at,
  };
}

const settingsBody = z.object({
  enabled: z.boolean().optional(),
  daysBefore: z.number().int().min(1).max(30).nullable().optional(),
  onDueDate: z.boolean().optional(),
  repeatEveryDays: z.number().int().min(1).max(90).optional(),
  maxRepeats: z.number().int().min(0).max(12).optional(),
  channels: channelList.optional(),
  overdueInterestPct: percentField.refine((v) => v <= 60, 'At most 60').optional(),
});

/** The steps of one invoice: `before`, `due`, then `after_1` .. `after_N`, each with its date. */
export function reminderSteps(s: ReminderSettings, dueDate: string): { step: string; date: string }[] {
  const out: { step: string; date: string }[] = [];
  if (s.daysBefore) out.push({ step: 'before', date: addDays(dueDate, -s.daysBefore) });
  if (s.onDueDate) out.push({ step: 'due', date: dueDate });
  for (let k = 1; k <= s.maxRepeats; k += 1) out.push({ step: `after_${k}`, date: addDays(dueDate, k * s.repeatEveryDays) });
  return out;
}

export interface ReminderRun { enabled: boolean; parties: number; invoices: number; queued: number; skipped: number }

/** Queues today's reminders for a company. Safe to run again: a step is logged once per invoice. */
export async function runReminders(tx: Tx, who: Who, today: string): Promise<ReminderRun> {
  const out: ReminderRun = { enabled: false, parties: 0, invoices: 0, queued: 0, skipped: 0 };
  const settings = await loadSettings(tx, who.companyId);
  if (!settings.enabled) return out;
  out.enabled = true;

  const open = await tx.selectFrom('invoices as i').innerJoin('parties as p', 'p.id', 'i.party_id')
    .select(['i.id', 'i.number', 'i.invoice_date', 'i.due_date', 'i.total', 'i.amount_paid', 'p.id as party_id', 'p.name', 'p.email', 'p.phone'])
    .where('i.company_id', '=', who.companyId).where('i.status', '=', 'posted').whereRef('i.amount_paid', '<', 'i.total')
    .where('p.no_reminders', '=', false).where('p.type', '!=', 'vendor').orderBy('i.due_date').orderBy('i.number').execute();
  if (!open.length) return out;

  const logged = await tx.selectFrom('reminder_log').select(['invoice_id', 'step'])
    .where('company_id', '=', who.companyId).where('invoice_id', 'in', open.map((i) => i.id)).execute();
  const done = new Set(logged.map((l) => `${l.invoice_id}:${l.step}`));
  const sentToday = new Set((await tx.selectFrom('reminder_log').select('party_id')
    .where('company_id', '=', who.companyId).where('run_date', '=', today).execute()).map((r) => r.party_id));
  const company = await tx.selectFrom('companies').select(['name', 'upi_id']).where('id', '=', who.companyId).executeTakeFirstOrThrow();

  // The latest step that has come due (today or up to a few days back) and is not logged yet.
  const byParty = new Map<string, { id: string; step: string; date: string }[]>();
  for (const inv of open) {
    const due = reminderSteps(settings, inv.due_date)
      .filter((s) => s.date > inv.invoice_date && s.date <= today && s.date >= addDays(today, -CATCH_UP_DAYS))
      .sort((a, b) => (a.date < b.date ? 1 : -1))[0];
    if (!due || done.has(`${inv.id}:${due.step}`)) continue;
    const list = byParty.get(inv.party_id) ?? [];
    list.push({ id: inv.id, step: due.step, date: due.date });
    byParty.set(inv.party_id, list);
  }

  for (const [partyId, triggers] of byParty) {
    if (sentToday.has(partyId)) continue; // one reminder per party per day; the rest wait for tomorrow
    const mine = open.filter((i) => i.party_id === partyId);
    const party = mine[0]!;
    const amountDue = round2(mine.reduce((s, i) => s + i.total - i.amount_paid, 0));
    const channels = settings.channels.filter((c) => (c === 'email' ? party.email?.trim() : party.phone?.trim()));
    let outboxIds: string[] = [];
    if (channels.length) {
      outboxIds = await notify(tx, { tenantId: who.tenantId, companyId: who.companyId }, {
        to: { email: party.email, phone: party.phone, partyId, channels }, template: 'payment_reminder',
        data: {
          partyName: party.name, companyName: company.name, count: mine.length, amountDue,
          oldestDue: mine.map((i) => i.due_date).sort()[0], upiId: company.upi_id,
        },
      });
    }
    const status = channels.length ? 'queued' : 'skipped';
    await tx.insertInto('reminder_log').values(triggers.map((t) => ({
      tenant_id: who.tenantId, company_id: who.companyId, party_id: partyId, invoice_id: t.id, step: t.step, step_date: t.date,
      run_date: today, channels, outbox_ids: outboxIds, amount: amountDue, status, note: channels.length ? null : 'No email or phone',
    }))).onConflict((oc) => oc.columns(['invoice_id', 'step']).doNothing()).execute();
    out.parties += 1;
    out.invoices += triggers.length;
    if (channels.length) out.queued += 1; else out.skipped += 1;
  }
  return out;
}

registerJobHandler('reminders.run', async (tx, job) => {
  if (!job.company_id) return { enabled: false };
  return runReminders(tx, { tenantId: job.tenant_id, companyId: job.company_id }, todayIst());
});

const STEP_LABEL = (step: string) => step === 'before' ? 'Before due date' : step === 'due' ? 'On due date' : `Overdue reminder ${step.slice(6)}`;

// ---------------------------------------------------------------------------------------------
// Recurring invoices
// ---------------------------------------------------------------------------------------------

/** Periods one template can bill in a single run, so a very old start date does not flood the books. */
const MAX_CATCH_UP = 12;

const lineBody = z.object({
  itemId: z.uuid(),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
  rate: moneyField.optional(),
  discountPct: percentField.optional(),
  description: optionalText(300),
});
const templateFields = {
  name: z.string().trim().min(1, 'Give the template a name').max(120),
  partyId: z.uuid(),
  locationId: z.uuid(),
  lines: z.array(lineBody).min(1, 'Add at least one line').max(50, 'At most 50 lines'),
  frequency: z.enum(FREQUENCIES as [string, ...string[]]),
  startDate: dateField,
  endDate: dateField.nullable().optional(),
  maxRuns: z.number().int().min(1).max(1000).nullable().optional(),
  dayOfMonth: z.number().int().min(1).max(31).nullable().optional(),
  autoSend: z.boolean().optional(),
  sendChannels: channelList.optional(),
  notes: optionalText(1000),
};
const createTemplate = z.object(templateFields);
const patchTemplate = z.object(templateFields).partial();
const listTemplates = pageQuery.extend({ status: z.enum(['active', 'paused', 'ended']).optional(), partyId: z.uuid().optional() });

type TemplateRow = Awaited<ReturnType<typeof templateRows>>[number];
const templateRows = (tx: Tx, companyId: string) =>
  tx.selectFrom('recurring_invoices as r').innerJoin('parties as p', 'p.id', 'r.party_id').innerJoin('locations as l', 'l.id', 'r.location_id')
    .innerJoin('users as u', 'u.id', 'r.created_by')
    .select(['r.id', 'r.name', 'r.party_id', 'r.location_id', 'r.lines', 'r.frequency', 'r.start_date', 'r.end_date', 'r.max_runs',
      'r.day_of_month', 'r.status', 'r.slot_no', 'r.next_date', 'r.runs_done', 'r.auto_send', 'r.send_channels', 'r.notes', 'r.last_error',
      'r.last_run_at', 'r.created_by', 'r.created_at', 'r.updated_at', 'p.name as party_name', 'l.name as location_name', 'u.name as creator_name'])
    .where('r.company_id', '=', companyId).execute();

type StoredLine = { itemId: string; qty: number; rate?: number; discountPct?: number; description?: string };

const scheduleOf = (r: { frequency: string; start_date: string; day_of_month: number | null }): Schedule =>
  ({ frequency: r.frequency as Schedule['frequency'], startDate: r.start_date, dayOfMonth: r.day_of_month });

async function templateJson(tx: Tx, rows: TemplateRow[]) {
  const itemIds = [...new Set(rows.flatMap((r) => (r.lines as StoredLine[]).map((l) => l.itemId)))];
  const items = itemIds.length ? await tx.selectFrom('items').select(['id', 'name']).where('id', 'in', itemIds).execute() : [];
  const nameOf = new Map(items.map((i) => [i.id, i.name]));
  return rows.map((r) => ({
    id: r.id, name: r.name, partyId: r.party_id, partyName: r.party_name, locationId: r.location_id, locationName: r.location_name,
    lines: (r.lines as StoredLine[]).map((l) => ({
      itemId: l.itemId, itemName: nameOf.get(l.itemId) ?? '', qty: l.qty, rate: l.rate ?? null, discountPct: l.discountPct ?? 0,
      description: l.description ?? null,
    })),
    frequency: r.frequency, startDate: r.start_date, endDate: r.end_date, maxRuns: r.max_runs, dayOfMonth: r.day_of_month,
    status: r.status, nextDate: r.next_date, runsDone: r.runs_done, autoSend: r.auto_send, sendChannels: r.send_channels,
    notes: r.notes, lastError: r.last_error, lastRunAt: r.last_run_at, createdBy: { id: r.created_by, name: r.creator_name },
    createdAt: r.created_at, updatedAt: r.updated_at,
  }));
}

/** After a period was billed (or skipped on resume): the next date, or `ended` when the template is finished. */
function advance(r: { frequency: string; start_date: string; day_of_month: number | null; end_date: string | null; max_runs: number | null },
  slotNo: number, runsDone: number): { slot_no: number; next_date: string | null; status?: 'ended' } {
  if (r.max_runs !== null && runsDone >= r.max_runs) return { slot_no: slotNo, next_date: null, status: 'ended' as const };
  const next = slotDate(scheduleOf(r), slotNo);
  if (r.end_date && next > r.end_date) return { slot_no: slotNo, next_date: null, status: 'ended' as const };
  return { slot_no: slotNo, next_date: next };
}

async function requireTemplate(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('recurring_invoices').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const r = await q.executeTakeFirst();
  if (!r) throw notFound('Recurring invoice');
  return r;
}

async function checkTemplate(tx: Tx, ctx: RequestContext, b: { partyId: string; locationId: string; lines: StoredLine[] }) {
  const party = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!party) throw badRequest('Customer not found.', { partyId: 'Not found' });
  if (party.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });
  await getLocation(tx, ctx, b.locationId);
  const ids = [...new Set(b.lines.map((l) => l.itemId))];
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  if (found.length !== ids.length) throw badRequest('One of the items was not found.', { lines: 'Item not found' });
}

function checkShape(s: { frequency: string; startDate: string; endDate?: string | null; dayOfMonth?: number | null }) {
  if (s.endDate && s.endDate < s.startDate) throw badRequest('The end date is before the start date.', { endDate: 'Before the start date' });
  if (s.frequency === 'weekly' && s.dayOfMonth) throw badRequest('Day of month does not apply to a weekly template.', { dayOfMonth: 'Not for weekly' });
}

export interface RecurringRun {
  templates: number;
  created: { templateId: string; name: string; period: string; invoiceId: string; number: string }[];
  errors: { templateId: string; name: string; message: string }[];
}

/**
 * Bills every active template whose next date has come. Each period is billed once (template and period are
 * unique), as the template's creator, in a savepoint so one failing template does not stop the others.
 */
export async function runRecurring(tx: Tx, db: Db, who: Who, today: string, onlyId?: string): Promise<RecurringRun> {
  const out: RecurringRun = { templates: 0, created: [], errors: [] };
  let q = tx.selectFrom('recurring_invoices').selectAll().where('company_id', '=', who.companyId)
    .where('status', '=', 'active').where('next_date', '<=', today).orderBy('next_date').orderBy('created_at').forUpdate().skipLocked();
  if (onlyId) q = q.where('id', '=', onlyId);
  const due = await q.execute();
  const ctxs = new Map<string, RequestContext | null>();
  const company = due.some((t) => t.auto_send)
    ? await tx.selectFrom('companies').select(['name', 'upi_id']).where('id', '=', who.companyId).executeTakeFirst() : undefined;

  for (const t of due) {
    out.templates += 1;
    if (!ctxs.has(t.created_by)) ctxs.set(t.created_by, await contextFor(tx, db, who.tenantId, t.created_by, who.companyId));
    const ctx = ctxs.get(t.created_by);
    const fail = async (message: string) => {
      out.errors.push({ templateId: t.id, name: t.name, message });
      await tx.updateTable('recurring_invoices').set({ last_error: message.slice(0, 500) }).where('id', '=', t.id).execute();
    };
    if (!ctx || !ctx.can('invoices.create')) { await fail('The person who created this template can no longer create invoices.'); continue; }

    let slot = t.slot_no;
    let runs = t.runs_done;
    let state: ReturnType<typeof advance> = { slot_no: slot, next_date: t.next_date };
    for (let i = 0; i < MAX_CATCH_UP && state.next_date && state.next_date <= today && state.status !== 'ended'; i += 1) {
      const period = state.next_date;
      const already = await tx.selectFrom('recurring_invoice_runs').select('id').where('template_id', '=', t.id).where('period', '=', period).executeTakeFirst();
      let billed = false;
      if (!already) {
        await sql`savepoint recurring_sp`.execute(tx);
        try {
          const inv = await createInvoice(ctx, tx, {
            locationId: t.location_id, partyId: t.party_id, invoiceDate: period, lines: t.lines as StoredLine[],
            notes: t.notes ?? t.name,
          } as never) as { id: string; number: string; invoiceDate: string; dueDate: string; total: number };
          await tx.insertInto('recurring_invoice_runs').values({
            tenant_id: who.tenantId, company_id: who.companyId, template_id: t.id, period, invoice_id: inv.id,
          }).execute();
          await sql`release savepoint recurring_sp`.execute(tx);
          billed = true;
          out.created.push({ templateId: t.id, name: t.name, period, invoiceId: inv.id, number: inv.number });
          if (t.auto_send && t.send_channels.length) {
            const party = await tx.selectFrom('parties').select(['name', 'email', 'phone']).where('id', '=', t.party_id).executeTakeFirstOrThrow();
            await notify(tx, who, {
              to: { email: party.email, phone: party.phone, partyId: t.party_id, channels: t.send_channels as ('email' | 'whatsapp')[] },
              template: 'recurring_invoice',
              data: { partyName: party.name, companyName: company?.name ?? '', invoiceNumber: inv.number, invoiceDate: inv.invoiceDate, dueDate: inv.dueDate, total: inv.total, upiId: company?.upi_id ?? null },
            });
          }
        } catch (err) {
          await sql`rollback to savepoint recurring_sp`.execute(tx);
          await fail(err instanceof AppError ? err.message : `Could not create the invoice: ${(err as Error).message}`);
          break;
        }
      }
      slot += 1;
      if (billed) runs += 1;
      state = advance(t, slot, runs);
      await tx.updateTable('recurring_invoices').set({
        ...state, runs_done: runs, last_run_at: new Date(), ...(billed ? { last_error: null } : {}),
      }).where('id', '=', t.id).execute();
    }
  }
  return out;
}

registerJobHandler('recurring.run', async (tx, job, deps) => {
  if (!job.company_id) return { templates: 0 };
  const r = await runRecurring(tx, deps.db, { tenantId: job.tenant_id, companyId: job.company_id }, todayIst());
  return { templates: r.templates, created: r.created.length, errors: r.errors.length };
});

// ---------------------------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------------------------

export async function receivablesRoutes(app: FastifyInstance): Promise<void> {
  // Reminder settings ----------------------------------------------------------------------
  app.get('/reminders/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.view');
    return ctx.tx((tx) => loadSettings(tx, ctx.companyId));
  });

  const saveSettings = async (req: { ctx: RequestContext; body: unknown }) => {
    const ctx = req.ctx;
    ctx.require('payments.create');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadSettings(tx, ctx.companyId);
      const next = { ...before, ...Object.fromEntries(Object.entries(b).filter(([, v]) => v !== undefined)) } as ReminderSettings;
      if (next.enabled && !next.channels.length) throw badRequest('Choose at least one channel.', { channels: 'Required' });
      if (next.enabled && !next.daysBefore && !next.onDueDate && next.maxRepeats === 0) {
        throw badRequest('Turn on at least one reminder step.', { enabled: 'No steps' });
      }
      const values = {
        reminders_enabled: next.enabled, days_before: next.daysBefore, on_due_date: next.onDueDate,
        repeat_every_days: next.repeatEveryDays, max_repeats: next.maxRepeats, channels: next.channels,
        overdue_interest_pct: next.overdueInterestPct,
      };
      await tx.insertInto('receivable_settings').values({ company_id: ctx.companyId, tenant_id: ctx.tenantId, ...values })
        .onConflict((oc) => oc.column('company_id').doUpdateSet(values)).execute();
      await writeAudit(tx, auditOf(ctx), 'reminder_settings', ctx.companyId, 'update', before, next);
      return loadSettings(tx, ctx.companyId);
    });
  };
  app.put('/reminders/settings', saveSettings);
  app.patch('/reminders/settings', saveSettings);

  app.patch<{ Params: { id: string } }>('/parties/:id/reminders', async (req) => {
    const ctx = req.ctx;
    ctx.require('parties.edit');
    const id = parse(z.uuid(), req.params.id);
    const { doNotRemind } = parse(z.object({ doNotRemind: z.boolean() }), req.body);
    return ctx.tx(async (tx) => {
      const r = await tx.updateTable('parties').set({ no_reminders: doNotRemind }).where('id', '=', id).where('company_id', '=', ctx.companyId)
        .returning('id').executeTakeFirst();
      if (!r) throw notFound('Party');
      return { partyId: id, doNotRemind };
    });
  });

  app.get('/reminders/excluded', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.view');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('parties').select(['id', 'name', 'phone', 'email']).where('company_id', '=', ctx.companyId)
        .where('no_reminders', '=', true).orderBy('name').execute();
      return { data: rows.map((r) => ({ partyId: r.id, name: r.name, phone: r.phone, email: r.email })) };
    });
  });

  app.post('/reminders/run', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.create');
    return ctx.tx((tx) => runReminders(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId }, todayIst()));
  });

  app.get('/reminders/log', async (req) => {
    const ctx = req.ctx;
    ctx.require('payments.view');
    const q = parse(pageQuery.extend({ partyId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('reminder_log as g').where('g.company_id', '=', ctx.companyId);
      if (q.partyId) base = base.where('g.party_id', '=', q.partyId);
      const total = await base.select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const rows = await base.innerJoin('parties as p', 'p.id', 'g.party_id').innerJoin('invoices as i', 'i.id', 'g.invoice_id')
        .select(['g.id', 'g.party_id', 'g.invoice_id', 'g.step', 'g.step_date', 'g.run_date', 'g.channels', 'g.outbox_ids', 'g.amount',
          'g.status', 'g.note', 'g.created_at', 'p.name as party_name', 'i.number as invoice_number'])
        .orderBy('g.created_at', 'desc').orderBy('g.id').limit(q.limit).offset(q.offset).execute();
      const ids = [...new Set(rows.flatMap((r) => r.outbox_ids))];
      const outbox = ids.length ? await tx.selectFrom('notification_outbox').select(['id', 'status']).where('id', 'in', ids).execute() : [];
      const statusOf = new Map(outbox.map((o) => [o.id, o.status]));
      const delivery = (outboxIds: string[]) => {
        const s = outboxIds.map((id) => statusOf.get(id) ?? 'pending');
        if (!s.length) return 'none';
        if (s.includes('failed')) return 'failed';
        if (s.includes('pending')) return 'pending';
        return s.every((x) => x === 'skipped') ? 'none' : 'sent';
      };
      return {
        data: rows.map((r) => ({
          id: r.id, partyId: r.party_id, partyName: r.party_name, invoiceId: r.invoice_id, invoiceNumber: r.invoice_number,
          step: r.step, stepLabel: STEP_LABEL(r.step), stepDate: r.step_date, runDate: r.run_date, channels: r.channels,
          status: r.status, note: r.note, delivery: delivery(r.outbox_ids), amount: Number(r.amount), createdAt: r.created_at,
        })),
        total: Number(total.n),
      };
    });
  });

  // Recurring invoices ---------------------------------------------------------------------
  app.get('/recurring-invoices', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.view');
    const q = parse(listTemplates, req.query);
    return ctx.tx(async (tx) => {
      let rows = await templateRows(tx, ctx.companyId);
      if (q.status) rows = rows.filter((r) => r.status === q.status);
      if (q.partyId) rows = rows.filter((r) => r.party_id === q.partyId);
      const rank = (s: string) => (s === 'active' ? 0 : s === 'paused' ? 1 : 2);
      rows.sort((a, b) => rank(a.status) - rank(b.status) || (a.next_date ?? '9999').localeCompare(b.next_date ?? '9999') || a.name.localeCompare(b.name));
      const page = rows.slice(q.offset, q.offset + q.limit);
      return { data: await templateJson(tx, page), total: rows.length };
    });
  });

  app.post('/recurring-invoices', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('invoices.create');
    const b = parse(createTemplate, req.body);
    checkShape(b);
    const out = await ctx.tx(async (tx) => {
      await checkTemplate(tx, ctx, b);
      const first = advance({ frequency: b.frequency, start_date: b.startDate, day_of_month: b.dayOfMonth ?? null, end_date: b.endDate ?? null, max_runs: b.maxRuns ?? null }, 0, 0);
      const row = await tx.insertInto('recurring_invoices').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, party_id: b.partyId, location_id: b.locationId,
        lines: JSON.stringify(b.lines), frequency: b.frequency, start_date: b.startDate, end_date: b.endDate ?? null,
        max_runs: b.maxRuns ?? null, day_of_month: b.dayOfMonth ?? null, auto_send: b.autoSend ?? false,
        send_channels: b.sendChannels ?? ['email'], notes: b.notes ?? null, created_by: ctx.userId, ...first,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'recurring_invoice', row.id, 'create', null, { name: b.name, partyId: b.partyId, frequency: b.frequency });
      return templateOne(tx, ctx, row.id);
    });
    return reply.status(201).send(out);
  });

  async function templateOne(tx: Tx, ctx: RequestContext, id: string) {
    const rows = (await templateRows(tx, ctx.companyId)).filter((r) => r.id === id);
    if (!rows.length) throw notFound('Recurring invoice');
    return (await templateJson(tx, rows))[0]!;
  }

  app.get<{ Params: { id: string } }>('/recurring-invoices/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const t = await templateOne(tx, ctx, id);
      const raw = await requireTemplate(tx, ctx, id);
      const runs = await tx.selectFrom('recurring_invoice_runs as r').innerJoin('invoices as i', 'i.id', 'r.invoice_id')
        .select(['r.period', 'r.invoice_id', 'r.created_at', 'i.number', 'i.invoice_date', 'i.total', 'i.amount_paid', 'i.status'])
        .where('r.template_id', '=', id).orderBy('r.period', 'desc').execute();
      const upcoming: string[] = [];
      if (raw.status === 'active' && raw.next_date) {
        const s = scheduleOf(raw);
        for (let n = raw.slot_no; upcoming.length < 3 && n < raw.slot_no + 3; n += 1) {
          const d = slotDate(s, n);
          if (raw.end_date && d > raw.end_date) break;
          if (raw.max_runs !== null && raw.runs_done + upcoming.length >= raw.max_runs) break;
          upcoming.push(d);
        }
      }
      return {
        ...t,
        invoices: runs.map((r) => ({
          period: r.period, invoiceId: r.invoice_id, number: r.number, invoiceDate: r.invoice_date, total: r.total,
          amountPaid: r.amount_paid, status: r.status, createdAt: r.created_at,
        })),
        upcoming,
      };
    });
  });

  app.patch<{ Params: { id: string } }>('/recurring-invoices/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchTemplate, req.body);
    return ctx.tx(async (tx) => {
      const cur = await requireTemplate(tx, ctx, id, true);
      if (cur.status === 'ended') throw conflict('This template has ended.', 'TEMPLATE_ENDED');
      const scheduleChange = (b.frequency !== undefined && b.frequency !== cur.frequency)
        || (b.startDate !== undefined && b.startDate !== cur.start_date)
        || (b.dayOfMonth !== undefined && (b.dayOfMonth ?? null) !== cur.day_of_month);
      if (scheduleChange && cur.runs_done > 0) {
        throw conflict('The schedule cannot change once an invoice has been created.', 'SCHEDULE_LOCKED');
      }
      const m = {
        name: b.name ?? cur.name, partyId: b.partyId ?? cur.party_id, locationId: b.locationId ?? cur.location_id,
        lines: b.lines ?? (cur.lines as StoredLine[]), frequency: b.frequency ?? cur.frequency, startDate: b.startDate ?? cur.start_date,
        endDate: b.endDate !== undefined ? b.endDate : cur.end_date, maxRuns: b.maxRuns !== undefined ? b.maxRuns : cur.max_runs,
        dayOfMonth: b.dayOfMonth !== undefined ? b.dayOfMonth : cur.day_of_month,
      };
      checkShape(m);
      await checkTemplate(tx, ctx, m);
      const step = {
        frequency: m.frequency, start_date: m.startDate, day_of_month: m.dayOfMonth ?? null, end_date: m.endDate ?? null, max_runs: m.maxRuns ?? null,
      };
      const next = scheduleChange ? advance(step, 0, 0) : advance(step, cur.slot_no, cur.runs_done);
      await tx.updateTable('recurring_invoices').set({
        name: m.name, party_id: m.partyId, location_id: m.locationId, lines: JSON.stringify(m.lines), ...step,
        auto_send: b.autoSend ?? cur.auto_send, send_channels: b.sendChannels ?? cur.send_channels,
        notes: b.notes !== undefined ? b.notes : cur.notes, ...next,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'recurring_invoice', id, 'update', { name: cur.name }, { name: m.name });
      return templateOne(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/recurring-invoices/:id/pause', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const cur = await requireTemplate(tx, ctx, id, true);
      if (cur.status !== 'active') throw conflict('Only an active template can be paused.', 'NOT_ACTIVE');
      await tx.updateTable('recurring_invoices').set({ status: 'paused' }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'recurring_invoice', id, 'pause', { status: 'active' }, { status: 'paused' });
      return templateOne(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/recurring-invoices/:id/resume', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const cur = await requireTemplate(tx, ctx, id, true);
      if (cur.status !== 'paused') throw conflict('Only a paused template can be resumed.', 'NOT_PAUSED');
      // Periods that fell due while paused are skipped, not billed late.
      const slot = firstSlotFrom(scheduleOf(cur), cur.slot_no, todayIst());
      const next = advance(cur, slot, cur.runs_done);
      await tx.updateTable('recurring_invoices').set({ ...next, status: next.status ?? 'active' }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'recurring_invoice', id, 'resume', { status: 'paused' }, { status: 'active' });
      return templateOne(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/recurring-invoices/:id/end', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const cur = await requireTemplate(tx, ctx, id, true);
      if (cur.status === 'ended') throw conflict('This template has already ended.', 'TEMPLATE_ENDED');
      await tx.updateTable('recurring_invoices').set({ status: 'ended', next_date: null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'recurring_invoice', id, 'end', { status: cur.status }, { status: 'ended' });
      return templateOne(tx, ctx, id);
    });
  });

  app.post('/recurring-invoices/run', async (req) => {
    const ctx = req.ctx;
    ctx.require('invoices.create');
    return ctx.tx((tx) => runRecurring(tx, ctx.db, { tenantId: ctx.tenantId, companyId: ctx.companyId }, todayIst()));
  });
}

documentRoute('PATCH', '/reminders/settings', { summary: 'Change automatic payment reminder settings', body: settingsBody });
documentRoute('POST', '/recurring-invoices', { summary: 'Create a recurring invoice template', body: createTemplate });
