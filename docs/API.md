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
| `GET /locations` | `locations.view` | list query (+ `all=true`) | `{data: Location[], total}` (only locations in the user's scope; with `all=true` and `transfers.create`, every active location, for picking a transfer destination) |
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
| `GET /invoices` | `invoices.view` | list query (+ `status`, `from`, `to`, `locationId`, `partyId`, `paymentStatus` = `unpaid`/`partial`/`paid`) | `{data: Invoice[], total}` newest first, no lines |
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
               isReversal: boolean, reversesId: string|null /* the entry this one reverses */,
               reversedById: string|null /* set once cancelled: the reversing entry */, createdAt, createdBy: {id, name}|null,
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
            rejectedAt: string|null, rejectedBy: {id, name}|null, rejectReason: string|null /* the current rejection; cleared on resubmit */,
            isFulfilled: boolean /* approved or closed, and every line's fulfilledQty ≥ approvedQty */,
            lines: { id, itemId, itemName, unit, qty, approvedQty: number|null, fulfilledQty, boqLineId: string|null }[] }

Issue     { id, number, locationId, locationName, projectId: string|null, boqLineId: string|null, boqCode: string|null,
            date, notes: string|null, status: 'posted'|'cancelled', createdAt, createdBy: {id, name},
            cancelledAt: string|null, cancelReason: string|null,
            totalValue?: number /* items.view_cost */,
            lines: { itemId, itemName, unit, qty, costRate?: number, value?: number /* items.view_cost */ }[] }

FileRef   { id, name, mimeType, size, url /* "/api/v1/files/<id>" — fetch with the Authorization header */ }

Dpr       { id, locationId, locationName, projectId: string|null, date, weather: string|null,
            status: 'draft'|'submitted'|'approved'|'rejected', summary: string|null, hindrances: string|null,
            workDone: { id, boqLineId: string|null, boqCode: string|null, description, qty: number|null, unit: string|null }[],
            labour: { trade, count }[], equipment: { name, hours }[],
            photos: { fileId, url, caption: string|null }[],
            createdAt, createdBy: {id, name}, submittedAt: string|null, approvedAt: string|null, approvedBy: {id, name}|null,
            rejectedAt: string|null, rejectedBy: {id, name}|null, rejectReason: string|null /* the current rejection; cleared on resubmit */ }

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

Location   += { projectId: string|null }   // the project a site belongs to
Transfer   += { indentId: string|null }
Purchase   += { indentId: string|null }
```

Wage maths: `basic = presentDays × dailyRate`; `otAmount = otHours × dailyRate ÷ 8 × 2` (overtime at twice the ordinary rate); `gross = basic + otAmount`; `net = gross − advance`; each rounded to paise, half up (½ day at ₹300.03 = ₹150.02).

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
| `PUT /indents/:id` | `indents.create` (creator) or `indents.approve` | `{ locationId /* a site or store */, requiredBy?, notes?, lines: [{ itemId, qty, boqLineId? }] }` — replaces the whole indent: omitted `requiredBy`/`notes` are cleared, lines are replaced and their `approvedQty` reset | `Indent`. Only while `draft` or `rejected` (`409` otherwise); the status does not change. |
| `POST /indents/:id/submit` | `indents.create` | — | `Indent` (draft or rejected → submitted; clears `rejectedAt`, `rejectedBy`, `rejectReason`) |
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
| `PATCH /dprs/:id` | `dpr.create` (creator) or `dpr.approve` | same fields; only while `draft` or `rejected` (`409` otherwise). A rejected DPR stays `rejected` while it is corrected. `submit: true` (needs `dpr.create`) submits it exactly like `/submit`. | `Dpr` |
| `POST /dprs/:id/submit` | `dpr.create` | — | `Dpr` (draft or rejected → submitted; clears `rejectedAt`, `rejectedBy`, `rejectReason`) |
| `POST /dprs/:id/reject` | `dpr.approve` | `{ reason }` (3–300 characters) | `Dpr` (submitted → rejected; `409` otherwise) |
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

## Clarifications (backend)

- **Journals and stock moves.** `JournalEntry.voucherType` gains `'issue'` and `'wages'` (also accepted by `GET /journals?voucherType=`). `StockMove.refType` gains `'issue'` and `'issue_cancel'`. Audit `entity` gains `project`, `boq_line`, `indent`, `issue`, `file`, `dpr`, `worker`, `attendance` and `wage_sheet`.
- **System accounts.** A company that already uses code 1400, 5300 or 5310 for its own account gets the system account at the next free code (e.g. 1401). Look accounts up by `systemKey`, not by code. 5300 and 5310 are posted automatically and are not offered as expense heads in the account picker.
- **Projects.** `code` is unique per company, ignoring case (`409`). Scoped users must link at least one of their own sites when creating a project, and may only link or unlink sites in their scope. A site linked to a project cannot change its location type (`409`).
- **BOQ.** `code` is unique within a project, ignoring case (`409`; `400` for duplicates inside one bulk request). `qty` must be more than 0. New lines get the next `sortOrder` unless one is given. `GET /projects/:id/boq` takes the standard list query (`q` searches code and description).
- **Project costs.** `from` is `null` when neither the query nor the project gives a start date; then everything up to `to` counts. `actual.labour` counts approved and paid wage sheets whose period ends between `from` and `to`. `actual.expenses` is the amount before GST. `executedQty` and `progressPct` in `byBoqLine` are cumulative, like on `BoqLine`. For location-scoped users, actuals cover only the project's sites in their scope.
- **Indents.** `projectId` is the project of the indent's site. On approval each `approvedQty` must be between 0 and the requested `qty`. Fulfilment needs an `approved` indent at the transfer's destination or the purchase's location (`400` otherwise). Several lines for the same item are filled in line order. Cancelling a purchase removes what it fulfilled. Linking a transfer or purchase does not require the user to see the indent.
- **Issues.** Only items with `trackStock` can be issued. `boqLineId` must belong to the project of the issue's location (`400`).
- **DPRs.** DPRs are for active locations of type `site`. A work entry's `unit` defaults to its BOQ line's unit. Photos must be JPEG, PNG or WebP files uploaded first (`400` for PDFs or unknown files).
- **Files.** An oversized file (`400`, `details.file: "Larger than 10 MB"`), an empty file, a type that is not allowed (checked from the file's first bytes, never its name or claimed type), or a non-multipart request returns `400 VALIDATION_ERROR`. `name` is a display name only.
- **Attendance.** Only workers whose home site is this site can be marked (`400`). A worker marked at another site that day gives `409 CONFLICT`. `otHours` (0–24, 2 decimals) is stored as 0 for `absent`.
- **Wage sheets.** `to` cannot be in the future. Rows cover workers with any attendance at the site in the period. Approval re-reads attendance first, keeping advances, so the approved figures match the attendance it locks. A recompute fails with `400` if an advance would exceed the new gross. An advance cannot exceed the worker's gross (`400`). Paying needs a non-zero gross. Its journal (voucher type `wages`, dimension = the site) drops zero lines.

## Demo data (v1.2)

`npm run db:seed` now adds `pm@demo.in` (Priya PM, Project Manager, all locations). It also adds project `PRJ-T1` on Site A — Tower 1 with 8 BOQ lines, an indent fulfilled by the warehouse transfer, a material issue, an approved DPR and a submitted DPR, 8 workers (4 through a labour contractor), a week of attendance and a paid wage sheet.

---

# v1.3 additions — Phase 2b: subcontracts, labour advances, real-estate sales, GST e-invoice

Research behind this section: `docs/research/` (see its README). Migration `006_phase2b.sql` creates every table below. `db/schema.ts`, `auth/permissions.ts` (keys and built-in roles), `lib/series.ts` (prefixes) and `accounting/accounts.ts` (system accounts) are already updated.

## New permissions

| Key | Allows |
| --- | --- |
| `subcontracts.view` / `subcontracts.manage` / `subcontracts.approve` | Work orders and RA bills: view / create work orders and prepare RA bills / approve, reject or cancel RA bills, pay mobilisation advances, release retention, close or cancel work orders |
| `units.view` / `units.manage` | Real-estate units and payment plans |
| `bookings.view` / `bookings.manage` | Bookings, demands, agreement and possession, RERA status |
| `einvoice.manage` | Generate and cancel IRNs and e-way bills |

Labour advances use the existing `wages.view` (view) and `wages.pay` (pay, cancel).

Built-in roles gain:

| Role | New permissions |
| --- | --- |
| Owner, Company Admin | everything |
| Accountant | `subcontracts.view`, `subcontracts.approve`, `units.view`, `bookings.view`, `bookings.manage`, `einvoice.manage` |
| Sales Executive | `units.view`, `bookings.view`, `bookings.manage` |
| Site Supervisor | `subcontracts.view`, `subcontracts.manage` |
| Project Manager | `subcontracts.view`, `subcontracts.manage`, `subcontracts.approve`, `units.view` |
| Auditor | every `.view` |

**Scope:**
- Work orders, RA bills, units, payment plans, bookings and demands are visible when their project is visible (the v1.2 project rule). A project with no sites is visible to unscoped users only.
- `GET /projects` and `GET /projects/:id` also accept `units.view` or `bookings.view`, so sales staff can pick a project. `PATCH /projects/:id` (including `reraRegNo` and `reraAccountId`) still needs `projects.manage`.
- Labour advances follow the worker's home site.

## New system accounts

| Code | Name | Type | `systemKey` |
| --- | --- | --- | --- |
| 1410 | Contractor Advances | asset | `contractor_advances` |
| 2110 | TDS Payable | liability | `tds_payable` |
| 2120 | BOCW Cess Payable | liability | `cess_payable` |
| 2200 | Retention Payable | liability | `retention_payable` |
| 2300 | Customer Advances — Bookings | liability | `booking_advances` |
| 4100 | Property Sales | income | `property_sales` |
| 5320 | Subcontract Work | expense | `subcontract_cost` (posted automatically; not offered as an expense head) |

The v1.2 clash rule applies: a code already in use gets the next free code, so always look accounts up by `systemKey`.

## Document numbers

| Document | Example |
| --- | --- |
| Labour advance | `LA/26-27/00001` |
| Work order | `WO/26-27/00001` |
| Contractor advance | `CA/26-27/00001` |
| RA bill | `RAB/26-27/00001` |
| Retention release | `RR/26-27/00001` |
| Booking | `BKG/26-27/00001` |
| Demand | `DMD/26-27/00001` |

## Changed objects

```ts
Worker      += { advanceBalance: number /* Σ (amount − recovered) of open advances */ }
WageSheet.rows[] += { advanceBalance /* the worker's open balance when the row was last computed */ }
Party       += { pan: string|null /* AAAAA9999A */, pincode: string|null /* 6 digits, not starting with 0 */ }
Company     += { pincode: string|null, einvoiceEnabled: boolean, einvoiceMode: 'manual'|'sandbox' }
Location    += { pincode: string|null }
Project     += { reraRegNo: string|null, reraAccountId: string|null /* an active bank account */ }
ProjectCosts.actual += { subcontract /* gross of approved RA bills dated in range, plus GST when not ITC-eligible */ }
                       // actual.total includes it
Payment.allocations[].docType: 'invoice'|'purchase'|'ra_bill'|'demand'
OpenDoc     += { docType: 'invoice'|'purchase'|'ra_bill'|'demand' }
Invoice     += {
  einvoice: { irn, ackNo, ackDate /* timestamp */, signedQrCode, status: 'active'|'cancelled', sandbox: boolean,
              cancelledAt: string|null, cancelReason: string|null } | null,
  ewaybill: { ewbNo, ewbDate, validUntil, status: 'active'|'cancelled', transportMode: 'road'|'rail'|'air'|'ship',
              vehicleNo: string|null, distanceKm, transporterGstin: string|null, cancelledAt: string|null } | null }
```

`POST`/`PATCH` for parties, the company, locations and projects accept the new fields.

## New objects

```ts
LabourAdvance { id, number, workerId, workerName, siteId: string|null, siteName: string|null, date, amount,
                recovered, balance, paidFromAccountId, paidFromAccountName, notes: string|null,
                status: 'open'|'recovered'|'cancelled', createdAt, createdBy: {id, name},
                cancelledAt: string|null, cancelReason: string|null,
                recoveries?: { wageSheetId, wageSheetNumber, date /* paid date */, amount }[] /* detail only */ }

