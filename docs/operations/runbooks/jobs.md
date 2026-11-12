# Jobs stuck or failing

Background work (notification delivery, compliance digest, auth cleanup) runs from the `jobs` table. Code: `backend/src/lib/jobs.ts`.

How it behaves:

- The worker wakes every second and claims ready jobs with `jobs_claim`, which uses `for update skip locked`.
- A failed attempt goes back to `queued` with a delay of 30 s, 60 s, 120 s and so on. After `max_attempts` (3 by default) the job is `failed` and stays there. This is the dead-letter state.
- A running job sends a heartbeat every minute (`heartbeat_at`). A job with no heartbeat for 10 minutes (its worker died) goes back to the queue at the next claim.
- Daily jobs are added once per company per IST day: `cleanup.auth` from 02:00 and `digest.compliance` from 09:00 (`DAILY` in `jobs.ts`).

## Check

1. In the app: Jobs screen, or `GET /api/v1/jobs` (needs `company.manage`). `GET /api/v1/jobs/:id` shows the error.
2. In SQL as the admin user:

```
select status, count(*) from jobs group by status;
select id, kind, attempts, error from jobs where status = 'failed' order by finished_at desc limit 20;
select id, kind, started_at, heartbeat_at from jobs where status = 'running' and coalesce(heartbeat_at, started_at) < now() - interval '10 minutes';
```

## Fix

| Symptom | Action |
| --- | --- |
| Many `queued`, none moving | Is the worker on? `JOBS_WORKER` must not be `false` on at least one process. Check the log for `job worker tick failed` |
| `failed` after a provider outage | Fix the cause (gsp-outage.md or notification-outage.md), then `POST /api/v1/jobs/:id/retry` for each. Only failed jobs can be retried |
| `running` for a long time | If `heartbeat_at` is recent, the job is still working. If it is older than 10 minutes, the worker died and the next claim re-queues it. If a job keeps hanging, read the log for that job id |
| Same job ran twice | Expected after a crash or a 10-minute reclaim. Handlers should be safe to repeat; report any that are not as a defect |

Do not delete job rows to clear them. Keep them as the record of what failed.
