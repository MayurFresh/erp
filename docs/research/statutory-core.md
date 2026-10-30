# Statutory core for every Indian business: GST, TDS/TCS, MSME, books

Checked 29 Oct 2026 (FY 2026-27). Every fact cites a source. Anything not confirmed from a primary or official source is marked **UNVERIFIED**.

**Scope.** This note covers what any Progen tenant needs, whatever its industry. It does not repeat:
- E-invoice and e-way bill: see [gst-einvoice-ewaybill.md](gst-einvoice-ewaybill.md).
- The contractor TDS table (194C, 194M, 194H, 194-IA, 194J, "designated person", no-PAN): see the TDS section of [contractor-billing.md](contractor-billing.md). Section 3 below reuses it and adds the other sections.

**Source quality.**
- incometaxindia.gov.in and cbic-gst.gov.in blocked or returned undecodable PDFs to automated fetches in several cases.
- The CBIC gazette PDF of Notification 15/2025-CT(Rate) was decoded locally (see section 1.4). Most other rate and rule text comes from secondary sites that quote the gazette.
- Treat the secondary-sourced rows as "likely right, confirm before code".

**Law in force (headline).**
- GST: CGST Act 2017 and CGST Rules 2017, as amended through the Finance Act 2026 (Act 4 of 2026, assent 30 Mar 2026).
- Income tax: Income-tax Act 2025 (in force 1 Apr 2026) and Income-tax Rules 2026 (G.S.R. 198(E), 20 Mar 2026). Cited as "new s.X (old s.Y)".
- MSME: MSMED Act 2006.
- Companies: Companies Act 2013 and Companies (Accounts) Rules 2014.

---

## 1. GST rate structure after 22 Sep 2025 ("GST 2.0")

### 1.1 Slabs

The 56th GST Council (3 Sep 2025) replaced the 5/12/18/28% structure. Rates took effect on 22 Sep 2025.

