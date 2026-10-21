# Progen ERP API — v1 contract

The Flutter app (web, Android, iOS, desktop) and the backend both follow this file.
Change it first, then change both sides.

- Base URL: `http://<host>:8080/api/v1` (health check at `GET /health`, outside the prefix)
- JSON everywhere, keys in `camelCase`.
- Dates: `YYYY-MM-DD`. Timestamps: ISO-8601 UTC (`2026-10-21T09:30:00.000Z`).
- Money and quantities are JSON numbers. Money has at most 2 decimals, quantities at most 3.
- IDs are UUID strings.

## Headers

| Header | When | Value |
| --- | --- | --- |
| `Authorization` | every endpoint except `/auth/signup`, `/auth/login`, `/auth/refresh` | `Bearer <accessToken>` |
| `X-Company-Id` | every company-scoped endpoint (everything except `/auth/*` and `/me`) | a company id from `GET /me`. If omitted, the server uses the user's first company. |

## Errors

Every error uses an HTTP status and this body:

```json
{ "error": { "code": "VALIDATION_ERROR", "message": "Human readable", "details": {} } }
```

| Status | `code` values |
| --- | --- |
| 400 | `VALIDATION_ERROR` (`details` = field → message map) |
| 401 | `UNAUTHORIZED`, `TOKEN_EXPIRED` |
| 403 | `FORBIDDEN` |
| 404 | `NOT_FOUND` |
| 409 | `CONFLICT`, `INSUFFICIENT_STOCK`, `ALREADY_CANCELLED` |
| 500 | `INTERNAL_ERROR` |

On `401 TOKEN_EXPIRED` the client calls `/auth/refresh` once and retries the request. On any other 401, or if the refresh fails, the client logs out.

## Updating records

In `PATCH` bodies, a field that is **absent** stays unchanged, and `null` (or `""`) **clears** an optional field. An empty body is valid and returns the record unchanged.

## Lists

List endpoints accept `?q=<search>&limit=<1..200, default 50>&offset=<default 0>` and return:

```json
{ "data": [ ... ], "total": 123 }
```

## Permissions

Permission keys (strings). The app shows menus and buttons only when the active company's `permissions` contain the key. The server enforces them regardless.

| Key | Allows |
| --- | --- |
| `dashboard.view` | Dashboard |
| `items.view` / `items.create` / `items.edit` | Items |
| `items.view_cost` | See `purchasePrice` on items and `value` on stock. Without it these fields are **absent** from responses. |
| `parties.view` / `parties.create` / `parties.edit` | Customers and vendors |
| `locations.view` / `locations.manage` | Branches, sites, warehouses, departments |
| `stock.view` / `stock.adjust` | Stock balances, stock adjustments |
| `invoices.view` / `invoices.create` / `invoices.cancel` | Sales invoices |
| `users.manage` | Users and their role assignments |
| `roles.manage` | Create roles |
| `audit.view` | Audit log |
| `company.manage` | Edit company profile, bank details and invoice terms |
| `purchases.view` / `purchases.create` / `purchases.cancel` | Purchase bills |
| `payments.view` / `payments.create` / `payments.cancel` | Receipts from customers and payments to vendors |
| `credit_notes.view` / `credit_notes.create` / `credit_notes.cancel` | Sales returns |
| `transfers.view` / `transfers.create` / `transfers.receive` | Stock transfers between locations |
| `expenses.view` / `expenses.create` / `expenses.cancel` | Expenses paid from cash or bank |
| `accounts.view` | Chart of accounts, ledgers, day book, trial balance, P&L, balance sheet |
| `accounts.manage` | Create and edit accounts (bank, cash, expense heads…) |
| `accounts.journal` | Manual journal vouchers |
| `reports.view` | Sales/purchase registers, GST summary, ageing, stock valuation (valuation also needs `items.view_cost`) |

**Location scope.** Each company membership has `locationIds`: `null` means all locations; a list means the user may only see and create location-bound records (stock, invoices) for those locations. The server filters every list and rejects writes outside the scope with `403`.

## Objects

```ts
User        { id, name, email, phone: string|null }
Company     { id, name, legalName: string|null, gstin: string|null, stateCode: string, pan: string|null, address: string|null }
Membership  Company & { roles: {id, name}[], permissions: string[], locationIds: string[]|null }
Me          { user: User, companies: Membership[] }
AuthResult  { accessToken, refreshToken, expiresIn: number /* seconds */, user: User }

Location    { id, companyId, parentId: string|null, type: 'branch'|'site'|'warehouse'|'department'|'store'|'office',
              name, code: string|null, stateCode: string, address: string|null, isActive: boolean, createdAt }

Item        { id, companyId, name, sku: string|null, hsnCode: string|null, unit, gstRate: number /* 0,5,12,18,28,40 etc */,
              salePrice: number, purchasePrice?: number /* only with items.view_cost */, trackStock: boolean,
              reorderLevel: number, isActive: boolean, createdAt, updatedAt }

Party       { id, companyId, type: 'customer'|'vendor'|'both', name, gstin: string|null, stateCode: string|null,
              phone: string|null, email: string|null, address: string|null, creditLimit: number, createdAt }

StockBalance{ itemId, itemName, sku: string|null, unit, locationId, locationName, qty: number, reorderLevel: number,
              value?: number /* only with items.view_cost; qty × purchasePrice */ }
StockMove   { id, itemId, locationId, qty: number /* + in, - out */, rate: number|null,
              refType: 'opening'|'adjustment'|'invoice'|'invoice_cancel', refId: string|null, note: string|null, createdAt }

InvoiceLine { id, itemId, description, hsnCode: string|null, qty, unit, rate, discountPct, taxableValue,
              gstRate, cgst, sgst, igst, lineTotal }
Invoice     { id, companyId, locationId, locationName, partyId, partyName, partyGstin: string|null,
              number: string, fy: string /* "2026-27" */, invoiceDate, placeOfSupply: string /* state code */,
              supplyType: 'intra'|'inter', status: 'posted'|'cancelled',
              subtotal /* sum of taxableValue */, cgst, sgst, igst, taxTotal, roundOff, total,
              notes: string|null, createdAt, createdBy: {id, name},
              cancelledAt: string|null, cancelReason: string|null,
              lines?: InvoiceLine[] /* present on GET /invoices/:id, create and preview; absent in lists */ }

Role        { id, name, description: string|null, isSystem: boolean, permissions: string[] }
UserRow     { id, name, email, phone: string|null, isActive: boolean,
              assignments: { roleId, roleName, locationIds: string[]|null }[] }
Dashboard   { salesToday, salesThisMonth, invoicesThisMonth: number, lowStockCount: number,
              recentInvoices: Invoice[] /* max 5, no lines */,
              topItems: { itemId, name, qty, amount }[] /* this month, max 5 */ }
AuditEntry  { id, entity, entityId, action, userId: string|null, userName: string|null, before: object|null, after: object|null, createdAt }
```

