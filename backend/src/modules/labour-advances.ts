import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const round2 = (n: number) => Math.round(n * 100) / 100;
const createBody = z.object({
  workerId: z.uuid(), date: dateField.optional(), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  paidFromAccountId: z.uuid(), notes: optionalText(500),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const listQuery = pagingQuery.extend({
  workerId: z.uuid().optional(), siteId: z.uuid().optional(), status: z.enum(['open', 'recovered', 'cancelled']).optional(),
});

async function loadAdvances(tx: Tx, ids: string[], withRecoveries: boolean) {
  if (!ids.length) return [];
  const rows = await tx.selectFrom('labour_advances as a').innerJoin('workers as w', 'w.id', 'a.worker_id')
    .leftJoin('locations as l', 'l.id', 'a.site_id').innerJoin('accounts as ac', 'ac.id', 'a.paid_from_account_id')
    .innerJoin('users as u', 'u.id', 'a.created_by')
    .selectAll('a').select(['w.name as worker_name', 'l.name as site_name', 'ac.name as account_name', 'u.name as created_by_name'])
    .where('a.id', 'in', ids).execute();
  const recs = withRecoveries
    ? await tx.selectFrom('labour_advance_recoveries as r').innerJoin('wage_sheets as s', 's.id', 'r.wage_sheet_id')
      .select(['r.labour_advance_id', 'r.wage_sheet_id', 's.number', 's.paid_date', 'r.amount'])
      .where('r.labour_advance_id', 'in', ids).orderBy('s.paid_date').execute()
    : [];
  return ids.map((id) => rows.find((r) => r.id === id)).filter((a) => !!a).map((a) => ({
    id: a.id, number: a.number, workerId: a.worker_id, workerName: a.worker_name, siteId: a.site_id, siteName: a.site_name,
    date: a.advance_date, amount: a.amount, recovered: a.recovered,
    balance: a.status === 'cancelled' ? 0 : round2(a.amount - a.recovered),
    paidFromAccountId: a.paid_from_account_id, paidFromAccountName: a.account_name, notes: a.notes, status: a.status,
    createdAt: a.created_at, createdBy: { id: a.created_by, name: a.created_by_name },
    cancelledAt: a.cancelled_at, cancelReason: a.cancel_reason,
    ...(withRecoveries ? {
      recoveries: recs.filter((r) => r.labour_advance_id === a.id).map((r) => ({
        wageSheetId: r.wage_sheet_id, wageSheetNumber: r.number, date: r.paid_date, amount: r.amount,
      })),
    } : {}),
  }));
}

function visible(ctx: RequestContext, siteId: string | null) {
  const scope = scopedLocationIds(ctx);
  return scope === null || (siteId !== null && scope.includes(siteId));
}

export async function labourAdvanceRoutes(app: FastifyInstance) {
  app.get('/labour-advances', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('labour_advances as a').innerJoin('workers as w', 'w.id', 'a.worker_id')
        .where('a.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('a.site_id', 'in', scope);
      if (q.workerId) base = base.where('a.worker_id', '=', q.workerId);
      if (q.siteId) base = base.where('a.site_id', '=', q.siteId);
      if (q.status) base = base.where('a.status', '=', q.status);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('a.number', 'ilike', t), eb('w.name', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('a.id').orderBy('a.advance_date', 'desc').orderBy('a.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadAdvances(tx, ids.map((r) => r.id), false), total };
    });
  });

  app.get<{ Params: { id: string } }>('/labour-advances/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const a = await tx.selectFrom('labour_advances').select(['id', 'site_id']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!a || !visible(ctx, a.site_id)) throw notFound('Labour advance');
      return (await loadAdvances(tx, [id], true))[0];
    });
  });

  app.post('/labour-advances', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('wages.pay');
    const body = parse(createBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const worker = await tx.selectFrom('workers').select(['id', 'name', 'site_id']).where('id', '=', body.workerId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!worker || !visible(ctx, worker.site_id)) throw badRequest('Worker not found.', { workerId: 'Not found' });
      const account = await tx.selectFrom('accounts').select(['id', 'type', 'subtype', 'is_active'])
        .where('id', '=', body.paidFromAccountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!account || !account.is_active || account.type !== 'asset' || !['cash', 'bank'].includes(account.subtype)) {
        throw badRequest('Choose an active cash or bank account.', { paidFromAccountId: 'Not a cash or bank account' });
      }
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      const number = await nextNumber(tx, ctx, 'labour_advance', financialYear(date));
      const row = await tx.insertInto('labour_advances').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, worker_id: worker.id, site_id: worker.site_id,
        advance_date: date, amount: body.amount, paid_from_account_id: account.id, notes: body.notes ?? null,
        created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      const acc = await systemAccounts(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'labour_advance', voucherId: row.id, number, narration: `Advance to ${worker.name}`,
        lines: [
          { accountId: acc.labour_advances, amount: body.amount, locationId: worker.site_id },
          { accountId: account.id, amount: -body.amount, locationId: worker.site_id },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'labour_advance', row.id, 'create', null, { number, workerId: worker.id, amount: body.amount });
      return (await loadAdvances(tx, [row.id], true))[0];
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/labour-advances/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('wages.pay');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const a = await tx.selectFrom('labour_advances').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!a || !visible(ctx, a.site_id)) throw notFound('Labour advance');
      if (a.status === 'cancelled') throw conflict('This is already cancelled.', 'ALREADY_CANCELLED');
      if (a.recovered > 0) throw conflict('Part of this advance has been recovered from wages.');
      await tx.updateTable('labour_advances').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${a.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'labour_advance', id, 'cancel', { status: a.status }, { status: 'cancelled', reason });
      return (await loadAdvances(tx, [id], true))[0];
    });
  });
}
