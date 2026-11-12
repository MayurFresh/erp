# Research gaps (commerce wedge), 3 Nov 2026

Needs a vendor demo, the vendor's quote, or the owner's seller accounts.

## Needs the owner's accounts
- Amazon SP-API: rate limits per operation, sandbox behaviour for Orders and PII, Notifications availability, settlement and returns reports. Docs pages on the new domain (developer-docs.amazon) partly 404ed or redirected.
- Flipkart: sandbox, rate limits, returns and inventory APIs, and settlement report access. The doc says to raise a ticket under the API node.
- Delhivery One: all endpoint detail, webhooks and NDR flow are behind login.
- Shiprocket: sandbox, rate limits, NDR and returns endpoints, whether a partner application is needed for a multi-tenant app.
- Myntra, Nykaa, AJIO, JioMart, Meesho: no public documents found. Access is through approved integrators or the marketplace team.

## Needs a vendor demo or quote
- Prices: Unicommerce, EasyEcom, Vinculum, Increff, Ginesys, Linnworks, Cin7 Omni, Zoho Books, NetSuite, SAP B1.
- Feature depth: wave picking, bundles, batch and serial, three-way match, settlement reconciliation for Unicommerce, EasyEcom, Vinculum, Increff and Ginesys. Most cells in feature-matrix.csv are "unverified" for that reason.
- AI features: none confirmed GA for any vendor in this pass.
- India GST coverage of Odoo, ERPNext, NetSuite, SAP B1 (not fetched).

## Method caveats
- Cells marked "native (general knowledge...)" in feature-matrix.csv are widely known ERP capabilities not read from a page this session. Treat as low confidence.
- Cells marked "no (not evidenced)" mean nothing was found, not that it is absent.
- Customer counts and market share were not researched. Vendor claims (Gartner, 290+ integrations, 5% of GMV) are labelled as claims.
- Zoho Books, Shopify Webhooks and WooCommerce webhook signature detail were not read.
- Odoo prices on the page were ambiguous between two figure pairs.

## ERP and SMB platforms

- Odoo: IRN, e-way bill, GSTR-1 filing, GSTR-2B matching, TDS and TCS documented for 19.0 (needs a GSP). Still open: Community versus Enterprise split.
- ERPNext: all GST features come from the India Compliance app. IRN, e-way bill, GSTR-1, 2A/2B reconciliation covered. GSTR-9, 6, 7 not generated.
- NetSuite: India Localization SuiteTax Engine SuiteApp covers GST, TDS, TCS, IRN, e-way bill. GSTR return coverage and current e-way bill API support still open.
- SAP B1: IRN through E-Billing Connector (ClearTax) from FP 2405. E-way bill is JSON export for portal upload. No profile written; see erp-feature.csv.

## Needs a vendor demo
- Odoo: JSON-2 rate limits, XML-RPC end date, India modules in Community, marketplace connectors, offline mobile scanning.
- ERPNext: webhooks and rate limits, mobile app, marketplace settlement reconciliation.
- Zoho: Zoho ERP module list and manufacturing depth, GSTR filing in Books, Inventory settlement reconciliation.
- Business Central: whether IRN needs a partner connector, API throttling, GA status of agents in India.
- D365 Finance and SCM: India price, effort to set up IRP integration.
- SAP S/4HANA Cloud: India scope list for Public Edition, OData coverage, Joule features GA in India.
- NetSuite: current e-way bill and GSTR support, whether NetSuite Next is open in India.
- TallyPrime: XML and ODBC limits, mobile options, depth of payroll and manufacturing.
- Rows with low confidence in erp-competitor-master.csv (Oracle Fusion, Workday, Infor, IFS, Acumatica, Sage, Unit4, SYSPRO, Priority, Xero, Exact, Dolibarr, Tryton, iDempiere, Axelor): no vendor page was read. They need a first pass.

## Needs a quote
- SAP S/4HANA Cloud, Oracle Fusion, NetSuite, Workday, Infor, IFS, Acumatica, Sage Intacct and X3, Unit4, SYSPRO, Priority, D365 Finance and SCM.
- Marg, Focus ERP, Ramco, LOGIC ERP, TranZact, AlignBooks: no official price found; listings conflict.
- Zoho One and Zoho ERP India price: Zoho's page returned 404 and partner prices conflict.
- Odoo light users (Rs 195) and implementation.

## Needs a login or other access
- NetSuite pricing page returned 403.
- Vyapar pricing page returned no plan detail to the fetcher.
- Zoho ERP help site had a certificate error; AI feature list not read.
- Tally TDL and integration release notes (help.tallysolutions.com) not opened.
- SAP Business Accelerator Hub and SAP for Me release notes need a browser or login.

## Caveats
- HQ country values for vendors not fetched are general knowledge and are labelled so.
- Several AI statuses rest on partner blogs. Treat as unverified until Microsoft, SAP, Oracle and Odoo release notes are read.
- Odoo price page layout is ambiguous. Figures follow the yearly and monthly toggle.