| Slab | Use | Source |
| --- | --- | --- |
| 0% / exempt | Unchanged exempt and nil-rated lists | [Business Standard on the Council decision](https://www.business-standard.com/economy/news/gst-council-adopts-two-rate-structure-with-exemptions-125090301624_1.html) |
| 5% | Merit slab (old 5% plus most old 12%) | same |
| 18% | Standard slab (old 18% plus most old 28%) | same |
| 40% | "De-merit" slab: large cars, motorcycles over 350cc, yachts, personal aircraft, aerated drinks, etc. | [Tally summary](https://tallysolutions.com/gst/new-gst-rates-september-2025-business-impact/) |

The Council's own page is https://gstcouncil.gov.in/node/3879 (listed in search; not opened, so item-level lists are **UNVERIFIED** here).

Notification numbers:
- Goods: 9/2025-Central Tax (Rate) dated 17 Sep 2025 (G.S.R. 641(E)). It superseded 1/2017-CT(Rate). Later amended by 19/2025-CT(Rate) dated 31 Dec 2025 and 01/2026-CT(Rate) dated 30 Apr 2026 (aligns with the Finance Act 2026). Sources: [taxheal copy of 9/2025](https://www.taxheal.com/?p=104997), [CBIC-hosted 19/2025 PDF](https://d23z1tp9il9etb.cloudfront.net/download/gstlaw/19-2025-CTR-Eng1767267819.pdf), [simpliance listing of 01/2026](https://simpliance.in/India/FCC/govt_notification/Central/notification-regarding-amendment-of-notification-no-92025-central-tax-rate-to-align-them-with-changes-made-vide-finance-act-2026-9278). Texts of 19/2025 and 01/2026 were not read.
- Services: 15/2025-Central Tax (Rate) dated 17 Sep 2025, amending 11/2017-CT(Rate). The IGST and UTGST twins carry the same date.
- Because the rate is a column per tax head, the CGST column is half the IGST rate (e.g. 9% + 9% = 18%).

### 1.2 Special rates (outside the slabs)

| Item | Rate | Status |
| --- | --- | --- |
| Gold, silver (value of goods) | 3% | Unchanged; Council retained it ([Angel One](https://www.angelone.in/news/economy/gold-silver-retain-3-gst-as-council-freezes-tax-rates-ahead-of-festive-season)) |
| Jewellery making charges (job work on jewellery) | 5% | Same source |
| Rough diamonds and rough precious stones | 0.25% | Secondary summary ([busy.in](https://busy.in/gst-rates.md)); **UNVERIFIED** against the schedule |
| Cut and polished diamonds | 1.5% | Pre-2025 entry; not re-confirmed after Sep 2025, **UNVERIFIED** |
| Works contract and construction for affordable and other housing | 1% / 5% | Unchanged; see 1.4 |
| Biri | 9% | From 1 Feb 2026 per [CA Cult summary](https://cacult.com/?p=59482); **UNVERIFIED** (gazette not opened) |
| Pan masala, unmanufactured tobacco, cigarettes, other tobacco products | 20% | From 1 Feb 2026, same source; **UNVERIFIED**. Central excise on tobacco is a separate regime. |

Schedule VII (14%) and its entries were deleted from 9/2025 effective 1 Feb 2026 (same CA Cult source, **UNVERIFIED**).

### 1.3 Compensation cess wind-down

- From 22 Sep 2025 the cess was dropped for everything except tobacco-related goods. For luxury and sin goods it was merged into the 40% rate. Source: [India Briefing](https://www.india-briefing.com/news/gst-cess-removal-india-2025-business-benefits-39879.html/) and the Council summary linked above.
- Tobacco and pan masala stayed at the old GST plus cess "until loan and interest obligations under the cess account are discharged" (same sources).
- The cess then ended for tobacco with the 1 Feb 2026 notification above. Source is secondary and silent on cess, so the end date for cess is **UNVERIFIED**.
- Old cess still matters for: credit notes against pre-cutover tobacco invoices, returns for old periods, and ITC of cess paid on purchases (cess ITC can only be set against cess liability).

### 1.4 Works-contract GST rates: open question resolved

Question from [docs/research/README.md](README.md) and [contractor-billing.md §5](contractor-billing.md): did government works contract rates move from 12% to 18% on 22 Sep 2025, and what happened to the other entries?

**Primary evidence.**
- The gazette text of Notification 15/2025-CT(Rate), 17 Sep 2025, was opened (BCAS-hosted copy of the Gazette, https://bcasonline.org/wp-content/uploads/2025/09/No.15-2025-Central-Tax-Rate.pdf) and its streams were decoded locally.
- It amends entry "serial number 3" of 11/2017 (heading 9954, construction). Its operative text is: "against serial number 3, in column (3): (A) against item (vii), for the entry in column (4) ... (B) against item (viii) ... (C) against item (x) ..." with the CGST column rate substituted by 9.
- The font in the PDF mangles digits, so the substituted figure shows as ":" which is "9" in the same encoding (the same glyph replaces "6" elsewhere in this notification, i.e. 6% CGST becomes 9%).
- So: only items (vii), (viii) and (x) of Sl. No. 3 changed, each from 6% CGST (12% IGST) to 9% CGST (18% IGST). Items (i) to (vi) and (ix) of Sl. No. 3 were not touched. That covers the 1% and 5% housing entries.

**Which items are (vii), (viii), (x).**
- Item descriptions were not legible in the decoded text.
- [Construction Placements' table](https://www.constructionplacements.com/gst-rates-on-construction-services-materials-india-sept-2025-update) lists the moved rows as: works contract for the Government that is predominantly earthwork (over 75%); sub-contractors to that contract; and offshore oil and gas exploration and production. All moved 12% to 18% with ITC.
- That list is consistent with three changed items, but the mapping of item letters to descriptions is **UNVERIFIED**. It also does not mention local authorities.

**Resolution for Progen.**
- General works contract (SAC 9954, default entry): 18%, unchanged.
- The three formerly 12% concessional entries above: 18% for supplies (time of supply) on or after 22 Sep 2025. Supplies before that date at 12% stay at 12%, including credit notes.
- Affordable housing 1% (no ITC) and other residential 5% (no ITC): unchanged. Commercial apartments in a non-RREP project at 12%: no change found in 15/2025; **UNVERIFIED** against the full Sl. No. 3 text.
- Local authority and "pure services" entries under other serial numbers were not in the decoded amendments, so any 12% concessional rate not in Sl. No. 3 is **UNVERIFIED**.
- Keep rate on the WO line and let accounts override (as contractor-billing.md says). Updating the README open-question line: **resolved for Sl. No. 3**, with the item-letter mapping to confirm against the consolidated 11/2017.

### 1.5 What the tax-rate master must hold

An effective-dated table, never a single "current rate" field.

| Field | Notes |
| --- | --- |
| `tax_code` | e.g. `GST18`, `GST5`, `GST40`, `GST3_GOLD`, `GST025_ROUGH_DIAMOND`, `GST0_NIL`, `GST0_EXEMPT`, `GST0_NONGST` |
| `cgst_bp`, `sgst_bp`, `igst_bp`, `cess_bp`, `cess_fixed_paise_per_unit` | Basis points (900 = 9%) so 0.25% = 25 and 1.5% = 150. Integers only. |
| `effective_from`, `effective_to` | Inclusive dates. Legacy rows keep `effective_to = 2025-09-21`. |
| `legacy_flag` | True for 12% and 28% rows (and 14%). Hidden from new-document pickers, still resolvable. |
| `hsn_sac` link | Rate resolved by HSN/SAC plus date, with item-level override. |
| `itc_eligible_default`, `rcm_default`, `exempt_type` | Exempt vs nil-rated vs non-GST matter for Rule 42 and GSTR-1 tables. |

Rules:
- Rate resolves on the **time of supply** (s.12 goods, s.13 services), not on document entry date. An invoice dated after 22 Sep 2025 for an advance received before that date is a mixed case. Flag it for review. **UNVERIFIED** on the transition circular text.
- A credit note or debit note uses the rate on the **original invoice** (stored on the original line), never today's rate. Hence the legacy 12% and 28% rows stay live for notes issued up to the s.34 deadline (see 5.4), and for 40% vs 28% on old cars and the like.
- Cess: rows are retained for old periods and tobacco; zero for new documents.
- Rounding: tax per line in paise, `round_half_up(taxable_paise * bp / 10000)`. Invoice total is the sum of line taxes unless the GST rules say otherwise. Confirm the rounding rule with a CA; the GSTN e-invoice schema takes 2-decimal values.
- Guardrail: refuse to post a document whose rate is not in the table for its supply date. Show "rate changed on 22 Sep 2025" notice when a user picks a pre-cutover date.

---

## 2. GST returns

### 2.1 GSTR-1, GSTR-1A, IFF

- **GSTR-1.** Monthly (or quarterly under QRMP). Due on the 11th of the following month (monthly); quarterly filers by the 13th after the quarter. Source: CGST Rule 59 and standard CBIC due dates, **UNVERIFIED** here (rule text not opened).
- **IFF** (Invoice Furnishing Facility). QRMP filers may report B2B invoices and credit notes in months 1 and 2, up to ₹50 lakh per month, by the 13th. **UNVERIFIED** (not re-checked in 2026).
- **GSTR-1A.** Amendment/addition of GSTR-1 details for the same period, before filing GSTR-3B. Used to correct auto-populated Table 3.1 and 3.2 once those are locked. Source: [Taxscan on the 5 Dec 2025 advisory](https://www.taxscan.in/top-stories/gstn-issues-advisory-on-reporting-values-in-system-locked-table-32-of-gstr-3b-1439411) via the search result below.
- **Table 12 (HSN summary)** is mandatory in GSTR-1 (see 2.6).

### 2.2 GSTR-3B and hard-locking

- GSTR-3B Tables 3.1 and 3.2 (outward supplies) are auto-populated from GSTR-1, IFF and GSTR-1A and are **not editable** from the July 2025 tax period (filed Aug 2025). Corrections go through GSTR-1A for the same period. Sources: [EY alert on the Oct 2024 advisory](https://ey.com/en_in/technical/alerts-hub/2024/10/gstn-issues-advisory-on-hard-locking-of-auto-populated-values-in-form-gstr-3b), [Munim explainer](https://themunim.com/blog/gstr-3b-autofill-facility/), [Taxscan on locked Table 3.2](https://www.taxscan.in/top-stories/gstn-issues-advisory-on-reporting-values-in-system-locked-table-32-of-gstr-3b-1439411). The effective period is from secondary sources, **UNVERIFIED** against the advisory text.
- **Table 4 (ITC) hard-lock:** reported as proposed or expected from about July 2026. No GSTN advisory could be found. Treat as **UNVERIFIED** and not in force. Source: [TAXAJ, 20 Aug 2026](https://www.taxaj.com/learn/gstr-3b-table-4-itc-hard-locking-from-july-2026-no-manual-editing-surv/) (explicitly says unconfirmed). A Beancount blog (7 Oct 2026) claims it is already locked; unreliable.
- Design consequence: Progen's own GSTR-3B workings must (a) tie to GSTR-1 data it exports, so no manual override is needed, and (b) keep ITC reversals (4B) and reclaims as separately evidenced entries, because they are the lines that will still need manual input.

### 2.3 IMS and its effect on GSTR-2B

The Invoice Management System (live from Oct 2024) lets a recipient act on supplier-reported documents.
- Covered: invoices, debit notes and credit notes saved or filed by suppliers in GSTR-1, GSTR-1A or IFF.
- Actions: Accept, Reject, Pending.
  - **Accept:** goes into the ITC Available part of GSTR-2B and auto-populates GSTR-3B.
  - **Reject:** shown under ITC Rejected in GSTR-2B and not in GSTR-3B. The supplier must amend.
  - **Pending:** excluded from GSTR-2B and from GSTR-3B for that month, and carried forward until acted upon.
  - **No action:** per a GSTN FAQ summary, treated as accepted when 2B is generated. A secondary FAQ says the opposite, so this default is **UNVERIFIED**; design so Progen never assumes it.
- Timing: the recipient can act until filing GSTR-3B. Actions after the 14th mean GSTR-2B must be recomputed.
- Credit notes: a "pending" option was added around Oct 2025 along with a declaration for ITC reversal. **UNVERIFIED** as to details; see [Taxscan](https://www.taxscan.in/top-stories/gstn-introduces-pending-option-for-credit-notes-and-itc-reversal-declaration-in-invoice-management-system-ims-1435215).
- Sources: [GSTZen overview](https://gstzen.in/a/comprehensive-overview-of-invoice-management-system-ims.html), [Zoho Books explainer](https://www.zoho.com/in/books/academy/taxes-and-compliance/invoice-management-system-gst.html), [BDO alert](https://bdo.in/en-gb/insights/alerts-updates/gstn-to-introduce-invoice-management-system-functionality). None is a GSTN primary source. The GSTN IMS FAQ on gst.gov.in should be read before building (**UNVERIFIED**).

### 2.4 GSTR-9, GSTR-9C, QRMP, due dates

| Return | Rule | Source |
| --- | --- | --- |
| GSTR-9 (annual) | Mandatory above ₹2 crore aggregate turnover; optional below | [Studycafe on FY 2025-26](https://studycafe.in/gst-portal-opens-gstr-9-and-gstr-9c-filing-for-fy-2025-26-check-due-date-and-key-points-427389.html), [Taxscan](https://www.taxscan.in/gst/gst-portal-enables-gstr-99c-annual-returns-for-fy-2025-26); sources split on "mandatory" vs "optional" below ₹2 crore: **UNVERIFIED** |
| GSTR-9C | Reconciliation statement above ₹5 crore, self-certified since FY 2020-21 | same; one secondary source still says CA-certified: **UNVERIFIED** |
| Due date FY 2025-26 | 31 Dec 2026, no extension announced as of Oct 2026 | same |
| GSTN advisory 13 Oct 2026 | File all pending GSTR-1 and GSTR-3B first; FY 2025-26 facility enabled | Taxscan above |
| GSTR-3B monthly | 20th of next month (turnover over ₹5 crore); QRMP state-wise 22nd or 24th | Standard CBIC due dates, **UNVERIFIED** here |
| QRMP | Up to ₹5 crore aggregate turnover; quarterly GSTR-1 and 3B, monthly tax payment by PMT-06 (35% or self-assessed method) | CBIC scheme; thresholds **UNVERIFIED** here |
| Late fee on annual return | ₹200 per day (₹100 CGST + ₹100 SGST), capped at 0.5% of turnover per head | Secondary sources conflicted (one said 0.25%, one a flat ₹25,000), so **UNVERIFIED** |

- **3-year bar.** Returns cannot be filed after three years from the original due date (s.37(3), s.39(11), s.44 as amended by the Finance Act 2023, from 1 Oct 2023 for GSTR-1, 3B and 9). One secondary source applies it to FY 2025-26 GSTR-9 as 31 Dec 2029. Statutory text not opened, **UNVERIFIED**.
- Interest on late tax: 18% p.a. under s.50(1) (24% for wrongly availed ITC under s.50(3)). Rate figures **UNVERIFIED** here. Rule 88B calculates interest on net cash liability.

### 2.5 JSON and offline-tool formats an ERP should export

All data to GST tools is JSON, not CSV. GSTN publishes schemas on the portal's "Offline Tools" page (not opened; table codes below are the standard ones, **UNVERIFIED**).

**GSTR-1 JSON (`gstin`, `fp` as `MMYYYY`, `gt`, `cur_gt`):**

| Key | Table | Content |
| --- | --- | --- |
| `b2b` | 4A/4B/4C/6B/6C | Invoices to registered persons, by recipient GSTIN, with `inum`, `idt`, `val`, `pos`, `rchrg`, `inv_typ`, items with `rt`, `txval`, `iamt`/`camt`/`samt`/`csamt` |
| `b2cl` | 5 | Inter-state B2C invoices above ₹1 lakh (threshold **UNVERIFIED**) |
| `b2cs` | 7 | B2C small, aggregated by state, rate, type |
| `exp` | 6A | Exports (WPAY/WOPAY) |
| `cdnr` | 9B | Credit/debit notes to registered persons |
| `cdnur` | 9B | Credit/debit notes to unregistered persons |
| `nil` | 8 | Nil-rated, exempt, non-GST |
| `at`, `txpd` | 11A/11B | Advances received and adjusted |
| `hsn` | 12 | HSN summary (see 2.6) |
| `doc_issue` | 13 | Documents issued, serial from-to, cancelled count |
| `ecom`/`eco` | 14/15 | E-commerce supplies |

**GSTR-3B JSON:** `ret_period`, `sup_details` (3.1 a-e), `inter_sup` (3.2), `itc_elg` (4A: `itc_avl` types IMPG, IMPS, ISRC, ISD, OTH; `itc_rev` 4B1/4B2; `itc_net`; `itc_inelg`), `inward_sup` (5), `intr_ltfee` (5.1), `tx_pmt` (6.1).
**GSTR-2B (download):** supplier-wise `b2b`, `cdnr`, `isd`, `impg` sections with ITC-available flags, used for reconciliation.
**GSTR-9/9C:** table-wise JSON (Tables 4 to 19 for GSTR-9; the 9C reconciliation). Offline utility is released per year.
**ERP exports:** one `gstr1_YYYYMM.json`, one `gstr3b_YYYYMM.json` workings sheet, and a human-readable reconciliation XLSX. Keep a hash of every file exported.

### 2.6 HSN reporting in returns

Table 12 HSN summary has been mandatory with a required number of digits since 1 Apr 2025 (4 digits up to ₹5 crore turnover, 6 above, per Notification 78/2020-CT as amended by 12/2025-CT, **UNVERIFIED**; see 5.2). Table-wise `hsn` data must carry HSN, UQC, quantity, taxable value, tax, and rate.

---

## 3. Input tax credit

Sources for the whole section: CGST Act 2017 as on the CBIC repository https://taxinformation.cbic.gov.in/ (s.34 page opened; others not), Taxmann and TaxGuru commentary. Section text below is the standard text; each row not opened on the CBIC site is **UNVERIFIED** at statute level.

### 3.1 s.16(2) conditions

ITC is available only if all hold:
1. (a) Holds a tax invoice or debit note (or other prescribed document).
2. (aa) The supplier's details appear in the recipient's GSTR-2B. This is the s.38 matching condition; it is why IMS "reject" and "pending" block ITC.
3. (b) The goods or services have been received (deemed received if delivered to a person on the recipient's direction).
4. (c) The tax charged has actually been paid to the government by the supplier (cash or ITC).
5. (d) The recipient has filed GSTR-3B (s.39).
- Rule 36(4): 2B-matching limit. Since 1 Jan 2022 the rule is that ITC is available only if it appears in GSTR-2B (s.16(2)(aa)). **UNVERIFIED**.
- Rule 37 sits behind 16(2) second proviso: pay the supplier within 180 days (3.3).

### 3.2 s.16(4) time limit and the Finance Act 2024 relief

- Invoice and debit note ITC must be claimed by the **30 November following the end of the financial year** of the invoice, or the date of filing the annual return, whichever is earlier. Example: a Jan 2026 invoice (FY 2025-26) must be claimed by 30 Nov 2026 (the GSTR-3B for October 2026, filed in November 2026).
- Finance Act 2024 inserted s.16(5) and 16(6): for FY 2017-18 to 2020-21, the 16(4) period was extended to 30 Nov 2021 or the return date for specified cases; for notices and orders under s.73, a one-time relief on invoices and debit notes, effective retrospectively from 1 Jul 2017. **UNVERIFIED** against the Act text. The searches did not retrieve s.16(5)/(6) text.
- ERP rule: store `itc_claim_deadline = 30 Nov following FY end` on every purchase. Alert at 60, 30 and 7 days. For credit-note-adjusted ITC, check 16(4) against the original invoice.

### 3.3 Rule 37: pay within 180 days or reverse

- If the recipient has not paid the supplier (value plus tax) within **180 days from the invoice date**, ITC claimed must be reversed with interest under s.50 (18% p.a. from the date ITC was availed until reversal). The reversed credit can be re-availed on payment. Sources: [ClearTax on Rule 37](https://cleartax.in/s/rule-37-of-cgst-sgst-rules-itc-reversal-180-days).
- Report in GSTR-3B Table 4B(2) and interest in Table 5.1. Source: same.
- Does not apply where supply is on RCM, or where the value is part-paid (reversal is proportionate to the unpaid amount). Part-payment proportion is **UNVERIFIED**.
- Relevant to Progen: set-off through credit notes, advances, or contra counts as payment (the Rule text covers "payment" including book adjustments, **UNVERIFIED**).

### 3.4 Rule 37A

- If a supplier has not filed GSTR-3B for the tax period by **30 September of the next FY** (or the annual return date), and the recipient availed ITC on the invoice, the recipient reverses ITC in the return for the period ending **30 November** (September-end deadline plus one return cycle). Re-availment when the supplier later files. Reported in Table 4B(2). Interest under s.50 if reversal is late. Sources: [Taxmann analysis](https://www.taxmann.com/post/blog/analysis-understanding-rule-37a-and-gstn-advisory/), [TaxGuru on Rule 37A](https://taxguru.in/goods-and-service-tax/rule-37a-cgst-rules-reversal-re-availment-input-tax-credit-itc.html). The exact date wording in the sources differs, so the 30 Nov date is **UNVERIFIED**.
- Litigation: Taxmann argues the rule exceeds s.16(2)(c); Tripura HC limited it for bona fide recipients ([TaxGuru](https://taxguru.in/goods-and-service-tax/section-16-2-c-rule-37a-tripura-high-courts-protection-bona-fide-recipients-gst.html)). Not settled; Progen should flag, not decide.

### 3.5 Rules 42 and 43, s.17(5), Rule 86B

- **Rule 42** (inputs and input services used for both taxable and exempt supplies): ITC attributable to exempt supply is reversed using the formula `D1 + D2` where `D1 = C2 × T1/T`, the exempt turnover to total turnover. Provisional monthly calculation, annual true-up by 30 Sep after the year-end, with interest. **UNVERIFIED** formula wording.
- **Rule 43** (capital goods used for both): the capital-goods credit is spread over 5 years (60 months), with the exempt share reversed each month. Same status.
- Reported in GSTR-3B Table 4B(1) (rules 38, 42, 43 and s.17(5)).
- **Rule 38:** banks and financial companies option, skip for general ERP.
- **s.17(5) blocked credits** (headline, **UNVERIFIED** at text level): motor vehicles (with exceptions, e.g. goods transport, dealers, driving schools); food, beverages, outdoor catering, beauty treatment, health services, cosmetic surgery, club membership, rent-a-cab, life and health insurance (with exceptions); travel benefits to employees; works contract and construction of immovable property (other than plant and machinery) for own account (see [contractor-billing.md §5](contractor-billing.md)); goods lost, stolen, destroyed, written off or gifted; goods or services for personal consumption; free samples. Also tax paid under composition and demand cases (s.74).
- **Rule 86B:** electronic credit ledger cannot pay more than 99% of output tax liability if taxable value of supplies (excluding exempt and zero-rated) exceeds ₹50 lakh in the month. Exceptions for income tax payers over ₹1 lakh, refunds over ₹1 lakh in the prior two years, etc. **UNVERIFIED** (text not opened).

---

## 4. Reverse charge

### 4.1 Where the lists live

- s.9(3): notified categories of goods or services where the **recipient** pays tax. Services: Notification 13/2017-CT(Rate) (as amended); goods: 4/2017-CT(Rate). Source: a notification index ([mantra.tips](https://mantra.tips/hi/gst/notifications)), **UNVERIFIED** and unofficial. IGST twins: 10/2017 and 4/2017-IT(Rate).
- s.9(4): supplies by unregistered persons to registered persons. Now limited to notified goods and services (promoters in real estate for land and construction, etc.). Source: CBIC notifications 7 and 8 of 2017 (not opened), **UNVERIFIED**.
- The 2026 RCM list was not retrieved. The GSTN RCM advisory of 16 Oct 2026 is about RCM e-invoicing, see [gst-einvoice-ewaybill.md](gst-einvoice-ewaybill.md).

### 4.2 Commonly notified services under s.9(3) (13/2017, **UNVERIFIED**, check the current consolidated notification)

| Service | Payer on RCM | Notes |
| --- | --- | --- |
| Goods transport agency (GTA) | Registered recipient (factory, company, firm, society, etc.) | GTA may opt for forward charge at 5% (no ITC) or 18% (with ITC). Rate 5% under 11/2017 as amended. |
| Legal services by an advocate or firm of advocates to a business entity | Business entity | Services of senior advocates are covered; individual advocate pays no tax to an unregistered person |
| Arbitral tribunal services | Business entity | |
| Services by a director to the company (non-employee) | Company | Salary under contract of service excluded. Directors' fees: RCM. |
| Sponsorship services (other than to body corporate or partnership firm) | Body corporate or partnership firm | |
| Renting of immovable property by an **unregistered** person to a registered person | Recipient | See 4.3 on residential/commercial |
| Services by the Government or local authority to a business entity | Business entity | Exceptions: renting for residential use, etc. |
| Insurance agent services | Insurance company | |
| Recovery agent services to banks and financial institutions | Recipient | |
| Security services (other than to a body corporate registered person) | Registered person | Changed from 2019 and 2024: **UNVERIFIED** current status |
| Import of services from outside India | Recipient (IGST) | s.5(3) IGST Act |
| Supply by a GTA, goods transport by water, rail excluded | See notification | |

### 4.3 Renting of immovable property
- Renting of commercial property by an unregistered person to a registered person: RCM from 10 Jul 2022 ([notification 5/2022-CT(Rate)](https://taxguru.in/?p=852053), **UNVERIFIED** link). Residential rent to a registered person for use as residence: RCM-exempt on residential dwelling used for residence (partial; Notification 05/2022 as amended 2022 and 2025 changed this). Currently the safe default for the master: commercial rent from an unregistered lessor: RCM at 18%; flag residential cases.
- Residential dwelling rented to a registered person (e.g. employer-hired accommodation): the rule was narrowed in 2022 and amended again from 10 Jul 2022; Progen should store `rent_type` as an input and let accounts choose, because the legal text could not be confirmed.

### 4.4 Goods under s.9(3)
Cashew nuts (not shelled), bidi wrapper leaves (tendu), tobacco leaves, silk yarn, raw cotton from agriculturists, supply of lottery by state governments, used vehicles and old vehicles by registered persons, scrap by government, renewable energy devices by government, among others. Rates are from the goods RCM notification. **UNVERIFIED**.

### 4.5 Self-invoice, payment voucher, timing
- Registered recipient issues a **self-invoice** (s.31(3)(f)) for supplies received from an unregistered supplier. As amended in 2024 (Rule 46(a) and Circular 211/05/2024-GST, **UNVERIFIED**), a single invoice for the month is allowed for a supplier if consolidation is required, but the more usual practice is a per-supply document.
- A **payment voucher** (s.31(3)(g), Rule 52) is issued at the time of payment to the supplier for the same supply.
- **Time of supply under RCM:**
  - Goods (s.12(3)): earliest of date of receipt of goods, date of payment, 30 days from invoice date, or (if later) date recipient books it.
  - Services (s.13(3)): earliest of date of payment or **60 days from the invoice date**; if no invoice, 60 days from the supply date. Where the supplier is an associated enterprise outside India, date of entry in books or payment, whichever earlier.
  - Exact windows are standard, from statute memory, **UNVERIFIED** here.
- **Payment of RCM:** only in **cash** (the electronic cash ledger). ITC cannot pay RCM. ITC on the RCM tax is available in the same or a later month if used for business (s.16, not blocked by s.17(5)). Reported in GSTR-3B 3.1(d) (liability) and 4A(3) (ITC). Source: general GSTR-3B structure (EY and ClearTax pages above).
- **E-invoice for RCM self-invoices:** the 2026 NIC sandbox supports `RCMDOM` and `RCMIMP`. Production date not set. See [gst-einvoice-ewaybill.md §1](gst-einvoice-ewaybill.md).

---

## 5. Invoices, notes, composition

### 5.1 Rule 46 mandatory fields
(Tax invoice. Source: CGST Rules 2017 rule 46, text not opened, **UNVERIFIED**; standard list.)
- Name, address and GSTIN of supplier.
- **Serial number**: consecutive, unique for the FY, up to **16 characters**, letters, numerals, "/" and "-" only.
- Date of issue.
- Name, address and GSTIN of recipient if registered. For unregistered, name, address and state code where value is ₹50,000 or more; B2C below that needs no recipient details.
- HSN (goods) or SAC (services), description, quantity and unit, total value, taxable value after discount, rate, tax amount by head (CGST, SGST/UTGST, IGST, cess).
- Place of supply with state name and code where it differs from the delivery state.
- Address of delivery where it differs from the place of supply.
- Whether tax is payable under reverse charge.
- Signature or digital signature of the supplier. Not required on e-invoices or dynamic QR cases.
- QR code and IRN for e-invoice taxpayers (see [gst-einvoice-ewaybill.md](gst-einvoice-ewaybill.md)).
- Time limit to issue: goods, at or before removal/delivery; services, within **30 days** of supply (45 days for banks and financial institutions and insurers; ≤ ₹5 crore taxpayers). Actual statutory text is rule 47. **UNVERIFIED**.

### 5.2 HSN digits (Rule 46 and Notification 78/2020-CT)
| Annual turnover (previous FY) | B2B | B2C |
| --- | --- | --- |
| Up to ₹5 crore | 4 digits | 4 digits |
| Over ₹5 crore | 6 digits | 6 digits |
Exports and imports use 8 digits. The B2C-for-small-taxpayers exception (no HSN up to ₹5 crore B2C) was removed from 1 Apr 2025. **UNVERIFIED** here: the notification 12/2025-CT amendment was recalled from memory and not opened. Treat the digit counts as a configurable setting per tenant, validated against the HSN master.

### 5.3 Bill of supply, receipt voucher, refund voucher
- **Bill of supply** (s.31(3)(c), rule 49): for exempt supplies, composition dealers and nil-rated goods. No tax shown; must not claim ITC. A mix of taxable and exempt goods can use one "invoice-cum-bill of supply" with a clear column. Standard rule, **UNVERIFIED**.
- **Receipt voucher** (s.31(3)(d), rule 50): on receiving an advance for goods or services. Since the 2017 notifications, advance tax on goods is no longer payable for registered suppliers' goods (Notification 66/2017-CT), but still payable on services. Services advance: pay GST at advance receipt.
- **Refund voucher** (rule 51): when the advance is returned and no supply is made.
- Time of supply (s.12/13/14) uses the earlier of invoice and payment, as in 4.5; for goods, removal or delivery; for services, invoice (if issued within 30 days) or payment.

### 5.4 Credit and debit notes (s.34)
- **Credit note:** issued by the supplier for reduced value, returns, or discounts. **Time limit:** by **30 November following the end of the FY** of the original supply, or the date of filing the annual return, whichever is earlier. Source: CBIC s.34 text https://taxinformation.cbic.gov.in/content/html/tax_repository/gst/acts/2017_CGST_act/active/chapter7/section34_v1.00.html (opened via the search listing, not read in full).
- **Finance Act 2026 change:** s.15(3)(b) no longer needs a pre-supply agreement for post-supply discounts, and s.34(1) is amended so credit notes cover such discounts, with the recipient reversing ITC. The CBIC appointed **1 Nov 2026** for sections 153 to 155 on 26 Oct 2026, as reported by [SCC Online](https://www.scconline.com/blog/?p=399871) and [Taxscan](https://www.taxscan.in/top-stories/budget-2026-27-amendment-to-s-34-of-cgst-act-clarifies-validity-of-credit-notes-for-post-sale-discounts-1442606). The CBIC notification itself was not opened: **UNVERIFIED**. From 1 Nov 2026 a post-sale discount document is a credit note with a mandatory recipient ITC-reversal flag.
- **Debit note:** no tax time limit for the supplier to issue (tax on it follows the original supply date). Rate: the debit note is taxed in the period of issue, at the rate of the original supply. **UNVERIFIED** the exact rate treatment.
- The credit note must show the original invoice number and date, and a reason code (return, rate difference, discount, correction).

### 5.5 Composition scheme (s.10)
| Class | Rate (of turnover) | Source |
| --- | --- | --- |
| Manufacturers and traders (goods) | 1% (0.5% CGST + 0.5% SGST) | Rule 7 CGST Rules; standard, **UNVERIFIED** |
| Restaurants (not serving alcohol) | 5% | same |
| Other service providers (s.10(2A)) | 6% | same |
Turnover limit ₹1.5 crore (₹75 lakh in special-category states). Services-only limit ₹50 lakh. **UNVERIFIED**.
Restrictions: no inter-state outward supply (except s.10(2A) services in some cases), no e-commerce supply (except restaurants), no ITC, no tax collected from customers (issue **bill of supply**, with "composition taxable person, not eligible to collect tax" written at the top), no supply of non-taxable goods like alcohol, and quarterly CMP-08 payment with annual GSTR-4. Works contract suppliers cannot be composition dealers unless in limited classes. Progen guardrail: the registration type of the supplier decides tax and ITC eligibility (see [contractor-billing.md §5](contractor-billing.md)).

---

## 6. TDS and TCS master under the Income-tax Act 2025

Sources:
- Section mapping: [Studycafe TDS rate chart FY 2026-27](https://studycafe.in/tds-rate-chart-for-fy-2026-2027-under-income-tax-act-2025-420727.html) and [CA Cult 1961 vs 2025 guide](https://cacult.com/tds-tcs-guide-under-income-tax-act-1961-vs-2025/).
- Statement forms and dates: [Income Tax Dept FAQ on Form 138](https://www.incometaxindia.gov.in/documents/d/guest/form-138-faqs), [Form 140 FAQs](https://www.incometaxindia.gov.in/documents/d/guest/form-140-faqs) (opened only via the search listing; not read), [TaxHeal Form guide](https://www.taxheal.com/tds-compliance-2-0-new-dates-new-forms-and-the-mega-form-141.html).
- The contractor rows are **verified** in [contractor-billing.md](contractor-billing.md). The rest are from the two secondary pages above and are **UNVERIFIED** until read against the Act. The two pages disagree on the rent mapping, see below.

### 6.1 Section table (old to new)

Columns: threshold is per-FY unless stated; "S" is single payment; "A" aggregate for the payee in the FY from the same deductor. No-PAN rate is the higher of the rate in the Act, the rate in force, and 20% (new s.397(2)(b)(i) from contractor-billing.md; old s.206AA). Lower deduction certificate: new s.395 (old s.197), UNVERIFIED section number.

| Old | New (Table Sl. No.) | Payment | Threshold | Rate | No-PAN |
| --- | --- | --- | --- | --- | --- |
| 194C | 393(1) 6(i) | Contractors (see contractor-billing) | ₹30,000 S or ₹1,00,000 A | 1% ind/HUF, 2% others | 20% |
| 194J(b) | 393(1) 6(iii) | Fees for technical services (and call-centre) | ₹50,000 A | 2% | 20% |
| 194J(a) | 393(1) 6(iii) | Professional fees (and director fees) | ₹50,000 A | 10% | 20% |
| 194I(a) | 393(1) 2(ii)? | Rent of plant, machinery, equipment | ₹50,000 per month (per FY ₹6,00,000 test is the 2025 Act wording: **UNVERIFIED**) | 2% | 20% |
| 194I(b) | 393(1) 2(ii)? | Rent of land, building, furniture, fittings | same | 10% | 20% |
| 194-IB | 393(1) 2(i)? | Rent by individual/HUF not otherwise liable | Over ₹50,000 per month | 2% (from 1 Oct 2024; was 5%) | 20% |
| 194H | 393(1) 1(ii) | Commission or brokerage | ₹20,000 A | 2% | 20% |
| 194Q | 393(1) 8(ii) | Purchase of goods from a resident | Over ₹50 lakh in the FY from one seller (tax on excess) | 0.1% | 5% |
| 194A | 393(1) 5(ii) | Interest other than on securities | ₹50,000 (₹1,00,000 for senior citizens, banks and co-ops: ₹40,000/₹50,000 older) | 10% | 20% |
| 193 | 393(1) 5(i) | Interest on securities | Various | 10% | 20% |
| 194 | 393(1) 7 | Dividends | ₹10,000 | 10% | 20% |
| 194R | 393(1) 8(iv) | Business perquisites/benefits | ₹20,000 A | 10% | 20% |
| 194O | 393(1) 8(v) | E-commerce operator on sales | ₹5 lakh ind/HUF; nil others | 0.1% | 5% |
| 194T | 393(3) 7 | Payments to partners (salary, bonus, interest, remuneration) | ₹20,000 A | 10% | 20% |
| 194M | 393(1) 6(i)/(ii) | Individual/HUF paying contractors, professionals, commission | ₹50 lakh | 2% | 20% |
| 194-IA | 393(1) 3(i) | Immovable property (other than agricultural land) | ₹50 lakh | 1% | 20% |
| 192 | 392 | Salary | Slab-based | Slab | Link only: salary payroll is out of scope here; see [labour-wages.md](labour-wages.md) |
| 195 | 393(2) Table | Payments to non-residents (and foreign companies) | None | Rates in force; the DTAA rate can apply | Headline only; Form 144 |

Notes:
- **Rent mapping conflict.** Studycafe puts 194I at 393(1) 2(ii) and 194-IB at 2(i); CA Cult says 194I at 2(i) and 194-IB at 2(ii). Store the section as a free-text `section_ref_2025` and verify against the Act before printing on certificates.
- **Rent threshold.** Old 194-I: ₹6,00,000 per FY from 1 Apr 2025 (Finance Act 2025); Studycafe shows ₹50,000 per month. The two are different tests. Both **UNVERIFIED**; keep the threshold type (`per_month` or `per_fy`) configurable per row.
- **194I(a) vs (b).** 2% for plant, machinery and equipment; 10% for land, building, furniture, fittings. Source: [TDSMan](https://blog.tdsman.com/2026/06/tds-on-rent-section-3931-section-194i-a-b/) and Studycafe.
- **Threshold aggregation** is per **deductor, per payee PAN, per FY, per section** (each section aggregates separately). Once crossed, deduct on the whole amount including earlier payments, except 194Q where tax applies on the excess over ₹50 lakh.
- **GST component.** Where GST is shown separately, TDS is on the amount excluding GST (CBDT Circular 23/2017, per contractor-billing.md). For rent, 194-I follows the same circular. Status under the 2025 Act is **UNVERIFIED**.
- **Lower or nil deduction certificate:** old s.197, now new s.395 (Form 128?). **UNVERIFIED** both the section and form. Store certificate number, validity dates, rate, and the maximum amount, and apply only within them.
- **Form 121** replaces 15G and 15H (declaration of no deduction). Source: Studycafe. **UNVERIFIED**.

### 6.2 TCS under s.394 (old s.206C)

| Old | New (s.394 Item) | Goods or payment | Rate |
| --- | --- | --- | --- |
| 206C(1) | Item 1 | Alcoholic liquor for human consumption | 2% |
| 206C(1) | Item 2 | Tendu leaves | 2% |
| 206C(1) | Item 4 | Scrap | 2% |
| 206C(1) | Item 5 | Minerals (coal, lignite, iron ore) | 2% |
| 206C(1F) | Item 6 | Motor vehicle above ₹10 lakh | 1% |
| 206C(1G) | Item 7 | LRS remittances above ₹10 lakh (education/medical 2% over ₹10 lakh, others 20%) | 2% / 20% |
| 206C(1G) | Item 8 | Overseas tour package | 2% |
Source: CA Cult guide above. **UNVERIFIED**. Item 3 not listed in that page. Note: the 2025 Act tables may have changed the LRS rates in Finance Act 2026; confirm. TCS on sale of goods above ₹50 lakh (206C(1H)) was withdrawn from 1 Oct 2024. Not covered.

### 6.3 Deposit, statements, certificates

Source: [TaxHeal TDS Compliance 2.0](https://www.taxheal.com/tds-compliance-2-0-new-dates-new-forms-and-the-mega-form-141.html) (secondary; the Income Tax Dept form FAQs for Forms 138 and 140 exist but were not read).

- **Deposit (Rule 218):** amounts deducted in April to February by the **7th of the next month**; March deductions by **30 April** (the page says "within 7 days from the end of the month", read as the 7th). Government offices, same day when paid without a challan. Form 141 transactions (below) within 30 days from the end of the month of deduction.
- **Statements (Rule 219):**

| Old | New | Covers |
| --- | --- | --- |
| 24Q | Form 138 | Salary TDS |
| 26Q | Form 140 | Non-salary TDS, residents |
| 27Q | Form 144 | Non-residents |
| 27EQ | Form 143 | TCS |

- **Due dates:** Q1 31 Jul, Q2 31 Oct, Q3 31 Jan, Q4 **31 May**. Q4 Form 143 (TCS) was listed once as 15 May; verify. Source as above.
- **Form 141:** one challan-cum-statement replacing 26QB, 26QC, 26QD and 26QE (property, rent by individual/HUF, contractor payments by individuals, VDA payments). Filed per transaction.
- **Certificates:** Form 130 (replaces Form 16, due 15 Jun); Form 131 (replaces 16A, quarterly; the Form 131 deadline was reported as 15 days after the statement due date); Form 132 (replaces 16B, C, D, E; within 15 days of Form 141); Form 133 (replaces 27D for TCS). The TaxHeal page and the Income Tax FAQs agree on the numbers, but the due days are **UNVERIFIED**.
- **Interest (old s.201(1A)):** 1% per month or part of a month from the date tax was deductible to the date it was deducted; 1.5% per month from deduction to deposit. **UNVERIFIED** under the 2025 Act (new section number unknown).
- **Late fee (old s.234E):** ₹200 per day until the statement is filed, capped at the TDS amount. **UNVERIFIED** under the 2025 Act.
- **Late filing penalty (old s.271H):** ₹10,000 to ₹1,00,000. **UNVERIFIED**.

### 6.4 Disallowance on non-deduction

- Old s.40(a)(ia): **30%** of the expense is disallowed if TDS was not deducted, or deducted and not deposited by the due date of the return (s.139(1)). The balance is allowed in the year of deposit. Payments to non-residents (old 40(a)(i)): 100% disallowed. Sources: [Disytax guide](https://disytax.com/?p=19737), [StudyCafe on 40(a)(ia)](https://studycafe.in/section-40aia-disallowance-for-non-deduction-short-deduction-of-tds-under-income-tax-107551.html). Delhi HC: no disallowance for short deduction ([LiveLaw](https://livelaw.in/news-updates/delhi-high-court-income-tax-act-tds-itat-tax-deduction-204536)).
- The 2025 Act's section number for this was not found. An article names "Clause 35 of the Income Tax Bill, 2025" as the s.40 counterpart (search listing only). **UNVERIFIED**.

---

## 7. MSME payments

### 7.1 MSMED Act 2006 s.15 and s.16

- **s.15:** the buyer pays within the agreed time, no more than **45 days** from the day of acceptance (or deemed acceptance, i.e., 15 days after the day of delivery or the day of objection). If there is **no written agreement**, within **15 days** of acceptance or deemed acceptance. Source: MSMED Act 2006 text (not opened this session; standard); **UNVERIFIED** here.
- **s.16:** compound interest **monthly** at **three times the RBI bank rate** on delay. Interest is payable on the principal and accrued interest each month, and cannot be waived by contract. The RBI bank rate on 29 Oct 2026 was not retrieved; the current figure needs checking (the RBI bank rate equals the MSF rate; **UNVERIFIED**).
- **Scope:** suppliers registered on Udyam as micro or small at the **time of supply**. Medium enterprises and traders (wholesale or retail only) are not covered (Udyam supply of goods or services). The Supreme Court in the Gujarat State Civil Supplies case (2023) held that registration after the supply is not retroactive. **UNVERIFIED**.
- **Delayed interest is not deductible** for tax, and the principal is deferred to the year of payment (Finance Ministry reply, below).

### 7.2 Income-tax disallowance (old s.43B(h))

- Amounts due to micro and small enterprises beyond the s.15 time limit are allowed as a deduction only on actual payment. Introduced by Finance Act 2023, effective from FY 2023-24.
- **2025 Act equivalent: s.37(2)(g).** Source: the Finance Ministry's Rajya Sabha reply of 21 Jul 2026 as reported in [TaxGuru on the Finance Ministry clarification](https://taxguru.in/income-tax/finance-ministry-clarifies-section-43bh-45-day-msme-payment-rule.html) and [Taxscan, Aug 2026](https://www.taxscan.in/top-stories/msme-payment-rule-us-43bh-of-income-tax-act-due-dates-tax-impact-and-form-3cd-reporting-1449695). Parliamentary answer text not opened; the mapping is repeated by two secondary sources, so mark **UNVERIFIED** in print.
- Payment made after the year-end but within the s.15 limit (15 or 45 days) is not disallowed. Tax audit Form 3CD reporting continues (new Form number **UNVERIFIED**).
- Practical test at year-end (31 Mar): list every unpaid bill to a micro or small supplier older than 45 days (15 days with no agreement) and add it back to taxable income for the year.

### 7.3 Udyam and MSME-1

- **Udyam registration number** format `UDYAM-XX-00-0000000` (state code, district, serial). Category (micro, small, medium) and the date of registration or validity belong on the supplier master. Investment and turnover limits: micro ₹2.5 crore invest and ₹10 crore turnover; small ₹25 crore and ₹100 crore; medium ₹125 crore and ₹500 crore (revised from 1 Apr 2025). **UNVERIFIED** here; the search did not check them.
- **MSME-1:** a half-yearly return by **companies** with outstanding dues to micro and small suppliers over 45 days. April to September due **31 Oct**; October to March due **30 Apr**. Sources: [Compliance Calendar](https://www.compliancecalendar.in/learn/form-msme-1), [CalcGuru](https://calcguru.in/?p=5764). A 25 Mar 2025 MSME ministry notification introduced an updated format (per one search summary, **UNVERIFIED**). It requires the supplier's name, PAN or Udyam number, amount, due date and reason.
- So, **today is 29 Oct 2026**: the MSME-1 for April to September 2026 is due **31 Oct 2026**.

---

## 8. Books, audit and depreciation

### 8.1 Audit trail (Companies (Accounts) Rules 2014, rule 3(1))
- Companies using accounting software for books must use software with a feature to record an **audit trail (edit log) of each and every transaction**, creating an edit log of each change made to the books, **with the date of the change**, and the audit trail **cannot be disabled**. Applicable from FY beginning 1 Apr 2023. The record must be retained as per Section 128 (**8 years**, per the 2022 amendment of the rule's retention). Source: the rule text (MCA notification G.S.R. 206(E), 24 Mar 2021, and the 2022 amendment). **UNVERIFIED** here: the search for the rule text returned nothing, so all of this paragraph is recalled from the rule and needs confirming against the MCA gazette.
- Auditors report on it under Rule 11(g) of the Companies (Audit and Auditors) Rules 2014 (ICAI Implementation Guide). Not opened.
- What the log must capture (ICAI guidance, **UNVERIFIED**): who, when, what changed (old and new value), and at the application level and the database level (changes made through the DBA). The log must not be editable by users, including admins.

### 8.2 Record retention
- CGST s.36 and Rule 56: records for **72 months from the due date of the annual return** for the year (longer where litigation is pending, until it is concluded). Companies Act s.128: 8 years. Income-tax Act: records for 8 years from the end of the tax year where an assessment is open (old s.44AA rule 6F; new equivalent **UNVERIFIED**). Take the longest as the default retention: **8 years**, with a legal-hold flag.

### 8.3 E-invoice numbers (confirm only)
- Threshold **₹5 crore** AATO, in force since 1 Aug 2023 (Notification 10/2023-CT). Reporting to the IRP within **30 days** of the invoice date for taxpayers with AATO ₹10 crore and above, from 1 Apr 2025 (Notification 10/2023-CT as amended; hard cap). Full detail: [gst-einvoice-ewaybill.md §§1-2](gst-einvoice-ewaybill.md). The 30-day figure and the ₹10 crore split are from that note; they were not rechecked here.

### 8.4 Financial-year lock and period close
- No statute requires an ERP lock, but the audit trail, GST (return filed, so later edits cause mismatch), and 16(4) and 34 time limits make it necessary. Expected design:
  - Month-level **soft close** after GSTR-3B is filed; **hard close** on the FY after the statutory audit sign-off (companies: AGM and AOC-4).
  - Back-dated entries into a locked period need a reason, an approver, and appear in the audit trail. They should create an adjustment entry in the open period for GST (credit note, GSTR-1A or Table 4B), not edit the old one.
  - Opening balances roll forward automatically; TDS and GST payable are not cleared by year-end.

### 8.5 Depreciation (headline)
| | Companies Act 2013 Schedule II (useful life, straight line or WDV, residual up to 5%) | Income-tax block rates (WDV; old Appendix I rule 5, new equivalent in the 2025 Rules) |
| --- | --- | --- |
| Buildings (other than factory) | 60 years (RCC) | 10% (residential 5%) |
| Factory buildings | 30 years | 10% |
| Plant and machinery (general) | 15 years | 15% |
| Furniture and fittings | 10 years | 10% |
| Office equipment | 5 years | 15% |
| Computers and servers | 3 and 6 years | 40% |
| Motor cars | 8 years | 15% |
| Intangibles (software, patents) | Per Ind AS 38 | 25% |
Sources: Companies Act 2013 Schedule II and Income-tax Rules (not opened this session). All values **UNVERIFIED** here; they are the widely published figures and need checking against Schedule II Part C and the 2026 Rules. Notes: income-tax depreciation is per **block of assets**, half-rate if used under 180 days in the year; the Companies Act is per asset. Keep two registers. Deferred tax is the difference.

---

## 9. What Progen needs to build

All money is **integer paise**. Tax per line: `round_half_up(taxable_paise * bp / 10000)`. Journals balance (Dr = Cr) in the same transaction as the document. Every compliance action writes to an append-only audit log. Posting into a locked period is rejected.

### 9.1 Tax-rate master (GST 2.0)
- Table per section 1.5. Seed: GST0, GST5, GST18, GST40, GST3 (gold, silver), GST025 (rough diamonds), plus legacy GST12, GST28, GST14, with `effective_to = 2025-09-21`. Seed cess rows for tobacco with `effective_to = 2026-01-31` (**UNVERIFIED**, see 1.3).
- Rate resolver: `resolve_rate(hsn, supply_date, supply_type)`. Credit and debit notes inherit the original line's rate.
- Works contract: rate selected on the WO line (see 1.4), default 18%.
- Guardrails: no document posts with a rate not valid on the supply date; a banner when a pre-22-Sep-2025 date is entered; changing the master requires an admin role and a new effective-dated row, never an edit.
- Journal (sale, intra-state, ₹1,00,000.00 at 18%): Dr Receivable 11,800,000; Cr Sales 10,000,000; Cr CGST payable 900,000; Cr SGST payable 900,000.

### 9.2 GSTR-1 and GSTR-3B data and export
- Data views: `gstr1_b2b`, `b2cl`, `b2cs`, `cdnr`, `cdnur`, `exp`, `nil`, `at`/`txpd`, `hsn`, `doc_issue` per section 2.5; and `gstr3b_workings` with 3.1, 3.2, 4A, 4B, 4D, 5, 5.1, 6.1.
- Export JSON per period (`fp = MMYYYY`) plus an XLSX tie-out. A period cannot be exported if documents in that period are in draft.
- Guardrails: HSN digits per tenant turnover (5.2); invoice number ≤ 16 characters and FY-unique; the GSTR-1 totals must equal the ledger tax balance for the period, else show the variance.
- Post-filing correction: the system never edits a filed period; it raises a "GSTR-1A / next-period amendment" task (Tables 9A/9B).

### 9.3 IMS and 2B reconciliation
- Import GSTR-2B JSON. Match to the purchase register on supplier GSTIN, document number (normalised) and date; tolerance ₹1 on tax, ₹10 on taxable value (configurable).
- States per document: matched, mismatched, missing in books, missing in 2B, IMS-pending, IMS-rejected.
- IMS action cache (accept, reject, pending, no action, with timestamp). Warn: "no action" may count as accepted in 2B; never assume.
- Output: ITC claimable for the month = matched and accepted. Variance report to chase suppliers.
- Journal when ITC is taken: Dr GST input (CGST/SGST/IGST) Cr Payable (with the purchase). Reversal: Dr ITC reversed (expense or "ITC ineligible") Cr GST input.

### 9.4 ITC tracking, Rule 37 and 37A
- Per purchase invoice: `itc_amount_paise`, `itc_claim_deadline` (30 Nov after FY), `paid_to_supplier_paise`, `due_180_date = invoice_date + 180 days`.
- Daily job: alert at day 120, 150, 170. On day 181 with an unpaid balance create a proposed reversal: `reverse_paise = itc * unpaid / (invoice value incl. tax)`, plus interest `reverse_paise * 18% * days_from_itc_claim_to_reversal / 365` (rounded half-up; interest rate editable).
- Reversal journal: Dr ITC reversal (balance sheet "ITC reversed – recoverable") 4B(2); Cr GST input. Re-availment on payment: Dr GST input, Cr ITC reversed, with the interest not recoverable.
- Rule 37A: after 30 Sep, flag purchases from suppliers with a missing GSTR-3B (from 2B or a supplier compliance feed); propose reversal in the November return; allow re-availment.
- s.17(5) flags per purchase category; Rule 42/43 monthly calculator with an annual true-up; Rule 86B check (99% cash cap) when turnover over ₹50 lakh.
- Guardrails: block ITC claim if no 2B match and no override reason; block after the 16(4) deadline; log who overrode and why.

### 9.5 RCM self-invoicing
- Purchase flagged RCM when the supplier is unregistered and the category is in the notified list (category table editable, **UNVERIFIED** list), or the service is GTA, legal, director, sponsorship and similar from a registered/unregistered supplier.
- Auto-create a self-invoice (series `RCM/YY-YY/…`, ≤ 16 characters) on the supply date and a payment voucher when payment is made. Time-of-supply logic per 4.5 (60 days for services).
- Journals: purchase: Dr Expense 10,000,000 Cr Supplier 10,000,000. RCM: Dr RCM input CGST 900,000, Dr RCM input SGST 900,000, Cr RCM output CGST 900,000, Cr RCM output SGST 900,000. Pay cash: Dr RCM output payable 1,800,000, Cr Bank 1,800,000. ITC is claimable only after the cash payment.
- E-invoice for RCM: wait for the production date (see [gst-einvoice-ewaybill.md](gst-einvoice-ewaybill.md)).
- Guardrail: the RCM ITC cannot be taken before the liability is paid in cash.

### 9.6 TDS section master and statement data
- `tds_section` table: code (internal), `old_section`, `new_ref`, rate_bp, `rate_bp_no_pan`, `threshold_single_paise`, `threshold_aggregate_paise`, `threshold_basis` (per_month, per_fy, per_payment), `effective_from`, `payee_type` condition, `verified` boolean (shows the UNVERIFIED state in the UI).
- Aggregation table: `(deductor, payee PAN, section, FY)` with running total. On each bill: if single threshold or running total crosses, deduct on the **whole** amount, catching up earlier payments (194Q: on the excess only).
- Base: ex-GST value where GST is shown separately.
- Lower-deduction certificate: validity, rate, cap; auto-apply inside the cap.
- Journal (professional fee ₹1,00,000.00 at 10%): Dr Professional fees 10,000,000; Dr GST input 1,800,000 (if eligible); Cr TDS payable 1,000,000; Cr Vendor 10,800,000 (fee 10,000,000 + GST 1,800,000 - TDS 1,000,000). Deposit: Dr TDS payable Cr Bank by the 7th.
- Statement data: per quarter, one row per deduction (payee PAN, section, amount paid, date, TDS, deposit challan BSR/serial). Exports for Forms 138, 140, 144 and 143 as CSV for a TDS filing utility or tool (the official FVU/JSON format is not confirmed: **UNVERIFIED**). Certificate register for Forms 130, 131, 132.
- Alerts: deposit by the 7th (30 Apr for March); statements by 31 Jul, 31 Oct, 31 Jan, 31 May; interest and late-fee calculator (see 6.3).
- Guardrails: block payment without PAN or apply 20%; flag a payee at 90% of the threshold; the 40(a)(ia) risk report (undeducted or undeposited) at year-end.

### 9.7 MSME 45-day alerts and interest
- Supplier master: `udyam_no`, `msme_category` (micro, small, medium, none), `udyam_valid_from`, `agreement_days` (0 = none → 15 days; max 45).
- Per bill: `acceptance_date`, `msme_due_date = acceptance + (agreement_days or 15)`, capped at 45 days.
- Alerts at 15, 7, 0 days before due. Year-end report for s.37(2)(g) (old 43B(h)): unpaid MSME bills past due at 31 Mar.
- Interest: `bank_rate_bp` table (RBI rate with effective dates, **to be loaded**). Monthly compounding at `3 × bank_rate`. For each completed month late: `interest = (principal + accrued) * 3 * rate / 12`. Partial month handled by days/30 (rule **UNVERIFIED**).
- Journal on accrual (if the company chooses to book it): Dr MSME interest expense (non-deductible, tag) Cr Interest payable to supplier. Payment: Dr Payable Cr Bank. MSME-1 view: bills over 45 days by supplier for each half-year, due 31 Oct and 30 Apr.
- Guardrail: if the supplier is micro or small, warn when payment terms exceed 45 days; do not allow a longer term without an override note.

### 9.8 Audit-trail compliance checklist
- Every table that holds books of account (journal, ledger, invoices, bills, payments, tax rate changes, master edits) has an append-only `audit_log`: user, time (UTC), action, table, record id, **old and new values**, IP/session, request id.
- No UPDATE or DELETE on posted rows; corrections are reversal entries. Database role used by the app cannot alter the audit table; the log has no admin disable switch and no feature flag.
- Hash chain on the log (each row holds the previous row's hash) so tampering is detectable.
- Retention 8 years minimum, with legal hold; export for the auditor (CSV, with chain proof).
- Logs also cover changes made by direct DB or API (not just the UI), and the periods locked or unlocked.
- Auditor view: per-FY report of manual overrides (ITC, TDS, rate), back-dated entries and unlocks.
- Guardrail tests: cannot disable the log; cannot post into a locked period; a hard-close needs two approvers.

### 9.9 Build order
1. Tax-rate master and resolver (everything else uses it).
2. Audit trail and period lock (companies already need it).
3. TDS master and aggregation (verify the section numbers first).
4. GSTR-1 and GSTR-3B data and export.
5. ITC tracking with the 37 and 37A alerts.
6. IMS and 2B reconciliation.
7. RCM self-invoicing.
8. MSME alerts and interest.

### 9.10 Open items before coding
- Read the consolidated 11/2017 Sl. No. 3 and the GST goods schedule (9/2025 as amended).
- Confirm RCM lists, Rule 37A date, Rule 86B and s.16(5)/(6) from the CGST Act and Rules.
- Confirm new-Act section numbers for interest, late fee, no-PAN, lower deduction certificate and 40(a)(ia).
- Get the GSTN IMS FAQ and the GSTR-1 and GSTR-3B JSON schemas.
- Check the RBI bank rate and the MSME-1 2025 format.
- Confirm Companies (Accounts) Rules 3(1) text and Schedule II lives.
