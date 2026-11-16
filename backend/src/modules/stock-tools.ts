import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { fifoActive, groupedMoves, replayAverage, replayLayers, valuationSetting, type ValuationSetting } from '../accounting/fifo.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { daysBetween, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, notFound } from '../lib/errors.ts';
import { documentRoute } from '../lib/openapi.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

/** Stock valuation method, alternate units, ageing and slow-moving reports. See docs/API.md "Stock valuation and handling". */

const round2 = (n: number) => Math.round(n * 100) / 100;
const round3 = (n: number) => Math.round(n * 1000) / 1000;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const methodBody = z.object({ method: z.enum(['average', 'fifo']), effectiveFrom: dateField.optional() });
const unitsBody = z.object({
  units: z.array(z.object({
    name: z.string().trim().min(1, 'Give a name').max(20),
    factor: z.coerce.number().positive('Must be more than zero').max(1_000_000).refine((v) => Math.round(v * 1e6) / 1e6 === v, 'At most 6 decimals'),
  })).max(20).default([]),
  defaultPurchaseUnit: z.string().trim().max(20).nullable().optional(),
  defaultSaleUnit: z.string().trim().max(20).nullable().optional(),
});
const ageingQuery = z.object({ locationId: z.uuid().optional(), asOf: dateField.optional() });
const movementQuery = z.object({
  mode: z.enum(['non_moving', 'slow_moving']).default('non_moving'),
  days: z.coerce.number().int().min(1).max(3650).default(90),
  coverDays: z.coerce.number().int().min(1).max(3650).default(180),
  locationId: z.uuid().optional(),
});

export const AGEING_BUCKETS = ['0-30', '31-60', '61-90', '91-180', '180+'] as const;
const bucketOf = (age: number) => (age <= 30 ? 0 : age <= 60 ? 1 : age <= 90 ? 2 : age <= 180 ? 3 : 4);

function scopeOf(ctx: RequestContext, locationId?: string) {
  if (locationId) ctx.requireLocation(locationId);
  return { scope: scopedLocationIds(ctx), locationId };
}

/** The method that costs the books today. */
export const effectiveMethod = (s: ValuationSetting): 'average' | 'fifo' => (fifoActive(s) ? 'fifo' : 'average');

/**
 * Valuation by a method other than the one the books use, rebuilt from the stock moves per item and location.
 * The ledger is not touched; this is for comparison.
 */
export async function comparisonValuation(tx: Tx, ctx: RequestContext, method: 'average' | 'fifo', scope: string[] | null, locationId?: string) {
  const groups = await groupedMoves(tx, ctx.companyId, { asOf: todayIst(), locationIds: scope, locationId });
  const per = new Map<string, { qty: number; value: number }>();
  for (const g of groups) {
    let qty: number;
    let value: number;
    if (method === 'fifo') {
      const layers = replayLayers(g.moves);
      qty = layers.reduce((s, l) => s + l.qty, 0);
      value = layers.reduce((s, l) => s + l.qty * l.rate, 0);
    } else ({ qty, value } = replayAverage(g.moves));
    const e = per.get(g.itemId) ?? { qty: 0, value: 0 };
    per.set(g.itemId, { qty: e.qty + qty, value: e.value + value });
  }
  const ids = [...per.keys()];
  const items = ids.length ? await tx.selectFrom('items').select(['id', 'name', 'sku', 'unit']).where('id', 'in', ids).orderBy('name').execute() : [];
  const rows = items.map((i) => {
    const e = per.get(i.id)!;
    const qty = round3(e.qty);
    const value = round2(e.value);
    return { itemId: i.id, name: i.name, sku: i.sku, unit: i.unit, qty, avgCost: qty > 0 ? round2(value / qty) : 0, value };
  }).filter((r) => r.qty !== 0 || r.value !== 0);
  return { rows, totalValue: round2(rows.reduce((s, r) => s + r.value, 0)) };
}

async function loadUnits(tx: Tx, ctx: RequestContext, itemId: string) {
  const item = await tx.selectFrom('items').select(['id', 'unit', 'default_purchase_unit', 'default_sale_unit'])
    .where('id', '=', itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!item) throw notFound('Item');
  const units = await tx.selectFrom('item_units').select(['id', 'name', 'factor']).where('item_id', '=', itemId).orderBy('created_at').orderBy('name').execute();
  return {
    baseUnit: item.unit, units: units.map((u) => ({ id: u.id, name: u.name, factor: Number(u.factor) })),
    defaultPurchaseUnit: item.default_purchase_unit, defaultSaleUnit: item.default_sale_unit,
  };
}

