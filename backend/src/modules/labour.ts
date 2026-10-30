import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';

const TRADES = [
  'mason', 'carpenter', 'bar_bender', 'helper', 'electrician',
  'plumber', 'painter', 'welder', 'operator', 'other',
] as const;
const SKILLS = ['unskilled', 'semi_skilled', 'skilled', 'highly_skilled'] as const;
const ATTENDANCE_STATUSES = ['present', 'half_day', 'absent'] as const;
const WAGE_STATUSES = ['draft', 'approved', 'paid', 'cancelled'] as const;

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const blankToNull = (v: unknown) => (v === '' ? null : v);
const nullableUuid = z.preprocess(blankToNull, z.uuid().nullable().optional());
const nullableDate = z.preprocess(blankToNull, dateField.nullable().optional());
const round2 = (n: number) => Math.round(n * 100) / 100;

/**
 * Wage maths in integer paise, rounded half-up like GST:
 * basic = presentDays × dailyRate; otAmount = otHours × dailyRate ÷ 8 × 2.
 * (Plain floating point would give, for example, 0.5 × 300.03 = 150.01 instead of 150.02.)
 */
export function wageAmounts(dailyRate: number, presentDays: number, otHours: number) {
  const rate = BigInt(Math.round(dailyRate * 100));
  const halfDays = BigInt(Math.round(presentDays * 2));
  const centiHours = BigInt(Math.round(otHours * 100));
  const basic = (halfDays * rate + 1n) / 2n;
  const otAmount = (centiHours * rate + 200n) / 400n;
  return { basic: Number(basic) / 100, otAmount: Number(otAmount) / 100, gross: Number(basic + otAmount) / 100 };
}

const workerCreateBody = z.object({
  name: z.string().trim().min(1, 'Required').max(200),
  phone: optionalText(20),
  trade: z.enum(TRADES),
  skill: z.enum(SKILLS).default('unskilled'),
  dailyRate: moneyField,
  contractorPartyId: nullableUuid,
  siteId: nullableUuid,
  aadhaarLast4: z.preprocess(
    blankToNull,
    z.string().trim().regex(/^\d{4}$/, 'Use the last 4 digits').nullable().optional(),
  ),
  bocwRegNo: optionalText(80),
  photoFileId: nullableUuid,
  joinedOn: nullableDate,
});
const workerPatchBody = z.object({
  name: z.string().trim().min(1, 'Required').max(200).optional(),
  phone: nullableText(20),
  trade: z.enum(TRADES).optional(),
  skill: z.enum(SKILLS).optional(),
  dailyRate: moneyField.optional(),
  contractorPartyId: nullableUuid,
  siteId: nullableUuid,
  aadhaarLast4: z.preprocess(
    blankToNull,
    z.string().trim().regex(/^\d{4}$/, 'Use the last 4 digits').nullable().optional(),
  ),
  bocwRegNo: nullableText(80),
  photoFileId: nullableUuid,
  joinedOn: nullableDate,
  isActive: z.boolean().optional(),
});

const workerListQuery = pagingQuery.extend({
  siteId: z.uuid().optional(),
  contractorId: z.uuid().optional(),
  trade: z.enum(TRADES).optional(),
  activeOnly: z.enum(['true', 'false']).optional(),
});
const attendanceQuery = z.object({ siteId: z.uuid(), date: dateField });
const attendanceBody = z.object({
  siteId: z.uuid(),
  date: docDate,
  entries: z.array(z.object({
    workerId: z.uuid(),
    status: z.enum(ATTENDANCE_STATUSES),
    otHours: z.number().min(0).max(24).refine(
      (v) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-6,
      'At most 2 decimals',
    ).optional(),
  })).max(10_000),
});
const wageListQuery = pagingQuery.extend({
  siteId: z.uuid().optional(),
  status: z.enum(WAGE_STATUSES).optional(),
});
const createWageBody = z.object({ siteId: z.uuid(), from: dateField, to: dateField });
const patchWageBody = z.object({
  rows: z.array(z.object({ workerId: z.uuid(), advance: moneyField })).max(10_000),
});
const payWageBody = z.object({ paidFromAccountId: z.uuid(), date: dateField.optional() });
const cancelWageBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });

/** Serialises attendance and wage-period changes for one company/site. */
async function lockSite(tx: Tx, ctx: RequestContext, siteId: string): Promise<void> {
  await sql`select pg_advisory_xact_lock(hashtextextended(${`${ctx.companyId}:labour:${siteId}`}, 0))`
    .execute(tx);
}

/** A location used for workers, attendance and wages must be an active site. */
async function requireSite(tx: Tx, ctx: RequestContext, id: string) {
  const location = await getLocation(tx, ctx, id);
  if (location.type !== 'site') {
    throw badRequest('Choose a site.', { siteId: 'Not a site' });
  }
  if (!location.is_active) {
    throw badRequest('This site is inactive.', { siteId: 'Inactive site' });
  }
  return location;
}

async function loadWorkerRows(tx: Tx, ctx: RequestContext, ids: string[]) {
  if (!ids.length) return [];
  return tx.selectFrom('workers as w')
    .leftJoin('locations as l', 'l.id', 'w.site_id')
    .leftJoin('parties as p', 'p.id', 'w.contractor_party_id')
    .select([
      'w.id', 'w.name', 'w.phone', 'w.trade', 'w.skill', 'w.daily_rate',
      'w.contractor_party_id', 'w.site_id', 'w.aadhaar_last4', 'w.bocw_reg_no',
      'w.photo_file_id', 'w.joined_on', 'w.is_active', 'w.created_at',
      'l.name as site_name', 'p.name as contractor_name',
      sql<number>`coalesce((select sum(a.amount - a.recovered) from labour_advances a where a.worker_id = w.id and a.status = 'open'), 0)::float8`.as('advance_balance'),
    ])
    .where('w.id', 'in', ids).where('w.company_id', '=', ctx.companyId)
    .execute();
}

function workerJson(w: Awaited<ReturnType<typeof loadWorkerRows>>[number]) {
  return {
    id: w.id, name: w.name, phone: w.phone, trade: w.trade, skill: w.skill,
    dailyRate: w.daily_rate, contractorPartyId: w.contractor_party_id,
    contractorName: w.contractor_name, siteId: w.site_id, siteName: w.site_name,
    aadhaarLast4: w.aadhaar_last4, bocwRegNo: w.bocw_reg_no,
    photoFileId: w.photo_file_id, joinedOn: w.joined_on, isActive: w.is_active,
    createdAt: w.created_at, advanceBalance: round2(w.advance_balance),
  };
}

/** Open labour-advance balance (Σ amount − recovered of open advances) per worker. */
async function advanceBalances(tx: Tx, workerIds: string[]): Promise<Map<string, number>> {
  const map = new Map<string, number>();
  if (!workerIds.length) return map;
  const rows = await tx.selectFrom('labour_advances').select(['worker_id', 'amount', 'recovered'])
    .where('worker_id', 'in', workerIds).where('status', '=', 'open').execute();
  for (const r of rows) map.set(r.worker_id, round2((map.get(r.worker_id) ?? 0) + r.amount - r.recovered));
  return map;
}

/** Deductions may not exceed 50% of gross wages (Code on Wages) nor the open advance balance. */
function advanceCap(gross: number, balance: number): number {
  return Math.min(balance, Math.floor(Math.round(gross * 100) / 2) / 100);
}

/** Worker visibility follows the worker's home site, not a project or wage sheet. */
function canSeeWorker(ctx: RequestContext, worker: { site_id: string | null }): boolean {
  const scope = scopedLocationIds(ctx);
  return scope === null || (worker.site_id !== null && scope.includes(worker.site_id));
}

async function validateWorkerRefs(
  tx: Tx,
  ctx: RequestContext,
  body: { contractorPartyId?: string | null; siteId?: string | null; photoFileId?: string | null },
): Promise<void> {
  if (body.contractorPartyId) {
    const contractor = await tx.selectFrom('parties').select(['id', 'type'])
      .where('id', '=', body.contractorPartyId).where('company_id', '=', ctx.companyId)
      .executeTakeFirst();
    if (!contractor || (contractor.type !== 'vendor' && contractor.type !== 'both')) {
      throw badRequest('Choose a labour contractor.', { contractorPartyId: 'Not a contractor' });
    }
  }
  if (body.siteId) await requireSite(tx, ctx, body.siteId);
  if (body.photoFileId) {
    const file = await tx.selectFrom('files').select(['id', 'mime_type'])
      .where('id', '=', body.photoFileId).where('company_id', '=', ctx.companyId)
      .executeTakeFirst();
    if (!file || !['image/jpeg', 'image/png', 'image/webp'].includes(file.mime_type)) {
      throw badRequest('Choose a JPEG, PNG or WebP worker photo.', { photoFileId: 'Not an image' });
    }
  }
}