GST rules used by the server: seller state = invoice location's `stateCode`. Place of supply = party `stateCode`, else seller state. Same state → `supplyType: 'intra'`, CGST and SGST are each half the rate. Different state → `'inter'`, IGST at the full rate. Each line is rounded to paise; the invoice total is rounded to the nearest rupee and the difference is `roundOff`.

Invoice numbers are gapless per company per financial year (April–March): `INV/26-27/00001`. Cancelled invoices keep their number. Posting an invoice reduces stock at its location for `trackStock` items and fails with `409 INSUFFICIENT_STOCK` if stock would go negative. Cancelling reverses the stock.

## Endpoints

### Auth

| Method & path | Body | Response |
| --- | --- | --- |
| `POST /auth/signup` | `{ businessName, name, email, password /* min 8 */, phone?, stateCode /* 2 digits */, gstin? }` | `201 AuthResult`. Creates the company, a "Head Office" location, the system roles and makes the user Owner. |
| `POST /auth/login` | `{ email, password }` | `200 AuthResult` |
| `POST /auth/refresh` | `{ refreshToken }` | `200 AuthResult` (the old refresh token stops working). A missing, malformed, expired or reused token returns `401`; reusing an old token also ends all of the user's sessions. |
| `POST /auth/logout` | `{ refreshToken }` | `204` |
| `GET /me` | — | `200 Me` |

### Locations

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /locations` | `locations.view` | list query | `{data: Location[], total}` (only locations in the user's scope) |
| `POST /locations` | `locations.manage` | `{ type, name, code?, stateCode?, address?, parentId? }` (stateCode defaults to company's) | `201 Location` |
| `PATCH /locations/:id` | `locations.manage` | any of the create fields + `isActive` | `200 Location` |

### Items

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /items` | `items.view` | list query (+ `activeOnly=true`) | `{data: Item[], total}` |
| `GET /items/:id` | `items.view` | — | `Item` |
| `POST /items` | `items.create` | `{ name, sku?, hsnCode?, unit /* e.g. "pcs","kg","bag" */, gstRate, salePrice, purchasePrice?, trackStock? /* default true */, reorderLevel? }` | `201 Item` |
| `PATCH /items/:id` | `items.edit` | any create field + `isActive` (`purchasePrice` ignored without `items.view_cost`) | `200 Item` |

### Parties

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /parties` | `parties.view` | list query (+ `type=customer\|vendor`; each also returns parties of type `both`) | `{data: Party[], total}` |
| `GET /parties/:id` | `parties.view` | — | `Party` |
| `POST /parties` | `parties.create` | `{ type, name, gstin?, stateCode?, phone?, email?, address?, creditLimit? }` (stateCode defaults to the first 2 digits of gstin) | `201 Party` |
| `PATCH /parties/:id` | `parties.edit` | any create field | `200 Party` |

### Stock

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /stock` | `stock.view` | `?locationId=&q=&lowOnly=true` + paging | `{data: StockBalance[], total}` — one row per item × location with any movement |
| `POST /stock/adjustments` | `stock.adjust` | `{ locationId, itemId, qty /* non-zero, + adds, - removes */, rate?, note? }` | `201 StockMove` (`409 INSUFFICIENT_STOCK` if it would go negative) |
| `GET /stock/moves` | `stock.view` | `?itemId=&locationId=` + paging | `{data: StockMove[], total}` newest first |

