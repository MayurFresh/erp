# Self-filing GST without a CA: what is required and what is possible

Researched 2026-10-30. Builds on [statutory-core.md](statutory-core.md) section 2 and `docs/API.md` section 6 (v1.4: GSTR-1 JSON, GSTR-3B workings, 2B recon, ITC ageing). Not repeated here.

**Source quality warning.** The search tool surfaced mostly secondary sources (ClearTax, TaxGuru, Taxscan, vendor docs). The official gst.gov.in, tutorial.gst.gov.in and cbic-gst.gov.in pages did not come back, and `developer.gst.gov.in/apiportal` was only a nav menu. Every figure below is **unverified against the primary text** unless it says otherwise. Before coding a number into a rule table, open the notification named in the text. Items marked "(background)" come from general knowledge and have no URL.

---

## 1. Return and filing calendar (who, when, penalty)

### 1.1 Due dates

| Filing | Who | Due date | Source |
| --- | --- | --- | --- |
| GSTR-1 | Regular, monthly | 11th of next month | statutory-core 2.1 (unverified) |
| GSTR-1 | QRMP (up to Rs 5 crore) | 13th after quarter (13 Jan, 13 Apr, 13 Jul, 13 Oct) | [Taxaj QRMP](https://www.taxaj.com/learn/?p=758), [Patron tracker](https://www.patronaccounting.com/tools/gst-return-due-date-tracker) |
| IFF | QRMP, optional, months 1 and 2, B2B and credit notes only | 13th of next month | same; Rs 50 lakh/month cap is background, unverified |
| GSTR-1A | Any filer; amends or adds to GSTR-1 of the same period, before GSTR-3B is filed | Before that period's 3B | [Taxscan advisory](https://www.taxscan.in/top-stories/gstn-issues-advisory-on-reporting-values-in-system-locked-table-32-of-gstr-3b-1439411) |
| GSTR-3B | Regular, monthly | 20th of next month | statutory-core 2.4 (unverified) |
| GSTR-3B | QRMP | 22nd (Category A states) or 24th (Category B) after quarter | [Patron tracker](https://www.patronaccounting.com/tools/gst-return-due-date-tracker); state list is background (unverified) |
| PMT-06 | QRMP, months 1 and 2 | 25th of next month | [Taxaj QRMP](https://www.taxaj.com/learn/?p=758) |
| CMP-08 | Composition | 18th after each quarter (18 Jul, 18 Oct, 18 Jan, 18 Apr) | [Taxscan](https://www.taxscan.in/top-stories/gstr-4-vs-cmp-08-due-dates-differences-and-complete-filing-guide-for-composition-taxpayers-2025-26-1444682) |
| GSTR-4 | Composition, annual | **Conflict:** 30 Jun per most 2025-26 sources (Rule 62); 30 Apr per two others. **Unverified.** Read the portal's due-date page. | [Taxscan](https://www.taxscan.in/top-stories/gstr-4-vs-cmp-08-due-dates-differences-and-complete-filing-guide-for-composition-taxpayers-2025-26-1444682), [Munim](https://themunim.com/blog/gstr-4-composition-annual-return/) |
| GSTR-9 | Annual. Mandatory above Rs 2 crore; optional up to Rs 2 crore (Notification 15/2025-CT per one source; unverified) | 31 Dec after FY end; FY 2025-26 is 31 Dec 2026, no extension seen | [TaxGuru FY24-25](https://taxguru.in/goods-and-service-tax/insights-key-gstr-9-gstr-9c-fy-2024-2025.html), statutory-core 2.4 |
| GSTR-9C | Above Rs 5 crore. **Self-certified**, no CA, since FY 2020-21 (one page still says CA; ignore) | with GSTR-9 | [Taxscan FY24-25](https://www.taxscan.in/top-stories/key-changes-in-gstr-9-and-gstr-9c-for-fy-2024-25-everything-you-should-know-1437208) |
| ITC-04 | Registered persons sending goods for job work | Half-yearly (25 Oct, 25 Apr) above Rs 5 crore; yearly (25 Apr) up to Rs 5 crore | (background) **unverified**; no source found |
| LUT (RFD-11) | Exporters without IGST payment | Once per FY, before the first export invoice of the year. No fixed statutory date. FY 2026-27 form live. | [Setindiabiz](https://www.setindiabiz.com/blog/gst-lut-filing-fy-2026-27), [Taxonation](https://taxonation.com/show-detail-news/2911104/gstns-important-update-furnishing-of-letter-of-undertaking-lut-for-fy-202627-enabled-on-gst-portal) |
| DRC-03 | Voluntary payment of tax, interest, or after a DRC-01B/01C/ASMT-10 | No due date; interest runs until paid | [TaxGuru DRC-01C](https://taxguru.in/goods-and-service-tax/respond-drc-01c-notice-itc-mismatch-gstr-2b-vs-gstr-3b.html) |
| GSTR-2B | Auto-generated for recipients | Around the 14th (background, unverified) | none |

Note: per [Taxscan](https://www.taxscan.in/gst/gst-portal-enables-gstr-99c-annual-returns-for-fy-2025-26), GSTN's 13 Oct 2026 advisory says to file all pending GSTR-1 and 3B before GSTR-9 (unverified beyond that).

### 1.2 Late fee and interest

| Item | Rule | Source |
| --- | --- | --- |
| GSTR-1 / GSTR-3B | s.47: Rs 50/day (25 CGST + 25 SGST); nil return Rs 20/day; nil cap Rs 500 | [ClearTax](https://cleartax.in/s/gst-return-late-fees) |
| Cap, non-nil | By annual turnover: Rs 2,000 (up to 1.5 cr), Rs 5,000 (1.5 to 5 cr), Rs 10,000 (above 5 cr). Notifications 19/2021 and 20/2021. Sources conflict (one gives a flat Rs 10,000); GSTR-1 and 3B may differ by slab. **Unverified.** | [TaxGuru](https://taxguru.in/goods-and-service-tax/late-fee-interest-cgst-act-2017-latest-amendments.html) |
| GSTR-4 | Rs 50/day, nil Rs 20/day, cap Rs 2,000 (nil Rs 500), Notification 21/2021 | [TaxGuru](https://taxguru.in/goods-and-service-tax/gst-late-fee-penalty-calculation-avoid.html) |
| GSTR-9 | Up to Rs 5 cr turnover: Rs 50/day, cap 0.04% of state turnover (Notification 07/2023). Above Rs 5 cr: Rs 100/day (5 to 20 cr) and Rs 200/day (above 20 cr) with higher caps; these are **unverified background**. Sources conflict. | [ClearTax GSTR-9](https://cleartax.in/s/gstr-9-annual-return) |
| CMP-08, PMT-06 | No per-day late fee found; interest only (**unverified**) | none |
| Interest, tax paid late | 18% p.a. (s.50(1)); 24% on excess or wrongly availed ITC (s.50(3)). Rule 88B: interest on the **net cash** portion only, not on tax covered by credit-ledger balance on the due date | [SMFG summary](https://www.smfgindiacredit.com/knowledge-center/gst-return-late-fees.aspx); Rule 88B text not opened, **unverified** |
| Time bar | No GSTR-1, 3B or 9 more than 3 years after the original due date (Finance Act 2023; s.37(3), 39(11), 44). **Unverified**, text not opened. | statutory-core 2.4 |
| Filing sequence | GSTR-3B cannot be filed if the earlier period's 3B is pending; GSTR-1 can be blocked by an unanswered DRC-01C (see 7) | [TaxGuru Rule 88D](https://taxguru.in/goods-and-service-tax/rule-88d-form-drc-01c-itc-differences-gstr-2b-vs-gstr-3b.html) |

### 1.3 Auto-population and locking: current state

- **Tables 3.1 and 3.2 of GSTR-3B**: auto-populated from GSTR-1, IFF, GSTR-1A and locked (July 2025 period onward). Fix through GSTR-1A. See statutory-core 2.2 for sources.
- **Table 4 (ITC)**: auto-populated from GSTR-2B. Hard lock from July 2026 is **not confirmed**. The best search summary says no GSTN advisory could be verified and Table 4 had stayed editable as of Aug 2026. Sources: [Taxscan](https://www.taxscan.in/top-stories/big-gst-change-from-july-2026-gstr-3b-itc-locking-explained-1448389), [TAXAJ](https://www.taxaj.com/learn/gstr-3b-table-4-itc-hard-locking-from-july-2026-no-manual-editing-surv/). Plan for both outcomes.
- **Confirmed new hard validations** (GSTN Advisory 643, 29 Dec 2025, per a search summary; **verify**): 3B is blocked unless the **Electronic Credit Reversal and Re-claimed Statement** (Table 4B(2), 4D(1)) and the **RCM Liability/ITC Statement** (Table 3.1(d), 4A(3)) are filled and tie to the return. Source: [TaxGuru](https://taxguru.in/goods-and-service-tax/gstn-itc-reclaim-ledger-rcm-ledger-hard-validations-block-gstr-3b-filing.html).
- IMS: see statutory-core 2.3. Actions must be done before 3B. Pending items are left out of 2B and 3B.
- Excess-ITC block: GSTN advisory that 3B can be barred for ITC above 2B-based limits. [LiveLaw](https://www.livelaw.in/amp/tax-cases/taxpayers-to-be-barred-from-filing-gstr-3b-return-for-excess-gst-itc-claims-gstn-issues-advisory-516489). Details unverified.

---

## 2. Self-filing path, return by return

### 2.1 Upload formats at a glance

| Return | JSON upload? | Official offline tool | Keyed online? |
| --- | --- | --- | --- |
| GSTR-1 | Yes. Returns Dashboard > Prepare Offline > Upload JSON. Already built (API.md `format=gstn`). | Excel tool exports JSON; the JSON schema is on the offline-tools page | Possible but slow |
| IFF | Yes, same route (**unverified**) | Excel tool covers it (**unverified**) | Yes |
| GSTR-1A | Online only in practice (**unverified**) | none found | Yes |
| GSTR-3B | Yes, "Prepare Offline > Upload" per [Tally guide](https://help.tallysolutions.com/docs/te9rel66/Tax_India/gst/filing_gstr3b.htm); JSON schema is public on the API developer portal (**unverified**). With 3.1/3.2 locked, an uploaded 3.1/3.2 that disagrees with GSTR-1 is probably ignored or rejected (**unverified**). | A 3B offline utility existed in 2017 to 2019 (background) | Yes, and for set-off in 6.1 always |
| PMT-06 | No | none | Yes, online challan |
| CMP-08 | **No offline tool, online only** per [ClearTax GSTR-4 guide](https://cleartax.in/s/gstr-4-offline-utility-guide) | none | Yes |
| GSTR-4 | Yes: Excel offline tool plus portal Upload/Download JSON | Yes, "Downloads > Offline Tools > GSTR-4 Annual Return Offline Tool" | Yes |
| GSTR-9 | Yes: offline utility imports portal-generated JSON of GSTR-1/3B data, then you edit and upload JSON | Yes, released per FY. [ClearTax](https://cleartax.in/s/gstr9-offline-utility-guide), [GSTZen manual](https://gstzen.in/a/gst-manuals-user-manuals-preparing-gstr-9-using-offline-utility.html) | Yes (small filers) |
| GSTR-9C | Offline utility and JSON, self-certified (**unverified**) | Yes | Yes |
| ITC-04 | Offline utility and JSON (background, **unverified**) | Yes | Yes |
| LUT, DRC-03 | No | none | Yes, online forms |

Design rule: **use the official offline utility or the portal's own preview as the final validator.** Progen exports are "portal-ready" only if they pass the portal's JSON upload validation, which we cannot test without a taxpayer login. Ship a "Validate on portal" checklist step.

### 2.2 Signing, verification and OTP

- Rule 26 (background, **unverified**): a company must sign returns with **DSC**; other persons may use DSC, e-sign or **EVC**. GSTN has sometimes allowed EVC for companies on some returns; check the current return's "File" screen. Sole proprietors, partnerships and LLPs normally use EVC.
- EVC: an OTP to the mobile and email registered for the **authorised signatory** on the GSTIN. This is the only human step that no software can remove for portal filing.
- Login uses username and password plus an OTP (mobile). Keep the signatory's mobile active.
- Nil GSTR-1/3B can be filed by SMS (background, **unverified**; not in sources). Do not depend on it.

### 2.3 Owner steps per return (portal route)

Common start: log in at gst.gov.in > Services > Returns > Returns Dashboard > choose financial year and period > open the tile.

**GSTR-1 (monthly or quarterly)**
1. In Progen: Reports > GSTR-1 for the period; fix every warning; export `gstr1_YYYYMM.json`.
2. Portal: GSTR-1 tile > Prepare Offline > Upload > Choose file. Wait for "Processed" (refresh the page).
3. Open each table; check counts and values against the Progen summary.
4. Generate summary > Submit (freezes data) > File with EVC or DSC > enter OTP. Quarterly filers: also upload B2B to IFF in months 1 and 2 if buyers need credit earlier.
5. Download the filed PDF into Progen's document store for the audit trail.

**GSTR-3B (monthly or quarterly)**
1. Wait for 2B (about the 14th). Fetch from the portal: Returns > Auto-drafted ITC Statement (2B) > Download JSON; import into Progen (`POST /gst/2b-imports`). Act on IMS first (see 7).
2. Open the 3B tile. Tables 3.1/3.2 and 4 appear pre-filled. Compare with Progen's 3B workings (table map below). Edit only editable cells (3.1(d) RCM, 4B reversals, 4D, 5, 5.1) and anything not locked.
3. Table 6.1: shows tax payable. If cash is short, use "Create Challan" (PMT-06) inside the return, pay, wait for the cash-ledger credit, then click "Set off liability".
4. Preview > Submit > Make payment > File with EVC or DSC. **A filed 3B cannot be revised.**

**PMT-06 (QRMP, months 1 and 2)**
1. Services > Payments > Create Challan. For QRMP the 35% option shows after the previous quarterly 3B: the challan pre-fills with 35% of last quarter's cash tax if the last return was quarterly, or 100% if it was monthly ([Studycafe](https://studycafe.in/gst-pmt-06-35-option-challan-enabled-on-gst-portal-94346.html)). Or use the self-assessment method with Progen's computed liability.
2. Pay by net banking, card, UPI (**unverified**), NEFT/RTGS (generate challan, pay at bank) or over the counter. Challan valid 15 days. Details: [Zoho](https://www.zoho.com/in/books/gst/pmt-06-payment-challan.html), [ClearTax](https://cleartax.in/s/gst-payment).
3. CPIN is created at challan generation; the bank returns a CIN on payment. Cash-ledger credit is usually the same day for online modes (**unverified**).

**CMP-08 (composition, quarterly)**: Returns Dashboard > CMP-08 tile > enter outward supplies value, inward RCM value, tax per head, interest if late > pay from cash ledger (create PMT-06 challan if short) > submit > file with EVC/DSC. Fully online.

**GSTR-4 (composition, annual)**: download the offline tool or use the portal JSON route; Table 5 (self-assessed liability per CMP-08) is auto-populated and locked ([ClearTax](https://cleartax.in/s/gstr-4-offline-utility-guide)); enter the remaining tables, compute, submit, file with EVC/DSC.

**GSTR-9 / 9C**: see section 5.

**LUT**: Services > User Services > Furnish Letter of Undertaking (LUT) > choose FY > fill details, no payment; sign with DSC or EVC ([Setindiabiz](https://www.setindiabiz.com/blog/gst-lut-filing-fy-2026-27)). Keep the ARN; quote the LUT ARN on export invoices without tax.

**DRC-03**: portal path **unverified** (Services > Payments area). Choose the Act and the cause (for example "ITC mismatch GSTR-2B to 3B", "Others" for voluntary), amounts per head, pay from the cash ledger; file on or after the notice date if answering a notice ([TaxGuru](https://taxguru.in/goods-and-service-tax/respond-drc-01c-notice-itc-mismatch-gstr-2b-vs-gstr-3b.html)).

**ITC-04**: Progen would need a job-work challan register (items sent, received back, scrapped, balance). Does not exist yet; low priority.

### 2.4 Which Progen number goes into which GSTR-3B table

Existing `GET /gst/gstr3b` fields on the left. "Gap" means the report needs extending.

| Portal table | Content | Progen source | Status |
| --- | --- | --- | --- |
| 3.1(a) | Outward taxable (not zero-rated) | `outward` | present; will be overwritten by the locked auto-population |
| 3.1(b) | Outward zero-rated (exports, SEZ), taxable value and IGST if paid | none | **gap**, needs export/SEZ invoice flag |
| 3.1(c) | Nil, exempt | `zeroNil.taxable` | present |
| 3.1(d) | Inward supplies on reverse charge | `inwardRcm` | present; must match the RCM statement |
| 3.1(e) | Non-GST outward | none | gap |
| 3.2 | Inter-state supplies to unregistered, composition, UIN | `interStateUnregistered` | partial (no composition/UIN split) |
| 4A(1), 4A(2) | ITC on import of goods, services | none | gap (needs bill of entry and import flags) |
| 4A(3) | RCM ITC | `itc.rcm` | present |
| 4A(4) | ISD | none | not needed for most |
| 4A(5) | Other ITC, from 2B | `itc.others` | present; **must be limited to 2B-accepted** |
| 4B(1) | Reversals under Rule 38, 42, 43, s.17(5) | `itc.reversed` is 0 | gap |
| 4B(2) | Other reversals (Rule 37 180-day from ITC ageing) | ITC ageing report | gap, link `reversal` rows |
| 4D(1), 4D(2) | Reclaim of earlier reversal; ineligible ITC | none | gap |
| 5 | Exempt, nil, non-GST inward supplies (intra and inter; also composition suppliers) | none | gap |
| 5.1 | Interest and late fee | account 5910 | partial |
| 6.1 | Tax and interest paid, by credit/cash | `payable`, `rcmCash` | **simple version only**, no cross-utilisation (section 4) |

### 2.5 CMP-08 and GSTR-4 number map

| Portal field | Progen source |
| --- | --- |
| CMP-08 outward supplies (excluding inward RCM), by rate class | Bill-of-supply total for the quarter by category, net of credit notes |
| CMP-08 inward supplies attracting RCM, tax | RCM report (composition taxpayers still pay RCM; **unverified**) |
| CMP-08 interest | Computed from due date (section 1.2) |
| GSTR-4 Table 4 | Inward supplies split: from registered suppliers (B2B, with RCM), from unregistered, imports, from composition/exempt (table numbers **unverified**, check the offline tool) |
| GSTR-4 Table 5 | Auto from CMP-08 |
| GSTR-4 outward supplies table | Annual turnover by rate class, net of notes |

---

## 3. Direct filing by software (GSP / ASP model)

### 3.1 Who can call GSTN APIs

- GSTN gives direct API access only to **GSTN-approved GST Suvidha Providers (GSPs)**. Eligibility is a company registered in India or a PSU with infrastructure to handle at least 1 lakh GST transactions a month ([Medianama, 2016](https://www.medianama.com/2016/10/223-gst-network-apis-eligibility-criteria/)). The 2016 criteria may have changed.
- An **Application Service Provider (ASP)** is a software vendor (Progen) that uses a GSP's API. No GSTN approval is needed for an ASP; the ASP contracts with a GSP and gets credentials from it. Sources: [Tally ASP vs GSP](https://tallysolutions.com/gst/asp-vs-gsp-in-gst-what-is-the-difference-and-how-do-they-work-together/), [Deskera](https://www.deskera.com/blog/why-has-the-goods-and-services-tax-gst-network-created-apis/). The GSTN API developer portal `developer.gst.gov.in/apiportal` lists Taxpayer API groups (Returns and Ledger, Authentication, Registration, Payment, E-Invoice) but **no detail is public to non-GSPs** (page fetched, nav only).
- Onboarding steps with a GSP (typical; **unverified**, vendor-specific): sign API agreement; get sandbox keys; build against sandbox with test GSTINs; UAT sign-off; production keys. The GSP lists Progen as an ASP with a name that the taxpayer later selects on the portal.
- Cost: no public rate card. One GSP (SahiGST) estimated about Rs 125 a month per GSTIN (up to 2,000 B2B documents) plus about Rs 10 per eSign ([SahiGST](https://sahigst.freshdesk.com/support/solutions/articles/31000131736-understanding-gsp-charges)); this is an older estimate. SaaS tools charge about Rs 149 to 199 per GSTIN per month, which bounds what end users accept. Ask each GSP for a quote. **Treat cost as unknown.**

### 3.2 Taxpayer consent flow

Per [Quicko](https://learn.quicko.com/gst-portal-manage-api-access), [Tally](https://tallysolutions.com/gst/gst-asp-consent-what-is-it-and-how-will-it-work-for-taxpayers/), [IRIS](https://irisgst.com/?p=36420):
1. Taxpayer logs in at gst.gov.in > My Profile > **Manage API Access** > Enable API Request = Yes.
2. Selects the **GSP and ASP pair** (Progen under its GSP) and a duration (minimum 6 hours, up to 30 days). Repeat per GSTIN.
3. Software calls Generate OTP; GSTN sends an OTP to the taxpayer's registered mobile; software calls Verify OTP and receives an auth token and session key.
4. Token life: 6 hours by default; the IRIS page says it can be extended without a new OTP within 24 hours, and a new OTP is needed after the chosen window (single source, **unverified**). The taxpayer can see 30 days of token logs and revoke a token at any time ([Tally](https://tallysolutions.com/gst/gst-portal-to-notify-taxpayers-about-asp-access-what-changes-for-businesses/)).
5. UX consequence: the owner must re-enter an OTP at least once per session window. Progen must keep a "session expires in X" banner and fall back to the file-pack route.

### 3.3 APIs that exist (via GSPs)

Names from [Masters India docs](https://docs.mastersindia.co/goods-and-services-tax-gst-api/file-submit) and the [Sandbox walkthrough](https://medium.com/blog-by-sandbox/file-gst-returns-using-sandbox-apis-be560f528ae7). The raw GSTN names are in the closed GSP documentation.

| Function | Available | Source |
| --- | --- | --- |
| Authenticate (OTP, verify, refresh) | Yes | Sandbox |
| GSTR-1 upload (save), reset, submit, summary, file | Yes | Sandbox |
| GSTR-3B save, get, autocalc liability, submit, file | Yes (save_3b_data, get_3b_data, get_autocalc_liability_detail_api, Upload_gstr3b) | Masters India |
| Cash, credit and liability ledgers, cash balance | Yes (Returns and Ledger group) | GSTN portal nav; call names **unverified** |
| GSTR-2B / 2A fetch | Yes (background; **unverified**) | none |
| IMS actions (accept, reject, pending) | **Unverified**, expect GSP-specific APIs; no source found | none |
| Return status by reference ID | Yes (background; **unverified**) | none |
| PMT-06 challan creation, payment | Challan generation via API exists (Payment group); payment itself goes through the bank gateway, so a human is involved | **unverified** |

### 3.4 Can filing be completed through the API?

**Yes for EVC, no for DSC without extra tooling.** Sandbox shows: Upload > Submit > **Generate EVC OTP** (OTP sent to the signatory's phone and email) > **File with EVC OTP** ([Sandbox walkthrough](https://medium.com/blog-by-sandbox/file-gst-returns-using-sandbox-apis-be560f528ae7)). The owner still types two OTPs: one to open the session, one to file. DSC needs a signing helper (emSigner or a local agent) and a company DSC cannot be signed from a phone app (**unverified**). Submission alone is not filing.

### 3.5 GSPs to approach

| Provider | Public docs | Note |
| --- | --- | --- |
| Masters India | [docs.mastersindia.co](https://docs.mastersindia.co/goods-and-services-tax-gst-api/file-submit) | Public REST docs, JWT, GSTR-1 and 3B file/submit pages; some pages two years old |
| Sandbox (sandbox.co.in) | [Medium walkthrough](https://medium.com/blog-by-sandbox/file-gst-returns-using-sandbox-apis-be560f528ae7) | Developer-first, full EVC flow documented |
| Quicko | [quicko.com/gsp](https://quicko.com/gsp) | Markets "build on Quicko"; API consent guide public |
| IRIS GST | [irisgst.com](https://irisgst.com/?p=36420) | Long-standing GSP; docs behind sign-up |
| GSTHero (Perennial) | [gsthero.com](https://gsthero.com/gst-suvidha-provider-gsp/) | ASP model for ERPs; marketing claims unverified |

Also possible: Cygnet, ClearTax (no public developer docs found). Check GSTN's current approved-GSP list on gst.gov.in before signing (not found in search).

---

## 4. Payment, ledgers, and the set-off algorithm

### 4.1 Ledgers

- **Electronic cash ledger**: filled by PMT-06 challan. Heads: tax, interest, penalty, fee, other, each across IGST, CGST, SGST/UTGST, cess. Cash can pay any head.
- **Electronic credit ledger**: ITC only, for tax heads only (not interest, penalty, late fee).
- **Electronic liability register**: what the return created. Payment through "Set off liability" in 3B or DRC-03.
- Interest, late fee and penalty: **cash only**. RCM tax: **cash only** (RCM ITC is claimed later in 4A(3)). [ClearTax](https://cleartax.in/s/gst-payment), [Tally](https://help.tallysolutions.com/docs/te9rel62/Tax_India/gst/filing_gstr3b.htm).
- Rule 86B (background, **unverified**): if taxable outward value in the month exceeds Rs 50 lakh, at least 1% of output tax (other than RCM and exempt classes) must be paid in cash unless the exceptions apply. Check the rule text before enforcing.

### 4.2 Utilisation order (s.49, 49A, 49B, Rule 88A)

Sources: [TaxGuru](https://taxguru.in/goods-and-service-tax/input-tax-credit-gst-section-49a-49b-rule-88a.html), [Munim](https://themunim.com/blog/order-of-itc-utilisation-under-gst/). Effective 1 Feb 2019; rule text not opened here. **Unverified in primary form.**

Rules:
1. IGST credit is used **first** and **fully** against IGST liability, then the remainder against CGST and SGST liability in any order and any proportion (Rule 88A).
2. Only after IGST credit is exhausted may CGST credit be used, first against CGST liability, then against IGST.
3. Only after IGST credit is exhausted may SGST credit be used, first against SGST liability, then against IGST.
4. CGST credit never pays SGST liability and SGST credit never pays CGST liability (s.49(5)).
5. Cess credit pays cess liability only. Cess is being wound down (statutory-core 1.3).
6. Any remaining liability is paid from the cash ledger, by head.
7. Order across dues (s.49(8), background): earlier-period self-assessed tax, then current-period self-assessed tax, then other dues; within each, tax, interest, penalty, fee, others. Do the credit ledger step only for tax.

Implementable algorithm (all values in paise, per return):

```
input:  liab {igst, cgst, sgst, cess}, rcm {igst, cgst, sgst, cess},
        credit {igst, cgst, sgst, cess}, cash balances by head
        intFee {interest, lateFee} (cash only)
step 0: pay_by_credit = liab - rcm          // RCM is cash-only
        cash_need    = rcm + intFee
step 1: use_i_to_i = min(credit.igst, pay.igst);  credit.igst -= use_i_to_i; pay.igst -= use_i_to_i
step 2: // remaining IGST credit against CGST and SGST in any order.
        // Default rule: CGST first, then SGST (least loss, see note). Allow user override.
        use_i_to_c = min(credit.igst, pay.cgst); credit.igst -= use_i_to_c; pay.cgst -= use_i_to_c
        use_i_to_s = min(credit.igst, pay.sgst); credit.igst -= use_i_to_s; pay.sgst -= use_i_to_s
step 3: // only after step 1-2 leave credit.igst == 0 OR all pay.cgst/pay.sgst == 0 ... see below
step 4: use_c_to_c = min(credit.cgst, pay.cgst); credit.cgst -= use_c_to_c; pay.cgst -= use_c_to_c
step 5: use_c_to_i = min(credit.cgst, pay.igst); credit.cgst -= use_c_to_i; pay.igst -= use_c_to_i
step 6: use_s_to_s = min(credit.sgst, pay.sgst); credit.sgst -= use_s_to_s; pay.sgst -= use_s_to_s
step 7: use_s_to_i = min(credit.sgst, pay.igst); credit.sgst -= use_s_to_i; pay.igst -= use_s_to_i
step 8: cess: use = min(credit.cess, pay.cess)
step 9: cash_due[h] = pay[h] + rcm[h] + intFee   // by head; compare with cash balance
output: set-off matrix, remaining credit (carry forward), cash_due, cash shortfall
```

Notes for the implementer:
- Step 3 is a guard, not code: Rule 88A requires IGST credit to be exhausted **before** CGST/SGST credit pays anything. If IGST credit remains after step 2, then pay.cgst and pay.sgst are already zero, so steps 4 to 7 only act on residual IGST liability (none left) and are harmless. If the code ever lets CGST credit pay CGST liability while IGST credit is unused, that is a bug.
- The case of choice: when IGST credit exceeds IGST liability and both CGST and SGST are due, the owner may choose the split. Default CGST first is a heuristic. Optimise instead to **leave the larger carry-forward in the head that is more likely to be needed**, and show both options. The portal 3B screen takes the owner's chosen split.
- v1.4 `payable` currently floors per head with no cross-utilisation. This algorithm replaces it. Keep the old figure as `payableNoCross` for diff.
- Test cases: IGST credit 100, IGST due 40, CGST due 50, SGST due 30 gives IGST 40, then CGST 50 pays from the remaining 60 IGST credit, SGST 10 from the rest, SGST due remaining 20 from SGST credit or cash.
- The portal screen allows the user to edit the split in Table 6.1. Progen's set-off page should show the **suggested split** the owner types in, plus the numbers that must match.

### 4.3 PMT-06 helper data

Challan needs: GSTIN, period or free text, amounts per head split by tax, interest, penalty, fee, other; payment mode. A pre-filled helper in Progen should compute the **cash shortfall per head** from section 4.2 and show "Pay this much on PMT-06 under these heads". Add a reminder that net-banking credit may take hours and challans lapse after 15 days.

---

## 5. Annual return: GSTR-9 and GSTR-9C

Table numbers are the standard GSTR-9 layout (background); **check against the FY 2025-26 offline utility**, which GSTN changes yearly (see [Taxscan FY24-25 changes](https://www.taxscan.in/top-stories/key-changes-in-gstr-9-and-gstr-9c-for-fy-2024-25-everything-you-should-know-1437208)).

| GSTR-9 table | Content | Progen source | Gap |
| --- | --- | --- | --- |
| 4 | Outward taxable supplies, by B2C, B2B, exports, SEZ, deemed, advances, inward RCM, amendments | GSTR-1 totals for the FY plus amendments | auto-populated from GSTR-1; Progen needs FY roll-up and post-FY amendment tracker |
| 5 | Non-taxable outward (zero-rated, exempt, nil, non-GST) | nil/exempt/export flags | export flag gap |
| 6 | ITC availed (inputs, capital goods, services, imports, RCM) | purchases, expenses, ITC by type | **capital goods flag gap**, import flag gap |
| 7 | ITC reversed (Rules 37, 39, 42, 43, s.17(5)) | reversal entries | gap (4B not built) |
| 8 | ITC per GSTR-2B (8A) vs availed; 8D difference | `2b-recon` | **tie-out data exists** |
| 9 | Tax paid: payable, paid in cash, paid by ITC | set-off records | gap (section 4) |
| 10 to 13 | Prior-FY transactions declared in this FY | amendments register | gap |
| 14 | Differential tax paid on 10 to 13 | gap | gap |
| 15 | Refunds, demands, deemed supply | none | manual entry |
| 16 | Composition supplies, deemed supply, goods on approval | none | manual entry |
| 17, 18 | HSN summary of outward and inward (Table 17/18 optional up to Rs 5 crore per one source, **unverified**) | HSN data exists for outward in GSTR-1; **inward HSN gap** | inward HSN gap |
| 19 | Late fee on 9 | none | computed |

**Turnover reconciliation**: Annual-return turnover must reconcile to books. Progen can show: (a) revenue per ledger, (b) invoices in GSTR-1, (c) differences with reason codes (unbilled revenue, advances, credit notes after year end, exempt, other). This feeds GSTR-9C Table 5.

**GSTR-9C (above Rs 5 crore, self-certified)** needs (background, **unverified table numbers**):
- Part A: reconcile turnover per audited financial statements to GSTR-9 (Tables 5 to 8), taxable turnover reconciliation (Table 7), tax paid reconciliation (Table 9 to 10), ITC reconciliation (Tables 11 to 12: expenses vs ITC, with reasons), and additional liability (Table 14).
- Part B: the taxpayer's own certification (replaced the CA's) of the reconciliation, signed by DSC or EVC.
- Needs **audited financial statements** (P&L, balance sheet for the FY); Progen can supply ledger-based unaudited versions and variance lists, but the owner must have the audited figures.

Time: GSTR-9 is a significant yearly job. A Progen "annual pack" would be an XLSX with the table map above and every difference listed, which the owner then keys into the offline utility.

---

## 6. Composition scheme (CMP-08 and GSTR-4)

| Class | Rate on turnover | Source |
| --- | --- | --- |
| Manufacturers, traders (goods) | 1% (0.5% CGST + 0.5% SGST) | statutory-core 5.5 (unverified) |
| Restaurants, no alcohol | 5% | same |
| Other services (s.10(2A)) | 6% | same |

- Limits: Rs 1.5 crore (Rs 75 lakh special-category states); services-only Rs 50 lakh (statutory-core 5.5, unverified). Rates on "turnover in the State" (aggregate of taxable and exempt supplies, excluding inward RCM supplies and exports; background).
- **CMP-08 computation**: quarterly tax = rate x (outward turnover for the quarter, net of credit notes) + RCM tax on inward supplies (pay in cash). No ITC. Pay in cash ledger, then file. Quarter Q4 (Jan to Mar) is also reported in GSTR-4.
- Tax is **not collected from the customer**: bill of supply only (see statutory-core 5.5).
- **GSTR-4**: annual; reconciles to CMP-08 (Table 5, auto-populated); confirm inward supplies split and outward by rate class; interest and late fee fields for late CMP-08.
- Cannot do inter-state outward goods (statutory-core 5.5).
- Progen status: nothing exists for composition returns. Needs a company-level `registrationType: 'composition'` flag (see contractor-billing.md section 5), category rate, bill-of-supply numbering, and a quarterly CMP-08 report.

---

## 7. Notices and pre-filing checks

### 7.1 The notices

| Notice | Trigger | Consequence | Response | Source |
| --- | --- | --- | --- | --- |
| DRC-01B (Rule 88C) | Liability reported in GSTR-1/IFF exceeds tax paid in 3B beyond a threshold (amount and percentage; **unverified**, about Rs 50,000 and 10% from background) | Next period's GSTR-1/IFF may be blocked until answered | Pay the difference via DRC-03 or explain in Part B within 7 days | [TaxGuru](https://taxguru.in/goods-and-service-tax/respond-drc-01c-notice-itc-mismatch-gstr-2b-vs-gstr-3b.html) (rule reference confusion noted by the search tool) |
| DRC-01C (Rule 88D, Notification 38/2023-CT, 4 Aug 2023) | ITC in 3B exceeds ITC in 2B beyond a threshold (about Rs 25,000 and 20%, background, **unverified**) | GSTR-1/IFF blocked if no Part B reply in 7 days (Rule 59(6)) | Reverse via DRC-03 (cause: ITC mismatch) with interest, or reconcile invoice-wise and reply in Part B. GSTR-1 unblocks on filing the reply | [TaxGuru Rule 88D](https://taxguru.in/goods-and-service-tax/rule-88d-form-drc-01c-itc-differences-gstr-2b-vs-gstr-3b.html), [ClearTax Rule 88D](https://cleartax.in/s/rule-88d-cgst-itc-mismatch-gstr-2b-vs-gstr-3b) |
| ASMT-10 | Officer's scrutiny of a return: difference between returns and 2B/e-invoice/e-way bill data, or other discrepancies (s.61) | Reply in ASMT-11 within 30 days (background, **unverified**); failure leads to adjudication (s.73/74/74A) | Explain or pay | background, no source |

### 7.2 Pre-filing checks Progen should run

Check list (each is a pure query on Progen data):

1. **GSTR-1 vs 3B liability**: after GSTR-1 export, compare 1 totals (tax) with the ledger and the 3B tax payable; flag any difference above Rs 1 (DRC-01B guard). Already partially covered by `variance` in `Gstr1`.
2. **ITC vs 2B**: 3B `itc.others` must not exceed 2B accepted ITC for the period (DRC-01C guard). Show "excess ITC" before filing; show the DRC-01C threshold (once confirmed).
3. **IMS pending**: warn if any 2B line is pending or unactioned before 3B.
4. **Rule 37 and Rule 37A**: list ageing items that need reversal in 4B(2); reclaim items in 4D(1); both must tie to the reclaim statement (Advisory 643).
5. **RCM statement tie-out**: 3.1(d) and 4A(3) equal the sum of RCM self-invoices (account 2130).
6. **Missing GSTIN or invalid GSTIN checksum** on B2B documents; **place of supply** and rate validity (already covered by the rate master).
7. **E-invoice IRN missing** for B2B invoices if the company is in the e-invoice scheme (threshold not re-verified here; see e-invoice docs).
8. **Filing sequence**: previous period's 1 and 3B filed; nothing pending (13 Oct 2026 advisory).
9. **HSN digits** per turnover class (statutory-core 2.6).
10. **Document series continuity** for Table 13 (docs issued) and cancelled counts.
11. **Cash shortfall** against the set-off algorithm: "pay Rs X by date Y to avoid interest".
12. **Time bar**: warn when a missing return is within 90 days of the 3-year limit.
13. **Interest and late fee estimate** for late returns, with Rule 88B net-cash basis.

---

## Build recommendation for Progen

Priority order. Assumes the file-pack route is the default and direct filing is an upgrade.

**(a) Self-file packs and exports, now**
1. **GSTR-1 pack**: keep `gstr1_YYYYMM.json`; add a one-page checklist PDF/HTML with the numbers to compare on the portal and the portal steps from 2.3. Add IFF JSON for QRMP (B2B and notes only).
2. **GSTR-3B pack**: an XLSX or on-screen worksheet in the portal's table order (map 2.4), with a column for "portal shows" so the owner ticks agreement. Add a `format=gstn` JSON for 3B (`ret_period`, `sup_details`, `inter_sup`, `itc_elg`, `inward_sup`, `intr_ltfee`, `tx_pmt`) as an **optional** upload, because 3.1/3.2 will be locked anyway (**unverified** acceptance).
3. **Reversal and reclaim statement and RCM statement** exports in the portal's format, since Advisory 643 blocks 3B without them. Build the 4B(1), 4B(2), 4D(1) data (currently 0).
4. **CMP-08 sheet and GSTR-4 annual sheet** for composition clients (needs registration-type flag). Online keying only, so the sheet is the product.
5. **GSTR-9/9C annual pack**: XLSX with the section 5 table map, turnover reconciliation, ITC and 2B differences, outward and inward HSN summaries. No JSON: the owner imports the portal JSON into the offline utility and types differences.
6. **Due-date alerts**: extend `Alert.kind` with `cmp08_due`, `gstr4_due`, `pmt06_due`, `gstr9_due`, `lut_renew`, `itc04_due`, `gstr1a`.
7. Store every filed ARN and PDF, plus the SHA-256 of every export (as statutory-core 2.5 says).

**(b) Set-off calculator and challan helper**
- Implement section 4.2 as `POST /gst/setoff-preview?period=` returning the matrix, carry-forward credit and cash shortfall by head. Add cash and credit ledger **opening balance entry** (manual entry from the portal ledger, with a "last synced" date) because Progen has no ledger feed without the API.
- PMT-06 helper: amounts per head and a step list for QRMP (35% or self-assessed). Journal for challan payment: Dr GST cash ledger (new asset account), Cr bank; on set-off, move between GST liability, ITC and cash accounts.
- Interest and late-fee estimator (section 1.2).

**(c) Pre-filing checks**
- A single `GET /gst/prefile-check?period=` returning pass/warn/fail for each item in 7.2, shown on the GST screen and blocking the "Mark as filed" action on failures. Highest value: items 1, 2, 3, 4, 5, 8.
- Do not claim DRC thresholds in the UI until verified against Rule 88C/88D text.

**(d) Direct-filing adapter (later; same modes as e-invoice)**
- `gstProvider: 'manual' | 'sandbox' | 'live_gsp'`. `manual` is (a). `sandbox` uses the GSP's test GSTIN and fake OTPs. `live_gsp` uses real taxpayer consent.
- Interface: `authenticate(gstin) -> sessionId` (OTP request, verify), `getSession`, `saveGstr1(payload)`, `submitGstr1`, `fileGstr1(evcOtp)`, `getGstr2b(period)`, `saveGstr3b`, `getLiabilityAutocalc`, `getLedgers`, `submitGstr3b`, `fileGstr3b(evcOtp)`, `getReturnStatus(refId)`, `imsAction(...)` (**API unconfirmed**).
- Credentials per company: GSP name, ASP client id and secret (platform-wide, stored server side), per-GSTIN: portal username, **session token and expiry** (never store the OTP), and the Manage API Access validity window. Rotating secrets must be encrypted at rest and redacted in logs.
- Start with: **read-only** (2B fetch, ledgers, return status) because it removes the biggest manual jobs (download and import 2B, key cash balance) with no filing risk. Then GSTR-1 save/submit/file, then 3B.
- Pick one GSP first (Masters India or Sandbox have public docs); abstract the rest behind the adapter.
- Cost: unknown, ask for quotes; model it as a per-GSTIN monthly fee, probably Rs 100 to 200 range (**unverified**, SahiGST estimate only).

**(e) What cannot be avoided**
- The owner or authorised signatory with the registered mobile must enter the **login OTP** and the **EVC OTP** (or use DSC) to file GSTR-1, 3B, CMP-08, GSTR-4, 9, 9C. No software can file on its own. Companies typically need a DSC (Rule 26; confirm).
- **Manage API Access** consent and session renewal belong to the taxpayer, at least every 30 days.
- **Bank payment** for PMT-06 (net banking login and OTP at the bank).
- **LUT** and **DRC-03** have no known API path; do in the portal.
- Notice replies (DRC-01B/01C/ASMT-10) need human judgement and signing.
- GSTR-9C needs audited financials and a human certification.
- Provide a clear in-app "Needs you" panel listing each of these with the login steps; do not imply "auto-filed".

### Open items to verify before coding
1. GSTR-4 due date (30 Apr vs 30 Jun) and CMP-08 late-fee rules.
2. Late-fee cap table (GSTR-1 vs 3B slabs; GSTR-9 above Rs 5 crore).
3. Rule 88C and 88D thresholds.
4. Whether Table 4 hard-lock is live; GSTN Advisory 643 text.
5. Whether portal accepts an uploaded 3B JSON when 3.1/3.2 are locked.
6. GSTN IMS and GSTR-2B API availability through GSPs, and GSP price quotes.
7. Rule 26 on EVC versus DSC for companies.
