# Coverage review, November 2026

What OneMatrix has, what rivals have that OneMatrix lacks, which Indian rules changed, and the build order. Based on a code audit and web research on 2026-11-13. Rows marked "unconfirmed" came from secondary sources and need a CA or an official notice before the numbers go into the app.

## Where OneMatrix is already ahead

- One product covers accounting, GST and TDS filing, stock, purchases, manufacturing, payroll and 13 sector modules. Rivals sell these as separate apps (Zoho Books + Inventory + Payroll + CRM) or leave them out (Vyapar, myBillBook have no manufacturing, payroll depth or sector modules).
- GSTR-1, 3B, 2B reconciliation and GSTR-9 built in; MSME 45-day dues report; fixed assets with Companies Act and IT block depreciation; consolidation across companies.
- Roles per business type, approvals, audit log, period lock, API keys and webhooks, Tally export.

## Gaps, by area

### CRM (none exists today)
- Leads with source (IndiaMART, JustDial, website form, walk-in, referral), owner, and duplicate check against parties.
- Deals with stages, probability, expected close date, won/lost reason; the deal becomes a quotation, then a sales order or invoice, with no retyping.
- Follow-ups: calls, meetings, tasks with due time; overdue list; one-tap call and WhatsApp.
- Contact persons per party (today a party has one phone and one email).
- Customer page: everything about one customer in one timeline, with what they owe, credit limit, 12-month sales and how fast they usually pay. Rivals' CRMs cannot show this without syncing to accounting.
- Targets per salesperson and commission.
- Lead capture: IndiaMART Pull API (key from seller.indiamart.com, one call per 5 minutes at most, dedupe on the query id), a website form endpoint using the existing API keys. JustDial and TradeIndia need an account manager; later.
- Calculations: weighted pipeline (value x probability), win rate (won / closed), average deal size, sales cycle days, stage conversion, target achievement and gap, pipeline coverage (open pipeline / remaining target), lead response time (first activity minus lead created).

### Selling
- Quotation (estimate) and proforma invoice. Today the first document is a sales order.
- Price lists and customer-specific prices; bill-level discount; schemes (buy 10, get 1 free).
- Credit limit check on invoices and sales orders (the limit is stored but never checked).
- Customer statement PDF; scheduled payment reminders (today they are sent by hand); interest on overdue.
- Recurring invoices outside memberships (rent, retainers, AMC).
- Export invoice under LUT, multi-currency with exchange gain or loss, delivery challan document.
- TCS on sales where it still applies.

### Buying
- Purchase return and debit note to a vendor, with the GST reversal.
- Landed cost (freight, customs spread over the goods).
- Request for quotation and side-by-side comparison of vendor quotes.
- GST Invoice Management System: accept, reject or keep pending per supplier invoice before GSTR-2B and 3B (unconfirmed details).
- 43B(h) disallowance figure for unpaid MSME dues at year end.

### Stock
- FIFO valuation as an option (today weighted average only).
- Unit conversion (box of 12, kg and gram).
- Stock ageing report; barcode label printing.
- Batches, expiry and serials currently live in the warehouse sub-ledger only; decide whether they should drive stock value.

### Accounts and reports
- Cash flow statement (today only a monthly cash chart), ratio analysis, year-end close with carry forward.
- Budgets vs actual for any company (today construction only).
- Cheque printing and a post-dated cheque register.

### HR and payroll
- Gratuity, full and final settlement, statutory bonus, leave encashment, shifts and overtime.
- Employee expense claims and salary advances or loans.
- Form 16 and 24Q; the 26Q file is a draft only.

### Service businesses
- Helpdesk tickets with response targets; AMC and service contracts with visit schedules; timesheets with time billing.

### Platform
- Global search; scheduled reports by email; SMS; Hindi and other languages; offline billing.
- UPI payment links with automatic matching (needs a Razorpay or Cashfree merchant account).
- Bank feeds through Account Aggregator (only regulated entities can be data users, so this needs a licensed partner; later).
- Bill photo to purchase entry (OCR).

## Rules that change calculations

