# Work state

Everything on the build list is done and integrated (2026-11-12): wave 2 modules, the "fix everything" round (exact discounts, warehouse auto-fill and reversals, payroll files and attendance, job-work returns, channel paging, Tally voucher types, OpenTelemetry, OpenAPI bodies) and round 3 (reverse charge, POS series, exact partial credit notes, clinic IPD with refunds, exams with remarks and co-scholastic grades, Shopify on GraphQL). 39 backend files pass (433 tests), `flutter test` 708 pass, analyze clean. Nothing committed. No agents running.

## Waiting on the owner

- Shopify test store (Admin API token, location id) and WooCommerce test store (REST keys), to run the connectors against real stores and confirm the Shopify `updated_at` filter.
- Amazon, Flipkart and Meesho seller accounts, if live connectors are wanted beyond file import.
- CA review: PF wage ceiling after October 2026, GST rate slabs, reverse charge handling in GSTR-1/3B, Form 10BD, ITC-04, TCS/TDS rates.
- Production settings (listed, commented out, in `backend/.env.example`): `DATA_KEY`, `JWT_SECRET`, database passwords, an SMTP mail account, a WhatsApp Business Cloud API phone id and token, the public app and API addresses.
- Hosting choice, domain, product name, and one or two pilot businesses.

## Not planned unless asked

ICU charting; moving grants received before the liability change out of income.
