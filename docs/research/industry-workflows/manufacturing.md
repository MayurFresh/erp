# Manufacturing workflows

Checked 2026-11-03. Builds on ../industry-verticals.md section 1. Master plan: section 6.4. Profile: ../competitor-profiles/epicor-kinetic.md. Job-work and labour rules: ../labour-wages.md and ../gst-einvoice-ewaybill.md.

## Scope
- Small and mid-size discrete and process manufacturers (10-500 staff).
- BOM, routing, production orders, material issue, scrap, costing, subcontract (job work), basic quality.
- Out of scope now: MES with machine integration, finite scheduling, PLM, advanced planning.
- Maintenance (CMMS) is a possible add-on and is covered by MaintainX, Fiix and similar products.

## End-to-end workflow
1. Item master with finished goods, raw material, semi-finished and packing.
2. BOM with versions, yield and scrap factors; routing with work centres.
3. Demand: sales order, forecast or reorder level.
4. MRP run: net requirement against stock, open POs and open production orders.
5. Purchase requisitions to purchase orders; goods receipt and incoming inspection.
6. Production order released; materials reserved.
7. Material issue to the shop floor, by backflush or manual issue.
8. Shop-floor reporting: quantity done, scrap, rework, hours, machine time.
9. In-process and final inspection with accept, reject, rework.
10. Finished goods receipt into the warehouse, with batch or serial.
11. Dispatch against sales order, invoice, e-way bill.
12. Cost roll-up: material, labour, overhead; variance against standard.
13. Job work: send material to a vendor on a challan, receive processed goods, reconcile loss.

## Key entities and states
- BOM: draft, approved, obsolete.
- Production order: planned, released, in progress, completed, closed, cancelled.
- Operation: not started, running, paused, done.
- Inspection lot: pending, accepted, rejected, rework.
- Job-work challan: issued, partly received, closed, overdue.
- Batch: created, quarantined, released, expired, blocked.

## India specifics
- Job work: GST challan flow, time limits for return of inputs, ITC on job-work goods: ../industry-verticals.md section 1; challan and e-way bill handling: ../gst-einvoice-ewaybill.md.
- Subcontracting vendors under the labour laws: ../labour-wages.md.
- Many small units keep costing in Excel or Tally (section 1). Progen's ledger link is the hook.
- BIS and industry-specific certificates: UNVERIFIED here; see section 1.

## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Epicor Kinetic | Mid-market discrete | UNVERIFIED | Production, MES, planning, quality; Prism AI | n | epicor.com (via search) |
| Infor CloudSuite Industrial | Mid-market discrete | UNVERIFIED | Financials to shop floor, quality | n | docs.infor.com |
| QAD (Adaptive ERP, Redzone) | Manufacturers, supply chain | UNVERIFIED | Redzone is a frontline workforce product; ERP detail not found | n | search summary |
| Plex (Rockwell) | Cloud ERP and MES | UNVERIFIED | Real-time shop floor data (low-quality source) | n | search summary |
| MRPeasy | Small manufacturers | UNVERIFIED for India | Pricing page blocked (403) | UNVERIFIED | mrpeasy.com |
| Katana | Small product brands | UNVERIFIED for India | Free plan up to 30 SKUs; Advantage plan custom | partly | katanamrp.com/pricing |
| Tulip | Frontline apps and traceability | UNVERIFIED | No-code shop-floor apps, agents, connectors (2026 additions) | n | arcweb.com |
| MaintainX | Maintenance and work orders | UNVERIFIED for India | Basic $0; Essential $20-25; Premium $65-75 per user per month; currency not stated | y | getmaintainx.com/pricing |
| Tally, Busy, Zoho, ERPNext, Odoo | India SMB base | India | See competitor-master.csv | mixed | competitor-master.csv |

## Table stakes vs differentiators
- Table stakes: multi-level BOM, production order, material issue, finished goods receipt, scrap, batch, cost roll-up, GST invoice, job-work challan.
- Differentiators: job-work reconciliation inside the books, backflush with actual variance, simple inspection plans, one system from PO to e-way bill.
- Later: MRP with lead times, finite scheduling, MES, machine data, PLM.

## Edge cases to test
- BOM change while a production order is released.
- Co-products and by-products with cost split.
- Scrap found after finished goods receipt.
- Backflush with insufficient raw material.
- Unit conversion (kg to metres) with yield loss.
- Job-work goods not returned within the time limit.
- Negative stock caused by late material issue entry.
- Rework creating a second production order.
- Batch recall tracing to customers.

## What Progen can reuse from its core
- Items, units, stock, locations, transfers, GRN, purchase orders, reorder, stock counts, fixed assets (for machines), work orders (construction pack's work orders are a different object), subcontract modules (subcontract-common.ts in construction pack), approvals, e-way bill.
- Construction labour and subcontract billing patterns map to job-work vendors.

## Smallest useful Progen slice
- BOM and production order with manual material issue and finished goods receipt, scrap, cost roll-up posted to the ledger, batch tracking.
- Job-work challan out and in, with loss reconciliation.
- No MRP engine at first; use reorder levels.

## Rough effort and priority
- Slice: M to L. MRP: M. Quality plans: S to M. MES: L.
- Priority: high on the roadmap (after warehouse depth and HR).

## Open questions
- Costing method target: standard or actual or both?
- How many customers need job work first versus in-house production?
- Do small units want machine-hour costing?
- MRPeasy and Katana India availability and price need confirmation.

## Sources
- https://katanamrp.com/pricing/
- https://www.getmaintainx.com/pricing
- https://docs.infor.com/csbi/2023.x/en-us/solution_overview_cl_sl/gxa1667486641791.html
- https://www.arcweb.com/node/164298
- ../industry-verticals.md, ../competitor-master.csv
