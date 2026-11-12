import { randomUUID } from 'node:crypto';
import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { averageCost, lockItems, positions } from '../accounting/costing.ts';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { documentRoute } from '../lib/openapi.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const round3 = (n: number) => Math.round(n * 1000) / 1000;
const round4 = (n: number) => Math.round(n * 10_000) / 10_000;

const createBody = z.object({
  locationId: z.uuid(),
  itemIds: z.array(z.uuid()).min(1).max(2000).optional(),
  notes: optionalText(500),
});
const listQuery = pagingQuery.extend({
  status: z.enum(['open', 'posted', 'cancelled']).optional(),
  locationId: z.uuid().optional(),
});
const scanBody = z.object({
  scanId: z.string().trim().min(1).max(64).optional(),
  code: z.string().trim().min(1).max(100).optional(),
  itemId: z.uuid().optional(),
  qty: qtyField.optional(),
  mode: z.enum(['add', 'set']).optional(),
});
const postBody = z.object({ zeroUncounted: z.boolean().optional() }).optional();
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });

function requireView(ctx: RequestContext) {
  if (!ctx.can('stock_counts.manage') && !ctx.can('stock.view')) ctx.require('stock_counts.manage');
}

async function threshold(tx: Tx, ctx: RequestContext) {
  const c = await tx.selectFrom('companies').select('count_approval_value').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  return c.count_approval_value;
}

async function lockCount(tx: Tx, ctx: RequestContext, id: string) {
  const c = await tx.selectFrom('stock_counts').selectAll()
    .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!c || !ctx.canAccessLocation(c.location_id)) throw notFound('Stock count');
  return c;
}

type CountRow = Awaited<ReturnType<typeof lockCount>>;

async function lineViews(tx: Tx, ctx: RequestContext, c: CountRow) {
  const lines = await tx.selectFrom('stock_count_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.item_id', 'i.name', 'i.sku', 'i.barcode', 'i.unit', 'i.purchase_price', 'l.expected_qty', 'l.counted_qty', 'l.variance_qty', 'l.variance_value'])
    .where('l.count_id', '=', c.id).orderBy('i.name').execute();
  const ids = lines.map((l) => l.item_id);
  const moved = new Map<string, number>();
  if (ids.length) {
    let q = tx.selectFrom('stock_moves').select((eb) => ['item_id', eb.fn.sum<number>('qty').as('qty')])
      .where('company_id', '=', ctx.companyId).where('location_id', '=', c.location_id).where('item_id', 'in', ids)
      .where('created_at', '>', c.snapshot_at).where(sql<boolean>`ref_id is distinct from ${c.id}`);
    if (c.posted_at) q = q.where('created_at', '<=', c.posted_at);
    for (const r of await q.groupBy('item_id').execute()) moved.set(r.item_id, Number(r.qty));
  }
  const pos = c.status === 'open' ? await positions(tx, ctx.companyId, ids) : null;
  const showValue = ctx.can('items.view_cost');
  let absTotal = 0;
  const out = lines.map((l) => {
    const movedSince = round3(moved.get(l.item_id) ?? 0);
    const expectedNow = round3(l.expected_qty + movedSince);
    const live = c.status === 'open' && l.counted_qty !== null;
    const varianceQty = c.status === 'open' ? (l.counted_qty === null ? null : round3(l.counted_qty - expectedNow)) : l.variance_qty;
    let varianceValue: number | null = l.variance_value;
    if (live && varianceQty !== null) {
      const rate = averageCost(pos!.get(l.item_id) ?? { qty: 0, value: 0 }, l.purchase_price);
      varianceValue = round2(varianceQty * rate);
    }
    absTotal += Math.abs(varianceValue ?? 0);
    return {
      itemId: l.item_id, itemName: l.name, sku: l.sku, barcode: l.barcode, unit: l.unit, expectedQty: l.expected_qty, movedSince,
      expectedNow, countedQty: l.counted_qty, varianceQty, ...(showValue ? { varianceValue } : {}),
    };
  });
  return { lines: out, absTotal: round2(absTotal) };
}

