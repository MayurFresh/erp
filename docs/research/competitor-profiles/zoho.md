# Zoho One, Zoho ERP and Zoho Books (Zoho Corporation)

Checked 2026-11-03. Confidence: medium for Books, low for One and ERP. Books pricing and e-invoicing read from Zoho pages. Zoho One price page returned 404 and the ERP AI page failed on a certificate error.

## Snapshot

| Field | Detail |
|---|---|
| URL | https://www.zoho.com/in/books/ , https://www.zoho.com/in/erp/ (not fetched) |
| HQ | India (Chennai); not re-verified on a fetched page |
| Markets | Global with regional editions. India edition has INR pricing |
| Sizes | Micro to mid-size. Zoho ERP is pitched upward (search results) |
| Industries | Horizontal. Manufacturing and ERP coverage UNVERIFIED |
| Deployment | SaaS |
| Pricing | Books India published (below). Zoho One not read from Zoho; partner pages quote Rs 1,250 to Rs 1,800 all-employee and about Rs 3,500 flexible, conflicting, so not recorded as published |
| India availability | Yes |
| GST localisation | Books: e-invoicing from Standard plan. Zoho is a GSP. e-way bill via Zoho as GSP |

Zoho Books India (INR per organisation per month, ex tax, 2026-11-03): Free 0 (1 user plus accountant, under Rs 25 lakh revenue). Standard 749 yearly, 899 monthly (3 users). Professional 1,499 or 1,799 (5). Premium 2,999 or 3,599 (10). Elite 4,999 or 5,999 (15). Ultimate 7,999 or 9,599 (25). Extra user Rs 150 to 180.

## Modules

| Area | Label | Note |
|---|---|---|
| Books accounting, invoicing | native | |
| e-invoice (IRN) | native | All paid Books plans. Recurring e-invoices, multiple GSTIN, REST APIs |
| e-way bill | native | After registering Zoho as GSP |
| GSTR filing | unverified | Page only mentions ANX-1 and ANX-2 data flow |
| Inventory, Billing, Expense, Payroll, CRM | native (separate apps) | Not fetched |
| Zoho ERP | native, launched early 2026 | Partner blog says "AI-native ERP". Module list UNVERIFIED |
| Zoho One bundle | native | Suite of apps; app count not read from Zoho |
| Creator, Flow, Deluge | configurable | Low-code layer, UNVERIFIED this pass |
| Marketplace connectors | partner | Zoho Marketplace; coverage UNVERIFIED |

## Workflows worth copying

- Smart validation before IRN upload: missing mandatory fields and violations are caught first.
- Recurring invoices that go to the IRP and the customer without a click.
- Plan limits by annual invoice count (1,000 on Free up to 1,00,000 on Elite and Ultimate).
- Free tier gated by revenue (under Rs 25 lakh), not by time.

## APIs and integrations

- Books has REST APIs including e-invoice push to IRP (Zoho e-invoicing page).
- Webhooks, rate limits and OAuth detail not read this pass.
- One shared identity across apps is the main integration advantage (Zoho claim).

## Mobile

Mobile apps exist for Books (UNVERIFIED on a store page this pass).

## AI

| Item | Status |
|---|---|
| Zia Agents, Agent Studio, Marketplace | Announced Feb 2025; free to build, model use billed separately (search report) |
| Zoho ERP AI features | Reported at launch; GA scope UNVERIFIED |
| Receipt and document autoscans in Books | Published as plan quotas (50 to 1,000 per month) |

## Strengths (with evidence)

- Low published Books price with GST e-invoicing on the first paid tier.
- Zoho acts as its own GSP, so no extra GSP fee for IRP (e-invoicing page).
- Wide suite under one login.

## Gaps (with evidence)

- GSTR filing detail not on the e-invoicing page.
- Zoho One and ERP prices are not published on pages that could be read.
- Plan invoice caps create upgrade cliffs.

## What Progen should take from it

- Make e-invoice available on the lowest paid plan. It is the anchor feature in India.
- Pre-validate documents before submission.
- Price by organisation with generous users, not per seat, at the low end.
- Publish invoice-volume tiers clearly.

## Unknowns needing a demo

- Zoho ERP module list, manufacturing depth and India pricing.
- Zoho One current India price.
- GSTR-1 and 3B filing inside Books.
- Marketplace settlement reconciliation in Inventory.

## Sources

- https://www.zoho.com/in/books/pricing/ (Fetched 2026-11-03)
- https://www.zoho.com/in/books/e-invoicing/ (Fetched)
- https://www.zoho.com/en-in/erp/ai-in-erp/ (Search, not fetched)
- https://itwire.com/business-it-news/data/zoho-corporation-unveils-zia-agents-the-next-frontier-in-enterprise-ai (Search)
- https://precisiontech.in/software/zoho/zoho-one/ (Search, partner, secondary)
