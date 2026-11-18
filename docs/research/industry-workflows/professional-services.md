# Professional services workflows

Checked 2026-11-03. Builds on ../industry-verticals.md section 8 (professional services and agencies). Contractor billing patterns: ../contractor-billing.md. Master plan: section 5.1 Professional services.

## Scope
- CA, legal, consulting, IT services, architects and agencies with 5-200 staff.
- Projects, timesheets, resource planning, milestone and retainer billing, profitability.
- Out of scope now: CRM depth, document management, e-signature.

## End-to-end workflow
1. Client and engagement set up with contract, rates and billing terms.
2. Project with budget, tasks and team.
3. Resources allocated by role and capacity.
4. Staff log time and expenses.
5. Manager approves time.
6. Invoice by time and material, milestone, fixed fee or retainer.
7. GST invoice, with TDS deducted by the client at payment.
8. Receipt and TDS credit matching.
9. WIP and unbilled revenue review at month end.
10. Project profitability: revenue against staff cost and expenses.

## Key entities and states
- Engagement: proposal, signed, active, on hold, closed.
- Timesheet: draft, submitted, approved, billed, written off.
- Milestone: planned, delivered, accepted, invoiced.
- Retainer: active, consumed, expired.
- Invoice: draft, issued, part paid, paid.

## India specifics
- GST on services, TDS under section 194J or 194C by the client, advance receipts: ../industry-verticals.md section 8 and ../statutory-core.md.
- Reimbursement of expenses as pure agent or as supply: UNVERIFIED here; see section 8.
- Form 26AS and TDS credit matching are common pains.

## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Kantata | PSA, resource planning | UNVERIFIED | Allocation, capacity, forecasting; Salesforce-native edition; AI forecasting and agents | n | g2.com features page |
| Deltek Vantagepoint | Project ERP | Capterra India listing exists; India fit UNVERIFIED | Project accounting, billing, CRM, resource scheduling | n | deltek.com |
| Zoho Books and Projects, TallyPrime | Indian SMB base | India | See competitor-master.csv | y | competitor-master.csv |
| Productive, Scoro | PSA | UNVERIFIED | Not researched in this pass | UNVERIFIED | open question |

## Table stakes vs differentiators
- Table stakes: projects, timesheets, approval, invoice from time, milestone billing, expense claims, TDS on receipts.
- Differentiators: books built in, TDS credit matching on receipts, retainer drawdown, profitability by project and by client, utilisation by person.
- Later: capacity forecasting, AI summaries.

## Edge cases to test
- Time approved after the invoice was issued.
- Retainer overrun billed at a different rate.
- TDS deducted at a different rate than agreed.
- Milestone partly accepted.
- Credit note for a written-off timesheet.
- Staff rate change in the middle of a project.

## What OneMatrix can reuse from its core
- Parties, invoices and credit notes, TDS, expenses, approvals, projects (construction projects exist and cost centres), custom fields, audit, payments.

## Smallest useful OneMatrix slice
- Timesheets with approval, invoice from approved time or milestone, retainer, project profitability report. Reuse the projects table.

## Rough effort and priority
- Slice: S to M. Priority: medium. Industry-verticals.md says the core is mostly enough here.

## Open questions
- Which firm types come first: CA, agencies or IT services?
- Is resource planning needed in v1 or only timesheets?
- Do customers need a client portal?

## Sources
- https://www.g2.com/products/kantata-professional-services-automation-formerly-mavenlink-kimble/features
- https://www.deltek.com/en/products/vantagepoint/accounting-and-financial-management
- https://thedigitalprojectmanager.com/tools/deltek-vantagepoint-review/ (secondary)
- ../industry-verticals.md, ../contractor-billing.md
