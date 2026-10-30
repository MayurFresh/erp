# Self-filing income tax and TDS: research for Progen ERP

Researched 2026-10-30. Scope: what a small business, proprietor, firm or professional can file without a CA, what files and packs the app can produce, and where a CA is legally needed.

Conventions: **UNVERIFIED** = only a secondary source, or my own prior knowledge, with no official page read. "Old" = Income-tax Act 1961 / Rules 1962. "New" = Income-tax Act 2025 / Rules 2026, in force from 1 Apr 2026. Returns for FY 2025-26 (AY 2026-27) are filed under the old Act; tax year 2026-27 onward is the new Act. Not repeated here: the TDS section master and Act transition ([statutory-core.md](statutory-core.md)); salary TDS, PF and ESI ([payroll-hr.md](payroll-hr.md)).

What Progen already has (API.md §2 and §5): `tds_deductions`, `tds_challans`, and a quarterly statement as JSON/CSV labelled "Form 140". That CSV is not an FVU-ready file. Section 1.4 below says what is missing.

Most pages below are secondary (blogs, news). The official pages that could be read are marked "official". Several incometaxindia.gov.in pages returned HTTP 403 to automated fetch, so form PDFs there were not read.

---

## 1. TDS returns

### 1.1 Forms, old to new

| Old | New (tax year 2026-27 onward) | Covers | Rule |
| --- | --- | --- | --- |
| 24Q | Form 138 | Salary TDS | 219 |
| 26Q | Form 140 | Non-salary, residents | 219 |
| 27Q | Form 144 | Non-residents | 219 |
| 27EQ | Form 143 | TCS | 219 |
| 26QB, 26QC, 26QD, 26QE | Form 141 | Challan-cum-statement for property, rent (individual/HUF), contractor payments by individual/HUF, VDA | |

