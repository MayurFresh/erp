import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { contextFor } from '../auth/context.ts';
import type { Db, Tx } from '../db/database.ts';
import { badRequest, forbidden, notFound } from '../lib/errors.ts';
import { registerJobHandler } from '../lib/jobs.ts';
import { notify } from '../lib/notify.ts';
import { buildReport, nextRunAfter, PERIODS, REPORTS, reportHtml, summaryText, type ReportKey } from '../lib/report-builder.ts';
import { parse } from '../lib/validate.ts';
import { documentRoute } from '../lib/openapi.ts';
import { auditOf, writeAudit } from './audit.ts';

const reportKeys = Object.keys(REPORTS) as [ReportKey, ...ReportKey[]];
const body = z.object({
  name: z.string().trim().min(1, 'Required').max(120),
  report: z.enum(reportKeys),
  filters: z.object({ period: z.enum(PERIODS).optional() }).default({}),
  frequency: z.enum(['daily', 'weekly', 'monthly']),
  weekday: z.number().int().min(0).max(6).nullish(),
  monthDay: z.number().int().min(1).max(28).nullish(),
  time: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:MM'),
  recipientUserIds: z.array(z.uuid()).max(50).default([]),
  recipientEmails: z.array(z.string().trim().toLowerCase().email('Not an email address')).max(20).default([]),
  isActive: z.boolean().default(true),
});
const patch = body.partial();

type Row = {
  id: string; tenant_id: string; company_id: string; name: string; report: ReportKey; filters: { period?: string }; frequency: string;
  weekday: number | null; month_day: number | null; send_time: string; recipient_user_ids: string[]; recipient_emails: string[];
  is_active: boolean; next_run_at: Date | null; last_run_at: Date | null; created_by: string; created_at: Date;
};

const json = (r: Row) => ({
  id: r.id, name: r.name, report: r.report, reportLabel: REPORTS[r.report].label, filters: r.filters, frequency: r.frequency,
  weekday: r.weekday, monthDay: r.month_day, time: r.send_time, recipientUserIds: r.recipient_user_ids, recipientEmails: r.recipient_emails,
  isActive: r.is_active, nextRunAt: r.next_run_at, lastRunAt: r.last_run_at, createdBy: r.created_by,
});

function check(b: { frequency: string; weekday?: number | null; monthDay?: number | null; recipientUserIds: string[]; recipientEmails: string[] }) {
  const errors: Record<string, string> = {};
  if (b.frequency === 'weekly' && b.weekday == null) errors.weekday = 'Choose a day';
  if (b.frequency === 'monthly' && b.monthDay == null) errors.monthDay = 'Choose a date, 1 to 28';
  if (!b.recipientUserIds.length && !b.recipientEmails.length) errors.recipientEmails = 'Add at least one recipient';
  if (Object.keys(errors).length) throw badRequest('Check the schedule.', errors);
}

async function load(tx: Tx, ctxLike: { companyId: string; userId: string; can: (p: string) => boolean }, id: string, forUpdate = false): Promise<Row> {
  let q = sql<Row>`select * from scheduled_reports where id = ${id} and company_id = ${ctxLike.companyId}`;
  if (forUpdate) q = sql<Row>`${q} for update`;
  const r = (await q.execute(tx)).rows[0];
  if (!r) throw notFound('Scheduled report');
  if (r.created_by !== ctxLike.userId && !ctxLike.can('company.manage')) throw forbidden();
  return r;
}

