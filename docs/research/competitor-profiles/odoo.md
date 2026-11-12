# Odoo (Odoo S.A.)

Checked 2026-11-03. Confidence: medium. Pricing, API and India GST read from official pages. Module depth and AI status come from secondary sources.

## Snapshot

| Field | Detail |
|---|---|
| URL | https://www.odoo.com |
| HQ | Belgium (not re-verified this pass; UNVERIFIED on fetched pages) |
| Markets | Global. India has a localisation package (`l10n_in`) |
| Sizes | Small to mid-size. Larger firms via partners (UNVERIFIED) |
| Industries | Horizontal apps. Vertical depth comes from partners and Studio |
| Deployment | Odoo Online (SaaS), Odoo.sh (PaaS), on-premise. Community edition is open source (LGPL, not re-checked) |
| Pricing | Published. India page, 2026-11-03: One App Free Rs 0. Standard Rs 580 per user per month yearly (Rs 725 monthly). Custom Rs 1,080 yearly (Rs 1,350 monthly). The page shows struck-through list prices and says the discount applies for 12 months to the initial users. Light users Rs 195 each, by quote |
| India availability | Yes. Price page is in INR |
| GST localisation | Modules `l10n_in`, `l10n_in_edi`, `l10n_in_ewaybill`, `l10n_in_ewaybill_stock`, `l10n_in_reports` (19.0 docs) |

The price page layout was ambiguous in the last pass. This pass read the yearly and monthly toggle. Treat the figures as "as shown", and confirm at checkout.

## Modules

| Area | Label | Note |
|---|---|---|
| Accounting, invoicing | native | Standard plan includes all apps |
| Inventory, purchase, sales, CRM | native | Per Odoo marketing; depth UNVERIFIED |
| Manufacturing (MRP) | native | UNVERIFIED depth |
| India e-invoice (IRN) | native (enterprise apps) | Needs a GSP. Docs name BVM IT Consulting. Edition split not stated on the page read |
| India e-way bill | native | Also from receipts and delivery orders |
| GSTR-1, GSTR-2B, GSTR-3B | native | GST E-Filing and Matching files GSTR-1 and fetches GSTR-2B |
| TDS and TCS | native | Threshold alerts, applied on invoices and bills |
| Studio (custom fields and apps) | configurable | Custom plan only |
| Multi-company | configurable | Custom plan, or free one-app plan |
| External API | configurable | Custom plan only, per pricing page |
| Marketplace connectors | add-on, partner | App store; coverage of Indian marketplaces UNVERIFIED |

## Workflows worth copying

- Send wizard on a confirmed invoice that submits to the NIC portal, then stamps IRN, acknowledgement number, date and QR on the PDF.
- Automatic conversion of negative lines (discounts) before submission, because the portal rejects them.
- E-way bill created directly from a delivery order or receipt.
- GSTR-2B retrieval and matching against vendor bills inside the books.
- One-app-free tier with unlimited users. A cheap way to get adoption.

## APIs and integrations

- 19.0 documents a JSON-2 external API with API keys, and a section on migrating from XML-RPC and JSON-RPC. The deprecation date was not read (page text was cut off).
- Webhooks appear under Studio automation rules. Detail not read.
- API access is a Custom plan feature. Check this before promising integrations to a Standard customer.

## Mobile

Odoo has mobile apps (UNVERIFIED on a store page this pass). Offline scanning: UNVERIFIED.

## AI

| Item | Status |
|---|---|
| Ask AI (Ctrl+K), AI fields, AI agents in 19 | Reported GA in Odoo 19 (Sept 2025) by partner blogs only |
| "Agentic AI" | Listed on the Custom plan on the pricing page |
| Features planned for 19.1 to 19.4 | Roadmap. A Probuse page says it may change |

Which features are in 19.0 versus later point releases is not confirmed from official release notes.

## Strengths (with evidence)

- Full India GST chain in documented modules, from IRN to GSTR-3B (19.0 India page).
- Published, low entry price. Rs 580 per user per month for all apps.
- Hosting choice: Online, Odoo.sh or on-premise (pricing page).

## Gaps (with evidence)

- API, Studio and multi-company need the Custom plan at about 1.9 times the price (pricing page).
- Needs a third-party GSP for e-invoicing. Cost of that GSP is not on the page.
- Light-user and implementation pricing needs a quote.
- No evidence read of Indian marketplace settlement reconciliation (TCS 52 / TDS 194-O matching).

## What Progen should take from it

- Offer a free single-app tier with unlimited users to seed adoption.
- Keep API and webhooks in a lower tier than Odoo does. That is an opening for SMBs.
- Copy the e-way bill from delivery order flow and negative line handling.
- Show GSTR-2B matching inside the ledger view, not as a separate report.

## Unknowns needing a demo

- Which India modules exist in Community versus Enterprise.
- JSON-2 rate limits and deprecation date for XML-RPC.
- Real cost of the GSP and credits.
- Offline mobile scanning and barcode flows.
- Marketplace connectors for Amazon, Flipkart and Meesho.

## Sources

- https://www.odoo.com/pricing (Fetched 2026-11-03)
- https://www.odoo.com/documentation/19.0/applications/finance/fiscal_localizations/india.html (Fetched, first 100k chars)
- https://www.odoo.com/documentation/19.0/developer/reference/external_api.html (Fetched, partial)
- https://www.odoo-bs.com/blog/global-5/artificial-intelligence-in-odoo-19-415 (Search, secondary)
