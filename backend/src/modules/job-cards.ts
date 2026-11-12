import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { locationQty } from '../accounting/costing.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { requireFiles } from './files.ts';
import { createInvoice } from './invoices.ts';
import { createPayment } from './payments.ts';
import { defaultLocation, round2, round3 } from './services-common.ts';
import { reservedQty } from './stock.ts';
import { documentRoute } from '../lib/openapi.ts';

/*
 * Repair job cards. Status runs received, estimate sent, approved, in progress, ready, delivered (or cancelled).
 * Issuing a part checks and holds the stock for the job; the stock itself moves once, when the job bill is made
 * through createInvoice, so cost, tax and the ledger come from the one invoice code path.
 */

const STATUSES = ['received', 'estimate_sent', 'approved', 'in_progress', 'ready', 'delivered', 'cancelled'] as const;
type Status = (typeof STATUSES)[number];
const NEXT: Record<Status, Status[]> = {
  received: ['estimate_sent', 'cancelled'],
  estimate_sent: ['approved', 'cancelled'],
  approved: ['in_progress', 'estimate_sent', 'cancelled'],
  in_progress: ['ready', 'cancelled'],
  ready: ['delivered', 'in_progress'],
  delivered: [],
  cancelled: [],
};
const LABEL: Record<Status, string> = {
  received: 'received', estimate_sent: 'waiting for your approval of the estimate', approved: 'approved and queued',
  in_progress: 'being worked on', ready: 'ready for collection', delivered: 'delivered', cancelled: 'cancelled',
};
const EDITABLE: Status[] = ['received', 'estimate_sent', 'approved', 'in_progress'];

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const blank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? undefined : v);
const phoneField = z.string().trim().min(5, 'Enter a phone number').max(20).regex(/^[0-9+() -]+$/, 'Digits only');
const payBody = z.object({
  accountId: z.uuid(), mode: z.enum(['cash', 'bank', 'upi', 'cheque', 'card']),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), reference: optionalText(60),
});
const lineBody = z.object({
  kind: z.enum(['part', 'labour']), itemId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
  rate: moneyField.optional(), discountPct: percentField.optional(), description: optionalText(300),
});
const linePatch = z.object({
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero').optional(), rate: moneyField.optional(),
  discountPct: percentField.optional(), description: nullableText(300),
});
const assetFields = {
  kind: z.enum(['vehicle', 'device']),
  vehicleNo: z.preprocess(blank, z.string().trim().toUpperCase().max(20).optional()),
  make: optionalText(60), model: optionalText(60),
  odometer: z.preprocess(blank, z.coerce.number().int().min(0).max(5_000_000).optional()),
  serialNo: optionalText(60),
};
const createBody = z.object({
  ...assetFields,
  partyId: z.uuid().optional(),
  customer: z.object({ name: z.string().trim().min(1).max(200), phone: phoneField }).optional(),
  complaints: z.string().trim().min(1, 'Describe the problem').max(2000),
  accessories: optionalText(500),
  photoFileIds: z.array(z.uuid()).max(8).default([]),
  promisedDate: z.preprocess(blank, dateField.optional()),
  technicianId: z.uuid().optional(),
  locationId: z.uuid().optional(),
}).refine((b) => b.partyId || b.customer, { message: 'Choose or add the customer', path: ['partyId'] });
const patchBody = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  vehicleNo: z.preprocess((v) => (v === '' ? null : v), z.string().trim().toUpperCase().max(20).nullable().optional()),
  make: nullableText(60), model: nullableText(60),
  odometer: z.preprocess((v) => (v === '' ? null : v), z.coerce.number().int().min(0).max(5_000_000).nullable().optional()),
  serialNo: nullableText(60),
  complaints: z.string().trim().min(1).max(2000).optional(), accessories: nullableText(500),
  photoFileIds: z.array(z.uuid()).max(8).optional(),
  promisedDate: z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional()),
  technicianId: z.uuid().nullable().optional(),
});
const statusBody = z.object({ status: z.enum(STATUSES), approvedBy: optionalText(100), reason: optionalText(300) });
const issueBody = z.object({ lineIds: z.array(z.uuid()).max(100).optional() });
const billBody = z.object({ payment: payBody.optional() });
const listQuery = pagingQuery.extend({
  status: z.enum(STATUSES).optional(), technicianId: z.uuid().optional(), mine: z.enum(['true', 'false']).optional(),
  open: z.enum(['true', 'false']).optional(),
});

