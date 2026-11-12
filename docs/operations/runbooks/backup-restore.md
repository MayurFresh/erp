# Backup and restore

Status: drill not yet done. These commands are standard PostgreSQL tools and have not been rehearsed against Progen data. A restore drill is a release blocker (`docs/release/production-readiness-checklist.md`, gate 5).

## What to back up

| Item | How |
| --- | --- |
| PostgreSQL database | `pg_dump` (below) |
| Uploaded files | Copy the `UPLOAD_DIR` folder. Files are stored on disk, not in the database, so they need their own backup |
| Secrets: `JWT_SECRET`, `DATA_KEY` | Store in a secrets manager. Without the same `DATA_KEY`, sealed TOTP, SSO and GSP secrets cannot be read after a restore |

## Backup

Use the admin (owner) connection, not the app role, so every row is included:

```
pg_dump --format=custom --no-owner --file progen-$(date +%F).dump "$OWNER_DATABASE_URL"
```

`$OWNER_DATABASE_URL` is the admin credentials pointing at the Progen database (not the `postgres` database). Encrypt the file before it leaves the host. Keep daily copies for at least 14 days and test one regularly.

## Restore

1. Stop the API (start-stop.md).
2. Make an empty database and make sure the app role exists: `npm run db:setup` creates the role and databases if missing.
3. Restore:

```
pg_restore --no-owner --dbname "$OWNER_NEW_DATABASE_URL" --exit-on-error progen-YYYY-MM-DD.dump
```

4. Re-grant the app role: `npm run db:migrate` (applies nothing new but runs the grants).
5. Restore the `UPLOAD_DIR` folder from the same point in time.
6. Set `DATABASE_URL` to the restored database and start the API.
7. Verify: sign in, open a recent invoice, open an attachment, run the trial balance, check `select count(*) from schema_migrations`.

## Drill checklist (to do)

- Time the restore and write the number here.
- Confirm RLS still isolates tenants on the restored copy.
- Confirm an uploaded file opens.
- Confirm 2FA sign-in works (proves `DATA_KEY` matches).
- Record who ran it and the date.
