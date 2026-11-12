# Data flow

Three flows with the real tables. All amounts are numeric rupees. All steps for one action run in one transaction under `withTenant`.

## Order to cash

```
sales_orders (draft)
  -> confirm: stock_reservations (active); sales_order_lines.qty_reserved
  -> pick list: pick_lists, pick_list_lines
  -> scan pick: scan_events (kind pick), qty_picked
  -> scan pack: scan_events (kind pack), qty_packed
  -> dispatch (one transaction, Idempotency-Key):
       invoices + invoice_lines (createInvoice)
       stock_moves (ref_type invoice), reservations -> consumed
       journal_entries + journal_lines
       shipments + shipment_lines, shipment_status_history
  -> shipment status: booked, in_transit, delivered | rto_initiated, rto_delivered | lost
  -> return: sales_returns + sales_return_lines (customer_return or rto)
       received, inspected (disposition restock, damaged, scrap)
       close -> credit_notes, stock_moves (ref_type credit_note) for restock units only
```

Invariants (migration 013 checks): `qty_dispatched <= qty_packed <= qty_picked`; `qty_reserved <= ordered - dispatched - cancelled`; `qty_returned <= qty_dispatched`. Available stock is `locationQty` minus reserved (`availableOf`). Order status is derived by `refreshStatus`. A plain invoice cannot take reserved stock.

## Procure to pay

```
purchase_orders (draft) -> pending_approval? -> approved -> sent
  -> goods_receipts + goods_receipt_lines (accepted, rejected qty)
       stock_moves (ref_type grn)
       journal: Dr Inventory, Cr 2140 Goods Received Not Invoiced
       PO status: partially_received | received
  -> purchases + purchase_lines (bill) with purchase_order_id and GRN line links
       no new stock move when linked to a receipt
       journal: Dr GRNI, Cr Payable; price difference -> 5110 Purchase Price Variance
  -> payments
```

Controls: `po_receipt_tolerance_pct`, `po_price_tolerance_pct`, `purchases.override` permission for variance. Cancels post reversals (`grn_cancel`, `purchase_cancel`), and are refused if stock is gone or the receipt is billed.

Reorder and counts: `reorder.ts` lists items at or below `reorder_level` and creates draft POs per vendor. `stock_counts`, `stock_count_lines` and `stock_count_scans` post variances as `stock_count` moves, gated by `count_approval_value` and `stock_counts.approve`.

## Stock ledger

`stock_moves` holds signed `qty`, `rate`, `cost_rate`, `value`, `ref_type` and `ref_id`. Allowed `ref_type` values (012): opening, adjustment, invoice, invoice_cancel, purchase, purchase_cancel, credit_note, credit_note_cancel, transfer_out, transfer_in, transfer_cancel, issue, issue_cancel, grn, grn_cancel, stock_count, write_off.

- Balance is the sum of `qty` per item and location. Cost is weighted average (`costing.ts`, `positions`, `locationQty`).
- Writers call `lockItems(tx, companyId, itemIds)` first, which takes a per-item advisory lock with ids sorted.
- Nothing updates or deletes rows; a cancel appends a reverse move.
- Reservations are not ledger rows. They live in `stock_reservations` and line quantities, and are subtracted when checking availability.

## Not yet built

Channel orders (v1.9) will enter at the top of the O2C flow as `sales_orders` with `source = channel` and a unique `external_ref`.
