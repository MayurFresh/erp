# Industry verticals and SMB user pain points

DRAFT. First-pass research as of 29 Oct 2026, from about 14 web searches. Almost every source reached was secondary (blogs, review aggregators, vendor pages). The official sites that matter (cbic-gst.gov.in, incometaxindia.gov.in, fcraonline.nic.in, cdsco.gov.in, nppaindia.nic.in, abdm.gov.in, fssai.gov.in, bis.gov.in) were not opened. Anything not confirmed from a primary source is marked **UNVERIFIED**. Rules that come from general knowledge, not from a retrieved page, are also marked **UNVERIFIED**. Treat the rate and section tables as a checklist to verify against the notification text before building.

Scope: Part A covers 13 industries (law, GST, calculations, ERP features, core-vs-pack call). Part B covers 15 user pain points and 10 quick wins. E-commerce, HR/payroll and general GST/TDS rules are out of scope (other analysts). Features the spec already lists are not repeated.

Reading the tables:
- "Core" means settings, fields or reports in the shared core. "Pack" means a separate module with its own screens and permissions.
- Priority is the build priority of that vertical for Progen: high, medium or low. It reflects market size, compliance risk and how badly the core fails without it.

## 0. Cross-industry facts used throughout

Sources for this section are secondary except where stated.

| Topic | Rule as understood on 29 Oct 2026 | Source / status |
| --- | --- | --- |
| GST slabs from 22 Sep 2025 | Main slabs are 5% and 18%, plus 40% for a short list of sin/luxury goods. The old 12% and 28% slabs were folded away for most items. | 56th GST Council decisions; PIB summary https://static.pib.gov.in/WriteReadData/specificdocs/documents/2025/sep/doc2025921642801.pdf (not opened, listed by search). CBIC FAQ digest https://fintaxblog.com/cbic-faqs-decisions-of-56th-gst-council-explained/ (secondary). Item-level rates **UNVERIFIED** until the notification text is read. |
| Rate changes by price | Several rates now depend on the per-unit price (apparel and footwear up to Rs 2,500 per piece at 5%, above that 18%; hotel rooms up to Rs 7,500 per night). The ERP must pick the rate per line from the unit price, not only from the item master. | Secondary: https://tallysolutions.com/gst/new-gst-rates-2025-key-changes-and-faqs. **UNVERIFIED** for the apparel limit. |
| Cash receipt ban Rs 2 lakh | Old s.269ST. One source says the 2025 Act equivalent is s.186, in force for receipts from 1 Apr 2026. Another says s.221. The number is not settled. Threshold and the three tests (one day, one transaction, one event) are said to be unchanged. | https://ebizfiling.com/blog/section-186-of-the-income-tax-act/ and https://www.incorpx.io/blog/cash-transaction-limits-small-business-2026. Section number **UNVERIFIED**. Penalty under the old Act was 100% of the amount (s.271DA). |
| TCS on motor vehicle sale over Rs 10 lakh | Old s.206C(1F), 1%. A 2025 Act equivalent was not found. Assume still applicable. | **UNVERIFIED**. Needs the 2025 Act text (TCS chapter). |
| Post-sale discounts | Discount by credit note is allowed only if agreed before the supply and shown in the original invoice terms; the buyer must reverse ITC. CGST Act s.15(3)(b), s.34. | Rule is from general knowledge, **UNVERIFIED** here. Check CBIC Circular 92/11/2019-GST. |
| B2C invoice rules | A registered seller selling to an unregistered buyer may issue a consolidated daily invoice for supplies under Rs 200 where the buyer does not ask for an invoice (Rule 46). Dynamic QR code is mandatory only on B2C invoices of a seller with turnover above Rs 500 crore. E-invoice is for B2B only. | General knowledge, **UNVERIFIED**. |
| E-invoice threshold | Aggregate annual turnover above Rs 5 crore (existing doc in this folder: gst-einvoice-ewaybill.md). Not repeated here. | See that note. |
| MSME payment rule | Payment to micro/small suppliers within 45 days or the expense is disallowed (old s.43B(h)). 2025 Act section not checked. | **UNVERIFIED**. Needs an ageing flag on payables for Udyam-registered vendors. |

## PART A. Industry by industry

## 1. Manufacturing

Laws and registrations:
- GST registration; Udyam (MSME) registration; Factories Act 1948 and state shops/factory licences; BIS/ISI marks for notified products; Legal Metrology for packaged goods. Excise remains only for a few goods (petroleum, tobacco); not covered. **UNVERIFIED** on any change after Sep 2025.
- Job work: CGST Act s.143, Rules 45 and 55 (challan), Form GST ITC-04. All from search results, secondary: https://www.knowyourgst.com/blog/gst-form-itc-04-job-work-supplies-109/ and https://gsthero.com/form-itc-04-job-work-a-complete-guideline-to-claim-input-tax-credit/.

