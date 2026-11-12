import { sql } from 'kysely';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { todayIst } from '../lib/dates.ts';
import { AppError } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import type { NormalisedOrder } from '../lib/channels/types.ts';
import { cancelOrder, confirmOrder, createOrder } from './sales-orders.ts';

export interface Connection {
  id: string; company_id: string; name: string; party_id: string; location_id: string; order_status: string;
  prices_include_tax: boolean; created_by: string;
}

export type OrderAction = 'create' | 'duplicate' | 'cancel' | 'ignored' | 'blocked';

export interface PlannedLine { channelSku: string; itemId: string; itemName: string; qty: number; rate: number; gstRate: number }
export interface Plan {
  action: OrderAction; reason: string | null; unmappedSkus: string[]; lines: PlannedLine[];
  estimate: { subtotal: number; taxTotal: number; total: number } | null; existingOrderId: string | null;
}

const round2 = (n: number) => Math.round(n * 100) / 100;

/** What an order would become: duplicate, cancel, blocked by missing SKU mappings, or a new sales order. Writes nothing. */
export async function planOrder(tx: Tx, ctx: RequestContext, conn: Connection, order: NormalisedOrder): Promise<Plan> {
  const base = { unmappedSkus: [] as string[], lines: [] as PlannedLine[], estimate: null, existingOrderId: null as string | null };
  const existing = await tx.selectFrom('sales_orders').select(['id', 'status'])
    .where('channel_id', '=', conn.id).where('external_ref', '=', order.externalRef).executeTakeFirst();
  if (existing) base.existingOrderId = existing.id;
  if (order.status === 'cancelled') {
    if (!existing) return { ...base, action: 'ignored', reason: 'Cancelled on the channel before it was imported.' };
    if (existing.status === 'cancelled') return { ...base, action: 'duplicate', reason: 'Already cancelled.' };
    return { ...base, action: 'cancel', reason: null };
  }
  if (existing) return { ...base, action: 'duplicate', reason: 'This order id was imported before.' };

  const skus = [...new Set(order.lines.map((l) => l.sku))];
  const listings = await tx.selectFrom('channel_listings').select(['id', 'channel_sku']).where('connection_id', '=', conn.id)
    .where('channel_sku', 'in', skus).where('is_active', '=', true).execute();
  const unmapped = skus.filter((s) => !listings.some((l) => l.channel_sku === s));
  const comps = listings.length
    ? await tx.selectFrom('channel_listing_components as c').innerJoin('items as i', 'i.id', 'c.item_id')
      .select(['c.listing_id', 'c.item_id', 'c.qty', 'i.name', 'i.gst_rate', 'i.sale_price'])
      .where('c.listing_id', 'in', listings.map((l) => l.id)).execute()
    : [];
  // A listing with no components counts as unmapped too.
  for (const l of listings) if (!comps.some((c) => c.listing_id === l.id)) unmapped.push(l.channel_sku);
  if (unmapped.length) return { ...base, unmappedSkus: unmapped, action: 'blocked', reason: `Map ${unmapped.length === 1 ? 'this SKU' : 'these SKUs'} to items first: ${unmapped.join(', ')}.` };

  const lines: PlannedLine[] = [];
  for (const ol of order.lines) {
    const listing = listings.find((l) => l.channel_sku === ol.sku)!;
    const parts = comps.filter((c) => c.listing_id === listing.id);
    // What the buyer paid for this line, after discount; split across components by their sale price.
    const paid = Math.max(ol.unitPrice * ol.qty - ol.discount, 0);
    const weights = parts.map((p) => p.qty * (p.sale_price > 0 ? p.sale_price : 1));
    const wsum = weights.reduce((s, w) => s + w, 0);
    parts.forEach((p, i) => {
      const share = i === parts.length - 1
        ? paid - parts.slice(0, -1).reduce((s, _q, j) => s + round2(paid * weights[j]! / wsum), 0)
        : round2(paid * weights[i]! / wsum);
      const qty = Math.round(ol.qty * p.qty * 1000) / 1000;
      const gross = share / qty;
      const rate = round2(order.taxInclusive ? gross / (1 + p.gst_rate / 100) : gross);
      lines.push({ channelSku: ol.sku, itemId: p.item_id, itemName: p.name, qty, rate, gstRate: p.gst_rate });
    });
  }
  const loc = await tx.selectFrom('locations').select('state_code').where('id', '=', conn.location_id).executeTakeFirstOrThrow();
  const party = await tx.selectFrom('parties').select('state_code').where('id', '=', conn.party_id).executeTakeFirstOrThrow();
  const pos = order.shipToState ?? party.state_code ?? loc.state_code;
  const g = computeGst(loc.state_code, pos, lines.map((l) => ({ qty: l.qty, rate: l.rate, discountPct: 0, gstRate: l.gstRate })));
  return { ...base, action: 'create', reason: null, lines, estimate: { subtotal: g.subtotal, taxTotal: g.taxTotal, total: g.total } };
}

