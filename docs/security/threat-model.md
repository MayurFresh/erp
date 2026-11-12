# Threat model

Scope: the Progen API (`backend/`), its PostgreSQL database, the job worker and the Flutter client, as of v1.8 (2026-11-03). Written from code, not from a test of a running deployment. Method: STRIDE per trust boundary.

## Assets

| Asset | Where | Why it matters |
| --- | --- | --- |
| Ledger, invoices, stock moves | PostgreSQL | Money and tax records; must not be forged, duplicated or lost |
| Tenant separation | RLS policies (`001_init.sql:220`) | One business must never see another |
| Credentials and tokens | `users` (bcrypt), `refresh_tokens`, JWT secret | Account takeover |
| Sealed secrets | TOTP secrets, SSO client secrets, GSP credentials (AES-256-GCM, `backend/src/lib/crypto.ts`) | Access to tax portal and sign-in |
| Audit log | `audit_log`, update and delete blocked by rules (`001_init.sql:238`) | Evidence |
| Uploaded files | `UPLOAD_DIR` on disk | Worker photos, DPR images, documents |
| Personal data | Party and worker records (PAN, GSTIN, phone, wages) | Privacy |

## Actors

| Actor | Trust |
| --- | --- |
| Anonymous internet user | None; reaches signup, login, reset, SSO routes only |
| Signed-in user with a role | Limited by permissions and location scope |
| Tenant admin (`security.manage`, `users.manage`) | Can configure SSO and GSP, create users |
| Operator with database access | Full; bypasses RLS as table owner |
| GSP, WhatsApp, SMTP providers | External, partly trusted |
| Marketplaces (future) | External, untrusted payloads |

## Trust boundaries

1. Client to API (HTTP, bearer token).
2. API to database (app role without `bypassrls`, tenant set per transaction).
3. Job worker to database and providers (runs in the API process).
4. API to GSP and notification providers (outbound).
5. Marketplace webhooks to API (future, v1.9).

## 1. Client to API

| STRIDE | Threat | Existing control | Residual risk |
| --- | --- | --- | --- |
| Spoofing | Stolen or guessed credentials | bcrypt cost 10 (`modules/auth.ts:23`), lockout after 10 failures for 15 minutes (`auth.ts:29`), weak-password list (`backend/src/lib/password.ts`), optional TOTP 2FA, SSO | No breached-password check; lockout allows targeted denial of service on a known email |
| Spoofing | Token forgery | HS256 JWT, algorithm pinned on verify (`auth/tokens.ts:26`); secret at least 32 chars (`config.ts:14`) | Single shared secret, no key id, so rotation signs everyone out |
| Spoofing | Stolen refresh token | Rotation; reuse ends all sessions (`api.test.ts`); session list and revoke (`modules/security.ts:218`) | Tokens held in client storage; no device binding |
| Tampering | Edit IDs or bodies to reach other data | Tenant and company come from token and membership, never the body; non-UUID path ids give 404 (`app.ts:176`); zod validation on bodies | Business rules are per endpoint; a new endpoint can miss a check |
| Tampering | Double submit or retry | `Idempotency-Key` on creates (`backend/src/lib/idempotency.ts`); row locks on state changes | Only POST under the secured scope |
| Repudiation | User denies an action | `audit_log` on writes, not updatable | Reads are not logged; no log shipping off the host |
| Information disclosure | Cross-tenant read | RLS plus `withTenant` (`db/database.ts:24`); tests in `api.test.ts` and `p2p.test.ts` | Operator and migration role bypass RLS; no external tenant-isolation test |
| Information disclosure | Verbose errors | 500s return a generic message (`app.ts:167`, `INTERNAL_ERROR`); PG codes mapped | Validation messages echo field names |
| Denial of service | Request floods, large bodies, heavy exports | 1 MB body limit (`app.ts:104`); 10 MB upload limit; page size max 200 (`backend/src/lib/paging.ts`); auth route rate limits | No rate limit outside auth; in-memory store; no load test |
| Elevation of privilege | Grant more access than held | `api.test.ts :: stops users from granting more access than they have`; `ctx.require` checks | Permission checks are hand-placed per route |
| Elevation of privilege | CORS misconfiguration | Allow-list from `CORS_ORIGINS`, narrow headers (`app.ts:122`) | Default is `*` (defect D-01) |

## 2. API to database with RLS

