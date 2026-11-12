# ADR-002: Tenant isolation with Postgres row-level security

Status: Accepted

## Context
The product is multi-tenant SaaS holding accounting data. A missing `where tenant_id = ?` in any query would leak one business's books to another. Master plan section 9.3 requires isolation that does not rely on every developer remembering a filter.

## Decision
One shared schema. Every tenant table has `tenant_id` and a `tenant_isolation` policy using `app_tenant_id()`, which reads `app.tenant_id`. The API connects as a non-superuser role without `bypassrls`. All business queries run inside `withTenant`, which sets the value with `set_config(..., true)` in a transaction. Cross-tenant lookups needed before login or in the job claim are SECURITY DEFINER functions kept few and narrow. Company and location scope stay in application code.

## Consequences
- A forgotten filter returns nothing instead of another tenant's rows. Proven by `api.test.ts` "enforces isolation in the database itself".
- Every request pays one `set_config` and runs in a transaction.
- Every migration that adds a table must add the policy. A table without it is a leak; there is no automatic check yet (candidate: a test listing tables lacking policy).
- Pooled connections are safe because the setting is transaction-local.
- Per-tenant backup, restore or data residency is harder than with a database per tenant.

## Alternatives
- Application-level filters only: simplest, one mistake from a breach.
- Schema per tenant: strong separation, painful migrations at many tenants.
- Database per tenant: strongest, highest cost and operations load; revisit for very large customers.
