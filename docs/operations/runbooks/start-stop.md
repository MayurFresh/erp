# Start and stop the API

## Start

```
cd backend
npm start
```

Runs `node --env-file-if-exists=.env src/server.ts`. Listens on `HOST:PORT` (default 0.0.0.0:8080). The job worker runs inside the same process unless `JOBS_WORKER=false`.

For several API replicas, run the worker in one of them only (`JOBS_WORKER=false` on the rest). Claiming uses `for update skip locked`, so extra workers are safe, but they share the load.

## Check

- `curl http://localhost:8080/health` returns `{"status":"ok","db":"ok", ...}`, or 503 with `"db":"down"` if the database does not answer within 2 seconds.
- Real check: sign in through `/api/v1/auth/login`, or open `/api/v1/me` with a token.
- Logs are structured JSON at `LOG_LEVEL` (default info). Startup logs a warning when `DATA_KEY` is not set.

## Stop

Send SIGTERM or SIGINT (Ctrl+C). `backend/src/server.ts` then stops the worker (waits for the running batch), closes the HTTP server and the database pool, and exits 0.

If this takes more than 15 seconds (usually a hung job), the process exits with code 1. A job cut off this way stops sending heartbeats and is re-queued after 10 minutes (jobs.md).

## Common start failures

| Message | Cause |
| --- | --- |
| `DATABASE_URL is required` or `JWT_SECRET must be at least 32 characters` | Missing or short env value (`backend/src/config.ts`) |
| `DATA_KEY must be 32 bytes, base64-encoded` | Bad `DATA_KEY` |
| Connection refused | PostgreSQL not running or wrong URL |
| Permission denied for table | Migrations not applied with grants; run `npm run db:migrate` |
