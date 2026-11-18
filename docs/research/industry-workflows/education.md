# Education workflows
Checked 2026-11-03. Builds on ../industry-verticals.md section 7 (schools, coaching and education).
## Scope
Schools and coaching institutes: admissions, student records, fee collection, attendance, timetable, exams, parent portal. LMS stays external.
## End-to-end workflow
1. Enquiry and admission. 2. Student and guardian records. 3. Fee structure per class and category. 4. Fee demand, collection, receipt. 5. Attendance and timetable. 6. Exam marks and report card. 7. Concessions, dues and year-end promotion.
## Key entities and states
Admission: enquiry, applied, admitted, enrolled, withdrawn. Fee demand: due, part paid, paid, waived. Student: active, transferred, alumni.
## India specifics
GST on education services is mostly exempt but some items are taxable; fee receipts for 80C certificates; board formats (CBSE, ICSE, state): ../industry-verticals.md section 7. Details UNVERIFIED here.
## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Fedena | Schools and colleges | Yes (CBSE, ICSE, state boards named) | Admission, fees, timetable, exams, parent apps; claims 40,000+ institutions | n (links to a plans page) | fedena.com |
| Ellucian | Higher education | UNVERIFIED | Banner and Colleague; not researched | n | vertical-competitor-master.csv |
## Table stakes vs differentiators
Table stakes: admissions, fee collection and receipts, attendance, report cards, parent app. Differentiators: fees posted to the ledger, instalment and late-fee rules, concession approvals, transport and hostel fees.
## Edge cases to test
Mid-year admission with prorated fee; sibling discount; fee refund on withdrawal; cheque bounce; fee head changes after demand raised.
## What OneMatrix can reuse from its core
Parties, invoices and receipts, series, approvals, custom fields, notifications, reports.
## Smallest useful OneMatrix slice
Student as a party, fee structure, demand, receipt, dues report. No exams.
## Rough effort and priority
S to M. Priority: low.
## Open questions
Do schools prefer one vendor for fees plus exams? Is WhatsApp fee reminder a must?
## Sources
https://www.fedena.com/ ; ../industry-verticals.md