/** Builds the report and queues one email per recipient. Records the run; a failure is recorded too. */
export async function runScheduledReport(tx: Tx, db: Db, r: Row, trigger: 'schedule' | 'manual'): Promise<{ id: string; status: string; recipients: number; rowCount: number; error: string | null }> {
  let status: 'sent' | 'failed' = 'sent';
  let error: string | null = null;
  let rowCount = 0;
  let outbox: string[] = [];
  let recipients = 0;
  await sql`savepoint report_run`.execute(tx);
  try {
    const ctx = await contextFor(tx, db, r.tenant_id, r.created_by, r.company_id);
    if (!ctx) throw new Error('The person who made this schedule no longer has access to the company.');
    const built = await buildReport(tx, ctx, r.report, r.filters, r.frequency);
    rowCount = built.rows.length;
    const company = await tx.selectFrom('companies').select('name').where('id', '=', r.company_id).executeTakeFirstOrThrow();
    const who = { tenantId: r.tenant_id, companyId: r.company_id };
    const data = {
      reportName: r.name, companyName: company.name, period: built.period, text: summaryText(built),
      html: reportHtml(built, company.name), attachments: [{ filename: `${r.report}-${new Date().toISOString().slice(0, 10)}.csv`, content: built.csv }],
    };
    if (r.recipient_user_ids.length) outbox.push(...await notify(tx, who, { userIds: r.recipient_user_ids, template: 'scheduled_report', data }));
    for (const email of r.recipient_emails) outbox.push(...await notify(tx, who, { to: { email, channels: ['email'] }, template: 'scheduled_report', data }));
    recipients = outbox.length;
    if (!recipients) throw new Error('No recipient has an email address.');
  } catch (e) {
    status = 'failed';
    error = (e instanceof Error ? e.message : String(e)).slice(0, 500);
    outbox = [];
    await sql`rollback to savepoint report_run`.execute(tx);
  }
  const run = (await sql<{ id: string }>`insert into scheduled_report_runs (tenant_id, company_id, report_id, trigger, status, recipients, row_count, outbox_ids, error)
    values (${r.tenant_id}, ${r.company_id}, ${r.id}, ${trigger}, ${status}, ${recipients}, ${rowCount}, ${sql.raw(`array[${outbox.map((o) => `'${o}'`).join(',')}]::uuid[]`)}, ${error})
    returning id`.execute(tx)).rows[0]!;
  await sql`update scheduled_reports set last_run_at = now() where id = ${r.id}`.execute(tx);
  return { id: run.id, status, recipients, rowCount, error };
}

const runJson = (x: any) => ({ id: x.id, trigger: x.trigger, status: x.status, recipients: x.recipients, rowCount: x.row_count, error: x.error, ranAt: x.ran_at });

