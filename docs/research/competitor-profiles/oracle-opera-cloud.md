# OPERA Cloud (Oracle Hospitality)

Checked 2026-11-03. Confidence: medium for the integration platform (Oracle docs read), low for module depth and India fit.

## Snapshot

| Field | Value |
| --- | --- |
| Segment | Hotel PMS for chains and large properties |
| Vendor | Oracle (Hospitality and Food and Beverage units) |
| Legacy products | OPERA 5 and Suite8 use a separate approval-based partner programme (third-party analysis) |
| India availability | UNVERIFIED. Oracle sells globally, but no India GST or tax page was read. |
| Pricing published | No (not found) |

## Modules

| Module | Label | Evidence |
| --- | --- | --- |
| Front office | native | hoteltechreport listing |
| Accounting and finance | native | hoteltechreport listing |
| Marketing and e-commerce | native | hoteltechreport listing |
| Customer management (profiles) | native | hoteltechreport listing |
| Administration and housekeeping, maintenance | native | hoteltechreport listing |
| Mobile companion app | native | hoteltechreport listing |
| Simphony (restaurant POS) | separate product, interfaced | Oracle Simphony page; 180 countries claimed |
| Revenue management, sales and catering, central reservations | UNVERIFIED | not confirmed in this pass |

## Workflows worth copying

- Interface events at check-in, check-out and room move, pushed to POS, door locks and telephony (IFC8 page).
- Posting a POS charge to a guest room through an inbound API call.
- Profile-centric guest history across properties.

## APIs and integrations

- OHIP (Oracle Hospitality Integration Platform) is the self-service API layer for OPERA Cloud. Oracle states more than 3,400 API capabilities for early adopters (Oracle page, via search).
- Postman collections and API specs are in the GitHub repo oracle/hospitality-api-docs. Oracle says specs there are the most current.
- IFC8 interface: inbound REST actions (post charge, guest inquiry, room status, wake-up, balance), outbound streaming (check-in, check-out, room move), and synchronous calls (door key make and delete). It uses FIAS and XML-POS messages.
- Third-party guide: OHIP needs host name, application key, hotel ID, and OAuth client ID and secret.
- Announced, not GA: a push-based business-events API over WebSocket (Oracle said it is preparing it).

## Mobile and devices

- Companion mobile app for staff and guest service. Detail UNVERIFIED.

## AI

- GA: none confirmed.
- Announced: none confirmed.

## Strengths (evidence)

- Largest documented hotel API surface found in this pass.
- Standard interface protocols (FIAS) that many third parties already support.

## Gaps (evidence)

- Heavy product for small Indian hotels (this is an inference; no Oracle statement on SME fit).
- Pricing and India tax handling not found.

## What OneMatrix should take from it

- Define a small set of outbound hotel events (check-in, check-out, room move, charge posted) before building any integrations.
- Keep a charge-posting endpoint so a restaurant pack can post to a room folio.
- Do not copy the breadth. A 30-100 room Indian hotel needs far less.
- See docs/research/industry-workflows/hospitality.md.

## Unknowns needing a demo

- Night audit and business-date rollover.
- Block and group handling.
- India localisation: GST on room tariff slabs, SAC codes, e-invoice.
- Licence model for small hotels.

## Sources

- https://docs.oracle.com/en/industries/hospitality/integration-platform/ifcig/c_overview.htm
- https://oracle.com/hospitality/integration-platform/focus-on-oracle-hospitality-integration-platform
- https://www.oracle.com/hospitality/integration-platform/changing-the-game-in-hospitality-integrations/
- https://www.oracle.com/food-beverage/restaurant-pos-systems/simphony-pos/
- https://www.altexsoft.com/blog/opera-pms-integration (secondary)
- https://hoteltechreport.com/operations/property-management-systems/opera-pms (secondary)
