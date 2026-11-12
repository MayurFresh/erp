# Domain boundaries

Bounded contexts inside the monolith. "May call" is a rule for new code. The code does not enforce it today; review does.

| Context | Main tables | Modules (`backend/src/modules`) | May call |
|---|---|---|---|
| Identity and access | users, roles, user_roles, refresh_tokens, mfa_challenges, password_resets, sso_providers, sso_states, sso_tickets | auth, users, users-admin, company | lib (crypto, oidc) only |
| Tenancy and company | tenants, companies, locations, doc_series | company, locations | Identity |
| Parties and items | parties, items | parties, items | Tenancy |
| Accounting | accounts, journal_entries, journal_lines | accounts, journal, reports, accounting/* | Tenancy. Others call it, it calls nobody. |
| Sales and invoicing | invoices, invoice_lines, credit_notes, payments | invoices, credit-notes, payments | Items, Stock, Accounting |
| Order to cash | sales_orders, sales_order_lines, stock_reservations, pick_lists, scan_events, shipments, sales_returns | sales-orders, fulfilment, shipments, sales-returns, o2c-common, o2c | Sales (createInvoice, credit note), Stock, Approvals |
| Procure to pay | purchase_orders, goods_receipts, stock_counts, purchases | purchase-orders, goods-receipts, purchases, p2p-match, reorder, stock-counts | Stock, Accounting, Approvals |
| Stock | stock_moves | stock, transfers, accounting/costing | Accounting |
| Compliance | gsp_credentials, gsp_submissions, gst_ledger_balances, gst_payments, statutory_filings | compliance, einvoice, gst-returns | GSP adapter, Accounting |
| Construction and real estate | projects, DPR, labour, subcontract, real-estate tables (003, 004, 006) | projects, construction modules, realestate | Items, Stock, Accounting |
| Platform controls | approvals, custom fields, cost centres, import_jobs, audit_log, notifications | controls, audit, imports, jobs | none of the business contexts' internals |

Table names above are the main ones from migrations 001 to 014; read the migrations for the full list.

## Rules

1. Only the owning context writes its tables. Other contexts call its exported functions, as O2C dispatch calls `createInvoice`.
2. Accounting posts through `accounting/journal.ts`. No module inserts journal rows directly.
3. Stock changes only by appending to `stock_moves`, under `lockItems`. See ADR-004.
4. Every table has `tenant_id` and the `tenant_isolation` policy. See ADR-002.
5. Cross-context transactions are allowed because it is one database. Dispatch creates the invoice and the shipment in one transaction (`fulfilment.ts`).
6. Approvals are plugged in through `registerApprovalDoc` (journal, credit_note, expense, payment, purchase, purchase_order).

## Planned

v1.9 adds a Channels context (connections, inbox, listings, settlements) that may call O2C to create orders, Stock to read availability and Accounting to post settlements. It may not read O2C tables directly.
