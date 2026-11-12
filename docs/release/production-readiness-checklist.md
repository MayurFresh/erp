# Production-readiness checklist

Gates 1 to 7 from master plan section 12, assessed on 2026-11-03 for v1.8 (uncommitted tree). A module is production-ready only when every gate row is Met. None is.

Status: Met (evidence exists), Partial (some evidence), Missing (none). Paths are relative to this folder. Owners are roles, not named people; "Unassigned" means nobody has been asked.

Modules: Platform and identity, Finance, GST, Inventory, O2C (orders to returns), P2P (purchase to pay), Construction, Real estate.

## Gate 1: Product requirements

Needs approved user stories, acceptance criteria, state machine, permission matrix, error states, retention rules and analytics events.

| Module or area | Evidence | Status | Owner |
| --- | --- | --- | --- |
| Platform and identity | Roles and permissions in `../../backend/src/auth/permissions.ts`; contract in `../API.md`. No approved stories; retention and analytics events undefined | Partial | Product owner |
| Finance | `../API.md`; `../research/statutory-core.md`. No signed-off acceptance criteria | Partial | Product owner |
| GST | `../research/gst-einvoice-ewaybill.md`, `../research/self-filing-gst.md`. Statutory figures unverified by a chartered accountant | Partial | Product owner, CA |
| Inventory | `../research/commerce-ops.md`; stock rules in `../API.md` | Partial | Product owner |
| O2C | `../research/commerce-ops.md`; order and return states coded in `../../backend/src/modules/sales-orders.ts` and `sales-returns.ts` | Partial | Product owner |
| P2P | `../research/commerce-ops.md`; states in `../../backend/src/modules/purchase-orders.ts` | Partial | Product owner |
| Construction | `../research/contractor-billing.md`, `../research/labour-wages.md` | Partial | Product owner |
| Real estate | `../research/real-estate-sales.md` | Partial | Product owner |

## Gate 2: Engineering

Needs code review, unit and integration tests, migrations tested, API documented, observability, no committed secrets, tenant boundaries tested.

| Module or area | Evidence | Status | Owner |
| --- | --- | --- | --- |
| Platform and identity | Tests: `../../backend/test/api.test.ts`, `platform.test.ts`, `robustness.test.ts`, `controls.test.ts`. Tenant tests in `api.test.ts`. Migrations 001 to 014 run on every test setup. Logs only; no metrics or traces. `.env` is git-ignored. Review: single developer plus lead, tree uncommitted | Partial | Engineering |
| Finance | `../../backend/test/phase1.test.ts`, `fixed-assets.test.ts`, `statutory.test.ts` | Partial | Engineering |
| GST | `../../backend/test/gst.test.ts`, `gst-filing.test.ts`, `compliance.test.ts`, `einvoice.test.ts`, `income-tax.test.ts`; GSP sandbox adapter only | Partial | Engineering |
| Inventory | `../../backend/test/phase1.test.ts` (ledger ties to stock), `robustness.test.ts` (parallel issue) | Met | Engineering |
| O2C | `../../backend/test/o2c.test.ts` (10 tests, includes cross-tenant 404 and reservation race) | Met | Engineering |
| P2P | `../../backend/test/p2p.test.ts` (17 tests, includes cross-tenant 404) | Met | Engineering |
| Construction | `../../backend/test/construction.test.ts`, `subcontracts.test.ts` | Met | Engineering |
| Real estate | `../../backend/test/realestate.test.ts` | Met | Engineering |

Cross-cutting: API docs are hand-written (`../API.md`), no OpenAPI. CI (`.github/workflows/ci.yml`) runs typecheck, tests and audit on each push; it has not run on GitHub yet.

## Gate 3: Functional QA

Needs happy paths, edge-case suite, cross-module flows, import and export validated, browser and device tests, accessibility review.

| Module or area | Evidence | Status | Owner |
| --- | --- | --- | --- |
| Platform and identity | Happy paths pass (2026-11-03 results: `../qa/test-results/2026-11-03-v1.8.md`). Edge cases: 11 auth and 10 tenancy rows in `../qa/edge-case-catalogue.md`, most Covered or Partial. Browser matrix and accessibility not done | Partial | QA |
| Finance | Edge cases mostly Covered (catalogue, Finance section). Import tested: `controls.test.ts :: imports items, with a failing row first and then fixed` | Partial | QA |
| GST | Return builders and set-off tested; figures not reviewed by a CA | Partial | QA, CA |
| Inventory | Catalogue Inventory section: batches, serials, FEFO, conversions not built | Partial | QA |
| O2C | Live test `../../test/live_commerce_test.dart` passes. Partial shipment, multi-package, split warehouse not covered | Partial | QA |
| P2P | Same live test; stock count and billing edge cases tested | Partial | QA |
| Construction | `../../test/construction/live_construction_test.dart` passes; flows tested | Partial | QA |
| Real estate | `../../backend/test/realestate.test.ts`; `../../test/realestate/re_test.dart` | Partial | QA |

Cross-cutting: accessibility review Missing. Cross-module flow tests exist inside single files only (for example construction purchase to stock to BOQ).

## Gate 4: Security

Needs ASVS mapping, API checks, no unresolved critical or high issues, clean dependency scan, penetration test, reviewed incident plan.

