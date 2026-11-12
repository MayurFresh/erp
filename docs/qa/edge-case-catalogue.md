# Edge-case catalogue

Every case from master plan section 11.2 (mandatory catalogue) and 11.4 (concurrency), checked against the code and tests on 2026-11-03 (v1.8, uncommitted tree).

How to read it:

- Status: Covered = a test we found exercises it. Partial = some code or a related test exists, but the case itself is not proven. Not covered = built, no test. N/A = the feature or vertical is not built yet.
- Evidence: `test file :: test title` for backend (`backend/test/`), `flutter:` for `test/`, or `path:line` for code. Where the title is cut, it is cut at the first words.
- Target: the release that should close it (v1.9 channels, v1.10 warehouse depth, v1.11 platform readiness, v1.12 HR, v1.13 manufacturing, Later).
- Cases that depend on marketplaces, webhooks or hardware are N/A until those exist. Where an internal analogue is tested, it is named.

Totals (176 cases): Covered 35, Partial 40, Not covered 28, N/A 73. Most N/A rows are marketplace, hardware and unbuilt-vertical cases.

## Authentication and permissions

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Expired access token | Partial | flutter: unit/api_client_test.dart :: refreshes once on TOKEN_EXPIRED and retries. Server mapping at `backend/src/auth/tokens.ts:33`, no backend test with an expired token | v1.11 |
| Revoked refresh token | Partial | platform.test.ts :: lists, revokes one and revokes the others. Refresh check on revoked session not asserted | v1.11 |
| Reused refresh token | Covered | api.test.ts :: rotates refresh tokens and ends all sessions when an old one is reused | done |
| User removed from tenant | Covered | robustness.test.ts :: rejects the old token once the user is deactivated; rejects a company the user has no access to | done |
| Role changed during active session | Partial | Memberships and permissions are reloaded on every request (`backend/src/app.ts:197`). No test changes a role mid-session | v1.11 |
| Cross-tenant ID substitution | Covered | api.test.ts :: never shows one business the data of another; enforces isolation in the database itself; p2p.test.ts :: another tenant's records are 404; o2c.test.ts :: hides another business order | done |
| Unauthorized branch access | Covered | api.test.ts :: limits a site supervisor to their site and hides costs; construction.test.ts :: keeps worker home-site and wage-site scopes independent | done |
| Privilege escalation | Covered | api.test.ts :: stops users from granting more access than they have; o2c.test.ts :: enforces permissions; p2p.test.ts :: needs permissions | done |
| Concurrent sessions | Covered | platform.test.ts :: lists, revokes one and revokes the others | done |
| Brute-force attempts | Covered | platform.test.ts :: locks after 10 failures, even for the right password, and an admin can unlock. Per-IP rate limit is switched off in tests (`authRateLimit: false`) so it is not tested | v1.11 for the rate limit |
| MFA recovery misuse | Partial | platform.test.ts :: sets up, enables, signs in with a code and a recovery code; stops an mfaToken after 5 wrong codes. Reusing one recovery code is not asserted | v1.11 |

## Multi-tenancy

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Tenant A reads Tenant B order | Covered | o2c.test.ts :: hides another business order; api.test.ts :: enforces isolation in the database itself | done |
| Tenant A exports Tenant B records | Partial | Exports run inside `withTenant` (`backend/src/db/database.ts:24`) so RLS applies. No export-specific cross-tenant test | v1.11 |
| Tenant A guesses file URL from Tenant B | Partial | Files are keyed `tenantId/id.ext` (`backend/src/modules/files.ts:82`) and served from the same record. construction.test.ts :: accepts real images and PDFs only, up to 10 MB, within the business. No explicit guess test | v1.11 |
| Cache collision across tenants | N/A | No cache layer exists | v1.11 if a cache is added |
| Search index cross-tenant leakage | N/A | No search index; search is SQL `ilike` under RLS | Later |
| Background job with missing tenant context | Partial | `jobs.tenant_id` is not null and handlers run in `withTenant(job.tenant_id)` (`backend/src/lib/jobs.ts:55`). platform.test.ts :: lists, retries a failed job. No test for a job with a bad tenant | v1.11 |
| Webhook mapped to wrong tenant | N/A | No inbound webhooks yet | v1.9 |
| Admin impersonation without audit | N/A | No impersonation feature. Design needed before support access exists | v1.11 |
| Tenant suspension and data export | Not covered | No suspend state or full-tenant export | v1.11 |
| Tenant deletion and retention | Not covered | `tenant_id` foreign keys cascade, but no retention policy or deletion flow | v1.11 |

