import type { FastifyInstance, FastifyRequest } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { documentRoute } from '../lib/openapi.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { createPo } from './purchase-orders.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const rfqBody = z.object({
  locationId: z.uuid().optional(),
  rfqDate: docDate.optional(),
  dueDate: docDate.nullable().optional(),
  notes: optionalText(1000),
  indentId: z.uuid().nullable().optional(),
  vendorIds: z.array(z.uuid()).min(1, 'Choose at least one vendor').max(20, 'At most 20 vendors'),
  lines: z.array(z.object({
    itemId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero'), description: optionalText(300),
  })).max(200, 'At most 200 lines').optional(),
});
type RfqBody = z.infer<typeof rfqBody>;
const quotesBody = z.object({
  partyId: z.uuid(),
  quotes: z.array(z.object({
    lineId: z.uuid(), rate: moneyField, discountPct: percentField.optional(), gstRate: percentField.optional(),
    leadDays: z.coerce.number().int().min(0).max(3650).nullable().optional(), paymentTerms: optionalText(200),
    validUntil: dateField.nullable().optional(), notes: optionalText(500),
  })).max(200),
});
const choicesBody = z.union([
  z.object({ mode: z.literal('lowest') }),
  z.object({ choices: z.array(z.object({ lineId: z.uuid(), partyId: z.uuid().nullable() })).min(1).max(200) }),
]);
const listQuery = pagingQuery.extend({ status: z.enum(['draft', 'sent', 'quotes_received', 'closed']).optional() });

/** Total of a quote: quantity x rate, less discount, plus GST. */
export const quoteTotals = (qty: number, rate: number, discountPct: number, gstRate: number) => {
  const taxable = round2(qty * rate * (1 - discountPct / 100));
  return { taxable, total: round2(taxable * (1 + gstRate / 100)) };
};

async function lockRfq(tx: Tx, ctx: RequestContext, id: string) {
  const r = await tx.selectFrom('rfqs').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!r || !ctx.canAccessLocation(r.location_id)) throw notFound('Request for quotation');
  return r;
}

async function loadRfq(tx: Tx, ctx: RequestContext, id: string) {
  const r = await tx.selectFrom('rfqs as r').innerJoin('locations as l', 'l.id', 'r.location_id').selectAll('r')
    .select('l.name as location_name').where('r.id', '=', id).where('r.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!r || !ctx.canAccessLocation(r.location_id)) throw notFound('Request for quotation');
  const vendors = await tx.selectFrom('rfq_vendors as v').innerJoin('parties as p', 'p.id', 'v.party_id')
    .select(['v.party_id', 'p.name', 'v.sent_at']).where('v.rfq_id', '=', id).orderBy('p.name').execute();
  const lines = await tx.selectFrom('rfq_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.id', 'l.line_no', 'l.item_id', 'i.name as item_name', 'l.description', 'l.qty', 'l.unit', 'l.chosen_party_id', 'l.purchase_order_id'])
    .where('l.rfq_id', '=', id).orderBy('l.line_no').execute();
  const quotes = await tx.selectFrom('rfq_quotes').selectAll().where('rfq_id', '=', id).execute();
  const names = new Map(vendors.map((v) => [v.party_id, v.name]));
  const vendorTotals = new Map<string, number>();
  const lineJson = lines.map((l) => {
    const qs = quotes.filter((q) => q.rfq_line_id === l.id).map((q) => ({ q, ...quoteTotals(l.qty, q.rate, q.discount_pct, q.gst_rate) }));
    const lowest = qs.length ? Math.min(...qs.map((x) => x.total)) : null;
    const leads = qs.filter((x) => x.q.lead_days != null).map((x) => x.q.lead_days!);
    const fastest = leads.length ? Math.min(...leads) : null;
    for (const x of qs) vendorTotals.set(x.q.party_id, round2((vendorTotals.get(x.q.party_id) ?? 0) + x.total));
    return {
      id: l.id, lineNo: l.line_no, itemId: l.item_id, itemName: l.item_name, description: l.description, qty: l.qty, unit: l.unit,
      chosenPartyId: l.chosen_party_id, purchaseOrderId: l.purchase_order_id,
      quotes: qs.map(({ q, taxable, total }) => ({
        partyId: q.party_id, partyName: names.get(q.party_id) ?? '', rate: q.rate, discountPct: q.discount_pct, gstRate: q.gst_rate,
        leadDays: q.lead_days, paymentTerms: q.payment_terms, validUntil: q.valid_until, notes: q.notes, taxable, total,
        isLowest: total === lowest, isFastest: fastest !== null && q.lead_days === fastest,
      })),
    };
  });
  const poIds = [...new Set(lines.map((l) => l.purchase_order_id).filter((x): x is string => !!x))];
  const pos = poIds.length
    ? await tx.selectFrom('purchase_orders').select(['id', 'number', 'party_id']).where('id', 'in', poIds).execute()
    : [];
  return {
    id: r.id, number: r.number, status: r.status, rfqDate: r.rfq_date, dueDate: r.due_date, locationId: r.location_id,
    locationName: r.location_name, indentId: r.indent_id, notes: r.notes, sentAt: r.sent_at, closedAt: r.closed_at,
    createdAt: r.created_at, updatedAt: r.updated_at,
    vendors: vendors.map((v) => ({ partyId: v.party_id, partyName: v.name, sentAt: v.sent_at, total: vendorTotals.get(v.party_id) ?? 0 })),
    lines: lineJson,
    purchaseOrders: pos.map((p) => ({ id: p.id, number: p.number, partyId: p.party_id })),
  };
}