export interface Outcome {
  externalRef: string; action: OrderAction; status: 'processed' | 'ignored' | 'failed'; errorCode: string | null; message: string | null;
  salesOrderId: string | null; salesOrderNumber: string | null; heldAsDraft: boolean;
}

async function writeInbox(tx: Tx, ctx: RequestContext, conn: Connection, order: NormalisedOrder, o: Omit<Outcome, 'salesOrderNumber' | 'heldAsDraft'>, total: number | null, source: string) {
  const row = {
    tenant_id: ctx.tenantId, company_id: ctx.companyId, connection_id: conn.id, event_id: order.externalRef, topic: 'order',
    source, payload: JSON.stringify(order), status: o.status, error: o.message, error_code: o.errorCode,
    sales_order_id: o.salesOrderId, order_date: order.orderDate || null, total,
  };
  await tx.insertInto('channel_inbox').values(row as never)
    .onConflict((oc) => oc.columns(['connection_id', 'event_id']).doUpdateSet((eb) => ({
      payload: eb.ref('excluded.payload'), status: eb.ref('excluded.status'), error: eb.ref('excluded.error'),
      error_code: eb.ref('excluded.error_code'), sales_order_id: eb.ref('excluded.sales_order_id'),
      total: eb.ref('excluded.total'), attempts: sql<number>`channel_inbox.attempts + 1`, updated_at: sql<Date>`now()`,
    }))).execute();
}

async function noteUnmapped(tx: Tx, ctx: RequestContext, conn: Connection, order: NormalisedOrder, skus: string[]) {
  for (const sku of skus) {
    const title = order.lines.find((l) => l.sku === sku)?.title ?? null;
    await tx.insertInto('channel_unmapped').values({ tenant_id: ctx.tenantId, connection_id: conn.id, channel_sku: sku, title })
      .onConflict((oc) => oc.columns(['connection_id', 'channel_sku']).doUpdateSet({
        seen_count: sql<number>`channel_unmapped.seen_count + 1`, last_seen_at: sql<Date>`now()`,
      })).execute();
  }
}

/**
 * Turns one channel order into a sales order (confirmed, with stock reserved, unless the channel is set to keep drafts or stock
 * is short). Runs in its own savepoint so one bad order never undoes the others. Importing the same order id again does nothing.
 */
