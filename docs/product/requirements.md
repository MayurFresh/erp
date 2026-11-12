# Requirements

Scope: full detail for the v1.8 commerce core (built, release checks pending) and the v1.9 Channels release (planned). Later releases are at epic level at the end.

How to read it:
- v1.8 text describes the code on 2026-11-03. Sources are the migrations `backend/src/db/migrations/013_o2c.sql` and `014_p2p.sql`, the modules named in each feature, and the contract in `docs/API.md` (section "v1.8 additions").
- v1.9 text is planned (v1.9). Nothing in it exists in code.
- Story IDs (US-...) are in `user-stories.md`; acceptance criteria in `acceptance-criteria.md`. Personas P1 to P8 are in `personas.md`.
- Non-functional limits that apply to every feature: quantities have 3 decimals and money 2 (`backend/src/lib/numbers.ts`); request body at most 1 MB (`app.ts` `bodyLimit`); serialization failures and deadlocks are retried once, then `409 TRY_AGAIN` (`db/database.ts`); every write is audited (`modules/audit.ts`); every list is `{ data, total }`; creates accept `Idempotency-Key` (`backend/src/lib/idempotency.ts`). No latency or throughput target is set yet. Load tests are planned (v1.11).

## Part 1. v1.8 order to cash

### F1 Sales order with stock reservation

| Field | Content |
| --- | --- |
| User problem | Two sales people promise the same last unit. Invoices are raised before stock is checked. |
| Persona | P5 sales executive, P2 ops manager |
| Outcome | Confirmed orders hold stock. Available stock for a new order excludes what is held. |
| Functional | Create a draft order with 1 to 200 lines at one location (`POST /sales-orders`). Edit only in draft; `lines` replaces all lines. Confirm reserves every line in full or fails the whole order with a list of shortages (`INSUFFICIENT_STOCK`). Lines marked `allow_backorder` reserve what is available. `POST /sales-orders/:id/reserve` retries reservation for unreserved quantity. Cancel all or part of the open quantity and release reservations. Close an order. Availability query (`GET /sales-orders/availability`). Only stock-tracked items allowed. `external_ref` is unique per company and source (`DUPLICATE_ORDER`). |
| Non-functional | Reservation and availability run under a per-item advisory lock, sorted to avoid deadlocks (`accounting/costing.ts` `lockItems`). Order and lines are row-locked on every state change (`modules/o2c-common.ts`). Available = on hand at the location minus active reservations (`sales-orders.ts` `availableOf`). |
| Permissions | `sales_orders.view`, `sales_orders.manage`. A caller outside the order's location gets 404 (`lockOrder`). |
| Entities | `sales_orders`, `sales_order_lines`, `sales_order_events`, `stock_reservations` |
| State transitions | `draft` to `confirmed`; `confirmed` to `picking` to `packed` to `partially_dispatched` or `dispatched` to `closed`; `cancelled` from open states. Status is derived from line quantities and open pick lists by `refreshStatus`. Draft, cancelled and closed are never overwritten by it. |
| Failure scenarios | Shortage on confirm: no reservation is made for any line. Two confirms race for the last unit: one wins, one gets `INSUFFICIENT_STOCK`. Cancel while an open pick list holds picks: `HAS_OPEN_PICK_LIST`. Edit after confirm: `ILLEGAL_TRANSITION`. |
| Dependencies | Items, parties, locations, stock ledger (B7), numbering (`backend/src/lib/series.ts`, code SO) |
| Priority | P0 (release exit check 1) |

### F2 Pick lists and scan picking

