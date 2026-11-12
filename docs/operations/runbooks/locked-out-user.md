# Restoring a locked-out user

Lockout rules: 10 failed passwords lock the account for 15 minutes (`backend/src/modules/auth.ts:29`). 5 wrong 2FA codes end the 2FA step. Both are covered by `platform.test.ts`.

## Find the cause

| Symptom | Cause |
| --- | --- |
| `ACCOUNT_LOCKED` (HTTP 423) | Too many failed passwords |
| `MFA_INVALID` | Wrong or reused 2FA code; clock drift on the phone |
| `SSO_REQUIRED` | The company enforces SSO for the email domain |
| `SESSION_REVOKED` or token errors | Session ended or user deactivated |
| Reset email not arriving | Notification outage (notification-outage.md) |

## Fix, using the app (preferred)

An admin with `users.manage` can:

1. Unlock: `POST /api/v1/users/:id/unlock` (Users screen, Unlock).
2. Reset 2FA: `POST /api/v1/users/:id/2fa/reset`. The user enrols again at next sign-in.
3. Set a temporary password through the Users screen, or ask the user to use "Forgot password" (`POST /api/v1/auth/password/forgot`, limited to 5 per minute).
4. Reactivate a deactivated user in the Users screen.

For SSO-enforced domains, a user holding `security.manage` can still sign in with a password as break-glass (comment in `modules/auth.ts`).

## If the only admin is locked out

As the admin database user (this bypasses RLS and is not audited by the app, so write down what you did):

```
update users set failed_logins = 0, locked_until = null where lower(email) = lower('<email>');
```

For lost 2FA on the only admin, clear it from the database and ask them to enrol again. Check column names in `backend/src/db/schema.ts` first (`two_factor_enabled_at` and its secret columns). Then rotate that person's password.

Never share the temporary password over an unsafe channel. Record the event in the incident log.
