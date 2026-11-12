# Acceptance criteria

Given/When/Then, keyed to the IDs in `user-stories.md`. For v1.8, the "Test" line names the existing vitest case in `backend/test/o2c.test.ts` or `backend/test/p2p.test.ts` that covers it, or says "no test" where none is visible. v1.9 criteria are planned (v1.9); no tests exist.

## v1.8 order to cash

### US-O2C-001
- Given a customer and a stock-tracked item, when a sales executive posts a sales order with a location and 1 to 200 lines, then the order is created in `draft` with a number from the `SO` series and no stock is reserved.
- Given an item that does not track stock, when it is on an order line, then the API answers 400.
- Test: `o2c.test.ts` "runs the happy path from order to closed return".

### US-O2C-002
- Given 10 units on hand, when an order for 4 is confirmed, then `qty_reserved` is 4 and available stock for the item at that location is 6.
- Given 3 units available, when an order line for 5 without backorder is confirmed, then the response is 409 `INSUFFICIENT_STOCK` with `details.shortages` and no line on that order is reserved.
- Test: happy path, and "lets only one of two orders reserve the last unit".

### US-O2C-003
- Given 1 unit available and two draft orders for 1 unit, when both are confirmed at once, then exactly one succeeds and the other gets `INSUFFICIENT_STOCK`.
- Test: "lets only one of two orders reserve the last unit". Release exit check 1.

### US-O2C-004
- Given a line with `allowBackorder` and 2 of 5 available, when the order is confirmed, then 2 are reserved and the order is confirmed.
- Given stock arrives, when `POST /sales-orders/:id/reserve` is called, then the open unreserved quantity is reserved up to what is available.
- Test: no dedicated test visible for backorder lines; check before release.

### US-O2C-005
- Given a confirmed order with reservations, when it is cancelled, then active reservations become `released` and available stock returns.
- Given an open pick list holds picks for the order, when cancel is requested, then 409 `HAS_OPEN_PICK_LIST`.
- Test: "releases reservations on cancel and blocks illegal moves".

### US-O2C-006
- Given 1 to 50 pickable orders at one location, when a pick list is created, then it is `open` with one line per order line.
- Given an order at another location, when included, then 400.
- Given an order that is not confirmed, when included, then 409 `ILLEGAL_TRANSITION`.
- Test: happy path.

### US-O2C-007
- Given an open pick list and an item barcode, when a scan with a new `scanId` is posted, then `qty_picked` rises by the scanned quantity and the order moves to `picking`.
- Test: happy path.

### US-O2C-008
- Given a scan already accepted, when the same `scanId` is posted again, then the response repeats the first result with `duplicate: true` and no quantity changes.
- Test: "rejects unknown and wrong barcodes, over picks and repeats a scan safely".

### US-O2C-009
- Given a code not on any item, then 400 `UNKNOWN_BARCODE`. Given an item not on the list, then 400 `WRONG_ITEM`. Given more than the list needs, then 400 `OVER_PICK` with `remaining`.
- Given any failed scan, then no scan event is stored.
- Test: same case as US-O2C-008.

### US-O2C-010
- Given a list with short picks, when it is completed, then status is `completed` and the short quantity stays reserved for a new list.
- Test: no dedicated test visible.

### US-O2C-011
- Given 3 picked, when 3 pack scans are posted, then `qty_packed` is 3. When a fourth is posted, then 400 `OVER_PACK`.
- Given all reserved quantity packed, then the order status is `packed`.
- Test: happy path.

### US-O2C-012
- Given picked equals packed on every shipping line, when dispatch is posted with an `Idempotency-Key`, then one invoice, one shipment (status `booked`) and the stock-out exist, and reservations are `consumed`.
- Given the same request repeated with the same key, then the stored response is returned with `Idempotent-Replayed: true` and stock is posted once.
- Test: "dispatches once when the same request is repeated". Release exit check 2.

### US-O2C-013
- Given picked differs from packed, when dispatch is requested, then 409 `PACK_INCOMPLETE`. Given nothing packed, then 409 `NOTHING_TO_DISPATCH`.
- Test: "refuses to dispatch when picked and packed differ".

