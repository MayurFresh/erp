# SAP S/4HANA Cloud (SAP SE)

Checked 2026-11-03. Confidence: low to medium. No SAP product page was fetched. Findings come from search results, including SAP Knowledge Base and SAP Community entries, and partner pages.

## Snapshot

| Field | Detail |
|---|---|
| URL | https://www.sap.com/products/erp/s4hana.html (not fetched) |
| HQ | Germany (general knowledge; not re-verified) |
| Markets | Global. India localisation exists |
| Sizes | Mid-size to enterprise. Smaller firms use SAP Business One (already in competitor-master.csv) |
| Industries | Many. Industry scope differs between Public and Private Edition (UNVERIFIED) |
| Deployment | Public Edition (multi-tenant SaaS), Private Edition (hosted). Subscription only for the cloud editions per partner sources |
| Pricing | Not published. Partner and aggregator figures conflict ($180 and $550 per user per month), so none recorded. Priced by Full User Equivalents per a partner source |
| India availability | Yes. Public Edition launched in India (insidesap.asia, eximguru) |
| GST localisation | India master data, GST tax procedures. E-invoice and e-way bill through SAP Document and Reporting Compliance, cloud edition |

## Modules

| Area | Label | Note |
|---|---|---|
| Finance, procurement, sales, inventory | native | SAP standard |
| Manufacturing, supply chain | native | Edition scope UNVERIFIED |
| India GST tax calculation | native | Tax and pricing procedures with GST |
| India e-invoice (IRN) | add-on | Document and Reporting Compliance. A Jan 2025 community thread reported e-invoice missing from the e-document cockpit on Public Edition |
| India e-way bill | add-on | Same service |
| GST returns reporting | add-on | Same service, per SAP Community blog title |
| Direct IRP integration | partner | Partner products exist (SAT Infotech listing on sap.com) |
| Extensibility | configurable | Key user tools; side-by-side on BTP (UNVERIFIED) |

## Workflows worth copying

- Compliance as a separate cockpit with document status per e-document.
- Standard process content with fixed scope items, so a rollout follows a script (SAP "Grow with SAP" content; detail UNVERIFIED).
- Clear split between key-user extension and developer extension.

## APIs and integrations

- Public APIs are published on the SAP Business Accelerator Hub (UNVERIFIED this pass; no page read).
- Integration through SAP Business Technology Platform and Integration Suite (SAP page snippet).
- Webhooks and rate limits UNVERIFIED.

## Mobile

Fiori apps run on phones and tablets (general knowledge). Native offline scanning UNVERIFIED.

## AI

| Item | Status |
|---|---|
| Joule, included with Public Edition | Included, scope depends on subscription (consultancy source) |
| Joule Studio | Reported GA Q1 2026 (partner blog) |
| Supply chain agents | Conflicting: Q1 2026 GA or Q4 2026 GA |
| Finance assistants such as revenue recognition | Early Adopter Care, GA targeted Q1 2027 (SAP Insider summary) |
| "Autonomous Suite", 200+ agents | Announced at Sapphire 2026; single secondary source |

## Strengths (with evidence)

- Compliance content kept by the vendor for India (SAP KBA collects GST, TDS, TCS, e-way bill, e-billing).
- Joule and agent roadmap is the widest of the vendors in this pass, though much is not GA.

## Gaps (with evidence)

- No published price.
- E-invoice enablement on Public Edition was questioned in a community thread (Jan 2025). May be fixed since.
- Needs partners for rollout. Not a self-serve product.

## What Progen should take from it

- Do not compete on enterprise scope. Use SAP as the upper bound and as a data export target.
- Copy the e-document cockpit: one list showing every legal document and its portal status.
- Plan an SAP-compatible CSV or OData export for customers who grow out of Progen.

## Unknowns needing a demo

- Current Public Edition India scope list.
- Pricing and minimum user count.
- Rate limits and OData coverage of public APIs.
- Which Joule features are GA in the India tenant.

## Sources

- https://userapps.support.sap.com/sap/support/knowledge/en/3318208 (Search; B1 handbook, also relevant)
- https://userapps.support.sap.com/sap/support/knowledge/en/3692370 (Search)
- https://community.sap.com/t5/enterprise-resource-planning-q-a/einv-amp-ewb/qaq-p/13999498 (Search, community)
- https://news.sap.com/2026/04/sap-business-ai-release-highlights-q1-2026/ (Search)
- https://sapinsider.org/articles/joule-is-now-the-front-door-to-your-business-what-sap-sapphire-2026-means-for-customers-vendors-and-partners/ (Search, secondary)
- https://insidesap.asia/s4hana-cloud-launched-india/ (Search)
