# ADR-001: Keep Fastify, PostgreSQL and Flutter

Status: Accepted (confirms plan section 1.2)

## Context
The master plan suggests a platform with many services, queues and a web framework of its own choosing. OneMatrix already runs on Node 24 with TypeScript, Fastify 5, Kysely, PostgreSQL 16 and zod 4 on the server, and Flutter 3.44 with Riverpod 3 and go_router on the client. It has 14 migrations, about 62 route modules, 91 permissions and a test suite covering isolation, concurrency and idempotency. The next releases (channels, warehouse depth) need reliability more than a new stack.

## Decision
Keep the stack. Extend it. Do not rewrite the backend or client for v1.8 to v1.11.

## Consequences
- Delivery time goes to features and evidence, not migration.
- One language on the server, one on the client. Types are shared by convention through zod schemas and `docs/API.md`.
- Flutter web has a weaker fit for dense data tables and SEO than a React stack. Acceptable for an internal ERP; a B2B portal (later) may need a separate web surface.
- The in-process worker and single database set a scale ceiling. Revisit under load testing in v1.11.
- Hiring pool for Dart is smaller than for TypeScript-only stacks.

## Alternatives
- Rewrite in NestJS and React: gains familiarity, costs months and the existing tests.
- Move to microservices and a message broker: premature (see ADR-006, ADR-003).
- Use a managed backend (Supabase, Hasura): would replace the permission and RLS work already done and complicate India-region hosting.
