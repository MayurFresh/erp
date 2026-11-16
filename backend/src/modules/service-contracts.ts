import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { notify } from '../lib/notify.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { slotDate, type Frequency } from '../lib/recurrence.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { requireFiles } from './files.ts';
import { createInvoice } from './invoices.ts';
import { defaultLocation, round2 } from './services-common.ts';

/*
 * Service contracts (AMC). The value is before GST; invoices use the service item's GST. Preventive visits
 * are dated by the shared recurrence rules from the start date, strictly before the end date. Bills are keyed by
 * contract and period, so billing again never doubles an invoice.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const VISIT_FREQ = ['none', 'monthly', 'quarterly', 'half_yearly', 'yearly'] as const;
const BILL_FREQ = ['monthly', 'quarterly', 'half_yearly', 'yearly'] as const;
const assetBody = z.object({ itemId: z.uuid().optional(), serialNo: optionalText(60), description: optionalText(300) })
  .refine((a) => a.itemId || a.serialNo || a.description, 'Give an item, serial number or description');
const createBody = z.object({
  partyId: z.uuid(), title: z.string().trim().min(1, 'Give the contract a title').max(200),
  startDate: dateField, endDate: dateField, value: moneyField,
  billing: z.enum(['upfront', 'periodic']), billFrequency: z.enum(BILL_FREQ).optional(),
  visitFrequency: z.enum(VISIT_FREQ).default('none'), serviceItemId: z.uuid(), locationId: z.uuid().optional(),
  assets: z.array(assetBody).max(200).default([]), notes: optionalText(2000),
}).refine((b) => b.endDate > b.startDate, { message: 'End date must be after the start date', path: ['endDate'] })
  .refine((b) => b.billing === 'upfront' || b.billFrequency, { message: 'Choose how often to bill', path: ['billFrequency'] });
const patchBody = z.object({
  title: z.string().trim().min(1).max(200).optional(), notes: nullableText(2000), endDate: dateField.optional(),
  assets: z.array(assetBody).max(200).optional(), visitFrequency: z.enum(VISIT_FREQ).optional(), value: moneyField.optional(),
});
const billBody = z.object({ upTo: dateField.optional() });
const renewBody = z.object({ startDate: dateField.optional(), endDate: dateField.optional(), value: moneyField.optional() });
const linkBody = z.object({ refType: z.enum(['ticket', 'job_card']), refId: z.uuid() });
const listQuery = pagingQuery.extend({
  status: z.enum(['active', 'expired', 'cancelled', 'renewed']).optional(), partyId: z.uuid().optional(),
  expiringInDays: z.coerce.number().int().min(0).max(365).optional(),
});
const coverQuery = z.object({ partyId: z.uuid(), serialNo: z.string().max(60).optional(), itemId: z.uuid().optional(), on: dateField.optional() });
const visitQuery = z.object({
  from: dateField.optional(), to: dateField.optional(), status: z.enum(['scheduled', 'done', 'skipped']).optional(),
  technicianId: z.uuid().optional(), contractId: z.uuid().optional(),
});
const completeBody = z.object({
  doneDate: dateField.optional(), technicianId: z.uuid().optional(), notes: optionalText(2000),
  partsUsed: z.array(z.object({ itemId: z.uuid().optional(), name: z.string().trim().min(1).max(120), qty: qtyField.refine((v) => v > 0) })).max(50).default([]),
  signatureName: optionalText(100), signatureFileId: z.uuid().optional(), photoFileIds: z.array(z.uuid()).max(8).default([]),
});

// Schedules ---------------------------------------------------------------------------------------

/** Dates (after the start, before the end) of the preventive visits. */
export function visitDates(start: string, end: string, freq: string): string[] {
  if (freq === 'none') return [];
  const out: string[] = [];
  for (let n = 1; n < 500; n += 1) {
    const d = slotDate({ frequency: freq as Frequency, startDate: start, dayOfMonth: null }, n);
    if (d >= end) break;
    out.push(d);
  }
  return out;
}

