# EasyEcom (EasyEcom Technologies)

Checked 2026-11-03. Confidence: medium. Support site read. Prices not official.

## Snapshot

| Item | Detail |
|---|---|
| URL | https://www.easyecom.io ; support at https://support.easyecom.io |
| HQ | India |
| Markets | India; some overseas (UNVERIFIED) |
| Sizes | Small and mid sellers, D2C brands |
| Deployment | SaaS |
| Pricing | Starter, Growth, Enterprise. Charged per order by recharge slab |
| India availability | Yes |

The support page links to easyecom.io/pricing and /pricing-india/ but gives no INR or USD figure. Third-party figures conflict, so none are recorded here.

## Modules

| Module | Status |
|---|---|
| Multichannel order sync | native |
| SKU mapping | native |
| Bundles and combos | native (existing matrix) |
| Inventory sync | native, per location |
| Warehouse and GRN | native (GRN webhooks exist) |
| Shipping and manifest | native (manifested and RTD webhooks) |
| Returns | native (mark return webhook) |
| Mobile app | unverified |
| Settlement reconciliation | unverified |
| Accounting | unverified |

## Order-to-settlement workflow

1. Orders sync from channels and appear as created.
2. A user or rule confirms the order.
3. Inventory updates per location.
4. Order is packed and manifested.
5. Ready to dispatch, tracking updates.
6. Returns are marked on receipt.
7. Settlement: UNVERIFIED.

## APIs, webhooks and integrations

- Since 22 July 2023 every API call needs a JWT token and an X-API-Key header.
- 12 webhooks: create order V1 and V2, confirm order, update inventory, manifested, mark return, GRN details, complete GRN, RTD, tracking, confirm order start, fetch order, cancel order.
- The token goes in an Access-Token header.
- Retries are not documented. Trigger history in the panel shows 2 days.
- Meesho is a client-level integration: you email the Meesho team to enable it.

## Mobile and scanning

UNVERIFIED. No official page read.

## AI

No AI evidence found on official pages read.

## Strengths (with evidence)

- A long named webhook list for orders, GRN and inventory.
- Bundles are native in the existing matrix.
- Two-factor API security (JWT plus API key) since 2023.

## Gaps (with evidence)

- Retry policy not documented.
- No official price on the support page.
- No AI evidence.
- Mobile app unverified.

## What Progen should take from it

- Webhooks per business event, including GRN and manifest.
- Per-location inventory events.
- Show webhook trigger history in the panel. Progen should keep it longer than 2 days.

## Unknowns needing a demo

- Webhook retry and signing.
- Settlement and TCS matching.
- Mobile and scanning.
- Real order slab prices.
- Marketplace coverage by channel.

## Sources

- https://support.easyecom.io/ (webhook-conf article; API auth notice)
- https://support.easyecom.io/portal/en/kb/articles/integrating-meeshoapi-with-easyecom
- docs/research/pricing-matrix.csv