WorkOrder { id, number, projectId, projectName, contractorPartyId, contractorName, date, title, scope: string|null,
            status: 'draft'|'active'|'closed'|'cancelled',
            retentionPct, advanceRecoveryPct, tdsPct, gstPct, itcEligible: boolean, cessPct,
            totalValue /* Σ line amount */, billedGross /* Σ gross of approved RA bills */,
            hasFinalBill: boolean,
            advance: { paid, recovered, balance }, retention: { held, released, balance },
            lines?: { id, lineNo, boqLineId: string|null, boqCode: string|null, description, unit, qty, rate, amount,
                      billedQty /* cumQty on the latest approved RA bill */ }[] /* detail only */,
            createdAt, createdBy: {id, name}, cancelledAt: string|null, cancelReason: string|null }

ContractorAdvance { id, number, workOrderId, date, amount, paidFromAccountId, paidFromAccountName, notes: string|null,
                    createdAt, createdBy: {id, name}, cancelledAt: string|null, cancelReason: string|null }

RetentionRelease { id, number, workOrderId, date, amount, notes: string|null, createdAt, createdBy: {id, name} }

RaBill { id, number, workOrderId, workOrderNumber, projectId, projectName, contractorPartyId, contractorName,
         billSeq /* 1, 2, 3… within the work order */, date, periodFrom: string|null, periodTo: string|null, dueDate,
         status: 'draft'|'submitted'|'approved'|'cancelled', isFinal: boolean,
         lines?: { workOrderLineId, description, unit, rate, qty /* work-order qty */, prevQty, cumQty, thisQty, amount }[] /* detail only */,
         gross, cgst, sgst, igst, invoiceTotal /* gross + GST */,
         retention, advanceRecovery, tds, cess, otherDeduction, otherDeductionNote: string|null,
         totalDeductions, netPayable, amountPaid, amountDue, paymentStatus: 'unpaid'|'partial'|'paid',
         notes: string|null, rejectReason: string|null /* cleared on submit */,
         createdAt, createdBy: {id, name}, submittedAt: string|null, approvedAt: string|null, approvedBy: {id, name}|null,
         cancelledAt: string|null, cancelReason: string|null }

Unit { id, projectId, projectName, code /* "A-1203" */, wing: string|null, floor: number|null, unitType /* "2 BHK" */,
       carpetArea /* m², RERA carpet area */, balconyArea: number|null, listPrice,
       status: 'available'|'hold'|'booked'|'agreement'|'possession', bookingId: string|null, notes: string|null, createdAt }

PaymentPlan { id, projectId, name, isActive: boolean, stages: { id, name, pct, sortOrder }[], createdAt }

Booking { id, number, projectId, projectName, unitId, unitCode, customerPartyId, customerName, date,
          agreementValue, gstPct, paymentPlanId, paymentPlanName,
          status: 'booked'|'agreement'|'possession'|'cancelled',
          agreementNo: string|null, agreementDate: string|null, possessionDate: string|null, notes: string|null,
          stages: { id, name, pct, amount, sortOrder, demandId: string|null, demandNumber: string|null }[],
          totals: { demanded /* excl. GST, open demands */, gst, received /* Σ amountPaid of open demands */,
                    due /* Σ amountDue of open demands */, undemanded /* agreementValue − demanded */ },
          createdAt, createdBy: {id, name}, cancelledAt: string|null, cancelReason: string|null }

Demand { id, number, bookingId, bookingNumber, projectId, unitCode, partyId, partyName, date, dueDate,
         stages: { id, name, pct, amount }[], amount /* excl. GST */, cgst, sgst, total, amountPaid, amountDue,
         paymentStatus: 'unpaid'|'partial'|'paid', status: 'open'|'cancelled',
         createdAt, createdBy: {id, name}, cancelledAt: string|null, cancelReason: string|null }

ProjectRera { projectId, reraRegNo: string|null, reraAccountId: string|null, reraAccountName: string|null, to,
              collections /* receipts allocated to this project's demands, GST share excluded */,
              required /* 70% of collections */, deposited /* debits to the RERA account up to `to` */,
              withdrawn /* credits to it */, balance /* deposited − withdrawn */, shortfall /* max(0, required − deposited) */ }
```

### Calculations

Every amount is rounded to paise, half up.

**RA bill:**
- **Quantities.** `prevQty` is that line's `cumQty` on the work order's latest approved bill (0 if there is none). Then:
  - `thisQty = cumQty − prevQty`
  - `amount = thisQty × rate`
  - `gross = Σ amount`
- **GST** is `gross × gstPct ÷ 100`.
  - It is split into equal CGST and SGST halves when the contractor's `stateCode` equals the company's, or the contractor has none.
  - Otherwise it is all IGST.
- **Default deductions**, all on `gross` (TDS is on the amount excluding GST):
  - `retention = gross × retentionPct`
  - `tds = gross × tdsPct`
  - `cess = gross × cessPct`
  - `advanceRecovery = min(advance balance, gross × advanceRecoveryPct)`
- **Overrides.** A draft may override `retention`, `advanceRecovery`, `tds`, `cess` and `otherDeduction`:
  - each must be between 0 and `gross`
  - `advanceRecovery` may not exceed the advance balance (`400`)
- **Net payable:** `netPayable = gross + GST − retention − advanceRecovery − tds − cess − otherDeduction`. A negative result is a `400`.

**Default `tdsPct` on a new work order:**
- 1 when the contractor's PAN has P or H as its 4th character (individual or HUF; for GSTIN-only parties use GSTIN characters 3–12).
- Otherwise 2.
- The client may change it. TDS thresholds are not applied automatically; set 0 where TDS does not apply.

**Booking stages:**
- `amount = agreementValue × pct ÷ 100`. The last stage takes the remainder, so the stages always add up to `agreementValue`.
- GST on a demand: `cgst = sgst = amount × gstPct ÷ 200`. The place of supply of a flat is the property, so it is always intra-state for the builder.
- The default `gstPct` is 5. Use 1 for affordable housing, and 0 when the whole consideration is received after the completion certificate.

### Journals

Zero lines are dropped. The location dimension is the worker's site for labour advances, and the project's first site (by name) for subcontract and real-estate vouchers, or none.

| Voucher type | When | Lines |
| --- | --- | --- |
| `labour_advance` | advance paid | Dr Labour Advances / Cr cash or bank |
| `contractor_advance` | mobilisation advance paid | Dr Contractor Advances (party) / Cr cash or bank |
| `ra_bill` | RA bill approved | Dr Subcontract Work `gross` (+ GST when `itcEligible` is false) / Dr Input CGST, SGST or IGST (when `itcEligible`) / Cr Accounts Payable (party) `netPayable` / Cr Retention Payable / Cr Contractor Advances (party) / Cr TDS Payable / Cr BOCW Cess Payable / Cr Other Income `otherDeduction` (penalties, recoveries for material or services supplied) |
| `retention_release` | retention released | Dr Retention Payable / Cr Accounts Payable (party) |
| `demand` | demand raised | Dr Accounts Receivable (party) `total` / Cr Customer Advances — Bookings `amount` (Property Sales once the booking is in possession) / Cr Output CGST, Output SGST |
| `possession` | possession recorded | Dr Customer Advances — Bookings / Cr Property Sales, for Σ `amount` of the booking's open demands |

Cancelling any of these posts the reversal (`is_reversal`, `reverses_id`), as for other documents.

## Endpoints

### Labour advances

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /labour-advances` | `wages.view` | list query + `workerId, siteId, status` | `{data: LabourAdvance[], total}` newest first |
| `GET /labour-advances/:id` | `wages.view` | — | `LabourAdvance` with `recoveries` |
| `POST /labour-advances` | `wages.pay` | `{ workerId, date?, amount, paidFromAccountId /* cash or bank */, notes? }` | `201 LabourAdvance`. The site is the worker's home site. |
| `POST /labour-advances/:id/cancel` | `wages.pay` | `{ reason }` | `LabourAdvance`. Only while `recovered = 0` (`409`). |

**Wage sheet changes:**
- **Defaults.** On create and recompute, each row's `advance` defaults to `min(advanceBalance, 50% of gross)`, rounded down to paise. A recompute keeps an advance the user edited, if it is still within the cap.
- **Cap.** `PATCH` and approve enforce `advance ≤ min(advanceBalance, 50% × gross)` (`400`). This is the Code on Wages limit on deductions.
- **Paying** records recoveries against the worker's open advances, oldest first. An advance becomes `recovered` when its balance reaches 0. If a balance has dropped below the row's advance since approval, paying returns `409`.

### Work orders

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /work-orders` | `subcontracts.view` | list query + `projectId, contractorId, status` | `{data: WorkOrder[], total}` newest first, without lines |
| `GET /work-orders/:id` | `subcontracts.view` | — | `WorkOrder` with lines |
| `POST /work-orders` | `subcontracts.manage` | `{ projectId, contractorPartyId /* supplier or both */, date?, title, scope?, retentionPct?, advanceRecoveryPct?, tdsPct?, gstPct?, itcEligible?, cessPct?, activate?: boolean, lines: [{ boqLineId?, description, unit, qty, rate }] /* 1–500 */ }` | `201 WorkOrder` (`draft`, or `active` if `activate`) |
| `PATCH /work-orders/:id` | `subcontracts.manage` | any create field except `projectId`; `lines` replaces every line | `WorkOrder`. Lines and percentages can change only while no RA bill exists (`409`); `title`, `scope` and `date` can always change until closed. |
| `POST /work-orders/:id/activate` | `subcontracts.manage` | — | draft → active |
| `POST /work-orders/:id/close` | `subcontracts.approve` | — | active → closed; `409` while a draft or submitted RA bill exists |
| `POST /work-orders/:id/cancel` | `subcontracts.approve` | `{ reason }` | draft or active, with no approved RA bill and no uncancelled advance (`409`) |
| `GET /work-orders/:id/advances` | `subcontracts.view` | — | `{data: ContractorAdvance[], total}` |
| `POST /work-orders/:id/advances` | `subcontracts.approve` | `{ date?, amount, paidFromAccountId, notes? }` | `201 ContractorAdvance`. The work order must be active. |
| `POST /contractor-advances/:id/cancel` | `subcontracts.approve` | `{ reason }` | `ContractorAdvance`; `409` if the advance balance would go below 0 |
| `GET /work-orders/:id/retention-releases` | `subcontracts.view` | — | `{data: RetentionRelease[], total}` |
| `POST /work-orders/:id/retention-releases` | `subcontracts.approve` | `{ date?, amount, notes? }` | `201 RetentionRelease`. `amount ≤ retention.balance` (`400`). |
| `GET /work-orders/:id/ra-bill-template` | `subcontracts.manage` | — | an unsaved `RaBill` for the next bill: `prevQty` per line, `cumQty = prevQty`, default percentages. Feeds the form. |

### RA bills

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /ra-bills` | `subcontracts.view` | list query + `workOrderId, projectId, contractorId, status, paymentStatus` | `{data: RaBill[], total}` newest first, without lines |
| `GET /ra-bills/:id` | `subcontracts.view` | — | `RaBill` with lines |
| `POST /ra-bills` | `subcontracts.manage` | `{ workOrderId, date?, periodFrom?, periodTo?, dueDate? /* default date + contractor creditDays */, isFinal?, notes?, lines: [{ workOrderLineId, cumQty }], retention?, advanceRecovery?, tds?, cess?, otherDeduction?, otherDeductionNote?, submit?: boolean }` | `201 RaBill` (see the rules after this table) |
| `PATCH /ra-bills/:id` | `subcontracts.manage` | same fields except `workOrderId`; draft only (`409`) | `RaBill` (recomputed) |
| `POST /ra-bills/:id/submit` | `subcontracts.manage` | — | draft → submitted |
| `POST /ra-bills/:id/reject` | `subcontracts.approve` | `{ reason }` (3–300 characters) | submitted → draft, with `rejectReason` |
| `POST /ra-bills/:id/approve` | `subcontracts.approve` | — | submitted → approved; posts the `ra_bill` journal |
| `POST /ra-bills/:id/cancel` | `subcontracts.approve` | `{ reason }` | `RaBill`. Only an approved bill with `amountPaid = 0` that is the work order's latest approved bill (`409`); reverses the journal. |

