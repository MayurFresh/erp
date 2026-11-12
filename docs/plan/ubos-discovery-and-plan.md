# Progen as a business operating system: discovery report and plan

Written 3 November 2026 against the "Universal Business Operating System master plan" (v1.0). The plan describes building that product from scratch. Progen already exists, so this report answers three questions: what in the plan is already built, what is missing, and what to build next, in what order.

Section numbers in brackets refer to the master plan.

## 1. Where Progen stands today

| Area | State |
| --- | --- |
| Backend | Node 24 (TypeScript, run directly), Fastify 5, Kysely 0.29, PostgreSQL 16, zod 4. One process: a modular monolith with a job worker inside it. |
| Client | Flutter 3.44 (web, Android, iOS, desktop from one codebase), Riverpod 3, go_router 17. |
| Tenancy | Shared schema. Every tenant table has `tenant_id`, and PostgreSQL row-level security enforces it, so a forgotten `where tenant_id = ?` still can't leak rows. Tenant and company come from the signed token and membership, never from the request body. |
| Identity | Passwords with lockout, two-factor sign-in with recovery codes, OIDC single sign-on, session list with remote sign-out, refresh-token rotation, roles and per-location scope. |
| Controls | Approval engine (multi-level, by amount and role), custom fields, cost centres, audit log on every write, idempotency keys on creates, books lock, row locks on state changes. |
| Finance | Double-entry ledger, invoices, purchases, payments and allocations, credit notes, expenses, journals, bank reconciliation, fixed assets and depreciation, multi-company with inter-company entries and consolidation. |
| India compliance | GST rates by date, GSTR-1, 3B, 2B matching, GSTR-9, e-invoice and e-way bill via a GSP adapter (sandbox today), TDS sections, challans and returns, MSME dues, self-filing kit, ITR pack. |
| Inventory | Stock ledger (`stock_moves`, append-only, signed quantities), locations (warehouses and sites), transfers, material issues, stock valuation. |
| Industry packs | Construction (projects, BOQ, indents, DPRs, labour, subcontract work orders, RA bills) and real-estate sales (units, bookings, payment plans, demands). |
| Platform | Background jobs with retries, notification outbox (email and WhatsApp), CSV import with preview, CSV export. |
| Commerce (v1.8) | Sales orders with reservations, pick, pack with scan check, dispatch to invoice and shipment, returns and RTO with inspection, purchase orders with approval, goods receipt, three-way bill match, reorder suggestions, cycle counts. |
| Tests | Backend 183 (vitest, real PostgreSQL, includes a robustness fuzz pass). Flutter 401 widget and unit tests, plus 22 tests against the running API. Flutter web release build passes. |

### 1.1 Architecture

```text
Flutter app (web, Android, iOS)
        |  HTTPS, JSON, Bearer token, X-Company-Id
Fastify API: auth hook -> tenant and company context -> permission check
        |
Route modules: accounting, sales, purchases, stock, GST, TDS, construction,
               real estate, approvals, imports, platform ...
        |
withTenant(tx): sets app.tenant_id -> PostgreSQL row-level security
        |
PostgreSQL 16 (ledgers, documents, audit_log, jobs, notification_outbox)
        |
Job worker (same process): notifications, imports, GSP calls, digests
```

### 1.2 Stack decision ([ADR-001](../architecture/decisions/ADR-001-keep-fastify-postgres-flutter.md))

The master plan prefers NestJS, MySQL and Next.js "unless repository constraints justify a different approach" [§D]. We keep Fastify, PostgreSQL and Flutter:

- **PostgreSQL row-level security** is the strongest answer to the plan's own rule "do not rely only on developers remembering `WHERE tenant_id = ?`" [§9.3]. MySQL has no equivalent.
- **Flutter** already covers web plus the mobile scanning apps the plan needs [§Phase 3], from one codebase. Next.js would add a second client.
- **A rewrite would throw away** about 500 passing tests and the India compliance work. The plan forbids that without evidence [§A].

Redis and BullMQ are not needed yet. The PostgreSQL job table (`for update skip locked`) handles current volumes. Revisit when queue lag is measured [§9.1].

## 2. Gap analysis against the master plan

Legend: **Done** = built and tested. **Partial** = some of it exists. **Missing** = not started.