/** Workers visible to a scoped caller have a home site in that caller's scope. */
function workerScope(ctx: RequestContext): string[] | null {
  return scopedLocationIds(ctx);
}

async function loadAttendance(tx: Tx, ctx: RequestContext, siteId: string, date: string) {
  const workers = await tx.selectFrom('workers as w')
    .leftJoin('attendance as a', (join) => join
      .onRef('a.worker_id', '=', 'w.id')
      .on('a.att_date', '=', date)
      .on('a.site_id', '=', siteId))
    .leftJoin('parties as p', 'p.id', 'w.contractor_party_id')
    .select([
      'w.id as worker_id', 'w.name as worker_name', 'w.trade', 'w.is_active',
      'p.name as contractor_name', 'a.status', 'a.ot_hours',
    ])
    .where('w.company_id', '=', ctx.companyId)
    .where((eb) => eb.or([
      eb.and([eb('w.site_id', '=', siteId), eb('w.is_active', '=', true)]),
      eb('a.id', 'is not', null),
    ]))
    .orderBy('w.name')
    .execute();
  const locked = await tx.selectFrom('wage_sheets')
    .select('id')
    .where('company_id', '=', ctx.companyId).where('site_id', '=', siteId)
    .where('status', 'in', ['approved', 'paid'])
    .where('from_date', '<=', date).where('to_date', '>=', date)
    .executeTakeFirst();
  return {
    siteId,
    date,
    locked: !!locked,
    rows: workers.map((w) => ({
      workerId: w.worker_id,
      workerName: w.worker_name,
      trade: w.trade,
      contractorName: w.contractor_name,
      status: w.status ?? null,
      otHours: w.ot_hours ?? 0,
    })),
  };
}

async function ensureAttendanceUnlocked(tx: Tx, siteId: string, date: string): Promise<void> {
  const locked = await tx.selectFrom('wage_sheets').select('id')
    .where('site_id', '=', siteId)
    .where('status', 'in', ['approved', 'paid'])
    .where('from_date', '<=', date).where('to_date', '>=', date)
    .executeTakeFirst();
  if (locked) throw conflict('Attendance is locked by an approved wage sheet.', 'LOCKED');
}

async function loadWageSheets(tx: Tx, ids: string[], includeRows: boolean) {
  if (!ids.length) return [];
  const sheets = await tx.selectFrom('wage_sheets as w')
    .innerJoin('locations as l', 'l.id', 'w.site_id')
    .innerJoin('users as u', 'u.id', 'w.created_by')
    .selectAll('w')
    .select(['l.name as site_name', 'u.name as created_by_name'])
    .where('w.id', 'in', ids)
    .execute();
  const rows = includeRows
    ? await tx.selectFrom('wage_sheet_rows as r')
      .innerJoin('workers as w', 'w.id', 'r.worker_id')
      .leftJoin('parties as p', 'p.id', 'w.contractor_party_id')
      .select([
        'r.id', 'r.wage_sheet_id', 'r.worker_id', 'w.name as worker_name', 'w.trade',
        'p.name as contractor_name', 'r.daily_rate', 'r.present_days', 'r.ot_hours',
        'r.basic', 'r.ot_amount', 'r.gross', 'r.advance', 'r.net',
      ])
      .where('r.wage_sheet_id', 'in', ids)
      .orderBy('w.name')
      .execute()
    : [];
  const balances = await advanceBalances(tx, [...new Set(rows.map((r) => r.worker_id))]);
  return sheets.map((sheet) => ({
    id: sheet.id,
    number: sheet.number,
    siteId: sheet.site_id,
    siteName: sheet.site_name,
    from: sheet.from_date,
    to: sheet.to_date,
    status: sheet.status,
    totalGross: sheet.total_gross,
    totalDeductions: sheet.total_deductions,
    totalNet: sheet.total_net,
    paidFromAccountId: sheet.paid_from_account_id,
    paidAt: sheet.paid_at,
    createdAt: sheet.created_at,
    createdBy: { id: sheet.created_by, name: sheet.created_by_name },
    ...(includeRows ? {
      rows: rows.filter((r) => r.wage_sheet_id === sheet.id).map((r) => ({
        workerId: r.worker_id,
        workerName: r.worker_name,
        trade: r.trade,
        contractorName: r.contractor_name,
        dailyRate: r.daily_rate,
        presentDays: r.present_days,
        otHours: r.ot_hours,
        basic: r.basic,
        otAmount: r.ot_amount,
        gross: r.gross,
        advance: r.advance,
        advanceBalance: balances.get(r.worker_id) ?? 0,
        net: r.net,
      })),
    } : {}),
  }));
}

