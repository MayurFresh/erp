import { assertFresh } from '../lib/stale.ts';
import { convertUnits, enteredJson, enteredOf, enteredPreview, saveEntered } from '../lib/uom.ts';
import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { assertGstRates } from '../lib/rates.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { registerApprovalDoc, requestApproval } from './approvals.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { recomputePoStatus } from './p2p-match.ts';
import { documentRoute } from '../lib/openapi.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

export const poLineBody = z.object({
  itemId: z.uuid(),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
  rate: moneyField.optional(),
  discountPct: percentField.optional(),
  description: optionalText(300),
  /** Unit the quantity and rate are entered in (an alternate unit of the item); omitted means the base unit. */
  unit: z.string().trim().max(20).optional(),
});
const poBody = z.object({
  locationId: z.uuid(),
  partyId: z.uuid(),
  orderDate: docDate.optional(),
  expectedDate: docDate.nullable().optional(),
  notes: optionalText(1000),
  lines: z.array(poLineBody).min(1, 'Add at least one line').max(200, 'At most 200 lines'),
});
type PoBody = z.infer<typeof poBody>;
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(['draft', 'pending_approval', 'approved', 'sent', 'partially_received', 'received', 'closed', 'cancelled']).optional(),
  from: dateField.optional(),
  to: dateField.optional(),
  locationId: z.uuid().optional(),
  partyId: z.uuid().optional(),
});
const settingsBody = z.object({
  receiptTolerancePct: percentField,
  priceTolerancePct: percentField,
  countApprovalValue: moneyField,
});

/** Validates a PO body and works out the tax. Shared by create, edit and the reorder generator. */
export async function preparePo(tx: Tx, ctx: RequestContext, body: PoBody) {
  const location = await getLocation(tx, ctx, body.locationId);
  if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
  const party = await tx.selectFrom('parties').selectAll()
    .where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!party) throw badRequest('Vendor not found.', { partyId: 'Not found' });
  if (party.type === 'customer') throw badRequest('Choose a vendor, not a customer.', { partyId: 'Not a vendor' });
  const orderDate = body.orderDate ?? todayIst();
  if (body.expectedDate && body.expectedDate < orderDate) {
    throw badRequest('Expected date cannot be before the order date.', { expectedDate: 'Before order date' });
  }
  await convertUnits(tx, ctx, body.lines);
  const ids = [...new Set(body.lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').selectAll().where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const byId = new Map(items.map((i) => [i.id, i]));
  const lines = body.lines.map((l, idx) => {
    const item = byId.get(l.itemId);
    if (!item) throw badRequest(`Line ${idx + 1}: item not found.`, { [`lines.${idx}.itemId`]: 'Not found' });
    if (!item.is_active) throw badRequest(`Line ${idx + 1}: ${item.name} is inactive.`, { [`lines.${idx}.itemId`]: 'Inactive' });
    return { item, qty: l.qty, rate: l.rate ?? item.purchase_price, discountPct: l.discountPct ?? 0, description: l.description ?? item.name };
  });
  await assertGstRates(tx, orderDate, lines.map((l, idx) => ({
    rate: l.item.gst_rate, hsn: l.item.hsn_code, field: `lines.${idx}.itemId`, label: `${l.item.name} (line ${idx + 1})`,
  })), ctx.companyId);
  const gst = computeGst(location.state_code, party.state_code ?? location.state_code,
    lines.map((l) => ({ qty: l.qty, rate: l.rate, discountPct: l.discountPct, gstRate: l.item.gst_rate })));
  return { location, party, orderDate, fy: financialYear(orderDate), lines, gst, entered: enteredOf(body.lines) };
}

function lineValues(ctx: RequestContext, poId: string, p: Awaited<ReturnType<typeof preparePo>>) {
  return p.lines.map((l, i) => {
    const g = p.gst.lines[i]!;
    return {
      tenant_id: ctx.tenantId, purchase_order_id: poId, line_no: i + 1, item_id: l.item.id, description: l.description,
      hsn_code: l.item.hsn_code, qty: l.qty, unit: l.item.unit, rate: l.rate, discount_pct: l.discountPct,
      taxable_value: g.taxableValue, gst_rate: l.item.gst_rate, cgst: g.cgst, sgst: g.sgst, igst: g.igst, line_total: g.lineTotal,
    };
  });
}

function poSelect(tx: Tx) {
  return tx.selectFrom('purchase_orders as o')
    .innerJoin('locations as l', 'l.id', 'o.location_id')
    .innerJoin('parties as p', 'p.id', 'o.party_id')
    .innerJoin('users as u', 'u.id', 'o.created_by')
    .selectAll('o')
    .select(['l.name as location_name', 'p.name as party_name', 'p.gstin as party_gstin', 'u.name as created_by_name']);
}
type PoRow = Awaited<ReturnType<ReturnType<typeof poSelect>['executeTakeFirstOrThrow']>>;

function poJson(r: PoRow) {
  return {
    id: r.id, number: r.number, status: r.status, fy: r.fy, orderDate: r.order_date, expectedDate: r.expected_date,
    locationId: r.location_id, locationName: r.location_name, partyId: r.party_id, partyName: r.party_name, partyGstin: r.party_gstin,
    placeOfSupply: r.place_of_supply, supplyType: r.supply_type, subtotal: r.subtotal, cgst: r.cgst, sgst: r.sgst, igst: r.igst,
    taxTotal: round2(r.cgst + r.sgst + r.igst), roundOff: r.round_off, total: r.total, notes: r.notes,
    approvalRequestId: r.approval_request_id, submittedAt: r.submitted_at, approvedAt: r.approved_at, sentAt: r.sent_at,
    cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason, createdAt: r.created_at, updatedAt: r.updated_at,
    createdBy: { id: r.created_by, name: r.created_by_name },
  };
}

async function loadLines(tx: Tx, poId: string) {
  return tx.selectFrom('purchase_order_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.id', 'l.line_no', 'l.item_id', 'i.name as item_name', 'i.sku', 'l.description', 'l.hsn_code', 'l.qty', 'l.unit',
      'l.rate', 'l.discount_pct', 'l.gst_rate', 'l.taxable_value', 'l.cgst', 'l.sgst', 'l.igst', 'l.line_total',
      'l.received_qty', 'l.rejected_qty', 'l.billed_qty', 'l.cancelled_qty', 'l.entered_unit', 'l.entered_qty'])
    .where('l.purchase_order_id', '=', poId).orderBy('l.line_no').execute();
}

