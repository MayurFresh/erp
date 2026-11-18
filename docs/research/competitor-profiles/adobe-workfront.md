# Adobe Workfront (Adobe)

Checked 2026-11-03. Confidence: medium for pricing model and Proof API, low for module depth. The Adobe pricing page timed out on direct fetch. Facts come from Experience League docs, search summaries and Adobe's product description.

## Snapshot

| Field | Value |
| --- | --- |
| Segment | Enterprise work management for marketing and creative teams |
| Plans | Select, Prime, Ultimate (Ultimate adds automation and data management over Prime) |
| Pricing published | No. Official regional pages show "Get pricing" or contact sales. Adobe's product description sets a per-user, per-year licence metric. Third-party estimates of $30-$99 per user per month are unverified. |
| India availability | An Adobe India pricing page exists (business.adobe.com/in). Local support and billing: UNVERIFIED. |

## Modules

| Module | Label | Evidence |
| --- | --- | --- |
| Projects, tasks, requests | native | Adobe docs |
| Resource management (capacity and workload at project and global level) | native, plan dependent | Adobe pricing page |
| Proofing (built in) | native | Experience League |
| Workfront Proof (standalone product) | separate product with its own API | Experience League |
| Workfront Fusion (automation, apps and modules) | native or add-on: UNVERIFIED | Experience League |
| Planning, portfolio, financials | UNVERIFIED | not confirmed |
| Adobe Creative Cloud and Experience Manager connectors | partner or native: UNVERIFIED | not confirmed |

## Workflows worth copying

- Request intake to project, with brief and deliverables captured on the request.
- Proof with versions, comments and decisions (approve, approve with changes, deny).
- Automating routing of assets between tools through Fusion scenarios.
- Resource planning by capacity against project load.

## APIs and integrations

- Workfront Proof API exists. Fusion has Workfront Proof modules, and a custom API call module for actions that other modules do not cover.
- Fusion can call the Workfront API through HTTP modules (community posts, not official guidance).
- Full Workfront API scope, webhooks: UNVERIFIED in this pass.
- A community post says Fusion automation of approve, deny and approve-with-changes was planned. No confirmation it shipped.

## Mobile and devices

- UNVERIFIED.

## AI

- GA: none confirmed.
- Announced or gated: an AI reviewer for proofs. A Q4 2025 release webinar Q&A says it needs Adobe IMS migration, Unified Approvals and the Adobe Gen AI agreement. Legal claims and copy-guideline checks were on the roadmap with no date.

## Strengths (evidence)

- Proofing and approvals are first-class and scriptable (Proof API, Fusion modules).
- Capacity-based resource management is in the pricing grid.

## Gaps (evidence)

- No published price. Per-user per-year licensing.
- AI reviewer has prerequisites that suggest migration work.
- No evidence of invoicing or project accounting. Workfront is not an ERP.

## What OneMatrix should take from it

- Reuse OneMatrix approvals for creative sign-off: a deliverable has versions, each version has reviewers and a decision.
- Link a project to a client invoice and to a cost centre. Workfront does not do this, so it is a OneMatrix advantage.
- Do not build proofing markup. Link to files and record decisions.
- See docs/research/industry-workflows/media-creative.md.

## Unknowns needing a demo

- Approval states and who can override.
- Resource management detail and rate cards.
- Fusion licensing and run limits.
- Financial and budget tracking per project.
- Indian pricing and billing in INR.

## Sources

- https://experienceleague.adobe.com/en/docs/workfront/using/adobe-workfront-fusion/fusion-apps-and-modules/workfront-proof-modules
- https://experienceleague.adobe.com/en/docs/workfront/using/workfront-proof/wf-proof-integrations/wf-proof-api/workfront-proof-api
- https://business.adobe.com/products/workfront/pricing
- https://helpx.adobe.com/my_en/legal/product-descriptions/adobe-workfront.html
- https://experienceleaguecommunities.adobe.com/workfront-23/event-follow-up-adobe-workfront-fourth-quarter-2025-release-webinar-133506
- https://thedigitalprojectmanager.com/tools/adobe-workfront-pricing/ (secondary)