async function getWageSheet(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let query = tx.selectFrom('wage_sheets').selectAll()
    .where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) query = query.forUpdate();
  const sheet = await query.executeTakeFirst();
  if (!sheet || !ctx.canAccessLocation(sheet.site_id)) throw notFound('Wage sheet');
  return sheet;
}

/** Rebuilds wage rows from attendance while keeping draft advances. */
async function recomputeWageSheet(tx: Tx, ctx: RequestContext, sheetId: string): Promise<void> {
  const sheet = await tx.selectFrom('wage_sheets').selectAll()
    .where('id', '=', sheetId).where('company_id', '=', ctx.companyId)
    .executeTakeFirstOrThrow();
  const attendance = await tx.selectFrom('attendance as a')
    .innerJoin('workers as w', 'w.id', 'a.worker_id')
    .select([
      'a.worker_id', 'a.status', 'a.ot_hours', 'w.daily_rate', 'w.name',
    ])
    .where('a.site_id', '=', sheet.site_id)
    .where('a.att_date', '>=', sheet.from_date).where('a.att_date', '<=', sheet.to_date)
    .execute();
  const existing = await tx.selectFrom('wage_sheet_rows').select(['worker_id', 'advance'])
    .where('wage_sheet_id', '=', sheetId).execute();
  const advances = new Map(existing.map((r) => [r.worker_id, r.advance]));
  const balances = await advanceBalances(tx, [...new Set(attendance.map((a) => a.worker_id))]);
  const byWorker = new Map<string, {
    workerId: string; dailyRate: number; presentDays: number; otHours: number;
  }>();
  for (const row of attendance) {
    const value = byWorker.get(row.worker_id) ?? {
      workerId: row.worker_id, dailyRate: row.daily_rate, presentDays: 0, otHours: 0,
    };
    if (row.status === 'present') value.presentDays += 1;
    else if (row.status === 'half_day') value.presentDays += 0.5;
    value.otHours = round2(value.otHours + row.ot_hours);
    byWorker.set(row.worker_id, value);
  }
  await tx.deleteFrom('wage_sheet_rows').where('wage_sheet_id', '=', sheetId).execute();
  let totalGross = 0;
  let totalDeductions = 0;
  let totalNet = 0;
  const values = [...byWorker.values()].map((row) => {
    const { basic, otAmount, gross } = wageAmounts(row.dailyRate, row.presentDays, row.otHours);
    // Default: as much of the open advance as the 50% cap allows. An edited advance stays while it is within the cap.
    const cap = advanceCap(gross, balances.get(row.workerId) ?? 0);
    const kept = advances.get(row.workerId);
    const advance = round2(kept !== undefined && kept <= cap + 0.004 ? kept : cap);
    const net = round2(gross - advance);
    totalGross = round2(totalGross + gross);
    totalDeductions = round2(totalDeductions + advance);
    totalNet = round2(totalNet + net);
    return {
      tenant_id: ctx.tenantId, wage_sheet_id: sheetId, worker_id: row.workerId,
      daily_rate: row.dailyRate, present_days: row.presentDays, ot_hours: row.otHours,
      basic, ot_amount: otAmount, gross, advance, net,
    };
  });
  if (values.length) await tx.insertInto('wage_sheet_rows').values(values).execute();
  await tx.updateTable('wage_sheets').set({
    total_gross: totalGross, total_deductions: totalDeductions, total_net: totalNet,
  }).where('id', '=', sheetId).execute();
}