## Commerce orders

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Duplicate order webhook | N/A | No webhooks. Internal analogue: o2c.test.ts :: dispatches once when the same request is repeated | v1.9 |
| Out-of-order webhook | N/A | Order state machine rejects bad moves: o2c.test.ts :: releases reservations on cancel and blocks illegal moves | v1.9 |
| Order updated after cancellation | Covered | o2c.test.ts :: releases reservations on cancel and blocks illegal moves (confirm and edit after cancel give 409 ILLEGAL_TRANSITION) | done |
| Partial cancellation | Not covered | Cancel is whole-order only | v1.10 |
| Partial shipment | Not covered | Dispatch is all-or-nothing. o2c.test.ts :: refuses to dispatch when picked and packed differ | v1.10 |
| Multi-package shipment | Not covered | One shipment per dispatch | v1.10 |
| Split order across warehouses | Not covered | One location per order | v1.10 |
| Marketplace order import timeout | N/A | No connectors | v1.9 |
| Provider returns malformed payload | N/A | No order connectors. GSP side: platform.test.ts :: seals provider credentials and maps provider failures to 502 and 503 | v1.9 |
| Unknown SKU mapping | N/A | No SKU mapping yet. Unknown barcode on scan is covered, see Warehouse scanning | v1.9 |
| Product mapping changed after order | N/A | No mapping. Order lines keep their own item and price (`backend/src/modules/sales-orders.ts:128`) | v1.9 |
| Customer address incomplete | Partial | Party and place-of-supply rules (`backend/src/modules/sales-orders.ts:87`); no address-completeness test | v1.9 |
| COD order | Partial | Shipment mode `cod` with `cod_amount` (`backend/src/modules/shipments.ts:32`). No test asserts COD handling | v1.9 |
| Prepaid order | Partial | Shipment mode `prepaid`, same code. Invoice and receipt flow is covered in o2c.test.ts :: runs the happy path from order to closed return | v1.9 |
| Fraud or cancelled order | Partial | Cancel releases stock (o2c.test.ts :: releases reservations on cancel). No fraud flag | v1.9 |
| Marketplace rate limit | N/A | No connectors | v1.9 |
| Provider outage | N/A | No order connectors. GSP outage is covered by platform.test.ts :: seals provider credentials and maps provider failures to 502 and 503 | v1.9 |
| Late order event after manual correction | N/A | No external events | v1.9 |

## Inventory

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Two channels sell the last unit at once | Covered | o2c.test.ts :: lets only one of two orders reserve the last unit; robustness.test.ts :: refuses a parallel stock issue that exceeds the balance. Channels themselves N/A | done |
| Two employees pick the same unit | Partial | o2c.test.ts :: rejects unknown and wrong barcodes, over picks and repeats a scan safely. No two-user race | v1.10 |
| Negative stock attempt | Covered | robustness.test.ts :: refuses a parallel stock issue that exceeds the balance; phase1.test.ts :: refuses to cancel a bill whose stock is already sold; `backend/src/modules/stock.ts:50` | done |
| Reservation expires during packing | Not covered | Reservations have no expiry; released on cancel or dispatch only | v1.10 |
| Reservation release repeated | Partial | o2c.test.ts :: releases reservations on cancel and blocks illegal moves (second action gives 409). No direct double-release call | v1.10 |
| Transfer partially received | Not covered | phase1.test.ts :: cancels a transfer in transit and a manual journal covers cancel only | v1.10 |
| Lost or damaged goods | Partial | Return dispositions restock, damaged, scrap (`backend/src/modules/sales-returns.ts:31`); p2p.test.ts :: tracks rejected quantity separately and asks for a reason. No write-off document | v1.10 |
| Stock count mismatch | Covered | p2p.test.ts :: scans, handles a movement during the count, and posts the variance; a variance above the threshold needs the approve permission | done |
| Unit conversion error | Not covered | One unit per item; no conversion factors | v1.10 |
| Decimal quantity | Partial | gst.test.ts :: handles fractional quantities and rates exactly. Stock quantities are `numeric(14,3)` (`001_init.sql:101`); no stock-specific decimal test | v1.10 |
| Batch expiry | N/A | Batches not built | v1.10 |
| FEFO allocation | N/A | Batches not built | v1.10 |
| Serial number duplicate | N/A | Serials not built | v1.10 |
| Return received without original order | Partial | Returns need a source document (credit notes take `invoiceId`); no test sends an orphan return | v1.10 |
| Return quantity exceeds sold quantity | Covered | o2c.test.ts :: refuses returns beyond what was sold; phase1.test.ts:80 (second credit note above the remainder) | done |
| Inventory sync delayed | N/A | No channel stock sync | v1.9 |
| Provider stock update rejected | N/A | No channel stock sync | v1.9 |
| Reconciliation detects drift | Partial | phase1.test.ts :: posts every document correctly and ties stock to the ledger. No scheduled drift check or replay invariant | v1.11 |