### Invoices

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /invoices` | `invoices.view` | list query (+ `status`, `from`, `to`, `locationId`) | `{data: Invoice[], total}` newest first, no lines |
| `GET /invoices/:id` | `invoices.view` | — | `Invoice` with lines |
| `POST /invoices/preview` | `invoices.create` | same body as create | `200 Invoice` with lines, `id: null`, `number: null`, nothing saved |
| `POST /invoices` | `invoices.create` | `{ locationId, partyId, invoiceDate? /* default today */, notes?, lines: [{ itemId, qty, rate? /* default item salePrice */, discountPct?, description? }] }` (1–200 lines) | `201 Invoice` with lines |
| `POST /invoices/:id/cancel` | `invoices.cancel` | `{ reason }` | `200 Invoice` |

### Dashboard

| Method & path | Permission | Response |
| --- | --- | --- |
| `GET /dashboard` | `dashboard.view` | `Dashboard` (limited to the user's location scope) |

### Users and roles

| Method & path | Permission | Body | Response |
| --- | --- | --- | --- |
| `GET /permissions` | `roles.manage` or `users.manage` | — | `{ key, module, label }[]` |
| `GET /roles` | `users.manage` or `roles.manage` | — | `{data: Role[], total}` |
| `POST /roles` | `roles.manage` | `{ name, description?, permissions: string[] }` | `201 Role` |
| `GET /users` | `users.manage` | list query | `{data: UserRow[], total}` |
| `POST /users` | `users.manage` | `{ name, email, phone?, password, roleId, locationIds?: string[]\|null }` | `201 UserRow` |

### Audit

| Method & path | Permission | Query | Response |
| --- | --- | --- | --- |
| `GET /audit` | `audit.view` | `?entity=&entityId=` + paging (`entity` is one of `company`, `location`, `item`, `party`, `stock_move`, `invoice`, `user`, `role`) | `{data: AuditEntry[], total}` newest first |

## Demo data

`npm run db:seed` (in `backend/`) creates a demo company with these logins, all with password `Demo@1234`:

| Email | Role |
| --- | --- |
| `owner@demo.in` | Owner, all locations |
| `accountant@demo.in` | Accountant, all locations |
| `sales@demo.in` | Sales Executive, only "Central Warehouse", no cost prices |
| `supervisor@demo.in` | Site Supervisor, only "Site A — Tower 1" |

---

# v1.1 additions — completing the core MVP

Everything above still holds. This section adds accounting, purchases, payments, returns, transfers, expenses, reports and administration.

## Accounting model (read this first)

- Every money document posts a balanced **journal entry** automatically (debits = credits, enforced by the database).
- Stock is valued at **weighted-average cost** per item across the company. Every stock move stores `costRate` and a signed `value`; stock value = Σ value. Sales post cost of goods sold at the average cost at the time of sale.
- Cancelling a document never deletes anything: it posts a reversing entry and reversing stock moves.
- Each company gets these system accounts on first use (codes are fixed; users may add more):

| Code | Name | Type | `subtype` / `systemKey` |
| --- | --- | --- | --- |
| 1000 | Cash in Hand | asset | cash / `cash` |
| 1010 | Bank Account | asset | bank / `bank` |
| 1100 | Accounts Receivable | asset | receivables / `receivables` |
| 1200 | Inventory | asset | inventory / `inventory` |
| 1210 | Stock in Transit | asset | inventory / `stock_in_transit` |
| 1300–1302 | Input CGST / SGST / IGST | asset | tax / `input_cgst`, `input_sgst`, `input_igst` |
| 2000 | Accounts Payable | liability | payables / `payables` |
| 2100–2102 | Output CGST / SGST / IGST | liability | tax / `output_cgst`, `output_sgst`, `output_igst` |
| 3000 | Owner's Capital | equity | other / `capital` |
| 3100 | Opening Balances | equity | other / `opening_balances` |
| 4000 | Sales | income | other / `sales` |
| 4010 | Sales Returns | income | other / `sales_returns` |
| 4900 | Other Income | income | other / `other_income` |
| 5000 | Cost of Goods Sold | expense | other / `cogs` |
| 5100 | Purchases — Non-stock Items | expense | other / `purchases_nonstock` |
| 5200 | Stock Shortage & Wastage | expense | other / `stock_loss` |
| 5900 | Round Off | expense | other / `round_off` |
| 6000–6090 | Rent, Salaries & Wages, Electricity, Transport & Freight, Office Expenses, Repairs & Maintenance, Professional Fees, Bank Charges, Travel & Conveyance, Miscellaneous Expenses | expense | other / `null` (normal expense heads) |

Balances are reported **debit-positive**: assets and expenses are normally positive; liabilities, equity and income normally negative in `balance`, but reports show them as positive amounts in their own section.

## Document numbers

Gapless per company per financial year, max 16 characters:

| Document | Format |
| --- | --- |
| Purchase bill (internal no.) | `PUR/26-27/00001` |
| Receipt | `RCT/26-27/00001` |
| Payment | `PAY/26-27/00001` |
| Credit note | `CN/26-27/00001` |
| Transfer | `TRF/26-27/00001` |
| Expense | `EXP/26-27/00001` |
| Manual journal | `JV/26-27/00001` |

## Changed objects

```ts
Company     += { phone, email, website, bankName, bankAccountNo, bankIfsc, upiId, invoiceTerms, invoiceFooter }   // all string|null
               // Membership (in /me) carries these too.
Party       += { creditDays: number, balance: number /* + they owe us, − we owe them */ }
Item        += { avgCost?: number /* only with items.view_cost; weighted-average cost now */ }
StockBalance.value = Σ move values (weighted-average valuation), still only with items.view_cost
StockMove   += { costRate: number|null, value?: number /* only with items.view_cost */ }
StockMove.refType ∈ 'opening'|'adjustment'|'invoice'|'invoice_cancel'|'purchase'|'purchase_cancel'|
                    'credit_note'|'credit_note_cancel'|'transfer_out'|'transfer_in'|'transfer_cancel'
Invoice     += { dueDate, amountPaid, amountDue, paymentStatus: 'unpaid'|'partial'|'paid' }
               // amountPaid = receipts allocated + credit notes against it. Cancelled invoices: amountDue 0.
