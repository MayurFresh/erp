# Roadmap

The release plan lives in `docs/plan/ubos-discovery-and-plan.md` section 4. This page does not repeat it. It adds the exit check for each release and the order things depend on each other.

## Exit checks

A release is done when its check passes with evidence, not when its features are merged.

| Release | Theme | Exit check | Evidence today |
|---|---|---|---|
| v1.8 | Commerce core | Two orders for the last unit cannot both reserve it. A duplicate dispatch cannot double-post stock. Receipt, bill and stock reconcile. | Built, uncommitted. Covered by `o2c.test.ts` and `p2p.test.ts`. Live tests, web build and probe still pending. |
| v1.9 | Channels | Replaying the same webhook or file changes nothing. | Not started. No webhook or inbox code exists. |
| v1.10 | Warehouse depth | Offline scans converge, or show a conflict. | Not started. Scan idempotency (`scan_events`) exists as a base. |
| v1.11 | Platform readiness | Production-readiness gates 2, 4 and 5 have evidence. | Not started. Needs load, backup drill and pen-test results. |
| v1.12 | HR and payroll | Plan section 4. | Not started. |
| v1.13 | Manufacturing | Plan section 4. | Not started. |
| Later | POS, B2B portal, restaurant, hospitality, AI assistant, multi-currency | One wedge at a time, after pilot feedback. | Not started. |

## Dependency order

1. v1.8 is closed first: fix `live_commerce_test`, run the live tests, build the web app, run the probe, then report. Nothing in v1.9 starts on an unverified base.
2. v1.9 connector contract (`docs/architecture/integration-architecture.md`) comes before any adapter. Order inside v1.9: registry and inbox, then CSV import with SKU mapping (needs no outside access), then Shopify and WooCommerce, then stock push, then settlement posting, then health page. Amazon and Flipkart wait for access.
3. v1.10 needs v1.9 channel orders so that scan load is real.
4. v1.11 can overlap v1.10 but must finish before any pilot is called production.
5. v1.12 and v1.13 start only when v1.11 is done and a pilot has asked for them.

## Gates outside the code

These are owner tasks and can delay a release regardless of engineering: marketplace API access, a courier aggregator account, a GSP for live e-invoice, pilot businesses, and chartered accountant review of statutory figures. See `docs/product/risks.md` and plan section 7.
