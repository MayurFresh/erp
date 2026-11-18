import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { computeGst } from '../lib/gst.ts';
import { fallbackRates } from '../lib/pricing.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { documentRoute } from '../lib/openapi.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { advanceDealForQuotation, markDealWon } from './crm-common.ts';
import { createInvoice } from './invoices.ts';
import { getLocation } from './locations.ts';
import { createOrder } from './sales-orders.ts';
import { convertUnits, enteredJson, enteredOf, saveEntered } from '../lib/uom.ts';

/** Quotations and proforma invoices (core sales). See docs/API.md "v1.14". */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

const lineBody = z.object({
  itemId: z.uuid(),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
  rate: moneyField.optional(),
  discountPct: percentField.optional(),
  /** Fixed discount in rupees before GST; use instead of discountPct, not with it. */
  discountAmount: moneyField.optional(),
  description: optionalText(300),
  /** Unit the quantity and rate are entered in (an alternate unit of the item); omitted means the base unit. */
  unit: z.string().trim().max(20).optional(),
}).refine((l) => !(l.discountAmount !== undefined && l.discountPct), {
  message: 'Give a line discount as a percent or an amount, not both.', path: ['discountAmount'],
});
const fields = {
  kind: z.enum(['quotation', 'proforma']).optional(),
  locationId: z.uuid(),
  partyId: z.uuid(),
  contactId: z.uuid().nullable().optional(),
  dealId: z.uuid().nullable().optional(),
  quoteDate: docDate.optional(),
  validUntil: dateField.nullable().optional(),
  placeOfSupply: z.string().trim().min(1).max(10).nullable().optional(),
  notes: optionalText(2000),
  terms: optionalText(4000),
  lines: z.array(lineBody).min(1, 'Add at least one line').max(200, 'At most 200 lines'),
};
const createBody = z.object(fields);
const patchBody = z.object(fields).partial().extend({ expectedUpdatedAt: z.string().max(40).optional() });
const declineBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const convertBody = z.object({
  to: z.enum(['sales_order', 'invoice']), locationId: z.uuid().optional(),
  /** Bill past the customer's credit limit; needs parties.credit_override. */
  allowOverLimit: z.boolean().optional(),
});
const listQuery = pagingQuery.extend({
  status: z.enum(['draft', 'sent', 'accepted', 'declined', 'converted', 'cancelled']).optional(),
  kind: z.enum(['quotation', 'proforma']).optional(),
  partyId: z.uuid().optional(),
  dealId: z.uuid().optional(),
  from: dateField.optional(),
  to: dateField.optional(),
});

type LineInput = z.infer<typeof lineBody>;

const locked = (q: { status: string }, action: string) =>
  conflict(`This quotation is ${q.status}, so it can't be ${action}.`, 'QUOTATION_LOCKED', { status: q.status });