**`POST /ra-bills` rules:**
- The work order must be active and have no approved final bill.
- Only one draft or submitted bill may exist per work order (`409`).
- Each line's `cumQty` must be between `prevQty` and the work-order `qty` (`400`). Omitted lines keep `cumQty = prevQty`.
- `thisQty` cannot be negative.

**Paying contractors and collecting from customers.** Use `POST /payments`:
- **Payments** (`kind: payment`) allocate to purchases and approved RA bills (`netPayable`).
- **Receipts** (`kind: receipt`) allocate to invoices and open demands (`total`).
- **Allocation.** Automatic allocation takes the oldest documents first, across both types. `allocations: [{ docId, amount }]` still takes only the id; the server finds the document.
- **Outstanding.** `GET /parties/:id/outstanding` lists demands with `invoices`, and RA bills with `purchases`, each carrying `docType`.
- **Ageing.** `GET /reports/ageing` counts them too.

### Real-estate sales

| Method & path | Permission | Body / query | Response |
| --- | --- | --- | --- |
| `GET /units` | `units.view` | list query + `projectId, status, wing, unitType` | `{data: Unit[], total}` ordered by wing, floor, code |
| `GET /units/:id` | `units.view` | — | `Unit` |
| `POST /units` | `units.manage` | `{ projectId, code, wing?, floor?, unitType, carpetArea, balconyArea?, listPrice?, notes? }`, or `{ projectId, units: [ …same without projectId… ] }` for bulk (max 500) | `201 Unit` or `201 {data: Unit[], total}`. `code` is unique per project, ignoring case (`409`). |
| `PATCH /units/:id` | `units.manage` | any create field except `projectId`, plus `status` (only `available` ↔ `hold`; `409` otherwise) | `Unit` |
| `GET /payment-plans` | `units.view` | list query + `projectId, activeOnly` | `{data: PaymentPlan[], total}` |
| `GET /payment-plans/:id` | `units.view` | — | `PaymentPlan` |
| `POST /payment-plans` | `units.manage` | `{ projectId, name, stages: [{ name, pct }] /* 1–30 */ }` | `201 PaymentPlan`. Σ `pct` must be exactly 100 (`400`). |
| `PATCH /payment-plans/:id` | `units.manage` | `{ name?, isActive?, stages? }` (`stages` replaces them; existing bookings keep their own copy) | `PaymentPlan` |
| `GET /bookings` | `bookings.view` | list query + `projectId, unitId, customerId, status` | `{data: Booking[], total}` newest first |
| `GET /bookings/:id` | `bookings.view` | — | `Booking` |
| `POST /bookings` | `bookings.manage` | `{ unitId, customerPartyId /* customer or both */, date?, agreementValue? /* default unit listPrice; > 0 */, gstPct?, paymentPlanId /* active, same project */, notes? }` | `201 Booking`; the plan's stages are copied. The unit must be `available` or `hold` (`409`) and becomes `booked`. |
| `PATCH /bookings/:id` | `bookings.manage` | `{ notes?, gstPct?, agreementValue? }` (the last two only while no open demand exists, `409`; the value change re-splits the stages) | `Booking` |
| `POST /bookings/:id/agreement` | `bookings.manage` | `{ agreementNo, agreementDate }` | booked → agreement; the unit becomes `agreement` |
| `POST /bookings/:id/demands` | `bookings.manage` | `{ stageIds: string[] /* ≥ 1 */, date?, dueDate? /* default date + 15 days */ }` | `201 Demand` (see the rules after this table) |
| `POST /bookings/:id/possession` | `bookings.manage` | `{ date }` | `Booking` (agreement → possession; the unit becomes `possession`). Every stage must be demanded (`409`). Posts the `possession` journal. |
| `POST /bookings/:id/cancel` | `bookings.manage` | `{ reason }` | `Booking` (see the rules after this table) |
| `GET /demands` | `bookings.view` | list query + `bookingId, projectId, customerId, status, paymentStatus, from, to` | `{data: Demand[], total}` newest first |
| `GET /demands/:id` | `bookings.view` | — | `Demand` |
| `POST /demands/:id/cancel` | `bookings.manage` | `{ reason }` | `Demand`. Only open, with `amountPaid = 0`, and the booking not in possession (`409`). Reverses the journal; the stages become undemanded. |
| `GET /projects/:id/rera` | `bookings.view` | `?to=` (default today) | `ProjectRera` |

**`POST /bookings/:id/demands` rules:**
- The stages must belong to the booking and be undemanded (`409`).
- While the booking is `booked`, total demanded excluding GST may not exceed 10% of `agreementValue` (`409 AGREEMENT_REQUIRED`, RERA s.13(1)).
- The demand posts the `demand` journal.

**`POST /bookings/:id/cancel` rules:**
- Only `booked` or `agreement` bookings can be cancelled.
- It returns `409` while any open demand has `amountPaid > 0`. Cancel or reallocate those receipts first; refunds come in a later phase.
- It cancels the open demands and their journals, and the unit becomes `available`.

### GST e-invoice and e-way bill

Two modes, set on the company. A live GSP connection comes in a later phase.
- **`manual`:** Progen builds the IRP JSON. The user uploads it on the IRP portal or offline tool, then records the IRN, acknowledgement and signed QR that come back.
- **`sandbox`:** Progen generates test values locally for demos and training. They are always flagged `sandbox: true` and are never valid for filing.
  - IRN = lowercase SHA-256 hex of `supplierGstin + fy ("2026-27") + "INV" + invoiceNumber`
  - acknowledgement number: 15 digits
  - `signedQrCode`: base64url of a JSON summary (seller GSTIN, buyer GSTIN, number, date, total, item count, main HSN, IRN)

| Method & path | Permission | Body | Response |
| --- | --- | --- | --- |
| `GET /invoices/:id/einvoice/payload` | `einvoice.manage` | — | the IRP schema Version 1.1 JSON for this invoice (see `docs/research/gst-einvoice-ewaybill.md` §6). `400 VALIDATION_ERROR` with `details` naming any missing data: company GSTIN or pincode, party GSTIN, pincode or state, or line HSN. |
| `POST /invoices/:id/einvoice` | `einvoice.manage` | sandbox: `{}`; manual: `{ irn /* 64 hex */, ackNo, ackDate, signedQrCode }` | `Invoice`. `409` if `einvoiceEnabled` is false, the invoice is cancelled, or an active IRN exists. `400` for a party without GSTIN (B2C). |
| `POST /invoices/:id/einvoice/cancel` | `einvoice.manage` | `{ reasonCode: '1'|'2'|'3'|'4' /* duplicate, data-entry mistake, order cancelled, other */, remark }` | `Invoice`. Within 24 h of `ackDate` (otherwise `409 IRN_CANCEL_WINDOW`: issue a credit note); `409` while an active e-way bill exists. The invoice itself stays posted. |
| `POST /invoices/:id/ewaybill` | `einvoice.manage` | `{ transportMode, distanceKm /* 0–4000 */, vehicleNo? /* required for road */, transporterGstin? }`; manual mode adds `{ ewbNo /* 12 digits */, ewbDate, validUntil }` | `Invoice`. Needs an active IRN (`409`). Sandbox: a random 12-digit number; valid to 23:59:59 IST of the generation day plus 1 day per 200 km (minimum 1). |
| `POST /invoices/:id/ewaybill/cancel` | `einvoice.manage` | `{ reasonCode: '1'|'2'|'3'|'4', remark }` | `Invoice`. Within 24 h of `ewbDate` (`409`). |

**Related rules:**
- `POST /invoices/:id/cancel` returns `409 IRN_ACTIVE` while the invoice has an active IRN. Cancel the IRN first, within 24 h, or issue a credit note.
- When an active IRN exists, the invoice PDF prints the IRN, Ack No and Ack Date, a QR code of `signedQrCode`, and the e-way bill number and validity when present. Sandbox IRNs also print "SANDBOX — not valid for GST".

## Clarifications (backend)

- **Voucher types and audit:**
  - `JournalEntry.voucherType` (and `GET /journals?voucherType=`) gains `labour_advance`, `contractor_advance`, `ra_bill`, `retention_release`, `demand` and `possession`.
  - Audit `entity` gains `labour_advance`, `work_order`, `contractor_advance`, `ra_bill`, `retention_release`, `unit`, `payment_plan`, `booking`, `demand` and `einvoice`.
- **Party types:**
  - A work order's contractor must be a `supplier` or `both`.
  - A booking's customer must be a `customer` or `both` (`400`).
- **RA bills:**
  - `billSeq` is the work order's highest bill number + 1; cancelled bills keep their number.
  - `billedQty` and `prevQty` come from the latest approved, uncancelled bill.
  - After an approved final bill, no more bills can be raised (`409`).
- **The RERA account** must be an active asset account with subtype `bank`. Users move money into it with a journal.
  - `deposited` counts every debit to it, and `withdrawn` every credit, up to `to`.
  - The GST share of each allocation is `allocation × (cgst + sgst) ÷ total`.

## Demo data (v1.3)

`npm run db:seed` also adds the following.

**Subcontracts:**
- A subcontractor party "Shree Constructions (Subcon)" (supplier, PAN `AAKFS1234C`).
- A work order on `PRJ-T1` with 3 lines linked to BOQ lines (retention 5%, advance recovery 10%, TDS 2%, GST 18%).
- A mobilisation advance.
- RA bill 1, approved and paid in full by a payment; RA bill 2, approved and unpaid; RA bill 3, draft.

**Labour:** two labour advances, one partly recovered by the paid wage sheet.

**Real estate:**
- Project `PRJ-R1` "Progen Heights", with 12 units (wings A and B, floors 1–3, two per floor).
- A construction-linked plan of 10/20/15/15/15/15/10.
- Three bookings:
  - one at agreement, with 3 demands and a part receipt
  - one booked, with the booking-amount demand
  - one cancelled
- RERA account "RERA Collection A/c — Progen Heights" (bank), with one transfer in.

**E-invoice:**
- Company pincode, plus party PAN and pincode on the demo parties.
- `einvoiceEnabled: true`, mode `sandbox`.
- One B2B invoice with a sandbox IRN.

---

# v1.4 additions — Statutory core and quick wins

For every Indian business, whatever the industry: GST 2.0 rates, TDS, reverse charge, MSME payment rules, the period lock, GST returns data, GSTR-2B matching, ITC ageing, bank reconciliation, licence reminders, setup health and data export. Research behind it: `docs/research/statutory-core.md` and `industry-verticals.md`.

Migration `007_statutory.sql` creates every table and column below. `db/schema.ts`, `auth/permissions.ts`, `accounting/accounts.ts`, `lib/series.ts` and `accounting/journal.ts` (period lock) are already updated.

**Rule for all statutory numbers:** rates, thresholds and due dates live in effective-dated tables (`gst_rates`, `tds_sections`) or in one constants file per topic, never inline in route code. Many come from secondary sources; rows with `verified: false` show an "unverified" badge in the UI.

## New permissions

| Key | Allows |
| --- | --- |
| `gst.view` / `gst.manage` | GSTR-1, GSTR-3B, 2B reconciliation, ITC ageing / import 2B, record IMS actions, add GST rates |
| `tds.view` / `tds.manage` | TDS deductions, challans, statements, summary / record and cancel challans, add TDS sections |
| `bank.reconcile` | Import bank statements, match, unmatch, ignore, create entries |
| `compliance.view` / `compliance.manage` | Licences and registrations, due-date alerts / add and edit them |
| `books.lock` | Set or clear `booksLockedUntil` |
| `data.export` | CSV export of company data |

Built-in roles gain:

| Role | New permissions |
| --- | --- |
| Owner, Company Admin | everything |
| Accountant | all of the above except `books.lock` |
| Project Manager, Site Supervisor | `compliance.view` |
| Auditor | every `.view` |

## New system accounts

| Code | Name | Type | `systemKey` |
| --- | --- | --- | --- |
| 1310 | TDS Receivable | asset (tax) | `tds_receivable` |
| 2130 | GST Payable — Reverse Charge | liability (tax) | `rcm_payable` |
| 5910 | Interest and Late Fee on Taxes | expense | `tax_interest` |