const r3 = (n: number) => Math.round(n * 1000) / 1000;

function linesJson(lines: Awaited<ReturnType<typeof loadLines>>) {
  return lines.map((l) => ({
    id: l.id, lineNo: l.line_no, itemId: l.item_id, itemName: l.item_name, sku: l.sku, description: l.description, hsnCode: l.hsn_code,
    qty: l.qty, unit: l.unit, rate: l.rate, discountPct: l.discount_pct, gstRate: l.gst_rate, taxableValue: l.taxable_value,
    cgst: l.cgst, sgst: l.sgst, igst: l.igst, lineTotal: l.line_total, receivedQty: l.received_qty, rejectedQty: l.rejected_qty,
    billedQty: l.billed_qty, cancelledQty: l.cancelled_qty, ...enteredJson(l), openQty: Math.max(0, r3(l.qty - l.cancelled_qty - l.received_qty)),
  }));
}

function progress(lines: Awaited<ReturnType<typeof loadLines>>) {
  return {
    ordered: r3(lines.reduce((s, l) => s + l.qty, 0)), received: r3(lines.reduce((s, l) => s + l.received_qty, 0)),
    billed: r3(lines.reduce((s, l) => s + l.billed_qty, 0)), cancelled: r3(lines.reduce((s, l) => s + l.cancelled_qty, 0)),
  };
}

export async function loadPo(tx: Tx, ctx: RequestContext, id: string, detail = true) {
  const row = await poSelect(tx).where('o.id', '=', id).where('o.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Purchase order');
  const lines = await loadLines(tx, id);
  const base = { ...poJson(row), progress: progress(lines), lines: linesJson(lines) };
  if (!detail) return base;
  const receipts = await tx.selectFrom('goods_receipts').select(['id', 'number', 'receipt_date', 'status'])
    .where('purchase_order_id', '=', id).orderBy('created_at').execute();
  const bills = await tx.selectFrom('purchases').select(['id', 'number', 'bill_date', 'total', 'status'])
    .where('purchase_order_id', '=', id).orderBy('created_at').execute();
  return {
    ...base,
    receipts: receipts.map((g) => ({ id: g.id, number: g.number, receiptDate: g.receipt_date, status: g.status })),
    bills: bills.map((b) => ({ id: b.id, number: b.number, billDate: b.bill_date, total: b.total, status: b.status })),
  };
}

