# History: state at the 2026-11-04 pause (v1.8.2)

Moved out of CLAUDE.md to keep it small. Open only when a v1.8.2 detail is needed.


Done and uncommitted: v1.8 Commerce, v1.8.1 defect fixes D-01 to D-10, v1.8.2 owner review release.

### v1.8.2: what the owner asked for and where it stands

| Review point | Status |
|---|---|
| Too much padding on dashboard and forms | Done. Tighter tokens, `FormRow`, sticky save bars, redesigned dashboard. |
| Export PDF looks poor | Done. New PDF kit. Invoice, credit note, receipt, PO, quotation, order, statement and report PDFs rewritten and checked page by page. |
| Double taps, edit and loading edge cases | Done for the audited cases in `docs/qa/robustness-audit.md`. See gaps below. |
| Looks plain | Done. New look, icons, cards and charts. |
| Charts and a client-ready report | Done. `/insights`, dashboard charts, and `/reports/client-report` as an A4 report or slides PDF. |
| Roles for every business sector | Partly done. 52 business types with their own roles, menus, words, quick actions and plans. Dedicated daily-use modules are not built. |

### Final checks on 2026-11-04

All run after the last code change unless noted.

- `flutter analyze`: no issues.
- `flutter test`: 462 passed, 22 skipped. The skips are the live tests.
- `tsc`: clean.
- Backend `test/business.test.ts`: 10 of 10 passed.
- Full backend vitest: 219 passed on the last full run, before the one-word farm change in `business-types.ts`. Not re-run in full since.
- Live tests: 22 of 22 passed before the final word and field height fixes. Not re-run since.
- `flutter build web --release`: built. API `/health` and the web server on 5050 both answered 200.

### Pending for v1.8.2

- Open the rebuilt app as a hospital company and confirm the last word fixes on screen. They are covered by widget tests only.
- View these unreviewed screenshots of the earlier build: company profile at 390px, and delivery status text.
- Re-run the live tests. They last passed 22 of 22 before the final word and field height fixes.
- Add a test that a short trend draws `GroupedBarChart`. Build it with `Analytics.fromJson(...)` as in `test/insights/insights_rules_test.dart`.
- Rebuild the APK and test in-app sign-in on the phone. Check the phone's foreground app first.
- Click through the unsaved-changes prompt and the 5 second skip after save by hand.
- Remove test tenants after the last live run. Tenant names match `^Live (Test|Construction|Admin|Books) \d+$`, including the temporary hospital company. Look at the rows first, then delete in one transaction with `SET LOCAL session_replication_role='replica'`, and confirm Demo Builders & Traders is untouched.

### Known gaps

- Account dialog has no Reload action on a stale edit.
- Client-side duplicate line warnings are not done.
- There is no VAT engine. Non-Indian companies get one rate split as CGST and SGST against state 97, and totals round to the nearest rupee.
- Plan table and user limits are defaults the owner may change. Nothing is billed. Only `solo` restricts modules. `general` turns every module on.
- `AgeingBuckets` is duplicated in `analytics_models.dart` and `report_models.dart`.
- There is no `Perm.projectsView`.
- Dark mode was viewed at 1440px only.
- `FormRow` caps two-field rows at 520px each, which leaves a small gap on the right on wide screens. This is deliberate.
- Statutory figures are unverified and need a CA or current-law check before real filing.