Invoice (detail only) += { settlements: { kind: 'receipt'|'credit_note', id, number, date, amount }[] }
InvoiceLine (detail only) += { returnedQty: number }
Dashboard   += { receivables, payables, cashAndBank, purchasesThisMonth }
```

`POST /stock/adjustments` body gains `isOpening?: boolean` (default false). Opening stock is credited to Opening Balances; other increases to Other Income; decreases are charged to Stock Shortage & Wastage. Increases are valued at `rate` if given, else the current average cost (falling back to the item's purchase price).

`POST /invoices/:id/cancel` now returns `409 HAS_SETTLEMENTS` if any receipt or credit note is applied to the invoice (cancel those first).

`POST /parties` and `PATCH /parties/:id` accept `creditDays` (0–365). An invoice's `dueDate` = invoice date + the party's credit days.

## New objects

```ts
Purchase     { id, companyId, locationId, locationName, partyId, partyName, partyGstin: string|null,
               number /* PUR/.. */, supplierInvoiceNo: string|null, supplierInvoiceDate: string|null,
               fy, billDate, dueDate, placeOfSupply, supplyType: 'intra'|'inter', status: 'posted'|'cancelled',
               subtotal, cgst, sgst, igst, taxTotal, roundOff, total, amountPaid, amountDue,
               paymentStatus: 'unpaid'|'partial'|'paid', notes: string|null, createdAt, createdBy: {id, name},
               cancelledAt: string|null, cancelReason: string|null,
               lines?: PurchaseLine[] /* detail, create, preview */,
               settlements?: { kind: 'payment', id, number, date, amount }[] /* detail */ }
PurchaseLine { id, itemId, description, hsnCode, qty, unit, rate, discountPct, taxableValue, gstRate, cgst, sgst, igst, lineTotal }

Payment      { id, companyId, kind: 'receipt'|'payment', number, date, partyId, partyName,
               accountId, accountName /* cash or bank account */, mode: 'cash'|'bank'|'upi'|'cheque'|'card',
               reference: string|null, amount, allocated, unallocated, notes: string|null,
               status: 'posted'|'cancelled', createdAt, createdBy: {id, name}, cancelledAt, cancelReason,
               allocations: { docType: 'invoice'|'purchase', docId, docNumber, docDate, docTotal, amount }[] }

CreditNote   { id, companyId, invoiceId, invoiceNumber, locationId, locationName, partyId, partyName,
               number /* CN/.. */, fy, noteDate, reason, restock: boolean, placeOfSupply, supplyType,
               status: 'posted'|'cancelled', subtotal, cgst, sgst, igst, taxTotal, roundOff, total,
               createdAt, createdBy: {id, name}, cancelledAt, cancelReason,
               lines?: { id, invoiceLineId, itemId, description, hsnCode, qty, unit, rate, discountPct,
                         taxableValue, gstRate, cgst, sgst, igst, lineTotal }[] }

Transfer     { id, companyId, number /* TRF/.. */, fromLocationId, fromLocationName, toLocationId, toLocationName,
               status: 'in_transit'|'received'|'cancelled', transferDate, notes: string|null,
               totalValue?: number /* only with items.view_cost */,
               createdAt, createdBy: {id, name}, receivedAt: string|null, receivedBy: {id, name}|null,
               cancelledAt: string|null, cancelReason: string|null,
               lines: { itemId, itemName, sku: string|null, unit, qty }[] }

Expense      { id, companyId, number /* EXP/.. */, expenseDate, locationId, locationName,
               accountId, accountName /* expense head */, partyId: string|null, partyName: string|null,
               description, amount /* before GST */, gstRate, cgst, sgst, igst, total,
               paidFromAccountId, paidFromAccountName, status: 'posted'|'cancelled',
               createdAt, createdBy: {id, name}, cancelledAt, cancelReason }

Account      { id, code, name, type: 'asset'|'liability'|'equity'|'income'|'expense',
               subtype: 'cash'|'bank'|'receivables'|'payables'|'inventory'|'tax'|'other',
               systemKey: string|null, isSystem: boolean, isActive: boolean, balance: number /* debit-positive */ }

JournalEntry { id, date, voucherType: 'sales'|'purchase'|'receipt'|'payment'|'credit_note'|'expense'|'stock'|'transfer'|'journal',
               voucherId: string|null, number: string|null /* the source document's number */, narration: string|null,
               isReversal: boolean, createdAt, createdBy: {id, name}|null,
               lines: { accountId, accountCode, accountName, partyId: string|null, partyName: string|null, debit, credit }[] }

LedgerLine   { entryId, date, voucherType, voucherId, number, narration, partyName: string|null, debit, credit, balance }
Ledger       { accountId, accountName, from, to, openingBalance, closingBalance, totalDebit, totalCredit, lines: LedgerLine[] }
```

## New endpoints

### Company

| Method & path | Permission | Body | Response |
| --- | --- | --- | --- |
| `GET /company` | any member | — | `Company` (active company) |
| `PATCH /company` | `company.manage` | any of `name, legalName, gstin, pan, address, phone, email, website, bankName, bankAccountNo, bankIfsc, upiId, invoiceTerms, invoiceFooter` (`null` clears). `stateCode` cannot change once documents exist. | `Company` |

### Purchases

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /purchases` | `purchases.view` | list query + `status, from, to, locationId, partyId, paymentStatus` | `{data: Purchase[], total}` newest first, no lines |
| `GET /purchases/:id` | `purchases.view` | — | `Purchase` with lines and settlements |
| `POST /purchases/preview` | `purchases.create` | same as create | `Purchase` with lines, `id`/`number` null |
| `POST /purchases` | `purchases.create` | `{ locationId, partyId /* vendor or both */, billDate?, supplierInvoiceNo?, supplierInvoiceDate?, notes?, lines: [{ itemId, qty, rate? /* default item purchasePrice */, discountPct?, description? }] }` | `201 Purchase`. Adds stock at the location for tracked items, at the line's taxable value. |
| `POST /purchases/:id/cancel` | `purchases.cancel` | `{ reason }` | `Purchase`. `409 HAS_SETTLEMENTS` if payments are applied; `409 INSUFFICIENT_STOCK` if the stock was already used. |