| Master plan area | State | Notes |
| --- | --- | --- |
| Tenants, legal entities, branches [§5.1 A] | Done | Companies are legal entities; locations are branches, warehouses and sites. No separate business-unit level. |
| Users, roles, MFA, SSO, audit [§5.1 A] | Done | SAML not built. |
| Subscription, plans, entitlements, module activation [§5.2, §5.3] | Missing | Every tenant sees every pack. Needed before charging per module. |
| Workflow and approvals [§5.1 A] | Partial | Approvals done; no general workflow builder. |
| API keys, developer portal, outbound webhooks, OpenAPI [§5.1 A, §9.1] | Missing | The contract is in docs/API.md by hand. |
| Sales orders [§5.1 B] | Done (v1.8) | Quotations not built. |
| Purchase orders and goods receipt [§5.1 B] | Done (v1.8) | With approval and three-way match. |
| Stock reservations, available-to-promise [§6.2] | Done (v1.8) | Reservations sit outside the stock ledger. |
| Pick, pack, scan, dispatch [§6.1 steps 7–12] | Done (v1.8) | Scan by barcode field; camera scanning in v1.10. |
| Returns, RTO, inspection, disposition [§6.1 steps 13–15] | Done (v1.8) | No customer return portal. |
| Cycle counts [§6.2] | Done (v1.8) | |
| Bins, batches, expiry, FEFO, serials [§G] | Missing | v1.10. |
| Marketplace and store connectors [§7] | Missing | Research done (docs/research/ecommerce-marketplaces.md). v1.9. |
| Settlement reconciliation [§6.1 step 16] | Missing | Posting rules researched (same note, §8). v1.9. |
| Multi-currency [§8.2] | Missing | INR only. Needed for exports and global use. |
| HR and payroll | Missing | Research done (docs/research/payroll-hr.md). |
| Manufacturing (BOM, MRP, QC) [§6.4] | Missing | |
| Retail POS, restaurant, hospitality, media and other verticals [§5.1 C] | Missing | One at a time, each after domain research [§I]. |
| AI assistant [§J] | Missing | After the tool layer (OpenAPI and permissions) is ready. |
| Observability: traces, metrics, error reporting [§9.1] | Partial | Structured logs only. |
| CI/CD, Docker, IaC [§13] | Missing | Tests run locally only. |
| Load, soak, backup-restore drills [§11.5, §10.3] | Missing | |
| Property-based tests [§11.3] | Partial | A random-input robustness pass exists; no fast-check invariants yet. |

## 3. Who we build for first

The master plan's recommended first market fits Progen's strengths [§1.2, §2.2]: **Indian SMEs that hold stock and sell through several channels**. That means marketplace sellers, D2C brands, distributors and wholesalers, and small manufacturers with one or more warehouses. They already need what Progen does well (GST, TDS, books), and what they lack today is order, warehouse and channel operations.

Construction and real estate stay as existing industry packs. They are not the launch wedge.

## 4. Roadmap

Each release keeps the same rule: contract first in docs/API.md, then backend with tests, then client screens with tests, then a live test against seeded data.

| Release | Scope | Exit check |
| --- | --- | --- |
| **v1.8 Commerce core** (done 3 Nov 2026) | Sales orders with stock reservations, pick lists, pack with scan check, dispatch to invoice and shipment, returns and RTO with inspection. Purchase orders through approval, goods receipt, bill matching (PO, GRN, bill), reorder suggestions, cycle counts. A new design system across the app. Competitor and channel-API research. | Two orders for the last unit can't both reserve it. A duplicate dispatch can't double-post stock. Receipt, bill and stock reconcile. |
| v1.9 Channels | CSV order, return and settlement import for any channel (first, see §9), connector contract (as the GSP adapter), Shopify and WooCommerce adapters, Amazon and Flipkart once access is granted, Tally export, SKU mapping and bundles, stock sync, settlement posting and reconciliation, connector health page, webhook inbox with signature check and dedupe. | Replaying the same webhook or file changes nothing. |
| v1.10 Warehouse depth | Bins, batches and expiry with FEFO, serial numbers, camera scanning in the mobile app, offline scan queue with conflict rules, labels and manifests, courier aggregator adapter. | Offline scans converge or show a conflict to resolve. |
| v1.11 Platform readiness | OpenAPI from the zod schemas, CI on every push, Docker image, OpenTelemetry, backup and restore drill, k6 load test, fast-check invariants (journals balance, stock replay), module entitlements and plans, API keys and outbound webhooks. | Production-readiness gates 2, 4 and 5 [§12] have evidence. |
| v1.12 HR and payroll | From docs/research/payroll-hr.md. | |
| v1.13 Manufacturing | BOM, MRP, production orders, job work, quality checks. | |
| Later | Retail POS, B2B portal, restaurant, hospitality, AI assistant, multi-currency and other countries. | |

