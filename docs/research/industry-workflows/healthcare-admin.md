# Healthcare administration workflows
Checked 2026-11-03. Administration only. Clinical records are out of scope (master plan: dedicated secure clinical domain). Builds on ../industry-verticals.md sections 5 and 6.
## Scope
Clinic and small-hospital front desk: registration, appointments, OPD billing, pharmacy stock, lab orders as a billing item, consent and access audit.
## End-to-end workflow
1. Patient registered. 2. Appointment booked. 3. OPD visit and token. 4. Services and medicines billed. 5. Payment or insurer or TPA claim. 6. Pharmacy and consumable stock update. 7. Daily collection report.
## Key entities and states
Appointment: booked, arrived, in consult, done, no-show, cancelled. Bill: draft, issued, paid, refunded. Claim: submitted, approved, rejected, settled.
## India specifics
GST exemption for healthcare services and taxable medicines, drug licence and batch rules, patient data privacy under the DPDP Act: ../industry-verticals.md sections 5 and 6 (rates not restated; DPDP detail UNVERIFIED here).
## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Clinizy Care | Clinics, small hospitals | India | Registration, OPD, GST billing, basic pharmacy | UNVERIFIED | getapp.com.au listing |
| DocPulse | Clinics | India | Appointments, billing, records | UNVERIFIED | docpulse.com |
| SoftClinic, ClinicAdmin | Clinics, hospitals | India, Africa, Middle East | Not verified beyond listings | UNVERIFIED | selecthub.com |
## Table stakes vs differentiators
Table stakes: registration, appointments, OPD bill, receipts, pharmacy stock, reports. Differentiators: books and GST built in, TPA claim tracking, access audit log, batch and expiry on pharmacy.
## Edge cases to test
Refund after a pharmacy return; package bill with split tax treatment; patient merge of duplicates; consent withdrawn; audit trail for record access.
## What OneMatrix can reuse from its core
Parties, items with batch and expiry (planned), invoices, credit notes, stock, audit, approvals, files.
## Smallest useful OneMatrix slice
Patient as a party, appointments, OPD billing, pharmacy stock. No clinical notes.
## Rough effort and priority
M. Priority: low to medium (pharmacy distributor pack comes first, per industry-verticals.md).
## Open questions
Is a clinical-records vendor integration wanted? Who owns DPDP consent design?
## Sources
https://www.getapp.com.au/software/2291297/clinizy-care ; https://www.selecthub.com/p/medical-software/softclinic-genx/ ; ../industry-verticals.md
