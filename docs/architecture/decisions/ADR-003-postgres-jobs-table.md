# ADR-003: Postgres jobs table instead of Redis and BullMQ

Status: Accepted

## Context
Background work is needed: notifications, daily digests, cleanup, CSV import commit, and from v1.9 channel polling and webhook processing. The master plan lists queues generically. A new Redis service adds cost, an operations burden and a second place for data to be lost.

## Decision
Use a `jobs` table in the same database (`backend/src/lib/jobs.ts`). `enqueue(tx, ...)` runs inside the caller's transaction. `jobs_claim` uses `for update skip locked` and requeues jobs stuck running over 10 minutes. Three attempts by default with backoff 30 s doubling. A unique `dedupe_key` prevents duplicate enqueues. The worker runs in the API process and ticks every second; daily jobs are enqueued by `jobs_enqueue_daily`.

## Consequences
- A job exists only if the business change committed. No lost or phantom jobs.
- No new infrastructure, and jobs inherit backups and RLS (handlers run under `withTenant`).
- Throughput is bounded by Postgres polling at one second and by one process. Fine for hundreds of jobs per minute; unproven above that.
- No priority queues, rate-limited queues or delayed fan-out beyond `run_after`. Channel stock push will need coalescing logic in application code.
- A worker crash stops processing until restart, though stuck jobs recover afterwards.

## Alternatives
- Redis with BullMQ: richer features, extra service, dual-write problem between database and queue.
- Cloud queue (SQS, Pub/Sub): same dual-write problem, ties hosting choice.
- Separate worker process on the same table: no code change needed beyond a start flag; the first step when load requires it.
