import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createCreditNote } from './credit-notes.ts';
import { EPS, addEvent, round3 } from './o2c-common.ts';
import { documentRoute } from '../lib/openapi.ts';

const positive = qtyField.refine((v) => v > 0, 'Must be more than zero');
const lineInput = z.object({ orderLineId: z.uuid().optional(), invoiceLineId: z.uuid().optional(), qty: positive })
  .refine((l) => Boolean(l.orderLineId) !== Boolean(l.invoiceLineId), 'Give orderLineId or invoiceLineId');
const createBody = z.object({
  orderId: z.uuid().optional(),
  invoiceId: z.uuid().optional(),
  shipmentId: z.uuid().optional(),
  type: z.enum(['customer_return', 'rto']).optional(),
  reason: z.string().trim().min(3, 'Give a reason').max(300),
  lines: z.array(lineInput).min(1, 'Choose at least one line').max(200),
}).refine((b) => Boolean(b.orderId) !== Boolean(b.invoiceId), 'Give orderId or invoiceId');
const receiveBody = z.object({ lines: z.array(z.object({ lineId: z.uuid(), qtyReceived: qtyField.refine((v) => v >= 0, 'Cannot be negative') })).max(200).optional() });
const inspectBody = z.object({
  lines: z.array(z.object({ lineId: z.uuid(), disposition: z.enum(['restock', 'damaged', 'scrap']), note: optionalText(300) })).min(1).max(200),
});
const cancelBody = z.object({ reason: optionalText(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(['requested', 'received', 'inspected', 'closed', 'cancelled']).optional(),
  type: z.enum(['customer_return', 'rto']).optional(),
  orderId: z.uuid().optional(),
  invoiceId: z.uuid().optional(),
});

const OPEN = ['requested', 'received', 'inspected'];
const illegal = (r: { status: string }, action: string) =>
  conflict(`This return is ${r.status}, so it can't be ${action}.`, 'ILLEGAL_TRANSITION', { status: r.status });
const exceeds = (lineIndex: number, returnable: number, unit: string) =>
  new AppError(400, 'RETURN_EXCEEDS_SOLD', `Line ${lineIndex + 1}: only ${returnable} ${unit} can still be returned.`, { lineIndex, returnable });

/** Quantity of each invoice line that is still returnable: invoiced − credited − held by open returns. */
async function returnable(tx: Tx, invoiceId: string) {
  const lines = await tx.selectFrom('invoice_lines').select(['id', 'item_id', 'qty', 'returned_qty', 'unit'])
    .where('invoice_id', '=', invoiceId).orderBy('id').forUpdate().execute();
  const held = await tx.selectFrom('sales_return_lines as l').innerJoin('sales_returns as r', 'r.id', 'l.return_id')
    .select(['l.invoice_line_id', sql<number>`sum(coalesce(l.qty_received, l.qty))`.as('qty')])
    .where('r.invoice_id', '=', invoiceId).where('r.status', 'in', OPEN).groupBy('l.invoice_line_id').execute();
  const heldBy = new Map(held.map((h) => [h.invoice_line_id, Number(h.qty)]));
  return new Map(lines.map((l) => [l.id, {
    ...l, left: round3(l.qty - l.returned_qty - (heldBy.get(l.id) ?? 0)),
  }]));
}

interface Resolved { invoiceLineId: string; orderLineId: string | null; itemId: string; qty: number }

async function insertReturn(
  tx: Tx, ctx: RequestContext,
  head: { invoiceId: string; orderId: string | null; shipmentId: string | null; type: string; reason: string },
  lines: Resolved[],
) {
  const inv = await tx.selectFrom('invoices').select(['id', 'location_id', 'party_id', 'number', 'status']).where('id', '=', head.invoiceId).executeTakeFirstOrThrow();
  const number = await nextNumber(tx, ctx, 'sales_return', financialYear(todayIst()));
  const row = await tx.insertInto('sales_returns').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: inv.location_id, invoice_id: inv.id, order_id: head.orderId,
    shipment_id: head.shipmentId, party_id: inv.party_id, number, type: head.type, reason: head.reason, credit_note_id: null,
    received_at: null, inspected_at: null, closed_at: null, created_by: ctx.userId,
  }).returning('id').executeTakeFirstOrThrow();
  await tx.insertInto('sales_return_lines').values(lines.map((l, i) => ({
    tenant_id: ctx.tenantId, return_id: row.id, line_no: i + 1, invoice_line_id: l.invoiceLineId, order_line_id: l.orderLineId,
    item_id: l.itemId, qty: l.qty, qty_received: null, disposition: null, note: null,
  }))).execute();
  for (const l of lines) {
    if (!l.orderLineId) continue;
    await tx.updateTable('sales_order_lines').set((eb) => ({ qty_returned: eb('qty_returned', '+', l.qty) })).where('id', '=', l.orderLineId).execute();
  }
  if (head.orderId) await addEvent(tx, ctx, head.orderId, 'return', `Return ${number} ${head.type === 'rto' ? '(RTO) ' : ''}created`);
  await writeAudit(tx, auditOf(ctx), 'sales_return', row.id, 'create', null, { number, type: head.type, invoiceId: inv.id });
  return row.id;
}

