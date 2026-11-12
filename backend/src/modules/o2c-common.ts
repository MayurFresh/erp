import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { notFound } from '../lib/errors.ts';
import { auditOf, writeAudit } from './audit.ts';

export const round3 = (n: number) => Math.round(n * 1000) / 1000;
export const round2 = (n: number) => Math.round(n * 100) / 100;
export const EPS = 0.0005;

/** Order statuses in which stock can still be picked, packed or dispatched. */
export const FULFILLABLE = ['confirmed', 'picking', 'packed', 'partially_dispatched'] as const;

export async function addEvent(tx: Tx, ctx: RequestContext, orderId: string, kind: string, message: string) {
  await tx.insertInto('sales_order_events').values({
    tenant_id: ctx.tenantId, order_id: orderId, kind, message: message.slice(0, 500), created_by: ctx.userId,
  }).execute();
}

/** Locks and returns an order the caller may see. */
export async function lockOrder(tx: Tx, ctx: RequestContext, id: string) {
  const o = await tx.selectFrom('sales_orders').selectAll()
    .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!o || !ctx.canAccessLocation(o.location_id)) throw notFound('Sales order');
  return o;
}

export async function lockLines(tx: Tx, orderId: string) {
  return tx.selectFrom('sales_order_lines').selectAll().where('order_id', '=', orderId).orderBy('line_no').forUpdate().execute();
}

export type OrderLine = Awaited<ReturnType<typeof lockLines>>[number];

export const openQty = (l: Pick<OrderLine, 'qty_ordered' | 'qty_dispatched' | 'qty_cancelled'>) =>
  round3(l.qty_ordered - l.qty_dispatched - l.qty_cancelled);

/**
 * Moves `qty` of a line's active reservation to `consumed` or `released` and lowers the line's reserved quantity.
 * The reservation row is split when only part of it is used.
 */
export async function closeReservation(tx: Tx, lineId: string, qty: number, to: 'consumed' | 'released', note: string | null = null) {
  if (qty <= EPS) return;
  const rows = await tx.selectFrom('stock_reservations').selectAll()
    .where('order_line_id', '=', lineId).where('status', '=', 'active').orderBy('created_at').forUpdate().execute();
  let left = qty;
  for (const r of rows) {
    if (left <= EPS) break;
    const take = Math.min(r.qty, left);
    if (take >= r.qty - EPS) {
      await tx.updateTable('stock_reservations').set({ status: to, note, updated_at: new Date() }).where('id', '=', r.id).execute();
    } else {
      await tx.updateTable('stock_reservations').set({ qty: round3(r.qty - take), updated_at: new Date() }).where('id', '=', r.id).execute();
      await tx.insertInto('stock_reservations').values({
        tenant_id: r.tenant_id, company_id: r.company_id, location_id: r.location_id, item_id: r.item_id,
        order_line_id: r.order_line_id, qty: round3(take), status: to, note,
      }).execute();
    }
    left = round3(left - take);
  }
}

/** Adds an active reservation for a line (merged into its existing active row). */
export async function addReservation(tx: Tx, ctx: RequestContext, order: { location_id: string }, line: OrderLine, qty: number) {
  if (qty <= EPS) return;
  const existing = await tx.selectFrom('stock_reservations').select(['id', 'qty'])
    .where('order_line_id', '=', line.id).where('status', '=', 'active').forUpdate().executeTakeFirst();
  if (existing) {
    await tx.updateTable('stock_reservations').set({ qty: round3(existing.qty + qty), updated_at: new Date() }).where('id', '=', existing.id).execute();
  } else {
    await tx.insertInto('stock_reservations').values({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: order.location_id, item_id: line.item_id,
      order_line_id: line.id, qty: round3(qty), status: 'active', note: null,
    }).execute();
  }
}

/** Derives the order status from its lines and open pick lists. Draft, cancelled and closed are left alone. */
export async function refreshStatus(tx: Tx, ctx: RequestContext, orderId: string) {
  const order = await tx.selectFrom('sales_orders').select(['id', 'status']).where('id', '=', orderId).executeTakeFirstOrThrow();
  if (['draft', 'cancelled', 'closed'].includes(order.status)) return order.status;
  const lines = await tx.selectFrom('sales_order_lines').selectAll().where('order_id', '=', orderId).execute();
  const open = lines.reduce((s, l) => s + openQty(l), 0);
  const dispatched = lines.reduce((s, l) => s + l.qty_dispatched, 0);
  const reserved = lines.reduce((s, l) => s + l.qty_reserved, 0);
  const packedOut = lines.reduce((s, l) => s + (l.qty_packed - l.qty_dispatched), 0);
  const pickedOut = lines.reduce((s, l) => s + (l.qty_picked - l.qty_dispatched), 0);
  const onList = await tx.selectFrom('pick_list_lines as pl').innerJoin('pick_lists as p', 'p.id', 'pl.pick_list_id')
    .select('pl.id').where('pl.order_id', '=', orderId).where('p.status', '=', 'open').executeTakeFirst();
  let next: string;
  if (open <= EPS) next = dispatched > EPS ? 'dispatched' : 'cancelled';
  else if (dispatched > EPS) next = 'partially_dispatched';
  else if (reserved > EPS && packedOut >= reserved - EPS) next = 'packed';
  else if (pickedOut > EPS || onList) next = 'picking';
  else next = 'confirmed';
  if (next !== order.status) {
    await tx.updateTable('sales_orders').set({
      status: next, updated_at: new Date(),
      ...(next === 'cancelled' ? { cancelled_at: new Date() } : {}),
    }).where('id', '=', orderId).execute();
    await writeAudit(tx, auditOf(ctx), 'sales_order', orderId, 'status', { status: order.status }, { status: next });
  }
  return next;
}
