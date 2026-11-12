import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { AppDeps } from '../app.ts';
import { contextFor } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import type { JobRow } from '../lib/jobs.ts';
import { registerJobHandler } from '../lib/jobs.ts';
import { forbidden, notFound, conflict } from '../lib/errors.ts';
import { notify } from '../lib/notify.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { buildAlerts } from './compliance.ts';

const listQuery = z.object({
  status: z.enum(['queued', 'running', 'done', 'failed']).optional(),
  kind: z.string().trim().max(60).optional(),
  limit: z.coerce.number().int().min(1).max(200).default(50),
  offset: z.coerce.number().int().min(0).default(0),
});

async function jobsJson(tx: Tx, rows: JobRow[]) {
  const ids = [...new Set(rows.map((r) => r.created_by).filter((x): x is string => !!x))];
  const users = ids.length ? await tx.selectFrom('users').select(['id', 'name']).where('id', 'in', ids).execute() : [];
  return rows.map((j) => ({
    id: j.id, kind: j.kind, status: j.status, attempts: j.attempts, maxAttempts: j.max_attempts, runAfter: j.run_after,
    result: (j.result as object | null) ?? null, error: j.error,
    createdBy: j.created_by ? { id: j.created_by, name: users.find((u) => u.id === j.created_by)?.name ?? '' } : null,
    createdAt: j.created_at, finishedAt: j.finished_at,
  }));
}

/** Job list, detail and retry (v1.7 section 5), and the two daily job handlers. */
export async function jobRoutes(app: FastifyInstance, _deps: AppDeps): Promise<void> {
  app.get('/jobs', async (req) => {
    const ctx = req.ctx;
    ctx.require('company.manage');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('jobs').where((eb) => eb.or([eb('company_id', '=', ctx.companyId), eb('company_id', 'is', null)]));
      if (q.status) base = base.where('status', '=', q.status);
      if (q.kind) base = base.where('kind', '=', q.kind);
      const total = await base.select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await jobsJson(tx, rows), total: Number(total.n) };
    });
  });

  app.get<{ Params: { id: string } }>('/jobs/:id', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const j = await tx.selectFrom('jobs').selectAll().where('id', '=', id).executeTakeFirst();
      if (!j) throw notFound('Job');
      if (j.created_by !== ctx.userId && !ctx.can('company.manage')) throw forbidden();
      return (await jobsJson(tx, [j]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/jobs/:id/retry', async (req) => {
    const ctx = req.ctx;
    ctx.require('company.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const j = await tx.selectFrom('jobs').selectAll().where('id', '=', id).forUpdate().executeTakeFirst();
      if (!j) throw notFound('Job');
      if (j.status !== 'failed') throw conflict('Only a failed job can be retried.');
      const after = await tx.updateTable('jobs').set({
        status: 'queued', attempts: 0, error: null, finished_at: null, started_at: null, run_after: new Date(),
      }).where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'job', id, 'retry', { status: 'failed' }, { status: 'queued' });
      return (await jobsJson(tx, [after]))[0];
    });
  });
}

// Handlers are registered once, on import.

registerJobHandler('digest.compliance', async (tx, job, deps) => {
  if (!job.company_id) return { sent: 0 };
  const company = await tx.selectFrom('companies').select('name').where('id', '=', job.company_id).executeTakeFirst();
  if (!company) return { sent: 0 };
  const optedIn = await tx.selectFrom('notification_prefs').select('user_id')
    .where('template', '=', 'compliance_digest').where('email', '=', true).execute();
  let sent = 0;
  for (const { user_id } of optedIn) {
    const ctx = await contextFor(tx, deps.db, job.tenant_id, user_id, job.company_id);
    if (!ctx) continue;
    const alerts = (await buildAlerts(tx, ctx, 7)).filter((a) => a.dueDate);
    if (!alerts.length) continue;
    const items = alerts.map((a) => ({ label: a.title, dueDate: a.dueDate ?? '', overdue: a.severity === 'overdue' }));
    await notify(tx, { tenantId: job.tenant_id, companyId: job.company_id }, {
      userIds: [user_id], template: 'compliance_digest', data: { companyName: company.name, items },
    });
    sent += 1;
  }
  return { sent };
});

registerJobHandler('cleanup.auth', async (tx) => {
  const now = new Date();
  const old = new Date(now.getTime() - 30 * 86_400_000);
  const n = async (r: Promise<{ numDeletedRows: bigint }[]>) => Number((await r)[0]?.numDeletedRows ?? 0);
  const states = await n(tx.deleteFrom('sso_states').where('expires_at', '<', now).execute());
  const tickets = await n(tx.deleteFrom('sso_tickets').where('expires_at', '<', now).execute());
  const resets = await n(tx.deleteFrom('password_resets').where('expires_at', '<', now).execute());
  const challenges = await n(tx.deleteFrom('mfa_challenges').where('expires_at', '<', now).execute());
  const refresh = await n(tx.deleteFrom('refresh_tokens').where('expires_at', '<', old).execute());
  return { states, tickets, resets, challenges, refresh };
});