export async function createPo(ctx: RequestContext, tx: Tx, body: PoBody) {
  const p = await preparePo(tx, ctx, body);
  const number = await nextNumber(tx, ctx, 'purchase_order', p.fy);
  const row = await tx.insertInto('purchase_orders').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: p.location.id, party_id: p.party.id, number, fy: p.fy,
    order_date: p.orderDate, expected_date: body.expectedDate ?? null, place_of_supply: p.location.state_code,
    supply_type: p.gst.supplyType, subtotal: p.gst.subtotal, cgst: p.gst.cgst, sgst: p.gst.sgst, igst: p.gst.igst,
    round_off: p.gst.roundOff, total: p.gst.total, notes: body.notes ?? null, approval_request_id: null, submitted_at: null,
    approved_at: null, sent_at: null, cancelled_at: null, cancel_reason: null, created_by: ctx.userId,
  }).returning('id').executeTakeFirstOrThrow();
  await tx.insertInto('purchase_order_lines').values(lineValues(ctx, row.id, p)).execute();
  await saveEntered(tx, 'purchase_order_lines', 'purchase_order_id', row.id, p.entered);
  await writeAudit(tx, auditOf(ctx), 'purchase_order', row.id, 'create', null,
    { number, total: p.gst.total, partyId: p.party.id, locationId: p.location.id });
  return loadPo(tx, ctx, row.id);
}

/** Locks a PO of the active company the caller may access. */
async function lockPo(tx: Tx, ctx: RequestContext, id: string) {
  const row = await tx.selectFrom('purchase_orders').selectAll()
    .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Purchase order');
  return row;
}

registerApprovalDoc('purchase_order', {
  permission: 'purchase_orders.manage',
  create: async (ctx, tx, payload) => {
    const { purchaseOrderId } = parse(z.object({ purchaseOrderId: z.uuid() }), payload);
    const po = await lockPo(tx, ctx, purchaseOrderId);
    if (po.status !== 'pending_approval') throw conflict(`This purchase order is ${po.status.replace('_', ' ')}.`, 'INVALID_STATE');
    await tx.updateTable('purchase_orders').set({ status: 'approved', approved_at: new Date(), updated_at: new Date() })
      .where('id', '=', po.id).execute();
    await writeAudit(tx, auditOf(ctx), 'purchase_order', po.id, 'approve', { status: 'pending_approval' }, { status: 'approved' });
    return { id: po.id, number: po.number };
  },
  onDecline: async (ctx, tx, payload) => {
    const { purchaseOrderId } = parse(z.object({ purchaseOrderId: z.uuid() }), payload);
    const res = await tx.updateTable('purchase_orders').set({ status: 'draft', approval_request_id: null, updated_at: new Date() })
      .where('id', '=', purchaseOrderId).where('status', '=', 'pending_approval').returning('id').executeTakeFirst();
    if (res) await writeAudit(tx, auditOf(ctx), 'purchase_order', res.id, 'approval_declined', { status: 'pending_approval' }, { status: 'draft' });
  },
});

const invalidState = (po: { status: string }, action: string) =>
  conflict(`A ${po.status.replace('_', ' ')} purchase order cannot be ${action}.`, 'INVALID_STATE');