/** Billing periods with their dates and amounts; the last period takes the rounding. */
export function billingPeriods(c: { start_date: string; end_date: string; value: number; billing: string; bill_frequency: string | null }) {
  if (c.billing === 'upfront') return [{ period: 'upfront', date: c.start_date, amount: round2(c.value) }];
  const dates: string[] = [];
  for (let n = 0; n < 1000; n += 1) {
    const d = slotDate({ frequency: c.bill_frequency as Frequency, startDate: c.start_date, dayOfMonth: null }, n);
    if (d >= c.end_date) break;
    dates.push(d);
  }
  const each = round2(c.value / dates.length);
  return dates.map((date, i) => ({
    period: date, date, amount: i === dates.length - 1 ? round2(c.value - each * (dates.length - 1)) : each,
  }));
}

// Loading -----------------------------------------------------------------------------------------

function contractQuery(tx: Tx) {
  return tx.selectFrom('service_contracts as c').innerJoin('parties as p', 'p.id', 'c.party_id').innerJoin('items as i', 'i.id', 'c.service_item_id')
    .selectAll('c').select(['p.name as party_name', 'i.name as item_name',
      sql<number>`coalesce((select sum(b.amount) from service_contract_bills b where b.contract_id = c.id), 0)`.as('billed')]);
}
type ContractRow = Awaited<ReturnType<ReturnType<typeof contractQuery>['executeTakeFirstOrThrow']>>;

function contractJson(r: ContractRow, assets: { id: string; item_id: string | null; item_name: string | null; serial_no: string | null; description: string | null }[], renewalDays: number) {
  const today = todayIst();
  const ended = r.status === 'active' && String(r.end_date) < today;
  const daysLeft = daysBetween(today, String(r.end_date));
  return {
    id: r.id, number: r.number, partyId: r.party_id, partyName: r.party_name, title: r.title, startDate: r.start_date, endDate: r.end_date,
    value: Number(r.value), billing: r.billing, billFrequency: r.bill_frequency, visitFrequency: r.visit_frequency,
    serviceItemId: r.service_item_id, serviceItemName: r.item_name, locationId: r.location_id, status: ended ? 'expired' : r.status,
    daysLeft, renewalDue: r.status === 'active' && !ended && daysLeft <= renewalDays, renewedFromId: r.renewed_from_id,
    renewedToId: r.renewed_to_id, notes: r.notes, billedAmount: Number(r.billed),
    assets: assets.map((a) => ({ id: a.id, itemId: a.item_id, itemName: a.item_name, serialNo: a.serial_no, description: a.description })),
    createdAt: r.created_at, updatedAt: r.updated_at,
  };
}

async function assetsOf(tx: Tx, ids: string[]) {
  if (!ids.length) return new Map<string, Awaited<ReturnType<typeof loadAssets>>>();
  const rows = await loadAssets(tx, ids);
  const m = new Map<string, typeof rows>();
  for (const r of rows) m.set(r.contract_id, [...(m.get(r.contract_id) ?? []), r]);
  return m;
}
const loadAssets = (tx: Tx, ids: string[]) => tx.selectFrom('service_contract_assets as a').leftJoin('items as i', 'i.id', 'a.item_id')
  .select(['a.id', 'a.contract_id', 'a.item_id', 'i.name as item_name', 'a.serial_no', 'a.description']).where('a.contract_id', 'in', ids).orderBy('a.id').execute();