/** RTO delivered back to the warehouse: one return for what was shipped and not yet returned. Safe to call twice. */
export async function createReturnFromShipment(tx: Tx, ctx: RequestContext, shipmentId: string) {
  const existing = await tx.selectFrom('sales_returns').select('id').where('shipment_id', '=', shipmentId).where('type', '=', 'rto')
    .where('status', '<>', 'cancelled').executeTakeFirst();
  if (existing) return existing.id;
  const ship = await tx.selectFrom('shipments').select(['id', 'order_id', 'invoice_id', 'number']).where('id', '=', shipmentId).executeTakeFirstOrThrow();
  const sl = await tx.selectFrom('shipment_lines').selectAll().where('shipment_id', '=', shipmentId).execute();
  const left = await returnable(tx, ship.invoice_id);
  const lines: Resolved[] = [];
  for (const l of sl) {
    const qty = Math.min(l.qty, left.get(l.invoice_line_id)?.left ?? 0);
    if (qty > EPS) lines.push({ invoiceLineId: l.invoice_line_id, orderLineId: l.order_line_id, itemId: l.item_id, qty: round3(qty) });
  }
  if (!lines.length) return null;
  return insertReturn(tx, ctx, { invoiceId: ship.invoice_id, orderId: ship.order_id, shipmentId, type: 'rto', reason: `Returned to origin: shipment ${ship.number}` }, lines);
}

function returnSelect(tx: Tx) {
  return tx.selectFrom('sales_returns as r')
    .innerJoin('locations as l', 'l.id', 'r.location_id')
    .innerJoin('invoices as v', 'v.id', 'r.invoice_id')
    .innerJoin('parties as p', 'p.id', 'r.party_id')
    .leftJoin('sales_orders as o', 'o.id', 'r.order_id')
    .leftJoin('credit_notes as c', 'c.id', 'r.credit_note_id')
    .selectAll('r')
    .select(['l.name as location_name', 'v.number as invoice_number', 'p.name as party_name', 'o.number as order_number', 'c.number as credit_note_number']);
}
type ReturnRow = Awaited<ReturnType<ReturnType<typeof returnSelect>['executeTakeFirstOrThrow']>>;

function returnJson(r: ReturnRow) {
  return {
    id: r.id, number: r.number, type: r.type, status: r.status, reason: r.reason, locationId: r.location_id,
    locationName: r.location_name, invoiceId: r.invoice_id, invoiceNumber: r.invoice_number, orderId: r.order_id,
    orderNumber: r.order_number, shipmentId: r.shipment_id, partyId: r.party_id, partyName: r.party_name,
    creditNoteId: r.credit_note_id, creditNoteNumber: r.credit_note_number, receivedAt: r.received_at,
    inspectedAt: r.inspected_at, closedAt: r.closed_at, createdAt: r.created_at,
  };
}

