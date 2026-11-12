# Decisions and assumptions register

Basis links are relative to `docs/`. Owner is a role. Date is when recorded. An assumption is not verified; a decision is made.

| ID | Type | Statement | Basis | Date | Owner | Revisit when |
|---|---|---|---|---|---|---|
| D1 | Decision | Keep Fastify, Postgres and Flutter | [ADR-001](architecture/decisions/ADR-001-keep-fastify-postgres-flutter.md), [plan 1.2](plan/ubos-discovery-and-plan.md) | 2026-11-03 | Architect | Load test shows a hard limit, or B2B portal needs a web stack |
| D2 | Decision | Tenant isolation by RLS | [ADR-002](architecture/decisions/ADR-002-row-level-security-tenancy.md), [multi-tenancy](architecture/multi-tenancy.md) | 2026-11-03 | Backend lead | A customer needs its own database |
| D3 | Decision | Jobs in Postgres, no Redis | [ADR-003](architecture/decisions/ADR-003-postgres-jobs-table.md) | 2026-11-03 | Architect | Jobs per minute or latency exceed what v1.11 load test allows |
| D4 | Decision | Append-only stock ledger with item locks | [ADR-004](architecture/decisions/ADR-004-append-only-stock-ledger.md) | 2026-11-03 | Backend lead | Multi-warehouse bins (v1.10) |
| D5 | Decision | Idempotency keys on POST | [ADR-005](architecture/decisions/ADR-005-idempotency-keys.md) | 2026-11-03 | Backend lead | Offline sync design (v1.10) |
| D6 | Decision | Modular monolith | [ADR-006](architecture/decisions/ADR-006-modular-monolith.md) | 2026-11-03 | Architect | A module needs independent scaling |
| D7 | Decision | One wedge per release | [roadmap](product/roadmap.md), [plan 4](plan/ubos-discovery-and-plan.md) | 2026-11-03 | Product owner | A pilot demands two things at once |
| D8 | Decision | CSV import ships before marketplace adapters | [requirements F14](product/requirements.md), [ecommerce-marketplaces](research/ecommerce-marketplaces.md) | 2026-11-03 | Product owner | Amazon or Flipkart access arrives early |
| D9 | Decision | v1.8 is called built, not shipped, until live tests, web build and probe pass | [roadmap](product/roadmap.md) | 2026-11-03 | Product owner | Release checks complete |
| A1 | Assumption | Amazon SP-API registration is obtainable | [risks R2](product/risks.md), [ecommerce-marketplaces](research/ecommerce-marketplaces.md) | 2026-11-03 | Owner | Registration refused or delayed past v1.9 |
| A2 | Assumption | Flipkart seller API self-access is quick | [ecommerce-marketplaces](research/ecommerce-marketplaces.md) | 2026-11-03 | Owner | First access attempt |
| A3 | Assumption | Meesho has no public API, so CSV only | [ecommerce-marketplaces](research/ecommerce-marketplaces.md) | 2026-11-03 | Product owner | Meesho publishes an API |
| A4 | Assumption | Shopify and WooCommerce are open for development | [ecommerce-marketplaces](research/ecommerce-marketplaces.md) | 2026-11-03 | Backend lead | Dev store or test site cannot be obtained |
| A5 | Assumption | Shiprocket-type aggregator suffices for courier status | [commerce-ops](research/commerce-ops.md) | 2026-11-03 | Owner | Aggregator account declined |
| A6 | Assumption | Statutory figures are unverified until a chartered accountant reviews them | [risks R7](product/risks.md) | 2026-11-03 | Owner | CA review complete |
| A7 | Assumption | The in-process worker is enough for pilot load | [ADR-003](architecture/decisions/ADR-003-postgres-jobs-table.md) | 2026-11-03 | Architect | v1.11 load test |
| A8 | Assumption | Reservations outside the ledger are sufficient | [ADR-004](architecture/decisions/ADR-004-append-only-stock-ledger.md) | 2026-11-03 | Backend lead | Bin-level picking or offline scans |
| A9 | Assumption | Money as numeric rupees is fine for documents; settlement may need paise | [commerce-ops](research/commerce-ops.md) | 2026-11-03 | Accounting lead | First settlement rounding mismatch |
| A10 | Assumption | Manufacturing, retail POS and pharma are the highest-value next verticals | [industry-verticals](research/industry-verticals.md) | 2026-11-03 | Product owner | Pilot feedback |
| A11 | Assumption | No separate business-unit level is needed | [multi-tenancy](architecture/multi-tenancy.md) | 2026-11-03 | Architect | A group customer needs it |
| A12 | Assumption | Owner will choose hosting region and product name | [plan 7](plan/ubos-discovery-and-plan.md) | 2026-11-03 | Owner | Before first pilot |