Sources: [taxaj form mapping](https://www.taxaj.com/learn/?p=90968), [Taxscan on Forms 138/140](https://www.taxscan.in/top-stories/income-tax-forms-138-140-replace-24q-26q-new-tds-reporting-rules-for-salary-and-non-salary-payments-1444578), [Form 143](https://www.taxscan.in/top-stories/income-tax-form-143-replaces-form-27eq-new-quarterly-tcs-form-explained-1444603). The Form 140 user manual on the e-filing portal (official) confirms Form 140 and the quarter dates: [form140-um](https://www.incometax.gov.in/iec/foportal/newformpage/forms/form140-um). Caution: taxguru's table also lists "Forms 92 to 95 / 137 / 139 / 142" for the same statements. Those are February 2026 draft numbers; the final numbers are 138, 140, 143, 144 ([taxguru table](https://taxguru.in/income-tax/comparision-new-income-tax-vs-old-income-tax-forms.html), which itself warns of the mix).

Applicability rule: statements for FY 2025-26 and earlier (including Q4 FY 2025-26, due 31 May 2026) stay in 24Q/26Q/27Q/27EQ with FVU 9.5. The new forms apply from the quarter ending 30 Jun 2026 ([TDSMAN FVU 1.0](https://blog.tdsman.com/2026/07/new-file-validation-utility-fvu-version-1-0-released-on-1st-july-2026/)).

### 1.2 Due dates, late fee, penalty

| Item | Rule | Source |
| --- | --- | --- |
| Statement due | Q1 31 Jul, Q2 31 Oct, Q3 31 Jan, Q4 31 May (official manual page). Form 143 Q4 listed as 15 May by one calendar: **UNVERIFIED** | [form140-um](https://www.incometax.gov.in/iec/foportal/newformpage/forms/form140-um), [studycafe calendar](https://studycafe.in/tds-and-tcs-due-date-compliance-calendar-for-tax-year-2026-27-419614.html) |
| Deposit | 7th of next month; March by 30 April (Rule 218). Form 141 within 30 days of month end | see statutory-core §6.3 |
| Late fee | s.427 (old 234E): Rs 200 per day until filed, capped at the TDS/TCS amount, payable before filing | [TDSMAN](https://blog.tdsman.com/2026/05/fee-for-default-in-furnishing-statements-section-427-section-234e/) |
| Penalty | s.461 (old 271H): Rs 10,000 to Rs 1,00,000 for late filing, or wrong details (PAN, challan, amounts). Relief if tax, interest and fee are paid and the statement is filed within the prescribed relaxation period (conditions **UNVERIFIED**) | same |
| Interest for non-deduction / non-deposit | Old 201(1A): 1% per month from the date deductible to the date deducted; 1.5% per month from deduction to deposit. New section number not found, **UNVERIFIED** | statutory-core §6.3 |
| Intimation (old 200A) | Successor section **UNVERIFIED**: sources point to "clause 399 of the Bill" or ss.392/393 | [calcguru](https://calcguru.in/?p=8263) |

Today (30 Oct 2026) is the Q2 due date for Forms 138/140/144.

### 1.3 Filing path (official portal flow, read from the e-filing user manual)

Source: [Form 140 user manual](https://www.incometax.gov.in/iec/foportal/newformpage/forms/form140-um).

1. Deductor needs a TAN registered on the e-filing portal, the latest RPU from Protean, and a DSC only if DSC is used to verify.
2. Prepare the data in the Protean RPU (or any software that writes the .txt), validate it in the **FVU** (the FVU takes the .txt and writes a `.fvu` file plus Form 27A control chart), and **zip** the FVU output.
3. Log in to incometax.gov.in with the TAN. Go to e-File > Income Tax Forms > File Income Tax Forms. Under "Forms as per Income Tax Act 2025", pick Deduction and Collection at Source and choose the form, tax year, quarter and Regular or Correction.
4. Upload the zip. The FVU version must match the one shown on screen. E-verify (DSC or EVC). Status under View Filed Forms. Accepted statements go to TRACES.
5. Common rejections: wrong tax year, a second filing for the same quarter, FVU version mismatch, TAN in file differs from login TAN.

So the portal now takes both regular and correction uploads for the new forms (the manual says so). One older guide said only regular statements were allowed on the portal ([Teachoo manual](https://cdn.teachoo.com/f19f16e5-88e3-47b1-b779-643ed3d632c8/tds-return-upload-process.pdf)); that predates the new forms. The older route through a TIN facilitation centre (the Protean page still says the FVU file "is to be furnished to a TIN-FC", [Protean](https://tinpan.proteantech.in/services/etds-etcs/etds-steps.html)) remains a fallback. Government deductors and large filers may differ: **UNVERIFIED**.

FVU timeline: [v1.0 on 1 Jul 2026](https://blog.tdsman.com/2026/07/new-file-validation-utility-fvu-version-1-0-released-on-1st-july-2026/), [v1.1 on 8 Jul](https://blog.tdsman.com/2026/07/new-file-validation-utility-fvu-version-1-1-released-on-8th-july-2026/), [v1.2 on 19 Aug 2026](https://blog.tdsman.com/2026/08/new-file-validation-utility-fvu-version-1-2-released-on-19th-august-2026/). v1.2 changes: Interest Allocation and Others Allocation fields are back in Challan Details; Date of Payment in Deductee Details must fall inside the quarter and tax year; Form 144 Nature of Remittance codes were remapped to tax codes. The FVU version changes every few weeks, so the app must not hard-code it.

### 1.4 The text file (input to the FVU)

Third-party software may generate it. Protean states the return "must be prepared as clean text ASCII files with a .txt extension" and "can be made with in-house software, third-party software, or the Protean TDS Return Preparation Utility" ([Protean e-TDS steps](https://tinpan.proteantech.in/services/etds-etcs/etds-steps.html), official). Samples (`26QQ1.zip` and so on) and the format spreadsheets are linked there.

Official format files (all .xls under `https://tinpan.proteantech.in/downloads/e-tds/`):
- `File_Format_26Q_Regular_Q1_to_Q4_Version_7.5_22052024_201011.xls` (regular)
- `File_Format_26Q_Correction_Q1_to_Q4_Version_7.7_22052024_201011.xls` (correction)
- Matching files for 24Q (regular Q1-Q3 v6.2, Q4 v7.3), 27Q (v7.3, correction v7.5), 27EQ (v6.7, correction v7.2).
- **Gap:** the Protean page I could read (last updated 24 Jun 2024) lists only the old 24Q/26Q/27Q/27EQ formats. I could not find the published format sheet for Forms 138/140/143/144 (tax year 2026-27). Treat the old 26Q v7.5 layout below as the working basis, and **UNVERIFIED** for the new forms until the new sheet is downloaded from the Protean downloads page. The FVU 1.0 to 1.2 notes show some field changes (the "Financial Year" to "Tax Year" rename, the allocation fields, the date check), so assume the layout differs in details.

Structure of the 26Q file (read from the [Oracle JD Edwards 26Q field map](https://docs.oracle.com/cd/E16582_01/doc.91/e23355/txt_file_field_26q.htm), a third-party implementation of the official layout; the delimiter is not stated there):
- Hierarchy: FH, then batch(es): BH, then CD (challan) records, each followed by DD (deductee) records. Each line starts with a running line number, then the 2-letter record type.
- **Delimiter: caret `^`** ([Tally help on caret delimiters](https://help.tallysolutions.com/tally/form-26q/); also seen in the Greytrix samples). Treat as confirmed in practice, from vendor docs, not from the official sheet.
- **SD record**: the brief asks about it. I found no evidence for an SD record in the 26Q regular layout. Salary statements (24Q) add salary-detail records (Annexure II); the name and layout are **UNVERIFIED**.

| Record | Key fields (field number) |
| --- | --- |
| FH (1 per file) | 2 record type `FH`; 3 file type `NS1`; 4 upload type `R`; 5 creation date ddmmyyyy; 6 file sequence; 7 uploader type `D`; 8 deductor TAN; 9 number of batches; 10 RPU name |
| BH (per batch) | 2 `BH`; 3 batch no; 4 count of challan records; 5 form no (`26Q`); 9 previous regular token (only if field 52 = Y); 13 TAN; 15 PAN; 16 assessment year; 17 financial year; 18 period `Q1..Q4`; 19 deductor name; 26/27 state, PIN; 47 total deposit (sum of CD field 27); 52 earlier regular filed Y/N; 59 TAN registration no |
| CD (per challan) | 3 batch no; 4 challan record no; 5 count of DD rows; 6 NIL challan indicator; 12 bank challan serial; 16 BSR code (7 digits); 18 challan date; 22 TDS; 23 surcharge; 24 cess; 25 interest; 26 others; 27 total deposit (= 22+23+24+25+26+39); 29-35 totals per deductee annexure; 37 book entry Y/N; 39 late fee (old 234E); 40 minor head |
| DD (per deductee) | 4 challan record no; 5 deductee row no; 8 deductee code (01 company, 02 other); 10 PAN (or `PANAPPLIED`, `PANINVALID`, `PANNOTAVBL`); 13 name; 14-17 TDS, surcharge, cess, total; 19 total deposited; 22 amount paid; 23 date paid; 24 date deducted; 26 rate (4 decimals); 30 reason for non-deduction/lower deduction; 32 section code; 34 section 197 certificate no |

Rules that bite: CD total deposit must equal the sum of its parts; DD totals must reconcile to CD (control totals); PAN must be valid-format or use the placeholders; amounts are integers in CD and 2-decimal in DD; challan BSR code, serial and date must match the bank's record (TRACES matches them against OLTAS).

Gap to Progen's current statement export: our CSV has deduction rows and challan BSR/serial, so the data is nearly there. Missing for an FVU-ready file: deductor master data (TAN, PAN, address, responsible person, deductor category), the deductee code, the section code mapping, per-challan grouping of deductees, control-total checks, and the line-numbered `^` writer. Correction statements (below) need the previous token and PRN data.

Do not try to implement the FVU. It is a Java utility from Protean, and the file is only valid after the FVU passes it. The app writes the .txt; the user runs the FVU (or we bundle a "validate" step as instructions).

### 1.5 Correction statements

- Types: C1 (deductor details), C2 (deductor and challan), C3 (PAN or deductee details), C5 (challan and deductee details), C9 (batch addition), Y (cancellation). These types come from my prior knowledge of the old regime. **UNVERIFIED** for the new forms.
- Portal: the Form 140 manual (official) lets you pick "Correction" at upload; the correction FVU must use the RRR (token/PRN) of the regular statement; filing a correction as regular, or the reverse, is rejected. The correction file uses its own format (26Q correction v7.7).
- Challan corrections (BSR/serial/amount) and PAN fixes are sometimes done on TRACES without a correction statement ([calcguru](https://calcguru.in/?p=8263)); a wrong tax code needs a correction statement.
- The app must keep: the token/PRN, each filed statement version, and which deduction rows were in which quarterly statement.

### 1.6 TRACES

- Certificates: Form 130 (old Form 16, salary; due 15 Jun per TaxHeal, **UNVERIFIED**), Form 131 (16A, TRACES generates it from Form 140 data, [Taxscan](https://www.taxscan.in/top-stories/income-tax-forms-138-140-replace-24q-26q-new-tds-reporting-rules-for-salary-and-non-salary-payments-1444578)), Form 132 (16B/C/D/E), Form 133 (27D, TCS). Rule 215 ([taxaj](https://www.taxaj.com/learn/?p=90968)). Form 130 can also be generated in the employer's own software with a TRACES-signed part A: **UNVERIFIED**.
- Justification report, default view, conso file, correction request: all available only to a logged-in TAN on [tdscpc.gov.in](https://www.tdscpc.gov.in) (the TRACES login). Only the existence of these is from prior knowledge; **UNVERIFIED** under the new Act's names.
- The conso file (a zip of the filed statement plus the challan/PAN processing results) is meant to be loaded into a TDS software for a correction. Our import would parse the same caret-delimited text. **UNVERIFIED** for new-form layout.
- API for software vendors: I found **no** public API for TDS statement upload or for TRACES. Filing is manual upload by the deductor.

---

## 2. Income-tax returns

### 2.1 Forms and due dates

Under Rule 164 the ITR names are unchanged: ITR-1 to ITR-7 ([taxaj mapping](https://www.taxaj.com/learn/?p=90968)). Forms for AY 2026-27 (FY 2025-26) were notified 30 Mar 2026, Notification 45/2026 ([Business Today](https://www.businesstoday.in/personal-finance/tax/story/cbdt-releases-itr-forms-for-ay-2026-27-check-key-changes-for-return-filing-523394-2026-03-31)). One table lists "Form 99 to 105" as new form numbers for ITR-1 to ITR-7 ([taxguru](https://taxguru.in/income-tax/comparision-new-income-tax-vs-old-income-tax-forms.html)); that is a draft numbering and conflicts with Rule 164, so treat as wrong.

| Taxpayer | Form | Notes |
| --- | --- | --- |
| Proprietor / individual / HUF with business or profession income, books or any income not fitting ITR-4 | ITR-3 | Full P&L and balance sheet schedules |
| Individual / HUF / firm (not LLP) under presumptive scheme (44AD/44ADA/44AE; new s.58) | ITR-4 (Sugam) | No P&L; summary turnover and presumptive income. Not for company directors, unlisted shares holders, or income above Rs 50 lakh (limit **UNVERIFIED** for this year) |
| Partnership firm, LLP, AOP, BOI | ITR-5 | Schedules for partners' remuneration and interest |
| Company (not claiming s.11) | ITR-6 | Must e-file with DSC; may need Schedule on MAT/AMT |
| Trust, political party, institutions | ITR-7 | |

Due dates for AY 2026-27: non-audit individuals (ITR-1/2) 31 Jul 2026; non-audit business (ITR-3/4) 31 Aug 2026; audit cases and companies 31 Oct 2026; transfer pricing 30 Nov 2026; belated/revised 31 Dec 2026 ([carajput](https://carajput.com/blog/?p=31808); [taxguru](https://taxguru.in/income-tax/income-business-income-tax-act-2025-sections-itr-forms-compliance-ay-2026-27.html)). Both are secondary, so check the portal. Note 31 Oct 2026 is today for audit-case ITR-3/5 and ITR-6 filers (any extension: **UNVERIFIED**).

### 2.2 Presumptive schemes

Old 44AD, 44ADA and 44AE are merged into **s.58** of the 2025 Act ([taxguru article](https://taxguru.in/income-tax/income-business-income-tax-act-2025-sections-itr-forms-compliance-ay-2026-27.html), secondary, **UNVERIFIED**; section number not read in the Act text).

| Scheme | Eligible | Limit | Deemed income |
| --- | --- | --- | --- |
| Business (old 44AD) | Resident individual, HUF, firm (not LLP); not for agency, brokerage, commission business | Turnover up to Rs 2 crore; Rs 3 crore if cash receipts are 5% or less | 6% of digital receipts and 8% of other (or a higher declared profit) |
| Profession (old 44ADA) | Specified professions (legal, medical, engineering, architecture, accountancy, interior design, technical consultancy, film and other notified) | Gross receipts up to Rs 50 lakh; Rs 75 lakh if cash is 5% or less | 50% of gross receipts |
| Goods carriage (old 44AE) | Owner of up to 10 vehicles | Per vehicle | Rs 1,000 per tonne of gross vehicle weight per month (heavy), Rs 7,500 per vehicle per month (others) |

Rules: advance tax in one instalment by 15 March; no books under 44AA for 44AD/44ADA filers (but a declaration of income below the deemed rate triggers audit, below); five-year lock-in after opting out of 44AD. The tax-audit trigger for low declared profit under the new Act is disputed across sources ([Taxscan](https://www.taxscan.in/top-stories/section63-new-act-vs-section44ab-old-income-tax-act-low-profit-declarations-now-mandate-audit-1445774) says yes; [taxguru](https://taxguru.in/?p=1073150) on AY 2026-27 says no audit without a prior opt-out). **UNVERIFIED** for tax year 2026-27.

### 2.3 JSON, schemas and validation rules

- The portal accepts uploaded JSON generated by the Department's offline utilities (Excel utility, Common Offline Utility for ITR-1 to 4). For each form the Department publishes a **JSON schema and a validation-rules PDF** at [incometax.gov.in downloads](https://www.incometax.gov.in/iec/foportal/downloads/income-tax-returns). Examples: [ITR-5 validation rules v1.0 AY 2026-27](https://www.incometax.gov.in/iec/foportal/sites/default/files/2026-07/CBDT_e-Filing_ITR-5_Validation%20Rules_V1.0_AY%2026-27.pdf), [ITR-6 validation rules v1.0](https://www.incometax.gov.in/iec/foportal/sites/default/files/2026-08/CBDT__e-Filing_ITR-6_Validation%20Rules_Version%201.0_AY%202026-27.pdf).
- ITR-3 utility, JSON schema and rules were released 18 Jun 2026 ([Business Today](https://businesstoday.in/personal-finance/tax/story/itr-3-excel-utility-now-available-on-income-tax-portal-heres-how-taxpayers-can-use-it-538050-2026-06-19)); ITR-4 utility is also out ([TaxHeal](https://www.taxheal.com/?p=130251)).
- Whether the portal accepts a JSON written by arbitrary third-party software (not the Department's utility) is not stated in anything I read. In prior years the JSON was upload-accepted from any source if it matched the schema, and commercial filers used it before ERI. I did not confirm this for AY 2026-27: **UNVERIFIED**. The safe wording: the file must validate against the published schema and rules; the portal can still reject it.
- Schemas change per form and per year, sometimes mid-season (utility versions). Pin a schema version in the app and expect to chase it.

### 2.4 What the P&L and balance sheet schedules need from the books

ITR-3 and ITR-5 (and ITR-6) need these from the ledger; this is from the standard form structure and prior knowledge (the AY 2026-27 schedules were not opened): **UNVERIFIED** for exact line items.

- Balance sheet at year end: partners'/proprietor's capital, reserves, secured and unsecured loans, sundry creditors, other liabilities and provisions; fixed assets (net block), investments, inventories (with valuation method), sundry debtors, cash and bank, loans and advances.
- P&L: sales/turnover (split by GST if relevant), other income, opening and closing stock, purchases, direct expenses, employee costs, interest, depreciation, rent, repairs, professional fees, other expenses; net profit.
- Part A-OI: nature of business and business code.
- Schedules: depreciation (block-wise, Schedule DPM/DOA), partner details, TDS/TCS credit, advance and self-assessment tax paid, deduction schedules (chapter VI-A), unabsorbed losses, quantitative details for traders and manufacturers, and the audit-info fields (auditor, 3CD date and number) when audited.
- Progen gaps: account-to-ITR-line mapping, depreciation per IT block, stock valuation method, GST turnover split, and disallowances (see 4, 5).

### 2.5 Individual and HUF: old vs new regime, current tax year

Section map: new regime is s.202(1) (old 115BAC(1A)); rebate is s.156 (old 87A) ([taxguru](https://taxguru.in/?p=1047520), secondary). Slab rates and the Rs 60,000 rebate up to Rs 12 lakh are as reported by calculator sites and Budget 2025; the Finance Act 2026 reportedly made no change. **UNVERIFIED** against the Act or the Department.

| New regime (default) | Rate | Old regime (below 60 years) | Rate |
| --- | --- | --- | --- |
| Up to Rs 4 lakh | Nil | Up to Rs 2.5 lakh | Nil |
| 4 to 8 lakh | 5% | 2.5 to 5 lakh | 5% |
| 8 to 12 lakh | 10% | 5 to 10 lakh | 20% |
| 12 to 16 lakh | 15% | Above 10 lakh | 30% |
| 16 to 20 lakh | 20% | | |
| 20 to 24 lakh | 25% | | |
| Above 24 lakh | 30% | | |

- New regime: rebate up to Rs 60,000 if taxable income is Rs 12 lakh or less (resident); salary standard deduction Rs 75,000; few deductions (no 80C/HRA); max surcharge 25%. Old regime: rebate Rs 12,500 up to Rs 5 lakh (prior knowledge); standard deduction Rs 50,000; 80C, 80D, HRA, home loan interest, and the like; surcharge up to 37%; higher basic exemption for seniors (prior knowledge). Cess 4% on both.
- Business income earners (not salaried) who choose old regime after opting for new must follow the one-time switch back rule (old Form 10-IEA); under the new Act the choice is made in the return itself (Rule 136; 10-IEA continues for AY 2026-27 only, [taxaj](https://www.taxaj.com/learn/?p=90968)). Fine details: **UNVERIFIED**.

### 2.6 Advance tax, interest, self-assessment tax

- Instalments: 15 Jun, 15 Sep, 15 Dec, 15 Mar; cumulative 15%, 45%, 75%, 100% (prior knowledge, structure unchanged under the new Act per [India Briefing](https://india-briefing.com/news/indias-advance-tax-due-dates-tax-year-2026-27-45178.html/) and [CA Rajput](https://carajput.com/learn/all-about-advance-tax-under-the-income-tax-act-2025.html); only the 15% figure was shown in results, **UNVERIFIED** for the rest). Liability starts at Rs 10,000 tax after TDS (prior knowledge). Presumptive filers (44AD/44ADA): one payment by 15 March. Resident seniors with no business income need not pay.
- Interest: new s.423 (old 234A, late return), s.424 (old 234B, advance tax paid below 90%: 1% per month or part of month), s.425 (old 234C, deferment: 1% per month for 3 months on shortfalls of the first three instalments, 1 month on the last) ([TaxClue on s.424](https://taxclue.in/blog/section-424-income-tax-act-2025-advance-tax-interest), secondary; rates from prior knowledge).
- The FY 2025-26 Mar 2026 instalment and interest stay under the old Act.
- Self-assessment tax: pay through **e-Pay Tax** on incometax.gov.in (challan ITNS 280, tax type "self-assessment tax (300)" and "advance tax (100)", prior knowledge); get CIN (BSR code, date, serial). The return needs this CIN. Under the new Act the challan name may change: **UNVERIFIED**.

### 2.7 26AS, AIS, TIS

- AIS can be downloaded as **PDF (password-protected), JSON, and CSV** from the e-filing portal; TIS as PDF (JSON reported by some). The AIS Utility imports the AIS JSON ([taxguru AIS utility](https://taxguru.in/income-tax/annual-information-statement-ais-utility-presentation.html), [Taxmann FAQs](https://www.taxmann.com/post/blog/faqs-income-tax-returns-itr-annual-information-statement-ais/), secondary). The AIS JSON schema is not published as far as I found: **UNVERIFIED**; any import must tolerate changes.
- Form 26AS (new: Form 168, "annual information statement", Rule 245 per [taxaj](https://www.taxaj.com/learn/?p=90968)): downloadable as PDF or text from the e-filing portal/TRACES (the TXT format, a caret-delimited file, is from prior knowledge; **UNVERIFIED**).
- Reconciliation idea: match TDS receivable by (deductor TAN, section, date, amount) against 26AS/AIS Part A rows. Both sources carry the deductor TAN, not our party PAN, so users must map TAN to party once.

---

## 3. Direct filing by software: ERI

Sources: [e-filing ERI registration help](https://www.incometax.gov.in/iec/foportal/help/eri/registration) (official), [Protean ERI eligibility](https://tinpan.proteantech.in/services/e-return/ereturn-eligibility.html) (official), [Protean ERI overview](https://tinpan.proteantech.in/services/e-return/ereturn-overview.html).

| Type | What it is | Registration documents |
| --- | --- | --- |
| Type 1 | Uses Department-approved utilities or services through the e-filing portal (no API) | Undertaking, bank guarantee |
| Type 2 | Uses Department-approved utilities or services **through API** | Undertaking, bank guarantee, audit report; sandbox testing |
| Type 3 | Develops offline software utilities | Undertaking, bank guarantee, audit report; sandbox testing |

- Eligible applicants: companies incorporated in India, firms of CA/advocates/CS/cost accountants, LLPs, individual CA/advocate/CS/cost accountant, and government DDOs. Type 3 also allows an individual with a PAN. Resident applicants only. So Progen's operating company would qualify.
- Steps: register on the e-filing portal (Register > Others > e-Return Intermediary), validate PAN/TAN with OTP, upload attachments (each 5 MB or less), wait for approval, set a password. Type 2/3 test in a sandbox: test details come from erihelp@incometax.gov.in; submit a test status report; share a public key certificate (SHA-2, 2048-bit RSA) per Protean.
- Type 1 and Type 2 ERIs can file returns and statutory forms for clients and add clients (PAN users) with client consent (client-activation flow). APIs: the API specifications are published on the e-filing portal for ERIs. The names of the prefill, ITR-submit and e-verify endpoints are not in anything I could read. **UNVERIFIED**.
- Bank guarantee amount, fee, and approval timeline: not stated in the sources. **UNVERIFIED**. Plan on weeks to months (prior knowledge, not a source).
- TDS statements and TRACES: I found no ERI or vendor API for these. TDS statements are uploaded by the deductor as a zip on the portal.

---

## 4. Depreciation and fixed assets

### 4.1 Income-tax (block of assets, WDV)

New Act: s.33 (old 32), rates carried over ([Patron Accounting](https://www.patronaccounting.com/blog/depreciation-rules-2026-rates-block-assets) says s.33; [taxguru](https://taxguru.in/?p=1036553) says s.34; **UNVERIFIED**, take s.33 from [the taxguru s.58/62/63 article](https://taxguru.in/income-tax/income-business-income-tax-act-2025-sections-itr-forms-compliance-ay-2026-27.html)). The rate table sits in the Rules (Rule 25 of draft Rules 2026 per Patron). Main blocks, from [ComplianceCalendar](https://www.compliancecalendar.in/learn/depreciation-rates-for-fy-2025-26-under-income-tax-act) and [ClearTax](https://cleartax.in/s/depreciation-income-tax-act) plus prior knowledge:

| Block | WDV rate |
| --- | --- |
| Residential building | 5% |
| Other buildings | 10% |
| Temporary structures | 40% |
| Furniture and fittings | 10% |
| Plant and machinery (general) | 15% |
| Motor cars (not for hire) | 15% |
| Computers and software | 40% |
| Intangibles (patents, licences, know-how) | 25% |
| Energy-saving and pollution-control equipment | 40% |
| Ships | 20% |

Rates not re-read from the Rules text: **UNVERIFIED** for this year.

- Half-rate rule: an asset put to use for less than 180 days in the year gets 50% of the normal rate; the balance is not lost (it stays in the block). Mentioned in the [taxguru article](https://taxguru.in/income-tax/income-business-income-tax-act-2025-sections-itr-forms-compliance-ay-2026-27.html) (secondary).
- Additional depreciation 20% on new plant and machinery for manufacturing/power undertakings (same article; half in the first year if used under 180 days is prior knowledge).
- Block mechanics: opening WDV + additions - sale proceeds; block never goes negative except short-term capital gain when the block ceases (prior knowledge). Land is not depreciable. Depreciation is allowed whether or not claimed (s.33(7) per the same article).

### 4.2 Companies Act Schedule II (books)

The official text is on the [Income Tax Department page for Schedule II](https://www.incometaxindia.gov.in/w/schedule-ii) (not read) and the MCA. From [registerkaro](https://www.registerkaro.in/post/depreciation-rates-as-per-companies-act-2013) the confirmed items: plant and machinery (general) 15 years, furniture and fittings 10 years, residual value up to 5%. From prior knowledge, **UNVERIFIED**: RCC-framed building 60 years, other buildings 30 years, motor cars 8 years, end-user computers 3 years, servers 6 years, office equipment 5 years. Part C lives are for the whole asset; component accounting is required for significant components; a company may use a different life with disclosure. Methods allowed: SLM or WDV (the rate is derived from the life and residual value).

### 4.3 What a fixed-asset register needs

- Asset master: category, IT block, Schedule II class, description, location, supplier bill, GST ITC taken (ITC reduces the cost), cost, date of purchase, date put to use (drives the 180-day rule), custodian, serial/tag number.
- Per-asset book depreciation (SLM or WDV, life and residual value, component split) and per-block tax depreciation (opening WDV, additions in the first half or second half of the year, disposals with sale value, closing WDV).
- Disposals and scrap: book gain/loss and block adjustments; transfers between locations; capitalisation from CWIP; revaluation or impairment (rare).
- Output: depreciation journal (monthly or annual), the Schedule DPM/DOA-style block table for the ITR, Schedule II-style note for company accounts, deferred tax on the book/tax difference (companies).
- Section 43B-type and 40A(3) checks are not asset issues; 40A(3) disallows cash payments above Rs 10,000 (prior knowledge) and also affects capitalised cost.

---

## 5. Where a CA is legally required

| Matter | Rule | CA needed? | Source |
| --- | --- | --- | --- |
| Tax audit (old 44AB; new s.63, report on Form 26 replacing 3CA/3CB/3CD) | Business turnover above Rs 1 crore (Rs 10 crore if cash receipts and payments are each 5% or less, the "95% digital" relaxation); profession gross receipts above Rs 50 lakh; presumptive filers who declare less than the deemed profit (the new-Act low-profit trigger is disputed, see 2.2); 44AD opt-out and income above the basic exemption | Yes: report by a chartered accountant | [taxguru](https://taxguru.in/income-tax/income-business-income-tax-act-2025-sections-itr-forms-compliance-ay-2026-27.html), [taxaj](https://www.taxaj.com/learn/?p=90968) |
| 44AD opt-out audit trap | Opting out of 44AD in a year while income is above the exemption limit needs audit, and the 5-year lock-in applies | Yes | [taxguru](https://taxguru.in/?p=1073150) |
| Company statutory audit | Every company must appoint a CA auditor under Companies Act 2013 s.139 (prior knowledge; not confirmed in this session) | Yes | **UNVERIFIED** |
| LLP audit | Turnover above Rs 40 lakh or contribution above Rs 25 lakh (prior knowledge) | Yes | **UNVERIFIED** |
| Foreign remittance: 15CA (new Form 145) and 15CB (new Form 146) | Part A of 15CA is self-filed for small amounts; Part C needs a CA's 15CB for remittances where the amount exceeds Rs 5 lakh in a year and is taxable (old rule; the new thresholds not verified) | Yes for 15CB | [taxaj](https://www.taxaj.com/learn/?p=90968), thresholds **UNVERIFIED** |
| MAT report (29B, new Form 66) and AMT (29C, new Form 67) | Report on book profit | Yes | [taxaj](https://www.taxaj.com/learn/?p=90968) |
| Transfer pricing report 3CEB (new Form 48) | Related-party and international transactions | Yes | same |
| GST annual return GSTR-9C | Reconciliation is **self-certified** by the taxpayer for turnover above Rs 5 crore since FY 2020-21; a CA certificate is no longer required (prior knowledge; not confirmed in this session) | No | **UNVERIFIED** |
| Form 10CCB (new Form 44), 10F (new Form 41) | Deduction reports; treaty declaration | 10CCB: CA; 10F: self-filed | [taxaj](https://www.taxaj.com/learn/?p=90968) |
| ITR-6 | Digital signature of the director | No (but a DSC is needed) | prior knowledge |
| Other common | Company ROC returns need a CS in some cases; capital reduction, valuation reports; bank loan CMA data; GST refund certificates (for some refunds) | Varies | **UNVERIFIED** |

Books of account (old 44AA; new **s.62**) ([taxguru](https://taxguru.in/income-tax/income-business-income-tax-act-2025-sections-itr-forms-compliance-ay-2026-27.html)): specified professions must keep books; others must if income exceeds Rs 1.2 lakh or turnover exceeds Rs 10 lakh in any of the three preceding years (individuals/HUF: Rs 2.5 lakh and Rs 25 lakh). Retention (old rule 6F): 6 years from the end of the relevant year for books; the Companies Act requires 8 years for company books (prior knowledge). **UNVERIFIED** for the new Act.

---

## 6. Notices and mismatches; pre-filing checks

| Notice or mismatch | Cause | Pre-filing check in the app |
| --- | --- | --- |
| TDS short deduction (200A intimation / default) | Rate lower than required, no-PAN rate not applied, threshold mistakes | Use the section master and the 20% no-PAN logic already built; show a "rate used vs rate required" check before posting |
| Short payment / challan mismatch | Challan amount, BSR, serial or date not matching OLTAS; challan tagged to the wrong quarter | Match statement CD rows to bank challans; warn if CD total differs from DD total |
| Late filing fee (s.427, old 234E) and late deposit interest | Statement after due date; deposit after 7th | Due-date alerts; compute interest and fee in-app, include them in the challan (CD fields 25 and 39) |
| PAN errors | Wrong or invalid PAN; deductee name mismatch with PAN database | PAN format check (and the fourth letter vs party type); use `PANAPPLIED` only for pending PANs; verify PAN on the portal (Protean/NSDL PAN verification) before filing |
| Section 461 penalty (old 271H) | Late or wrong statement | Fix via a correction before the relaxation period ends |
| 26AS / AIS mismatch | Deductor did not file, or filed late; wrong PAN; income reported by third parties (AIS) not in the return | Reconcile TDS receivable against 26AS/AIS before filing (see 2.7) |
| 143(1) adjustments | Arithmetic errors, claims not backed by the data (TDS credit beyond 26AS, 80C without proof, disallowances of late-paid PF/ESI), and the return not matching AIS | Pull AIS; match TDS credit; verify late-paid employee contributions; check challan CIN entries |
| Disallowance (old 40(a)(ia), see statutory-core §6.4) | TDS not deducted or paid by the return due date | Warn on expenses where TDS applies and no deduction row exists |

The deemed-notice legal basis and curable defaults come from [calcguru](https://calcguru.in/?p=8263). The 143(1) item is from prior knowledge; no 2025-Act equivalent section found: **UNVERIFIED**.

---

## Build recommendation for Progen

Priorities are ordered by value for self-filers against effort and risk.

**(a) Files and packs to generate now**
1. TDS statement text file (Forms 138/140/143/144), caret-delimited FH/BH/CD/DD, written from `tds_deductions` and `tds_challans`. Prerequisites: deductor master data (TAN, PAN, category, responsible person), deductee code, section code, and the control-total checks. First download the official format sheet for the new forms from the Protean downloads page (not yet found); build to the 26Q v7.5 layout only as a draft. The user runs the FVU on the file, then uploads the zip on the portal (flow in 1.3). Ship a step-by-step pack: deposit, FVU, upload, status, Form 131 download.
2. Correction support: store token/PRN per filed statement and a regular-vs-correction flag; write a correction .txt only after confirming the correction format.
3. ITR-3 and ITR-4 "data pack" (PDF and CSV): P&L and balance sheet mapped to the schedules in 2.4, depreciation block table, TDS credit list, advance and self-assessment tax paid (CIN), and a step-by-step entry guide for the portal. This is feasible now and low risk.
4. ITR JSON: only after the AY 2026-27 schema for ITR-3 and ITR-4 is downloaded and the upload of third-party JSON is confirmed to work (open question in 2.3). Treat it as phase 2; the schemas change by season. Never promise a file the portal rejects.
5. Quarterly deposit and return due-date calendar tied to the TDS summary (already have due dates in API.md).

**(b) Calculators**
- Advance tax (4 instalments, one for presumptive filers) with 234B/234C-equivalent interest (s.424/s.425).
- Regime comparison for individual/HUF (new vs old, table in 2.5; effective-dated, like `tds_sections`).
- Presumptive income (s.58: 44AD, 44ADA, 44AE) with the limit check and the audit trap warning.
- TDS late-deposit interest and the s.427 late fee. All rates in effective-dated tables, never in route code.

**(c) Fixed-asset register**
- Build it (section 4.3): asset master, IT block table with the 180-day half rate, Schedule II dual depreciation (SLM/WDV), monthly journals. It feeds the books, the tax computation and the ITR schedule. Highest dependency for ITR packs.

**(d) Imports: 26AS/AIS reconciliation**
- Import AIS JSON/CSV and 26AS text; match to TDS receivable by deductor TAN, section, date, amount; show unmatched rows. The formats are not officially documented (2.7), so write a tolerant parser and sample-test with real downloads first.

**(e) Direct-filing adapter (ERI)**
- Not now. A company can register (Type 2 for API) but needs a bank guarantee, an audit report, sandbox testing and an approval period; the API names and amounts are unconfirmed. Revisit when user volume justifies it, and ask the Department's ERI help desk first (erihelp@incometax.gov.in) for the guarantee amount and timeline. No TDS/TRACES API exists for vendors, so TDS stays manual upload.

**(f) "Needs a CA" guard list**
Show a banner or block the pack when:
- Business turnover is above Rs 1 crore (above Rs 10 crore with cash 5% or less), profession receipts above Rs 50 lakh, or a presumptive filer declares below the deemed profit or has opted out of s.58 while above the exemption: tax audit needed.
- Company or LLP (statutory audit and the ITR-6 DSC).
- Foreign payment (15CA/15CB), transfer pricing, MAT/AMT, treaty claims.
- Capital gains on land or property, foreign assets, or a loss carry-forward position the app cannot compute.
- GST turnover above Rs 5 crore: GSTR-9C is self-certified, but advise a review.
- Any notice (143(1), 200A, 148): show it as "get advice".
Wording on the guard: "The law requires a chartered accountant for this," or "You can file this yourself; the app covers X, but not Y."

Open items to settle first: the official file format for Forms 138/140/143/144; the tax year 2026-27 ITR schemas and the JSON third-party upload rule; the old-to-new section map for interest and intimation provisions; the new-Act thresholds for 15CA/15CB.