| Field | Content |
| --- | --- |
| User problem | Pickers walk with paper and pick the wrong item. |
| Persona | P3 warehouse picker, P2 |
| Outcome | One list covers up to 50 orders at a location. Every unit picked is confirmed by a scan. |
| Functional | Create a pick list from orders (`POST /pick-lists`). Scan by barcode or SKU, or choose the item by hand, with a client `scanId`. Scan allocates to order lines. Complete the list; short picks stay reserved and can go on a new list. Cancel only if nothing was picked (`HAS_PICKS`). |
| Non-functional | Scan is idempotent by `(company, kind, list id, scanId)` (`scan_events` unique key). A repeated scan returns the first result with `duplicate: true`. Failed scans are not stored. |
| Permissions | `fulfilment.manage` to act; `sales_orders.view` to read |
| Entities | `pick_lists`, `pick_list_lines`, `scan_events`, `items.barcode` (unique per company) |
| State transitions | Pick list: `open` to `completed` or `cancelled`. |
| Failure scenarios | `UNKNOWN_BARCODE`, `WRONG_ITEM`, `OVER_PICK`, closed list `ILLEGAL_TRANSITION`, order not pickable, order at another location (400). |
| Dependencies | F1, items barcode (`012_commerce.sql`), numbering (code PCK) |
| Priority | P0 |

### F3 Pack with scan check

| Field | Content |
| --- | --- |
| User problem | Items picked are packed in the wrong parcel or short. |
| Persona | P3 |
| Outcome | Packed quantity can never exceed picked, and dispatch requires picked = packed. |
| Functional | Pack scans (`POST /sales-orders/:id/pack-scans`) add to packed quantity. Manual pack by line (`POST /sales-orders/:id/pack`). |
| Non-functional | Idempotent by `scanId`. DB check `qty_dispatched <= qty_packed <= qty_picked` on `sales_order_lines`. |
| Permissions | `fulfilment.manage` |
| Entities | `sales_order_lines.qty_packed`, `scan_events` (kind `pack`) |
| State transitions | Order `picking` to `packed` when packed covers all reserved quantity. |
| Failure scenarios | `OVER_PACK`, `WRONG_ITEM`, `UNKNOWN_BARCODE`. |
| Dependencies | F2 |
| Priority | P0 |

### F4 Dispatch to invoice and shipment

| Field | Content |
| --- | --- |
| User problem | Dispatch, invoice and stock update happen in three places and can disagree or run twice. |
| Persona | P2, P4 accountant |
| Outcome | One action creates the GST invoice, the stock-out and the shipment, once. |
| Functional | `POST /sales-orders/:id/dispatch` with courier, AWB, mode (`prepaid` or `cod`), COD amount, invoice date. Ships all packed and undispatched quantity. Consumes reservations, raises the invoice through the standard invoice function (stock out, journal, GST), creates the shipment, its lines and history, and logs an order event. |
| Non-functional | One transaction. Item locks held (`lockItems`). `Idempotency-Key` replays the stored response; `shipments.dispatch_key` is unique per company as a second guard. `shipments.invoice_id` is unique. |
| Permissions | `fulfilment.manage` |
| Entities | `shipments`, `shipment_lines`, `shipment_status_history`, `invoices`, `invoice_lines`, `stock_moves` (`ref_type invoice`), `journal_entries` |
| State transitions | Order to `partially_dispatched` or `dispatched`. Shipment starts `booked`. |
| Failure scenarios | `NOTHING_TO_DISPATCH`, `PACK_INCOMPLETE` (picked differs from packed), prepaid with a COD amount (400), order not in a fulfillable state. A duplicate request must not double-post stock (release exit check 2). |
| Dependencies | F1 to F3, invoices (B4), books lock, numbering (SHP) |
| Priority | P0 |

### F5 Shipment tracking and RTO