async function countJson(tx: Tx, ctx: RequestContext, id: string) {
  const c = await tx.selectFrom('stock_counts as s').innerJoin('locations as l', 'l.id', 's.location_id')
    .selectAll('s').select('l.name as location_name').where('s.id', '=', id).where('s.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!c || !ctx.canAccessLocation(c.location_id)) throw notFound('Stock count');
  const { lines, absTotal } = await lineViews(tx, ctx, c);
  const thr = await threshold(tx, ctx);
  const counted = lines.filter((l) => l.countedQty !== null).length;
  return {
    id: c.id, number: c.number, status: c.status, scope: c.scope, locationId: c.location_id, locationName: c.location_name,
    snapshotAt: c.snapshot_at, notes: c.notes, varianceValue: ctx.can('items.view_cost') ? c.variance_value : undefined,
    postedAt: c.posted_at, postedBy: c.posted_by, approvedBy: c.approved_by, thresholdValue: thr, createdBy: c.created_by,
    createdAt: c.created_at, cancelReason: c.cancel_reason, needsApproval: c.status === 'open' && absTotal > thr,
    summary: { lines: lines.length, counted, uncounted: lines.length - counted, withVariance: lines.filter((l) => l.varianceQty).length },
    lines,
  };
}

export async function stockCountRoutes(app: FastifyInstance) {
  app.get('/stock-counts', async (req) => {
    const ctx = req.ctx;
    requireView(ctx);
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('stock_counts as s').innerJoin('locations as l', 'l.id', 's.location_id')
        .where('s.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('s.location_id', 'in', scope);
      if (q.status) base = base.where('s.status', '=', q.status);
      if (q.locationId) base = base.where('s.location_id', '=', q.locationId);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll('s').select('l.name as location_name')
        .select((eb) => [
          eb.selectFrom('stock_count_lines as x').select((e) => e.fn.countAll<number>().as('n')).whereRef('x.count_id', '=', 's.id').as('line_count'),
          eb.selectFrom('stock_count_lines as x').select((e) => e.fn.countAll<number>().as('n')).whereRef('x.count_id', '=', 's.id').where('x.counted_qty', 'is not', null).as('counted_count'),
        ])
        .orderBy('s.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      const showValue = ctx.can('items.view_cost');
      return {
        data: rows.map((r) => ({
          id: r.id, number: r.number, status: r.status, locationId: r.location_id, locationName: r.location_name, scope: r.scope,
          snapshotAt: r.snapshot_at, lineCount: Number(r.line_count), countedCount: Number(r.counted_count),
          ...(showValue ? { varianceValue: r.variance_value } : {}), createdAt: r.created_at,
        })),
        total: Number(total),
      };
    });
  });

  app.get<{ Params: { id: string } }>('/stock-counts/:id', async (req) => {
    const ctx = req.ctx;
    requireView(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => countJson(tx, ctx, id));
  });

  app.post('/stock-counts', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('stock_counts.manage');
    const body = parse(createBody, req.body);
    const saved = await ctx.tx(async (tx) => {
      const location = await getLocation(tx, ctx, body.locationId);
      if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
      await sql`select pg_advisory_xact_lock(hashtextextended(${`count:${location.id}`}, 0))`.execute(tx);
      const open = await tx.selectFrom('stock_counts').select('number')
        .where('company_id', '=', ctx.companyId).where('location_id', '=', location.id).where('status', '=', 'open').executeTakeFirst();
      if (open) throw conflict(`Count ${open.number} is still open at ${location.name}. Post or cancel it first.`, 'COUNT_OPEN');

      let itemIds: string[];
      if (body.itemIds) {
        const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId)
          .where('track_stock', '=', true).where('id', 'in', body.itemIds).execute();
        if (found.length !== new Set(body.itemIds).size) throw badRequest('Some items were not found or do not track stock.', { itemIds: 'Invalid' });
        itemIds = found.map((f) => f.id);
      } else {
        const rows = await tx.selectFrom('stock_moves as m').innerJoin('items as i', 'i.id', 'm.item_id')
          .select('m.item_id').distinct().where('m.company_id', '=', ctx.companyId).where('m.location_id', '=', location.id)
          .where('i.track_stock', '=', true).execute();
        itemIds = rows.map((r) => r.item_id);
      }
      await lockItems(tx, ctx.companyId, itemIds);
      const fy = financialYear(todayIst());
      const number = await nextNumber(tx, ctx, 'stock_count', fy);
      const row = await tx.insertInto('stock_counts').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: location.id, number, fy,
        scope: body.itemIds ? 'selected' : 'all', notes: body.notes ?? null, variance_value: null, approved_by: null,
        posted_by: null, posted_at: null, cancelled_at: null, cancel_reason: null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      if (itemIds.length) {
        const qty = await tx.selectFrom('stock_moves').select((eb) => ['item_id', eb.fn.sum<number>('qty').as('qty')])
          .where('company_id', '=', ctx.companyId).where('location_id', '=', location.id).where('item_id', 'in', itemIds)
          .groupBy('item_id').execute();
        const byItem = new Map(qty.map((q) => [q.item_id, Number(q.qty)]));
        await tx.insertInto('stock_count_lines').values(itemIds.map((id) => ({
          tenant_id: ctx.tenantId, count_id: row.id, item_id: id, expected_qty: round3(byItem.get(id) ?? 0),
          counted_qty: null, counted_at: null, counted_by: null, variance_qty: null, variance_value: null,
        }))).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'stock_count', row.id, 'create', null,
        { number, locationId: location.id, scope: body.itemIds ? 'selected' : 'all', lines: itemIds.length });
      return countJson(tx, ctx, row.id);
    });
    return reply.status(201).send(saved);
  });

  app.post<{ Params: { id: string } }>('/stock-counts/:id/scans', async (req) => {
    const ctx = req.ctx;
    ctx.require('stock_counts.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(scanBody, req.body);
    if (!!body.code === !!body.itemId) throw badRequest('Send either a code or an item.', { code: 'Send a code or an item' });
    const mode = body.mode ?? 'add';
    const qty = body.qty ?? 1;
    if (mode === 'add' && qty <= 0) throw badRequest('Quantity must be more than zero.', { qty: 'Must be more than zero' });
    if (mode === 'set' && qty < 0) throw badRequest('Quantity cannot be negative.', { qty: 'Cannot be negative' });
    return ctx.tx(async (tx) => {
      const c = await lockCount(tx, ctx, id);
      if (c.status !== 'open') throw conflict('This count is not open.', 'NOT_OPEN');
      const scanId = body.scanId ?? randomUUID();
      const lineOut = async (itemId: string, duplicate: boolean) => {
        const view = await lineViews(tx, ctx, c);
        return { duplicate, line: view.lines.find((l) => l.itemId === itemId)! };
      };
      const dup = await tx.selectFrom('stock_count_scans').select('item_id').where('count_id', '=', id).where('scan_id', '=', scanId).executeTakeFirst();
      if (dup) return lineOut(dup.item_id, true);

      let item: { id: string; track_stock: boolean };
      if (body.itemId) {
        const found = await tx.selectFrom('items').select(['id', 'track_stock']).where('company_id', '=', ctx.companyId).where('id', '=', body.itemId).executeTakeFirst();
        if (!found) throw badRequest('Item not found.', { itemId: 'Not found' });
        item = found;
      } else {
        const code = body.code!.toLowerCase();
        const found = await tx.selectFrom('items').select(['id', 'track_stock']).where('company_id', '=', ctx.companyId)
          .where((eb) => eb.or([eb(sql`lower(barcode)`, '=', code), eb(sql`lower(sku)`, '=', code)]))
          .orderBy(sql`(lower(barcode) = ${code})`, 'desc').limit(1).executeTakeFirst();
        if (!found) throw new AppError(400, 'UNKNOWN_BARCODE', `No item has the code ${body.code}.`, { code: 'Unknown code' });
        item = found;
      }
      if (!item.track_stock) throw badRequest('This item does not track stock.', { itemId: 'Not stock tracked' });
      let line = await tx.selectFrom('stock_count_lines').select(['id', 'counted_qty']).where('count_id', '=', id).where('item_id', '=', item.id).executeTakeFirst();
      if (!line) {
        if (c.scope === 'selected') throw new AppError(400, 'NOT_IN_COUNT', 'This item is not part of the count.', { itemId: 'Not in this count' });
        line = await tx.insertInto('stock_count_lines').values({
          tenant_id: ctx.tenantId, count_id: id, item_id: item.id, expected_qty: 0, counted_qty: null, counted_at: null,
          counted_by: null, variance_qty: null, variance_value: null,
        }).returning(['id', 'counted_qty']).executeTakeFirstOrThrow();
      }
      const counted = round3(mode === 'add' ? (line.counted_qty ?? 0) + qty : qty);
      await tx.updateTable('stock_count_lines').set({ counted_qty: counted, counted_at: new Date(), counted_by: ctx.userId }).where('id', '=', line.id).execute();
      await tx.insertInto('stock_count_scans').values({
        tenant_id: ctx.tenantId, count_id: id, scan_id: scanId, item_id: item.id, code: body.code ?? null, mode, qty, created_by: ctx.userId,
      }).execute();
      return lineOut(item.id, false);
    });
  });

  app.post<{ Params: { id: string } }>('/stock-counts/:id/post', async (req) => {
    const ctx = req.ctx;
    ctx.require('stock_counts.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(postBody, req.body ?? undefined);
    return ctx.tx(async (tx) => {
      const c = await lockCount(tx, ctx, id);
      if (c.status !== 'open') throw conflict('This count is not open.', 'NOT_OPEN');
      const lines = await tx.selectFrom('stock_count_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
        .select(['l.id', 'l.item_id', 'l.expected_qty', 'l.counted_qty', 'i.purchase_price'])
        .where('l.count_id', '=', id).execute();
      await lockItems(tx, ctx.companyId, lines.map((l) => l.item_id));
      const ids = lines.map((l) => l.item_id);
      const pos = await positions(tx, ctx.companyId, ids);
      const movedRows = ids.length ? await tx.selectFrom('stock_moves').select((eb) => ['item_id', eb.fn.sum<number>('qty').as('qty')])
        .where('company_id', '=', ctx.companyId).where('location_id', '=', c.location_id).where('item_id', 'in', ids)
        .where('created_at', '>', c.snapshot_at).groupBy('item_id').execute() : [];
      const moved = new Map(movedRows.map((m) => [m.item_id, Number(m.qty)]));

      const plan = [] as { line: (typeof lines)[number]; varianceQty: number; rate: number; value: number }[];
      const done = [] as { id: string; varianceQty: number; value: number }[];
      for (const l of lines) {
        const counted = l.counted_qty ?? (body?.zeroUncounted ? 0 : null);
        if (counted === null) continue;
        const expectedNow = round3(l.expected_qty + (moved.get(l.item_id) ?? 0));
        const varianceQty = round3(counted - expectedNow);
        const p = pos.get(l.item_id)!;
        const rate = averageCost(p, l.purchase_price);
        let value = 0;
        if (varianceQty < 0) {
          const lastUnits = p.qty > 0 && Math.abs(p.qty + varianceQty) < 0.0005;
          value = -(lastUnits ? round2(Math.max(p.value, 0)) : round2(-varianceQty * rate));
        } else if (varianceQty > 0) value = round2(varianceQty * rate);
        done.push({ id: l.id, varianceQty, value });
        if (varianceQty !== 0) plan.push({ line: l, varianceQty, rate: round4(rate), value });
      }
      const absTotal = round2(plan.reduce((s, p) => s + Math.abs(p.value), 0));
      const thr = await threshold(tx, ctx);
      const approver = ctx.can('stock_counts.approve');
      if (absTotal > thr && !approver) {
        throw new AppError(403, 'COUNT_APPROVAL_REQUIRED',
          `The variance of ${absTotal.toFixed(2)} is above ${thr.toFixed(2)}. Someone who can approve stock counts must post this count.`,
          { varianceValue: absTotal, thresholdValue: thr });
      }
      const net = round2(plan.reduce((s, p) => s + p.value, 0));
      if (plan.length) {
        await tx.insertInto('stock_moves').values(plan.map((p) => ({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: c.location_id, item_id: p.line.item_id, qty: p.varianceQty,
          rate: p.rate, cost_rate: p.rate, value: p.value, ref_type: 'stock_count', ref_id: id, note: c.number, created_by: ctx.userId,
        }))).execute();
        const acc = await systemAccounts(tx, ctx);
        const loss = round2(plan.filter((p) => p.value < 0).reduce((s, p) => s - p.value, 0));
        const gain = round2(plan.filter((p) => p.value > 0).reduce((s, p) => s + p.value, 0));
        await postJournal(tx, auditOf(ctx), {
          date: todayIst(), voucherType: 'stock', voucherId: id, number: c.number, narration: `Stock count ${c.number}`,
          lines: [
            { accountId: acc.inventory, amount: net, locationId: c.location_id },
            { accountId: acc.stock_loss, amount: loss, locationId: c.location_id },
            { accountId: acc.other_income, amount: -gain, locationId: c.location_id },
          ],
        });
      }
      for (const d of done) {
        await tx.updateTable('stock_count_lines').set({ variance_qty: d.varianceQty, variance_value: d.value }).where('id', '=', d.id).execute();
      }
      await tx.updateTable('stock_counts').set({
        status: 'posted', variance_value: net, posted_by: ctx.userId, posted_at: new Date(), approved_by: absTotal > thr ? ctx.userId : null,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'stock_count', id, 'post', { status: 'open' },
        { status: 'posted', net, absolute: absTotal, lines: plan.length });
      return countJson(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/stock-counts/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('stock_counts.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const c = await lockCount(tx, ctx, id);
      if (c.status !== 'open') throw conflict('This count is not open.', 'NOT_OPEN');
      await tx.updateTable('stock_counts').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'stock_count', id, 'cancel', { status: 'open' }, { status: 'cancelled', reason });
      return countJson(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/stock-counts', { body: createBody });
documentRoute('POST', '/stock-counts/:id/scans', { body: scanBody });
documentRoute('POST', '/stock-counts/:id/cancel', { body: cancelBody });