## Document numbers

| Document | Example |
| --- | --- |
| TDS challan | `TDC/26-27/00001` |
| RCM self-invoice | `RCM/26-27/00001` (15 characters; GSTN allows 16) |
| Bank entry | `BNK/26-27/00001` |

## Errors

| Status | `code` | When |
| --- | --- | --- |
| 409 | `PERIOD_LOCKED` | Any posting or reversal dated on or before `booksLockedUntil`. `details: { lockedUntil }`. Enforced in `postJournal` and `reverseEntry`, so every document type is covered. |
| 400 | `VALIDATION_ERROR` | A GST rate that is not valid for the document date (see below). `details` points at the field, e.g. `{ "lines.0.itemId": "12% is not a GST rate on 2026-10-29 for goods" }`. |
| 409 | `TDS_DEPOSITED` | Cancelling a purchase, expense or RA bill whose TDS is already in a posted challan. Cancel the challan first. |

## 1. GST rate master (GST 2.0)

```
GstRate { id, rate: number, kind: 'any'|'goods'|'services', label, effectiveFrom, effectiveTo: string|null,
          isLegacy: boolean, isSystem: boolean /* tenant_id null */ }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /gst-rates` | any signed-in user | `?date=YYYY-MM-DD` (default today) `&kind=goods|services` `&includeLegacy=true` | `{ data: GstRate[] }`: rows valid on `date`, ordered by rate. Legacy rows only with `includeLegacy`. |
| `POST /gst-rates` | `gst.manage` | `{ rate, kind, label, effectiveFrom, effectiveTo? }` | `201 GstRate` (a business row) |
| `PATCH /gst-rates/:id` | `gst.manage` | `{ effectiveTo: string|null, label? }` | `GstRate`. System rows: `403`. |