### US-O2C-014
- Given mode `cod` with no amount, then the shipment COD amount is the invoice total. Given mode `prepaid` with an amount above 0, then 400.
- Test: no dedicated test visible.

### US-O2C-015
- Given a `booked` shipment, when status `in_transit` is posted, then a history row is added. Given `booked` to `delivered`, then 409 `ILLEGAL_TRANSITION`.
- Test: happy path covers the valid path; invalid moves are covered under "blocks illegal moves" for orders only. Shipment illegal moves: no test visible.

### US-O2C-016
- Given an `in_transit` shipment moved to `rto_initiated` then `rto_delivered`, then a return of type `rto` in `requested` exists with quantity shipped minus already returned.
- Given the same shipment reaches `rto_delivered` again, then no second RTO return is created (unique index).
- Test: no dedicated test visible for RTO.

### US-O2C-017
- Given 2 units dispatched, when a return for 3 is requested, then 400 `RETURN_EXCEEDS_SOLD` with `returnable` 2. Open returns count against the limit.
- Test: "refuses returns beyond what was sold".

### US-O2C-018
- Given a `requested` return, when it is received then inspected with a disposition on every received line, then status is `inspected`.
- Given a received line with no disposition, when inspect is posted, then 400.
- Test: happy path.

### US-O2C-019
- Given an inspected return with 2 received, 1 `restock` and 1 `damaged`, when closed, then a credit note covers 2 units and one stock move returns 1 unit at its original cost.
- Test: happy path.

### US-O2C-020
- Given 5 on hand with 5 reserved, when a plain invoice for 1 unit is created for that item and location, then it is refused for insufficient available stock.
- Test: "keeps a plain invoice from taking reserved stock".

### US-O2C-021
- Given a Store Keeper, when creating a sales order, then 403. Given a Sales Executive, when dispatching, then 403.
- Test: "enforces permissions".

### US-O2C-022
- Given an order in business A, when business B (or a user scoped to another location) requests it, then 404.
- Test: "hides another business order" for tenants. Location scope: no order-specific test visible; location scope is tested for stock in `api.test.ts` "limits a site supervisor to their site and hides costs".

## v1.8 procure to pay

### US-P2P-001
- Given a vendor and items, when a PO is created, edited, submitted with no matching approval rule and sent, then status goes `draft`, `approved`, `sent`. Editing after submit gives `NOT_EDITABLE`.
- Test: "draft, edit, submit, send".

### US-P2P-002
- Given a rule covering the PO total, when submitted, then status is `pending_approval` until an approver decides. A rejection returns it to `draft`.
- Test: "a matching rule holds the PO until an approver decides".

### US-P2P-003
- Given a PO with nothing received, when cancelled, then status is `cancelled`.
- Test: "cancels a PO with nothing received". Partial cancel: no dedicated test visible.

### US-P2P-004
- Given an approved PO, when a partial then a full GRN are posted, then stock rises by accepted quantity each time, Inventory is debited and GRNI credited, and PO status is `partially_received` then `received`.
- Test: "partial then full receipt, stock and GRNI follow".

### US-P2P-005
- Given ordered 10 and tolerance 0, when a receipt for 11 is posted, then it is refused. Given tolerance above 0, then it is accepted within tolerance.
- Test: "blocks over-receipt and honours tolerance".

### US-P2P-006
- Given a receipt line with rejected quantity and no reason, then 400. Given a reason, then rejected quantity is stored and stock does not move for it.
- Test: "tracks rejected quantity separately and asks for a reason".

### US-P2P-007
- Given stock from a GRN has been issued, when the GRN is cancelled, then it is refused. Given a billed GRN, then refused. Given neither, then a `grn_cancel` move and journal reversal are posted.
- Test: "cancel rules: stock gone, billed, then allowed".

### US-P2P-008
- Given a posted GRN, when a bill line carries its `grnLineId`, then no stock move is added, GRNI is cleared and the Inventory value is unchanged by the bill.
- Test: "billing from a receipt does not count stock or inventory twice".