GST on purchases: supplier state = party `stateCode` (else the location's); same as the location's state → intra (CGST+SGST input), otherwise inter (IGST input).

### Receipts and payments

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /payments` | `payments.view` | list query + `kind, partyId, from, to, status` | `{data: Payment[], total}` newest first |
| `GET /payments/:id` | `payments.view` | — | `Payment` |
| `POST /payments` | `payments.create` | `{ kind, partyId, date?, accountId /* cash or bank account */, mode, reference?, amount, notes?, allocations?: [{ docId, amount }] }` | `201 Payment` |
| `POST /payments/:id/cancel` | `payments.cancel` | `{ reason }` | `Payment` (allocations released) |
| `GET /parties/:id/outstanding` | `payments.view` | — | `{ balance, invoices: OpenDoc[], purchases: OpenDoc[] }` with `OpenDoc { id, number, date, dueDate, total, amountDue }`, oldest first |
| `GET /parties/:id/statement` | `parties.view` and (`payments.view` or `accounts.view`) | `?from=&to=` (default: financial year to date) | `Ledger` of the party's receivable/payable account |

- A receipt (`kind: 'receipt'`) allocates to that party's **invoices**; a payment (`'payment'`) to its **purchases**.
- If `allocations` is **omitted**, the server allocates to the oldest open documents first. If it is given (even `[]`), it is used exactly. Σ allocations ≤ `amount`; each ≤ that document's `amountDue`. The rest stays as an advance (`unallocated`).
- `400 VALIDATION_ERROR` if the account is not a cash/bank account.

### Credit notes (sales returns)

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /credit-notes` | `credit_notes.view` | list query + `status, from, to, invoiceId, partyId` | `{data: CreditNote[], total}` |
| `GET /credit-notes/:id` | `credit_notes.view` | — | `CreditNote` with lines |
| `POST /credit-notes/preview` | `credit_notes.create` | same as create | `CreditNote` with lines, `id`/`number` null |
| `POST /credit-notes` | `credit_notes.create` | `{ invoiceId, noteDate?, reason, restock? /* default true */, lines: [{ invoiceLineId, qty }] }` | `201 CreditNote`. Rate, discount and GST follow the invoice line; qty ≤ `qty − returnedQty`. Reduces the invoice's amount due; any excess becomes the customer's credit. |
| `POST /credit-notes/:id/cancel` | `credit_notes.cancel` | `{ reason }` | `CreditNote` (`409 INSUFFICIENT_STOCK` if restocked goods were already used) |

### Stock transfers

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /transfers` | `transfers.view` | list query + `status, locationId` (either side) | `{data: Transfer[], total}` — those where the source **or** destination is in the user's scope |
| `GET /transfers/:id` | `transfers.view` | — | `Transfer` |
| `POST /transfers` | `transfers.create` | `{ fromLocationId, toLocationId, transferDate?, notes?, lines: [{ itemId, qty }] }` | `201 Transfer` with status `in_transit`; stock leaves the source now (`409 INSUFFICIENT_STOCK`). Source must be in scope. |
| `POST /transfers/:id/receive` | `transfers.receive` | — | `Transfer` with status `received`; stock arrives at the destination. Destination must be in scope. |
| `POST /transfers/:id/cancel` | `transfers.create` | `{ reason }` | Only while `in_transit`; stock returns to the source. |

### Expenses

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /expenses` | `expenses.view` | list query + `from, to, accountId, locationId, status` | `{data: Expense[], total}` |
| `GET /expenses/:id` | `expenses.view` | — | `Expense` |
| `POST /expenses` | `expenses.create` | `{ expenseDate?, locationId, accountId /* an expense account */, description, amount, gstRate? /* default 0 */, partyId? /* vendor, for GST input credit */, paidFromAccountId /* cash or bank */ }` | `201 Expense` |
| `POST /expenses/:id/cancel` | `expenses.cancel` | `{ reason }` | `Expense` |

GST on an expense is split CGST/SGST when the vendor's state equals the location's state (or there is no vendor), otherwise IGST; it is booked as input tax.

### Accounts and journals

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /accounts` | `accounts.view`; or `payments.create` / `expenses.create` (then only cash, bank and expense accounts are returned, with `balance` 0) | `?type=&subtype=&activeOnly=true` | `{data: Account[], total}` ordered by code |
| `POST /accounts` | `accounts.manage` | `{ name, code? /* auto if absent */, type, subtype? /* 'cash'|'bank'|'other', default 'other' */ }` | `201 Account` |
| `PATCH /accounts/:id` | `accounts.manage` | `{ name?, code?, isActive? }` (system accounts: name only) | `Account` |
| `GET /accounts/:id/ledger` | `accounts.view` | `?from=&to=&partyId=` (default: financial year to date) | `Ledger` |
| `GET /journals` | `accounts.view` | list query + `from, to, voucherType` | `{data: JournalEntry[], total}` newest first (the day book) |
| `GET /journals/:id` | `accounts.view` | — | `JournalEntry` |
| `POST /journals` | `accounts.journal` | `{ date?, narration, lines: [{ accountId, partyId?, debit?, credit? }] }` — 2–50 lines, each line exactly one of debit/credit > 0, totals equal; `partyId` only on receivable/payable accounts | `201 JournalEntry` (number `JV/..`) |
| `POST /journals/:id/cancel` | `accounts.journal` | `{ reason }` | `JournalEntry` (the reversal). Only manual journals can be cancelled here. |

### Reports

All accept dates as `YYYY-MM-DD`; `from` defaults to the start of the current financial year and `to`/`asOf` to today.

| Method & path | Permission | Response |
| --- | --- | --- |
| `GET /reports/trial-balance?asOf=` | `accounts.view` | `{ asOf, rows: [{ accountId, code, name, type, debit, credit }], totalDebit, totalCredit }` (accounts with a non-zero balance) |
| `GET /reports/profit-loss?from=&to=` | `accounts.view` | `{ from, to, revenue: Section, cogs: Section, grossProfit, otherIncome: Section, expenses: Section, netProfit }` with `Section { rows: [{ accountId, code, name, amount }], total }`. Revenue = Sales − Sales Returns. |
| `GET /reports/balance-sheet?asOf=` | `accounts.view` | `{ asOf, assets: Section, liabilities: Section, equity: Section /* includes a row "Profit & Loss" with accountId null */, totalAssets, totalLiabilitiesAndEquity }` |
| `GET /reports/sales-register?from=&to=&locationId=` | `reports.view` | `{ rows: [{ id, number, date, partyName, partyGstin, placeOfSupply, taxable, cgst, sgst, igst, total, status }], totals: { taxable, cgst, sgst, igst, total } }` (cancelled rows have zero amounts in totals) |
| `GET /reports/purchase-register?from=&to=&locationId=` | `reports.view` | same shape for purchases (`number` is the internal number; adds `supplierInvoiceNo`) |
| `GET /reports/gst-summary?from=&to=` | `reports.view` | `{ outward: { byRate: RateRow[], b2b: { count, taxable, tax }, b2c: { count, taxable, tax }, creditNotes: RateRow /* gstRate null */, net: RateRow }, inward: { byRate: RateRow[], expenses: RateRow, total: RateRow }, hsn: [{ hsnCode, unit, qty, taxable, cgst, sgst, igst }], netPayable: { cgst, sgst, igst, total } }` with `RateRow { gstRate, taxable, cgst, sgst, igst }`. Posted documents only. |
| `GET /reports/stock-valuation?locationId=` | `reports.view` + `items.view_cost` | `{ rows: [{ itemId, name, sku, unit, qty, avgCost, value }], totalValue }` |
| `GET /reports/ageing?type=receivables\|payables&asOf=` | `reports.view` | `{ asOf, rows: [{ partyId, partyName, notDue, d1_30, d31_60, d61_90, d90plus, total }], totals: { notDue, d1_30, d31_60, d61_90, d90plus, total } }` — open documents bucketed by days past `dueDate` |

### Users, roles and passwords

| Method & path | Permission | Body | Response |
| --- | --- | --- | --- |
| `PATCH /users/:id` | `users.manage` | `{ name?, phone?, isActive?, roleId?, locationIds? }` (role and locations replace the user's assignment in the active company; the same "no more access than your own" rules apply; you cannot deactivate yourself or remove the last Owner) | `UserRow` |
| `POST /users/:id/password` | `users.manage` | `{ password }` | `204` (ends that user's sessions) |
| `POST /me/password` | signed in | `{ currentPassword, newPassword }` | `204` (`400` if the current password is wrong) |
| `PATCH /roles/:id` | `roles.manage` | `{ name?, description?, permissions? }` | `Role` (`403` for system roles — copy them instead) |

---

# v1.2 additions — Construction pack (phase 2a)

Projects with BOQ and budgets, material indents, material issue to work, daily progress reports (DPR) with photos, workers, attendance and wage sheets. Contractor RA bills and real-estate sales follow in phase 2b.

## New permissions

| Key | Allows |
| --- | --- |
| `projects.view` / `projects.manage` | See / create and edit projects and link sites |
| `boq.manage` | Create and edit BOQ lines |
| `indents.view` / `indents.create` / `indents.approve` | Material indents |
| `consumption.view` / `consumption.create` | Material issued to work at a site |
| `dpr.view` / `dpr.create` / `dpr.approve` | Daily progress reports |
| `labour.view` / `labour.manage` | Worker register |
| `attendance.mark` | Mark daily attendance |
| `wages.view` / `wages.manage` / `wages.pay` | Wage sheets: view / prepare and approve / pay |

New built-in role **Project Manager**: `dashboard.view, items.view, locations.view, stock.view, transfers.view, transfers.create, transfers.receive, purchases.view, projects.view, boq.manage, indents.view, indents.approve, consumption.view, dpr.view, dpr.approve, labour.view, labour.manage, wages.view, wages.manage, reports.view`.
Site Supervisor gains `projects.view, indents.view, indents.create, consumption.view, consumption.create, dpr.view, dpr.create, labour.view, attendance.mark, wages.view`. Store Keeper gains `indents.view, consumption.view, consumption.create`. Accountant gains `projects.view, consumption.view, wages.view, wages.pay`. Owner and Company Admin get everything; Auditor gets every `.view`.

**Scope:** location-bound records (indents, issues, DPRs, workers by home site, attendance, wage sheets) follow the user's location scope. A project is visible if any of its sites is in scope (projects without sites: unscoped users only).

## New system accounts

| Code | Name | Type | `systemKey` |
| --- | --- | --- | --- |
| 5300 | Material Consumed at Sites | expense | `material_consumed` |
| 5310 | Site Labour Wages | expense | `site_labour` |
| 1400 | Labour Advances | asset | `labour_advances` (advances paid to workers, e.g. by a journal Dr Labour Advances / Cr Cash) |

## Document numbers

Indent `IND/26-27/00001` · Material issue `ISS/26-27/00001` · Wage sheet `WG/26-27/00001`.

## Objects

```ts
Project   { id, companyId, code, name, clientPartyId: string|null, clientName: string|null,
            managerUserId: string|null, managerName: string|null,
            status: 'planning'|'active'|'on_hold'|'completed', startDate: string|null, endDate: string|null,
            contractValue: number, address: string|null,
            sites: { id, name }[], budgetTotal: number /* Σ BOQ amount */, progressPct: number /* amount-weighted */,
            createdAt }

BoqLine   { id, projectId, code /* "2.1.3" */, description, unit, qty, rate, amount /* qty × rate */,
            materialBudget, labourBudget, otherBudget, executedQty /* Σ approved DPR work entries */,
            progressPct /* executedQty ÷ qty × 100, max 100 */, sortOrder }

Indent    { id, number, projectId: string|null, locationId, locationName, requiredBy: string|null,
            status: 'draft'|'submitted'|'approved'|'rejected'|'closed', notes: string|null,
            createdAt, createdBy: {id, name}, approvedAt: string|null, approvedBy: {id, name}|null,
            rejectReason: string|null,
            lines: { id, itemId, itemName, unit, qty, approvedQty: number|null, fulfilledQty, boqLineId: string|null }[] }

Issue     { id, number, locationId, locationName, projectId: string|null, boqLineId: string|null, boqCode: string|null,
            date, notes: string|null, status: 'posted'|'cancelled', createdAt, createdBy: {id, name},
            totalValue?: number /* items.view_cost */,
            lines: { itemId, itemName, unit, qty, costRate?: number, value?: number /* items.view_cost */ }[] }

FileRef   { id, name, mimeType, size, url /* "/api/v1/files/<id>" — fetch with the Authorization header */ }

Dpr       { id, locationId, locationName, projectId: string|null, date, weather: string|null,
            status: 'draft'|'submitted'|'approved', summary: string|null, hindrances: string|null,
            workDone: { id, boqLineId: string|null, boqCode: string|null, description, qty: number|null, unit: string|null }[],
            labour: { trade, count }[], equipment: { name, hours }[],
            photos: { fileId, url, caption: string|null }[],
            createdAt, createdBy: {id, name}, submittedAt: string|null, approvedAt: string|null, approvedBy: {id, name}|null }

Worker    { id, name, phone: string|null,
            trade: 'mason'|'carpenter'|'bar_bender'|'helper'|'electrician'|'plumber'|'painter'|'welder'|'operator'|'other',
            skill: 'unskilled'|'semi_skilled'|'skilled'|'highly_skilled', dailyRate,
            contractorPartyId: string|null, contractorName: string|null, siteId: string|null, siteName: string|null,
            aadhaarLast4: string|null, bocwRegNo: string|null, photoFileId: string|null, joinedOn: string|null,
            isActive: boolean, createdAt }

AttendanceRow { workerId, workerName, trade, contractorName: string|null,
                status: 'present'|'half_day'|'absent'|null /* null = not marked */, otHours: number }

WageSheet { id, number, siteId, siteName, from, to, status: 'draft'|'approved'|'paid'|'cancelled',
            totalGross, totalDeductions, totalNet, paidFromAccountId: string|null, paidAt: string|null,
            createdAt, createdBy: {id, name},
            rows?: { workerId, workerName, trade, contractorName: string|null, dailyRate, presentDays /* half day = 0.5 */,
                     otHours, basic, otAmount, gross, advance, net }[] /* detail only */ }

ProjectCosts { projectId, from, to,
               budget: { material, labour, other, total },
               actual: { material /* issues at project sites */, labour /* approved + paid wage sheets */,
                         expenses /* expenses at project sites */, total },
               byBoqLine: { boqLineId, code, description, qty, executedQty, progressPct, materialBudget, materialActual }[] }
```

Wage maths: `basic = presentDays × dailyRate`; `otAmount = otHours × dailyRate ÷ 8 × 2` (overtime at twice the ordinary rate); `gross = basic + otAmount`; `net = gross − advance`; each rounded to paise.

## Endpoints

### Projects and BOQ

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /projects` | `projects.view` | list query + `status` | `{data: Project[], total}` |
| `GET /projects/:id` | `projects.view` | — | `Project` |
| `POST /projects` | `projects.manage` | `{ code, name, clientPartyId?, managerUserId?, status? /* default planning */, startDate?, endDate?, contractValue?, address?, siteIds?: string[] }` | `201 Project`. Sites must be locations of type `site`; a site belongs to at most one project (`409`). |
| `PATCH /projects/:id` | `projects.manage` | any create field (`siteIds` replaces the set; `null` clears optional fields) | `Project` |
| `GET /projects/:id/boq` | `projects.view` | — | `{data: BoqLine[], total}` ordered by `sortOrder`, then code |
| `POST /projects/:id/boq` | `boq.manage` | `{ code, description, unit, qty, rate, materialBudget?, labourBudget?, otherBudget? }` or `{ lines: [ …same… ] }` for bulk (max 500) | `201 BoqLine` or `201 {data: BoqLine[], total}` |
| `PATCH /boq/:id` | `boq.manage` | any field above + `sortOrder` | `BoqLine` |
| `DELETE /boq/:id` | `boq.manage` | — | `204`; `409 IN_USE` if a DPR entry, issue or indent line refers to it |
| `GET /projects/:id/costs` | `projects.view` (+ `items.view_cost` for material values, else they are 0) | `?from=&to=` (default: project start / today) | `ProjectCosts` |

### Indents

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /indents` | `indents.view` | list query + `status, locationId, projectId` | `{data: Indent[], total}` newest first |
| `GET /indents/:id` | `indents.view` | — | `Indent` |
| `POST /indents` | `indents.create` | `{ locationId /* a site or store */, requiredBy?, notes?, submit?: boolean, lines: [{ itemId, qty, boqLineId? }] }` | `201 Indent` (`draft`, or `submitted` if `submit`) |
| `POST /indents/:id/submit` | `indents.create` | — | `Indent` (draft → submitted) |
| `POST /indents/:id/approve` | `indents.approve` | `{ lines?: [{ lineId, approvedQty }] }` (default: approve requested qty) | `Indent` (submitted → approved) |
| `POST /indents/:id/reject` | `indents.approve` | `{ reason }` | `Indent` |
| `POST /indents/:id/close` | `indents.approve` or the creator | — | `Indent` (approved → closed) |

Fulfilment: `POST /transfers` and `POST /purchases` accept an optional `indentId`. When a transfer is **received** at, or a purchase is **posted** at, the indent's location, `fulfilledQty` of matching item lines increases (capped at the approved qty). An indent becomes fulfilled when every line's `fulfilledQty ≥ approvedQty`; it stays `approved` until closed.

### Material issue to work

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /issues` | `consumption.view` | list query + `locationId, projectId, boqLineId, from, to, status` | `{data: Issue[], total}` |
| `GET /issues/:id` | `consumption.view` | — | `Issue` |
| `POST /issues` | `consumption.create` | `{ locationId, boqLineId?, date?, notes?, lines: [{ itemId, qty }] }` | `201 Issue`. Stock leaves the location at average cost (`409 INSUFFICIENT_STOCK`); posts Material Consumed at Sites / Inventory. Stock move `refType` `'issue'`. |
| `POST /issues/:id/cancel` | `consumption.create` | `{ reason }` | `Issue` (stock returns, `refType` `'issue_cancel'`) |

### Files

| Method & path | Permission | Body | Response |
| --- | --- | --- | --- |
| `POST /files` | any signed-in user | `multipart/form-data`, field `file`; JPEG, PNG, WebP or PDF; max 10 MB | `201 FileRef` |
| `GET /files/:id` | any user of the same business | — | the file bytes with its content type |

### Daily progress reports

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /dprs` | `dpr.view` | list query + `locationId, projectId, from, to, status` | `{data: Dpr[], total}` newest first |
| `GET /dprs/:id` | `dpr.view` | — | `Dpr` |
| `POST /dprs` | `dpr.create` | `{ locationId, date?, weather?, summary?, hindrances?, workDone?: [{ boqLineId?, description, qty?, unit? }], labour?: [{ trade, count }], equipment?: [{ name, hours }], photos?: [{ fileId, caption? }], submit?: boolean }` | `201 Dpr`. One DPR per site per date (`409 CONFLICT`). |
| `PATCH /dprs/:id` | `dpr.create` (creator) or `dpr.approve` | same fields; only while `draft` | `Dpr` |
| `POST /dprs/:id/submit` | `dpr.create` | — | `Dpr` |
| `POST /dprs/:id/approve` | `dpr.approve` | — | `Dpr` (approved work quantities count towards BOQ progress) |
| `GET /dprs/previous?locationId=` | `dpr.view` | — | the latest DPR of that site, or `404` (to pre-fill "copy yesterday") |

### Workers, attendance and wages

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /workers` | `labour.view` | list query + `siteId, contractorId, trade, activeOnly` | `{data: Worker[], total}` |
| `GET /workers/:id` | `labour.view` | — | `Worker` |
| `POST /workers` | `labour.manage` | `{ name, phone?, trade, skill?, dailyRate, contractorPartyId?, siteId?, aadhaarLast4?, bocwRegNo?, photoFileId?, joinedOn? }` | `201 Worker` |
| `PATCH /workers/:id` | `labour.manage` | any create field + `isActive` | `Worker` |
| `GET /attendance` | `labour.view` | `?siteId=&date=` | `{ siteId, date, locked: boolean, rows: AttendanceRow[] }` — all active workers of the site plus anyone already marked that day |
| `PUT /attendance` | `attendance.mark` | `{ siteId, date, entries: [{ workerId, status, otHours? }] }` | same as GET. `409 LOCKED` if the date is inside an approved or paid wage sheet; no future dates. |
| `GET /wage-sheets` | `wages.view` | list query + `siteId, status` | `{data: WageSheet[], total}` (no rows) |
| `GET /wage-sheets/:id` | `wages.view` | — | `WageSheet` with rows |
| `POST /wage-sheets` | `wages.manage` | `{ siteId, from, to }` | `201 WageSheet` (draft) computed from attendance; `409` if it overlaps another non-cancelled sheet of the site |
| `PATCH /wage-sheets/:id` | `wages.manage` | `{ rows: [{ workerId, advance }] }` (draft only) | `WageSheet` |
| `POST /wage-sheets/:id/recompute` | `wages.manage` | — | draft only; re-reads attendance, keeps advances |
| `POST /wage-sheets/:id/approve` | `wages.manage` | — | `WageSheet` (locks attendance for the period) |
| `POST /wage-sheets/:id/pay` | `wages.pay` | `{ paidFromAccountId /* cash or bank */, date? }` | `WageSheet` (paid). Posts Site Labour Wages Dr gross / cash-bank Cr net / Labour Advances Cr advances recovered. |
| `POST /wage-sheets/:id/cancel` | `wages.manage` | `{ reason }` | draft or approved only |