## Warehouse scanning

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Wrong barcode | Covered | o2c.test.ts :: rejects unknown and wrong barcodes, over picks and repeats a scan safely | done |
| Unknown barcode | Covered | Same test | done |
| Duplicate scan | Covered | Same test (repeat scan is safe) | done |
| Scan offline and sync later | N/A | No offline queue. Client reads connection errors as offline only: flutter: unit/api_client_test.dart :: connection errors and timeouts read as offline | v1.10 |
| Scanner disconnect | N/A | No scanner integration | v1.10 |
| Camera permission denied | N/A | Camera scanning not built | v1.10 |
| Damaged barcode | N/A | Manual entry by barcode text only | v1.10 |
| Wrong bin | N/A | Bins not built | v1.10 |
| Wrong variant | Not covered | No variant model; item mismatch is the wrong-barcode case | v1.10 |
| Quantity mismatch | Covered | o2c.test.ts :: refuses to dispatch when picked and packed differ | done |
| Serial number mismatch | N/A | Serials not built | v1.10 |
| Batch mismatch | N/A | Batches not built | v1.10 |
| Concurrent packing | Not covered | Pack is checked against picks, no two-user race test | v1.10 |
| Label printer unavailable | N/A | No label printing | v1.10 |
| Print succeeds but acknowledgement times out | N/A | No label printing | v1.10 |
| Employee loses permission during task | Partial | Permissions reloaded per request (`backend/src/app.ts:197`); no mid-task test | v1.10 |

## Returns and refunds

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Return initiated twice | Partial | o2c.test.ts :: refuses returns beyond what was sold stops a second return over the remainder; same-key retry in robustness.test.ts :: replays the stored response and creates nothing twice | v1.9 |
| Return cancelled after pickup | Not covered | No courier pickup state. Return statuses are requested, received, inspected, closed, cancelled (`sales-returns.ts:35`) | v1.9 |
| Partial return | Covered | o2c.test.ts :: refuses returns beyond what was sold (line quantities); phase1.test.ts:73 (credit note for part of an invoice) | done |
| Wrong item returned | Not covered | Inspection exists, no wrong-item test | v1.10 |
| Empty package | Not covered | No explicit case | v1.10 |
| Damaged item | Partial | Disposition `damaged` exists (`sales-returns.ts:31`); happy path in o2c.test.ts :: runs the happy path from order to closed return | v1.10 |
| Used item | Not covered | Disposition list has no used or refurbish option | v1.10 |
| Missing serial number | N/A | Serials not built | v1.10 |
| Return received at wrong warehouse | Not covered | Receiving location is not checked against the order | v1.10 |
| Refund initiated but provider times out | N/A | No payment provider or refund API | v1.9 |
| Refund succeeds but webhook is delayed | N/A | No payment provider | v1.9 |
| Refund duplicated | Partial | Credit notes cannot exceed the invoice (phase1.test.ts:80). No provider refund exists | v1.9 |
| Marketplace and ERP states disagree | N/A | No connectors | v1.9 |
| Restock before quality inspection | Covered | Disposition is set at inspection, after receipt (`sales-returns.ts:31`); o2c.test.ts :: runs the happy path from order to closed return | done |
| RTO mistaken for customer return | Partial | Return `type` is `customer_return` or `rto` (`sales-returns.ts:25`). No test compares their handling | v1.9 |

