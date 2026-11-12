# Production-readiness checklist (plan section 12)

State on 2026-11-12, tree uncommitted. This page is the short, current view of the seven gates. The per-module tables, written for v1.8, are in [../release/production-readiness-checklist.md](../release/production-readiness-checklist.md). Status: Met, Partial, Missing. "Owner" means only the owner or a hired party can close it.

## Gate 1: Product requirements
| Item | Status | Evidence or next step |
| --- | --- | --- |
| Stories, acceptance criteria, state machines | Partial | `../API.md`, `../research/`. No signed-off criteria. Owner |
| Permission matrix | Met | `backend/src/auth/permissions.ts`, role templates in `business-types.ts` |
| Retention rules, analytics events | Missing | Payroll retention (5 years) noted in `../research/payroll-hr.md`; nothing enforced. Owner decides |
| Statutory figures reviewed by a CA | Missing | GST, TDS, PF ceiling after Oct 2026, Form 10BD, ITC-04. Owner |

## Gate 2: Engineering
| Item | Status | Evidence or next step |
| --- | --- | --- |
| Unit and integration tests | Met | One vitest file per module in `backend/test/`; Flutter tests in `test/` |
| Invariants | Met | fast-check property test: journals balance, stock replay (`platform-readiness.test.ts`) |
| Migrations tested | Met | Every test setup runs all migrations; `stock_moves` is append-only (034) |
| API documented | Met | `../API.md` and generated `../openapi.json` (`npm run openapi`); CI fails when it is stale. Request bodies are described for integrations, invoices, purchases, payments, expenses, items, parties and business profile; other routes list path only |
| Module entitlements | Met | 403 `MODULE_DISABLED`, `backend/src/lib/entitlements.ts` |
| CI | Partial | `.github/workflows/ci.yml` (typecheck, tests, OpenAPI diff, audit, Flutter, Docker build). Never run on GitHub |
| Tenant boundaries tested | Met | Cross-tenant 404 tests in api, o2c, p2p and module files |
| Tracing | Missing | OpenTelemetry skipped: its `@opentelemetry/api` range conflicts with vitest. Logs only. Revisit after a vitest upgrade |
| Secrets not committed | Met | `.env` ignored; `DATA_KEY` required in production |

## Gate 3: Functional QA
| Item | Status | Evidence or next step |
| --- | --- | --- |
| Happy paths | Partial | Live tests in `test/live_*_test.dart`. Wave 2 sectors are unit-tested but not run together or viewed on screen |
| Edge cases | Partial | `../qa/edge-case-catalogue.md`: 35 covered, 40 partial, 28 not covered |
| Cross-module flows | Partial | Inside single test files only |
| Import and export | Partial | Item import tested; channel connectors are file import only |
| Browser and device matrix | Missing | Chrome and one Android phone only |
| Accessibility review | Missing | None done |

## Gate 4: Security
| Item | Status | Evidence or next step |
| --- | --- | --- |
| ASVS mapping, threat model | Partial | `../security/threat-model.md`, `../security/security-findings.md` |
| Critical and high findings | Met | None open; mediums listed in the findings file |
| Dependency scan | Partial | `npm audit` in CI, not yet run there |
| SAST, secret scan, DAST | Missing | Add CodeQL and a secret scanner to CI |
| API keys and webhooks | Met | Hashed keys, role-bound, cannot manage keys; webhook URLs checked against private addresses; signed deliveries |
| Penetration test | Missing | Owner hires |
| Incident plan | Partial | `../operations/runbooks/incident-response.md`, never rehearsed |
| Malware scan and upload backup | Missing | Uploads sit on local disk |

## Gate 5: Reliability
| Item | Status | Evidence or next step |
| --- | --- | --- |
| Backup and restore | Partial | Drill passed on the dev database: `backup-restore.md`. Repeat on a production-sized copy and the host's point-in-time restore |
| Load test | Partial | Script `backend/load/k6-smoke.js`; no recorded result at production size |
| Soak test | Missing | Run k6 for 4 hours, watch memory and connections |
| Queue retry and dead letter | Partial | Job heartbeat and retry tested; webhook deliveries retry with a log |
| Provider outage simulation | Missing | Runbooks `gsp-outage.md`, `notification-outage.md` untested |
| Monitoring and alerts | Missing | `/health` checks the database; no metrics, no alert rules, no uptime probe |
| Rate limit store | Partial | Per process; needs a shared store with more than one API instance |

## Gate 6: Business validation
| Item | Status | Evidence or next step |
| --- | --- | --- |
| Pilot users on real workflows | Missing | Owner |
| Finance and inventory reconcile against pilot books | Missing | Owner and CA |
| Marketplace channels verified live | Missing | Needs seller accounts |
| Support trained, documentation ready | Missing | Owner |

## Gate 7: Release
| Item | Status | Evidence or next step |
| --- | --- | --- |
| Rollback plan | Partial | Migrations are forward only; restore from backup is the rollback. Write per-release notes |
| Feature flags, staged rollout | Partial | Per-company module switches work as flags; no percentage rollout |
| Migration plan | Partial | `../operations/runbooks/migrate-and-seed.md` |
| Release notes, known limitations | Partial | Known gaps listed in `../../CLAUDE.md`; no release notes |
| Owner sign-off | Missing | Owner |

## Closed by engineering next
1. Run CI once on GitHub and fix what it finds.
2. Add CodeQL and a secret scan.
3. Record a k6 result and a soak run against a production-sized database.
4. Metrics endpoint, alert rules and an uptime probe.
5. Tracing after the vitest conflict is gone.