| STRIDE | Threat | Existing control | Residual risk |
| --- | --- | --- | --- |
| Spoofing | App connects as owner | App role is `nosuperuser nobypassrls` (`db/setup.ts`); migrations run as admin | Deployment must keep two URLs apart; nothing checks it at start |
| Tampering | SQL injection | Kysely parameterised queries; raw `sql` uses bound parameters | Hand-written SQL in functions (`jobs_claim`) is `security definer` and should be reviewed with each change |
| Tampering | Edit or delete ledger history | Append-only stock moves; reversing journals; `journal_reversed_once` index; period lock | Owner role can still edit rows |
| Repudiation | Silent data change | Audit log rules block update and delete | Owner can drop the rules |
| Information disclosure | Missing `tenant_id` filter | Policy `tenant_isolation` on every tenant table (`001_init.sql:231`); `set_config('app.tenant_id', ..., true)` is per transaction (`database.ts:27`) | Tables are `enable`, not `force`, row level security, so the owner bypasses |
| Denial of service | Long locks, deadlocks | Deadlock and serialisation errors return 409 TRY_AGAIN (`app.ts:148`) | No statement timeout set |
| Elevation of privilege | `security definer` functions | `auth_find_user_by_email`, `jobs_claim` with fixed `search_path` | Functions bypass RLS by design; list is small |

## 3. Job worker

| STRIDE | Threat | Existing control | Residual risk |
| --- | --- | --- | --- |
| Spoofing | Job runs as the wrong tenant | Each job row has `tenant_id`; handler runs in `withTenant(job.tenant_id)` (`backend/src/lib/jobs.ts:55`) | Handlers that write other tenants' data are not tested |
| Tampering | Job payload changed | Payload is written only by server code | None found |
| Repudiation | Unknown job outcome | `jobs` table keeps status, attempts, error, result; `/jobs` list (`modules/jobs.ts:34`) | Failed jobs are terminal; there is no alert |
| Information disclosure | Error text holds secrets | Provider errors are mapped (platform test `maps provider failures to 502 and 503`) | Job `error` column stores messages; not scrubbed |
| Denial of service | Poison job loops forever | `max_attempts` 3, backoff 30 s doubling (`jobs.ts:43`), then `failed` | Worker is in the API process; a slow job shares its CPU |
| Denial of service | Crash mid-job | `jobs_claim` re-queues jobs running over 10 minutes with `skip locked` (`010_enterprise.sql:433`) | Handler may run twice (D-10) |
| Elevation of privilege | Retry endpoint abuse | `/jobs/:id/retry` accepts only failed jobs (platform test) | None found |

## 4. GSP and notification providers

| STRIDE | Threat | Existing control | Residual risk |
| --- | --- | --- | --- |
| Spoofing | Fake provider response | HTTPS only for WhatsApp (`backend/src/lib/notify.ts:101`); sandbox adapter used in tests | GSP responses are not signature-verified beyond the adapter |
| Tampering | IRN payload edited | Payload built server-side (`backend/src/lib/einvoice-payload.ts`); e-invoice only after readiness check | None found |
| Repudiation | Disputed filing | Submissions listed (`/gst/submissions`); config changes audited (`modules/gsp.ts:101`) | Provider acknowledgement numbers are the only external proof |
| Information disclosure | Credential leak | Credentials sealed at rest; API returns only `savedSecrets` flags | Key falls back to `JWT_SECRET` (D-05) |
| Information disclosure | SSRF via SSO issuer | https or localhost only (`backend/src/lib/oidc.ts:12`) | Internal https hosts reachable by a tenant admin (D-04) |
| Denial of service | Provider hangs | Timeouts: 15 s notify, 8 s OIDC, GSP `timeoutMs`; transient errors retried | No circuit breaker; outage fills the outbox with retries |
| Elevation of privilege | Manual mode bypass | Mode setting needs permission; platform test `refuses manual mode` for upload | None found |

## 5. Marketplace webhooks (future, v1.9)

Not built. Controls to build before the first connector goes live:

| STRIDE | Threat | Planned control | Residual risk today |
| --- | --- | --- | --- |
| Spoofing | Fake webhook | HMAC signature check per channel account with constant-time compare; reject stale timestamps | Not built |
| Tampering | Replay or reorder | Store provider event id, dedupe, apply by version | Not built |
| Repudiation | Disputed order | Keep raw payload and signature verdict | Not built |
| Information disclosure | Webhook mapped to wrong tenant | Resolve tenant only from the channel account record, never the payload | Not built |
| Denial of service | Burst of events | Queue, per-account limits, 202 fast ack | Not built |
| Elevation of privilege | Connector token scope drift | Re-check scopes on each reconnect | Not built |

## Open items

Tracked in `docs/qa/defect-register.md` (D-01 to D-10) and `docs/security/security-findings.md`. Update this model when v1.9 connectors, API keys and outbound webhooks land.
