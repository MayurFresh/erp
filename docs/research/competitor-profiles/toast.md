# Toast (Toast, Inc.)

Checked 2026-11-03. Confidence: low to medium. Toast's own pricing and developer pages returned 403 or empty text, so most facts come from search summaries of Toast pages and third-party guides.

## Snapshot

| Field | Value |
| --- | --- |
| Segment | Restaurant POS, payments and back office |
| Home market | United States |
| Other markets | Canada, Ireland, United Kingdom (2023), Australia (listed on its regional site) |
| India availability | Not sold in India. India is absent from the regional site list and the product-availability support page. No India page was found. |
| Pricing published | Partly. Toast's own pricing guide gives a software range of $0 to $69 per month for standard restaurant plans. Plans pair with card-processing rates. Third-party figures differ, so check the live page. |
| Deployment | Cloud with proprietary hardware |

## Modules

| Module | Label | Evidence |
| --- | --- | --- |
| POS, handhelds (Toast Go 3 launched globally 28 Apr 2026 in UK, IE, CA, AU) | native | Toast news |
| Kitchen display system | add-on (custom quote) | pricing guides |
| Payroll | add-on (custom quote) | pricing guides |
| Toast Capital (financing) | native, US only | Toast support page |
| Online ordering, gift cards, loyalty, marketing | UNVERIFIED on fetched pages | not confirmed |
| Inventory, recipe costing, scheduling | UNVERIFIED | not confirmed |
| Toast IQ (AI layer) | native, included | third-party guides |

## Workflows worth copying

- Pay-as-you-go versus monthly plan choice tied to processing rates. It lowers the cost of trying the product.
- One handheld for order, pay at table and kitchen send.
- Peer benchmarking in reports (third-party description).
- Cash-advance financing from sales data. Not relevant to OneMatrix now.

## APIs and integrations

- A developer portal exists (developer.toasttab.com). Its API areas, auth model and webhook list were not readable. UNVERIFIED.
- Partner programme terms: UNVERIFIED.

## Mobile and devices

- Toast Go handhelds, cellular and Wi-Fi models (Toast news, April 2026).
- Apple Pay and Samsung Pay in Canada, Ireland and UK.

## AI

- GA: Toast IQ, chat interface for sales, labour and menu insights. Third parties say it can complete some tasks. Scope of actions UNVERIFIED.
- Announced: none confirmed.

## Strengths (evidence)

- Software plus payments plus hardware from one vendor.
- Expansion to four more countries since 2023, so localisation tooling exists (Toast engineering blog "Internationalization @ Toast").

## Gaps (evidence)

- Not available in India.
- Some products are country-locked (Toast Capital is US only).
- Third-party sources disagree on prices. The vendor page was not readable.

## What OneMatrix should take from it

- Treat Toast as a reference for restaurant workflow, not a competitor in India.
- Use its plan design: a free or low tier plus payments revenue. OneMatrix has no payment rail yet, so UNVERIFIED value.
- Copy the idea of an AI assistant over sales, labour and menu data, only after the POS data model is stable.
- See docs/research/industry-workflows/restaurant-food.md.

## Unknowns needing a demo

- Offline mode behaviour.
- Menu and modifier model.
- API scopes, rate limits and partner approval time.
- Whether hardware is locked to Toast payments.

## Sources

- https://support.toasttab.com/en/article/Toast-Product-Availability-in-Australia-Canada-Ireland-and-the-United-Kingdom
- https://pos.toasttab.com/blog/on-the-line/toast-pricing
- https://developer.toasttab.com/
- https://technology.toasttab.com/entry/internationalization-toast/
- https://d2a0efs422ycyj.cloudfront.net/news/toast-go-3-handheld-pos-global-launch
- https://www.upmenu.com/blog/toast-pricing (third-party)
