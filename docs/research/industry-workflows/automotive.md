# Automotive workflows
Checked 2026-11-03. Builds on ../industry-verticals.md section 11 (auto dealers and service workshops).
## Scope
Independent workshops and small dealers: job cards, parts, service booking, warranty, vehicle history. Dealer management for OEM networks is out of scope.
## End-to-end workflow
1. Vehicle and customer lookup by registration. 2. Service booking. 3. Job card with complaints. 4. Estimate and approval. 5. Parts issue and labour. 6. Insurance or warranty claim step if needed. 7. Invoice and delivery. 8. Service reminder.
## Key entities and states
Job card: open, estimate sent, approved, in work, ready, delivered, closed. Vehicle: registered by plate and VIN. Claim: submitted, surveyed, approved, paid.
## India specifics
GST on parts and labour at different rates, insurance claim and surveyor flow, vehicle sale and used-vehicle margin scheme: ../industry-verticals.md section 11. Details UNVERIFIED here.
## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Shopmonkey | Independent shops | UNVERIFIED (US dollar pricing) | Plans Basic, Clever, Genius, Multi-Shop; 3-5 users included; extra users $20 per month | y | shopmonkey.io/pricing |
| Tekion | Dealerships | UNVERIFIED | Automotive Retail Cloud; pricing negotiated | n | gartner.com |
| CDK, Reynolds and Reynolds, AutoLeap | Dealers and shops | UNVERIFIED | Not researched | UNVERIFIED | open question |
## Table stakes vs differentiators
Table stakes: job card, estimate, parts issue, invoice, vehicle history, reminders. Differentiators: serial and VIN tracking, insurance claim steps, books built in, WhatsApp estimate approval.
## Edge cases to test
Estimate changed after approval; part returned after invoice; warranty job billed to the OEM; two jobs on one vehicle; customer pays in parts.
## What Progen can reuse from its core
Items with serial, stock, issues, parties, invoices, approvals, notifications, fixed assets.
## Smallest useful Progen slice
Vehicle master, job card with estimate approval, parts issue, invoice, service reminder.
## Rough effort and priority
M. Priority: low to medium.
## Open questions
What do Indian garages pay for software? Is insurance claim support needed at launch?
## Sources
https://www.shopmonkey.io/pricing ; https://www.gartner.com/reviews/product/tekion-automotive-retail-cloud ; ../industry-verticals.md
