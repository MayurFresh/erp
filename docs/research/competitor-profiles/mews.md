# Mews (Mews Systems)

Checked 2026-11-03. Confidence: medium for API auth, low for modules and pricing. The Connector API authentication page was read. Module lists come from third-party summaries.

## Snapshot

| Field | Value |
| --- | --- |
| Segment | Cloud hotel PMS and guest platform |
| HQ | Amsterdam per third-party listings. Offices in Europe, US and Australia. |
| Scale claims | 85 countries. Customer counts vary by source (5,000, 12,500 and 15,000 appear). |
| India availability | UNVERIFIED. No India office or India customer count found. |
| Pricing published | No (not found) |

## Modules

| Module | Label | Evidence |
| --- | --- | --- |
| PMS: reservations (individual and group), housekeeping, front office, rate management, accounting | native | third-party summaries |
| Mews Payments (gateway in PMS, 10+ methods, 40+ countries claimed) | native | third-party summary |
| POS | native product in the suite | third-party summary |
| Revenue management (RMS) | native product in the suite | third-party summary |
| Flexkeeping (housekeeping and operations) | acquired, now in the suite | third-party summary |
| Booking engine, channel manager API | native | Mews API page via search |
| Online check-in, upsell, guest journeys | native | third-party summary |
| Marketplace of 1,000+ integrations | partner | Mews tier list via search |

## Workflows worth copying

- Reservation, stay and bill sit in one record, with accounting items posted per outlet.
- Settlement rules and central payment reconciliation inside the PMS.
- Online check-in and upsell before arrival.
- Housekeeping tasks on mobile (Flexkeeping).

## APIs and integrations

- Connector API. Requests carry ClientToken, AccessToken and Client name in the body. The AccessToken is per enterprise (property). Portfolio tokens cover many enterprises.
- Public demo tokens exist. Production use requires a certification process.
- Open API, Booking Engine API, Channel Manager API and Connector API are listed on the product page. Tier availability: UNVERIFIED.
- Webhooks, rate limits: UNVERIFIED (page not found in this pass).
- Docs expose a sitemap and a full-text export (docs.mews.com/llms-full.txt), useful for the next pass.

## Mobile and devices

- Mobile app and kiosk payments are mentioned for payments. Native staff app details: UNVERIFIED.

## AI

- GA: none confirmed.
- Announced: none confirmed.

## Strengths (evidence)

- Documented, token-based, per-property API with a public demo environment.
- Payments and POS in the same product as the PMS.

## Gaps (evidence)

- No evidence of India GST handling, Indian payment methods or Indian support.
- Pricing not published.

## What Progen should take from it

- Model a property as a tenant-scoped entity, with one token per property if an API is ever offered.
- Post all outlet charges to the guest folio through accounting items. Progen's journal engine can do this.
- Keep payments abstract. Do not build a gateway.
- See docs/research/industry-workflows/hospitality.md.

## Unknowns needing a demo

- Folio split and transfer rules.
- Group block and allotment handling.
- Night audit steps and what posts to accounting.
- Webhook events and rate limits.
- Any India deployment or tax localisation.

## Sources

- https://docs.mews.com/connector-api/guidelines/authentication
- https://beta.mews.com/en/products/api (redirects to staging.mews.com)
- https://www.getapp.com/hotel-management-software/a/mews (secondary)
- https://hoteltechreport.com/compare/mews-vs-hotelogix-hms-vs-cloudbeds-myfrontdesk (secondary)