GST treatment:
| Item | Treatment | Status |
| --- | --- | --- |
| Goods sold | Per HSN, mostly 5% or 18% after Sep 2025. | Rate per item **UNVERIFIED** |
| Composition scheme (manufacturer) | 1% of turnover, no ITC, no inter-state, turnover up to Rs 1.5 crore. | General knowledge, **UNVERIFIED** |
| Job-work service charged by the job worker | 18% in general; 5% for some textile and leather job work (Notif. 11/2017-CT(R) item 26). | **UNVERIFIED** |
| Inputs sent to job worker | No GST if sent under a challan; principal may take ITC on inputs and capital goods sent out. | s.143 |
| Return time limit | Inputs: back (or supplied from the job worker's premises) within 1 year. Capital goods: 3 years. Moulds, dies, jigs, fixtures and tools are excluded from the 3-year rule. Clock runs from the date of dispatch. Miss the limit and the dispatch is deemed a supply, so GST plus interest is due. | Only one blog gave the 1/3-year rule; the statute text was not opened. **UNVERIFIED** |
| ITC-04 filing | Filed by the principal only. Turnover above Rs 5 crore: half-yearly (25 Oct, 25 Apr). Up to Rs 5 crore: yearly (25 Apr). | Secondary, sources disagree on dates. **UNVERIFIED** |
| Scrap | Taxable as a supply at the scrap's HSN rate. Waste from job work belongs to the principal unless the job worker keeps it. | General knowledge |
| By-products | Separate item with its own HSN; cost allocation by net realisable value is the usual method. | Accounting practice, not a statute |

Key calculations:
- Multi-level BOM explosion with yield and scrap percent: required quantity = BOM quantity / (1 - scrap%).
- Standard cost versus actual cost; WIP valuation; variance by material, labour and overhead.
- Joint-product and by-product cost split (relative sales value or NRV).
- Job-work ageing: days since dispatch, days left to the 1-year or 3-year deadline, by challan line.
- ITC-04 table 4 (sent) and table 5 (received back) built from challans.

Must-have ERP features:
- BOM with versions, alternates, and process routing; production order; material issue (manual and backflush); finished-goods receipt; by-product and scrap receipt.
- Batch and serial tracking from raw material to finished goods (forward and backward trace); batch-wise cost.
- Job-work challan (Rule 55) for out and in; free-issue material; automatic ITC-04 export; ageing alert at 90 and 30 days before the deadline.
- Work centre and machine capacity (basic), reorder level and MRP-lite (material requirements from sales orders).
- Quality hold (QC pass/fail) before stock becomes available.
- 43B(h) vendor ageing for MSME suppliers.

Core or pack: **Separate pack (Manufacturing). Priority: high.** Core already covers inventory and purchases, but BOM, production orders and job work cannot be bolted on with settings. This is also the biggest reason Busy and Tally users outgrow their software (secondary: https://www.techjockey.com/compare/mybillbook-accounting-software-vs-tally-erp-9).

## 2. Trading and distribution

Laws and registrations: GST; trade licence; for FMCG distributors, the principal's distributor agreement is the real rulebook (target, scheme, claim and return terms). Shops and Establishments Act. Legal Metrology for resold packaged goods.

GST treatment: per item rate. Key point is how schemes are taxed.
| Scheme type | GST treatment | Status |
| --- | --- | --- |
| Trade discount shown on the invoice | Reduces the taxable value (s.15(3)(a)). | General knowledge, **UNVERIFIED** |
| Volume/turnover rebate by credit note after the supply | Reduces value only if agreed before supply and linked to specific invoices; buyer reverses ITC. | s.15(3)(b), s.34. **UNVERIFIED** |
| Free goods under "buy 10 get 1" | Treated either as a discount spread over the paid goods or as a separate free supply at its own value; the cleaner method is to show the free line at zero rate-value and apportion tax. Gift of free goods outside a scheme blocks ITC (s.17(5)(h)). | **UNVERIFIED** |
| Manufacturer's scheme claim to the distributor | If it is a price discount the distributor invoices nothing; if a service (display, promotion) it is a taxable supply. | **UNVERIFIED** |

Key calculations:
- Scheme application: slab, quantity bundle, value slab, product-group, retailer-class; stack or best-of rules.
- Price list resolution order: customer-specific, then customer group, then item price list, then MRP-based.
- Credit exposure = outstanding invoices + unbanked cheques + open orders - advances; block or warn when over limit or overdue by N days.
- Margin on landed cost; claim receivable from the principal = scheme discount passed to retailers.

Must-have ERP features:
- Sales schemes engine (quantity free, % off, value slab, combo), with a scheme-claim ledger.
- Multiple price lists with validity dates; customer-wise special rate memory.
- Credit limit and credit days per customer, with an approval override by role.
- Beat plan: route, retailer list, visit schedule; order capture on mobile, offline; GPS check-in.
- Van sales: load stock to van, sell and collect, end-of-day reconciliation of stock, cash and UPI; delivery challan for goods moved without invoice.
- Cheque register: received, deposited, bounced, and charge-back.
- Secondary-sales visibility: distributors want retailer-wise, SKU-wise sales to share with the principal, and the principal wants stock-at-distributor and claim status. Provide a standard monthly export (retailer, SKU, quantity, value) and a claims statement.
- Salesperson targets and incentive reports; outstanding collection by salesperson.
- Returns: damaged, expired and near-expiry, with credit note and ITC reversal.

Core or pack: **Core for schemes, price lists, credit limits, cheque register (priority: high). A "Distribution / Field sales" pack for beat, van and secondary-sales (priority: medium).** Marg and Busy are strong here, so this is where Progen is most often compared head to head.

## 3. Retail and POS

Laws and registrations: GST; Shops and Establishments licence; Legal Metrology (Packaged Commodities) Rules 2011 and Weights and Measures Act 2009; FSSAI for food retail; BIS for notified goods. Legal Metrology text not opened. **UNVERIFIED** on specifics below.

Rules that shape the product:
| Rule | Effect on the ERP | Status |
| --- | --- | --- |
| MRP is the maximum retail price, inclusive of all taxes; selling above MRP is an offence. | Store MRP per item or batch. Selling price is at or below MRP. Taxable value = selling price x 100 / (100 + GST rate). Never add GST on top of MRP. | General knowledge, **UNVERIFIED** |
| Different MRP for the same item across batches. | Price must be batch-linked; the POS must show the batch MRP. | Same |
| Loose items sold by weight need a verified, stamped scale. | Weighing-scale integration; scale verification date reminder. | **UNVERIFIED** |
| Apparel/footwear rate depends on per-piece price. | Rate picked per line at billing. | See section 0 |
| B2C invoice, consolidated daily invoice below Rs 200. | Allow quick bill, optional customer details, daily summary invoice. | See section 0 |
| Cash limit: seller cannot accept Rs 2 lakh or more in cash in a day from one person (s.269ST, now s.186 or s.221). | Warn at the till at Rs 1.9 lakh per customer per day (needs customer or mobile capture) and block at the limit. PAN needed for cash sale above Rs 2 lakh (Rule 114B). | Section number **UNVERIFIED** |

Key calculations:
- MRP-inclusive back-calculation with rounding rule (round at line or at invoice; both are used; make it a setting).
- Bill-level discount spread across lines before tax.
- Loyalty: points earned = floor(net bill x rate); redemption reduces payable; liability = unredeemed points x value. GST treatment of redeemed points as a discount versus payment: **UNVERIFIED**.
- Cash-up: opening float + cash sales - refunds - cash drops = expected; variance = counted - expected.
- Weighing-scale barcode: EAN-13 starting with 2 carries an item code and either price or weight; decode at the till. **UNVERIFIED** (GS1 variable-measure format).

Must-have ERP features:
- Fast POS: barcode scan, search, hold and recall bills, multiple payment modes (cash, UPI, card, split), offline billing with later sync, thermal 2/3 inch printing, and A4 invoice option.
- Barcode label printing; EAN/GS1 import; item variants (size, colour).
- Weighing-scale and PLU integration.
- Returns and exchanges with credit note; gift vouchers and store credit; loyalty and customer wallet.
- Shift and cash management: open and close shift, cash drop, Z-report, till variance, UPI/card settlement reconciliation.
- Daily GST summary; HSN summary; consolidated B2C invoice.
- Multi-counter and multi-store with location scopes (core RBAC already has this); inter-store transfers.

Core or pack: **Separate pack (Retail POS). Priority: high.** Core invoicing is not fast enough for a counter, and the offline requirement is non-negotiable (see Part B, item 1).

## 4. Restaurants and hotels

Laws and registrations: FSSAI (licence number on every bill and premises display, see below); GST; Shops Act; fire and health trade licence; liquor licence where applicable (state excise, not covered); for hotels, police registration and Form C for foreign guests (Foreigners Act, via the FRRO portal). Form C details **UNVERIFIED**.

FSSAI (Food Safety and Standards (Licensing and Registration) Regulations 2011; fssai.gov.in not opened):
- Registration for turnover up to Rs 12 lakh, state licence above that up to Rs 20 crore, central above. **UNVERIFIED**.
- The licence number must be printed on invoices and cash memos and the licence displayed at the premises. **UNVERIFIED**.

GST treatment (post 22 Sep 2025; conflicting secondary sources, see notes):
| Supply | Rate | Notes |
| --- | --- | --- |
| Standalone restaurant, takeaway, delivery | 5%, no ITC | Widely reported as unchanged. Source: https://djubo.com/blog/gst-reforms-2025-hotels-restaurants. One blog (taxguru) said 18% with ITC; that conflicts with the others and is treated as wrong. **UNVERIFIED** until Notif. 11/2017-CT(R) is read. |
| Restaurant inside a hotel with room tariff above Rs 7,500 (specified premises) | 18% with ITC | Same source set. |
| Composition restaurant | 5% flat, no ITC, turnover up to Rs 1.5 crore | General knowledge, **UNVERIFIED** |
| Hotel room up to Rs 7,500 per unit per day | 5% | 22 Sep 2025 cut from 12%. Sources agree on the rate but not on ITC; some say with ITC, some without. **UNVERIFIED**. https://www.angelone.in/news/taxation/gst-cut-on-hotel-rooms-below-7-500-how-much-you-save |
| Hotel room above Rs 7,500 | 18% with ITC | Same |
| Rate is chosen on the price actually charged per room per day, room by room, not on an average | Needs per-night, per-room tariff on the folio | Same source set |
| Banquet, conference | 18% | General knowledge |
| Outdoor catering | 5% without ITC (18% with ITC at specified premises) | **UNVERIFIED** |

Aggregator (Swiggy, Zomato) under CGST s.9(5): the aggregator (e-commerce operator) pays GST on restaurant service supplied through its app. The restaurant therefore does not charge or pay GST on those orders, and cannot take ITC against them. The restaurant still bills the aggregator for packaging, and the aggregator bills commission at 18%. Effective from 1 Jan 2022 (Notif. 17/2021-CT(R)). General knowledge, **UNVERIFIED** here. From Sep 2025 local delivery through an app is also reported to fall under s.9(5); **UNVERIFIED**.

Key calculations:
- Per-line rate from restaurant status (and for hotels from the room rate of that night).
- Aggregator settlement: order value - commission (18% GST on it) - packaging share - TCS/TDS = payout; reconcile to the daily sales report.
- Table turnover, covers, average spend, food cost % (recipe cost / selling price).
- Service charge: taxed at the rate of the underlying supply. The legality of mandatory service charge is contested; **UNVERIFIED**.

Must-have ERP features:
- Table map, order taking on a handheld, KOT printing to kitchen and bar by station, KOT cancel/edit with reason, bill split and merge, bill hold, void with manager PIN.
- Recipe costing with ingredient deduction on sale; wastage; kitchen stock and central kitchen transfers.
- Aggregator order inflow (as a sales channel marked s.9(5), no GST on bill) and payout reconciliation.
- FSSAI number and licence-expiry reminder on the bill template.
- Hotel: room master and rate plans, reservation calendar, check-in and Form C data, folio with night audit, extra-bed and other charges, per-night rate for the slab check.
- Delivery rider assignment (basic); loyalty; online QR ordering is optional.

Core or pack: **Separate pack (Restaurant POS). Priority: medium.** Hotel PMS is a separate, larger product; **priority: low** (integrate with a channel manager rather than build one).

## 5. Pharma distributors and medical stores

Laws and registrations:
- Drugs and Cosmetics Act 1940 and Rules 1945. Retail licence Forms 20 and 21, wholesale Forms 20B and 21B; a registered pharmacist is required for retail.
- Schedule H (prescription drugs), Schedule H1 (antibiotics and some others, separate register), Schedule X (narcotic and psychotropic, stricter). Narcotics also fall under the NDPS Act.
- Price control: DPCO 2013 and the NPPA. NPPA fixes a ceiling price for scheduled formulations; the figure excludes GST. Selling above the ceiling plus GST is an offence. Retailer margin is said to be 16%. Retailers must display the price list (para 24(4) DPCO). Source (secondary): https://www.corpseed.com/law-update/nppa-fixes-ceiling-prices-for-key-medicines-under-dpco-2013 and https://www.indialaw.in/blog/regulatory/dpco-2013-ceiling-price-2026-legal-analysis-of-nppa-order/.
- The search did not reach the Schedule H1 register contents. From general knowledge (**UNVERIFIED**): the H1 register records the prescriber, patient name and address, drug, quantity and date, and is kept for three years; Schedule H sales need a prescription copy retained.

GST treatment (post 22 Sep 2025; secondary, **UNVERIFIED**):
- Most medicines now 5% (earlier 12%); a list of about 33 life-saving drugs and three cancer drugs nil; medical devices 5%; health insurance for individuals exempt.
- Free goods and scheme "10+1" follow the trading rules in section 2.
- Near-expiry returns need a credit note under s.34; the supplier must issue it by 30 Nov after the financial year or by the annual return date, whichever is earlier (time limit **UNVERIFIED**).

Key calculations:
- MRP-inclusive pricing with PTR (price to retailer) and PTS (price to stockist) margins; the effective margin after scheme.
- Ceiling check: sale rate per unit (strip or ml) must not exceed ceiling per unit x pack size plus GST. Packs of different sizes need the per-unit conversion.
- Batch-wise expiry ageing buckets (0-3, 3-6, 6-12 months); return window (many companies accept returns three months before to six months after expiry; contract-specific, **UNVERIFIED**).

Must-have ERP features:
- Batch, expiry, MRP and free-quantity captured on every purchase line; FEFO (first expiry, first out) picking; expiry blocking at sale.
- Drug licence numbers on the invoice (both parties); licence validity reminder; pharmacist name on the bill.
- Schedule H, H1 and X registers generated from sales lines flagged by drug schedule, with prescriber and patient details at billing. Print and export.
- NPPA ceiling price table import and a warning when a sale price breaks it; periodic price-list update.
- Near-expiry report, supplier-wise return list, expiry-credit-note flow.
- Salt/composition-based substitute search; strip/loose quantity sales (a strip split into tablets).
- Fast billing with doctor name and discount; cold-chain items flag.
- Supplier purchase import (the Marg-style distributor invoice).

Core or pack: **Core for batch and expiry (priority: high, it serves pharma, FMCG, food and cosmetics). A Pharma pack for schedule registers, licences, NPPA and expiry returns. Priority: high.** Marg built its business here, and this is the pack most likely to win distributor customers.

## 6. Clinics and hospitals

Laws and registrations: state medical council registration for doctors; Clinical Establishments (Registration and Regulation) Act 2010 where adopted by the state (not all states); NABH accreditation (voluntary); biomedical waste authorisation; PCPNDT for imaging centres; pharmacy licence if there is a pharmacy. All general knowledge, **UNVERIFIED**.

GST treatment (general knowledge, **UNVERIFIED**; post-Sep-2025 changes mostly on medicines):
- Healthcare services by a clinical establishment, doctor or paramedic are exempt (Notif. 12/2017-CT(R) item 74). Cosmetic and plastic surgery that is not medically necessary is taxable at 18%.
- Room rent above Rs 5,000 per day (excluding ICU, CCU, NICU) is taxable at 5% on the amount above, no ITC (the 2022 change).
- Medicines and implants supplied to an in-patient as part of treatment are part of the exempt composite supply. Pharmacy sales to out-patients and walk-ins are taxable at the medicine's rate (CBIC Circular 32/06/2018-GST). **UNVERIFIED**.
- Because the clinic's own outward supply is exempt, ITC is blocked for it (Rule 42 and 43 reversal on mixed use).

ABDM and ABHA basics (https://abdm.gov.in not opened; **UNVERIFIED**):
- ABHA: a 14-digit health account number (created by Aadhaar OTP or mobile) plus an ABHA address.
- Facility registers in the Health Facility Registry (HFR); doctors in the Healthcare Professionals Registry (HPR).
- A clinic software connects to ABDM as a health information provider (HIP): it can create or verify ABHA at registration, scan-and-share a patient token, and link care contexts (visits, prescriptions, lab reports) via the gateway. Integration passes through a sandbox and milestone certification (M1, M2, M3).
- Treat ABDM as optional in v1, because uptake in small clinics is low; build the data hooks (ABHA number field, HFR ID, doctor HPR ID).

Key calculations:
- Package billing (surgery package inclusive of room, medicines, consumables) and split to exempt and taxable parts.
- Doctor revenue share (percentage of consultation or procedure).
- Insurance and TPA cashless: pre-authorisation amount, approved amount, co-pay, non-payable items, and TPA deduction on settlement; PM-JAY package rates.

Must-have ERP features:
- Patient master (UHID, ABHA, phone), OPD token and appointment, consultation fee, e-prescription, IPD admission-bed-discharge and interim bill, deposit and refund.
- Pharmacy and lab inventory with batch/expiry (reuse pharma); lab test catalogue and report print.
- Exempt versus taxable service flag per charge head; room-rent threshold rule.
- TPA and insurance claim tracking; doctor payout; medical-record retention and privacy (DPDP Act 2023, consent and access logging; rules timeline **UNVERIFIED**).

Core or pack: **Separate pack (Clinic/Hospital). Priority: medium for clinics and small nursing homes, low for large hospitals** (HIS is a mature, regulated product; do not compete there).

## 7. Schools, coaching and education

Laws and registrations: affiliation to a board (CBSE, ICSE, state); trust or society registration (see section 13); RTE Act 2009 (25% seats for weaker sections in private unaided schools); UDISE+ reporting; state fee regulation acts; for coaching, shops and establishments plus GST registration if above threshold. **UNVERIFIED** on state specifics.

GST treatment (Notif. 12/2017-CT(R), general knowledge, **UNVERIFIED**):
| Service | Treatment |
| --- | --- |
| School (pre-school to higher secondary) fees from students, including admission, tuition, exam, and late fee | Exempt |
| Services supplied to the school by others (transport, security, catering) | Exempt in specified cases; check the entry. Student transport by school-run bus is exempt. |
| Higher education leading to a recognised qualification | Exempt for the institution's core services |
| Private coaching centres, test-prep, skill training not leading to a qualification | Taxable at 18% |
| Individual tutor | Taxable above the Rs 20 lakh threshold; GST exemption for individuals covers only specific cases |
| Sale of uniforms, stationery, and non-printed material | Taxable goods, at their own rate; printed books nil |
| Online coaching to students abroad | Export of services if conditions are met (see section 8) |

Key calculations:
- Fee structure: class x category x term; heads (tuition, transport by route slab, hostel, activity); concessions (sibling, staff ward, merit, RTE, EWS) as percentage or fixed; late fee by day or slab; instalment schedule.
- Dues by student, family (parent with several children), and class; advance fee; refund on withdrawal.
- Coaching: batch fee, GST at 18% on fee, instalments with GST on each receipt.

Must-have ERP features:
- Student master, class and section, parent links; fee heads and fee structures by session; concession rules; instalment calendar; auto-generate demand; collect at counter, UPI or cheque; receipt print with receipt number, session, heads paid, and balance.
- Defaulter list, reminders by SMS and WhatsApp, fee reports for management; bank reconciliation of online collections.
- Receipt series per session; no gaps and no deletion, only reversal.
- Optional: attendance, timetable, exam results; these are a full school ERP and out of scope.

Core or pack: **Separate pack (Education fees). Priority: low.** Fee collection and receipts can be done with settings (items as fee heads, customers as students), but concessions and family-level dues need a real model. The school-ERP market is crowded; limit to fees and accounts, with a trust accounting link (section 13).

## 8. Professional services and agencies

Laws and registrations: GST; professional body registration (ICAI, BCI, ICSI, Council of Architecture and so on); Shops Act or LLP/company law for firms. SAC codes are GST service accounting codes; the main ones (general knowledge, **UNVERIFIED**):
| SAC | Service |
| --- | --- |
| 9982 | Legal and accounting services |
| 9983 | Other professional, technical and business services (consulting, design, advertising 998361, IT consulting 998313) |
| 9984 | Telecom (reference) |
| 9985 | Support services (manpower supply 998513) |
| 9987 | Maintenance and repair |
| 9992 | Education services |

GST and tax rules:
- Standard rate 18%. Services to a person outside India can be an export of services (zero-rated) if the five conditions of IGST s.2(6) are met: supplier in India, recipient outside India, place of supply outside India, payment in convertible foreign exchange (or INR where RBI permits), and the two parties are not merely establishments of one person. General knowledge, **UNVERIFIED** here.
- Export without paying IGST needs a Letter of Undertaking (LUT, Rule 96A, Form GST RFD-11), filed once per financial year. Otherwise pay IGST and claim refund. Bond/LUT validity is annual; **UNVERIFIED** on any change in 2026.
- Legal services by an advocate or firm of advocates to a business entity: reverse charge, recipient pays (Notif. 13/2017-CT(R)). Exempt for a recipient business below the registration threshold. The supplier issues an invoice with no tax and the recipient self-assesses. Same for senior advocates. **UNVERIFIED**.
- Time of supply for services: invoice must be issued within 30 days of service (s.31, Rule 47); advance payments for services are taxable on receipt. **UNVERIFIED**.
- TDS under the new Act on professional fees: the old 194J, now s.393(1) Sl. 6(iii), 10% for professional fees (rates and thresholds in contractor-billing.md).

Key calculations:
- Retainer: fixed fee per month, billed in advance, with true-up on hours used; unused hours roll or lapse.
- Timesheet billing: hours x rate card by role, by client or project; write-offs; utilisation %.
- Milestone billing: percentage of contract on milestone completion; revenue recognition by stage; retention.
- Out-of-pocket (OPE) recharge; pure-agent expenses are outside the taxable value only if the strict conditions of Rule 33 are met (**UNVERIFIED**).
- Foreign currency invoice and realisation: exchange gain or loss on receipt, FIRC/e-BRC tracking.

Must-have ERP features:
- Client and engagement master, rate cards, timesheets with approval, WIP (unbilled) report, recurring invoices, milestone schedule, retainer ledger.
- RCM flag on a purchase (legal services) with self-invoice and payment voucher; GSTR-3B RCM table.
- Export invoice with LUT number on it, currency, and the zero-rated flag; LUT expiry reminder.
- Client-wise profitability (revenue minus cost of staff time).
- Approval, document storage per client.

Core or pack: **Core settings (SAC items, RCM, LUT, recurring invoices, foreign currency) and the Organisations pack for timesheets. Priority: medium.** No separate vertical pack needed; this is where the most users sit (CAs, architects, agencies) and where Vyapar and myBillBook are weak.

## 9. Logistics and transport (GTA)

Laws and registrations: Motor Vehicles Act 1988 (permits, fitness, national permit, driver licence, insurance, PUC); GST; e-way bill under CGST Rule 138; Carriage by Road Act 2007 (consignment note, carrier's lien) **UNVERIFIED**.

GST treatment of goods transport agency (GTA) services:
| Option | Rate | Who pays | ITC |
| --- | --- | --- | --- |
| Reverse charge (default) | 5% | Recipient, when a registered person of a specified type (factory, company, society, partnership firm, casual taxable person and similar) | GTA gets no ITC. Recipient may take credit of the RCM tax. |
| Forward charge (GTA opts in) | **18%** after 22 Sep 2025 (it was 12%) | GTA | GTA can take ITC |
- The brief for this note said "12% forward charge". After the 22 Sep 2025 rationalisation, a secondary summary of the CBIC FAQ gives 5% without ITC or 18% with ITC: https://fintaxblog.com/cbic-faqs-decisions-of-56th-gst-council-explained/. Treat 12% as out of date. **UNVERIFIED** until Notification 15/2025-CT(R) (or successor) is read.
- The option is exercised through a declaration; a forum source says it is for the whole financial year and carries forward unless revoked (https://www.caclubindia.com/forum/change-in-gst-rate-for-gta-614073.asp). The date of 15 March before the year (Annexure V, Notif. 03/2022-CT(R)) is from general knowledge, **UNVERIFIED**.
- Exempt: transport of specified goods (agricultural produce, milk, food grains and so on) and transport where the consideration is under Rs 1,500 per consignment or Rs 750 per single carriage (**UNVERIFIED**).
- Unregistered GTA supplying to a registered recipient: the recipient pays 5% under RCM.

TDS: a transporter owning up to 10 goods carriages who gives a PAN declaration is exempt from TDS (see contractor-billing.md; old s.194C(6), new s.393(4)).

Key calculations:
- Freight: rate x weight or per trip or per km or per container; detention and loading charges; fuel surcharge; GST by option.
- Trip profit: freight income - fuel - driver bata - toll (FASTag) - repairs - tyre - commission - other.
- Fuel efficiency: km per litre by vehicle; mileage variance.
- E-way bill: validity of 1 day per 200 km for ordinary goods and per 20 km for over-dimensional cargo; Part B update on vehicle change; consolidated e-way bill for multiple consignments in one vehicle. Duty to generate rests on the consignor, the recipient or, when neither does, the transporter, for consignments above Rs 50,000 (general knowledge, **UNVERIFIED**; more detail in gst-einvoice-ewaybill.md).

Must-have ERP features:
- Lorry receipt (LR/consignment note) with consignor, consignee, goods, weight, freight, "to pay / paid / TBB" terms; LR series; the GTA invoice must carry LR numbers (Rule 46(p)). **UNVERIFIED**.
- Booking, loading and delivery status; proof of delivery upload; multiple LRs on one invoice; bilty-wise outstanding.
- Fleet: vehicle master with document expiry (permit, fitness, insurance, PUC, tax); driver master; tyre and maintenance log; fuel entries and mileage; trip sheet and driver advance settlement.
- Vendor hire (attached vehicles): hire charges, advance and balance, TDS flag, RCM.
- E-way bill generation by LR with Part B and extend; GPS integration is optional.
- Fuel is outside GST (diesel and petrol are not covered), so no ITC on fuel: the cost must go to the P&L inclusive of tax.

Core or pack: **Separate pack (Transport). Priority: medium.** The e-way bill and GTA RCM logic are in core already; LR, trip and fleet are specific.

## 10. Jewellery

Laws and registrations:
- BIS Hallmarking of Gold Jewellery and Artefacts Order 2020: hallmarking is mandatory in notified districts; each article carries a 6-character alphanumeric HUID since 1 Apr 2023; jeweller must hold BIS registration; grades 14, 18, 20, 22, 23, 24 carat. District coverage and the latest phase are **UNVERIFIED** (bis.gov.in not opened).
- PMLA: dealers in precious metals and stones that accept cash of Rs 10 lakh or more are reporting entities (KYC, FIU-IND reports). **UNVERIFIED**.
- GST registration; PAN rules; Legal Metrology for weighing scales (accuracy class).

GST treatment (general knowledge, **UNVERIFIED**; no change in Sep 2025 was found):
- Gold, silver and jewellery 3%; rough or unworked diamonds 0.25%; cut and polished diamonds 1.5%. (The old Rs 3% rate is for the goods; the making charge is part of the value of the jewellery.)
- Job work for jewellery by a job worker: 5% on the making/job-work charge when billed separately (the old Notif. 11/2017-CT(R) item 26).
- Buying old gold from consumers: a purchase from an unregistered person is not under GST reverse charge (RCM on all unregistered purchases is suspended since 2017), so the jeweller makes a purchase voucher and no tax. If the old gold is exchanged against new jewellery, the new jewellery is invoiced at its full value and the old gold is a payment in kind. Whether the margin scheme (Rule 32(5)) applies to second-hand gold is **UNVERIFIED**.
- Jewellery sold to a buyer above Rs 2 lakh in cash needs PAN (Rule 114B). The old cash TCS on jewellery (s.206C(1D)) may have been removed; **UNVERIFIED**.
- The cash receipt cap of Rs 2 lakh (section 0) applies.

Key calculations:
- Gross weight, stone weight, net metal weight, purity, and fine weight = net weight x purity / 24 (for 24-carat basis) or x fineness / 1000.
- Rate of the day per gram; value = net weight x rate + making charge (per gram, per piece or percent) + stone value; wastage percent (deducted or added as extra weight); then GST at 3% on the total (and 5% on the job-work charge if separately supplied).
- Old-gold exchange: net weight after melting loss x purity x rate; deduct from the bill.
- Scheme "gold savings plan" instalments; these are advances for goods and attract GST at the time rules for goods (**UNVERIFIED**).

Must-have ERP features:
- Item master by tag: metal, purity, gross and net weight, stone detail, HUID, tag barcode; each piece is a serialised item.
- Daily rate board; billing with making-charge modes and wastage; old-gold purchase voucher and exchange; stone and diamond sub-ledger; advance and "booking at today's rate".
- Karigar (job worker) ledger in fine weight and money; issue/receive of metal; melting loss; ITC-04 for gold sent for job work (section 1).
- HUID capture at sale and mandatory print on the invoice; BIS registration number; cash and PAN alerts; KYC capture above limits.
- Stock in weight and in pieces, both; metal-wise reports.

Core or pack: **Separate pack (Jewellery). Priority: medium.** The weight-based, multi-unit stock and the karigar ledger do not fit the core. Marg and a few niche tools dominate; a focused Progen pack can compete.

## 11. Automobile dealers and service workshops

Laws and registrations: Motor Vehicles Act 1988 and Central Motor Vehicles Rules (dealer trade certificate, vehicle registration through Vahan, Form 21 sale certificate, Form 22 invoice); OEM dealer agreement; GST; pollution and fire licences for workshops. **UNVERIFIED** on forms.

GST treatment (post 22 Sep 2025; secondary, **UNVERIFIED**):
- Small cars (petrol up to 1200 cc and 4 m, diesel up to 1500 cc and 4 m) and two-wheelers up to 350 cc: 18%. Larger cars and bikes above 350 cc: 40%. The compensation cess on cars was removed. Electric vehicles stay at 5%. Spare parts moved to 18% from 28% for most.
- Workshop labour and servicing: 18%. Used-vehicle sale by a dealer: margin scheme under Rule 32(5), tax on the margin only, rate depends on the vehicle (**UNVERIFIED** after the Sep 2025 changes).
- TCS on sale of a motor vehicle with value above Rs 10 lakh: 1% (old s.206C(1F)). The 2025 Act reference and current rate were not confirmed; **UNVERIFIED**. It is collected by the seller and shown on the invoice, deposited like TDS, and reported in the TCS return.
- Sales through a dealer under dealer agency: commission from OEM is a taxable service.

Key calculations:
- Ex-showroom price, GST, TCS, road tax and registration, insurance, accessories, exchange value; on-road price.
- Used-car margin: sale price - purchase price (and cost of repairs under conditions).
- Job card: labour (flat-rate hours x rate) + parts + consumables + outside work, with warranty versus customer-pay split; parts markup on cost.
- Warranty claim to OEM: parts and labour allowed at OEM schedule; claim lag and rejection.

Must-have ERP features:
- Vehicle master (VIN or chassis, engine, registration, model, colour, key number); stock by VIN; booking and delivery; finance and insurance referral; exchange vehicle valuation; TCS handling on invoice; Form 21/22 data.
- Service: appointment, job card with estimate and customer approval, parts issue, outside job, final invoice, vehicle history, next-service reminder by km or date, AMC and extended warranty.
- Spare parts: part master with OEM part number, supersession, bin location, fast and slow movers, min and max, dealer price vs MRP, interchange.
- Workshop technician allocation and productivity (basic).

Core or pack: **Separate pack (Auto dealership/workshop). Priority: low to medium.** Most dealers use OEM-mandated DMS software; independent workshops (large market) need a light job-card pack. Build the workshop part first.

## 12. Agriculture, FPOs and agri-traders

Laws and registrations: state APMC Acts (mandi trading licence, market fee, user charges, commission cap); e-NAM for online mandi trade; FPOs registered as producer companies under the Companies Act 1956 Part IXA or as cooperative societies; Fertiliser Control Order, Insecticides Act and Seeds Act for input dealers (licence per category); FSSAI for processed food. **UNVERIFIED** on all; none opened.

GST treatment (general knowledge, **UNVERIFIED**):
- Unprocessed agricultural produce (fresh vegetables, fruit, raw grain) is exempt. Pre-packaged and labelled branded cereals, pulses and flour carry 5%. Unbranded stays exempt.
- Fertilisers 5%; many pesticides 18% reduced to 5% for some after Sep 2025; tractors and farm machinery reduced to 5% from 12% (**UNVERIFIED**).
- Commission agent services to an agriculturist for sale or purchase of agricultural produce are exempt (Notif. 12/2017-CT(R)). Services to the trader (buyer) are taxable. The arhtiya (commission agent) model depends on this split.
- Supply of agricultural produce by an agriculturist to a registered person: exempt from reverse charge (Notif. 5/2017-CT(R), as amended). **UNVERIFIED**.
- Agricultural income is exempt from income tax (old s.10(1), 2025 Act section not checked). The old s.80PA deduction for producer companies: continuation **UNVERIFIED**.
- APMC market fee and other mandi charges are state levies. They are not GST; if charged on top of a taxable service they may be part of the value. **UNVERIFIED**.

Key calculations (mandi):
- Arhtiya sale account (the "account sale" or "kachchi/pakki arhat"): gross sale at the mandi, less commission (percent), hamali (loading), tulai (weighing), market fee, bardana (bag) cost, and advance already paid = net payable to the farmer.
- Weight: gross - tare = net; moisture and quality deductions; rate per quintal.
- Interest on advances given to farmers; settle against the crop.
- FPO: member-wise produce, pooling and price, bonus, share capital, and aggregation costs.

Must-have ERP features:
- Farmer/member master with bank and Aadhaar (optional); advance and loan ledger; gate-in, weighing, auction or rate entry, "patti" (account sale) printing; buyer billing; commission and levy rules per commodity and state; mandi fee payment and return forms.
- Commodity master with unit conversions (quintal, kg, bag, number); stock in bags and weight both; lot and quality grade.
- Cold-storage and warehouse receipts (basic).
- Input-shop: seed and fertiliser licence number on invoice, batch and expiry, state-mandated stock registers.

Core or pack: **Separate pack (Agri/Mandi). Priority: low to medium.** It is a large, underserved, state-fragmented market; start with an arhtiya patti and farmer ledger for one or two states, and an input-dealer view that reuses the pharma batch/expiry features.

## 13. NGOs, trusts and societies

Laws and registrations:
- Registration: trust deed (Indian Trusts Act and state public trust acts), Societies Registration Act, or Section 8 company. Income tax: registration for exemption under old ss.12A/12AB and old 80G approval; Form 10A/10AB. Under the Income-tax Act 2025 the framework is reported to be renumbered: charities register as "registered non-profit organisations (RNPO)" under s.332, and donor deduction sits at s.354. These numbers are from a secondary guide only: https://www.patronaccounting.com/blog/donation-certificate-80g-rules-2026-form-10bd-10be-donor-compliance. **UNVERIFIED**; confirm in the Act text.
- Donation reporting: the old Form 10BD (statement of donations, filed by the institution) and Form 10BE (certificate to donors) continue under the 2026 Rules, with rule numbers possibly changed (**UNVERIFIED**); due date under the old Act was 31 May after the year; a late statement attracted a fee and penalty. The donor claims only against a statement that matches the institution's filing. The deduction may not be available under the new tax regime (**UNVERIFIED**).
- FCRA 2010 (foreign contribution): registration or prior permission with the MHA; a designated FCRA account at the SBI New Delhi Main Branch (after the 2020 amendment); a separate utilisation account allowed in any scheduled bank; quarterly disclosure of receipts on the FCRA site; annual return in Form FC-4 by 31 December; administrative expenses capped at 20%; no sub-granting to other organisations. Source not opened (fcraonline.nic.in); **UNVERIFIED**.
- Application of income: 85% of income to be applied in the year under the old Act, with limited accumulation under conditions, and corpus donations and specific-purpose funds tracked. **UNVERIFIED**.

GST treatment (general knowledge, **UNVERIFIED**): charitable activities (health, education, relief of poor) exempt for the entity; membership fees and event or sale activities may be taxable; a registered entity may have to pay RCM. Donations are not a supply unless against a benefit (sponsorship is taxable).

Key calculations:
- Fund accounting: restricted and unrestricted funds, corpus, project (grant) funds, each with its own income, expense and balance; transfers between funds with approval.
- 85% application test, accumulation (Form 9A/10 equivalent), carry-forward of excess application: **UNVERIFIED** in detail.
- FCRA: foreign receipts, utilisation by purpose, administration expense % check against 20%.
- 80G receipt data: donor name, address, PAN or Aadhaar (for the 10BD), amount, mode (cash donations above Rs 2,000 are not eligible for deduction under old s.80G(5D); **UNVERIFIED** in the new Act).

Must-have ERP features:
- Donor master and donation receipt (registration number, 80G/RNPO approval number and validity, PAN of donor, mode of payment, purpose), numbering without gaps; export in the 10BD format; annual donor statement.
- Grants and projects: grant received, utilisation by budget head, utilisation certificate, and donor-wise reports.
- FCRA module: separate bank accounts and ledgers, FCRA-flagged receipts and expenses, quarterly and FC-4 data, cap check.
- Member management for societies (subscription, receipts), income-and-expenditure and receipts-and-payments statements, balance sheet by fund.
- Audit-ready trail; role split between treasurer and approver.

Core or pack: **Separate pack (Non-profit). Priority: medium** (high compliance risk, few good tools). Fund accounting uses core ledgers but needs fund dimension and restricted balances; donation receipts and FCRA logic are specific.

## Vertical summary

| # | Industry | Core settings enough? | Pack | Priority |
| --- | --- | --- | --- | --- |
| 1 | Manufacturing | No | Manufacturing | High |
| 2 | Trading and distribution | Mostly (schemes, price lists, credit) | Field sales / DMS | Core high, pack medium |
| 3 | Retail and POS | No | Retail POS | High |
| 4 | Restaurants (hotels) | No | Restaurant POS (Hotel PMS) | Medium (low) |
| 5 | Pharma | Batch/expiry in core | Pharma | High |
| 6 | Clinics and hospitals | No | Clinic | Medium (low for hospitals) |
| 7 | Education | Partly | Education fees | Low |
| 8 | Professional services | Yes | None (use Organisations pack) | Medium |
| 9 | Logistics (GTA) | Partly (e-way, RCM) | Transport | Medium |
| 10 | Jewellery | No | Jewellery | Medium |
| 11 | Auto dealers and workshops | No | Auto workshop | Low to medium |
| 12 | Agri and mandi | No | Agri/Mandi | Low to medium |
| 13 | NGOs and trusts | Partly (fund dimension) | Non-profit | Medium |

Shared building blocks that several packs need, so build them once in core: batch and expiry (pharma, FMCG, food, agri inputs); serial and tag tracking (jewellery, vehicles, electronics); multi-unit conversion (agri, jewellery, pharma strips); per-line rate by unit price (apparel, hotels); weighing-scale input; challan and ageing tracker (job work, van sales, jewellery karigar); fund or project dimension (NGO, education, construction, which Progen already has as projects); document expiry reminders (licences, fleet, FSSAI, drug licence, FCRA).

## PART B. User pain points

Method and caveat: searches reached review aggregators (Capterra, G2, Software Advice, Techjockey), vendor comparison pages, and a few complaint boards. No Reddit threads, CA-forum threads, Play Store or App Store review pages, or YouTube comments were reached, so "how common" is a qualitative label from the number of independent reviews that mention the theme, not a measured rate. Vendor pages are biased and are labelled. Treat each row as a hypothesis to validate with a short customer survey, and see the ratings caution at the end.

| # | Pain | Products named | How common (qualitative) | Source | Progen fix |
| --- | --- | --- | --- | --- | --- |
| 1 | No true offline mode, or offline works but sync conflicts are unclear. Cloud-only tools stop working with a bad connection. | Zoho Books (no offline); Vyapar (offline, sync edge cases) | Frequent for cloud tools; occasional for hybrid | https://vyaparapp.in/comparison-with-other-apps?brand=zoho (vendor claim); https://profitbooks.net/vyapar-review/ | Offline-first mobile and POS with a local queue; visible sync state per document; clear conflict rule (server number series, last-writer on master data, merge on lines); a "pending to sync" screen. |
| 2 | Data loss or mismatch after a crash or reinstall, and terms that put the loss on the user. | Vyapar | Occasional but severe | https://www.softwareadvice.com/accounting/vyapar-profile/reviews; https://www.capterra.com/p/180579/Vyapar/reviews/ | Automatic cloud backup with point-in-time restore, per-tenant export any time, and a daily "backup healthy" status. Never rely on the phone as the only copy. |
| 3 | Support is slow, scripted or rude; long calls without a fix. | Vyapar, Marg, Tally (partner access complaint), Busy (support rating 3.9 of 5) | Frequent | https://www.capterra.com/p/180579/Vyapar/reviews/; https://www.consumercomplaints.in/tally-solutions-tally-prime-c3468492; https://www.capterra.com/p/71449/Busy-Accounting-Software/reviews/ | In-app support chat that attaches a diagnostic bundle (version, last errors, company ID); named SLA; WhatsApp support; and a public status page. |
| 4 | Pricing: price rises, features moving behind paid plans, user-count limits, annual renewals for desktop versions. | myBillBook, Zoho Books (user limits), Tally (licence and renewal) | Frequent | https://www.capterra.com/p/202732/FloBooks/reviews/ (the page is listed under a FloBooks URL, so the product match is **UNVERIFIED**); https://www.techjockey.com/reviews/mybillbook-accounting-software; Tally pricing from https://www.techjockey.com/reviews/tally-erp-9 (older figures) | Flat per-business price with unlimited users and locations, no feature removal for existing customers, 12-month price lock written into the plan. |
| 5 | Mobile app and web app behave differently; mobile is weak for accountants, and Tally and Marg are desktop-only. | myBillBook, Tally, Marg, Busy | Frequent | https://www.softwareadvice.com.au/software/246387/flobooks; https://www.techjockey.com/reviews/margerp-9; https://www.capterra.com/p/71449/Busy-Accounting-Software/reviews/ | One API and one feature set: every web feature is available on mobile (or clearly marked "web only"), with a tablet layout. Responsive for the CA and the owner on the same account. |
| 6 | Remote and multi-user: the accountant in another city cannot work on live data; the cloud or Tally.NET lags; multi-user licences cost extra. | Tally, Marg, Busy | Frequent | https://hisabkitab.co/top-7-problems-tally-users-face-solved-by-tally-connector (vendor); https://g2.com/products/tallyprime/reviews | Native multi-user with role and location scopes (already in core). Invite a CA as an external role with read or limited edit and an audit log of what they changed. |
| 7 | Bank reconciliation is slow at volume; feeds miss or delay transactions; reconciliation tools are thin. | Zoho Books | Frequent in global reviews, thin India data | https://www.capterra.in/reviews/134507/zoho-books; https://capterra.com/p/163115/Zoho-Books/reviews/?page=2 | Statement import (CSV, PDF, bank-feed later) with auto-match rules by reference, amount and date; bulk accept; learned rules for repeat payees; a UPI and settlement-ID matcher. |
| 8 | GST reconciliation: GSTR-2B versus purchase books; report generation slow or complex in newer Tally. | Tally Prime | Frequent for every product; users do this monthly | https://softwarefinder.com/accounting-software/tally-prime/reviews; https://www.capterra.com/p/127762/Tally-ERP-9/reviews | 2B import with invoice-level matching (exact, fuzzy, tolerance), supplier-wise mismatch list, ITC-at-risk number, and a "hold payment to non-filer" flag; pre-filing 3B vs books vs 1 check. |
| 9 | Reports are slow on large data, and slow in Busy ("feels a bit slow"). | Busy, Tally Prime | Occasional | https://www.techjockey.com/reviews/busy-accounting-software; https://softwarefinder.com/accounting-software/tally-prime/reviews | Server-side aggregates and indexed ledgers; report budget under 3 seconds on 1 lakh vouchers; background-build with "last updated" stamp for heavy reports; export to Excel. |
| 10 | Migration from Tally and others is lossy: data not compatible with other software, masters and opening balances mismatch. | Tally to anything | Frequent at onboarding | https://softwarefinder.com/accounting-software/tally-prime/reviews (compatibility remark); spec already lists importers, so the gap is in validation | Importer with a dry run, a trial-balance tie-out report (old vs new by ledger), unmatched-ledger mapping screen, and a side-by-side parallel-run mode for one month. |
| 11 | WhatsApp sharing is manual or missing; no payment link, no reminder automation. | Most desktop tools | Frequent as a feature request; **UNVERIFIED** from reviews | Not retrieved; the user base for Vyapar and myBillBook values WhatsApp invoicing (vendor pages) | One-tap invoice PDF and payment link on WhatsApp Business API; scheduled dues reminders with a polite escalation ladder; delivery and read status on the invoice. |
| 12 | Regional languages: English-only interface, invoices and print templates; hard for non-English accountants. | Tally ("non-English environments") | Occasional to frequent in tier-2 and tier-3 cities | https://softwarefinder.com/accounting-software/tally-prime/reviews | UI and invoice print in Hindi, Marathi, Gujarati, Tamil, Telugu, Kannada, Bengali; transliterated item names; voice-to-entry later. |
| 13 | Complexity and learning curve for small businesses: Marg "too advanced"; Busy and Zoho Books "difficult to access"; Odoo setup needs a partner. | Marg, Busy, Zoho Books, Odoo | Frequent | https://www.techjockey.com/reviews/margerp-9; https://g2.com/products/zoho-books/reviews; https://www.itechguides.com/fix-common-gst-and-e-invoicing-errors-in-odoo/ (Odoo e-invoice failures traced to setup, not bugs) | Guided first-run by industry template (pre-set items, GST, voucher series); progressive disclosure so a shopkeeper sees five menus and an accountant sees fifty; setup health-check (GST credentials, e-invoice, series). |
| 14 | Limited template and report customisation: invoice templates, missing basics (for example GST-number cash invoice in Busy). | myBillBook, Busy | Occasional | https://www.techjockey.com/reviews/mybillbook-accounting-software; https://www.capterra.com/p/71449/Busy-Accounting-Software/reviews/ | Template editor with live preview, per-document-type layouts, and a library of Indian formats (GST tax invoice, bill of supply, delivery challan, quotation, thermal 2/3 inch). Custom fields on any document without code. |
| 15 | Audit trail and controls: who edited or deleted a voucher, back-dated entries, period locks; users report trust issues when data silently changes. | Tally (edit log is optional), Vyapar (fixed roles) | Occasional in reviews; frequent in CA discussion, **UNVERIFIED** | Not retrieved from a primary source; spec notes Vyapar's roles are fixed | Always-on, tamper-evident audit log (who, when, before, after); period lock with a controlled unlock; delete becomes reversal for numbered documents; approval workflows by amount. |

Notes on reading Part B:
- Odoo India: no independent user complaint data was found. Odoo's own documentation shows e-invoicing needs NIC credentials entered and a journal option enabled, and a third-party guide says most failures come from configuration (https://www.odoo.com/documentation/17.0/applications/finance/fiscal_localizations/india.html). The pain "needs a partner and weeks to set up" is a hypothesis, **UNVERIFIED**.
- Zoho Books: reviewers also say its India GST compliance is strong; Progen should not claim to beat it there.
- Ratings are mixed and sites disagree (Marg scored 3.2 on Software Advice and 4.7 on Techjockey; Busy 4.2 on Capterra with support the lowest category). Sample sizes are small.

## Quick wins for the core (prioritised)

Each item helps every industry above and is small relative to a vertical pack.

| Rank | Quick win | Why it matters | Pain # | Effort |
| --- | --- | --- | --- | --- |
| 1 | Offline-first billing with a visible sync queue and deterministic conflict rules | Retail, field sales, restaurants and transport all work with weak connectivity; the biggest churn risk. | 1, 5 | Large |
| 2 | Automatic cloud backup, per-tenant export, point-in-time restore | One data-loss story kills trust; cheap to add on a Postgres stack. | 2 | Small |
| 3 | GSTR-2B reconciliation with ITC-at-risk and "supplier not filed" flag | Every GST-registered user does this monthly; Tally's weak spot. | 8 | Medium |
| 4 | Bank statement import with auto-match and bulk accept, including UPI settlement matching | Every business has a bank; reconciliation is where hours go. | 7 | Medium |
| 5 | WhatsApp invoice, payment link and dues reminders | Highest daily value for small traders and professionals. | 11 | Small to medium |
| 6 | Importer validation: dry run, trial-balance tie-out, parallel-run mode | The first week decides whether a Tally user switches. | 10 | Medium |
| 7 | Always-on audit log, period lock, delete-as-reversal | A CA and a business owner both ask for this on day one. | 15 | Small |
| 8 | Batch, expiry and per-line price rules as core item features (including rate-by-unit-price) | Unlocks pharma, food, apparel, hotels and agri inputs without separate packs. | Section 0 | Medium |
| 9 | Industry templates at setup, plus a setup health check (GST, e-invoice, series, licences) | Cuts the learning curve and support tickets across all verticals. | 13 | Small |
| 10 | Licence and document expiry reminders (drug, FSSAI, FCRA, fleet papers, hallmark, Legal Metrology) | One engine serves many verticals; low effort and strong compliance value. | Section 0 | Small |

Also worth doing soon but not in the top ten: regional-language invoice print (pain 12), flat unlimited-user pricing (pain 4), and a reports performance budget (pain 9).

## Open questions to verify before building

1. Exact GST notification texts and rates after 22 Sep 2025: hotel rooms (ITC or not), restaurant specified premises, GTA, medicines, apparel threshold, auto and spare parts.
2. Section numbers in the Income-tax Act 2025 for: cash receipt limit (s.186 or s.221), motor vehicle TCS, jewellery cash TCS, 80G and 12A equivalents (s.354, s.332), and donation statement rules in the Income-tax Rules 2026.
3. ITC-04 frequency and due dates, and the 1-year and 3-year job-work return rule, from the CGST Act and Rules text.
4. GTA annual declaration date and form.
5. Drugs Rules 1945 Schedule H and H1 register fields and retention period; current NPPA ceiling list.
6. ABDM current integration requirements and whether incentives still run.
7. FCRA current rules: SBI New Delhi account, 20% cap, FC-4 due date.
8. Customer interviews to turn the qualitative "how common" labels in Part B into real frequencies; Play Store and App Store review mining (not reached here).
