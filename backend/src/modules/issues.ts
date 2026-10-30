import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { issue, lockItems, positions } from '../accounting/costing.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { boqLinesAt } from './projects.ts';
import { requireStock } from './stock.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const createBody = z.object({
  locationId: z.uuid(),
  boqLineId: z.uuid().nullable().optional(),
  date: docDate.optional(),
  notes: optionalText(500),
  lines: z.array(z.object({ itemId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero') }))
    .min(1, 'Add at least one item').max(200),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  locationId: z.uuid().optional(),
  projectId: z.uuid().optional(),
  boqLineId: z.uuid().optional(),
  from: dateField.optional(),
  to: dateField.optional(),
  status: z.enum(['posted', 'cancelled']).optional(),
});

/** Issues as JSON, in the order of `ids`; costs only with items.view_cost. */
async function loadIssues(tx: Tx, ctx: RequestContext, ids: string[]) {
  if (!ids.length) return [];
  const rows = await tx.selectFrom('issues as s')
    .innerJoin('locations as l', 'l.id', 's.location_id')
    .innerJoin('users as u', 'u.id', 's.created_by')
    .leftJoin('boq_lines as b', 'b.id', 's.boq_line_id')
    .selectAll('s')
    .select(['l.name as location_name', 'l.project_id', 'u.name as created_by_name', 'b.code as boq_code'])
    .where('s.id', 'in', ids).execute();
  const lines = await tx.selectFrom('issue_lines as il').innerJoin('items as i', 'i.id', 'il.item_id')
    .select(['il.issue_id', 'il.item_id', 'i.name', 'i.unit', 'il.qty', 'il.cost_rate', 'il.value'])
    .where('il.issue_id', 'in', ids).orderBy('il.line_no').execute();
  const showCost = ctx.can('items.view_cost');
  return ids.map((id) => {
    const s = rows.find((r) => r.id === id)!;
    const mine = lines.filter((l) => l.issue_id === id);
    return {
      id: s.id, number: s.number, locationId: s.location_id, locationName: s.location_name, projectId: s.project_id,
      boqLineId: s.boq_line_id, boqCode: s.boq_code, date: s.issue_date, notes: s.notes, status: s.status,
      createdAt: s.created_at, createdBy: { id: s.created_by, name: s.created_by_name },
      cancelledAt: s.cancelled_at, cancelReason: s.cancel_reason,
      ...(showCost ? { totalValue: round2(mine.reduce((sum, l) => sum + l.value, 0)) } : {}),
      lines: mine.map((l) => ({
        itemId: l.item_id, itemName: l.name, unit: l.unit, qty: l.qty,
        ...(showCost ? { costRate: l.cost_rate, value: l.value } : {}),
      })),
    };
  });
}

export async function issueRoutes(app: FastifyInstance) {
  app.get('/issues', async (req) => {
    const ctx = req.ctx;
    ctx.require('consumption.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('issues as s').innerJoin('locations as l', 'l.id', 's.location_id')
        .where('s.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('s.location_id', 'in', scope);
      if (q.locationId) base = base.where('s.location_id', '=', q.locationId);
      if (q.projectId) base = base.where('l.project_id', '=', q.projectId);
      if (q.boqLineId) base = base.where('s.boq_line_id', '=', q.boqLineId);
      if (q.from) base = base.where('s.issue_date', '>=', q.from);
      if (q.to) base = base.where('s.issue_date', '<=', q.to);
      if (q.status) base = base.where('s.status', '=', q.status);
      if (q.q) base = base.where((eb) => eb.or([eb('s.number', 'ilike', likeTerm(q.q!)), eb('s.notes', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('s.id').orderBy('s.issue_date', 'desc').orderBy('s.created_at', 'desc')
        .limit(q.limit).offset(q.offset).execute();
      return { data: await loadIssues(tx, ctx, ids.map((r) => r.id)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/issues/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('consumption.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const s = await tx.selectFrom('issues').select('location_id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!s || !ctx.canAccessLocation(s.location_id)) throw notFound('Material issue');
      return (await loadIssues(tx, ctx, [id]))[0];
    });
  });

  app.post('/issues', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('consumption.create');
    const body = parse(createBody, req.body);
    const saved = await ctx.tx(async (tx) => {
      const location = await getLocation(tx, ctx, body.locationId);
      if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
      if (body.boqLineId) await boqLinesAt(tx, location, [{ id: body.boqLineId, field: 'boqLineId' }]);
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });

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
      for (const [itemId, qty] of totals) await requireStock(tx, ctx, location, items.find((x) => x.id === itemId)!, qty);

      const pos = await positions(tx, ctx.companyId, ids);
      const costed = body.lines.map((l) => {
        const item = items.find((x) => x.id === l.itemId)!;
        const out = issue(pos.get(l.itemId)!, l.qty, item.purchase_price);
        pos.set(l.itemId, out.after);
        return { ...l, costRate: out.costRate, value: out.value };
      });

      const number = await nextNumber(tx, ctx, 'issue', financialYear(date));
      const row = await tx.insertInto('issues').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, issue_date: date, location_id: location.id,
        boq_line_id: body.boqLineId ?? null, notes: body.notes ?? null, created_by: ctx.userId,
        cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('issue_lines').values(costed.map((c, i) => ({
        tenant_id: ctx.tenantId, issue_id: row.id, line_no: i + 1, item_id: c.itemId, qty: c.qty, cost_rate: c.costRate, value: c.value,
      }))).execute();
      await tx.insertInto('stock_moves').values(costed.map((c) => ({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: location.id, item_id: c.itemId, qty: -c.qty, rate: null,
        cost_rate: c.costRate, value: -c.value, ref_type: 'issue', ref_id: row.id, note: `${number} issued to work`, created_by: ctx.userId,
      }))).execute();

      const value = round2(costed.reduce((s, c) => s + c.value, 0));
      if (value !== 0) {
        const acc = await systemAccounts(tx, ctx);
        await postJournal(tx, auditOf(ctx), {
          date, voucherType: 'issue', voucherId: row.id, number, narration: `Material issued to work at ${location.name}`,
          lines: [
            { accountId: acc.material_consumed, amount: value, locationId: location.id },
            { accountId: acc.inventory, amount: -value, locationId: location.id },
          ],
        });
      }
      await writeAudit(tx, auditOf(ctx), 'issue', row.id, 'create', null,
        { number, locationId: location.id, boqLineId: body.boqLineId ?? null, lines: body.lines });
      return (await loadIssues(tx, ctx, [row.id]))[0];
    });
    return reply.status(201).send(saved);
  });

  app.post<{ Params: { id: string } }>('/issues/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('consumption.create');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const s = await tx.selectFrom('issues').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!s || !ctx.canAccessLocation(s.location_id)) throw notFound('Material issue');
      if (s.status === 'cancelled') throw conflict('This issue is already cancelled.', 'ALREADY_CANCELLED');

      const lines = await tx.selectFrom('issue_lines').selectAll().where('issue_id', '=', id).execute();
      await lockItems(tx, ctx.companyId, lines.map((l) => l.item_id));
      // Stock returns at the cost it left at, so the average cost is restored exactly.
      await tx.insertInto('stock_moves').values(lines.map((l) => ({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: s.location_id, item_id: l.item_id, qty: l.qty, rate: null,
        cost_rate: l.cost_rate, value: l.value, ref_type: 'issue_cancel', ref_id: id, note: `Cancelled ${s.number}`, created_by: ctx.userId,
      }))).execute();
      await tx.updateTable('issues').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${s.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'issue', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return (await loadIssues(tx, ctx, [id]))[0];
    });
  });
}
