# Epicor Kinetic (Epicor Software)

Checked 2026-11-03. Confidence: low to medium. Epicor product and press pages returned 403. Facts come from search summaries of Epicor articles and third-party listings.

## Snapshot

| Field | Value |
| --- | --- |
| Segment | Mid-market discrete manufacturing ERP |
| Deployment | Cloud and other options (UNVERIFIED which) |
| India availability | UNVERIFIED. The Prism launch news found covers Europe, Australia and New Zealand, and Latin America. India not mentioned. |
| Pricing published | No (not found) |

## Modules

| Module | Label | Evidence |
| --- | --- | --- |
| Financial management | native | erpfocus listing |
| Supply chain, inventory, purchasing | native | erpfocus listing |
| Production management | native; may need extra licence | erpresearch guide |
| Advanced MES | native; may need extra licence | erpresearch guide |
| Planning and scheduling | native; may need extra licence | erpresearch guide |
| Quality management | native | erpresearch guide |
| Service, project management, CRM, analytics, compliance | native | erpfocus listing |
| Prism (embedded AI) | native, see AI | Epicor release |
| Grow Data Platform and Grow AI | UNVERIFIED; one podcast transcript only | SourceForge podcast |

## Workflows worth copying

- Work order execution with variance reporting (one third-party comparison praises this for Infor, not Kinetic; do not treat as Kinetic evidence).
- Shop-floor reporting through MES tied to production management.
- Finite scheduling after MRP.

These are generic discrete-manufacturing flows. Kinetic-specific screens: UNVERIFIED.

## APIs and integrations

- Public REST or webhook documentation: UNVERIFIED in this pass.
- Marketplace and partner connectors: UNVERIFIED.

## Mobile and devices

- UNVERIFIED.

## AI

- GA (per Epicor): Prism, embedded in Kinetic, conversational access to ERP data, "more than 18 pre-built agents" per Epicor. Launched in Europe (July 2026 coverage), Australia and NZ, and Latin America.
- Agents are industry specific. Epicor says Kinetic agents differ from those for Prophet 21 (distribution).
- Announced or unclear: "Grow" platform and agents. No source defines them as a product.

## Strengths (evidence)

- Broad manufacturing coverage from finance to MES in one vendor.
- Embedded AI agents with regional rollout across several markets in 2026.

## Gaps (evidence)

- Extra licences for some manufacturing modules (erpresearch guide).
- No India evidence found.
- Pricing not published.

## What OneMatrix should take from it

- Build in the order: BOM, work order, material issue, finished goods, cost roll-up. Skip MES and finite scheduling at first.
- Keep AI as a read-only assistant over production data after the data model exists.
- Use Kinetic's module split as a checklist, not a target.
- See docs/research/industry-workflows/manufacturing.md.

## Unknowns needing a demo

- Costing method (standard, actual, both).
- Subcontract and job-work support.
- Lot and serial traceability depth.
- API style, auth and limits.
- India tax localisation, if any.

## Sources

- https://www.epicor.com/en-us/newsroom/news-releases/prism-launches-across-european-markets/ (403 on fetch; read through search summary)
- https://epicor.com/en/blog/supply-chain-management/understanding-vertical-ai-agents-in-manufacturing-erp
- https://erpfocus.com/epicor-kinetic-erp.html (secondary)
- https://erpresearch.com/en-gb/epicor-kinetic-for-manufacturing (secondary)
- https://sourceforge.net/articles/?p=24127 (podcast, secondary)
