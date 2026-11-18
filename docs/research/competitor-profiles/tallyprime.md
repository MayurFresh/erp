# TallyPrime (Tally Solutions)

Checked 2026-11-03. Confidence: high for price and release history. Medium for features. API detail not read.

## Snapshot

| Field | Detail |
|---|---|
| URL | https://tallysolutions.com |
| HQ | India (Bengaluru; general knowledge, not re-verified) |
| Markets | India first. Also GCC, South Asia (Arabic and Bangla language support appear in release notes) |
| Sizes | Micro to mid-size accounting. Auditor Edition exists |
| Industries | Horizontal accounting and inventory. Extensions via TDL partners |
| Deployment | Desktop licence. Cloud Access and TallyDrive sync as add-ons. Server pack for 8 to 128 users |
| Pricing | Published, 2026-11-03, ex GST. Silver (single user) Rs 22,500 one-time. Gold (unlimited LAN users) Rs 67,500. Rental Silver Rs 750 per month or Rs 8,100 per year, Gold Rs 2,250 or Rs 24,300. TSS renewal Silver Rs 4,500, Gold Rs 13,500, Auditor Rs 6,750 per year. Cloud Access Rs 450 to 600. WhatsApp Rs 1,300 per year plus wallet from Rs 675 |
| India availability | Yes |
| GST localisation | Native. e-invoice, e-way bill, GST filing (Connected GST), IMS, e-TDS and e-TCS in 7.1 |

Prices include one year of TSS (Tally Software Services). If TSS lapses, the software works but statutory updates and connected features stop.

## Modules

| Area | Label | Note |
|---|---|---|
| Accounting, inventory, invoicing | native | |
| GST returns and portal connect | native (needs TSS) | Connected GST filing since 5.0 |
| e-invoice and e-way bill | native | Listed in Silver and Gold |
| IMS reconciliation | native | 6.1 introduced; 7.1 adds Books View |
| TDS 194Q automation | native | 5.0 |
| Connected Banking, PrimeBanking payments | native | Axis, SBI, Kotak, ICICI (7.1) |
| WhatsApp sharing | add-on | Annual fee plus prepaid wallet |
| Payroll | native | Basic; depth UNVERIFIED |
| Manufacturing BOM | native | Basic job work and BOM; depth UNVERIFIED |
| Multi-branch consolidation | add-on | Server pack, online sync |
| Customisation | custom | TDL language |
| Order management, WMS, marketplace sync | no (not evidenced) | Done through partners |

## Workflows worth copying

- Keyboard-first voucher entry. Accountants expect it (general knowledge).
- Edit Log with summary report (6.1).
- Auto voucher creation from bank statements (6.0).
- Multi-period GSTR-1 export and GST conflict resolution (5.1).
- Capture by AI: Docs by Ira drafts entries from scanned invoices, user reviews before save (7.1).
- Perpetual licence with a paid update service. Many buyers prefer it to subscription.

## APIs and integrations

- Tally has XML over HTTP, ODBC and TDL integration (general knowledge). The help site has release notes for TDL and integration. Not opened this pass.
- Large third-party connector market (Unicommerce, Busy and others list Tally integration). UNVERIFIED which are certified.
- No public webhook feature evidenced.

## Mobile

Reports in Browser became mobile-responsive in 2.0. A native phone app was not evidenced on the pages read. TallyDrive and Cloud Access give remote access.

## AI

| Item | Status |
|---|---|
| Docs by Ira (TallyIra) | GA in 7.1, released 2026-06-23 per Tally's page. Paid at Rs 200 per 100 pages |
| Other AI features | Blog predictions only. Not evidenced |

## Strengths (with evidence)

- Lowest published cost of ownership in this set. Rs 22,500 once.
- Release cadence tracks GST rules, with dated notes back to 2020.
- Strong accountant familiarity (general knowledge, no source read).

## Gaps (with evidence)

- No commerce, order or marketplace flow in the product pages.
- Multi-user and multi-branch need Gold, Server or cloud access.
- Statutory updates depend on paid TSS.
- No evidenced open webhook API.

## What OneMatrix should take from it

- Offer Tally export and import first. Customers keep Tally as their auditor-facing book.
- Match voucher keyboard speed on web.
- Add a one-click "send to Tally" and a Tally XML bridge for marketplace settlements. That is the commerce wedge.
- Pre-fill entries from scanned documents with human review before posting.
- Consider an annual-licence option for micro buyers.

## Unknowns needing a demo

- Current XML and ODBC capabilities and limits.
- Mobile app options.
- Depth of manufacturing and payroll.
- Which commerce tools are certified Tally integrators.

## Sources

- https://tallysolutions.com/business-guides/tallyprime-total-cost-of-ownership-india/ (Fetched 2026-11-03)
- https://tallysolutions.com/whats-new/ (Fetched)
- https://tallysolutions.com/darpan/product-update-tallyprime-7-1/ (Search)
- https://help.tallysolutions.com/ (Search, TDL release notes not opened)
