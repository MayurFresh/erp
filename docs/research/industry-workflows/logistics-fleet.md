# Logistics and fleet workflows

Checked 2026-11-03. Builds on ../industry-verticals.md section 9 (logistics and transport, GTA). Master plan: section 5.1 Logistics.

## Scope
- Goods transport agencies (GTA), truck owners, small fleets and 3PL operators.
- Booking, lorry receipt (LR), trip, freight billing, driver and vehicle records.
- Out of scope now: route optimisation engines, last-mile courier networks, cold-chain sensors.

## End-to-end workflow
1. Customer enquiry and rate quote by lane, weight or truck type.
2. Booking confirmed; vehicle and driver assigned (own or hired).
3. LR issued per consignment with e-way bill.
4. Loading, trip start, advance to driver.
5. In-transit tracking and expense capture (toll, fuel, repair).
6. Delivery and proof of delivery (POD); shortage and damage noted.
7. Freight bill to consignor or consignee, with GST under forward or reverse charge.
8. Hired-vehicle payment after POD, with TDS on transporter payment.
9. Trip close with profit per trip.
10. Vehicle compliance: fitness, insurance, permit, PUC renewals.

## Key entities and states
- Booking: enquiry, confirmed, assigned, in transit, delivered, billed, closed.
- LR: draft, issued, delivered, POD received, disputed.
- Trip: planned, running, completed, settled.
- Vehicle document: valid, expiring, expired.
- Freight bill: draft, issued, part paid, paid.

## India specifics
- GTA GST (reverse charge versus forward charge option), e-way bill, TDS on freight: ../industry-verticals.md section 9 and ../gst-einvoice-ewaybill.md. Rates not restated.
- Vehicle tracking compliance (AIS-140 and VLTD) is described by Fleetx as a compliance point for Indian fleets. Official rule text was not read: UNVERIFIED.

## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Fleetx | Fleet and transport operations | India (Gurugram) | Tracking, renewal reminders, compliance | UNVERIFIED | blog.fleetx.io |
| Shipsy | TMS, WMS, last mile | India-based; global | Route, load capacity, on-time delivery | UNVERIFIED | shipsy.io |
| LogiNext | Route and workforce | One third-party source reports a 2024 bankruptcy filing; status UNVERIFIED | Route optimisation, compliance | UNVERIFIED | cbinsights.com |
| Small GTA billing packages (LR and freight bill) | Small transporters | India | Not researched in this pass | UNVERIFIED | open question |

## Table stakes vs differentiators
- Table stakes: booking, LR print, e-way bill, freight bill with GST, trip expenses, vehicle document reminders, party ledger.
- Differentiators: trip profitability in the ledger, hired-vehicle payment with TDS, POD-linked billing, WhatsApp POD capture.
- Later: GPS integration, route optimisation, driver app.

## Edge cases to test
- Part load with several LRs on one vehicle.
- Shortage or damage deducted from freight.
- Reverse-charge bill mixed with forward-charge bill for one party.
- Hired vehicle paid before POD received.
- E-way bill extended after breakdown.
- Trip crossing a financial year end.

## What OneMatrix can reuse from its core
- Parties, invoices, credit notes, e-way bill and e-invoice, TDS module, expenses, fixed assets (vehicles), shipments and fulfilment modules, files (POD scans), approvals.

## Smallest useful OneMatrix slice
- Booking, LR with e-way bill, trip expenses, freight bill, hired-vehicle payable with TDS, vehicle document reminders.

## Rough effort and priority
- Slice: M. Priority: medium. The GST and TDS rules fit the core.

## Open questions
- Which small-GTA products dominate and what do they cost?
- Does the target user bill per LR or per trip?
- Is GPS integration needed to win customers?

## Sources
- https://blog.fleetx.io/transport-software-the-complete-guide-for-logistics-operators-and-teams/
- https://shipsy.io/blogs/logistics-software-companies-in-india/
- https://www.cbinsights.com/compare/loginext-vs-shipsy
- ../industry-verticals.md