| Field | Content |
| --- | --- |
| User problem | Undelivered parcels return and nobody updates stock or the customer account. |
| Persona | P2 |
| Outcome | Shipment status is recorded; an RTO creates the return record automatically. |
| Functional | Update status (`POST /shipments/:id/status`) with note, courier, AWB. Edit courier, AWB, notes until the shipment is final. List and filter. |
| Non-functional | Status history is append-only (`shipment_status_history`). Status updates are manual in v1.8; courier tracking feeds are planned (v1.10). |
| Permissions | `fulfilment.manage`, `sales_orders.view` |
| Entities | `shipments`, `shipment_status_history`, `sales_returns` (type `rto`) |
| State transitions | `booked` to `in_transit` to `delivered`; `in_transit` to `rto_initiated` to `rto_delivered`; `in_transit` or `rto_initiated` to `lost`; `rto_initiated` to `delivered`. |
| Failure scenarios | Any other move gives `ILLEGAL_TRANSITION`. A second RTO for the same shipment is blocked by a partial unique index (`sales_returns_rto_uq`). |
| Dependencies | F4, F6 |
| Priority | P0 |

### F6 Returns and RTO with inspection

| Field | Content |
| --- | --- |
| User problem | Returned goods are restocked without a check, or never restocked. Credit notes are raised by hand. |
| Persona | P3, P2, P4 |
| Outcome | Returned units are inspected, restocked only if fit, and a credit note is created from the received quantity. |
| Functional | Request a return by order or invoice (`POST /sales-returns`), type `customer_return` or `rto`. Receive (full or part). Inspect each received line with a disposition `restock`, `damaged` or `scrap`. Close creates the credit note through the existing credit-note function. Cancel frees the quantity. |
| Non-functional | Returnable quantity = dispatched or invoiced minus already returned, counting open returns. Only `restock` units create a stock move, at the cost they left at. `damaged` and `scrap` get the credit note but no stock move; their cost stays in cost of goods sold. |
| Permissions | `returns.manage`, `sales_orders.view` |
| Entities | `sales_returns`, `sales_return_lines`, `credit_notes`, `stock_moves` (`ref_type credit_note`) |
| State transitions | `requested` to `received` to `inspected` to `closed`; `cancelled` from the first three. |
| Failure scenarios | `RETURN_EXCEEDS_SOLD`; inspect without a disposition on a received line (400); close before inspection (`ILLEGAL_TRANSITION`). |
| Dependencies | F4, credit notes (B4), invoices |
| Priority | P0 |

## Part 2. v1.8 procure to pay

### F7 Purchase order with approval

| Field | Content |
| --- | --- |
| User problem | Bills are entered with no prior commitment, so price and quantity cannot be checked. |
| Persona | P6 purchase manager, P1 owner |
| Outcome | POs commit price and quantity; large POs wait for an approver. |
| Functional | Create, preview totals, edit (draft only), submit, send, cancel (`/purchase-orders`). Submit goes through the approval engine when a rule matches the total (docType `purchase_order`), else straight to approved. P2P settings: receipt tolerance %, price tolerance %, count approval value (`GET/PUT /p2p/settings`). |
| Non-functional | GST computed with the same engine as bills. Rejected or cancelled approval returns the PO to draft. |
| Permissions | `purchase_orders.view`, `purchase_orders.manage`; approvers use `approvals.*` |
| Entities | `purchase_orders`, `purchase_order_lines`, `approval_requests` |
| State transitions | `draft` to `approved` or `pending_approval`; `approved` to `sent`; to `partially_received`, `received`, `closed`; `cancelled`. |
| Failure scenarios | Edit outside draft: `NOT_EDITABLE`. Cancel with receipts: only the remaining quantity is cancelled. Requester approving own request: refused by the engine. |
| Dependencies | Approvals (A6), parties, items, numbering (PO) |
| Priority | P0 |

### F8 Goods receipt (GRN)

