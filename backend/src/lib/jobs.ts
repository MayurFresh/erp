import { sql, type Selectable } from 'kysely';
import type { Config } from '../config.ts';
import { withTenant, type Db, type Tx } from '../db/database.ts';
import type { JobTable } from '../db/schema.ts';
import { todayIst } from './dates.ts';

export type JobRow = Selectable<JobTable>;

/** What a job handler gets besides its transaction. */
export interface JobDeps {
  db: Db;
  config: Config;
  log?: { info: (msg: string) => void; warn: (msg: string) => void; error: (obj: unknown, msg?: string) => void };
}

type Handler = (tx: Tx, job: JobRow, deps: JobDeps) => Promise<object | void>;
/** Runs in its own transaction after the job's own one rolled back; `final` when no retry is left. */
type FailureHook = (tx: Tx, job: JobRow, error: Error, final: boolean) => Promise<void>;

const handlers = new Map<string, { run: Handler; onFailure?: FailureHook }>();

export function registerJobHandler(kind: string, run: Handler, opts: { onFailure?: FailureHook } = {}): void {
  handlers.set(kind, { run, onFailure: opts.onFailure });
}

export interface EnqueueOptions { runAfter?: Date; dedupeKey?: string; maxAttempts?: number }

/** Adds a job in the caller's transaction, so it only runs if that transaction commits. Returns the job id. */
export async function enqueue(
  tx: Tx, who: { tenantId: string; companyId: string | null; userId: string | null },
  kind: string, payload: object, opts: EnqueueOptions = {},
): Promise<string> {
  const row = await tx.insertInto('jobs').values({
    tenant_id: who.tenantId, company_id: who.companyId, kind, payload: JSON.stringify(payload),
    run_after: opts.runAfter ?? new Date(), dedupe_key: opts.dedupeKey ?? null,
    max_attempts: opts.maxAttempts ?? 3, created_by: who.userId,
  }).onConflict((oc) => oc.column('dedupe_key').doNothing()).returning('id').executeTakeFirst();
  if (row) return row.id;
  const existing = await tx.selectFrom('jobs').select('id').where('dedupe_key', '=', opts.dedupeKey!).executeTakeFirstOrThrow();
  return existing.id;
}

/** How often a running job renews its claim; jobs_claim re-queues after 10 minutes without one. */
export const HEARTBEAT_MS = 60_000;

/** Retry delay after the given (1-based) attempt: 30 s, 60 s, 120 s, ... */
export const backoffMs = (attempt: number) => 30_000 * 2 ** Math.max(0, attempt - 1);

const message = (err: unknown) => (err instanceof Error ? err.message : String(err)).slice(0, 2000);

/** Claims and runs up to `limit` ready jobs. Returns how many ran. */
export async function runJobsOnce(deps: JobDeps, opts: { limit?: number } = {}): Promise<number> {
  const claimed = await sql<JobRow>`select * from jobs_claim(${opts.limit ?? 10})`.execute(deps.db);
  for (const job of claimed.rows) {
    const h = handlers.get(job.kind);
    // Keeps the claim alive, so jobs_claim only re-queues jobs whose worker died.
    const beat = setInterval(() => {
      sql`select jobs_heartbeat(${job.id}::uuid)`.execute(deps.db).catch((e) => deps.log?.warn(`job ${job.id}: heartbeat failed: ${e.message}`));
    }, HEARTBEAT_MS);
    beat.unref();
    try {
      if (!h) throw new Error(`No handler for job kind ${job.kind}`);
      await withTenant(deps.db, job.tenant_id, async (tx) => {
        const result = await h.run(tx, job, deps);
        await tx.updateTable('jobs').set({
          status: 'done', result: result ? JSON.stringify(result) : null, error: null, finished_at: new Date(),
        }).where('id', '=', job.id).execute();
      });
    } catch (err) {
      const final = !h || job.attempts >= job.max_attempts;
      const error = err instanceof Error ? err : new Error(String(err));
      deps.log?.warn(`job ${job.kind} ${job.id} attempt ${job.attempts} failed: ${error.message}`);
      await withTenant(deps.db, job.tenant_id, async (tx) => {
        await tx.updateTable('jobs').set(final
          ? { status: 'failed', error: message(err), finished_at: new Date() }
          : { status: 'queued', error: message(err), run_after: new Date(Date.now() + backoffMs(job.attempts)) },
        ).where('id', '=', job.id).execute();
        if (h?.onFailure) await h.onFailure(tx, job, error, final);
      }).catch((e) => deps.log?.error(e, `job ${job.id}: could not record the failure`));
    } finally {
      clearInterval(beat);
    }
  }
  return claimed.rows.length;
}

/** Daily jobs, one per company per IST day, added from `hourIst` onwards. */
const DAILY: { kind: string; hourIst: number }[] = [
  { kind: 'digest.compliance', hourIst: 9 },
  { kind: 'cleanup.auth', hourIst: 2 },
  { kind: 'cleanup.channels', hourIst: 3 },
];

export async function scheduleDaily(db: Db, now = new Date()): Promise<void> {
  const day = todayIst(now);
  const hourIst = new Date(now.getTime() + 5.5 * 3600_000).getUTCHours();
  for (const d of DAILY) {
    if (hourIst >= d.hourIst) await sql`select jobs_enqueue_daily(${d.kind}, ${day}::date)`.execute(db);
  }
}

/** Polls for jobs every second and adds the daily jobs once a minute. */
export function startJobWorker(deps: JobDeps): { stop: () => Promise<void> } {
  let busy: Promise<unknown> | null = null;
  let lastDaily = 0;
  const tick = () => {
    if (busy) return;
    busy = (async () => {
      if (Date.now() - lastDaily >= 60_000) {
        lastDaily = Date.now();
        await scheduleDaily(deps.db);
        await sql`select channel_enqueue_pulls()`.execute(deps.db);
      }
      while ((await runJobsOnce(deps)) > 0) { /* drain */ }
    })().catch((err) => deps.log?.error(err, 'job worker tick failed')).finally(() => { busy = null; });
  };
  const timer = setInterval(tick, 1000);
  timer.unref();
  return {
    stop: async () => {
      clearInterval(timer);
      await busy;
    },
  };
}
