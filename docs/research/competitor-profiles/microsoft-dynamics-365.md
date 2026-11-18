# Dynamics 365 Business Central and Finance and Supply Chain Management (Microsoft)

Checked 2026-11-03. Confidence: high for Business Central India features and price. Medium for Finance and Supply Chain (F&SCM). Low for AI status.

## Snapshot

| Field | Detail |
|---|---|
| URL | https://www.microsoft.com/en-in/dynamics-365/products/business-central/pricing |
| HQ | USA (general knowledge) |
| Markets | Global. Business Central has an India local version |
| Sizes | Business Central: SMB to mid-size. F&SCM: mid-size to enterprise |
| Industries | Horizontal plus partner solutions |
| Deployment | Business Central: SaaS, on-premise. F&SCM: SaaS (on-premise variants UNVERIFIED) |
| Pricing | Business Central India page, 2026-11-03, per user per month billed yearly, GST extra: Essentials Rs 6,655, Premium Rs 9,150, Team Members Rs 665. Page says the final price shows at checkout. F&SCM: not read |
| India availability | Yes |
| GST localisation | Business Central: GST, TDS, TCS, e-invoice, e-way bill. F&SCM: e-invoice and e-way bill through the IRP |

## Modules

| Area | Label | Note |
|---|---|---|
| Finance, sales, purchasing, inventory | native | Essentials |
| Service and manufacturing | native (Premium) | Pricing page |
| GST (purchase, sales, returns, RCM, SEZ, advance, stock transfer, ISD) | native | Docs list each as Available Now |
| GST reconciliation, settlement, ITC adjustment | native | Docs list |
| e-invoice, e-way bill | native | Both listed Available Now. Partner pages disagree, so check on a demo |
| TDS incl. 194Q, TCS incl. 206C(1H) | native | |
| TDS for customers | native | |
| Gate entry, subcontracting, stale cheque, fixed assets | native | India-specific modules |
| Audit trail and edit logs (India rule) | native | |
| Tax Engine | configurable | Rule engine for custom tax use cases |
| F&SCM e-invoice and IRN | configurable | Needs Electronic reporting configs, a data package from LCS, Key Vault secrets |
| F&SCM GSP file integration | native | Export and import files as fallback |
| Marketplace connectors | partner | AppSource; coverage UNVERIFIED |

## Workflows worth copying

- India feature list published page by page with status per scenario (purchase from composite vendor, RCM, SEZ, foreign vendor and so on). Good template for OneMatrix's own coverage table.
- Gate entry (inward and outward) tied to the GST flow.
- F&SCM e-invoice status page: Created, Sent, Cancel, Canceled, with action log showing portal error code.
- Direct IRP only for firms above the turnover threshold or registered on the e-way bill portal. Others go through a GSP (Microsoft doc).
- Cancelled IRN cannot be resent. Doc states a new invoice is needed.

## APIs and integrations

- Business Central: REST API v2.0, enabled by default online, OData. Extending standard API fields is not possible. Custom API pages in AL are needed (Microsoft doc).
- Webhook subscriptions and throttling were not on the page read.
- F&SCM: data entities, OData, Electronic messaging for IRP calls.
- Dynamics 365 ERP MCP server reported GA by one source. UNVERIFIED.

## Mobile

Business Central has mobile apps (general knowledge, UNVERIFIED this pass). Offline scanning UNVERIFIED.

## AI

| Item | Status |
|---|---|
| Copilot included in Business Central Essentials | Stated on pricing page. Copilot Credits sold separately. Agents need an Azure subscription |
| 2026 wave 1 agents | Many in preview (secondary source) |
| 2026 wave 2 agent items | Preview, GA expected December 2026 (Stoneridge blog) |

## Strengths (with evidence)

- Most granular India tax documentation of the products in this pass (about 70 scenario pages).
- Tax Engine allows new rules without code.
- Published price in INR for Business Central.

## Gaps (with evidence)

- Rs 6,655 per user per month is about 11 times Zoho Books Standard's per-org price. Not an SMB price point.
- Standard APIs cannot be extended with fields.
- F&SCM e-invoice setup needs ER configurations, LCS packages and Key Vault. High implementation effort.
- GSTN put the planned 2026-08-01 e-invoice and e-way bill changes on hold (Thomson Reuters via search). Watch for rule shifts.

## What OneMatrix should take from it

- Publish a scenario-by-scenario GST coverage table.
- Build a tax rule engine with versioned rules.
- Show IRP status and the portal error text next to every invoice.
- Add gate entry and subcontracting challans for the construction and manufacturing packs.

## Unknowns needing a demo

- Whether Business Central e-invoice needs a partner connector.
- F&SCM pricing in India.
- API throttling and webhook limits.
- Which Copilot and agent features are GA in India.

## Sources

- https://www.microsoft.com/en-in/dynamics-365/products/business-central/pricing (Fetched 2026-11-03)
- https://learn.microsoft.com/en-us/dynamics365/business-central/localfunctionality/india/india-local-functionality (Fetched)
- https://learn.microsoft.com/en-us/dynamics365/finance/localizations/india/apac-ind-e-invoices (Fetched)
- https://learn.microsoft.com/en-us/dynamics365/business-central/dev-itpro/api-reference/v2.0/ (Fetched)
- https://stoneridgesoftware.com/finance-and-supply-chain-management-wave-2-26-new-features/ (Search, secondary)
- https://europe.thomsonreuters.com/fr/compliance/regulatory-updates/india (Search, secondary)
