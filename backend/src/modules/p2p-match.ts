import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { AppError, badRequest, conflict } from '../lib/errors.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const EPS = 0.0005;

/** A goods receipt line a bill line refers to, with the PO terms it was ordered on. */
export interface GrnInfo {
  grnLineId: string; grnId: string; grnNumber: string; itemId: string; itemName: string; locationId: string; partyId: string;
  purchaseOrderId: string; poLineId: string; acceptedQty: number; billedQty: number; unitCost: number; value: number;
  clearedValue: number; poRate: number; discountPct: number;
}

interface BillLineRef { itemId: string; qty: number; rate?: number | undefined; discountPct?: number | undefined; grnLineId?: string | undefined }

/**
 * Loads (and row-locks) the GRN lines named by a bill and checks they can be billed here: same vendor and location,
 * posted receipt, one purchase order, item matches, quantity within what is received and not yet billed.
 */
export async function loadGrnLines(
  tx: Tx, ctx: RequestContext, lines: BillLineRef[], partyId: string, locationId: string,
): Promise<Map<number, GrnInfo>> {
  const out = new Map<number, GrnInfo>();
  const ids = [...new Set(lines.map((l) => l.grnLineId).filter((x): x is string => !!x))];
  if (!ids.length) return out;
  const rows = await tx.selectFrom('goods_receipt_lines as gl')
    .innerJoin('goods_receipts as g', 'g.id', 'gl.goods_receipt_id')
    .innerJoin('purchase_order_lines as pl', 'pl.id', 'gl.po_line_id')
    .innerJoin('items as i', 'i.id', 'gl.item_id')
    .select(['gl.id', 'gl.goods_receipt_id', 'g.number as grn_number', 'g.status', 'g.company_id', 'g.party_id', 'g.location_id',
      'g.purchase_order_id', 'gl.po_line_id', 'gl.item_id', 'i.name as item_name', 'gl.accepted_qty', 'gl.billed_qty',
      'gl.unit_cost', 'gl.value', 'gl.cleared_value', 'pl.rate', 'pl.discount_pct'])
    .where('gl.id', 'in', ids).where('g.company_id', '=', ctx.companyId).forUpdate('gl').execute();
  const byId = new Map(rows.map((r) => [r.id, r]));
  const used = new Map<string, number>();
  lines.forEach((l, idx) => {
    if (!l.grnLineId) return;
    const r = byId.get(l.grnLineId);
    const field = `lines.${idx}.grnLineId`;
    if (!r) throw badRequest(`Line ${idx + 1}: goods receipt line not found.`, { [field]: 'Not found' });
    if (r.status !== 'posted') throw badRequest(`Line ${idx + 1}: ${r.grn_number} is cancelled.`, { [field]: 'Receipt cancelled' });
    if (r.party_id !== partyId) throw badRequest(`Line ${idx + 1}: ${r.grn_number} is from a different vendor.`, { [field]: 'Different vendor' });
    if (r.location_id !== locationId) throw badRequest(`Line ${idx + 1}: ${r.grn_number} was received at a different location.`, { [field]: 'Different location' });
    if (r.item_id !== l.itemId) throw badRequest(`Line ${idx + 1}: the item does not match the goods receipt line.`, { [`lines.${idx}.itemId`]: 'Does not match receipt' });
    used.set(r.id, (used.get(r.id) ?? 0) + l.qty);
    out.set(idx, {
      grnLineId: r.id, grnId: r.goods_receipt_id, grnNumber: r.grn_number, itemId: r.item_id, itemName: r.item_name,
      locationId: r.location_id, partyId: r.party_id, purchaseOrderId: r.purchase_order_id, poLineId: r.po_line_id,
      acceptedQty: r.accepted_qty, billedQty: r.billed_qty, unitCost: r.unit_cost, value: r.value, clearedValue: r.cleared_value,
      poRate: r.rate, discountPct: r.discount_pct,
    });
  });
  if (new Set([...out.values()].map((g) => g.purchaseOrderId)).size > 1) {
    throw badRequest('One bill can match goods from one purchase order only.', { lines: 'Several purchase orders' });
  }
  const over = [...used].flatMap(([id, qty]) => {
    const r = byId.get(id)!;
    const billable = Math.round((r.accepted_qty - r.billed_qty) * 1000) / 1000;
    return qty > billable + EPS ? [{ grnLineId: id, itemName: r.item_name, billable, billing: qty }] : [];
  });
  if (over.length) {
    throw new AppError(400, 'OVER_BILLED',
      `You can bill ${over[0]!.billable} of ${over[0]!.itemName}, not ${over[0]!.billing}.`, { lines: over });
  }
  return out;
}

