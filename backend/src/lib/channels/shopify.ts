import { channelAllowPrivate, channelJson, gstStateFromIso, hmacBase64, istDate, safeEqual } from './http.ts';
import { GENERIC_ORDER_COLUMNS, GENERIC_SETTLEMENT_ALIASES } from './registry-generic.ts';
import { ChannelError, type ChannelCall, type ChannelConnector, type NormalisedOrder, type RawEvent, type StockUpdate } from './types.ts';

/** Admin GraphQL API version. To verify against Shopify's current supported versions before a production pilot. */
export const SHOPIFY_API_VERSION = '2026-10';

const DOMAIN = /^[a-z0-9][a-z0-9-]*\.myshopify\.com$/i;

/** `https://<shop>.myshopify.com`; with private hosts allowed (tests) a full http(s) URL is also accepted. */
export function shopifyBase(domain: string): string {
  const d = domain.trim().replace(/\/+$/, '');
  if (DOMAIN.test(d)) return `https://${d.toLowerCase()}`;
  if (channelAllowPrivate() && /^https?:\/\/[^/@\s]+$/.test(d)) return d;
  throw new ChannelError('BAD_DOMAIN', 'Shop domain must look like yourshop.myshopify.com.', 'permanent');
}

const endpoint = (c: ChannelCall) => `${shopifyBase(c.credentials.shopDomain ?? '')}/admin/api/${SHOPIFY_API_VERSION}/graphql.json`;
const auth = (c: ChannelCall) => ({ 'x-shopify-access-token': c.credentials.accessToken ?? '' });

/** One GraphQL call. Shopify answers 200 with `errors` for throttling and bad queries. */
async function gql(c: ChannelCall, query: string, variables: Record<string, unknown> = {}): Promise<any> {
  const { json } = await channelJson(c, 'POST', endpoint(c), auth(c), { query, variables });
  const errs: any[] = Array.isArray(json?.errors) ? json.errors : [];
  if (errs.length) {
    if (errs.some((e) => e?.extensions?.code === 'THROTTLED')) throw new ChannelError('RATE_LIMITED', 'The store is limiting requests.', 'rate_limited', 2000);
    if (errs.some((e) => e?.extensions?.code === 'ACCESS_DENIED')) throw new ChannelError('AUTH', 'The store refused the credentials.', 'auth');
    throw new ChannelError('REJECTED', `Shopify rejected the query: ${String(errs[0]?.message ?? '').slice(0, 120)}`, 'permanent');
  }
  return json?.data ?? {};
}

const gidNum = (gid: unknown) => { const m = /(\d+)$/.exec(String(gid ?? '')); return m ? Number(m[1]) : null; };
const money = (set: any) => set?.shopMoney?.amount ?? '0';

const ORDERS_QUERY = `query Orders($first: Int!, $after: String, $query: String) {
  orders(first: $first, after: $after, query: $query, sortKey: UPDATED_AT) {
    pageInfo { hasNextPage endCursor }
    nodes {
      id name createdAt updatedAt cancelledAt note taxesIncluded
      shippingAddress { name provinceCode }
      shippingLines(first: 10) { nodes { originalPriceSet { shopMoney { amount } } } }
      lineItems(first: 100) { nodes { id sku title quantity variant { id } product { id }
        originalUnitPriceSet { shopMoney { amount } } totalDiscountSet { shopMoney { amount } } } }
    }
  }
}`;

/** Maps a GraphQL order node to the webhook (REST) payload shape that normaliseShopifyOrder reads. */
export function graphqlOrderToPayload(o: any): any {
  return {
    id: gidNum(o.id), name: o.name, created_at: o.createdAt, updated_at: o.updatedAt, cancelled_at: o.cancelledAt ?? null,
    note: o.note, taxes_included: o.taxesIncluded === true,
    shipping_address: o.shippingAddress ? { name: o.shippingAddress.name, province_code: o.shippingAddress.provinceCode } : null,
    shipping_lines: (o.shippingLines?.nodes ?? []).map((l: any) => ({ price: money(l.originalPriceSet) })),
    line_items: (o.lineItems?.nodes ?? []).map((l: any) => ({
      id: gidNum(l.id), sku: l.sku, title: l.title, quantity: l.quantity, variant_id: gidNum(l.variant?.id), product_id: gidNum(l.product?.id),
      price: money(l.originalUnitPriceSet), total_discount: money(l.totalDiscountSet),
    })),
  };
}

const STOCK_MUTATION = `mutation SetStock($input: InventorySetQuantitiesInput!) {
  inventorySetQuantities(input: $input) { userErrors { field message code } }
}`;

const num = (v: unknown) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };

