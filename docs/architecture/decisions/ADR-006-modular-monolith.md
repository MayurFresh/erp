# ADR-006: Modular monolith

Status: Accepted

## Context
The master plan lists many domains (sales, stock, accounting, channels, HR, manufacturing) and warns against too many microservices (risk in section 17). The team is small. Domains share transactions: dispatch creates an invoice, a shipment, stock moves and journal lines together.

## Decision
One deployable API with one database. Code is split by module (`backend/src/modules`, about 62 files) and by shared libraries (`accounting`, `lib`, `auth`). Bounded contexts and call rules are in `docs/architecture/domain-boundaries.md`. The job worker is in the same process. New contexts, including Channels in v1.9, join as modules.

## Consequences
- Cross-domain actions are one ACID transaction, with no sagas or compensation code.
- One deploy, one log stream, simple local development and tests.
- Boundaries are enforced by review only. Without discipline, modules will import each other's tables. A lint rule or folder-per-context layout would help.
- Scaling is whole-process. Heavy work (imports, polling) can move to a second worker process first (ADR-003).
- A module can be extracted later if its tables are only touched through its own functions. Rule 1 in domain-boundaries is what keeps that open.

## Alternatives
- Microservices per domain: independent scaling, but distributed transactions and heavy operations for a small team.
- Separate services only for channels: possible later if provider traffic needs it; not needed for v1.9.
