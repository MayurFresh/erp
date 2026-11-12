# Test strategy

State on 2026-11-03, v1.8. Master plan reference: section 11.

## What exists

| Layer | Where | Tool | Count (2026-11-03) |
| --- | --- | --- | --- |
| Backend unit (pure functions) | `backend/test/gst.test.ts`, `gst-filing.test.ts` (set-off), `fixed-assets.test.ts` (depreciation), `subcontracts.test.ts` (rounding, TDS), parts of `compliance.test.ts` | vitest | inside the 183 |
| Backend integration (HTTP through `app.inject`, real PostgreSQL 16, RLS on) | the other files in `backend/test/` (17 files in all) | vitest | 183 total |
| Robustness and fuzz | `backend/test/robustness.test.ts` | vitest | hostile ids, bodies, queries on every route; races; idempotency |
| Flutter unit | `test/unit/`, `test/construction/wage_math_test.dart`, `boq_paste_test.dart`, models tests | flutter_test | in the 401 |
| Flutter widget (against fake backends) | `test/widget/`, `test/admin/`, `test/platform/`, `test/controls/`, `test/construction/`, `test/realestate/`, `test/sales_orders/`, `test/purchase_orders/`, `test/compliance/`, `test/gst_filing/`, `test/income_tax/`, `test/fixed_assets/`, `test/tax/` | flutter_test | in the 401 |
| Live contract tests (real client against the running API and seeded data) | `test/live_api_test.dart`, `live_commerce_test.dart`, `live_selffiling_test.dart`, `live_enterprise_test.dart`, `test/admin/live_admin_test.dart`, `test/construction/live_construction_test.dart` | flutter_test | 22, skipped unless `PROGEN_API` is set |
| Static checks | `tsc --noEmit`, `flutter analyze` | tsc, dart | clean |
| Build check | `flutter build web --release` | flutter | passes |

Backend tests hit a real database, not mocks. Every API test file starts from an emptied tenant table, so the files run one after another (`fileParallelism: false` in `backend/vitest.config.ts`).

## Commands

| Task | Command | Where |
| --- | --- | --- |
| Backend typecheck | `npm run typecheck` | `backend/` |
| Backend tests | `npm test` (vitest run) | `backend/` |
| One backend file | `npx vitest run test/o2c.test.ts` | `backend/` |
| Flutter analyze | `flutter analyze` | repo root |
| Flutter tests | `flutter test` | repo root |
| Live tests | `PROGEN_API=http://localhost:8080/api/v1 flutter test test/live_commerce_test.dart` (repeat per file, or pass the six files) | repo root |
| Web build | `flutter build web --release` | repo root |

## Test database pattern

Tests need `TEST_DATABASE_URL` and `DATABASE_ADMIN_URL` in `backend/.env` (names only; never commit values). `npm run db:setup` creates the app role (`nosuperuser nobypassrls`) and both databases (`backend/src/db/setup.ts`).

`setupTestApp()` in `backend/test/helpers.ts`:

1. Migrates the test database as the owner.
2. Runs `truncate tenants cascade` and puts back the system rows of `gst_rates` and `tds_sections`.
3. Builds the app with the app-role URL, so RLS applies to every query. Auth rate limits are off (`authRateLimit: false`).

Parallel agents must not share a test database, because step 2 wipes it. Each agent gives itself its own `TEST_DATABASE_URL` database name in its `.env` (for example `progen_test_d2`), runs `npm run db:setup` once, and never points tests at the development or production database. Test uploads go to the OS temp folder, not `backend/uploads`.

## Live-test setup

1. `npm run db:setup`, then `npm run db:seed` in `backend/` (creates owner@demo.in and the demo roles through the real handlers).
2. `npm start` in `backend/` (port 8080 by default).
3. Run `flutter test` with `PROGEN_API` set as above. Without it the 22 live tests skip.

Live tests change data in the seeded database. Run them on a development database only.

## Gaps against plan section 11

| Plan item | State | Target |
| --- | --- | --- |
| Property-based tests (fast-check invariants: journals balance, stock replay, no cross-tenant read) | Missing. Only the random-input pass in `robustness.test.ts` | v1.11 |
| Contract tests / OpenAPI drift | Missing. Contract is `docs/API.md`, kept by hand | v1.11 |
| Provider payload fixtures and webhook signature tests | Missing (no webhooks yet). GSP sandbox adapter is tested | v1.9, v1.11 |
| Load, stress, spike | Missing | v1.11 (k6) |
| Soak | Missing | v1.11 |
| Failover and backup restore | Missing, see `docs/operations/runbooks/backup-restore.md` | v1.11 |
| DAST and dependency scan | Missing | v1.11 |
| SAST, secret scanning | Missing | v1.11 |
| Mobile offline sync | Missing (no offline queue) | v1.10 |
| Accessibility review | Missing. Only layout tests (`test/widget/responsive_test.dart`) | v1.11 |
| Localisation / RTL | Missing | Later |
| Browser and device matrix | Missing. Web build passes; no cross-browser run | v1.11 |
| CI | Missing. No `.github/`; tests run locally only | v1.11 |
| End-to-end through a browser | Missing. Live tests cover API plus client code, not rendered UI | v1.11 |

## Rules we follow

- Contract first in `docs/API.md`, then backend with tests, then client with tests, then a live test (from `docs/plan/ubos-discovery-and-plan.md`, section 4).
- A statutory figure is marked unverified until a chartered accountant reviews it.
- A bug found by a test run goes into `docs/qa/defect-register.md` with a regression test name.
