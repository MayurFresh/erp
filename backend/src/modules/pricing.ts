import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { Tx } from '../db/database.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { optionalText } from '../lib/india.ts';
import { documentRoute } from '../lib/openapi.ts';
import { resolvePrices } from '../lib/pricing.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

/** Price lists, customer prices, schemes and price resolution. See docs/API.md "v1.15". */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const positiveQty = qtyField.refine((v) => v > 0, 'Must be more than zero');
const pctField = z.coerce.number().refine((v) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-6, 'At most 2 decimals');
const orderedDates = (v: { validFrom?: string | null; validTo?: string | null }) => !v.validFrom || !v.validTo || v.validTo >= v.validFrom;
const datesMsg = { message: 'The end date is before the start date.', path: ['validTo'] };

const listFields = {
  name: z.string().trim().min(1).max(80),
  mode: z.enum(['fixed', 'percent']),
  adjustPct: pctField.min(-100).max(1000),
  validFrom: dateField.nullable().optional(),
  validTo: dateField.nullable().optional(),
  isActive: z.boolean(),
  notes: optionalText(500),
};
const listCreate = z.object({ ...listFields, adjustPct: listFields.adjustPct.optional(), isActive: listFields.isActive.optional() }).refine(orderedDates, datesMsg);
const listPatch = z.object(listFields).partial().refine(orderedDates, datesMsg);
const itemRows = z.object({
  items: z.array(z.object({ itemId: z.uuid(), minQty: positiveQty.optional(), rate: moneyField })).max(2000),
});
const customerRows = z.object({
  partyId: z.uuid(),
  items: z.array(z.object({
    itemId: z.uuid(), minQty: positiveQty.optional(), rate: moneyField,
    validFrom: dateField.nullable().optional(), validTo: dateField.nullable().optional(),
  }).refine(orderedDates, datesMsg)).max(2000),
});
const schemeBase = z.object({
  name: z.string().trim().min(1).max(100),
  kind: z.enum(['free_qty', 'slab_discount']),
  itemId: z.uuid(),
  buyQty: positiveQty.optional(),
  freeQty: positiveQty.optional(),
  freeItemId: z.uuid().nullable().optional(),
  minQty: positiveQty.optional(),
  discountPct: pctField.refine((v) => v > 0 && v <= 100, 'Between 0 and 100').optional(),
  validFrom: dateField.nullable().optional(),
  validTo: dateField.nullable().optional(),
  isActive: z.boolean().optional(),
});
const schemeShape = (v: z.infer<typeof schemeBase>) => v.kind === 'free_qty'
  ? v.buyQty !== undefined && v.freeQty !== undefined
  : v.minQty !== undefined && v.discountPct !== undefined;
const schemeCreate = schemeBase.refine(orderedDates, datesMsg)
  .refine(schemeShape, { message: 'A free-quantity scheme needs buyQty and freeQty; a slab discount needs minQty and discountPct.', path: ['kind'] });
const schemePatch = schemeBase.partial().refine(orderedDates, datesMsg);
const resolveQuery = z.object({
  partyId: z.uuid().optional(), itemId: z.uuid(), qty: qtyField.refine((v) => v > 0).optional(), date: dateField.optional(),
});
const resolveBody = z.object({
  partyId: z.uuid().nullable().optional(), date: dateField.optional(),
  lines: z.array(z.object({ itemId: z.uuid(), qty: positiveQty.optional() })).min(1).max(200),
});

const listJson = (l: Record<string, any>, extra: object = {}) => ({
  id: l.id, name: l.name, mode: l.mode, adjustPct: l.adjust_pct, validFrom: l.valid_from, validTo: l.valid_to,
  isActive: l.is_active, notes: l.notes, ...extra,
});
const schemeJson = (s: Record<string, any>) => ({
  id: s.id, name: s.name, kind: s.kind, itemId: s.item_id, itemName: s.item_name ?? null, buyQty: s.buy_qty, freeQty: s.free_qty,
  freeItemId: s.free_item_id, minQty: s.min_qty, discountPct: s.discount_pct, validFrom: s.valid_from, validTo: s.valid_to, isActive: s.is_active,
});