export async function scheduledReportRoutes(app: FastifyInstance, deps: AppDeps) {
  app.get('/scheduled-reports/catalogue', async (req) => {
    req.ctx.require('reports.view');
    return { data: (Object.keys(REPORTS) as ReportKey[]).map((k) => ({ key: k, label: REPORTS[k].label, ranged: REPORTS[k].ranged, allowed: req.ctx.can(REPORTS[k].perm) })), periods: PERIODS };
  });

  app.get('/scheduled-reports', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    return ctx.tx(async (tx) => {
      const rows = (await sql<Row>`select * from scheduled_reports where company_id = ${ctx.companyId}
        ${ctx.can('company.manage') ? sql`` : sql`and created_by = ${ctx.userId}`} order by created_at desc`.execute(tx)).rows;
      return { data: rows.map(json) };
    });
  });

  app.post('/scheduled-reports', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const b = parse(body, req.body);
    check(b);
    if (!ctx.can(REPORTS[b.report].perm)) throw forbidden();
    const next = nextRunAfter({ frequency: b.frequency, weekday: b.weekday ?? null, monthDay: b.monthDay ?? null, time: b.time }, new Date());
    return ctx.tx(async (tx) => {
      const r = (await sql<Row>`insert into scheduled_reports (tenant_id, company_id, name, report, filters, frequency, weekday, month_day, send_time,
        recipient_user_ids, recipient_emails, is_active, next_run_at, created_by) values (${ctx.tenantId}, ${ctx.companyId}, ${b.name}, ${b.report},
        ${JSON.stringify(b.filters)}::jsonb, ${b.frequency}, ${b.frequency === 'weekly' ? b.weekday ?? null : null}, ${b.frequency === 'monthly' ? b.monthDay ?? null : null},
        ${b.time}, ${sql.raw(`array[${b.recipientUserIds.map((x) => `'${x}'`).join(',')}]::uuid[]`)}, ${sql.raw(`array[${b.recipientEmails.map((x) => `'${x.replace(/'/g, "''")}'`).join(',')}]::text[]`)},
        ${b.isActive}, ${b.isActive ? next : null}, ${ctx.userId}) returning *`.execute(tx)).rows[0]!;
      await writeAudit(tx, auditOf(ctx), 'scheduled_report', r.id, 'create', null, { name: b.name, report: b.report });
      return reply.status(201).send(json(r));
    });
  });

  app.get<{ Params: { id: string } }>('/scheduled-reports/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => json(await load(tx, ctx, id)));
  });

  app.route<{ Params: { id: string } }>({ method: ['PATCH', 'PUT'], url: '/scheduled-reports/:id', handler: async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const id = parse(z.uuid(), req.params.id);
    const p0 = parse(patch, req.body);
    const sent = (req.body ?? {}) as Record<string, unknown>;
    // zod fills defaults on a partial schema; only fields actually sent count.
    const p = Object.fromEntries(Object.entries(p0).filter(([k]) => k in sent)) as typeof p0;
    return ctx.tx(async (tx) => {
      const cur = await load(tx, ctx, id, true);
      const m = {
        name: p.name ?? cur.name, report: p.report ?? cur.report, filters: p.filters ?? cur.filters, frequency: p.frequency ?? cur.frequency,
        weekday: p.weekday !== undefined ? p.weekday : cur.weekday, monthDay: p.monthDay !== undefined ? p.monthDay : cur.month_day,
        time: p.time ?? cur.send_time, recipientUserIds: p.recipientUserIds ?? cur.recipient_user_ids,
        recipientEmails: p.recipientEmails ?? cur.recipient_emails, isActive: p.isActive ?? cur.is_active,
      };
      check(m);
      if (!ctx.can(REPORTS[m.report].perm)) throw forbidden();
      const next = m.isActive ? nextRunAfter({ frequency: m.frequency, weekday: m.weekday ?? null, monthDay: m.monthDay ?? null, time: m.time }, new Date()) : null;
      const r = (await sql<Row>`update scheduled_reports set name = ${m.name}, report = ${m.report}, filters = ${JSON.stringify(m.filters)}::jsonb,
        frequency = ${m.frequency}, weekday = ${m.frequency === 'weekly' ? m.weekday ?? null : null}, month_day = ${m.frequency === 'monthly' ? m.monthDay ?? null : null},
        send_time = ${m.time}, recipient_user_ids = ${sql.raw(`array[${m.recipientUserIds.map((x) => `'${x}'`).join(',')}]::uuid[]`)},
        recipient_emails = ${sql.raw(`array[${m.recipientEmails.map((x) => `'${x.replace(/'/g, "''")}'`).join(',')}]::text[]`)},
        is_active = ${m.isActive}, next_run_at = ${next} where id = ${id} returning *`.execute(tx)).rows[0]!;
      await writeAudit(tx, auditOf(ctx), 'scheduled_report', id, 'update', null, { name: m.name });
      return json(r);
    });
  } });

  app.delete<{ Params: { id: string } }>('/scheduled-reports/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await load(tx, ctx, id);
      await sql`delete from scheduled_reports where id = ${id}`.execute(tx);
      await writeAudit(tx, auditOf(ctx), 'scheduled_report', id, 'delete', null, null);
      return reply.status(204).send();
    });
  });

  app.post<{ Params: { id: string } }>('/scheduled-reports/:id/run', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const r = await load(tx, ctx, id, true);
      const out = await runScheduledReport(tx, deps.db, r, 'manual');
      const row = (await sql<any>`select * from scheduled_report_runs where id = ${out.id}`.execute(tx)).rows[0];
      return runJson(row);
    });
  });

  app.get<{ Params: { id: string } }>('/scheduled-reports/:id/runs', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await load(tx, ctx, id);
      const rows = (await sql<any>`select * from scheduled_report_runs where report_id = ${id} order by ran_at desc limit 50`.execute(tx)).rows;
      return { data: rows.map(runJson) };
    });
  });
}

registerJobHandler('report.scheduled', async (tx, job, deps) => {
  const { reportId } = job.payload as { reportId: string };
  const r = (await sql<Row>`select * from scheduled_reports where id = ${reportId} for update`.execute(tx)).rows[0];
  if (!r || !r.is_active) return { skipped: true };
  // Move the schedule on first, so a failing report is retried at its next time, not every minute.
  const next = nextRunAfter({ frequency: r.frequency, weekday: r.weekday, monthDay: r.month_day, time: r.send_time }, new Date());
  await sql`update scheduled_reports set next_run_at = ${next} where id = ${r.id}`.execute(tx);
  const out = await runScheduledReport(tx, deps.db, r, 'schedule');
  return { status: out.status, recipients: out.recipients };
});

documentRoute('POST', '/scheduled-reports', { body });
