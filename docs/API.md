# Progen ERP API — v1 contract

The Flutter app (web, Android, iOS, desktop) and the backend both follow this file.
Change it first, then change both sides.

- Base URL: `http://<host>:8080/api/v1` (health check at `GET /health`, outside the prefix: `200 { status: "ok", db: "ok", time }`, or `503 { status: "unavailable", db: "down", time }` when the database does not answer within 2 s)
- Rate limits: every route is limited per IP (`RATE_LIMIT_PER_MINUTE`, default 600); sign-in routes have tighter limits. Over the limit: `429 RATE_LIMITED`.
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

# v1.7 additions — Enterprise platform

Goal: what an enterprise buyer checks before signing: strong sign-in, approvals with maker-checker, custom fields, bulk import, background work and notifications, several companies with inter-company entries and consolidated statements, cost centres, and a pluggable GST provider (GSP) adapter. Research behind it: `docs/research/ziperp-gap-analysis.md`.

Migration `010_enterprise.sql` creates every table, column and SQL function below. The following are already in place:
- `db/schema.ts`, `auth/permissions.ts`, `accounting/accounts.ts` (1295), `accounting/journal.ts` (`costCentreId` on `JLine`, the new voucher types), `lib/series.ts` and `config.ts`;
- `lib/crypto.ts` (`seal`, `unseal`, `sha256Hex`, `randomToken`);
- `lib/jobs.ts` (§5), `lib/notify.ts` and `lib/templates.ts` (§6), `lib/custom-fields.ts` (§8);
- `accounting/statements.ts` (trial balance, P&L with `costCentreId`/`locationId` filters, balance sheet), now used by `modules/reports.ts`;
- `RequestContext.forCompany(id)` and `contextFor(tx, db, tenantId, userId, companyId)`;
- `AppDeps` now carries `config`.
Module stubs are registered in `app.ts`.

**Not in v1.7:** SAML (Google Workspace and Microsoft Entra ID both offer OIDC), a live GSP (no provider chosen; §12 is the plug-in point), elimination of invoices between group companies, `.xlsx` upload (save as "CSV UTF-8", or paste from Excel), and mobile SSO.

## Configuration (backend/.env)

| Variable | Default | Use |
| --- | --- | --- |
| `APP_URL` | `http://localhost:5000` | Client base URL, used for links in emails and as the only allowed SSO `returnTo` |
| `PUBLIC_API_URL` | `http://localhost:8080` | Builds the SSO redirect URI `${PUBLIC_API_URL}/api/v1/auth/sso/callback` |
| `DATA_KEY` | derived from `JWT_SECRET` | 32 bytes, base64. Seals TOTP secrets, SSO client secrets and GSP credentials (AES-256-GCM). Set it in production; the server logs a warning when it is derived. |
| `EMAIL_DRIVER` | `log` | `log` or `smtp` |
| `SMTP_URL`, `EMAIL_FROM` | none | For `smtp`, e.g. `smtps://user:pass@smtp.example.com:465` and `Progen <no-reply@example.com>` |
| `WHATSAPP_DRIVER` | `log` | `log` or `cloud_api` (WhatsApp Business Cloud API) |
| `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_ID`, `WHATSAPP_API_VERSION` | none, none, `v21.0` | For `cloud_api` |
| `JOBS_WORKER` | `true` | Runs the job worker inside the API process. Tests build the app without it and call `runJobsOnce`. |

The `log` drivers write the message to the server log and mark it sent with `providerRef: 'log'`.

## New permissions

