# Work state

Wave 2 is committed as 24435aa on `main` and pushed. Wave 3, the build order from `docs/research/coverage-review-2026-11.md`, was built and integrated on 2026-11-16, then committed as cfcffad, merged into `main` and pushed. It adds CRM (layout A), quotations, purchase returns with credit limits, receivables, pricing, statutory payroll, claims and loans, GST compliance, TDS forms, finance reports, stock valuation, landed cost and RFQ, helpdesk and timesheets, export, currency, challans and TCS, and platform extras. Wave 4 (below) integrated on 2026-11-18: dev DB migrated to 061, 59 backend files pass (615 tests), `flutter test` passes 975 (23 skipped: live tests and the icon renderer), analyze and tsc clean, wave 4 screens checked headless at 320 and 1440 with no API or console errors. No agents are running.

## Next

Wave 4 (2026-11-18): renamed to OneMatrix (domain onematrix.site, app id `site.onematrix.app`) and closed the wave 3 gaps: line units, MRP and stock age (058); gratuity provision, loan recovery cap and foreclosure interest (059); print cheque, cash flow and ratios export, export/SEZ e-invoice types, payables revaluation, TCS reversal on credit notes, landed cost sources (060); visit photos and signature, SLA pause, visit parts stock and ledger, Cashfree, MSG91 body fix (061). Section 206C(1H) was not built: the Finance Act 2025 switched it off from 1 April 2025.

Known gaps:
- Stock: transfers made before 058 have no layer dates, so their age restarts as before. The bill preview (`POST /purchases/preview`) does not return entered unit fields.
- Payroll: the ECR export uses the built-in EPF ceiling (the owner declined that change). September 2026 uses the 15,000 ceiling, with no split month. Gratuity cap is the company setting, not a dated rate. Foreclosure interest is for reducing-balance loans only. Fixed-term staff gratuity after one year (Code on Social Security) is not modelled.
- Export: Rule 46 and 55 wording comes from secondary sources. TCS rates and the 206CC rule come from memory (TCS is off by default). E-invoice `CntCode` is left out when the country is not a known ISO code or name. Purchase bill detail has no "tag currency" button; tagging is on the foreign payables screen.
- Shell (web, wide layout, older than wave 4): after an in-app navigation to a page whose menu entry is scrolled out of view, the previous entry can stay highlighted. Widget tests with the same routes clear it correctly, so it is web-only; not fixed yet.
- Platform: Cashfree is untested against a real account and ignores partial payments. The "Collect online" provider chooser has no widget test.

## Waiting on the owner

- Shopify test store (Admin API token, location id) and WooCommerce test store (REST keys), to run the connectors against real stores and confirm the Shopify `updated_at` filter.
- Amazon, Flipkart and Meesho seller accounts, if live connectors are wanted beyond file import.
- CA review: EPF ceiling of 25,000 from 17 Sep 2026 (S.O. 5109(E)) against the Gazette, the Labour Code 50% wages rule, bonus eligibility and ceiling (S.O. 4710/4711(E)), GST rate slabs, reverse charge handling in GSTR-1/3B, Form 10BD, ITC-04, TCS 206C(1) rates and 206CC, rule 46 and 55 wording, and the TCS section label under the Income-tax Act 2025.
- Razorpay account (test keys are enough to try) and its webhook secret. Cashfree, if wanted.
- SMS: DLT registration (entity, sender name, approved templates) and an MSG91 or other provider key. IndiaMART CRM key. WhatsApp per-message billing in INR and approved templates.
- Production settings (listed, commented out, in `backend/.env.example`): `DATA_KEY`, `JWT_SECRET`, database passwords, an SMTP mail account, a WhatsApp Business Cloud API phone id and token, the public app and API addresses.
- Hosting choice, domain, product name, and one or two pilot businesses.

## Not planned unless asked

ICU charting; moving grants received before the liability change out of income.