async function loadContract(tx: Tx, ctx: { companyId: string }, id: string, lock = false) {
  const row = await contractQuery(tx).where('c.id', '=', id).where('c.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row) throw notFound('Contract');
  if (lock) await tx.selectFrom('service_contracts').select('id').where('id', '=', id).forUpdate().execute();
  return row;
}

async function renewalDaysOf(tx: Tx, companyId: string) {
  const s = await tx.selectFrom('hd_settings').select('renewal_days').where('company_id', '=', companyId).executeTakeFirst();
  return s?.renewal_days ?? 30;
}

function visitJson(v: { id: string; contract_id: string; number: string; party_name: string; due_date: string; status: string;
  technician_id: string | null; technician_name: string | null; done_date: string | null; notes?: string | null; parts_used?: unknown;
  signature_name?: string | null; photo_file_ids?: string[]; signature_file_id?: string | null; skip_reason?: string | null }) {
  return {
    id: v.id, contractId: v.contract_id, contractNumber: v.number, partyName: v.party_name, dueDate: v.due_date, status: v.status,
    overdue: v.status === 'scheduled' && String(v.due_date) < todayIst(), technicianId: v.technician_id, technicianName: v.technician_name,
    doneDate: v.done_date, notes: v.notes ?? null, partsUsed: v.parts_used ?? [], signatureName: v.signature_name ?? null,
    signatureFileId: v.signature_file_id ?? null, photoFileIds: v.photo_file_ids ?? [], skipReason: v.skip_reason ?? null,
  };
}

const visitSelect = (tx: Tx, companyId: string) => tx.selectFrom('service_visits as v').innerJoin('service_contracts as c', 'c.id', 'v.contract_id')
  .innerJoin('parties as p', 'p.id', 'c.party_id').leftJoin('users as u', 'u.id', 'v.technician_id')
  .select(['v.id', 'v.contract_id', 'c.number', 'p.name as party_name', 'v.due_date', 'v.status', 'v.technician_id', 'u.name as technician_name',
    'v.done_date', 'v.notes', 'v.parts_used', 'v.signature_name', 'v.photo_file_ids', 'v.signature_file_id', 'v.skip_reason'])
  .where('v.company_id', '=', companyId);

async function detail(tx: Tx, ctx: { companyId: string }, id: string) {
  const c = await loadContract(tx, ctx, id);
  const assets = (await assetsOf(tx, [id])).get(id) ?? [];
  const visits = await visitSelect(tx, ctx.companyId).where('v.contract_id', '=', id).orderBy('v.due_date').execute();
  const bills = await tx.selectFrom('service_contract_bills as b').innerJoin('invoices as i', 'i.id', 'b.invoice_id')
    .select(['b.period', 'b.invoice_id', 'i.number', 'b.amount', 'b.period_date']).where('b.contract_id', '=', id).orderBy('b.period_date').execute();
  const links = await tx.selectFrom('service_contract_links').select(['ref_type', 'ref_id']).where('contract_id', '=', id).orderBy('created_at').execute();
  const tickets = links.filter((l) => l.ref_type === 'ticket').map((l) => l.ref_id);
  const jobs = links.filter((l) => l.ref_type === 'job_card').map((l) => l.ref_id);
  const tn = tickets.length ? await tx.selectFrom('hd_tickets').select(['id', 'number']).where('id', 'in', tickets).execute() : [];
  const jn = jobs.length ? await tx.selectFrom('job_cards').select(['id', 'number']).where('id', 'in', jobs).execute() : [];
  return {
    ...contractJson(c, assets, await renewalDaysOf(tx, ctx.companyId)),
    visits: visits.map(visitJson),
    bills: bills.map((b) => ({ period: b.period, invoiceId: b.invoice_id, number: b.number, amount: Number(b.amount), date: b.period_date })),
    links: links.map((l) => ({ refType: l.ref_type, refId: l.ref_id,
      label: (l.ref_type === 'ticket' ? tn : jn).find((x) => x.id === l.ref_id)?.number ?? l.ref_id })),
  };
}

// Shared helpers ----------------------------------------------------------------------------------

/** Active contracts of a party on a date that cover the serial or item (all of the party's when neither is given). */
export async function coveringContracts(tx: Tx, companyId: string, q: { partyId: string; serialNo?: string; itemId?: string; on?: string }) {
  const on = q.on ?? todayIst();
  let base = tx.selectFrom('service_contracts as c').select(['c.id', 'c.number', 'c.title', 'c.end_date'])
    .where('c.company_id', '=', companyId).where('c.party_id', '=', q.partyId).where('c.status', '=', 'active')
    .where('c.start_date', '<=', on).where('c.end_date', '>=', on).orderBy('c.end_date');
  if (q.serialNo || q.itemId) {
    base = base.where((eb) => eb.exists(eb.selectFrom('service_contract_assets as a').select('a.id').whereRef('a.contract_id', '=', 'c.id').where((e2) => e2.or([
      ...(q.serialNo ? [e2(sql`lower(a.serial_no)`, '=', q.serialNo.toLowerCase())] : []),
      ...(q.itemId ? [e2('a.item_id', '=', q.itemId)] : []),
    ]))));
  }
  return base.execute();
}

async function insertAssets(tx: Tx, tenantId: string, contractId: string, companyId: string, assets: z.infer<typeof assetBody>[]) {
  const ids = assets.map((a) => a.itemId).filter(Boolean) as string[];
  if (ids.length) {
    const found = await tx.selectFrom('items').select('id').where('company_id', '=', companyId).where('id', 'in', ids).execute();
    if (found.length !== new Set(ids).size) throw badRequest('An item was not found.', { assets: 'Item not found' });
  }
  if (assets.length) {
    await tx.insertInto('service_contract_assets').values(assets.map((a) => ({
      tenant_id: tenantId, contract_id: contractId, item_id: a.itemId ?? null, serial_no: a.serialNo ?? null, description: a.description ?? null,
    }))).execute();
  }
}

async function makeVisits(tx: Tx, ctx: { tenantId: string; companyId: string }, contractId: string, start: string, end: string, freq: string) {
  const keep = await tx.selectFrom('service_visits').select('due_date').where('contract_id', '=', contractId).where('status', '!=', 'scheduled').execute();
  const have = new Set(keep.map((k) => String(k.due_date)));
  await tx.deleteFrom('service_visits').where('contract_id', '=', contractId).where('status', '=', 'scheduled').execute();
  const dates = visitDates(start, end, freq).filter((d) => !have.has(d));
  if (dates.length) {
    await tx.insertInto('service_visits').values(dates.map((d) => ({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, contract_id: contractId, due_date: d,
    }))).execute();
  }
}

async function validateCommon(tx: Tx, ctx: RequestContext, b: { partyId: string; serviceItemId: string; locationId?: string }) {
  const p = await tx.selectFrom('parties').select(['id', 'type']).where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!p) throw badRequest('Customer not found.', { partyId: 'Not found' });
  if (p.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { partyId: 'Not a customer' });
  const it = await tx.selectFrom('items').select('id').where('id', '=', b.serviceItemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!it) throw badRequest('Service item not found.', { serviceItemId: 'Not found' });
  if (b.locationId) ctx.requireLocation(b.locationId);
}

