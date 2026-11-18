# Hospitality workflows

Checked 2026-11-03. Builds on ../industry-verticals.md section 4 (restaurants and hotels). Profiles: ../competitor-profiles/mews.md and ../competitor-profiles/oracle-opera-cloud.md. Master plan: section 3.7 and 5.1.

## Scope
- Independent hotels, guest houses and small chains (roughly 10-150 rooms).
- Front office, reservations, rates, folio, housekeeping, maintenance, night audit.
- Channel manager and booking engine as connectors, not built in.
- Out of scope now: revenue management engines, large-chain central reservations, vacation-rental management (Hostaway-style) beyond a note.

## End-to-end workflow
1. Room types, rooms, rate plans and seasons set up.
2. Reservation from a direct call, booking engine or OTA through a channel manager.
3. Availability and rates pushed to channels after every change.
4. Pre-arrival: guest details, ID, advance payment.
5. Check-in: room assigned, ID captured (Form C for foreign guests), keys issued.
6. In-stay charges post to the folio: room, food, laundry, extras.
7. Housekeeping: room status changes (dirty, clean, inspected), tasks assigned.
8. Maintenance requests block a room if needed.
9. Check-out: folio settled, split between guest and company if needed, GST invoice issued.
10. Night audit: close the business date, post room charges, reconcile cash.
11. OTA commission and payout reconciliation.
12. Daily revenue and occupancy reports.

## Key entities and states
- Reservation: tentative, confirmed, checked in, checked out, cancelled, no-show.
- Room status: vacant clean, vacant dirty, occupied, out of order, inspected.
- Folio: open, split, settled, transferred to company account.
- Rate plan: base rate, derived rates, restrictions (min stay, close to arrival).
- Housekeeping task: pending, in progress, done, inspected.
- Business date: open, audited, closed.

## India specifics
- GST on room tariff depends on the tariff slab, and food and beverage follows restaurant rules. See ../industry-verticals.md section 4. Rates not restated; slab changes in 2025 are UNVERIFIED here.
- Foreign guest reporting (Form C) and ID capture: section 4.
- Many Indian hotels sell through OTAs, so TCS and TDS on OTA payouts matter (../ecommerce-marketplaces.md).
- No evidence found that Mews, OPERA Cloud or Cloudbeds localise GST for India. Mark all three UNVERIFIED for India.

## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Oracle OPERA Cloud | Chains, large hotels | UNVERIFIED | OHIP APIs, interfaces, front office, accounting | n | docs.oracle.com |
| Mews | Cloud PMS, mid-market | UNVERIFIED | PMS, payments, POS, Connector API | n | docs.mews.com |
| Cloudbeds | Independent hotels | UNVERIFIED | PMS, channel manager, booking engine, payments, tiers Flex, One, Experience, Enterprise | n (quote) | cloudbeds.com/pricing |
| SiteMinder | Channel manager | Listed with eZee link; India pricing not found | Channel manager, booking engine | n | siteminder.com |
| eZee Absolute | Hotel PMS for India and Asia | India (Capterra India listing) | Classic, Elite, Star, Champion tiers; own channel manager in upper tiers | partly (third-party shows from Rs 2,250 excl GST; unverified) | techjockey.com, fitgap |
| Hostaway | Vacation rentals | UNVERIFIED | Tiers by listing count (2-14, 15-49, 50+) | n | hostaway.com/pricing |
| Hotelogix and other India PMS | Indian hotels | India | Not researched in this pass | UNVERIFIED | open question |

## Table stakes vs differentiators
- Table stakes: reservation calendar, room status board, folio with GST invoice, check-in and out, housekeeping list, night audit, channel manager link, reports.
- Differentiators: restaurant and spa charges posting to the folio from the same system, OTA payout reconciliation, company billing with credit terms, books built in.
- Later: revenue management, dynamic rates, guest messaging, keyless entry.

## Edge cases to test
- Overbooking when a channel pushes a booking during a rate update.
- Room move mid-stay with split rates.
- Early check-in and late check-out charges.
- Group booking with master folio and individual extras.
- Cancellation of a prepaid OTA booking and the commission clawback.
- Tariff crossing a GST slab on a date change.
- Night audit run twice or on a back date.
- Advance receipt before the invoice, with GST on advance.

## What OneMatrix can reuse from its core
- Parties (guests, companies), invoices and credit notes, journal engine, receipts, items for services, approvals, audit, file storage for ID scans, cost centres.
- Bookings module in the real-estate pack (bookings.ts) has a calendar-like reservation pattern, but it models unit sales, not nights. Reuse is limited.

## Smallest useful OneMatrix slice
- Room master, reservation calendar, check-in and out, folio with GST invoice, housekeeping status board, night audit report, receipt reconciliation.
- Connector to one channel manager later (no own channel manager).
- Restaurant charge posting to room as the first cross-pack link.

## Rough effort and priority
- Slice: M to L. Channel manager connector: M each. Priority: low to medium. Hotels in India already have cheap local PMS products, so OneMatrix needs the books and restaurant link as its hook.

## Open questions
- What do 20-60 room Indian hotels pay today for a PMS?
- Do they need an in-house channel manager or only a SiteMinder link?
- Mews and OPERA India availability needs a vendor answer.
- Are Form C filings automated by competitors?

## Sources
- https://docs.oracle.com/en/industries/hospitality/integration-platform/ifcig/c_overview.htm
- https://docs.mews.com/connector-api/guidelines/authentication
- https://www.cloudbeds.com/pricing/
- https://www.siteminder.com/ezee-pms-siteminder-channel-manager/
- https://techjockey.com/detail/ezee-absolute
- https://www.hostaway.com/pricing/
- ../industry-verticals.md
