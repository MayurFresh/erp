# Common brief for every module agent

Repo root: this repository. Read `CLAUDE.md` first and follow it.

## Save tokens
- Budget: aim to finish under 150k tokens. Read each file once, only the parts you need. Run each test file once after a batch of changes, then only the failing tests until they pass. Don't re-run suites you didn't touch.
- Read only what you need. Use grep and `sed -n a,bp` on parts of big files. Don't cat whole large files or dump long command output; pipe through `tail`/`head`.
- Model your work on one existing module instead of surveying many. Good models: backend `src/modules/units.ts` + `bookings.ts` (real estate), Flutter `lib/features/realestate/`, tests `backend/test/realestate.test.ts`.
- Final report under 250 words.

## Order of work (CLAUDE.md release order)
1. Add a section to `docs/API.md` at the end: `# Wave 2: <your module>` with the endpoints, bodies and errors. Short.
2. Migration with your assigned number. Write it complete and valid in one go: RLS on every new table the same way earlier migrations do it (tenant_id + policy + grants; copy the pattern from `020_updated_at_ops.sql` or `012_commerce.sql`), `updated_at` for editable rows.
3. Backend module, registered in `src/app.ts`, table types in `src/db/schema.ts`, permissions in `src/auth/permissions.ts`, module key in `MODULES` in `src/lib/business-types.ts` and in the `modules` of the business types that need it. Add sensible role templates or extend existing ones for those types so their staff get the new permissions.
4. Vitest file `backend/test/<name>.test.ts`. Run it with your assigned database:
   `cd backend && TEST_DATABASE_URL=$(grep '^TEST_DATABASE_URL=' .env | cut -d= -f2- | sed 's/progen_test$/<your_db>/') npx vitest run test/<name>.test.ts`
   Never print .env values.
5. Flutter screens under `lib/features/<name>/`, routes and menu entries wired the way real estate is (find it with grep in `lib/features/shell/` and the router), gated by your module key and permissions, permissions added to `lib/core/permissions.dart`. Widget tests under `test/<name>/` using `test/support/app_harness.dart` and `test/support/fake_backend.dart`.
6. Checks: `npx tsc --noEmit -p .` in backend, `flutter analyze lib/features/<name> test/<name>` plus any shared file you edited, `flutter test test/<name>`.

## Reuse, don't rebuild
- Sales posting: create bills through the existing invoice service in `src/modules/invoices.ts` (find the function that creates and posts an invoice so GST, stock moves, ledger and numbering stay correct). Receipts through the payments service. Don't write ledger rows yourself.
- Number series `src/lib/series.ts`, stale edits `src/lib/stale.ts` (`expectedUpdatedAt`, 409 STALE_EDIT), audit `writeAudit`, paging `src/lib/paging.ts`, validation `src/lib/validate.ts`, errors `src/lib/errors.ts`. Idempotency is automatic for POSTs.
- Flutter: `ApiClient`, `PageHeader`, `AdaptiveDataList`, `FormRow`, `showFormDialog`, `DirtyDialogGuard`, `PickerField`, money formatting in `lib/core/money.dart`, PDFs with `lib/core/pdf_kit.dart`. Sector words: `context.w(...)` only where those widgets don't already apply it.
- Design rules in `docs/design/README.md`. Works at 320px. No emoji, purple gradients, glassmorphism or sparkle icons. Plain words.

## Four agents work in this tree at the same time
- Only create files in your own area. In shared files (`app.ts`, `schema.ts`, `permissions.ts`, `business-types.ts`, `docs/API.md`, `lib/core/permissions.dart`, router, `nav.dart`, `fake_backend.dart`) make small additive edits; re-read the exact spot just before each edit; never reorder, reformat or revert lines you didn't write.
- Never run git commands that change files (checkout, stash, reset, clean), never commit, never run `dart format` or `flutter pub` on the whole repo (format only your own files).
- Errors in files you don't own come from another agent mid-edit: don't fix them; wait a minute and retry, and mention them in your report if they persist. A failing migration that isn't yours: same.
- Don't start servers, browsers or touch the phone. Don't run the full `flutter test` or full vitest.

## Sample data
Export `seed<Name>Demo(tx, { tenantId, companyId, userId })` from `backend/src/db/seed-<name>.ts` that adds a small realistic Indian sample set for your module (and the items or parties it needs). Don't call it from `seed.ts`; the lead wires it into demo accounts later.

## Report
Files added, shared files changed, endpoints, permissions, module key and which business types got it, test counts (backend and Flutter), and known gaps.
