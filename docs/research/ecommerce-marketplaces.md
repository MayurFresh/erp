# E-commerce pack: selling through marketplaces (GST, income tax, settlements, listings)

DRAFT. First-pass research from about 12 web searches, as of 29 Oct 2026, for the E-commerce pack. WebFetch of primary pages was not used, so almost every figure below comes from secondary sources or search snippets. Anything not confirmed from a primary source is marked **UNVERIFIED**. Marketplace fee tables change every few months, so every fee rate in this note is a default for tests, never a hard-coded rule. Column names of settlement reports were not available from any official page; they are taken from third-party reconciliation guides and must be checked against a real downloaded report.

Status: research for the E-commerce pack, not started in code.

Source quality legend:
- (P) primary: official government or marketplace page, or the Act text.
- (S) secondary: tax-portal commentary, vendor blogs, search snippets.

## How to read the rate notes

- GST rates were rationalised from 22 Sep 2025 (broadly 5% and 18%, with 40% for sin and luxury goods). The old 12% and 28% slabs are gone for most goods. Item-level rates (for example apparel) depend on the item and price. The apparel split (5% up to ₹2,500 per piece, 18% above) is from secondary sources and is **UNVERIFIED**. Progen must keep rate per HSN and per date in a table and never infer rate from the old list.
- Income-tax references use the Income-tax Act 2025 section, with the old number in brackets, as in contractor-billing.md.
- incometaxindia.gov.in returned errors to automated fetch in the earlier note, so Act text could not be opened directly here either.

## 1. GST for sellers on marketplaces

### 1.1 TCS under s.52 CGST Act

| Item | Rule | Source |
| --- | --- | --- |
| Who collects | The e-commerce operator (ECO) that owns, operates or manages the digital platform, from the supplier, on supplies of goods or services made through the platform where the ECO collects consideration | CGST Act s.52(1) (P, text not opened); search summary (S) |
| Rate | 0.5% from 10 Jul 2024 (0.25% CGST + 0.25% SGST for intra-state, 0.5% IGST for inter-state). Earlier 1% (0.5% + 0.5%) from 1 Oct 2018. | Notification 15/2024-Central Tax, after the 53rd GST Council meeting (S). One source dated it 10.06.2024; most say 10.07.2024. Treat 10 Jul 2024 as likely but **UNVERIFIED** against the Gazette. |
| Base | "Net value of taxable supplies": aggregate taxable supplies made through the ECO in the month by the supplier, minus taxable supplies returned to the supplier, minus supplies where the ECO itself pays tax under s.9(5). Excludes GST. Computed per supplier GSTIN. | s.52(1) Explanation (S) |
| Timing | ECO pays the TCS to the government by the 10th of the next month (s.52(3)) and files GSTR-8 by the 10th of the next month (s.52(4)). | (S) |
| Annual statement | ECO files an annual statement (s.52(5)) by 31 Dec following the year. Not needed in Progen. | (S) **UNVERIFIED** date |
| Credit to the seller | The ECO's GSTR-8 populates the seller's view (GSTR-2A, and the TCS lines of GSTR-2B). The credit goes to the seller's electronic cash ledger (s.52(9) read with Rule 67), after the seller can accept or reject details. The seller then uses cash-ledger balance to pay output tax in GSTR-3B. | (S) mechanics **UNVERIFIED** |
| Seller still reports the gross | The seller's GSTR-1 shows the full sale (invoice value). TCS does not reduce the seller's liability on the invoice; it is a prepayment. The seller reports supplies made through ECO in GSTR-1 Table 14 / 15 (supplies through ECO, split by ECO GSTIN). | (S) **UNVERIFIED** table numbers |
| Seller's return of goods | Customer returns reduce the "net value" in the month of the credit note. If returns exceed supplies in a month, the net can be negative and the ECO adjusts in later months. | (S) **UNVERIFIED** carry-forward detail |

Key behaviours for Progen:
- TCS is not an expense and not input tax credit. It is a **receivable from the tax department**, to be matched to GSTR-8 and then used against GST liability.
- The TCS base is not the marketplace's gross collection. It is taxable value net of returns. A marketplace statement showing TCS on the invoice value including tax should be checked, not trusted.
- A COD sale, where a courier collects cash, is within s.52 only if the ECO "collects" consideration. How marketplaces treat COD is **UNVERIFIED**. In practice Amazon, Flipkart and Meesho show TCS on all orders.

### 1.2 Supplies where the ECO pays tax under s.9(5)

- s.9(5): on notified services supplied through an ECO, the ECO (not the supplier) pays the GST, as if the ECO were the supplier. Notification 17/2017-Central Tax (Rate), 28 Jun 2017, as amended (S for the existence; the list was not retrieved).
- Services I believe are notified: passenger transport by motor cab / radio taxi, accommodation in hotels and similar (where the hotel is not registered), housekeeping, and restaurant services. Local delivery services (supplied by delivery persons through an ECO) were added from the 2025 rate rationalisation. All of these are **UNVERIFIED**; they are services, not goods.
- **Goods are never under s.9(5).** For a seller of goods on Amazon, Flipkart or Meesho, the seller is the supplier and issues the tax invoice.
- Progen should hold a per-listing flag "ECO liable under s.9(5)" (default false), because a seller of services (for example a cab or hotel operator) falls outside the goods flow and is out of scope for v1.
- Where 9(5) applies, the seller does not need registration for that supply (s.24(ix) carves out s.9(5) services, per a secondary source). Excluded from the TCS base.

### 1.3 Composition dealers and unregistered sellers

- **Unregistered sellers.** s.24(ix) CGST Act requires registration of persons supplying goods through an ECO that collects TCS, whatever their turnover. The ₹40 lakh (goods) threshold exemption is not available. Sources agree (S). The earlier carve-out for intra-state goods sellers (Notification 7/2019 style relief for small suppliers) does not apply once an ECO collecting TCS is involved. **UNVERIFIED** against the Act text.
- **Composition dealers.** s.10(2)(d) bars composition for persons supplying goods through an ECO. Notification 36/2023-Central Tax (4 Jul 2023) is reported to let composition suppliers sell goods **intra-state only** through ECOs, with TCS collected, and the ECO must not allow inter-state supplies by them. **UNVERIFIED**: only a secondary source, not the notification. Progen must treat both rules as hard guardrails (Section 8.6).
- **Services sellers** (non-9(5)) on an ECO are also barred from the threshold exemption (S).
- **The ECO itself** must register in every state it operates in, whatever its turnover (s.24(x)) (S). Not relevant to a seller.
- Progen should not allow a composition-scheme company to create a channel with inter-state delivery. See guardrails.