## 5. v1.8 work split

| Owner | Scope | Files |
| --- | --- | --- |
| Lead | Foundation (migration 012, series codes), wiring routes, nav and seed, live test, final checks | `012_commerce.sql`, `lib/series.ts`, `router.dart`, `nav.dart`, `seed.ts` |
| C1 | Order to cash: sales orders, reservations, pick, pack, dispatch, shipments, returns. Backend and Flutter. | `013_o2c.sql`, `modules/sales-orders.ts` and friends, `lib/features/sales_orders/`, API.md §A |
| C2 | Procure to pay: purchase orders, goods receipt, bill matching, reorder, cycle counts. Backend and Flutter. | `014_p2p.sql`, `modules/purchase-orders.ts` and friends, `lib/features/purchase_orders/`, API.md §B |
| D | Design system: palette, type, spacing, components, illustrations, app icon, dashboard, sign-in, copy. | `lib/core/theme.dart`, `lib/widgets/`, shell, dashboard, auth screens, `web/` |
| R | Research: competitor teardown for the commerce wedge, channel API access, pricing, source register. | `docs/research/` |

## 6. Risks I see in the master plan itself

- **Scope.** Seventeen verticals is a decade of work for a large team. The plan says so too [§1.2]. We hold to one wedge per release.
- **Marketplace access is a business task, not a coding one.** Amazon SP-API needs a developer registration, and Flipkart needs a seller API application. Meesho has no public seller API that we could confirm. Code can be ready, but nothing goes live until the owner gets access [§7.3].
- **Compliance sign-off.** Every statutory figure in Progen is marked unverified until a chartered accountant reviews it [§8].
- **"Production ready" needs evidence we don't have yet:** load tests, a penetration test, backup drills and pilot customers [§12]. v1.11 produces the engineering evidence. Pilots are the owner's call.

## 7. Decisions needed from the owner

