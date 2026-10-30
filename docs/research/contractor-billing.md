# Subcontract work orders and running-account (RA) bills

DRAFT. The income-tax section is verified and final. Sections 2 to 8 are first-pass research (about 5 web searches, mostly secondary sources); anything not confirmed is marked "(unverified)". Free-issue material and test cases are not covered yet.

Status: research for phase 2b, as of 28 Oct 2026.

## TDS on payments to contractors and related income-tax rules (verified)

Primary sources:
- Income-tax (No. 2) Bill 2025 as passed by Lok Sabha, which became the Income-tax Act 2025 (Act 30 of 2025, in force 1 Apr 2026). PRS copy: https://prsindia.org/files/bills_acts/bills_parliament/2025/Bill_as_passed_by_LS_Income_Tax_(No.2)_Bill.pdf
- Finance Bill 2026 memorandum (official): https://www.indiabudget.gov.in/doc/memo.pdf. The Finance Act 2026 received assent on 30 Mar 2026; that date comes from a secondary source, https://www.taxmann.com/post/blog/finance-act-receives-assent-of-the-president/
- Income-tax Rules 2026, G.S.R. 198(E) dated 20 Mar 2026 (CBDT Notification 22/2026), in force 1 Apr 2026. Gazette copy mirrored at https://abcaus.in/wp-content/uploads/2026/03/income-tax-rules-2026.pdf

Note: incometaxindia.gov.in returned HTTP 403 to every automated fetch, so its section pages could not be opened directly.

| Old (1961 Act) | New reference (2025 Act) | Rate | Threshold |
| --- | --- | --- | --- |
| 194C contractors | s.393(1) Table Sl. No. 6(i) | 1% if the contractor is an individual or HUF; 2% for anyone else | ₹30,000 for a single sum, or ₹1,00,000 aggregate in the tax year |
| 194M (an individual or HUF paying a contractor, professional or commission agent) | s.393(1) Sl. No. 6(ii) | 2% | ₹50 lakh |
| 194H commission or brokerage | s.393(1) Sl. No. 1(ii), deducted by a "specified person" | 2% | ₹20,000 |
| 194-IA immovable property | s.393(1) Sl. No. 3(i) | 1% of the higher of the consideration and the stamp duty value | ₹50 lakh |
| 194J professional fees / fees for technical services | s.393(1) Sl. No. 6(iii) | 10% / 2% | ₹50,000 |

