# ADR-005: Idempotency keys on POST requests

Status: Accepted

## Context
Mobile clients retry on poor networks, users double-tap, and from v1.9 providers redeliver webhooks. A repeated dispatch or payment must not post twice. Master plan section 9.5 requires idempotency on all external and posting operations.

## Decision
`backend/src/lib/idempotency.ts` wraps POST requests carrying `Idempotency-Key` (8 to 100 characters of letters, digits, underscore, hyphen). Multipart uploads are skipped. A row in `idempotency_keys` is unique on (tenant, user, key) and stores a sha256 of the body. Outcomes: same key and body replays the stored response with `Idempotent-Replayed: true`; same key with a different body gives 422 `IDEMPOTENCY_MISMATCH`; same key while the first is running gives 409 `REQUEST_IN_PROGRESS`. Only 2xx responses are stored, so a failure can be retried with the same key. Rows are purged after 24 hours, or 5 minutes if stuck running. Domain-level guards back this up: `shipments.dispatch_key` (partial unique), `scan_events` unique scan id, `sales_orders` unique (company, source, external_ref).

## Consequences
- Safe client retries for dispatch, posting and imports. Tests: "dispatches once when the same request is repeated", robustness idempotency cases.
- Keys are optional, so a client that omits one gets no protection. Clients must send them on posting actions.
- 24-hour window: a retry after a day is a new request. Domain unique keys cover the critical cases.
- The key is scoped to a user, so two users cannot collide.
- Webhooks do not use this header; they dedupe by provider event id (see `integration-architecture.md`).

## Alternatives
- Require keys on every POST: stricter, breaks simple clients.
- Dedupe only by domain unique keys: protects fewer endpoints.
- Exactly-once through a queue: more infrastructure (ADR-003).