### 1.4 Warehouses in other states (FBA, Flipkart Fulfilment, Meesho warehouses)

- GST registration is state-wise. A seller who stores stock in a marketplace warehouse in a state other than where it is registered needs a registration in that state (s.25(1), s.22(1)), with the warehouse declared as the principal or an additional place of business there. Amazon and Flipkart seller help pages say the same: the seller must hold a GSTIN in every state where inventory is stored (P, pages not opened). **UNVERIFIED**.
- "Additional place of business" is the correct field within one state. For a new state, it is a separate GSTIN (a separate registration of the same PAN), not an extra place under the old GSTIN. Nominated goods may be held in the home state's additional place if the warehouse is within the home state.
- Without a registration in the warehouse state, the transfer is a violation; goods may be detained. Penalty exposure is not researched.
- Progen needs `gstin` per place of business and a mapping from channel warehouse to our location and GSTIN. The product's existing company/locations model is a natural fit (the existing locations feature).

### 1.5 Stock transfers to marketplace warehouses

- A transfer to own warehouse in another state under a different GSTIN is a supply between "distinct persons" (s.25(4) CGST Act, Schedule I entry 2: supply of goods without consideration between related or distinct persons in the course of business). It is taxable. Between states: IGST. The sender issues a tax invoice (not a delivery challan) at cost or open-market value (Rule 28, valuation among related persons) (S, from memory of the Act). **UNVERIFIED**.
- E-way bill (Rule 138 CGST Rules): needed for consignment value above ₹50,000 inter-state. The marketplace's inbound shipment (FBA "Send to Amazon") plan generates the stock transfer details; sellers often generate the invoice and e-way bill themselves. See docs/research/gst-einvoice-ewaybill.md for the e-way bill rules already researched; do not duplicate.
- The receiving GSTIN takes input tax credit (IGST) on the transfer. The seller's later B2C sale from that warehouse is then intra-state or inter-state based on the customer's state, not the origin state.
- The same-state transfer to a warehouse under the same GSTIN is not a supply. Under a different GSTIN in the same state (rare) it would be a supply.
- No GST on stock moving between marketplace fulfilment centres of the same seller, if both are covered by the same state GSTIN. Between states, a new transfer invoice every time (marketplaces sometimes do inter-FC balancing; the seller must raise invoices). **UNVERIFIED**.

### 1.6 Place of supply for B2C online sales