export async function purchaseOrderRoutes(app: FastifyInstance) {
  app.get('/p2p/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.view');
    return ctx.tx(async (tx) => {
      const c = await tx.selectFrom('companies').select(['po_receipt_tolerance_pct', 'po_price_tolerance_pct', 'count_approval_value'])
        .where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      return { receiptTolerancePct: c.po_receipt_tolerance_pct, priceTolerancePct: c.po_price_tolerance_pct, countApprovalValue: c.count_approval_value };
    });
  });

  app.put('/p2p/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('companies').select(['po_receipt_tolerance_pct', 'po_price_tolerance_pct', 'count_approval_value'])
        .where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      await tx.updateTable('companies').set({
        po_receipt_tolerance_pct: b.receiptTolerancePct, po_price_tolerance_pct: b.priceTolerancePct, count_approval_value: b.countApprovalValue,
      }).where('id', '=', ctx.companyId).execute();
      await writeAudit(tx, auditOf(ctx), 'company', ctx.companyId, 'p2p_settings', before, b);
      return b;
    });
  });

  app.get('/purchase-orders', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = poSelect(tx).where('o.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('o.location_id', 'in', scope);
      if (q.status) base = base.where('o.status', '=', q.status);
      if (q.from) base = base.where('o.order_date', '>=', q.from);
      if (q.to) base = base.where('o.order_date', '<=', q.to);
      if (q.locationId) base = base.where('o.location_id', '=', q.locationId);
      if (q.partyId) base = base.where('o.party_id', '=', q.partyId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('o.number', 'ilike', t), eb('p.name', 'ilike', t), eb('o.notes', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('o.order_date', 'desc').orderBy('o.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      const ids = rows.map((r) => r.id);
      const sums = ids.length
        ? await tx.selectFrom('purchase_order_lines').select((eb) => ['purchase_order_id', eb.fn.sum<number>('qty').as('ordered'),
          eb.fn.sum<number>('received_qty').as('received'), eb.fn.sum<number>('billed_qty').as('billed'),
          eb.fn.sum<number>('cancelled_qty').as('cancelled')]).where('purchase_order_id', 'in', ids).groupBy('purchase_order_id').execute()
        : [];
      const by = new Map(sums.map((s) => [s.purchase_order_id, s]));
      return {
        data: rows.map((r) => {
          const s = by.get(r.id);
          return { ...poJson(r), progress: { ordered: Number(s?.ordered ?? 0), received: Number(s?.received ?? 0), billed: Number(s?.billed ?? 0), cancelled: Number(s?.cancelled ?? 0) } };
        }),
        total,
      };
    });
  });

  app.get<{ Params: { id: string } }>('/purchase-orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadPo(tx, ctx, id));
  });

  app.post('/purchase-orders', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const body = parse(poBody, req.body);
    return reply.status(201).send(await ctx.tx((tx) => createPo(ctx, tx, body)));
  });

  app.post('/purchase-orders/preview', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const body = parse(poBody, req.body);
    return ctx.tx(async (tx) => {
      const p = await preparePo(tx, ctx, body);
      return {
        id: null, number: null, status: 'draft', placeOfSupply: p.location.state_code, supplyType: p.gst.supplyType,
        subtotal: p.gst.subtotal, cgst: p.gst.cgst, sgst: p.gst.sgst, igst: p.gst.igst,
        taxTotal: round2(p.gst.cgst + p.gst.sgst + p.gst.igst), roundOff: p.gst.roundOff, total: p.gst.total,
        lines: p.lines.map((l, i) => {
          const g = p.gst.lines[i]!;
          return {
            itemId: l.item.id, description: l.description, hsnCode: l.item.hsn_code, qty: l.qty, unit: l.item.unit, rate: l.rate,
            ...enteredPreview(p.entered[i], l.qty, l.rate),
            discountPct: l.discountPct, taxableValue: g.taxableValue, gstRate: l.item.gst_rate, cgst: g.cgst, sgst: g.sgst,
            igst: g.igst, lineTotal: g.lineTotal,
          };
        }),
      };
    });
  });

  const updatePo = async (req: FastifyRequest<{ Params: { id: string } }>) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(poBody.extend({ expectedUpdatedAt: z.string().max(40).optional() }), req.body);
    return ctx.tx(async (tx) => {
      const po = await lockPo(tx, ctx, id);
      assertFresh(po.updated_at, body.expectedUpdatedAt, 'purchase order');
      if (po.status !== 'draft') throw conflict('Only a draft purchase order can be edited.', 'NOT_EDITABLE');
      const p = await preparePo(tx, ctx, body);
      await tx.updateTable('purchase_orders').set({
        location_id: p.location.id, party_id: p.party.id, order_date: p.orderDate, fy: p.fy, expected_date: body.expectedDate ?? null,
        place_of_supply: p.location.state_code, supply_type: p.gst.supplyType, subtotal: p.gst.subtotal, cgst: p.gst.cgst,
        sgst: p.gst.sgst, igst: p.gst.igst, round_off: p.gst.roundOff, total: p.gst.total, notes: body.notes ?? null, updated_at: new Date(),
      }).where('id', '=', id).execute();
      await tx.deleteFrom('purchase_order_lines').where('purchase_order_id', '=', id).execute();
      await tx.insertInto('purchase_order_lines').values(lineValues(ctx, id, p)).execute();
      await saveEntered(tx, 'purchase_order_lines', 'purchase_order_id', id, p.entered);
      await writeAudit(tx, auditOf(ctx), 'purchase_order', id, 'update', { total: po.total }, { total: p.gst.total });
      return loadPo(tx, ctx, id);
    });
  };
  app.put<{ Params: { id: string } }>('/purchase-orders/:id', updatePo);
  app.patch<{ Params: { id: string } }>('/purchase-orders/:id', updatePo);

  app.post<{ Params: { id: string } }>('/purchase-orders/:id/submit', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const po = await lockPo(tx, ctx, id);
      if (po.status !== 'draft') throw invalidState(po, 'submitted');
      const request = await requestApproval(ctx, tx, 'purchase_order', { purchaseOrderId: id },
        { amount: po.total, date: po.order_date, partyId: po.party_id, locationId: po.location_id, narration: po.notes });
      if (request) {
        await tx.updateTable('purchase_orders').set({
          status: 'pending_approval', approval_request_id: request.id, submitted_at: new Date(), updated_at: new Date(),
        }).where('id', '=', id).execute();
      } else {
        await tx.updateTable('purchase_orders').set({
          status: 'approved', submitted_at: new Date(), approved_at: new Date(), updated_at: new Date(),
        }).where('id', '=', id).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'purchase_order', id, 'submit', { status: 'draft' }, { status: request ? 'pending_approval' : 'approved' });
      return loadPo(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/purchase-orders/:id/send', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const po = await lockPo(tx, ctx, id);
      if (po.status !== 'approved' && po.status !== 'sent') throw invalidState(po, 'sent');
      await tx.updateTable('purchase_orders').set({ status: 'sent', sent_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'purchase_order', id, 'send', { status: po.status }, { status: 'sent' });
      return loadPo(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/purchase-orders/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const po = await lockPo(tx, ctx, id);
      if (po.status === 'cancelled') throw conflict('This purchase order is already cancelled.', 'ALREADY_CANCELLED');
      if (po.status === 'received' || po.status === 'closed') throw conflict('Everything on this purchase order has been received.', 'FULLY_RECEIVED');
      const lines = await tx.selectFrom('purchase_order_lines').select(['id', 'qty', 'received_qty']).where('purchase_order_id', '=', id).execute();
      for (const l of lines) {
        await tx.updateTable('purchase_order_lines').set({ cancelled_qty: Math.max(0, r3(l.qty - l.received_qty)) }).where('id', '=', l.id).execute();
      }
      const anyReceived = lines.some((l) => l.received_qty > 0.0005);
      if (po.status === 'pending_approval' && po.approval_request_id) {
        const pending = await tx.updateTable('approval_requests').set({ status: 'cancelled', decided_at: new Date() })
          .where('id', '=', po.approval_request_id).where('status', '=', 'pending').returning('id').executeTakeFirst();
        if (pending) {
          await tx.insertInto('approval_actions').values({
            tenant_id: ctx.tenantId, request_id: pending.id, level: null, action: 'cancelled', user_id: ctx.userId, comment: null,
          }).execute();
        }
      }
      if (!anyReceived) {
        await tx.updateTable('purchase_orders').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason, updated_at: new Date() })
          .where('id', '=', id).execute();
      } else {
        await recomputePoStatus(tx, id);
        await tx.updateTable('purchase_orders').set({ cancel_reason: `Remaining quantity cancelled: ${reason}`, updated_at: new Date() }).where('id', '=', id).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'purchase_order', id, 'cancel', { status: po.status }, { reason, remainingOnly: anyReceived });
      return loadPo(tx, ctx, id);
    });
  });
}

documentRoute('PUT', '/p2p/settings', { body: settingsBody });
documentRoute('POST', '/purchase-orders', { body: poBody });
documentRoute('POST', '/purchase-orders/preview', { body: poBody });
documentRoute('POST', '/purchase-orders/:id/cancel', { body: cancelBody });
