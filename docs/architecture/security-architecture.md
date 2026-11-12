# Security architecture

## Authentication

- Passwords: bcrypt cost 10. After 10 failed attempts (`MAX_FAILS`) the account locks for 15 minutes (`LOCK_MS`). A password policy is checked on signup and change.
- Access token: JWT HS256, default life 900 s, claims `typ`, `tid`, `sid`, `amr`.
- Refresh token: 30 days, stored in `refresh_tokens`. Refresh rotates the token. Reusing a revoked refresh token revokes all of that user's tokens (`modules/auth.ts`).
- Sessions: the auth hook checks the session row on every request, so revoking a session takes effect at once.
- Password reset: `password_resets`, looked up by `auth_find_password_reset`.
- Auth routes have an IP rate limit (default 20 per minute).

## Two-factor

TOTP with recovery codes. Login with 2FA returns a 5-minute `mfaToken`; five wrong codes stop it (`mfa_challenges`). A company can set `require_2fa`. Users without enrolment then get 403 `MFA_ENROLMENT_REQUIRED`, except on `ENROL_EXEMPT` paths.

## Single sign-on

OIDC only (`backend/src/lib/oidc.ts`): discovery, issuer must be https or loopback, PKCE, nonce check. Tables `sso_providers`, `sso_states`, `sso_tickets`. SAML is not built.

## Authorization

- 91 permission keys in `auth/permissions.ts`. System roles: Owner, Company Admin, Accountant, Sales Executive, Store Keeper, Site Supervisor, Project Manager, Auditor.
- Role grants honour `valid_from`, `valid_to` and `location_ids`.
- Handlers call `ctx.require('key')`. Sensitive overrides have their own keys, such as `purchases.override` and `stock_counts.approve`.
- Approvals (`registerApprovalDoc`) add a second person for journal, credit note, expense, payment, purchase and purchase order.
- Known gap: no scan-only role for warehouse pickers. See `docs/product/personas.md`.

## Audit

`writeAudit(tx, who, entity, entityId, action, before, after)` in `modules/audit.ts` writes `audit_log` in the same transaction as the change. Posted records are reversed, not edited.

## Idempotency

`backend/src/lib/idempotency.ts`. Applies to POST with `Idempotency-Key` matching `^[A-Za-z0-9_-]{8,100}$`; multipart is skipped. Unique (tenant, user, key), with a sha256 of the body. A different body gives 422 `IDEMPOTENCY_MISMATCH`; a still-running request gives 409 `REQUEST_IN_PROGRESS`; a replay returns the stored response with `Idempotent-Replayed: true`. Only 2xx responses are kept. Purged after 24 hours, or 5 minutes if still running. See ADR-005.

## Secrets and DATA_KEY

`backend/src/lib/crypto.ts` seals values with AES-256-GCM as `v1.<iv>.<tag>.<ct>`. `DATA_KEY` is 32 bytes, base64. If unset, a key is derived from `JWT_SECRET` with HKDF and a warning is logged. It protects TOTP secrets, SSO client secrets and GSP credentials. v1.9 channel credentials must use the same functions.

Production rule: set `DATA_KEY` separately from `JWT_SECRET`. Rotation is not built; the `v1.` prefix leaves room for a key id.

## HTTP hardening

helmet is on with CSP off (the API serves JSON). CORS allows Authorization, Content-Type, X-Company-Id, Idempotency-Key. Body limit 1 MB, uploads 10 MB. Non-UUID ids give 404.

## Not yet evidenced

Pen test, load test and backup restore drill (production-readiness gates, v1.11). Webhook signature verification arrives with v1.9.
