import type { FastifyInstance } from 'fastify';
import type { Selectable } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import { positions } from '../accounting/costing.ts';
import type { Tx } from '../db/database.ts';
import type { ItemTable } from '../db/schema.ts';
import { conflict, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';


const createBody = z.object({
  name: z.string().trim().min(1).max(200),
  sku: optionalText(60),
  hsnCode: z.preprocess((v) => (v === '' ? undefined : v), z.string().trim().regex(/^\d{4,8}$/, 'HSN/SAC must be 4–8 digits').optional()),
  unit: z.string().trim().min(1).max(20),
  gstRate: percentField,
  salePrice: moneyField,
  purchasePrice: moneyField.optional(),
  trackStock: z.boolean().optional(),
  reorderLevel: qtyField.refine((v) => v >= 0, 'Cannot be negative').optional(),
});
const patchBody = createBody.partial().extend({
  sku: nullableText(60),
  hsnCode: z.preprocess((v) => (v === '' ? null : v), z.string().trim().regex(/^\d{4,8}$/, 'HSN/SAC must be 4–8 digits').nullable().optional()),
  isActive: z.boolean().optional(),
});
const listQuery = pagingQuery.extend({ activeOnly: z.enum(['true', 'false']).optional() });

/** Item as JSON; purchase price only for callers allowed to see costs. */
export function itemJson(ctx: RequestContext, i: Selectable<ItemTable>, avg?: Map<string, number>) {
  return {
    id: i.id, companyId: i.company_id, name: i.name, sku: i.sku, hsnCode: i.hsn_code, unit: i.unit,
    gstRate: i.gst_rate, salePrice: i.sale_price,
    ...(ctx.can('items.view_cost') ? { purchasePrice: i.purchase_price, avgCost: avg?.get(i.id) ?? i.purchase_price } : {}),
    trackStock: i.track_stock, reorderLevel: i.reorder_level, isActive: i.is_active,
    createdAt: i.created_at, updatedAt: i.updated_at,
  };
}

/** Current weighted-average cost of items that have stock. */
async function avgCosts(tx: Tx, companyId: string, ids: string[]): Promise<Map<string, number>> {
  const pos = await positions(tx, companyId, ids);
  const result = new Map<string, number>();
  for (const [id, p] of pos) if (p.qty > 0 && p.value > 0) result.set(id, Math.round((p.value / p.qty) * 100) / 100);
  return result;
}

const isUniqueViolation = (err: unknown) => (err as { code?: string }).code === '23505';

export async function itemRoutes(app: FastifyInstance) {
  app.get('/items', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('items').where('company_id', '=', ctx.companyId);
      if (q.activeOnly === 'true') base = base.where('is_active', '=', true);
      if (q.q) {
        const term = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('name', 'ilike', term), eb('sku', 'ilike', term), eb('hsn_code', 'ilike', term)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('name').limit(q.limit).offset(q.offset).execute();
      const avg = ctx.can('items.view_cost') ? await avgCosts(tx, ctx.companyId, rows.map((r) => r.id)) : undefined;
      return { data: rows.map((r) => itemJson(ctx, r, avg)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/items/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const item = await tx.selectFrom('items').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!item) throw notFound('Item');
      return itemJson(ctx, item, ctx.can('items.view_cost') ? await avgCosts(tx, ctx.companyId, [id]) : undefined);
    });
  });

  app.post('/items', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('items.create');
    const body = parse(createBody, req.body);
    try {
      const item = await ctx.tx(async (tx) => {
        const row = await tx.insertInto('items').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, name: body.name, sku: body.sku ?? null,
          hsn_code: body.hsnCode ?? null, unit: body.unit, gst_rate: body.gstRate, sale_price: body.salePrice,
          purchase_price: ctx.can('items.view_cost') ? body.purchasePrice ?? 0 : 0,
          track_stock: body.trackStock ?? true, reorder_level: body.reorderLevel ?? 0,
        }).returningAll().executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'item', row.id, 'create', null, row);
        return row;
      });
      return reply.status(201).send(itemJson(ctx, item));
    } catch (err) {
      if (isUniqueViolation(err)) throw conflict('An item with this SKU already exists.', 'CONFLICT', { sku: 'Already used' });
      throw err;
    }
  });

  app.patch<{ Params: { id: string } }>('/items/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.edit');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    try {
      return await ctx.tx(async (tx) => {
        const before = await tx.selectFrom('items').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!before) throw notFound('Item');
        const after = await tx.updateTable('items').set({
          name: body.name, sku: body.sku, hsn_code: body.hsnCode, unit: body.unit, gst_rate: body.gstRate,
          sale_price: body.salePrice, purchase_price: ctx.can('items.view_cost') ? body.purchasePrice : undefined,
          track_stock: body.trackStock, reorder_level: body.reorderLevel, is_active: body.isActive, updated_at: new Date(),
        }).where('id', '=', id).returningAll().executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'item', id, 'update', before, after);
        return itemJson(ctx, after);
      });
    } catch (err) {
      if (isUniqueViolation(err)) throw conflict('An item with this SKU already exists.', 'CONFLICT', { sku: 'Already used' });
      throw err;
    }
  });
}
