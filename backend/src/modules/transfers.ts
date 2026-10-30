import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { issue, lockItems, positions } from '../accounting/costing.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { checkIndentLink, fulfilIndent, reverseFulfilment } from './indents.ts';
import { getLocation } from './locations.ts';
import { requireStock } from './stock.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const createBody = z.object({
  fromLocationId: z.uuid(),
  toLocationId: z.uuid(),
  transferDate: docDate.optional(),
  notes: optionalText(500),
  indentId: z.uuid().nullable().optional(),
  lines: z.array(z.object({ itemId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero') }))
    .min(1, 'Add at least one item').max(200),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  status: z.enum(['in_transit', 'received', 'cancelled']).optional(),
  locationId: z.uuid().optional(),
});

async function loadTransfer(tx: Tx, ctx: RequestContext, id: string) {
  const t = await tx.selectFrom('transfers as t')
    .innerJoin('locations as f', 'f.id', 't.from_location_id')
    .innerJoin('locations as d', 'd.id', 't.to_location_id')
    .innerJoin('users as u', 'u.id', 't.created_by')
    .leftJoin('users as r', 'r.id', 't.received_by')
    .selectAll('t')
    .select(['f.name as from_name', 'd.name as to_name', 'u.name as created_by_name', 'r.name as received_by_name'])
    .where('t.id', '=', id).where('t.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!t || !(ctx.canAccessLocation(t.from_location_id) || ctx.canAccessLocation(t.to_location_id))) throw notFound('Transfer');
  const lines = await tx.selectFrom('transfer_lines as tl').innerJoin('items as i', 'i.id', 'tl.item_id')
    .select(['tl.item_id', 'i.name', 'i.sku', 'i.unit', 'tl.qty', 'tl.value'])
    .where('tl.transfer_id', '=', id).orderBy('tl.line_no').execute();
  return {
    id: t.id, companyId: t.company_id, number: t.number, fromLocationId: t.from_location_id, fromLocationName: t.from_name,
    toLocationId: t.to_location_id, toLocationName: t.to_name, status: t.status, transferDate: t.transfer_date, notes: t.notes,
    indentId: t.indent_id,
    ...(ctx.can('items.view_cost') ? { totalValue: round2(lines.reduce((s, l) => s + l.value, 0)) } : {}),
    createdAt: t.created_at, createdBy: { id: t.created_by, name: t.created_by_name },
    receivedAt: t.received_at, receivedBy: t.received_by ? { id: t.received_by, name: t.received_by_name! } : null,
    cancelledAt: t.cancelled_at, cancelReason: t.cancel_reason,
    lines: lines.map((l) => ({ itemId: l.item_id, itemName: l.name, sku: l.sku, unit: l.unit, qty: l.qty })),
  };
}

export async function transferRoutes(app: FastifyInstance) {
  app.get('/transfers', async (req) => {
    const ctx = req.ctx;
    ctx.require('transfers.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('transfers as t').where('t.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where((eb) => eb.or([eb('t.from_location_id', 'in', scope), eb('t.to_location_id', 'in', scope)]));
      if (q.status) base = base.where('t.status', '=', q.status);
      if (q.locationId) base = base.where((eb) => eb.or([eb('t.from_location_id', '=', q.locationId!), eb('t.to_location_id', '=', q.locationId!)]));
      if (q.q) base = base.where('t.number', 'ilike', likeTerm(q.q));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('t.id').orderBy('t.transfer_date', 'desc').orderBy('t.created_at', 'desc')
        .limit(q.limit).offset(q.offset).execute();
      const data = [];
      for (const { id } of ids) data.push(await loadTransfer(tx, ctx, id));
      return { data, total };
    });
  });

  app.get<{ Params: { id: string } }>('/transfers/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('transfers.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadTransfer(tx, ctx, id));
  });

  app.post('/transfers', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('transfers.create');
    const body = parse(createBody, req.body);
    if (body.fromLocationId === body.toLocationId) {
      throw badRequest('Choose two different locations.', { toLocationId: 'Same as source' });
    }
    const transfer = await ctx.tx(async (tx) => {
      const from = await getLocation(tx, ctx, body.fromLocationId);
      const to = await tx.selectFrom('locations').selectAll()
        .where('id', '=', body.toLocationId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!to) throw badRequest('Destination not found.', { toLocationId: 'Not found' });
      if (!to.is_active || !from.is_active) throw badRequest('Both locations must be active.', { toLocationId: 'Inactive' });
      const date = body.transferDate ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { transferDate: 'In the future' });
      if (body.indentId) await checkIndentLink(tx, ctx, body.indentId, to.id);

      const ids = [...new Set(body.lines.map((l) => l.itemId))];
      const items = await tx.selectFrom('items').select(['id', 'name', 'unit', 'track_stock', 'purchase_price'])
        .where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
      body.lines.forEach((l, i) => {
        const item = items.find((x) => x.id === l.itemId);
        if (!item) throw badRequest(`Line ${i + 1}: item not found.`, { [`lines.${i}.itemId`]: 'Not found' });
        if (!item.track_stock) throw badRequest(`Line ${i + 1}: stock is not tracked for ${item.name}.`, { [`lines.${i}.itemId`]: 'Not tracked' });
      });

      await lockItems(tx, ctx.companyId, ids);
      const totals = new Map<string, number>();
      for (const l of body.lines) totals.set(l.itemId, (totals.get(l.itemId) ?? 0) + l.qty);
      for (const [itemId, qty] of totals) await requireStock(tx, ctx, from, items.find((x) => x.id === itemId)!, qty);

      const pos = await positions(tx, ctx.companyId, ids);
      const costed = body.lines.map((l) => {
        const item = items.find((x) => x.id === l.itemId)!;
        const out = issue(pos.get(l.itemId)!, l.qty, item.purchase_price);
        pos.set(l.itemId, out.after);
        return { ...l, costRate: out.costRate, value: out.value };
      });

      const number = await nextNumber(tx, ctx, 'transfer', financialYear(date));
      const row = await tx.insertInto('transfers').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, from_location_id: from.id, to_location_id: to.id,
        transfer_date: date, notes: body.notes ?? null, created_by: ctx.userId, received_by: null, received_at: null,
        cancelled_at: null, cancel_reason: null, indent_id: body.indentId ?? null,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('transfer_lines').values(costed.map((c, i) => ({
        tenant_id: ctx.tenantId, transfer_id: row.id, line_no: i + 1, item_id: c.itemId, qty: c.qty, cost_rate: c.costRate, value: c.value,
      }))).execute();
      await tx.insertInto('stock_moves').values(costed.map((c) => ({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: from.id, item_id: c.itemId, qty: -c.qty, rate: null,
        cost_rate: c.costRate, value: -c.value, ref_type: 'transfer_out', ref_id: row.id, note: `${number} to ${to.name}`, created_by: ctx.userId,
      }))).execute();

      const value = round2(costed.reduce((s, c) => s + c.value, 0));
      const acc = await systemAccounts(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'transfer', voucherId: row.id, number, narration: `Dispatched from ${from.name} to ${to.name}`,
        lines: [
          { accountId: acc.stock_in_transit, amount: value, locationId: to.id },
          { accountId: acc.inventory, amount: -value, locationId: from.id },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'transfer', row.id, 'dispatch', null, { number, from: from.id, to: to.id, lines: body.lines });
      return loadTransfer(tx, ctx, row.id);
    });
    return reply.status(201).send(transfer);
  });

  app.post<{ Params: { id: string } }>('/transfers/:id/receive', async (req) => {
    const ctx = req.ctx;
    ctx.require('transfers.receive');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const t = await tx.selectFrom('transfers').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!t || !(ctx.canAccessLocation(t.from_location_id) || ctx.canAccessLocation(t.to_location_id))) throw notFound('Transfer');
      if (!ctx.canAccessLocation(t.to_location_id)) throw forbidden('Only someone at the destination can receive this transfer.');
      if (t.status !== 'in_transit') throw conflict(`This transfer is already ${t.status.replace('_', ' ')}.`, 'CONFLICT');

      const lines = await tx.selectFrom('transfer_lines').selectAll().where('transfer_id', '=', id).execute();
      await lockItems(tx, ctx.companyId, lines.map((l) => l.item_id));
      await tx.insertInto('stock_moves').values(lines.map((l) => ({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: t.to_location_id, item_id: l.item_id, qty: l.qty, rate: null,
        cost_rate: l.cost_rate, value: l.value, ref_type: 'transfer_in', ref_id: id, note: t.number, created_by: ctx.userId,
      }))).execute();
      await tx.updateTable('transfers').set({ status: 'received', received_by: ctx.userId, received_at: new Date() }).where('id', '=', id).execute();
      if (t.indent_id) {
        await fulfilIndent(tx, ctx, t.indent_id, { type: 'transfer', id, locationId: t.to_location_id },
          lines.map((l) => ({ itemId: l.item_id, qty: l.qty })));
      }

      const value = round2(lines.reduce((s, l) => s + l.value, 0));
      const acc = await systemAccounts(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date: todayIst(), voucherType: 'transfer', voucherId: id, number: t.number, narration: `Received ${t.number}`,
        lines: [
          { accountId: acc.inventory, amount: value, locationId: t.to_location_id },
          { accountId: acc.stock_in_transit, amount: -value, locationId: t.to_location_id },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'transfer', id, 'receive', { status: 'in_transit' }, { status: 'received' });
      return loadTransfer(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/transfers/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('transfers.create');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const t = await tx.selectFrom('transfers').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!t || !(ctx.canAccessLocation(t.from_location_id) || ctx.canAccessLocation(t.to_location_id))) throw notFound('Transfer');
      if (!ctx.canAccessLocation(t.from_location_id)) throw forbidden('Only someone at the source can cancel this transfer.');
      if (t.status === 'cancelled') throw conflict('This transfer is already cancelled.', 'ALREADY_CANCELLED');
      if (t.status !== 'in_transit') throw conflict('Only transfers still in transit can be cancelled.', 'CONFLICT');

      const lines = await tx.selectFrom('transfer_lines').selectAll().where('transfer_id', '=', id).execute();
      await lockItems(tx, ctx.companyId, lines.map((l) => l.item_id));
      await tx.insertInto('stock_moves').values(lines.map((l) => ({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: t.from_location_id, item_id: l.item_id, qty: l.qty, rate: null,
        cost_rate: l.cost_rate, value: l.value, ref_type: 'transfer_cancel', ref_id: id, note: `Cancelled ${t.number}`, created_by: ctx.userId,
      }))).execute();
      await tx.updateTable('transfers').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${t.number}: ${reason}`);
      await reverseFulfilment(tx, ctx, t.indent_id, id);
      await writeAudit(tx, auditOf(ctx), 'transfer', id, 'cancel', { status: 'in_transit' }, { status: 'cancelled', reason });
      return loadTransfer(tx, ctx, id);
    });
  });
}
