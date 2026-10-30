# Research notes

Regulatory and domain research behind Progen ERP's India-specific features. Each note cites its sources inline and marks anything not confirmed from a primary source as **UNVERIFIED**. Confirm those items before they reach code or customer-facing text. Every note ends with a "What Progen needs to build" checklist; `docs/API.md` (v1.3 to v1.6) turns the first slice of each into a contract. Most facts in the 29 Oct 2026 notes come from secondary sources, which is why statutory rates, thresholds and state slabs are stored as effective-dated data, not code.

| Note | Covers | Status |
| --- | --- | --- |
| [gst-einvoice-ewaybill.md](gst-einvoice-ewaybill.md) | Who must e-invoice, the 30-day limit, IRPs and GSPs, API auth and paths, Version 1.1 JSON, error codes, IRN and QR, e-way bill rules | Done (checked 21–28 Oct 2026) |
| [real-estate-sales.md](real-estate-sales.md) | Unit inventory and booking flow, agreement for sale and the 10% cap, construction-linked payment plans, RERA interest, the 70% account, QPRs, cancellation, GST and TDS on flats, stamp duty, brokers | Done (28 Oct 2026); stamp duty is all UNVERIFIED |
| [labour-wages.md](labour-wages.md) | Labour Codes status, working time and OT, minimum and floor wages, EPF/ESI, BOCW, contract labour, registers, payment timelines and deductions | Done (28 Oct 2026) |
| [contractor-billing.md](contractor-billing.md) | TDS on contractor payments (verified), RA bills and the measurement book, retention, mobilisation and secured advances, GST on works contracts, BOCW cess, final bill and DLP | First pass (29 Oct 2026); several GST rates, advance terms and cess timing are UNVERIFIED; free-issue material not covered |
| [statutory-core.md](statutory-core.md) | GST 2.0 slabs (22 Sep 2025), GSTR-1/3B, IMS and 2B matching, ITC Rule 37/37A, RCM self-invoice, the Income-tax Act 2025 TDS/TCS tables (s.392–394), MSME 45-day rule and interest, audit trail and period lock | Done (29 Oct 2026); mostly secondary-sourced, so every rate goes in dated tables |
| [industry-verticals.md](industry-verticals.md) | 13 Indian industries (trading, retail, pharma, manufacturing, services, logistics, hospitality and more), the top 15 user pain points and quick wins | Done (29 Oct 2026) |
| [ecommerce-marketplaces.md](ecommerce-marketplaces.md) | Marketplace channels, listings, orders, returns, settlement reports and fee lines, TCS u/s 52 and GSTR-8, e-commerce TDS, settlement reconciliation | Done (29 Oct 2026); file import only for v1 |
| [payroll-hr.md](payroll-hr.md) | Salary structure, EPF/ESI/PT/LWF, salary TDS (new regime), gratuity, bonus, leave, full and final, statutory returns | Done (29 Oct 2026); the EPF ceiling change is UNVERIFIED |
| [self-filing-gst.md](self-filing-gst.md) | Filing GSTR-1/IFF, 3B, CMP-08, GSTR-4/9/9C yourself: portal steps, mapping Progen figures to 3B tables, Rule 88A set-off order, PMT-06, prefile checks, the GSP/sandbox route, what still needs a person | Done (30 Oct 2026); late-fee caps, the GSTR-4 date and 3B JSON upload are UNVERIFIED |
| [self-filing-income-tax.md](self-filing-income-tax.md) | ITR form choice and data packs, presumptive income (s.58), advance tax and interest (s.423–425), TDS statements (Forms 138/140/143/144) and FVU, fixed-asset depreciation (IT blocks and Schedule II), 26AS/AIS, ERI, a "needs a CA" list | Done (30 Oct 2026); the FVU file layout for the new forms is a draft |

## Open questions across notes

- **Labour:** Gujarat and Maharashtra final state rules under the four Labour Codes, and the floor wage notification ([labour-wages.md §8](labour-wages.md)).
- **Contractor GST:** resolved. Only Sl. No. 3 items (vii), (viii) and (x) moved from 12% to 18% on 22 Sep 2025 ([statutory-core.md](statutory-core.md)).
- **Payroll:** the EPF wage ceiling change and several state PT/LWF slabs ([payroll-hr.md](payroll-hr.md)).
- **RERA:** the Maharashtra QPR deadline, and Gujarat's interest rule ([real-estate-sales.md](real-estate-sales.md)).
- **E-invoice:** a GSP has not been chosen yet. Until one is, v1.3 supports manual IRP upload and a local sandbox mode only.
