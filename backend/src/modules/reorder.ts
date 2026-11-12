import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest } from '../lib/errors.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { createPo } from './purchase-orders.ts';
import { documentRoute } from '../lib/openapi.ts';

const round3 = (n: number) => Math.round(n * 1000) / 1000;
const key = (itemId: string, locationId: string) => `${itemId}|${locationId}`;

const listQuery = z.object({ locationId: z.uuid().optional() });
const createBody = z.object({
  selections: z.array(z.object({
    itemId: z.uuid(),
    locationId: z.uuid(),
    qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
    partyId: z.uuid().optional(),
    rate: moneyField.optional(),
  })).min(1, 'Select at least one item').max(200, 'At most 200 items'),
});

async function lastVendors(tx: Tx, companyId: string, itemIds: string[]) {
  const map = new Map<string, { partyId: string; partyName: string; rate: number }>();
  if (!itemIds.length) return map;
  const rows = await tx.selectFrom('purchase_lines as l')
    .innerJoin('purchases as p', 'p.id', 'l.purchase_id').innerJoin('parties as v', 'v.id', 'p.party_id')
    .select(['l.item_id', 'p.party_id', 'v.name', 'l.rate', 'l.discount_pct'])
    .where('p.company_id', '=', companyId).where('p.status', '=', 'posted').where('l.item_id', 'in', itemIds)
    .orderBy('p.bill_date', 'desc').orderBy('p.created_at', 'desc').execute();
  for (const r of rows) {
    if (!map.has(r.item_id)) map.set(r.item_id, { partyId: r.party_id, partyName: r.name, rate: Math.round(r.rate * (1 - r.discount_pct / 100) * 100) / 100 });
  }
  return map;
}

export async function reorderSuggestions(tx: Tx, ctx: RequestContext, locationId?: string) {
  const scope = scopedLocationIds(ctx);
  let items = tx.selectFrom('items').select(['id', 'name', 'sku', 'unit', 'reorder_level', 'purchase_price'])
    .where('company_id', '=', ctx.companyId).where('track_stock', '=', true).where('is_active', '=', true).where('reorder_level', '>', 0);
  items = items.orderBy('name');
  const itemRows = await items.execute();
  if (!itemRows.length) return [];
  const itemIds = itemRows.map((i) => i.id);

  let moves = tx.selectFrom('stock_moves').select((eb) => ['item_id', 'location_id', eb.fn.sum<number>('qty').as('qty')])
    .where('company_id', '=', ctx.companyId).where('item_id', 'in', itemIds);
  if (locationId) moves = moves.where('location_id', '=', locationId);
  if (scope) moves = moves.where('location_id', 'in', scope);
  const onHand = new Map<string, number>();
  for (const m of await moves.groupBy(['item_id', 'location_id']).execute()) onHand.set(key(m.item_id, m.location_id), Number(m.qty));

  const locs = await tx.selectFrom('locations').select(['id', 'name']).where('company_id', '=', ctx.companyId).execute();
  const locName = new Map(locs.map((l) => [l.id, l.name]));
  if (locationId && (!scope || scope.includes(locationId)) && locName.has(locationId)) {
    for (const id of itemIds) if (!onHand.has(key(id, locationId))) onHand.set(key(id, locationId), 0);
  }

  const reserved = new Map<string, number>();
  const hasRes = (await sql<{ t: string | null }>`select to_regclass('stock_reservations')::text as t`.execute(tx)).rows[0]?.t;
  if (hasRes) {
    const rows = await tx.selectFrom('stock_reservations').select((eb) => ['item_id', 'location_id', eb.fn.sum<number>('qty').as('qty')])
      .where('company_id', '=', ctx.companyId).where('status', '=', 'active').where('item_id', 'in', itemIds)
      .groupBy(['item_id', 'location_id']).execute();
    for (const r of rows) reserved.set(key(r.item_id, r.location_id), Number(r.qty));
  }
  const openPo = new Map<string, number>();
  const po = await tx.selectFrom('purchase_order_lines as l').innerJoin('purchase_orders as o', 'o.id', 'l.purchase_order_id')
    .select((eb) => ['l.item_id', 'o.location_id', eb.fn.sum<number>(sql<number>`greatest(l.qty - l.cancelled_qty - l.received_qty, 0)`).as('qty')])
    .where('o.company_id', '=', ctx.companyId).where('o.status', 'in', ['approved', 'sent', 'partially_received'])
    .where('l.item_id', 'in', itemIds).groupBy(['l.item_id', 'o.location_id']).execute();
  for (const r of po) openPo.set(key(r.item_id, r.location_id), Number(r.qty));

  const vendors = await lastVendors(tx, ctx.companyId, itemIds);
  const out: Record<string, unknown>[] = [];
  for (const item of itemRows) {
    for (const [k, qty] of onHand) {
      if (!k.startsWith(`${item.id}|`)) continue;
      const lid = k.split('|')[1]!;
      const res = reserved.get(k) ?? 0;
      const open = openPo.get(k) ?? 0;
      const position = round3(qty - res + open);
      if (position > item.reorder_level) continue;
      const v = vendors.get(item.id);
      out.push({
        itemId: item.id, itemName: item.name, sku: item.sku, unit: item.unit, locationId: lid, locationName: locName.get(lid) ?? '',
        onHand: round3(qty), reserved: round3(res), openPoQty: round3(open), position, reorderLevel: item.reorder_level,
        suggestedQty: Math.max(1, Math.ceil((item.reorder_level * 2 - position) * 1000) / 1000),
        lastVendorId: v?.partyId ?? null, lastVendorName: v?.partyName ?? null, lastRate: v?.rate ?? null,
      });
    }
  }
  return out;
}

export async function reorderRoutes(app: FastifyInstance) {
  app.get('/reorder-suggestions', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.view');
    const q = parse(listQuery, req.query);
    if (q.locationId && !ctx.canAccessLocation(q.locationId)) return { data: [], total: 0 };
    const data = await ctx.tx((tx) => reorderSuggestions(tx, ctx, q.locationId));
    return { data, total: data.length };
  });

  app.post('/reorder-suggestions/purchase-orders', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const body = parse(createBody, req.body);
    const data = await ctx.tx(async (tx) => {
      const ids = [...new Set(body.selections.map((s) => s.itemId))];
      const vendors = await lastVendors(tx, ctx.companyId, ids);
      const groups = new Map<string, { partyId: string; locationId: string; lines: { itemId: string; qty: number; rate?: number }[] }>();
      body.selections.forEach((s, idx) => {
        const partyId = s.partyId ?? vendors.get(s.itemId)?.partyId;
        if (!partyId) throw badRequest(`Selection ${idx + 1}: choose a vendor.`, { [`selections.${idx}.partyId`]: 'Required' });
        const k = `${partyId}|${s.locationId}`;
        const g = groups.get(k) ?? { partyId, locationId: s.locationId, lines: [] };
        const existing = g.lines.find((l) => l.itemId === s.itemId);
        if (existing) existing.qty = round3(existing.qty + s.qty);
        else g.lines.push({ itemId: s.itemId, qty: s.qty, rate: s.rate ?? (s.partyId ? undefined : vendors.get(s.itemId)?.rate) });
        groups.set(k, g);
      });
      const pos = [];
      for (const g of groups.values()) pos.push(await createPo(ctx, tx, { locationId: g.locationId, partyId: g.partyId, notes: 'Created from reorder suggestions', lines: g.lines }));
      return pos;
    });
    return reply.status(201).send({ data });
  });
}

documentRoute('POST', '/reorder-suggestions/purchase-orders', { body: createBody });