| Field | Content |
| --- | --- |
| User problem | Stock is counted when the bill arrives, not when goods arrive. |
| Persona | P3, P6 |
| Outcome | Stock and inventory value rise at receipt. Unbilled receipts show as a liability (GRNI). |
| Functional | Create a GRN against a PO with accepted and rejected quantities and a reason for rejection. Partial receipts. Rejected goods never enter stock and can be received again. Cancel a GRN. |
| Non-functional | Accepted quantity only moves stock (`ref_type grn`). Journal: debit Inventory, credit Goods Received Not Invoiced (account 2140). Over-receipt blocked beyond `po_receipt_tolerance_pct`. Item locks held. |
| Permissions | `grn.manage` |
| Entities | `goods_receipts`, `goods_receipt_lines`, `stock_moves`, `journal_entries` |
| State transitions | GRN `posted` or `cancelled`. PO moves to `partially_received` or `received`. |
| Failure scenarios | Over-receipt; cancel after stock is gone; cancel when billed. |
| Dependencies | F7, stock ledger |
| Priority | P0 |

### F9 Bill matching (PO, GRN, bill)

| Field | Content |
| --- | --- |
| User problem | Bills are paid at a price or quantity nobody agreed. Stock and inventory are counted twice. |
| Persona | P4, P6 |
| Outcome | A bill that links to receipt lines posts no second stock move. Price differences are caught. |
| Functional | A bill line carries `grnLineId`. Posting clears GRNI and posts any price difference to Purchase Price Variance (account 5110). Over-billing blocked. Price beyond `po_price_tolerance_pct` blocks unless `acceptVariance` is sent by a caller with `purchases.override`. Bill cancel releases the receipt. |
| Non-functional | The last unit billed clears the exact remaining GRN value so GRNI nets to zero. Weighted-average cost is not changed by variance. |
| Permissions | `purchases.create`, `purchases.override` |
| Entities | `purchases`, `purchase_lines` (`grn_line_id`, `grni_value`), `goods_receipt_lines.billed_qty`, `cleared_value` |
| State transitions | PO `received` to `closed` when bills cover all received units. |
| Failure scenarios | Over-billing; vendor or location mismatch; price variance without override. |
| Dependencies | F8, purchases (B6) |
| Priority | P0 (release exit check 3) |

### F10 Reorder suggestions

| Field | Content |
| --- | --- |
| User problem | Reordering depends on memory. |
| Persona | P6, P2 |
| Outcome | Items at or below reorder level are listed with last vendor and rate; draft POs are created by vendor. |
| Functional | `GET /reorder-suggestions`, `POST /reorder-suggestions/purchase-orders` with up to 200 selections. |
| Non-functional | Suggestion uses stock on hand per location. Forecasting is out of scope. |
| Permissions | `purchase_orders.view`, `purchase_orders.manage` |
| Entities | `items` reorder fields, `purchase_orders` |
| State transitions | Creates POs in `draft`. |
| Failure scenarios | Item with no vendor history needs `partyId`. |
| Dependencies | F7 |
| Priority | P1 |

### F11 Stock counts

| Field | Content |
| --- | --- |
| User problem | Stock is corrected by manual adjustments with no count trail. |
| Persona | P3, P2, P4 |
| Outcome | A snapshot, scans, and a posted variance with an approval above a threshold. |
| Functional | Open a count for a location (all items or a selection). Scan items. Post variances. Cancel. Uncounted lines can be zeroed. Gains post to income. |
| Non-functional | Movement during the count is handled: variance is computed against expected stock at post time. Post runs under a per-location advisory lock. Variance value hidden without `items.view_cost`. |
| Permissions | `stock_counts.manage`; `stock_counts.approve` above `count_approval_value` |
| Entities | `stock_counts`, `stock_count_lines`, `stock_count_scans`, `stock_moves` (`ref_type stock_count`) |
| State transitions | `open` to `posted` or `cancelled`. |
| Failure scenarios | Variance above threshold without approve permission; scan outside a selected scope. |
| Dependencies | Items barcode, stock ledger |
| Priority | P1 |

## Part 3. v1.9 Channels (planned)

All features below are planned (v1.9). Design basis: `docs/architecture/integration-architecture.md`. Research: `docs/research/commerce-ops.md` §3 to §4, `docs/research/ecommerce-marketplaces.md` §8. Owner actions for access are in plan §7.

