import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { CONNECTORS, GENERIC_ORDER_COLUMNS, connectorById, connectorJson } from '../lib/channels/registry.ts';
import { parseOrderFile } from '../lib/channels/files.ts';
import type { NormalisedOrder } from '../lib/channels/types.ts';
import { todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { planOrder, processOrder, type Connection, type Outcome } from './channels-flow.ts';
import { channelLiveRoutes, credentialStatus, liveConnector } from './channels-live.ts';
import { channelSettlementRoutes } from './channels-settlements.ts';
import { getLocation } from './locations.ts';
import { documentRoute } from '../lib/openapi.ts';

const PROVIDERS = ['manual', 'amazon', 'flipkart', 'meesho', 'shopify', 'woocommerce', 'other'] as const;
const mapObject = z.record(z.string().min(1).max(60), z.string().trim().min(1).max(80)).refine((o) => Object.keys(o).length <= 40, 'Too many entries');
const connFields = {
  name: z.string().trim().min(1, 'Required').max(80),
  locationId: z.uuid(),
  partyId: z.uuid().optional(),
  orderStatus: z.enum(['draft', 'confirmed']).optional(),
  pricesIncludeTax: z.boolean().optional(),
  stockBuffer: qtyField.refine((v) => v >= 0, 'Cannot be negative').optional(),
  tcsRate: percentField.optional(),
  tdsRate: percentField.optional(),
  csvMapping: mapObject.optional(),
  settlementAliases: mapObject.optional(),
};
const createBody = z.object({ provider: z.enum(PROVIDERS), ...connFields });
const patchBody = z.object(connFields).partial().extend({
  expectedUpdatedAt: z.string().max(40).optional(),
  status: z.enum(['connected', 'disabled']).optional(),
  pushStock: z.boolean().optional(),
});
const listingBody = z.object({
  channelSku: z.string().trim().min(1, 'Required').max(100),
  title: z.string().trim().max(300).nullable().optional(),
  externalId: z.string().trim().max(100).nullable().optional(),
  isActive: z.boolean().optional(),
  components: z.array(z.object({ itemId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero') })).min(1, 'Choose an item').max(20),
});
const importBody = z.object({ csv: z.string().min(1, 'Choose a file').max(5_000_000), dryRun: z.boolean().default(false) });
const inboxQuery = pagingQuery.extend({
  connectionId: z.uuid().optional(),
  status: z.enum(['received', 'processed', 'ignored', 'failed', 'dead']).optional(),
});

export async function loadConnection(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('channel_connections').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const c = await q.executeTakeFirst();
  if (!c) throw notFound('Channel');
  return c;
}

const connJson = (c: Awaited<ReturnType<typeof loadConnection>>, extra: Record<string, unknown> = {}) => ({
  id: c.id, provider: c.provider, name: c.name, status: c.status, statusReason: c.status_reason, partyId: c.party_id,
  locationId: c.location_id, orderStatus: c.order_status, pricesIncludeTax: c.prices_include_tax, stockBuffer: c.stock_buffer,
  tcsRate: c.tcs_rate, tdsRate: c.tds_rate, csvMapping: c.csv_mapping, settlementAliases: c.settlement_aliases,
  csvColumns: { ...GENERIC_ORDER_COLUMNS, ...c.csv_mapping }, lastImportAt: c.last_import_at, lastError: c.last_error,
  createdAt: c.created_at, updatedAt: c.updated_at,
  live: Boolean(liveConnector(c.provider)), hasCredentials: Boolean(c.credentials), credentials: credentialStatus(c),
  pushStock: c.push_stock, lastCheckAt: c.last_check_at, lastSuccessAt: c.last_success_at, ...extra,
});

async function loadListings(tx: Tx, connectionId: string, listingIds?: string[]) {
  let q = tx.selectFrom('channel_listings').selectAll().where('connection_id', '=', connectionId);
  if (listingIds) q = q.where('id', 'in', listingIds);
  const rows = await q.orderBy('channel_sku').execute();
  const comps = rows.length
    ? await tx.selectFrom('channel_listing_components as c').innerJoin('items as i', 'i.id', 'c.item_id')
      .select(['c.listing_id', 'c.item_id', 'c.qty', 'i.name as item_name', 'i.sku as item_sku'])
      .where('c.listing_id', 'in', rows.map((r) => r.id)).execute()
    : [];
  return rows.map((r) => ({
    id: r.id, channelSku: r.channel_sku, title: r.title, externalId: r.external_id, isActive: r.is_active, updatedAt: r.updated_at,
    components: comps.filter((c) => c.listing_id === r.id).map((c) => ({ itemId: c.item_id, itemName: c.item_name, itemSku: c.item_sku, qty: c.qty })),
  }));
}

async function checkItems(tx: Tx, ctx: RequestContext, ids: string[]) {
  const unique = [...new Set(ids)];
  if (unique.length !== ids.length) throw badRequest('An item can appear once in a listing.', { components: 'Duplicate item' });
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', unique).execute();
  if (found.length !== unique.length) throw badRequest('Item not found.', { components: 'Item not found' });
}

/** Re-runs inbox orders that failed only because a SKU was not mapped. */
async function requeueUnmapped(tx: Tx, ctx: RequestContext, conn: Connection) {
  const rows = await tx.selectFrom('channel_inbox').select(['id', 'payload']).where('connection_id', '=', conn.id).where('topic', '=', 'order')
    .where('status', '=', 'failed').where('error_code', '=', 'UNMAPPED_SKU').orderBy('created_at').limit(200).execute();
  let created = 0;
  for (const r of rows) {
    const out = await processOrder(tx, ctx, conn, r.payload as NormalisedOrder);
    if (out.action === 'create') created += 1;
  }
  await tx.deleteFrom('channel_unmapped').where('connection_id', '=', conn.id)
    .where('channel_sku', 'in', tx.selectFrom('channel_listings').select('channel_sku').where('connection_id', '=', conn.id)).execute();
  return created;
}

const inboxJson = (r: {
  id: string; connection_id: string; connection_name: string; event_id: string; status: string; error: string | null; error_code: string | null;
  sales_order_id: string | null; order_number: string | null; order_status: string | null; order_date: string | null; total: number | null;
  source: string; created_at: Date; payload: unknown; attempts: number;
}) => ({
  id: r.id, connectionId: r.connection_id, connectionName: r.connection_name, externalRef: r.event_id, status: r.status,
  error: r.error, errorCode: r.error_code, salesOrderId: r.sales_order_id, salesOrderNumber: r.order_number,
  salesOrderStatus: r.order_status, orderDate: r.order_date, total: r.total, source: r.source, attempts: r.attempts,
  lines: ((r.payload as NormalisedOrder | null)?.lines ?? []).map((l) => ({ sku: l.sku, title: l.title, qty: l.qty })),
  createdAt: r.created_at,
});

export async function channelRoutes(app: FastifyInstance) {
  app.get('/channels/connectors', async (req) => {
    req.ctx.require('channels.view');
    return { data: CONNECTORS.map(connectorJson) };
  });

  app.get('/channels', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.view');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('channel_connections as c').innerJoin('locations as l', 'l.id', 'c.location_id')
        .selectAll('c').select('l.name as location_name').where('c.company_id', '=', ctx.companyId).orderBy('c.name').execute();
      const ids = rows.map((r) => r.id);
      const counts = ids.length
        ? await tx.selectFrom('channel_inbox').select(['connection_id', 'status']).select((eb) => eb.fn.countAll<number>().as('n'))
          .where('connection_id', 'in', ids).groupBy(['connection_id', 'status']).execute()
        : [];
      const listings = ids.length
        ? await tx.selectFrom('channel_listings').select('connection_id').select((eb) => eb.fn.countAll<number>().as('n'))
          .where('connection_id', 'in', ids).groupBy('connection_id').execute()
        : [];
      const unmapped = ids.length
        ? await tx.selectFrom('channel_unmapped').select('connection_id').select((eb) => eb.fn.countAll<number>().as('n'))
          .where('connection_id', 'in', ids).groupBy('connection_id').execute()
        : [];
      return {
        data: rows.map((r) => connJson(r, {
          locationName: r.location_name,
          listingCount: Number(listings.find((x) => x.connection_id === r.id)?.n ?? 0),
          unmappedCount: Number(unmapped.find((x) => x.connection_id === r.id)?.n ?? 0),
          orderCounts: Object.fromEntries(counts.filter((x) => x.connection_id === r.id).map((x) => [x.status, Number(x.n)])),
          connector: connectorJson(connectorById(r.provider)!),
        })),
        total: rows.length,
      };
    });
  });

  app.post('/channels', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const b = parse(createBody, req.body);
    const row = await ctx.tx(async (tx) => {
      const loc = await getLocation(tx, ctx, b.locationId);
      let partyId = b.partyId;
      if (partyId) {
        const p = await tx.selectFrom('parties').select('type').where('id', '=', partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p) throw badRequest('Customer not found.', { partyId: 'Not found' });
        if (p.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });
      } else {
        // One customer record stands for the channel's buyers; the marketplace pays the seller.
        const p = await tx.insertInto('parties').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: `${b.name} (channel)`, state_code: loc.state_code,
          gstin: null, phone: null, email: null, address: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
        }).returning('id').executeTakeFirstOrThrow();
        partyId = p.id;
      }
      try {
        const c = await tx.insertInto('channel_connections').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, provider: b.provider, name: b.name,
          status: liveConnector(b.provider) ? 'not_connected' : 'connected', status_reason: liveConnector(b.provider) ? 'Add credentials and run the check.' : null, party_id: partyId, location_id: b.locationId,
          order_status: b.orderStatus ?? 'confirmed', prices_include_tax: b.pricesIncludeTax ?? true, stock_buffer: b.stockBuffer ?? 0,
          tcs_rate: b.tcsRate ?? 0.5, tds_rate: b.tdsRate ?? 0.1, csv_mapping: JSON.stringify(b.csvMapping ?? {}) as never,
          settlement_aliases: JSON.stringify(b.settlementAliases ?? {}) as never, last_import_at: null, last_error: null,
          created_by: ctx.userId,
        }).returning('id').executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'channel', c.id, 'create', null, { name: b.name, provider: b.provider });
        return connJson(await loadConnection(tx, ctx, c.id));
      } catch (err) {
        if ((err as { code?: string }).code === '23505') throw conflict('A channel with this name already exists.', 'DUPLICATE_NAME', { name: 'Already used' });
        throw err;
      }
    });
    return reply.status(201).send(row);
  });

  app.get<{ Params: { id: string } }>('/channels/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const c = await loadConnection(tx, ctx, id);
      return connJson(c, { connector: connectorJson(connectorById(c.provider)!) });
    });
  });

  app.patch<{ Params: { id: string } }>('/channels/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const c = await loadConnection(tx, ctx, id, true);
      assertFresh(c.updated_at, b.expectedUpdatedAt, 'channel');
      if (b.locationId) await getLocation(tx, ctx, b.locationId);
      const set: Record<string, unknown> = {};
      if (b.name !== undefined) set.name = b.name;
      if (b.locationId !== undefined) set.location_id = b.locationId;
      if (b.partyId !== undefined) set.party_id = b.partyId;
      if (b.orderStatus !== undefined) set.order_status = b.orderStatus;
      if (b.pricesIncludeTax !== undefined) set.prices_include_tax = b.pricesIncludeTax;
      if (b.stockBuffer !== undefined) set.stock_buffer = b.stockBuffer;
      if (b.tcsRate !== undefined) set.tcs_rate = b.tcsRate;
      if (b.tdsRate !== undefined) set.tds_rate = b.tdsRate;
      if (b.csvMapping !== undefined) set.csv_mapping = JSON.stringify(b.csvMapping);
      if (b.settlementAliases !== undefined) set.settlement_aliases = JSON.stringify(b.settlementAliases);
      if (b.pushStock !== undefined) {
        if (b.pushStock && !liveConnector(c.provider)) throw conflict('This channel has no live connection.', 'NO_LIVE_API');
        set.push_stock = b.pushStock;
      }
      if (b.status !== undefined) {
        // A live channel is only "connected" after a check passes.
        const live = Boolean(liveConnector(c.provider));
        set.status = b.status === 'connected' && live ? 'not_connected' : b.status;
        set.status_reason = b.status === 'disabled' ? 'Turned off by a user' : live ? 'Run the check.' : null;
        if (b.status === 'disabled') set.push_stock = false;
      }
      try {
        if (Object.keys(set).length) await tx.updateTable('channel_connections').set({ ...set, updated_at: new Date() } as never).where('id', '=', id).execute();
      } catch (err) {
        if ((err as { code?: string }).code === '23505') throw conflict('A channel with this name already exists.', 'DUPLICATE_NAME', { name: 'Already used' });
        throw err;
      }
      await writeAudit(tx, auditOf(ctx), 'channel', id, 'update', null, Object.keys(set));
      return connJson(await loadConnection(tx, ctx, id));
    });
  });

  // SKU mapping -----------------------------------------------------------------------------------------------

  app.get<{ Params: { id: string } }>('/channels/:id/listings', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(pagingQuery, req.query);
    return ctx.tx(async (tx) => {
      await loadConnection(tx, ctx, id);
      const all = await loadListings(tx, id);
      const t = q.q?.toLowerCase();
      const data = t ? all.filter((l) => l.channelSku.toLowerCase().includes(t) || (l.title ?? '').toLowerCase().includes(t)) : all;
      return { data: data.slice(q.offset, q.offset + q.limit), total: data.length };
    });
  });

  app.get<{ Params: { id: string } }>('/channels/:id/unmapped', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await loadConnection(tx, ctx, id);
      const rows = await tx.selectFrom('channel_unmapped').selectAll().where('connection_id', '=', id).orderBy('last_seen_at', 'desc').execute();
      return { data: rows.map((r) => ({ channelSku: r.channel_sku, title: r.title, seenCount: r.seen_count, lastSeenAt: r.last_seen_at })), total: rows.length };
    });
  });

  app.post<{ Params: { id: string } }>('/channels/:id/listings', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(listingBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const conn = await loadConnection(tx, ctx, id, true);
      await checkItems(tx, ctx, b.components.map((c) => c.itemId));
      let listingId: string;
      try {
        listingId = (await tx.insertInto('channel_listings').values({
          tenant_id: ctx.tenantId, connection_id: id, channel_sku: b.channelSku, title: b.title ?? null, external_id: b.externalId ?? null,
          is_active: b.isActive ?? true,
        }).returning('id').executeTakeFirstOrThrow()).id;
      } catch (err) {
        if ((err as { code?: string }).code === '23505') throw conflict('This channel SKU is already mapped.', 'DUPLICATE_SKU', { channelSku: 'Already mapped' });
        throw err;
      }
      await tx.insertInto('channel_listing_components').values(b.components.map((c) => ({
        tenant_id: ctx.tenantId, listing_id: listingId, item_id: c.itemId, qty: c.qty,
      }))).execute();
      await writeAudit(tx, auditOf(ctx), 'channel_listing', listingId, 'create', null, { channelSku: b.channelSku });
      const created = await requeueUnmapped(tx, ctx, conn as Connection);
      return { listing: (await loadListings(tx, id, [listingId]))[0], ordersCreated: created };
    });
    return reply.status(201).send(out);
  });

  app.route<{ Params: { id: string; listingId: string } }>({ method: ['PUT', 'PATCH'], url: '/channels/:id/listings/:listingId', handler: async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    const listingId = parse(z.uuid(), req.params.listingId);
    const b = parse(listingBody, req.body);
    return ctx.tx(async (tx) => {
      const conn = await loadConnection(tx, ctx, id, true);
      const l = await tx.selectFrom('channel_listings').select('id').where('id', '=', listingId).where('connection_id', '=', id).executeTakeFirst();
      if (!l) throw notFound('Listing');
      await checkItems(tx, ctx, b.components.map((c) => c.itemId));
      try {
        await tx.updateTable('channel_listings').set({
          channel_sku: b.channelSku, title: b.title ?? null, external_id: b.externalId ?? null, is_active: b.isActive ?? true, updated_at: new Date(),
        }).where('id', '=', listingId).execute();
      } catch (err) {
        if ((err as { code?: string }).code === '23505') throw conflict('This channel SKU is already mapped.', 'DUPLICATE_SKU', { channelSku: 'Already mapped' });
        throw err;
      }
      await tx.deleteFrom('channel_listing_components').where('listing_id', '=', listingId).execute();
      await tx.insertInto('channel_listing_components').values(b.components.map((c) => ({
        tenant_id: ctx.tenantId, listing_id: listingId, item_id: c.itemId, qty: c.qty,
      }))).execute();
      await writeAudit(tx, auditOf(ctx), 'channel_listing', listingId, 'update', null, { channelSku: b.channelSku });
      const created = await requeueUnmapped(tx, ctx, conn as Connection);
      return { listing: (await loadListings(tx, id, [listingId]))[0], ordersCreated: created };
    });
  } });

  app.delete<{ Params: { id: string; listingId: string } }>('/channels/:id/listings/:listingId', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    const listingId = parse(z.uuid(), req.params.listingId);
    await ctx.tx(async (tx) => {
      await loadConnection(tx, ctx, id);
      const r = await tx.deleteFrom('channel_listings').where('id', '=', listingId).where('connection_id', '=', id).executeTakeFirst();
      if (!r.numDeletedRows) throw notFound('Listing');
      await writeAudit(tx, auditOf(ctx), 'channel_listing', listingId, 'delete');
    });
    return reply.status(204).send();
  });

  // Orders ----------------------------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/channels/:id/orders/import', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(importBody, req.body);
    return ctx.tx(async (tx) => {
      const conn = await loadConnection(tx, ctx, id, true);
      if (conn.status === 'disabled') throw conflict('This channel is turned off.', 'CHANNEL_DISABLED');
      const { orders, issues } = parseOrderFile(b.csv, conn.csv_mapping, conn.prices_include_tax);
      if (orders.length > 2000) throw badRequest('At most 2000 orders in one file.', { csv: 'Too many orders' });
      if (b.dryRun) {
        const preview: Record<string, unknown>[] & { action?: string }[] = [];
        for (const o of orders) {
          const plan = await planOrder(tx, ctx, conn as Connection, { ...o, orderDate: o.orderDate || todayIst() });
          preview.push({
            externalRef: o.externalRef, orderDate: o.orderDate || null, buyerName: o.buyerName, action: plan.action, reason: plan.reason,
            unmappedSkus: plan.unmappedSkus, lines: plan.lines, estimate: plan.estimate, existingOrderId: plan.existingOrderId,
          });
        }
        const count = (a: string) => preview.filter((p) => p.action === a).length;
        return {
          dryRun: true, issues, orders: preview,
          summary: { total: preview.length, create: count('create'), duplicate: count('duplicate'), cancel: count('cancel'), ignored: count('ignored'), blocked: count('blocked') },
        };
      }
      const results: Outcome[] = [];
      for (const o of orders) results.push(await processOrder(tx, ctx, conn as Connection, o));
      await tx.updateTable('channel_connections').set({ last_import_at: new Date(), last_error: issues[0]?.message ?? null, updated_at: new Date() }).where('id', '=', id).execute();
      const count = (f: (r: Outcome) => boolean) => results.filter(f).length;
      await writeAudit(tx, auditOf(ctx), 'channel', id, 'import_orders', null, { orders: results.length, created: count((r) => r.action === 'create' && r.status === 'processed') });
      return {
        dryRun: false, issues, results,
        summary: {
          total: results.length, created: count((r) => r.action === 'create' && r.status === 'processed'),
          duplicates: count((r) => r.action === 'duplicate'), cancelled: count((r) => r.action === 'cancel' && r.status === 'processed'),
          ignored: count((r) => r.status === 'ignored'), failed: count((r) => r.status === 'failed'), heldAsDraft: count((r) => r.heldAsDraft),
        },
      };
    });
  });

  app.get('/channels/inbox', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.view');
    const q = parse(inboxQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('channel_inbox as i').innerJoin('channel_connections as c', 'c.id', 'i.connection_id')
        .leftJoin('sales_orders as o', 'o.id', 'i.sales_order_id').where('i.company_id', '=', ctx.companyId).where('i.topic', '=', 'order');
      if (q.connectionId) base = base.where('i.connection_id', '=', q.connectionId);
      if (q.status) base = base.where('i.status', '=', q.status);
      if (q.q) base = base.where((eb) => eb.or([eb('i.event_id', 'ilike', likeTerm(q.q!)), eb('o.number', 'ilike', likeTerm(q.q!))]));
      const total = await base.select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const rows = await base.select(['i.id', 'i.connection_id', 'c.name as connection_name', 'i.event_id', 'i.status', 'i.error', 'i.error_code',
        'i.sales_order_id', 'o.number as order_number', 'o.status as order_status', 'i.order_date', 'i.total', 'i.source', 'i.created_at', 'i.payload', 'i.attempts'])
        .orderBy('i.created_at', 'desc').orderBy('i.event_id').limit(q.limit).offset(q.offset).execute();
      const counts = await tx.selectFrom('channel_inbox').select('status').select((eb) => eb.fn.countAll<number>().as('n'))
        .where('company_id', '=', ctx.companyId).where('topic', '=', 'order').$if(Boolean(q.connectionId), (qb) => qb.where('connection_id', '=', q.connectionId!)).groupBy('status').execute();
      return {
        data: rows.map(inboxJson), total: Number(total.n),
        counts: Object.fromEntries(counts.map((c) => [c.status, Number(c.n)])),
      };
    });
  });

  app.post<{ Params: { id: string } }>('/channels/inbox/:id/retry', async (req) => {
    const ctx = req.ctx;
    ctx.require('channels.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const row = await tx.selectFrom('channel_inbox').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!row) throw notFound('Channel order');
      if (row.topic !== 'order') throw notFound('Channel order');
      if (row.status !== 'failed') throw conflict('Only failed orders can be tried again.', 'ILLEGAL_TRANSITION', { status: row.status });
      const conn = await loadConnection(tx, ctx, row.connection_id, true);
      const out = await processOrder(tx, ctx, conn as Connection, row.payload as NormalisedOrder);
      return { result: out };
    });
  });

  await channelLiveRoutes(app);
  await channelSettlementRoutes(app);
}

documentRoute('POST', '/channels', { body: createBody });
documentRoute('PATCH', '/channels/:id', { body: patchBody });
documentRoute('POST', '/channels/:id/listings', { body: listingBody });
documentRoute('PUT', '/channels/:id/listings/:listingId', { body: listingBody });
documentRoute('PATCH', '/channels/:id/listings/:listingId', { body: listingBody });
documentRoute('POST', '/channels/:id/orders/import', { body: importBody });
