# Module catalogue

Modules grouped by master plan §5.1 layers. Status on 2026-11-03: shipped (in the code and tested), partial, planned (vX.Y). v1.8 modules are marked "built (v1.8)": the code and tests exist, release exit checks are still pending (see `roadmap.md`).

Backend names are files in `backend/src/modules/` unless a path is given. Flutter names are folders in `lib/features/`.

## Dependency metadata (master plan §5.3)

Today no module registry exists in code: every tenant gets every route (`backend/src/app.ts`). The `Depends on` column below is the metadata we would load into the entitlement registry, planned (v1.11). The registry must refuse to disable a module that has live documents, per §5.3.

## Layer A: platform

| ID | Module | Status | Backend | Flutter | Depends on |
| --- | --- | --- | --- | --- | --- |
| A1 | Tenant and companies | shipped | `companies.ts`, `company.ts`, `auth/context.ts` | `company`, `platform` | none |
| A2 | Locations (branches, warehouses, sites) | shipped | `locations.ts`, `backend/src/lib/scope.ts` | `locations` | A1 |
| A3 | Users, roles, permissions | shipped | `users.ts`, `users-admin.ts`, `auth/permissions.ts` | `users`, `settings` | A1, A2 |
| A4 | Authentication, MFA, sessions, SSO (OIDC) | shipped | `auth.ts`, `security.ts`, `backend/src/lib/oidc.ts`, `backend/src/lib/totp.ts` | `auth`, `platform` | A3 |
| A5 | Audit log | shipped | `audit.ts` | `audit` | A1 |
| A6 | Approval engine | shipped | `approvals.ts` | `controls` | A3 |
| A7 | Custom fields, cost centres | shipped | `custom-fields.ts`, `cost-centres.ts`, `backend/src/lib/custom-fields.ts` | `controls` | A1 |
| A8 | Notifications (in-app, email, WhatsApp outbox) | shipped | `notifications.ts`, `backend/src/lib/notify.ts` | `platform` | A1 |
| A9 | Background jobs | shipped | `jobs.ts`, `backend/src/lib/jobs.ts` | `platform` | A1 |
| A10 | Documents and files | shipped | `files.ts` | `documents` | A1 |
| A11 | Import and export (CSV) | shipped | `imports.ts`, `export.ts`, `backend/src/lib/csv.ts` | `controls` | A1 |
| A12 | Subscription, plans, entitlements, module activation | planned (v1.11) | none | none | A1 |
| A13 | API keys, outbound webhooks, OpenAPI | planned (v1.11) | none | none | A3, A9 |
| A14 | Integration hub (connector registry, webhook inbox, health) | planned (v1.9) | GSP adapter is the model: `backend/src/lib/gsp/`, `gsp.ts` | `platform/gsp_screens.dart` | A9, A11 |
| A15 | Workflow builder | not planned; approvals only | none | none | A6 |
| A16 | Search, help centre | not planned | none | none | none |
| A17 | Multi-currency, localisation | later (INR only) | none | none | A1 |

## Layer B: shared engines