### US-P2P-009
- Given 10 received and 10 billed, when another bill line for 1 is posted against the same receipt line, then it is refused.
- Test: "blocks over-billing".

### US-P2P-010
- Given a bill rate above PO rate beyond `po_price_tolerance_pct`, when posted without `acceptVariance`, then it is blocked. Given `acceptVariance` from a caller without `purchases.override`, then 403. Given `purchases.override`, then it posts and the difference goes to Purchase Price Variance.
- Test: "price variance blocks, override needs permission and posts to variance".

### US-P2P-011
- Given a bill linked to a GRN, when the bill is cancelled, then the receipt's billed quantity and cleared value are released.
- Test: "cancelling the bill releases the receipt".

### US-P2P-012
- Given an item at or below `reorder_level`, when suggestions are listed, then it appears with last vendor and rate. When selected and posted, then one draft PO per vendor is created.
- Test: "lists items at or below the level and creates draft POs by vendor".

### US-P2P-013
- Given an open count, when items are scanned and the count is posted, then a stock move of `ref_type stock_count` is posted for each variance. A movement during the count is accounted for.
- Test: "scans, handles a movement during the count, and posts the variance"; "selected scope refuses other items, uncounted lines can be zeroed, gains post to income".

### US-P2P-014
- Given a variance value above `count_approval_value`, when a caller without `stock_counts.approve` posts, then it is refused.
- Test: "a variance above the threshold needs the approve permission".

### US-P2P-015
- Given a caller without the permission, then 403. Given another tenant's id, then 404.
- Test: "needs permissions"; "another tenant's records are 404".

## v1.9 Channels (planned)

### US-CHN-001
- Given saved credentials, when the capability check fails, then the connection shows its failure reason and is not shown as connected.
- Given the check passes, then status moves toward production enabled per master plan §7.4.

### US-CHN-002
- Given a secret credential field, when saved, then it is stored sealed (AES-256-GCM, `backend/src/lib/crypto.ts`) and never returned by the API. When rotated, then the old value stops being used on the next call.

### US-CHN-003
- Given a webhook with an invalid signature, when received, then the response is 401 and no order is created. Given a valid signature, then the raw payload is stored with its provider event id.

### US-CHN-004
- Given an event id already stored for the connection, when it arrives again, then the response is 200, no second job is queued and no second order exists.

### US-CHN-005
- Given webhooks are down, when the poll job runs, then it fetches from the stored cursor, saves the new cursor only after the batch is stored, and a re-run after a crash produces no duplicates.

### US-CHN-006
- Given a saved mapping, when a file is uploaded, then a preview shows rows to create, skip and fix before commit. Commit creates sales orders with `source csv`.

### US-CHN-007
- Given an unmapped channel SKU, then the row goes to a fix list. Given a bundle mapping of 2 items, then the order line expands to both items with component quantities.

### US-CHN-008
- Given a channel order id already imported, when the file is imported again, then the row is skipped and nothing changes.

### US-CHN-009
- Given a stock change, then a push job per mapped listing is queued with the available quantity (on hand minus reserved). Repeated changes within the coalescing window produce one push.

### US-CHN-010
- Given a balanced settlement file, when posted, then one journal entry is created and re-importing the same file creates no second entry.

### US-CHN-011
- Given lines that do not sum to the settlement total within 1 paisa per line, then the settlement is marked `unbalanced` and posting is refused.

### US-CHN-012
- Given TCS and TDS lines, when mapping to accounts is saved, then a mapping to an expense account is refused. Posting debits the receivable accounts.

### US-CHN-013
- Given a connection with failed polls, then the page shows `degraded`, the last success time and the backlog. A failed health check shows unknown, not healthy.

### US-CHN-014
- Given a dead-lettered event, when replay is requested by a user with `channels.manage`, then it is processed again once and the replay is audited.

### US-CHN-015
- Given a channel cancellation event for an order not yet dispatched, then the order's open quantity is cancelled through the existing cancel flow and reservations are released.

### US-CHN-016
- Given no working access, then the connector stays at "access requested" and CSV import is offered. Given access and a passing sandbox check, then it can move to sandbox available.
