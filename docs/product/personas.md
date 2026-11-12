# Personas

Seven personas for the commerce wedge, plus construction and real estate. They are working models drawn from `docs/research/commerce-ops.md`, `docs/research/industry-verticals.md` and the system roles in `backend/src/auth/permissions.ts` (`SYSTEM_ROLES`). None is a named customer. Validate each in pilot interviews.

## Role mapping

| Persona | System role today | Gap |
| --- | --- | --- |
| P1 Owner | Owner | none |
| P2 Ops manager | Company Admin | no dedicated role template; Company Admin is broader than needed |
| P3 Warehouse picker | Store Keeper (`sales_orders.view`, `fulfilment.manage`) | no scan-only role; a custom role can drop the other permissions |
| P4 Accountant | Accountant | none |
| P5 Sales and channel executive | Sales Executive (`sales_orders.manage`) | channel permissions planned (v1.9) |
| P6 Purchase manager | Accountant plus `purchase_orders.manage` or a custom role | no template; Store Keeper only views POs |
| P7 Site supervisor | Site Supervisor | construction pack |
| P8 Real-estate sales and finance lead | Sales Executive, Accountant (`bookings.manage`) | none |

## P1 Owner (commerce SME)

- Goal: know cash, margin and stock at any time, without chasing staff.
- Pains: no single view across channels and books; marketplace payouts that do not match orders (research §1 "Settlement").
- Uses: dashboard, reports, approvals, audit log, roles.
- Needs from v1.8: reservations that stop overselling; approval on large POs. From v1.9: payout variance by channel.
- Success: month close without a spreadsheet.

## P2 Operations manager

- Goal: orders leave on time, stock counts are right.
- Pains: partial shipments, short picks, returns that never reach stock, reorder by gut feel.
- Uses: sales orders, pick lists, shipments, returns, reorder suggestions, stock counts.
- Success: no order stuck in `picking`; count variances explained.

## P3 Warehouse picker or packer

- Goal: pick and pack the right item fast, on a phone or scanner.
- Pains: wrong item shipped, double scans, weak connectivity (industry-verticals Part B pain 1).
- Uses: pick list scan, pack scan, barcode lookup, goods receipt, counts (`lib/features/fulfilment/`, `stock_counts/`).
- Constraints: little training time; scan errors must say what is wrong (`UNKNOWN_BARCODE`, `WRONG_ITEM`, `OVER_PICK`).
- Offline scan queue: planned (v1.10).

## P4 Accountant (in-house or outside CA)

- Goal: books that match stock and tax filings, with an audit trail.
- Pains: bills that do not match receipts, GSTR-2B mismatches, period back-dating (industry-verticals pain 8, 15).
- Uses: purchases, three-way match, journals, GST returns, TDS, bank reconciliation, books lock, exports.
- Needs: price variance posted to a variance account, GRNI visible, no hard deletes.
- Success: bill, receipt and stock agree; reversals instead of deletions.

## P5 Sales and channel executive

- Goal: take orders, quote stock honestly, handle customer returns.
- Uses: sales orders, availability check, returns. Channel SKU mapping and order import: planned (v1.9).
- Pain: promising stock that is already reserved.

## P6 Purchase manager

- Goal: buy what is low, at the agreed price, and receive it against the PO.
- Uses: reorder suggestions, purchase orders, approvals, goods receipts, bill matching.
- Pain: price drift between PO and bill; over-receipt.

## P7 Site supervisor (construction)

- Goal: record material use, labour and progress at one site.
- Uses: indents, issues, DPRs, attendance (`lib/features/construction/`). Access limited to assigned sites (`user_roles.location_ids`).
- Pain: office staff cannot see site stock or progress the same day.

## P8 Real-estate sales and finance lead

- Goal: book units, raise demands against payment plans, track receipts.
- Uses: units, bookings, demands, RERA status (`modules/units.ts`, `bookings.ts`).
- Pain: payment-plan demand tracking in spreadsheets.