export async function stockToolRoutes(app: FastifyInstance) {
  app.get('/stock/valuation-method', async (req) => {
    const ctx = req.ctx;
    ctx.require('stock.view');
    return ctx.tx(async (tx) => {
      const s = await valuationSetting(tx, ctx.companyId);
      return { method: s.method, effectiveFrom: s.effectiveFrom };
    });
  });

  const setMethod = async (req: { ctx: RequestContext; body?: unknown }) => {
    const ctx = req.ctx;
    ctx.require('stock.valuation');
    const body = parse(methodBody, req.body);
    const today = todayIst();
    const effectiveFrom = body.effectiveFrom ?? today;
    if (effectiveFrom < today) throw badRequest('The effective date cannot be in the past.', { effectiveFrom: 'In the past' });
    return ctx.tx(async (tx) => {
      const before = await valuationSetting(tx, ctx.companyId);
      await sql`insert into stock_valuation_settings (company_id, tenant_id, method, effective_from, updated_by, updated_at)
        values (${ctx.companyId}, ${ctx.tenantId}, ${body.method}, ${effectiveFrom}::date, ${ctx.userId}, now())
        on conflict (company_id) do update set method = excluded.method, effective_from = excluded.effective_from,
          updated_by = excluded.updated_by, updated_at = now()`.execute(tx);
      await writeAudit(tx, auditOf(ctx), 'stock_valuation', ctx.companyId, 'set_method', before, { method: body.method, effectiveFrom });
      return { method: body.method, effectiveFrom };
    });
  };
  app.put('/stock/valuation-method', setMethod);
  app.patch('/stock/valuation-method', setMethod);

  app.get<{ Params: { id: string } }>('/items/:id/units', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadUnits(tx, ctx, id));
  });

  const setUnits = async (req: { ctx: RequestContext; params: { id: string }; body?: unknown }) => {
    const ctx = req.ctx;
    ctx.require('items.edit');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(unitsBody, req.body);
    return ctx.tx(async (tx) => {
      const current = await loadUnits(tx, ctx, id);
      const names = new Set<string>([current.baseUnit.toLowerCase()]);
      body.units.forEach((u, idx) => {
        const k = u.name.toLowerCase();
        if (names.has(k)) throw badRequest(`${u.name} is already used for this item.`, { [`units.${idx}.name`]: 'Already used' });
        names.add(k);
      });
      const known = (n: string | null | undefined) => !n || names.has(n.toLowerCase());
      if (!known(body.defaultPurchaseUnit)) throw badRequest('Choose the base unit or a unit of this item.', { defaultPurchaseUnit: 'Unknown unit' });
      if (!known(body.defaultSaleUnit)) throw badRequest('Choose the base unit or a unit of this item.', { defaultSaleUnit: 'Unknown unit' });
      await tx.deleteFrom('item_units').where('item_id', '=', id).execute();
      if (body.units.length) {
        await tx.insertInto('item_units').values(body.units.map((u) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: id, name: u.name, factor: u.factor,
        }))).execute();
      }
      const canon = (n: string | null | undefined) => (n ? ([current.baseUnit, ...body.units.map((u) => u.name)].find((x) => x.toLowerCase() === n.toLowerCase()) ?? null) : null);
      await tx.updateTable('items').set({
        default_purchase_unit: body.defaultPurchaseUnit === undefined ? current.defaultPurchaseUnit : canon(body.defaultPurchaseUnit),
        default_sale_unit: body.defaultSaleUnit === undefined ? current.defaultSaleUnit : canon(body.defaultSaleUnit),
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'item', id, 'units', current, body);
      return loadUnits(tx, ctx, id);
    });
  };
  app.put<{ Params: { id: string } }>('/items/:id/units', setUnits);
  app.patch<{ Params: { id: string } }>('/items/:id/units', setUnits);

  app.get('/reports/stock-ageing', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const q = parse(ageingQuery, req.query);
    const showValue = ctx.can('items.view_cost');
    const asOf = q.asOf ?? todayIst();
    const { scope, locationId } = scopeOf(ctx, q.locationId);
    return ctx.tx(async (tx) => {
      const groups = await groupedMoves(tx, ctx.companyId, { asOf, locationIds: scope, locationId });
      const live = groups.map((g) => {
        const buckets = AGEING_BUCKETS.map(() => ({ qty: 0, value: 0 }));
        for (const l of replayLayers(g.moves)) {
          const b = buckets[bucketOf(Math.max(0, daysBetween(l.date, asOf)))]!;
          b.qty += l.qty;
          b.value += l.qty * l.rate;
        }
        return { g, buckets };
      }).filter((r) => r.buckets.some((b) => b.qty > 0.0005));
      const itemIds = [...new Set(live.map((r) => r.g.itemId))];
      const locIds = [...new Set(live.map((r) => r.g.locationId))];
      const items = itemIds.length ? await tx.selectFrom('items').select(['id', 'name', 'sku', 'unit']).where('id', 'in', itemIds).execute() : [];
      const locs = locIds.length ? await tx.selectFrom('locations').select(['id', 'name']).where('id', 'in', locIds).execute() : [];
      const itemOf = new Map(items.map((i) => [i.id, i]));
      const locOf = new Map(locs.map((l) => [l.id, l.name]));
      const totals = AGEING_BUCKETS.map(() => ({ qty: 0, value: 0 }));
      const rows = live.map(({ g, buckets }) => {
        const i = itemOf.get(g.itemId)!;
        buckets.forEach((b, k) => { totals[k]!.qty += b.qty; totals[k]!.value += b.value; });
        return {
          itemId: g.itemId, name: i.name, sku: i.sku, unit: i.unit, locationId: g.locationId, locationName: locOf.get(g.locationId) ?? '',
          qty: round3(buckets.reduce((s, b) => s + b.qty, 0)),
          buckets: buckets.map((b) => ({ qty: round3(b.qty), ...(showValue ? { value: round2(b.value) } : {}) })),
          ...(showValue ? { value: round2(buckets.reduce((s, b) => s + b.value, 0)) } : {}),
        };
      }).sort((a, b) => a.name.localeCompare(b.name) || a.locationName.localeCompare(b.locationName));
      return {
        asOf, buckets: [...AGEING_BUCKETS], rows,
        totals: {
          qty: round3(totals.reduce((s, b) => s + b.qty, 0)),
          buckets: totals.map((b) => ({ qty: round3(b.qty), ...(showValue ? { value: round2(b.value) } : {}) })),
          ...(showValue ? { value: round2(totals.reduce((s, b) => s + b.value, 0)) } : {}),
        },
      };
    });
  });

  app.get('/reports/stock-movement', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const q = parse(movementQuery, req.query);
    const showValue = ctx.can('items.view_cost');
    const { scope, locationId } = scopeOf(ctx, q.locationId);
    const today = todayIst();
    return ctx.tx(async (tx) => {
      if (scope && !scope.length) return { mode: q.mode, days: q.days, rows: [] };
      const ist = sql`((created_at at time zone 'Asia/Kolkata')::date)`;
      let where = sql`company_id = ${ctx.companyId}`;
      if (scope) where = sql`${where} and location_id in (${sql.join(scope)})`;
      if (locationId) where = sql`${where} and location_id = ${locationId}`;
      const res = await sql<{ item_id: string; qty: number; value: number; last_sale: string | null; sold: number }>`
        select item_id, sum(qty)::float8 as qty, sum(value)::float8 as value,
          (max(case when ref_type = 'invoice' then ${ist} end))::text as last_sale,
          coalesce(-sum(case when ref_type in ('invoice','invoice_cancel') and ${ist} > ${today}::date - ${q.days}::int then qty end), 0)::float8 as sold
        from stock_moves where ${where} group by item_id having sum(qty) > 0.0005`.execute(tx);
      const ids = res.rows.map((r) => r.item_id);
      const items = ids.length ? await tx.selectFrom('items').select(['id', 'name', 'sku', 'unit']).where('id', 'in', ids).execute() : [];
      const itemOf = new Map(items.map((i) => [i.id, i]));
      const rows = res.rows.flatMap((r) => {
        const sold = Number(r.sold);
        const daysSince = r.last_sale ? daysBetween(r.last_sale, today) : null;
        const qty = Number(r.qty);
        const cover = sold > 0 ? Math.round(qty / (sold / q.days)) : null;
        const hit = q.mode === 'non_moving' ? sold <= 0 && (daysSince === null || daysSince >= q.days) : sold > 0 && cover! > q.coverDays;
        if (!hit) return [];
        const i = itemOf.get(r.item_id)!;
        return [{
          itemId: r.item_id, name: i.name, sku: i.sku, unit: i.unit, qty: round3(qty), ...(showValue ? { value: round2(Number(r.value)) } : {}),
          lastSaleDate: r.last_sale, daysSinceSale: daysSince, soldQty: round3(sold), coverDays: cover,
        }];
      }).sort((a, b) => (b.daysSinceSale ?? 1e9) - (a.daysSinceSale ?? 1e9) || a.name.localeCompare(b.name));
      return { mode: q.mode, days: q.days, coverDays: q.coverDays, rows };
    });
  });
}

documentRoute('PUT', '/stock/valuation-method', { body: methodBody });
documentRoute('PUT', '/items/:id/units', { body: unitsBody });
