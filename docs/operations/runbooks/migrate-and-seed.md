# Migrate and seed

## Apply migrations

```
cd backend
npm run db:migrate
```

- Runs `backend/src/db/migrate.ts` as the admin URL. Applies files from `backend/src/db/migrations/` that are not in `schema_migrations`, in name order, one transaction per file.
- Then grants the app role table and sequence access. Safe to run again.
- Migrations are forward only. There is no down script. To undo a change, write a new migration.
- Before a production migration: take a backup (backup-restore.md) and run the migration on a restored copy first.

## Seed demo data

```
npm run db:seed
```

- Goes through the real API handlers, so seeded data obeys business rules.
- If owner@demo.in can already sign in, it prints "Demo data already exists" and does nothing.
- Creates demo users with a fixed demo password. Never run it against production.

## Full reseed (development only)

There is no reset flag. To start clean, drop and rebuild the development database:

1. Stop the API (start-stop.md).
2. Drop and recreate the app database as the admin user, for example `psql "$DATABASE_ADMIN_URL" -c 'drop database <app_db>'`, using the database name from `DATABASE_URL`.
3. `npm run db:setup`
4. `npm run db:seed`
5. Start the API.

Do not drop the test database this way; the tests truncate it themselves.
Confirm the target name twice before step 2. Uploaded files in `UPLOAD_DIR` are not removed by a drop; delete them by hand if you want a clean state.