## Channels, couriers and OMS vendors

- CLOSED: Shopify webhook HMAC. Header X-Shopify-Hmac-SHA256, base64 HMAC-SHA256 of raw body, keyed by app client secret. Dedupe on X-Shopify-Webhook-Id. 5s total timeout, 8 retries over 4h.
- PARTLY CLOSED: Shopify rate limits. Leaky bucket per app and store, max single query cost 1000. Per-plan points per second (100, 200, 1000, 2000) came from a search summary and one third party disagrees (50 and 500). Re-check the official table.
- PARTLY CLOSED: WooCommerce webhook signature. Official page confirms a hash in headers and secret default, not the header name. X-WC-Webhook-Signature is third-party only. Confirm in the woocommerce.github.io REST docs.
- PARTLY CLOSED: Shiprocket API auth. Login endpoint and 240 hour token confirmed from an official help article.
- OPEN: Shiprocket NDR endpoints and rate limits. apidocs.shiprocket.in returned HTTP 498. NDR paths come from community SDKs only.
- OPEN: Shiprocket tracking webhook payload and signing. Panel setup only.
- PARTLY CLOSED: Delhivery public API docs. Docs sit behind Delhivery One login. The 11 API names are public. Webhooks not mentioned. Needs a client account.
- OPEN: Ecom Express API after the July 2025 Delhivery acquisition.
- OPEN: Blue Dart, DTDC, Xpressbees developer docs (not public).
- OPEN: Shopee Open Platform and Swiggy restaurant integration (no official page found).
- OPEN: BigCommerce webhook signature (sources conflict between X-BC-Signature and Standard Webhooks headers).
- OPEN: Razorpay and Cashfree settlement APIs, PhonePe merchant onboarding, PayU field order samples.
- OPEN: Manhattan Active and Blue Yonder were not researched. Rows are labelled UNVERIFIED.
- OPEN: Unicommerce webhook subscription, sandbox and rate limits. EasyEcom webhook retries. Vinculum webhook retries.
- OPEN: Official prices for Unicommerce, EasyEcom, Vinculum. Third-party figures conflict.
- CONFLICT: Cin7 Core Advanced is 1199 USD on cin7.com/pricing (2026-11-03). The existing pricing-matrix.csv row says 999 USD. Update the old row.
- CONFLICT: Shippo Pro shows 17 USD on the page and 19 USD in structured data.
- NOTE: Meesho, Myntra, AJIO, Nykaa, JioMart and Snapdeal have no public API. Existing combined rows kept. Access is through partners, so Progen needs CSV import first.
- NOTE: No separate rows added for Meesho, Myntra, AJIO, Nykaa, JioMart. Existing rows already say partner-gated.
- NOTE: One GSP row added with status Sandbox available, pointing to gst-einvoice-ewaybill.md section 10.

## Industry verticals

- Events and venues: no product research was done. The workflow file has no verified products. Next step: search Indian event-ticketing and venue-booking vendors.
- Toast, Mews, Cloudbeds, Square, Lightspeed, Deliverect, MarketMan, Hostaway, Procore, CMiC and most manufacturing vendors: India availability not confirmed on an official page. Ask each vendor or check India sites.
- Official pricing pages returned 403 or truncated content for Toast, Lightspeed, MRPeasy, Square and Epicor. Only Katana, MaintainX and Shopmonkey gave readable official prices. Currency codes were not stated on those pages.
- Shopmonkey page does not label which price is monthly and which is annual. The pricing file records the lower figures with that caveat.
- Petpooja: no price, no API docs, aggregator support only from reviews. Needs a demo and a quote.
- Mews: webhooks, rate limits and endpoint list not read. The docs site offers a sitemap and full-text export for the next pass.
- OPERA Cloud: India GST localisation, night audit and group handling not verified. OHIP push-events API is announced, not GA.
- Epicor Kinetic: official product pages blocked. The Grow platform appears only in one podcast transcript. Costing, API and India fit unknown.
- Workfront: AI reviewer availability is gated and undated. Full Workfront API and webhooks not read.
- Indian competitors not researched: Marg, Vyapar, Gofrugal, Hotelogix, Retail DMS products, small GTA billing tools, Indian event and school ERP vendors beyond Fedena.
- Indian rule details (GST slabs on hotel tariff, restaurant ITC rules, Form C, AIS-140, DPDP consent, mandi rules) are linked to industry-verticals.md and were not re-verified in this pass.
- QAD, Plex, Infor, Tulip, Bynder, Frame.io, Kantata, Deltek, Ellucian, Tekion: only third-party or search-summary evidence. Treat rows in vertical-competitor-master.csv as low confidence.
- Hardware and payments (POS terminals, UPI, card settlement) were not researched.
- Progen's own construction pack was compared by module names in code only. Feature depth was not tested.