Hooks already in v1.8: `sales_orders.source` accepts `manual`, `csv`, `channel`; `external_ref` is unique per `(company, source, external_ref)` (`013_o2c.sql`). `sales_orders` has no channel id yet.

### F12 Connector contract and registry

| Field | Content |
| --- | --- |
| User problem | Every channel integration is custom, so each new one is a project. |
| Persona | P1, P2 |
| Outcome | A channel is one adapter file plus one registration line, as with the GSP adapter. |
| Functional | A registry of adapters with id, capabilities, credential fields, `ping`. A per-company connection record with encrypted credentials. Status model from master plan §7.4. A connection is `connected` only after a successful capability check, not on saving credentials. |
| Non-functional | Credentials sealed with `DATA_KEY` (`backend/src/lib/crypto.ts`). No provider call outside an adapter. Calls time out and retry transient errors only. |
| Permissions | New: `channels.manage`, `channels.view` (planned) |
| Entities | `channel_connections`, `channel_credentials` (planned names) |
| State transitions | Master plan §7.4: planned, researching, access requested, sandbox available, development, internal testing, partner certification, production enabled, degraded, suspended, deprecated. |
| Failure scenarios | Bad credentials: connection stays not connected with a reason. Provider outage: `degraded`. |
| Dependencies | Job worker, encryption, F13 |
| Priority | P0 for v1.9 |

### F13 Webhook inbox with signature check and dedupe

| Field | Content |
| --- | --- |
| User problem | Replayed or forged events create duplicate or fake orders. |
| Persona | P2 |
| Outcome | Replaying the same event changes nothing (release exit check). |
| Functional | A public endpoint per provider verifies the signature, stores the raw payload with a unique provider event id, answers fast, and enqueues processing. Failed processing retries then goes to a dead-letter list with replay. |
| Non-functional | Signature check before any parsing. Unique key `(connection, provider event id)`. Payload retention limit. Tenant is resolved from the connection, never from the body. |
| Permissions | Endpoint is unauthenticated but signature-gated. Replay needs `channels.manage`. |
| Entities | `webhook_events` (planned) |
| State transitions | `received` to `processed`, `failed`, `dead`. |
| Failure scenarios | Bad signature: 401, nothing stored beyond a counter. Duplicate: 200, no new processing. Unknown connection: 404. |
| Dependencies | F12, jobs table |
| Priority | P0 |

### F14 CSV order import with SKU mapping

| Field | Content |
| --- | --- |
| User problem | Most channels have no API access. Sellers download a file. |
| Persona | P2, P5 |
| Outcome | Orders from any channel enter as sales orders. |
| Functional | Upload orders CSV with a saved header mapping per channel. Map channel SKU to an item, or to several items (bundle with quantities). Unmapped SKUs go to a fix list. Orders are created as sales orders with `source csv` and the channel order id as `external_ref`. |
| Non-functional | Re-importing the same file changes nothing (unique on external ref). Preview before commit, as the existing import engine does (`modules/imports.ts`). |
| Permissions | `imports.run`, `channels.manage` |
| Entities | `channel_listings` (channel SKU to item), `listing_components`, `sales_orders` |
| State transitions | Orders start `draft` or `confirmed` by channel setting. |
| Failure scenarios | Unmapped SKU; negative or zero quantity; order already exists (`DUPLICATE_ORDER` is skipped, not failed). |
| Dependencies | F1, import engine |
| Priority | P0 |

### F15 Shopify and WooCommerce adapters

| Field | Content |
| --- | --- |
| User problem | D2C stores re-key orders and stock. |
| Persona | P2, P5 |
| Outcome | Orders flow in by webhook with polling as a fallback; stock flows out. |
| Functional | OAuth or key auth, order pull with cursor, webhook registration, order normalisation into sales orders, cancellations and refunds mapped to existing cancel and return flows. |
| Non-functional | Rate limits respected per provider. Shopify protected customer data needs access approval (research §3). |
| Permissions | `channels.manage` |
| Entities | F12 and F13 tables |
| State transitions | Per F12 status model. |
| Failure scenarios | Rate limit (back off), token revoked (`suspended`), out-of-order events. |
| Dependencies | F12 to F14; owner action: development store and test site (plan §7 item 2) |
| Priority | P0 |

