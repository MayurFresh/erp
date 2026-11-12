# ADR-004: Append-only stock ledger with per-item advisory locks

Status: Accepted, with one gap (no database enforcement)

## Context
Inventory must reconcile with accounts and must never oversell. Master plan section 6.2 wants a ledger of movements and atomic reservations. Two orders racing for the last unit, a parallel cancel, or a repeated dispatch must not corrupt balances.

## Decision
- Stock is the sum of signed rows in `stock_moves` (`qty`, `rate`, `cost_rate`, `value`, `ref_type`, `ref_id`). Balances are never stored as editable numbers.
- Corrections and cancels append a reversing move (`invoice_cancel`, `grn_cancel`, and so on). No code updates or deletes the rows.
- Cost is weighted average, computed in `accounting/costing.ts`.
- Any code that reads then writes stock calls `lockItems(tx, companyId, itemIds)`, taking `pg_advisory_xact_lock` on a hash of `company:item`, with ids sorted to avoid deadlocks. Stock counts and labour use their own advisory locks.
- Reservations are rows in `stock_reservations`, not ledger moves. Availability is on-hand minus active reservations.

## Consequences
- Races are serialised per item, not globally. Tests: "lets only one of two orders reserve the last unit", "refuses a parallel stock issue that exceeds the balance", "never over-allocates when two receipts race".
- Full history for audit and reconciliation.
- Balance reads sum many rows; will need a snapshot or index tuning at volume.
- Append-only is a convention, not a rule the database enforces. No trigger blocks UPDATE or DELETE. Fix: revoke those rights on `stock_moves` from the app role, or add a trigger (risk R18).
- Master plan section 6.2 treats reserve, pick, pack and dispatch as ledger events. Here only dispatch is a ledger event; earlier steps live on line quantities and reservations. This is simpler and was judged sufficient; revisit with multi-warehouse bins in v1.10.

## Alternatives
- Mutable balance column per item: fast, loses history, races easily.
- Row locks on a balance row: works, contention on hot items, no history.
- Serializable isolation for everything: correct but retry-heavy.
