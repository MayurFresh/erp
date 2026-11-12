# Notification provider outage

Email (SMTP) and WhatsApp (Cloud API) messages go through the `notification_outbox` table and the job `notification.send`. Code: `backend/src/lib/notify.ts`. In-app notifications do not depend on the providers.

## Confirm

1. `GET /api/v1/notifications/outbox` (or the outbox screen) shows each message with its status.
2. Check which driver is on: `EMAIL_DRIVER` and `WHATSAPP_DRIVER` are `log` or `smtp` / `cloud_api`. With `log`, nothing is sent by design.
3. Look in the API log for the provider error. The WhatsApp call times out after 15 seconds.

## Respond

| Cause | Action |
| --- | --- |
| SMTP down or credentials wrong | Fix `SMTP_URL` / `EMAIL_FROM`, restart the API |
| WhatsApp token expired | Replace `WHATSAPP_TOKEN` (and check `WHATSAPP_PHONE_ID`), restart |
| Provider outage | Wait. Jobs retry three times (30 s, 60 s, 120 s). After that they are `failed` |

After the provider is back, retry failed `notification.send` jobs with `POST /api/v1/jobs/:id/retry` (jobs.md). Old reminders may be stale; payment reminders send at most once a day (`platform.test.ts :: sends a payment reminder once a day`), so a late retry does not double up.

Password reset and invite emails use the same path. If email is down, users cannot get reset links. Use locked-out-user.md for an admin-assisted route.
