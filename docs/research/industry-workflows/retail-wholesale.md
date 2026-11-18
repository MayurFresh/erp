# Retail, wholesale and distribution workflows

Checked 2026-11-03. Builds on ../industry-verticals.md sections 2 (trading and distribution) and 3 (retail and POS). Commerce channels are in ../commerce-ops.md and are not repeated here.

## Scope
- Retail POS: counter billing for shops, chains and franchise stores.
- B2B wholesale: price lists, credit limits, schemes, challans.
- Distributors: field sales orders, beat plans, claims from the principal, DMS.
- Out of scope: marketplaces and OMS (commerce-ops.md), jewellery (separate pack, see industry-verticals.md section 10), pharma (section 5).

## End-to-end workflow
Retail POS:
1. Item master with barcode, MRP, GST rate, HSN, unit and variants.
2. Opening shift with cash float.
3. Scan items, apply item and bill discounts, customer lookup by phone.
4. Tender: cash, UPI, card, split tender, store credit, gift voucher.
5. GST invoice or bill of supply issued; e-invoice only if the seller crosses the threshold.
6. Returns and exchanges against the original bill, with credit note.
7. Hold and recall bills.
8. Shift close: cash count, variance, settlement of card and UPI.
9. Daily sales and stock posted to the ledger.
10. Stock transfer between store and warehouse, reorder from min levels.

B2B and distributor:
1. Retailer master with route, beat, credit limit and price list.
2. Salesman takes order on a phone, offline if needed.
3. Order approved against credit and stock.
4. Picklist, invoice with scheme and discount, dispatch with e-way bill if above limit.
5. Delivery, proof of delivery, collection of cash or cheque.
6. Outstanding ageing and follow-up.
7. Scheme and claim computation, claim sent to the principal, credit note received.
8. Returns: expiry, damage, short delivery.
9. Stock reorder to the principal.

## Key entities and states
- Bill: draft, held, completed, partly returned, cancelled.
- Sales order (B2B): draft, approved, picked, invoiced, delivered, closed.
- Shift: open, closing, closed, variance noted.
- Scheme claim: computed, submitted, accepted, settled, rejected.
- Retailer credit: within limit, over limit (needs approval), blocked.

## India specifics
- GST invoice versus bill of supply, composition dealers, B2C QR code rules, e-invoice threshold, e-way bill: see ../gst-einvoice-ewaybill.md.
- MRP and batch rules for packaged goods, schemes and trade discounts treated before or after GST: ../industry-verticals.md sections 2 and 3.
- UPI QR and card settlement reconciliation is a daily pain point (section 3).
- Rates and thresholds are not restated here. Check the linked docs.

## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Ginesys One | Fashion and retail chains | India | ERP, POS, OMS bundle | UNVERIFIED | competitor-master.csv |
| Busy 21 | Trading, distribution | India | GST accounting with stock | y (perpetual and yearly) | competitor-master.csv |
| TallyPrime | Trading, services | India | Accounting base most shops already use | y | competitor-master.csv |
| Zoho Inventory | SMB trading, retail | India | Multi-warehouse, channels | y | competitor-master.csv |
| Cin7 Core | Wholesale, ecommerce | Sold globally; India UNVERIFIED | B2B portal, EDI | y (USD) | competitor-master.csv |
| Lightspeed Retail, Square for Retail | Small retail POS | UNVERIFIED for India; sites target US and other markets | POS with inventory | UNVERIFIED | vertical-competitor-master.csv |
| Marg, Vyapar, Gofrugal, Retail distributor DMS products | India retail and distribution | India (from industry-verticals.md) | Not researched in this pass | UNVERIFIED | open question |

## Table stakes vs differentiators
- Table stakes: barcode billing, GST invoice, returns with credit note, multi-tender, shift close, stock by store, price lists, credit limit, ageing.
- Differentiators: offline-first POS, one ledger with no Tally export, scheme engine with claims, salesman app with beat plans, UPI settlement reconciliation, batch and expiry on distributor stock.
- Later: loyalty, omnichannel promotions, demand forecast.

## Edge cases to test
- Same barcode with two MRPs (old and new batch).
- Return after a price change or after a scheme ended.
- Split tender with part refund to a different mode.
- Bill held across shift close.
- Rounding of per-line GST against bill total.
- Credit limit hit by an order already in picking.
- Back-dated invoice after a period lock.
- Offline bills with duplicate numbers on sync.

## What OneMatrix can reuse from its core
- Invoices, credit notes, e-invoice, items, units, locations, stock, transfers, reorder, GRN, purchase orders, parties, approvals, sales orders, shipments, fulfilment (all present in backend/src/modules).
- Series numbering per outlet (backend/src/lib/series.ts).

## Smallest useful OneMatrix slice
- Counter billing screen: scan, tender, GST bill, held bills, return with credit note, shift close posting to the ledger. Use existing invoice and stock engines.
- Price lists and credit limit on parties for B2B.
- Defer the salesman app, schemes and DMS claims.

## Rough effort and priority
- POS slice: M. B2B price list and credit: S. Distributor DMS and schemes: L.
- Priority: high (core already close; first after commerce).

## Open questions
- Which retail product do target customers use today: Marg, Vyapar, Gofrugal or Tally?
- Is offline mode a must for the first release?
- Do distributors want claims automation before field sales?
- Which printers and scanners must work on day one?

## Sources
- ../industry-verticals.md, ../commerce-ops.md, ../gst-einvoice-ewaybill.md, ../competitor-master.csv
- https://www.lightspeedhq.com/pos/restaurant/pricing/ (403, not read)
