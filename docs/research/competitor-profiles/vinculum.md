# Vinculum Vin eRetail (Vinculum Solutions)

Checked 2026-11-03. Confidence: medium. Swagger and helpdesk seen. Prices not published.

## Snapshot

| Item | Detail |
|---|---|
| URL | https://www.vinculumgroup.com ; Swagger at https://erp.vineretail.com/swagger |
| HQ | India |
| Markets | India, Middle East, Southeast Asia (vendor, UNVERIFIED) |
| Sizes | Mid-market and enterprise retail and brands |
| Deployment | SaaS |
| Pricing | Not published |
| India availability | Yes |

## Modules

| Module | Status |
|---|---|
| OMS | native |
| WMS | native |
| Seller Panel | native |
| Batch-wise inventory | native |
| Serial and IMEI capture | native (Aug 2024 release note) |
| Batch and wave picking | configurable (vendor claim) |
| Bundles | unverified |
| Returns | unverified |
| Settlement | unverified |
| Accounting | no (not evidenced) |

## Order-to-settlement workflow

1. Orders enter from channels into the Seller Panel or WMS.
2. Orders are allocated and picked.
3. Camera scan captures IMEI or serial at pick.
4. Shipping and tracking events post back.
5. Webhooks tell outside systems about status changes.
6. Returns and settlement: UNVERIFIED.

## APIs, webhooks and integrations

- Swagger at erp.vineretail.com/swagger.
- Webhooks are registered in Admin > Miscellaneous > Manage API > Register Webhook.
- Choose the source (WMS or Seller Panel), an API category such as Orders, and events. No events selected means all status changes.
- Custom headers are pipe separated (for example x-api-key).
- Payload is Full or Partial, in JSON or XML. A webhook has an Active flag.
- Retry policy is not documented.

## Mobile and scanning

- Android app.
- Camera scan for IMEI or serial at receiving and picking (Aug 2024 release note).
- A G2 reviewer in Dec 2022 called mobile functions limited. This is old.

## AI

No official AI evidence found. Mark unverified.

## Strengths (with evidence)

- Webhook registration UI with event filters and header control.
- Serial scan by camera, useful for electronics.
- Batch-wise inventory.

## Gaps (with evidence)

- Webhook retry policy not documented.
- Pricing not published.
- Wave picking is a vendor claim only.
- Older reviews note mobile limits.

## What Progen should take from it

- A webhook form with source, category, events, headers and payload size.
- Camera scan for serial numbers.
- Treat empty event selection as all events only if the UI says so clearly.

## Unknowns needing a demo

- Webhook retry and signing.
- Bundle and kit handling.
- Settlement and TCS.
- Offline scanning.
- Price band.

## Sources

- https://erp.vineretail.com/swagger
- https://vinculumhelpdesk.freshdesk.com/ (webhook registration, batch inventory)
- Vinculum Aug 2024 release note