async function assertItems(tx: Tx, companyId: string, ids: string[], field = 'items') {
  const uniq = [...new Set(ids)];
  if (!uniq.length) return;
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', companyId).where('id', 'in', uniq).execute();
  if (found.length !== uniq.length) throw badRequest('One of the items was not found.', { [field]: 'Item not found' });
}
function assertNoDuplicates(rows: { itemId: string; minQty?: number }[]) {
  const seen = new Set<string>();
  for (const r of rows) {
    const k = `${r.itemId}:${r.minQty ?? 1}`;
    if (seen.has(k)) throw badRequest('An item appears twice with the same minimum quantity.', { items: 'Duplicate row' });
    seen.add(k);
  }
}

async function loadList(tx: Tx, companyId: string, id: string) {
  const l = await tx.selectFrom('price_lists').selectAll().where('id', '=', id).where('company_id', '=', companyId).executeTakeFirst();
  if (!l) throw notFound('Price list');
  return l;
}

export async function pricingRoutes(app: FastifyInstance) {
  // --- price lists
  app.get('/price-lists', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    const q = parse(z.object({ includeInactive: z.enum(['true', 'false']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('price_lists as l').where('l.company_id', '=', ctx.companyId);
      if (q.includeInactive !== 'true') base = base.where('l.is_active', '=', true);
      const rows = await base.selectAll('l').select((eb) => [
        eb.selectFrom('price_list_items as i').select((e) => e.fn.countAll<number>().as('n')).whereRef('i.price_list_id', '=', 'l.id').as('item_count'),
        eb.selectFrom('parties as p').select((e) => e.fn.countAll<number>().as('n')).whereRef('p.price_list_id', '=', 'l.id').as('party_count'),
      ]).orderBy('l.name').execute();
      return { data: rows.map((r) => listJson(r, { itemCount: r.item_count ?? 0, partyCount: r.party_count ?? 0 })) };
    });
  });

  app.get<{ Params: { id: string } }>('/price-lists/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const l = await loadList(tx, ctx.companyId, id);
      const rows = await tx.selectFrom('price_list_items as r').innerJoin('items as i', 'i.id', 'r.item_id')
        .select(['r.id', 'r.item_id', 'i.name as item_name', 'i.sku', 'r.min_qty', 'r.rate'])
        .where('r.price_list_id', '=', id).orderBy('i.name').orderBy('r.min_qty').execute();
      return listJson(l, {
        items: rows.map((r) => ({ id: r.id, itemId: r.item_id, itemName: r.item_name, sku: r.sku, minQty: r.min_qty, rate: r.rate })),
      });
    });
  });

  app.post('/price-lists', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('pricing.manage');
    const body = parse(listCreate, req.body);
    const row = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('price_lists').select('id').where('company_id', '=', ctx.companyId).where((eb) => eb(eb.fn('lower', ['name']), '=', body.name.toLowerCase())).executeTakeFirst();
      if (dup) throw conflict('A price list with this name already exists.', 'DUPLICATE_NAME', { name: 'Already used' });
      const r = await tx.insertInto('price_lists').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: body.name, mode: body.mode,
        adjust_pct: body.mode === 'percent' ? (body.adjustPct ?? 0) : 0, valid_from: body.validFrom ?? null, valid_to: body.validTo ?? null,
        is_active: body.isActive ?? true, notes: body.notes ?? null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'price_list', r.id, 'create', null, r);
      return r;
    });
    return reply.status(201).send(listJson(row, { itemCount: 0, partyCount: 0, items: [] }));
  });

  app.patch<{ Params: { id: string } }>('/price-lists/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('pricing.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(listPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadList(tx, ctx.companyId, id);
      const from = body.validFrom !== undefined ? body.validFrom : before.valid_from;
      const to = body.validTo !== undefined ? body.validTo : before.valid_to;
      if (from && to && to < from) throw badRequest('The end date is before the start date.', { validTo: 'Before start' });
      const set: Record<string, unknown> = {};
      if (body.name !== undefined) set.name = body.name;
      if (body.mode !== undefined) set.mode = body.mode;
      if (body.adjustPct !== undefined) set.adjust_pct = body.adjustPct;
      if (body.validFrom !== undefined) set.valid_from = body.validFrom;
      if (body.validTo !== undefined) set.valid_to = body.validTo;
      if (body.isActive !== undefined) set.is_active = body.isActive;
      if (body.notes !== undefined) set.notes = body.notes;
      if ((set.mode ?? before.mode) === 'fixed') set.adjust_pct = 0;
      const after = Object.keys(set).length
        ? await tx.updateTable('price_lists').set(set).where('id', '=', id).returningAll().executeTakeFirstOrThrow() : before;
      await writeAudit(tx, auditOf(ctx), 'price_list', id, 'update', before, after);
      return listJson(after);
    });
  });

  app.delete<{ Params: { id: string } }>('/price-lists/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('pricing.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const before = await loadList(tx, ctx.companyId, id);
      const used = await tx.selectFrom('parties').select('id').where('price_list_id', '=', id).executeTakeFirst();
      if (used) throw conflict('Customers use this price list. Deactivate it instead, or move them to another list first.', 'PRICE_LIST_IN_USE');
      await tx.deleteFrom('price_lists').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'price_list', id, 'delete', before, null);
    });
    return reply.status(204).send();
  });

  const replaceItems = async (req: any) => {
    const ctx = req.ctx;
    ctx.require('pricing.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(itemRows, req.body);
    assertNoDuplicates(body.items);
    return ctx.tx(async (tx: Tx) => {
      await loadList(tx, ctx.companyId, id);
      await assertItems(tx, ctx.companyId, body.items.map((r) => r.itemId));
      await tx.deleteFrom('price_list_items').where('price_list_id', '=', id).execute();
      if (body.items.length) {
        await tx.insertInto('price_list_items').values(body.items.map((r) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, price_list_id: id, item_id: r.itemId, min_qty: r.minQty ?? 1, rate: r.rate,
        }))).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'price_list', id, 'items', null, { count: body.items.length });
      return { count: body.items.length };
    });
  };
  app.put('/price-lists/:id/items', replaceItems);
  app.patch('/price-lists/:id/items', replaceItems);

  // --- customer prices
  app.get('/customer-prices', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    const q = parse(z.object({ partyId: z.uuid() }), req.query);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('customer_prices as r').innerJoin('items as i', 'i.id', 'r.item_id')
        .select(['r.id', 'r.party_id', 'r.item_id', 'i.name as item_name', 'i.sku', 'r.min_qty', 'r.rate', 'r.valid_from', 'r.valid_to'])
        .where('r.company_id', '=', ctx.companyId).where('r.party_id', '=', q.partyId).orderBy('i.name').orderBy('r.min_qty').execute();
      return {
        data: rows.map((r) => ({
          id: r.id, partyId: r.party_id, itemId: r.item_id, itemName: r.item_name, sku: r.sku, minQty: r.min_qty, rate: r.rate,
          validFrom: r.valid_from, validTo: r.valid_to,
        })),
      };
    });
  });

  const replaceCustomer = async (req: any) => {
    const ctx = req.ctx;
    ctx.require('pricing.manage');
    const body = parse(customerRows, req.body);
    assertNoDuplicates(body.items);
    return ctx.tx(async (tx: Tx) => {
      const party = await tx.selectFrom('parties').select('id').where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw badRequest('Customer not found.', { partyId: 'Not found' });
      await assertItems(tx, ctx.companyId, body.items.map((r) => r.itemId));
      await tx.deleteFrom('customer_prices').where('party_id', '=', body.partyId).execute();
      if (body.items.length) {
        await tx.insertInto('customer_prices').values(body.items.map((r) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, party_id: body.partyId, item_id: r.itemId, min_qty: r.minQty ?? 1,
          rate: r.rate, valid_from: r.validFrom ?? null, valid_to: r.validTo ?? null,
        }))).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'party', body.partyId, 'customer_prices', null, { count: body.items.length });
      return { count: body.items.length };
    });
  };
  app.put('/customer-prices', replaceCustomer);
  app.patch('/customer-prices', replaceCustomer);

  // --- schemes
  app.get('/price-schemes', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('price_schemes as s').innerJoin('items as i', 'i.id', 's.item_id')
        .selectAll('s').select('i.name as item_name').where('s.company_id', '=', ctx.companyId).orderBy('s.name').execute();
      return { data: rows.map(schemeJson) };
    });
  });

  app.post('/price-schemes', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('pricing.manage');
    const b = parse(schemeCreate, req.body);
    const row = await ctx.tx(async (tx) => {
      await assertItems(tx, ctx.companyId, [b.itemId, ...(b.freeItemId ? [b.freeItemId] : [])]);
      const r = await tx.insertInto('price_schemes').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, kind: b.kind, item_id: b.itemId,
        buy_qty: b.kind === 'free_qty' ? b.buyQty! : null, free_qty: b.kind === 'free_qty' ? b.freeQty! : null,
        free_item_id: b.kind === 'free_qty' ? (b.freeItemId ?? null) : null,
        min_qty: b.kind === 'slab_discount' ? b.minQty! : null, discount_pct: b.kind === 'slab_discount' ? b.discountPct! : null,
        valid_from: b.validFrom ?? null, valid_to: b.validTo ?? null, is_active: b.isActive ?? true,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'price_scheme', r.id, 'create', null, r);
      return r;
    });
    return reply.status(201).send(schemeJson(row));
  });

  app.patch<{ Params: { id: string } }>('/price-schemes/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('pricing.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(schemePatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('price_schemes').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!before) throw notFound('Scheme');
      const ids = [b.itemId, b.freeItemId].filter((x): x is string => !!x);
      await assertItems(tx, ctx.companyId, ids);
      const kind = b.kind ?? before.kind;
      const set: Record<string, unknown> = {};
      const map: [keyof typeof b, string][] = [['name', 'name'], ['kind', 'kind'], ['itemId', 'item_id'], ['buyQty', 'buy_qty'], ['freeQty', 'free_qty'],
        ['freeItemId', 'free_item_id'], ['minQty', 'min_qty'], ['discountPct', 'discount_pct'], ['validFrom', 'valid_from'], ['validTo', 'valid_to'], ['isActive', 'is_active']];
      for (const [k, col] of map) if (b[k] !== undefined) set[col] = b[k];
      if (kind === 'free_qty') { set.min_qty = null; set.discount_pct = null; } else { set.buy_qty = null; set.free_qty = null; set.free_item_id = null; }
      const merged = { ...before, ...set } as typeof before;
      if (kind === 'free_qty' ? merged.buy_qty == null || merged.free_qty == null : merged.min_qty == null || merged.discount_pct == null) {
        throw badRequest('The scheme is missing its quantities or discount.', { kind: 'Incomplete' });
      }
      if (merged.valid_from && merged.valid_to && merged.valid_to < merged.valid_from) throw badRequest('The end date is before the start date.', { validTo: 'Before start' });
      const after = await tx.updateTable('price_schemes').set(set).where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'price_scheme', id, 'update', before, after);
      return schemeJson(after);
    });
  });

  app.delete<{ Params: { id: string } }>('/price-schemes/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('pricing.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const before = await tx.selectFrom('price_schemes').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!before) throw notFound('Scheme');
      await tx.deleteFrom('price_schemes').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'price_scheme', id, 'delete', before, null);
    });
    return reply.status(204).send();
  });

  // --- resolve
  app.get('/prices/resolve', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    const q = parse(resolveQuery, req.query);
    return ctx.tx(async (tx) => {
      await assertItems(tx, ctx.companyId, [q.itemId], 'itemId');
      return (await resolvePrices(tx, ctx.companyId, q.partyId, [{ itemId: q.itemId, qty: q.qty ?? 1 }], q.date ?? todayIst()))[0];
    });
  });

  app.post('/prices/resolve', async (req) => {
    const ctx = req.ctx;
    ctx.require('items.view');
    const b = parse(resolveBody, req.body);
    return ctx.tx(async (tx) => {
      await assertItems(tx, ctx.companyId, b.lines.map((l) => l.itemId), 'lines');
      return { data: await resolvePrices(tx, ctx.companyId, b.partyId, b.lines.map((l) => ({ itemId: l.itemId, qty: l.qty ?? 1 })), b.date ?? todayIst()) };
    });
  });
}

documentRoute('POST', '/price-lists', { summary: 'Create a price list', body: listCreate });
documentRoute('PATCH', '/price-lists/:id', { summary: 'Edit a price list', body: listPatch });
documentRoute('PUT', '/price-lists/:id/items', { summary: 'Replace the item prices and slabs of a price list', body: itemRows });
documentRoute('PUT', '/customer-prices', { summary: 'Replace the item prices of one customer', body: customerRows });
documentRoute('POST', '/price-schemes', { summary: 'Create a scheme', body: schemeCreate });
documentRoute('POST', '/prices/resolve', { summary: 'Resolve rate, discount and free quantity for lines', body: resolveBody });
