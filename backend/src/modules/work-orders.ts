import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { assertGstRates } from '../lib/rates.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import {
  advanceFigures, computeRaBill, defaultTdsPct, latestCumQtys, lineAmount, projectLocationId, requireProjectVisible,
  round2, user, visibleProjectIds,
} from './subcontract-common.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const pct = (max: number) => z.coerce.number().min(0).max(max).refine((v) => Math.abs(v * 100 - Math.round(v * 100)) < 1e-6, 'At most 2 decimals');
const reason = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const uuidParam = (v: string) => parse(z.uuid(), v);

const lineBody = z.object({
  boqLineId: z.uuid().nullish(),
  description: z.string().trim().min(1, 'Required').max(500),
  unit: z.string().trim().min(1, 'Required').max(20),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
  rate: moneyField,
});
const fields = {
  contractorPartyId: z.uuid(),
  date: docDate,
  title: z.string().trim().min(1, 'Required').max(200),
  scope: optionalText(2000),
  retentionPct: pct(20), advanceRecoveryPct: pct(100), tdsPct: pct(20), gstPct: pct(28), itcEligible: z.boolean(), cessPct: pct(2),
  lines: z.array(lineBody).min(1, 'Add at least one line').max(500, 'At most 500 lines'),
};
const createBody = z.object({
  projectId: z.uuid(),
  contractorPartyId: fields.contractorPartyId,
  date: fields.date.optional(), title: fields.title, scope: fields.scope,
  retentionPct: fields.retentionPct.optional(), advanceRecoveryPct: fields.advanceRecoveryPct.optional(),
  tdsPct: fields.tdsPct.optional(), gstPct: fields.gstPct.optional(), itcEligible: fields.itcEligible.optional(),
  cessPct: fields.cessPct.optional(), activate: z.boolean().optional(), lines: fields.lines,
});
const patchBody = z.object({
  contractorPartyId: fields.contractorPartyId.optional(), date: fields.date.optional(), title: fields.title.optional(),
  scope: optionalText(2000), retentionPct: fields.retentionPct.optional(), advanceRecoveryPct: fields.advanceRecoveryPct.optional(),
  tdsPct: fields.tdsPct.optional(), gstPct: fields.gstPct.optional(), itcEligible: fields.itcEligible.optional(),
  cessPct: fields.cessPct.optional(), lines: fields.lines.optional(),
});
const listQuery = pagingQuery.extend({
  projectId: z.uuid().optional(), contractorId: z.uuid().optional(),
  status: z.enum(['draft', 'active', 'closed', 'cancelled']).optional(),
});
const advanceBody = z.object({
  date: docDate.optional(), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  paidFromAccountId: z.uuid(), notes: optionalText(500),
});
const releaseBody = z.object({
  date: docDate.optional(), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), notes: optionalText(500),
});

export async function getWorkOrder(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('work_orders').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const wo = await q.executeTakeFirst();
  if (!wo) throw notFound('Work order');
  await requireProjectVisible(tx, ctx, wo.project_id, 'Work order');
  return wo;
}

