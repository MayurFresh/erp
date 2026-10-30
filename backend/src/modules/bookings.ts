import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { paymentInfo } from '../lib/docs.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, percentField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getProject } from './projects.ts';
import { getUnit } from './units.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const reasonBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const BOOKING_STATUSES = ['booked', 'agreement', 'possession', 'cancelled'] as const;

const createBody = z.object({
  unitId: z.uuid(),
  customerPartyId: z.uuid(),
  date: docDate.optional(),
  agreementValue: moneyField.optional(),
  gstPct: percentField.max(28).optional(),
  paymentPlanId: z.uuid(),
  notes: optionalText(1000),
});
const patchBody = z.object({
  notes: z.preprocess((v) => (typeof v === 'string' && v.trim() === '' ? null : v), z.string().trim().max(1000).nullable().optional()),
  gstPct: percentField.max(28).optional(),
  agreementValue: moneyField.optional(),
});
const agreementBody = z.object({ agreementNo: z.string().trim().min(1, 'Required').max(60), agreementDate: dateField });
const demandBody = z.object({
  stageIds: z.array(z.uuid()).min(1, 'Choose at least one stage').max(50),
  date: docDate.optional(),
  dueDate: dateField.optional(),
});
const possessionBody = z.object({ date: dateField });
const listQuery = pagingQuery.extend({
  projectId: z.uuid().optional(),
  unitId: z.uuid().optional(),
  customerId: z.uuid().optional(),
  status: z.enum(BOOKING_STATUSES).optional(),
});
const demandListQuery = pagingQuery.extend({
  bookingId: z.uuid().optional(),
  projectId: z.uuid().optional(),
  customerId: z.uuid().optional(),
  status: z.enum(['open', 'cancelled']).optional(),
  paymentStatus: z.enum(['unpaid', 'partial', 'paid']).optional(),
  from: dateField.optional(),
  to: dateField.optional(),
});
const reraQuery = z.object({ to: dateField.optional() });

// Paise arithmetic --------------------------------------------------------------------------------

/** a × b ÷ d rounded half up; all non-negative. */
function mulDivRound(a: bigint, b: bigint, d: bigint): bigint {
  return (a * b * 2n + d) / (2n * d);
}
const toPaise = (rupees: number) => BigInt(Math.round(rupees * 100));
const fromPaise = (p: bigint) => Number(p) / 100;

/** Stage amounts for a percentage list; the last stage takes the remainder so the sum is exact. */
export function splitStages(agreementValue: number, pcts: number[]): number[] {
  const total = toPaise(agreementValue);
  let used = 0n;
  return pcts.map((pct, i) => {
    if (i === pcts.length - 1) return fromPaise(total - used);
    const part = mulDivRound(total, BigInt(Math.round(pct * 100)), 10_000n);
    used += part;
    return fromPaise(part);
  });
}

/** One of the two equal GST halves on a demand: amount × gstPct ÷ 200. */
export function gstHalf(amount: number, gstPct: number): number {
  return fromPaise(mulDivRound(toPaise(amount), BigInt(Math.round(gstPct * 100)), 20_000n));
}

// Loading -----------------------------------------------------------------------------------------

function bookingSelect(tx: Tx) {
  return tx.selectFrom('bookings as b')
    .innerJoin('projects as p', 'p.id', 'b.project_id')
    .innerJoin('units as u', 'u.id', 'b.unit_id')
    .innerJoin('parties as c', 'c.id', 'b.customer_party_id')
    .innerJoin('payment_plans as pp', 'pp.id', 'b.payment_plan_id')
    .innerJoin('users as cu', 'cu.id', 'b.created_by')
    .selectAll('b')
    .select(['p.name as project_name', 'u.code as unit_code', 'c.name as customer_name', 'pp.name as plan_name', 'cu.name as created_by_name']);
}