export async function processOrder(tx: Tx, ctx: RequestContext, conn: Connection, order: NormalisedOrder, source = 'csv'): Promise<Outcome> {
  const blank = { externalRef: order.externalRef, salesOrderNumber: null, heldAsDraft: false };
  const day = order.orderDate || todayIst();
  const withDate = { ...order, orderDate: day };
  await sql`savepoint channel_order`.execute(tx);
  try {
    const plan = await planOrder(tx, ctx, conn, withDate);
    if (plan.action === 'duplicate') {
      await sql`release savepoint channel_order`.execute(tx);
      return { ...blank, action: 'duplicate', status: 'processed', errorCode: null, message: plan.reason, salesOrderId: plan.existingOrderId };
    }
    if (plan.action === 'ignored') {
      await writeInbox(tx, ctx, conn, withDate, { externalRef: order.externalRef, action: 'ignored', status: 'ignored', errorCode: null, message: plan.reason, salesOrderId: null }, null, source);
      await sql`release savepoint channel_order`.execute(tx);
      return { ...blank, action: 'ignored', status: 'ignored', errorCode: null, message: plan.reason, salesOrderId: null };
    }
    if (plan.action === 'blocked') {
      await noteUnmapped(tx, ctx, conn, withDate, plan.unmappedSkus);
      await writeInbox(tx, ctx, conn, withDate, { externalRef: order.externalRef, action: 'blocked', status: 'failed', errorCode: 'UNMAPPED_SKU', message: plan.reason, salesOrderId: null }, null, source);
      await sql`release savepoint channel_order`.execute(tx);
      return { ...blank, action: 'blocked', status: 'failed', errorCode: 'UNMAPPED_SKU', message: plan.reason, salesOrderId: null };
    }
    if (plan.action === 'cancel') {
      const id = plan.existingOrderId!;
      try {
        await sql`savepoint channel_cancel`.execute(tx);
        await cancelOrder(tx, ctx, id, { reason: 'Cancelled on the channel' });
        await sql`release savepoint channel_cancel`.execute(tx);
        await writeInbox(tx, ctx, conn, withDate, { externalRef: order.externalRef, action: 'cancel', status: 'processed', errorCode: null, message: 'Order cancelled and stock released.', salesOrderId: id }, null, source);
        await sql`release savepoint channel_order`.execute(tx);
        return { ...blank, action: 'cancel', status: 'processed', errorCode: null, message: 'Order cancelled and stock released.', salesOrderId: id };
      } catch (err) {
        if (!(err instanceof AppError)) throw err;
        await sql`rollback to savepoint channel_cancel`.execute(tx);
        const msg = `Cancelled on the channel but not here: ${err.message} Raise a sales return if goods were sent.`;
        await writeInbox(tx, ctx, conn, withDate, { externalRef: order.externalRef, action: 'cancel', status: 'failed', errorCode: err.code, message: msg, salesOrderId: id }, null, source);
        await sql`release savepoint channel_order`.execute(tx);
        return { ...blank, action: 'cancel', status: 'failed', errorCode: err.code, message: msg, salesOrderId: id };
      }
    }
    const id = await createOrder(tx, ctx, {
      locationId: conn.location_id, partyId: conn.party_id, orderDate: day, externalRef: order.externalRef, source: 'channel',
      channelId: conn.id, placeOfSupply: order.shipToState ?? undefined, notes: `${conn.name} order ${order.externalRef}${order.buyerName ? ` for ${order.buyerName}` : ''}`,
      createdNote: `Imported from ${conn.name}`,
      lines: plan.lines.map((l) => ({ itemId: l.itemId, qty: l.qty, rate: l.rate, discountPct: 0, description: undefined, allowBackorder: false })),
    } as Parameters<typeof createOrder>[2]);
    let held = false;
    let message: string | null = null;
    let code: string | null = null;
    if (conn.order_status === 'confirmed') {
      await sql`savepoint channel_confirm`.execute(tx);
      try {
        await confirmOrder(tx, ctx, id);
        await sql`release savepoint channel_confirm`.execute(tx);
      } catch (err) {
        if (!(err instanceof AppError) || err.code !== 'INSUFFICIENT_STOCK') throw err;
        await sql`rollback to savepoint channel_confirm`.execute(tx);
        held = true; code = 'INSUFFICIENT_STOCK'; message = 'Not enough stock to confirm. The order is kept as a draft.';
      }
    }
    const num = await tx.selectFrom('sales_orders').select('number').where('id', '=', id).executeTakeFirstOrThrow();
    await writeInbox(tx, ctx, conn, withDate, { externalRef: order.externalRef, action: 'create', status: 'processed', errorCode: code, message, salesOrderId: id }, plan.estimate?.total ?? null, source);
    await sql`release savepoint channel_order`.execute(tx);
    return { ...blank, action: 'create', status: 'processed', errorCode: code, message, salesOrderId: id, salesOrderNumber: num.number, heldAsDraft: held };
  } catch (err) {
    await sql`rollback to savepoint channel_order`.execute(tx);
    if (!(err instanceof AppError)) throw err;
    const msg = err.message;
    await writeInbox(tx, ctx, conn, withDate, { externalRef: order.externalRef, action: 'blocked', status: 'failed', errorCode: err.code, message: msg, salesOrderId: null }, null, source);
    return { ...blank, action: 'blocked', status: 'failed', errorCode: err.code, message: msg, salesOrderId: null };
  }
}