export async function loadWorkOrders(tx: Tx, ids: string[], withLines: boolean) {
  if (!ids.length) return [];
  const rows = await tx.selectFrom('work_orders as w')
    .innerJoin('projects as p', 'p.id', 'w.project_id').innerJoin('parties as c', 'c.id', 'w.contractor_party_id')
    .innerJoin('users as u', 'u.id', 'w.created_by')
    .selectAll('w').select(['p.name as project_name', 'c.name as contractor_name', 'u.name as created_by_name'])
    .where('w.id', 'in', ids).execute();
  const billed = await tx.selectFrom('ra_bills').select(['work_order_id', 'gross', 'is_final'])
    .where('work_order_id', 'in', ids).where('status', '=', 'approved').execute();
  const lines = withLines
    ? await tx.selectFrom('work_order_lines as l').leftJoin('boq_lines as b', 'b.id', 'l.boq_line_id')
      .selectAll('l').select('b.code as boq_code').where('l.work_order_id', 'in', ids).orderBy('l.line_no').execute()
    : [];
  const out = [];
  for (const id of ids) {
    const w = rows.find((r) => r.id === id);
    if (!w) continue;
    const fig = await advanceFigures(tx, id);
    const cum = withLines ? await latestCumQtys(tx, id) : new Map<string, number>();
    const mine = billed.filter((b) => b.work_order_id === id);
    out.push({
      id: w.id, number: w.number, projectId: w.project_id, projectName: w.project_name,
      contractorPartyId: w.contractor_party_id, contractorName: w.contractor_name, date: w.order_date, title: w.title,
      scope: w.scope, status: w.status, retentionPct: w.retention_pct, advanceRecoveryPct: w.advance_recovery_pct,
      tdsPct: w.tds_pct, gstPct: w.gst_pct, itcEligible: w.itc_eligible, cessPct: w.cess_pct, totalValue: w.total_value,
      billedGross: round2(mine.reduce((s, b) => s + b.gross, 0)), hasFinalBill: mine.some((b) => b.is_final),
      advance: fig.advance, retention: fig.retention,
      ...(withLines ? {
        lines: lines.filter((l) => l.work_order_id === id).map((l) => ({
          id: l.id, lineNo: l.line_no, boqLineId: l.boq_line_id, boqCode: l.boq_code ?? null, description: l.description,
          unit: l.unit, qty: l.qty, rate: l.rate, amount: l.amount, billedQty: cum.get(l.id) ?? 0,
        })),
      } : {}),
      createdAt: w.created_at, createdBy: user(w.created_by, w.created_by_name),
      cancelledAt: w.cancelled_at, cancelReason: w.cancel_reason,
    });
  }
  return out;
}

async function requireContractor(tx: Tx, ctx: RequestContext, id: string) {
  const party = await tx.selectFrom('parties').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!party || (party.type !== 'vendor' && party.type !== 'both')) {
    throw badRequest('Choose a supplier as the contractor.', { contractorPartyId: 'Not a supplier' });
  }
  return party;
}

async function checkBoqLines(tx: Tx, projectId: string, lines: { boqLineId?: string | null }[]) {
  const ids = [...new Set(lines.map((l) => l.boqLineId).filter((x): x is string => !!x))];
  if (!ids.length) return;
  const found = await tx.selectFrom('boq_lines').select('id').where('id', 'in', ids).where('project_id', '=', projectId).execute();
  if (found.length !== ids.length) {
    const idx = lines.findIndex((l) => l.boqLineId && !found.some((f) => f.id === l.boqLineId));
    throw badRequest('This BOQ line is not part of the project.', { [`lines.${idx}.boqLineId`]: 'Not in this project' });
  }
}

async function writeLines(tx: Tx, ctx: RequestContext, woId: string, lines: z.infer<typeof lineBody>[]) {
  const values = lines.map((l, i) => ({
    tenant_id: ctx.tenantId, work_order_id: woId, line_no: i + 1, boq_line_id: l.boqLineId ?? null,
    description: l.description, unit: l.unit, qty: l.qty, rate: l.rate, amount: lineAmount(l.qty, l.rate),
  }));
  await tx.insertInto('work_order_lines').values(values).execute();
  const total = round2(values.reduce((s, v) => s + v.amount, 0));
  await tx.updateTable('work_orders').set({ total_value: total }).where('id', '=', woId).execute();
}

async function requireCashBank(tx: Tx, ctx: RequestContext, id: string) {
  const a = await tx.selectFrom('accounts').select(['id', 'name', 'type', 'subtype', 'is_active'])
    .where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!a || !a.is_active || a.type !== 'asset' || !['cash', 'bank'].includes(a.subtype)) {
    throw badRequest('Choose an active cash or bank account.', { paidFromAccountId: 'Not a cash or bank account' });
  }
  return a;
}

function advanceJson(a: {
  id: string; number: string; work_order_id: string; advance_date: string; amount: number; paid_from_account_id: string;
  account_name: string; notes: string | null; created_at: Date; created_by: string; created_by_name: string;
  cancelled_at: Date | null; cancel_reason: string | null;
}) {
  return {
    id: a.id, number: a.number, workOrderId: a.work_order_id, date: a.advance_date, amount: a.amount,
    paidFromAccountId: a.paid_from_account_id, paidFromAccountName: a.account_name, notes: a.notes, createdAt: a.created_at,
    createdBy: user(a.created_by, a.created_by_name), cancelledAt: a.cancelled_at, cancelReason: a.cancel_reason,
  };
}