async function loadBookings(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const rows = await bookingSelect(tx).where('b.id', 'in', ids).execute();
  const stages = await tx.selectFrom('booking_stages as s').leftJoin('demands as d', 'd.id', 's.demand_id')
    .select(['s.id', 's.booking_id', 's.name', 's.pct', 's.amount', 's.sort_order', 's.demand_id', 'd.number as demand_number'])
    .where('s.booking_id', 'in', ids).orderBy('s.sort_order').execute();
  const demands = await tx.selectFrom('demands').selectAll().where('booking_id', 'in', ids).where('status', '=', 'open').execute();
  return ids.map((id) => {
    const b = rows.find((r) => r.id === id)!;
    const open = demands.filter((d) => d.booking_id === id);
    const demanded = round2(open.reduce((s, d) => s + d.amount, 0));
    return {
      id: b.id, number: b.number, projectId: b.project_id, projectName: b.project_name, unitId: b.unit_id, unitCode: b.unit_code,
      customerPartyId: b.customer_party_id, customerName: b.customer_name, date: b.booking_date,
      agreementValue: b.agreement_value, gstPct: b.gst_pct, paymentPlanId: b.payment_plan_id, paymentPlanName: b.plan_name,
      status: b.status, agreementNo: b.agreement_no, agreementDate: b.agreement_date, possessionDate: b.possession_date,
      notes: b.notes,
      stages: stages.filter((s) => s.booking_id === id).map((s) => ({
        id: s.id, name: s.name, pct: s.pct, amount: s.amount, sortOrder: s.sort_order, demandId: s.demand_id,
        demandNumber: s.demand_number,
      })),
      totals: {
        demanded, gst: round2(open.reduce((s, d) => s + d.cgst + d.sgst, 0)),
        received: round2(open.reduce((s, d) => s + d.amount_paid, 0)),
        due: round2(open.reduce((s, d) => s + Math.max(d.total - d.amount_paid, 0), 0)),
        undemanded: round2(b.agreement_value - demanded),
      },
      createdAt: b.created_at, createdBy: { id: b.created_by, name: b.created_by_name },
      cancelledAt: b.cancelled_at, cancelReason: b.cancel_reason,
    };
  });
}

function demandSelect(tx: Tx) {
  return tx.selectFrom('demands as d')
    .innerJoin('bookings as b', 'b.id', 'd.booking_id')
    .innerJoin('units as u', 'u.id', 'b.unit_id')
    .innerJoin('parties as p', 'p.id', 'd.party_id')
    .innerJoin('users as cu', 'cu.id', 'd.created_by')
    .selectAll('d')
    .select(['b.number as booking_number', 'b.project_id', 'u.code as unit_code', 'p.name as party_name', 'cu.name as created_by_name']);
}

async function loadDemands(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const rows = await demandSelect(tx).where('d.id', 'in', ids).execute();
  const stages = await tx.selectFrom('booking_stages').select(['id', 'name', 'pct', 'amount', 'demand_id', 'sort_order'])
    .where('demand_id', 'in', ids).orderBy('sort_order').execute();
  return ids.map((id) => {
    const d = rows.find((r) => r.id === id)!;
    return {
      id: d.id, number: d.number, bookingId: d.booking_id, bookingNumber: d.booking_number, projectId: d.project_id,
      unitCode: d.unit_code, partyId: d.party_id, partyName: d.party_name, date: d.demand_date, dueDate: d.due_date,
      stages: stages.filter((s) => s.demand_id === id).map((s) => ({ id: s.id, name: s.name, pct: s.pct, amount: s.amount })),
      amount: d.amount, cgst: d.cgst, sgst: d.sgst, total: d.total, ...paymentInfo(d.total, d.amount_paid, d.status),
      status: d.status, createdAt: d.created_at, createdBy: { id: d.created_by, name: d.created_by_name },
      cancelledAt: d.cancelled_at, cancelReason: d.cancel_reason,
    };
  });
}

async function getBooking(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('bookings').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const booking = await q.executeTakeFirst();
  if (!booking) throw notFound('Booking');
  await getProject(tx, ctx, booking.project_id);
  return booking;
}

/** First site of the project by name: the location dimension of its real-estate vouchers. */
async function projectSite(tx: Tx, projectId: string): Promise<string | null> {
  const site = await tx.selectFrom('locations').select('id').where('project_id', '=', projectId).orderBy('name').limit(1).executeTakeFirst();
  return site?.id ?? null;
}

// Routes ------------------------------------------------------------------------------------------