Rules engineers must implement:
- **Base and timing.** Tax is deducted on the *entire* amount once the single sum or the yearly aggregate crosses the threshold. It is deducted at credit or payment, whichever comes first (s.393(1)(a), (c)).
- **Who must deduct under 6(i): the "designated person"** (s.402(11)). This covers government, local authorities, statutory corporations, any company, co-operative society, housing or planning authority, society, trust, university or firm. It also covers an individual, HUF, AOP or BOI whose turnover in the preceding tax year exceeded ₹1 crore (business) or ₹50 lakh (profession).
- **Supply of manpower** counts as "work" under s.402(47) from 1 Apr 2026, so it falls under 6(i) and not 6(iii). Source: Finance Bill 2026 memo, clause 78.
- **Material.** For work of the s.402(47)(e) kind (making to the customer's specification using the customer's material), tax is deducted on the invoice value excluding material if the material is shown separately; otherwise on the whole invoice (Note to Sl. 6).
- **No deduction for small transporters** (s.393(4) Table Sl. 8): a contractor plying, hiring or leasing goods carriages who owns 10 or fewer of them and gives a declaration with PAN. Also none where an individual or HUF pays for purely personal purposes.
- **No PAN.** Deduct at the higher of the Act rate, the rates in force, or 20% (s.397(2)(b)(i)).
- **GST component.** Tax is deducted on the amount excluding GST when GST is shown separately. Source: CBDT Circular 23/2017, copy at https://itatonline.org/info/wp-content/uploads/2017/07/CBDT-Circular-23-TDS-GST.pdf. Its continuation under the 2025 Act is **UNVERIFIED**.
- **Deposit** (Rule 218(2)): within 7 days from the end of the month; for March, by 30 April.
- **Quarterly statement for residents** (Rule 219(1), replaces 26Q): **Form 140**. Due dates (Rule 219(4)): 31 Jul, 31 Oct, 31 Jan, 31 May.
- **Certificate** (Rule 215, replaces 16A): **Form 131**, within 15 days from the statement due date.
- **Property and 6(ii) deductions** (Rule 219(5)): challan-cum-statement **Form 141**, within 30 days from the end of the month of deduction. Certificate **Form 132** (Rule 215). No TAN is needed (s.397(1)(c)(i)).
- **Return codes.** Payment codes 1023 (individual/HUF) and 1024 (others) for 6(i) are reported by secondary sources only (https://www.terra-insight.com/resources/section-393-payment-code-reference/). They are **UNVERIFIED**.

## 2. RA bills and the measurement book

Practice follows the CPWD / state PWD model, which private main contractors copy (CPWD Works Manual itself not opened; unverified).

- **Work order (WO)** to the subcontractor lists BOQ items: code, description, unit, WO quantity, rate (excluding GST). Variations need a written amendment or deviation approval.
- **Measurement book (MB)** records dated measurements per item, taken jointly by the contractor and the site engineer: nos x L x B x H = quantity, with location or grid reference. Each entry is signed. Quantities are cumulative to date.
- **RA bill arithmetic (cumulative method).** For each BOQ line, cumulative measured qty x WO rate = cumulative gross value. Sum all lines. Subtract the gross of all previous RA bills. The difference is the gross of this bill. Never bill from per-bill quantities alone; the cumulative method self-corrects re-measurements and negative quantities.
- **Bill fields.** Bill no. (RA-n), WO no., project, subcontractor and GSTIN, period, bill date, per line: previous qty, this-bill qty, cumulative qty, rate, amount; then totals, deductions (sections 3 to 5 below), GST, net payable.
- **Approval flow.** Subcontractor submits, site engineer verifies the MB and quantities, project manager certifies, QS or billing checks rates and WO limits, accounts checks deductions and statutory compliance, then payment approval. Each step needs a timestamp and user. Excess over WO quantity (over about 10 to 20 percent, varies by contract) should block or need a deviation approval (threshold unverified).
- **Final bill** is marked "final" and needs no-claim / no-dues sign-off (section 7).

## 3. Retention money (security deposit)

- **Typical rate:** 5 to 10 percent of each RA bill's gross, set in the WO. CPWD uses 5 percent of each running bill as security deposit up to a cap of 5 percent of tendered value, plus performance guarantee (unverified; the search did not confirm it).
- **Deduction:** per RA bill on gross value of work (excluding GST), until the cap if any.
- **Release:** commonly 50 percent on completion / virtual completion certificate and the balance after the defect liability period (DLP), or all at the end of DLP. Release terms are contractual, so store them per WO.
- **Against bank guarantee (BG):** the subcontractor may replace cash retention with a BG for the same amount, valid beyond the DLP end plus a claim period. The system should track BG no., bank, amount, expiry and send alerts before expiry.
- **Tax note:** retention is deducted from payment, but TDS and GST apply on the full billed value at bill time (credit or payment, whichever is first), not at release. Release itself triggers no new TDS (the amount was already credited and tax deducted).

## 4. Mobilisation advance and secured advance

**Mobilisation advance (MA)**
- CPWD manual para 31.6, as quoted in CAG audit reports: up to 10 percent of estimated or tendered value, or ₹1 crore, whichever is less, with simple interest at 10 percent a year until adjusted, against a bank guarantee. See [CAG report](https://cag.gov.in/uploads/download_audit_report/2020/06%20Chapter%202-of-10-2020-05f809740af13a2.24153591.pdf) and the [CPWD payments slide deck](https://www.slideshare.net/slideshow/payments-provisions-in-cpwd-contract/73633570).
- Recovery: starts after about 10 percent of work is done and finishes by about 80 percent (secondary source, unverified). Private contracts typically use 5 to 10 percent, interest-free or at a stated rate, and recovery as a flat percentage of each RA bill (for example the advance percentage, so it is cleared pro rata) (unverified, commercial practice).
- Treated as an advance to the subcontractor, not income. GST is due on advance for services only per time of supply (see section 5), but in practice a mobilisation advance that is adjusted later is usually invoiced as part of RA bills. Confirm with a CA (unverified).

**Secured advance**
- Advance against non-perishable materials brought to site and stored under contractor and department joint custody. CPWD: up to 90 percent of the assessed value of material, no BG needed, recovered from the next RA bills as materials are consumed in measured work ([slide deck](https://www.slideshare.net/slideshow/payments-provisions-in-cpwd-contract/73633570); the 90 percent figure is from a secondary source). Whether interest is charged is unverified.
- Private main contractors seldom give secured advance to subcontractors; support it as an optional WO term.

**System rule:** each advance has a register row (WO, type, amount, interest %, BG ref, recovered to date, balance). Each RA bill recovers a computed amount, never more than the balance.

## 5. GST on works contracts

- **Rate.** Works contract is a composite supply of service (SAC 9954), 18 percent in general. For government and local-authority civil works, the rate was 12 percent before GST 2.0 and is reported as 18 percent from 22 Sep 2025 for new contracts. The reports are secondary and conflict (unverified): [DisyTax summary](https://disytax.com/?p=24147), [GST 2.0 reports](https://www.taxheal.com/?p=44747). A concessional 12 percent for affordable housing works contracts (carpet area up to 60 sq m, competent-authority approved) appears in older sources and its status after Sep 2025 is unverified. Store the rate per WO line / bill and let accounts override. Do not hard-code it.
- **CGST + SGST** for intra-state, **IGST** for inter-state, by place of supply (location of the immovable property).
- **Time of supply (services).** The earlier of invoice date (invoice due within 30 days of the service, CGST s.13(2)) and receipt of payment. For stage-based RA bills, treat each certified bill as a milestone supply and invoice at certification. Retention is part of the invoice value and GST is paid on it at bill time (unverified in detail; confirm with a CA).
- **ITC blocking, s.17(5)(c)/(d).** No ITC to the recipient on works contract services for construction of immovable property (other than plant and machinery) except where the service is used to further supply of works contract service itself. Land and building cases are blocked even if used in business, unless it is plant and machinery. A main contractor billing the client for works contract can claim ITC on subcontractor works contract (to supply further works contract). A developer building for sale is generally blocked (unverified in detail). Add a per-project flag "ITC eligible Y/N" that decides whether subcontractor GST goes to GST input (eligible) or is capitalised/expensed in Subcontract cost (blocked).
- **GST TDS, CGST s.51.** Government departments, local authorities and notified bodies deduct 2 percent (1 + 1 CGST/SGST, or 2 IGST) when the contract value (excluding GST) exceeds ₹2.5 lakh. It applies to the taxable value, excluding GST. Sources: [TaxGuru on s.51](https://taxguru.in/goods-and-service-tax/section-51-gst-act-deduction-tds-specified-persons.html), [Bihar GST study material](https://bica.bihar.gov.in/Doc/Study%20Matrials/TDS%20under%20GST.pdf). It applies when Progen's client is such a body, and is relevant to Progen's own billing (receivable side) more than to subcontractor payments, unless Progen is itself a notified recipient (unlikely). Threshold is per contract, not per invoice (secondary source). Return is GSTR-7 (not detailed here).
- **Reverse charge (RCM).** Normally the subcontractor charges GST. RCM under s.9(4) on supplies by unregistered persons now applies only to notified classes (unverified for works contracts; in practice most subcontractors are registered). If a subcontractor is unregistered or under the composition scheme, the bill is "bill of supply" with no GST and the system must not claim ITC. Flag subcontractor GST registration type.

## 6. BOCW welfare cess

- Building and Other Construction Workers' Welfare Cess Act 1996, s.3: cess of 1 to 2 percent of the cost of construction; the Centre notified 1 percent. Collected from the employer, including by deduction at source from bills ([Cess Rules 1998 summary](https://future.indiankanoon.org/doc/75457346/); [taxheal on 1% under the Code on Social Security 2020](https://www.taxheal.com/notification-to-be-published-in-gazette-of-india-for-levy-and-collection-of-bocw-cess-at-the-rate-of-1-per-cent-under-section-100-1-of-code-on-social-security-2020.html)). The Social Security Code 2020 status for cess (in force or not) was not verified.
- **Who and when.** Government and PSU clients deduct 1 percent from each bill paid to the main contractor. Private clients pay to the board on completion or on assessment, normally within 30 days (secondary source). Whether a subcontractor bears cess is contractual and case-law dependent. Who counts as "employer" is disputed (see the Kaanoon / TMI discussions linked in the search results). Treat as a configurable deduction on gross value: percent, who deducts, deposit state board (unverified per state).
- **Base.** Cost of construction excluding land and some items (Rule 3), so the base on an RA bill is usually the gross excluding GST (unverified for GST).
- Payable to the state welfare board. Keep a "BOCW cess payable" ledger and deposit report.

## 7. Final bill, DLP and closure

- **Completion:** completion certificate after joint inspection, with a snag list. Quantities finalised (final measurement, reconciliation of deviations and extra items), recovery of all advances plus interest, penalties or liquidated damages (LD), back-charges for materials supplied by the main contractor (free-issue; not covered yet).
- **Final bill** = final cumulative measurement less all earlier bills, less recoveries. Retention at this point is usually 50 percent released or held in full until DLP end.
- **DLP** (commonly 6 to 12 months, sometimes 12 to 24; contract-specific, unverified). The subcontractor repairs defects at own cost; the main contractor may recover repair cost from retention or BG.
- **Closure:** at DLP end, defect-free certificate, release of retention or BG, no-dues / no-claim certificate, TDS certificate (Form 131) issued, WO status = closed. Block further bills after closure.
- **Rework and defect cost** after the final bill is booked against the retention payable, not as a new RA bill.

## 8. What Progen needs to build

### Objects and fields
- **Work order:** id, project, subcontractor (vendor with PAN, GSTIN, registration type, TDS category individual/HUF or other), date, validity, GST rate, TDS %, retention %, retention cap, DLP months, advance terms, BOCW cess %, status (draft, approved, active, closed). **WO line:** BOQ code, description, unit, qty, rate_paise.
- **RA bill:** id, bill no., WO, period, status (draft, site_verified, pm_certified, accounts_approved, paid, cancelled), final flag. **Bill line:** WO line id, prev_qty, cum_qty, rate_paise (snapshot), cum_gross_paise. Header: gross_cum, gross_prev, gross_this, retention, advance_recovery, TDS, GST TDS (only when relevant), BOCW cess, other deductions, GST charged, net_payable, all in integer paise.
- **MB entry:** line, date, description, nos, L, B, H, qty, measured by, checked by, attachments (photos).
- **Advance register:** WO, kind (mobilisation / secured), amount, interest rate, BG ref, recovery rule, recovered, balance.
- **Retention register:** WO, withheld, released, balance; BG details and expiry.
- **Deduction rules** per WO. **Audit trail** per bill transition.

### Calculations (paise, integer; round half up per line, then sum)
1. gross_this = cum_gross - gross_prev (can be negative for over-billing corrections; block if cum > WO limit without approval).
2. retention = round(gross_this x retention_bp / 10000), capped so retained total <= cap.
3. advance_recovery = min(advance balance, rule amount).
4. GST = round(taxable x rate), where taxable = gross_this (retention not netted, GST is on the full value).
5. TDS (income tax) on gross_this excluding GST, using the threshold logic in the TDS section above (aggregate tracking per vendor per financial year).
6. BOCW cess = round(gross_this x cess_bp / 10000) when Progen deducts.
7. net_payable = gross_this + GST - retention - advance_recovery - TDS - GST TDS - cess - other.

Example (paise): gross_this 1,00,00,000 (₹1,00,000.00), retention 5% = 5,00,000, advance recovery 10% = 10,00,000, TDS 2% = 2,00,000, GST 18% = 18,00,000, cess 1% = 1,00,000. Net = 1,00,00,000 + 18,00,000 - 5,00,000 - 10,00,000 - 2,00,000 - 1,00,000 = 1,00,00,000 paise (₹1,00,000.00).

### Journal entries (Dr / Cr)
- **Mobilisation advance paid:** Dr Mobilisation advance, Cr Bank. (TDS applies on advance credit/payment under 194C; Dr Mobilisation advance full, Cr TDS payable, Cr Bank.)
- **RA bill approved:** Dr Subcontract cost (gross_this); Dr GST input (if ITC eligible, else add to cost); Cr Subcontractor payable (net of deductions as owed now); Cr Retention payable; Cr TDS payable; Cr BOCW cess payable; Cr Mobilisation advance (advance recovery). Example above: Dr Subcontract cost 1,00,00,000; Dr GST input 18,00,000; Cr Retention payable 5,00,000; Cr Mobilisation advance 10,00,000; Cr TDS payable 2,00,000; Cr BOCW cess payable 1,00,000; Cr Subcontractor payable 1,00,00,000.
- **Payment of the net:** Dr Subcontractor payable, Cr Bank.
- **Deposit of TDS / cess:** Dr TDS payable (or BOCW cess payable), Cr Bank.
- **Retention release:** Dr Retention payable, Cr Subcontractor payable, then pay as above. No new TDS.
- **Retention forfeited / used for defects:** Dr Retention payable, Cr Other income or Cr Subcontract cost (reversal), as policy dictates.
- **Retention replaced by BG:** memo only (off-balance track BG); Dr Retention payable, Cr Subcontractor payable on release of cash.
- **Interest on advance:** Dr Subcontractor payable, Cr Interest income, added to deductions.
- **Closure:** all retention, advance and cess balances must be zero or explicitly written off.

### Guardrails
- Block approval if cumulative quantity exceeds WO quantity without a deviation approval.
- Block payment if TDS or vendor GST data is missing.
- Never edit approved bills; use a credit bill or a reversal.
- All rates and percentages that are marked unverified above must be configurable per WO / project, not hard-coded.