| ID | Module | Status | Backend | Flutter | Depends on |
| --- | --- | --- | --- | --- | --- |
| B1 | Contacts (customers, vendors) | shipped | `parties.ts` | `parties` | A1 |
| B2 | Item catalogue (barcode, GST rate, units) | shipped | `items.ts`, `tax-masters.ts` | `items`, `tax` | A1 |
| B3 | Pricing and tax (GST by date, TDS) | shipped | `backend/src/lib/gst.ts`, `backend/src/lib/rates.ts`, `tds.ts` | `tax` | B2 |
| B4 | Sales invoices and credit notes | shipped | `invoices.ts`, `credit-notes.ts` | `invoices`, `credit_notes` | B1, B2, B3, C-ledger |
| B5 | Sales orders and reservations | built (v1.8) | `sales-orders.ts`, `o2c-common.ts` | `sales_orders` | B1, B2, B7 |
| B6 | Purchasing: bills, purchase orders, goods receipt, three-way match, reorder | built (v1.8) for PO, GRN, match, reorder; shipped for bills | `purchases.ts`, `purchase-orders.ts`, `goods-receipts.ts`, `p2p-match.ts`, `reorder.ts` | `purchases`, `purchase_orders` | B1, B2, B7, A6 |
| B7 | Inventory: stock ledger, transfers, issues, counts, valuation | shipped (ledger, transfers, issues); built (v1.8) for counts | `stock.ts`, `transfers.ts`, `issues.ts`, `stock-counts.ts`, `accounting/costing.ts` | `stock`, `transfers`, `stock_counts` | B2, A2 |
| B8 | Warehouse and barcode operations: pick, pack, dispatch, returns | built (v1.8) | `fulfilment.ts`, `shipments.ts`, `sales-returns.ts` | `fulfilment`, `returns` | B5, B7 |
| B9 | Bins, batches, expiry, serials | planned (v1.10) | none | none | B7 |
| B10 | Payments and bank reconciliation | shipped | `payments.ts`, `bank.ts` | `payments`, `compliance/bank_recon_screen.dart` | B4, B6, C-ledger |
| B11 | Accounting ledger, journals, statements | shipped | `accounts.ts`, `accounting/ledger.ts`, `statements.ts` | `accounting`, `accounts` | A1 |
| B12 | Expenses | shipped | `expenses.ts` | `expenses` | B11 |
| B13 | Fixed assets | shipped | `fixed-assets.ts`, `backend/src/lib/depreciation.ts` | `fixed_assets` | B11 |
| B14 | Multi-company, inter-company, consolidation | shipped | `companies.ts`, `intercompany.ts` | `platform` | B11 |
| B15 | India compliance: GST returns, e-invoice, e-way, TDS, filings, income tax | shipped (e-invoice sandbox only) | `gst-returns.ts`, `gst-filing.ts`, `einvoice.ts`, `gsp.ts`, `tds.ts`, `filings.ts`, `income-tax.ts`, `compliance.ts` | `compliance`, `gst_filing`, `filings`, `income_tax` | B4, B6, B11 |
| B16 | Reports and dashboard | shipped | `reports.ts`, `dashboard.ts` | `reports`, `dashboard` | B4, B6, B7, B11 |
| B17 | HR and payroll | planned (v1.12) | none (labour wages in construction pack only) | none | A1, B11 |
| B18 | Projects and tasks | partial (construction projects) | `projects.ts` | `construction` | B11 |
| B19 | Channel orders, SKU mapping, stock sync, settlements | planned (v1.9) | none | none | A14, B5, B7, B11 |
| B20 | CRM, support desk, marketing | not planned | none | none | none |
| B21 | Assets and maintenance (equipment) | not planned; fixed assets only | none | none | B13 |
| B22 | Analytics, AI assistant | later | none | none | A13 |

"C-ledger" is B11.

## Layer C: industry apps

| ID | App | Status | Backend | Flutter | Depends on |
| --- | --- | --- | --- | --- | --- |
| C1 | Marketplace OMS (channels, mapping, settlements) | planned (v1.9) | none | none | B19, A14 |
| C2 | Construction | shipped | `projects.ts`, `indents.ts`, `dprs.ts`, `labour.ts`, `labour-advances.ts`, `work-orders.ts`, `ra-bills.ts` | `construction` | B7, B11, A2 |
| C3 | Real-estate sales | shipped | `units.ts`, `bookings.ts` | `realestate` | B4, B10 |
| C4 | Manufacturing | planned (v1.13) | none | none | B6, B7, B9 |
| C5 | Retail POS, B2B portal | later | none | none | B7, B4 |
| C6 | Restaurant, hospitality, media, healthcare, education, agriculture, automotive, events, logistics | later | none | none | per vertical |

## Notes

- Flutter shell and routing: `lib/features/shell/`. The `admin_routes.dart` and `construction_routes.dart` files at `lib/features/` register screens.
- A module's permissions are listed in `backend/src/auth/permissions.ts` (`PERMISSIONS`, 91 keys at the time of writing).