| Module or area | Evidence | Status | Owner |
| --- | --- | --- | --- |
| Platform and identity | `../security/security-findings.md` (code read, not a pentest); OWASP and ASVS tables are Partial. No critical or high found; 6 medium open. Incident plan drafted: `../operations/runbooks/incident-response.md`, not reviewed | Partial | Engineering |
| Finance | Posting guarded by idempotency, row locks, period lock (tests in `robustness.test.ts`, `statutory.test.ts`) | Partial | Engineering |
| GST | GSP credentials sealed at rest; SSRF finding S-03 applies to SSO, not GSP | Partial | Engineering |
| Inventory | Permission and scope tests (`o2c.test.ts :: enforces permissions`) | Partial | Engineering |
| O2C | v1.8 role probe: no 5xx, 403s correct (`../qa/test-results/2026-11-03-v1.8.md`) | Partial | Engineering |
| P2P | `p2p.test.ts :: needs permissions` | Partial | Engineering |
| Construction | Location scope tests in `api.test.ts` and `construction.test.ts` | Partial | Engineering |
| Real estate | Permissions tested through `realestate.test.ts` | Partial | Engineering |
| Penetration test | Not done | Missing | Product owner |
| Dependency scan, SAST, secret scan, DAST | Not run; no CI | Missing | Engineering |

## Gate 5: Reliability

Needs load and soak tests, backup restore verified, recovery runbook tested, queue retry and dead-letter tested, provider outage simulation, monitoring and alerting.

| Module or area | Evidence | Status | Owner |
| --- | --- | --- | --- |
| Load and soak (all modules) | None | Missing | Engineering |
| Backup restore verified | Runbook written, drill not yet done: `../operations/runbooks/backup-restore.md` | Missing | Engineering |
| Recovery runbook tested | Runbooks written, none rehearsed: `../operations/runbooks/README.md` | Missing | Engineering |
| Queue retry and dead-letter | Retry and failed state implemented (`../../backend/src/lib/jobs.ts`); `platform.test.ts :: lists, retries a failed job and rejects retrying anything else`. Crash reclaim not tested | Partial | Engineering |
| Provider outage simulation | GSP failure mapping tested (`platform.test.ts :: seals provider credentials and maps provider failures to 502 and 503`); no outage drill; no circuit breaker | Partial | Engineering |
| Monitoring and alerting | Structured logs and `/health` (process only). No metrics, traces, alerts | Missing | Engineering |
| Graceful shutdown | `../../backend/src/server.ts` stops worker, server and pool, and exits after 15 s if something hangs | Met | Engineering |
| Concurrency (all posting modules) | `robustness.test.ts` races: allocations, cancels, stock issue; `o2c.test.ts` last-unit race | Met | Engineering |

## Gate 6: Business validation

Needs pilot users on real workflows, finance reconciling, inventory reconciling, marketplace verified, support trained, documentation ready.

| Module or area | Evidence | Status | Owner |
| --- | --- | --- | --- |
| Pilot users (all modules) | None | Missing | Product owner |
| Finance reconciles | Ledger-to-stock and journal balance tests only, on test data | Partial | Product owner, CA |
| Inventory reconciles | `phase1.test.ts :: posts every document correctly and ties stock to the ledger`; no real data | Partial | Product owner |
| Marketplace verified | No connectors yet (v1.9) | Missing | Product owner |
| Support trained | None | Missing | Product owner |
| Documentation and onboarding | `../API.md`, runbooks, research notes; no user guide or onboarding flow | Partial | Product owner |
| GST filing accepted by portal | Sandbox adapter only; no production GSP test | Missing | Product owner, CA |

## Gate 7: Release

Needs rollback plan, feature flags, staged rollout, migration plan, release notes, owner sign-off, known limitations documented.

| Module or area | Evidence | Status | Owner |
| --- | --- | --- | --- |
| Rollback plan | Migrations are forward only; rollback means restore from backup (not drilled) | Missing | Engineering |
| Feature flags | None. Every tenant sees every pack | Missing | Engineering |
| Staged rollout | `.github/workflows/ci.yml` and `backend/Dockerfile` exist, but no hosted environment yet | Missing | Engineering |
| Migration plan | `../operations/runbooks/migrate-and-seed.md`; dry-run on a restored copy not done | Partial | Engineering |
| Release notes | Plan and roadmap in `../plan/ubos-discovery-and-plan.md`; no per-release notes | Partial | Product owner |
| Owner sign-off | Not given | Missing | Product owner |
| Known limitations documented | `../qa/defect-register.md` (G-01 to G-05, D-01 to D-10) | Met | QA |

## Release blockers

From master plan section 12, with status on 2026-11-03.

| Blocker | Status | Basis |
| --- | --- | --- |
| Any cross-tenant data leak | None known; not independently tested | RLS plus tests in `api.test.ts`, `o2c.test.ts`, `p2p.test.ts`; no pentest |
| Any duplicate financial posting | None known | Idempotency and race tests in `robustness.test.ts`; webhooks and payment providers not built, so not exercised |
| Any untraceable inventory mutation | None known | Append-only `stock_moves`; ledger tie test in `phase1.test.ts`; no replay property test |
| Any authorization bypass | None known | Permission tests and v1.8 role probe; probe checked status codes only |
| Any unresolved critical vulnerability | None known; no scan run | `../security/security-findings.md` lists 6 medium findings |
| Any data loss in tested recovery scenarios | Cannot say; no recovery scenario tested | Backup drill Missing |
| Any unhandled integration failure that can corrupt state | None known for GSP and notifications | Provider errors mapped; marketplaces not built |

Gates still blocking launch:

1. Penetration test (gate 4).
2. Load and soak tests (gate 5).
3. Backup restore drill and recovery rehearsal (gate 5).
4. Dependency, secret and SAST scanning, and CI (gates 2, 4).
5. Monitoring and alerting (gate 5).
6. Pilot customers and CA review of statutory figures (gate 6).
7. Rollback plan, feature flags, staged rollout (gate 7).
8. Accessibility review and browser matrix (gate 3).

The plan puts items 2 to 5 and 7 in v1.11 (platform readiness). Items 1 and 6 are the owner's to arrange.
