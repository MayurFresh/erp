# Events and venues workflows
Checked 2026-11-03. Not covered in ../industry-verticals.md. Master plan: section 5.1 Events and venues. Product research for this vertical was not done in this pass.
## Scope
Venue and event booking, ticketing, QR entry, vendors and crew, sponsorship, event settlement. Payment gateway and ticket marketplace are out of scope.
## End-to-end workflow
1. Venue enquiry and hold. 2. Quote and booking with advance. 3. Event plan, vendors and crew. 4. Ticket or guest list issued with QR. 5. Entry scan. 6. On-site sales and POS. 7. Vendor and sponsor settlement. 8. Final invoice and profit report.
## Key entities and states
Booking: enquiry, held, confirmed, held-expired, completed, cancelled. Ticket: issued, scanned, void. Settlement: draft, agreed, paid.
## India specifics
GST on venue rental and on event services; entertainment tax by state: UNVERIFIED, not researched. Advance receipt handling is in ../statutory-core.md.
## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Not researched | Events and ticketing | UNVERIFIED | None verified | UNVERIFIED | gap in vertical-gaps.md |
## Table stakes vs differentiators
Table stakes: calendar with holds, quote, advance, QR ticket scan, vendor payables. Differentiators: settlement and profit per event in the ledger, multi-day holds with clash checks.
## Edge cases to test
Double booking of one hall; hold expiry; refund after partial entry scan; sponsor invoice with TDS; vendor paid before event.
## What OneMatrix can reuse from its core
Bookings module (real-estate pack calendar pattern), parties, invoices, advances, projects and cost centres, approvals, POS (once built).
## Smallest useful OneMatrix slice
Venue calendar with holds, quote to invoice, advance, event cost centre and profit report.
## Rough effort and priority
S to M. Priority: low.
## Open questions
Who are the competitors in India? Is QR ticketing needed or only booking?
## Sources
Master plan §5.1 (owner document, not in the repo)
