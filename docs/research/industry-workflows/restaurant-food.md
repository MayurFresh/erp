# Restaurant and food workflows

Checked 2026-11-03. Builds on ../industry-verticals.md section 4. Master plan workflow: section 6.3. Profiles: ../competitor-profiles/petpooja.md and ../competitor-profiles/toast.md.

## Scope
- Dine-in, takeaway and quick-service restaurants, cafes, cloud kitchens.
- Multi-outlet brands with a central kitchen.
- Delivery aggregator orders (Zomato, Swiggy and similar).
- Out of scope now: hotel banquets (hospitality.md), food manufacturing (manufacturing.md), staff rostering depth.

## End-to-end workflow
1. Menu, modifiers, combos, taxes and prices set per outlet.
2. Order taken by waiter, counter, QR or a delivery channel.
3. Order checked against item availability (86 list).
4. KOT printed or sent to kitchen display by station.
5. Kitchen marks items preparing, ready, served.
6. Table actions: transfer, merge, split bill.
7. Ingredients deducted by recipe, or later by actual count.
8. Discount, void and complimentary need a reason and a role check.
9. Bill with GST and service charge; payment by cash, UPI, card or wallet.
10. Shift and outlet settlement: cash, card, UPI, aggregator payouts.
11. Daily stock count, wastage entry, variance against recipe.
12. Purchase orders to vendors and indents to the central kitchen.
13. Aggregator payout reconciliation with commission and tax.

## Key entities and states
- Order: open, sent to kitchen, partly served, billed, paid, closed, voided.
- KOT item: queued, preparing, ready, served, cancelled (with reason).
- Table: free, occupied, bill printed, cleaning.
- Delivery order: received, accepted, prepared, dispatched, delivered, cancelled, disputed.
- Shift: open, closed, reconciled.
- Recipe: version with yield and unit conversion.

## India specifics
- GST on restaurant service, ITC rules, composition scheme, service charge treatment: ../industry-verticals.md section 4. Rates not restated.
- FSSAI licence number on the bill and licence expiry tracking: section 4.
- Aggregators collect the customer payment and remit net of commission. TCS and TDS apply to the aggregator payout: see ../ecommerce-marketplaces.md and ../statutory-core.md.
- Zomato and Swiggy integrations are normally through middleware such as UrbanPiper (UrbanPiper site lists Swiggy, Zomato, UberEats, Talabat).

## Leading products
| Product | Segment | India availability | Notable features | Pricing published | Source |
| --- | --- | --- | --- | --- | --- |
| Petpooja | Restaurant POS and back office | India | Billing, KOT, tables, inventory, payroll, GST invoice | n | petpooja.com |
| Restroworks (ex Posist) | Enterprise and multi-outlet | India, 42+ countries claimed | POS, KDS, central kitchen, recipe, forecasting, 400-500 integrations claimed | n | restroworks.com |
| UrbanPiper | Delivery aggregation middleware | India and other countries | Hub, Meraki ordering, Orderline AI | n | urbanpiper.com |
| Toast | Restaurant POS and payments | No India sales found | POS, KDS, payroll, Toast IQ | partly | support.toasttab.com |
| Oracle Simphony | Enterprise restaurant POS | Global, 180 countries claimed; India UNVERIFIED | Open API, 200+ partners | n | oracle.com |
| Lightspeed Restaurant | SMB POS | UNVERIFIED | POS, payments, reservations, inventory | n (403 on fetch) | lightspeedhq.com |
| Square for Restaurants | SMB POS | UNVERIFIED for India | Free and Plus plans exist; prices not read | UNVERIFIED | squareup.com |
| Deliverect | Delivery integration | UNVERIFIED for India | Order and menu integrations | UNVERIFIED | vertical-competitor-master.csv |
| MarketMan | Inventory and procurement | UNVERIFIED for India | Integrates with UrbanPiper | UNVERIFIED | marketman.com/partner/urbanpiper |

## Table stakes vs differentiators
- Table stakes: tables, KOT print, GST bill, split bill, modifiers, shift close, aggregator orders, daily sales report, recipe stock deduction.
- Differentiators: books built in (no export), aggregator payout reconciliation with TCS and TDS, central kitchen indents, actual-versus-theoretical variance, anti-theft audit trail (Restroworks sells this), offline billing.
- Later: self-order kiosk, voice ordering (UrbanPiper Orderline AI), forecasting.

## Edge cases to test
- Item sold while out of stock on an aggregator.
- Modifier that changes price and recipe.
- Bill split by item and by seat with one discount.
- KOT cancelled after the kitchen started.
- Void after payment and after shift close.
- Combo with items taxed at different rates.
- Aggregator order cancelled after dispatch.
- Recipe unit conversion (kg to g to piece).
- Table transfer with a running KOT.
- Power cut mid-bill; sync of offline bills.

## What Progen can reuse from its core
- Items, units, locations, stock, transfers, indents (construction module has indents), purchase orders, GRN, parties, approvals, audit, invoices and the journal engine.
- Batch and expiry (planned core building block, see ../industry-verticals.md summary).

## Smallest useful Progen slice
- Single-outlet dine-in and takeaway: tables, KOT print, GST bill, split bill, shift close, daily posting to ledger, recipe-based stock deduction.
- No aggregator, no KDS, no reservations.
- Add the aggregator inbox through one middleware (UrbanPiper) once the slice works.

## Rough effort and priority
- Slice: M. Aggregators and payout reconciliation: M. Multi-outlet with central kitchen: L.
- Priority: medium (after retail POS; shares the POS engine).

## Open questions
- Is offline mode needed in the first release?
- Do target restaurants want hardware bundled?
- Aggregator API access for a non-partner is UNVERIFIED. Confirm terms with UrbanPiper and the aggregators.
- Petpooja price per outlet is not published. Get a quote.

## Sources
- https://www.petpooja.com/
- https://www.restroworks.com/
- https://www.urbanpiper.com/
- https://support.toasttab.com/en/article/Toast-Product-Availability-in-Australia-Canada-Ireland-and-the-United-Kingdom
- https://www.oracle.com/food-beverage/restaurant-pos-systems/simphony-pos/
- https://www.marketman.com/partner/urbanpiper
- ../industry-verticals.md, ../ecommerce-marketplaces.md
