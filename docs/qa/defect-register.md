# Defect register

Severity: High (data loss, leak, wrong money), Medium (wrong behaviour with a workaround), Low (cosmetic or missing convenience). Status: Fixed, Open, Accepted.

Rows marked "found in doc review, unverified by test" came from reading code while writing the QA and security documents. No test has reproduced them yet.

## Found during v1.8 (2026-11-03)

| ID | Found | Area | Description | Severity | Status | Regression test |
| --- | --- | --- | --- | --- | --- | --- |
| R-01 | 2026-11-03 | Client tests | Menu test failed because it did not expect the new Stock counts entry | Low | Fixed | `test/unit/permissions_test.dart` |
| R-02 | 2026-11-03 | Client tests | Compile error in `test/live_commerce_test.dart` from a nullable `PurchaseOrder.id` | Low | Fixed | `test/live_commerce_test.dart` (compiles and passes live) |

## Known v1.8 gaps

| ID | Found | Area | Description | Severity | Status | Regression test |
| --- | --- | --- | --- | --- | --- | --- |
| G-01 | 2026-11-03 | P2P client | No `/p2p/settings` screen, because `ApiClient` has no `put` method | Low | Open | none |
| G-02 | 2026-11-03 | P2P client | Bill-from-GRN screen posts raw JSON | Low | Open | none |
| G-03 | 2026-11-03 | O2C client | No create-return-from-invoice screen | Low | Open | none |
| G-04 | 2026-11-03 | Dashboard | Dashboard lacks ageing, GST and TDS liability, bank balances and trends | Low | Open | none |
| G-05 | 2026-11-03 | Client UI | Construction, real-estate and platform detail screens are not restyled | Low | Open | none |

## Found in doc review (fixed in v1.8.1 unless noted)

| ID | Found | Area | Description | Severity | Status | Regression test |
| --- | --- | --- | --- | --- | --- | --- |
| D-01 | 2026-11-03 | API config | `CORS_ORIGINS` defaults to `*` (`backend/src/config.ts:17`). A production deploy that forgets to set it accepts any origin. Tokens are bearer headers, not cookies, so the risk is limited | Medium | Fixed | `test/hardening.test.ts` configuration |
| D-02 | 2026-11-03 | API rate limit | Rate limiting is registered with `global: false` (`backend/src/app.ts:128`) and applied only to auth routes (`modules/auth.ts:120`). Other routes, exports and imports are not limited. The store is in memory, so limits are per process. `trustProxy: true` (`app.ts:103`) lets a client forge `X-Forwarded-For` if the API is reachable without a proxy | Medium | Fixed (per-process store remains) | `test/hardening.test.ts` rate limits |
| D-03 | 2026-11-03 | CSV export | Formula guard covers `=`, `+`, `@` only (`backend/src/lib/csv.ts:8`). A cell starting with `-`, tab or CR is not neutralised | Low | Fixed | `test/hardening.test.ts` CSV formula guard |
| D-04 | 2026-11-03 | SSO | OIDC issuer URL is fetched server-side with only a scheme check (`backend/src/lib/oidc.ts:12`). A tenant admin with `security.manage` can point it at an internal https host (SSRF). Discovery documents also supply `token_endpoint` | Medium | Fixed (DNS rebinding remains) | `test/hardening.test.ts` SSO discovery |
| D-05 | 2026-11-03 | Secrets | Without `DATA_KEY`, the sealing key is derived from `JWT_SECRET` (`backend/src/lib/crypto.ts:15`). Rotating `JWT_SECRET` then makes every sealed TOTP secret, SSO client secret and GSP credential unreadable | Medium | Fixed (`DATA_KEY` required in production) | `test/hardening.test.ts` configuration |
| D-06 | 2026-11-03 | Operations | `/health` returns ok without touching the database (`backend/src/app.ts:184`). No readiness check | Low | Fixed | `test/hardening.test.ts` health check |
| D-07 | 2026-11-03 | Operations | Shutdown has no deadline (`backend/src/server.ts:11`). `worker.stop()` waits for the running job batch, so a hung job blocks exit | Low | Fixed (15 s deadline in `server.ts`) | none (process exit) |
| D-08 | 2026-11-03 | Files | Uploads live on local disk under `UPLOAD_DIR`, outside any database backup, with no malware scan | Medium | Partly fixed (active PDFs rejected; scanner and backup of `UPLOAD_DIR` at deploy) | `test/hardening.test.ts` uploads |
| D-09 | 2026-11-03 | Release | No CI config (`.github/` missing) and no Dockerfile in the repo | Medium | Fixed (`.github/workflows/ci.yml`, `backend/Dockerfile`; not yet run on GitHub or built) | none |
| D-10 | 2026-11-03 | Jobs | `jobs_claim` re-queues any job running over 10 minutes (`010_enterprise.sql:433`). A legitimate long job could run twice if its handler is not idempotent | Low | Fixed (heartbeat, migration 015) | `test/hardening.test.ts` job claims |