/** Renewal reminders: once per active contract ending within `days`. Returns how many were queued. */
export async function runContractReminders(tx: Tx, who: { tenantId: string; companyId: string }, today: string, days: number) {
  const rows = await tx.selectFrom('service_contracts as c').innerJoin('parties as p', 'p.id', 'c.party_id')
    .select(['c.id', 'c.number', 'c.title', 'c.end_date', 'c.created_by', 'p.name as party_name'])
    .where('c.company_id', '=', who.companyId).where('c.status', '=', 'active')
    .where('c.end_date', '>=', today).where('c.end_date', '<=', addDays(today, days))
    .where((eb) => eb.not(eb.exists(eb.selectFrom('service_contract_reminders as r').select('r.contract_id').whereRef('r.contract_id', '=', 'c.id')))).execute();
  for (const c of rows) {
    await notify(tx, who, {
      userIds: [c.created_by], template: 'contract_renewal', link: `/service-contracts/${c.id}`,
      data: { number: c.number, title: c.title, partyName: c.party_name, endDate: String(c.end_date), daysLeft: daysBetween(today, String(c.end_date)) },
    });
    await tx.insertInto('service_contract_reminders').values({ tenant_id: who.tenantId, contract_id: c.id, sent_on: today }).execute();
  }
  return rows.length;
}

// Routes ------------------------------------------------------------------------------------------