function loadAdvances(tx: Tx, where: { workOrderId?: string; id?: string }) {
  let q = tx.selectFrom('contractor_advances as a').innerJoin('accounts as ac', 'ac.id', 'a.paid_from_account_id')
    .innerJoin('users as u', 'u.id', 'a.created_by').selectAll('a')
    .select(['ac.name as account_name', 'u.name as created_by_name']);
  if (where.workOrderId) q = q.where('a.work_order_id', '=', where.workOrderId);
  if (where.id) q = q.where('a.id', '=', where.id);
  return q.orderBy('a.advance_date', 'desc').orderBy('a.created_at', 'desc').execute();
}

function releaseJson(r: {
  id: string; number: string; work_order_id: string; release_date: string; amount: number; notes: string | null;
  created_at: Date; created_by: string; created_by_name: string;
}) {
  return {
    id: r.id, number: r.number, workOrderId: r.work_order_id, date: r.release_date, amount: r.amount, notes: r.notes,
    createdAt: r.created_at, createdBy: user(r.created_by, r.created_by_name),
  };
}

export async function workOrderRoutes(app: FastifyInstance) {
  app.get('/work-orders', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('work_orders as w').innerJoin('parties as c', 'c.id', 'w.contractor_party_id')
        .where('w.company_id', '=', ctx.companyId);
      const visible = await visibleProjectIds(tx, ctx);
      if (visible) base = base.where('w.project_id', 'in', visible);
      if (q.projectId) base = base.where('w.project_id', '=', q.projectId);
      if (q.contractorId) base = base.where('w.contractor_party_id', '=', q.contractorId);
      if (q.status) base = base.where('w.status', '=', q.status);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('w.number', 'ilike', t), eb('w.title', 'ilike', t), eb('c.name', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('w.id').orderBy('w.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadWorkOrders(tx, ids.map((r) => r.id), false), total };
    });
  });

  app.get<{ Params: { id: string } }>('/work-orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.view');
    const id = uuidParam(req.params.id);
    return ctx.tx(async (tx) => {
      await getWorkOrder(tx, ctx, id);
      return (await loadWorkOrders(tx, [id], true))[0];
    });
  });

  app.post('/work-orders', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.manage');
    const body = parse(createBody, req.body);
    const wo = await ctx.tx(async (tx) => {
      const project = await tx.selectFrom('projects').select('id').where('id', '=', body.projectId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!project) throw badRequest('Project not found.', { projectId: 'Not found' });
      await requireProjectVisible(tx, ctx, project.id, 'Project');
      const party = await requireContractor(tx, ctx, body.contractorPartyId);
      await checkBoqLines(tx, project.id, body.lines);
      const date = body.date ?? todayIst();
      await assertGstRates(tx, date, [{ rate: body.gstPct ?? 18, hsn: '99', field: 'gstPct', label: 'Work order' }]);
      const number = await nextNumber(tx, ctx, 'work_order', financialYear(date));
      const row = await tx.insertInto('work_orders').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, project_id: project.id, contractor_party_id: party.id,
        order_date: date, title: body.title, scope: body.scope ?? null, status: body.activate ? 'active' : 'draft',
        retention_pct: body.retentionPct ?? 5, advance_recovery_pct: body.advanceRecoveryPct ?? 0,
        tds_pct: body.tdsPct ?? defaultTdsPct(party), gst_pct: body.gstPct ?? 18, itc_eligible: body.itcEligible ?? true,
        cess_pct: body.cessPct ?? 0, created_by: ctx.userId, closed_at: null, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      await writeLines(tx, ctx, row.id, body.lines);
      await writeAudit(tx, auditOf(ctx), 'work_order', row.id, 'create', null, { number, projectId: project.id, contractorPartyId: party.id });
      return (await loadWorkOrders(tx, [row.id], true))[0];
    });
    return reply.status(201).send(wo);
  });

  app.patch<{ Params: { id: string } }>('/work-orders/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.manage');
    const id = uuidParam(req.params.id);
    const body = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const wo = await getWorkOrder(tx, ctx, id, true);
      if (wo.status === 'closed' || wo.status === 'cancelled') throw conflict('A closed or cancelled work order cannot be changed.');
      const structural = body.lines !== undefined || body.retentionPct !== undefined || body.advanceRecoveryPct !== undefined ||
        body.tdsPct !== undefined || body.gstPct !== undefined || body.itcEligible !== undefined || body.cessPct !== undefined ||
        (body.contractorPartyId !== undefined && body.contractorPartyId !== wo.contractor_party_id);
      if (structural) {
        const anyBill = await tx.selectFrom('ra_bills').select('id').where('work_order_id', '=', id).limit(1).executeTakeFirst();
        if (anyBill) throw conflict('Lines, rates and the contractor cannot change once an RA bill exists.');
      }
      if (body.gstPct !== undefined || body.date !== undefined) {
        await assertGstRates(tx, body.date ?? wo.order_date, [{ rate: body.gstPct ?? wo.gst_pct, hsn: '99', field: 'gstPct', label: 'Work order' }]);
      }
      const set: Record<string, unknown> = {};
      if (body.contractorPartyId !== undefined && body.contractorPartyId !== wo.contractor_party_id) {
        const adv = await tx.selectFrom('contractor_advances').select('id').where('work_order_id', '=', id).limit(1).executeTakeFirst();
        if (adv) throw conflict('The contractor cannot change after an advance was paid.');
        const party = await requireContractor(tx, ctx, body.contractorPartyId);
        set.contractor_party_id = party.id;
        if (body.tdsPct === undefined) set.tds_pct = defaultTdsPct(party);
      }
      if (body.date !== undefined) set.order_date = body.date;
      if (body.title !== undefined) set.title = body.title;
      if (body.scope !== undefined) set.scope = body.scope;
      if (body.retentionPct !== undefined) set.retention_pct = body.retentionPct;
      if (body.advanceRecoveryPct !== undefined) set.advance_recovery_pct = body.advanceRecoveryPct;
      if (body.tdsPct !== undefined) set.tds_pct = body.tdsPct;
      if (body.gstPct !== undefined) set.gst_pct = body.gstPct;
      if (body.itcEligible !== undefined) set.itc_eligible = body.itcEligible;
      if (body.cessPct !== undefined) set.cess_pct = body.cessPct;
      if (Object.keys(set).length) await tx.updateTable('work_orders').set(set).where('id', '=', id).execute();
      if (body.lines) {
        await checkBoqLines(tx, wo.project_id, body.lines);
        await tx.deleteFrom('work_order_lines').where('work_order_id', '=', id).execute();
        await writeLines(tx, ctx, id, body.lines);
      }
      await writeAudit(tx, auditOf(ctx), 'work_order', id, 'update', { number: wo.number }, body);
      return (await loadWorkOrders(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/work-orders/:id/activate', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.manage');
    const id = uuidParam(req.params.id);
    return ctx.tx(async (tx) => {
      const wo = await getWorkOrder(tx, ctx, id, true);
      if (wo.status !== 'draft') throw conflict('Only a draft work order can be activated.');
      await tx.updateTable('work_orders').set({ status: 'active' }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'work_order', id, 'activate', { status: 'draft' }, { status: 'active' });
      return (await loadWorkOrders(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/work-orders/:id/close', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.approve');
    const id = uuidParam(req.params.id);
    return ctx.tx(async (tx) => {
      const wo = await getWorkOrder(tx, ctx, id, true);
      if (wo.status !== 'active') throw conflict('Only an active work order can be closed.');
      const open = await tx.selectFrom('ra_bills').select('id').where('work_order_id', '=', id).where('status', 'in', ['draft', 'submitted']).limit(1).executeTakeFirst();
      if (open) throw conflict('A draft or submitted RA bill exists. Approve or cancel it first.');
      await tx.updateTable('work_orders').set({ status: 'closed', closed_at: new Date() }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'work_order', id, 'close', { status: 'active' }, { status: 'closed' });
      return (await loadWorkOrders(tx, [id], true))[0];
    });
  });

  app.post<{ Params: { id: string } }>('/work-orders/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.approve');
    const id = uuidParam(req.params.id);
    const { reason: why } = parse(reason, req.body);
    return ctx.tx(async (tx) => {
      const wo = await getWorkOrder(tx, ctx, id, true);
      if (wo.status === 'cancelled') throw conflict('This work order is already cancelled.', 'ALREADY_CANCELLED');
      if (wo.status !== 'draft' && wo.status !== 'active') throw conflict('Only a draft or active work order can be cancelled.');
      const approved = await tx.selectFrom('ra_bills').select('id').where('work_order_id', '=', id).where('status', '=', 'approved').limit(1).executeTakeFirst();
      if (approved) throw conflict('An approved RA bill exists.');
      const adv = await tx.selectFrom('contractor_advances').select('id').where('work_order_id', '=', id).where('cancelled_at', 'is', null).limit(1).executeTakeFirst();
      if (adv) throw conflict('Cancel the advances paid on this work order first.');
      await tx.updateTable('ra_bills').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: `Work order cancelled: ${why}` })
        .where('work_order_id', '=', id).where('status', 'in', ['draft', 'submitted']).execute();
      await tx.updateTable('work_orders').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: why }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'work_order', id, 'cancel', { status: wo.status }, { status: 'cancelled', reason: why });
      return (await loadWorkOrders(tx, [id], true))[0];
    });
  });

  app.get<{ Params: { id: string } }>('/work-orders/:id/advances', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.view');
    const id = uuidParam(req.params.id);
    return ctx.tx(async (tx) => {
      await getWorkOrder(tx, ctx, id);
      const data = (await loadAdvances(tx, { workOrderId: id })).map(advanceJson);
      return { data, total: data.length };
    });
  });

  app.post<{ Params: { id: string } }>('/work-orders/:id/advances', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.approve');
    const id = uuidParam(req.params.id);
    const body = parse(advanceBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const wo = await getWorkOrder(tx, ctx, id, true);
      if (wo.status !== 'active') throw conflict('The work order must be active.');
      const account = await requireCashBank(tx, ctx, body.paidFromAccountId);
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      const number = await nextNumber(tx, ctx, 'contractor_advance', financialYear(date));
      const row = await tx.insertInto('contractor_advances').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, work_order_id: id, advance_date: date, amount: body.amount,
        paid_from_account_id: account.id, notes: body.notes ?? null, created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      const acc = await systemAccounts(tx, ctx);
      const loc = await projectLocationId(tx, wo.project_id);
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'contractor_advance', voucherId: row.id, number, narration: `Mobilisation advance ${wo.number}`,
        lines: [
          { accountId: acc.contractor_advances, amount: body.amount, partyId: wo.contractor_party_id, locationId: loc },
          { accountId: account.id, amount: -body.amount, locationId: loc },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'contractor_advance', row.id, 'create', null, { number, workOrderId: id, amount: body.amount });
      return advanceJson((await loadAdvances(tx, { id: row.id }))[0]!);
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/contractor-advances/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.approve');
    const id = uuidParam(req.params.id);
    const { reason: why } = parse(reason, req.body);
    return ctx.tx(async (tx) => {
      const adv = await tx.selectFrom('contractor_advances').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!adv) throw notFound('Contractor advance');
      const wo = await getWorkOrder(tx, ctx, adv.work_order_id, true);
      if (adv.cancelled_at) throw conflict('This is already cancelled.', 'ALREADY_CANCELLED');
      const fig = await advanceFigures(tx, wo.id);
      if (round2(fig.advance.balance - adv.amount) < 0) throw conflict('Part of this advance has already been recovered on RA bills.');
      await tx.updateTable('contractor_advances').set({ cancelled_at: new Date(), cancel_reason: why }).where('id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${adv.number}: ${why}`);
      await writeAudit(tx, auditOf(ctx), 'contractor_advance', id, 'cancel', null, { reason: why });
      return advanceJson((await loadAdvances(tx, { id }))[0]!);
    });
  });

  app.get<{ Params: { id: string } }>('/work-orders/:id/retention-releases', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.view');
    const id = uuidParam(req.params.id);
    return ctx.tx(async (tx) => {
      await getWorkOrder(tx, ctx, id);
      const rows = await tx.selectFrom('retention_releases as r').innerJoin('users as u', 'u.id', 'r.created_by')
        .selectAll('r').select('u.name as created_by_name').where('r.work_order_id', '=', id)
        .orderBy('r.release_date', 'desc').orderBy('r.created_at', 'desc').execute();
      return { data: rows.map(releaseJson), total: rows.length };
    });
  });

  app.post<{ Params: { id: string } }>('/work-orders/:id/retention-releases', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.approve');
    const id = uuidParam(req.params.id);
    const body = parse(releaseBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const wo = await getWorkOrder(tx, ctx, id, true);
      if (wo.status === 'draft' || wo.status === 'cancelled') throw conflict('This work order has no retention to release.');
      const fig = await advanceFigures(tx, id);
      if (body.amount > fig.retention.balance + 0.001) {
        throw badRequest(`Only ₹${fig.retention.balance} of retention is held.`, { amount: `At most ${fig.retention.balance}` });
      }
      const date = body.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      const number = await nextNumber(tx, ctx, 'retention_release', financialYear(date));
      const row = await tx.insertInto('retention_releases').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, work_order_id: id, release_date: date,
        amount: body.amount, notes: body.notes ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const acc = await systemAccounts(tx, ctx);
      const loc = await projectLocationId(tx, wo.project_id);
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'retention_release', voucherId: row.id, number, narration: `Retention release ${wo.number}`,
        lines: [
          { accountId: acc.retention_payable, amount: body.amount, locationId: loc },
          { accountId: acc.payables, amount: -body.amount, partyId: wo.contractor_party_id, locationId: loc },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'retention_release', row.id, 'create', null, { number, workOrderId: id, amount: body.amount });
      const saved = await tx.selectFrom('retention_releases as r').innerJoin('users as u', 'u.id', 'r.created_by')
        .selectAll('r').select('u.name as created_by_name').where('r.id', '=', row.id).executeTakeFirstOrThrow();
      return releaseJson(saved);
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/work-orders/:id/ra-bill-template', async (req) => {
    const ctx = req.ctx;
    ctx.require('subcontracts.manage');
    const id = uuidParam(req.params.id);
    return ctx.tx(async (tx) => {
      const wo = await getWorkOrder(tx, ctx, id);
      const [full] = await loadWorkOrders(tx, [id], true);
      const last = await tx.selectFrom('ra_bills').select((eb) => eb.fn.max('bill_seq').as('m')).where('work_order_id', '=', id).executeTakeFirstOrThrow();
      const party = await tx.selectFrom('parties').select('credit_days').where('id', '=', wo.contractor_party_id).executeTakeFirstOrThrow();
      const date = todayIst();
      const lines = full!.lines!.map((l) => ({
        workOrderLineId: l.id, description: l.description, unit: l.unit, rate: l.rate, qty: l.qty,
        prevQty: l.billedQty, cumQty: l.billedQty, thisQty: 0, amount: 0,
      }));
      return {
        id: null, number: null, workOrderId: id, workOrderNumber: wo.number, projectId: wo.project_id, projectName: full!.projectName,
        contractorPartyId: wo.contractor_party_id, contractorName: full!.contractorName, billSeq: Number(last.m ?? 0) + 1,
        date, periodFrom: null, periodTo: null, dueDate: addDays(date, party.credit_days), status: 'draft', isFinal: false, lines,
        gross: 0, cgst: 0, sgst: 0, igst: 0, invoiceTotal: 0, retention: 0, advanceRecovery: 0, tds: 0, cess: 0,
        otherDeduction: 0, otherDeductionNote: null, totalDeductions: 0, netPayable: 0, amountPaid: 0, amountDue: 0,
        paymentStatus: 'unpaid', notes: null, rejectReason: null, createdAt: null, createdBy: null, submittedAt: null,
        approvedAt: null, approvedBy: null, cancelledAt: null, cancelReason: null,
        retentionPct: wo.retention_pct, advanceRecoveryPct: wo.advance_recovery_pct, tdsPct: wo.tds_pct, cessPct: wo.cess_pct,
        gstPct: wo.gst_pct, advanceBalance: full!.advance.balance,
      };
    });
  });
}

// computeRaBill is re-exported for tests and the RA bill module.
export { computeRaBill };
