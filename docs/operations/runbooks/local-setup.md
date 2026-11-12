# Local setup

Needs Node 22.18 or newer (`engines` in `backend/package.json`), PostgreSQL 16 and Flutter.

1. Create `backend/.env` from `backend/.env.example`. Set `DATABASE_URL` (app role), `DATABASE_ADMIN_URL` (a superuser or owner), `TEST_DATABASE_URL` and a `JWT_SECRET` of at least 32 characters. `.env` is git-ignored; do not commit it.
2. Install and create the databases:

```
cd backend
npm install
npm run db:setup
```

`db:setup` creates the app role (no superuser, no bypass of RLS) and the app and test databases, then applies every migration in `backend/src/db/migrations/`.

3. Optional demo data: `npm run db:seed` (see migrate-and-seed.md).
4. Check: `npm run typecheck` and `npm test`.
5. Start the API: `npm run dev` (watch mode) or `npm start`. Health check: `curl http://localhost:8080/health`.
6. Client: from the repo root, `flutter pub get`, then `flutter run -d chrome` or `flutter test`.

Two agents on one machine need separate test databases (different `TEST_DATABASE_URL` names), because every test file truncates the tenant tables. See `docs/qa/test-strategy.md`.

Default delivery drivers are `EMAIL_DRIVER=log` and `WHATSAPP_DRIVER=log`: messages are written to the log, not sent. Reset links then appear in the API log.