export function normaliseShopifyOrder(topic: string, payload: unknown): NormalisedOrder | null {
  if (!topic.startsWith('orders/')) return null;
  const o = payload as any;
  if (!o || typeof o !== 'object' || o.id == null) return null;
  const lines = (Array.isArray(o.line_items) ? o.line_items : []).map((l: any) => ({
    sku: String(l.sku || (l.variant_id ? `variant-${l.variant_id}` : `product-${l.product_id ?? l.id}`)),
    title: l.title ? String(l.title).slice(0, 300) : null,
    qty: num(l.quantity), unitPrice: num(l.price), discount: num(l.total_discount),
  })).filter((l: { qty: number }) => l.qty > 0);
  const addr = o.shipping_address ?? o.billing_address ?? null;
  const shipping = (Array.isArray(o.shipping_lines) ? o.shipping_lines : []).reduce((s: number, l: any) => s + num(l.price), 0);
  return {
    externalRef: String(o.name ?? `#${o.order_number ?? o.id}`), orderDate: istDate(o.created_at),
    status: o.cancelled_at || topic === 'orders/cancelled' ? 'cancelled' : 'open',
    buyerName: addr?.name ? String(addr.name).slice(0, 120) : null,
    shipToState: gstStateFromIso(addr?.province_code), taxInclusive: o.taxes_included === true, lines, shipping,
    note: o.note ? String(o.note).slice(0, 300) : null,
  };
}

export const shopifyConnector: ChannelConnector = {
  id: 'shopify', version: '1', name: 'Shopify', stage: 'development', auth: 'api_key',
  capabilities: new Set(['orders_csv', 'settlements_csv', 'orders_pull', 'orders_webhook', 'stock_push']),
  credentialFields: [
    { key: 'shopDomain', label: 'Shop domain (yourshop.myshopify.com)', secret: false },
    { key: 'accessToken', label: 'Admin API access token', secret: true },
    { key: 'webhookSecret', label: 'Webhook signing secret', secret: true },
    { key: 'locationId', label: 'Shopify location id for stock', secret: false },
  ],
  rateLimit: { perSecond: 2 },
  csvColumns: GENERIC_ORDER_COLUMNS, settlementAliases: GENERIC_SETTLEMENT_ALIASES,

  async ping(c) {
    const data = await gql(c, 'query { shop { name } }');
    return { message: `Connected to ${String(data?.shop?.name ?? 'the shop').slice(0, 80)}.` };
  },

  verifyWebhook(raw, headers, credentials) {
    const sig = headers['x-shopify-hmac-sha256'];
    if (!sig || !credentials.webhookSecret || !safeEqual(sig, hmacBase64(credentials.webhookSecret, raw))) return null;
    const topic = headers['x-shopify-topic'];
    const eventId = headers['x-shopify-event-id'] ?? headers['x-shopify-webhook-id'];
    return topic && eventId ? { eventId, topic } : null;
  },

  /** Cursor is `updated_at`, or `updated_at~endCursor` while a run stopped part-way through the pages. */
  async pullOrders(c, cursor) {
    const [base = '', after = ''] = (cursor ?? '').split('~');
    const variables: Record<string, unknown> = { first: 50, after: after || null, query: base ? `updated_at:>='${base}'` : null };
    let data;
    try {
      data = await gql(c, ORDERS_QUERY, variables);
    } catch (err) {
      // A stale page cursor: start the series again from its first timestamp.
      if (after && err instanceof ChannelError && err.kind === 'permanent') return { events: [], cursor: base || null };
      throw err;
    }
    const orders: any[] = Array.isArray(data?.orders?.nodes) ? data.orders.nodes : [];
    const events: RawEvent[] = orders.map((o) => {
      const payload = graphqlOrderToPayload(o);
      return { eventId: `${payload.id}:${payload.updated_at}`, topic: payload.cancelled_at ? 'orders/cancelled' : 'orders/updated', payload };
    });
    const pi = data?.orders?.pageInfo;
    if (pi?.hasNextPage && pi.endCursor) return { events, cursor: `${base}~${pi.endCursor}`, more: true };
    const last = orders.length ? String(orders[orders.length - 1].updatedAt) : base || null;
    return { events, cursor: last, more: false };
  },

  normaliseOrder: normaliseShopifyOrder,

  async pushStock(c, updates: StockUpdate[]) {
    const out: { sku: string; ok: boolean; error?: string }[] = [];
    for (const u of updates) {
      if (!u.externalId) { out.push({ sku: u.sku, ok: false, error: 'No Shopify inventory item id on this listing.' }); continue; }
      try {
        const data = await gql(c, STOCK_MUTATION, { input: {
          name: 'available', reason: 'correction', ignoreCompareQuantity: true,
          quantities: [{
            inventoryItemId: `gid://shopify/InventoryItem/${Number(u.externalId)}`,
            locationId: `gid://shopify/Location/${Number(c.credentials.locationId)}`,
            quantity: Math.max(0, Math.floor(u.qty)), changeFromQuantity: null,
          }],
        } });
        const ue: any[] = data?.inventorySetQuantities?.userErrors ?? [];
        out.push(ue.length ? { sku: u.sku, ok: false, error: String(ue[0].message ?? 'Shopify refused the quantity.').slice(0, 200) } : { sku: u.sku, ok: true });
      } catch (err) {
        if (!(err instanceof ChannelError) || err.kind === 'auth' || err.kind === 'rate_limited' || err.kind === 'transient') throw err;
        out.push({ sku: u.sku, ok: false, error: err.message });
      }
    }
    return out;
  },
};
