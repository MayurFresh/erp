# Commerce operations: what the market does and what OneMatrix should build

Research date 2026-11-03. Sources in source-register.md. Confidence is medium at best: many vendor pages show no detail, so see research-gaps.md. Data in competitor-master.csv, feature-matrix.csv, integration-matrix.csv, pricing-matrix.csv.

## 1. How the leaders run order to settlement

| Step | What Unicommerce, EasyEcom, Increff, Ginesys describe |
| --- | --- |
| Order in | Pull from marketplaces, carts (Shopify, Woo) and B2B into one panel. Unicommerce documents polling plus a 2-minute out-of-stock push. |
| Inventory | One central stock, pushed back to every channel. Mapping of channel SKU to master SKU is the first thing a seller sets up. |
| Warehouse | Allocation or routing across warehouses (EasyEcom), picklists, scan-based pack (Increff), bin accuracy. |
| Shipping | Courier aggregation, labels, manifests, tracking, and NDR follow-up by WhatsApp or SMS (Unicommerce). Shiprocket is the common aggregator. |
| Returns | Return and exchange portal (Unicommerce), RTO from couriers, QC then restock. |
| Settlement | Match orders, payments and returns per marketplace (Unicommerce UniReco, EasyEcom reconciliation report). This is what pays for the tool. |
| Books | Export to Tally or an ERP. This is OneMatrix's opening: it already is the books. |

## 2. Table stakes vs differentiators (Indian sellers)

- Table stakes: channel order sync, SKU mapping, stock sync, labels and courier, returns/RTO, GST invoice with e-invoice and e-way bill, PO and GRN, reorder, multi-warehouse.
- Differentiators: settlement reconciliation with TCS (s.52) and TDS matching posted straight to the ledger, NDR automation, three-way match, one system for books and ops (competitors export to Tally), published affordable pricing.
- Not yet worth it: wave picking, quick commerce, forecasting, AI.

## 3. Marketplace API reality

| Channel | Reality | Owner application |
| --- | --- | --- |
| Amazon | Open to registered developers, but needs developer profile approval and security review for PII roles. | Register in Solution Provider Portal (primary account, professional selling account). Start as a private app on the owner's seller account. |
| Flipkart | Self-access app for own account is quick. Third-party multi-seller apps need partner verification (doc says about 72h). | Create a self-access app in the seller dashboard. Later register as a partner. |
| Meesho | No public API found. Access via partners, by emailing Meesho. | Ask Meesho seller support for API/partner route, or file import. |
| Myntra, Nykaa, AJIO, JioMart | Partner-gated, no public docs found. | Ask each account manager; use CSV import first. |
| Shopify | Open. Customer name/address/email needs protected-data access; public apps are reviewed, custom apps are not. | A Shopify dev store. |
| WooCommerce | Open, key-based. | A test site. |
| Shiprocket | Open to any account holder via API user. | A Shiprocket account. |
| Delhivery | Client account, docs behind login. | Delhivery client account. |
| ONDC | Via a Seller Network Participant or becoming one (registry, FQDN, SSL). | Decide later; not v1.9. |

File import (CSV or report download) works everywhere and must exist anyway.

## 4. Recommended scope

v1.9 Channels (priority order): 1 CSV order and settlement import for any channel with SKU mapping; 2 Shopify and Woo adapters; 3 settlement reconciliation with fee, TCS and TDS posting; 4 webhook inbox with dedupe; 5 stock push; 6 Amazon and Flipkart self-access adapters once accounts exist; 7 connector health page.

v1.10 Warehouse depth: 1 batch and expiry with FEFO; 2 bins; 3 serials; 4 Shiprocket adapter (labels, AWB, tracking webhook) then NDR status capture; 5 manifests; 6 camera scan and offline queue; 7 bundles stock explosion if not in v1.9.

## 5. Pricing patterns

- Per order volume: Unicommerce (Growth 10-5000 orders), EasyEcom (per-order recharge slabs), Linnworks (order tiers with overage), Zoho Inventory (order caps).
- Per user: Odoo (INR 580-1080 per user per month, page ambiguous).
- Licence: Tally and Busy, one-time or annual, INR 8,000-24,300 a year (Tally).
- Per shipment: Shiprocket, plan INR 0-799 per month.
- Anchor: Zoho Inventory INR 999-7,499 per month with order caps. Enterprise vendors hide prices. OneMatrix could publish prices, which most commerce vendors do not.

## 6. What OneMatrix should improve next (ranked)

1. Finish v1.8 exits: reservations, no double dispatch, three-way match. Evidence: reservation and match are table stakes.
2. Settlement reconciliation with TCS/TDS posting (v1.9). Only a few vendors show it, and none link it to books.
3. CSV import for orders, returns and settlements with channel SKU mapping.
4. Shopify and WooCommerce adapters, the open channels.
5. Webhook inbox with signature check and replay safety.
6. Shiprocket adapter: labels, AWB, tracking webhook.
7. NDR status capture and action queue (Unicommerce, Shiprocket do this).
8. Batch, expiry and FEFO (Busy has it at INR 8,000 a year, so SMEs expect it).
9. Bins and a scan app with offline queue.
10. Bundles and kits with component stock.
11. Outbound webhooks and API keys (Shiprocket, Unicommerce expose them).
12. Published pricing page and module entitlements.
13. Warehouse routing across locations.
14. Returns QC disposition and customer return portal.
15. Amazon and Flipkart adapters after the owner has access.

## 7. Owner actions for API access

1. Amazon: Solution Provider Portal registration (private app) on the owner seller account.
2. Flipkart: self-access app in seller dashboard; ask support for sandbox and rate limits.
3. Shopify development store; WooCommerce test site.
4. Shiprocket account and API user; Delhivery client account.
5. Ask Meesho, Myntra, Nykaa, AJIO and JioMart account managers about partner API access.
6. Request vendor quotes or demos (Unicommerce, EasyEcom) to close gaps in research-gaps.md.