### F16 Stock sync to channels

| Field | Content |
| --- | --- |
| User problem | Overselling on channels. |
| Persona | P2 |
| Outcome | Available stock is pushed per channel listing. |
| Functional | On stock change, enqueue a push per mapped listing, with a per-channel buffer and a manual full resync. |
| Non-functional | Pushes are coalesced. Quantity pushed is available (on hand minus reserved), the same figure as `GET /sales-orders/availability`. |
| Permissions | `channels.manage` |
| Entities | `channel_listings`, `jobs` |
| State transitions | Push `queued`, `done`, `failed`. |
| Failure scenarios | Provider rejects: retried, then dead-lettered. |
| Dependencies | F12, F14 |
| Priority | P1 |

### F17 Settlement import and posting

| Field | Content |
| --- | --- |
| User problem | Marketplace payouts do not match orders; fees and TCS are unknown. |
| Persona | P4, P1 |
| Outcome | A settlement file posts one balanced journal, once. |
| Functional | Import a settlement CSV with a line-type alias table. Match lines to orders and returns. Post fees, GST on fees, TCS and TDS receivables, refunds and reserve holds to the ledger. Show variance per order. |
| Non-functional | Posting keyed by `(channel, settlement id, line index)`. Money in paise internally for settlement lines (research §8.2). Unbalanced settlements cannot post. Locked periods block posting. TCS and TDS are never mapped to expense (research §8.5). |
| Permissions | `settlements.manage`, `accounts.journal` (planned) |
| Entities | `settlements`, `settlement_lines`, `journal_entries` |
| State transitions | `imported`, `matched`, `posted`, `unbalanced`. |
| Failure scenarios | Re-import; unbalanced file; inactive channel; locked period. |
| Dependencies | F12, F14, ledger. Needs chartered accountant review of postings (plan §7 item 5). |
| Priority | P0 |

### F18 Connector health page

| Field | Content |
| --- | --- |
| User problem | Nobody knows a channel stopped syncing. |
| Persona | P2, P1 |
| Outcome | One page lists each connection, status, last success, backlog, dead letters. |
| Functional | Status per master plan §7.4, last poll time, queue depth, error counts, replay action. Notification on `degraded`. |
| Non-functional | Reads job and inbox tables only. |
| Permissions | `channels.view` |
| Entities | F12, F13 tables, `notifications` |
| State transitions | Status changes written to audit log. |
| Failure scenarios | Health check itself fails: shown as unknown, not green. |
| Dependencies | F12, F13 |
| Priority | P1 |

### F19 Amazon and Flipkart adapters

Planned (v1.9), only after the owner holds working access (plan §7 item 1). Until then the status is "access requested" and CSV import (F14) is the route. Same contract as F12. Priority P2 for the release.

## Part 4. Later releases (epic level)

| Release | Epic | Source |
| --- | --- | --- |
| v1.10 Warehouse depth | Bins; batches and expiry with FEFO; serial numbers; camera scanning; offline scan queue with explicit conflict rules; labels and manifests; courier aggregator adapter with NDR status | plan §4; research commerce-ops §4 |
| v1.11 Platform readiness | OpenAPI from zod schemas; CI; Docker; OpenTelemetry; backup and restore drill; load test; property tests (journals balance, stock replay); module entitlements and plans; API keys and outbound webhooks | plan §4 |
| v1.12 HR and payroll | From `docs/research/payroll-hr.md` | plan §4 |
| v1.13 Manufacturing | BOM, MRP, production orders, job work, quality checks | plan §4 |
| Later | Retail POS, B2B portal, restaurant, hospitality, AI assistant with tool allowlist and approvals, multi-currency | plan §4; master plan §J |
