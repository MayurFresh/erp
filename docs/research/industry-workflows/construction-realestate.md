# Construction and real estate workflows
Checked 2026-11-03. Compares OneMatrix's existing packs with global products. Real-estate sales rules: ../real-estate-sales.md. Contractor billing: ../contractor-billing.md. Labour: ../labour-wages.md.
## Scope
Builders and contractors: BOQ, indents, material, labour, subcontract, RA bills, DPR, sales bookings. Property management (lease and rent) is a later extension.
## End-to-end workflow
1. Project and budget. 2. Indent and PO. 3. GRN and issue to site. 4. Labour attendance and wages. 5. Subcontract work order. 6. DPR. 7. RA bill and certification. 8. Unit booking, demand and receipts. 9. Cost to completion review.
## Key entities and states
Indent: draft, approved, ordered, received. RA bill: draft, certified, invoiced, paid. Booking: held, booked, agreement, possession, cancelled.
## India specifics
RERA 70 percent account, GST on works contract and on under-construction units, retention, labour cess: ../real-estate-sales.md, ../contractor-billing.md, ../labour-wages.md. Not restated.
## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Procore | Construction project management | India page not read; no official India evidence | 4.5 rating from 2,655 Capterra reviews | n | capterra.com compare page |
| CMiC | ERP-first construction | An Indian blog calls it an ERP-first Procore alternative; India sales UNVERIFIED | Financials plus project management | n | constructionestimatorindia.com |
| Yardi Voyager | Property and construction management | India customer in 2016 (Karle Infra, Bengaluru, commercial property) | Construction management module | n | yardi.com news |
## Table stakes vs differentiators
OneMatrix has in code: indents, work orders, GRN, labour, labour advances, subcontracts, RA bills, DPRs, projects, bookings. Gaps against the products above: drawings and RFIs, safety and quality checklists, equipment, lease and rent, BOQ estimating (UNVERIFIED whether present in OneMatrix). Differentiators: RA bill to GST invoice to ledger in one system, labour wages and subcontract TDS, RERA-aware receipts.
## Edge cases to test
RA bill with retention and advance recovery; GST rate change mid-project; unit cancellation after receipts; labour paid by two contractors; material transfer between sites.
## What OneMatrix can reuse from its core
Everything above is already built in the construction pack and core ledger.
## Smallest useful OneMatrix slice
Already shipped. Next: BOQ, equipment log and lease or rent for property management.
## Rough effort and priority
Gap closure: M. Priority: high, since it extends a pack that exists.
## Open questions
Do target builders need RFIs and drawings, or only cost control? Is Procore sold in India?
## Sources
https://capterra.com/compare/39271-56250/CMiC-vs-Procore ; https://constructionestimatorindia.com/?p=10745 ; https://www.yardi.com/news/karle-infra-pvt-ltd-selects-yardi-voyager-7s-for-commercial-property-management/
