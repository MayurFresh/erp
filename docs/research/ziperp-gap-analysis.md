# ZipERP comparison and enterprise readiness

**Checked:** 3 Nov 2026, against 15 pages of https://www.ziperp.com/: home, ERP solutions, the accounting, sales, purchase, job work, inventory, production, quality control, CRM, HRMS and reports module pages, pricing, POS and the customer portal. The 8 industry pages were not read.

These are ZipERP's marketing claims. They have not been checked in the product. The Progen side was checked against `backend/src/modules`, the migrations and `lib/features` on the same date.

## Where Progen is already ahead

ZipERP's site doesn't mention any of the following, all of which Progen has:
- **Construction:** BOQ, indents, issues, DPR, labour attendance and wages, subcontract work orders, RA bills, retention.
- **Real estate:** units, bookings, construction-linked payment plans, demands, possession, the RERA 70% account.
- **GST self-filing:** prefile checks, GSTR-1 JSON, the 3B worksheet, Rule 88A set-off, PMT-06, GSTR-2B reconciliation, ITC Rule 37, GSTR-9 pack, filing register and calendar.
- **TDS:** section-wise deduction on purchases, expenses and RA bills, challans, the quarterly statement file.
- **Income tax:** regime and presumptive calculators, advance tax, ITR data pack, "Do I need a CA?".
- **Other statutory and controls:** MSME 45-day dues, books lock.
- **Access control:** role, location and field-level permissions; row-level tenant isolation.
- **Reliability:** idempotent posting.

ZipERP's site says only "advanced security protocols". It names no audit trail, SSO, 2FA or certification.

## Gaps: ZipERP lists it, Progen lacks it

| Area | ZipERP feature | Progen today | Priority |
| --- | --- | --- | --- |
| Sales cycle | Quotation, sales order, proforma, delivery note, invoice against delivery, receipt against order, sales return | Direct invoice; credit notes | High |
| Sales control | Price lists, credit control, sales targets, WhatsApp and email notifications | Item sale price only; WhatsApp share link | High |
| Purchase cycle | Requisition, purchase inquiry, vendor quotation comparison, PO, goods receipt against PO, bill verification, purchase return, debit note | Direct purchase bill; construction indents only | High |
| Inventory | Batch and serial tracking, expiry, barcode printing, physical inventory, stock journal, standard cost, reorder alerts | Reorder level shown on the dashboard only | High |
| Manufacturing | BOM, MRP, production planning and orders, process confirmation, finished-goods costing | None | Medium |
| Job work | Job work order, goods issue and receipt, GST job-work challan with e-way bill | None | Medium |
| Quality control | QC orders for raw, in-process and finished goods; accept and reject | None | Medium |
| CRM | Leads, contacts, campaigns, pipeline, follow-up reminders, executive hierarchy | None | Medium |
| HRMS and payroll | Employees, attendance (biometric and geo), leave approvals, payroll with PF and PT, advances and claims, travel, PMS, ESS app | Site labour attendance and wages only (researched in payroll-hr.md) | High |
| POS | Counter billing | None (planned) | Medium |
| Customer portal | Customer login, statements, online ordering, order and dispatch tracking | None | Medium |
| Accounting | Cost centres, budgets, payment requests, consolidated reports, multi-currency, bank integration | Project budgets; bank statement CSV import and reconciliation; one company per account | High |
| Integrations | Live e-invoice and e-way bill, WhatsApp integration, biometric devices | E-invoice sandbox or manual IRN entry; no GSP chosen | High, but needs a GSP account |
| Editions | Starter at ₹500 and Professional at ₹1,500 per user per month; Enterprise custom; 30-day trial | No plans or billing | Business decision |

## Enterprise readiness: what Progen still needs

Neither product shows these on its site. Enterprise buyers ask for them in security reviews and RFPs.

**Identity:**
- TOTP or OTP two-factor login.
- SSO through OIDC and SAML (Google Workspace, Microsoft Entra).
- Self-service password reset by email. Today only an admin can reset a password.
- A password policy, IP allow-lists, and a device and session list. Sessions can already be revoked.

**Controls:**
- A configurable approval engine: multi-level, with amount thresholds. It applies to PO, purchase bills, payments, expenses, journals, credit notes and price overrides.
- Maker-checker separation and approval history in the audit trail.

**Structure:**
- Several companies under one account, with inter-company entries and consolidated statements.
- Branch-wise P&L.
- Cost centres.

**Extensibility:**
- Custom fields on masters and documents.
- Saved and shareable report views, and scheduled reports by email.
- A public API with API keys, and webhooks.

**Data:**
- CSV and Excel import for masters, opening stock and opening balances.
- Migration from Tally.
- Full data export, which already exists as CSV.
- Personal data obligations under the DPDP Act 2023 and its Rules: notice, access and erasure, breach reporting (**UNVERIFIED**, confirm the current Rules and timelines).

**Scale:**
- A background job queue for exports, heavy reports and notifications.
- Load targets, for example 200 concurrent users and 5 million journal lines per company, with load tests.
- Archival or partitioning for old years.

**Operations:**
- Point-in-time backups and a tested restore.
- Structured logs, metrics and alerting.
- Zero-downtime migrations, and separate staging and production environments.

**Usability:**
- PDFs in Indic scripts, and a Hindi or regional interface.
- An offline mode for site staff on mobile.
- A notification centre.

**Assurance:**
- An external VAPT or penetration test.
- ISO 27001 or SOC 2 readiness: policies, access reviews, vendor list.

## What Progen needs to build

1. **Enterprise platform:**
   - 2FA, password reset, SSO
   - approval engine
   - custom fields
   - CSV import
   - job queue with email and WhatsApp notifications
   - multi-company with consolidation, and cost centres
2. **Order to cash and procure to pay:**
   - quotation, sales order, proforma, delivery note, price lists, credit limits
   - requisition, RFQ and comparison, PO, goods receipt, three-way match, purchase return and debit note
3. **Inventory depth:** batch, serial and expiry; barcode labels; stock count; stock journal; reorder alerts.
4. **Payroll and HR**, from payroll-hr.md.
5. **Manufacturing, job work and QC.**
6. **CRM and the customer portal.**
7. **E-commerce** (ecommerce-marketplaces.md), POS, pharma.
8. **Live e-invoice, e-way bill and GST filing** through a GSP, once one is chosen.