export async function bookingRoutes(app: FastifyInstance) {
  app.get('/bookings', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('bookings as b')
        .innerJoin('units as u', 'u.id', 'b.unit_id').innerJoin('parties as c', 'c.id', 'b.customer_party_id')
        .where('b.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) {
        base = base.where((eb) => eb.exists(eb.selectFrom('locations as s').select('s.id')
          .whereRef('s.project_id', '=', 'b.project_id').where('s.id', 'in', scope)));
      }
      if (q.projectId) base = base.where('b.project_id', '=', q.projectId);
      if (q.unitId) base = base.where('b.unit_id', '=', q.unitId);
      if (q.customerId) base = base.where('b.customer_party_id', '=', q.customerId);
      if (q.status) base = base.where('b.status', '=', q.status);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('b.number', 'ilike', t), eb('u.code', 'ilike', t), eb('c.name', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('b.id').orderBy('b.booking_date', 'desc').orderBy('b.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadBookings(tx, ids.map((r) => r.id)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/bookings/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await getBooking(tx, ctx, id);
      return (await loadBookings(tx, [id]))[0];
    });
  });

  app.post('/bookings', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('bookings.manage');
    const body = parse(createBody, req.body);
    const booking = await ctx.tx(async (tx) => {
      const unit = await getUnit(tx, ctx, body.unitId, true);
      if (unit.status !== 'available' && unit.status !== 'hold') {
        throw conflict(`Unit ${unit.code} is not available.`, 'CONFLICT', { unitId: 'Not available' });
      }
      const party = await tx.selectFrom('parties').select(['id', 'type'])
        .where('id', '=', body.customerPartyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw badRequest('Customer not found.', { customerPartyId: 'Not found' });
      if (party.type === 'vendor') throw badRequest('Choose a customer, not a vendor.', { customerPartyId: 'Not a customer' });
      const plan = await tx.selectFrom('payment_plans').selectAll()
        .where('id', '=', body.paymentPlanId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!plan || plan.project_id !== unit.project_id) {
        throw badRequest('Choose a payment plan of the same project.', { paymentPlanId: 'Not in this project' });
      }
      if (!plan.is_active) throw badRequest('This payment plan is inactive.', { paymentPlanId: 'Inactive' });
      const agreementValue = body.agreementValue ?? unit.list_price;
      if (!(agreementValue > 0)) throw badRequest('Agreement value must be more than zero.', { agreementValue: 'Must be more than zero' });
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Booking date cannot be in the future.', { date: 'In the future' });

      const planStages = await tx.selectFrom('payment_plan_stages').selectAll().where('payment_plan_id', '=', plan.id).orderBy('sort_order').execute();
      const amounts = splitStages(agreementValue, planStages.map((s) => s.pct));
      const number = await nextNumber(tx, ctx, 'booking', financialYear(date));
      const row = await tx.insertInto('bookings').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, project_id: unit.project_id, unit_id: unit.id,
        customer_party_id: party.id, booking_date: date, agreement_value: agreementValue, gst_pct: body.gstPct ?? 5,
        payment_plan_id: plan.id, notes: body.notes ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('booking_stages').values(planStages.map((s, i) => ({
        tenant_id: ctx.tenantId, booking_id: row.id, sort_order: s.sort_order, name: s.name, pct: s.pct, amount: amounts[i]!,
      }))).execute();
      await tx.updateTable('units').set({ status: 'booked' }).where('id', '=', unit.id).execute();
      const saved = (await loadBookings(tx, [row.id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'booking', row.id, 'create', null,
        { number, unitId: unit.id, customerPartyId: party.id, agreementValue });
      return saved;
    });
    return reply.status(201).send(booking);
  });

  app.patch<{ Params: { id: string } }>('/bookings/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const before = await getBooking(tx, ctx, id, true);
      if (before.status === 'cancelled') throw conflict('This booking is cancelled.', 'CONFLICT');
      const old = (await loadBookings(tx, [id]))[0]!;
      const financial = body.gstPct !== undefined || body.agreementValue !== undefined;
      if (financial) {
        const open = await tx.selectFrom('demands').select('id').where('booking_id', '=', id).where('status', '=', 'open').executeTakeFirst();
        if (open) throw conflict('The value and GST cannot change once a demand has been raised.', 'CONFLICT');
      }
      const changes: Record<string, unknown> = {};
      if (body.notes !== undefined) changes.notes = body.notes;
      if (body.gstPct !== undefined) changes.gst_pct = body.gstPct;
      if (body.agreementValue !== undefined) {
        if (!(body.agreementValue > 0)) throw badRequest('Agreement value must be more than zero.', { agreementValue: 'Must be more than zero' });
        changes.agreement_value = body.agreementValue;
        const stages = await tx.selectFrom('booking_stages').select(['id', 'pct']).where('booking_id', '=', id).orderBy('sort_order').execute();
        const amounts = splitStages(body.agreementValue, stages.map((s) => s.pct));
        for (const [i, s] of stages.entries()) await tx.updateTable('booking_stages').set({ amount: amounts[i]! }).where('id', '=', s.id).execute();
      }
      if (Object.keys(changes).length) {
        await tx.updateTable('bookings').set(changes).where('id', '=', id).execute();
        const after = (await loadBookings(tx, [id]))[0]!;
        await writeAudit(tx, auditOf(ctx), 'booking', id, 'update', old, after);
        return after;
      }
      return old;
    });
  });

  app.post<{ Params: { id: string } }>('/bookings/:id/agreement', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(agreementBody, req.body);
    return ctx.tx(async (tx) => {
      const b = await getBooking(tx, ctx, id, true);
      if (b.status !== 'booked') throw conflict('Only a booked unit can move to agreement.', 'CONFLICT');
      await tx.updateTable('bookings').set({ status: 'agreement', agreement_no: body.agreementNo, agreement_date: body.agreementDate })
        .where('id', '=', id).execute();
      await tx.updateTable('units').set({ status: 'agreement' }).where('id', '=', b.unit_id).execute();
      await writeAudit(tx, auditOf(ctx), 'booking', id, 'agreement', { status: 'booked' },
        { status: 'agreement', agreementNo: body.agreementNo, agreementDate: body.agreementDate });
      return (await loadBookings(tx, [id]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/bookings/:id/demands', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('bookings.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(demandBody, req.body);
    const demand = await ctx.tx(async (tx) => {
      const b = await getBooking(tx, ctx, id, true);
      if (b.status === 'cancelled') throw conflict('This booking is cancelled.', 'CONFLICT');
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Demand date cannot be in the future.', { date: 'In the future' });
      const dueDate = body.dueDate ?? addDays(date, 15);
      if (dueDate < date) throw badRequest('The due date is before the demand date.', { dueDate: 'Before the demand date' });

      const wanted = [...new Set(body.stageIds)];
      const stages = await tx.selectFrom('booking_stages').selectAll().where('booking_id', '=', id).where('id', 'in', wanted).execute();
      if (stages.length !== wanted.length) throw conflict('Some stages do not belong to this booking.', 'CONFLICT', { stageIds: 'Not in this booking' });
      const taken = stages.find((s) => s.demand_id !== null);
      if (taken) throw conflict(`Stage "${taken.name}" has already been demanded.`, 'CONFLICT', { stageIds: 'Already demanded' });

      const amountPaise = stages.reduce((s, x) => s + toPaise(x.amount), 0n);
      const amount = fromPaise(amountPaise);
      if (b.status === 'booked') {
        const open = await tx.selectFrom('demands').select((eb) => eb.fn.sum<number>('amount').as('s'))
          .where('booking_id', '=', id).where('status', '=', 'open').executeTakeFirstOrThrow();
        const demandedPaise = toPaise(Number(open.s ?? 0));
        const limitPaise = mulDivRound(toPaise(b.agreement_value), 10n, 100n);
        if (demandedPaise + amountPaise > limitPaise) {
          throw conflict('Before the agreement for sale is registered, at most 10% of the agreement value can be demanded (RERA s.13).',
            'AGREEMENT_REQUIRED');
        }
      }
      const half = gstHalf(amount, b.gst_pct);
      const total = fromPaise(amountPaise + toPaise(half) * 2n);
      const number = await nextNumber(tx, ctx, 'demand', financialYear(date));
      const row = await tx.insertInto('demands').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, booking_id: id, party_id: b.customer_party_id,
        demand_date: date, due_date: dueDate, amount, cgst: half, sgst: half, total, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.updateTable('booking_stages').set({ demand_id: row.id }).where('id', 'in', wanted).execute();

      const acc = await systemAccounts(tx, ctx);
      const loc = await projectSite(tx, b.project_id);
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'demand', voucherId: row.id, number, narration: `Demand ${number} for booking ${b.number}`,
        lines: [
          { accountId: acc.receivables, amount: total, partyId: b.customer_party_id, locationId: loc },
          { accountId: b.status === 'possession' ? acc.property_sales : acc.booking_advances, amount: -amount, locationId: loc },
          { accountId: acc.output_cgst, amount: -half, locationId: loc },
          { accountId: acc.output_sgst, amount: -half, locationId: loc },
        ],
      });
      const saved = (await loadDemands(tx, [row.id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'demand', row.id, 'create', null, { number, bookingId: id, amount, total });
      return saved;
    });
    return reply.status(201).send(demand);
  });

  app.post<{ Params: { id: string } }>('/bookings/:id/possession', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.manage');
    const id = parse(z.uuid(), req.params.id);
    const { date } = parse(possessionBody, req.body);
    return ctx.tx(async (tx) => {
      const b = await getBooking(tx, ctx, id, true);
      if (b.status !== 'agreement') throw conflict('Possession can be recorded only after the agreement.', 'CONFLICT');
      if (date > todayIst()) throw badRequest('Possession date cannot be in the future.', { date: 'In the future' });
      const undemanded = await tx.selectFrom('booking_stages').select('name').where('booking_id', '=', id).where('demand_id', 'is', null).executeTakeFirst();
      if (undemanded) throw conflict(`Stage "${undemanded.name}" has not been demanded yet.`, 'CONFLICT');
      const open = await tx.selectFrom('demands').select((eb) => eb.fn.sum<number>('amount').as('s'))
        .where('booking_id', '=', id).where('status', '=', 'open').executeTakeFirstOrThrow();
      const amount = Number(open.s ?? 0);
      const acc = await systemAccounts(tx, ctx);
      const loc = await projectSite(tx, b.project_id);
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'possession', voucherId: id, number: b.number, narration: `Possession of ${b.number}`,
        lines: [
          { accountId: acc.booking_advances, amount, locationId: loc },
          { accountId: acc.property_sales, amount: -amount, locationId: loc },
        ],
      });
      await tx.updateTable('bookings').set({ status: 'possession', possession_date: date }).where('id', '=', id).execute();
      await tx.updateTable('units').set({ status: 'possession' }).where('id', '=', b.unit_id).execute();
      await writeAudit(tx, auditOf(ctx), 'booking', id, 'possession', { status: 'agreement' }, { status: 'possession', date });
      return (await loadBookings(tx, [id]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/bookings/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(reasonBody, req.body);
    return ctx.tx(async (tx) => {
      const b = await getBooking(tx, ctx, id, true);
      if (b.status !== 'booked' && b.status !== 'agreement') throw conflict('Only a booked or agreement booking can be cancelled.', 'CONFLICT');
      const open = await tx.selectFrom('demands').selectAll().where('booking_id', '=', id).where('status', '=', 'open').forUpdate().execute();
      if (open.some((d) => d.amount_paid > 0)) {
        throw conflict('Receipts are allocated to this booking. Cancel or reallocate them first.', 'HAS_SETTLEMENTS');
      }
      for (const d of open) {
        await tx.updateTable('demands').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: `Booking cancelled: ${reason}` })
          .where('id', '=', d.id).execute();
        await reverseVoucher(tx, auditOf(ctx), d.id, todayIst(), `Cancelled ${d.number}: booking cancelled`);
        await writeAudit(tx, auditOf(ctx), 'demand', d.id, 'cancel', { status: 'open' }, { status: 'cancelled', reason });
      }
      await tx.updateTable('bookings').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await tx.updateTable('units').set({ status: 'available' }).where('id', '=', b.unit_id).execute();
      await writeAudit(tx, auditOf(ctx), 'booking', id, 'cancel', { status: b.status }, { status: 'cancelled', reason });
      return (await loadBookings(tx, [id]))[0];
    });
  });

  // Demands ------------------------------------------------------------------------------------

  app.get('/demands', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.view');
    const q = parse(demandListQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('demands as d')
        .innerJoin('bookings as b', 'b.id', 'd.booking_id').innerJoin('units as u', 'u.id', 'b.unit_id')
        .innerJoin('parties as p', 'p.id', 'd.party_id')
        .where('d.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) {
        base = base.where((eb) => eb.exists(eb.selectFrom('locations as s').select('s.id')
          .whereRef('s.project_id', '=', 'b.project_id').where('s.id', 'in', scope)));
      }
      if (q.bookingId) base = base.where('d.booking_id', '=', q.bookingId);
      if (q.projectId) base = base.where('b.project_id', '=', q.projectId);
      if (q.customerId) base = base.where('d.party_id', '=', q.customerId);
      if (q.status) base = base.where('d.status', '=', q.status);
      if (q.from) base = base.where('d.demand_date', '>=', q.from);
      if (q.to) base = base.where('d.demand_date', '<=', q.to);
      if (q.paymentStatus === 'paid') base = base.where('d.status', '=', 'open').whereRef('d.amount_paid', '>=', 'd.total');
      if (q.paymentStatus === 'partial') base = base.where('d.status', '=', 'open').where('d.amount_paid', '>', 0).whereRef('d.amount_paid', '<', 'd.total');
      if (q.paymentStatus === 'unpaid') base = base.where('d.status', '=', 'open').where('d.amount_paid', '=', 0).where('d.total', '>', 0);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('d.number', 'ilike', t), eb('u.code', 'ilike', t), eb('p.name', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('d.id').orderBy('d.demand_date', 'desc').orderBy('d.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadDemands(tx, ids.map((r) => r.id)), total };
    });
  });

  app.get<{ Params: { id: string } }>('/demands/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const d = await tx.selectFrom('demands').select(['id', 'booking_id']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!d) throw notFound('Demand');
      await getBooking(tx, ctx, d.booking_id);
      return (await loadDemands(tx, [id]))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/demands/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(reasonBody, req.body);
    return ctx.tx(async (tx) => {
      const d = await tx.selectFrom('demands').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!d) throw notFound('Demand');
      const b = await getBooking(tx, ctx, d.booking_id, true);
      if (d.status === 'cancelled') throw conflict('This demand is already cancelled.', 'ALREADY_CANCELLED');
      if (d.amount_paid > 0) throw conflict('Receipts are allocated to this demand. Cancel them first.', 'HAS_SETTLEMENTS');
      if (b.status === 'possession') throw conflict('The unit has been handed over; this demand cannot be cancelled.', 'CONFLICT');
      await tx.updateTable('demands').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await tx.updateTable('booking_stages').set({ demand_id: null }).where('demand_id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${d.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'demand', id, 'cancel', { status: 'open' }, { status: 'cancelled', reason });
      return (await loadDemands(tx, [id]))[0];
    });
  });

  // RERA ---------------------------------------------------------------------------------------

  app.get<{ Params: { id: string } }>('/projects/:id/rera', async (req) => {
    const ctx = req.ctx;
    ctx.require('bookings.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(reraQuery, req.query);
    const to = q.to ?? todayIst();
    return ctx.tx(async (tx) => {
      const project = await getProject(tx, ctx, id);
      const allocs = await tx.selectFrom('payment_allocations as a')
        .innerJoin('payments as p', 'p.id', 'a.payment_id')
        .innerJoin('demands as d', 'd.id', 'a.doc_id')
        .innerJoin('bookings as b', 'b.id', 'd.booking_id')
        .select(['a.amount', 'd.cgst', 'd.sgst', 'd.total'])
        .where('a.doc_type', '=', 'demand').where('b.project_id', '=', id)
        .where('p.status', '=', 'posted').where('p.payment_date', '<=', to).execute();
      const collections = round2(allocs.reduce((s, a) => s + (a.amount - (a.total > 0 ? round2((a.amount * (a.cgst + a.sgst)) / a.total) : 0)), 0));
      let deposited = 0, withdrawn = 0, accountName: string | null = null;
      if (project.rera_account_id) {
        const acc = await tx.selectFrom('accounts').select('name').where('id', '=', project.rera_account_id).executeTakeFirst();
        accountName = acc?.name ?? null;
        const sums = await tx.selectFrom('journal_lines as l').innerJoin('journal_entries as e', 'e.id', 'l.entry_id')
          .select([sql<number>`coalesce(sum(l.debit), 0)`.as('dr'), sql<number>`coalesce(sum(l.credit), 0)`.as('cr')])
          .where('l.account_id', '=', project.rera_account_id).where('e.entry_date', '<=', to).executeTakeFirstOrThrow();
        deposited = round2(Number(sums.dr));
        withdrawn = round2(Number(sums.cr));
      }
      const required = round2(collections * 0.7);
      return {
        projectId: id, reraRegNo: project.rera_reg_no, reraAccountId: project.rera_account_id, reraAccountName: accountName, to,
        collections, required, deposited, withdrawn, balance: round2(deposited - withdrawn),
        shortfall: round2(Math.max(0, required - deposited)),
      };
    });
  });
}
