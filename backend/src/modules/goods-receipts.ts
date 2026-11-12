import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { lockItems } from '../accounting/costing.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { recomputePoStatus } from './p2p-match.ts';
import { requireStock } from './stock.ts';
import { documentRoute } from '../lib/openapi.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const round3 = (n: number) => Math.round(n * 1000) / 1000;
const round4 = (n: number) => Math.round(n * 10_000) / 10_000;

const lineBody = z.object({
  poLineId: z.uuid(),
  acceptedQty: qtyField.refine((v) => v >= 0, 'Cannot be negative'),
  rejectedQty: qtyField.refine((v) => v >= 0, 'Cannot be negative').optional(),
  rejectReason: optionalText(200),
});
const createBody = z.object({
  purchaseOrderId: z.uuid(),
  locationId: z.uuid().optional(),
  receiptDate: docDate.optional(),
  challanNo: optionalText(40),
  challanDate: docDate.optional(),
  vehicleNo: optionalText(20),
  notes: optionalText(1000),
  lines: z.array(lineBody).min(1, 'Add at least one line').max(200, 'At most 200 lines'),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  purchaseOrderId: z.uuid().optional(),
  status: z.enum(['posted', 'cancelled']).optional(),
  locationId: z.uuid().optional(),
});

function grnSelect(tx: Tx) {
  return tx.selectFrom('goods_receipts as g')
    .innerJoin('purchase_orders as o', 'o.id', 'g.purchase_order_id')
    .innerJoin('locations as l', 'l.id', 'g.location_id')
    .innerJoin('parties as p', 'p.id', 'g.party_id')
    .innerJoin('users as u', 'u.id', 'g.created_by')
    .selectAll('g')
    .select(['o.number as po_number', 'l.name as location_name', 'p.name as party_name', 'u.name as created_by_name']);
}
type GrnRow = Awaited<ReturnType<ReturnType<typeof grnSelect>['executeTakeFirstOrThrow']>>;

const grnJson = (r: GrnRow) => ({
  id: r.id, number: r.number, status: r.status, fy: r.fy, receiptDate: r.receipt_date, purchaseOrderId: r.purchase_order_id,
  purchaseOrderNumber: r.po_number, partyId: r.party_id, partyName: r.party_name, locationId: r.location_id,
  locationName: r.location_name, challanNo: r.challan_no, challanDate: r.challan_date, vehicleNo: r.vehicle_no, notes: r.notes,
  createdAt: r.created_at, createdBy: { id: r.created_by, name: r.created_by_name }, cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
});

async function loadGrn(tx: Tx, ctx: RequestContext, id: string) {
  const row = await grnSelect(tx).where('g.id', '=', id).where('g.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Goods receipt');
  const lines = await tx.selectFrom('goods_receipt_lines as gl')
    .innerJoin('items as i', 'i.id', 'gl.item_id').innerJoin('purchase_order_lines as pl', 'pl.id', 'gl.po_line_id')
    .select(['gl.id', 'gl.line_no', 'gl.po_line_id', 'gl.item_id', 'i.name as item_name', 'i.sku', 'i.unit', 'gl.received_qty',
      'gl.accepted_qty', 'gl.rejected_qty', 'gl.reject_reason', 'gl.unit_cost', 'gl.value', 'gl.billed_qty', 'pl.rate', 'pl.discount_pct', 'pl.gst_rate'])
    .where('gl.goods_receipt_id', '=', id).orderBy('gl.line_no').execute();
  return {
    ...grnJson(row),
    lines: lines.map((l) => ({
      id: l.id, lineNo: l.line_no, poLineId: l.po_line_id, itemId: l.item_id, itemName: l.item_name, sku: l.sku, unit: l.unit,
      receivedQty: l.received_qty, acceptedQty: l.accepted_qty, rejectedQty: l.rejected_qty, rejectReason: l.reject_reason,
      poRate: l.rate, discountPct: l.discount_pct, unitCost: l.unit_cost, gstRate: l.gst_rate, value: l.value,
      billedQty: l.billed_qty, billableQty: row.status === 'posted' ? round3(l.accepted_qty - l.billed_qty) : 0,
    })),
  };
}

