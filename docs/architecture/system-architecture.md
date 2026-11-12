# System architecture

Progen ERP is a modular monolith: one Fastify API process, one PostgreSQL 16 database, one Flutter client (web, mobile, desktop). A job worker runs inside the API process.

## Diagram

```
 Flutter app (Riverpod, go_router)
        |  HTTPS, Bearer JWT, X-Company-Id, Idempotency-Key
        v
 Fastify 5  (backend/src/app.ts)
   helmet, CORS, rate-limit, multipart (10 MB), bodyLimit 1 MB
   public scope: /health, auth routes (IP rate limit)
   secured scope: onRequest auth hook -> req.ctx (RequestContext)
        |
        v
 modules/*.ts  (about 62 route files, zod validation)
        |  ctx.tx(...)  = withTenant(db, tenantId, fn)
        v
 accounting/*, lib/*   (journal, costing, series, jobs, notify, gsp, oidc, crypto)
        |
        v
 PostgreSQL 16  (Kysely; RLS on tenant tables; app role nosuperuser nobypassrls)
        ^
        |  jobs_claim (for update skip locked)
 Job worker (startJobWorker, same process, 1 s tick)
```

## Components

| Component | Where | Role |
|---|---|---|
| App factory | `backend/src/app.ts` | Registers plugins, hooks, error handler and every module. |
| Server | `backend/src/server.ts` | Listens and starts the worker when `JOBS_WORKER` is true (default). |
| Config | `backend/src/config.ts` | Environment: `JWT_SECRET`, `DATA_KEY`, token TTLs, rate limits. |
| Database | `backend/src/db/` | Kysely, `withTenant`, migrations 001 to 014, seed, role setup. |
| Auth | `backend/src/auth/` | Tokens, memberships, permissions, `RequestContext`. |
| Accounting | `backend/src/accounting/` | Accounts, journal posting, weighted-average costing, item locks. |
| Libraries | `backend/src/lib/` | Idempotency, jobs, notify, series, scope, crypto, OIDC, GSP adapters. |
| Client | `lib/` | Feature folders per module, `api_client.dart` for HTTP and errors. |

## Request lifecycle

1. Plugins run: helmet (CSP off), CORS (allowed headers Authorization, Content-Type, X-Company-Id, Idempotency-Key), rate limit (`global: false`).
2. The preValidation hook returns 404 for any `id` or `*Id` parameter that is not a UUID.
3. In the `secured` scope the onRequest hook verifies the HS256 JWT (claims `typ`, `tid`, `sid`, `amr`) and checks that the session row in `refresh_tokens` is live. A revoked session gives `sessionRevoked`.
4. It loads memberships (`loadMemberships`), honouring `valid_from`, `valid_to` and `location_ids`. `X-Company-Id` must match a membership.
5. If the company has `require_2fa` and the user has not enrolled, the response is 403 `MFA_ENROLMENT_REQUIRED`, except on paths in `ENROL_EXEMPT`.
6. `req.ctx` is created. Handlers call `ctx.require(permission)`, `ctx.requireLocation(id)` and `ctx.tx(...)`.
7. For POST requests with an `Idempotency-Key`, the idempotency wrapper replays or records the response.
8. The error handler maps database errors: 23505 CONFLICT, 23503 IN_USE or VALIDATION_ERROR, 40001 and 40P01 TRY_AGAIN, 22xxx VALIDATION_ERROR, 413, 429 RATE_LIMITED.

## Job worker

`backend/src/lib/jobs.ts` and `modules/jobs.ts`. Table `jobs` has status (queued, running, done, failed), attempts, `max_attempts` (3), `run_after`, a unique `dedupe_key`, payload, result and error.

- `enqueue(tx, ...)` joins the caller's transaction, so a job exists only if the business change committed.
- `jobs_claim(limit)` is SECURITY DEFINER, uses `for update skip locked`, and requeues jobs stuck running for over 10 minutes.
- Backoff is 30 s times 2 to the power attempt minus 1. Handlers run under `withTenant`. `onFailure` receives a `final` flag.
- `startJobWorker` ticks every second and calls `scheduleDaily` once a minute. Daily kinds: `digest.compliance` (09:00 IST), `cleanup.auth` (02:00 IST), enqueued by `jobs_enqueue_daily`.
- Handlers: `notification.send`, `digest.compliance`, `cleanup.auth`, `import.commit`.

## Where change is expected

v1.9 adds a connector registry, webhook inbox and poll jobs on this same worker. See `integration-architecture.md`. ADR-003 explains why no queue server is added.
