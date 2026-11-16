# Work state

Wave 2 is committed as 24435aa on `main` and pushed. Wave 3, the build order from `docs/research/coverage-review-2026-11.md`, was built and integrated on branch `idea/crm` on 2026-11-16. It is not committed. It adds CRM (layout A), quotations, purchase returns with credit limits, receivables, pricing, statutory payroll, claims and loans, GST compliance, TDS forms, finance reports, stock valuation, landed cost and RFQ, helpdesk and timesheets, export, currency, challans and TCS, and platform extras. The dev DB is migrated to 057. 55 backend files pass (590 tests). `flutter test` passes 941. Analyze is clean. No agents are running.

## Next

The owner decides whether to commit and merge `idea/crm`. Known gaps from wave 3:
- Stock: the unit picker is not in the line forms, and PDFs don't show the entered unit. Items have no MRP field. A transfer-in restarts stock age. Quotation convert drops the entered unit.
- Payroll: the ECR export uses the built-in EPF ceiling (the owner declined that change). September 2026 uses the 15,000 ceiling, with no split month. There is no gratuity provision journal.
- Claims and loans: recovery is not capped at net pay, and foreclosure takes principal only.
- Finance: there is no "Print cheque" button on payment detail. Cash flow and ratios have no export.
- Export: 206C(1H) is not built. Rule 46 and 55 wording comes from secondary sources. TCS rates and the 206CC rule come from memory (TCS is off by default). There are no e-invoice export/SEZ types and no revaluation of payables. Credit notes don't reverse TCS.
- Landed cost: the form has no expense or vendor-bill source picker.
- Helpdesk: there is no photo or signature upload. SLA doesn't pause while waiting on the customer. Visit parts don't move stock.
- Platform: Cashfree is not built, and the MSG91 body shape is unverified.

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