// Access ----------------------------------------------------------------------------------------

const seesAll = (ctx: RequestContext) => ctx.can('job_cards.view') || ctx.can('job_cards.create') || ctx.can('job_cards.manage');
const writesAll = (ctx: RequestContext) => ctx.can('job_cards.create') || ctx.can('job_cards.manage');

function needAny(ctx: RequestContext) { ctx.require('job_cards.view', 'job_cards.create', 'job_cards.work', 'job_cards.manage'); }

/** Work-only staff touch the jobs assigned to them; reception and managers touch any. */
function canWork(ctx: RequestContext, job: { technician_id: string | null }) {
  return writesAll(ctx) || (ctx.can('job_cards.work') && job.technician_id === ctx.userId);
}
function needWork(ctx: RequestContext, job: { technician_id: string | null }) {
  if (!canWork(ctx, job)) throw forbidden(ctx.can('job_cards.work') ? 'This job is assigned to someone else.' : undefined);
}

// Loading ---------------------------------------------------------------------------------------

async function loadJob(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('job_cards').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Job card');
  if (!seesAll(ctx) && row.technician_id !== ctx.userId) {
    if (!ctx.can('job_cards.work')) throw forbidden();
    throw notFound('Job card');
  }
  return row;
}
type JobRow = Awaited<ReturnType<typeof loadJob>>;

const assetLabel = (j: Pick<JobRow, 'kind' | 'vehicle_no' | 'make' | 'model' | 'serial_no'>) =>
  [j.kind === 'vehicle' ? j.vehicle_no : null, [j.make, j.model].filter(Boolean).join(' ') || null, j.kind === 'device' && j.serial_no ? `S/N ${j.serial_no}` : null]
    .filter(Boolean).join(' - ') || (j.kind === 'vehicle' ? 'Vehicle' : 'Device');

