# Integration architecture (v1.9 connector contract)

Status: design for v1.9. Only the GSP adapter exists in code. There is no webhook, inbox or polling code in the repo today. The contract below generalises the GSP adapter to sales channels, couriers and storefronts, and covers master plan section 7.1.

## What exists: the GSP model

`backend/src/lib/gsp/`:
- `types.ts`: `GspCapability`, `GspCall {gstin, credentials, timeoutMs}`, `GspAdapter {id, name, capabilities, credentialFields[{key,label,secret}], ping, ...}`, `GspError(code, message, transient)`.
- `registry.ts`: `registerGspAdapter`, `gspAdapter`, `listGspAdapters`. Adding a provider is one file and one register line.
- `resolveGsp`: 409 `GSP_NOT_CONFIGURED`; 501 `NOT_SUPPORTED` when a capability is missing; unseals secret fields; timeout 20 s.
- `callGsp`: retries transient errors with backoff 1 s then 3 s, then 503 `GSP_UNAVAILABLE`. Non-transient gives 502 `GSP_ERROR` with provider code and message.
- Tables `gsp_credentials`, `gsp_submissions`. Test: `platform.test.ts` "GSP adapter".

## Connector contract

```ts
interface ChannelConnector {
  id: string; version: string; name: string;
  capabilities: ('orders_pull'|'orders_webhook'|'stock_push'|'price_push'|'settlements'|'shipments'|'returns')[];
  auth: 'api_key' | 'oauth2';
  credentialFields: { key: string; label: string; secret: boolean }[];
  rateLimit: { perSecond: number; burst: number };
  ping(call): Promise<HealthResult>;
  verifyWebhook?(rawBody: Buffer, headers): { ok: boolean; eventId: string };
  pullOrders?(call, cursor): Promise<{ events: RawEvent[]; next: Cursor }>;
  normaliseOrder(raw): NormalisedOrder;     // pure function, tested with recorded payloads
  pushStock?(call, updates): Promise<PushResult>;
  refresh?(call): Promise<NewCredentials>;  // OAuth refresh
}
```
Errors use the `GspError` shape: code, message, `transient`. Transient means retry; permanent means dead-letter after one try.

## Contract items

| Item (master plan 7.1) | Design |
|---|---|
| Provider id and version | Registered like the GSP registry. Version is stored on the connection, so a payload can be replayed with the version that produced it. |
| Auth and credentials | Stored sealed with `seal` (AES-256-GCM, `DATA_KEY`). Secret fields never returned by the API. Rotation replaces the sealed value and is audited. |
| Token refresh and revocation | `refresh` called before expiry or on a 401. A failed refresh moves the connection to `degraded`. Revoke clears the sealed values. |
| Capabilities | Declared per connector. A missing capability gives 501 `NOT_SUPPORTED` as in `resolveGsp`. |
| Rate limits | Per connection token bucket. A 429 from the provider is transient and honours Retry-After. |
| Webhook inbox | `POST /webhooks/:connectionId`. Verify the signature on the raw body first, then insert into `channel_inbox` (unique per connection and provider event id) and return 200. Processing is a job. A bad signature gives 401 and stores nothing. |
| Dedupe | Unique (connection, event id). A repeat insert is ignored and no job is queued. Order creation is also guarded by `sales_orders` unique (company, source, `external_ref`). Two layers. |
| Polling fallback | A scheduled job calls `pullOrders` from the stored cursor. The cursor is saved in the same transaction that stores the batch in the inbox. A crash re-fetches and dedupe absorbs it. |
| Pagination, cursors | Cursor is opaque to the platform, stored per connection and resource. Backfill sets it back to a chosen time. |
| Retries | Reuse the jobs table: 3 attempts, backoff 30 s doubling. Provider calls inside use the GSP-style short retry for transient errors. |
| Dead-letter | A job that exhausts attempts stays `failed` with its error and the inbox row is marked dead. A user with `channels.manage` can replay it. Replay is audited. |
| Idempotency toward the provider | Stock push carries a deterministic key (connection, listing, version). Posting settlements is keyed by (channel, settlement id, line index). |
| Mapping and normalisation | `normaliseOrder` returns a neutral order. SKU mapping and bundle expansion happen after, in platform code, so connectors stay thin. |
| Error classification | transient, permanent, auth, rate_limited. Auth errors degrade the connection. |
| Health | `ping` plus last success, last error and backlog counts per connection. |
| Audit | Connect, rotate, revoke, replay and status changes call `writeAudit`. |

## Connection statuses (master plan 7.4)

Planned, Researching, Access requested, Sandbox available, Development, Internal testing, Partner certification, Production enabled, Degraded, Suspended, Deprecated.

A connection shows as connected only when status is Production enabled and the last health check passed. Saved credentials alone never produce it. Provider-level statuses (for example "Access requested" for Amazon) belong to the connector; per-account states (Degraded, Suspended) belong to the connection.

## Proposed tables

`channel_connections`, `channel_inbox`, `channel_listings`, `channel_listing_components`, `channel_settlements`, `channel_settlement_lines`, `channel_cursors`. All carry `tenant_id` and the RLS policy. Names are proposals, not built.

## Tests required before release

Contract test per connector with recorded payloads; replay test (same webhook twice, same file twice) for the v1.9 exit check; signature test; crash-after-store cursor test; cross-tenant 404 for every route.
