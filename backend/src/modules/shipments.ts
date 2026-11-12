import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { addEvent } from './o2c-common.ts';
import { createReturnFromShipment } from './sales-returns.ts';
import { documentRoute } from '../lib/openapi.ts';

export const SHIPMENT_STATUSES = ['booked', 'in_transit', 'delivered', 'rto_initiated', 'rto_delivered', 'lost'] as const;
const NEXT: Record<string, string[]> = {
  booked: ['in_transit'],
  in_transit: ['delivered', 'rto_initiated', 'lost'],
  rto_initiated: ['rto_delivered', 'lost', 'delivered'],
  delivered: [], rto_delivered: [], lost: [],
};
const FINAL = ['delivered', 'rto_delivered', 'lost'];

const statusBody = z.object({
  status: z.enum(SHIPMENT_STATUSES),
  note: optionalText(300),
  courier: optionalText(100),
  awb: optionalText(60),
});
const patchBody = z.object({ courier: optionalText(100), awb: optionalText(60), notes: optionalText(500) });
const listQuery = pagingQuery.extend({
  status: z.enum(SHIPMENT_STATUSES).optional(),
  mode: z.enum(['prepaid', 'cod']).optional(),
  orderId: z.uuid().optional(),
});

function shipmentSelect(tx: Tx) {
  return tx.selectFrom('shipments as s')
    .innerJoin('sales_orders as o', 'o.id', 's.order_id')
    .innerJoin('invoices as v', 'v.id', 's.invoice_id')
    .innerJoin('parties as p', 'p.id', 'o.party_id')
    .selectAll('s')
    .select(['o.number as order_number', 'o.location_id', 'v.number as invoice_number', 'v.total as invoice_total', 'p.name as party_name']);
}
type ShipmentRow = Awaited<ReturnType<ReturnType<typeof shipmentSelect>['executeTakeFirstOrThrow']>>;

function shipmentJson(r: ShipmentRow) {
  return {
    id: r.id, number: r.number, orderId: r.order_id, orderNumber: r.order_number, invoiceId: r.invoice_id,
    invoiceNumber: r.invoice_number, invoiceTotal: r.invoice_total, partyName: r.party_name, courier: r.courier, awb: r.awb,
    mode: r.mode, codAmount: r.cod_amount, status: r.status, notes: r.notes, dispatchedAt: r.dispatched_at,
    deliveredAt: r.delivered_at,
  };
}

export async function loadShipment(tx: Tx, ctx: RequestContext, id: string) {
  const row = await shipmentSelect(tx).where('s.id', '=', id).where('s.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Shipment');
  const lines = await tx.selectFrom('shipment_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.id', 'l.order_line_id', 'l.invoice_line_id', 'l.item_id', 'l.qty', 'i.name as item_name', 'i.unit'])
    .where('l.shipment_id', '=', id).execute();
  const history = await tx.selectFrom('shipment_status_history as h').leftJoin('users as u', 'u.id', 'h.created_by')
    .select(['h.status', 'h.note', 'h.created_at', 'u.name as by_name']).where('h.shipment_id', '=', id).orderBy('h.created_at').execute();
  const ret = await tx.selectFrom('sales_returns').select('id').where('shipment_id', '=', id).where('type', '=', 'rto')
    .where('status', '<>', 'cancelled').executeTakeFirst();
  return {
    ...shipmentJson(row),
    invoice: { id: row.invoice_id, number: row.invoice_number, total: row.invoice_total },
    lines: lines.map((l) => ({
      id: l.id, orderLineId: l.order_line_id, invoiceLineId: l.invoice_line_id, itemId: l.item_id, itemName: l.item_name,
      unit: l.unit, qty: l.qty,
    })),
    history: history.map((h) => ({ status: h.status, note: h.note, at: h.created_at, by: h.by_name })),
    returnId: ret?.id ?? null,
  };
}

export async function shipmentRoutes(app: FastifyInstance) {
  app.get('/shipments', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = shipmentSelect(tx).where('s.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('o.location_id', 'in', scope);
      if (q.status) base = base.where('s.status', '=', q.status);
      if (q.mode) base = base.where('s.mode', '=', q.mode);
      if (q.orderId) base = base.where('s.order_id', '=', q.orderId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('s.number', 'ilike', t), eb('s.awb', 'ilike', t), eb('o.number', 'ilike', t), eb('p.name', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('s.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(shipmentJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/shipments/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadShipment(tx, ctx, id));
  });

  app.patch<{ Params: { id: string } }>('/shipments/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('shipments as s').innerJoin('sales_orders as o', 'o.id', 's.order_id')
        .select(['s.id', 's.status', 'o.location_id']).where('s.id', '=', id).where('s.company_id', '=', ctx.companyId).forUpdate('s').executeTakeFirst();
      if (!cur || !ctx.canAccessLocation(cur.location_id)) throw notFound('Shipment');
      if (FINAL.includes(cur.status)) throw conflict(`This shipment is ${cur.status.replace('_', ' ')}, so it can't be edited.`, 'ILLEGAL_TRANSITION', { status: cur.status });
      await tx.updateTable('shipments').set({ courier: body.courier, awb: body.awb, notes: body.notes, updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'shipment', id, 'update', null, body);
      return loadShipment(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/shipments/:id/status', async (req) => {
    const ctx = req.ctx;
    ctx.require('fulfilment.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(statusBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('shipments as s').innerJoin('sales_orders as o', 'o.id', 's.order_id')
        .select(['s.id', 's.status', 's.number', 's.order_id', 'o.location_id']).where('s.id', '=', id).where('s.company_id', '=', ctx.companyId)
        .forUpdate('s').executeTakeFirst();
      if (!cur || !ctx.canAccessLocation(cur.location_id)) throw notFound('Shipment');
      if (!NEXT[cur.status]!.includes(body.status)) {
        throw conflict(`A shipment that is ${cur.status.replace('_', ' ')} can't be marked ${body.status.replace('_', ' ')}.`,
          'ILLEGAL_TRANSITION', { status: cur.status, requested: body.status });
      }
      await tx.updateTable('shipments').set({
        status: body.status, courier: body.courier, awb: body.awb, updated_at: new Date(),
        ...(body.status === 'delivered' ? { delivered_at: new Date() } : {}),
      }).where('id', '=', id).execute();
      await tx.insertInto('shipment_status_history').values({
        tenant_id: ctx.tenantId, shipment_id: id, status: body.status, note: body.note ?? null, created_by: ctx.userId,
      }).execute();
      await addEvent(tx, ctx, cur.order_id, 'shipment', `Shipment ${cur.number} ${body.status.replace('_', ' ')}`);
      if (body.status === 'rto_delivered') await createReturnFromShipment(tx, ctx, id);
      await writeAudit(tx, auditOf(ctx), 'shipment', id, 'status', { status: cur.status }, { status: body.status });
      return loadShipment(tx, ctx, id);
    });
  });
}

documentRoute('PATCH', '/shipments/:id', { body: patchBody });
documentRoute('POST', '/shipments/:id/status', { body: statusBody });