export async function goodsReceiptRoutes(app: FastifyInstance) {
  app.get('/goods-receipts', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = grnSelect(tx).where('g.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('g.location_id', 'in', scope);
      if (q.purchaseOrderId) base = base.where('g.purchase_order_id', '=', q.purchaseOrderId);
      if (q.status) base = base.where('g.status', '=', q.status);
      if (q.locationId) base = base.where('g.location_id', '=', q.locationId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('g.number', 'ilike', t), eb('o.number', 'ilike', t), eb('p.name', 'ilike', t), eb('g.challan_no', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('g.receipt_date', 'desc').orderBy('g.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(grnJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/goods-receipts/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadGrn(tx, ctx, id));
  });

  app.post('/goods-receipts', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('grn.manage');
    const body = parse(createBody, req.body);
    const saved = await ctx.tx(async (tx) => {
      const po = await tx.selectFrom('purchase_orders').selectAll()
        .where('id', '=', body.purchaseOrderId).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!po || !ctx.canAccessLocation(po.location_id)) throw notFound('Purchase order');
      if (!['approved', 'sent', 'partially_received'].includes(po.status)) {
        throw conflict(`A ${po.status.replace('_', ' ')} purchase order cannot receive goods.`, 'PO_NOT_RECEIVABLE');
      }
      const location = await getLocation(tx, ctx, body.locationId ?? po.location_id);
      if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
      const receiptDate = body.receiptDate ?? todayIst();
      if (receiptDate > todayIst()) throw badRequest('Receipt date cannot be in the future.', { receiptDate: 'In the future' });

      const seen = new Set<string>();
      body.lines.forEach((l, idx) => {
        if (seen.has(l.poLineId)) throw badRequest(`Line ${idx + 1}: this purchase order line is listed twice.`, { [`lines.${idx}.poLineId`]: 'Duplicate' });
        seen.add(l.poLineId);
        const rejected = l.rejectedQty ?? 0;
        if (l.acceptedQty + rejected <= 0) throw badRequest(`Line ${idx + 1}: enter a quantity.`, { [`lines.${idx}.acceptedQty`]: 'Enter a quantity' });
        if (rejected > 0 && !l.rejectReason) throw badRequest(`Line ${idx + 1}: give a reason for the rejected quantity.`, { [`lines.${idx}.rejectReason`]: 'Required' });
      });
      const poLines = await tx.selectFrom('purchase_order_lines as pl').innerJoin('items as i', 'i.id', 'pl.item_id')
        .select(['pl.id', 'pl.item_id', 'pl.qty', 'pl.rate', 'pl.discount_pct', 'pl.received_qty', 'pl.cancelled_qty', 'i.name', 'i.track_stock'])
        .where('pl.purchase_order_id', '=', po.id).forUpdate('pl').execute();
      const byId = new Map(poLines.map((l) => [l.id, l]));
      const tol = (await tx.selectFrom('companies').select('po_receipt_tolerance_pct').where('id', '=', ctx.companyId).executeTakeFirstOrThrow()).po_receipt_tolerance_pct;

      const over: { poLineId: string; itemName: string; allowed: number; receiving: number }[] = [];
      const lines = body.lines.map((l, idx) => {
        const pl = byId.get(l.poLineId);
        if (!pl) throw badRequest(`Line ${idx + 1}: not a line of this purchase order.`, { [`lines.${idx}.poLineId`]: 'Not found' });
        const allowed = round3((pl.qty - pl.cancelled_qty) * (1 + tol / 100));
        const receiving = round3(pl.received_qty + l.acceptedQty);
        if (receiving > allowed + 0.0005) over.push({ poLineId: pl.id, itemName: pl.name, allowed, receiving });
        const unitCost = round4(pl.rate * (1 - pl.discount_pct / 100));
        const rejected = l.rejectedQty ?? 0;
        return {
          pl, accepted: l.acceptedQty, rejected, reason: l.rejectReason ?? null, unitCost,
          value: pl.track_stock ? round2(l.acceptedQty * unitCost) : 0,
        };
      });
      if (over.length) {
        throw new AppError(400, 'OVER_RECEIPT', `${over[0]!.itemName}: ${over[0]!.receiving} would exceed the ${over[0]!.allowed} allowed on the purchase order.`, { lines: over });
      }

      const fy = financialYear(receiptDate);
      const number = await nextNumber(tx, ctx, 'grn', fy);
      const row = await tx.insertInto('goods_receipts').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, purchase_order_id: po.id, party_id: po.party_id, location_id: location.id,
        number, fy, receipt_date: receiptDate, challan_no: body.challanNo ?? null, challan_date: body.challanDate ?? null,
        vehicle_no: body.vehicleNo ?? null, notes: body.notes ?? null, created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('goods_receipt_lines').values(lines.map((l, i) => ({
        tenant_id: ctx.tenantId, goods_receipt_id: row.id, line_no: i + 1, po_line_id: l.pl.id, item_id: l.pl.item_id,
        received_qty: round3(l.accepted + l.rejected), accepted_qty: l.accepted, rejected_qty: l.rejected, reject_reason: l.reason,
        unit_cost: l.unitCost, value: l.value,
      }))).execute();

      const stocked = lines.filter((l) => l.pl.track_stock && l.accepted > 0);
      await lockItems(tx, ctx.companyId, stocked.map((l) => l.pl.item_id));
      if (stocked.length) {
        await tx.insertInto('stock_moves').values(stocked.map((l) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: location.id, item_id: l.pl.item_id, qty: l.accepted,
          rate: l.pl.rate, cost_rate: l.unitCost, value: l.value, ref_type: 'grn', ref_id: row.id, note: number, created_by: ctx.userId,
        }))).execute();
        const acc = await systemAccounts(tx, ctx);
        const value = round2(stocked.reduce((s, l) => s + l.value, 0));
        await postJournal(tx, auditOf(ctx), {
          date: receiptDate, voucherType: 'stock', voucherId: row.id, number,
          narration: `Goods received against ${po.number}`,
          lines: [
            { accountId: acc.inventory, amount: value, locationId: location.id },
            { accountId: acc.grni, amount: -value, locationId: location.id },
          ],
        });
      }
      for (const l of lines) {
        await tx.updateTable('purchase_order_lines').set((eb) => ({
          received_qty: eb('received_qty', '+', l.accepted), rejected_qty: eb('rejected_qty', '+', l.rejected),
        })).where('id', '=', l.pl.id).execute();
      }
      const status = await recomputePoStatus(tx, po.id);
      await writeAudit(tx, auditOf(ctx), 'goods_receipt', row.id, 'create', null,
        { number, purchaseOrder: po.number, locationId: location.id, poStatus: status });
      return loadGrn(tx, ctx, row.id);
    });
    return reply.status(201).send(saved);
  });

  app.post<{ Params: { id: string } }>('/goods-receipts/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('grn.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const g = await tx.selectFrom('goods_receipts').selectAll()
        .where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!g || !ctx.canAccessLocation(g.location_id)) throw notFound('Goods receipt');
      await tx.selectFrom('purchase_orders').select('id').where('id', '=', g.purchase_order_id).forUpdate().execute();
      const cur = await tx.selectFrom('goods_receipts').select('status').where('id', '=', id).forUpdate().executeTakeFirstOrThrow();
      if (cur.status === 'cancelled') throw conflict('This goods receipt is already cancelled.', 'ALREADY_CANCELLED');
      const lines = await tx.selectFrom('goods_receipt_lines').selectAll().where('goods_receipt_id', '=', id).forUpdate().execute();
      if (lines.some((l) => l.billed_qty > 0)) throw conflict('A bill has been raised against this receipt. Cancel the bill first.', 'HAS_BILLS');

      const moves = await tx.selectFrom('stock_moves as m').innerJoin('items as i', 'i.id', 'm.item_id')
        .select(['m.item_id', 'm.location_id', 'm.qty', 'm.rate', 'm.cost_rate', 'm.value', 'i.name', 'i.unit'])
        .where('m.ref_type', '=', 'grn').where('m.ref_id', '=', id).execute();
      await lockItems(tx, ctx.companyId, moves.map((m) => m.item_id));
      const location = await getLocation(tx, ctx, g.location_id);
      for (const m of moves) await requireStock(tx, ctx, location, { id: m.item_id, name: m.name, unit: m.unit }, m.qty);

      await tx.updateTable('goods_receipts').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      if (moves.length) {
        await tx.insertInto('stock_moves').values(moves.map((m) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: m.location_id, item_id: m.item_id, qty: -m.qty,
          rate: m.rate, cost_rate: m.cost_rate, value: -m.value, ref_type: 'grn_cancel', ref_id: id,
          note: `Cancelled ${g.number}`, created_by: ctx.userId,
        }))).execute();
        await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${g.number}: ${reason}`);
      }
      for (const l of lines) {
        await tx.updateTable('purchase_order_lines').set((eb) => ({
          received_qty: eb('received_qty', '-', l.accepted_qty), rejected_qty: eb('rejected_qty', '-', l.rejected_qty),
        })).where('id', '=', l.po_line_id).execute();
      }
      await recomputePoStatus(tx, g.purchase_order_id);
      await writeAudit(tx, auditOf(ctx), 'goods_receipt', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return loadGrn(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/goods-receipts', { body: createBody });
documentRoute('POST', '/goods-receipts/:id/cancel', { body: cancelBody });