## Finance

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Duplicate invoice number | Covered | Gapless series locked until commit (`backend/src/lib/series.ts:23`), unique `(company_id, number)` (`002_accounting_and_documents.sql:139`); api.test.ts :: runs location → item → stock → party → invoice → cancel with correct GST and numbering | done |
| Duplicate payment webhook | N/A | No payment webhooks. API retries: robustness.test.ts :: replays the stored response and creates nothing twice | v1.9 |
| Partial payment | Covered | phase1.test.ts:66 (amountPaid 2000, amountDue 1540); phase1.test.ts :: validates allocations and keeps advances on the party | done |
| Overpayment | Covered | robustness.test.ts :: never over-allocates when two receipts race for one invoice; phase1.test.ts :: validates allocations and keeps advances on the party | done |
| Refund after period close | Partial | statutory.test.ts :: blocks posting and cancelling inside a locked period. No refund flow exists | v1.11 |
| Credit note | Covered | phase1.test.ts :: posts every document correctly and ties stock to the ledger; controls.test.ts :: defaults a credit note to its invoice cost centre | done |
| Currency rounding | Covered | gst.test.ts :: applies discount before tax and rounds the total to the rupee; sums many lines without floating-point drift; subcontracts.test.ts :: rounds half up in paise | done |
| Tax rule effective date changes | Covered | statutory.test.ts :: rejects 12% on goods today but accepts 5%, and 12% services; lets a business add a rate and protects system rows | done |
| Journal does not balance | Covered | `backend/src/accounting/journal.ts:41` throws, and the database checks at commit; construction.test.ts :: runs worker → attendance → draft → approved → paid with one balanced journal | done |
| Unauthorized journal posting | Partial | phase1.test.ts :: limits account pickers and reports by role; controls.test.ts :: tags manual journal lines and enforces costCentreRequired. No direct 403 test on manual journal | v1.11 |
| Concurrent posting | Covered | robustness.test.ts :: lets exactly one of two parallel cancels win; never over-allocates when two receipts race for one invoice | done |
| Reconciliation mismatch | Covered | compliance.test.ts :: imports 2B and reconciles matched, mismatch and missing both ways; imports, auto-matches and creates an entry (bank) | done |
| Bank import duplicates | Partial | Duplicate lines skipped on import (`backend/src/modules/bank.ts:251`); compliance.test.ts :: imports, auto-matches and creates an entry. Re-import not asserted by title | v1.11 |
| Deleted or changed customer tax details | Not covered | No test edits GSTIN after invoicing | v1.11 |
| Negative or zero quantities and discounts | Covered | robustness.test.ts :: survives hostile ids, bodies and queries on every route (negative and tiny values); turns out-of-range totals into 400, not 500 | done |

## Restaurant

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Table assigned twice | N/A | Restaurant vertical not built | Later |
| Menu item unavailable after order | N/A | Not built | Later |
| Kitchen printer offline | N/A | Not built | Later |
| KOT duplicated | N/A | Not built | Later |
| Split bill | N/A | Not built | Later |
| Merge tables | N/A | Not built | Later |
| Partial payment | N/A | Not built (invoice partial payment is covered under Finance) | Later |
| Refund after shift close | N/A | Not built | Later |
| Recipe stock insufficient | N/A | Not built | Later |
| Modifier price mismatch | N/A | Not built | Later |
| Delivery order duplicated | N/A | Not built | Later |
| Kitchen station unavailable | N/A | Not built | Later |
| Offline POS transaction sync conflict | N/A | Not built | Later |

## Manufacturing

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| BOM cycle | N/A | No BOM | v1.13 |
| Missing component | N/A | No BOM | v1.13 |
| Substitute component | N/A | No BOM | v1.13 |
| Scrap above planned quantity | N/A | No production orders | v1.13 |
| Partial production | N/A | No production orders | v1.13 |
| Machine downtime | N/A | No production orders | v1.13 |
| Work order cancellation after material issue | N/A | Production work orders not built. Construction subcontract work orders are a different feature | v1.13 |
| Rework loop | N/A | Not built | v1.13 |
| Quality failure | N/A | Not built | v1.13 |
| Batch recall | N/A | Batches not built | v1.13 |
| Cost variance | N/A | Not built. Purchase price variance exists: p2p.test.ts :: price variance blocks, override needs permission and posts to variance | v1.13 |
| Concurrent material reservation | N/A | Not built. Sales stock reservations are tested: o2c.test.ts :: lets only one of two orders reserve the last unit | v1.13 |

## Hotel and booking

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Double booking | N/A | Hotel vertical not built. Real-estate unit bookings are separate | Later |
| Booking overlap at timezone boundary | N/A | Not built | Later |
| Payment timeout | N/A | Not built | Later |
| Cancellation fee | N/A | Not built | Later |
| No-show | N/A | Not built | Later |
| Room out of service | N/A | Not built | Later |
| Partial stay | N/A | Not built | Later |
| Early check-in or late checkout | N/A | Not built | Later |
| Channel manager duplicate booking | N/A | Not built | Later |
| Rate plan mismatch | N/A | Not built | Later |

