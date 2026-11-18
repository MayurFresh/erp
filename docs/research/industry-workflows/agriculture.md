# Agriculture workflows
Checked 2026-11-03. Builds on ../industry-verticals.md section 12 (agriculture, FPOs and agri-traders).
## Scope
FPOs, agri-input dealers, traders and processors: farmer records, procurement, weighing, storage, sales. Satellite and crop advisory are out of scope.
## End-to-end workflow
1. Farmer and plot registered. 2. Inputs supplied on credit. 3. Produce procured with weighment and quality grade. 4. Payment to farmer, with input recovery. 5. Storage lot in a warehouse. 6. Sale to buyer with GST or bill of supply. 7. Traceability by lot.
## Key entities and states
Farmer: registered, active, blocked. Procurement lot: received, graded, stored, sold. Input credit: issued, partly recovered, settled.
## India specifics
Many unprocessed agri produce items are GST-exempt, mandi fees and commission agent rules, FPO status: ../industry-verticals.md section 12. Details UNVERIFIED here.
## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| FarmERP | Agri enterprises | India (Capterra India listing) | Farm ERP, IoT, QR access, advisory; onboarding can be slow (one reviewer) | UNVERIFIED | capterra.in |
| Cropin | Agri enterprises and agencies | India-origin, 103 countries claimed | Data foundry, 22+ domain models, agents; 250+ enterprise clients claimed | n | cropin.com |
## Table stakes vs differentiators
Table stakes: farmer master, procurement with weighment, grading, payment, stock by lot. Differentiators: input recovery against produce payment, books built in, traceability by lot, multi-unit conversion (quintal, bag).
## Edge cases to test
Moisture deduction after weighment; split payment across two farmers; unit conversion rounding; partial input recovery; lot blending.
## What OneMatrix can reuse from its core
Parties, items with units, batch tracking (planned), stock, purchases, payments, locations.
## Smallest useful OneMatrix slice
Farmer party, procurement with weigh slip, grade and deduction, farmer payment with input recovery.
## Rough effort and priority
M. Priority: low to medium.
## Open questions
Are mandi commission rules uniform by state? Is weighbridge integration needed?
## Sources
https://www.capterra.in/software/130210/farmerp ; https://www.cropin.com/ ; ../industry-verticals.md
