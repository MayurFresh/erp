# Rotating secrets

## DATA_KEY

`DATA_KEY` (32 bytes, base64) seals TOTP secrets, SSO client secrets and GSP credentials with AES-256-GCM (`backend/src/lib/crypto.ts`).

Warning: there is no re-seal tool and no key id. Changing `DATA_KEY` makes every existing sealed value unreadable. After a change:

- Users with 2FA cannot pass the code step. An admin must reset their 2FA (`POST /api/v1/users/:id/2fa/reset`) and they enrol again.
- SSO client secrets must be re-entered per provider.
- GSP credentials must be re-entered.

If `DATA_KEY` is not set, the key is derived from `JWT_SECRET` (the API logs a warning at start). Then changing `JWT_SECRET` has the same effect. With `NODE_ENV=production` the API refuses to start without `DATA_KEY`, so the two can be rotated separately.

Procedure:

1. Announce a maintenance window.
2. Generate a new key: `node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"`. Store it in the secrets manager only.
3. Set the new `DATA_KEY`, restart the API.
4. Reset 2FA for affected users, re-enter SSO and GSP secrets.
5. Keep the old key until you have confirmed nothing needs it, in case you must roll back. Rolling back is only possible while the old key is kept.

## JWT_SECRET

At least 32 characters. Changing it:

- Signs out every user at once, because all access and refresh tokens fail verification. There is one key and no overlap period.
- If `DATA_KEY` is unset, also breaks sealed secrets (see above).

Procedure: set `DATA_KEY` first if it is unset (with the key derived from the old `JWT_SECRET` you cannot recover the sealed values after a change, so re-enter them). Pick a quiet time, set the new `JWT_SECRET`, restart, tell users to sign in again.

## Other secrets

| Secret | Where | Notes |
| --- | --- | --- |
| Database passwords | `DATABASE_URL`, `DATABASE_ADMIN_URL` | `alter role ... password ...`, update env, restart |
| `SMTP_URL`, `WHATSAPP_TOKEN` | env | Restart to apply |
| GSP and SSO credentials | Stored sealed in the database | Re-enter through the app |

If a secret may have leaked, treat it as an incident (incident-response.md): rotate first, then investigate.
