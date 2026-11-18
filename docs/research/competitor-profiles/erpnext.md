# ERPNext (Frappe Technologies)

Checked 2026-11-03. Confidence: medium. Pricing, REST API and India GST docs read. Other modules and AI from search results.

## Snapshot

| Field | Detail |
|---|---|
| URL | https://frappe.io/erpnext |
| HQ | India (Mumbai); not re-verified on a fetched page |
| Markets | Global. India is the home market |
| Sizes | SMB to mid-size. 200+ listed partners (Frappe pricing page claim) |
| Industries | Manufacturing, distribution, retail, services, education, healthcare modules (UNVERIFIED per module) |
| Deployment | Frappe Cloud (SaaS), or self-host. GPL-3.0 |
| Pricing | Software is free. Frappe Cloud hosting from $5 (Rs 410) per month per site, $20 (Rs 1,800) entry servers, $125 (Rs 5,400) higher tier, Enterprise by quote. Not priced per user. 14-day trial. Implementation not priced |
| India availability | Yes |
| GST localisation | Provided by the separate India Compliance app, not core ERPNext |

## Modules

| Area | Label | Note |
|---|---|---|
| Accounting, stock, buying, selling | native | Core |
| Manufacturing, BOM, MRP | native | v16 adds inward subcontracting and MRP changes (search result) |
| HR and payroll | native (HRMS app) | Separate app; UNVERIFIED for Indian statutory payroll |
| GST, HSN, reverse charge, SEZ, export | add-on | India Compliance app, free and open source |
| e-invoice (IRN) | add-on | India Compliance. API credits on self-hosted sites |
| e-way bill | add-on | From Delivery Note, Stock Entry, purchase return. Extend and cancel supported |
| GSTR-1 | add-on | Generate, compare and file |
| GSTR-2A and 2B purchase reconciliation | add-on | Includes ITC claim period lock after GSTR-3B |
| GSTR-9, 6, 7 | no (not evidenced) | Docs say not generated; use reports and file on portal |
| TDS and TCS | add-on | v16.3.1+ maps categories to Income Tax Act 2025 sections |
| Custom fields, workflows | native | DocType model |

## Workflows worth copying

- One address per GSTIN. Transactions pick the GSTIN from the company address.
- GST Settings screen with HSN length checks.
- ITC Claim Period that blocks edits to periods already filed in GSTR-3B.
- Sandbox mode for IRN and e-way bill before production.
- Every record is a DocType, so any field is reachable through the REST API.

## APIs and integrations

- REST: `GET/POST/PUT/DELETE /api/resource/:doctype`, whitelisted methods under `/api/method/`, file upload.
- Auth: token (`api_key:api_secret`), session cookie, OAuth bearer.
- Rate limits and webhooks were not on the page read. Frappe has a Webhook doctype (UNVERIFIED this pass).
- Third-party MCP servers exist (search result). Not an official feature.

## Mobile

Frappe has mobile apps for some products. ERPNext mobile status UNVERIFIED this pass.

## AI

No native AI feature found in v16 sources. Third-party MCP servers and agents exist. Treat as not GA from Frappe.

## Strengths (with evidence)

- Cost: free software, per-site hosting rather than per-user (pricing page).
- GST depth: e-invoice, e-way bill, GSTR-1 and 2B reconciliation in documented flows (India GST help page).
- Open source: customisable at any layer.
- Version 16 released 2026-01-12 (Frappe Times via search).

## Gaps (with evidence)

- India compliance depends on a separate community app with its own credit-based API access for self-hosting.
- GSTR-9, 6, 7 not generated.
- No published implementation prices. Quality varies by partner (UNVERIFIED, general market view).
- No native AI found.

## What OneMatrix should take from it

- Treat GST as a product surface, not a plugin: settings page, sandbox, failure queue.
- Block edits to filed periods.
- Charge for API calls to the government portal transparently, or absorb them.
- Per-site or per-company pricing is a credible alternative to per-user.

## Unknowns needing a demo

- Webhook support and rate limits.
- India Compliance API credit prices.
- Mobile apps and offline use.
- Marketplace connectors and settlement reconciliation.

## Sources

- https://frappe.io/erpnext/pricing (Fetched 2026-11-03)
- https://docs.frappe.io/erpnext/india-gst-help (Fetched)
- https://docs.frappe.io/framework/user/en/api/rest (Fetched)
- https://frappecloud.com/marketplace/apps/india_compliance (Search)
- https://frappe.io/erpnext/version-16 (Search)
- https://frappe.io/times/january-2026 (Search)