async function updateWageTotals(tx: Tx, sheetId: string): Promise<void> {
  const rows = await tx.selectFrom('wage_sheet_rows')
    .select((eb) => [
      eb.fn.sum<number>('gross').as('gross'),
      eb.fn.sum<number>('advance').as('advance'),
      eb.fn.sum<number>('net').as('net'),
    ])
    .where('wage_sheet_id', '=', sheetId)
    .groupBy('wage_sheet_id')
    .executeTakeFirst();
  await tx.updateTable('wage_sheets').set({
    total_gross: round2(rows?.gross ?? 0),
    total_deductions: round2(rows?.advance ?? 0),
    total_net: round2(rows?.net ?? 0),
  }).where('id', '=', sheetId).execute();
}

export async function labourRoutes(app: FastifyInstance) {
  app.get('/workers', async (req) => {
    const ctx = req.ctx;
    ctx.require('labour.view');
    const q = parse(workerListQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('workers as w').where('w.company_id', '=', ctx.companyId);
      const scope = workerScope(ctx);
      if (scope) base = base.where('w.site_id', 'in', scope);
      if (q.siteId) base = base.where('w.site_id', '=', q.siteId);
      if (q.contractorId) base = base.where('w.contractor_party_id', '=', q.contractorId);
      if (q.trade) base = base.where('w.trade', '=', q.trade);
      if (q.activeOnly === 'true') base = base.where('w.is_active', '=', true);
      if (q.q) {
        const term = likeTerm(q.q);
        base = base.where((eb) => eb.or([
          eb('w.name', 'ilike', term),
          eb('w.phone', 'ilike', term),
          eb('w.bocw_reg_no', 'ilike', term),
        ]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('w.id').orderBy('w.name').limit(q.limit).offset(q.offset).execute();
      return { data: (await loadWorkerRows(tx, ctx, ids.map((r) => r.id))).map(workerJson), total };
    });
  });

  app.get<{ Params: { id: string } }>('/workers/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('labour.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const worker = (await loadWorkerRows(tx, ctx, [id]))[0];
      if (!worker || !canSeeWorker(ctx, worker)) throw notFound('Worker');
      return workerJson(worker);
    });
  });

  app.post('/workers', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('labour.manage');
    const body = parse(workerCreateBody, req.body);
    const worker = await ctx.tx(async (tx) => {
      if (!body.siteId && workerScope(ctx)) {
        throw badRequest('Select a home site in your location scope.', { siteId: 'Required' });
      }
      await validateWorkerRefs(tx, ctx, body);
      const row = await tx.insertInto('workers').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: body.name, phone: body.phone ?? null,
        trade: body.trade, skill: body.skill, daily_rate: body.dailyRate,
        contractor_party_id: body.contractorPartyId ?? null, site_id: body.siteId ?? null,
        aadhaar_last4: body.aadhaarLast4 ?? null, bocw_reg_no: body.bocwRegNo ?? null,
        photo_file_id: body.photoFileId ?? null, joined_on: body.joinedOn ?? null,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'worker', row.id, 'create', null, body);
      return (await loadWorkerRows(tx, ctx, [row.id]))[0]!;
    });
    return reply.status(201).send(workerJson(worker));
  });

  app.patch<{ Params: { id: string } }>('/workers/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('labour.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(workerPatchBody, req.body);
    return ctx.tx(async (tx) => {
      const before = (await loadWorkerRows(tx, ctx, [id]))[0];
      if (!before || !canSeeWorker(ctx, before)) throw notFound('Worker');
      if (body.siteId === null && workerScope(ctx)) {
        throw badRequest('Select a home site in your location scope.', { siteId: 'Required' });
      }
      await validateWorkerRefs(tx, ctx, body);
      const changes = Object.fromEntries(Object.entries({
        name: body.name, phone: body.phone, trade: body.trade, skill: body.skill,
        daily_rate: body.dailyRate, contractor_party_id: body.contractorPartyId,
        site_id: body.siteId, aadhaar_last4: body.aadhaarLast4,
        bocw_reg_no: body.bocwRegNo, photo_file_id: body.photoFileId,
        joined_on: body.joinedOn, is_active: body.isActive,
      }).filter(([, value]) => value !== undefined));
      if (!Object.keys(changes).length) return workerJson(before);
      await tx.updateTable('workers').set(changes).where('id', '=', id).execute();
      const after = (await loadWorkerRows(tx, ctx, [id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'worker', id, 'update', before, after);
      return workerJson(after);
    });
  });

  app.get('/attendance', async (req) => {
    const ctx = req.ctx;
    ctx.require('labour.view');
    const q = parse(attendanceQuery, req.query);
    return ctx.tx(async (tx) => {
      await requireSite(tx, ctx, q.siteId);
      return loadAttendance(tx, ctx, q.siteId, q.date);
    });
  });

  app.put('/attendance', async (req) => {
    const ctx = req.ctx;
    ctx.require('attendance.mark');
    const body = parse(attendanceBody, req.body);
    if (body.date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
    return ctx.tx(async (tx) => {
      await requireSite(tx, ctx, body.siteId);
      await lockSite(tx, ctx, body.siteId);
      await ensureAttendanceUnlocked(tx, body.siteId, body.date);
      const ids = [...new Set(body.entries.map((entry) => entry.workerId))];
      if (ids.length) {
        const existing = await tx.selectFrom('attendance').select(['worker_id', 'site_id'])
          .where('worker_id', 'in', ids).where('att_date', '=', body.date).execute();
        const existingByWorker = new Map(existing.map((row) => [row.worker_id, row.site_id]));
        for (const id of ids) {
          if (existingByWorker.has(id) && existingByWorker.get(id) !== body.siteId) {
            throw conflict('This worker is already marked at another site on that date.', 'CONFLICT');
          }
        }
        const workers = await tx.selectFrom('workers').select(['id', 'site_id'])
          .where('id', 'in', ids).where('company_id', '=', ctx.companyId).execute();
        const byId = new Map(workers.map((worker) => [worker.id, worker]));
        body.entries.forEach((entry, index) => {
          const worker = byId.get(entry.workerId);
          if (!worker || worker.site_id !== body.siteId) {
            throw badRequest('A worker can be marked only at their home site.', {
              [`entries.${index}.workerId`]: 'Not a worker at this site',
            });
          }
        });
      }
      for (const entry of body.entries) {
        const otHours = entry.status === 'absent' ? 0 : entry.otHours ?? 0;
        await tx.insertInto('attendance').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, site_id: body.siteId,
          worker_id: entry.workerId, att_date: body.date, status: entry.status,
          ot_hours: otHours, marked_by: ctx.userId, marked_at: new Date(),
        }).onConflict((oc) => oc.columns(['worker_id', 'att_date']).doUpdateSet({
          site_id: body.siteId, status: entry.status, ot_hours: otHours,
          marked_by: ctx.userId, marked_at: new Date(),
        })).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'attendance', null, 'mark', null, {
        siteId: body.siteId, date: body.date, entries: body.entries,
      });
      return loadAttendance(tx, ctx, body.siteId, body.date);
    });
  });

  app.get('/wage-sheets', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.view');
    const q = parse(wageListQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('wage_sheets as w').where('w.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('w.site_id', 'in', scope);
      if (q.siteId) base = base.where('w.site_id', '=', q.siteId);
      if (q.status) base = base.where('w.status', '=', q.status);
      if (q.q) base = base.where('w.number', 'ilike', likeTerm(q.q));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('w.id').orderBy('w.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadWageSheets(tx, ids.map((r) => r.id), false), total };
    });
  });

  app.get<{ Params: { id: string } }>('/wage-sheets/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const sheet = await getWageSheet(tx, ctx, id);
      return (await loadWageSheets(tx, [sheet.id], true))[0];
    });
  });

  app.post('/wage-sheets', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('wages.manage');
    const body = parse(createWageBody, req.body);
    if (body.from > body.to) throw badRequest('The start date is after the end date.', { from: 'After to' });
    if (body.to > todayIst()) throw badRequest('The end date cannot be in the future.', { to: 'In the future' });
    const sheet = await ctx.tx(async (tx) => {
      await requireSite(tx, ctx, body.siteId);
      await lockSite(tx, ctx, body.siteId);
      const overlap = await tx.selectFrom('wage_sheets').select(['id', 'number'])
        .where('company_id', '=', ctx.companyId).where('site_id', '=', body.siteId)
        .where('status', '!=', 'cancelled')
        .where('from_date', '<=', body.to).where('to_date', '>=', body.from)
        .executeTakeFirst();
      if (overlap) {
        throw conflict(`This period overlaps wage sheet ${overlap.number}.`, 'CONFLICT', {
          from: 'Overlaps an existing wage sheet', to: 'Overlaps an existing wage sheet',
        });
      }
      const number = await nextNumber(tx, ctx, 'wage_sheet', financialYear(body.to));
      const row = await tx.insertInto('wage_sheets').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, site_id: body.siteId,
        from_date: body.from, to_date: body.to, status: 'draft', created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await recomputeWageSheet(tx, ctx, row.id);
      await writeAudit(tx, auditOf(ctx), 'wage_sheet', row.id, 'create', null, {
        number, siteId: body.siteId, from: body.from, to: body.to,
      });
      return (await loadWageSheets(tx, [row.id], true))[0]!;
    });
    return reply.status(201).send(sheet);
  });

  app.patch<{ Params: { id: string } }>('/wage-sheets/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patchWageBody, req.body);
    return ctx.tx(async (tx) => {
      const sheet = await getWageSheet(tx, ctx, id, true);
      if (sheet.status !== 'draft') throw conflict('Only draft wage sheets can be edited.', 'CONFLICT');
      await lockSite(tx, ctx, sheet.site_id);
      const rows = await tx.selectFrom('wage_sheet_rows').selectAll()
        .where('wage_sheet_id', '=', id).execute();
      const byWorker = new Map(rows.map((row) => [row.worker_id, row]));
      const balances = await advanceBalances(tx, rows.map((r) => r.worker_id));
      const seen = new Set<string>();
      for (const input of body.rows) {
        if (seen.has(input.workerId)) throw badRequest('A worker can appear only once.', { rows: 'Duplicate worker' });
        seen.add(input.workerId);
        const row = byWorker.get(input.workerId);
        if (!row) throw badRequest('This worker is not in the wage sheet.', { rows: 'Unknown worker' });
        const cap = advanceCap(row.gross, balances.get(row.worker_id) ?? 0);
        if (input.advance > cap + 0.004) {
          throw badRequest(`Advance recovery is limited to ₹${cap} (the lower of the open advance and 50% of gross).`, {
            rows: 'Advance exceeds the open balance or 50% of gross',
          });
        }
      }
      for (const input of body.rows) {
        const row = byWorker.get(input.workerId)!;
        await tx.updateTable('wage_sheet_rows').set({
          advance: input.advance, net: round2(row.gross - input.advance),
        }).where('id', '=', row.id).execute();
      }
      await updateWageTotals(tx, id);
      await writeAudit(tx, auditOf(ctx), 'wage_sheet', id, 'update', { status: 'draft' }, body);
      return (await loadWageSheets(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/wage-sheets/:id/recompute', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const sheet = await getWageSheet(tx, ctx, id, true);
      if (sheet.status !== 'draft') throw conflict('Only draft wage sheets can be recomputed.', 'CONFLICT');
      await lockSite(tx, ctx, sheet.site_id);
      await recomputeWageSheet(tx, ctx, id);
      await writeAudit(tx, auditOf(ctx), 'wage_sheet', id, 'recompute', null, null);
      return (await loadWageSheets(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/wage-sheets/:id/approve', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const sheet = await getWageSheet(tx, ctx, id, true);
      if (sheet.status !== 'draft') throw conflict('Only draft wage sheets can be approved.', 'CONFLICT');
      await lockSite(tx, ctx, sheet.site_id);
      await recomputeWageSheet(tx, ctx, id);
      await tx.updateTable('wage_sheets').set({
        status: 'approved', approved_by: ctx.userId, approved_at: new Date(),
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'wage_sheet', id, 'approve', { status: 'draft' }, { status: 'approved' });
      return (await loadWageSheets(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/wage-sheets/:id/pay', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.pay');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(payWageBody, req.body);
    const date = body.date ?? todayIst();
    if (date > todayIst()) throw badRequest('Payment date cannot be in the future.', { date: 'In the future' });
    return ctx.tx(async (tx) => {
      const sheet = await getWageSheet(tx, ctx, id, true);
      if (sheet.status !== 'approved') throw conflict('Only approved wage sheets can be paid.', 'CONFLICT');
      const account = await tx.selectFrom('accounts').selectAll()
        .where('id', '=', body.paidFromAccountId).where('company_id', '=', ctx.companyId)
        .executeTakeFirst();
      if (!account || !account.is_active || account.type !== 'asset' ||
          (account.subtype !== 'cash' && account.subtype !== 'bank')) {
        throw badRequest('Choose an active cash or bank account.', { paidFromAccountId: 'Not a cash or bank account' });
      }
      const rows = await tx.selectFrom('wage_sheet_rows').selectAll()
        .where('wage_sheet_id', '=', id).execute();
      const gross = round2(rows.reduce((sum, row) => sum + row.gross, 0));
      const advances = round2(rows.reduce((sum, row) => sum + row.advance, 0));
      const net = round2(rows.reduce((sum, row) => sum + row.net, 0));
      if (gross <= 0) throw badRequest('This wage sheet has no wages to pay.', { paidFromAccountId: 'No wages to pay' });
      if (net < 0) throw badRequest('Advance recovery exceeds gross wages.', { paidFromAccountId: 'Invalid net wages' });
      // Recover advances oldest first; a balance that dropped since approval blocks payment.
      for (const row of rows) {
        let left = row.advance;
        if (left <= 0) continue;
        const open = await tx.selectFrom('labour_advances').selectAll()
          .where('worker_id', '=', row.worker_id).where('status', '=', 'open')
          .orderBy('advance_date').orderBy('created_at').forUpdate().execute();
        const available = round2(open.reduce((sum, a) => sum + a.amount - a.recovered, 0));
        if (available + 0.004 < left) {
          throw conflict('A worker\'s advance balance is lower than the recovery on this wage sheet. Recompute the sheet.', 'CONFLICT');
        }
        for (const a of open) {
          if (left <= 0) break;
          const take = round2(Math.min(left, a.amount - a.recovered));
          if (take <= 0) continue;
          const recovered = round2(a.recovered + take);
          await tx.updateTable('labour_advances').set({
            recovered, status: recovered >= a.amount - 0.004 ? 'recovered' : 'open',
          }).where('id', '=', a.id).execute();
          await tx.insertInto('labour_advance_recoveries').values({
            tenant_id: ctx.tenantId, labour_advance_id: a.id, wage_sheet_id: id, amount: take,
          }).execute();
          left = round2(left - take);
        }
      }
      const accounts = await systemAccounts(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date,
        voucherType: 'wages',
        voucherId: id,
        number: sheet.number,
        narration: `Site wages ${sheet.number}`,
        lines: [
          { accountId: accounts.site_labour, amount: gross, locationId: sheet.site_id },
          { accountId: account.id, amount: -net, locationId: sheet.site_id },
          { accountId: accounts.labour_advances, amount: -advances, locationId: sheet.site_id },
        ],
      });
      await tx.updateTable('wage_sheets').set({
        status: 'paid', paid_from_account_id: account.id, paid_date: date,
        paid_at: new Date(), paid_by: ctx.userId,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'wage_sheet', id, 'pay', { status: 'approved' }, {
        status: 'paid', date, accountId: account.id, gross, advances, net,
      });
      return (await loadWageSheets(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/wage-sheets/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelWageBody, req.body);
    return ctx.tx(async (tx) => {
      const sheet = await getWageSheet(tx, ctx, id, true);
      if (sheet.status === 'cancelled') throw conflict('This wage sheet is already cancelled.', 'ALREADY_CANCELLED');
      if (sheet.status !== 'draft' && sheet.status !== 'approved') {
        throw conflict('Only draft or approved wage sheets can be cancelled.', 'CONFLICT');
      }
      await tx.updateTable('wage_sheets').set({
        status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'wage_sheet', id, 'cancel', { status: sheet.status }, {
        status: 'cancelled', reason,
      });
      return (await loadWageSheets(tx, [id], true))[0];
    });
  });
}
