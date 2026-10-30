# Payroll and HR for the Organisations pack (offices, factories, schools, hospitals, agencies)

Status: research as of 29 Oct 2026 for FY 2026-27 (Tax Year 2026-27 under the Income-tax Act 2025). Scope: payroll calculation depth. Labour Code status, working time and OT, minimum/floor wages, EPF/ESI basics, contract labour, registers and payment timelines are already in `docs/research/labour-wages.md`; this note links to those sections instead of repeating them.

How to read this note:
- **Source quality warning.** In this research session the primary sources (egazette, EPFO, ESIC, CBDT, state gazettes) were mostly not openable. Most figures below come from law-firm, news and payroll-vendor pages, with the URL shown. Anything resting only on those is marked **UNVERIFIED**, even where several secondary sources agree.
- Items already verified from primary sources in `labour-wages.md` are cited as "LW §n".
- Figures from memory of the old regime (pre-2026) that I could not re-confirm are marked **UNVERIFIED (carried over)**.
- Income-tax Act 2025 section numbers are given with the 1961 number in brackets. Most 2025-Act section numbers other than 392/393 are **UNVERIFIED**.

---

## 1. Salary structure and the "wages" definition

### 1.1 The Code definition (verified in LW §4 and §7)
- Code on Wages s.2(y) = SS Code s.2(88): wages = basic pay + dearness allowance + retaining allowance, plus the rest of "all remuneration", but excluding listed items. Details and URLs: LW §4 ("Wage definition").
- Excluded items (a) to (i) in the proviso, as paraphrased in LW: bonus, value of housing/amenities, employer PF/pension contribution, conveyance allowance, special expenses of the job, house rent allowance, award/settlement remuneration, overtime, commission. Gratuity on termination and retrenchment/retirement benefits are excluded separately.
- **50% rule.** If items (a) to (i) exceed one-half of total remuneration, the excess over one-half is added back into wages (LW §4). The 50% test runs on the **full remuneration**, i.e. all earnings including the excluded ones.
- Secondary confirmation that the new wage definition applies prospectively from 21 Nov 2025, not to earlier service: https://www.legalserviceindia.com/Legal-Articles/gratuity-act-under-the-code-on-social-security-2020-employer-duties/ (**UNVERIFIED**, blog).

