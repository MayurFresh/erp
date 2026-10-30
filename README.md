# Progen ERP

One ERP for Indian businesses: GST billing, inventory, multi-site operations and role-based access, with Construction, E-commerce and Organisation packs to follow (see the [functionality spec](docs/Progen_ERP_Functionality_Specification.pdf)).

```
progen_erp/
├── backend/        Node.js + TypeScript API (Fastify, PostgreSQL)
├── lib/            Flutter app — one codebase for web, Android, iOS and desktop
├── test/           Flutter tests
└── docs/API.md     API contract shared by the app and the backend
```

Web and mobile are the same Flutter app, so both always show the same data from the same API.

## What works today

- Sign up a business, sign in, automatic session refresh, logout.
- Companies, branches, sites, warehouses and departments.
- Roles with permissions and **location scope** (a site supervisor sees only their site); cost prices hidden from roles without `items.view_cost`.
- Items with HSN and GST rate; customers and vendors with GSTIN validation.
- Stock ledger per location with adjustments and low-stock alerts.
- GST invoices: CGST/SGST or IGST by place of supply, paise-exact maths, rupee round-off, gapless `INV/26-27/00001` numbering, stock deduction, cancellation that restores stock.
- **Purchases** (bills with input GST), **receipts and payments** with allocation to invoices/bills and advances, **credit notes** (sales returns with restocking), **stock transfers** (in transit → received), **expenses** with GST.
- **Double-entry accounting**: every document posts a balanced journal automatically (the database refuses unbalanced entries); stock is valued at weighted-average cost; chart of accounts, account and party ledgers, day book, manual journals.
- **Reports**: trial balance, profit & loss, balance sheet, sales and purchase registers, GST summary (rate-wise, B2B/B2C, HSN, input credit, net payable), stock valuation, receivable/payable ageing.
- Company profile with bank and UPI details, role editor, user editing and password resets, dashboard, audit log.
- **Construction pack**:
  - Projects tied to sites, with a BOQ (paste from Excel), and progress weighted by BOQ amount.
  - Material indents (raise → approve → fulfil by transfer or purchase, edit and resubmit after rejection) and material issues to site, booked at average cost.
  - Daily progress reports with photos, approval and rejection.
  - Workers and labour contractors, daily attendance with overtime (OT), and wage sheets (OT at 2×, advance recovery, payment posted to the books).
  - A project cost sheet: material + labour + expenses.
- Every customer's data is isolated by PostgreSQL row-level security, not just by application code.

## Requirements

| Tool | Version | Windows | macOS |
| --- | --- | --- | --- |
| Node.js | 22.18 or newer (24 recommended) | [nodejs.org](https://nodejs.org) installer | `brew install node` |
| PostgreSQL | 15 or newer | [postgresql.org](https://www.postgresql.org/download/windows/) installer (remember the `postgres` password) | `brew install postgresql@16` |
| Flutter | 3.44 or newer | [docs.flutter.dev](https://docs.flutter.dev/get-started/install/windows) | [docs.flutter.dev](https://docs.flutter.dev/get-started/install/macos) |

## 1. Start the backend

```bash
cd backend
npm install
cp .env.example .env          # Windows: copy .env.example .env
```

Edit `backend/.env`:

- `DATABASE_ADMIN_URL`: your PostgreSQL superuser, e.g. `postgres://postgres:<your-password>@localhost:5432/postgres`.
- `JWT_SECRET`: any random string of 32+ characters.

Then:

```bash
npm run db:setup    # creates the progen_app role and the progen + progen_test databases
npm run db:seed     # demo company, items, stock, invoices and users
npm run dev         # API on http://localhost:8080 (restarts on file changes)
```

Check it: open <http://localhost:8080/health>.

After pulling new code, run `npm run db:migrate` to apply new database migrations. Existing data is kept. To reload the demo data from scratch, drop the `progen` database, then run `npm run db:setup` and `npm run db:seed` again.

## 2. Run the app

```bash
flutter pub get
flutter run -d chrome                     # web
flutter run -d emulator-5554              # Android emulator (uses http://10.0.2.2:8080 automatically)
```

On a **real phone** on the same Wi-Fi, point the app at your computer's IP address:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.20:8080/api/v1
```

(Find the IP with `ipconfig` on Windows or `ipconfig getifaddr en0` on macOS, and allow port 8080 through the firewall.)

iPhone builds need a Mac with Xcode.

## Demo logins

All use password `Demo@1234`:

| Email | What you'll see |
| --- | --- |
| `owner@demo.in` | Everything |
| `accountant@demo.in` | Invoices, parties, stock values and audit for all locations |
| `sales@demo.in` | Invoices and customers for Central Warehouse only, no cost prices |
| `supervisor@demo.in` | Stock, indents, DPRs and attendance for Site A — Tower 1 only |
| `pm@demo.in` | Project Manager: projects, BOQ, approvals, labour and wage sheets |

## Tests

```bash
cd backend && npm test && npm run typecheck   # API: GST, accounting, construction, roles, tenant isolation
flutter analyze && flutter test               # app
# End-to-end check that the app's API client works against the running backend:
PROGEN_API=http://localhost:8080/api/v1 flutter test test/live_api_test.dart
```

On Windows PowerShell, set the variable first: `$env:PROGEN_API="http://localhost:8080/api/v1"; flutter test test/live_api_test.dart`.

## Production notes

- Set `CORS_ORIGINS` to your web app's domain and use a long random `JWT_SECRET`.
- Run the API with `npm start` behind HTTPS (for example Nginx or a cloud load balancer).
- Build the web app with `flutter build web --dart-define=API_BASE_URL=https://api.yourdomain.in/api/v1` and serve `build/web`.
- Remove `usesCleartextTraffic` from the Android manifest once the API is on HTTPS.