/** Bill price against PO price; returns the lines that differ by more than the tolerance percent. */
export function priceVariances(
  lines: { index: number; qty: number; rate: number; discountPct: number }[], grn: Map<number, GrnInfo>, tolerancePct: number,
) {
  const out: Record<string, unknown>[] = [];
  for (const l of lines) {
    const g = grn.get(l.index);
    if (!g) continue;
    const billNet = l.rate * (1 - l.discountPct / 100);
    const poNet = g.poRate * (1 - g.discountPct / 100);
    const pct = poNet > 0 ? (Math.abs(billNet - poNet) / poNet) * 100 : billNet > 0 ? 100 : 0;
    if (pct > tolerancePct + 0.0001) {
      out.push({
        index: l.index, grnLineId: g.grnLineId, itemName: g.itemName, poRate: round2(poNet), billRate: round2(billNet),
        variancePct: Math.round(pct * 100) / 100, varianceValue: round2((billNet - poNet) * l.qty),
      });
    }
  }
  return out;
}

export function priceVarianceError(items: Record<string, unknown>[]) {
  return conflict('The bill price differs from the purchase order.', 'PRICE_VARIANCE', { lines: items });
}

/** Moves bill quantity onto GRN and PO lines after a bill is saved. */
export async function applyGrnBilling(
  tx: Tx, entries: { grnLineId: string; poLineId: string; purchaseOrderId: string; qty: number; clearing: number }[],
) {
  for (const e of entries) {
    await tx.updateTable('goods_receipt_lines')
      .set((eb) => ({ billed_qty: eb('billed_qty', '+', e.qty), cleared_value: eb('cleared_value', '+', e.clearing) }))
      .where('id', '=', e.grnLineId).execute();
    await tx.updateTable('purchase_order_lines').set((eb) => ({ billed_qty: eb('billed_qty', '+', e.qty) }))
      .where('id', '=', e.poLineId).execute();
  }
  for (const id of new Set(entries.map((e) => e.purchaseOrderId))) await recomputePoStatus(tx, id);
}

/** Undoes `applyGrnBilling` for a cancelled bill. */
export async function releaseGrnBilling(tx: Tx, purchaseId: string) {
  const rows = await tx.selectFrom('purchase_lines as l')
    .innerJoin('goods_receipt_lines as gl', 'gl.id', 'l.grn_line_id')
    .innerJoin('goods_receipts as g', 'g.id', 'gl.goods_receipt_id')
    .select(['l.grn_line_id', 'l.qty', 'l.grni_value', 'gl.po_line_id', 'g.purchase_order_id'])
    .where('l.purchase_id', '=', purchaseId).where('l.grn_line_id', 'is not', null).execute();
  for (const r of rows) {
    await tx.updateTable('goods_receipt_lines')
      .set((eb) => ({ billed_qty: eb('billed_qty', '-', r.qty), cleared_value: eb('cleared_value', '-', r.grni_value) }))
      .where('id', '=', r.grn_line_id!).execute();
    await tx.updateTable('purchase_order_lines').set((eb) => ({ billed_qty: eb('billed_qty', '-', r.qty) }))
      .where('id', '=', r.po_line_id).execute();
  }
  for (const id of new Set(rows.map((r) => r.purchase_order_id))) await recomputePoStatus(tx, id);
}

/** Derives the PO status from received, billed and cancelled quantities (only once the PO is approved). */
export async function recomputePoStatus(tx: Tx, poId: string): Promise<string> {
  const po = await tx.selectFrom('purchase_orders').select(['status', 'sent_at']).where('id', '=', poId).executeTakeFirstOrThrow();
  if (['draft', 'pending_approval', 'cancelled'].includes(po.status)) return po.status;
  const lines = await tx.selectFrom('purchase_order_lines').select(['qty', 'cancelled_qty', 'received_qty', 'billed_qty'])
    .where('purchase_order_id', '=', poId).execute();
  const effective = (l: { qty: number; cancelled_qty: number }) => l.qty - l.cancelled_qty;
  const received = lines.reduce((s, l) => s + l.received_qty, 0);
  const ordered = lines.reduce((s, l) => s + effective(l), 0);
  let next: string;
  if (ordered < EPS && received < EPS) next = 'cancelled';
  else if (lines.every((l) => l.received_qty >= effective(l) - EPS)) {
    next = lines.every((l) => l.billed_qty >= l.received_qty - EPS) ? 'closed' : 'received';
  } else if (received > EPS) next = 'partially_received';
  else next = po.sent_at ? 'sent' : 'approved';
  if (next !== po.status) {
    await tx.updateTable('purchase_orders')
      .set({ status: next, updated_at: new Date(), ...(next === 'cancelled' ? { cancelled_at: new Date(), cancel_reason: 'All quantity cancelled' } : {}) })
      .where('id', '=', poId).execute();
  }
  return next;
}
