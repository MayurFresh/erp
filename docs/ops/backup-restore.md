# Backup and restore drill

Runbook with the steps for a real incident: [operations/runbooks/backup-restore.md](../operations/runbooks/backup-restore.md). This page is the drill and its evidence.

## Run the drill

```sh
cd backend
scripts/backup-drill.sh            # source = the database in DATABASE_URL
scripts/backup-drill.sh progen_test
```

Needs `DATABASE_ADMIN_URL` (from `backend/.env` or the environment) and `pg_dump`, `pg_restore`, `psql` on PATH. The script:

1. dumps the source database in custom format,
2. restores it into a new scratch database named `<source>_drill_<timestamp>`,
3. counts rows in every public table in both, and prints PASS or the differing tables (exit code 1),
4. drops the scratch database.

It never changes the source database. Uploads under `UPLOAD_DIR` are files, not database rows: back them up separately (volume snapshot) and restore them to the same path.

## Result

| Date | Source | Tables | Rows | Backup | Restore | Result |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-12 | local dev database `progen` | 114 | 3,386 | 1 s | 1 s | Pass, counts identical |

This is a small development database on one machine. It proves the procedure and the script, not recovery time for production data. Before launch: run it against a production-sized copy, record the timings, and repeat the restore on the hosting provider's managed backups (point-in-time restore).

## Tracing

OpenTelemetry tracing is off by default. To turn it on, install the packages in the deployment image (`npm install --no-save @opentelemetry/api @opentelemetry/sdk-trace-node @opentelemetry/exporter-trace-otlp-http`) and set `OTEL_ENABLED=true` and `OTEL_EXPORTER_OTLP_ENDPOINT`. One span per request, named `METHOD /route`. Database spans are not traced yet. The packages are not in `package.json` because `@opentelemetry/sdk-trace-node` and vitest disagree on the `@opentelemetry/api` version range.

## Load test

`backend/load/k6-smoke.js`: 10 virtual users for about 70 seconds, reads the dashboard and the main lists. Thresholds: under 1% failed requests, p95 under 500 ms, p99 under 1.5 s. Run `k6 run -e BASE_URL=http://localhost:8080/api/v1 backend/load/k6-smoke.js` against a test database. k6 is not installed on the build machine, so no result is recorded yet.
