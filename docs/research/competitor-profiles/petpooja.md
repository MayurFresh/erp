# Petpooja (Petpooja)

Checked 2026-11-03. Confidence: low to medium. The vendor site shows product names and claims only. Features, price and integrations come mostly from review sites and one competitor's blog.

## Snapshot

| Field | Value |
| --- | --- |
| Segment | Restaurant POS and back office, India |
| HQ | UNVERIFIED (India per all third-party listings) |
| Scale claim | "150k+ Businesses" on the homepage. A third-party listing says "15,000+ merchants" for the restaurant POS. The two do not agree. |
| Deployment | Cloud with a mobile app (homepage); offline behaviour UNVERIFIED |
| Pricing published | No. A competitor (DineOpen) estimates Rs 5,000-12,000 per month for full features; treat as unreliable |
| Hardware | Sold or bought separately (printer, tablet, terminal); prices are third-party estimates |

## Modules

| Module | Label | Evidence |
| --- | --- | --- |
| Poss (restaurant POS): floor plan, table status, orders, KOT and bill print, mobile app | native | petpooja.com |
| Inventory, purchase orders, recipe management | native | review sites; one reviewer rates recipe and inventory 3.5 of 5 |
| CRM, 50+ reports, multi-outlet | native | review sites |
| Invoice (GST billing, inventory, P&L) | native | petpooja.com |
| Attendo (attendance, payroll, leave) | native, separate product | petpooja.com |
| Stepwise (staff task checklists) | native, separate product | petpooja.com |
| Purchase | unverified | only a demo-form option |
| Delivery aggregator integration | UNVERIFIED on vendor site; reviewers call it the strongest feature | third-party |
| Online ordering site, QR ordering, KDS, reservations | UNVERIFIED | not on fetched pages |

## Workflows worth copying

- Billing table actions: split, merge, move and edit a bill (reviewer description). Real tables need all four.
- Floor plan with live table status, then KOT and bill print from the same screen.
- Staff task checklists next to the POS (Stepwise). This is cheap to build and not common in Western POS.
- Payroll with biometric attendance sold in the same suite.

## APIs and integrations

- Public API docs: UNVERIFIED. None found.
- Zomato and Swiggy are not named on the homepage. Reviewers say they are supported. Treat as UNVERIFIED until a demo.
- Tally or accounting export: UNVERIFIED.

## Mobile and devices

- A mobile app exists for floor staff (homepage). Handheld ordering, kiosk and KDS support: UNVERIFIED.
- Thermal printers and billing terminals are common hardware (third-party estimates only).

## AI

- GA: none found.
- Announced: none found.

## Strengths (evidence)

- Large Indian footprint by the vendor's own claim (150k+ businesses).
- Suite covers billing, stock, payroll and tasks in one vendor (homepage).
- Aggregator integration rated best in India by one reviewer (restaurantdaily blog, secondary).

## Gaps (evidence)

- Pricing is opaque (no price on homepage or on GetApp).
- Recipe and inventory depth rated lower (3.5 of 5, one reviewer).
- Merchant count claims conflict (150k vs 15,000).
- Accounting depth beyond GST billing: UNVERIFIED.

## What Progen should take from it

- Start with the table and KOT loop and GST bill. These are table stakes in India.
- Add a delivery-aggregator inbox only after the POS loop works. See UrbanPiper in vertical-competitor-master.csv.
- Post daily sales and stock consumption into the ledger. Competitors export to Tally. Progen is the books.
- See docs/research/industry-workflows/restaurant-food.md and docs/research/industry-verticals.md section 4.

## Unknowns needing a demo

- Offline mode and sync after outage.
- Recipe costing method: standard cost or actual consumption.
- Aggregator menu sync and order status round trip.
- API access and partner terms.
- Real price per outlet per year, including hardware and add-ons.
- Multi-outlet and central kitchen features.

## Sources

- https://www.petpooja.com/
- https://www.getapp.com/all-software/a/petpooja/
- https://www.capterra.com/p/172163/Petpooja-Restaurant-Management-Platform/
- https://www.dineopen.com/blog/petpooja-pricing-plans-2026.html (competitor blog)
- https://restaurantdaily.vercel.app/blog/petpooja-review-operator-honest-2026 (review, secondary)
