# Incident response

No on-call rota, alerting or status page exists yet. This is the minimum procedure until they do.

## Severity

| Level | Examples | Response |
| --- | --- | --- |
| SEV1 | Cross-tenant data seen, forged or duplicate financial posting, data loss, leaked secret, authorization bypass | Start now. Owner informed within the hour |
| SEV2 | API down, database down, jobs not running, GSP failing for all | Start within the working day |
| SEV3 | One user or one screen affected | Normal queue |

These SEV1 cases match the release blockers in master plan section 12.

## Steps

1. Record time, who found it, what was seen. Keep one running log.
2. Contain.
   - Suspected leak or abuse: set `CORS_ORIGINS` tight, deactivate the user or tenant users, revoke sessions, or stop the API (start-stop.md).
   - Leaked secret: rotate it (rotate-secrets.md).
   - Bad data being written: stop the API first, then investigate.
3. Preserve evidence. Copy API logs and the relevant `audit_log` and `jobs` rows (the audit table cannot be edited by the app). Take a database backup before any repair (backup-restore.md).
4. Diagnose with the audit log (`GET /api/v1/audit` or SQL on `audit_log` by `entity`, `user_id`, `created_at`).
5. Fix forward. Never edit posted ledger rows by hand. Correct with a reversing journal or a cancel document through the app, so the audit trail stays whole.
6. Verify: run the affected test file (`npx vitest run test/<file>.test.ts`), then the full suite, and check the books balance.
7. Tell affected customers when personal or financial data was involved. The owner decides the wording and any legal notice.
8. Write up within 3 working days: timeline, cause, fix, what test or control was missing. Add a row to `docs/qa/defect-register.md` with a regression test.

## Contacts

Fill in before launch: owner, database administrator, hosting provider support, GSP support, chartered accountant. Not recorded in the repo.