## Media and documents

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Large file | Covered | construction.test.ts :: accepts real images and PDFs only, up to 10 MB, within the business; robustness.test.ts :: answers 413 above 1 MB | done |
| Malicious file | Partial | Type is sniffed from magic bytes (`backend/src/modules/files.ts:15`); no malware scan | v1.11 |
| Unsupported codec | N/A | No audio or video handling | Later |
| Duplicate upload | Not covered | No content hash or de-duplication | v1.11 |
| Interrupted upload | Not covered | Single multipart request, no resume | v1.11 |
| Version conflict | Not covered | No document versioning | Later |
| Unauthorized download | Partial | Download resolves the record under RLS (`files.ts:108`); no direct 404 test for another tenant or role | v1.11 |
| Expired licence | N/A | No media licensing | Later |
| Asset deleted while referenced | Partial | robustness.test.ts :: maps a foreign-key violation to IN_USE on delete and to 400 on create | v1.11 |
| Storage quota exceeded | Not covered | No quotas; entitlements are planned | v1.11 |

## General platform

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Empty values | Covered | api.test.ts :: clears optional fields with null or "" and tolerates empty edits; flutter: unit/validators_test.dart :: empty optional values pass | done |
| Null values | Covered | api.test.ts :: clears optional fields with null or "" and tolerates empty edits | done |
| Very long strings | Partial | Database length errors map to 400 (`backend/src/app.ts:151`); robustness.test.ts :: survives hostile ids, bodies and queries on every route | v1.11 |
| Unicode and emoji | Partial | robustness.test.ts :: survives hostile ids, bodies and queries on every route (surrogate and NUL text). No round-trip test of emoji | v1.11 |
| RTL language | Not covered | No localisation layer | Later |
| DST and timezone changes | Partial | Dates are IST calendar dates (`backend/src/lib/dates.ts`); gst.test.ts :: validates calendar dates; labels Indian financial years. India has no DST | v1.11 |
| Large CSV import | Partial | controls.test.ts :: checks permissions, empty files and size. No large-file timing | v1.11 |
| CSV formula injection | Partial | Guard prefixes `=`, `+`, `@` (`backend/src/lib/csv.ts:8`). No test, and `-`, tab and CR are not guarded (see defect register D-03) | v1.11 |
| PDF generation failure | Partial | flutter: unit/invoice_pdf_test.dart covers generation; no failure path | v1.11 |
| Email or SMS provider outage | Partial | Outbox with job retry and backoff (`backend/src/lib/jobs.ts:44`); platform.test.ts :: keeps in-app rows, preferences and the outbox; lists, retries a failed job. No email-driver failure test | v1.11 |
| Queue backlog | Not covered | No load or backlog test | v1.11 |
| Database failover | Not covered | Single PostgreSQL, no failover drill | v1.11 |
| Cache outage | N/A | No cache | v1.11 if added |
| Network packet loss | Partial | flutter: unit/api_client_test.dart :: connection errors and timeouts read as offline | v1.11 |
| Browser refresh during transaction | Covered | robustness.test.ts :: replays the stored response and creates nothing twice; answers 409 REQUEST_IN_PROGRESS while the first request is still running | done |
| Duplicate form submission | Covered | flutter: widget/busy_guard_test.dart; robustness.test.ts :: replays the stored response and creates nothing twice | done |
| Stale client version | Not covered | No client version header or minimum-version check | v1.11 |
| Subscription expires mid-operation | N/A | No subscriptions yet | v1.11 |
| Usage limit reached during bulk job | N/A | No usage limits yet | v1.11 |

## Concurrency (section 11.4)

| Case | Status | Evidence | Target |
| --- | --- | --- | --- |
| Last item sold by two marketplaces | Covered | Internal analogue: o2c.test.ts :: lets only one of two orders reserve the last unit. Marketplaces N/A | v1.9 for channels |
| Same order imported by webhook and polling | N/A | No importers | v1.9 |
| Two employees picking the same order | Not covered | No two-user pick test | v1.10 |
| Two managers approving the same request | Partial | controls.test.ts :: walks multi-level approvals in order and refuses the wrong approver; stops one person approving two levels. Not run in parallel | v1.11 |
| Payment webhook and user retry together | Partial | robustness.test.ts :: answers 409 REQUEST_IN_PROGRESS while the first request is still running. No webhook | v1.9 |
| Reservation expiry while payment is processing | Not covered | No reservation expiry | v1.10 |
| Stock transfer and stock count at the same time | Partial | p2p.test.ts :: scans, handles a movement during the count, and posts the variance (movement, not transfer) | v1.10 |
| Two edits to the same product or listing | Not covered | No version or ETag check on updates | v1.11 |
| Duplicate job execution after worker crash | Partial | `jobs_claim` re-queues jobs running over 10 minutes and uses `for update skip locked` (`010_enterprise.sql:433`). No crash test; handlers must be idempotent | v1.11 |