| Key | Allows |
| --- | --- |
| `approvals.view` | See every approval request in the company, not only your own and those waiting for you |
| `approvals.manage` | Create and edit approval rules |
| `imports.run` | Use the CSV import (the kind's own create permission is also needed) |
| `companies.create` | Add another company to the business |
| `security.manage` | SSO providers, the company's "require 2FA" switch |

Built-in roles gain:
- **Owner:** all five.
- **Company Admin:** `approvals.view`, `approvals.manage`, `imports.run`.
- **Accountant:** `approvals.view`, `imports.run`.
- **Auditor:** `approvals.view`.

## New system account, voucher types, document numbers

| Code | Name | Type (subtype) | `systemKey` |
| --- | --- | --- | --- |
| 1295 | Inter-company Account | asset (other); may run a credit balance | `intercompany` |

The new voucher types are `intercompany` and `opening`, the latter for account opening balances from an import.

| Document | Example |
| --- | --- |
| Approval request | `APR/26-27/00001` |
| Inter-company entry | `ICE/26-27/00001` (from the giving company's series) |

## Errors

| Status | `code` | When |
| --- | --- | --- |
| 401 | `MFA_INVALID` | Wrong or reused 2FA code at sign-in |
| 400 | `MFA_INVALID` | Wrong 2FA code on a `/me/2fa/*` call. `details: { code: 'Incorrect code' }` |
| 409 | `MFA_ALREADY_ENABLED` | `POST /me/2fa/setup` when 2FA is on |
| 409 | `MFA_REQUIRED_BY_COMPANY` | Turning 2FA off while a company of the user requires it |
| 403 | `MFA_ENROLMENT_REQUIRED` | A company requires 2FA and the user hasn't set it up (§1) |
| 423 | `ACCOUNT_LOCKED` | 10 failed sign-ins in a row. `details: { lockedUntil }` |
| 400 | `RESET_TOKEN_INVALID` | Unknown, used or expired password-reset token |
| 401 | `SESSION_REVOKED` | (v1.5 code) also when the session was ended (§3) |
| 403 | `SSO_REQUIRED` | Password sign-in or reset for an email whose domain enforces SSO. `details: { providerId }` |
| 400 | `SSO_DISCOVERY_FAILED` | The issuer's OIDC discovery document can't be fetched or is invalid |
| 409 | `SSO_DOMAIN_TAKEN` | Another business already has an active provider for that domain |
| 401 | `SSO_TICKET_INVALID` | Unknown, used or expired SSO ticket |
| 403 | `SELF_APPROVAL` | Approving or rejecting your own request |
| 403 | `ALREADY_ACTED` | Approving a second level of a request you already approved |
| 409 | `NOT_PENDING` | Acting on a request that is no longer pending |
| 409 | `NOT_VALIDATED` | Committing an import that isn't `validated` |
| 409 | `TOO_SOON` | A second payment reminder to the same party on the same channel within 24 hours |
| 409 | `GSP_NOT_CONFIGURED` | e-invoice mode `gsp` without a provider and its credentials |
| 501 | `NOT_SUPPORTED` | The e-invoice mode or provider lacks the capability (e.g. GSTR-1 upload) |
| 502 | `GSP_ERROR` | The provider rejected the call. `details: { provider, providerCode, providerMessage }` |
| 503 | `GSP_UNAVAILABLE` | The provider timed out or failed after two retries; nothing was recorded |

`Company` (v1.1) gains `require2fa: boolean`, `costCentreRequired: boolean`, `gspProvider: string|null`; `einvoiceMode` gains `'gsp'`. `PATCH /company` accepts `require2fa` (needs `security.manage`) and `costCentreRequired`.

## 1. Two-factor sign-in, lockout, password policy

```
LoginResult = Tokens /* v1 shape */ | { mfaRequired: true, mfaToken, methods: ['totp', 'recovery'] }
Security { twoFactorEnabled, twoFactorEnabledAt: string|null, recoveryCodesLeft, mustEnrol2fa, passwordChangedAt: string|null }
```

- **TOTP** follows RFC 6238: SHA-1, 6 digits, 30-second steps, ±1 step accepted. A step at or before the last one used is rejected (no replay).
- **Recovery codes:** 10, in the form `xxxx-xxxx` (lowercase letters and digits), stored as SHA-256. Each works once.
- **Secrets** are sealed with `lib/crypto.ts`.

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `POST /auth/login` | open | v1 | `LoginResult`. When 2FA is on, there are no tokens yet. `mfaToken` is a JWT of type `mfa` that lives 5 minutes. |
| `POST /auth/login/mfa` | open, rate-limited | `{ mfaToken, code? , recoveryCode? }` (exactly one) | `Tokens`. 401 `MFA_INVALID`; after 5 wrong codes the `mfaToken` stops working (401 `UNAUTHORIZED`). |
| `GET /me/security` | signed in | | `Security` |
| `POST /me/2fa/setup` | signed in | `{}` | `{ secret /* base32 */, otpauthUri: 'otpauth://totp/Progen:{email}?secret=…&issuer=Progen&digits=6&period=30' }`. Replaces any unfinished setup. |
| `POST /me/2fa/enable` | signed in | `{ code }` | `{ recoveryCodes: string[] }`, shown once. Emails `mfa_changed`. |
| `POST /me/2fa/disable` | signed in | `{ password, code /* TOTP or recovery */ }` | `204`. Emails `mfa_changed`. |
| `POST /me/2fa/recovery-codes` | signed in | `{ password, code }` | `{ recoveryCodes }`; the old ones stop working |
| `POST /users/:id/2fa/reset` | `users.manage` | | `204`. Turns the user's 2FA off and ends their sessions (lost phone). Audited. |
| `POST /users/:id/unlock` | `users.manage` | | `204` |

**Lockout:**
- 10 failed attempts in a row (wrong password or wrong code) lock the account for 15 minutes. Further attempts get 423 `ACCOUNT_LOCKED`, even with the right password.
- A successful sign-in, a password reset or an admin unlock clears the count.
- Unknown emails are still compared against a dummy hash and never locked.

**Require 2FA:** when any company the user belongs to has `require2fa` and the user hasn't turned 2FA on:
- password sign-in still works, and `GET /me` returns `user.mustEnrol2fa: true`;
- every other secured endpoint returns 403 `MFA_ENROLMENT_REQUIRED`;
- the exceptions are `GET /me`, `GET /me/security`, `/me/2fa/*`, `POST /me/password`, `/me/sessions*` and `GET /notifications/unread-count`;
- SSO sessions are exempt, because the identity provider does MFA.

**Password policy** (`lib/password.ts`) applies to signup, `POST /me/password`, reset and admin set:
- 8–128 characters, with at least one letter and one digit;
- not in the built-in list of common passwords;
- does not contain the email's local part when that part has 4 or more characters.

It fails with 400 and `details: { <field>: message }`.

## 2. Password reset

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `POST /auth/password/forgot` | open, 5 per minute per IP | `{ email }` | Always `204`. For an active user (and no enforced SSO on the domain), it makes a 32-byte random token and stores its SHA-256 with a 30-minute expiry. Earlier unused tokens stop working. It emails `password_reset` with `${APP_URL}/#/reset-password?token=…`. |
| `POST /auth/password/reset` | open, rate-limited | `{ token, newPassword }` | `204`. Sets the password, uses up the token, clears the lockout, ends every session, and writes audit `password_reset`. 2FA stays on. 400 `RESET_TOKEN_INVALID`. |

The admin `POST /users/:id/password` (v1.1) now also ends that user's sessions.

## 3. Sessions

```
Session { id, userAgent: string|null, ip: string|null, startedAt, lastUsedAt, method: 'password'|'mfa'|'sso', current: boolean }
```

- Each sign-in starts a session. A refresh keeps its id: `refresh_tokens.session_id`, backfilled to the token id for old rows.
- Access and refresh tokens carry `sid` (session id) and `amr` (`pwd`, `mfa` or `sso`).
- The secured hook rejects an access token whose session has no unrevoked refresh token with 401 `SESSION_REVOKED`, so ending a session takes effect on the next request.
- Tokens issued before v1.7 have no `sid` and work until they expire.

| Endpoint | Permission | Response |
| --- | --- | --- |
| `GET /me/sessions` | signed in | `{ data: Session[] }`, active only, most recently used first |
| `DELETE /me/sessions/:id` | signed in | `204` |
| `POST /me/sessions/revoke-others` | signed in | `204`; keeps the current one |

## 4. Single sign-on (OIDC)

```
SsoProvider { id, name, issuer, clientId, hasClientSecret, emailDomains: string[], enforce, autoProvision,
              defaultCompanyId: string|null, defaultRoleId: string|null, isActive, createdAt, updatedAt }
```

Providers belong to the business (tenant), not to one company.

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /sso-providers` | `security.manage` | | `{ data: SsoProvider[] }` |
| `POST /sso-providers` | `security.manage` | `{ name, issuer /* https */, clientId, clientSecret, emailDomains /* 1–10 */, enforce?, autoProvision?, defaultCompanyId?, defaultRoleId? }` | `201` (see the rules after this table) |
| `PATCH /sso-providers/:id` | `security.manage` | same, all optional; leaving out `clientSecret` keeps it | `SsoProvider` |
| `POST /sso-providers/:id/test` | `security.manage` | | `{ ok, message, authorizationEndpoint, tokenEndpoint, jwksUri }` |
| `DELETE /sso-providers/:id` | `security.manage` | | `204` (deactivates) |
| `GET /auth/sso/discover` | open, rate-limited | `?email=` | `{ providers: [{ id, name }], enforced: boolean }` |
| `GET /auth/sso/:id/start` | open | `?returnTo=` (must start with `APP_URL`; default `APP_URL`) | 302 to the IdP |
| `GET /auth/sso/callback` | open | `?code=&state=` (from the IdP) | 302 to the app (see the steps after this table) |
| `POST /auth/sso/redeem` | open, rate-limited | `{ ticket }` | `Tokens` with `amr: 'sso'`. 401 `SSO_TICKET_INVALID`. |

**Creating a provider:**
- It fetches `${issuer}/.well-known/openid-configuration` first, failing with 400 `SSO_DISCOVERY_FAILED`.
- A domain already used by any business's active provider fails with 409 `SSO_DOMAIN_TAKEN`.
- Public mail domains (gmail.com, googlemail.com, yahoo.com, yahoo.co.in, outlook.com, hotmail.com, live.com, rediffmail.com, icloud.com, proton.me, protonmail.com, aol.com, zoho.com) fail with 400.
- `autoProvision` needs both defaults, and the role and company must belong to the business.
- The client secret is sealed.

**Start (`GET /auth/sso/:id/start`):**
- It redirects with `response_type=code`, `scope=openid email profile`, `state`, `nonce`, PKCE S256 and `redirect_uri=${PUBLIC_API_URL}/api/v1/auth/sso/callback`.
- The state lives 10 minutes.

**Callback (`GET /auth/sso/callback`), in order:**
1. Exchanges the code (`client_secret_post`).
2. Verifies the ID token against the IdP's JWKS: signature, `iss`, `aud`, `exp` and `nonce`. It rejects `email_verified: false`.
3. Checks that the email's domain is in the provider's list.
4. Finds the active user with that email in the provider's business. Under `autoProvision` it creates one instead: name from the `name` claim, an unusable password hash, the default role in the default company.
5. Redirects to `${returnTo}#/sso/done?ticket=…`. The ticket works once and lives 60 seconds.

On failure it redirects to `${returnTo}#/login?ssoError=CODE`, where CODE is one of `SSO_STATE_INVALID`, `SSO_TOKEN_INVALID`, `SSO_DOMAIN_MISMATCH`, `SSO_NO_ACCOUNT`, `SSO_USER_LIMIT` (auto-provisioning would exceed the plan's user limit), `SSO_IDP_ERROR` or `ACCOUNT_DISABLED`.

**Enforced SSO:** password sign-in and forgot-password for a domain with an active `enforce: true` provider get 403 `SSO_REQUIRED`. Users who hold `security.manage` in any company are exempt (break-glass), so an owner can't lock the business out.

## 5. Background jobs

```
Job { id, kind, status: 'queued'|'running'|'done'|'failed', attempts, maxAttempts, runAfter, result: object|null, error: string|null,
      createdBy: {id, name}|null, createdAt, finishedAt: string|null }
```

**How the queue works:**
- Jobs live in the `jobs` table.
- The worker claims them with the security-definer `jobs_claim(limit)`, which uses `for update skip locked`, so several API instances can run workers.
- Each job runs in its own tenant transaction.
- A failure retries after 30 s × 2^(attempt − 1), up to `maxAttempts` (default 3), then the job is `failed` with `error`.
- A job left `running` for over 10 minutes goes back to `queued`.

**`lib/jobs.ts`:**
- `enqueue(tx, who, kind, payload, { runAfter?, dedupeKey?, maxAttempts? })`
- `registerJobHandler(kind, (tx, job, deps) => Promise<object|void>)`
- `runJobsOnce(deps, { limit? })`
- `startJobWorker(deps)`, which polls every second and once a minute schedules the daily jobs with `jobs_enqueue_daily(kind, day)` (one job per company, deduplicated by `kind:companyId:day`).

| Kind | What it does |
| --- | --- |
| `notification.send` | Delivers one email or WhatsApp outbox row (§6) |
| `import.commit` | Writes a validated import (§10) |
| `digest.compliance` | Daily at 09:00 IST per company: emails filings due within 7 days and overdue ones to users who opted in |
| `cleanup.auth` | Daily: deletes expired SSO states and tickets, reset tokens and refresh tokens over 30 days past expiry |

| Endpoint | Permission | Response |
| --- | --- | --- |
| `GET /jobs` | `company.manage` | `?status=&kind=&limit=&offset=` → `{ data: Job[], total }`, newest first |
| `GET /jobs/:id` | its creator, or `company.manage` | `Job` |
| `POST /jobs/:id/retry` | `company.manage` | A `failed` job goes back to `queued` with attempts reset → `Job`. Otherwise 409 `CONFLICT`. |

## 6. Notifications

```
Notification { id, template, title, body, link: string|null /* client route */, readAt: string|null, createdAt }
NotificationPref { template, label, email: boolean, whatsapp: boolean|null /* null = not offered */, mandatory: boolean }
OutboxRow { id, channel: 'email'|'whatsapp', to, template, subject: string|null, status: 'pending'|'sent'|'failed'|'skipped',
            attempts, error: string|null, providerRef: string|null, sentAt: string|null, createdAt }
```

**`notify(tx, who, { userIds?, to?: { email?, phone? }, template, data, link? })`** in `lib/notify.ts`:
- writes one in-app row per user;
- writes an email row per user who hasn't opted out, and a WhatsApp row where the template offers it, the recipient opted in and has a phone;
- writes an email or WhatsApp row for `to`, for people who aren't users, such as customers;
- enqueues one `notification.send` job per outbox row.

Templates live in `lib/templates.ts`. A row with no address is `skipped`.

| Template | In-app | Email | WhatsApp | Default |
| --- | --- | --- | --- | --- |
| `password_reset` | no | yes | no | mandatory |
| `mfa_changed` | no | yes | no | mandatory |
| `approval_requested` | yes | yes | no | email on |
| `approval_decided` | yes | yes | no | email on |
| `import_finished` | yes | no | no | in-app only |
| `compliance_digest` | no | yes | no | email off |
| `payment_reminder` | no | yes | yes | to customers, on request only |

**WhatsApp `cloud_api`:**
- Sends the approved template `payment_reminder` (language `en`) with body parameters: party name, amount due, oldest due date, company name, UPI ID or "—".
- The phone number becomes `91` plus 10 digits.

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /notifications` | signed in | `?unread=true&limit=&offset=` | `{ data: Notification[], total, unread }`: the caller's rows for the current company and rows with no company |
| `GET /notifications/unread-count` | signed in | | `{ unread }` |
| `POST /notifications/:id/read` | signed in | | `204` |
| `POST /notifications/read-all` | signed in | | `204` |
| `GET /me/notification-prefs` | signed in | | `{ data: NotificationPref[] }` |
| `PATCH /me/notification-prefs` | signed in | `{ prefs: [{ template, email?, whatsapp? }] }` | as GET. Turning off a mandatory one fails with 400. |
| `GET /notifications/outbox` | `company.manage` | `?status=&channel=&limit=&offset=` | `{ data: OutboxRow[], total }`, newest first |
| `POST /parties/:id/remind` | `invoices.view` | `{ channel: 'email'|'whatsapp' }` | `202 { outboxId }` (see the rules after this table) |

**Payment reminder (`POST /parties/:id/remind`):**
- The message gives the party's open invoices: count, total due, oldest due date and the company UPI ID.
- It fails with 400 when there is no email or phone, or nothing is due.
- A second reminder within 24 hours fails with 409 `TOO_SOON`.

## 7. Approval engine

```
ApprovalRule { id, docType, name, minAmount, locationId: string|null, locationName: string|null, isActive, createdAt, updatedAt,
               levels: [{ level, approverRoleId: string|null, approverUserId: string|null, label /* role or user name */ }] }
docType: 'purchase'|'payment'|'expense'|'journal'|'credit_note'
ApprovalRequest { id, number, docType, status: 'pending'|'approved'|'rejected'|'cancelled', amount,
                  summary: { date, partyName: string|null, locationName: string|null, narration: string|null },
                  payload: object /* the create body as submitted */, ruleId, ruleName,
                  levels: ApprovalRule['levels'] /* snapshot at submit */, currentLevel, totalLevels,
                  requestedBy: {id, name}, requestedAt, canAct: boolean /* caller may approve or reject now */,
                  document: { type: docType, id, number }|null, actions: ApprovalAction[], decidedAt: string|null }
ApprovalAction { level: number|null, action: 'submitted'|'approved'|'rejected'|'cancelled', by: {id, name}, comment: string|null, at }
```

**Covered creates:**

| Create | `docType` | Amount it's matched on |
| --- | --- | --- |
| `POST /purchases` | `purchase` | `total` |
| `POST /payments` with `kind: 'payment'` | `payment` | `amount` |
| `POST /expenses` | `expense` | total including tax |
| `POST /journals` | `journal` | total debit |
| `POST /credit-notes` | `credit_note` | `total` |

**Which rule applies:**
- Among active rules for the doc type with `minAmount ≤ amount` and a `locationId` that is null or equals the document's location, the highest `minAmount` wins.
- At the same amount, a location rule beats a company-wide one.
- With no match, the document is created at once, as before.

**Submit:**
1. The server runs the full create as a dry run inside a savepoint and rolls it back. A request that would fail is rejected immediately with the same error.
2. It stores the request and returns **`202 { approvalRequest }`**.

Nothing posts and no document number is used until the final approval. The levels are copied into the request, so later rule edits don't change pending requests.

**Approve:**
- A user qualifies for a level when they hold that level's role in this company, or are that level's user.
- The requester can never act on their own request (403 `SELF_APPROVAL`).
- Each level needs a different person (403 `ALREADY_ACTED`).
- The final approval creates the document as the requester, checking their current permissions and location access, inside the approver's transaction.
- If that create fails (books locked, stock moved, permission lost), the call returns that error and the request stays at its level. The approver can reject it.

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /approval-rules` | `approvals.manage` | `?docType=` | `{ data: ApprovalRule[] }` |
| `POST /approval-rules` | `approvals.manage` | `{ docType, name, minAmount ≥ 0, locationId?, levels: 1–5 × ({ approverRoleId } or { approverUserId }) }` | `201`. 400 when a role or user has no access to this company. |
| `PATCH /approval-rules/:id` | `approvals.manage` | any of the fields | `ApprovalRule` |
| `DELETE /approval-rules/:id` | `approvals.manage` | | `204` (deactivates) |
| `GET /approvals` | signed in; `scope=all` needs `approvals.view` | `?scope=awaiting_me|mine|all` (default `awaiting_me`) `&status=&docType=&limit=&offset=` | `{ data: ApprovalRequest[] /* without payload and actions */, total }`, newest first |
| `GET /approvals/count` | signed in | | `{ awaitingMe, mine }`, pending only |
| `GET /approvals/:id` | the requester, anyone who qualifies at any level, or `approvals.view` | | `ApprovalRequest` |
| `POST /approvals/:id/approve` | qualifies at `currentLevel` | `{ comment? }` | `ApprovalRequest`; after the last level, `status: 'approved'` and `document` set |
| `POST /approvals/:id/reject` | qualifies at `currentLevel` | `{ comment /* required, 3–500 */ }` | `ApprovalRequest` |
| `POST /approvals/:id/cancel` | the requester | | `ApprovalRequest` |

**Notifications and audit:**
- Submit notifies everyone who qualifies at level 1 (`approval_requested`, link `/approvals/:id`).
- Each step notifies the next level.
- Approve and reject notify the requester (`approval_decided`).
- Every action is audited as entity `approval_request`.

## 8. Custom fields

```
CustomField { id, entity: 'item'|'party'|'invoice'|'purchase'|'project', key /* ^[a-z][a-z0-9_]{1,29}$ */, label /* 1–60 */,
              type: 'text'|'number'|'date'|'boolean'|'select', options: string[] /* select: 1–50, each 1–60 */,
              required, showOnPrint, sortOrder, isActive, createdAt }
```

**Fields:**
- At most 25 active fields per entity.
- `key` and `type` never change.
- Options can be replaced; stored values stay and still show.

**Records:**
- Items, parties, invoices, purchases and projects gain `custom: { [key]: string|number|boolean }`, holding only keys with a value.
- Create bodies accept `custom`. The PATCH bodies of items, parties and projects merge it, and `null` clears a key.
- Invoices and purchases take `custom` on create only.

**`validateCustom(tx, companyId, entity, input, existing?)`** fails with 400 and `details: { 'custom.<key>': message }` for any of these:
- an unknown or inactive key;
- text over 500 characters;
- a number that isn't finite;
- a date not in `YYYY-MM-DD`;
- a boolean that isn't a boolean;
- a select value that isn't one of the options;
- a required field missing on create, or being cleared.

**Display:**
- CSV exports of these entities gain one column per active field, headed with the label.
- The invoice PDF prints `showOnPrint` fields under the header details.

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /custom-fields` | signed in | `?entity=&includeInactive=true` | `{ data: CustomField[] }` by `sortOrder`, then label |
| `POST /custom-fields` | `company.manage` | `{ entity, key, label, type, options?, required?, showOnPrint?, sortOrder? }` | `201`. 409 `CONFLICT` for a duplicate key; 400 over the limit. |
| `PATCH /custom-fields/:id` | `company.manage` | `{ label?, options?, required?, showOnPrint?, sortOrder?, isActive? }` | `CustomField` |

## 9. Cost centres and branch P&L

```
CostCentre { id, code /* 1–20, unique per company */, name, parentId: string|null, isActive, createdAt }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /cost-centres` | signed in | `?includeInactive=true` | `{ data: CostCentre[] }` by code |
| `POST /cost-centres` | `accounts.manage` | `{ code, name, parentId? }` | `201`; 409 `CONFLICT` for a duplicate code |
| `PATCH /cost-centres/:id` | `accounts.manage` | `{ name?, parentId?, isActive? }` | `CostCentre`; 400 if the parent would make a loop |
| `GET /reports/cost-centres` | `accounts.view` | `?from=&to=` | `{ from, to, rows: [{ costCentreId: string|null, code: string|null, name /* 'Untagged' for null */, parentId, income, expense, net }], totals: { income, expense, net } }` |

**Tagging documents:**
- Invoices, purchases, expenses and credit notes take an optional header `costCentreId`, which is returned too. A credit note defaults to its invoice's.
- The header tags the document's income and expense journal lines: sales, sales returns, COGS, non-stock purchases and expense heads. Balance-sheet lines are never tagged.
- Manual journals take `costCentreId` per line. On a balance-sheet account it fails with 400.
- An inactive or unknown cost centre fails with 400.
- With `company.costCentreRequired`, those documents and the P&L lines of manual journals need one: 400 with `details: { costCentreId: 'Required' }`.

**Branch P&L:**
- Invoices, purchases and credit notes now put `locationId` on every journal line, as expenses already did. Migration 010 backfills older lines from their documents.
- `GET /reports/profit-loss` accepts `costCentreId` and `locationId`, which filter journal lines. With `locationId` it is the branch P&L.

## 10. CSV import

```
ImportJob { id, kind, status: 'validated'|'invalid'|'queued'|'running'|'done'|'failed', fileName: string|null, totalRows, validRows,
            errors: [{ row /* 1 = first data row */, column: string|null, message }] /* first 200 */,
            preview: object[] /* first 20 normalised rows */, options: { asOf: string|null, updateExisting: boolean },
            result: { created, updated, skipped }|null, error: string|null, jobId: string|null,
            createdBy: {id, name}, createdAt, finishedAt: string|null }
kind: 'items'|'parties'|'opening_stock'|'account_balances'
```

**Input:**
- UTF-8 text, comma-separated, or tab-separated as pasted from Excel. The delimiter is detected from the header row.
- A header row is required. Names match without regard to case or spaces.
- At most 5,000 rows and 2 MB.

**Columns** (`*` = required):

| Kind | Columns | What it writes |
| --- | --- | --- |
| `items` | `name*`, `sku`, `hsn`, `unit*`, `gstRate*`, `salePrice`, `purchasePrice`, `trackStock` (yes/no), `reorderLevel`, `custom.<key>` | Items |
| `parties` | `type*` (customer/vendor/both), `name*`, `gstin`, `stateCode` (from the GSTIN when blank), `pan`, `phone`, `email`, `address`, `pincode`, `creditLimit`, `creditDays`, `openingBalance`, `openingType` (dr/cr), `custom.<key>` | Parties. `openingBalance` posts an `opening` journal on `asOf`, tagged with the party: `dr` is Dr Accounts Receivable / Cr Opening Balances; `cr` is Dr Opening Balances / Cr Accounts Payable. |
| `opening_stock` | `sku` or `itemName`*, `locationCode*`, `qty*` (> 0), `rate*` (≥ 0) | Opening stock moves, as `POST /stock/adjustments` with `isOpening` (Dr Inventory / Cr Opening Balances), dated `asOf` |
| `account_balances` | `accountCode*`, `debit`, `credit` (exactly one above 0) | One `opening` journal on `asOf`. Any difference goes to Opening Balances (3100). Receivables, payables, inventory, tax and inter-company accounts are refused; use the parties and stock imports for those. |

**Matching and errors:**
- Items match by `sku`, else by name (case-insensitive). Parties match by GSTIN, else by name and type.
- A match with `updateExisting: false` is an error ("already exists"). With `true`, the given columns update and blank cells leave fields as they are.
- An opening balance for a party that already has one is an error.
- Duplicate rows within the file are errors.
- `asOf` is required for the openings, and must fall in an open period.

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /imports/templates/:kind` | `imports.run` | | `text/csv`: the header and two example rows |
| `POST /imports` | `imports.run` plus the kind's permission (`items.create`, `parties.create`, `stock.adjust`, `accounts.journal`) | `{ kind, csv, fileName?, options?: { asOf?, updateExisting? } }`, body up to 3 MB | `201 ImportJob` with status `validated` or `invalid`. Nothing is written yet. |
| `GET /imports` | `imports.run` | `?limit=&offset=` | `{ data: ImportJob[] /* without preview and errors */, total }` |
| `GET /imports/:id` | `imports.run` | | `ImportJob` |
| `POST /imports/:id/commit` | as `POST /imports` | | `202 ImportJob` with status `queued`. 409 `NOT_VALIDATED`. |

The `import.commit` job validates again, because masters may have changed since. It then writes every row in one transaction, all or nothing. When done it notifies the creator (`import_finished`, link `/imports/:id`).

## 11. Several companies, inter-company entries, consolidation

```
IntercompanyEntry { id, number, date, amount, narration, status: 'posted'|'cancelled',
                    from: { companyId, companyName, accountId, accountName, entryId },
                    to:   { companyId, companyName, accountId, accountName, entryId },
                    createdBy: {id, name}, createdAt, cancelledAt: string|null, cancelReason: string|null }
```

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `POST /companies` | `companies.create` in the current company | `{ name, legalName?, stateCode, gstin?, pan?, copyAccountsFrom?: companyId }` | `201 Company` (see the steps after this table) |
| `GET /companies` | signed in | | `{ data: [Company & { roles }] }`, the caller's companies |
| `POST /intercompany-entries` | `accounts.journal` in both companies (else 403 `FORBIDDEN`) | `{ date, amount > 0, narration /* 3–300 */, from: { companyId, accountId }, to: { companyId, accountId } }` | `201 IntercompanyEntry` (see the rules after this table) |
| `GET /intercompany-entries` | `accounts.view` | `?counterpartyId=&from=&to=&status=&limit=&offset=` | `{ data: IntercompanyEntry[], total }`, where the current company is either side |
| `POST /intercompany-entries/:id/cancel` | `accounts.journal` in both | `{ reason }` | `IntercompanyEntry`; reverses both journals |
| `GET /reports/intercompany` | `accounts.view` | `?asOf=` | `{ asOf, rows: [{ companyId, companyName, balance /* + they owe us, − we owe them */ }], accountBalance /* this company's 1295 */, unexplained /* accountBalance − Σ balance */ }` |
| `GET /reports/consolidated/trial-balance` | `accounts.view` in every listed company (else 403) | `?companyIds=a,b /* 2–20 */&asOf=` | consolidated shape below |
| `GET /reports/consolidated/profit-loss` | same | `?companyIds=&from=&to=` | consolidated shape below |
| `GET /reports/consolidated/balance-sheet` | same | `?companyIds=&asOf=` | consolidated shape below |

**Adding a company (`POST /companies`):**
1. Creates it in the same business, with a Head Office location and the system accounts.
2. Gives the caller the Owner role there, for all locations.
3. With `copyAccountsFrom`, copies that company's non-system accounts; the caller needs `accounts.view` there.
4. Writes an audit entry.

**Posting an inter-company entry:**
- `from` is the company that gives, by paying or charging. It posts Dr Inter-company / Cr `from.accountId`.
- `to` posts Dr `to.accountId` / Cr Inter-company.
- Both journals are voucher type `intercompany`, carry one number and go in one transaction. Both periods must be open.
- Each account must belong to its company and be active. It can't be a receivables, payables, inventory or inter-company account.
- Manual journals on 1295 fail with 400 ("use an inter-company entry").

**Consolidated shape:** the single-company report shape plus:
- `companies: [{ id, name }]`;
- `byCompany: { [companyId]: amount }` on every row;
- `eliminations: { intercompany }`;
- `warnings: string[]`.

**Consolidation rules:**
- Rows merge by account code; the name comes from the first company listed. A different name for the same code adds a warning.
- Inter-company balances between companies in the list are eliminated, and their total is shown in `eliminations`.
- Balances with companies outside the list, and `unexplained` amounts, stay on an "Inter-company Account" row with a warning.
- Invoices between group companies are not eliminated in v1.7. The report warns when it finds a party whose GSTIN belongs to another listed company.

## 12. GSP adapter

```
GspProviderInfo { id, name, capabilities: ('einvoice'|'ewaybill'|'gstr1_save')[], credentialFields: [{ key, label, secret: boolean }] }
GspSettings { mode: 'manual'|'sandbox'|'gsp', provider: string|null, providers: GspProviderInfo[],
              credentials: { [key]: string|null } /* secret values are never returned: null */, savedSecrets: string[], updatedAt: string|null }
GspSubmission { id, kind: 'gstr1', period, provider, reference, status, createdAt, createdBy: {id, name} }
```

**Code layout:**
- `lib/gsp/types.ts` holds the interface, `lib/gsp/registry.ts` holds `registerGspAdapter`, `gspAdapter(id)` and `listGspAdapters()`, and `lib/gsp/sandbox.ts` is the v1.3 local fake moved behind the interface.
- No live provider ships. A new one is one file in `lib/gsp/` plus one line in the registry.
- Tests register a fake adapter.

```ts
interface GspCall { gstin: string; credentials: Record<string, string>; timeoutMs: number }
interface GspAdapter {
  id: string; name: string; capabilities: ReadonlySet<'einvoice' | 'ewaybill' | 'gstr1_save'>;
  credentialFields: { key: string; label: string; secret: boolean }[];
  ping(c: GspCall): Promise<{ ok: boolean; message: string }>;
  generateIrn(c: GspCall, payload: object /* v1.3 Version 1.1 JSON */): Promise<{ irn: string; ackNo: string; ackDate: Date; signedQr: string; signedInvoice: string | null }>;
  cancelIrn(c: GspCall, irn: string, reasonCode: '1' | '2' | '3' | '4', remark: string): Promise<{ cancelledAt: Date }>;
  generateEwb(c: GspCall, input: { irn: string; transportMode: string; distanceKm: number; vehicleNo?: string; transporterGstin?: string }): Promise<{ ewbNo: string; ewbDate: Date; validUntil: Date | null }>;
  cancelEwb(c: GspCall, ewbNo: string, reasonCode: '1' | '2' | '3' | '4', remark: string): Promise<{ cancelledAt: Date }>;
  saveGstr1?(c: GspCall, period: string, json: object): Promise<{ reference: string; status: string }>;
}
class GspError extends Error { constructor(code: string, message: string, transient: boolean) }
```

**Errors and retries:**
- A non-transient `GspError` becomes 502 `GSP_ERROR`.
- Transient errors (timeouts, network failures, HTTP 5xx) are retried twice inside the call, with backoff of 1 s and then 3 s, and then become 503 `GSP_UNAVAILABLE`.
- Nothing is recorded when a call fails.

**Modes** (`company.einvoiceMode`):
- `manual` records the IRN copied from the IRP portal, as in v1.3.
- `sandbox` uses the sandbox adapter. Its IRNs are marked `irnSandbox: true`, as before.
- `gsp` uses `company.gspProvider` with its saved credentials, otherwise 409 `GSP_NOT_CONFIGURED`.

The e-invoice and e-way bill endpoints keep their v1.3 shapes. In `sandbox` and `gsp` the request body is ignored and the adapter's answer is stored.

| Endpoint | Permission | Request | Response |
| --- | --- | --- | --- |
| `GET /company/gsp` | `einvoice.manage` | | `GspSettings` |
| `PATCH /company/gsp` | `company.manage` | `{ mode?, provider?, credentials?: { [key]: string|null } }` | `GspSettings`. Secrets are sealed; a secret left out is kept; `null` clears it. The provider must be registered and not `sandbox`. |
| `POST /company/gsp/test` | `einvoice.manage` | | `{ ok, message }` from `ping` |
| `POST /gst/gstr1/upload` | `gst.manage` | `{ period, acknowledgeFailures? }` | `201 GspSubmission` (see the steps after this table) |
| `GET /gst/submissions` | `gst.view` | `?period=` | `{ data: GspSubmission[] }` |

**GSTR-1 upload (`POST /gst/gstr1/upload`):**
1. Runs the GSTR-1 prefile check (409 `PREFILE_FAILED`, as in v1.6).
2. Builds the v1.4 GSTN JSON.
3. Calls `saveGstr1`.
4. Returns 501 `NOT_SUPPORTED` when the mode is `manual` or the provider lacks the capability.

The sandbox returns `reference: 'SBX-…'` and `status: 'saved'`. Filing with EVC or DSC still happens on the portal, and the v1.6 filing register is unchanged.

## 13. Client

- **Sign-in:**
  - a 2FA code step, with "Use a recovery code";
  - a locked-account message showing the time;
  - "Forgot password?" and `/reset-password?token=`;
  - "Sign in with SSO" after the email is typed (`discover`); when SSO is enforced the password field is hidden;
  - `/sso/done?ticket=` redeems the ticket;
  - an `ssoError` on `/login` shows a message.
- **MFA enrolment:** `MFA_ENROLMENT_REQUIRED`, or `mustEnrol2fa`, sends the user to the 2FA setup screen, the only screen allowed until it's done.
- **Profile → Security:**
  - 2FA setup: QR code, secret, confirm code, then the recovery codes shown once with copy;
  - turn off, and new recovery codes;
  - sessions with "Sign out" each and "Sign out everywhere else".
- **Admin → Security** (`security.manage`): the "Require 2FA" switch and SSO providers (list, form, test).
- **Users admin:** "Reset 2FA" and "Unlock".
- **Notifications:**
  - a bell in the app bar with an unread badge, polling `/notifications/unread-count` every 60 s while visible;
  - the notification list (tap opens `link`, mark read, mark all read);
  - notification settings.
- **Admin → Delivery log** (outbox) and **Background jobs** (with retry).
- **Approvals:**
  - Inbox with the tabs "Waiting for me", "My requests" and "All" (the last with `approvals.view`). The nav badge comes from `/approvals/count`.
  - A detail screen that renders the payload per doc type (party, date, lines, totals) and the action history, with approve, reject (comment required) and cancel.
  - A rules admin.
  - The `ApiClient` turns a `202` with `approvalRequest` into `ApprovalPendingException`. Busy buttons show "Sent for approval (APR/…)" and the form closes as after a save.
- **Custom fields:**
  - admin per entity;
  - a `CustomFieldsSection` in the item, party, invoice, purchase and project forms;
  - values on detail screens;
  - `showOnPrint` fields on the invoice PDF.
- **Cost centres:**
  - the master list;
  - a picker in the invoice, purchase, expense, credit-note and journal-line forms, required when the company says so;
  - cost-centre and location filters on the P&L;
  - the cost-centre report;
  - the "Cost centre required" switch on the company profile.
- **Import** (`/imports`), in steps:
  1. Pick the kind.
  2. Download the template.
  3. Pick a CSV file, or paste from Excel.
  4. Set the options and validate.
  5. Review the errors table (row, column, message) and the preview.
  6. Commit, and watch progress by polling `GET /imports/:id` every 2 s.
  7. See the result.

  There is also a history list.
- **Companies:**
  - "Add company" (`companies.create`);
  - the company switcher in the shell;
  - inter-company entries (list, form, cancel) and the balances report;
  - consolidated reports: pick companies, then TB, P&L and BS with per-company columns, eliminations and warnings.
- **Company profile → E-invoice provider:**
  - mode, provider, credential fields from `credentialFields`, and "Test connection";
  - the GST filing wizard's GSTR-1 step offers "Upload via provider" when the capability exists.

## Demo data (v1.7)

- **A second company,** "Progen Infra Projects LLP" (Gujarat, no GSTIN), in the demo business. owner@demo.in is its Owner.
- **One inter-company entry:** the main company pays 25,000 rent for the second company.
- **Cost centres:** `RET` Retail, `PRJ` Projects and `HO` Head office, with a few seeded invoices and expenses tagged.
- **Custom fields:**
  - item `brand` (text, printed);
  - party `region` (select: North, South, East, West);
  - invoice `po_number` (text, printed).
- **Approval rule:** payments of ₹5,00,000 or more need the Owner role at level 1.
  - accountant@demo.in has one pending request for ₹6,00,000.
  - The threshold is high so the live tests' payments don't need approval.
- **Imports:** one finished import of three items.
- **2FA:** off for every demo user.

# v1.8 additions — Commerce operations (order to cash, procure to pay)

Plan and reasons: docs/plan/ubos-discovery-and-plan.md. Shared foundation (lead): migration `012_commerce.sql` adds stock move kinds `grn`, `grn_cancel`, `stock_count`, `write_off`; `lib/series.ts` adds `sales_order` SO, `pick_list` PCK, `shipment` SHP, `sales_return` RMA, `purchase_order` PO, `grn` GRN, `stock_count` CNT.

Conventions are unchanged from v1.5–v1.7: money in rupees as numbers with 2 decimals, quantities with 3, `Idempotency-Key` on creates, `{ data, total }` lists, errors via `lib/errors.ts`, every write audited, row locks on state changes.

## A. Order to cash

Permissions: `sales_orders.view` (read sales orders, availability, pick lists, shipments, returns), `sales_orders.manage` (create, edit, confirm, reserve, cancel, close orders), `fulfilment.manage` (pick lists, picks, pack, dispatch, shipment status), `returns.manage` (create, receive, inspect, close, cancel returns). Defaults: Owner and Company Admin all four; Accountant `sales_orders.view`, `returns.manage`; Sales Executive `sales_orders.view`, `sales_orders.manage`; Store Keeper `sales_orders.view`, `fulfilment.manage`, `returns.manage`; Auditor `sales_orders.view`. Location scope applies everywhere: a record at a location outside the caller's scope is `404`. Another business's record is `404`.

All `POST` calls accept `Idempotency-Key`. Quantities have 3 decimals. Only stock-tracked items can be on an order (`400` otherwise).

### Items: barcode and scanner lookup

- `items` gain `barcode` (string 4–64 printable characters without spaces, unique per company, nullable) on create, patch, get and list; the list search also matches barcodes. A duplicate gives `409 CONFLICT` with `details.barcode`.
- `GET /items/by-code/:code` (`items.view`): exact barcode, else SKU (case-insensitive). `404` when neither matches.
- `GET /stock` rows gain `reservedQty` and `availableQty` (= `qty` − active reservations).

### Availability and reservations

Available at a location = on hand − active reservations at that location. `requireStock` (used by invoices, transfers, issues, adjustments, purchase and credit-note cancels) uses available, so a plain invoice cannot take stock held for an order: `409 INSUFFICIENT_STOCK`, `details { itemId, available, required, onHand, reserved }`. A dispatch consumes its own reservation first, so it passes. Reserving locks per item (advisory lock), so two simultaneous confirms for the last unit cannot both succeed.

`GET /sales-orders/availability?locationId=&q=&limit=&offset=` (`sales_orders.view`): stock-tracked, active items with their numbers at the location, for the item picker. `{ data: [{ itemId, name, sku, barcode, unit, salePrice, gstRate, onHand, reserved, available }], total }`.

### Sales order

States: `draft` → `confirmed` → `picking` → `packed` → `partially_dispatched` | `dispatched` → `closed`; `cancelled` from `draft`, `confirmed`, `picking`, `packed`, `partially_dispatched` (cancels what is not yet dispatched).

| From | Action | To |
| --- | --- | --- |
| draft | confirm | confirmed (reserves stock) |
| draft | cancel | cancelled |
| confirmed, picking, packed, partially_dispatched | cancel (all or per line) | cancelled, or unchanged with reduced quantities; `dispatched` if nothing is left to ship |
| confirmed | pick list created | picking |
| picking | all reserved quantity packed | packed |
| picking, packed | dispatch | partially_dispatched (open quantity remains) or dispatched |
| partially_dispatched | dispatch | partially_dispatched or dispatched |
| dispatched | close | closed |

Status is derived after every change from the line quantities: nothing open and something dispatched → `dispatched`; something dispatched and open quantity left → `partially_dispatched`; packed (not dispatched) equals reserved → `packed`; picked or on an open pick list → `picking`; else `confirmed`. Anything not in the table is `409 ILLEGAL_TRANSITION` ("This order is <status>, so it can't be <action>.") with `details { status }`.

Order JSON: `{ id, number, fy, status, source ('manual'|'csv'|'channel'), externalRef, locationId, locationName, partyId, partyName, orderDate, expectedDate, placeOfSupply, subtotal, taxTotal, total, notes, cancelReason, confirmedAt, packVerified, createdAt, createdBy { id, name }, lines [...] }`. Money is an estimate from the same GST rules as invoices; the invoice at dispatch is the tax document. Line: `{ id, lineNo, itemId, itemName, sku, barcode, unit, description, qtyOrdered, rate, discountPct, gstRate, allowBackorder, qtyReserved, qtyPicked, qtyPacked, qtyDispatched, qtyReturned, qtyCancelled, qtyOpen, qtyShort }`. `qtyOpen` = ordered − dispatched − cancelled; `qtyShort` = open − reserved. Quantities: `picked ≥ packed ≥ dispatched`; `reserved ≤ open`. `packVerified` is true when picked equals packed on every line (nothing waiting to be packed). The detail response also has `events [{ kind, message, createdAt, by }]` (timeline), `shipments [shipment summary]`, `returns [return summary]`.

| Method and path | Permission | Body / query | Result |
| --- | --- | --- | --- |
| `GET /sales-orders` | view | `q` (number, customer, external ref), `status`, `partyId`, `locationId`, `from`, `to`, `limit`, `offset` | `{ data: [order without lines], total }` |
| `GET /sales-orders/:id` | view | | order with lines, events, shipments, returns |
| `POST /sales-orders` | manage | `{ locationId, partyId, orderDate?, expectedDate?, externalRef?, notes?, lines: [{ itemId, qty, rate?, discountPct?, description?, allowBackorder? }] }` (1–200 lines) | `201` draft order. Rate defaults to the item's sale price. `externalRef` is unique per company and source: `409 DUPLICATE_ORDER` |
| `PATCH /sales-orders/:id` | manage | same fields, all optional; `lines` replaces all lines | draft only, else `409 ILLEGAL_TRANSITION` |
| `POST /sales-orders/:id/confirm` | manage | none | reserves each line: all of it, or `409 INSUFFICIENT_STOCK` with `details { shortages: [{ lineNo, itemId, itemName, available, required }] }` and nothing reserved. A line with `allowBackorder` reserves what is available (maybe zero) and shows `qtyShort` |
| `POST /sales-orders/:id/reserve` | manage | none | retries reservation of `qtyShort` for backorder lines; reserves what is available; allowed in `confirmed`, `picking`, `packed`, `partially_dispatched` |
| `POST /sales-orders/:id/cancel` | manage | `{ reason, lines?: [{ lineId, qty }] }` | without `lines` cancels all open quantity. Releases reservations. Not allowed while an open pick list holds the order (`409 HAS_OPEN_PICK_LIST`) |
| `POST /sales-orders/:id/close` | manage | none | only from `dispatched` |

### Pick lists and scanning

A pick list is for one location and one or more orders in `confirmed`, `picking` or `partially_dispatched`. Each line is a quantity still to pick: reserved − (picked − dispatched) − already on open pick lists. `409 NOTHING_TO_PICK` ("Nothing to pick at <location>") when nothing qualifies.

Pick list JSON: `{ id, number, status ('open'|'completed'|'cancelled'), locationId, locationName, orderNumbers [..], totalTarget, totalPicked, createdAt, completedAt, lines [{ id, lineNo, orderId, orderNumber, orderLineId, itemId, itemName, sku, barcode, unit, qtyTarget, qtyPicked }] }` (lines only on detail).

| Method and path | Permission | Body | Result |
| --- | --- | --- | --- |
| `GET /pick-lists` | view | `status`, `q`, `locationId`, paging | `{ data, total }` |
| `GET /pick-lists/:id` | view | | pick list with lines |
| `POST /pick-lists` | fulfilment.manage | `{ locationId, orderIds: [uuid] (1–50) }` | `201`; `409 ILLEGAL_TRANSITION` if an order is not pickable; `400` if an order is at another location |
| `POST /pick-lists/:id/scan` | fulfilment.manage | `{ scanId (4–100 chars, client-generated), code? , itemId?, qty? = 1, orderLineId? }`. Give `code` (barcode or SKU) or, for manual entry, `itemId` | `{ duplicate, item { id, name, sku }, qty, allocations [{ lineId, qty }], pickList }` |
| `POST /pick-lists/:id/complete` | fulfilment.manage | none | marks completed; short picks stay reserved and can go on a new list |
| `POST /pick-lists/:id/cancel` | fulfilment.manage | none | only when nothing has been picked (`409 HAS_PICKS`) |

Scan rules: unknown code `400 UNKNOWN_BARCODE`; item not on the list `400 WRONG_ITEM`; picking more than the list needs `400 OVER_PICK` (details `{ itemId, remaining }`); a closed list `409 ILLEGAL_TRANSITION`. A repeated `scanId` returns the first result with `duplicate: true` and changes nothing. Failed scans are not stored. When the item is on several lines, the quantity fills the lines in order; `orderLineId` targets one line.

### Pack

- `POST /sales-orders/:id/pack-scans` (fulfilment.manage): `{ scanId, code?|itemId?, qty? = 1 }` adds to packed quantity. Same errors as picking: `UNKNOWN_BARCODE`, `WRONG_ITEM` (item has nothing picked and unpacked on this order), `OVER_PACK` (400, packing more than picked). Idempotent by `scanId`. Result `{ duplicate, item, qty, order }`.
- `POST /sales-orders/:id/pack` (fulfilment.manage): `{ lines?: [{ lineId, qty }] }`; no `lines` packs everything picked and not yet packed. `400 OVER_PACK` if qty exceeds picked − packed. Result: the order (see `packVerified`).

### Dispatch

`POST /sales-orders/:id/dispatch` (fulfilment.manage; send an `Idempotency-Key`). Body `{ courier?, awb?, mode?: 'prepaid'|'cod' (default prepaid), codAmount? (default the invoice total when cod; must be 0 or omitted when prepaid), notes?, invoiceDate? }`. Dispatches all packed, undispatched quantity. In one transaction it: locks the order; requires `picked = packed` on every line with unshipped picks (`409 PACK_INCOMPLETE`, "Packed quantity does not match picked") and something packed (`409 NOTHING_TO_DISPATCH`); consumes the reservations; creates the tax invoice with the existing invoice function (GST, journal, stock out and cost of goods sold all come from it) at the order rate and discount; creates the shipment (`booked`) with its lines. Order status becomes `partially_dispatched` or `dispatched`. A second request with the same `Idempotency-Key` replays the first response; a second request without a key gets `409 ILLEGAL_TRANSITION` once the order is fully dispatched, or `409 NOTHING_TO_DISPATCH` when other quantity remains but none is packed; the database also holds a unique key per invoice and per dispatch key. Result `201`: shipment detail with `invoice { id, number, total }`.

### Shipments

States: `booked` → `in_transit` → `delivered`; `in_transit` → `rto_initiated` → `rto_delivered`; `in_transit` or `rto_initiated` → `lost`; `rto_initiated` → `delivered` (customer accepts after all). Anything else `409 ILLEGAL_TRANSITION`.

Shipment JSON: `{ id, number, orderId, orderNumber, invoiceId, invoiceNumber, partyName, courier, awb, mode, codAmount, status, notes, dispatchedAt, deliveredAt, history [{ status, note, at, by }] (detail), lines [{ id, orderLineId, invoiceLineId, itemId, itemName, qty }] (detail), returnId (detail, when an RTO return exists) }`.

| Method and path | Permission | Body / query | Result |
| --- | --- | --- | --- |
| `GET /shipments` | view | `status`, `mode`, `q` (number, AWB, order, customer), `orderId`, paging | `{ data, total }` |
| `GET /shipments/:id` | view | | shipment with lines, history |
| `POST /shipments/:id/status` | fulfilment.manage | `{ status, note?, courier?, awb? }` | `rto_delivered` also creates the RTO sales return (type `rto`, status `requested`, one per shipment, quantities = shipped − already returned); `delivered` stamps `deliveredAt` |
| `PATCH /shipments/:id` | fulfilment.manage | `{ courier?, awb?, notes? }` | not after `delivered`, `rto_delivered` or `lost` |

### Sales returns

Types: `customer_return` (customer sends goods back) and `rto` (courier returns an undelivered parcel). Status: `requested` → `received` → `inspected` → `closed`; `cancelled` from `requested`, `received`, `inspected`.

Return JSON: `{ id, number, type, status, reason, locationId, locationName, invoiceId, invoiceNumber, orderId, orderNumber, shipmentId, partyId, partyName, creditNoteId, creditNoteNumber, receivedAt, inspectedAt, closedAt, createdAt, lines [{ id, lineNo, invoiceLineId, orderLineId, itemId, itemName, unit, qty, qtyReceived, disposition, note }] (detail) }`.

| Method and path | Permission | Body / query | Result |
| --- | --- | --- | --- |
| `GET /sales-returns` | view | `status`, `type`, `q`, `orderId`, `invoiceId`, paging | `{ data, total }` |
| `GET /sales-returns/:id` | view | | return with lines |
| `POST /sales-returns` | returns.manage | `{ orderId? \| invoiceId?, type? = 'customer_return', reason, lines: [{ orderLineId? \| invoiceLineId?, qty }] }`. Give `orderId` (lines by `orderLineId`) or `invoiceId` (lines by `invoiceLineId`) | `201`. `400 RETURN_EXCEEDS_SOLD` when qty is more than dispatched (or invoiced) − already returned (including returns still open); details `{ lineIndex, returnable }` |
| `POST /sales-returns/:id/receive` | returns.manage | `{ lines?: [{ lineId, qtyReceived }] }` (default: full qty) | `requested` → `received`; `qtyReceived` ≤ `qty` |
| `POST /sales-returns/:id/inspect` | returns.manage | `{ lines: [{ lineId, disposition: 'restock'\|'damaged'\|'scrap', note? }] }` | `received` → `inspected`; every line with `qtyReceived > 0` needs a disposition |
| `POST /sales-returns/:id/close` | returns.manage | none | `inspected` → `closed`; creates the credit note for the received quantities with the existing credit-note function and links it; stock rule below |
| `POST /sales-returns/:id/cancel` | returns.manage | `{ reason? }` | frees the quantities for another return |

Stock and accounting rule (one rule for both types): the credit note covers every received unit at the invoice price and tax, whatever its condition, and reverses revenue and output tax. Only units with disposition `restock` go back on the shelf, at the cost they left at (inventory debit, cost of goods sold credit). `damaged` and `scrap` units get the credit note but no stock move: they never re-enter the books, so their cost stays in cost of goods sold as the loss. Units claimed but not received are released and get no credit. An RTO parcel is returned the same way as a customer return; no cash was settled for an undelivered parcel, so the credit note offsets the receivable (COD: the courier never remitted cash). Closing is allowed with nothing received (no credit note is created).

### Errors added

| Status | `code` | When |
| --- | --- | --- |
| 409 | `ILLEGAL_TRANSITION` | Action not allowed in the current state of an order, pick list, shipment or return |
| 409 | `INSUFFICIENT_STOCK` | Confirming or reserving more than is available (with `shortages`) |
| 409 | `NOTHING_TO_PICK`, `NOTHING_TO_DISPATCH`, `PACK_INCOMPLETE`, `HAS_OPEN_PICK_LIST`, `HAS_PICKS`, `DUPLICATE_ORDER` | As described above |
| 400 | `UNKNOWN_BARCODE`, `WRONG_ITEM`, `OVER_PICK`, `OVER_PACK`, `RETURN_EXCEEDS_SOLD` | As described above |


## B. Procure to pay and stock counts

Migration `014_p2p.sql`. Code: `modules/purchase-orders.ts`, `modules/goods-receipts.ts`, `modules/stock-counts.ts`, `modules/reorder.ts`; bill linking in `modules/purchases.ts`; approval hook in `modules/approvals.ts`.

### B.0 Permissions, accounts, settings

| Permission | Meaning | Default roles |
| --- | --- | --- |
| `purchase_orders.view` | View POs, goods receipts, reorder suggestions, P2P settings | Owner, Company Admin, Accountant, Store Keeper, Project Manager, Auditor |
| `purchase_orders.manage` | Create, edit, submit, send, cancel POs; create POs from reorder suggestions; edit P2P settings | Owner, Company Admin, Accountant |
| `grn.manage` | Create and cancel goods receipts | Owner, Company Admin, Store Keeper |
| `purchases.override` | Post a bill whose price differs from the PO (`acceptVariance`) | Owner, Company Admin |
| `stock_counts.manage` | Open, scan, post and cancel stock counts | Owner, Company Admin, Store Keeper |
| `stock_counts.approve` | Post a count whose variance value exceeds the company threshold | Owner, Company Admin |

System accounts (added to every company): `2140 Goods Received Not Invoiced` (`grni`, liability) and `5110 Purchase Price Variance` (`purchase_price_variance`, expense). Document numbers: `PO/26-27/00001`, `GRN/...`, `CNT/...`. Stock-move kinds `grn`, `grn_cancel`, `stock_count` come from migration 012. Journals use voucher type `stock` (GRN, count) and `purchase` (bill).

Company settings (columns on `companies`), `GET/PUT /p2p/settings` (GET needs `purchase_orders.view`, PUT `purchase_orders.manage`):

```
{ receiptTolerancePct: 0, priceTolerancePct: 0, countApprovalValue: 10000 }
```

- `receiptTolerancePct` (0-100, default 0): extra quantity over the PO that a receipt may bring in.
- `priceTolerancePct` (0-100, default 0): allowed difference between bill price and PO price before a bill is blocked.
- `countApprovalValue` (rupees, default 10,000): a count whose absolute variance value is more than this needs `stock_counts.approve` to post.

### B.1 Accounting rule (read this first)

Goods are valued at the PO net rate (rate less discount, GST excluded). Direct bills (no `grnLineId`) are unchanged: tracked items move stock and debit Inventory on the bill.

1. **GRN** (accepted qty only; rejected goods never enter stock). Per tracked line: stock move `ref_type 'grn'`, qty = accepted, `value = round2(accepted x unitCost)`, `cost_rate = unitCost`. Journal (voucher `stock`, voucher id = GRN id, at the GRN location):
   `Dr Inventory  value` / `Cr Goods received not invoiced  value`. Non-stock items post nothing.
2. **Bill from GRN** (a bill line with `grnLineId`): no stock move, no inventory debit. For the line, `clearing` = `round2(qty x unitCost)`, or the whole remaining GRN value when the line bills the last unit (so GRNI nets to exactly zero). `variance = line taxable value - clearing`. Journal lines added to the normal bill journal: `Dr GRNI clearing` and `Dr/Cr Purchase price variance variance`, instead of the Inventory debit. GST, TDS, reverse charge, round-off and payables are posted exactly as for a direct bill. Non-stock GRN lines post to Purchases - non-stock as usual.
3. **GRN cancel**: stock move `grn_cancel` for the original value and a reversal of the GRN journal.
4. **Bill cancel** reverses the bill journal (including GRNI and variance lines) and releases the GRN line billed quantity and cleared value.

Result: stock quantity and Inventory value rise once (at GRN), the bill never touches them again, and `Goods received not invoiced` is the value of goods received but not yet billed. Weighted-average cost is not changed by price variance; variance goes to the expense account.

### B.2 Purchase orders

State machine:

```
draft --submit--> approved                    (no approval rule matches the PO total)
draft --submit--> pending_approval --approve--> approved   (rule matches; engine v1.7, docType purchase_order)
pending_approval --reject/cancel request--> draft
approved --send--> sent
approved|sent --receipt--> partially_received --receipt--> received
received --bills cover every received unit--> closed        (also closed when remaining qty is cancelled and all received is billed)
draft|pending_approval|approved|sent|partially_received --cancel--> cancelled (nothing received)
partially_received|received(not fully) --cancel--> remaining qty cancelled, status recomputed
```

- Edit (`PUT`) only in `draft` (409 `NOT_EDITABLE`).
- `received` counts accepted quantity. `rejected` is tracked separately; a rejected quantity can be received again (replacement) until the ordered quantity is accepted or cancelled.
- A rejected approval request (or one cancelled by the requester) returns the PO to `draft`.

PO JSON:

```
{ id, number, status, fy, orderDate, expectedDate, locationId, locationName, partyId, partyName, partyGstin,
  placeOfSupply, supplyType, subtotal, cgst, sgst, igst, taxTotal, roundOff, total, notes,
  approvalRequestId, submittedAt, approvedAt, sentAt, cancelledAt, cancelReason,
  createdAt, createdBy: { id, name },
  progress: { ordered, received, billed, cancelled },      // quantity sums
  lines: [{ id, lineNo, itemId, itemName, sku, description, hsnCode, qty, unit, rate, discountPct, gstRate,
            taxableValue, cgst, sgst, igst, lineTotal,
            receivedQty, rejectedQty, billedQty, cancelledQty, openQty }],   // openQty = qty - cancelledQty - receivedQty
  receipts: [{ id, number, receiptDate, status }],         // detail only
  bills: [{ id, number, billDate, total, status }] }       // detail only
```

`GET /purchase-orders?status=&q=&partyId=&locationId=&from=&to=&limit=&offset=` (`purchase_orders.view`; location-scoped) returns `{ data: [PO without lines/receipts/bills], total }`. `q` matches number, vendor name, notes.

`POST /purchase-orders` (`purchase_orders.manage`, 201) body:

```
{ locationId, partyId, orderDate?, expectedDate?, notes?, lines: [{ itemId, qty, rate?, discountPct?, description? }] }
```

`rate` defaults to the item's purchase price. Tax is computed as purchase bills compute it (supplier state vs delivery location state). Errors: 400 for a customer party, an inactive item or location, or `expectedDate` before `orderDate`.
`PUT /purchase-orders/:id` (also accepted as `PATCH`, which the Flutter client uses) same body, draft only. `POST /:id/submit` (no body): returns the PO (200). With a matching rule the PO is `pending_approval` and `approvalRequestId` is set; the request appears in `/approvals` with `docType: 'purchase_order'`; final approval moves the PO to `approved` (the requester must still hold `purchase_orders.manage`). `POST /:id/send` (approved or sent) sets `sent` and `sentAt`. `POST /:id/cancel { reason }` as above; 409 `FULLY_RECEIVED` when nothing is left to cancel; `ALREADY_CANCELLED`; 409 `INVALID_STATE` for other transitions.
`POST /purchase-orders/preview` takes the create body and returns the totals and taxed lines without saving (`id` and `number` are null).
All state changes lock the PO row and are audited (`purchase_order`).

### B.3 Goods receipts (GRN)

`POST /goods-receipts` (`grn.manage`, 201) body:

```
{ purchaseOrderId, locationId?, receiptDate?, challanNo?, challanDate?, vehicleNo?, notes?,
  lines: [{ poLineId, acceptedQty, rejectedQty?, rejectReason? }] }
```

- The PO must be `approved`, `sent` or `partially_received` (409 `PO_NOT_RECEIVABLE`). `locationId` defaults to the PO delivery location.
- `rejectedQty > 0` needs `rejectReason`; every line needs accepted + rejected > 0; a PO line can appear once.
- Over-receipt: if `receivedQty + acceptedQty > (qty - cancelledQty) x (1 + receiptTolerancePct/100)` the call fails with 400 `OVER_RECEIPT` and `details: { lines: [{ poLineId, itemName, allowed, receiving }] }`.
- Posts stock and the GRNI journal (B.1), raises PO `received_qty`/`rejected_qty`, recomputes the PO status. Number `GRN/FY/nnnnn`.
- Receipt date cannot be in the future.

`GET /goods-receipts?purchaseOrderId=&status=&q=&limit=&offset=` -> `{ data, total }`. `GET /goods-receipts/:id`:

```
{ id, number, status, fy, receiptDate, purchaseOrderId, purchaseOrderNumber, partyId, partyName, locationId, locationName,
  challanNo, challanDate, vehicleNo, notes, createdAt, createdBy, cancelledAt, cancelReason,
  lines: [{ id, lineNo, poLineId, itemId, itemName, sku, unit, receivedQty, acceptedQty, rejectedQty, rejectReason,
            poRate, discountPct, unitCost, gstRate, value, billedQty, billableQty }] }   // billableQty = acceptedQty - billedQty
```

`value` is the PO-rate value, which the viewer already sees on the PO, so it is always shown.

`POST /goods-receipts/:id/cancel { reason }`: 409 `ALREADY_CANCELLED`; 409 `HAS_BILLS` if any line is billed; 409 `INSUFFICIENT_STOCK` if the accepted quantity is no longer on hand at the location. Reverses stock (`grn_cancel`) and the GRN journal, lowers PO received qty, recomputes status.

### B.4 Bill from GRN (three-way match)

`POST /purchases` and `/purchases/preview` accept two additions; everything else is unchanged:

```
lines[].grnLineId?: uuid        // the goods receipt line being billed
acceptVariance?: boolean        // default false
```

Rules (only for lines with `grnLineId`):

- The GRN must be `posted`, belong to the bill's vendor (`partyId`) and location (400 otherwise); `itemId` must match the GRN line.
- Omitted `rate` / `discountPct` default to the PO line's. `qty` defaults are not applied (send it).
- `qty` more than `acceptedQty - billedQty` (counting the same GRN line twice in one bill) -> 400 `OVER_BILLED`, `details: { lines: [{ grnLineId, itemName, billable, billing }] }`.
- Net price (rate x (1 - discount)) differing from the PO net price by more than `priceTolerancePct` percent -> 409 `PRICE_VARIANCE`, `details: { lines: [{ index, grnLineId, itemName, poRate, billRate, variancePct, varianceValue }] }`. Pass `acceptVariance: true` to proceed: it needs `purchases.override`, else 403 `FORBIDDEN`. The bill stores `varianceAccepted: true` and the audit record notes it.
- The bill's `purchaseOrderId` is set (all GRN lines on one bill must belong to one PO, else 400). Billing raises PO line `billedQty`; a PO that is fully received and fully billed becomes `closed`.
- Journal: B.1. Direct lines may be mixed with GRN lines on one bill.
- Approval rules for `purchase` apply as before (202 `approvalRequest`).

Bill JSON gains `purchaseOrderId`, `varianceAccepted`, and per line `grnLineId`, `grniValue`, `varianceValue`.

### B.5 Reorder suggestions

`GET /reorder-suggestions?locationId=` (`purchase_orders.view`; location-scoped) -> `{ data: [...], total }`. Stock-tracked, active items with `reorderLevel > 0`. Without `locationId`, every location where the item has had stock moves is listed; with it, every such item at that location (including zero stock).

```
{ itemId, itemName, sku, unit, locationId, locationName, onHand, reserved, openPoQty, position, reorderLevel,
  suggestedQty, lastVendorId, lastVendorName, lastRate }
```

- `openPoQty` = unreceived, uncancelled quantity on `approved`, `sent` and `partially_received` POs delivering to that location.
- `reserved` = active sales reservations at the location when the table `stock_reservations` exists (v1.8 A), else 0.
- `position = onHand - reserved + openPoQty`. Listed when `position <= reorderLevel`.
- `suggestedQty = reorderLevel x 2 - position` (order up to twice the reorder level), at least 1 unit rounded up to the quantity precision.
- Last vendor = vendor of the most recent posted bill containing the item.

`POST /reorder-suggestions/purchase-orders` (`purchase_orders.manage`, 201):

```
{ selections: [{ itemId, locationId, qty, partyId? }] }      // partyId defaults to the last vendor, else 400
```

Creates draft POs grouped by vendor and location, at the item's purchase price (last bill rate when known). Returns `{ data: [PO] }`.

### B.6 Stock counts

`POST /stock-counts` (`stock_counts.manage`, 201) body `{ locationId, itemIds?: uuid[], notes? }`. Without `itemIds` the scope is `all`: every stock-tracked item with any stock move at the location. With them the scope is `selected`. The snapshot (`expectedQty` = on hand at that moment, `snapshotAt`) is stored per line. One open count per location (409 `COUNT_OPEN`).

`GET /stock-counts?status=&locationId=&limit=&offset=` -> `{ data: [{ id, number, status, locationId, locationName, scope, snapshotAt, lineCount, countedCount, varianceValue, createdAt }], total }`.

`GET /stock-counts/:id`:

```
{ id, number, status, scope, locationId, locationName, snapshotAt, notes, varianceValue, postedAt, postedBy, approvedBy,
  thresholdValue, createdBy, createdAt, needsApproval,
  summary: { lines, counted, uncounted, withVariance },
  lines: [{ itemId, itemName, sku, barcode, unit, expectedQty, movedSince, expectedNow, countedQty, varianceQty, varianceValue }] }
```

- `movedSince` = stock moves at the location after `snapshotAt`; `expectedNow = expectedQty + movedSince`; `varianceQty = countedQty - expectedNow` (null until counted). `varianceValue` = variance x average cost (only with `items.view_cost`, else absent).

`POST /stock-counts/:id/scans` (open counts only; 409 `NOT_OPEN`):

```
{ scanId?: string(<=64), code?: string, itemId?: uuid, qty?: number (default 1), mode?: 'add' | 'set' (default 'add') }
```

- Exactly one of `code` (barcode or SKU, case-insensitive exact) and `itemId`. Unknown code -> 400 `UNKNOWN_BARCODE`.
- `mode: add` adds `qty` to the counted quantity (scanner); `set` replaces it (manual entry, `qty >= 0`).
- An item that is not on the count: added with expected 0 for scope `all`; 400 `NOT_IN_COUNT` for scope `selected`.
- A `scanId` already used on this count changes nothing and returns the current line with `duplicate: true`.
- Response `{ duplicate, line: { ...line as above } }`.

`POST /stock-counts/:id/post { zeroUncounted?: boolean }` (`stock_counts.manage`): only counted lines are posted (uncounted lines are skipped unless `zeroUncounted`, which counts them as zero). For each line with variance: `stock_count` move at the location, gains at the current average cost (item purchase price when none), losses at the average cost. One journal (voucher `stock`): Dr/Cr Inventory net, Dr Stock shortage & wastage for losses, Cr Other income for gains, with each line's variance computed again under the item lock. If the sum of absolute variance values exceeds `countApprovalValue` and the user lacks `stock_counts.approve`: 403 `COUNT_APPROVAL_REQUIRED` with `details: { varianceValue, thresholdValue }`. Returns the count (status `posted`). A count with no variance posts with no moves. 409 `NOT_OPEN` otherwise.

`POST /stock-counts/:id/cancel { reason }`: open counts only. Audited: `stock_count` create, scan(not audited per scan), post, cancel.

### B.7 Errors added

`OVER_RECEIPT` 400, `OVER_BILLED` 400, `UNKNOWN_BARCODE` 400, `NOT_IN_COUNT` 400, `PRICE_VARIANCE` 409, `PO_NOT_RECEIVABLE` 409, `NOT_EDITABLE` 409, `INVALID_STATE` 409, `FULLY_RECEIVED` 409, `HAS_BILLS` 409, `COUNT_OPEN` 409, `NOT_OPEN` 409, `COUNT_APPROVAL_REQUIRED` 403. Cross-tenant ids return 404 as everywhere else.

### B.8 Client (Flutter)

`lib/features/purchase_orders/` (list, form, detail, receive goods, create bill, reorder suggestions) and `lib/features/stock_counts/` (list, count session, variance review). Routes and nav entries are exposed from `purchasing_routes.dart`. A PO's approval is acted on in the existing approvals screens.

### B.9 Demo data

`seedP2p`: approval rule for purchase orders of 2,00,000 or more (Owner); POs in five states (pending approval, sent, partially received, closed after a three-way-matched bill, draft from reorder); one posted stock count with a small variance.


# v1.8.2 additions

## Optimistic edit check (`STALE_EDIT`)

| Status | `code` | When |
| --- | --- | --- |
| 409 | `STALE_EDIT` | An edit sent `expectedUpdatedAt` and the record changed after that time. Message: "Someone else changed this <record> while you were editing. Reload to see the latest version." |

- Edit requests (`PATCH` or `PUT`) may carry `expectedUpdatedAt`: the `updatedAt` the client last read. If it is missing the edit is applied as before.
- Routes: `PATCH /parties/:id`, `/items/:id`, `/accounts/:id`, `/locations/:id`, `/sales-orders/:id`, `PUT|PATCH /purchase-orders/:id`, `/work-orders/:id`, `/ra-bills/:id`, `/projects/:id`, `/cost-centres/:id`, `/units/:id`, `/bookings/:id`, `/workers/:id`.
- Responses of those resources carry `updatedAt` (ISO time). Migration `019_updated_at.sql` adds `updated_at` to `parties`, `accounts` and `locations` and keeps it current with a trigger. Migration `020_updated_at_ops.sql` does the same for `work_orders`, `ra_bills`, `projects`, `cost_centres`, `units`, `bookings` and `workers`.
- Not covered: DPRs, indents, shipments, wage sheets, BOQ lines and payment plans (single-owner or status-driven edits).
- Client: the edit form sends the `updatedAt` it loaded. On `STALE_EDIT` it keeps the typed values, shows the message and offers "Reload", which refetches the record.
- Cancelled, posted or locked documents are refused on the server (`NOT_EDITABLE`, `ALREADY_CANCELLED`, `PERIOD_LOCKED`); the UI hides their edit actions.

## GSTIN check digit on edit

- Create requests always check the GSTIN check digit when it is enforced (production, or `ENFORCE_GSTIN_CHECKSUM=1`).
- `PATCH /parties/:id` and `PATCH /company` check it only when the GSTIN in the request differs from the saved one, so older records can still be edited. The demo seed uses valid check digits.

## Client duplicate-submit rules

- `ApiClient` sends one request for identical mutations (same method, path and body) that overlap in time.
- After a network failure, timeout or 5xx, the next identical `POST` reuses the `Idempotency-Key` of the failed one, so a retry cannot post twice.
- A form with unsaved edits asks "Discard changes?" before sidebar, `context.go` and browser-back navigation, not only before pop. A successful save in the last 5 seconds skips the prompt.

## GET /analytics/overview

Permission `reports.view`. Query: `from`, `to` (`YYYY-MM-DD`; default financial-year start to today; at most 3 years). The previous period is the equal-length window ending the day before `from`.

Response: `{ from, to, previousFrom, previousTo, kpis: { current, previous }, trend, cashFlow?, topCustomers, topItems, salesByLocation, expensesByCategory, ageing }`.

- `kpis.*`: `sales` (invoices less credit notes, ex-tax), `purchases`, `expenses` always. `collections`, `payments`, `receivables`, `payables`, `cashAndBank` need `accounts.view` or `payments.view`. `grossProfit`, `netProfit` need `accounts.view`. `stockValue` needs `items.view_cost`. Hidden fields are omitted.
- `trend`: `[{ month: 'YYYY-MM', sales, purchases, expenses }]`. `cashFlow` (same permission as collections): `[{ month, cashIn, cashOut }]`.
- `topCustomers`: `[{ partyId, name, amount, invoices, share }]` (share in percent). `topItems`: `[{ itemId, name, unit, qty, amount }]`. `salesByLocation`: `[{ locationId, name, amount }]`. `expensesByCategory`: `[{ accountId, category, amount }]`.
- `ageing.receivables` and `ageing.payables`: `{ notDue, d1_30, d31_60, d61_90, d90plus, total }` as of `to`.
- Document figures respect the user's location scope.

## Business types, modules and plans (track D)

**Security note.** Modules only shape the menu. A disabled module vanishes from the navigation and its routes redirect home, but nothing is blocked on the server. Permissions (role based, checked by `ctx.require`) remain the only access control. Never rely on a module being off to protect data.

### GET /business-types (public, no auth)
Returns `{ groups, types, modules, plans, termDefaults, countries, permissionCount }`.
- `types[]`: `{ id, name, group, description, icon, modules[], roles[{ name, description, permissions[] }], terms{}, quickActions[{ label, route, permission }] }`. About 50 types in 15 groups (retail, food, healthcare, professional, construction, manufacturing, education, hospitality, logistics, agriculture, services, non-profit, public sector, companies, plus `general`).
- Role templates use real job titles and only existing permission keys. The catalogue is validated at server start; an unknown permission, module, term or group stops the server.
- Add a module or permission in one place: `backend/src/lib/business-types.ts` (and `lib/core/business_profile.dart` for the client list).

### Signup
`POST /auth/signup` additionally accepts `businessType` (default `general`), `plan` (default `business`), `country` (ISO code or `XX`, default `IN`). `stateCode` is optional. A non-IN country always stores state code `97` and no GSTIN. The company starts with the type's modules (explicit `enabledModules`), its words (`terms`) and its role templates.

### POST /company/business-profile (`company.manage`)
Body (all optional): `businessType`, `plan`, `country`, `currency`, `enabledModules` (array or null), `terms` (map of word key to singular word, 30 characters).
- A changed `businessType` applies that type's module defaults and words (`terms = type terms + body.terms`), then creates any missing role templates (`is_system = false`, existing names untouched).
- It never deletes or edits roles and never removes a user's role.
- `country` or `currency` cannot change once an invoice or purchase bill exists: `409 CONFLICT` with `details: { country: 'Locked' }` or `{ currency: 'Locked' }`.
- Outside IN, `gst`, `tds`, `income_tax` and `einvoice` are switched off.
- Audited as `business_profile`. Returns `{ company, rolesCreated }`.
- `GET /company` returns `businessType`, `plan`, `enabledModules` (`null` = every module; older companies), `terms`, `country`, `currency`, `logoFileId`, `brandColor`.

### Plans (a default the owner may change)
`PLANS` in `backend/src/lib/business-types.ts`: `solo` 1 user and a simplified menu (limited module set); `team` 10 users; `business` 50 users; `enterprise` unlimited users with single sign-on, approvals and multiple companies (informational, not enforced). A plan is only a setting; there is no billing.

The user limit is enforced when a user is created or reactivated: `409 USER_LIMIT` with a plain message, for example "The Team plan allows 10 users. Change the plan under Settings, Business profile to add more." It counts active users with a role in the company. SSO auto-provisioning checks the same limit and redirects with `ssoError=SSO_USER_LIMIT` instead of creating the user. Only `solo` limits modules and only the user limit is enforced for every plan; the other plan features (single sign-on, approvals, multiple companies) are descriptions, not checks.

Outside India (`country` not `IN`) the GST rate master does not apply: items, invoices, bills, purchase orders and expenses accept any tax rate from 0 to 100 in `gstRate`. The tax is still computed as one rate (split as CGST and SGST against the company's state `97`); there is no separate VAT engine, return or reverse charge.

# Wave 2: Clinic and hospital OPD (module `clinic`)

Module key `clinic`, on by default for `clinic`, `hospital` and `diagnostic_lab`. In-patient care (IPD) is described at the end of this section.
Permissions: `clinic.view` (read lists), `clinic.front_desk` (patients, appointments, tokens), `clinic.consult` (clinical notes, vitals, prescriptions), `clinic.manage` (doctors, fees). Billing needs `invoices.create`, and `payments.create` to take money.

Clinical data (vitals, complaints, findings, diagnosis, advice, tests, prescription lines, patient `notes`) is returned only to users with `clinic.consult` and is never in list endpoints or audit entries (audit holds field names only).

**Patients**
- `GET /clinic/patients?q=&limit=&offset=` search name, phone or UHID. No notes.
- `POST /clinic/patients` (front_desk). Body: `name, sex(male|female|other), dob?|ageYears?, phone, address?, bloodGroup?, allergies?, emergencyName?, emergencyPhone?, notes?, force?`. Creates a customer party and a UHID (`UHID/26-27/00001`). Same phone and same name (case-insensitive) answers `409 DUPLICATE_PATIENT` with `details.matches`; send `force: true` to register anyway. 201 with the patient.
- `GET /clinic/patients/:id`, `PATCH /clinic/patients/:id` (front_desk, `expectedUpdatedAt`). `notes` shown and settable only with `clinic.consult`.
- `GET /clinic/patients/:id/history` visits with doctor, bill and payment status; diagnosis and Rx count only with `clinic.consult`.

**Doctors**: `GET /clinic/doctors`, `POST /clinic/doctors`, `PATCH /clinic/doctors/:id` (manage). Body: `name, userId?, speciality?, registrationNo?, consultFee, followUpFee, followUpDays, slotMinutes, workingHours:[{day 0-6 (0=Sunday), from:"HH:MM", to}], isActive`. `GET /clinic/doctors/:id/slots?date=` lists slots with `free`.

**Appointments** (the queue is the list for a date)
- `GET /clinic/appointments?date=&doctorId=&patientId=&status=` sorted by status, token, time. No clinical data.
- `POST /clinic/appointments` (front_desk). Booked: `patientId, doctorId, date, startTime, reason?`. Walk-in: `patientId, doctorId, walkIn: true, reason?` (today, status `arrived`, token number per doctor per day). `409 SLOT_TAKEN` on a taken slot; `400` outside working hours or off the slot grid or in the past.
- `POST /clinic/appointments/:id/status` `{status: arrived|cancelled|no_show, reason?}` (front_desk). Flow: booked to arrived, cancelled or no_show; arrived to cancelled. Arrival gives a token. `in_consultation` and `done` are set by starting and completing a visit.
- `POST /clinic/appointments/:id/reschedule` `{date, startTime, doctorId?}` for a booked appointment.

**Consultations** (all need `clinic.consult` except billing)
- `POST /clinic/visits` `{appointmentId}` or `{patientId, doctorId}` (creates a walk-in). Moves the appointment to in_consultation. Repeating returns the same visit.
- `GET /clinic/visits/:id` full visit with `rx` lines; front desk gets the non-clinical header only (`clinical: false`).
- `PATCH /clinic/visits/:id` `{vitals:{bpSys,bpDia,pulse,tempC,spo2,weightKg,heightCm}, complaints, findings, diagnosis, testsAdvised, advice, followupDate, rx:[{itemId?, medicine, dose, frequency, days, instructions}], expectedUpdatedAt}`.
- `POST /clinic/visits/:id/complete` closes the visit and marks the appointment done.
- `GET /clinic/visits/:id/prescription` data for the A5 prescription (clinic header, doctor and registration number, patient, Rx, advice, follow-up).
- `POST /clinic/visits/:id/bill` (`invoices.create` and front_desk or consult) `{locationId?, includeConsultation?, lines:[{itemId, qty, rate?, discountPct?, description?}], payment?:{accountId, mode, amount, reference?}}`. Adds the consultation fee, or the follow-up fee when the patient had a paid consultation with the same doctor within `followUpDays`. Uses each item's own tax rate. Returns `{invoice, payment, feeKind}`. `409 ALREADY_BILLED` unless the earlier invoice was cancelled. `payment` needs `payments.create`.

**In-patient care (IPD)** (migration 039). Permissions: `clinic.ipd` (see the bed board and stays, add and post charges) and `clinic.ipd_manage` (set up wards and beds, admit, transfer, deposits, void charges, discharge and bill). Granted to Owner, Company Admin, and by role template to hospital and clinic staff (Front Desk and Billing get both; Doctor and Nurse get `clinic.ipd`). Deposits and the final bill need `payments.create` and `invoices.create`. Diagnosis, treatment, advice and the provisional diagnosis are clinical: returned and written only with `clinic.consult`, never in audit entries. Admission numbers use the `IPD` series (`IPD/26-27/00001`). Settings routes (wards, beds, summary) answer to both PATCH and PUT.
- `GET /clinic/ipd/wards` wards with beds. `POST /clinic/ipd/wards` `{name, kind: general|semi_private|private|icu|nicu|other, sortOrder?, isActive?}` (409 `DUPLICATE_WARD`). `PATCH|PUT /clinic/ipd/wards/:id` (409 `WARD_IN_USE` when switching off a ward with admitted patients).
- `POST /clinic/ipd/beds` `{wardId, bedNo, dailyRate, isActive?}` (409 `DUPLICATE_BED`). `PATCH|PUT /clinic/ipd/beds/:id` `{bedNo, dailyRate, wardId, status: available|cleaning|maintenance, isActive}`; 409 `BED_OCCUPIED` while a patient is in it. The status `occupied` is set only by admission and transfer; a vacated bed goes to `cleaning` until someone sets it `available`.
- `GET /clinic/ipd/board` `{counts:{total, available, occupied, cleaning, maintenance}, admitted, wards:[{id, name, kind, beds:[{id, bedNo, dailyRate, status, admission: null | {id, number, patientName, uhid, doctorName, admitDate, days}}]}]}`.
- `GET /clinic/ipd/admissions?status=admitted|discharged&q&wardId&doctorId&limit&offset` `{total, data:[{id, number, status, admitDate, dischargeDate, days, expectedDays, patient, doctor, bed, invoiceId}]}`.
- `POST /clinic/ipd/admissions` `{patientId, doctorId, bedId, expectedDays?, provisionalDiagnosis?, deposit?:{accountId, mode, amount, reference?}}` 201 with the detail. The patient and doctor are the OPD records. 409 `ALREADY_ADMITTED`, 409 `BED_TAKEN`. The first day's bed charge is posted at once.
- `GET /clinic/ipd/admissions/:id` header plus `stays[]` (bed, from, to, rate), `charges[]` (`date, kind: bed|service|medicine, description, qty, rate, amount, isVoid`), `deposits[]`, `totals {bed, service, medicine, total, deposits, balance}` (before tax), `invoice` after discharge, and with `clinic.consult` `provisionalDiagnosis` and `summary {diagnosis, treatment, advice, condition, followupDate}`.
- `POST .../transfer` `{bedId, reason?}`: closes the current stay and opens one in the new bed at the new bed's rate. Nights before the move day stay on the old bed; the move day is charged to the new bed. The old bed becomes `cleaning`.
- `POST .../deposits` `{accountId, mode, amount, reference?}` a receipt through the payments service, left unallocated until discharge.
- `POST .../charges` `{kind: service|medicine, itemId?, description?, qty, rate?, chargeDate?}`. With `itemId` the description and rate default to the item's, and the invoice line keeps the item's own GST rate. Without it the line is a "Hospital services" line at 0% GST. `POST .../charges/:chargeId/void` `{reason}` removes a service or medicine charge (bed charges follow the stays and cannot be voided).
- `POST .../bed-charges` posts every missing bed night up to today (repeating adds nothing). `POST /clinic/ipd/bed-charges/run` does it for every admitted patient (the daily button on the board).
- `PATCH|PUT .../summary` (`clinic.consult`) `{diagnosis, treatment, advice, condition, followupDate, expectedUpdatedAt}`.
- `POST .../discharge` `{diagnosis?, treatment?, advice?, condition?, followupDate?, locationId?, payment?:{accountId, mode, amount, reference?}, allowCredit?}`. Needs diagnosis and treatment (saved earlier or sent here; summary fields need `clinic.consult`), else 400. In one transaction: closes the stay, posts the remaining bed nights (at least one day), frees the bed to `cleaning`, creates the invoice through `createInvoice` (bed nights grouped per stay at 0% GST like the OPD consultation; services at 0%; items at their own rate), applies the deposits to it, takes `payment` if given, and sets the admission `discharged`. Returns `{admission, invoice:{id, number, total}, depositsApplied, balanceDue, refundDue}`. 409 `BALANCE_DUE` when money is still owed and neither `payment` nor `allowCredit` covers it. 409 `NOT_ADMITTED` on a second call. `refundDue` is deposit left over; use the refund endpoint to pay it back.
- `POST .../refund` `{accountId, mode, amount, reference?}` (`clinic.ipd_manage`, `payments.create`) pays back deposit left after the final bill, through the payments service as a customer refund (migration 043). 409 `NOT_DISCHARGED` before discharge; 400 when `amount` is more than `refundDue`. The detail reply carries `refundDue` (deposits less what the bill used less earlier refunds).
- `GET .../discharge-summary` (`clinic.consult`) `{hospital, doctor, patient, admission, provisionalDiagnosis, summary, medicines[]}` for the PDF.

# Wave 2: Restaurant

Module key `restaurant`. Permissions: `restaurant.orders` (take orders, send KOT, print bill, move, merge), `restaurant.kitchen` (kitchen display), `restaurant.settle` (settle bills), `restaurant.manage` (menu, floor, settings, cancel sent lines, discounts, reopen). Reads need any of the four. All paths are under `/api/v1`. Errors use the usual `{error:{code, message, details}}` body.

## Setup
- `GET /restaurant/settings` -> `{serviceChargePct, serviceChargeGst, locationId, stations[]}`. `PATCH` (manage) takes the same fields (`stations` is read-only).
- `GET|POST /restaurant/categories`, `PATCH|DELETE /restaurant/categories/:id` (manage). Body `{name, sortOrder?, isActive?}`. 409 on a duplicate name.
- `GET /restaurant/menu?q&categoryId&station&available=true|false` -> `{data:[{itemId, name, shortName, price, gstRate, unit, categoryId, categoryName, diet, available, availableToday, station}], total}`. `available` is false when the item is switched off today or inactive.
- `POST /restaurant/menu` (manage) body `{itemId | newItem:{name, salePrice, gstRate=5, hsnCode?, unit='PLATE'}, categoryId?, diet: veg|non_veg|egg, available?, station='Main', shortName?}`. `newItem` creates a non-stock item. 409 if the item is already on the menu.
- `PATCH /restaurant/menu/:itemId` same optional fields plus `expectedUpdatedAt` (409 `STALE_EDIT`). Captains and kitchen may send `available` alone. `DELETE` removes the menu entry, not the item.
- `GET /restaurant/floor` -> `{areas:[{id, name, sortOrder, isActive, tables:[{id, name, seats, areaId, status: free|occupied|bill_printed, order: null | {id, number, covers, captainName, openedAt, amount, unsentLines, readyLines}}]}]}`. Status comes from the table's open order.
- `POST /restaurant/areas`, `PATCH|DELETE /restaurant/areas/:id` (409 `HAS_TABLES`). `POST /restaurant/tables`, `PATCH|DELETE /restaurant/tables/:id`. A table with an open order cannot be deactivated or deleted (409 `TABLE_BUSY`); a table with history is deactivated instead of deleted.

## Orders
- `POST /restaurant/orders` `{kind: dine_in|takeaway|delivery, tableId (dine-in), covers?, captainId?, customerPartyId?, customerName?, customerPhone? (required for delivery), deliveryAddress?, notes?, locationId?, lines?:[{itemId, qty, note?}]}` -> 201 order. 409 `TABLE_BUSY` (details `orderId`) if the table has an open order. Number is `Oyymmdd-nnn`, counted per day.
- `POST /restaurant/orders/:id/settle` also takes `{chargeToRoom: {roomNumber | reservationId}}` instead of `payments`: the bill's taxable value (after discount, with service charge) is posted once to the checked-in guest's hotel folio through `postFolioCharge` (source `restaurant`, ref = order id; 409 `NO_OPEN_FOLIO` if nobody is in that room) and the hotel invoice taxes it at check-out. No restaurant invoice is made; the reply has `invoice: null` and `folio {reservationId, lineId, amount}`.
- `GET /restaurant/orders?kind&status=active|open,settled&date&q&limit&offset` -> `{data:[{id, number, kind, status, tableName, customerName, customerPhone, itemCount, amount, readyLines, unsentLines}], total}`.
- `GET /restaurant/orders/:id` -> order with `lines[]` (state draft|sent|cancelled, kitchenStatus new|preparing|ready|served, kotNo, note), `kots[]` and `bill`.
- `PATCH /restaurant/orders/:id` `{covers, captainId, customerName, customerPhone, deliveryAddress, notes, expectedUpdatedAt}`.
- `POST /restaurant/orders/:id/lines` `{items:[{itemId, qty, note?}]}` adds unsent lines at the item's current price. 409 `ITEM_UNAVAILABLE` when switched off. `PATCH .../lines/:lineId` `{qty, note}` for unsent lines only (409 `LINE_SENT`).
- `POST .../lines/:lineId/cancel` `{reason}`. Unsent lines are removed. Sent lines need `restaurant.manage` and a reason (403 / 400) and are kept as cancelled with an audit entry.
- `POST .../send-kot` -> `{newKotIds[], order}`. One ticket per station for the unsent lines, all sharing one KOT number for the day. Calling again with nothing new returns `newKotIds: []`.
- `POST .../move` `{tableId}` (409 `TABLE_BUSY`). `POST .../merge` `{fromOrderId}` moves the other order's lines and tickets here and cancels it ("Merged into ...").
- `POST .../print-bill` `{discountPct? | discountAmount?, discountReason?, waiveServiceCharge?}` (percent or amount, not both; an amount is stored as a percent of the food total to 2 decimals) sets status `bill_printed` and freezes lines (409 `BILL_PRINTED` on edits). Discount or waiver needs `restaurant.manage`; a discount needs a reason. Service charge percent is copied from settings. `POST .../reopen` (manage) returns it to `open`.
- `POST .../cancel` `{reason}` cancels the order; a manager is needed once anything is sent.
- `POST .../settle` `{payments:[{mode: cash|upi|card, amount, reference?}], partyId?}` (settle). In one transaction: creates the tax invoice (each item's own GST rate; discount on every line; service charge as a separate line) with `createInvoice`, one receipt per payment with `createPayment`, and sets the order `settled`. Payments must add up to the bill total (400 otherwise). 409 `UNSENT_LINES` if lines were not sent. Guest is the party "Walk-in guest" unless `partyId` or the order's customer is set. Returns `{order, invoice:{id, number, total}, receipts[]}`.
- `bill` = `{lines, gross, discountPct, discount, serviceChargePct, serviceCharge, taxable, cgst, sgst, igst, taxTotal, roundOff, total, gstSummary:[{rate, taxable, cgst, sgst, igst}]}`. Lines with the same item and rate are grouped.

## Kitchen
- `GET /restaurant/kots?station&status=new,preparing,ready&orderId&limit` (default: new, preparing, ready on active orders) -> `{data:[{id, kotNo, station, status, createdAt, orderNumber, kind, tableName, areaName, covers, captainName, lines:[{id, name, qty, note, state, kitchenStatus}]}]}`. `GET /restaurant/kots/:id` one ticket.
- `PATCH /restaurant/kots/:id/status` `{status: new|preparing|ready|served}` moves every live line forward; 409 `STATUS_BACKWARD` going back. `PATCH /restaurant/kot-lines/:id/status` does one line. Kitchen or manage may set any status; a captain may set `served`.

# Wave 2: Counter billing (POS)

Module key `pos`. Permissions: `pos.use` (sell, hold, open and close own session, return goods) and `pos.manage` (see and close any session, reports of all sessions). Sales also need no other permission; the service posts the invoice and receipts itself. Money is rupees with 2 decimals. Errors use the usual `{error:{code,message,details}}` shape.

## Sessions (shifts)
- `GET /pos/sessions/current?locationId=` `{session|null, openCount}` the caller's open session.
- `POST /pos/sessions` `{locationId, openingFloat?, notes?}` 201. One open session per user and location: `409 SESSION_OPEN` with `details.sessionId`.
- `GET /pos/sessions?status&locationId&from&to&mine&limit&offset` own sessions; `pos.manage` sees all.
- `GET /pos/sessions/:id` and `/report` the X report while open, the Z report once closed: `{kind:'X'|'Z', session, sales:{count,total,taxTotal,discountTotal,itemsSold,creditGiven}, payments:{cash,upi,card,other}, refunds:{...}, returns:{count,total}, cashIn, cashOut, expected:{cash,upi,card,other}, counted, difference, cashMoves[]}`. Expected cash = opening float + cash received (net of change) - cash refunded + cash in - cash out. Other modes: received - refunded.
- `POST /pos/sessions/:id/cash-moves` `{kind:'in'|'out', amount, reason}` 201. Cash out above the cash in the drawer: `409 INSUFFICIENT_CASH`. Cash moves are session records only; they post no journal.
- `POST /pos/sessions/:id/close` `{counted:{cash, upi?, card?, other?}, notes?}` returns the Z report. `difference` = counted - expected for each counted mode. Closed again: `409 SESSION_CLOSED`.
- Someone else's session without `pos.manage`: 403.

## Items
- `GET /pos/items?q=&locationId=&limit=` `{exact, data:[{id,name,sku,barcode,unit,price,gstRate,hsnCode,trackStock,stock}]}`. An exact barcode or SKU match comes back alone with `exact:true`; otherwise a name/SKU/barcode contains search, names starting with the text first. `stock` is on hand minus reserved at the location (null when stock is not tracked). The location is the one asked for or the caller's open session's.
- `GET /pos/items/frequent?locationId=` top sellers of the last 60 days at the location, filled up with items by name.

## Sales
- `POST /pos/sales` 201 `{sessionId | locationId, partyId?, lines:[{itemId, qty, rate?, discountPct?}], billDiscount?:{type:'pct'|'amount', value}, payments:[{mode:'cash'|'upi'|'card'|'other', amount, reference?}], allowCredit?, notes?}`.
  - Creates a normal posted invoice (GST, stock, ledger, numbering as `POST /invoices`) and one receipt per payment mode, in one transaction. No partyId: the shared "Walk-in Customer" (created once per company). The bill discount is spread over the lines as extra line discount.
  - `cash` amount is what the customer handed over. Applied cash = min(cash, total - non-cash); the rest is `changeDue`. Receipts record cash net of change. UPI/card/other above the total: 400.
  - Short payment: 400, unless `partyId` names a customer and `allowCredit` is true; then the balance stays due on the invoice (`creditAmount`).
  - No open session: `409 NO_SESSION`; closed session: `409 SESSION_CLOSED`; stock: `409 INSUFFICIENT_STOCK`.
  - Response (also `GET /pos/sales/:id`): `{id, sessionId, invoiceId, number, date, createdAt, locationName, cashier, company:{name,legalName,gstin,address,phone,pincode,footer,upiId}, customer:{id,name,gstin,phone,isWalkIn}, lines:[{invoiceLineId,itemId,description,hsnCode,qty,unit,rate,discountPct,gstRate,taxableValue,lineTotal,returnedQty}], taxSummary:[{rate,taxable,cgst,sgst,igst}], subtotal, cgst, sgst, igst, taxTotal, roundOff, discountTotal, billDiscount, total, payments:[{mode,amount,reference}], tenderedCash, changeDue, creditAmount, status, returns[]}`.
- `GET /pos/sales?sessionId&locationId&from&to&q&limit&offset` `{data:[{id,sessionId,number,status,total,creditAmount,customerName,createdAt}], total}`; `q` matches bill number or customer.
- `POST /pos/sales/:id/return` 201 `{sessionId?, lines:[{invoiceLineId, qty}], reason, refundMode?='cash'}` creates a credit note (goods restocked) through the credit note service. The refund is the credit note total less anything applied to an unpaid balance; it is posted as a journal (receivable against cash or bank) and counted in the caller's open session at the same location. Response is the sale plus `returned:{creditNoteId,creditNoteNumber,total,refundAmount,refundMode}`. Over-returning: 400.

## Held bills
- `POST /pos/held` 201 `{sessionId | locationId, label?, payload:{...}, total?}` payload is any JSON object up to 60 KB; the client decides its shape.
- `GET /pos/held?locationId=` `{data:[{id,locationId,label,total,createdAt,createdBy,payload}]}` every held bill at the location, so another counter can pick it up.
- `POST /pos/held/:id/resume` returns the held bill and deletes it (a second resume: 404). `DELETE /pos/held/:id` 204.

# Platform super admin

The product owner can see and manage every account (tenant). Inside a tenant, organisation roles are unchanged.
Migration `021_platform_admin.sql`. All routes are under `/platform`, need a signed-in user, and return
`403 NOT_PLATFORM_ADMIN` for everyone else.

- **Granting admins is CLI-only:** `npm run platform:admin -- grant|revoke <email>` and `-- list` (uses `DATABASE_ADMIN_URL`).
  There is no screen or endpoint to grant or revoke. The dev seed creates `superadmin@demo.in` / `Demo@1234` in a tenant "Progen Platform" with no company.
- **There is no "sign in as" yet.** Admins see and change settings and users; they do not open a tenant's data.
- `GET /me` adds `isPlatformAdmin`. An admin may have no company: `companies` is `[]` and company routes return 403.
- Tables `platform_admins` and `platform_audit` have RLS with no policy for the app role. Cross-tenant reads go through `platform_*` security definer functions that re-check the admin. Work inside one tenant uses that tenant's row-level security.

| Route | Purpose |
|---|---|
| `GET /platform/overview` | `tenants, activeTenants, suspendedTenants, users, companies, usersSignedInLast30Days, byBusinessType[], byPlan[], byCountry[]` (`{key,count}`), `signupsByMonth[]` (12 months, `{month:'YYYY-MM',count}`) |
| `GET /platform/tenants?q&status&plan&businessType&limit&offset` | `{data,total}`; row: `id, name, status, createdAt, suspendedAt, suspendedReason, companyCount, userCount, activeUsers, businessType, plan, country, ownerName, ownerEmail, lastSignInAt, hasPlatformAdmin`. `q` matches name, owner name or owner email. Plan, type and country are those of the first company. |
| `GET /platform/tenants/:id` | `{tenant, companies[], users[]}`. Company: `id, name, businessType, plan, country, currency, enabledModules, createdAt, counts{invoices,parties,items}`. User: `id, name, email, isActive, isLocked, lockedUntil, twoFactor, lastSignInAt, isPlatformAdmin, roles[{companyId,role}]`. |
| `PATCH /platform/tenants/:id` | `{status:'active'|'suspended', reason?, name?}`. Suspending needs `reason` (3 to 500 chars). Returns the tenant row. |
| `PATCH /platform/companies/:id` | `{plan?, businessType?}`. Modules are re-clamped to the plan; a new type resets modules to its defaults and adds its role templates. `409 USER_LIMIT` when the new plan allows fewer users than are active. |
| `POST /platform/users/:id/deactivate` `/activate` `/unlock` `/sign-out` | 204. Deactivate and sign-out revoke all refresh tokens. |
| `POST /platform/users/:id/reset-link` | `{link, expiresAt}`. A one-use token valid 2 hours, same table as `/auth/password/forgot`; no email is sent. |
| `GET /platform/audit?limit&before&tenantId` | `{data[], next}`; row: `id, adminName, action, tenantId, tenantName, targetType, targetId, detail, createdAt`. Reset tokens are never stored. |

Errors: `409 PLATFORM_ADMIN_PROTECTED` when suspending a tenant that contains a platform admin, or deactivating or creating a reset link for a platform admin. `404` for unknown ids.

**Suspension:** a suspended tenant gets `403 ACCOUNT_SUSPENDED` ("This account is suspended. Contact support.") from login (after the password is verified), MFA, SSO redeem, refresh, and from every secured route for existing access tokens. SSO callback redirects with `ssoError=ACCOUNT_SUSPENDED`. Reactivating restores access.
`lastSignInAt` is the newest session token of the user or tenant (sign-in or refresh).

# Wave 2: Legal practice (module `legal`)

Permissions: `legal.view` (diary and your matters), `legal.work` (hearings, tasks, time and expenses on your matters), `legal.manage` (all matters, rates, bills, receipts). Billing also needs `invoices.create`; receipts need `payments.create`. A matter is visible to its responsible advocate, its team and anyone with `legal.manage`; any other id returns `404`. Matter numbers come from the `MAT` series (`MAT/26-27/00001`).

| Method and path | Purpose |
|---|---|
| `GET /legal/home` | `{today, tomorrow, hearings, pendingOutcome, deadlines, withoutNextDate}`. Hearings are today and tomorrow. Deadlines are open tasks due within 14 days or overdue (`overdue: true`). `pendingOutcome` is past hearings with no outcome. `withoutNextDate` is open matters with no scheduled hearing from today on. |
| `GET /legal/staff` | People of this business, for pickers. |
| `GET /legal/matters?status&advocateId&clientId&court&q` | Paged list with `nextHearingDate` and `team`. |
| `POST /legal/matters` | `title, clientId` (not a vendor) and optional `opposingParty, court, caseType, caseNo, caseYear, filingDate, stage, advocateId, teamIds, feeType (fixed_stage, per_hearing, hourly, retainer), agreedFee, hourlyRate, notes`. Without `legal.manage` the caller becomes the advocate. 400 if `agreedFee` is set on an hourly matter. |
| `GET /legal/matters/:id` | Matter plus `hearings` and `summary {unbilled {time, fee, disbursement, nonBillable}, openTasks, billedTotal, billedPaid, advanceReceived}`. |
| `PATCH /legal/matters/:id` | Any create field plus `status` (open, disposed, closed) and `expectedUpdatedAt` (409 `STALE_EDIT`). Only the advocate or a manager changes client, team or fees; only a manager reassigns. |
| `GET /legal/cause-list?from&to&advocateId` | Scheduled hearings of open matters, default today and tomorrow, at most 62 days. |
| `GET, POST /legal/matters/:id/hearings` | `hearingDate, court (defaults to the matter court), purpose`. |
| `PATCH /legal/hearings/:id` | Reschedule a hearing that has no outcome. 409 `ALREADY_RECORDED` after an outcome. |
| `POST /legal/hearings/:id/outcome` | `outcome, nextDate?, nextPurpose?, nextCourt?, stage?`. Marks the hearing held and creates the next hearing when `nextDate` is given (not before this hearing). On a `per_hearing` matter with an agreed fee it adds an unbilled fee entry. Returns `{hearing, next, feeEntryId, warning}`; `warning` is set when no next date was given. Second call: 409 `ALREADY_RECORDED`. |
| `GET /legal/tasks?matterId&assigneeId&status&overdue=true` | Tasks across visible matters. |
| `POST /legal/matters/:id/tasks`, `PATCH /legal/tasks/:id` | `title, kind (limitation, filing, other), dueDate, assigneeId, notes`; patch also `status` open or done. |
| `GET /legal/entries?matterId&userId&billed&from&to` | Time, fee and disbursement entries. |
| `POST /legal/matters/:id/entries` | `kind: time` with `minutes` (1 to 1440), optional `rate`; rate falls back to the person's rate card, then the matter rate. `kind: fee` with `amount`. `kind: disbursement` with `disbType` (court_fee, stamp_duty, clerkage, other) and `amount`. All take `description`, `entryDate`, `billable`, `hearingId`; managers may set `userId`. |
| `PATCH, DELETE /legal/entries/:id` | Own entries, or any with `legal.manage`. 409 `ALREADY_BILLED` once billed. |
| `GET /legal/rates`, `PUT` or `PATCH /legal/rates/:userId` | Hourly rate card (`legal.manage`). Body `{hourlyRate}`. |
| `POST /legal/matters/:id/bill` | `entryIds, invoiceDate?, locationId?, reverseCharge?, notes?`. Creates a posted invoice through the invoice service: time and fee entries become lines on "Legal professional fees" (18% GST); disbursements become lines on "Reimbursement of expenses paid on behalf of client" (0% GST). Entries are marked billed. 409 `ALREADY_BILLED` for a billed entry (concurrent bills of one entry: one wins). 400 for non-billable entries. |
| `GET /legal/matters/:id/bills` | `{bills, receipts}` for the matter. |
| `POST /legal/matters/:id/receipts` | `kind: fee` with `invoiceId` allocates to that bill; `kind: advance` is received unallocated and stays as client credit. Also `amount, accountId, mode, reference, date, tdsAmount`. |
| `GET, POST /legal/matters/:id/documents`, `DELETE /legal/documents/:id` | Attach files uploaded with `POST /files`: `{fileId, label}`. |

**Reverse charge.** With `reverseCharge: true` the fee lines use a 0% item ("Legal professional fees (reverse charge)") and the invoice note states that GST is payable by the recipient. The client must have a GSTIN (400 otherwise). Known gap: the invoice service has no reverse-charge flag, so the bill is not marked in GST returns and the client side RCM entry is not automated.

## Wave 2 POS addendum: tax-inclusive prices and held bills on close
- `GET /pos/settings` `{pricesIncludeTax}`; `PUT /pos/settings` `{pricesIncludeTax: boolean|null}` (`pos.manage` or `company.manage`). null = default: on for business types with the `pos` module.
- With inclusive prices, item `price` and line `rate` are MRP. `POST /pos/sales` sums the inclusive line amounts (after line and bill discount), shows `total` = that sum rounded to the rupee, and back-calculates each line's ex-tax rate and discount so the invoice total equals it exactly; spare paise land in `roundOff`. Send `expectedTotal` (the total the counter showed); a value more than Rs 1 from the lines gives 400.
- `GET /pos/sessions/:id` now includes `heldCount`. `POST /pos/sessions/:id/close` returns `409 HELD_BILLS` (`details.count`) while bills are held from that session, unless `confirmHeld: true` is sent.

# Wave 2: Hotel front office (module `hotel`)

Permissions: `hotel.view` (read), `hotel.front_office` (reservations, check-in/out, folio), `hotel.housekeeping` (room status), `hotel.manage` (setup, discounts, forced check-in). Dates are `YYYY-MM-DD`. A night belongs to its date; a stay `arrival` to `departure` has `departure - arrival` nights. Weekend nights are Friday and Saturday.

Setup (`hotel.view` to read, `hotel.manage` to write; PATCH takes `expectedUpdatedAt`, 409 `STALE_EDIT`):
- `GET/PATCH /hotel/settings` `{pricesIncludeTax, checkInTime, checkOutTime}`
- `GET/POST /hotel/room-types`, `PATCH /hotel/room-types/:id` `{name, baseOccupancy, maxOccupancy, baseTariff, extraPersonCharge, isActive}`
- `GET/POST /hotel/rooms`, `PATCH /hotel/rooms/:id` `{number, floor, roomTypeId, isActive}`
- `GET/POST /hotel/rate-plans`, `PATCH /hotel/rate-plans/:id` `{roomTypeId, name, meal: room_only|breakfast, weekdayTariff, weekendTariff, isActive}`

Housekeeping:
- `GET /hotel/rooms?status=&roomTypeId=` rows include `status`, `statusReason`, `occupied` (in house now) and `type`.
- `PATCH /hotel/rooms/:id/status` `{status: dirty|clean|inspected|out_of_order, reason}` (`hotel.housekeeping`). Flow: dirty to clean to inspected; clean or inspected back to dirty; any to out_of_order with a reason (not while in house); out_of_order only back to dirty. 409 `BAD_ROOM_STATUS`.

Availability and boards:
- `GET /hotel/availability?from&to` (to is exclusive, at most 62 days) returns `{dates, types:[{roomTypeId, name, total, byDate:[{date, booked, available}]}]}`. Out-of-order rooms are not counted as sellable.
- `GET /hotel/board?from&days=14` returns `{rooms:[{id, number, floor, type, status, stays:[{id, reservationId, number, guest, arrival, departure, status}]}]}` (stays only for assigned rooms).
- `GET /hotel/today` returns `{date, arrivals, departures, inHouse, roomCounts:{clean,dirty,inspected,out_of_order}, occupied, totalRooms}`.

Reservations:
- `POST /hotel/reservations` `{guest:{partyId} | {name, phone, address}, arrival, departure, rooms:[{roomTypeId, roomId?, ratePlanId?, adults, children}], overrideTariff?, source: walk_in|phone|ota|agent, sourceName?, status?: tentative|confirmed, notes?, advance?: {accountId, mode, amount, reference?}}`. Returns the reservation (201). 409 `NO_AVAILABILITY` (type full for a night), 409 `ROOM_TAKEN` (specific room overlaps).
- `GET /hotel/reservations?status=&date=&q=&from=&to=`, `GET /hotel/reservations/:id`, `PATCH /hotel/reservations/:id` (arrival, departure, overrideTariff, notes, source, sourceName; re-checks availability and room overlap; an in-house stay can only change departure, notes and override), `POST /:id/assign {rooms:[{id, roomId}]}` (assign or change specific rooms).
- `POST /:id/confirm`, `POST /:id/cancel {reason, refund?: {accountId, mode, amount, reference}}` (refund of up to the advance held: an outgoing payment through payments that reverses the receivable, kept as a folio payment of kind `refund`; needs `payments.create`; `advanceHeld` in the reply is net of refunds), `POST /:id/no-show`, `POST /:id/advance {accountId, mode, amount, reference}` (a receipt through payments, kept as an advance on the folio).

Stay:
- `POST /hotel/reservations/:id/check-in` `{rooms:[{id, roomId, guest:{name, phone?, address?, idType: aadhaar|passport|driving_licence|voter_id|pan|other, idNumber, nationality?, passportNo?, visaNo?, visaType?, visaExpiry?, arrivedFrom?, goingTo?, purpose?}}], force?}`. A foreign nationality needs passport and visa fields (Form C). Room must be clean or inspected (`hotel.manage` can `force`). Posts the first night. 409 `ROOM_NOT_READY`, 400 `TOO_EARLY`.
- `GET /:id/folio` returns `{reservation, lines, payments, totals:{subtotal, tax, discount, total, paid, balance}, invoice}`. Totals before check-out are estimates; the invoice is exact.
- `POST /:id/charges` `{chargeType: food|laundry|minibar|extra_bed|other|discount, description, qty?, rate, itemId?, reservationRoomId?}`; `discount` needs `hotel.manage` and `rate` is the amount off.
- `POST /:id/charges/:lineId/void {reason}`; `POST /:id/payments {accountId, mode, amount, reference}`.
- `POST /hotel/night-charges {date?}` posts the room charge for every in-house room for that date (default today, never future). Safe to repeat: one room charge per room per date.
- `POST /:id/check-out` `{payment?: {accountId, mode, amount, reference}, allowCredit?}`. Posts missing nights, creates one tax invoice, allocates advances and payments to it, takes the final payment, frees rooms as dirty. 409 `BALANCE_DUE` if the balance is not settled and `allowCredit` is not set. Returns `{reservation, invoice}`.

Reports (`hotel.view`):
- `GET /hotel/reports/occupancy?from&to` returns `{rows:[{date, available, sold, revenue, occupancyPct, adr, revpar}], totals}` from posted room nights.
- `GET /hotel/reports/guest-register?from&to` returns police-register rows: serial, room, name, address, nationality, ID, phone, arrival and departure time, passport and visa fields.

Tax: room nights use the tariff slab (up to 1,000 exempt, 1,001 to 7,500 at 5 percent, above 7,500 at 18 percent), picked per night. Needs a CA check. With `pricesIncludeTax` the tariff is what the guest pays and the invoice back-calculates as at the counter.
Other modules can add a charge to an open folio through the exported `postFolioCharge` in `backend/src/modules/hotel.ts`.

# Wave 2: Education (module `education`)

For `school` and `coaching`. Permissions: `education.view` (read everything except money), `education.admissions` (admit and edit students), `education.fees` (demands, dues, collection, receipts), `education.attendance` (mark attendance; teachers only for classes where they are the teacher, same day only), `education.manage` (years, classes, heads, plans, concessions, promotion; also allows all of the above). Admission numbers come from the `ADM` series (`ADM/26-27/00001`). A class is a school class with an optional `section`, or a coaching `batch` (`course`, `timing`, `teacherName`). Exams and report cards: see "Wave 2: Education exams and report cards".

| Method and path | Purpose |
|---|---|
| `GET /education/home` | `{today, year, classes[{id,label,students,attendanceMarked,present,absent,late,mine}], feesCollectedToday, duesTotal, defaultersCount}`. Money fields need `education.fees`; `feesCollectedToday` is `null` without it. |
| `GET /education/staff` | `{data[{id,name}]}` people of this business, for the class teacher picker. |
| `GET, POST /education/years`, `PATCH /education/years/:id` | `{name, startDate, endDate, isCurrent}`. One current year; the first is current. 409 `DUPLICATE_YEAR`. |
| `GET /education/classes?yearId&kind&active`, `POST`, `GET, PATCH /education/classes/:id` | `{yearId, kind, name, section, course, timing, teacherUserId, teacherName, capacity}`; list rows add `students`. 409 `DUPLICATE_CLASS`. |
| `GET, POST /education/fee-heads`, `PATCH /education/fee-heads/:id` | `{name, gstRate}`. Each head is a service item (HSN 999293) with its own rate: 0 for school tuition, 18 for most coaching. 409 `DUPLICATE_HEAD`. |
| `GET, PUT (or POST) /education/classes/:id/fee-plan` | One plan per class. `{name, late{kind: none, flat, percent, per_day; value; headId}, instalments[{label, dueDate, lines[{headId, amount}]}]}`. PUT replaces; instalments match by position so billed ones keep their id. 409 `PLAN_IN_USE` when removing a billed instalment. |
| `GET /education/students?q&classId&yearId&status` | Search by name, admission number or guardian phone. Default `status=active` (also `left`, `passed_out`). |
| `POST /education/students` | `name, sex, guardianName, guardianPhone`, optional `classId, rollNo, dob, guardianRelation, address, admissionDate, notes, force`. Creates the payer party. 409 `DUPLICATE_STUDENT` (same name and guardian phone, `matches[]`; resend with `force`), `CLASS_FULL`, `ROLL_TAKEN`. |
| `GET, PATCH /education/students/:id` | Patch takes any create field plus `status` and `expectedUpdatedAt` (409 `STALE_EDIT`). Read adds `concessions[]` and `dues {due, overdue}` (fees permission). |
| `POST /education/students/:id/concessions`, `DELETE /education/concessions/:id` | `{headId, kind: percent|amount, value, reason}`. One active concession per student and head; a new one replaces it. An amount is taken off that head in every instalment (never below zero). |
| `POST /education/promote` | `{fromClassId, toClassId?, passOut?, studentIds?}`. Moves active students (all if no ids) and clears roll numbers, or marks them `passed_out`. Returns `{moved, passedOut}`. 409 `CLASS_FULL`. |
| `POST /education/demands/generate` | `{classId, instalmentId, preview?, applyLateFee?=true, locationId?}`. One invoice per active student through the invoice service, due date = instalment date. Skips students already billed for that instalment (a cancelled invoice frees it), so it is safe to repeat. A late fee line is added when today is after the due date and the plan has a rule. `preview: true` posts nothing. Returns `{count, alreadyBilled, nothingToBill, amount, lateFeeCount, lateFeeAmount, concessionAmount, created, invoices[]}`. Up to 500 students at a time. Needs `invoices.create` to post. |
| `GET /education/dues?classId&overdue=true&q` | `{total, dueTotal, overdueTotal, data[{student fields, due, overdue, oldestDue, daysOverdue, reminder}]}`; `reminder` is plain text to copy. |
| `GET /education/students/:id/ledger` | `{billed, paid, due, bills[], receipts[]}`. |
| `POST /education/students/:id/collect` | `{accountId, mode, amount, reference?, date?}`. Receipt through the payments service, allocated to the oldest due date first; partial allowed. 400 when amount is over the dues. Needs `payments.create`. Returns `{payment, balance, allocations}`. |
| `GET /education/receipts/:paymentId` | Receipt data: `{school, receipt, student, paidFor[{invoiceNumber,label,paid,heads[]}], balance}`. |
| `GET, PUT (or POST) /education/classes/:id/attendance?date` | Roster `{students[{studentId,name,rollNo,status,recorded}], marked}`; default status is `present`. PUT `{date?, marks[{studentId, status: present|absent|late}]}` upserts one row per student per day; unlisted students with no row are saved as present. 400 for a future date; 403 for a teacher of another class or a past date. |
| `GET /education/classes/:id/attendance/sheet?month=YYYY-MM` | Monthly sheet: per student `marks` by day, counts and `percentage` ((present + late) of marked days). |
| `GET /education/students/:id/attendance?month` | `{overall, thisMonth, days[]}` with counts and percentage. |

Known gaps: exams and report cards; late fee is only added when demands are generated; no sibling grouping (one party per student); no SMS or WhatsApp sending.

# Wave 2: Funds and donations

Module keys `funds` (government, psu, local_body, ngo, religious, housing_society) and `donations` (ngo, religious). Permissions: `funds.view`, `funds.entry` (propose sanctions and re-appropriation, record grants, link spending), `funds.manage` (funds, heads, budgets, approvals, overspend rule); `donations.view`, `donations.create`, `donations.manage` (cancel receipts, Form 10BD). Money is rupees. A financial year is `2026-27`. Migration 028.

## Settings
- `GET /funds/settings`, `PUT` or `PATCH /funds/settings`: `{overspendMode: block|warn, reg80gNo, reg80gFrom, reg80gTo, trustPan, receiptFooter}`. `block` makes an overspend a 409 `BUDGET_EXCEEDED` or `FUND_EXCEEDED`; `warn` lets it through and returns `warnings`. Changing `overspendMode` needs `funds.manage`; 80G fields also `donations.manage`.

## Funds
- `GET, POST /funds/funds`: `name, kind (grant, csr, own, donation, other), sponsor, sanctionNo, sanctionDate, totalAmount, periodFrom, periodTo, returnUnspent, notes`. Rows carry `received, spent, committed, balance`. 409 `DUPLICATE_FUND`.
- `GET, PATCH /funds/funds/:id`: any create field plus `status` (active, closed) and `expectedUpdatedAt` (409 `STALE_EDIT`).
- `GET, POST /funds/funds/:id/receipts`: grants received. `amount, date, accountId (cash or bank, default bank), reference, narration`. Posts bank debit and grant income credit. 409 `FUND_CLOSED`. For a fund with `returnUnspent` the credit goes to the liability account "Grants Refundable (Unspent)"; each spending link (`POST /funds/links`) then moves its amount from that liability to grant income (journal on the link id), and `DELETE /funds/links/:id` reverses it. Receipts taken before this change stay as income.

## Budget heads
- `GET /funds/heads?fy`: flat list with `parentId, level, code, name, accountId, isLeaf, estimate, revised, reappIn, reappOut, budget, actual, committed, available, percentUsed, percentCommitted`; parents add up their children. `totals` sums the major heads.
- `POST /funds/heads`: `fy, level (major, minor, object), parentId, code, name, accountId (expense account), budgetEstimate, revisedEstimate`. A minor head sits under a major, an object head under a minor. Amounts live on the lowest heads only. 409 `DUPLICATE_HEAD`, `PARENT_HAS_BUDGET`, `PARENT_IN_USE`.
- `PATCH /funds/heads/:id`: `code, name, accountId, budgetEstimate, revisedEstimate, isActive, expectedUpdatedAt`.
- Budget of a lowest head = (revised, else estimate) + approved re-appropriation in - out. Available = budget - actual - committed.

## Re-appropriation
- `GET /funds/reappropriations?fy&status`, `POST /funds/reappropriations`: `fromHeadId, toHeadId, amount, orderNo, orderDate, reason`. Lowest heads of one year. With `funds.manage` it is approved at once; with `funds.entry` it waits as `pending`. 409 `INSUFFICIENT_BUDGET` when the source head has less available.
- `POST /funds/reappropriations/:id/approve`, `.../reject` (`funds.manage`). 409 `ALREADY_DECIDED`.

## Sanctions and spending
- `GET /funds/sanctions?status&headId&fundId`, `GET /funds/sanctions/:id`, `POST /funds/sanctions`: `headId, fundId, purpose, amount`. Number `SAN/yy-yy/00001`. Returns `warnings` as a preview; nothing is committed until approval.
- `POST /funds/sanctions/:id/approve` (`funds.manage`): `adminOrderNo, adminOrderDate, financialOrderNo, financialOrderDate, note`. Applies the overspend rule against the head and the fund's total. An approved sanction commits `amount - spent against it`.
- `POST /funds/sanctions/:id/reject` (manage), `POST /funds/sanctions/:id/cancel` (pending: entry; approved with no links: manage; else 409 `HAS_SPENDING`).
- `GET /funds/spendable?type=purchase|expense|payment&q`: documents with an unlinked balance.
- `POST /funds/links`: `sourceType, sourceId, headId, fundId, sanctionId?, amount? (default the unlinked balance), note`. Spending already covered by a sanction does not count twice. 409 `DOUBLE_COUNT` (a bill and its own payment), `ALREADY_LINKED`, overspend codes above. Cancelled documents drop out of actuals. `GET /funds/links?headId&fundId&sanctionId`, `DELETE /funds/links/:id`.

## Home and reports
- `GET /funds/home?fy`: `{fy, heads (major heads), funds, pendingSanctions, pendingReappropriations, totals, overspendMode}`.
- `GET /funds/reports/budget-vs-actual?fy`: heads as above plus `totals`.
- `GET /funds/reports/fund-wise?from&to`: per fund `opening, received, spent, closing`. Received includes grants and donations tagged to the fund.
- `GET /funds/funds/:id/utilisation?from&to`: data for the utilisation certificate: `fund, company, opening, received, receipts, spentByHead, spent, closing, returnUnspent, refundDue`. The PDF is built in the app.

## Donations
- `GET, POST /donors`, `GET, PATCH /donors/:id`: `name, phone, email, pan, aadhaar, address`. Creates a customer party. Aadhaar is returned masked. 409 `DUPLICATE_DONOR` for the same PAN, or the same name and phone unless `force: true`.
- `GET /donors/:id/statement?fy`: the year's donations, `total`, `eligibleFor80g`, 80G registration.
- `POST /donations`: `donorId, amount, mode (cash, upi, cheque, bank), date, reference, fundId, purpose, isCorpus, tax80g, accountId`. Receipt number `DON/yy-yy/00001`. Posts bank or cash debit and credit to "Donations Received" (income) or "Corpus Fund" (equity). `tax80g` needs donor PAN or Aadhaar (400). Cash above Rs 2,000 is saved with `deductionEligible: false` and a `warning`; a missing or expired 80G registration adds to `warnings`.
- `GET /donations?q&from&to&donorId&fundId&status`, `GET /donations/home` (today and this year), `GET /donations/:id` (adds donor, trust and 80G details for the receipt PDF), `POST /donations/:id/cancel` (`donations.manage`, `reason`; reverses the journal).
- `GET /donations/form-10bd?fy&format=json|csv` (`donations.manage`): eligible 80G donations of the year. Columns: Sr No, Section Code, Donor ID Type, Donor ID, Donor Name, Donor Address, Donation Type (Corpus, Specific grant, Others), Mode of Receipt (Cash, Other modes), Amount of Donation. Donors with no PAN or Aadhaar are listed in `skipped`. Check before filing: the portal's codes change.

# Wave 2: Memberships (module `memberships`) and job cards (module `job_cards`)

Memberships is for gym, salon and housing society. Job cards is for garage, electronics and auto parts. Money is posted through the normal invoice and payment services; these modules write no ledger rows. All bodies are JSON. Dates are `YYYY-MM-DD`. Errors use the usual shape. Migration 033.

## Memberships

Permissions: `memberships.view` (read), `memberships.manage` (everything below), `memberships.checkin` (door check-in only).

- `GET/POST /memberships/plans`, `PATCH /memberships/plans/:id`. Body: `name, billing (upfront|monthly), rateBasis (fixed|per_sqft), durationUnit (months|days), durationCount, price, gstRate, joiningFee, freezeDays, isActive`. A per sq ft plan must be monthly. Each plan makes a service item that carries the tax rate.
- `GET /memberships/summary` returns `active, expiring (within 7 days), expired, frozen, noPlan, total, visitsToday, duesMembers, duesAmount`.
- `GET /memberships/members?q=&status=&limit=&offset=`; status is `active|expiring|expired|frozen|none`.
- `POST /memberships/members` body: `name, phone, emergencyName, emergencyPhone, photoFileId, flatNo, wing, areaSqft, occupancy (owner|tenant), notes, planId, startDate, price, bill (default true), payment {accountId, mode, amount, reference}, locationId`. Creates the customer party, a member number from series `MEM`, the first subscription and, for upfront plans, the first bill (plus joining fee). Returns `{memberId, memberNo, subscription, invoice, payment}`. 400 if a per sq ft plan has no `areaSqft`.
- `GET/PATCH /memberships/members/:id`. The file holds subscriptions, bills, last 30 visits and dues.
- `POST /memberships/members/:id/renew` body `planId?, date?, price?, bill, payment`. The new term starts the day after the old end date, or on `date` (default today) when lapsed. 409 `FROZEN` while frozen.
- `POST /memberships/subscriptions/:id/freeze` `{date?}` and `/unfreeze` `{date?}`. Unfreeze adds the frozen days to the end date, capped by the plan's freeze days left. 409 `NO_FREEZE_DAYS`.
- `GET /memberships/dues` lists members with unpaid bills and a `reminder` text to copy. `POST /memberships/members/:id/collect` `{accountId, mode, amount, reference}` receipts against the oldest bills first; 400 if more than dues.
- `GET /memberships/bills/preview?kind=maintenance|renewals&period=YYYY-MM` returns `{count, alreadyBilled, skipped[]}`. `POST /memberships/bills/generate` `{kind, period?, locationId?}` returns `{created, total}`. Maintenance bills one invoice per monthly subscription per period (area times rate for per sq ft). `mem_bills` is unique on subscription and period, so a repeat run creates nothing. Renewals renews members whose term ends within 7 days or has ended.
- `POST /memberships/checkin` `{memberNo | phone}` returns `{ok, name, endDate, daysLeft, expiringSoon, repeatToday}`. Refused with 409 and a plain message: `MEMBERSHIP_EXPIRED`, `MEMBERSHIP_FROZEN`, `MEMBERSHIP_NOT_STARTED`, `NO_PLAN`, `MEMBER_INACTIVE`. 404 for an unknown member. `GET /memberships/visits?date=`.

## Job cards

Permissions: `job_cards.view` (all jobs), `job_cards.create` (receive, estimate, bill, deliver), `job_cards.work` (technician: sees and works only jobs assigned to them), `job_cards.manage`.

- `GET /job-cards?status=&open=true&mine=true&technicianId=&q=` returns `{data, counts}` by status. `GET /job-cards/technicians`.
- `POST /job-cards` body: `kind (vehicle|device), vehicleNo, make, model, odometer, serialNo, partyId | customer {name, phone}, complaints, accessories, photoFileIds[], promisedDate, technicianId, locationId`. Number from series `JOB`. Vehicle jobs need `vehicleNo`.
- `GET/PATCH /job-cards/:id`. Detail holds `lines, totals {parts, labour, subtotal, tax, total}, invoice, nextStatuses, statusMessage` (plain text to copy).
- `POST /job-cards/:id/lines` `{kind (part|labour), itemId, qty, rate?, discountPct?, description?}`, `PATCH|DELETE /job-cards/:id/lines/:lineId`. Labour must be a non-stocked item. A change after approval puts the job back to `estimate_sent`. Issued parts cannot be changed (409 `ALREADY_ISSUED`).
- `POST /job-cards/:id/status` `{status, approvedBy?, reason?}`. Flow: received, estimate_sent, approved, in_progress, ready, delivered; `approved` may go back to `estimate_sent`, `ready` back to `in_progress`; cancel before ready with a reason. 409 `BAD_TRANSITION` for any other move, `NOT_BILLED` for delivery without a bill, `BILLED` for cancelling a billed job.
- `POST /job-cards/:id/issue` `{lineIds?}` while in progress. Checks stock (on hand, less sales order reservations, less parts held by other open jobs) and marks the parts issued; repeating changes nothing. 409 `INSUFFICIENT_STOCK`. Stock itself moves once, when the bill is made.
- `POST /job-cards/:id/bill` `{payment?}` when ready. Creates one invoice (parts then labour) through the invoice service. 409 `ALREADY_BILLED`. `POST /job-cards/:id/receipt` `{accountId, mode, amount, reference}` against the job bill.

# v1.13 Manufacturing

Module key `manufacturing`. Permissions: `manufacturing.view` (read everything), `.bom` (BOMs, work centres), `.orders` (create, edit, release, cancel orders), `.issue` (issue and return material, job work), `.output` (record output), `.inspect` (quality inspections), `.manage` (close orders, settings, material planning, raise purchase orders). Costs (rates, values) show only with `items.view_cost`. All paths start with `/manufacturing`. Stale edits use `expectedUpdatedAt` and answer 409 `STALE_EDIT`. Every POST is idempotent by `Idempotency-Key`.

Stock moves and journals go through the stock and journal code. Material issued to an order debits Work in Progress (1220) and credits Inventory. Output debits Inventory for the finished goods and by-products, credits Work in Progress for the material it carries and credits Conversion Cost Absorbed (5340) for work centre time and overhead. Closing an order writes any unabsorbed material in WIP to Stock Shortage & Wastage.

## Setup
- `GET /settings`, `PUT` or `PATCH /settings` `{overheadPct 0-500}` (manage). Overhead is a percent of material plus work centre cost. An order keeps the percent that applied when it was created.
- `GET /work-centres?q&active`, `POST /work-centres` `{name, hourlyCost}`, `PATCH /work-centres/:id` `{name?, hourlyCost?, isActive?, expectedUpdatedAt?}` (bom). 409 on a duplicate name.

## Bills of materials
- `GET /boms?q&itemId&status&limit&offset`. Rows: `id, itemId, itemName, version, status (draft|active|archived), outputQty, lineCount, updatedAt`.
- `POST /boms` `{itemId, outputQty?, note?, lines[{kind (component|byproduct), itemId, qty, scrapPct?, rate?}], steps?[{operation, workCentreId, minutesPerUnit}]}`. Creates the next version as a draft. `qty` is for `outputQty` of the finished item. `rate` is the value per unit of a by-product (default 0). Components and the finished item must be stock items; an item cannot be its own component (400).
- `GET /boms/:id`: header, `lines`, `steps` (with `workCentreName`, `hourlyCost`), `standardCost` (with cost permission).
- `PATCH /boms/:id` same body, all optional, replaces lines and steps when sent. Draft only; 409 `BOM_LOCKED` otherwise.
- `POST /boms/:id/activate`: the previous active version becomes `archived`. 409 `BOM_CYCLE` when the structure loops back on itself.
- `POST /boms/:id/copy`: new draft version with the same lines. `DELETE /boms/:id`: draft only.
- `GET /explode?itemId|bomId&qty` explodes into `tree` (nested components with `qty`, `bomId` if the component has its own active BOM) and `raw[{itemId, name, unit, qty, onHand}]`, the total raw material for `qty` including scrap.

## Production orders
- `GET /orders?status&q&from&to`, `GET /orders/:id`. Detail: header, `materials[{itemId, name, unit, plannedQty, issuedQty, returnedQty, netQty, onHand, ...costs}]`, `steps`, `outputs`, `byProducts`, `movements`, `inspections`, `cost {material, conversion, total, unitCost}`, `variance {lines[{itemId, expectedQty, actualQty, varianceQty, varianceValue}], yieldPct, ...}`, `nextActions`.
- `POST /orders` `{itemId, qty, locationId, bomId?, plannedStart?, plannedEnd?, salesOrderId?, notes?}`. Uses the active BOM unless `bomId` is given. Material plan = BOM lines scaled to `qty` with scrap. 409 `NO_ACTIVE_BOM`.
- `PATCH /orders/:id` `{qty?, locationId?, plannedStart?, plannedEnd?, notes?, expectedUpdatedAt?}` (draft or released; qty rescales untouched material lines). `PUT` or `PATCH /orders/:id/materials/:itemId` `{plannedQty}` adds or changes a planned line; `0` removes it if nothing was issued.
- `POST /orders/:id/release`, `POST /orders/:id/cancel` `{reason}` (409 `HAS_ACTIVITY` once material is issued and not returned, or output exists).
- `POST /orders/:id/issue` `{all?: true, lines?[{itemId, qty}], note?}` (issue). `all` issues what is still planned. Checks stock at the order's location (409 `INSUFFICIENT_STOCK`); 409 `NOTHING_TO_ISSUE`. Stock leaves at average cost.
- `POST /orders/:id/return` `{lines[{itemId, qty}], note?}` returns unused material at the cost it left at. 409 `RETURN_TOO_MUCH`.
- `POST /orders/:id/output` `{goodQty, rejectedQty?, minutes?, byProducts?[{itemId, qty}], date?, note?}` (output). Moves good quantity into stock at cost. Work centre cost uses `minutes` when given, otherwise routing minutes per unit times good plus rejected quantity. Rejected units carry cost into the good units; with no good units the cost goes to wastage. Partial output allowed; 409 `ORDER_NOT_OPEN` after close.
- `POST /orders/:id/inspections` `{outputId?, passQty, reworkQty, rejectQty, note}` (inspect). Records only; the sum cannot exceed good output not yet inspected (409 `INSPECTION_TOO_MUCH`).
- `POST /orders/:id/close` `{note?}` (manage). Status `completed`; response has the variance.

Status flow: draft, released, in_progress (first issue or output), completed or cancelled. 409 `BAD_TRANSITION` otherwise.

## Material planning
- `GET /mrp?locationId` lists `shortages[{itemId, name, unit, required, onHand, onOrder, shortage}]`. Demand = open sales orders (confirmed to partially dispatched) for finished items with an active BOM, net of finished stock and open production orders, exploded to raw material, plus unissued material of released and in-progress orders. Supply = stock on hand and open purchase order quantity (approved, sent, partly received).
- `POST /mrp/purchase-order` `{partyId, locationId, lines[{itemId, qty}], expectedDate?}` (manage and `purchase_orders.manage`) creates a draft purchase order through the purchase order service.
- `GET /home`: `{ordersByStatus, shortagesCount, todayOutput[{itemId, name, unit, goodQty}], openJobWork}`.

## Job work outward
- `GET /jobwork?status&q`, `GET /jobwork/:id` (lines with `qtySent, qtyReceived, qtyScrap, qtyPending`, receipts, `ageDays`).
- `POST /jobwork` `{partyId, locationId, challanDate?, process, expectedReturn?, vehicleNo?, notes?, lines[{itemId, returnItemId?, qty}]}` (issue). Stock leaves the location at average cost into Stock in Transit. Number from the `JWC` series.
- `POST /jobwork/:id/receive` `{date?, note?, lines[{lineId, qtyReceived, qtyScrap?}]}`. Processed goods enter stock at the cost sent; scrap goes to wastage. 409 `OVER_RECEIPT`.
- `POST /jobwork/:id/cancel` `{reason}` before any receipt: stock returns at the cost it left.
- `GET /jobwork/itc04?from&to` ITC-04 style rows per job worker and item (sent, received, scrap, pending, ageDays, `overdue` after 365 days) with `note: "Check before filing"`. Not a filing.

# v1.9 Channels

Online selling: marketplaces and web stores. No marketplace credentials or network calls exist yet. Every channel works in file-import mode (CSV order and settlement reports) behind the adapter interface in `backend/src/lib/channels/types.ts`. A live API client is added later. Report layouts and API details for Amazon, Flipkart, Meesho, Shopify and WooCommerce: to verify with each marketplace's current docs. Until then the generic column names below are used and each channel can remap its own headers.

Module key `channels`. Permissions: `channels.view` (see everything), `channels.manage` (set up channels, map SKUs, import orders), `settlements.manage` (import settlement reports, post them). Money is in rupees.

## Channels

- `GET /channels/connectors` lists providers with `stage`, `capabilities`, `liveApi` (false) and a note.
- `GET /channels` returns `{ data, total }`. Each row: `id, provider, name, status, locationId, locationName, partyId, orderStatus, pricesIncludeTax, tcsRate, tdsRate, csvMapping, settlementAliases, csvColumns, lastImportAt, lastError, listingCount, unmappedCount, orderCounts, connector, updatedAt`.
- `POST /channels` (manage): `provider` (manual, amazon, flipkart, meesho, shopify, woocommerce, other), `name`, `locationId`, optional `partyId` (a customer is created if missing), `orderStatus` (`confirmed` default, or `draft`), `pricesIncludeTax` (default true), `tcsRate` (default 0.5), `tdsRate` (default 0.1), `csvMapping` (generic column to the channel's header), `settlementAliases` (label to line kind). 409 `DUPLICATE_NAME`.
- `GET /channels/:id`, `PATCH /channels/:id` (manage; same fields, `status` connected or disabled, `expectedUpdatedAt` gives 409 `STALE_EDIT`).
- TCS (GST section 52) and TDS (section 194-O) rates are defaults to check before filing.

## SKU mapping

- `GET /channels/:id/listings?q=` returns `{ data, total }`; a listing has `channelSku, title, externalId, isActive, components[{ itemId, itemName, itemSku, qty }]`. A single item is one component with qty 1; a bundle has several.
- `POST /channels/:id/listings` and `PUT` or `PATCH /channels/:id/listings/:listingId`: `{ channelSku, title?, externalId?, isActive?, components: [{ itemId, qty }] }`. Returns `{ listing, ordersCreated }`. Saving a mapping re-runs orders that waited for it. 409 `DUPLICATE_SKU`. `DELETE` gives 204.
- `GET /channels/:id/unmapped` is the fix list: `channelSku, title, seenCount, lastSeenAt`.

## Orders

Generic order columns: `order_id, order_date, sku, title, qty, unit_price, discount, ship_state, status` (also `buyer_name`, `line_total`). Rows with the same `order_id` are one order. Dates: `YYYY-MM-DD`, `DD-MM-YYYY` or `DD/MM/YYYY`. `status` starting with "cancel" cancels.

- `POST /channels/:id/orders/import` (manage): `{ csv, dryRun }`. Dry run writes nothing and returns `orders[]` with `action` (`create`, `duplicate`, `cancel`, `ignored`, `blocked`), `reason`, `unmappedSkus`, `lines[]` (item, qty, rate before tax), `estimate { subtotal, taxTotal, total }`, plus `issues[]` (bad rows) and `summary`. A real run returns `results[]` (`externalRef, action, status, errorCode, message, salesOrderId, salesOrderNumber, heldAsDraft`) and `summary { total, created, duplicates, cancelled, ignored, failed, heldAsDraft }`.
- Each order is its own savepoint. Unmapped SKU: nothing is created, the inbox row fails with `UNMAPPED_SKU` and the SKU joins the fix list. Prices are converted to before-tax rates when `pricesIncludeTax`; bundle prices split by component sale price. The order becomes a sales order (source `channel`, `externalRef` = channel order id), is confirmed and stock reserved, unless the channel keeps drafts or stock is short (`heldAsDraft`, code `INSUFFICIENT_STOCK`). A cancel row cancels an unshipped order and releases its stock; for shipped orders the inbox row fails and a sales return is needed. Importing the same order id again does nothing.
- Invoices come from the existing fulfilment flow: pick, pack, `POST /sales-orders/:id/dispatch`.
- `GET /channels/inbox?connectionId&status&q` returns `{ data, total, counts }`. Row: `id, connectionName, externalRef, status (received, processed, ignored, failed, dead), error, errorCode, salesOrderId, salesOrderNumber, salesOrderStatus, orderDate, total, lines[]`.
- `POST /channels/inbox/:id/retry` (manage) re-runs a failed row.

## Settlements

Settlement columns: `settlement_id, payout_date, order_id, type, amount`. Positive is money to the seller. `type` is mapped to a line kind through built-in labels and the channel's `settlementAliases`: `sale, refund, commission, fee, shipping, gst_on_fees, tcs, tds, reserve, reserve_release, adjustment`. A row with type `payout` or `net payout` states the amount paid to the bank; without one the payout is the sum of lines. Unknown labels are listed in `issues` and skipped.

- `POST /channels/:id/settlements/import` (settlements.manage): `{ csv, dryRun, bankAccountId? }`. Returns `settlements[]` (`settlementRef, payoutDate, payout, linesTotal, difference, status, lineCount, unmatchedOrderRefs, duplicate, settlementId`), `issues`, `summary`. Status: `matched` (every order found), `imported`, `unbalanced` (payout differs from the lines). Importing a settlement id again creates nothing.
- `GET /channels/settlements?connectionId&status` and `GET /channels/settlements/:id`. Detail adds `orders[]` (`orderRef, orderNumber, expected, received, difference, fees, matched`), `lines[]`, `totals` by kind, `unmatchedOrders`, and `statutory { taxableValue, tcs, tds }` each with `rate, expected, received, difference`, plus a "check before filing" note.
- `POST /channels/settlements/:id/post` (settlements.manage): voucher type `settlement`, dated the payout date. Dr bank (payout); Cr Accounts Receivable with the channel customer for sales (Dr for refunds); Dr Marketplace Fees (6100) for commission, fees, shipping and adjustments; Dr Input IGST for GST on fees (CA review needed); Dr TCS Receivable (1311); Dr TDS Receivable (1310); Dr or Cr Marketplace Reserve (1420). Errors: 409 `UNBALANCED_SETTLEMENT`, 409 `PERIOD_LOCKED`, 409 `ILLEGAL_TRANSITION` (already posted).

# v1.12 HR and payroll

Module key `payroll`. Migration `031_payroll.sql`. Salaried staff only; site workers paid by the day stay in the labour endpoints.
Rates, slabs and state tables are defaults that need a CA check before real filing. Money is rupees. Months are `YYYY-MM`.

Permissions: `payroll.view` (pay figures, runs, reports), `payroll.employees` (employees, structures, leave setup), `payroll.leave_approve`,
`payroll.run` (prepare runs), `payroll.approve` (approve and pay; never the person who prepared the run), `payroll.self` (own payslips, leave).
Without `payroll.view`, list endpoints leave out pay (`monthlyGross` is absent).

## Setup
- `GET/PUT /payroll/settings` `{ lopDivisor: calendar|30|26, pfEnabled, esiEnabled, ptEnabled, lwfEnabled, pfRate: 10|12, pfCode, esiCode, ptRegistration }`
- `GET /payroll/components`, `POST /payroll/components`, `PATCH /payroll/components/:id`. Body `{ code, name, kind: earning|deduction, calc: fixed|pct_basic|pct_gross, percent, isBasic, taxable, pfWage, esiWage, proRata, sortOrder }`. Defaults (Basic, HRA, Conveyance, Special) are created on first read.
- `GET/POST/PATCH /leave-types` `{ code, name, isPaid, yearlyQuota, carryForwardLimit, isActive }`. Defaults CL, SL, EL, LOP on first read.
- `GET /holidays?year=`, `POST /holidays { date, name, locationId? }`, `DELETE /holidays/:id`.

## Employees
- `GET /employees?q&status&locationId&department&limit&offset`. Needs `payroll.view`, `.employees`, `.leave_approve` or `.run`. Rows: `id, code, name, department, designation, locationId, locationName, status, joiningDate, leavingDate, aadhaarLast4, uanSet, panSet, monthlyGross` (the last only with `payroll.view`).
- `GET /employees/:id` full file (own file with `payroll.self`). Aadhaar is never stored whole: `aadhaarMasked` is `XXXX XXXX 1234`. Bank account is masked unless the caller has `payroll.employees`.
- `POST /employees`, `PATCH /employees/:id` (`expectedUpdatedAt` gives 409 STALE_EDIT). Code `E0001`... is generated. Fields: `name, fatherSpouseName, dob, sex M|F|O, email, phone, joiningDate, leavingDate, department, designation, locationId, reportingTo, userId, pan, aadhaar, uan, esiNumber, bankName, bankAccount, bankIfsc, salaryMode, taxRegime new|old, pfApplicable, pfHigherWage, esiApplicable, ptStateCode, previousIncome, previousTds, notes, status`.
- `GET /employees/:id/salary` revisions, newest first. `POST /employees/:id/salary { effectiveFrom, ctcAnnual?, lines: [{ componentId, amount? }], note }`. Without `lines`, `ctcAnnual` is split (basic 50% by default). A date can have one revision; older revisions are never changed. 409 if the date is used.

## Leave and attendance
- `GET /leave-applications?status&employeeId&mine`, `POST /leave-applications { employeeId?, leaveTypeId, fromDate, toDate, halfDay, reason }`. Days exclude Sundays and holidays. Errors: 409 `INSUFFICIENT_LEAVE`, 409 overlap.
- `POST /leave-applications/:id/approve|reject|cancel { note }`. Approve and reject need `payroll.leave_approve` and never your own leave (403).
- `GET /employees/:id/leave-balances?fy=2026` (fy is the April start year). `POST /employees/:id/leave-adjustments { leaveTypeId, fy, days, reason }`.
- `GET /attendance-summaries?month=`, `PUT /attendance-summaries { month, rows: [{ employeeId, presentDays, paidLeaveDays, lopDays }] }`, `POST /attendance-summaries/derive { month }`. Without a row, a run takes loss-of-pay days from approved unpaid leave.
- `GET /attendance-days?month=` gives `{ data: [{ employeeId, day, status }] }`; status is `present|absent|half_day|leave|holiday|week_off`. `PUT` or `PATCH /attendance-days { month, rows: [{ employeeId, days: [{ day, status|null }] }] }` sets or clears days (null clears), then rewrites that employee's month totals with source `register` (present + half of half days, leave days as paid leave, absent + half of half days as loss of pay). Unmarked, holiday and week-off days count as nothing. 409 `RUN_LOCKED` once the month's run is approved. Audited. Migration 037.
- `GET /hr/summary` head count, joiners and leavers, pending leave, this month's runs, birthdays in 14 days.

## Payroll runs
Status: `draft`, `computed`, `approved`, `posted` (paid), `cancelled`. One live run per month and location (a run without a location covers everyone).
- `GET /payroll/runs?month&status`, `POST /payroll/runs { month, locationId?, notes }` (409 `RUN_EXISTS`), `GET /payroll/runs/:id` with `lines`, `adjustments`, `canApprove`.
- `POST /payroll/runs/:id/compute` rebuilds every line. Returns `skipped` (employees with no salary structure).
- `POST /payroll/runs/:id/adjustments { employeeId, kind, label, amount, taxable, reason }`, `DELETE .../adjustments/:adjId`. Arrears, bonus and advance recovery. The run is recomputed.
- `POST /payroll/runs/:id/overrides { employeeId, field: lop_days|pf_employee|esi_employee|pt|lwf_employee|tds, value, reason }` (reason required), `DELETE .../overrides/:employeeId/:field`.
- `POST /payroll/runs/:id/approve` needs `payroll.approve`; 403 `SELF_APPROVAL` if the caller created, computed, adjusted or overrode the run. Posts the journal (voucher type `wages`): debit salary by component and employer contributions; credit net salary, PF, ESI, professional tax, LWF, TDS and other deductions payable.
- `POST /payroll/runs/:id/pay { payDate?, accountId? }` debits Net Salary Payable, credits bank (or the chosen account). Status becomes `posted`.
- `POST /payroll/runs/:id/cancel` for draft or computed runs.
- Lines: `workingDays, paidDays, lopDays, earnings, adjustments, gross, pfWage, pfEmployee, pfEps, pfEpfEmployer, pfEdli, pfAdmin, esiEmployee, esiEmployer, pt, ptStateCode, lwfEmployee, lwfEmployer, tds, tdsWorking, otherDeductions, deductions, net, overrides, warnings`.

## Reports, files and payslips
- `GET /payroll/runs/:id/statutory` PF, ESI, PT by state, LWF and TDS totals.
- `GET /payroll/runs/:id/files/bank|ecr|esi|pt` downloads. Bank needs an approved run. ECR (`#~#` separated) needs a UAN for every member (409 `MISSING_UAN`), ESI needs ESI numbers (`MISSING_ESI`), bank needs account and IFSC (`MISSING_BANK`).
- `GET /payroll/me` the caller's linked employee. `GET /payroll/payslips?employeeId&month&mine` (own approved payslips with `payroll.self`). `GET /payroll/payslips/:id` full payslip: company, employee, earnings, deductions, employer contributions, net, year to date.

## Known limits
Mid-month pay revisions use one revision for the month. PF ceiling follows the first day of the month (15,000 before 1 Oct 2026, 25,000 from then; the September split is not pro-rated). PF admin charge has a 500 minimum at run level. No gratuity, bonus, final settlement, loans schedule or reversal of an approved run yet. A daily attendance register is not built.

# v1.11 Platform readiness

## Module entitlements
A route of a module the company has not enabled answers `403 MODULE_DISABLED` (`details.module` names it). The table is `MODULE_ROUTES` in `backend/src/lib/entitlements.ts`: pos, restaurant, clinic, legal, education, hotel, funds, donations (and donors), memberships, job-cards, channels, payroll, manufacturing, gst, tds, fixed-assets, fulfilment (pick-lists, shipments, sales-returns), construction (projects, boq, dprs, ra-bills, work-orders, wage-sheets, workers, attendance, indents, issues, labour and contractor advances), real estate (units, bookings, demands, payment-plans) and inter-company entries. Everything else is open: auth, me, company and business profile, platform admin, users and roles, files, jobs, and the core books. A company whose module list is null uses the defaults for its business type.

## OpenAPI
- `GET /openapi.json` (no sign-in) returns an OpenAPI 3.1 document of every route, with the module (`x-module`) that gates it. Request bodies are described where a zod schema is registered with `documentRoute`; others show a free-form object and are described in this file.
- `npm run openapi` in `backend` writes `docs/openapi.json`. CI fails when the committed file is out of date.

## API keys
Permission `integrations.manage` (Owner and Company Admin). A person manages keys; a key cannot (403).
- `GET /api-keys` lists keys: `id, name, prefix, roleId, roleName, expiresAt, lastUsedAt, revokedAt, createdAt`.
- `POST /api-keys { name, roleId, expiresAt? }` returns 201 with the same fields and `key` (`pk_...`), shown once. Only a SHA-256 hash is stored. 400 when the role has permissions the caller lacks, or includes user, role, security or integration management.
- `POST /api-keys/:id/revoke` returns the key with `revokedAt`; 404 when already revoked.
- Use a key as `Authorization: Bearer pk_...`. It acts in its company with exactly its role's permissions, attributed to the user who made it ("name (API key)"). 401 when revoked, expired, unknown, or when that user is deactivated. `X-Company-Id` for another company is 401. `lastUsedAt` updates at most once a minute.

## Webhooks
- `GET /webhooks/events` events you can subscribe to: `invoice.created`, `payment.received` (receipts), `order.created` (sales orders).
- `GET /webhooks`, `POST /webhooks { url, events[], description? }` (201, returns `secret` once, `whsec_...`), `PATCH /webhooks/:id { url?, events?, description?, isActive? }`, `POST /webhooks/:id/rotate-secret` (returns the new `secret`), `DELETE /webhooks/:id` (204).
- `POST /webhooks/:id/test` queues a `webhook.test` delivery (202, `deliveryId`). `GET /webhooks/:id/deliveries?limit&offset` is the log: `event, status (pending|retrying|delivered|failed), attempts, responseStatus, error, nextAttemptAt, deliveredAt`. `POST /webhooks/deliveries/:id/resend` sends the same data as a new delivery.
- Delivery: `POST` of `{ event, createdAt, data }` as JSON by the jobs runner, with headers `X-Progen-Event`, `X-Progen-Delivery` and `X-Progen-Signature: t=<unix>,v1=<hex>` where `v1` is HMAC-SHA256 of `"<t>.<raw body>"` with the secret. Success is any 2xx within 10 s; redirects are not followed. Up to 5 attempts, waiting 30 s, 1, 2 and 4 minutes; then `failed`.
- URLs must be https and must not resolve to loopback, private or link-local addresses (400 on create, checked again at each delivery). `WEBHOOK_ALLOW_PRIVATE=true` lifts both rules; it defaults to on outside production.

## Stock ledger
`stock_moves` is append-only in the database: an UPDATE or DELETE raises an error. Corrections are new reversing rows.

# v1.9 Channels phase 2 (live connectors)

Only Shopify (`shopify`) and WooCommerce (`woocommerce`) have a live adapter. Amazon, Flipkart and Meesho stay on CSV until the owner holds seller accounts. `GET /channels/connectors` adds `credentialFields [{key,label,secret}]` and `liveApi`.

## Credentials (permission `channels.manage`; write-only)
- `PUT /channels/:id/credentials { values: { <key>: string } }` seals the values (AES-256-GCM, `DATA_KEY`). Every field of the connector is required. The response is the channel with `credentials: [{key,label,secret,set}]`; values are never returned or logged. Sets status `not_connected`. 409 `NO_LIVE_API` for CSV-only providers. Shopify fields: `shopDomain` (`x.myshopify.com`), `accessToken`, `webhookSecret`, `locationId`. WooCommerce: `storeUrl` (https), `consumerKey`, `consumerSecret`, `webhookSecret`.
- `DELETE /channels/:id/credentials` removes them; status `not_connected`, stock push off.
- `POST /channels/:id/check` calls the provider with a cheap read. `{ ok, message, status }`. Status becomes `connected` only on success; `degraded` on a provider error after having been connected; the reason is in `statusReason`.
- `PATCH /channels/:id` also takes `pushStock`. Enabling a live channel again sets `not_connected` until a check passes.

## Inbound webhooks
- `POST /api/v1/webhooks/channels/:connectionId`, no sign-in, rate limited (120/min). The provider's signature is checked on the raw body (Shopify `X-Shopify-Hmac-Sha256`, WooCommerce `X-WC-Webhook-Signature`). 404 unknown, disabled or credential-less channel; 401 bad signature (counted in `webhookRejects`); 200 `{ ok: true }` when stored, also for a repeated event id. The event is stored in the inbox with `topic` set to the provider topic and processed by the `channel.event` job into a sales order.
- `GET /channels/inbox` returns only order rows (`topic = 'order'`).

## Pull, stock push, health
- A scheduled `channel.pull` job runs every 5 minutes for connected live channels; `POST /channels/:id/sync { what: "orders" | "stock" }` queues one now (202).
- Stock push: a trigger on `stock_moves` and `stock_reservations` queues `channel.stock` per company (one-minute bucket). Only changed quantities are sent: available minus `stockBuffer`, minimum 0, the least over a bundle's components. A listing needs `externalId` (Shopify inventory item id, WooCommerce product id).
- `GET /channels/:id/health` returns `status, statusReason, hasCredentials, pushStock, lastCheckAt, lastSuccessAt, lastError, lastErrorAt, webhookRejects, webhookPath, inbox {received,failed,dead}, unmapped, pushErrors, queuedJobs`.

## Tally export (`data.export`)
`GET /export/tally?from=YYYY-MM-DD&to=YYYY-MM-DD` returns Tally Prime import XML of journal vouchers (max 366 days). Voucher REMOTEID is the journal entry id. Debit amounts are negative with ISDEEMEDPOSITIVE Yes. Ledger names are the account names; create matching ledgers in Tally first.

# Wave 2: Warehouse depth

Module key `warehouse` (medical store, wholesale, electronics, retail, hardware, auto parts, manufacturer). Permissions: `warehouse.view`, `warehouse.pick` (receive, put away, pick, add batches), `warehouse.manage` (bins, rules, settings). Migration 030.

It is a sub-ledger (`wh_moves`, append-only) that says where inside a location the stock sits. It never writes `stock_moves`, so invoices, purchases, POS and manufacturing behave as before. Stock on hand that is not yet in a bin or batch is "unassigned"; a receipt places it. Without any warehouse call nothing changes.

| Method and path | Purpose |
|---|---|
| `GET/PUT/PATCH /warehouse/settings` | `{fefo, blockExpired, expiryWarnDays}` (defaults true, true, 90) |
| `GET/POST /warehouse/bins`, `PATCH /warehouse/bins/:id` | Bin `{locationId, code, name?, zone?, kind: storage/receiving/dispatch/quarantine, capacityQty?}`; list has `heldQty`. 409 `DUPLICATE_BIN`, `BIN_NOT_EMPTY` on switching off a bin that holds stock |
| `GET/PUT/PATCH /warehouse/items/:itemId` | Rule `{tracking: none/batch/serial, shelfLifeDays?}` |
| `GET/POST /warehouse/batches`, `PATCH /warehouse/batches/:id` | Batch `{itemId, batchNo, mfgDate?, expiryDate?, mrp?}`; list filters `itemId`, `q`, `expiringInDays`. 409 `DUPLICATE_BATCH` |
| `GET /warehouse/serials` | Filters `itemId`, `locationId`, `status` (in_stock/issued), `q` (serial number) |
| `GET /warehouse/stock?locationId=` | Stock by bin and batch; `itemId` adds `summary {onHand, tagged, unassigned}` |
| `GET /warehouse/moves` | Sub-ledger rows |
| `GET /warehouse/fefo?locationId&itemId&qty?` | Candidates in pick order, and the `plan` for `qty` |
| `GET /warehouse/expiry?days=&locationId=` | Batches with stock expiring within `days` (default from settings) or already expired |
| `POST /warehouse/receipts` | `{locationId, itemId, binId?, qty, batchId? or batch{batchNo, mfgDate?, expiryDate?, mrp?}, serialNos?, warrantyUntil?, note?}`. Expiry is worked out from `shelfLifeDays` when only the manufacture date is given. 409 `INSUFFICIENT_STOCK` when more than the unassigned stock, `BIN_FULL`, `BATCH_EXPIRED`, `DUPLICATE_SERIAL`. 400 when a batch or serials are required |
| `POST /warehouse/putaway` | `{locationId, itemId, fromBinId?, toBinId, batchId?, qty, serialNos?}`. 409 `INSUFFICIENT_BIN_STOCK`, `BIN_FULL`; expired stock may only go to a quarantine bin |
| `POST /warehouse/picks` | `{locationId, refType?, refId?, lines[{itemId, qty, binId?, batchId?, serialNos?}]}`. With no bin or batch it takes first-expiry-first-out (oldest batch first when `fefo` is off) and skips expired batches when `blockExpired`. Serial items need `serialNos` and mark them issued. Returns the allocations. 409 `INSUFFICIENT_BIN_STOCK`, `BATCH_EXPIRED`, `SERIAL_NOT_AVAILABLE`. Returns `refId` (given, or made) that names the pick list. Picking alone does not post the sale |

Item rule also has `defaultBinId` (bin that receives purchased stock). Migration 038.

**Document hook.** With the `warehouse` module on, invoice, POS and purchase lines may carry `binId`, `batchId` or `batchNo` + `expiry`, `serials[]`. After the document posts: a purchase line of a tracked item (rule not `none`, or a default bin, or line fields) is received into the line's bin or the item's default bin (only if it is in the purchase location), creating the batch from `batchNo`/`expiry`; a sale line takes stock first-expiry-first from bins (or the named bin, batch, serials) and writes `wh_moves` with `refType` invoice/purchase. Sales take only what bins cover when no bin or batch is named; the rest stays unassigned. Serial items are issued only when `serials` are given. Items with no rule and no line fields are untouched. Errors are those of receipts and picks (a batch-tracked purchase line without a batch is 400; `INSUFFICIENT_BIN_STOCK` and `BATCH_EXPIRED` for named bins and batches). Cancelling a document does not put bin stock back; use a receipt.

`POST /warehouse/picks/:refId/invoice` `{partyId, invoiceDate?, notes?, lines?[{itemId, rate?, discountPct?}]}` bills the pick list `refId` through the invoice service (needs `invoices.create`); quantities are what was picked, and bins are not picked again. 201 `{pickRefId, invoice}`. 404 unknown list, 409 `PICK_ALREADY_BILLED`.


# Fixed-amount discounts

- Invoice lines (`POST /invoices` and `/invoices/preview`) take an optional `discountAmount` (rupees, before GST) instead of `discountPct`. Sending both is 400. An amount above the line value is 400 (`lines.N.discountAmount`). The amount drives the tax exactly; the line's stored `discountPct` is the amount as a percent (2 decimals), for display only. Callers that send `discountPct` behave as before.
- Restaurant `POST /restaurant/orders/:id/print-bill` with `discountAmount` keeps the amount on the order (`discountAmount`, migration 036). The bill splits it over the food lines pro rata in paise, the leftover paise on the largest line, and settle posts those line amounts, so the printed bill and the invoice show the same discount. The bill JSON has `discountAmount` (null when a percent was used) and `discountPct` (display percent). Reopening the bill clears it.

# Wave 2: Education exams and report cards (module `education`, migration 040)

Permissions: `education.exams` (enter marks and read results for the classes where you are the teacher), `education.exams_manage` (subjects, terms, papers, grading scale, publish, reopen, all classes). `education.manage` also allows everything. Teachers get `education.exams`; the Principal and Centre Manager get both.

| Method and path | Purpose |
|---|---|
| `GET /education/subjects?classId`, `POST`, `PATCH /education/subjects/:id` | `{classId, name, code, seq}`; patch also `isActive`. 409 `DUPLICATE_SUBJECT`. |
| `POST /education/classes/:id/subjects/copy` | `{fromClassId}` adds the other class's missing subjects. `{added}`. |
| `GET /education/exam-terms?yearId`, `POST`, `GET, PATCH /education/exam-terms/:id` | Term `{yearId, name, seq, startDate, endDate}`; list rows add `papers`, `classes`, `status` (`draft`, `published`), `published`. `GET :id` adds `classes[{id,label,students,papers,entered,expected,mine}]` (teachers see their own). 409 `DUPLICATE_TERM`; PATCH on a published term 409 `TERM_PUBLISHED`. |
| `GET /education/exam-terms/:id/papers?classId`, `PUT` or `POST` same path | `{classId, papers[{subjectId, maxMarks, passMarks?, examDate?}]}` replaces the class's papers. 409 `PAPER_HAS_MARKS`, `MARKS_ABOVE_MAX`, `TERM_PUBLISHED`. |
| `GET /education/exam-terms/:id/classes/:classId/marks?subjectId` | Grid `{term, label, locked, papers[], students[{studentId,name,rollNo,marks{paperId: {marks, absent} or null}}]}`; `subjectId` narrows to one paper. |
| `PUT` or `POST` same path | `{entries[{paperId, studentId, marks, absent}]}`. `absent: true` stores no marks. `marks: null` and not absent clears the cell. 400 above the paper maximum or both set; 409 `TERM_PUBLISHED`. Returns the grid. |
| `GET .../classes/:classId/results` | Per student `subjects[{subject,maxMarks,marks,absent,grade,passed}]`, `total`, `maxTotal`, `percentage`, `grade`, `result` (`pass`, `fail`, `null` until complete), `rank`. Ranks go to students whose marks are all in; equal totals share a rank. A paper passes at its `passMarks`, else at the pass percent. |
| `GET .../classes/:classId/report-cards`, `GET /education/exam-terms/:id/students/:studentId/report-card` | Report card data: school, term, year, class, student, subjects, totals, grade, rank, `classSize`, `attendance{marked,present}`, `grades` (the scale), `draft` (true until published). The PDF is built in the app. |
| `POST /education/exam-terms/:id/publish` | Needs papers and every active student's mark (or absent) in every paper. 409 `MARKS_INCOMPLETE` lists the classes. Locks marks and papers. |
| `POST /education/exam-terms/:id/reopen` | Unlocks a published term (audited). 409 `NOT_PUBLISHED`. |
| `GET, PUT, PATCH /education/exam-settings` | `{grades[{grade,minPct}], passPercent}`. Default A1 91, A2 81, B1 71, B2 61, C1 51, C2 41, D 33, E 0, pass 33. The lowest grade must start at 0. `isDefault` is true until saved. |

# Reverse charge, POS series, exact discount credits (migration 041)

- `POST /invoices`, `/invoices/preview`: optional `reverseCharge` (boolean). Needs a customer GSTIN, else 400. No GST is collected: `cgst/sgst/igst/taxTotal` are 0, `total` is the taxable value rounded, and `rcmTax` holds the tax the recipient pays. Responses carry `reverseCharge` and `rcmTax`. The PDF prints "Tax payable on reverse charge: Yes" with `rcmTax`. Credit notes on such an invoice carry no tax.
- `GET /gst/gstr1`: B2B and CDNR rows carry `reverseCharge`; the GSTN JSON sets `rchrg` to `Y`.
- Legal `POST /legal/matters/:id/bill` with `reverseCharge: true` uses this flag (fee line at 18%, tax moved to `rcmTax`); the old 0% reverse-charge item and note are gone.
- POS bills use their own series (`doc_series` key `pos_invoice`), numbered `POS/26-27/00001`. `GET/PUT/PATCH /pos/settings` add `invoicePrefix` (1 to 8 letters, digits or hyphens, upper-cased, default `POS`). Normal invoices keep `INV/`.
- A line with a fixed `discountAmount` stores it; a partial credit note takes the discount pro-rata in paise by quantity, and the last of the quantity takes the remainder, so the credits add up to the invoice exactly.

## Exams: remarks and co-scholastic grades (migration 042)

| Method and path | Purpose |
|---|---|
| `GET, PUT or POST /education/classes/:id/co-areas` | `{areas[name]}`; replaces the class's areas (manage). Without any set, the defaults apply: Work education, Art education, Health and physical education, Discipline. |
| `GET .../exam-terms/:id/classes/:classId/remarks` | `{locked, areas[], coGrades[{grade,label}], students[{studentId,name,rollNo,remark,coScholastic[{area,grade}]}]}`. Same access as marks (own class, or exams manage). |
| `PUT or POST` same path | `{entries[{studentId, remark, areas{area: grade or null}}]}`. Empty `remark` or a null grade clears it. 400 unknown area or grade; 409 `TERM_PUBLISHED`. |
| `exam-settings` | Also `coGrades[{grade,label}]` (default A Very good, B Good, C Needs work; 2 to 6 grades). |

Results and report-card data now include `remark` and `coScholastic[{area,grade}]` for each student.