export async function serviceContractRoutes(app: FastifyInstance): Promise<void> {
  const view = (ctx: RequestContext) => ctx.require('service_contracts.view', 'service_contracts.manage');
  const manage = (ctx: RequestContext) => ctx.require('service_contracts.manage');

  app.get('/service-contracts', async (req) => {
    const ctx = req.ctx; view(ctx);
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      const today = todayIst();
      let base = contractQuery(tx).where('c.company_id', '=', ctx.companyId);
      if (q.status === 'expired') base = base.where('c.status', '=', 'active').where('c.end_date', '<', today);
      else if (q.status === 'active') base = base.where('c.status', '=', 'active').where('c.end_date', '>=', today);
      else if (q.status) base = base.where('c.status', '=', q.status);
      if (q.partyId) base = base.where('c.party_id', '=', q.partyId);
      if (q.expiringInDays !== undefined) {
        base = base.where('c.status', '=', 'active').where('c.end_date', '>=', today).where('c.end_date', '<=', addDays(today, q.expiringInDays));
      }
      if (q.q) {
        const like = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('c.number', 'ilike', like), eb('c.title', 'ilike', like), eb('p.name', 'ilike', like)]));
      }
      const total = await tx.selectFrom('service_contracts as c').innerJoin('parties as p', 'p.id', 'c.party_id')
        .select(sql<number>`count(*)::int`.as('n')).where('c.company_id', '=', ctx.companyId).$call((qb) => {
          let x = qb;
          if (q.status === 'expired') x = x.where('c.status', '=', 'active').where('c.end_date', '<', today);
          else if (q.status === 'active') x = x.where('c.status', '=', 'active').where('c.end_date', '>=', today);
          else if (q.status) x = x.where('c.status', '=', q.status);
          if (q.partyId) x = x.where('c.party_id', '=', q.partyId);
          if (q.expiringInDays !== undefined) x = x.where('c.status', '=', 'active').where('c.end_date', '>=', today).where('c.end_date', '<=', addDays(today, q.expiringInDays));
          if (q.q) { const like = likeTerm(q.q); x = x.where((eb) => eb.or([eb('c.number', 'ilike', like), eb('c.title', 'ilike', like), eb('p.name', 'ilike', like)])); }
          return x;
        }).executeTakeFirstOrThrow();
      const rows = await base.orderBy('c.end_date').orderBy('c.number').limit(q.limit).offset(q.offset).execute();
      const assets = await assetsOf(tx, rows.map((r) => r.id));
      const rd = await renewalDaysOf(tx, ctx.companyId);
      return { data: rows.map((r) => contractJson(r, assets.get(r.id) ?? [], rd)), total: total.n };
    });
  });

  app.get('/service-contracts/covering', async (req) => {
    const ctx = req.ctx;
    ctx.require('service_contracts.view', 'service_contracts.manage', 'helpdesk.view', 'helpdesk.manage', 'job_cards.view', 'job_cards.create');
    const q = parse(coverQuery, req.query);
    return ctx.tx(async (tx) => {
      const found = await coveringContracts(tx, ctx.companyId, q);
      const rd = await renewalDaysOf(tx, ctx.companyId);
      const out = [];
      for (const f of found) out.push(contractJson(await loadContract(tx, ctx, f.id), (await assetsOf(tx, [f.id])).get(f.id) ?? [], rd));
      return { data: out };
    });
  });

  app.get('/service-contracts/visits', async (req) => {
    const ctx = req.ctx; view(ctx);
    const q = parse(visitQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = visitSelect(tx, ctx.companyId);
      if (q.from) base = base.where('v.due_date', '>=', q.from);
      if (q.to) base = base.where('v.due_date', '<=', q.to);
      if (q.status) base = base.where('v.status', '=', q.status);
      if (q.technicianId) base = base.where('v.technician_id', '=', q.technicianId);
      if (q.contractId) base = base.where('v.contract_id', '=', q.contractId);
      const rows = await base.where('c.status', '!=', 'cancelled').orderBy('v.due_date').orderBy('c.number').limit(1000).execute();
      return { data: rows.map(visitJson) };
    });
  });

  app.patch<{ Params: { visitId: string } }>('/service-contracts/visits/:visitId', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const id = parse(z.uuid(), req.params.visitId);
    const b = parse(z.object({ dueDate: dateField.optional(), technicianId: z.uuid().nullable().optional() }), req.body);
    return ctx.tx(async (tx) => {
      const v = await tx.selectFrom('service_visits').select(['id', 'status']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!v) throw notFound('Visit');
      if (v.status !== 'scheduled') throw conflict('Only a scheduled visit can be changed.', 'BAD_STATE');
      const set: Record<string, unknown> = {};
      if (b.dueDate) set.due_date = b.dueDate;
      if (b.technicianId !== undefined) set.technician_id = b.technicianId;
      if (Object.keys(set).length) await tx.updateTable('service_visits').set(set as never).where('id', '=', id).execute();
      return visitJson((await visitSelect(tx, ctx.companyId).where('v.id', '=', id).executeTakeFirstOrThrow()));
    });
  });

  app.post<{ Params: { visitId: string } }>('/service-contracts/visits/:visitId/complete', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const id = parse(z.uuid(), req.params.visitId);
    const b = parse(completeBody, req.body);
    return ctx.tx(async (tx) => {
      const v = await tx.selectFrom('service_visits').select(['id', 'status']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!v) throw notFound('Visit');
      if (v.status !== 'scheduled') throw conflict('This visit is already closed.', 'BAD_STATE');
      const today = todayIst();
      if (b.doneDate && b.doneDate > today) throw badRequest('A visit cannot be done in the future.', { doneDate: 'Not in the future' });
      const refs = [...b.photoFileIds, ...(b.signatureFileId ? [b.signatureFileId] : [])].map((f) => ({ id: f, field: 'photoFileIds' }));
      await requireFiles(tx, refs, false);
      if (b.technicianId) {
        const u = await tx.selectFrom('users').select('id').where('id', '=', b.technicianId).where('is_active', '=', true).executeTakeFirst();
        if (!u) throw badRequest('Technician not found.', { technicianId: 'Not found' });
      }
      await tx.updateTable('service_visits').set({
        status: 'done', done_date: b.doneDate ?? today, technician_id: b.technicianId ?? ctx.userId, notes: b.notes ?? null,
        parts_used: JSON.stringify(b.partsUsed), signature_name: b.signatureName ?? null, signature_file_id: b.signatureFileId ?? null,
        photo_file_ids: b.photoFileIds,
      } as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'service_visit', id, 'complete', null, { doneDate: b.doneDate ?? today });
      return visitJson(await visitSelect(tx, ctx.companyId).where('v.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.post<{ Params: { visitId: string } }>('/service-contracts/visits/:visitId/skip', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const id = parse(z.uuid(), req.params.visitId);
    const b = parse(z.object({ reason: z.string().trim().min(1, 'Give a reason').max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const v = await tx.selectFrom('service_visits').select(['id', 'status']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!v) throw notFound('Visit');
      if (v.status !== 'scheduled') throw conflict('This visit is already closed.', 'BAD_STATE');
      await tx.updateTable('service_visits').set({ status: 'skipped', skip_reason: b.reason }).where('id', '=', id).execute();
      return visitJson(await visitSelect(tx, ctx.companyId).where('v.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.post('/service-contracts', async (req, reply) => {
    const ctx = req.ctx; manage(ctx);
    const b = parse(createBody, req.body);
    const out = await ctx.tx(async (tx) => {
      await validateCommon(tx, ctx, b);
      const number = await nextNumber(tx, ctx, 'service_contract', financialYear(b.startDate));
      const row = await tx.insertInto('service_contracts').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, party_id: b.partyId, title: b.title, start_date: b.startDate,
        end_date: b.endDate, value: b.value, billing: b.billing, bill_frequency: b.billing === 'periodic' ? b.billFrequency! : null,
        visit_frequency: b.visitFrequency, service_item_id: b.serviceItemId, location_id: b.locationId ?? null, notes: b.notes ?? null,
        created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await insertAssets(tx, ctx.tenantId, row.id, ctx.companyId, b.assets);
      await makeVisits(tx, ctx, row.id, b.startDate, b.endDate, b.visitFrequency);
      await writeAudit(tx, auditOf(ctx), 'service_contract', row.id, 'create', null, { number, partyId: b.partyId, value: b.value });
      return detail(tx, ctx, row.id);
    });
    return reply.code(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/service-contracts/:id', async (req) => {
    const ctx = req.ctx; view(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => detail(tx, ctx, id));
  });

  app.patch<{ Params: { id: string } }>('/service-contracts/:id', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const c = await loadContract(tx, ctx, id, true);
      if (c.status !== 'active') throw conflict('This contract can no longer be changed.', 'LOCKED');
      const set: Record<string, unknown> = {};
      if (b.title !== undefined) set.title = b.title;
      if (b.notes !== undefined) set.notes = b.notes;
      const end = b.endDate ?? String(c.end_date);
      if (b.endDate) {
        if (b.endDate <= String(c.start_date)) throw badRequest('End date must be after the start date.', { endDate: 'After start' });
        set.end_date = b.endDate;
      }
      if (b.value !== undefined) {
        const billed = await tx.selectFrom('service_contract_bills').select('id').where('contract_id', '=', id).limit(1).executeTakeFirst();
        if (billed) throw conflict('The value cannot change after billing.', 'BILLED');
        set.value = b.value;
      }
      const freq = b.visitFrequency ?? c.visit_frequency;
      if (b.visitFrequency) set.visit_frequency = b.visitFrequency;
      if (Object.keys(set).length) await tx.updateTable('service_contracts').set(set as never).where('id', '=', id).execute();
      if (b.assets) {
        await tx.deleteFrom('service_contract_assets').where('contract_id', '=', id).execute();
        await insertAssets(tx, ctx.tenantId, id, ctx.companyId, b.assets);
      }
      if (b.endDate || b.visitFrequency) await makeVisits(tx, ctx, id, String(c.start_date), end, freq);
      await writeAudit(tx, auditOf(ctx), 'service_contract', id, 'update', null, set);
      return detail(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/service-contracts/:id/bill', async (req) => {
    const ctx = req.ctx; manage(ctx);
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(billBody, req.body);
    return ctx.tx(async (tx) => {
      const c = await loadContract(tx, ctx, id, true);
      if (c.status !== 'active') throw conflict('Only an active contract can be billed.', 'LOCKED');
      const today = todayIst();
      const upTo = b.upTo ?? today;
      const done = new Set((await tx.selectFrom('service_contract_bills').select('period').where('contract_id', '=', id).execute()).map((x) => x.period));
      const location = await defaultLocation(tx, ctx, c.location_id ?? undefined);
      const created: { period: string; invoiceId: string; number: string; amount: number }[] = [];
      let skipped = 0;
      for (const p of billingPeriods({ ...c, value: Number(c.value) } as never)) {
        if (p.date > upTo) continue;
        if (done.has(p.period)) { skipped += 1; continue; }
        const inv = await createInvoice(ctx, tx, {
          locationId: location, partyId: c.party_id, invoiceDate: today,
          lines: [{ itemId: c.service_item_id, qty: 1, rate: p.amount, description: `${c.title} (${c.number}), ${p.period === 'upfront' ? 'full term' : `from ${p.period}`}` }],
          notes: `Service contract ${c.number}`,
        } as never) as { id: string; number: string };
        await tx.insertInto('service_contract_bills').values({
          tenant_id: ctx.tenantId, contract_id: id, period: p.period, period_date: p.date, amount: p.amount, invoice_id: inv.id,
        }).execute();
        created.push({ period: p.period, invoiceId: inv.id, number: inv.number, amount: p.amount });
      }
      return { created, skipped };
    });
  });

  app.post<{ Params: { id: string } }>('/service-contracts/:id/cancel', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ reason: z.string().trim().min(1, 'Give a reason').max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const c = await loadContract(tx, ctx, id, true);
      if (c.status !== 'active') throw conflict('This contract can no longer be changed.', 'LOCKED');
      await tx.updateTable('service_contracts').set({ status: 'cancelled', cancel_reason: b.reason }).where('id', '=', id).execute();
      await tx.deleteFrom('service_visits').where('contract_id', '=', id).where('status', '=', 'scheduled').execute();
      await writeAudit(tx, auditOf(ctx), 'service_contract', id, 'cancel', null, { reason: b.reason });
      return detail(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/service-contracts/:id/renew', async (req, reply) => {
    const ctx = req.ctx; manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(renewBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const c = await loadContract(tx, ctx, id, true);
      if (c.status === 'renewed') throw conflict('This contract is already renewed.', 'ALREADY_RENEWED');
      if (c.status === 'cancelled') throw conflict('A cancelled contract cannot be renewed.', 'LOCKED');
      const start = b.startDate ?? addDays(String(c.end_date), 1);
      const end = b.endDate ?? addDays(start, daysBetween(String(c.start_date), String(c.end_date)));
      if (end <= start) throw badRequest('End date must be after the start date.', { endDate: 'After start' });
      const number = await nextNumber(tx, ctx, 'service_contract', financialYear(start));
      const row = await tx.insertInto('service_contracts').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, party_id: c.party_id, title: c.title, start_date: start, end_date: end,
        value: b.value ?? Number(c.value), billing: c.billing, bill_frequency: c.bill_frequency, visit_frequency: c.visit_frequency,
        service_item_id: c.service_item_id, location_id: c.location_id, notes: c.notes, renewed_from_id: id, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const assets = (await assetsOf(tx, [id])).get(id) ?? [];
      await insertAssets(tx, ctx.tenantId, row.id, ctx.companyId, assets.map((a) => ({
        itemId: a.item_id ?? undefined, serialNo: a.serial_no ?? undefined, description: a.description ?? undefined })));
      await makeVisits(tx, ctx, row.id, start, end, c.visit_frequency);
      await tx.updateTable('service_contracts').set({ status: 'renewed', renewed_to_id: row.id }).where('id', '=', id).execute();
      await tx.deleteFrom('service_visits').where('contract_id', '=', id).where('status', '=', 'scheduled').where('due_date', '>=', start).execute();
      await writeAudit(tx, auditOf(ctx), 'service_contract', id, 'renew', null, { newContractId: row.id });
      return detail(tx, ctx, row.id);
    });
    return reply.code(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/service-contracts/:id/links', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(linkBody, req.body);
    return ctx.tx(async (tx) => {
      await loadContract(tx, ctx, id);
      const t = b.refType === 'ticket' ? 'hd_tickets' : 'job_cards';
      const ref = await tx.selectFrom(t).select('id').where('id', '=', b.refId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!ref) throw badRequest('That record was not found.', { refId: 'Not found' });
      await tx.insertInto('service_contract_links').values({ tenant_id: ctx.tenantId, contract_id: id, ref_type: b.refType, ref_id: b.refId })
        .onConflict((oc) => oc.doNothing()).execute();
      if (b.refType === 'ticket') await tx.updateTable('hd_tickets').set({ contract_id: id }).where('id', '=', b.refId).execute();
      return detail(tx, ctx, id);
    });
  });

  app.delete<{ Params: { id: string; refType: string; refId: string } }>('/service-contracts/:id/links/:refType/:refId', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const refType = parse(z.enum(['ticket', 'job_card']), req.params.refType);
    const refId = parse(z.uuid(), req.params.refId);
    return ctx.tx(async (tx) => {
      await loadContract(tx, ctx, id);
      await tx.deleteFrom('service_contract_links').where('contract_id', '=', id).where('ref_type', '=', refType).where('ref_id', '=', refId).execute();
      if (refType === 'ticket') await tx.updateTable('hd_tickets').set({ contract_id: null }).where('id', '=', refId).where('contract_id', '=', id).execute();
      return detail(tx, ctx, id);
    });
  });
}