| Rule | Change | From | Status |
|---|---|---|---|
| Income-tax Act 2025 | Replaces the 1961 Act. TDS sections renumbered (salary 192 to 392, most others into 393, TCS into 394); Form 16, 26AS, 24Q, 26Q get new numbers; "tax year" replaces PY/AY. Older deductions keep old codes. | 1 Apr 2026 | Unconfirmed. Affects every TDS screen, return and certificate made for deductions since April. Highest priority to confirm. |
| GST rates | Slabs become 5%, 18% and 40% (plus nil). Rates must be looked up by invoice date so old invoices and their credit notes keep old rates. | 22 Sep 2025 | Unconfirmed date; check our rate table. |
| Compensation cess | Ends on tobacco goods, replaced outside GST. | 1 Feb 2026 | Unconfirmed |
| GSTR-3B | Auto-filled outward tax is locked; fixes go through GSTR-1A. | July 2025 period | Advisory seen (state site copy) |
| E-invoice | Businesses with turnover of 10 crore or more must report within 30 days or the IRN is refused. | 1 Apr 2025 | Official notice on einvoice6.gst.gov.in |
| E-way bill | Not allowed for documents older than 180 days. | 1 Jan 2025 | Official notice family; 2FA date unconfirmed |
| TDS thresholds | 194J 50,000; 194A thresholds raised; 206C(1H) removed. | 1 Apr 2025 | Unconfirmed |
| New regime | Nil tax up to 12 lakh through the 87A rebate; standard deduction 75,000. | FY 2025-26 | Unconfirmed for FY 2026-27 |
| Labour Codes | Pay left out of "wages" above 50% of total pay is added back (affects PF, gratuity, leave encashment); gratuity for fixed-term staff after one year. | 21 Nov 2025 | Unconfirmed |
| EPF wage ceiling | Reported raised from 15,000 to 25,000. ESI stays 21,000. | 17 Sep 2026 | Unconfirmed; make ceilings dated settings, not constants |
| WhatsApp API | Per-message pricing; accounts must move to INR billing by 31 Dec 2026 or delivery stops. | 1 Jan 2027 | From Meta's developer page |

## Build order

1. CRM: leads, deals, follow-ups, contact persons, customer page, quotations and proforma, targets, IndiaMART pull, the pipeline calculations.
2. Selling and buying gaps: purchase return and debit note, credit limit check, price lists, bill discount, customer statement, scheduled reminders, recurring invoices.
3. Compliance: dated TDS section map and new form names, Form 16 and 24Q, dated PF/ESI ceilings, gratuity, full and final, bonus, leave encashment, IMS actions, e-invoice 30-day warning, e-way 180-day check, 43B(h) figure.
4. Accounts and stock: cash flow statement, ratios, year-end close, budgets for all, cheques and PDC, FIFO, unit conversion, stock ageing, landed cost, RFQ, labels.
5. Service and platform: tickets, AMC contracts, timesheets, expense claims and loans, global search, scheduled reports, export invoices and multi-currency.

Needs the owner: a CA to confirm the "unconfirmed" rows; an IndiaMART seller account for the lead key; a Razorpay or Cashfree merchant account for payment links; WhatsApp Business account moved to INR billing.

## Sources

- IndiaMART Pull API: https://help.indiamart.com/knowledge-base/lms-crm-integration-v2
- Pipeline formulas: https://support.pipedrive.com/article/probability-in-pipedrive , https://knowledge.hubspot.com/forecast/use-the-forecast-tool
- E-invoice 30-day limit: https://einvoice6.gst.gov.in/content/revised-time-limit-for-e-invoice-reporting-for-businesses-with-aato-of-%E2%82%B910-crores-above/
- Budget 2026 FAQ: https://incometaxindia.gov.in/Documents/Budget2026/FAQs-Budget-2026.pdf
- WhatsApp pricing: https://developers.facebook.com/documentation/business-messaging/whatsapp/pricing
- Zoho Books India pricing: https://www.zoho.com/in/books/pricing/
- Account Aggregator: https://financialservices.gov.in/account-aggregator-framework