async function loadLines(tx: Tx, jobId: string) {
  const rows = await tx.selectFrom('job_card_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
    .select(['l.id', 'l.line_no', 'l.kind', 'l.item_id', 'l.description', 'l.qty', 'l.rate', 'l.discount_pct', 'l.issued_at', 'i.name as item_name',
      'i.unit', 'i.gst_rate', 'i.track_stock'])
    .where('l.job_card_id', '=', jobId).orderBy('l.line_no').execute();
  return rows.map((l) => {
    const net = round2(l.qty * l.rate * (1 - l.discount_pct / 100));
    return {
      id: l.id, lineNo: l.line_no, kind: l.kind, itemId: l.item_id, itemName: l.item_name, unit: l.unit, description: l.description,
      qty: l.qty, rate: l.rate, discountPct: l.discount_pct, gstRate: l.gst_rate, amount: net, tracked: l.track_stock,
      issued: !!l.issued_at, issuedAt: l.issued_at,
    };
  });
}

function totalsOf(lines: Awaited<ReturnType<typeof loadLines>>) {
  const parts = round2(lines.filter((l) => l.kind === 'part').reduce((s, l) => s + l.amount, 0));
  const labour = round2(lines.filter((l) => l.kind === 'labour').reduce((s, l) => s + l.amount, 0));
  const tax = round2(lines.reduce((s, l) => s + l.amount * l.gstRate / 100, 0));
  const exact = parts + labour + tax;
  return { parts, labour, subtotal: round2(parts + labour), tax, total: Math.round(exact), roundOff: round2(Math.round(exact) - exact) };
}

function briefSelect(tx: Tx, ctx: RequestContext) {
  return tx.selectFrom('job_cards as j').innerJoin('parties as p', 'p.id', 'j.party_id').leftJoin('users as u', 'u.id', 'j.technician_id')
    .leftJoin('invoices as inv', 'inv.id', 'j.invoice_id')
    .select(['j.id', 'j.number', 'j.kind', 'j.vehicle_no', 'j.make', 'j.model', 'j.serial_no', 'j.status', 'j.promised_date', 'j.technician_id',
      'j.created_at', 'j.updated_at', 'j.invoice_id', 'p.name as party_name', 'p.phone as party_phone', 'u.name as tech_name',
      'inv.number as invoice_number', 'inv.total as invoice_total', 'inv.amount_paid as invoice_paid',
      sql<number>`coalesce((select sum(l.qty * l.rate * (1 - l.discount_pct / 100)) from job_card_lines l where l.job_card_id = j.id), 0)`.as('subtotal')])
    .where('j.company_id', '=', ctx.companyId);
}
type BriefRow = Awaited<ReturnType<ReturnType<typeof briefSelect>['execute']>>[number];
const briefJson = (r: BriefRow) => ({
  id: r.id, number: r.number, kind: r.kind, asset: assetLabel(r), status: r.status, customer: { name: r.party_name, phone: r.party_phone },
  technician: r.technician_id ? { id: r.technician_id, name: r.tech_name } : null, promisedDate: r.promised_date,
  overdue: !!r.promised_date && r.promised_date < todayIst() && !['ready', 'delivered', 'cancelled'].includes(r.status),
  subtotal: round2(Number(r.subtotal)), billed: !!r.invoice_id, invoiceNumber: r.invoice_number, createdAt: r.created_at, updatedAt: r.updated_at,
});

function statusMessage(j: JobRow, company: string, customer: string, total: number, balance: number | null) {
  const head = `Hello ${customer}, your ${assetLabel(j)} (job ${j.number}) at ${company} is ${LABEL[j.status as Status]}.`;
  const bits: string[] = [];
  if (j.status === 'estimate_sent' && total > 0) bits.push(`Estimate: Rs ${total.toFixed(2)}.`);
  if (j.status === 'ready' || j.status === 'delivered') if (balance !== null && balance > 0.004) bits.push(`Balance to pay: Rs ${balance.toFixed(2)}.`);
  if (j.promised_date && ['received', 'estimate_sent', 'approved', 'in_progress'].includes(j.status)) bits.push(`Expected by ${j.promised_date}.`);
  return [head, ...bits].join(' ');
}

async function detailJson(tx: Tx, ctx: RequestContext, j: JobRow) {
  const party = await tx.selectFrom('parties').select(['id', 'name', 'phone']).where('id', '=', j.party_id).executeTakeFirstOrThrow();
  const tech = j.technician_id ? await tx.selectFrom('users').select(['id', 'name']).where('id', '=', j.technician_id).executeTakeFirst() : undefined;
  const company = await tx.selectFrom('companies').select('name').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const lines = await loadLines(tx, j.id);
  const totals = totalsOf(lines);
  const inv = j.invoice_id
    ? await tx.selectFrom('invoices').select(['id', 'number', 'total', 'amount_paid', 'status']).where('id', '=', j.invoice_id).executeTakeFirst()
    : undefined;
  const photos = j.photo_file_ids.length
    ? await tx.selectFrom('files').select(['id', 'name']).where('id', 'in', j.photo_file_ids).execute() : [];
  const balance = inv ? round2(inv.total - inv.amount_paid) : null;
  return {
    id: j.id, number: j.number, kind: j.kind, asset: assetLabel(j), vehicleNo: j.vehicle_no, make: j.make, model: j.model,
    odometer: j.odometer, serialNo: j.serial_no, complaints: j.complaints, accessories: j.accessories, promisedDate: j.promised_date,
    status: j.status, nextStatuses: NEXT[j.status as Status], customer: { id: party.id, name: party.name, phone: party.phone },
    technician: tech ? { id: tech.id, name: tech.name } : null, locationId: j.location_id,
    estimateSentAt: j.estimate_sent_at, approvedAt: j.approved_at, approvedBy: j.approved_by, startedAt: j.started_at, readyAt: j.ready_at,
    deliveredAt: j.delivered_at, cancelReason: j.cancel_reason, photos: photos.map((f) => ({ id: f.id, name: f.name, url: `/api/v1/files/${f.id}` })),
    lines, totals, canEditLines: EDITABLE.includes(j.status as Status),
    invoice: inv ? { id: inv.id, number: inv.number, total: inv.total, amountPaid: inv.amount_paid, balance, status: inv.status } : null,
    statusMessage: statusMessage(j, company.name, party.name, totals.total, balance),
    createdAt: j.created_at, updatedAt: j.updated_at,
  };
}

async function checkItem(tx: Tx, ctx: RequestContext, itemId: string, kind: 'part' | 'labour') {
  const item = await tx.selectFrom('items').select(['id', 'name', 'sale_price', 'track_stock', 'is_active', 'unit'])
    .where('id', '=', itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!item) throw badRequest('Item not found.', { itemId: 'Not found' });
  if (!item.is_active) throw badRequest('This item is inactive.', { itemId: 'Inactive' });
  if (kind === 'labour' && item.track_stock) throw badRequest('Labour must be a service item, not a stocked part.', { itemId: 'Stocked item' });
  return item;
}

/** Putting the estimate back to "sent" when a line changes after approval, so the customer approves the new figure. */
async function reopenApproval(tx: Tx, j: JobRow) {
  if (j.status === 'approved') {
    await tx.updateTable('job_cards').set({ status: 'estimate_sent', approved_at: null, approved_by: null }).where('id', '=', j.id).execute();
  }
}

// Routes ----------------------------------------------------------------------------------------

export async function jobCardRoutes(app: FastifyInstance) {
  app.get('/job-cards', async (req) => {
    const ctx = req.ctx;
    needAny(ctx);
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = briefSelect(tx, ctx);
      if (!seesAll(ctx) || q.mine === 'true') base = base.where('j.technician_id', '=', ctx.userId);
      if (q.technicianId) base = base.where('j.technician_id', '=', q.technicianId);
      if (q.status) base = base.where('j.status', '=', q.status);
      if (q.open === 'true') base = base.where('j.status', 'not in', ['delivered', 'cancelled']);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('j.number', 'ilike', t), eb('j.vehicle_no', 'ilike', t), eb('j.serial_no', 'ilike', t),
          eb('p.name', 'ilike', t), eb('p.phone', 'ilike', t)]));
      }
      const rows = await base.orderBy('j.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      const counts = await tx.selectFrom('job_cards').select(['status', sql<number>`count(*)`.as('n')]).where('company_id', '=', ctx.companyId)
        .$if(!seesAll(ctx) || q.mine === 'true', (b) => b.where('technician_id', '=', ctx.userId)).groupBy('status').execute();
      return { data: rows.map(briefJson), counts: Object.fromEntries(counts.map((c) => [c.status, Number(c.n)])) };
    });
  });

  app.post('/job-cards', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('job_cards.create', 'job_cards.manage');
    const b = parse(createBody, req.body);
    if (b.kind === 'vehicle' && !b.vehicleNo) throw badRequest('Enter the vehicle number.', { vehicleNo: 'Required' });
    const out = await ctx.tx(async (tx) => {
      let partyId = b.partyId;
      if (partyId) {
        const p = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!p || p.type === 'vendor') throw badRequest('Choose a customer.', { partyId: 'Not a customer' });
      } else {
        const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
        const party = await tx.insertInto('parties').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: b.customer!.name, phone: b.customer!.phone,
          address: null, state_code: company.state_code, gstin: null, email: null, pan: null, pincode: null, udyam_no: null,
          msme_category: null, tds_section_id: null,
        }).returning('id').executeTakeFirstOrThrow();
        partyId = party.id;
      }
      if (b.technicianId) {
        const u = await tx.selectFrom('users').select('id').where('id', '=', b.technicianId).executeTakeFirst();
        if (!u) throw badRequest('Technician not found.', { technicianId: 'Not found' });
      }
      if (b.photoFileIds.length) await requireFiles(tx, b.photoFileIds.map((id) => ({ id, field: 'photoFileIds' })), true);
      const number = await nextNumber(tx, ctx, 'job_card', financialYear(todayIst()));
      const row = await tx.insertInto('job_cards').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: await defaultLocation(tx, ctx, b.locationId), party_id: partyId, number,
        kind: b.kind, vehicle_no: b.vehicleNo ?? null, make: b.make ?? null, model: b.model ?? null, odometer: b.odometer ?? null,
        serial_no: b.serialNo ?? null, complaints: b.complaints, accessories: b.accessories ?? null, photo_file_ids: b.photoFileIds,
        promised_date: b.promisedDate ?? null, technician_id: b.technicianId ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'job_card', row.id, 'create', null, { number });
      return detailJson(tx, ctx, await loadJob(tx, ctx, row.id));
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/job-cards/:id', async (req) => {
    const ctx = req.ctx;
    needAny(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => detailJson(tx, ctx, await loadJob(tx, ctx, id)));
  });

  app.patch<{ Params: { id: string } }>('/job-cards/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('job_cards.create', 'job_cards.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadJob(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'job card');
      if (['delivered', 'cancelled'].includes(before.status)) throw conflict('This job is closed.', 'BAD_STATE');
      if (b.technicianId !== undefined && b.technicianId !== before.technician_id) {
        ctx.require('job_cards.manage', 'job_cards.create');
        if (b.technicianId) {
          const u = await tx.selectFrom('users').select('id').where('id', '=', b.technicianId).executeTakeFirst();
          if (!u) throw badRequest('Technician not found.', { technicianId: 'Not found' });
        }
      }
      if (b.photoFileIds?.length) await requireFiles(tx, b.photoFileIds.map((x) => ({ id: x, field: 'photoFileIds' })), true);
      const changes = definedOnly({
        vehicle_no: b.vehicleNo, make: b.make, model: b.model, odometer: b.odometer, serial_no: b.serialNo, complaints: b.complaints,
        accessories: b.accessories, photo_file_ids: b.photoFileIds, promised_date: b.promisedDate, technician_id: b.technicianId,
      });
      if (Object.keys(changes).length) await tx.updateTable('job_cards').set(changes as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'job_card', id, 'update', null, { fields: Object.keys(changes) });
      return detailJson(tx, ctx, await loadJob(tx, ctx, id));
    });
  });

  // Estimate lines ----------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/job-cards/:id/lines', async (req, reply) => {
    const ctx = req.ctx;
    needAny(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(lineBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const j = await loadJob(tx, ctx, id, true);
      needWork(ctx, j);
      if (!EDITABLE.includes(j.status as Status)) throw conflict('Lines cannot be changed at this stage.', 'BAD_STATE');
      const item = await checkItem(tx, ctx, b.itemId, b.kind);
      const max = await tx.selectFrom('job_card_lines').select(sql<number>`coalesce(max(line_no), 0)`.as('m')).where('job_card_id', '=', id).executeTakeFirstOrThrow();
      await tx.insertInto('job_card_lines').values({
        tenant_id: ctx.tenantId, job_card_id: id, line_no: Number(max.m) + 1, kind: b.kind, item_id: item.id, description: b.description ?? null,
        qty: b.qty, rate: b.rate ?? item.sale_price, discount_pct: b.discountPct ?? 0,
      }).execute();
      await reopenApproval(tx, j);
      await tx.updateTable('job_cards').set({ updated_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'job_card', id, 'add_line', null, { kind: b.kind, itemId: b.itemId });
      return detailJson(tx, ctx, await loadJob(tx, ctx, id));
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string; lineId: string } }>('/job-cards/:id/lines/:lineId', async (req) => {
    const ctx = req.ctx;
    needAny(ctx);
    const id = parse(z.uuid(), req.params.id);
    const lineId = parse(z.uuid(), req.params.lineId);
    const b = parse(linePatch, req.body);
    return ctx.tx(async (tx) => {
      const j = await loadJob(tx, ctx, id, true);
      needWork(ctx, j);
      if (!EDITABLE.includes(j.status as Status)) throw conflict('Lines cannot be changed at this stage.', 'BAD_STATE');
      const line = await tx.selectFrom('job_card_lines').selectAll().where('id', '=', lineId).where('job_card_id', '=', id).forUpdate().executeTakeFirst();
      if (!line) throw notFound('Line');
      if (line.issued_at) throw conflict('This part is already issued and cannot be changed.', 'ALREADY_ISSUED');
      const changes = definedOnly({ qty: b.qty, rate: b.rate, discount_pct: b.discountPct, description: b.description });
      if (Object.keys(changes).length) {
        await tx.updateTable('job_card_lines').set(changes as never).where('id', '=', lineId).execute();
        await reopenApproval(tx, j);
        await tx.updateTable('job_cards').set({ updated_at: new Date() }).where('id', '=', id).execute();
      }
      return detailJson(tx, ctx, await loadJob(tx, ctx, id));
    });
  });

  app.delete<{ Params: { id: string; lineId: string } }>('/job-cards/:id/lines/:lineId', async (req) => {
    const ctx = req.ctx;
    needAny(ctx);
    const id = parse(z.uuid(), req.params.id);
    const lineId = parse(z.uuid(), req.params.lineId);
    return ctx.tx(async (tx) => {
      const j = await loadJob(tx, ctx, id, true);
      needWork(ctx, j);
      if (!EDITABLE.includes(j.status as Status)) throw conflict('Lines cannot be changed at this stage.', 'BAD_STATE');
      const line = await tx.selectFrom('job_card_lines').select(['id', 'issued_at']).where('id', '=', lineId).where('job_card_id', '=', id).forUpdate().executeTakeFirst();
      if (!line) throw notFound('Line');
      if (line.issued_at) throw conflict('This part is already issued and cannot be removed.', 'ALREADY_ISSUED');
      await tx.deleteFrom('job_card_lines').where('id', '=', lineId).execute();
      await reopenApproval(tx, j);
      await tx.updateTable('job_cards').set({ updated_at: new Date() }).where('id', '=', id).execute();
      return detailJson(tx, ctx, await loadJob(tx, ctx, id));
    });
  });

  // Status ------------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/job-cards/:id/status', async (req) => {
    const ctx = req.ctx;
    needAny(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(statusBody, req.body);
    return ctx.tx(async (tx) => {
      const j = await loadJob(tx, ctx, id, true);
      const from = j.status as Status;
      if (!NEXT[from].includes(b.status)) {
        throw conflict(`A job that is ${from.replace('_', ' ')} cannot move to ${b.status.replace('_', ' ')}.`, 'BAD_TRANSITION', { from, to: b.status, allowed: NEXT[from] });
      }
      const now = new Date();
      const set: Record<string, unknown> = { status: b.status };
      if (b.status === 'in_progress' || b.status === 'ready') {
        needWork(ctx, j);
      } else {
        ctx.require('job_cards.create', 'job_cards.manage');
      }
      if (b.status === 'cancelled' && b.status !== from) {
        if (j.invoice_id) throw conflict('This job is billed. Cancel the bill first.', 'BILLED');
        if (!b.reason) throw badRequest('Give a reason for cancelling.', { reason: 'Required' });
        set.cancel_reason = b.reason;
      }
      if (b.status === 'estimate_sent') {
        const lines = await tx.selectFrom('job_card_lines').select('id').where('job_card_id', '=', id).limit(1).executeTakeFirst();
        if (!lines) throw badRequest('Add parts or labour to the estimate first.', { lines: 'Required' });
        set.estimate_sent_at = now;
      }
      if (b.status === 'approved') { set.approved_at = now; set.approved_by = b.approvedBy ?? null; }
      if (b.status === 'in_progress') {
        if (from === 'approved') set.started_at = now;
        if (!j.technician_id && ctx.can('job_cards.work')) set.technician_id = ctx.userId;
      }
      if (b.status === 'ready') set.ready_at = now;
      if (b.status === 'delivered') {
        if (!j.invoice_id) throw conflict('Bill the job before delivering it.', 'NOT_BILLED');
        set.delivered_at = now;
      }
      await tx.updateTable('job_cards').set(set as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'job_card', id, 'status', { status: from }, { status: b.status });
      return detailJson(tx, ctx, await loadJob(tx, ctx, id));
    });
  });

  // Parts issue -------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/job-cards/:id/issue', async (req) => {
    const ctx = req.ctx;
    needAny(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(issueBody, req.body ?? {});
    return ctx.tx(async (tx) => {
      const j = await loadJob(tx, ctx, id, true);
      needWork(ctx, j);
      if (j.status !== 'in_progress') throw conflict('Parts are issued while the job is in progress.', 'BAD_STATE');
      let q = tx.selectFrom('job_card_lines as l').innerJoin('items as i', 'i.id', 'l.item_id')
        .select(['l.id', 'l.qty', 'l.item_id', 'l.issued_at', 'i.name', 'i.unit', 'i.track_stock'])
        .where('l.job_card_id', '=', id).where('l.kind', '=', 'part').forUpdate('l');
      if (b.lineIds?.length) q = q.where('l.id', 'in', b.lineIds);
      const lines = await q.execute();
      if (b.lineIds?.length && lines.length !== new Set(b.lineIds).size) throw notFound('Line');
      const todo = lines.filter((l) => !l.issued_at);
      const loc = await tx.selectFrom('locations').select(['id', 'name']).where('id', '=', j.location_id).executeTakeFirstOrThrow();
      for (const l of todo.filter((x) => x.track_stock)) {
        const onHand = await locationQty(tx, ctx.companyId, loc.id, l.item_id);
        const reserved = await reservedQty(tx, ctx.companyId, loc.id, l.item_id);
        const held = await tx.selectFrom('job_card_lines as x').innerJoin('job_cards as c', 'c.id', 'x.job_card_id')
          .select(sql<number>`coalesce(sum(x.qty), 0)`.as('q')).where('c.company_id', '=', ctx.companyId).where('c.location_id', '=', loc.id)
          .where('x.item_id', '=', l.item_id).where('x.issued_at', 'is not', null).where('c.invoice_id', 'is', null)
          .where('c.status', 'not in', ['cancelled', 'delivered']).executeTakeFirstOrThrow();
        const available = round3(onHand - reserved - Number(held.q));
        if (available + 0.0005 < l.qty) {
          throw conflict(`Only ${available} ${l.unit} of ${l.name} available at ${loc.name}.`, 'INSUFFICIENT_STOCK', { itemId: l.item_id, available, required: l.qty });
        }
      }
      if (todo.length) {
        await tx.updateTable('job_card_lines').set({ issued_at: new Date(), issued_by: ctx.userId }).where('id', 'in', todo.map((l) => l.id)).execute();
        await writeAudit(tx, auditOf(ctx), 'job_card', id, 'issue_parts', null, { lines: todo.length });
      }
      const out = await detailJson(tx, ctx, await loadJob(tx, ctx, id));
      return { ...out, issuedNow: todo.length, alreadyIssued: lines.length - todo.length };
    });
  });

  // Bill and receipt --------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/job-cards/:id/bill', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('job_cards.create', 'job_cards.manage');
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(billBody, req.body ?? {});
    if (b.payment) ctx.require('payments.create');
    const out = await ctx.tx(async (tx) => {
      const j = await loadJob(tx, ctx, id, true);
      if (j.invoice_id) {
        const inv = await tx.selectFrom('invoices').select('status').where('id', '=', j.invoice_id).executeTakeFirst();
        if (inv && inv.status !== 'cancelled') throw conflict('This job is already billed.', 'ALREADY_BILLED');
      }
      if (j.status !== 'ready') throw conflict('Bill the job when it is ready.', 'BAD_STATE');
      const lines = await tx.selectFrom('job_card_lines').selectAll().where('job_card_id', '=', id).orderBy('line_no').forUpdate().execute();
      if (!lines.length) throw badRequest('There is nothing to bill.', { lines: 'Required' });
      const ordered = [...lines.filter((l) => l.kind === 'part'), ...lines.filter((l) => l.kind === 'labour')];
      const invoice = await createInvoice(ctx, tx, {
        locationId: j.location_id, partyId: j.party_id, lines: ordered.map((l) => ({
          itemId: l.item_id, qty: l.qty, rate: l.rate, discountPct: l.discount_pct, description: l.description ?? undefined,
        })),
        notes: `Job ${j.number}, ${assetLabel(j)}`, custom: undefined,
      } as never);
      await tx.updateTable('job_card_lines').set({ issued_at: new Date(), issued_by: ctx.userId })
        .where('job_card_id', '=', id).where('kind', '=', 'part').where('issued_at', 'is', null).execute();
      await tx.updateTable('job_cards').set({ invoice_id: invoice.id }).where('id', '=', id).execute();
      let payment = null;
      if (b.payment) {
        const amt = Math.min(b.payment.amount, invoice.total);
        payment = await createPayment(ctx, tx, {
          kind: 'receipt', partyId: j.party_id, date: undefined, accountId: b.payment.accountId, mode: b.payment.mode,
          reference: b.payment.reference, amount: amt, tdsAmount: undefined, notes: `Job ${j.number}`,
          allocations: [{ docId: invoice.id, amount: amt }],
        } as never);
      }
      await writeAudit(tx, auditOf(ctx), 'job_card', id, 'bill', null, { invoiceId: invoice.id });
      return { invoice, payment, job: await detailJson(tx, ctx, await loadJob(tx, ctx, id)) };
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/job-cards/:id/receipt', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('job_cards.create', 'job_cards.manage');
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(payBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const j = await loadJob(tx, ctx, id, true);
      if (!j.invoice_id) throw conflict('Bill the job first.', 'NOT_BILLED');
      const inv = await tx.selectFrom('invoices').select(['id', 'total', 'amount_paid', 'status']).where('id', '=', j.invoice_id).forUpdate().executeTakeFirstOrThrow();
      if (inv.status === 'cancelled') throw conflict('The bill is cancelled.', 'BAD_STATE');
      const balance = round2(inv.total - inv.amount_paid);
      if (b.amount > balance + 0.004) throw badRequest(`The balance is only ${balance.toFixed(2)}.`, { amount: 'More than balance' });
      const payment = await createPayment(ctx, tx, {
        kind: 'receipt', partyId: j.party_id, date: undefined, accountId: b.accountId, mode: b.mode, reference: b.reference,
        amount: b.amount, tdsAmount: undefined, notes: `Job ${j.number}`, allocations: [{ docId: inv.id, amount: b.amount }],
      } as never);
      await writeAudit(tx, auditOf(ctx), 'job_card', id, 'receipt', null, { amount: b.amount });
      return { payment, balance: round2(balance - b.amount) };
    });
    return reply.status(201).send(out);
  });

  app.get('/job-cards/technicians', async (req) => {
    const ctx = req.ctx;
    ctx.require('job_cards.create', 'job_cards.manage');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('user_roles as ur').innerJoin('roles as r', 'r.id', 'ur.role_id').innerJoin('users as u', 'u.id', 'ur.user_id')
        .select(['u.id', 'u.name']).where('ur.company_id', '=', ctx.companyId).where('u.is_active', '=', true)
        .where(sql<boolean>`'job_cards.work' = any(r.permissions)`).groupBy(['u.id', 'u.name']).orderBy('u.name').execute();
      return { data: rows };
    });
  });
}

documentRoute('POST', '/job-cards', { body: createBody });
documentRoute('PATCH', '/job-cards/:id', { body: patchBody });
documentRoute('POST', '/job-cards/:id/lines', { body: lineBody });
documentRoute('PATCH', '/job-cards/:id/lines/:lineId', { body: linePatch });
documentRoute('POST', '/job-cards/:id/status', { body: statusBody });
documentRoute('POST', '/job-cards/:id/receipt', { body: payBody });