**Validation.** A rate is valid for a line when some row (system or the tenant's) has the same `rate`, covers the date (`effectiveFrom ≤ date ≤ effectiveTo` or open), and has `kind = 'any'` or the line's kind. The kind is `services` when the HSN/SAC code starts with `99`, else `goods`.
- Item create and edit: checked against today.
- Invoice and purchase lines: the item's rate, checked against the document date. The error names the item and tells the user to update its rate.
- Expenses: `gstRate` checked against `expenseDate` with any kind.
- Work orders: `gstPct` checked against `orderDate` as services.
- Credit notes keep the original invoice line's rate and are not checked.

Seeded system rows: 0, 5 and 18 (any, from 2017-07-01); 40 (any, from 2025-09-22); 0.25 and 3 (goods); 1 (services, affordable housing, from 2019-04-01); 12 (services, concessional entries kept after 22 Sep 2025, labelled "verify"); legacy 12 and 28 (any, 2017-07-01 to 2025-09-21).

## 2. TDS section master and deduction

```
TdsSection { id, code /* '194C' */, newRef: string|null /* 's.393(1) Sl. 6(i)' */, name,
             rateIndividual, rateOther, rateNoPan, thresholdSingle: number|null, thresholdAggregate: number|null,
             aggregateMode: 'whole'|'excess', effectiveFrom, effectiveTo: string|null, verified: boolean,
             isActive: boolean, isSystem: boolean }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /tds-sections` | any signed-in user | `?date=` (default today) `&activeOnly=true` | `{ data: TdsSection[] }` ordered by code |
| `POST /tds-sections` | `tds.manage` | every field except `id`, `isSystem` | `201 TdsSection` |
| `PATCH /tds-sections/:id` | `tds.manage` | `{ effectiveTo?, isActive?, name? }` | `TdsSection`. System rows: `403`. |
| `POST /tds/preview` | `purchases.create` or `expenses.create` or `tds.view` | `{ partyId, sectionId, date, gross, excludeSourceId? }` | `TdsCalc` |

```
TdsCalc { sectionId, sectionCode, rate, gross, base, amount, fyGross /* incl. this one */, threshold: number|null,
          reason: 'below_threshold'|'single'|'aggregate'|'excess'|'no_pan'|'lower_rate' }
```

**Calculation** (in `lib/tds.ts`; the FY is the document date's FY; `gross` is the value before GST):
- Rate: party PAN missing → `rateNoPan`. Else the 4th PAN letter `P` (individual) or `H` (HUF) → `rateIndividual`, otherwise `rateOther`.
- Let `prior` be the active `tds_deductions` rows for the same party, section code and FY, excluding `excludeSourceId`.
- `undeducted = Σ prior.gross − Σ prior.base`, and `fyGross = Σ prior.gross + gross`.
- `whole` mode:
  - if `thresholdAggregate` is set and `fyGross > thresholdAggregate`: `base = gross + undeducted` (catch-up), reason `aggregate`;
  - else if `thresholdSingle` is set and `gross > thresholdSingle`: `base = gross`, reason `single`;
  - else: `base = 0`, reason `below_threshold`.
- `excess` mode (194Q): `base = max(0, fyGross − thresholdAggregate) − max(0, Σ prior.gross − thresholdAggregate)`.
- `amount = round_half_up(base × rate ÷ 100)` to the paisa. `no_pan` replaces the reason whenever `rateNoPan` applied and `base > 0`.

**Deduction rows.** Every posted purchase, expense or approved RA bill that carries a section writes one `tds_deductions` row (even with amount 0), with `gross`, `base`, `rate`, `amount`, the party PAN at that time and the FY. Cancelling the document sets the row's status to `cancelled`. If the row has a challan, the cancel fails with `409 TDS_DEPOSITED`. RA bills use section `194C` with the work order's `tdsPct` as the rate, and `gross` = the bill gross; no threshold logic applies.

## 3. Master data changes

```
Company += { tan: string|null /* AAAA99999A */, booksLockedUntil: string|null, msmeBankRate: number|null /* % p.a., RBI bank rate */,
             gstFiling: 'monthly'|'quarterly' }
Party   += { udyamNo: string|null /* UDYAM-XX-00-0000000 */, msmeCategory: 'micro'|'small'|'medium'|null,
             tdsSectionId: string|null, tdsSectionCode: string|null }
```

- `PATCH /company`:
  - `booksLockedUntil` needs `books.lock`; every other field still needs `company.manage`.
  - Changing the lock writes an audit row with action `lock` or `unlock`.
- `POST /parties` and `PATCH /parties/:id` accept `udyamNo`, `msmeCategory` and `tdsSectionId`.
  - For a vendor (or `both`) that is `micro` or `small`, `creditDays > 45` is a 400: "MSME suppliers must be paid within 45 days (MSMED Act s.15)".

## 4. Purchases, expenses and receipts

**Purchase**

```
Purchase += { tdsSectionId: string|null, tdsSectionCode: string|null, tdsBase, tdsRate, tdsAmount,
              netPayable /* total − tdsAmount */, reverseCharge: boolean, rcmSelfInvoiceNo: string|null,
              msmeDueDate: string|null, msmeCategory: 'micro'|'small'|'medium'|null }
```

- `POST /purchases` (and the preview, if any) accepts:
  - `tdsSectionId?: string|null`. When it is absent the party's `tdsSectionId` is used; an explicit `null` means no TDS.
  - `reverseCharge?: boolean`, default false.
- `amountDue = netPayable − amountPaid`, and `paymentStatus` uses `netPayable`.
  - `GET /parties/:id/outstanding`, payment allocation, ageing and the dashboard use `netPayable` for purchases.
  - The `net_payable` column is generated, so never write it.
- **Reverse charge.** The supplier charges no GST.
  - `cgst`, `sgst` and `igst` hold the tax the business pays under RCM. `total = subtotal + roundOff` excludes them, and `taxTotal` still shows the tax.
  - A self-invoice number is taken from the `rcm_invoice` series.
- **MSME.** When the party is `micro` or `small` on the bill date, `msmeDueDate = billDate + (creditDays > 0 ? min(creditDays, 45) : 15)`.

Purchase journal, for ₹10,000 of goods at 18% intra-state, with 194Q not applicable and 194C at 2% on a service:
- Normal: Dr Inventory or expense 10,000; Dr Input CGST 900; Dr Input SGST 900; Cr Payable (party) `total − tds`; Cr TDS Payable `tds`.
- RCM: Dr Inventory or expense 10,000; Dr Input CGST 900; Dr Input SGST 900; Cr Payable (party) `10,000 − tds`; Cr TDS Payable `tds`; Cr GST Payable — Reverse Charge 1,800.

**Expense**

```
Expense += { tdsSectionId, tdsSectionCode, tdsBase, tdsRate, tdsAmount, netPaid /* total − tdsAmount */,
             reverseCharge: boolean, rcmSelfInvoiceNo: string|null }
```

- `POST /expenses` accepts `tdsSectionId?: string|null` (default: the party's section when `partyId` is given, else none) and `reverseCharge?: boolean`.
  - Both need a `partyId`; without one they are a 400.
- The paid-from account is credited with `netPaid`, and TDS Payable with `tdsAmount`.
- With reverse charge, `total = amount` and the tax goes as in the RCM purchase: Dr Input, Cr GST Payable — Reverse Charge.

**Receipt with TDS deducted by the customer**

```
Payment += { tdsAmount: number /* receipts only; 0 for payments */ }
```

- `POST /payments` with `kind: 'receipt'` accepts `tdsAmount?` (≥ 0). For a payment it is a 400.
- The receipt settles `amount + tdsAmount`: Σ allocations ≤ `amount + tdsAmount`, and `allocated`/`unallocated` use that sum.
- Journal: Dr Cash/Bank `amount`; Dr TDS Receivable `tdsAmount`; Cr Receivable (party) `amount + tdsAmount`.
- Cancelling reverses it as before.

## 5. TDS deductions, challans and statements

```
TdsDeduction { id, sourceType: 'purchase'|'expense'|'ra_bill', sourceId, number, date, partyId, partyName,
               pan: string|null, sectionCode, gross, base, rate, amount, status: 'active'|'cancelled',
               challanId: string|null, challanNumber: string|null }
TdsChallan   { id, number, depositDate, bsrCode /* 7 digits */, challanSerial /* 5 digits */, taxAmount, interest,
               lateFee, total, paidFromAccountId, paidFromAccountName, status: 'posted'|'cancelled', createdAt,
               createdBy: {id, name}, cancelledAt, cancelReason, deductions?: TdsDeduction[] /* detail */ }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /tds/deductions` | `tds.view` | `?fy=2026-27&quarter=1..4&sectionCode=&partyId=&challan=none|any&status=active` | `{ data: TdsDeduction[], total }`, newest first, `amount > 0` rows only unless `includeZero=true` |
| `GET /tds/summary` | `tds.view` | `?fy=` | `{ fy, months: [{ month: 'YYYY-MM', deducted, deposited, pending, dueDate, overdue: boolean }], quarters: [{ quarter, form: '140', dueDate, rows, amount }] }` |
| `POST /tds/challans` | `tds.manage` | `{ depositDate, bsrCode, challanSerial, paidFromAccountId /* cash or bank */, deductionIds: string[] /* ≥ 1, active, amount > 0, no challan */, interest?, lateFee? }` | `201 TdsChallan`. Journal `tds_challan`: Dr TDS Payable `taxAmount`; Dr Interest and Late Fee on Taxes `interest + lateFee`; Cr paid-from `total`. |
| `GET /tds/challans` | `tds.view` | `?fy=&status=` | `{ data: TdsChallan[], total }` |
| `GET /tds/challans/:id` | `tds.view` | — | `TdsChallan` with `deductions` |
| `POST /tds/challans/:id/cancel` | `tds.manage` | `{ reason }` | `TdsChallan`; reverses the journal and frees its deductions |
| `GET /tds/statement` | `tds.view` | `?fy=&quarter=&format=json|csv` | JSON `{ form: '140', fy, quarter, deductor: { name, tan, pan }, challans: TdsChallan[], rows: [{ pan, partyName, sectionCode, newRef, date, gross, base, rate, amount, challanSerial, bsrCode, depositDate }], warnings: string[] }`. CSV has one row per deduction. Warnings cover a missing TAN, deductions without PAN and deductions not yet in a challan. |

**Due dates** (constants in `lib/due-dates.ts`):
- TDS deposit: the 7th of the next month; 30 April for March.
- Form 140 statements: 31 Jul (Q1), 31 Oct (Q2), 31 Jan (Q3), 31 May (Q4).
- GSTR-1: the 11th of the next month (monthly), or the 13th after the quarter (quarterly).
- GSTR-3B: the 20th (monthly), or the 22nd after the quarter (quarterly; the 22nd or 24th by state, **UNVERIFIED**).

The CSV is a working file for a TDS utility, not the official FVU format.

## 6. GST returns

The period is `YYYY-MM`. Data covers posted documents dated in the period, for the whole company, ignoring location scope. HSN is taken from the line.

| Endpoint | Permission | Response |
| --- | --- | --- |
| `GET /gst/gstr1?period=` | `gst.view` | `Gstr1` below. `&format=gstn` returns a JSON shaped like the GSTN offline tool (`gstin`, `fp: 'MMYYYY'`, `b2b`, `b2cl`, `b2cs`, `cdnr`, `cdnur`, `hsn`, `doc_issue`), marked `"_note": "Unofficial; check with the GST offline tool before upload"`. |
| `GET /gst/gstr3b?period=` | `gst.view` | `Gstr3b` below |
| `POST /gst/2b-imports` | `gst.manage` | Body `{ period, fileName?, data?: object /* GSTR-2B JSON as downloaded */, csv?: string }`, exactly one of `data` or `csv`. CSV columns: `gstin, name, docType, docNo, docDate (dd-mm-yyyy), taxable, igst, cgst, sgst, cess`. Re-importing a period replaces it. → `201 { importId, period, lines, matched, mismatch, missingInBooks }` |
| `GET /gst/2b-recon?period=` | `gst.view` | `{ period, importedAt: string|null, summary: { matched, mismatch, missingInBooks, missingIn2b, itcMatched: Tax, itcAtRisk: Tax }, rows: ReconRow[] }` with `&status=` filter |
| `PATCH /gst/2b-lines/:id` | `gst.manage` | `{ imsAction?: 'none'|'accept'|'reject'|'pending', purchaseId?: string|null /* manual link; re-evaluates the status */, note? }` → `ReconRow` |
| `GET /gst/itc-ageing?asOf=` | `gst.view` | `{ asOf, rows: [{ purchaseId, number, partyName, billDate, day180, daysLeft, total, unpaid, itc, reversal, status: 'ok'|'warn'|'due' }], totals: { unpaid, itc, reversal } }`. Only unpaid purchases with tax > 0. `reversal = round(itc × unpaid ÷ total)`. `warn` when `daysLeft ≤ 60`, `due` when `daysLeft ≤ 0`. |

```
Tax      { taxable, igst, cgst, sgst }
RateRow  { rate, taxable, igst, cgst, sgst }
Gstr1    { period, gstin, filing: 'monthly'|'quarterly',
           b2b:   [{ invoiceId, number, date, partyName, gstin, placeOfSupply, invoiceValue, rates: RateRow[] }],
           b2cl:  [{ invoiceId, number, date, placeOfSupply, invoiceValue, rates: RateRow[] }],   // inter-state, unregistered, invoice value > ₹1,00,000
           b2cs:  [{ placeOfSupply, supplyType: 'intra'|'inter', rate, taxable, igst, cgst, sgst }], // other unregistered, net of their credit notes
           cdnr:  [{ creditNoteId, number, date, invoiceNumber, partyName, gstin, placeOfSupply, noteValue, rates: RateRow[] }],
           cdnur: [{ creditNoteId, number, date, invoiceNumber, placeOfSupply, noteValue, rates: RateRow[] }], // notes on b2cl invoices
           nil:   { interRegistered, intraRegistered, interUnregistered, intraUnregistered },  // taxable value of 0% lines
           hsn:   [{ segment: 'b2b'|'b2c', hsnCode, description, unit, qty, rate, taxable, igst, cgst, sgst }],
           docs:  [{ kind: 'invoice'|'credit_note', from, to, total, cancelled }],
           totals: Tax /* outward net of credit notes */, ledger: { igst, cgst, sgst } /* output tax ledger movement in the period */,
           variance: { igst, cgst, sgst } /* totals − ledger */, warnings: string[] }
Gstr3b   { period,
           outward: Tax            /* 3.1(a): invoices − credit notes, rate > 0 */,
           zeroNil: { taxable }    /* 3.1(c) */,
           inwardRcm: Tax          /* 3.1(d): RCM purchases and expenses */,
           interStateUnregistered: [{ placeOfSupply, taxable, igst }] /* 3.2 */,
           itc: { rcm: Tax /* 4A(3) */, others: Tax /* 4A(5): non-RCM purchases and expenses */,
                  reversed: Tax /* 4B: 0 in v1.4 */, net: Tax },
           payable: { igst, cgst, sgst } /* outward + RCM − net ITC, floored at 0 per head; no cross-utilisation */,
           rcmCash: { igst, cgst, sgst } /* RCM tax, always payable in cash */, warnings: string[] }
ReconRow { id: string|null /* null for missing_in_2b */, status: 'matched'|'mismatch'|'missing_in_books'|'missing_in_2b',
           supplierGstin, supplierName, docType, docNo, docDate, taxable, igst, cgst, sgst,
           purchaseId: string|null, purchaseNumber: string|null, book: Tax|null, diff: Tax|null, imsAction, note }
```

**Matching.**
- A 2B line matches a posted purchase in the period, or the previous 3 months, when:
  - the supplier GSTIN is the same, and
  - the normalised supplier invoice number is the same (uppercase, with spaces, `/`, `-` and leading zeros removed).
- It is `matched` when every tax head is within ₹1 and taxable value is within ₹10; otherwise `mismatch`.
- No candidate means `missing_in_books`.
- `missing_in_2b` rows are purchases dated in the period with a supplier GSTIN and no linked 2B line.
- `itcAtRisk` is the tax on mismatch and `missing_in_2b` rows. "No action" in IMS may count as accepted on the portal, so the UI should say so.

## 7. Bank reconciliation

```
BankStatement { id, accountId, accountName, fileName, fromDate, toDate, closingBalance: number|null, lines: number,
                matched: number, unmatched: number, ignored: number, createdAt }
BankLine      { id, lineNo, date, description, reference: string|null, withdrawal, deposit, balance: number|null,
                status: 'unmatched'|'matched'|'ignored',
                match: { journalLineId, entryId, voucherType, number, date, narration, amount }|null }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `POST /bank-statements` | `bank.reconcile` | `{ accountId /* subtype bank */, fileName?, csv, mapping?: { date, description, reference, withdrawal, deposit, amount, balance /* header names */, dateFormat?: 'dd/mm/yyyy'|'dd-mm-yyyy'|'yyyy-mm-dd'|'dd-MMM-yyyy'|'dd/mm/yy' } }` | `201 BankStatement`. Without `mapping`, headers are detected from common Indian bank exports: Date, Txn Date, Value Date, Transaction Date; Narration, Description, Particulars, Remarks; Ref No, Chq/Ref No, Cheque No, UTR; Withdrawal, Debit, Withdrawal Amt; Deposit, Credit, Deposit Amt; Balance, Closing Balance. A signed `amount` column also works. Lines already imported for the same account (same date, amounts and reference) are skipped. Then auto-match runs. |
| `GET /bank-statements` | `bank.reconcile` | `?accountId=` | `{ data: BankStatement[], total }` |
| `GET /bank-statements/:id` | `bank.reconcile` | `?status=` | `BankStatement & { lines: BankLine[], bookBalance /* ledger balance of the account at toDate */, unmatchedBook: number /* count of the account's journal lines in the period not matched */ }` |
| `POST /bank-statements/:id/auto-match` | `bank.reconcile` | — | `{ matched: number }` |
| `GET /bank-lines/:id/candidates` | `bank.reconcile` | — | `{ data: [{ journalLineId, entryId, voucherType, number, date, narration, amount, partyName, score }] }`: unmatched journal lines on the account with the same amount and direction, within ±10 days |
| `POST /bank-lines/:id/match` | `bank.reconcile` | `{ journalLineId }` | `BankLine` |
| `POST /bank-lines/:id/unmatch` · `/ignore` | `bank.reconcile` | — | `BankLine` |
| `POST /bank-lines/:id/create-entry` | `bank.reconcile` | `{ accountId /* contra: any active non-cash, non-bank account */, partyId?, narration? }` | `BankLine` (matched). Posts a `bank_entry` journal `BNK/..` on the line date. A deposit is Dr bank, Cr contra; a withdrawal is Dr contra, Cr bank. |

**Auto-match.**
- A deposit pairs with a debit to the bank account, and a withdrawal with a credit.
- The amount must be equal, and the dates within ±3 days.
- A candidate wins outright when the line's reference, or a 12-digit UTR or UPI number found in the description, appears in the payment's `reference` or the entry narration.
- Otherwise the match is made only when exactly one candidate exists.
- A journal line can be matched to one bank line only.

## 8. Compliance documents, alerts, setup health, export, MSME dues

```
ComplianceDoc { id, name, category: 'licence'|'registration'|'insurance'|'certificate'|'agreement'|'other', docNo, issuedBy,
                issueDate, expiryDate: string|null, remindDays, locationId: string|null, locationName: string|null,
                fileId: string|null, notes, isActive, status: 'valid'|'expiring'|'expired'|'no_expiry', daysLeft: number|null,
                createdAt, updatedAt }
Alert         { kind: 'doc_expiry'|'gstr1_due'|'gstr3b_due'|'tds_deposit'|'tds_statement'|'msme_overdue'|'itc_180'|'books_unlocked',
                severity: 'info'|'warn'|'overdue', title, detail, dueDate: string|null, link: string /* app path */ }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /compliance-docs` | `compliance.view` | `?status=&category=&locationId=&q=&page=&pageSize=` | `{ data: ComplianceDoc[], total }`, ordered by expiry, soonest first |
| `POST /compliance-docs` | `compliance.manage` | `{ name, category, docNo?, issuedBy?, issueDate?, expiryDate?, remindDays?, locationId?, fileId?, notes? }` | `201 ComplianceDoc` |
| `GET /compliance-docs/:id` · `PATCH /compliance-docs/:id` | view / manage | the same fields, plus `isActive` | `ComplianceDoc` |
| `GET /compliance/alerts` | any of `dashboard.view`, `compliance.view`, `gst.view`, `tds.view` | `?days=30` | `{ data: Alert[] }` sorted by due date. Each family needs its own permission: docs `compliance.view`; GST and ITC `gst.view`; TDS `tds.view`; MSME `reports.view` or `purchases.view`; `books_unlocked` (no lock, or a lock older than the last FY end + 6 months) needs `books.lock`. Due dates come from `lib/due-dates.ts`, and alerts cover the next `days` plus anything overdue. |
| `GET /setup/health` | `company.manage` or `compliance.view` | — | `{ score /* 0–100, share of passed checks */, checks: [{ key, ok, severity: 'required'|'recommended', title, detail, link }] }` |
| `GET /export/:dataset` | `data.export` | dataset is one of `parties`, `items`, `invoices`, `invoice-lines`, `purchases`, `purchase-lines`, `payments`, `expenses`, `journal`; `?from=&to=` | `text/csv` with a header row and `Content-Disposition: attachment; filename="<dataset>-<yyyy-mm-dd>.csv"`. The journal export is a day book: date, voucher type, number, account code, account name, party, debit, credit, narration. |
| `GET /reports/msme-dues` | `reports.view` | `?asOf=` | `{ asOf, bankRate: number|null, rows: [{ purchaseId, number, partyId, partyName, udyamNo, category, billDate, msmeDueDate, unpaid, daysOverdue, interest: number|null }], totals: { unpaid, overdue, interest }, yearEndDisallowance /* unpaid past-due MSME amount at the last 31 Mar on or before asOf: s.37(2)(g), old 43B(h) */, warnings }` |

**Setup health checks:**
- Required:
  - company GSTIN
  - PAN
  - address and pincode
  - TAN, when any party has a TDS section or any deduction exists
  - at least one active location
- Recommended:
  - bank account details and a UPI ID, for QR codes on invoices
  - invoice terms
  - every item with an HSN code (shows the count missing)
  - every active item's GST rate valid today (shows the count that is not)
  - vendors with a TDS section have a PAN
  - customers with a GSTIN have a state code
  - the books lock set within the last 18 months
  - `msmeBankRate` set, when an MSME vendor exists
  - no expired compliance document

**MSME interest** (in `lib/msme.ts`): compound monthly at `3 × bankRate`. For each full month past `msmeDueDate`, `balance += balance × 3 × bankRate ÷ 1200`. A part month adds `balance × 3 × bankRate ÷ 1200 × days ÷ 30`. `interest = balance − unpaid`, rounded to the paisa. When `bankRate` is null, interest is null and a warning asks the user to set it in the company settings.

## 9. Client-side quick wins (no new endpoints)

- **UPI QR on the invoice PDF:** shown when the company has a `upiId` and the invoice has a balance. The QR encodes `upi://pay?pa=<upiId>&pn=<company name>&am=<amountDue, 2 dp>&tn=<invoice number>&cu=INR`.
- **WhatsApp:**
  - "Share on WhatsApp" on the invoice detail opens `https://wa.me/<91 + 10-digit phone>?text=<encoded>` with the invoice number, date, amount due, due date and the UPI link. With no phone, it opens `https://wa.me/?text=…`.
  - The same "Send reminder" sits on the ageing report rows and the party ledger.
- **GST rate picker:** item, expense and work-order forms offer `GET /gst-rates` rows for the date instead of free text.

## Demo data (v1.4)

`npm run db:seed` also adds the following.
- Company TAN `MUMP12345E`, `msmeBankRate` 6.25 and a books lock at the last 31 Mar before the seed date minus one year, so no seeded document is inside it.
- The 12% demo item moves to 5%.
- The subcontractor gets section 194C.
- A professional vendor "Mehta & Associates (CA)" (PAN `AAAPM1234C`, section 194J(a)) with one expense of ₹60,000, so TDS applies.
- A micro vendor (Udyam number, credit days 30) with one purchase overdue.
- An RCM expense: GTA freight from an unregistered transporter.
- A receipt with ₹1,000 TDS deducted by the customer.
- One TDS challan covering the subcontractor's RA bill deductions.
- Three compliance documents: one expiring in 20 days, one expired, one valid.
- One bank statement for the bank account with 5 lines: 3 auto-matched, 1 bank charge to create an entry from, 1 unmatched.

---

# v1.5 additions — Hardening (the app must not break)

These rules apply to every existing and future endpoint and screen. They add no new resources.

## Errors

New codes:

| Status | `code` | When |
| --- | --- | --- |
| 409 | `IN_USE` | Deleting or changing a record that other records reference (Postgres 23503 on delete/update). Message: "This record is used by other documents, so it can't be deleted. Deactivate it instead." |
| 409 | `REQUEST_IN_PROGRESS` | Same `Idempotency-Key` while the first request is still running |
| 409 | `TRY_AGAIN` | Serialization failure or deadlock (40001 / 40P01) that still fails after one automatic retry |
| 413 | `PAYLOAD_TOO_LARGE` | Body over 1 MB (file upload endpoints keep their own limit) |
| 422 | `IDEMPOTENCY_MISMATCH` | Same `Idempotency-Key` with a different method, path or body |
| 401 | `SESSION_REVOKED` | The user was deactivated, or lost access to the company in `x-company-id`, after the token was issued |

No user input may cause a 500. Postgres input errors map to `400 VALIDATION_ERROR`: 22001 (too long), 22003 (number out of range), 22007/22008 (bad date), 22P02 (bad value), 23502 (missing), 23514 (check). A 23503 on insert keeps `400 VALIDATION_ERROR` ("A referenced record is invalid."). A path id that is not a UUID gives `404 NOT_FOUND`. Malformed JSON gives `400 VALIDATION_ERROR`.

## Idempotency

- Every `POST` except `/auth/*` accepts an optional `Idempotency-Key` header: 8–100 characters from `[A-Za-z0-9_-]`.
- The server keeps tenant, user, key, method, path, a SHA-256 of the body, the status and the response body for 24 hours.
  - Same key and the same request: the stored response is replayed with the same status and the header `Idempotent-Replayed: true`. Nothing is created again.
  - Same key with a different request: `422 IDEMPOTENCY_MISMATCH`.
  - Same key while the first request is still running: `409 REQUEST_IN_PROGRESS`.
  - Only 2xx responses are stored, so a failed request can be retried with the same key.
- Client: one key per user submit. It is created when the user presses the button and reused for automatic retries of that submit only.

## Concurrency

- Payment allocation, credit-note application, cancelling a document, RA-bill approval, challan creation and 2B linking lock the affected documents with `select … for update`, ordered by id, before checking balances or status. Two simultaneous requests can never over-allocate, double-cancel or double-deposit.
- A stock movement that would take a stock balance below zero gives `409 INSUFFICIENT_STOCK`, even under concurrent requests (per item and location lock).
- Number series stay gap-tolerant and unique (the existing upsert).

## Input limits (where a field has no stricter rule)

| Kind | Rule |
| --- | --- |
| Money | ≤ 2 decimals, absolute value ≤ 1,00,00,00,00,000 (1e12) |
| Quantity | ≤ 3 decimals, absolute value ≤ 1e9 |
| Percent | 0–100, ≤ 2 decimals |
| Document date | 2000-01-01 to today + 365 days |
| Name or title | trimmed, 1–200 characters |
| Notes or narration | ≤ 2000 characters |
| Lines per document | 1–500 |

## Client rules (no new endpoints)

- A submit button is disabled while its request runs, shows progress and sends an `Idempotency-Key`.
- A form with unsaved edits asks "Discard changes?" before back, close or navigation.
- Every list and detail has loading, empty, and error-with-retry states.
  - 403 shows the lock view.
  - 404 shows "Not found" with a way back.
  - No connection shows "You're offline" with a retry.
  - Raw exception text is never shown.
- After a refresh failure, a 401 or `SESSION_REVOKED` goes to sign-in, then back to the page the user wanted.
- Number fields accept Indian grouping ("1,00,000"), reject letters, and enforce the input limits above. GSTIN, PAN, TAN, IFSC, pincode, phone, email and Udyam fields share one set of validators.
- An unknown route shows "Page not found".
- No layout overflow at 320 px width or at text scale 1.3.
- In release builds, uncaught errors are logged and show a friendly retry screen instead of the red error screen.

# v1.6 additions — Self-filing kit ("file it yourself")

Goal: an owner can file GST and TDS returns, pay advance tax and prepare their income-tax return without a CA, wherever the law allows. Progen does not file on the portal. It produces the numbers in the portal's order, the upload files where the portal accepts them, the set-off and challan amounts, checks before filing, and step lists. A register records what was filed, and that clears the alert. Where the law needs a CA, the app says so (§8). Research behind it: `docs/research/self-filing-gst.md` and `self-filing-income-tax.md`.

Migration `009_selffiling.sql` creates every table and column below. `db/schema.ts`, `auth/permissions.ts`, `accounting/accounts.ts`, `lib/series.ts` and the voucher types are already updated. The v1.4 rule still applies: every statutory rate, slab, cap and due date lives in an effective-dated table or a constants file (`lib/gst-penalties.ts`, `lib/income-tax.ts`, `lib/due-dates.ts`), each entry carrying `verified: boolean`. Responses that use an unverified figure include it in `unverified: string[]`, and the UI shows an "unverified" badge.

**Direct filing** through a GSP (GST) or ERI (income tax) is a later adapter. `company.gstProvider` is not added yet.

## New permissions

| Key | Allows |
| --- | --- |
| `tax.view` / `tax.manage` | Income-tax calculators, ITR data pack, the CA check / record and cancel income-tax payments |
| `assets.view` / `assets.manage` | Fixed-asset register and depreciation / add, capitalise, depreciate, dispose |

Filing GST returns needs `gst.manage`. Filing TDS returns needs `tds.manage`. Filing an ITR needs `tax.manage`. `GET /filings` needs `compliance.view`.

Built-in roles gain: Owner and Company Admin get everything. Accountant gets all four. Auditor gets `tax.view` and `assets.view`.

## New system accounts

| Code | Name | Type (subtype) | `systemKey` |
| --- | --- | --- | --- |
| 1320 | GST Cash Ledger | asset (tax) | `gst_cash` |
| 1330 | Advance Income Tax | asset (tax) | `advance_tax` |
| 1500 | Fixed Assets | asset (fixed_asset) | `fixed_assets` |
| 1510 | Accumulated Depreciation | asset (fixed_asset), credit balance | `accumulated_depreciation` |
| 4910 | Gain on Sale of Assets | income | `asset_gain` |
| 5400 | Depreciation | expense | `depreciation` |
| 5920 | Loss on Sale of Assets | expense | `asset_loss` |

The account subtype gains `fixed_asset`. New voucher types: `gst_payment`, `gst_setoff`, `tax_payment`, `asset_capitalise`, `depreciation`, `asset_disposal`.

## Document numbers

| Document | Example |
| --- | --- |
| GST payment (PMT-06) | `GPM/26-27/00001` |
| Income-tax payment | `ITP/26-27/00001` |
| Fixed asset | `FA/26-27/00001` |
| Depreciation run | `DEP/26-27/00001` |

## Errors

| Status | `code` | When |
| --- | --- | --- |
| 409 | `PREFILE_FAILED` | Marking a return filed, or downloading a filing file, while a check fails. `details: { checks: PrefileCheck[] }` (failed ones only). Repeat with `acknowledgeFailures: true` to record it anyway; the record keeps the list. |
| 409 | `ALREADY_FILED` | A filed record already exists for that return and period. Cancel it first. |
| 409 | `CASH_SHORTFALL` | Posting a GST set-off when the GST Cash Ledger balance is below the cash needed. `details: { shortfall: { igst, cgst, sgst, cess, interest, lateFee } }` |
| 409 | `ASSET_DISPOSED` | Editing, depreciating or disposing of a disposed asset |
| 409 | `NOT_LATEST` | Cancelling a depreciation run other than the latest posted one |
| 409 | `RUN_OVERLAP` | A depreciation run starting on or before an asset's `depreciatedUntil` for every selected asset |

## 1. Filing register and calendar

```
Filing { id, returnType, period, status: 'filed'|'cancelled', filedOn, arn: string|null /* ARN, token or acknowledgement no. */,
         amountPaid: number|null, notes: string|null, exportSha256: string|null, acknowledgedFailures: PrefileCheck[],
         setoffEntryId: string|null, createdAt, createdBy: {id, name}, cancelledAt, cancelReason }
returnType: 'gstr1'|'iff'|'gstr3b'|'pmt06'|'gstr9'|'gstr9c'|'tds_140'|'itr'
period:     GST monthly 'YYYY-MM' (quarterly filers use the quarter's last month), TDS '2026-27-Q2', annual '2026-27'
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /filings` | `compliance.view` | `?returnType=&fy=&status=filed` | `{ data: Filing[], total }`, newest period first |
| `POST /filings` | the return's manage permission | `{ returnType, period, filedOn /* ≤ today */, arn?, amountPaid?, notes?, exportSha256?, acknowledgeFailures?: boolean, postSetoff?: boolean /* gstr3b only */, igstSplit?: 'cgst_first'|'sgst_first' }` | `201 Filing`. For `gstr1`, `gstr3b` and `tds_140` it runs the prefile check first (§3, §5). `postSetoff` also posts the §2 set-off journal in the same transaction and stores `setoffEntryId`. |
| `POST /filings/:id/cancel` | the return's manage permission | `{ reason }` | `Filing`; also reverses its set-off journal |
| `GET /filings/calendar` | `compliance.view` | `?fy=` | `{ fy, rows: [{ returnType, period, label, dueDate, status: 'filed'|'due'|'overdue'|'upcoming', filingId: string|null, daysLate: number|null, estimate: { lateFee, interest }|null }] }`. It covers GSTR-1, GSTR-3B, PMT-06 (quarterly filers, months 1 and 2), GSTR-9 (turnover above Rs 2 crore, or when a filing exists), Form 140 per quarter (when TAN is set) and the four advance-tax dates (shown with status `upcoming` or `due`; payments are in §6). |

Compliance alerts (`GET /compliance/alerts`) now skip any GST or TDS return that has a filed record. They gain `pmt06_due`, `gstr9_due` and `advance_tax_due`.

## 2. GSTR-3B upgrade, ITC reversals and set-off

`Gstr3b` gains these fields. The existing fields are unchanged.

```
Gstr3b += { zeroRated: Tax /* 3.1(b): 0 until export invoices exist; a warning says so */,
            nonGst: { taxable } /* 3.1(e): 0 */,
            inwardExempt: { inter, intra } /* Table 5: taxable value of 0% purchase and expense lines */,
            itc: { ..., reversed: { rule42_43: Tax /* 4B(1): 0 */, rule37: Tax /* 4B(2) */ }, reclaimed: Tax /* 4D(1) */,
                   net: Tax /* 4A(3) + 4A(5) − 4B + 4D(1) */, others2b: Tax|null /* 2B ITC on matched and accepted lines; null when no 2B import */ },
            payableNoCross: { igst, cgst, sgst } /* the v1.4 `payable` */, filing: Filing|null }
```

`GET /gst/gstr3b?period=&format=gstn` returns JSON shaped like the portal's 3B upload (`gstin`, `ret_period: 'MMYYYY'`, `sup_details`, `inter_sup`, `itc_elg`, `inward_sup`, `intr_ltfee`). It is marked `"_note": "Unofficial; tables 3.1 and 3.2 are auto-filled on the portal"`.

**ITC reversal and reclaim (Rule 37).**
- A purchase reaches day 180 on `billDate + 180`. In the period that contains day 180, reverse `round(itc × unpaid ÷ total)` per head, where `unpaid` is the amount unpaid at day 180.
- Reclaim it in the period of each later payment against that bill: `round(itc × paid ÷ total)`, capped at what was reversed.
- Only posted, non-RCM purchases with tax above 0 count.

| Endpoint | Permission | Response |
| --- | --- | --- |
| `GET /gst/itc-reversals?period=&format=json|csv` | `gst.view` | `{ period, rows: [{ purchaseId, number, partyName, supplierGstin, billDate, day180, kind: 'reversal'|'reclaim', paymentId: string|null, base, igst, cgst, sgst }], totals: { reversal: Tax, reclaim: Tax } }`. This is the "reversal and reclaim statement" the portal asks for before 3B (Advisory 643). |
| `GET /gst/ledger-balances` | `gst.view` | `{ data: [{ id, ledger: 'credit'|'cash', asOf, igst, cgst, sgst, cess, note, createdAt, createdBy }] }`, newest first |
| `POST /gst/ledger-balances` | `gst.manage` | `{ ledger, asOf, igst, cgst, sgst, cess?, note? }` copied from the portal → `201`. The latest snapshot on or before a date is that ledger's balance. |
| `GET /gst/setoff?period=&igstSplit=` | `gst.view` | `Setoff` below |
| `POST /gst/payments` | `gst.manage` | PMT-06 challan paid: `{ date, cpin?, cin?, paidFromAccountId /* cash or bank */, igst, cgst, sgst, cess?, interest?, lateFee?, period? }` → `201 GstPayment`. Journal `gst_payment`: Dr GST Cash Ledger, Cr paid-from. |
| `GET /gst/payments` | `gst.view` | `?fy=` → `{ data: GstPayment[], total }` |
| `POST /gst/payments/:id/cancel` | `gst.manage` | `{ reason }` → reverses. `IN_USE` if a set-off posted after it would leave GST Cash Ledger negative. |

```
GstPayment { id, number, date, period: string|null, cpin, cin, paidFromAccountId, paidFromAccountName,
             igst, cgst, sgst, cess, interest, lateFee, total, status: 'posted'|'cancelled', createdAt, createdBy }
Heads      { igst, cgst, sgst, cess }
Setoff     { period, igstSplit: 'cgst_first'|'sgst_first',
             liability: Heads   /* 3B outward tax (3.1a) excluding RCM */, rcm: Heads /* 3.1(d), cash only */,
             credit: { opening: Heads /* latest credit-ledger snapshot on or before the 3B due date; 0 if none */,
                       itc: Heads /* 3B itc.net */, total: Heads },
             matrix: [{ from: 'igst'|'cgst'|'sgst'|'cess', to: 'igst'|'cgst'|'sgst'|'cess', amount }],
             creditUsed: Heads, creditCarryForward: Heads,
             cash: { tax: Heads /* liability left + rcm */, interest, lateFee, total },
             cashBalance: { books: number /* GST Cash Ledger balance */, portal: Heads|null /* latest cash snapshot */ },
             shortfall: Heads & { interest, lateFee, total },
             pmt06: { amounts: Heads & { interest, lateFee }, steps: string[] },
             late: { dueDate, daysLate, interest /* 18% p.a. on cash tax only, Rule 88B */, lateFee }, unverified: string[] }
```

**Set-off algorithm (Rule 88A; `lib/gst-setoff.ts`, a pure function on paise).**
- RCM is excluded from credit set-off and paid in cash.
- IGST credit pays IGST first. What is left pays CGST then SGST (`cgst_first`, the default), or SGST then CGST.
- CGST credit pays CGST, then IGST. SGST credit pays SGST, then IGST. CGST credit never pays SGST, and SGST credit never pays CGST.
- Cess credit pays cess only.
- Whatever is left, plus RCM, interest and late fee, is paid in cash.
- Required test: IGST credit 100, dues IGST 40, CGST 50, SGST 30 give IGST→IGST 40, IGST→CGST 50, IGST→SGST 10, and SGST 20 from SGST credit or cash.

**Set-off journal** (`gst_setoff`, dated the 3B filing date, posted by `POST /filings` with `postSetoff`):
- Debits:
  - Output IGST, CGST and SGST by the liability set off and paid.
  - GST Payable — Reverse Charge by the RCM tax paid.
  - Interest and Late Fee on Taxes by interest plus late fee.
- Credits:
  - Input IGST, CGST and SGST by credit used.
  - GST Cash Ledger by the cash total.
- `CASH_SHORTFALL` if the GST Cash Ledger balance is below the cash total. A warning (not an error) if an Input account would go negative.

**Late fee and interest** (`lib/gst-penalties.ts`):
- Late fee: Rs 50 a day (Rs 20 for a nil return) from the due date to the filing date or today.
- The cap depends on last year's turnover from invoices: Rs 2,000 up to 1.5 crore, Rs 5,000 up to 5 crore, Rs 10,000 above. The nil cap is Rs 500. The caps are **unverified**.
- Interest is 18% p.a. by day on the cash tax.

## 3. Pre-filing check

`GET /gst/prefile-check?period=&return=gstr1|gstr3b` (`gst.view`) → `{ period, return, checks: PrefileCheck[], canFile: boolean /* no fail */ }`.

```
PrefileCheck { id, title, status: 'pass'|'warn'|'fail'|'skip', detail, count: number|null, link: string|null /* client path */ }
```

| `id` | Return | Fails when | Warns when |
| --- | --- | --- | --- |
| `sequence` | both | the previous period's same return has no filed record (skip when the company's first period with documents is this one) | — |
| `gstin` | gstr1 | a B2B document's party GSTIN fails the checksum | — |
| `irn_missing` | gstr1 | e-invoicing is on and a B2B invoice has no IRN | — |
| `doc_series` | gstr1 | — | a gap in a document series |
| `hsn_digits` | gstr1 | — | HSN shorter than 4 digits (6 when last year's turnover is above Rs 5 crore) |
| `ledger_variance` | both | — | any GSTR-1 `variance` head above Rs 1 |
| `gstr1_filed` | gstr3b | GSTR-1 for the period is not filed | — |
| `ims_pending` | gstr3b | — | 2B lines with IMS action `pending` or `none` |
| `itc_vs_2b` | gstr3b | — | `itc.others` above `others2b` by more than Rs 1 on any head (DRC-01C risk), or no 2B import |
| `rule37` | gstr3b | — | §2 reversals or reclaims exist (include them in 4B(2) and 4D(1)) |
| `rcm_tieout` | gstr3b | 3.1(d) differs from RCM self-invoices in the period by more than Rs 1 | — |
| `cash_shortfall` | gstr3b | — | `Setoff.shortfall.total > 0` (with the amount to pay on PMT-06) |
| `late` | both | — | past the due date (with the late fee and interest estimate) |
| `time_bar` | both | more than 3 years after the due date | within 90 days of that limit |

## 4. GSTR-9 annual pack

`GET /gst/gstr9?fy=&format=json|csv` (`gst.view`) → `{ fy, gstin, turnover, mandatory: boolean /* above Rs 2 crore */, needs9c: boolean /* above Rs 5 crore */, tables: { t4: { b2b: Tax, b2c: Tax, creditNotes: Tax, rcm: Tax, net: Tax }, t5: { nilExempt, nonGst }, t6: { others: Tax, rcm: Tax }, t7: { rule37: Tax, rule42_43: Tax }, t8: { itcIn3b: Tax, itcIn2b: Tax|null, difference: Tax|null }, t9: { payable: Heads, paidCredit: Heads, paidCash: Heads }, t10_13: { note }, t17: HsnRow[] /* outward */, t18: HsnRow[] /* inward */ }, monthly: [{ period, gstr1: Tax, gstr3b: Tax, gstr1Filed: boolean, gstr3bFiled: boolean }], warnings, unverified }`.
- Monthly figures come from the books, as in GSTR-1 and 3B for each period. Paid figures come from posted set-off journals.
- Warnings cover:
  - months where a return is not filed (the portal blocks GSTR-9 until all are filed);
  - month figures that differ from the books after corrections.
- CSV gives one section per table.

## 5. TDS: file-ready statement, defaults and responsible person

**Company** gains these fields (`PATCH /company`, `company.manage`):
- `constitution`: `'proprietorship'|'partnership'|'llp'|'private_company'|'public_company'|'huf'|'trust'|'other'|null`
- `responsiblePerson`: `{ name, designation, pan, mobile, email } | null`, the deductor's responsible person for TDS statements. PAN is checked against the PAN pattern, mobile has 10 digits.
- `itrForm`: `'itr3'|'itr4'|'itr5'|'itr6'|null`, the form the business files, used as the ITR pack default.

| Endpoint | Permission | Response |
| --- | --- | --- |
| `GET /tds/statement?fy=&quarter=&format=txt` | `tds.view` | `text/plain`, file name `{TAN}_140_{fy}_Q{n}.txt`. A caret-delimited draft (FH/BH/CD/DD records, laid out after the 26Q v7.5 file format) for the user to validate with the official FVU, then upload the zip on the e-filing portal. The first line is a comment `#PROGEN BETA: validate with FVU before upload`, to be removed if the FVU rejects comment lines. Blockers give `PREFILE_FAILED` with checks `tan`, `responsible_person`, `pan_missing` (a deductee without a PAN at 20%, a warning only), `unchallaned` (deductions not in a challan), `challan_mismatch` (deduction total ≠ challan tax). |
| `GET /tds/prefile-check?fy=&quarter=` | `tds.view` | `{ fy, quarter, checks: PrefileCheck[], canFile }`: the blockers above, plus `sequence`, `late` (s.427 fee estimate) and `interest` (late deposit). |
| `GET /tds/defaults?fy=` | `tds.view` | `{ fy, deposits: [{ month, deducted, depositDate: string|null, dueDate, monthsLate, interest /* 1.5% a month or part from deduction month-end to deposit or today */ }], statements: [{ quarter, dueDate, filedOn: string|null, daysLate, lateFee /* Rs 200 a day, capped at the quarter's TDS */ }], totals: { interest, lateFee }, unverified }`. The interest base date is the deduction date. The 1% "not deducted" interest is out of scope. |

Steps shown in the TDS pack (client): pay the challan → record it → download the .txt → run the FVU (Protean) with the challan CSI file → upload the zip on incometax.gov.in → note the token number → mark filed (`tds_140`, `arn` = token) → download Form 131 (TDS certificate) from TRACES.

## 6. Income tax: payments, calculators, ITR pack

```
TaxPayment { id, number, kind: 'advance_tax'|'self_assessment'|'other', taxYear /* '2026-27' */, date, amount,
             bsrCode, challanSerial, cin: string|null, paidFromAccountId, paidFromAccountName, status, createdAt, createdBy }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /tax/payments` | `tax.view` | `?taxYear=` | `{ data: TaxPayment[], total }` |
| `POST /tax/payments` | `tax.manage` | `{ kind, taxYear, date, amount, bsrCode /* 7 digits */, challanSerial /* 5 digits */, paidFromAccountId }` | `201`. Journal `tax_payment`: Dr Advance Income Tax, Cr paid-from. |
| `POST /tax/payments/:id/cancel` | `tax.manage` | `{ reason }` | reverses |
| `POST /tax/calc/regime` | `tax.view` | `{ taxYear, age: 'below60'|'60to80'|'above80', salary?, business?, otherIncome?, deductions?: { s80c?, s80d?, homeLoanInterest?, other? } }` | `{ taxYear, new: TaxCalc, old: TaxCalc, better: 'new'|'old', saving, unverified }` |
| `POST /tax/calc/presumptive` | `tax.view` | `{ taxYear, kind: 'business'|'profession', digitalReceipts, cashReceipts, declaredProfit? }` | `{ eligible, limit, deemedIncome, declaredBelowDeemed: boolean, auditRisk: string|null, notes, unverified }` |
| `GET /tax/advance-tax` | `tax.view` | `?taxYear=&estimatedIncome=&regime=new|old&presumptive=true|false` | `{ taxYear, entity /* from constitution */, estimatedIncome /* if not given: profit so far × 12 ÷ months elapsed */, tax: TaxCalc, tdsCredit /* TDS Receivable movement in the year */, netTax, required: boolean /* netTax ≥ 10,000 */, instalments: [{ dueDate, cumulativePct, cumulativeDue, paidByDate, shortfall, interest425 }], interest424, paid, balance, unverified }` |
| `GET /tax/itr-pack` | `tax.view` | `?taxYear=&form=itr3|itr4&format=json|csv` | `ItrPack` below |
| `GET /tax/ca-required` | `tax.view` | `?taxYear=` | §8 |

```
TaxCalc { taxable, slabs: [{ from, to: number|null, rate, tax }], baseTax, rebate, surcharge, cess, total }
ItrPack { taxYear, form, entity, company: { name, pan, gstin, address },
          pnl: { revenue, otherIncome, purchases, directExpenses, employeeCost, financeCost, depreciationBooks, otherExpenses, netProfit,
                 lines: [{ schedule, label, amount, accounts: string[] }] },
          balanceSheet: { capital, loans, payables, otherLiabilities, fixedAssetsNet, inventory, receivables, cashBank, otherAssets, lines: [...] },
          depreciation: ItBlockRow[] /* §7 */,
          adjustments: [{ label, amount, kind: 'add'|'less', reason }]   /* book depreciation added back, IT depreciation less, tax interest 5910 added back, cash payments above Rs 10,000 (s.40A(3) equivalent) flagged */,
          presumptive: { digitalReceipts, cashReceipts, deemedIncome } | null /* itr4 */,
          tdsCredits: [{ deductorName, tan: string|null, amount }], taxesPaid: TaxPayment[],
          incomeEstimate, steps: string[], warnings, unverified }
```

Tax rates by entity in `lib/income-tax.ts`, all effective-dated and **unverified**:
- Individual and HUF: the v1.6 research slabs for the new and old regimes, the Rs 60,000 rebate up to Rs 12 lakh (new), the Rs 12,500 rebate up to Rs 5 lakh (old), surcharge 10/15/25% above Rs 50 lakh, 1 crore and 2 crore (37% above 5 crore, old regime only), and 4% cess.
- Firm and LLP: 30%.
- Company: 25% (turnover up to Rs 400 crore) or 22% (concessional) as the default.
- Marginal relief is ignored, and a warning says so.
- Advance tax instalments: 15% by 15 Jun, 45% by 15 Sep, 75% by 15 Dec, 100% by 15 Mar. Presumptive filers pay 100% by 15 Mar.
- s.425 interest: 1% a month on each shortfall (3 months, 1 for March). s.424 interest: 1% a month from April to the return month when paid is below 90%.

## 7. Fixed-asset register

```
FixedAsset { id, number, name, blockCode, blockName, bookMethod: 'slm'|'wdv', usefulLifeYears, residualPct /* default 5 */,
             cost, gstItc, purchaseDate, putToUseDate, locationId: string|null, locationName, supplierName, billNo,
             serialNo, tagNo, custodian, notes, openingAccDep, accumulatedDep, bookValue, depreciatedUntil: string|null,
             status: 'active'|'disposed', disposal: { date, saleValue, gainLoss, entryId } | null, createdAt }
ItBlock    { code, name, rate, effectiveFrom, verified }
ItBlockRow { blockCode, blockName, rate, openingWdv, additionsFull /* put to use ≥ 180 days in the year */, additionsHalf,
             saleValue, depreciation, closingWdv, shortTermGain /* block ceased or sale above WDV */ }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /fixed-assets/blocks` | `assets.view` | — | `{ data: ItBlock[] }` (system rows) |
| `GET /fixed-assets` | `assets.view` | `?status=&blockCode=&q=&locationId=` | `{ data: FixedAsset[], total, totals: { cost, accumulatedDep, bookValue } }` |
| `GET /fixed-assets/:id` | `assets.view` | — | `FixedAsset` plus `history: [{ date, kind, amount, entryId }]` |
| `POST /fixed-assets` | `assets.manage` | `{ name, blockCode, bookMethod, usefulLifeYears /* 1–100 */, residualPct?, cost, gstItc?, purchaseDate, putToUseDate /* ≥ purchaseDate */, sourceAccountId, openingAccDep?, locationId?, supplierName?, billNo?, serialNo?, tagNo?, custodian?, notes? }` | `201`. Journal `asset_capitalise` dated `putToUseDate`: Dr Fixed Assets `cost`, Cr `sourceAccountId` (bank, cash, payables, Purchases — Non-stock Items, an expense account, or Opening Balances for an asset already owned). With `openingAccDep`: Dr Opening Balances, Cr Accumulated Depreciation. `sourceAccountId` may not be Fixed Assets or Accumulated Depreciation. |
| `PATCH /fixed-assets/:id` | `assets.manage` | name, location, serialNo, tagNo, custodian, notes; also `usefulLifeYears` and `residualPct` (affect future runs only) | `FixedAsset` |
| `POST /fixed-assets/depreciation-runs` | `assets.manage` | `{ toDate, assetIds?: string[] /* default every active asset */ }`; `?preview=true` returns the lines without posting (`200`, `id` and `entryId` null) | `201 { id, number, fromDates, toDate, lines: [{ assetId, number, name, from, to, days, amount }], total, entryId }`. Each asset runs from `depreciatedUntil + 1` (or `putToUseDate`) to `toDate`. SLM: `(cost − residual) ÷ life × days ÷ 365`. WDV: rate `1 − (residual ÷ cost)^(1 ÷ life)` on the opening book value `× days ÷ 365`. Book value never goes below residual. Journal `depreciation` dated `toDate`: Dr Depreciation, Cr Accumulated Depreciation. Assets already depreciated to `toDate` are skipped. `RUN_OVERLAP` only if nothing is left to run. |
| `GET /fixed-assets/depreciation-runs` | `assets.view` | `?fy=` | `{ data: [...], total }` |
| `POST /fixed-assets/depreciation-runs/:id/cancel` | `assets.manage` | `{ reason }` | Reverses it and rolls back `depreciatedUntil`. `NOT_LATEST` unless it is the latest posted run. |
| `POST /fixed-assets/:id/dispose` | `assets.manage` | `{ date, saleValue /* ≥ 0; 0 for scrap */, receivedInAccountId? /* required if saleValue > 0 */, notes? }` | `FixedAsset`. Depreciation is first charged up to `date`. Journal `asset_disposal`: Dr Accumulated Depreciation (all), Dr received-in `saleValue`, Cr Fixed Assets `cost`, and the balance to Gain or Loss on Sale of Assets. GST on the sale is not posted: raise a sales invoice for that (the UI says so). |
| `GET /fixed-assets/it-schedule` | `assets.view` | `?fy=` | `{ fy, rows: ItBlockRow[], totals, unverified }`. The block method uses the full rate on opening + full additions − sale value, and half the rate on half additions (the sale value is set first against the opening and full additions). Opening WDV is last year's closing; for the first year it comes from `it_block_openings`. |
| `POST /fixed-assets/it-openings` | `assets.manage` | `{ fy, blockCode, openingWdv }` (upsert) | `{ fy, blockCode, openingWdv }` |

IT block rates (system rows of `it_depreciation_blocks`, effective 2026-04-01, `verified: false`):

| Block | Rate |
| --- | --- |
| `building_res` Residential building | 5% |
| `building` Other buildings | 10% |
| `temp_structure` Temporary structures | 40% |
| `furniture` Furniture and fittings | 10% |
| `plant` Plant and machinery | 15% |
| `vehicle` Motor cars (not for hire) | 15% |
| `computer` Computers and software | 40% |
| `intangible` Intangibles | 25% |
| `energy` Energy-saving and pollution-control equipment | 40% |

A `land` row with rate 0 exists for land, which is never depreciated (book runs skip it too).

## 8. "Do I need a CA?"

`GET /tax/ca-required?taxYear=` (`tax.view`) → `{ taxYear, needed: boolean /* any 'required' */, items: [{ id, severity: 'required'|'advised', title, reason, law, canSelfFile: string|null /* what the app still covers */ }], figures: { turnover, cashReceiptsPct, professionalReceipts: number|null, gstTurnover } }`.

| `id` | Severity | When |
| --- | --- | --- |
| `tax_audit` | required | Business turnover above Rs 1 crore (Rs 10 crore when cash receipts and payments are each 5% or less), or a presumptive filer declaring below the deemed rate (disputed; shown as **unverified**) |
| `company_audit` | required | `constitution` is a company or LLP (statutory audit; ITR-6 needs a DSC) |
| `gst_9c` | advised | GST turnover above Rs 5 crore (GSTR-9C is self-certified, but a review is advised) |
| `foreign` | advised | Any party or invoice with a foreign country, or an IGST export (15CA/15CB and the like) |
| `capital_gains` | advised | An asset disposal with a short-term gain on a building or land block |
| `constitution_missing` | advised | `constitution` not set |

The client words it as "The law requires a chartered accountant for this", or as "You can file this yourself. The app covers X, not Y".

## 9. Client (no new endpoints)

- **"Needs you" panel** on the dashboard and the Compliance hub, built from `/filings/calendar` (due and overdue) and `/compliance/alerts`. Each row opens the right wizard.
- **GST filing wizard** per period, in these steps:
  1. Checks: `prefile-check`.
  2. GSTR-1: download the JSON (show its SHA-256), the portal steps, then mark it filed with the ARN.
  3. Ledgers and set-off:
     - enter the portal balances;
     - pick the IGST split;
     - see the amounts for PMT-06 and record the payment.
  4. GSTR-3B worksheet in the portal's table order. Each row has a "portal shows" tick box, and tapping a figure copies it.
  5. Mark 3B filed with the ARN, which posts the set-off.
- **TDS filing pack** per quarter:
  - checks;
  - defaults with the interest and late fee to add to the challan;
  - the .txt download marked **beta**;
  - FVU and portal steps;
  - mark filed with the token.
- **Income tax:**
  - payments register;
  - regime, presumptive and advance-tax calculators;
  - the ITR pack screen (view, CSV, print to PDF);
  - "Do I need a CA?".
- **Fixed assets:**
  - register list and detail;
  - add asset;
  - depreciation run: preview the lines (`?preview=true`), then confirm to post;
  - dispose;
  - the IT schedule with editable first-year openings.
- Every portal step list ends with "Keep the acknowledgement PDF" and a field for the ARN.

## Demo data (v1.6)

- The seed sets `constitution: 'private_company'` and a responsible person.
- It records GSTR-1 and GSTR-3B as filed for the period before last (3B with the set-off posted after a PMT-06 payment), plus a credit-ledger snapshot.
- It adds five fixed assets: a building (opening asset, with opening accumulated depreciation), a car, two computers (one put to use under 180 days ago), and furniture. A depreciation run is posted to last month's end.
- It records one advance-tax payment and the first-year IT block openings.
