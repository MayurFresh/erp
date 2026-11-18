# Unicommerce Uniware (Unicommerce eSolutions)

Checked 2026-11-03. Confidence: medium. API docs were read. Pricing and AI status come from third parties and press.

## Snapshot

| Item | Detail |
|---|---|
| URL | https://unicommerce.com ; docs at https://documentation.unicommerce.com |
| HQ | India (listed company) |
| Markets | India first; some South and Southeast Asia and Middle East (UNVERIFIED list) |
| Sizes | D2C brands, marketplace sellers, 3PLs, large retail |
| Deployment | SaaS |
| Pricing | Order-volume plans. See commerce-pricing note below |
| India availability | Yes. Built for Indian marketplaces and couriers |

Pricing: the existing pricing-matrix.csv has a Growth tier (10 to 5,000 orders per month) and Enterprise. No new official price was found this round.

## Modules

| Module | Status |
|---|---|
| Order management | native |
| Warehouse management | native |
| Inventory sync to channels | native |
| Handheld picking, sorting, packing | native (documented) |
| Lot and batch selection at pick | configurable |
| Wave, batch, cluster picking | configurable (marketing page only) |
| Serial numbers | unverified |
| Bundles and kits | unverified |
| Courier allocation | native (ShipSense AI, company disclosure) |
| Returns | native (UNVERIFIED depth) |
| Accounting | no (not evidenced) |
| Marketplace settlement | unverified |

## Order-to-settlement workflow

1. Channel orders arrive by connector, or by the Create Sale Order API.
2. Orders are allocated to a facility and a picklist is made.
3. Handheld devices guide batching, picking, sorting and packing.
4. A courier is assigned and a label is printed.
5. Status goes back to the channel through the Post Status Notification API.
6. Returns are received at the facility.
7. Settlement matching: UNVERIFIED. Not seen in docs read.

## APIs, webhooks and integrations

- REST API, OAuth. A Uniware username and password are needed to get a token.
- Create Sale Order: POST /services/rest/v1/oms/saleOrder/create with header Authorization: bearer token.
- A Facility Code header is required on facility-level APIs.
- Post Status Notification pushes item status (CREATED, PICKING, PICKED and so on) to a channel. It uses an apiKey header. Replies are SUCCESS, FAILED or PARTIAL_SUCCESS.
- Post Orders API for marketplaces uses a static security key.
- No general webhook subscription docs found. No sandbox or rate limit text found.

## Mobile and scanning

- Handheld flows for batching, picking, sorting and packing are documented.
- Offline scanning: UNVERIFIED.
- Serial capture: not evidenced.

## AI

| Item | Status |
|---|---|
| UniGPT | pilot, March 2024 |
| ShipSense courier allocation | stated as launched around Q2 FY26 |
| UniBot GenAI ops copilot | announced 12 Dec 2025; Hindi and English; GA unclear |
| ConvertWay Catalyst voice agent | Jan 2026; separate product |

Management says the company is becoming AI-first. Treat all items as announced until a demo shows them in production.

## Strengths (with evidence)

- Public API docs with named endpoints and a status push API.
- Handheld flows documented in official docs.
- Many Indian marketplace connectors (vendor claim).
- Listed company, so disclosures exist.

## Gaps (with evidence)

- No sandbox or rate limit text in the docs read.
- No webhook subscription model found. Status push is per channel.
- Serial and bundle handling not evidenced.
- Needs a user password to get an API token. This is a weak fit for service accounts.
- Wave picking is only on a marketing page.

## What OneMatrix should take from it

- Facility code on every warehouse-level API call.
- A status push per channel with clear result codes.
- Handheld pick flows that guide batching and sorting.
- Offer a proper webhook subscription and a sandbox. Unicommerce docs do not show either.

## Unknowns needing a demo

- Settlement and TCS matching depth.
- Webhooks, sandbox, rate limits.
- Bundle, serial, FEFO rules.
- Offline scanning.
- Which AI items are GA.
- Real price for 1,000 and 10,000 orders per month.

## Sources

- https://documentation.unicommerce.com/
- Company press releases and Q3 FY26 call notes (search results)
- docs/research/pricing-matrix.csv
