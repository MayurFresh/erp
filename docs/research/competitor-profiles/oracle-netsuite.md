# Oracle NetSuite (Oracle)

Checked 2026-11-03. Confidence: medium. India docs from Oracle help pages via search and one fetch. The NetSuite price page returned 403.

## Snapshot

| Field | Detail |
|---|---|
| URL | https://www.netsuite.com |
| HQ | USA (general knowledge) |
| Markets | Global. India through localisation SuiteApps |
| Sizes | Mid-size and growing firms (vendor positioning; UNVERIFIED) |
| Industries | Horizontal plus industry editions (UNVERIFIED) |
| Deployment | SaaS only |
| Pricing | Not published. Page blocked (403). Nothing recorded |
| India availability | Yes, through the India Localization SuiteTax Engine |
| GST localisation | GST, TDS, TCS, e-invoice, e-way bill, B2C QR invoices (Oracle help) |

## Modules

| Area | Label | Note |
|---|---|---|
| Financials, order to cash, procure to pay, inventory | native | Vendor standard |
| SuiteTax engine | configurable | Must be enabled. Accounts without SuiteTax use Legacy Tax |
| India GST calculation | add-on | India Localization SuiteTax Engine SuiteApp. Contact account manager to set up |
| TDS, TCS (206C) | add-on | Same SuiteApp. TDS challan vouchers |
| e-invoice | add-on | Generate, certify, send via GSP and IRP |
| e-way bill | add-on | Older docs: EWB-01 form only, CSV export for upload. Check the current state |
| GSTR returns | unverified | Tax Reporting Framework installs after the Engine; return coverage not read |
| Partner GST SuiteApps | partner | Saral GSP, Yantra, Riveron (search) |
| Customisation | configurable | SuiteScript, SuiteFlow, custom records |

## Workflows worth copying

- Fixed install order: Engine, then Tax Reporting Framework, then localisation. Avoids half-configured tenants.
- Localization Assistant SuiteApp to manage localisation pieces.
- Statutory adjustment journals generated for export transactions.
- LUT bond detail alerts by email.

## APIs and integrations

- SuiteTalk (REST and SOAP), RESTlets, SuiteScript: general knowledge, not read this pass.
- SuiteCloud AI Connector over MCP; Oracle help says it is not a paid feature and MCP Standard Tools SuiteApp is free (secondary source). More than 13,000 customers use it (Diginomica via search).
- Marketplace: SuiteApp Marketplace.

## Mobile

NetSuite has a mobile app (general knowledge). UNVERIFIED this pass.

## AI

| Item | Status |
|---|---|
| AI Connector service (MCP) | Available; upgrades March 2026 |
| SuiteSkills, AI Portlets, first industry SuiteAgents | Press release says available. Keynote called them upcoming. Conflict |
| NetSuite Next, Ask Oracle | US and Canada first, UK starting. India availability not evidenced |

## Strengths (with evidence)

- Localisation maintained by Oracle as a SuiteApp with documented e-invoice and e-way bill.
- Open MCP access to data for external AI clients.

## Gaps (with evidence)

- E-way bill doc says EWB-01 only with CSV export (older help page). Direct API generation may need a partner SuiteApp.
- Partner says automated e-invoice API may need a paid SuiteApp (Aaxonix). Oracle docs call the Engine free. Conflict.
- No published price. Setup goes through an account manager.
- NetSuite Next not evidenced for India.

## What Progen should take from it

- Treat the MCP connector as a pattern. Progen should expose its data to Claude and ChatGPT through MCP early.
- Ship tax localisation as versioned, installable bundles.
- Do not copy the CSV-upload e-way bill path. Direct API is the baseline.

## Unknowns needing a demo

- Current e-way bill and GSTR support in the SuiteApp.
- Price of the SuiteApp and any GSP fees.
- Whether NetSuite Next is open in India.
- Editions and minimum contract.

## Sources

- https://docs.oracle.com/en/cloud/saas/netsuite/ns-online-help/section_1543359686.html (Fetched)
- https://docs.oracle.com/en/cloud/saas/netsuite/ns-online-help/section_160007282193.html (Search)
- https://docs.oracle.com/en/cloud/saas/netsuite/ns-online-help/section_1548723858.html (Search)
- https://aaxonix.com/resources/?p=1279 (Search, partner)
- https://www.brokenrubik.com/blog/suiteworld-2026-announcements (Search, secondary)
- https://diginomica.com/node/31365 (Search, secondary)
