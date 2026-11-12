# Security findings

This is a read of the code on 2026-11-03 (v1.8). It is not a penetration test. Nothing here was exploited against a running system, and no scanner was run. Findings marked "unverified" have no test. A penetration test is still required before production (release checklist, gate 4).

Status values: Met (control exists and a test or code shows it), Partial, Gap (missing), N/A.

## Findings

| ID | Finding | Severity | Evidence | Fix target |
| --- | --- | --- | --- | --- |
| S-01 | CORS allows any origin unless `CORS_ORIGINS` is set | Medium | `backend/src/config.ts:17`, `app.ts:122` | Fixed 3 Nov 2026: startup fails in production with `*` |
| S-02 | Rate limits only on auth routes, in memory, and `trustProxy: true` always on | Medium | `app.ts:103,128`, `modules/auth.ts:120` | Fixed 3 Nov 2026: per-IP limit on every route before the auth check, `TRUST_PROXY` off by default. Store still per process (shared store when there is more than one instance) |
| S-03 | OIDC discovery and token calls accept any https host (SSRF by a tenant admin) | Medium | `backend/src/lib/oidc.ts:12,23,48` | Fixed 3 Nov 2026: issuer, token and JWKS hosts must resolve to public addresses in production. DNS rebinding between check and fetch remains |
| S-04 | Sealing key falls back to `JWT_SECRET`; rotating it breaks sealed secrets | Medium | `backend/src/lib/crypto.ts:17`, warning at `app.ts:118` | Fixed 3 Nov 2026: `DATA_KEY` required in production |
| S-05 | CSV guard misses `-`, tab, CR | Low | `backend/src/lib/csv.ts:8` | Fixed 3 Nov 2026 |
| S-06 | Uploads: type sniffed by magic bytes, no malware scan, local disk | Medium | `modules/files.ts:15,82` | Partly fixed 3 Nov 2026: PDFs with scripts or launch actions are rejected. Malware scanner and object storage at deploy time |
| S-07 | Tables use `enable`, not `force`, RLS, so the owner role bypasses | Low | `001_init.sql:220-232` | Accept; keep owner credentials off the app host |
| S-08 | No dependency, secret or SAST scanning; no CI | Medium | no `.github/` | Partly fixed 3 Nov 2026: CI with `npm audit`. Secret and static scans still open |
| S-09 | No security headers beyond helmet defaults; CSP disabled (API only) | Low | `app.ts:120` | Accept for API; set on the web host |
| S-10 | Access JWT is HS256 with one secret and no key id | Low | `auth/tokens.ts:18` | v1.11 |
| S-11 | Seed script creates a known password (`Demo@1234`) for owner@demo.in | Low | `db/seed.ts:18` | Never run seed against production |
| S-12 | No audit of reads or exports; no log shipping | Low | `modules/audit.ts` (writes only) | v1.11 |
| S-13 | Sensitive fields (PAN, bank details, wages) are stored and returned in clear to permitted roles; no masking | Low | schema | Later |

## OWASP API Security Top 10 (2023)

| Item | Status | Notes |
| --- | --- | --- |
| API1 Broken object level authorization | Met, with tests | RLS under every query plus ids from the token. `api.test.ts :: never shows one business the data of another`, `o2c.test.ts :: hides another business order`, `p2p.test.ts :: another tenant's records are 404` |
| API2 Broken authentication | Partial | Lockout, 2FA, rotation and reuse detection are tested (`platform.test.ts`, `api.test.ts`). No breached-password check; rate limit untested (tests disable it) |
| API3 Broken object property level authorization | Partial | Responses are built field by field, supervisors do not see costs (`api.test.ts :: limits a site supervisor to their site and hides costs`). No test sweeps every response for hidden fields; the role probe checked only status codes |
| API4 Unrestricted resource consumption | Partial | Body 1 MB, upload 10 MB, page size 200. No limit on exports or imports beyond size; S-02 |
| API5 Broken function level authorization | Met, with tests | `ctx.require(permission)` per route; `o2c.test.ts :: enforces permissions`, `p2p.test.ts :: needs permissions`; v1.8 role probe |
| API6 Unrestricted access to sensitive business flows | Partial | Signup limited to 20 per minute per IP; idempotency and row locks protect posting; approvals gate large documents. No bot controls |
| API7 Server side request forgery | Partial | Outbound calls go to fixed hosts except OIDC issuer (S-03) |
| API8 Security misconfiguration | Partial | helmet on, errors generic. CORS default open (S-01), `trustProxy` always on (S-02) |
| API9 Improper inventory management | Partial | One versioned prefix `/api/v1`; routes listed by hand in `docs/API.md`; no OpenAPI, so drift is possible (target v1.11) |
| API10 Unsafe consumption of APIs | Partial | GSP and WhatsApp errors mapped, timeouts set; payloads from GSP trusted after adapter parse. Marketplace inputs not built yet |

## OWASP ASVS 5.0, main chapters

Chapter names are grouped by topic; map to the exact ASVS 5.0 requirement numbers when the full mapping is done (gate 4).

| Chapter topic | Status | Notes |
| --- | --- | --- |
| Encoding and sanitization (injection, XSS) | Partial | Parameterised queries throughout; JSON-only API; CSV guard incomplete (S-05) |
| Validation and business logic | Met | zod on bodies, fuzz test (`robustness.test.ts`), business rules in the backend, races tested |
| Web frontend security | Gap | Flutter web build not reviewed for CSP, storage of tokens, headers |
| API and web service | Partial | See OWASP API table |
| File handling | Partial | Size and type limits; no malware scan, no isolated storage (S-06) |
| Authentication | Partial | Strong-password rules, lockout, 2FA with recovery codes, SSO with state check (`platform.test.ts :: rejects a bad state`). No passkeys; no breached-password check |
| Session management | Met | Refresh rotation, reuse detection, session list and revoke, revoke on deactivation (`robustness.test.ts`) |
| Authorization | Met, with tests | RLS plus permission checks plus location scope |
| Self-contained tokens (JWT) | Partial | Algorithm pinned, expiry enforced; one symmetric key (S-10) |
| OAuth and OIDC | Partial | Authorization code with PKCE verifier (`backend/src/lib/oidc.ts:45`), state tested; issuer host not restricted (S-03) |
| Cryptography | Partial | AES-256-GCM sealing, random IVs; key derivation fallback (S-04); no key rotation procedure with re-seal tool |
| Secure communication | Gap | TLS is expected at the proxy; not part of the repo; no HSTS test |
| Configuration | Partial | Env validated by zod (`config.ts`); `.env` is git-ignored; no secret scanning; no container hardening |
| Data protection | Partial | No field masking; backups unencrypted by default; no retention policy |
| Logging and error handling | Partial | Generic 500s, structured logs, audit of writes; no alerting; reads unaudited |
| WebRTC, MCP | N/A | Not used |

## What a penetration test should cover first

1. Tenant isolation through the API with two real tenants, including exports, files and jobs.
2. SSO issuer SSRF (S-03).
3. Auth flows: reset link, MFA token, recovery codes, refresh rotation under parallel calls.
4. Rate-limit bypass through `X-Forwarded-For` (S-02).
5. File upload with polyglot files.