- Goods supplied online to a consumer: place of supply is where the goods are delivered, i.e. the customer's delivery state (s.10(1)(a) IGST Act). If the origin state (the supplying warehouse GSTIN's state) differs, it is inter-state: IGST. If same state: CGST + SGST.
- With FBA, the origin is the warehouse state, not the seller's head-office state. So Progen must determine origin by fulfilment location.
- B2C invoices on marketplaces are issued by the seller (or on seller's behalf by the marketplace). Dynamic QR code is not mandatory for online sales.
- B2C inter-state supply to unregistered buyers is subject to IGST regardless of invoice value (no ₹2.5 lakh B2CL threshold for reporting; this affects GSTR-1 only). **UNVERIFIED** current reporting thresholds.
- E-invoicing: B2C is exempt from e-invoice IRN, but if the seller sells B2B on the marketplace (GST invoice with buyer GSTIN) and turnover is above the e-invoice threshold, the IRN applies. Thresholds are covered in docs/research/gst-einvoice-ewaybill.md.

### 1.7 Credit notes for returns

- s.34 CGST Act: the supplier may issue a credit note for a return or price reduction. The time limit to issue it, and to reduce the output tax, is 30 November following the end of the financial year in which the original invoice was issued, or the date of the annual return, whichever is earlier (s.34(2)). (S, widely cited since the 2022 amendment; not verified against the text.) The GST on the credit note reduces output tax only if the recipient's ITC is reversed (not relevant for B2C).
- For marketplace sales, the return is recognised when the item is received back (in the marketplace warehouse or at the seller's). The credit note date should be that date or the date the marketplace refunds the customer. A consistent rule is needed: Progen should use the date the return is *received* or the refund is confirmed, whichever the marketplace report shows first, and let the user edit.
- GSTR-1: the credit note is shown in the "credit/debit notes (unregistered)" table; supplies through ECO are in a separate table keyed by the ECO's GSTIN.
- TCS adjustment: the ECO reduces the next GSTR-8's net value by the returned supply's value. The seller's TCS receivable then reduces to match. A return in a later month produces a **negative** TCS line in a later settlement or a smaller credit in GSTR-8.
- An RTO (customer never received it) is not a "return" under s.34 in the strict sense, but is booked as a cancelled supply: if the invoice was issued, a credit note is required, because tax was paid on a supply that did not complete; if no invoice was issued (dispatch not completed), no GST event. **UNVERIFIED**, practice varies. Progen should issue the invoice at dispatch and a credit note on RTO receipt.

## 2. Income tax

### 2.1 TDS by e-commerce operators (old s.194-O)

- Provision: s.393(1) Table Sl. No. 8(v) of the Income-tax Act 2025 (old s.194-O) (S: taxtmi, tdsman, taxgarden blogs). Not opened from the Act itself.
- Who: an e-commerce operator paying an "e-commerce participant" (the seller) for sale of goods or provision of services facilitated through the platform. Deducted at the **earlier of credit to the participant's account or payment**, including credit in a separate account of the ECO.
- Rate: **0.1%** from 1 Oct 2024 (was 1%; Union Budget July 2024 cut, effective 1 Oct 2024). Continues for FY 2026-27 under the 2025 Act (S).
- Base: the **gross amount** of sales or services of the participant facilitated through the platform, including amounts the ECO pays on the participant's behalf, such as courier or payment gateway charges collected by the ECO. The ECO deducts on the gross, not on the amount after marketplace fees.
- Whether GST is included in the gross: CBDT Circular 17/2020 (29 Sep 2020) is the normal reference; I believe it says the base is the gross amount including GST (i.e. unlike contractors under Circular 23/2017). **UNVERIFIED**; Progen should store the TDS base as reported in the settlement report and not recompute it. The worked example in Section 4 uses GST-inclusive and notes the alternative.
- **Small participant exemption:** an individual or HUF participant whose gross sales or services through the ECO in the tax year do not exceed ₹5,00,000, and who has given PAN or Aadhaar to the ECO, is not subject to TDS. This was s.194-O(2); the 2025 Act carries it into s.393(4) Table Sl. No. 11 (S: taxtmi comparison). One secondary source says no threshold survives. The conditions, especially "individual or HUF only", are **UNVERIFIED** against the Act. A company or LLP seller is never exempt.
- **No PAN or Aadhaar:** the old rule was 5% under s.206AA(1) (the 20% floor does not apply to 194-O). Under the 2025 Act the corresponding section is either s.397(2) or s.394A depending on source (contractor-billing.md says s.397(2)(b)(i); one search result said s.394A). The rate is **UNVERIFIED**.
- The ECO's deduction overrides other TDS sections on the same payment: no deduction under 194C, 194H, 194J etc. on the amount on which 194-O was deducted (old s.194-O(4), the non-obstante clause). The marketplace's fees charged to the seller are a separate matter (Section 2.3).
- Credit to the seller: the seller sees TDS in Form 26AS / AIS, and claims it in the income-tax return for the year. It is a **receivable from the tax department**, to be adjusted against income-tax or advance tax. The seller does not get an immediate cash credit as with TCS. Under the 2025 Act the certificate is Form 131 (Rule 215) (from contractor-billing.md), and statements are Form 140; the seller does not file these, but sees them in the TDS credit statement.
- Quarterly TDS return and certificate are the ECO's duty; the seller should reconcile its books to AIS after the quarter's due date (31 Jul, 31 Oct, 31 Jan, 31 May).

### 2.2 Interplay with TDS on purchase of goods (old 194Q) and TCS on sale of goods (old 206C(1H))

- **Old s.194Q (buyer TDS of 0.1% on purchases of goods above ₹50 lakh from a resident seller in a year):** does not apply to transactions where 194-O applies (194Q proviso: not where TDS is deductible under any other provision, and not where TCS under 206C other than 206C(1H) applies). So for a seller's marketplace sales, the ECO deducts 194-O, not 194Q. But where a **seller** buys stock above ₹50 lakh from a supplier (a manufacturer or wholesaler), the 194Q rule applies to that purchase. Progen's buyer-side TDS is separate. (S; **UNVERIFIED** under 2025 section numbers.)
- **Old s.206C(1H) (seller TCS of 0.1% on sale of goods above ₹50 lakh):** Budget 2025 removed this with effect from 1 Apr 2025, as I recall (**UNVERIFIED**; not confirmed here). If still in force for any year, it never overlapped with 194-O (a sale already subject to 194-O has no TCS under 206C(1H)).
- The marketplace-side result for a seller: no TCS on sale (income-tax), TDS 0.1% from the ECO, GST TCS 0.5% from the ECO.
- Progen's guardrail: do not deduct TDS or collect TCS on marketplace-routed sales; these are on the ECO. Only direct B2B sales fall into the usual rules.

### 2.3 Fees paid by the seller to the marketplace

- Whether the seller must deduct TDS (194H, 194C, 194J equivalents) on commission, shipping and ad fees paid to Amazon, Flipkart, Meesho is a point where practice differs. Many sellers do not deduct. **UNVERIFIED**; needs an advisor's view. Progen should not auto-deduct; a switch is provided per channel. Ads are usually billed separately (Amazon Ads has its own invoice).
- GST on those fees: input tax credit available if the seller is registered and holds the marketplace's tax invoice with the seller's GSTIN (Section 3).
- Reverse charge does not apply to marketplace fees from an Indian ECO. For Shopify (foreign), see Section 3.5.

## 3. Fee and settlement structures

All rates below are for test and illustration only. The marketplace fee pages are the only source; none was opened. Amazon.in states its listed fees exclude GST and 18% GST is applied on them (S: sell.amazon.in fee schedule listing, indiaretailing). Rates change by category and price band.

### 3.1 Amazon.in

Fee heads (S: Amazon fee schedule snippets, third-party guides):

| Fee | How charged | Notes |
| --- | --- | --- |
| Referral fee | A percentage of the selling price, by category and price band | Percentage on the price **including GST and shipping charge** is the usual statement. Confirm. **UNVERIFIED** |
| Closing fee | A fixed amount per unit, depending on price band and fulfilment (FBA, Easy Ship, self-ship). Starts about ₹5 on low-priced items. | Charged per order line |
| Weight handling fee | FBA and Easy Ship only. Slab by weight and zone (local, regional, national, special). Self-ship sellers pay their own courier. | |
| FBA fees | Pick and pack, storage (monthly, per cubic foot, with long-term storage surcharge), removal and disposal fees, return processing fee | **UNVERIFIED** current slabs |
| Ads (sponsored products etc.) | Billed separately, per click, with its own invoice | Not netted in the settlement report as a rule. **UNVERIFIED** |
| GST | 18% on all of the above | Invoiced by Amazon Seller Services Pvt Ltd, per-state GSTIN of the Amazon entity that provides the service |
| TCS (GST) | 0.5% of net taxable value | A separate line |
| TDS (income tax) | 0.1% of gross | A separate line |
| Technology or other fees | Amazon has added and removed fees (for example a 2024 fee revision reported by trade press) | Do not assume any list is complete |

Settlement report: download from Seller Central, Reports, Payments (S). Third-party reconciliation guides say a row's net equals "sale price minus fees". The columns below are reported by third parties and **UNVERIFIED** (check a real "Date Range Report" or "All Statements" file):

- Identifiers: settlement-id, settlement-start-date, settlement-end-date, deposit-date, total-amount, currency.
- Order level: order-id, merchant-order-id, adjustment-id, shipment-id, marketplace-name, amount-type, amount-description, amount, fulfillment-id, posted-date, posted-date-time, order-item-code, merchant-order-item-id, merchant-adjustment-item-id, sku, quantity-purchased, promotion-id.
- `amount-type` / `amount-description` pairs include Principal, Tax, Shipping, ItemFees (Commission, FixedClosingFee, FBA weight handling), ItemWithheldTax (TCS-CGST, TCS-SGST, TCS-IGST, TDS), and Refund lines. These names are from the global settlement report format and may differ in India. **UNVERIFIED**.
- Progen should store the raw rows verbatim (`raw_json`) and map `amount-description` through a configurable alias table.

### 3.2 Flipkart

Fee heads (S: Flipkart Seller Hub fees page snippet, auperator knowledge base, shiprocket, others):

| Fee | Notes |
| --- | --- |
| Commission fee | A percentage of the selling price, by category and price band. Has a "commission fee waiver" column when a promotion applies. |
| Fixed fee | A flat amount per item by price band; generally not charged on returns. Has a waiver column. |
| Collection fee | Payment collection charge, differing for prepaid and COD (one source: 2.0% prepaid and 2.5% COD; **UNVERIFIED**). Has a waiver column. |
| Shipping fee | By weight slab and zone (local, zonal, national). Flipkart collects it from the seller even on Flipkart-shipped orders. |
| Reverse shipping fee | On customer returns and RTO, by chargeable weight and zone |
| Pick-and-pack, storage (Flipkart Fulfilment) | Listed by third-party sources only |
| GST | 18% on the fees (S: shiprocket says GST applies on commission, fixed fee and shipping) |
| TCS and TDS | Shown as separate deductions. A source saying "1% TCS and 1% TDS" is out of date or wrong; use 0.5% and 0.1% |

Payment (settlement) reports: Seller Hub, Payments, with a payment report per deposit (S). Third-party descriptions list paired columns (commission, commission waiver, collection fee, collection waiver, fixed fee, fixed waiver, shipping fee, reverse shipping fee, pick-and-pack fee), taxes, TCS, TDS, "settlement value" and "bank settlement value". Exact headers **UNVERIFIED**. Failed or reversed fees are reported in later cycles (auperator KB title: "Reconciling failed fees"); Progen needs a per-fee reversal model.

### 3.3 Meesho

Sources are all third-party and they conflict. Treat everything as **UNVERIFIED**.

- Commission: reported as 0% for most categories (the "zero commission" model).
- Shipping: charged to the seller and deducted at settlement, by weight slab and zone. Reported range ₹35 to ₹100 per order. Return shipping is charged on returns; RTO treatment is disputed between sources (one says Meesho bears it, others say it is deducted).
- GST: 18% on Meesho's shipping and platform charges.
- TCS 0.5% and TDS 0.1% as per law. One source says TCS is 1%, which is outdated.
- Settlement cycle: weekly, T+7 and T+15 all appear. The cycle is a per-channel setting, never a constant.
- A return-heavy week can give a negative settlement; the negative is carried to the next payout.
- Sellers may be unregistered for GST on Meesho: some sources say Meesho lets sellers without GST sell certain categories, which contradicts s.24(ix) unless the notified exemption applies. **UNVERIFIED**; Progen should not offer an "unregistered seller" path (Section 8.6).
- Payment sheet columns were not found in any source. Progen should rely on file import with a configurable mapping.

### 3.4 Common structure

Every marketplace settlement boils down to:

```
settlement payout = customer-paid amounts due to seller (sale + shipping recharge, incl. GST)
                  - fees (commission/referral, fixed/closing, collection, shipping, weight, FBA, ads)
                  - GST on fees
                  - TCS (GST, s.52)
                  - TDS (s.393 Sl. 8(v))
                  - refunds to customers (incl. their GST) + return fees
                  +/- reimbursements and adjustments (SAFE-T style, lost-in-transit, reserve)
                  - reserve held, + reserve released
```

Progen's settlement model must keep each of these as a line type with sign, the order or return it refers to (optional), and whether GST is included.

### 3.5 Shopify and payment gateways

- **Shopify store** is not an ECO: the seller sells its own goods on its own website. No s.52 TCS and no TDS under 194-O on these sales (Shopify does not pay the seller). GST invoice by the seller; place of supply by delivery state as in 1.6. Payment through a gateway.
- **Shopify subscription:** Shopify is a foreign provider, billed in USD. B2B recipient in India that is GST-registered: reverse charge (IGST by the recipient) on import of services, with input credit. Whether Shopify charges GST directly on India accounts is **UNVERIFIED**. Shopify Payments availability in India is **UNVERIFIED**; Indian stores generally use third-party gateways.
- **Razorpay:** the vendor's own blog says most domestic methods (cards, UPI, netbanking, wallets) are 2% + GST, and EMI, Amex, Diners, international cards about 3% + GST, with 18% GST applying only to the gateway's fee (P: razorpay.com blog, per search summary). Settlement T+2 business days for domestic standard (one comparison says T+1; Razorpay also offers instant settlement for an extra fee, 0.5% to 0.7% **UNVERIFIED**). UPI rate is negotiable and **UNVERIFIED**. Merchant discount rate (MDR) on RuPay debit and UPI is zero by RBI/government policy for banks, but gateways charge a platform fee; **UNVERIFIED**.
- **Cashfree:** figures disagree between sources (1.9% to 1.95% domestic cards plus GST, and a promotion of zero fee on first ₹20 lakh). **UNVERIFIED**, check the pricing page.
- **Settlement report from a gateway** (Razorpay "Settlements" and "Transactions" reports, **UNVERIFIED** headers) usually has: settlement id, settled at, payment id, order id, amount, fee, tax (GST on fee), debit/credit, net, UTR, plus refund and dispute rows. Fee and tax are separate columns. Progen should import these as settlement lines of type `gateway_fee` and `gateway_fee_gst`.
- GST on the gateway fee is an input credit for the seller, if the gateway's tax invoice carries the seller's GSTIN.
- Gateway fee is deducted from the payout, so the bank credit is lower than the order amount; the order shows a receivable from the gateway until settlement.
- On refunds, gateways usually do not return the original fee (**UNVERIFIED**). Keep as a cost.

### 3.6 COD remittance by couriers and aggregators

- For own-website or Shopify COD, a courier or an aggregator (Shiprocket, Delhivery, and similar) collects cash from the customer and remits to the seller after a delay. Typical remittance is T+2 to T+8 days (aggregators publish cycles; **UNVERIFIED**). A COD fee (a percentage, or a flat amount per order, whichever is higher) and 18% GST apply (S: unsourced).
- The courier's remittance file lists AWB, order id, COD amount collected, delivery date, COD charge, freight (forward and RTO), GST, remittance date, UTR. **UNVERIFIED** headers; reconciliation by AWB.
- Courier freight GST is 18% in general (the reduced 5% GTA option is a separate matter, **UNVERIFIED**). TDS under old 194C may apply to a seller paying freight beyond the thresholds (contractor-billing.md covers 194C). **UNVERIFIED** for this use.
- COD sale revenue is booked at dispatch (invoice date) with a receivable from the courier. It is not "cash in hand".
- RTO on COD: the courier charges forward and return freight; no cash is collected; the sale is reversed.

## 4. Worked example: ₹1,180 order on Amazon

All fee numbers here are **assumed for illustration**, not Amazon's real rates. Amount inclusive of 18% GST: taxable ₹1,000.00, GST ₹180.00. Seller and customer are in different states (IGST). FBA/Easy Ship, so Amazon ships.

Assumptions:
- Referral fee 8% of ₹1,180.00 = ₹94.40 (assumed; the base including GST is **UNVERIFIED**).
- Closing fee ₹20.00 (assumed).
- Weight handling fee ₹60.00 (assumed).
- GST at 18% on fees, rounded to the paisa per line group.
- TCS 0.5% of net taxable value ₹1,000.00.
- TDS 0.1% of gross ₹1,180.00 (GST included; **UNVERIFIED**; if the gross excludes GST, TDS is ₹1.00 and payout is ₹1.18 higher).

### 4.1 Calculations in paise

| Line | Paise | Rupees |
| --- | --- | --- |
| Customer paid (invoice value) | 118,000 | 1,180.00 |
| Taxable value | 100,000 | 1,000.00 |
| IGST 18% output | 18,000 | 180.00 |
| Referral fee (8% x 118,000) | 9,440 | 94.40 |
| Closing fee | 2,000 | 20.00 |
| Weight handling fee | 6,000 | 60.00 |
| Total fees before GST | 17,440 | 174.40 |
| GST 18% on fees (17,440 x 0.18 = 3,139.2, rounded) | 3,139 | 31.39 |
| TCS 0.5% x 100,000 | 500 | 5.00 |
| TDS 0.1% x 118,000 | 118 | 1.18 |
| Net payout (118,000 - 17,440 - 3,139 - 500 - 118) | 96,803 | 968.03 |

Check: 96,803 + 17,440 + 3,139 + 500 + 118 = 118,000.

Rounding: compute each fee line in paise with half-up rounding, sum, then compute GST on the sum or per line as the marketplace invoice does. A ±1 paisa difference should be accepted within a per-line tolerance of 1 paisa x number of lines.

### 4.2 Journal entries (simple account names)

At sale (on the invoice date, usually dispatch or shipment confirmation):

| Dr | Cr | Paise | Note |
| --- | --- | --- | --- |
| Amazon Receivable | | 118,000 | |
| | Sales | 100,000 | |
| | Output IGST | 18,000 | |

At settlement (when the report posts the order and the bank credit arrives):

| Dr | Cr | Paise |
| --- | --- | --- |
| Bank | | 96,803 |
| Marketplace Fees (referral, closing, weight) | | 17,440 |
| Input GST on Fees | | 3,139 |
| TCS Receivable | | 500 |
| TDS Receivable | | 118 |
| | Amazon Receivable | 118,000 |

Total debits 118,000 equal total credits 118,000.

Notes on timing: the sale entry is on the invoice date; the settlement entry is on the order's posting date in the report, or the deposit date when only a lump sum is known (then the order-level split goes through a clearing account "Amazon Clearing" and the bank entry through "Amazon Receivable" at deposit). Input GST on fees is claimable only if Amazon's fee invoice for the month shows the seller's GSTIN; book as claimable once matched, otherwise hold in a suspense line "Input GST pending". Hold-back reserves are a separate asset "Marketplace Reserve".

At GSTR-8 matching: Dr TCS Receivable is moved to "GST Cash Ledger" when the credit shows in the electronic cash ledger (a transfer, no P&L). TDS Receivable is moved to income-tax adjustments at year end.

### 4.3 Customer return (after settlement)

Assume the item is returned 20 days later. Assumed return terms (**UNVERIFIED**): referral fee refunded in full with its GST, closing and weight handling fees kept, reverse shipping ₹60.00 + 18% GST = ₹70.80, TCS reversed through the next GSTR-8, TDS not reversed.

Credit note (date of return received): reverse the sale.

| Dr | Cr | Paise |
| --- | --- | --- |
| Sales Returns | | 100,000 |
| Output IGST | | 18,000 |
| | Amazon Receivable | 118,000 |

At the settlement that carries the return (net clawback):

| Line | Paise |
| --- | --- |
| Refund to customer, clawed back | -118,000 |
| Referral fee refunded | +9,440 |
| GST on referral refund (9,440 x 0.18 = 1,699.2, rounded) | +1,699 |
| TCS reversed (credit) | +500 |
| Reverse shipping fee | -6,000 |
| GST on reverse shipping | -1,080 |
| Net settlement effect (deducted from the next payout) | -113,441 |

Entries:

| Dr | Cr | Paise |
| --- | --- | --- |
| Amazon Receivable | | 118,000 |
| Marketplace Fees (reverse shipping) | | 6,000 |
| Input GST on Fees | | 1,080 |
| | Marketplace Fees (referral refund) | 9,440 |
| | Input GST on Fees (ITC reversal) | 1,699 |
| | TCS Receivable | 500 |
| | Bank or Amazon Payable (clawback) | 113,441 |

Debits 125,080 equal credits 125,080.

Stock: move the item back from "In transit to marketplace" to "Returned (to be graded)", then to Sellable, Damaged, or Written off (Section 5). The cost of goods sold reverses only if the item goes back to sellable stock; otherwise the loss is charged on grading.

Credit note GST in GSTR-1 follows Section 1.7; the TCS credit reverses in GSTR-8 of the credit note month.

### 4.4 RTO case (order never delivered, before settlement)

Assume the customer refused delivery and the item came back. The prepaid amount is refunded to the customer by the marketplace, so nothing was ever paid out to the seller. Assumed terms (**UNVERIFIED**): referral fee and its GST refunded in full; closing fee ₹20.00, weight handling fee ₹60.00 and a return fee of ₹60.00 kept, plus 18% GST on them.

- Fees kept: 2,000 + 6,000 + 6,000 = 14,000 paise. GST 18% = 2,520 paise. The seller owes Amazon 16,520 paise (₹165.20), deducted from the next payout.
- No TCS or TDS is booked, because no payout was made for this order. If they were booked at order posting, reverse them when the return posts.
- The sale and its credit note net to zero.

Entries. The sale entry (Section 4.2) already debited Amazon Receivable 118,000. On RTO receipt, post the credit note and the kept fees together:

| Dr | Cr | Paise |
| --- | --- | --- |
| Sales Returns | | 100,000 |
| Output IGST | | 18,000 |
| Marketplace Fees | | 14,000 |
| Input GST on Fees | | 2,520 |
| | Amazon Receivable | 134,520 |

Debits 134,520 equal credits 134,520. Amazon Receivable ends at minus 16,520 (the seller owes Amazon), cleared by the next settlement.

Stock: the item returns to the seller (Easy Ship or self-ship RTO) or to the FC (FBA). Grade as in Section 5. Cost of goods sold reverses only when the item goes back to sellable stock.

## 5. Returns versus RTO accounting

| | Customer return | RTO (return to origin) |
| --- | --- | --- |
| What happened | The customer received it and sent it back | The customer never received it; the carrier returned it |
| GST | Credit note under s.34, within the time limit (Section 1.7) | Credit note, or cancel the invoice if possible before the e-way bill and GSTR-1 period (practice varies) |
| Revenue | Reversed at the credit note date | Reversed |
| Fees | Partly refunded; reverse shipping or return fee charged | Partly refunded; return fee charged |
| Stock | Return needs grading | Usually sealed and sellable, but still grade |
| Fraud risk | High (wrong or damaged item returned) | Low |

Stock grading (store as a status on the returned unit, with a reason):
1. **Received, ungraded** (quarantine, not in sellable stock).
2. **Sellable** (back to sellable stock at original cost; COGS reversed).
3. **Refurbishable** or **Open box** (moved to a different SKU or a lower-price listing; cost stays, with a possible write-down).
4. **Damaged or defective** (write off to "Returns Loss" at cost, or return to supplier or vendor if under warranty).
5. **Wrong item or missing** (claim from marketplace, Section 5.1).
6. **Disposed** (FBA removal or disposal; write off at cost; GST on written-off goods needs ITC reversal under s.17(5)(h) CGST). **UNVERIFIED** that this reversal applies to every write-off; confirm with the tax review.

Write-off entry: Dr Returns Loss (or Inventory Write-off), Cr Inventory at cost, and reverse input tax credit on the purchase cost if the goods are lost, destroyed or written off (s.17(5)(h), via GSTR-3B Table 4(B)(1)). Keep the ITC reversal as a flagged task, not an automatic journal.

### 5.1 Marketplace reimbursement claims

- **Amazon:** FBA reimbursements for lost, damaged inventory and for customer returns not received back within a window (the FBA policy page; windows and values **UNVERIFIED**). Reimbursement appears in the settlement report as a reimbursement row (amount-description varies). Claim by case when the system does not pay.
- **Flipkart SAFE-T:** the "Seller Asset Protection Fund (SAFE-T)" is Flipkart's claim programme for a seller to be compensated for loss or damage in returns (wrong, damaged or missing product) and for some lost shipments, with proof windows and a claim ticket. (S: general knowledge; Flipkart policy page was not opened; terms, claim window and payout caps are **UNVERIFIED**.)
- **Meesho:** claim mechanisms exist for wrong returns; details **UNVERIFIED**.
- **Accounting for a reimbursement:** it is not a sale. It is income or a recovery of loss. Dr Amazon Receivable or Bank, Cr "Marketplace Reimbursements" (or Cr "Returns Loss" to offset the loss). GST: compensation for loss is generally not a supply, so no output GST. **UNVERIFIED**; some reimbursements to cover the selling price of lost goods may be treated by the marketplace as a payment against the original sale. Model it with a configurable "treat as sale value" switch, default off.
- **Claim tracker:** a claim record linked to the return (order, SKU, qty, amount claimed, evidence refs, status, deadline, amount received). Alert before the deadline. Do not net automatically.

## 6. Listing compliance

### 6.1 Consumer Protection (E-Commerce) Rules 2020

Source: Department of Consumer Affairs notification of 23 Jul 2020 under the Consumer Protection Act 2019 (P, text not opened; summary from ksandk, ssrana and search snippets).

For a seller on a marketplace (Rule 6(5) and surrounding):
- Seller details shown to the consumer on the platform: legal name, principal geographic address, contact (email, phone), and the grievance officer's name, contact and designation. **Rule 6(5)(d)** (as quoted by one source) says the seller must give the platform the details the platform displays about the goods or services. The platform itself has its own obligations under Rule 4 (for example grievance officer, acknowledge within 48 hours and redress within one month; **UNVERIFIED** sub-rule numbers).
- Information on return, refund, exchange, warranty and guarantee, delivery and shipment, modes of payment and grievance redressal, in the listing.
- Country of origin on the listing (a Rule 4(?) requirement on the platform, with the seller supplying the data; **UNVERIFIED** rule number).
- Expiry date or best-before for goods where relevant.
- No unfair trade practice, no false representation, and refunds to follow the stated policy.
- Platform may require the seller to confirm the details at registration. A seller should keep a record of customer complaints and the grievance outcome. Own-website sellers (Shopify) are "inventory e-commerce entities" with their own Rule 5 duties (the same set plus the seller-level disclosures). **UNVERIFIED** split.

### 6.2 Legal Metrology (Packaged Commodities) Rules 2011

- Declarations a label must carry (Rule 6(1)): name and address of the manufacturer, packer or importer; common or generic name of the commodity; net quantity (with standard units); month and year of manufacture, packing or import; **maximum retail price (MRP) inclusive of all taxes**, as "MRP Rs. ... (inclusive of all taxes)"; consumer care details (name, address, phone, email); country of origin for imported goods, and a country-of-origin declaration also required for e-commerce (see below); dimensions, and similar for specific categories; best-before or expiry for food and drugs.
- **Unit sale price:** the rules require a unit sale price (price per standard unit, for example per kg or per metre) for certain pre-packed commodities, mainly where net quantity is declared in non-standard or multiple-piece packs. The exact scope after the 2017 and 2018 amendments could not be confirmed from the search results. **UNVERIFIED**; keep as an optional field with a category-level required flag.
- **E-commerce rule:** Rule 6(10) (per the Delhi High Court filing quoted in a search result; one secondary source says Rule 10) requires an e-commerce entity to display the mandatory declarations on the digital network before purchase, and the ECO relies on the seller for the data. Country of origin must appear on the listing (Consumer Affairs notification of 2017, with a 2018 amendment adding the e-commerce angle; dates conflict in sources).
- A 2026 amendment inserting Rule 6(10A), reported in an article dated 26 Aug 2026, appears to be deferred to 1 Jul 2027 by a later amendment. **UNVERIFIED**; the item is a watch item, not a build item.
- CCPA and the Legal Metrology department coordinate enforcement, so the penalty exposure is real (S).
- Other regulators are out of scope: FSSAI (food listings), BIS (compulsory registration marks), the Drugs and Cosmetics Act, and Weights and Measures for loose goods.

### 6.3 Dark patterns (CCPA guidelines, 2023)

- Guidelines for Prevention and Regulation of Dark Patterns, 2023, notified by the Central Consumer Protection Authority on 30 Nov 2023, under the Consumer Protection Act 2019 (P: the notification; text not opened here; the 13 listed patterns are from my knowledge).
- The 13 specified patterns: false urgency, basket sneaking, confirm shaming, forced action, subscription trap, interface interference, bait and switch, drip pricing, disguised advertisement, nagging, trick question, SaaS billing, and rogue malwares. **UNVERIFIED** against the Gazette text.
- Applies to all platforms, sellers and advertisers. For a seller's catalogue, the relevant ones are: drip pricing (the price shown must be the total payable, including shipping and handling fees, with no surprise add-ons), false urgency ("only 2 left" must be true), bait and switch, basket sneaking (no pre-added items or fees), and disguised ads (sponsored listings must be labelled).
- Subsequent CCPA directions asking platforms for self-audits in 2025 are **UNVERIFIED**.
- For Progen this is mostly a content and process matter. The data model only needs to avoid creating the patterns (for example showing a fee not in the displayed price).

### 6.4 What the seller's listing master must hold

Per listing (SKU on a channel) and per item master:

| Field | Reason |
| --- | --- |
| Item name, generic or common name | Legal Metrology |
| Net quantity and unit; number of pieces | Legal Metrology |
| MRP including taxes (paise) | Legal Metrology, price must not exceed MRP |
| Selling price (paise), whether GST-inclusive | Pricing, GST |
| Unit sale price (when applicable) | Legal Metrology (**UNVERIFIED** scope) |
| Manufacturer, packer or importer name and address | Legal Metrology |
| Month and year of manufacture, packing or import; best-before or expiry | Legal Metrology |
| Country of origin | Legal Metrology and E-Commerce Rules |
| Consumer care contact | Legal Metrology |
| HSN code and GST rate (with effective date) | GST |
| Return window, refund, exchange and warranty terms | E-Commerce Rules |
| Seller legal name, address, GSTIN, grievance officer | E-Commerce Rules (per channel profile, not per SKU) |
| Marketplace identifiers (ASIN, FSN, product id), channel SKU, FNSKU | Mapping |
| Category and fee category | Fee estimate |
| Weight and dimensions | Fee estimate |

Rule: the listing master holds the data; Progen validates completeness (warns) but does not publish to the marketplace in v1. Gaps block a channel's "ready" flag only as a warning.

## 7. Open questions for a human advisor

- Whether TDS under s.393 Sl. 8(v) applies to GST-inclusive or exclusive gross (Section 2.1).
- Whether the small-participant exemption survives in the 2025 Act and for whom.
- Whether sellers must deduct TDS on marketplace fees (Section 2.3).
- Treatment of COD in the TCS base.
- Whether reimbursements are a supply.
- Current fee schedules and report headers, from a real account.
- The exact 9(5) service list as of 2026.

## 8. What Progen needs to build

### 8.1 Objects

| Object | Key fields |
| --- | --- |
| Channel | id, type (amazon, flipkart, meesho, shopify, other), company, GSTIN used, state, settlement cycle days, fee profile id, `tcs_applies` (true for marketplaces), `tds_applies`, `tds_base_includes_gst`, active |
| Channel location map | channel warehouse code to Progen location and GSTIN |
| Listing | channel, channel SKU, marketplace id, item, status, price, MRP, fee category, country of origin and other 6.4 fields |
| Listing component | listing to item with quantity. Supports **combos and bundles**: one listing sells several items, stock and COGS split by component. Supports **variants** (many listings to one item). |
| Order | channel, order id (unique per channel), order date, customer state, place of supply, payment mode (prepaid or COD), status |
| Order line | listing, quantity, unit price incl. GST, taxable value, tax, discount, shipping recharge |
| Shipment | order, AWB, courier, fulfilment type (FBA, marketplace-shipped, self-ship), from location, dispatch, delivery, RTO status, e-way bill ref if any |
| Return | order line, type (customer return or RTO), received date, grade, reason code, quantity, credit note ref, claim status |
| Reimbursement claim | return or shipment, amount claimed, evidence refs, deadline, status, amount received |
| Settlement | channel, external settlement id, period start and end, deposit date, total (paise), file hash, status |
| Settlement line | settlement, line type, order or return ref (optional), amount (signed, paise), GST amount, raw row |
| Fee profile | channel, versioned effective dates, rules by category and price band (for estimates only) |
| TCS receivable | channel, month, base (paise), TCS (paise), source (settlement or GSTR-8 import), matched flag |
| TDS receivable | channel, quarter, base, TDS, source (settlement or AIS import), matched flag |
| Stock transfer | from GSTIN and location to channel warehouse GSTIN and location, invoice ref, e-way bill ref |

Settlement line types (an enum, extensible): `principal`, `tax_on_sale`, `shipping_recharge`, `commission`, `fixed_fee`, `closing_fee`, `collection_fee`, `shipping_fee`, `weight_fee`, `reverse_shipping_fee`, `fba_fee`, `ads_fee`, `gst_on_fees`, `tcs_cgst_sgst_igst`, `tds`, `refund`, `fee_refund`, `reimbursement`, `reserve_hold`, `reserve_release`, `other`.

### 8.2 Calculations (all in paise, integers)

- Money is stored as integer paise everywhere. No floats.
- Rounding: half-up to the paisa at each stated line, never on a total, unless the source document totals first.
- GST-inclusive to taxable: `taxable = round(gross * 100 / (100 + rate))`, tax = gross - taxable (so the two always add up). Rate comes from the HSN rate table by date.
- Intra-state: split tax into CGST and SGST with CGST = floor(tax / 2) and SGST = tax - CGST. Inter-state: IGST.
- TCS expected = `round(net_taxable x 5 / 1000)` per month per channel GSTIN, where `net_taxable` is sales taxable minus credit-note taxable in the month. Rate comes from a rate table by date (0.5% from 10 Jul 2024).
- TDS expected = `round(base x 1 / 1000)` where base is configured by channel (`tds_base_includes_gst`). Small-participant exemption: only for individual or HUF, with a yearly gross tracker, and configurable.
- Fee estimate = sum of fee rules from the fee profile; used only for pre-sale margin and for a variance flag against actual.
- Variance: `actual_fee - estimated_fee` per order; flag over a configurable tolerance (for example ₹1 plus 1% of the fee).
- Net payout check: `sum(settlement lines) = total` within 1 paisa per line; otherwise the settlement is "unbalanced" and cannot post.
- Margin per order: taxable sales minus COGS minus fees (net of ITC) minus reverse shipping and return losses. TCS and TDS are not costs.

### 8.3 Journal entries

Use the simple names from Section 4: Amazon Receivable (one per channel), Sales, Sales Returns, Output GST (CGST, SGST, IGST), Marketplace Fees, Input GST on Fees, TCS Receivable, TDS Receivable, Bank, Marketplace Reserve, Returns Loss, Marketplace Reimbursements, Gateway Fees, COD Receivable (courier), Inventory, Cost of Goods Sold, Stock In Transit (channel warehouse).

Events and posting:
1. **Order shipped (invoice):** Dr Channel Receivable, Cr Sales, Cr Output GST. COGS: Dr COGS, Cr Inventory at dispatch (FBM) or at order posting (FBA, stock already at the channel warehouse).
2. **Stock transfer to a channel warehouse:** Dr Stock In Transit (channel) at cost, Cr Inventory. Output IGST on the transfer invoice when the GSTINs differ by state, with input IGST at the receiving GSTIN. Same GSTIN: no tax.
3. **Settlement:** one entry per settlement, with lines per Section 4.2, balanced to Channel Receivable. Reserve held: Dr Marketplace Reserve.
4. **Return or RTO:** credit note entry as Section 4.3 or 4.4; stock per grade.
5. **Reimbursement:** Dr Channel Receivable or Bank, Cr Marketplace Reimbursements.
6. **TCS matching (monthly):** move matched TCS Receivable to GST Cash Ledger (asset) when the credit appears; pay output tax from it.
7. **TDS matching (quarterly or yearly):** move to Income-tax Receivable when it shows in the TDS credit statement.
8. **Gateway settlement (own store):** Dr Bank and Gateway Fees and Input GST, Cr Gateway Receivable.
9. **COD remittance:** Dr Bank, Dr Courier Fees, Dr Input GST, Cr COD Receivable.

Posting is idempotent: keyed by (channel, settlement id, line index). Re-importing a file never double-posts.

### 8.4 GSTR-8 versus books matching

Inputs: GSTR-8 TCS credit data per ECO (from GSTR-2A or 2B JSON, or a CSV) for each month.

Match per (ECO GSTIN, month):
- Books side: sum of `TCS Receivable` booked from settlements in that month, plus the TCS computed from the sales and credit notes of that month.
- Government side: the ECO's TCS for our GSTIN: gross supplies, returns, net value, and tax by head.
- Report: matched, difference, and cause hints (return posted in a later month, ECO-reported month differs, base on invoice value including GST, COD not included).
- A difference above a threshold creates a task, not a journal. When accepted, post the difference to a "TCS Difference" account only on user approval.
- A TCS credit in the cash ledger with no matching books entry is shown as "unbooked TCS".
- Also reconcile the seller's GSTR-1 ECO table (supplies through ECO) to the ECO's reported gross supplies; the two should agree month by month.

### 8.5 Guardrails

1. A composition-scheme company cannot create or activate a marketplace channel with inter-state delivery. A composition dealer on an ECO: intra-state only (**UNVERIFIED**), otherwise blocked.
2. An unregistered seller cannot activate a marketplace channel that collects TCS (GSTIN required).
3. A warehouse code on a channel must map to a location with a GSTIN in the same state as the warehouse. Block FBA stock transfer to a state where the company has no GSTIN.
4. A stock transfer between different GSTINs must be a tax invoice, never a delivery challan. E-way bill prompt above ₹50,000 inter-state.
5. Place of supply must follow the delivery state. Changing it after the invoice is blocked.
6. Credit note date: warn after 30 November following the financial year. Block a credit note against an invoice older than the limit unless an override is recorded with a reason.
7. A settlement cannot post if it does not balance, if its channel is inactive, or if it falls in a locked period.
8. TCS or TDS lines are never booked as expense; the posting engine refuses a mapping of a TCS or TDS line to an expense account.
9. A listing cannot be marked "ready" without MRP, country of origin, manufacturer details and net quantity (a warning level that a company can make a block).
10. Price above MRP is blocked.
11. Fee rates and TCS/TDS rates are data with effective dates. No rate constant in code.
12. TDS on marketplace fees paid by the seller is off by default (Section 2.3).
13. Do not auto-treat a reimbursement as a supply or auto-reverse ITC on write-off; both are reviewed tasks.
14. Never delete imported settlement lines; corrections are new lines (an audit trail).
15. GST rate for an HSN must come from the dated rate table; a rate changing mid-order uses the invoice date.

### 8.6 What can be file-import only (first release)

No marketplace API integration is needed for v1. Everything can be file import with a mapping:

| Import | Format | Notes |
| --- | --- | --- |
| Orders and shipments | CSV or XLSX downloaded from Seller Central, Seller Hub, the Meesho supplier panel, or Shopify export | Mapping stored per channel, header aliases |
| Settlement or payment report | CSV or XLSX (Amazon date-range report, Flipkart payment report, Meesho payment sheet, gateway settlement report) | The raw row is kept; line types via alias table |
| Return and RTO report | CSV or XLSX | Gives return receipt and reason |
| COD remittance | CSV from the courier or aggregator | Reconciled by AWB |
| GSTR-8 / TCS credit | The JSON or CSV from the GST portal (GSTR-2A or 2B) | For Section 8.4 |
| TDS credit | Form 26AS or AIS (CSV or JSON) | Quarterly, for matching |
| Fee schedule | Manual entry or CSV | Estimates only |
| Reimbursement claims | Manual entry | |

Deferred (not v1): live API sync (Amazon SP-API, Flipkart API), automated GSTR-8 download, automated e-way bill creation for transfers (see docs/research/gst-einvoice-ewaybill.md), marketplace publishing, and price repricing.

Not covered here: ONDC and quick-commerce, cross-border exports through marketplaces (Amazon Global), and marketplace-run cash-on-delivery refunds. Each needs its own note.
