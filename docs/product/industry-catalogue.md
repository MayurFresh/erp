# Industry catalogue

All verticals named in master plan §5.1 Layer C (14 groups), mapped to the state of OneMatrix on 2026-11-03. Statuses: shipped (in the code), partial (some of the group's features exist), planned (vX.Y) (on the roadmap in `docs/plan/ubos-discovery-and-plan.md` §4), later (no release assigned; needs domain research first, master plan §I).

Priority column comes from `docs/research/industry-verticals.md` (vertical summary) where that note covers the vertical. Blank means not researched there.

| Vertical (master plan §5.1) | Status | What exists or is planned | Research priority |
| --- | --- | --- | --- |
| Commerce (OMS, channels, settlements, courier) | partial | Shipped (v1.8, built, release checks pending): sales orders, reservations, pick, pack, dispatch, shipments, returns and RTO (`modules/sales-orders.ts`, `fulfilment.ts`, `shipments.ts`, `sales-returns.ts`). Planned (v1.9): channel connectors, SKU mapping, settlement reconciliation. Planned (v1.10): courier aggregator, labels, manifests. | wedge |
| Retail and wholesale (POS, loyalty, B2B, dealers) | partial | Trading core exists: invoices, parties, credit notes, purchases. Not built: POS, loyalty, variant matrices, price lists, B2B portal. Later (retail POS, B2B portal). | High (retail), medium pack (distribution) |
| Restaurant and food | later | Nothing built. | Medium |
| Hospitality | later | Nothing built. | Low (hotel PMS) |
| Manufacturing | planned (v1.13) | BOM, MRP, production orders, job work, quality checks. Nothing built; stock ledger and purchasing are the base. | High |
| Logistics (TMS, fleet, 3PL) | later | Shipments exist for outbound orders only (`shipments` table). No transport management. | Medium (GTA) |
| Media and creative | later | Nothing built. | not researched |
| Professional services | partial | Invoicing, expenses, projects exist (`modules/projects.ts` is construction-oriented). No timesheets, retainers or client portal. | Medium; research says no pack needed |
| Healthcare administration | later | Nothing built. | Medium (clinic), low (hospital) |
| Education | later | Nothing built. | Low |
| Construction and real estate | shipped | Construction: projects, BOQ, indents, material issue, DPRs, labour and wages, subcontract work orders, RA bills (`003_construction.sql`, `006_phase2b.sql`). Real estate: units, payment plans, bookings, demands. Not built: equipment, lease and rent, property maintenance. | built |
| Agriculture | later | Nothing built. | Low to medium (agri and mandi) |
| Automotive | later | Nothing built. | Low to medium (workshop) |
| Events and venues | later | Nothing built. | not researched |

## Verticals in the research note that are not master-plan groups

Pharma distributors (batch and expiry, high priority), jewellery, NGOs and trusts. Pharma needs batches and expiry, which are planned (v1.10) in core. The others are later.

## Shared building blocks several verticals need

From the paragraph after the vertical summary in `docs/research/industry-verticals.md`:

| Block | State |
| --- | --- |
| Batch and expiry, FEFO | planned (v1.10) |
| Serial numbers | planned (v1.10) |
| Bins | planned (v1.10) |
| Multi-unit conversion | not built; no release assigned |
| Offline queue with conflict rules | planned (v1.10) |
| Licence and document expiry reminders | shipped (`modules/compliance.ts`, `compliance_docs`) |

## Rule

One vertical per release, each after domain research and with a pilot business (plan §6, master plan §I).
