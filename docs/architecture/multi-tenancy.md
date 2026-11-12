# Multi-tenancy

Shared database, shared schema. A tenant is one customer business. A tenant has one or more companies (legal entities) and each company has locations. There is no business-unit level between tenant and company.

## Layers of scope

| Level | Carried by | Enforced by |
|---|---|---|
| Tenant | `tenant_id` column, JWT claim `tid`, setting `app.tenant_id` | Postgres RLS policy `tenant_isolation` |
| Company | `X-Company-Id` header, `company_id` column | Membership check in the auth hook, then queries filter by company |
| Location | `user_roles.location_ids` (null means all) | `ctx.canAccessLocation`, `ctx.requireLocation`, `scopedLocationIds` in `backend/src/lib/scope.ts` |

Tenant isolation is in the database. Company and location scope are enforced in code, so a bug there leaks within a tenant, not across tenants.

## Row-level security

- `app_tenant_id()` reads `current_setting('app.tenant_id', true)` (001_init.sql, around lines 216 to 233).
- Every tenant table has `tenant_id` and policy `tenant_isolation`. 001 creates the first ones; 002, 003, 006, 009, 010 and 013 loop `create policy tenant_isolation` over their tables, and 008 does it for `idempotency_keys`.
- The app connects as a role with `nosuperuser nobypassrls` (`db/setup.ts`). `migrate.ts` grants it select, insert, update, delete, grants execute on `auth_find_user_by_email`, and revokes writes on `schema_migrations`.
- With no `app.tenant_id` set, a query sees no rows.

## Setting the tenant

`withTenant(db, tenantId, fn)` in `db/database.ts` opens a transaction and runs `set_config('app.tenant_id', id, true)` (local to the transaction). It retries once on 40001 or 40P01, then throws 409 `TRY_AGAIN`. `ctx.tx` wraps it.

## Before the tenant is known

A few functions must read across tenants. They are SECURITY DEFINER and narrow: `auth_find_user_by_email`, `auth_find_password_reset`, `jobs_claim`, `jobs_enqueue_daily`. A new cross-tenant function needs a reason written next to it.

## Jobs, exports, cache

- Jobs: the claim is cross-tenant, but each handler runs under `withTenant` with the job's tenant. `contextFor` builds a `RequestContext` for the job or approval.
- Exports and files: handlers use `ctx.tx`, so RLS applies. Files are rows in `files` with `tenant_id`.
- Cache: no tenant-data cache was found in the code reviewed. If one is added, its key must start with the tenant id.
- Idempotency keys are unique per (tenant, user, key).

## Tests that prove isolation

| File | Case |
|---|---|
| `backend/test/api.test.ts` | "tenant isolation": "never shows one business the data of another"; "enforces isolation in the database itself, not only in code" (counts rows with no tenant context and expects 0) |
| `backend/test/api.test.ts` | "roles and location scope": "limits a site supervisor to their site and hides costs" |
| `backend/test/o2c.test.ts` | "hides another business order" |
| `backend/test/p2p.test.ts` | "another tenant's records are 404" |
| `backend/test/robustness.test.ts` | "session revocation": "rejects a company the user has no access to" |

## Rules for new work

1. Every new table has `tenant_id` and the policy, in the same migration.
2. Every new feature adds a cross-tenant 404 test.
3. v1.9 webhooks arrive without a user. Resolve the connection from the URL, verify the signature, and only then call `withTenant` with the connection's tenant.