### 1.2 Where "wages" is used (one engine, many consumers)
| Use | Base | Note |
|---|---|---|
| EPF/EPS/EDLI | Code wages, capped at the EPF ceiling (₹25,000) | LW §4 |
| ESI | ESI wages (all remuneration except a short exclusion list, see §3) | not the same as Code wages in practice, **UNVERIFIED** (ESIC wage definition under the Code: https://www.hrstop.com/Content/502/ESIC-2025-Wages-Definition) |
| Gratuity | last drawn Code wages (basic + DA, with add-back) | §7 |
| Bonus | Code wages, subject to the calculation ceiling | §8 |
| OT rate | normal rate of wage = Code wages (LW §2, r.2(1)(p)) | not gross |
| Leave encashment, notice pay, F&F | usually basic + DA, or per policy | §9, §10 |

### 1.3 Worked example: the add-back
Interpretation used here (the "payroll vendor view", **UNVERIFIED** as a legal reading): treat HRA, conveyance, commission, OT, employer PF, special-expense reimbursements and other non-basic allowances as the excluded block. Whether a free-form "special allowance" counts as wages or as an excluded item is disputed in commentary. Progen must therefore make each component's `countsAsWages` flag editable per company, with a default.

Example A: monthly remuneration ₹40,000
- Basic ₹15,000, HRA ₹7,500, conveyance ₹3,000, special allowance ₹14,500.
- Excluded block (HRA + conveyance + special, vendor view) = ₹25,000 which is 62.5% of ₹40,000.
- Half = ₹20,000. Excess = ₹5,000 is added back. Wages = ₹15,000 + ₹5,000 = **₹20,000**. (Equivalently: wages = max(basic + DA, 50% of total remuneration).)

| | Basic only (old habit) | Code wages ₹20,000 |
|---|---|---|
| Employee EPF 12% | ₹1,800 | ₹2,400 |
| Employer EPF 3.67% + EPS 8.33% | ₹1,800 | ₹2,400 |
| Gratuity per completed year (15/26) | ₹15,000 × 15/26 = ₹8,654 | ₹20,000 × 15/26 = ₹11,538 |
| Net effect on take-home | -₹600/month | |

Example B: monthly remuneration ₹1,00,000 with basic ₹50,000 (the 50% already met): no add-back, wages = ₹50,000. PF is then capped at the ceiling (₹25,000) anyway, so the add-back matters mainly for gratuity, bonus and leave.

### 1.4 Typical components
| Component | Taxable (new regime) | Counts as wages (default) | Notes |
|---|---|---|---|
| Basic | yes | yes | |
| DA | yes | yes | mostly factories, government-linked, VDA in scheduled employments (LW §3) |
| Retaining allowance | yes | yes | |
| HRA | yes (exemption only in old regime) | no (excluded) | |
| Conveyance / transport | yes | no (excluded) | |
| Special / other allowance | yes | **configurable** | see §1.3 |
| Overtime | yes | no | |
| Commission / incentive | yes | no | |
| Bonus (statutory/ex gratia) | yes | no | |
| Reimbursements (phone, fuel, books) | taxable unless paid against bills and exempt | no | model as bill-backed claims, not salary |
| Employer PF/NPS/superannuation | not taxed within the ₹7.5 lakh combined limit (**UNVERIFIED (carried over)**) | no | |

- Each component carries: code, name, type (earning/deduction/employer cost/reimbursement), `countsAsWages`, `epfApplicable`, `esiApplicable`, `taxable`, `ptApplicable`, `proRataOnLop`, `calcType` (fixed, % of basic, formula).
- Components may be fixed monthly amounts, percentages (basic = 40–50% of CTC is common), or formula-driven.

---

## 2. EPF, EPS and EDLI

Basics, the ₹25,000 ceiling from 17 Sep 2026, the SS Code s.16 rates and coverage are in LW §4. Below: the split, the charges, edge cases and examples.

### 2.1 Rates and split (EPFO)
- EPFO FAQ and rate sheet (https://www.epfindia.gov.in/site_docs/PDFs/MiscPDFs/ContributionRate.pdf, https://pmvbry.epfindia.gov.in/faq-epfo/): employee 12% of basic + DA + retaining allowance. Employer 12%, of which **8.33% goes to EPS** and 3.67% to EPF. Employer pays EDLI 0.5%. Employees pay neither EPS nor EDLI.
- Admin charge: 0.5% of EPF wages, rounded to the nearest rupee, **minimum ₹500 per month per establishment**. If there is no contributory member in the month the minimum is ₹75 (EPFO rate sheet above and https://www.staffnews.in/2026/10/revision-of-epfo-statutory-wage-ceiling.html). Whether the ₹500 floor is applied per ECR or per establishment-month is **UNVERIFIED**.
- Is the 0.5% EDLI/0.5% admin still the rate under the Code? The staffnews FAQ (Oct 2026) restates 0.5% each for contributions from October 2026. **UNVERIFIED** against the EPFO circular.
- EDLI maximum assurance stays at ₹7 lakh (same FAQ). EDLI on a ₹25,000 ceiling: 0.5% × 25,000 = ₹125 (the older cap was ₹75 at ₹15,000).
- EPS government share stays capped at ₹174 per member per month (same FAQ, Q37). Not an employer cost.
- Rate reduction to 10% is for notified categories only (LW §4). A company-level `epfRate` (10 or 12) must be configurable.
- **EPS eligibility.** EPS membership applies only to employees whose wages did not exceed the ceiling at joining (or at implementation of the new ceiling). A new joiner above ₹25,000 on the joining date has no EPS: the whole 12% employer share goes to EPF (staffnews FAQ Q13, **UNVERIFIED**).

### 2.2 The September 2026 split month (relevant for retro runs)
- The ceiling moved on 17 Sep 2026. EPFO's guidance (https://www.staffnews.in/2026/10/revision-of-epfo-statutory-wage-ceiling.html): wage month split at 16/17 Sep, one ECR for the month. Period 1 (1-16 Sep) uses the old ₹15,000; period 2 (17-30 Sep) uses ₹25,000.
- Worked example from that page, employee at ₹20,000 newly covered: wages for 14/30 days = ₹9,333.33. Employee EPF ₹1,120.00, employer EPF ₹342.53, EPS ₹777.47, EDLI ₹46.67, admin ₹46.67. Total ₹2,333.34. (Note: 14/30 is as stated on that page; 17-30 Sep is 14 days. The page's other scenarios do not reconcile, per my read: **UNVERIFIED**.)
- The September 2026 ECR and payment deadline was extended from 15 Oct to **31 Oct 2026** by an EPFO circular of 13 Oct 2026 (https://www.scconline.com/blog/?p=398865, https://caalley.com/news-updates/indian-news/epfo-extends-ecr-deadline-to-october-31-2026). Secondary only; **UNVERIFIED**. The October ECR remains due 15 Nov.
- Employees already contributing on higher wages continue as before; nobody must be cut to ₹25,000 (staffnews FAQ Q21-22). Employees above the ceiling may join EPF voluntarily with employer consent (Q26).

### 2.3 Voluntary PF and higher-wage contributions
- Two different things:
  1. **Contribution on actual wages above the ceiling** (employer and employee agree to pay 12% on all wages). EPS stays capped at 8.33% of the ceiling; the balance of the employer's 12% goes to EPF.
  2. **VPF**: the employee pays a voluntary extra percentage; the employer matches nothing. It earns the same interest and is deducted as a separate payroll deduction. In the ECR it is reported in the employee EPF column.
- EPFO rule on VPF is not in the sources I could open: **UNVERIFIED**. The ECR layout has no separate VPF column; it is folded into employee share (**UNVERIFIED (carried over)**).
- Tax interaction: employee PF + VPF is an old-regime deduction (80C equivalent) only. Interest on employee contributions above ₹2.5 lakh a year is taxable (**UNVERIFIED (carried over)**; section 2025 equivalent unknown).

### 2.4 International workers
- EPFO's employer booklet: for an international worker the ₹15,000 wage ceiling does not apply (https://www.epfindia.gov.in/site_docs/PDFs/MiscPDFs/Employer_Information_Booklet.pdf). So contributions are on full wages, with no EPS wage cap. Whether the ceiling exemption now refers to ₹25,000, and the EPS treatment when a social-security agreement exempts the worker, are **UNVERIFIED**.
- Data fields needed: `isInternationalWorker`, nationality, passport no., country of origin, certificate of coverage (excluded employee under a bilateral agreement, reported with "Y" in the ECR excluded flag).

### 2.5 ECR file
- The ECR (Electronic Challan cum Return) is uploaded on the EPFO Unified Portal (https://www.epfindia.gov.in/site_docs/PDFs/EPFOUnifiedPortal/Introduction_ECR2.0.pdf). Format: text file with `#~#` as the field separator, one line per member.
- Fields per line (from the ECR 2.0 layout, **UNVERIFIED (carried over)** since I could not open the PDF text): UAN; member name; gross wages; EPF wages; EPS wages; EDLI wages; EPF contribution remitted (employee share); EPS contribution remitted; EPF-EPS diff remitted (employer EPF share); NCP days (non-contributing days); refund of advances.
- The challan is built from totals. Admin charges and EDLI are computed on the portal from wages.
- **Due date.** The 15th of the following month (EPFO notices: https://www.zeebiz.com/hindi/personal-finance/epfo/epfo-what-is-ecr-and-filing-deadline-may-15-2026-penalty-rules-reminders-alert-full-update-255173). A grace period used to exist (5 days) but is not a safe assumption; late payment attracts damages and interest. Under the SS Code, the legal basis is SS Code s.16-17 plus the EPF scheme; exact current interest/damages rates are **UNVERIFIED**.
- Rounding: contributions are rounded to the nearest rupee per member in the ECR (EPFO rate sheet states nearest rupee for admin charge; per-member rounding is **UNVERIFIED (carried over)**). Progen should keep a configurable rule per charge head (`nearest`, `up`, `down`).
- NCP days: LOP days in the month. Gross wages in the ECR are the actual month's earned wages; EPF wages are capped.

### 2.6 Worked examples
Assumptions: whole month worked, company on 12%, contribution restricted to the ceiling, ceiling ₹25,000. Basic + DA (Code wages) given.

**Example 1: ₹18,000 basic + DA**
| Head | Calculation | Amount |
|---|---|---|
| Employee EPF | 12% × 18,000 | ₹2,160 |
| Employer EPS | 8.33% × 18,000 = 1,499.40 | ₹1,499 |
| Employer EPF | 12% × 18,000 = 2,160 less EPS 1,499 | ₹661 |
| EDLI (employer) | 0.5% × 18,000 | ₹90 |
| Admin (employer) | 0.5% × 18,000 = ₹90, minimum is per establishment | ₹90 (establishment minimum ₹500 applies on the total) |
| Total remitted | 2,160 + 1,499 + 661 + 90 + 90 | ₹4,500 |
- Employer cost = ₹2,160 + ₹90 + ₹90 = ₹2,340. Employee deduction ₹2,160.

**Example 2: ₹40,000 basic + DA (above the ₹25,000 ceiling)**
| Head | Restricted to ceiling (₹25,000) | Higher-wage / on actual (₹40,000) |
|---|---|---|
| Employee EPF | 12% × 25,000 = ₹3,000 | 12% × 40,000 = ₹4,800 |
| Employer EPS | 8.33% × 25,000 = 2,082.50 → ₹2,083 (half-up) | ₹2,083 (still capped) |
| Employer EPF | 3,000 - 2,083 = ₹917 | 4,800 - 2,083 = ₹2,717 |
| EDLI | 0.5% × 25,000 = ₹125 | ₹125 |
| Admin | 0.5% × 25,000 = ₹125 | 0.5% × 40,000 = ₹200 (**UNVERIFIED** which wage base admin uses for higher-wage members) |
- The employer cannot force the "on actual" option on an existing employee who is on the restricted basis; it needs written consent (**UNVERIFIED** for 2026).
- Round-half-up on ₹2,082.50 gives ₹2,083. PIB says "8.33% of ₹25,000" without stating the rupee value (LW §4).

---

## 3. ESI

Rate, ceiling and periods are in LW §4 (employer 3.25%, employee 0.75%, round **up** to the next rupee per SS Central Rules r.19; wage ceiling ₹21,000, ₹25,000 for persons with disability; periods 1 Apr-30 Sep and 1 Oct-31 Mar). This section adds how coverage and contributions behave.

### 3.1 Wage ceiling in force
- ESIC Coverage page and payroll guides still show ₹21,000. Parliamentary-panel and press reports (Feb–Mar 2026) say a rise to ₹25,000 or ₹30,000 is being considered; no notification found as of Oct 2026 (https://www.indpayroll.com/blog/esic-new-rules-2026-salary-limit-eligibility-contribution-rates-payroll-compliance-guide, https://www.business-standard.com/industry/news/govt-to-decide-epfo-esic-wage-ceilings-minimum-pension-126020601818_1.html). **UNVERIFIED**: check ESIC notifications before each period start (1 Apr, 1 Oct). Ceiling must be a dated config row.

### 3.2 What counts as ESI wages
- All remuneration paid or payable in cash, including OT, HRA, conveyance, special allowance and incentives. Excluded: employer's PF/ESI contributions, retrenchment/gratuity payments, overtime is **included** in ESI wages in the old Act since 2017 (**UNVERIFIED (carried over)**: the ESIC Code wage definition page https://www.hrstop.com/Content/502/ESIC-2025-Wages-Definition was not read in full). Do not use the Code's 50% add-back rule logic without confirming ESIC applies it.
- Coverage test is on the wage at joining and at the start of each contribution period.

### 3.3 Staying covered mid-period (contribution vs benefit period)
- An employee whose wages cross ₹21,000 during a contribution period stays covered until the end of that period (31 Mar or 30 Sep). Contributions continue at 3.25%/0.75% on all wages, even above ₹21,000, until the period ends. Coverage is reassessed from the next period (https://www.esic.gov.in/contribution, as read in LW §4; the "stay covered" rule itself is **UNVERIFIED (carried over)**).
- New joiner whose wages exceed ₹21,000 on the day of joining is not covered.
- Benefit periods follow contribution periods with a lag (table in LW §4), so cash benefits depend on contributions in the matching contribution period.
- Payroll consequence: the covered flag is **stateful per employee per period**, not recomputed monthly from current wages.
- The IP stays covered on leaving the ceiling mid-period even if wages in later months are higher through OT. Track the "covered until" date on the employee record.

### 3.4 Due date and file
- Contributions are due by the **15th of the following month** (ESIC portal; the date is not in sources I opened: **UNVERIFIED (carried over)**). The monthly contribution file is uploaded on the ESIC employer portal as an Excel/CSV template with IP number, IP name, days worked, total monthly wages, reason code for zero days, and last working day.
- Employees with daily average wages up to ₹176 pay no employee share; the employer still pays (LW §4, Code continuation **UNVERIFIED**).

### 3.5 Worked examples
| Case | Wages | Employee 0.75% | Employer 3.25% |
|---|---|---|---|
| Round-up | ₹19,737 | 148.03 → ₹149 | 641.45 → ₹642 |
| Exact | ₹20,000 | ₹150 | ₹650 |
| Covered at ceiling | ₹21,000 | ₹158 (157.50 up) | ₹683 (682.50 up) |
- Mid-period example: employee earns ₹20,000 until July, gets a raise to ₹23,000 from 1 Aug. Covered period 1 Apr-30 Sep. Aug and Sep contributions on ₹23,000: 0.75% = 172.50 → ₹173; 3.25% = 747.50 → ₹748. From 1 Oct: not covered (wages > ₹21,000 at period start).
- Employer cost per worker at ₹20,000 = ₹650 (3.25%).

---

## 4. Professional Tax (PT)

PT is a **state** tax (Article 276, cap ₹2,500 per person per year). The employer deducts it from salary and remits to the state; it is not a central deduction. States differ on slabs, gender, periodicity (monthly / half-yearly / annual), and whether the employer must hold an enrolment certificate.

**Data quality:** the figures below are from payroll/compliance aggregators (https://hrone.cloud/blog/professional-tax-slab-rates-2026-27/, https://calcguru.in/professional-tax-india-state-wise-guide-fy-2026-27/) plus remembered older slabs. No state gazette was opened. Treat **every row as UNVERIFIED** until checked against the state notification. Aggregators disagree in places (noted).

### 4.1 States with monthly slabs
| State | Monthly salary | PT per month | Notes |
|---|---|---|---|
| **Maharashtra** | up to ₹7,500 (men) | nil | women exempt up to ₹25,000 (calcguru; remembered, **UNVERIFIED**) |
| | ₹7,501–10,000 | ₹175 | men only; |
| | above ₹10,000 | ₹200 | **February: ₹300** so that the annual total = 11 × 200 + 300 = ₹2,500 |
| **Karnataka** | up to ₹24,999 / ₹25,000 | nil | threshold nil below ₹25,000 per calcguru |
| | ₹25,001 and above | ₹200 (Feb ₹300) per calcguru and my memory of the 2025 revision | hrone shows a lower middle slab ₹150 for ₹25,001–41,999 and ₹200 from ₹42,000: **conflict** |
| **West Bengal** | up to ₹10,000 | nil | annual max ₹2,400 |
| | ₹10,001–15,000 | ₹110 | |
| | ₹15,001–25,000 | ₹130 | |
| | ₹25,001–40,000 | ₹150 | |
| | above ₹40,000 | ₹200 | |
| **Telangana** | up to ₹15,000 | nil | |
| | ₹15,001–20,000 | ₹150 | |
| | above ₹20,000 | ₹200 | annual ₹2,400 |
| **Andhra Pradesh** | up to ₹15,000 | nil | same bands as Telangana per hrone; older AP slabs had ₹15,001-20,000 = ₹150, above = ₹200 |
| | ₹15,001–20,000 | ₹150 | |
| | above ₹20,000 | ₹200 | |
| **Gujarat** | up to ₹11,999 | nil | calcguru: nil below ₹12,000 and ₹200 above; hrone shows older ₹80/₹150 steps. Use ₹12,000 / ₹200, flagged |
| | ₹12,000 and above | ₹200 | annual ₹2,400 |
| **Madhya Pradesh** | up to ₹18,750 (₹2.25 lakh/yr) | nil | deducted monthly or per employer routine, annual total ₹2,500 |
| | ₹18,751–25,000 | ₹125 | |
| | ₹25,001–33,333 | ₹167 | |
| | above ₹33,333 | ₹208 (₹212 in the last month, so total = ₹2,500) | |
| **Assam** | up to ₹10,000 | nil | calcguru: max ₹208; middle bands from memory: ₹150 for 10,001–15,000, ₹180 for 15,001–25,000, ₹208 above (**UNVERIFIED (carried over)**) |
| **Meghalaya** | up to ₹4,166 | nil | hrone: entry ₹4,166, max ₹208 per month. Intermediate bands not confirmed; older slabs rise in about 10 steps to ₹208 above ₹41,666 (**UNVERIFIED (carried over)**). Calcguru calls Meghalaya an annual-charge state: **conflict** |
| **Sikkim** | up to ₹20,000 | nil | max ₹200 (hrone/calcguru). Remembered bands: ₹125 for 20,001–30,000, ₹150 for 30,001–40,000, ₹200 above (**UNVERIFIED (carried over)**) |

### 4.2 Half-yearly states
| State | Half-yearly salary | PT per half-year |
|---|---|---|
| **Tamil Nadu** (paid to the local body, not the state treasury; due 30 Sep and 31 Mar, **UNVERIFIED**) | up to ₹21,000 | nil |
| | ₹21,001–30,000 | ₹135 |
| | ₹30,001–45,000 | ₹315 |
| | ₹45,001–60,000 | ₹690 |
| | ₹60,001–75,000 | ₹1,025 |
| | above ₹75,000 | ₹1,250 (annual ₹2,500) |
| **Kerala** (local bodies) | up to ₹11,999 | nil |
| | ₹12,000–17,999 | ₹120 |
| | ₹18,000–29,999 | ₹180 |
| | ₹30,000–44,999 | ₹300 |
| | ₹45,000–59,999 | ₹450 |
| | ₹60,000–74,999 | ₹600 |
| | ₹75,000–99,999 | ₹750 |
| | ₹1,00,000–1,24,999 | ₹1,000 |
| | ₹1,25,000 and above | ₹1,250 (annual ₹2,500) |
- Kerala's slabs shown are the older table from hrone. Kerala has revised PT in recent years; confirm. **UNVERIFIED**.

### 4.3 Annual-income states (Bihar, Jharkhand)
- Bihar: calcguru says nil to ₹2,500 per year on annual income above ₹3 lakh. hrone says "suspended / verify". Remembered slabs: ₹3–5 lakh ₹1,000, ₹5–10 lakh ₹2,000, above ₹10 lakh ₹2,500 (**UNVERIFIED (carried over)**). Treat the status as **UNVERIFIED**.
- Jharkhand: annual income above ₹3 lakh; calcguru and hrone give ₹100–300 per quarter, up to ₹2,500 a year. Remembered slabs: ₹3–5 lakh ₹1,200, ₹5–8 lakh ₹1,800, ₹8–10 lakh ₹2,100, above ₹10 lakh ₹2,500 (**UNVERIFIED (carried over)**).
- Punjab: calcguru lists ₹200 per month with a nil band and refers to a "State Development Tax" for annual income above ₹2.5 lakh; hrone says "limited/suspended". **UNVERIFIED**. Do not apply Punjab PT by default; make it an explicit company-level opt-in until confirmed.

### 4.4 Odisha: repealed
- Odisha repealed its PT law (Odisha State Tax on Professions, Trades, Callings and Employments Act 2000) by ordinance, **effective 1 Apr 2026**: https://www.scconline.com/blog/post/2026/04/23/odisha-repeals-levy-of-professional-tax-effective-from-1-april-2026/ and https://taxguru.in/?p=1039172 (secondary copies of the notification). Arrears for periods before 1 Apr 2026 remain recoverable. Whether the ordinance became an Act is **UNVERIFIED**.
- The old Odisha table (₹125 / ₹167 / ₹208 monthly) still appears in some aggregators; do not apply it.

### 4.5 States and UTs with no PT
- Delhi, Haryana, Uttar Pradesh, Rajasthan, Uttarakhand, Himachal Pradesh, J&K, Goa (levied under an older Act per hrone's ₹15,000 / ₹200 entry; calcguru says not levied: **conflict**, **UNVERIFIED**), most UTs.
- Other PT states exist (Chhattisgarh, Tripura, Mizoram, Nagaland, Manipur, Puducherry) with small monthly amounts up to ₹208. Details not verified. They should be rows in the same table.

### 4.6 Employer enrolment vs employee registration
- **Employer** registers for two numbers: PTRC (Registration Certificate, to deduct and remit PT for employees) and PTEC (Enrolment Certificate, the employer's own liability as a trader/professional, usually a flat ₹2,500 a year in Maharashtra). Calcguru notes the enrolment-based PT is separate from the employer's deduction for staff.
- **Employees** do not register. The employer deducts based on gross monthly salary of the state where the employee is **posted (work location)**, not the head office.
- Cross-state: an employee posted in Karnataka while the company is registered in Maharashtra attracts Karnataka PT, which needs a Karnataka PTRC.
- PT is deductible in the old regime as a deduction from salary (old s.16(iii); new section **UNVERIFIED**). The new regime does not allow it (calcguru).
- Typical due dates: Maharashtra monthly (end of next month, or yearly for small employers; **UNVERIFIED**), Karnataka the 20th, West Bengal the 21st. All **UNVERIFIED (carried over)**. Store due date rule per state.

---

## 5. Labour Welfare Fund (LWF)

State statutes (Bombay LWF Act and others). Amounts below from https://calcguru.in/?p=8381 (a 2026 state-wise guide) and the notes below it. The page itself tells readers to verify on state portals. All **UNVERIFIED** for primary sources.

| State | Employee | Employer | State govt | Periodicity | Due |
|---|---|---|---|---|---|
| Andhra Pradesh | ₹30 | ₹70 | nil | yearly | 31 Jan |
| Chandigarh | ₹5 | ₹20 | nil | monthly | 15 Apr / 15 Oct |
| Chhattisgarh | ₹15 | ₹45 (min ₹1,500 per establishment) | equal to employer | half-yearly | 15 Jul / 15 Jan |
| Delhi | ₹0.75 | ₹2.25 | ₹1.50 | half-yearly | 15 Jul / 15 Jan |
| Goa | ₹120 | ₹360 | ₹240 | yearly | statement by 31 Jul / 31 Jan |
| Gujarat | ₹6 | ₹12 | equal to employer | half-yearly | 15 Jul / 15 Jan |
| Haryana | 0.2% of wages capped (₹35 from 1 Jan 2026) | twice the employee | nil | monthly | 31 Dec |
| Karnataka | ₹50 | ₹100 | ₹50 | yearly | 15 Jan |
| Kerala (LWF Act 1975) | ₹45 | ₹45 | nil | half-yearly | 15 Jul / 15 Jan |
| Madhya Pradesh | ₹10 | ₹50 (min ₹2,500) | equal to employer | half-yearly | 15 Jul / 15 Jan |
| Maharashtra | ₹25 | ₹75 | ₹50 | half-yearly | 15 Jul / 15 Jan |
| Odisha | ₹20 | ₹40 | nil | yearly | 15 Jan / 15 Jul |
| Punjab | ₹5 | ₹20 | nil | monthly | 15 Apr / 15 Oct |
| Tamil Nadu | ₹20 | ₹40 | ₹20 | yearly | 31 Jul |
| Telangana | ₹2 | ₹5 | nil | yearly | 31 Jan |
| West Bengal | ₹3 | ₹15 | equal to employer | half-yearly | 15 Jul / 15 Jan |

Corrections noted in that page and other 2026 news:
- Maharashtra: Act 25 of 2024 removed wage slabs, so the flat ₹25 / ₹75 applies to every employee. (Remembered older slab: ₹12/₹36 for wages up to ₹3,000.)
- Madhya Pradesh: from 30 Jan 2026 the employer rate rose from ₹30 to ₹50 and the minimum from ₹1,500 to ₹2,500 (https://calcguru.in/?p=8414).
- Haryana: employee cap raised ₹34 to ₹35 per month from 1 Jan 2026, employer twice (https://www.scconline.com/blog/post/2026/05/11/haryana-labour-welfare-fund-contribution-revised-2026/amp/, https://teamleaseregtech.com/updates/article/55716/govt-of-haryana-revised-the-labour-welfare-fund-contribution-ceiling-from-january-2026/).
- Karnataka: calcguru's table adds a state share of ₹50, making ₹200 per employee; another guide says the employer remits ₹150 (₹50 + ₹100) including the state share. **Conflict**, so check which party remits what.
- Goa: calcguru says ₹120/₹360/₹240, and says commonly published ₹60/₹180/₹120 are half the statutory rate. **UNVERIFIED**.
- West Bengal: the portal was reported suspended and the Nov 2024 notification could not be retrieved. Check before paying.
- Tamil Nadu: supervisory employees above ₹15,000 are excluded since 2018 (per the page).
- States with no LWF payroll contribution: Bihar, Rajasthan, Jharkhand, Assam, Himachal, J&K/Ladakh, Sikkim, Arunachal, Manipur, Meghalaya, Mizoram, Nagaland, Tripura, Puducherry; UP and Uttarakhand have Acts but no payroll contribution (same page).
- Mechanics: LWF is a deduction from the employee plus an employer contribution. The "employee amount" is deducted in the month stated (e.g. December in Karnataka, June/December in Maharashtra). The employer share is an expense. Eligibility often excludes managerial staff by wage or role (state specific, **UNVERIFIED**).

---

## 6. TDS on salary, FY 2026-27 (Tax Year 2026-27)

### 6.1 Legal frame
- Salary TDS is **s.392 of the Income-tax Act 2025 (old s.192)**. Non-salary TDS is s.393 (old 193–194T). Applies to payments on or after 1 Apr 2026 (https://finlecture.in/?p=1932, https://www.taxscan.in/top-stories/how-will-the-new-income-tax-act-2025-impact-your-tds-compliance-1444580, https://taxguru.in/?p=1044146). **UNVERIFIED** (secondary).
- "Previous year / assessment year" becomes "Tax Year". FY 2026-27 is Tax Year 2026-27.
- Employee declaration: **Form 124** (replaces Form 12BB) for claiming deductions/exemptions in salary TDS (https://cleartax.in/s/form-124-income-tax, https://efiletax.in/blog/form-no-124-new-salary-tds-declaration-form-under-the-income-tax-act-2025). Standard deduction needs no declaration. Without Form 124, TDS is deducted with no deductions or exemptions claimed.
- Regime choice: new regime is the default. The employee may opt for the old regime for TDS purposes; the employee declares each year and can finally choose at ITR time. Rule reference **UNVERIFIED**.

### 6.2 New-regime slabs (Tax Year 2026-27)
Budget 2026 left slabs, rebate and standard deduction unchanged from FY 2025-26 (https://www.businesstoday.in/personal-finance/tax/story/tax-slabs-fy-2026-27-what-budget-2026-changed-for-individual-taxpayers-and-which-regime-works-best-514044-2026-02-01, https://www.bajajfinserv.in/income-tax-changes-for-fy-2026-27). **UNVERIFIED** against the Act schedule/Finance Act 2026; the 2025-Act section for the slab table is **UNVERIFIED** (new regime was old s.115BAC).

| Taxable income | Rate |
|---|---|
| up to ₹4,00,000 | nil |
| ₹4,00,001–8,00,000 | 5% |
| ₹8,00,001–12,00,000 | 10% |
| ₹12,00,001–16,00,000 | 15% |
| ₹16,00,001–20,00,000 | 20% |
| ₹20,00,001–24,00,000 | 25% |
| above ₹24,00,000 | 30% |
- **Standard deduction:** ₹75,000 for salaried employees in the new regime. ₹50,000 in the old regime. (One result showed a conflict for the old regime; ₹50,000 matches the pre-2024 rule. **UNVERIFIED**.)
- **Rebate (old s.87A):** tax is nil if total taxable income does not exceed ₹12,00,000; rebate capped at ₹60,000. Does not apply to special-rate income such as capital gains under s.111A/112A (**UNVERIFIED (carried over)**).
- **Marginal relief:** if taxable income is just above ₹12 lakh, tax is limited to the amount of income above ₹12 lakh. Example: taxable income ₹12,10,000 gives slab tax ₹61,500 but payable tax is ₹10,000 (+ cess ₹400). Relief ends at about ₹12.71 lakh (where 60,000 + 15% × excess = excess).
- **Cess:** 4% health and education cess on tax after surcharge and rebate.
- **Surcharge (new regime):** 10% above ₹50 lakh, 15% above ₹1 crore, 25% above ₹2 crore (max 25% in the new regime). Not applicable below ₹50 lakh. **UNVERIFIED (carried over)**. Marginal relief also applies at each surcharge threshold.
- **Not allowed in the new regime:** HRA, LTA, 80C, 80D, home loan interest on self-occupied property, standard PT deduction. **Allowed:** standard deduction, employer NPS contribution (old s.80CCD(2), up to 14% of basic+DA), transport allowance for specially-abled, gratuity/leave-encashment exemptions (s.10 items), certain reimbursements. 2025-Act section numbers **UNVERIFIED**.

### 6.3 Old-regime main deductions (for employees who opt in)
| Item | Limit |
|---|---|
| Standard deduction | ₹50,000 |
| HRA exemption | least of: HRA received; rent paid less 10% of salary; 50% (metros) / 40% of salary |
| LTA | two journeys in a 4-year block, actual fare |
| Section 80C (equivalent) | ₹1.5 lakh: EPF, PPF, ELSS, life insurance, tuition |
| NPS 80CCD(1B) | additional ₹50,000 |
| Health insurance 80D | ₹25,000 (₹50,000 senior) + parents |
| Home loan interest (self-occupied) | ₹2 lakh |
| PT paid | deductible |
| Old-regime slabs | nil to ₹2.5 lakh, 5% to ₹5 lakh, 20% to ₹10 lakh, 30% above |
- All **UNVERIFIED (carried over)** limits from the 1961 Act. Section numbers in the 2025 Act were not looked up: **UNVERIFIED**. Rebate in the old regime: nil tax up to ₹5 lakh, capped ₹12,500.
- Salary-TDS engine must evaluate both regimes and use the employee's declared one.

### 6.4 Monthly TDS projection method
Standard approach (CBDT employer practice; the Act requires "average rate" TDS on estimated income for the year):
1. At each payroll (and when the declaration changes), compute **estimated annual taxable salary** = salary already paid this tax year + current month + projected remaining months at the current structure + known/declared one-offs (bonus, arrears) − exempt allowances − standard deduction − Form 124 deductions (old regime) − professional tax (old regime).
2. Add other-income declared by the employee, and previous-employer income (Form 12B equivalent in the 2025 Rules, **UNVERIFIED**).
3. Compute annual tax by the regime, with rebate, marginal relief, surcharge and cess, rounded per rule (nearest ₹10 under the old s.288B; 2025 section **UNVERIFIED**).
4. Subtract TDS already deducted this year (own and previous employer).
5. TDS this month = (annual tax − TDS already deducted) ÷ remaining months including this month. Round to whole rupees.
6. **True-up:** when the estimate changes (increment, bonus, regime switch, new declaration, leaver), re-run; the revised monthly amount spreads the difference over the remaining months. The last month absorbs any rounding residue.
- Declared deductions not proven by documents (Jan-Feb proof submission) are re-run in Feb/Mar with the employee's proofs.
- A leaver: recompute at F&F; TDS on the F&F amount is the remaining annual tax difference.
- TDS cannot exceed the salary payable in the month in practice (excess carried forward); the Act has no exception, so the cap is a **payroll policy** (**UNVERIFIED**).

### 6.5 Arrears, previous employer, perquisites
- **Arrears/ex-gratia** are taxed in the year received; the employee can claim relief for tax paid on arrears of earlier years (old s.89 with Form 10E; 2025 equivalent **UNVERIFIED**). Add the arrears to the projection in the month paid.
- **Previous-employer income**: the employee gives the previous employer's gross salary and TDS (Form 12B was used; new form number **UNVERIFIED**). Add to income and subtract the TDS. If not given, the current employer only counts its own pay.
- **Perquisites**: employer-provided car, housing, interest-free loans above ₹20,000, ESOPs, club fees; valued under the Income-tax Rules. Add to taxable salary and TDS. Perquisite value rules are **UNVERIFIED (carried over)**. Employer-paid TDS on perquisite is itself a perquisite (non-monetary perq tax paid by the employer is exempt in some cases). Keep it brief in v1: model perquisites as taxable earning components.

### 6.6 Deposit and returns
- **Deposit:** by the **7th of the next month** (government deposit by the same day; March TDS by 30 April). (**UNVERIFIED** for the 2025 Rules: not found in sources I opened; the 2026 Rules' Rule numbers were not read.) Challan 281 successor not checked.
- **Quarterly statement:** salary TDS statement is **Form 138** under Rule 219 of the Income-tax Rules 2026 (https://www.incometaxindia.gov.in/documents/d/guest/fn-138; replaces Form 24Q). One source also mentions a "Form 140" for the quarterly statement and calls it unreliable. Due dates quoted: 31 Jul, 31 Oct, 31 Jan, 31 May (secondary sources disagree between 30th and 31st: https://studycafe.in/tds-and-tcs-due-date-compliance-calendar-for-tax-year-2026-27-419614.html, https://www.incorpx.io/blog/quarterly-tds-returns-new-it-act-2025). **UNVERIFIED**.
- **Annual certificate:** **Form 130** (replaces Form 16) for salary of Tax Year 2026-27, due **15 Jun 2027**; Form 131 replaces Form 16A for non-salary (https://www.india-briefing.com/news/form-130-tds-certificate-salary-income-tax-act-2025-45463.html/). Form 16 still applies for FY 2025-26 (due 15 Jun 2026). Penalty for late certificate was ₹100 per day under 1961 Act s.272A(2)(g); the article quotes ₹500 per day under the 2025 Act: **UNVERIFIED**.
- Employers need TAN, TRACES login, and PAN of every employee. Missing PAN means a higher rate (old s.206AA, 20%) (**UNVERIFIED (carried over)**).

### 6.7 Worked examples (new regime, Tax Year 2026-27)
Assumptions for both: employer PF on the ceiling (₹25,000 × 12% = ₹3,000/month = ₹36,000/year); gratuity provision at 4.81% of basic is inside CTC but not taxable until paid; no other income; no Form 124; no previous employer; PT is ignored (not deductible in the new regime).

**Example A: ₹9,00,000 CTC**
- Basic 40% = ₹3,60,000 (₹30,000/month). Employer PF: ₹36,000 (ceiling). Gratuity provision 4.81% × 3,60,000 = ₹17,316.
- Taxable gross = 9,00,000 − 36,000 − 17,316 = ₹8,46,684. Less standard deduction ₹75,000 = **taxable ₹7,71,684**.
- Slab tax: (7,71,684 − 4,00,000) × 5% = ₹18,584.
- Rebate (income ≤ ₹12 lakh): −₹18,584. **Tax = nil**, so monthly TDS nil.
- The employee still pays PF ₹3,600/month (12% × ₹30,000 if on actual) or ₹3,000 (restricted) and PT per state.

**Example B: ₹18,00,000 CTC**
- Basic 40% = ₹7,20,000 (₹60,000/month). Employer PF ₹36,000 (restricted to the ceiling). Gratuity provision 4.81% × 7,20,000 = ₹34,632.
- Taxable gross = 18,00,000 − 36,000 − 34,632 = ₹17,29,368. Less ₹75,000 = **₹16,54,368**.
- Slab tax: 4–8 lakh at 5% = 20,000; 8–12 lakh at 10% = 40,000; 12–16 lakh at 15% = 60,000; 16,00,000–16,54,368 at 20% = 10,873.60. Total = ₹1,30,873.60.
- Rebate: not available (income > ₹12.71 lakh). Cess 4% = ₹5,234.94. Total = ₹1,36,108.54, rounded to the nearest ₹10 = **₹1,36,110**.
- Monthly TDS = 1,36,110 ÷ 12 = **₹11,342.50 → ₹11,343** for 11 months and the residue in March (or ₹11,342 × 11 + ₹11,348).
- If the employee joins in July instead: project the income for only the 9 months in this employer's year (9/12 of salary), with a prorated standard deduction **not** applying: the full ₹75,000 is given to the employee in any case. Plus add previous employer income; the tax slabs are not pro-rated.
- Mid-year true-up example: bonus of ₹1,00,000 declared in October. Re-estimate: taxable income rises ₹1,00,000 at the 20% bracket, so annual tax rises by ₹20,000 × 1.04 = ₹20,800. Remaining months (Oct–Mar = 6) each carry +₹3,467 (rounding in the last month).

---

## 7. Gratuity

### 7.1 Formula and eligibility
- **Formula (SS Code s.53, old Payment of Gratuity Act s.4):** gratuity = last drawn wages × 15 ÷ 26 × completed years of service. Part-year over 6 months is counted as a full year (same under the Act; one source says Social Security (Central) Rules r.33 states it: https://www.patronaccounting.com/blog/gratuity-calculation-2026-one-year-rule-fixed-term-employees). SS Code section number and rule number **UNVERIFIED**.
- "Wages" = Code wages (basic + DA + retaining, with the 50% add-back, §1). New wage definition applies **prospectively from 21 Nov 2025** per Labour Ministry comments reported at https://www.legalserviceindia.com/Legal-Articles/gratuity-act-under-the-code-on-social-security-2020-employer-duties/ (**UNVERIFIED**). A conservative reading: for service up to 20 Nov 2025 compute on the old definition; after on the new. Progen should support a two-tranche computation or flag this open item.
- **Eligibility:** 5 years of continuous service on superannuation, retirement, resignation, death or disablement. For death or disablement the 5-year condition does not apply (**UNVERIFIED (carried over)**).
- **Fixed-term employees:** eligible after **one year** of service under the contract, pro-rata. IR Code s.2(o)(c) as quoted in LW §7, and PIB (https://www.pib.gov.in/PressReleasePage.aspx?PRID=2192524) ("earlier five years"). Fixed-term employees' gratuity is payable on the pro-rata completed years, for which 6+ months counts as one.
- Seasonal establishments: 7 days for each season (**UNVERIFIED (carried over)**).
- Applicability: establishments with 10+ employees on any day in the preceding 12 months, and continues once covered (**UNVERIFIED (carried over)**).

### 7.2 Ceiling, tax and deadline
- **Ceiling:** ₹20 lakh for private-sector employees (https://www.legalserviceindia.com/Legal-Articles/gratuity-act-under-the-code-on-social-security-2020-employer-duties/ and several guides). **UNVERIFIED**: I did not find a notification raising it. Central government ceiling is ₹25 lakh (separate rules).
- **Tax exemption:** gratuity is exempt up to ₹20 lakh, with the lowest of: the actual amount, ₹20 lakh, or the 15/26-formula amount (old s.10(10); new section **UNVERIFIED**). Covered employees get formula limited exemption; uncovered get half-month average salary per year. Business Today on the interaction of the new wage definition with tax: https://www.businesstoday.in/personal-finance/tax/story/new-labour-code-could-boost-your-gratuity-but-raise-your-tax-bill-heres-how-525962-2026-04-16.
- **Payment deadline:** within **30 days** of it becoming payable (old Act s.7(3)). Interest at the notified rate if late. SS Code section and the current interest rate **UNVERIFIED**.
- Nomination is required; keep nominee records.

### 7.3 Worked example
- Employee with Code wages ₹50,000 and 12 years 8 months of service. Part-year 8 months > 6 months, so 13 years.
- 50,000 × 15 ÷ 26 × 13 = **₹3,75,000**.
- Fixed-term employee: wages ₹30,000, 1 year 7 months → 2 years: 30,000 × 15 ÷ 26 × 2 = ₹34,615.38.

### 7.4 Provisioning
- Provision monthly/annually at 15/26 × wages ÷ 12 per employee (about 4.81% of wages) for eligible/likely-to-qualify employees (Ind AS 19 / AS 15 actuarial valuation is the accounting standard; practical ERP approximation uses the formula). The provision is not a tax deduction until paid, or paid to an approved fund (**UNVERIFIED (carried over)**).
- Keep an optional accrual account "Gratuity Fund / Group Gratuity Scheme (LIC)" for funded schemes.

---

## 8. Statutory bonus

- **Source:** Code on Wages s.26 and two notifications dated **25 Aug 2026** (https://www.scconline.com/blog/post/2026/08/26/bonus-rules-under-code-on-wages-eligibility-calculation/, https://factohr.com/?p=49064): eligibility ceiling **₹21,000/month**; calculation ceiling **₹7,000 per month or the minimum wage applicable (whichever is higher)**; both deemed effective from 21 Nov 2025. Secondary; notification numbers not confirmed. **UNVERIFIED** (S.O. 4711(E) is quoted by one source).
- **Eligibility:** wages not exceeding ₹21,000/month (the eligibility test uses Code wages); worked at least 30 days in the accounting year (LW §7).
- **Rate:** minimum 8.33% of wages earned or ₹100, whichever is higher; maximum 20% (LW §7). Between 8.33% and 20% depends on allocable surplus (old Act s.10/11); the Code's allocable-surplus mechanics are **UNVERIFIED**. Establishments without profit still pay the minimum.
- **Deadline:** within 8 months of the close of the accounting year (old Act s.19; Code s.39 — **UNVERIFIED**; not confirmed in the Code text I opened; and within one month of an award/settlement). Contract workers' bonus: principal employer pays minimum if the contractor fails (LW §6 / Rules r.21).
- **Proportional bonus:** for employees who worked less than the full year, bonus is on the days worked (worked days ÷ 365/12).
- **Set-on/set-off, disqualification** (dismissal for fraud, theft, violence) apply (**UNVERIFIED (carried over)**).

### Worked example
A worker with Code wages above ₹21,000 is not eligible, so use an eligible worker:
- Code wages ₹18,000/month, full year (12 months), minimum rate 8.33%.
- Calculation wage = max(₹7,000, applicable minimum wage). Assume a state minimum wage of ₹13,000/month (illustrative only; **use the real state/central rate**). Calculation wage ₹13,000. Annual calculation wages = ₹1,56,000.
- Bonus at 8.33% = ₹12,994.80 → **₹12,995**. At 20% = ₹31,200.
- With a calculation ceiling of ₹7,000 only (pre-notification reading): 8.33% × 84,000 = ₹6,997.20.
- Worker with 3 months' service in the year: 3/12 × the full-year amounts.

---

## 9. Leave

### 9.1 Earned leave (OSH Code and Shops & Establishments)
- OSH Code: annual leave with wages for a worker who has worked at least 180 days in a calendar year, at the rate of **1 day for every 20 days worked** (for factories and covered establishments; cited from the Code s.32 in the 2020 text; I did not open the passage in this session, **UNVERIFIED**). The central Rules (r.?) were not checked.
- Accumulation and carry-forward caps are set by the appropriate Government in rules. For factories, the old Factories Act cap was 30 days. **UNVERIFIED**.
- State Shops & Establishments acts remain in force during the transition (LW §1). Examples from memory, **UNVERIFIED (carried over)** for 2026:
| State | Earned/privilege leave | Casual | Sick | Carry forward |
|---|---|---|---|---|
| Maharashtra Shops & Establishments (Regulation of Employment and Conditions of Service) Act 2017 | 21 days paid leave a year, after 240 days | 8 days | 8 days | up to 45 days (**UNVERIFIED**) |
| Karnataka Shops and Commercial Establishments Act 1961 | 18 days paid (after 240 days) | 12 | 12 | up to 42 days |
| Tamil Nadu Shops and Establishments Act 1947 | 12 days after 240 days | 12 | 12 | not carried (**UNVERIFIED**) |
- Leave policy engine must be per company and state: leave types (EL/PL, CL, SL, comp-off, maternity, paternity, LOP), accrual rule (per period, per N days worked), probation lock, max balance, carry-forward cap, lapse date, encashable flag.

### 9.2 Encashment and tax
- Unavailed leave encashed during service is taxable salary.
- On retirement or resignation: exempt up to **₹25 lakh** for non-government employees (old s.10(10AA); limit raised from ₹3 lakh to ₹25 lakh from 1 Apr 2023). The 2025 Act section is **UNVERIFIED**. The exemption is also bounded by: 10 months' average salary, ₹25 lakh, the actual amount, and the leave-at-credit encashment formula (max 30 days per year of service). Average salary = average of the last 10 months' basic + DA + commission on turnover.
- The exemption is available in both regimes (**UNVERIFIED**).
- Encashment rate default: basic + DA ÷ 26 (or per company policy) × days.

### 9.3 Maternity
- SS Code (the Maternity Benefit Act moved into it): 26 weeks of paid leave for the first two children (8 before delivery), 12 weeks for the third child and beyond; 12 weeks for adopting or commissioning mothers; crèche required in establishments with 50+ employees; work-from-home option. Eligibility: 80 days worked in the preceding 12 months. This is from the Maternity Benefit (Amendment) Act 2017 carried into the Code. Section numbers **UNVERIFIED**; primary text not opened. LW §7 notes that the central rules carry a women-employee register (Form XXII).
- ESI covered women get maternity benefit from ESIC (a cash benefit at 100% of average daily wage for 26 weeks, **UNVERIFIED (carried over)**); in that case the employer does not pay wages for the period. Non-ESI employer pays from its own funds.
- Payroll: pay at the average daily wage; mark attendance as maternity leave (not LOP); suppress PF/ESI correctly (PF continues on paid maternity leave; ESI continues as per ESIC rules).

---

## 10. Full and final settlement (F&F)

- **Deadline (verified):** Code on Wages s.17(2): wages are payable "within two working days" of removal, dismissal, retrenchment, resignation or closure (LW §7). Secondary sources say "48 hours" (https://www.pockethrms.com/?p=74812, https://www.patronaccounting.com/blog/full-final-settlement-2-day-rule-labour-code); "two working days" is the statutory text. Whether the deadline runs from the last working day or the date of resignation acceptance: **UNVERIFIED**.
- **Components (what is wages for the two-day rule):** salary up to the last working day (pro-rata), leave encashment, bonus due, OT, notice-pay if the employer waives, retrenchment compensation (IR Code), and reimbursements. Gratuity and PF settlement have **their own** timeline (gratuity 30 days, §7; PF claim via EPFO). Many employers pay gratuity on the F&F date anyway.
- **Recoveries:**
  - Notice pay shortfall: the contract's notice period less served days × daily pay, **within the s.18 deduction heads and 50% cap** (LW §7). Whether notice-pay recovery is a lawful "deduction" is contested; it is not in the s.18(2) list. Treat it as a **claim**, not an automatic deduction (**UNVERIFIED** legal position).
  - Advances (s.23), loans, damage/loss (s.21): same 50% cap applies per wage period, with the excess carried forward (LW §7). In F&F there is no next wage period, so the excess becomes a recovery claim, not a deduction. **UNVERIFIED**.
  - TDS: true-up on the F&F amount (§6.4). LWF, PT: only if the period is due.
- **Statements:** F&F sheet, experience/relieving letter, Form 11 (PF transfer/withdrawal) data, UAN exit date (employer-updated), ESI exit date, nomination for gratuity, TDS Form 130 for the part year (still due 15 Jun 2027 as the normal annual certificate).
- Leave encashment on exit follows the company policy (§9.2). Gratuity applies if eligible (§7).
- **Notice pay for the employee:** if the employer terminates without notice, notice pay is paid in lieu. The tax and PF treatment: notice pay in lieu is salary (taxable; PF-wage status **UNVERIFIED**).

---

## 11. Attendance-to-payroll rules

Working time and OT law: LW §2 (OT at twice the normal rate, daily rate ÷ 8, monthly wage ÷ 26 for the daily wage, OT rounding to 30 minutes). Registers (Form IX etc.): LW §7. Below: payroll logic only.

### 11.1 Paid days and LOP divisor
| Method | Daily rate | Typical use |
|---|---|---|
| Calendar days | monthly ÷ actual days in month (28–31) | most offices; LOP varies by month |
| 30 days | monthly ÷ 30 | common in Indian payroll |
| 26 days | monthly ÷ 26 | **statutory** daily rate for monthly-paid employees (Code on Wages Rules r.3(2) multiples by 26; OSH Rules r.69(3) daily wage is 1/26) as in LW §2 |
| Working days | monthly ÷ working days in the month | some offices |
- Configure per company: `lopDivisor ∈ {calendar, 30, 26, workingDays}`. For OT base and statutory purposes, use 26 (LW §2). LOP deduction is a deduction for absence under s.20 and must be proportional to the absence (LW §7).
- Weekly offs and holidays: paid under a monthly wage. Under the 26 divisor, 4 weekly offs a month are already inside the monthly figure, so the paid days = 26 − LOP days (cap at 26). Under the calendar-day method the employee is paid for all calendar days minus LOP days. Choosing the divisor changes the payout for the same absences: example: monthly ₹31,000, 2 LOP days in a 31-day month: calendar method = 31,000 × 29/31 = ₹29,000; 30-day method = 31,000 × 28/30 = ₹28,933.33 (the 30-day method treats the 31st as unpaid additional day in some policies: avoid); 26-day method = 31,000 − 2 × (31,000/26) = ₹28,615.38.
- Pay-for-the-weekly-off rule: a weekly off or paid holiday that is **sandwiched** between LOP days can be treated as LOP in some company policies. Make it a policy flag.

### 11.2 Mid-month joiners and leavers
- Pro-rata by calendar days (joined on the 11th of a 30-day month: 20/30), or by paid days under the 26 method. Same divisor as LOP.
- Statutory handling:
  - EPF: wages for the days worked; NCP days = days not in service (ECR NCP column). Contribution on earned wages.
  - ESI: **days worked** for the month in the file; contribution on actual wages. A joiner covered from the date of joining (registration before or on the day, LW §4).
  - PT: PT slabs use the gross for the month; whether to prorate is state specific. Most states charge the full slab on actual gross. **UNVERIFIED**.
  - LWF: due if on payroll in the deduction month.
  - Leavers: pay wages within 2 working days (LW §7, §10).
- Mid-month salary revision: split the month into two segments at the old and new rates.

### 11.3 Overtime
- OT rate = 2 × (Code wages ÷ 26 ÷ 8) per hour for a monthly employee (LW §2; the central rule rounds the daily rate to the nearest rupee, with half a rupee up). OT is **excluded** from Code wages, PF wages, gratuity and bonus, but **included** in ESI wages (§3.2; **UNVERIFIED** for 2026), and taxable. Contribution consequence: OT can push an ESI employee over ₹21,000 in a month; because of the period rule (§3.3), only the period start matters.
- Daily wager: OT after 8 hours a day; others after 48 hours a week, whichever is more favourable (LW §2). Quarterly cap 144 h for construction etc. (LW §2).
- OT needs worker consent (LW §2); consent flag on each OT entry.
- Rounding of OT time: 15–30 minutes → 30 minutes; above 30 → 1 hour (LW §2, OSH r.69(2)).
- Rest-day work is OT-rate paid (LW §2, r.6).

### 11.4 Night shifts crossing midnight
- Assign the shift to the **calendar date on which it starts** (the "shift date"), and count the hours, for daily-limit purposes, for that shift as a single day. Muster roll: one in/out pair per shift date (Form IX in LW §7 records in/out per day; a shift that ends the next morning is shown on the start date).
- For attendance days: one shift = one working day, not two half days.
- Weekly-off and holiday handling for shifts crossing midnight: if the weekly off is a particular date, the portion after midnight falls on the off day. Policy: the shift date decides the whole shift (recommended; legal position on spread across weekly holiday is **UNVERIFIED**).
- Women working night shifts: state conditions (consent, safety, transport) vary; the OSH Code allows with consent and safeguards (**UNVERIFIED**; not opened this session). Record the consent.
- Night shift allowance is a taxable component; whether it counts as wages is the company's classification (§1.3).

### 11.5 Other attendance facts for payroll
- Late-mark policies (3 late marks = 1 half day) are company policy; a deduction must fit the s.18 list (LW §7).
- Paid holidays: national and festival holidays by state list; if worked, paid at the OT rate or compensatory off by policy.
- Half-days, short leave and comp-off: track as separate units, convert to paid days at payroll cut-off.

---

## 12. Privacy: DPDP Act 2023 and DPDP Rules 2025

### 12.1 Status
- The Digital Personal Data Protection Rules 2025 were notified on 13 Nov 2025 (published in the Gazette 14 Nov, per some sources). Only enabling rules (r.1, 2, 17 to 21) came into force at once; the main obligations on data fiduciaries start after 18 months, about **13 May 2027** (https://www.mondaq.com/india/data-protection/1713500/regulatory-update-notification-of-the-digital-personal-data-protection-rules-2025, https://www.tribuneindia.com/news/business/govt-notifies-digital-personal-data-protection-rules-rollout-in-phases-specified-obligations-for-data-fiduciaries). Consent-manager registration begins about 14 Nov 2026. A tracker computed for 9 Sep 2026 reports 19 of 44 sections in force. **UNVERIFIED** dates (law-firm and news sources only).
- Practical timeline for Progen: build the controls now; they bind customers from about May 2027.

### 12.2 Employment as a legitimate use
- **s.7(i) of the DPDP Act:** processing "for the purposes of employment or those related to safeguarding the employer from loss or liability" is a legitimate use for which consent is not needed (https://factohr.com/dpdp-act-2023/, https://elplaw.in/wp-content/uploads/2026/05/Processing-employee-related-data-Where-are-the-potential-boundaries.pdf). Commentators caution that this covers data genuinely tied to the employment relationship, not every conceivable use. **UNVERIFIED** reading.
- So: payroll, PF, ESI, TDS data (Aadhaar for UAN/ESI as the law requires, PAN, bank, family for nominees) rest on the legal-obligation / employment basis. Statutory fields do not need consent but still need a notice.
- **Consent likely needed (or a very clear necessity record):** continuous GPS tracking, face recognition or fingerprint (biometric) attendance, photos, location outside work hours, health data beyond statutory needs, marketing, and any data used for analytics unrelated to employment. Biometric data is not a separate "sensitive" class under the DPDP Act (unlike the repealed SPDI Rules), but necessity and proportionality, notice and purpose limitation apply (**UNVERIFIED** commentary).
- Prefer an alternative where possible: allow PIN/QR/manual attendance when an employee declines biometrics or GPS (consent must be freely given; an employee in a power imbalance can argue it was not).

### 12.3 Obligations Progen must support
- **Notice** (s.5 and Rules): itemised list of personal data, purpose, how to exercise rights, how to complain to the Data Protection Board. Present at first use of GPS/face attendance in the app, in English and local language (the Act allows the 22 scheduled languages).
- **Consent record**, when consent is the basis: who, what purpose, timestamp, version of notice, and withdrawal as easy as giving it. Withdrawal stops the processing from then on; data already needed for legal obligations stays.
- **Rights:** access, correction, erasure, grievance redressal, nomination. Employee self-service for view/correct; erasure requests handled with legal-retention holds.
- **Retention and erasure:** s.8(7): erase personal data once the purpose is served and consent withdrawn, unless law requires retention. Statutory floors, from LW §7: wage registers 5 years after the last entry; EPF/ESI/tax records, **UNVERIFIED** (EPF records: 5 years under the scheme; income-tax records: 6–8 years: **UNVERIFIED (carried over)**). Practical policy: keep payroll and statutory records at least the longest applicable statutory period, then anonymise or erase; keep **attendance GPS coordinates and face templates short** (for instance, delete raw GPS trails after 90 days and keep only the punch result; delete face templates on exit within 30 days). These periods are product choices, not law: **UNVERIFIED**.
- **Security and breach:** reasonable safeguards (encryption, access control, logs kept for a year per the Rules, **UNVERIFIED**) and breach notice to the Board and affected persons (72 hours for the detailed report, **UNVERIFIED**).
- **Processor role:** Progen is the **data processor** for its customers (the data fiduciaries). It needs a data-processing agreement, sub-processor list, and the ability to apply deletion on instruction.
- Children's data: employees under 18 (apprentices, trainees): verifiable parental consent is needed; no tracking or targeted behaviour monitoring (**UNVERIFIED** application to employment).

---

## 13. What Progen needs to build

### 13.1 Objects
| Object | Key fields |
|---|---|
| **Employee** | code, name, DOB, gender, joining date, probation end, exit date/reason, employment type (permanent, fixed-term with end date, trainee, contract, part-time), department, designation, work location (state, city, PT state), reporting manager, PAN, Aadhaar (consent flag, masked), UAN, ESI IP no., bank a/c + IFSC, nominee(s), international-worker flag, ESI "covered until" date, tax regime + Form 124 data, previous-employer income and TDS, LWF/PT applicability, DPDP consent records |
| **Salary structure / template** | components with calc rules (§1.4), CTC definition, effective-from/to, revision history (never overwrite) |
| **Employee salary assignment** | structure + component amounts, effective date range, pay group, `lopDivisor`, wage period (monthly) |
| **Payroll run** | company, period, status (draft, calculated, approved, paid, locked), cut-off, inputs snapshot, reversal run ID |
| **Payroll line (per employee per run)** | days (paid, LOP, OT hours), every component amount, statutory wages (EPF, ESI, PT, LWF, TDS), employee and employer shares, TDS projection details, net pay, bank status |
| **Payslip** | rendered from the payroll line; Form V fields (LW §7); PDF + in-app view; issued on or before payment |
| **Statutory challan/return data** | EPF (ECR text + challan summary), ESI (monthly contribution file), PT per state (form-wise), LWF per state, TDS (challan + Form 138 data + Form 130 data), Form 24Q-style annexures |
| **Loan / advance** | type (salary advance, loan, travel advance), amount, instalments schedule, interest, 50% headroom check (LW §7), recovered, balance, F&F recovery |
| **F&F case** | exit date, notice served, leave balance, encashment, bonus, gratuity, recoveries, TDS true-up, payment due date, letters |
| **Leave ledger** | opening, accrual, taken, lapsed, encashed, per leave type |
| **Attendance summary (input to payroll)** | paid days, LOP, OT hours by rate, shift allowances, from the attendance module |
| **Rule tables (data)** | see §13.4 |

### 13.2 Calculation rules (all money in integer paise)
- Store every amount as integer paise. Percentages as basis points or rational numbers, not floats. Intermediate results stay in paise; round only where a rule says.
- A `RoundingRule` per charge head, configurable (data):
| Head | Rule used by default | Source |
|---|---|---|
| EPF employee and employer EPF/EPS | nearest rupee (half up) | EPFO: admin charge nearest rupee (rate sheet); per-member rule **UNVERIFIED** |
| EPF admin 0.5%, EDLI 0.5% | nearest rupee at establishment total; admin min ₹500 | EPFO rate sheet |
| ESI employee and employer | **round up to the next rupee** | SS Central Rules r.19 (LW §4) |
| PT | per slab table (whole rupees) | state tables |
| LWF | per state table | state tables |
| TDS monthly | whole rupees; annual tax rounded to nearest ₹10 | old s.288B; 2025 section **UNVERIFIED** |
| OT hourly/daily rates | nearest rupee, half or more up (Code on Wages Rules r.3(2), LW §2) | LW §2 |
| LOP/pro-rata earnings | paise precision then nearest rupee on the line total (company option) | policy |
| Gratuity, bonus | nearest rupee | policy |
- Calculation order per run: (1) paid days and LOP; (2) component earnings pro-rated; (3) statutory wage bases (Code wages with 50% add-back, EPF wage with ceiling, ESI wage); (4) EPF/ESI; (5) PT/LWF by work state and month; (6) other deductions within the s.18 list and the 50% cap (LW §7); (7) TDS projection; (8) net pay. TDS runs last because earlier items alter taxable income (PT old regime, employer NPS).
- Deterministic and re-runnable: a locked payroll cannot change; corrections post as **supplementary runs** or arrears lines in the next run, with an audit trail.
- Net pay never below zero; excess recovery carries forward (LW §7).
- Effective-dated config: EPF ceiling (₹15,000 until 16 Sep 2026, ₹25,000 from 17 Sep 2026), ESI ceiling, bonus ceilings, rates, PT/LWF tables all carry `validFrom`/`validTo`; a retro run (for example the split September 2026) picks the row by date, with day-wise split for the month in which a ceiling changed.

### 13.3 Journal entries (use the existing accounting module)
Per payroll run (accrual basis on the pay date or the month end):
1. **Salary expense (Dr)**: Salaries and wages (basic, DA, allowances, OT, bonus accrual) by cost centre/department/project.
2. **Employer statutory expense (Dr)**: Employer PF (EPF + EPS), EDLI, admin charges, employer ESI, employer LWF.
3. **Statutory payables (Cr)**:
   - PF payable (employee + employer EPF + EPS + EDLI + admin)
   - ESI payable (employee + employer)
   - PT payable (state-wise)
   - LWF payable (state-wise; employee + employer)
   - TDS on salary payable
4. **Employee advances / loans (Cr)** when recovered.
5. **Net salary payable (Cr)**, cleared to bank on payment: Dr Net salary payable, Cr Bank.
6. **Remittance entries**: Dr PF/ESI/PT/LWF/TDS payable, Cr Bank, when the challan is paid (the challan reference and date stored).
7. **Gratuity provision (monthly)**: Dr Gratuity expense, Cr Provision for gratuity (15/26 × Code wages ÷ 12 per eligible employee; actuarial true-up yearly). Payment: Dr Provision, Cr Bank, any shortfall Dr Expense.
8. **Bonus accrual (monthly)**: Dr Bonus expense, Cr Bonus payable. **Leave encashment provision** (optional) Dr Leave expense, Cr Provision.
9. **F&F entry**: same pattern with the settlement components.
- Cost allocation: expense lines tag company, cost centre, project (feeds the construction pack's labour cost when applicable). Journals must balance in paise.

### 13.4 State-configurable tables (data, not code)
- `pt_slab(state, effectiveFrom, effectiveTo, gender?, periodicity, fromAmount, toAmount, amount, monthOverride(month→amount), annualCap)` and `pt_state(state, periodicity, dueDay, registrationType, active)` (Odisha inactive from 1 Apr 2026).
- `lwf_rate(state, effectiveFrom, employeeAmount, employerAmount, stateAmount?, periodicity, deductionMonths[], dueDates[], percentRule?, minPerEstablishment?, applicabilityRules)`.
- `statutory_param(code, effectiveFrom, value)`: EPF ceiling, EPF rates, admin min, ESI ceiling and rates, bonus eligibility/calculation ceilings, gratuity cap, tax slabs/rebate/standard deduction by regime and tax year.
- Seed from the tables in §4 and §5 as **draft** rows, each with a `verifiedBy` and `sourceUrl` field. Block "verified" status in the UI until a human has checked the state notification.
- Per-company overrides for statutory flags: PT enrolment number, LWF number, EPF code, ESI code, TAN.

### 13.5 Screens and outputs
- Salary-structure builder with live preview and the 50% add-back; employee salary assignment; payroll run wizard with variance review against the last month; payslip PDF and email; bank advice file (NEFT/CSV) per bank format.
- Statutory outputs: EPF ECR (`#~#` text), ESI file, PT/LWF challan data per state, TDS Form 138 data and Form 130 certificates, Form 124 collection, Form I/IV/V/IX registers (LW §7), gratuity register, bonus sheet, F&F statement.
- Compliance calendar with due dates (EPF/ESI 15th, TDS 7th, PT and LWF per state, quarterly TDS statement, Form 130 by 15 Jun, bonus within 8 months, gratuity 30 days, F&F 2 working days), overdue alerts.
- Employee self-service: payslips, tax declaration (Form 124), regime choice, leave, attendance regularisation, DPDP notice and consent.

### 13.6 Guardrails
- **Never hard-delete** payroll, payslip, attendance and F&F records. Retain at least five years (LW §7); soft-delete and anonymise personal data only after the retention period and with legal-hold checks (§12).
- **Lock** a payroll month after approval; reopening needs a reason and a role with permission, and writes an audit log. Role split: HR prepares, finance approves, an auditor reads.
- Mask Aadhaar (last 4 digits), PAN, bank number in UI and logs; encrypt at rest; field-level permission for salary data; export logging.
- **Aadhaar** collected only where law requires (UAN/ESI/appointment), with a consent flag (LW §6, OSH r.6).
- **Statutory data is configuration with a verification state.** Show "unverified" badges on PT/LWF rows. Do not silently default to a rate that has not been confirmed.
- Warn (do not block) on: wages below the state minimum (LW §3), EPF ceiling mismatch, ESI covered-until mismatch, PT state mismatch with work location, negative net pay, more than 50% deductions (LW §7), OT above the cap (LW §2).
- Block on: no appointment letter on file (LW §8), missing PAN/UAN where mandatory (warn for the first run, block for statutory filings), duplicate bank accounts across employees (flag for review).
- A TDS projection must show the working (annual estimate, tax computed, tax paid, balance, months left) so the employee and auditor can follow.
- Do not present Progen's PT/LWF/TDS outputs as legal advice; each customer's statutory registrations remain their duty. Add a "last reviewed" date on each rule table and a yearly review task in April and October (EPF/ESI/VDA changes happen near those dates).
- Biometric/GPS: off by default, per-company switch, notice shown before first use, an alternate method available; store face templates as non-reversible templates, not images; retention timers enforced by a job (§12.3).

### 13.7 Open items to confirm before go-live
1. Primary text of the Code on Wages s.2(y) exclusions and how "special allowance" counts toward the 50% test; the Labour Ministry's FAQ on this.
2. Whether the EPF admin ₹500 minimum and EDLI 0.5% are unchanged under the Code and the current interest/damages rates for late EPF.
3. VPF reporting in the ECR, the ECR 2.0 field list and international-worker exemption handling.
4. ESIC ceiling (₹21,000) and whether the ₹176 exemption and the "stay covered until period end" rule continue under the SS Code rules; the due date of ESI contributions.
5. Every PT slab in §4, especially Karnataka, Gujarat, Kerala, Assam, Meghalaya, Sikkim, Bihar, Jharkhand, Punjab, Goa. Whether the Odisha repeal was converted into an Act.
6. Every LWF amount in §5, especially Karnataka's share split, Goa, West Bengal and Telangana.
7. Income-tax Act 2025 section numbers for slabs, rebate, s.10-type exemptions (gratuity, leave encashment, HRA), s.16-type deductions, the Rules 2026 numbers for Forms 124, 130, 138, and the quarterly due dates; the TDS deposit due dates under the 2026 Rules.
8. Gratuity ceiling (₹20 lakh) and the SS Code/Rules section numbers; handling of the 21 Nov 2025 cut-over.
9. Bonus: notification numbers, allocable surplus mechanics, payment deadline under the Code.
10. State Shops & Establishments leave tables and the OSH Code leave rules in the Central/State rules.
11. DPDP: final commencement dates, rules on retention and breach timelines, the extent of s.7(i).
