// Channel connector contract (v1.9). Design: docs/architecture/integration-architecture.md.

export type ChannelCapability = 'orders_csv' | 'orders_pull' | 'orders_webhook' | 'stock_push' | 'settlements_csv';

/** Provider-level stage (master plan 7.4). Per-account states live on the connection. */
export type ConnectorStage =
  | 'planned' | 'researching' | 'access_requested' | 'sandbox_available' | 'development' | 'internal_testing'
  | 'partner_certification' | 'production_enabled' | 'deprecated';

export interface ChannelCall {
  /** Unsealed credential values keyed by `credentialFields[].key`. */
  credentials: Record<string, string>;
  timeoutMs: number;
  /** Injected so tests can replay recorded responses. */
  fetch: typeof fetch;
}

export interface NormalisedLine {
  sku: string;
  title: string | null;
  qty: number;
  /** Price of one unit in rupees, as the channel shows it (see `taxInclusive`). */
  unitPrice: number;
  /** Total discount on the line in rupees. */
  discount: number;
}

/** A channel order in neutral form. SKU mapping and bundle expansion happen after this, in platform code. */
export interface NormalisedOrder {
  /** The order id the seller sees on the channel (for example "#1001"). Unique per connection. */
  externalRef: string;
  /** YYYY-MM-DD in IST. */
  orderDate: string;
  status: 'open' | 'cancelled';
  buyerName: string | null;
  /** Two-digit GST state code of the ship-to address, when known. */
  shipToState: string | null;
  taxInclusive: boolean;
  lines: NormalisedLine[];
  /** Shipping charged to the buyer in rupees (not put on the sales order in v1.9). */
  shipping: number;
  note: string | null;
}

export interface RawEvent { eventId: string; topic: string; payload: unknown }

export interface StockUpdate { sku: string; externalId: string | null; qty: number }

export interface ChannelConnector {
  id: string;
  version: string;
  name: string;
  stage: ConnectorStage;
  auth: 'none' | 'api_key' | 'oauth2';
  capabilities: ReadonlySet<ChannelCapability>;
  credentialFields: { key: string; label: string; secret: boolean }[];
  /** Requests per second the provider allows per store. */
  rateLimit?: { perSecond: number };
  /** Default CSV header for each order field, when the channel has a standard order report. */
  csvColumns?: Partial<Record<OrderCsvField, string>>;
  /** Settlement line labels (lower case) to settlement line kinds. */
  settlementAliases?: Record<string, SettlementKind>;
  /** Checks the credentials with a cheap read. Throws ChannelError on failure. */
  ping?(c: ChannelCall): Promise<{ message: string }>;
  /** Checks the signature on the raw body. Returns the provider's event id and topic, or null when it does not verify. */
  verifyWebhook?(raw: Buffer, headers: Record<string, string | undefined>, credentials: Record<string, string>): { eventId: string; topic: string } | null;
  /** Orders changed since `cursor` (opaque, null for the first pull), oldest first, and the cursor to store next. */
  pullOrders?(c: ChannelCall, cursor: string | null): Promise<{ events: RawEvent[]; cursor: string | null; /** False on the last page of this run's series. */ more?: boolean }>;
  /** Pure: a webhook or pulled payload as a neutral order, or null when the topic is not an order event. */
  normaliseOrder?(topic: string, payload: unknown): NormalisedOrder | null;
  /** Sets available quantity per listing. One result per update, in the same order. */
  pushStock?(c: ChannelCall, updates: StockUpdate[]): Promise<{ sku: string; ok: boolean; error?: string }[]>;
}

export type OrderCsvField = 'orderId' | 'orderDate' | 'sku' | 'title' | 'qty' | 'unitPrice' | 'lineTotal' | 'discount'
  | 'buyerName' | 'shipState' | 'status';

export type SettlementKind = 'sale' | 'refund' | 'commission' | 'fee' | 'shipping' | 'gst_on_fees' | 'tcs' | 'tds'
  | 'reserve' | 'reserve_release' | 'adjustment';

/**
 * `transient`: timeouts, network, 5xx (retry). `rate_limited`: 429 (retry after `retryAfterMs`).
 * `auth`: 401/403 or revoked token (connection degrades). `permanent`: the provider's answer (no retry).
 */
export class ChannelError extends Error {
  readonly code: string;
  readonly kind: 'transient' | 'rate_limited' | 'auth' | 'permanent';
  readonly retryAfterMs: number | null;
  constructor(code: string, message: string, kind: ChannelError['kind'], retryAfterMs: number | null = null) {
    super(message);
    this.code = code;
    this.kind = kind;
    this.retryAfterMs = retryAfterMs;
  }
}