1. Apply for Amazon SP-API developer access and the Flipkart seller API (both need the business's own seller accounts).
2. A Shopify development store and a WooCommerce test site for the v1.9 adapters.
3. A courier aggregator account (for example Shiprocket) for v1.10.
4. A GSP for live e-invoice and e-way bill (still sandbox).
5. Two or three pilot businesses in the wedge, and a chartered accountant to review postings.
6. Hosting region and provider, so v1.11 can target it.
7. Product name: keep "Progen", or rebrand to match the broader vision.
8. Whether to add a scan-only picker role for warehouse staff.
9. A separate `DATA_KEY` for production field encryption, held outside the database host.
10. Ask the Meesho, Myntra, AJIO, Nykaa and JioMart account managers about partner API access. Until then those channels run on file import.

## 8. Master plan deliverables [§4.1, §19]

| Deliverable | Where | State |
| --- | --- | --- |
| Research files [§4.1] | [docs/research/](../research/README.md): competitor-master (96 vendor rows), feature-matrix (48 features, Progen and 23 vendors), pricing-matrix (108 published prices), integration-matrix (41 APIs with Progen status), 18 competitor profiles, 13 industry workflows with a ranking, source register, research gaps, decisions and assumptions | Done. Gaps need vendor demos, quotes and the owner's seller logins. |
| Product docs [§19 C] | [docs/product/](../product/): vision, personas, industry and module catalogues, requirements F1 to F19 with acceptance criteria, user stories, roadmap, risks | Done |
| Architecture [§19 D] | [docs/architecture/](../architecture/): system, domain boundaries, data flow, multi-tenancy, security, integrations, and ADR-001 to ADR-006 | Done |
| QA, security, operations, release [§19 N] | [docs/qa/](../qa/), [docs/security/](../security/), [docs/operations/runbooks/](../operations/runbooks/), [docs/release/](../release/) | See §11 |

## 9. What the research changes

1. **v1.9 opens with file import, not adapters.** Meesho, Myntra, AJIO, Nykaa, JioMart and Snapdeal have no public seller API that we could find. CSV import for orders, returns and settlements, with channel SKU mapping, is the only route for them and works for every other channel too.
2. **The webhook inbox needs one verifier per provider.** Shopify signs the raw body with HMAC-SHA256, waits 5 seconds for a reply, retries 8 times and sends a `Webhook-Id` to dedupe on. WooCommerce disables a webhook after more than 5 failed deliveries. Each payment gateway signs differently. So the inbox stores the raw body, verifies, replies at once, and hands the work to the job worker, keyed on the provider's event id.
3. **Tally export moves into v1.9.** TallyPrime Silver costs Rs 22,500 once, and most target SMEs keep Tally as the book their CA works in. An export lets them run operations in Progen without moving their books on day one.
4. **A live GSP is now a competitive gap, not just a compliance one.** Zoho Books includes e-invoicing from Rs 749 per organisation per month and acts as its own GSP. Progen's e-invoice is still sandbox.
5. **Odoo puts its API, Studio and multi-company on its top Custom plan.** Progen has all three in core, which is worth saying on a pricing page.
6. **Business Central has about 70 India tax scenario pages.** That is the bar for compliance depth, and it is why the CA review in §7 matters.
7. **NetSuite exposes data to AI clients over MCP.** Progen's assistant should use the same route: the permissioned API from v1.11 first, the assistant after it.
8. **Vertical order after commerce:** construction and real-estate gap closure, then retail and wholesale (POS), manufacturing, professional services, restaurant, hospitality. The ranking is in [industry-workflows/README.md](../research/industry-workflows/README.md). India demand evidence is weak for most rows.

## 10. Code facts the plan should not assume away

- `stock_moves` is append-only by convention. No database trigger blocks an update or delete yet. ADR-004 records this, and v1.11 adds the trigger.
- Reservations are their own table, outside the stock ledger. Available stock is on hand minus reserved.
- Money is PostgreSQL `numeric` in rupees. Multi-currency will need a currency and rate on each document.
- There is no business-unit level and no SAML.
- No inbound webhook, outbound webhook or polling code exists yet. All of it is v1.9 work.

## 11. QA, security and release state [§11, §12, §19 N]

**Edge cases.** [qa/edge-case-catalogue.md](../qa/edge-case-catalogue.md) maps 176 cases from §11.2 and §11.4. 35 are covered by tests, 40 partly, 28 not at all, and 73 don't apply yet (features not built).

**Defects found in review** ([qa/defect-register.md](../qa/defect-register.md), D-01 to D-10). Found by reading code, not by a failing test. All ten were fixed in v1.8.1 with tests in `backend/test/hardening.test.ts`, except where a residual risk is noted.

| Id | Finding | Status |
| --- | --- | --- |
| D-01 | `CORS_ORIGINS` defaults to `*`. | Fixed v1.8.1: startup refuses `*` in production |
| D-02 | Rate limits cover sign-in routes only, live in memory, and `trustProxy` is always on, so a client can spoof its address. | Fixed v1.8.1: per-IP limit on every route, `TRUST_PROXY` off by default. The store is still per process (v1.11) |
| D-03 | The CSV formula guard escapes `=`, `+` and `@` but not `-`, tab or carriage return. | Fixed v1.8.1 |
| D-04 | The OIDC issuer URL is fetched with only a scheme check, so a tenant admin could point it at an internal host (SSRF). | Fixed v1.8.1: private addresses refused in production. DNS rebinding remains |
| D-05 | Without `DATA_KEY`, sealed secrets use a key derived from `JWT_SECRET`, so rotating `JWT_SECRET` breaks them. | Fixed v1.8.1: `DATA_KEY` required in production |
| D-06 to D-10 | `/health` doesn't check the database; shutdown has no deadline; uploads sit on local disk outside backups with no malware scan; no CI or Dockerfile; a job running over 10 minutes is re-queued and can run twice. | Fixed v1.8.1: DB health check, 15 s shutdown deadline, active PDFs rejected, CI and Dockerfile added, job heartbeat. Still open: malware scanner and upload backup at deploy |

**Security.** [security/threat-model.md](../security/threat-model.md) covers each trust boundary. [security/security-findings.md](../security/security-findings.md) lists the findings above by severity.

**Operations.** [operations/runbooks/](../operations/runbooks/README.md) has 10 runbooks: local setup, start and stop, migrate and seed, backup and restore, rotate secrets, jobs, GSP outage, notification outage, locked-out user, incident response. None has been rehearsed.

**Release.** [release/production-readiness-checklist.md](../release/production-readiness-checklist.md). Open blockers: penetration test, load and soak tests, a backup-restore drill, CI with dependency, secret and static scans, monitoring and alerts, rollback with feature flags and staged rollout, an accessibility and browser matrix, and pilots with a CA review. v1.11 closes the engineering ones. Pilots and the CA review are the owner's.
