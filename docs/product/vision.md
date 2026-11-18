# Product vision

Written 2026-11-03. Sources: master plan §1.3, §2.2, §2.3 (`/Users/freshcodestechnology/Downloads/Universal_Business_OS_Master_Plan_and_Claude_Code_Prompt.md`), `docs/plan/ubos-discovery-and-plan.md`.

## Vision

One system of record for a small or mid-size Indian business: books, tax, stock, orders and the people who run them, with industry packs added as the business needs them. The long-term shape is the master plan's three layers (platform, shared engines, industry apps). See `module-catalogue.md`.

OneMatrix is not a rewrite of that plan. It is an existing ERP (`backend/src/modules/` has 62 module files, `backend/src/db/migrations/` has 14 migrations) that grows toward the plan one release at a time.

## Who we serve first

Indian SMEs that hold stock and sell through several channels: marketplace sellers, D2C brands, distributors and wholesalers, small manufacturers with warehouses (plan §3, master plan §2.2). Construction and real-estate packs already exist and stay as packs, not the launch wedge.

## What OneMatrix offers today

- Books and Indian tax in one system: double-entry ledger, GST returns, e-invoice and e-way bill through a GSP adapter (sandbox only), TDS, bank reconciliation, fixed assets (`backend/src/modules/gst-returns.ts`, `einvoice.ts`, `tds.ts`, `bank.ts`, `fixed-assets.ts`).
- Order to cash and procure to pay with stock reservations, pick and pack scans, three-way match and cycle counts (v1.8, `013_o2c.sql`, `014_p2p.sql`).
- Controls a finance team asks for: approvals, audit log, books lock, MFA, SSO, per-location access (`backend/src/auth/`, `modules/approvals.ts`).
- Construction and real-estate sales packs.

## Principles (master plan §1.3) and how the code holds them

| Principle | State |
| --- | --- |
| Several legal entities, branches, warehouses per organisation | Shipped. Companies are legal entities, locations are branches, warehouses and sites (`modules/companies.ts`, `modules/locations.ts`). No business-unit level. |
| Users see only permitted data (organisation, role, location) | Shipped. Roles and per-location scope (`auth/context.ts`, `backend/src/lib/scope.ts`). |
| Industry modules independently enabled and billed | Not built. Every tenant sees every pack. Planned (v1.11 entitlements). |
| Every transaction traceable | Shipped. `audit_log` on writes (`modules/audit.ts`), append-only `stock_moves`, journal entries. |
| External systems behind connector contracts | One contract exists (GSP adapter, `backend/src/lib/gsp/`). Channel connectors planned (v1.9). |
| External events idempotent, replayable, observable | Idempotency keys on API creates shipped. Webhook inbox, replay and connector health planned (v1.9). |
| AI never bypasses permissions or audit | No AI feature exists. Later. |
| Offline workflows define conflict rules | Not built. Planned (v1.10). |
| Happy path is not production-ready | Gates need evidence we lack (load test, pen test, backup drill). Planned (v1.11), pilots are the owner's call. |

## What we will not claim

No "better than" claims against other products without measured evidence (master plan §2.3). No customer or revenue figures appear in these docs because none are recorded in the repo. Every statutory figure stays unverified until a chartered accountant reviews it (plan §6).

## Differentiation hypotheses to test with pilots

Master plan §2.3 lists nine. The four OneMatrix can test soonest:

1. One system for books and operations. Competitors in `docs/research/commerce-ops.md` §1 export to Tally; OneMatrix is the books.
2. Settlement reconciliation posted straight to the ledger, with TCS and TDS (planned v1.9).
3. India compliance already built (GST, TDS, e-invoice).
4. Published pricing (`docs/research/commerce-ops.md` §5). Needs entitlements first (planned v1.11).

These are hypotheses, not findings.