async function loadReturn(tx: Tx, ctx: RequestContext, id: string) {
  const row = await returnSelect(tx).where('r.id', '=', id).where('r.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Sales return');
  const lines = await tx.selectFrom('sales_return_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.id', 'l.line_no', 'l.invoice_line_id', 'l.order_line_id', 'l.item_id', 'l.qty', 'l.qty_received', 'l.disposition', 'l.note', 'i.name as item_name', 'i.unit'])
    .where('l.return_id', '=', id).orderBy('l.line_no').execute();
  return {
    ...returnJson(row),
    lines: lines.map((l) => ({
      id: l.id, lineNo: l.line_no, invoiceLineId: l.invoice_line_id, orderLineId: l.order_line_id, itemId: l.item_id,
      itemName: l.item_name, unit: l.unit, qty: l.qty, qtyReceived: l.qty_received, disposition: l.disposition, note: l.note,
    })),
  };
}

async function lockReturn(tx: Tx, ctx: RequestContext, id: string) {
  const r = await tx.selectFrom('sales_returns').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!r || !ctx.canAccessLocation(r.location_id)) throw notFound('Sales return');
  return r;
}

export async function salesReturnRoutes(app: FastifyInstance) {
  app.get('/sales-returns', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = returnSelect(tx).where('r.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('r.location_id', 'in', scope);
      if (q.status) base = base.where('r.status', '=', q.status);
      if (q.type) base = base.where('r.type', '=', q.type);
      if (q.orderId) base = base.where('r.order_id', '=', q.orderId);
      if (q.invoiceId) base = base.where('r.invoice_id', '=', q.invoiceId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('r.number', 'ilike', t), eb('v.number', 'ilike', t), eb('p.name', 'ilike', t), eb('o.number', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('r.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(returnJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/sales-returns/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('sales_orders.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadReturn(tx, ctx, id));
  });

  app.post('/sales-returns', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('returns.manage');
    const body = parse(createBody, req.body);
    const created = await ctx.tx(async (tx) => {
      let invoiceId = body.invoiceId ?? null;
      let orderId: string | null = null;
      let shipmentId: string | null = body.shipmentId ?? null;
      const resolved: Resolved[] = [];
      if (body.orderId) {
        const order = await tx.selectFrom('sales_orders').select(['id', 'location_id']).where('id', '=', body.orderId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!order || !ctx.canAccessLocation(order.location_id)) throw notFound('Sales order');
        orderId = order.id;
        const ship = await tx.selectFrom('shipment_lines as sl').innerJoin('shipments as s', 's.id', 'sl.shipment_id')
          .select(['sl.order_line_id', 'sl.invoice_line_id', 'sl.item_id', 'sl.qty', 's.id as shipment_id', 's.invoice_id'])
          .where('s.order_id', '=', order.id).$if(Boolean(shipmentId), (qb) => qb.where('s.id', '=', shipmentId!)).orderBy('s.created_at').execute();
        const invoiceIds = new Set<string>();
        const caps = new Map<string, Awaited<ReturnType<typeof returnable>>>();
        for (const [idx, l] of body.lines.entries()) {
          if (!l.orderLineId) throw badRequest('Give orderLineId for each line.', { [`lines.${idx}.orderLineId`]: 'Required' });
          const cands = ship.filter((s) => s.order_line_id === l.orderLineId);
          let need = l.qty;
          let total = 0;
          for (const c of cands) {
            if (!caps.has(c.invoice_id)) caps.set(c.invoice_id, await returnable(tx, c.invoice_id));
            const cap = caps.get(c.invoice_id)!.get(c.invoice_line_id)!;
            total += Math.max(cap.left, 0);
            const take = Math.min(need, Math.max(cap.left, 0));
            if (take > EPS) {
              resolved.push({ invoiceLineId: c.invoice_line_id, orderLineId: c.order_line_id, itemId: c.item_id, qty: round3(take) });
              cap.left = round3(cap.left - take);
              need = round3(need - take);
              invoiceIds.add(c.invoice_id);
              shipmentId = c.shipment_id;
            }
          }
          if (need > EPS) throw exceeds(idx, round3(total), 'units');
        }
        if (invoiceIds.size > 1) {
          throw badRequest('These lines were invoiced in separate shipments. Return one shipment at a time.', { shipmentId: 'Choose a shipment' });
        }
        invoiceId = [...invoiceIds][0] ?? null;
        if (new Set(resolved.map((r) => ship.find((s) => s.invoice_line_id === r.invoiceLineId)!.shipment_id)).size > 1) shipmentId = null;
      } else {
        const inv = await tx.selectFrom('invoices').select(['id', 'location_id']).where('id', '=', invoiceId!).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!inv || !ctx.canAccessLocation(inv.location_id)) throw badRequest('Invoice not found.', { invoiceId: 'Not found' });
        const caps = await returnable(tx, inv.id);
        for (const [idx, l] of body.lines.entries()) {
          if (!l.invoiceLineId) throw badRequest('Give invoiceLineId for each line.', { [`lines.${idx}.invoiceLineId`]: 'Required' });
          const cap = caps.get(l.invoiceLineId);
          if (!cap) throw badRequest(`Line ${idx + 1}: not a line of this invoice.`, { [`lines.${idx}.invoiceLineId`]: 'Not found' });
          if (l.qty > cap.left + EPS) throw exceeds(idx, Math.max(cap.left, 0), cap.unit);
          cap.left = round3(cap.left - l.qty);
          const link = await tx.selectFrom('shipment_lines as sl').innerJoin('shipments as s', 's.id', 'sl.shipment_id')
            .select(['sl.order_line_id', 's.order_id', 's.id as shipment_id']).where('sl.invoice_line_id', '=', cap.id).executeTakeFirst();
          if (link) { orderId = link.order_id; shipmentId = link.shipment_id; }
          resolved.push({ invoiceLineId: cap.id, orderLineId: link?.order_line_id ?? null, itemId: cap.item_id, qty: l.qty });
        }
      }
      if (!invoiceId || !resolved.length) throw badRequest('Choose at least one line.', { lines: 'Required' });
      const inv = await tx.selectFrom('invoices').select(['status']).where('id', '=', invoiceId).executeTakeFirstOrThrow();
      if (inv.status !== 'posted') throw badRequest('Only posted invoices can be returned.', { invoiceId: 'Cancelled' });
      const type = body.type ?? 'customer_return';
      if (type === 'rto' && !shipmentId) throw badRequest('An RTO return needs a shipment.', { shipmentId: 'Required' });
      const id = await insertReturn(tx, ctx, { invoiceId, orderId, shipmentId, type, reason: body.reason }, resolved);
      return loadReturn(tx, ctx, id);
    });
    return reply.status(201).send(created);
  });

  app.post<{ Params: { id: string } }>('/sales-returns/:id/receive', async (req) => {
    const ctx = req.ctx;
    ctx.require('returns.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(receiveBody, req.body);
    return ctx.tx(async (tx) => {
      const r = await lockReturn(tx, ctx, id);
      if (r.status !== 'requested') throw illegal(r, 'received');
      const lines = await tx.selectFrom('sales_return_lines').selectAll().where('return_id', '=', id).orderBy('line_no').execute();
      const given = new Map((body.lines ?? []).map((l) => [l.lineId, l.qtyReceived]));
      for (const lid of given.keys()) if (!lines.some((l) => l.id === lid)) throw badRequest('Not a line of this return.', { lineId: 'Not found' });
      for (const l of lines) {
        const got = given.get(l.id) ?? (body.lines ? 0 : l.qty);
        if (got > l.qty + EPS) throw badRequest(`Line ${l.line_no}: at most ${l.qty} can be received.`, { qtyReceived: `At most ${l.qty}` });
        await tx.updateTable('sales_return_lines').set({ qty_received: got }).where('id', '=', l.id).execute();
      }
      await tx.updateTable('sales_returns').set({ status: 'received', received_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
      if (r.order_id) await addEvent(tx, ctx, r.order_id, 'return', `Return ${r.number} received`);
      await writeAudit(tx, auditOf(ctx), 'sales_return', id, 'receive', { status: 'requested' }, { status: 'received' });
      return loadReturn(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/sales-returns/:id/inspect', async (req) => {
    const ctx = req.ctx;
    ctx.require('returns.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(inspectBody, req.body);
    return ctx.tx(async (tx) => {
      const r = await lockReturn(tx, ctx, id);
      if (r.status !== 'received') throw illegal(r, 'inspected');
      const lines = await tx.selectFrom('sales_return_lines').selectAll().where('return_id', '=', id).orderBy('line_no').execute();
      const given = new Map(body.lines.map((l) => [l.lineId, l]));
      for (const lid of given.keys()) if (!lines.some((l) => l.id === lid)) throw badRequest('Not a line of this return.', { lineId: 'Not found' });
      for (const l of lines) {
        const g = given.get(l.id);
        if (!g && (l.qty_received ?? 0) > EPS) throw badRequest(`Line ${l.line_no}: choose restock, damaged or scrap.`, { disposition: 'Required' });
        if (g) await tx.updateTable('sales_return_lines').set({ disposition: g.disposition, note: g.note ?? null }).where('id', '=', l.id).execute();
      }
      await tx.updateTable('sales_returns').set({ status: 'inspected', inspected_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
      if (r.order_id) await addEvent(tx, ctx, r.order_id, 'return', `Return ${r.number} inspected`);
      await writeAudit(tx, auditOf(ctx), 'sales_return', id, 'inspect', { status: 'received' }, { status: 'inspected' });
      return loadReturn(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/sales-returns/:id/close', async (req) => {
    const ctx = req.ctx;
    ctx.require('returns.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const r = await lockReturn(tx, ctx, id);
      if (r.status !== 'inspected') throw illegal(r, 'closed');
      const lines = await tx.selectFrom('sales_return_lines').selectAll().where('return_id', '=', id).orderBy('line_no').execute();
      const credited = lines.filter((l) => (l.qty_received ?? 0) > EPS);
      let creditNoteId: string | null = null;
      if (credited.length) {
        const note = await createCreditNote(ctx, tx, {
          invoiceId: r.invoice_id, reason: `Sales return ${r.number}`,
          lines: credited.map((l) => ({ invoiceLineId: l.invoice_line_id, qty: l.qty_received! })),
        }, { restockLineIds: new Set(credited.filter((l) => l.disposition === 'restock').map((l) => l.invoice_line_id)) });
        creditNoteId = note.id;
      }
      // Claimed but not received: release the order line quantity.
      for (const l of lines) {
        const short = round3(l.qty - (l.qty_received ?? 0));
        if (short > EPS && l.order_line_id) {
          await tx.updateTable('sales_order_lines').set((eb) => ({ qty_returned: eb('qty_returned', '-', short) })).where('id', '=', l.order_line_id).execute();
        }
      }
      await tx.updateTable('sales_returns').set({ status: 'closed', closed_at: new Date(), credit_note_id: creditNoteId, updated_at: new Date() }).where('id', '=', id).execute();
      if (r.order_id) await addEvent(tx, ctx, r.order_id, 'return', `Return ${r.number} closed${creditNoteId ? ' with a credit note' : ''}`);
      await writeAudit(tx, auditOf(ctx), 'sales_return', id, 'close', { status: 'inspected' }, { status: 'closed', creditNoteId });
      return loadReturn(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/sales-returns/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('returns.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const r = await lockReturn(tx, ctx, id);
      if (!OPEN.includes(r.status)) throw illegal(r, 'cancelled');
      const lines = await tx.selectFrom('sales_return_lines').select(['order_line_id', 'qty']).where('return_id', '=', id).execute();
      for (const l of lines) {
        if (!l.order_line_id) continue;
        await tx.updateTable('sales_order_lines').set((eb) => ({ qty_returned: eb('qty_returned', '-', l.qty) })).where('id', '=', l.order_line_id).execute();
      }
      await tx.updateTable('sales_returns').set({ status: 'cancelled', updated_at: new Date() }).where('id', '=', id).execute();
      if (r.order_id) await addEvent(tx, ctx, r.order_id, 'return', `Return ${r.number} cancelled${body.reason ? `: ${body.reason}` : ''}`);
      await writeAudit(tx, auditOf(ctx), 'sales_return', id, 'cancel', { status: r.status }, { status: 'cancelled', reason: body.reason ?? null });
      return loadReturn(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/sales-returns', { body: createBody });
documentRoute('POST', '/sales-returns/:id/receive', { body: receiveBody });
documentRoute('POST', '/sales-returns/:id/inspect', { body: inspectBody });
documentRoute('POST', '/sales-returns/:id/cancel', { body: cancelBody });
