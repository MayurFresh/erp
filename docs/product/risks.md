# Risk register

Starts from master plan section 17 and plan section 6. L = likelihood, I = impact (H, M, L). Owner is a role, not a person.

| ID | Risk | L | I | Mitigation | Owner |
|---|---|---|---|---|---|
| R1 | Scope too broad | H | H | One wedge per release. Exit checks in `roadmap.md`. Say no to verticals until v1.11 is done. | Product owner |
| R2 | Marketplace API access delayed or refused | H | H | Treat access as a business task. CSV import ships first. Do not promise Amazon or Flipkart dates. Meesho has no public API. | Owner |
| R3 | Provider API changes break a connector | M | M | Versioned adapters, contract tests against recorded payloads, health page showing degraded state. | Backend lead |
| R4 | Cross-tenant data leakage | L | H | RLS on every tenant table, non-superuser app role, isolation tests (`api.test.ts`, `o2c.test.ts`, `p2p.test.ts`). Add a test for every new table. See ADR-002. | Backend lead |
| R5 | Overselling | M | H | Atomic reservation under item locks, idempotent dispatch, reconciliation report. Tested in `o2c.test.ts`. Channel stock push in v1.9 adds delay risk, so push available quantity and reconcile daily. | Backend lead |
| R6 | Accounting errors | M | H | Balanced-journal trigger, reversing entries instead of edits, locked books (`books_locked_until`, PERIOD_LOCKED), GRNI and variance accounts. Chartered accountant review before claiming correctness. | Accounting lead |
| R7 | Statutory figures wrong | M | H | Marked unverified until a chartered accountant signs off. No compliance claims in the product until then. | Owner |
| R8 | Industry workflow misunderstood | M | M | Pilot with a real business per vertical before building depth. Research notes in `docs/research/industry-verticals.md`. | Product owner |
| R9 | Too many services too early | L | M | Modular monolith. See ADR-006. | Architect |
| R10 | Cloud cost | L | M | One API process, Postgres jobs table instead of Redis (ADR-003). Choose region and size from pilot load. | Architect |
| R11 | AI feature makes unsafe change | L | H | No AI writes in the roadmap before v1.11. When added: read-only first, human approval for writes, audit log entry. | Product owner |
| R12 | Offline scan conflicts | M | M | Scan ids are idempotent now. v1.10 exit check demands convergence or a visible conflict. | Mobile lead |
| R13 | Regulatory exposure (GST, e-invoice, TDS) | M | H | GSP behind an adapter, sandbox only today. Accountant review. Versioned tax rules. | Owner |
| R14 | Poor adoption | M | H | Pilot businesses, import from CSV and Tally-style exports, short setup. Measure time to first invoice. | Product owner |
| R15 | Unreliable reports | M | M | Reports read from ledgers only. Reconciliation checks in setup health. | Backend lead |
| R16 | Not production-ready without evidence | H | H | Load test, pen test, backup and restore drill, pilot run. Gates 2, 4 and 5 in v1.11. | Architect |
| R17 | Default `DATA_KEY` derived from JWT secret | M | M | Require `DATA_KEY` in production, log the warning already emitted, document rotation. | Backend lead |
| R18 | Stock ledger append-only only by convention | L | M | No database trigger blocks update or delete of `stock_moves`. Add one, or revoke UPDATE and DELETE from the app role on that table. | Backend lead |
| R19 | In-process job worker stops with the API | M | M | Stuck jobs are requeued after 10 minutes. Run a second worker only after load shows need. See ADR-003. | Backend lead |