async function writeContent(tx: Tx, ctx: RequestContext, rfqId: string, b: RfqBody) {
  const vendorIds = [...new Set(b.vendorIds)];
  const parties = await tx.selectFrom('parties').select(['id', 'type', 'name']).where('company_id', '=', ctx.companyId).where('id', 'in', vendorIds).execute();
  if (parties.length !== vendorIds.length) throw badRequest('A vendor was not found.', { vendorIds: 'Not found' });
  const bad = parties.find((p) => p.type === 'customer');
  if (bad) throw badRequest(`${bad.name} is a customer. Choose vendors.`, { vendorIds: 'Not a vendor' });

  let lines: { itemId: string; qty: number; description: string | null; indentLineId: string | null }[] = (b.lines ?? [])
    .map((l) => ({ itemId: l.itemId, qty: l.qty, description: l.description ?? null, indentLineId: null }));
  if (b.indentId && !b.lines?.length) {
    const il = await tx.selectFrom('indent_lines').select(['id', 'item_id', 'qty', 'approved_qty']).where('indent_id', '=', b.indentId).orderBy('line_no').execute();
    lines = il.map((l) => ({ itemId: l.item_id, qty: l.approved_qty ?? l.qty, description: null, indentLineId: l.id })).filter((l) => l.qty > 0);
  }
  if (!lines.length) throw badRequest('Add at least one line.', { lines: 'Required' });
  const ids = [...new Set(lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').selectAll().where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const byId = new Map(items.map((i) => [i.id, i]));
  await tx.deleteFrom('rfq_lines').where('rfq_id', '=', rfqId).execute();
  await tx.deleteFrom('rfq_vendors').where('rfq_id', '=', rfqId).execute();
  await tx.insertInto('rfq_lines').values(lines.map((l, i) => {
    const item = byId.get(l.itemId);
    if (!item) throw badRequest(`Line ${i + 1}: item not found.`, { [`lines.${i}.itemId`]: 'Not found' });
    return { tenant_id: ctx.tenantId, rfq_id: rfqId, line_no: i + 1, item_id: item.id, description: l.description ?? item.name,
      qty: l.qty, unit: item.unit, indent_line_id: l.indentLineId, chosen_party_id: null, purchase_order_id: null };
  })).execute();
  await tx.insertInto('rfq_vendors').values(vendorIds.map((p) => ({ tenant_id: ctx.tenantId, rfq_id: rfqId, party_id: p, sent_at: null }))).execute();
}

async function resolveHeader(tx: Tx, ctx: RequestContext, b: RfqBody) {
  let locationId = b.locationId;
  if (b.indentId) {
    const ind = await tx.selectFrom('indents').select(['id', 'status', 'location_id']).where('id', '=', b.indentId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!ind) throw badRequest('Indent not found.', { indentId: 'Not found' });
    if (ind.status !== 'approved') throw badRequest('Only an approved indent can go to quotation.', { indentId: 'Not approved' });
    locationId = locationId ?? ind.location_id;
  }
  if (!locationId) throw badRequest('Choose a location.', { locationId: 'Required' });
  const loc = await getLocation(tx, ctx, locationId);
  const rfqDate = b.rfqDate ?? todayIst();
  if (b.dueDate && b.dueDate < rfqDate) throw badRequest('Due date cannot be before the RFQ date.', { dueDate: 'Before RFQ date' });
  return { loc, rfqDate };
}

const invalid = (status: string, action: string) => conflict(`A ${status.replace('_', ' ')} request cannot be ${action}.`, 'INVALID_STATE');

export async function rfqRoutes(app: FastifyInstance) {
  app.get('/rfqs', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('rfqs as r').innerJoin('locations as l', 'l.id', 'r.location_id').selectAll('r')
        .select(['l.name as location_name',
          (eb) => eb.selectFrom('rfq_vendors as v').select((e) => e.fn.countAll<number>().as('n')).whereRef('v.rfq_id', '=', 'r.id').as('vendor_count'),
          (eb) => eb.selectFrom('rfq_lines as x').select((e) => e.fn.countAll<number>().as('n')).whereRef('x.rfq_id', '=', 'r.id').as('line_count'),
        ]).where('r.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('r.location_id', 'in', scope);
      if (q.status) base = base.where('r.status', '=', q.status);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('r.number', 'ilike', t), eb('r.notes', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('r.rfq_date', 'desc').orderBy('r.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((r) => ({
          id: r.id, number: r.number, status: r.status, rfqDate: r.rfq_date, dueDate: r.due_date, locationId: r.location_id,
          locationName: r.location_name, indentId: r.indent_id, notes: r.notes, vendorCount: Number(r.vendor_count ?? 0),
          lineCount: Number(r.line_count ?? 0), sentAt: r.sent_at,
        })),
        total,
      };
    });
  });

  app.get<{ Params: { id: string } }>('/rfqs/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadRfq(tx, ctx, id));
  });

  app.post('/rfqs', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const b = parse(rfqBody, req.body);
    return reply.status(201).send(await ctx.tx(async (tx) => {
      const h = await resolveHeader(tx, ctx, b);
      const fy = financialYear(h.rfqDate);
      const number = await nextNumber(tx, ctx, 'rfq', fy);
      const row = await tx.insertInto('rfqs').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: h.loc.id, number, fy, rfq_date: h.rfqDate,
        due_date: b.dueDate ?? null, indent_id: b.indentId ?? null, notes: b.notes ?? null, sent_at: null, closed_at: null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeContent(tx, ctx, row.id, b);
      await writeAudit(tx, auditOf(ctx), 'rfq', row.id, 'create', null, { number });
      return loadRfq(tx, ctx, row.id);
    }));
  });

  const update = async (req: FastifyRequest<{ Params: { id: string } }>) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(rfqBody, req.body);
    return ctx.tx(async (tx) => {
      const r = await lockRfq(tx, ctx, id);
      if (r.status !== 'draft') throw conflict('Only a draft request can be edited.', 'NOT_EDITABLE');
      const h = await resolveHeader(tx, ctx, b);
      await tx.updateTable('rfqs').set({ location_id: h.loc.id, rfq_date: h.rfqDate, fy: financialYear(h.rfqDate), due_date: b.dueDate ?? null,
        indent_id: b.indentId ?? null, notes: b.notes ?? null, updated_at: new Date() }).where('id', '=', id).execute();
      await writeContent(tx, ctx, id, b);
      await writeAudit(tx, auditOf(ctx), 'rfq', id, 'update', null, { number: r.number });
      return loadRfq(tx, ctx, id);
    });
  };
  app.put<{ Params: { id: string } }>('/rfqs/:id', update);
  app.patch<{ Params: { id: string } }>('/rfqs/:id', update);

  app.delete<{ Params: { id: string } }>('/rfqs/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const r = await lockRfq(tx, ctx, id);
      if (r.status !== 'draft') throw conflict('Only a draft request can be deleted.', 'NOT_EDITABLE');
      await tx.deleteFrom('rfqs').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'rfq', id, 'delete', { number: r.number }, null);
    });
    return reply.status(204).send();
  });

  app.post<{ Params: { id: string } }>('/rfqs/:id/send', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const r = await lockRfq(tx, ctx, id);
      if (r.status !== 'draft' && r.status !== 'sent') throw invalid(r.status, 'sent');
      const now = new Date();
      await tx.updateTable('rfq_vendors').set({ sent_at: now }).where('rfq_id', '=', id).execute();
      await tx.updateTable('rfqs').set({ status: 'sent', sent_at: r.sent_at ?? now, updated_at: now }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'rfq', id, 'send', { status: r.status }, { status: 'sent' });
      return loadRfq(tx, ctx, id);
    });
  });

  const putQuotes = async (req: FastifyRequest<{ Params: { id: string } }>) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(quotesBody, req.body);
    return ctx.tx(async (tx) => {
      const r = await lockRfq(tx, ctx, id);
      if (r.status !== 'sent' && r.status !== 'quotes_received') throw conflict(r.status === 'draft' ? 'Send the request before recording quotes.' : 'This request is closed.', 'INVALID_STATE');
      const v = await tx.selectFrom('rfq_vendors').select('id').where('rfq_id', '=', id).where('party_id', '=', b.partyId).executeTakeFirst();
      if (!v) throw badRequest('That vendor is not on this request.', { partyId: 'Not on request' });
      const lines = await tx.selectFrom('rfq_lines').select('id').where('rfq_id', '=', id).execute();
      const ok = new Set(lines.map((l) => l.id));
      const seen = new Set<string>();
      for (const [i, q] of b.quotes.entries()) {
        if (!ok.has(q.lineId)) throw badRequest(`Quote ${i + 1}: line not on this request.`, { [`quotes.${i}.lineId`]: 'Not found' });
        if (seen.has(q.lineId)) throw badRequest(`Quote ${i + 1}: line listed twice.`, { [`quotes.${i}.lineId`]: 'Duplicate' });
        seen.add(q.lineId);
      }
      await tx.deleteFrom('rfq_quotes').where('rfq_id', '=', id).where('party_id', '=', b.partyId).execute();
      if (b.quotes.length) {
        await tx.insertInto('rfq_quotes').values(b.quotes.map((q) => ({
          tenant_id: ctx.tenantId, rfq_id: id, rfq_line_id: q.lineId, party_id: b.partyId, rate: q.rate, discount_pct: q.discountPct ?? 0,
          gst_rate: q.gstRate ?? 0, lead_days: q.leadDays ?? null, payment_terms: q.paymentTerms ?? null, valid_until: q.validUntil ?? null,
          notes: q.notes ?? null,
        }))).execute();
      }
      // A removed quote can no longer be the chosen one.
      await tx.updateTable('rfq_lines').set({ chosen_party_id: null }).where('rfq_id', '=', id).where('chosen_party_id', '=', b.partyId)
        .where('id', 'not in', b.quotes.length ? b.quotes.map((q) => q.lineId) : ['00000000-0000-0000-0000-000000000000']).execute();
      const any = await tx.selectFrom('rfq_quotes').select('id').where('rfq_id', '=', id).executeTakeFirst();
      await tx.updateTable('rfqs').set({ status: any ? 'quotes_received' : 'sent', updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'rfq', id, 'quotes', null, { partyId: b.partyId, count: b.quotes.length });
      return loadRfq(tx, ctx, id);
    });
  };
  app.put<{ Params: { id: string } }>('/rfqs/:id/quotes', putQuotes);
  app.patch<{ Params: { id: string } }>('/rfqs/:id/quotes', putQuotes);

  const putChoices = async (req: FastifyRequest<{ Params: { id: string } }>) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(choicesBody, req.body);
    return ctx.tx(async (tx) => {
      const r = await lockRfq(tx, ctx, id);
      if (r.status !== 'quotes_received') throw conflict('Record at least one quote first.', 'INVALID_STATE');
      const detail = await loadRfq(tx, ctx, id);
      const picks = 'mode' in b
        ? detail.lines.flatMap((l) => {
          const best = l.quotes.filter((q) => q.isLowest).sort((a, c) => (a.leadDays ?? 9999) - (c.leadDays ?? 9999))[0];
          return best ? [{ lineId: l.id, partyId: best.partyId as string | null }] : [];
        })
        : b.choices;
      for (const [i, c] of picks.entries()) {
        const line = detail.lines.find((l) => l.id === c.lineId);
        if (!line) throw badRequest(`Choice ${i + 1}: line not on this request.`, { [`choices.${i}.lineId`]: 'Not found' });
        if (c.partyId && !line.quotes.some((q) => q.partyId === c.partyId)) {
          throw badRequest(`Choice ${i + 1}: that vendor has not quoted line ${line.lineNo}.`, { [`choices.${i}.partyId`]: 'No quote' });
        }
        await tx.updateTable('rfq_lines').set({ chosen_party_id: c.partyId }).where('id', '=', c.lineId).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'rfq', id, 'choose', null, { lines: picks.length });
      return loadRfq(tx, ctx, id);
    });
  };
  app.put<{ Params: { id: string } }>('/rfqs/:id/choices', putChoices);
  app.patch<{ Params: { id: string } }>('/rfqs/:id/choices', putChoices);

  app.post<{ Params: { id: string } }>('/rfqs/:id/convert', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const r = await lockRfq(tx, ctx, id);
      if (r.status !== 'quotes_received') throw invalid(r.status, 'turned into orders');
      const lines = await tx.selectFrom('rfq_lines').selectAll().where('rfq_id', '=', id).where('chosen_party_id', 'is not', null).orderBy('line_no').execute();
      if (!lines.length) throw conflict('Choose a vendor for at least one line.', 'NOTHING_CHOSEN');
      const quotes = await tx.selectFrom('rfq_quotes').selectAll().where('rfq_id', '=', id).execute();
      const byVendor = new Map<string, typeof lines>();
      for (const l of lines) byVendor.set(l.chosen_party_id!, [...(byVendor.get(l.chosen_party_id!) ?? []), l]);
      for (const [partyId, ls] of byVendor) {
        const qs = ls.map((l) => quotes.find((q) => q.rfq_line_id === l.id && q.party_id === partyId)!);
        const lead = Math.max(0, ...qs.map((q) => q.lead_days ?? 0));
        const orderDate = todayIst();
        const po = await createPo(ctx, tx, {
          locationId: r.location_id, partyId, orderDate, expectedDate: lead > 0 ? addDays(orderDate, lead) : null,
          notes: `From ${r.number}`,
          lines: ls.map((l, i) => ({ itemId: l.item_id, qty: l.qty, rate: qs[i]!.rate, discountPct: qs[i]!.discount_pct, description: l.description ?? undefined })),
        });
        await tx.updateTable('rfq_lines').set({ purchase_order_id: po.id }).where('id', 'in', ls.map((l) => l.id)).execute();
      }
      await tx.updateTable('rfqs').set({ status: 'closed', closed_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'rfq', id, 'convert', { status: r.status }, { status: 'closed', orders: byVendor.size });
      return loadRfq(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/rfqs/:id/close', async (req) => {
    const ctx = req.ctx;
    ctx.require('purchase_orders.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const r = await lockRfq(tx, ctx, id);
      if (r.status === 'closed') throw conflict('This request is already closed.', 'INVALID_STATE');
      await tx.updateTable('rfqs').set({ status: 'closed', closed_at: new Date(), updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'rfq', id, 'close', { status: r.status }, { status: 'closed' });
      return loadRfq(tx, ctx, id);
    });
  });
}

documentRoute('POST', '/rfqs', { summary: 'Create a request for quotation', body: rfqBody });
documentRoute('PUT', '/rfqs/:id/quotes', { summary: 'Record one vendor\'s quotes', body: quotesBody });