/** Validates references and works out the figures with the invoice GST rules. Saves nothing. */
async function prepare(tx: Tx, ctx: RequestContext, body: {
  locationId: string; partyId: string; dealId?: string | null; contactId?: string | null; placeOfSupply?: string | null; lines: LineInput[];
}) {
  const location = await getLocation(tx, ctx, body.locationId);
  if (!location.is_active) throw badRequest('This location is inactive.', { locationId: 'Inactive' });
  const party = await tx.selectFrom('parties').selectAll()
    .where('id', '=', body.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!party) throw badRequest('Customer not found.', { partyId: 'Not found' });
  if (party.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });
  if (body.dealId) {
    const deal = await tx.selectFrom('crm_deals').select('id').where('id', '=', body.dealId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!deal) throw badRequest('Deal not found.', { dealId: 'Not found' });
  }
  if (body.contactId) {
    const c = await tx.selectFrom('party_contacts').select('id').where('id', '=', body.contactId)
      .where('company_id', '=', ctx.companyId).where('party_id', '=', body.partyId).executeTakeFirst();
    if (!c) throw badRequest('Contact not found for this customer.', { contactId: 'Not found' });
  }
  await convertUnits(tx, ctx, body.lines);
  const ids = [...new Set(body.lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').selectAll().where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const byId = new Map(items.map((i) => [i.id, i]));
  const priced = await fallbackRates(tx, ctx.companyId, body.partyId, body.lines, todayIst());
  const lines = body.lines.map((l, idx) => {
    const item = byId.get(l.itemId);
    if (!item) throw badRequest(`Line ${idx + 1}: item not found.`, { [`lines.${idx}.itemId`]: 'Not found' });
    if (!item.is_active) throw badRequest(`Line ${idx + 1}: ${item.name} is inactive.`, { [`lines.${idx}.itemId`]: 'Inactive' });
    const rate = l.rate ?? priced[idx] ?? item.sale_price;
    const description = l.description ?? item.name;
    if (l.discountAmount !== undefined) {
      const gross = Math.round(l.qty * rate * 100) / 100;
      if (l.discountAmount > gross) throw badRequest(`Line ${idx + 1}: the discount is more than the line.`, { [`lines.${idx}.discountAmount`]: 'Too large' });
      const pct = gross > 0 ? Math.round(l.discountAmount / gross * 10000) / 100 : 0;
      return { item, qty: l.qty, rate, discountPct: pct, discountAmount: l.discountAmount, description };
    }
    return { item, qty: l.qty, rate, discountPct: l.discountPct ?? 0, discountAmount: 0, description };
  });
  const placeOfSupply = body.placeOfSupply ?? party.state_code ?? location.state_code;
  const gst = computeGst(location.state_code, placeOfSupply, lines.map((l) => ({
    qty: l.qty, rate: l.rate, discountPct: l.discountPct, discountAmount: l.discountAmount > 0 ? l.discountAmount : undefined,
    gstRate: l.item.gst_rate,
  })));
  return { location, party, lines, placeOfSupply, gst, entered: enteredOf(body.lines) };
}
type Prepared = Awaited<ReturnType<typeof prepare>>;

async function insertLines(tx: Tx, ctx: RequestContext, quotationId: string, p: Prepared) {
  await tx.insertInto('quotation_lines').values(p.lines.map((l, i) => ({
    tenant_id: ctx.tenantId, quotation_id: quotationId, line_no: i + 1, item_id: l.item.id, description: l.description,
    qty: l.qty, rate: l.rate, discount_pct: l.discountPct, discount_amount: l.discountAmount, gst_rate: l.item.gst_rate,
  }))).execute();
  await saveEntered(tx, 'quotation_lines', 'quotation_id', quotationId, p.entered);
}

function quotationSelect(tx: Tx) {
  return tx.selectFrom('quotations as q')
    .innerJoin('locations as l', 'l.id', 'q.location_id')
    .innerJoin('parties as p', 'p.id', 'q.party_id')
    .innerJoin('users as u', 'u.id', 'q.created_by')
    .selectAll('q')
    .select(['l.name as location_name', 'l.state_code as location_state', 'p.name as party_name', 'u.name as created_by_name']);
}
type Row = Awaited<ReturnType<ReturnType<typeof quotationSelect>['executeTakeFirstOrThrow']>>;

function quotationJson(r: Row) {
  const expired = (r.status === 'draft' || r.status === 'sent') && r.valid_until !== null && r.valid_until < todayIst();
  return {
    id: r.id, kind: r.kind, number: r.number, fy: r.fy, status: r.status, expired,
    locationId: r.location_id, locationName: r.location_name, partyId: r.party_id, partyName: r.party_name,
    contactId: r.contact_id, dealId: r.deal_id, quoteDate: r.quote_date, validUntil: r.valid_until,
    placeOfSupply: r.place_of_supply, subtotal: r.subtotal, taxTotal: r.tax_total, total: r.total, notes: r.notes, terms: r.terms,
    revisionOf: r.revision_of, salesOrderId: r.sales_order_id, invoiceId: r.invoice_id, sentAt: r.sent_at,
    acceptedAt: r.accepted_at, declinedAt: r.declined_at, declineReason: r.decline_reason,
    createdBy: { id: r.created_by, name: r.created_by_name }, createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

/** Lines in the stored order with the figures worked out again from the stored inputs. */
async function loadLines(tx: Tx, row: Row) {
  const lines = await tx.selectFrom('quotation_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .selectAll('l').select(['i.name as item_name', 'i.unit', 'i.hsn_code']).where('l.quotation_id', '=', row.id).orderBy('l.line_no').execute();
  const gst = computeGst(row.location_state, row.place_of_supply ?? row.location_state, lines.map((l) => ({
    qty: l.qty, rate: l.rate, discountPct: l.discount_pct, discountAmount: l.discount_amount > 0 ? l.discount_amount : undefined, gstRate: l.gst_rate,
  })));
  return {
    lines: lines.map((l, i) => {
      const g = gst.lines[i]!;
      return {
        id: l.id, lineNo: l.line_no, itemId: l.item_id, itemName: l.item_name, unit: l.unit, hsn: l.hsn_code,
        description: l.description, qty: l.qty, rate: l.rate, discountPct: l.discount_pct, discountAmount: l.discount_amount,
        gstRate: l.gst_rate, ...enteredJson(l), taxable: g.taxableValue, tax: Math.round((g.cgst + g.sgst + g.igst) * 100) / 100, total: g.lineTotal,
      };
    }),
    taxSplit: { cgst: gst.cgst, sgst: gst.sgst, igst: gst.igst },
  };
}

async function loadQuotation(tx: Tx, ctx: RequestContext, id: string) {
  const row = await quotationSelect(tx).where('q.id', '=', id).where('q.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row || !ctx.canAccessLocation(row.location_id)) throw notFound('Quotation');
  return { ...quotationJson(row), ...(await loadLines(tx, row)) };
}

async function lockQuotation(tx: Tx, ctx: RequestContext, id: string) {
  const q = await tx.selectFrom('quotations').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!q || !ctx.canAccessLocation(q.location_id)) throw notFound('Quotation');
  return q;
}

const validFor = (quoteDate: string) => addDays(quoteDate, 15);

export async function quotationRoutes(app: FastifyInstance) {
  app.get('/quotations', async (req) => {
    const ctx = req.ctx;
    ctx.require('quotations.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = quotationSelect(tx).where('q.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('q.location_id', 'in', scope);
      if (q.status) base = base.where('q.status', '=', q.status);
      if (q.kind) base = base.where('q.kind', '=', q.kind);
      if (q.partyId) base = base.where('q.party_id', '=', q.partyId);
      if (q.dealId) base = base.where('q.deal_id', '=', q.dealId);
      if (q.from) base = base.where('q.quote_date', '>=', q.from);
      if (q.to) base = base.where('q.quote_date', '<=', q.to);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('q.number', 'ilike', t), eb('p.name', 'ilike', t)]));
      }
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('q.quote_date', 'desc').orderBy('q.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(quotationJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/quotations/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('quotations.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadQuotation(tx, ctx, id));
  });

  app.post('/quotations', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('quotations.manage');
    const body = parse(createBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const p = await prepare(tx, ctx, body);
      const kind = body.kind ?? 'quotation';
      const quoteDate = body.quoteDate ?? todayIst();
      const fy = financialYear(quoteDate);
      const number = await nextNumber(tx, ctx, kind, fy);
      const row = await tx.insertInto('quotations').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind, number, fy, location_id: p.location.id, party_id: p.party.id,
        contact_id: body.contactId ?? null, deal_id: body.dealId ?? null, quote_date: quoteDate,
        valid_until: body.validUntil === undefined ? validFor(quoteDate) : body.validUntil, place_of_supply: p.placeOfSupply,
        subtotal: p.gst.subtotal, tax_total: p.gst.taxTotal, total: p.gst.total, notes: body.notes ?? null, terms: body.terms ?? null,
        revision_of: null, sales_order_id: null, invoice_id: null, sent_at: null, accepted_at: null, declined_at: null,
        decline_reason: null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await insertLines(tx, ctx, row.id, p);
      if (body.dealId) await advanceDealForQuotation(tx, ctx, body.dealId);
      await writeAudit(tx, auditOf(ctx), 'quotation', row.id, 'create', null, { number, kind, total: p.gst.total });
      return loadQuotation(tx, ctx, row.id);
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/quotations/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('quotations.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const q = await lockQuotation(tx, ctx, id);
      assertFresh(q.updated_at, body.expectedUpdatedAt, 'quotation');
      if (q.status !== 'draft' && q.status !== 'sent') throw locked(q, 'edited');
      if (body.kind && body.kind !== q.kind) throw badRequest('The kind of a document cannot be changed. Make a new one instead.', { kind: 'Cannot change' });
      const old = await tx.selectFrom('quotation_lines').selectAll().where('quotation_id', '=', id).orderBy('line_no').execute();
      const lineInput: LineInput[] = body.lines ?? old.map((l) => (l.discount_amount > 0
        ? { itemId: l.item_id, qty: l.qty, rate: l.rate, discountAmount: l.discount_amount, description: l.description }
        : { itemId: l.item_id, qty: l.qty, rate: l.rate, discountPct: l.discount_pct, description: l.description }));
      const partyChanged = (body.partyId ?? q.party_id) !== q.party_id || (body.locationId ?? q.location_id) !== q.location_id;
      const dealId = body.dealId !== undefined ? body.dealId : q.deal_id;
      const p = await prepare(tx, ctx, {
        locationId: body.locationId ?? q.location_id, partyId: body.partyId ?? q.party_id, dealId, lines: lineInput,
        contactId: body.contactId !== undefined ? body.contactId : (partyChanged ? null : q.contact_id),
        placeOfSupply: body.placeOfSupply !== undefined ? body.placeOfSupply : (partyChanged ? null : q.place_of_supply),
      });
      const quoteDate = body.quoteDate ?? q.quote_date;
      const contactId = body.contactId !== undefined ? body.contactId : (partyChanged ? null : q.contact_id);
      // The number keeps its financial year; a date in another year only changes the date.
      await tx.updateTable('quotations').set({
        location_id: p.location.id, party_id: p.party.id, contact_id: contactId, deal_id: dealId, quote_date: quoteDate,
        valid_until: body.validUntil !== undefined ? body.validUntil : q.valid_until, place_of_supply: p.placeOfSupply,
        subtotal: p.gst.subtotal, tax_total: p.gst.taxTotal, total: p.gst.total,
        notes: body.notes !== undefined ? body.notes : q.notes, terms: body.terms !== undefined ? body.terms : q.terms,
        updated_at: new Date(),
      }).where('id', '=', id).execute();
      await tx.deleteFrom('quotation_lines').where('quotation_id', '=', id).execute();
      await insertLines(tx, ctx, id, p);
      if (dealId && dealId !== q.deal_id) await advanceDealForQuotation(tx, ctx, dealId);
      await writeAudit(tx, auditOf(ctx), 'quotation', id, 'update', { total: q.total }, { total: p.gst.total });
      return loadQuotation(tx, ctx, id);
    });
  });

  const transition = (path: string, from: string[], action: string, apply: (tx: Tx, ctx: RequestContext, id: string, body: unknown) => Record<string, unknown>,
    schema?: z.ZodType) => {
    app.post<{ Params: { id: string } }>(`/quotations/:id/${path}`, async (req) => {
      const ctx = req.ctx;
      ctx.require('quotations.manage');
      const id = parse(z.uuid(), req.params.id);
      const body = schema ? parse(schema, req.body) : undefined;
      return ctx.tx(async (tx) => {
        const q = await lockQuotation(tx, ctx, id);
        if (!from.includes(q.status)) throw locked(q, action);
        const set = apply(tx, ctx, id, body);
        await tx.updateTable('quotations').set({ ...set, updated_at: new Date() }).where('id', '=', id).execute();
        await writeAudit(tx, auditOf(ctx), 'quotation', id, path, { status: q.status }, { status: set.status, ...(body as object | undefined) });
        return loadQuotation(tx, ctx, id);
      });
    });
  };
  transition('send', ['draft', 'sent'], 'sent', () => ({ status: 'sent', sent_at: new Date() }));
  transition('accept', ['draft', 'sent'], 'accepted', () => ({ status: 'accepted', accepted_at: new Date() }));
  transition('decline', ['draft', 'sent', 'accepted'], 'declined', (_t, _c, _i, b) => ({
    status: 'declined', declined_at: new Date(), decline_reason: (b as z.infer<typeof declineBody>).reason,
  }), declineBody);
  transition('cancel', ['draft', 'sent', 'accepted'], 'cancelled', () => ({ status: 'cancelled' }));

  app.post<{ Params: { id: string } }>('/quotations/:id/revise', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('quotations.manage');
    const id = parse(z.uuid(), req.params.id);
    const out = await ctx.tx(async (tx) => {
      const q = await lockQuotation(tx, ctx, id);
      if (!['draft', 'sent', 'accepted', 'declined'].includes(q.status)) throw locked(q, 'revised');
      const old = await tx.selectFrom('quotation_lines').selectAll().where('quotation_id', '=', id).orderBy('line_no').execute();
      const p = await prepare(tx, ctx, {
        locationId: q.location_id, partyId: q.party_id, dealId: q.deal_id, contactId: q.contact_id, placeOfSupply: q.place_of_supply,
        lines: old.map((l) => (l.discount_amount > 0
          ? { itemId: l.item_id, qty: l.qty, rate: l.rate, discountAmount: l.discount_amount, description: l.description }
          : { itemId: l.item_id, qty: l.qty, rate: l.rate, discountPct: l.discount_pct, description: l.description })),
      });
      const quoteDate = todayIst();
      const fy = financialYear(quoteDate);
      const number = await nextNumber(tx, ctx, q.kind as 'quotation' | 'proforma', fy);
      const row = await tx.insertInto('quotations').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: q.kind, number, fy, location_id: q.location_id, party_id: q.party_id,
        contact_id: q.contact_id, deal_id: q.deal_id, quote_date: quoteDate, valid_until: validFor(quoteDate),
        place_of_supply: p.placeOfSupply, subtotal: p.gst.subtotal, tax_total: p.gst.taxTotal, total: p.gst.total,
        notes: q.notes, terms: q.terms, revision_of: q.id, sales_order_id: null, invoice_id: null, sent_at: null,
        accepted_at: null, declined_at: null, decline_reason: null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await insertLines(tx, ctx, row.id, p);
      await tx.updateTable('quotations').set({ status: 'cancelled', updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'quotation', id, 'revise', { status: q.status }, { status: 'cancelled', newNumber: number });
      await writeAudit(tx, auditOf(ctx), 'quotation', row.id, 'create', null, { number, revisionOf: q.number, total: p.gst.total });
      return loadQuotation(tx, ctx, row.id);
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/quotations/:id/convert', async (req) => {
    const ctx = req.ctx;
    ctx.require('quotations.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(convertBody, req.body);
    ctx.require(body.to === 'sales_order' ? 'sales_orders.manage' : 'invoices.create');
    return ctx.tx(async (tx) => {
      const q = await lockQuotation(tx, ctx, id);
      if (!['draft', 'sent', 'accepted'].includes(q.status)) throw locked(q, 'converted');
      const lines = await tx.selectFrom('quotation_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
        .selectAll('l').select(['i.name as item_name', 'i.track_stock']).where('l.quotation_id', '=', id).orderBy('l.line_no').execute();
      const locationId = body.locationId ?? q.location_id;
      let salesOrderId: string | null = null;
      let invoiceId: string | null = null;
      // Quantity and rate stay in the base unit; the unit the customer was quoted in is copied across afterwards.
      const entered = lines.map((l) => (l.entered_unit && Number(l.entered_qty) > 0 ? { unit: l.entered_unit, qty: Number(l.entered_qty) } : null));
      if (body.to === 'sales_order') {
        const services = lines.filter((l) => !l.track_stock);
        if (services.length) {
          throw conflict(`A sales order takes only stock items. Remove ${services.map((l) => l.item_name).join(', ')} or convert to an invoice.`,
            'NOT_STOCK_ITEMS', { items: services.map((l) => ({ lineNo: l.line_no, itemId: l.item_id, itemName: l.item_name })) });
        }
        salesOrderId = await createOrder(tx, ctx, {
          locationId, partyId: q.party_id, notes: q.notes ?? undefined, placeOfSupply: q.place_of_supply,
          createdNote: `Created from quotation ${q.number}`,
          lines: lines.map((l) => ({ itemId: l.item_id, qty: l.qty, rate: l.rate, discountPct: l.discount_pct, description: l.description })),
        }, { creditCheck: { allowOver: body.allowOverLimit } });
        await saveEntered(tx, 'sales_order_lines', 'order_id', salesOrderId, entered);
      } else {
        // Invoices always take the customer's state (else the location's) as place of supply, so a quotation made
        // for another place would change its tax on the way. Refuse instead of changing the figures silently.
        const party = await tx.selectFrom('parties').select('state_code').where('id', '=', q.party_id).executeTakeFirstOrThrow();
        const loc = await tx.selectFrom('locations').select('state_code').where('id', '=', locationId)
          .where('company_id', '=', ctx.companyId).executeTakeFirst();
        const invoicePlace = party.state_code ?? loc?.state_code ?? null;
        if (q.place_of_supply && invoicePlace && q.place_of_supply !== invoicePlace) {
          throw conflict(`This quotation's place of supply (${q.place_of_supply}) differs from the customer's state (${invoicePlace}), `
            + 'so the invoice tax would change. Revise the quotation or correct the customer\'s state first.',
          'PLACE_OF_SUPPLY_DIFFERS', { quotation: q.place_of_supply, invoice: invoicePlace });
        }
        const inv = await createInvoice(ctx, tx, {
          locationId, partyId: q.party_id, notes: q.notes ? `${q.notes}\n(From ${q.number})`.slice(0, 1000) : `From ${q.number}`,
          lines: lines.map((l) => ({
            itemId: l.item_id, qty: l.qty, rate: l.rate, description: l.description,
            ...(l.discount_amount > 0 ? { discountAmount: l.discount_amount } : { discountPct: l.discount_pct }),
          })),
        } as Parameters<typeof createInvoice>[2], { creditCheck: { allowOver: body.allowOverLimit } });
        invoiceId = inv.id;
        await saveEntered(tx, 'invoice_lines', 'invoice_id', inv.id, entered);
      }
      await tx.updateTable('quotations').set({
        status: 'converted', sales_order_id: salesOrderId, invoice_id: invoiceId, updated_at: new Date(),
      }).where('id', '=', id).execute();
      if (q.deal_id) await markDealWon(tx, ctx, q.deal_id, q.total);
      await writeAudit(tx, auditOf(ctx), 'quotation', id, 'convert', { status: q.status }, { status: 'converted', salesOrderId, invoiceId });
      return { quotation: await loadQuotation(tx, ctx, id), salesOrderId, invoiceId };
    });
  });
}

documentRoute('POST', '/quotations', { summary: 'Create a quotation or proforma invoice', body: createBody });
documentRoute('PATCH', '/quotations/:id', { summary: 'Edit a draft or sent quotation', body: patchBody });
documentRoute('POST', '/quotations/:id/decline', { summary: 'Decline a quotation', body: declineBody });
documentRoute('POST', '/quotations/:id/convert', { summary: 'Convert a quotation to a sales order or an invoice', body: convertBody });
documentRoute('GET', '/quotations', { summary: 'List quotations', query: listQuery });
