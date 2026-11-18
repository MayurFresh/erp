# Runbooks

Short, exact procedures for running OneMatrix. Commands come from `backend/package.json`. Run backend commands in `backend/`. Environment variables are named in `backend/src/config.ts`; set them in `backend/.env` or the host environment. Never paste their values into tickets or chat.

Status on 2026-11-03: there is no Dockerfile, no CI and no hosted environment in the repo. These runbooks describe a single Node process plus PostgreSQL 16. Nothing here has been drilled in production.

| Runbook | Use when |
| --- | --- |
| [local-setup.md](local-setup.md) | New machine or new agent |
| [migrate-and-seed.md](migrate-and-seed.md) | Schema change, demo data, full reseed |
| [start-stop.md](start-stop.md) | Run, stop, check the API |
| [backup-restore.md](backup-restore.md) | Backups and recovery (drill not yet done) |
| [jobs.md](jobs.md) | Jobs stuck or failing |
| [gsp-outage.md](gsp-outage.md) | GST provider down or failing |
| [notification-outage.md](notification-outage.md) | Email or WhatsApp not delivered |
| [rotate-secrets.md](rotate-secrets.md) | Rotate JWT secret or DATA_KEY |
| [locked-out-user.md](locked-out-user.md) | User cannot sign in |
| [incident-response.md](incident-response.md) | Something is wrong in production |

Environment variable names: PORT, HOST, DATABASE_URL, DATABASE_ADMIN_URL, TEST_DATABASE_URL, JWT_SECRET, ACCESS_TOKEN_TTL_SECONDS, REFRESH_TOKEN_TTL_DAYS, CORS_ORIGINS, LOG_LEVEL, UPLOAD_DIR, APP_URL, PUBLIC_API_URL, DATA_KEY, EMAIL_DRIVER, SMTP_URL, EMAIL_FROM, WHATSAPP_DRIVER, WHATSAPP_TOKEN, WHATSAPP_PHONE_ID, WHATSAPP_API_VERSION, JOBS_WORKER.

Known gaps that affect operations: uploads need their own backup and a malware scanner (D-08), and the rate-limit store is per process (D-02). See `docs/qa/defect-register.md`.
