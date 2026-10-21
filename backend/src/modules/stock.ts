import type { FastifyInstance } from 'fastify';
import type { Selectable } from 'kysely';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { issue, lockItems, locationQty, positions } from '../accounting/costing.ts';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { StockMoveTable } from '../db/schema.ts';
import { todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';

export function moveJson(ctx: RequestContext, m: Selectable<StockMoveTable>) {
  return {
    id: m.id, itemId: m.item_id, locationId: m.location_id, qty: m.qty, rate: m.rate,
    costRate: m.cost_rate, ...(ctx.can('items.view_cost') ? { value: m.value } : {}),
    refType: m.ref_type, refId: m.ref_id, note: m.note, createdAt: m.created_at,
  };
}

/** Throws INSUFFICIENT_STOCK unless `qty` of the item is available at the location. */
export async function requireStock(
  tx: Parameters<typeof locationQty>[0], ctx: RequestContext,
  location: { id: string; name: string }, item: { id: string; name: string; unit: string }, qty: number,
) {
  const available = await locationQty(tx, ctx.companyId, location.id, item.id);
  if (available + 0.0005 < qty) {
    throw conflict(`Only ${available} ${item.unit} of ${item.name} in stock at ${location.name}.`, 'INSUFFICIENT_STOCK',
      { itemId: item.id, available, required: qty });
  }
}

const balanceQuery = pagingQuery.extend({ locationId: z.uuid().optional(), lowOnly: z.enum(['true', 'false']).optional() });
const movesQuery = pagingQuery.extend({ itemId: z.uuid().optional(), locationId: z.uuid().optional() });
const adjustBody = z.object({
  locationId: z.uuid(),
  itemId: z.uuid(),
  qty: qtyField.refine((v) => v !== 0, 'Quantity cannot be zero'),
  rate: moneyField.optional(),
  note: optionalText(300),
  isOpening: z.boolean().optional(),
});

export async function stockRoutes(app: FastifyInstance) {
  app.get('/stock', async (req) => {
    const ctx = req.ctx;
    ctx.require('stock.view');
    const q = parse(balanceQuery, req.query);
    const showValue = ctx.can('items.view_cost');
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('stock_moves as m')
        .innerJoin('items as i', 'i.id', 'm.item_id')
        .innerJoin('locations as l', 'l.id', 'm.location_id')
        .where('m.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('m.location_id', 'in', scope);
      if (q.locationId) base = base.where('m.location_id', '=', q.locationId);
      if (q.q) base = base.where((eb) => eb.or([eb('i.name', 'ilike', likeTerm(q.q!)), eb('i.sku', 'ilike', likeTerm(q.q!))]));
      let grouped = base
        .groupBy(['m.item_id', 'm.location_id', 'i.name', 'i.sku', 'i.unit', 'i.reorder_level', 'l.name'])
        .select((eb) => [
          'm.item_id', 'm.location_id', 'i.name as item_name', 'i.sku', 'i.unit', 'i.reorder_level',
          'l.name as location_name', eb.fn.sum<number>('m.qty').as('qty'), eb.fn.sum<number>('m.value').as('value'),
        ]);
      if (q.lowOnly === 'true') {
        grouped = grouped.where('i.reorder_level', '>', 0).having((eb) => eb(eb.fn.sum('m.qty'), '<=', eb.ref('i.reorder_level')));
      }
      const { total } = await tx.selectFrom(grouped.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await grouped.orderBy('i.name').orderBy('l.name').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((r) => ({
          itemId: r.item_id, itemName: r.item_name, sku: r.sku, unit: r.unit, locationId: r.location_id,
          locationName: r.location_name, qty: Number(r.qty), reorderLevel: r.reorder_level,
          ...(showValue ? { value: Number(r.value) } : {}),
        })),
        total,
      };
    });
  });

  app.get('/stock/moves', async (req) => {
    const ctx = req.ctx;
    ctx.require('stock.view');
    const q = parse(movesQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('stock_moves').where('company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('location_id', 'in', scope);
      if (q.itemId) base = base.where('item_id', '=', q.itemId);
      if (q.locationId) base = base.where('location_id', '=', q.locationId);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map((r) => moveJson(ctx, r)), total };
    });
  });

  app.post('/stock/adjustments', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('stock.adjust');
    const body = parse(adjustBody, req.body);
    const move = await ctx.tx(async (tx) => {
      const location = await getLocation(tx, ctx, body.locationId);
      const item = await tx.selectFrom('items').select(['id', 'name', 'track_stock', 'unit', 'purchase_price'])
        .where('id', '=', body.itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!item) throw notFound('Item');
      if (!item.track_stock) throw badRequest('Stock is not tracked for this item.', { itemId: 'Stock not tracked' });
      if (body.isOpening && body.qty < 0) throw badRequest('Opening stock must be a positive quantity.', { qty: 'Must be positive' });

      await lockItems(tx, ctx.companyId, [item.id]);
      const pos = (await positions(tx, ctx.companyId, [item.id])).get(item.id)!;
      let value: number;
      let costRate: number;
      if (body.qty > 0) {
        costRate = body.rate ?? (pos.qty > 0 && pos.value > 0 ? pos.value / pos.qty : item.purchase_price);
        value = Math.round(body.qty * costRate * 100) / 100;
      } else {
        await requireStock(tx, ctx, location, item, -body.qty);
        const out = issue(pos, -body.qty, item.purchase_price);
        costRate = out.costRate;
        value = -out.value;
      }

      const row = await tx.insertInto('stock_moves').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: location.id, item_id: item.id,
        qty: body.qty, rate: body.rate ?? null, cost_rate: Math.round(costRate * 10_000) / 10_000, value,
        ref_type: body.isOpening ? 'opening' : 'adjustment', ref_id: null, note: body.note ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();

      const acc = await systemAccounts(tx, ctx);
      const other = value > 0 ? (body.isOpening ? acc.opening_balances : acc.other_income) : acc.stock_loss;
      await postJournal(tx, auditOf(ctx), {
        date: todayIst(), voucherType: 'stock', voucherId: row.id, number: null,
        narration: `${body.isOpening ? 'Opening stock' : 'Stock adjustment'}: ${item.name} ${body.qty} ${item.unit}`,
        lines: [
          { accountId: acc.inventory, amount: value, locationId: location.id },
          { accountId: other, amount: -value, locationId: location.id },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'stock_move', row.id, body.isOpening ? 'opening' : 'adjust', null, moveJson(ctx, row));
      return row;
    });
    return reply.status(201).send(moveJson(ctx, move));
  });
}
