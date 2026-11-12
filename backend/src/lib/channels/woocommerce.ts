import { channelJson, gstStateFromIso, hmacBase64, istDate, safeEqual } from './http.ts';
import { GENERIC_ORDER_COLUMNS, GENERIC_SETTLEMENT_ALIASES } from './registry-generic.ts';
import { ChannelError, type ChannelCall, type ChannelConnector, type NormalisedOrder, type RawEvent, type StockUpdate } from './types.ts';

const api = (c: ChannelCall) => `${(c.credentials.storeUrl ?? '').trim().replace(/\/+$/, '')}/wp-json/wc/v3`;
const auth = (c: ChannelCall) => ({
  authorization: `Basic ${Buffer.from(`${c.credentials.consumerKey ?? ''}:${c.credentials.consumerSecret ?? ''}`).toString('base64')}`,
});
const num = (v: unknown) => { const n = Number(v); return Number.isFinite(n) ? n : 0; };

const CANCELLED = new Set(['cancelled', 'refunded', 'failed', 'trash']);

export function normaliseWooOrder(topic: string, payload: unknown): NormalisedOrder | null {
  if (!topic.startsWith('order.') || topic === 'order.deleted') return null;
  const o = payload as any;
  if (!o || typeof o !== 'object' || o.id == null) return null;
  // Line subtotal and total are before tax; subtotal is before discount, total after it.
  const lines = (Array.isArray(o.line_items) ? o.line_items : []).map((l: any) => {
    const qty = num(l.quantity);
    return {
      sku: String(l.sku || `product-${l.variation_id || l.product_id}`), title: l.name ? String(l.name).slice(0, 300) : null,
      qty, unitPrice: qty > 0 ? num(l.subtotal) / qty : 0, discount: Math.max(num(l.subtotal) - num(l.total), 0),
    };
  }).filter((l: { qty: number }) => l.qty > 0);
  const a = o.shipping?.state ? o.shipping : o.billing;
  const name = [a?.first_name, a?.last_name].filter(Boolean).join(' ');
  return {
    externalRef: `#${o.number ?? o.id}`, orderDate: istDate(o.date_created_gmt ? `${o.date_created_gmt}Z` : o.date_created),
    status: CANCELLED.has(String(o.status)) ? 'cancelled' : 'open', buyerName: name ? name.slice(0, 120) : null,
    shipToState: gstStateFromIso(a?.state), taxInclusive: false, lines, shipping: num(o.shipping_total),
    note: o.customer_note ? String(o.customer_note).slice(0, 300) : null,
  };
}

export const wooConnector: ChannelConnector = {
  id: 'woocommerce', version: '1', name: 'WooCommerce', stage: 'development', auth: 'api_key',
  capabilities: new Set(['orders_csv', 'settlements_csv', 'orders_pull', 'orders_webhook', 'stock_push']),
  credentialFields: [
    { key: 'storeUrl', label: 'Store address (https://shop.example.com)', secret: false },
    { key: 'consumerKey', label: 'REST API consumer key', secret: true },
    { key: 'consumerSecret', label: 'REST API consumer secret', secret: true },
    { key: 'webhookSecret', label: 'Webhook secret', secret: true },
  ],
  rateLimit: { perSecond: 5 },
  csvColumns: GENERIC_ORDER_COLUMNS, settlementAliases: GENERIC_SETTLEMENT_ALIASES,

  async ping(c) {
    await channelJson(c, 'GET', `${api(c)}/orders?per_page=1`, auth(c));
    return { message: 'Connected to the store.' };
  },

  verifyWebhook(raw, headers, credentials) {
    const sig = headers['x-wc-webhook-signature'];
    if (!sig || !credentials.webhookSecret || !safeEqual(sig, hmacBase64(credentials.webhookSecret, raw))) return null;
    const topic = headers['x-wc-webhook-topic'];
    const eventId = headers['x-wc-webhook-delivery-id'];
    return topic && eventId ? { eventId, topic } : null;
  },

  /** Cursor is `modified_after`, or `modified_after~page` while a run stopped part-way through the pages. */
  async pullOrders(c, cursor) {
    const [base = '', pageText = ''] = (cursor ?? '').split('~');
    const page = Math.max(1, Number(pageText) || 1);
    const q = new URLSearchParams({ per_page: '50', page: String(page), orderby: 'modified', order: 'asc', dates_are_gmt: 'true' });
    if (base) q.set('modified_after', base);
    const { json, headers } = await channelJson(c, 'GET', `${api(c)}/orders?${q}`, auth(c));
    const orders: any[] = Array.isArray(json) ? json : [];
    const events: RawEvent[] = orders.map((o) => ({ eventId: `${o.id}:${o.date_modified_gmt}`, topic: 'order.updated', payload: o }));
    const totalPages = Number(headers.get('x-wp-totalpages'));
    const more = Number.isFinite(totalPages) && totalPages > 0 ? page < totalPages : orders.length === 50;
    if (more) return { events, cursor: `${base}~${page + 1}`, more: true };
    const last = orders.length ? String(orders[orders.length - 1].date_modified_gmt) : base || null;
    return { events, cursor: last, more: false };
  },

  normaliseOrder: normaliseWooOrder,

  async pushStock(c, updates: StockUpdate[]) {
    const out: { sku: string; ok: boolean; error?: string }[] = [];
    for (const u of updates) {
      if (!u.externalId) { out.push({ sku: u.sku, ok: false, error: 'No WooCommerce product id on this listing.' }); continue; }
      try {
        await channelJson(c, 'PUT', `${api(c)}/products/${encodeURIComponent(u.externalId)}`, auth(c),
          { manage_stock: true, stock_quantity: Math.max(0, Math.floor(u.qty)) });
        out.push({ sku: u.sku, ok: true });
      } catch (err) {
        if (!(err instanceof ChannelError) || err.kind === 'auth' || err.kind === 'rate_limited' || err.kind === 'transient') throw err;
        out.push({ sku: u.sku, ok: false, error: err.message });
      }
    }
    return out;
  },
};
