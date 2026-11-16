// Payroll runs: draft -> computed -> approved -> posted (paid). Statutory maths is in lib/payroll/.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { toCsv } from '../lib/csv.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { pagingQuery } from '../lib/paging.ts';
import { computeLine, type AdjustmentInput, type OverrideInput } from '../lib/payroll/compute.ts';
import { establishmentAdmin, pfCeiling } from '../lib/payroll/epf.ts';
import { round2 } from '../lib/payroll/money.ts';
import { PT_RULES } from '../lib/payroll/pt.ts';
import { basicFlags, companyRateRows, loadStatSettings, overtimeHours, wageRuleFor } from '../lib/payroll/load.ts';
import { ratesInForce } from '../lib/payroll/rates.ts';
import { monthlyWages, overtimePay } from '../lib/payroll/statutory.ts';
import { daysInMonth } from '../lib/payroll/proration.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { ensureComponents, leaveInMonth, myEmployee, salaryFor } from './hr.ts';
import { onPayrollApproved } from './claims-payroll.ts';
import { documentRoute } from '../lib/openapi.ts';

const monthField = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM').transform((v) => `${v}-01`);
const lastDay = (m: string) => `${m.slice(0, 8)}${String(new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)), 0)).getUTCDate()).padStart(2, '0')}`;
const fyStartOf = (m: string) => (Number(m.slice(5, 7)) >= 4 ? `${m.slice(0, 4)}-04-01` : `${Number(m.slice(0, 4)) - 1}-04-01`);
const paise = (n: number) => Math.round(n * 100);

type Run = Awaited<ReturnType<typeof getRun>>;
export async function getRun(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('payroll_runs').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const r = await q.executeTakeFirst();
  if (!r) throw notFound('Payroll run');
  if (r.location_id) ctx.requireLocation(r.location_id);
  return r;
}

const runJson = (r: Run, extra: Record<string, unknown> = {}) => ({
  id: r.id, number: r.number, month: r.month.slice(0, 7), locationId: r.location_id, status: r.status, gross: r.gross,
  deductions: r.deductions, net: r.net, employerCost: r.employer_cost, employeeCount: r.employee_count, notes: r.notes,
  createdBy: r.created_by, computedAt: r.computed_at, approvedBy: r.approved_by, approvedAt: r.approved_at, accrualEntryId: r.accrual_entry_id,
  payDate: r.pay_date, paidAt: r.paid_at, payoutEntryId: r.payout_entry_id, createdAt: r.created_at, updatedAt: r.updated_at, ...extra,
});

export type LineRow = Awaited<ReturnType<typeof loadLines>>[number];
export async function loadLines(tx: Tx, runId: string) {
  return tx.selectFrom('payroll_lines as l').innerJoin('employees as e', 'e.id', 'l.employee_id')
    .selectAll('l').select(['e.code as emp_code', 'e.name as emp_name', 'e.department as emp_department', 'e.designation as emp_designation'])
    .where('l.run_id', '=', runId).orderBy('e.code').execute();
}
const dedOf = (l: { pf_employee: number; esi_employee: number; pt: number; lwf_employee: number; tds: number; other_ded_total: number }) =>
  round2(l.pf_employee + l.esi_employee + l.pt + l.lwf_employee + l.tds + l.other_ded_total);
const lineJson = (l: LineRow) => ({
  id: l.id, employeeId: l.employee_id, code: l.emp_code, name: l.emp_name, department: l.emp_department, designation: l.emp_designation,
  workingDays: l.working_days, paidDays: l.paid_days, lopDays: l.lop_days, earnings: l.earnings, adjustments: l.adjustments,
  otherDeductions: l.other_deductions, gross: l.gross, pfWage: l.pf_wage, esiWage: l.esi_wage, pfEmployee: l.pf_employee, pfEps: l.pf_eps,
  pfEpfEmployer: l.pf_epf_employer, pfEdli: l.pf_edli, pfAdmin: l.pf_admin, esiEmployee: l.esi_employee, esiEmployer: l.esi_employer,
  pt: l.pt, ptStateCode: l.pt_state_code, lwfEmployee: l.lwf_employee, lwfEmployer: l.lwf_employer, tds: l.tds, tdsWorking: l.tds_working,
  otherDeductionsTotal: l.other_ded_total, deductions: dedOf(l), net: l.net, overrides: l.overrides, warnings: l.warnings,
});

/** Builds every line of a run from current data. Adjustments and overrides entered for the run are kept. */
export async function computeRun(tx: Tx, ctx: RequestContext, run: Run) {
  await ensureComponents(tx, ctx);
  const monthStart = run.month, monthEnd = lastDay(monthStart);
  const settings = await tx.selectFrom('payroll_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst();
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  let eq = tx.selectFrom('employees as e').leftJoin('locations as l', 'l.id', 'e.location_id').selectAll('e').select('l.state_code as loc_state')
    .where('e.company_id', '=', ctx.companyId).where('e.joining_date', '<=', monthEnd).where('e.status', '<>', 'inactive')
    .where((eb) => eb.or([eb('e.leaving_date', 'is', null), eb('e.leaving_date', '>=', monthStart)]));
  if (run.location_id) eq = eq.where('e.location_id', '=', run.location_id);
  const emps = await eq.orderBy('e.code').execute();

  await tx.deleteFrom('payroll_lines').where('run_id', '=', run.id).execute();
  const taken = new Set((await tx.selectFrom('payroll_lines').select('employee_id').where('month', '=', monthStart).where('is_live', '=', true).execute()).map((r) => r.employee_id));
  // Employees with an approved full and final settlement leave payroll from the exit month on.
  const settled = new Set((await tx.selectFrom('fnf_settlements').select(['employee_id', 'exit_date']).where('company_id', '=', ctx.companyId)
    .where('status', 'in', ['approved', 'paid']).execute()).filter((f) => f.exit_date.slice(0, 7) <= monthStart.slice(0, 7)).map((f) => f.employee_id));
  const elig = emps.filter((e) => !taken.has(e.id) && !settled.has(e.id));
  const stat = await loadStatSettings(tx, ctx.companyId);
  const rateRows = await companyRateRows(tx, ctx.companyId);
  const basics = await basicFlags(tx, ctx.companyId);
  const otHours = await overtimeHours(tx, ctx.companyId, monthStart);
  const rule = wageRuleFor(stat, monthStart);
  const leave = await leaveInMonth(tx, ctx.companyId, monthStart, elig);
  const att = await tx.selectFrom('attendance_summaries').selectAll().where('company_id', '=', ctx.companyId).where('month', '=', monthStart).execute();
  const adjs = await tx.selectFrom('payroll_adjustments').selectAll().where('run_id', '=', run.id).execute();
  const ovs = await tx.selectFrom('payroll_overrides').selectAll().where('run_id', '=', run.id).execute();
  const skipped: { employeeId: string; name: string; reason: string }[] = [];
  let gross = 0, ded = 0, net = 0, cost = 0, count = 0;

  for (const e of elig) {
    const sal = await salaryFor(tx, e.id, monthStart, monthEnd);
    if (!sal) { skipped.push({ employeeId: e.id, name: e.name, reason: 'No salary structure' }); continue; }
    const a = att.find((x) => x.employee_id === e.id);
    const lopDays = a ? a.lop_days : (leave.get(e.id)?.unpaid ?? 0);
    const ytdRows = await tx.selectFrom('payroll_lines').select(['taxable_gross', 'tds', 'pt', 'pf_employee']).where('employee_id', '=', e.id)
      .where('is_live', '=', true).where('month', '>=', fyStartOf(monthStart)).where('month', '<', monthStart).where('run_id', '<>', run.id).execute();
    const ytd = ytdRows.reduce((s, r) => ({ taxable: s.taxable + r.taxable_gross, tds: s.tds + r.tds, pt: s.pt + r.pt, pfEmployee: s.pfEmployee + r.pf_employee }), { taxable: 0, tds: 0, pt: 0, pfEmployee: 0 });
    const adjustments: AdjustmentInput[] = adjs.filter((x) => x.employee_id === e.id).map((x) => ({ id: x.id, kind: x.kind as 'earning' | 'deduction', label: x.label, amount: x.amount, taxable: x.taxable, reason: x.reason }));
    const overrides: OverrideInput[] = ovs.filter((x) => x.employee_id === e.id).map((x) => ({ field: x.field as OverrideInput['field'], value: x.value, reason: x.reason }));
    const ptState = e.pt_state_code ?? e.loc_state ?? company.state_code;
    const otH = otHours.get(e.id) ?? 0;
    let otPay = 0;
    if (otH > 0) {
      const w = monthlyWages(sal.lines.filter((l) => l.kind === 'earning').map((l) => ({ code: l.code, amount: l.amount, isBasic: basics.get(l.component_id) ?? false })), rule);
      otPay = overtimePay({ wages: w.wages, divisorDays: (settings?.lop_divisor ?? 'calendar') === 'calendar' ? daysInMonth(monthStart) : Number(settings!.lop_divisor), hoursPerDay: stat.hoursPerDay, hours: otH, multiplier: stat.otMultiplier });
      if (otPay > 0) adjustments.push({ kind: 'earning', label: 'Overtime', amount: otPay, taxable: true, reason: `${otH} hours` });
    }
    const r = computeLine({
      monthStart, joining: e.joining_date, leaving: e.leaving_date, sex: e.sex, lopDays, divisor: (settings?.lop_divisor ?? 'calendar') as 'calendar' | '30' | '26',
      components: sal.lines.map((l) => ({ componentId: l.component_id, code: l.code, name: l.name, kind: l.kind as 'earning' | 'deduction', amount: l.amount, taxable: l.taxable, pfWage: l.pf_wage, esiWage: l.esi_wage, proRata: l.pro_rata })),
      adjustments, overrides,
      settings: { pfEnabled: settings?.pf_enabled ?? true, esiEnabled: settings?.esi_enabled ?? true, lwfEnabled: settings?.lwf_enabled ?? false, ptEnabled: settings?.pt_enabled ?? true, pfRate: settings?.pf_rate ?? 12 },
      employee: { pfApplicable: e.pf_applicable, pfHigherWage: e.pf_higher_wage, esiApplicable: e.esi_applicable, esiCoveredUntil: e.esi_covered_until, taxRegime: e.tax_regime as 'new' | 'old', previousIncome: e.previous_income, previousTds: e.previous_tds },
      ptStateCode: ptState, ytd, rates: ratesInForce(rateRows, monthStart, ptState), wageRule: rule,
    });
    const lineRow = await tx.insertInto('payroll_lines').values({
      tenant_id: ctx.tenantId, run_id: run.id, company_id: ctx.companyId, employee_id: e.id, month: monthStart, working_days: r.workingDays,
      paid_days: r.paidDays, lop_days: r.lopDays, earnings: JSON.stringify(r.earnings), adjustments: JSON.stringify(r.adjustments),
      other_deductions: JSON.stringify(r.otherDeductions), gross: r.gross, taxable_gross: r.taxableGross, pf_wage: r.pfWage, esi_wage: r.esiWage,
      pf_employee: r.pfEmployee, pf_eps: r.pfEps, pf_epf_employer: r.pfEpfEmployer, pf_edli: r.pfEdli, pf_admin: r.pfAdmin,
      esi_employee: r.esiEmployee, esi_employer: r.esiEmployer, esi_covered_until: r.esiCoveredUntil, pt: r.pt, pt_state_code: ptState,
      lwf_employee: r.lwfEmployee, lwf_employer: r.lwfEmployer, tds: r.tds, tds_working: JSON.stringify(r.tdsWorking),
      other_ded_total: r.otherDedTotal, net: r.net, overrides: JSON.stringify(r.overrides), warnings: JSON.stringify(r.warnings),
    }).returning('id').executeTakeFirstOrThrow();
    if (r.wageRuleAddback > 0 || otH > 0) {
      await tx.insertInto('payroll_line_extras').values({ line_id: lineRow.id, tenant_id: ctx.tenantId, wage_rule_addback: r.wageRuleAddback, ot_hours: otH, ot_pay: otPay }).execute();
    }
    gross += r.gross; net += r.net; cost += r.employerCost; count += 1;
    ded += r.gross - r.net;
  }
  await tx.updateTable('payroll_runs').set({
    status: 'computed', gross: round2(gross), deductions: round2(ded), net: round2(net), employer_cost: round2(cost), employee_count: count,
    computed_by: ctx.userId, computed_at: new Date(),
  }).where('id', '=', run.id).execute();
  return skipped;
}

export async function ensureAccount(tx: Tx, ctx: RequestContext, name: string, type: 'expense' | 'liability', base: number): Promise<string> {
  const ex = await tx.selectFrom('accounts').select('id').where('company_id', '=', ctx.companyId).where('name', '=', name).executeTakeFirst();
  if (ex) return ex.id;
  const used = new Set((await tx.selectFrom('accounts').select('code').where('company_id', '=', ctx.companyId).execute()).map((r) => r.code));
  let code = base;
  while (used.has(String(code))) code += 1;
  const row = await tx.insertInto('accounts').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, code: String(code), name, type, subtype: 'other', system_key: null, is_system: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

const MAKER_MSG = 'You prepared this run, so someone else must approve it.';
async function makers(tx: Tx, run: Run): Promise<Set<string>> {
  const s = new Set<string>();
  for (const u of [run.created_by, run.computed_by]) if (u) s.add(u);
  for (const t of ['payroll_adjustments', 'payroll_overrides'] as const) {
    const rows = await tx.selectFrom(t).select('created_by').where('run_id', '=', run.id).execute();
    for (const r of rows) if (r.created_by) s.add(r.created_by);
  }
  return s;
}

export async function postAccrual(tx: Tx, ctx: RequestContext, run: Run, lines: LineRow[]): Promise<string> {
  const byComp = new Map<string, number>();
  let oneTime = 0, employerContrib = 0, pf = 0, esi = 0, pt = 0, lwf = 0, tds = 0, other = 0, net = 0;
  for (const l of lines) {
    for (const e of l.earnings as { name: string; amount: number }[]) byComp.set(e.name, (byComp.get(e.name) ?? 0) + paise(e.amount));
    oneTime += paise((l.adjustments as AdjustmentInput[]).filter((a) => a.kind === 'earning').reduce((s, a) => s + a.amount, 0));
    employerContrib += paise(l.pf_eps + l.pf_epf_employer + l.pf_edli + l.pf_admin + l.esi_employer + l.lwf_employer);
    pf += paise(l.pf_employee + l.pf_eps + l.pf_epf_employer + l.pf_edli + l.pf_admin);
    esi += paise(l.esi_employee + l.esi_employer);
    pt += paise(l.pt); lwf += paise(l.lwf_employee + l.lwf_employer); tds += paise(l.tds); other += paise(l.other_ded_total); net += paise(l.net);
  }
  const jl: { accountId: string; amount: number; locationId: string | null }[] = [];
  const loc = run.location_id;
  for (const [name, p] of byComp) jl.push({ accountId: await ensureAccount(tx, ctx, `Salary - ${name}`, 'expense', 6500), amount: p / 100, locationId: loc });
  if (oneTime) jl.push({ accountId: await ensureAccount(tx, ctx, 'Salary - One-time additions', 'expense', 6500), amount: oneTime / 100, locationId: loc });
  if (employerContrib) jl.push({ accountId: await ensureAccount(tx, ctx, 'Employer PF, ESI and LWF contributions', 'expense', 6500), amount: employerContrib / 100, locationId: loc });
  const cr = async (name: string, p: number) => { if (p) jl.push({ accountId: await ensureAccount(tx, ctx, name, 'liability', 2450), amount: -p / 100, locationId: loc }); };
  await cr('Net Salary Payable', net); await cr('PF Payable', pf); await cr('ESI Payable', esi); await cr('Professional Tax Payable', pt);
  await cr('LWF Payable', lwf); await cr('TDS on Salary Payable', tds); await cr('Other Salary Deductions Payable', other);
  return postJournal(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId }, {
    date: lastDay(run.month), voucherType: 'wages', voucherId: run.id, number: run.number, narration: `Payroll ${run.number} for ${run.month.slice(0, 7)}`, lines: jl,
  });
}

const createBody = z.object({ month: monthField, locationId: z.preprocess((v) => (v === '' ? null : v), z.uuid().nullable().optional()), notes: optionalText(300) });
const adjBody = z.object({
  employeeId: z.uuid(), kind: z.enum(['earning', 'deduction']), label: z.string().trim().min(1).max(80),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), taxable: z.boolean().optional(), reason: optionalText(200),
});
const ovBody = z.object({
  employeeId: z.uuid(), field: z.enum(['lop_days', 'pf_employee', 'esi_employee', 'pt', 'lwf_employee', 'tds']),
  value: moneyField, reason: z.string().trim().min(3, 'Give a reason').max(200),
});
const listQuery = pagingQuery.extend({ month: monthField.optional(), status: z.enum(['draft', 'computed', 'approved', 'posted', 'cancelled']).optional() });

export async function payrollRoutes(app: FastifyInstance) {
  app.get('/payroll/runs', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('payroll_runs').where('company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('location_id', 'in', scope);
      if (q.month) base = base.where('month', '=', q.month);
      if (q.status) base = base.where('status', '=', q.status);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('month', 'desc').orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map((r) => runJson(r)), total };
    });
  });

  app.post('/payroll/runs', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.run');
    const b = parse(createBody, req.body);
    if (b.locationId) ctx.requireLocation(b.locationId);
    else if (scopedLocationIds(ctx)) throw forbidden('Choose a location: your access is limited to some locations.');
    const out = await ctx.tx(async (tx) => {
      if (b.locationId) {
        const l = await tx.selectFrom('locations').select('id').where('id', '=', b.locationId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!l) throw badRequest('Location not found.', { locationId: 'Not found' });
      }
      if (b.month.slice(0, 7) > todayIst().slice(0, 7)) throw badRequest('Payroll cannot be run for a future month.', { month: 'In the future' });
      const live = await tx.selectFrom('payroll_runs').select(['id', 'status', 'number', 'location_id']).where('company_id', '=', ctx.companyId)
        .where('month', '=', b.month).where('status', '<>', 'cancelled').execute();
      const clash = live.find((r) => !b.locationId || !r.location_id || r.location_id === b.locationId);
      if (clash) {
        throw conflict(`Payroll ${clash.number} already exists for ${b.month.slice(0, 7)} (${clash.status}).`, 'RUN_EXISTS', { runId: clash.id, status: clash.status });
      }
      const number = await nextNumber(tx, ctx, 'payroll_run', financialYear(b.month));
      const r = await tx.insertInto('payroll_runs').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, month: b.month, location_id: b.locationId ?? null, notes: b.notes ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'payroll_run', r.id, 'create', null, runJson(r));
      return runJson(r);
    });
    return reply.status(201).send(out);
  });

  async function detail(tx: Tx, ctx: RequestContext, id: string, skipped?: unknown) {
    const run = await getRun(tx, ctx, id);
    const lines = (await loadLines(tx, id)).map(lineJson);
    const adj = await tx.selectFrom('payroll_adjustments').selectAll().where('run_id', '=', id).orderBy('created_at').execute();
    const can = await makers(tx, run);
    return runJson(run, {
      lines, skipped: skipped ?? [], canApprove: ctx.can('payroll.approve') && !can.has(ctx.userId) && run.status === 'computed',
      adjustments: adj.map((a) => ({ id: a.id, employeeId: a.employee_id, kind: a.kind, label: a.label, amount: a.amount, taxable: a.taxable, reason: a.reason })),
    });
  }

  app.get<{ Params: { id: string } }>('/payroll/runs/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => detail(tx, ctx, id));
  });

  // Recompute whenever anything that feeds the run changes, so the run never shows stale figures.
  async function editable(tx: Tx, ctx: RequestContext, id: string) {
    const run = await getRun(tx, ctx, id, true);
    if (run.status !== 'draft' && run.status !== 'computed') throw conflict(`This run is ${run.status} and can no longer be changed.`, 'RUN_LOCKED');
    return run;
  }

  app.post<{ Params: { id: string } }>('/payroll/runs/:id/compute', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.run');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const run = await editable(tx, ctx, id);
      const skipped = await computeRun(tx, ctx, run);
      await writeAudit(tx, auditOf(ctx), 'payroll_run', id, 'compute', { status: run.status }, { status: 'computed' });
      return detail(tx, ctx, id, skipped);
    });
  });

  app.post<{ Params: { id: string } }>('/payroll/runs/:id/adjustments', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.run');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(adjBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const run = await editable(tx, ctx, id);
      const emp = await tx.selectFrom('employees').select('id').where('id', '=', b.employeeId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!emp) throw notFound('Employee');
      const a = await tx.insertInto('payroll_adjustments').values({
        tenant_id: ctx.tenantId, run_id: id, employee_id: b.employeeId, kind: b.kind, label: b.label, amount: b.amount, taxable: b.taxable ?? true,
        reason: b.reason ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'payroll_adjustment', a.id, 'create', null, { runId: id, ...b });
      const skipped = await computeRun(tx, ctx, run);
      return detail(tx, ctx, id, skipped);
    });
    return reply.status(201).send(out);
  });
  app.delete<{ Params: { id: string; adjId: string } }>('/payroll/runs/:id/adjustments/:adjId', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.run');
    const id = parse(z.uuid(), req.params.id), adjId = parse(z.uuid(), req.params.adjId);
    return ctx.tx(async (tx) => {
      const run = await editable(tx, ctx, id);
      const del = await tx.deleteFrom('payroll_adjustments').where('id', '=', adjId).where('run_id', '=', id).returning('id').executeTakeFirst();
      if (!del) throw notFound('Adjustment');
      await writeAudit(tx, auditOf(ctx), 'payroll_adjustment', adjId, 'delete', { runId: id }, null);
      return detail(tx, ctx, id, await computeRun(tx, ctx, run));
    });
  });

  app.post<{ Params: { id: string } }>('/payroll/runs/:id/overrides', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.run');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(ovBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const run = await editable(tx, ctx, id);
      const emp = await tx.selectFrom('employees').select('id').where('id', '=', b.employeeId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!emp) throw notFound('Employee');
      const set = { value: b.value, reason: b.reason, created_by: ctx.userId };
      await tx.insertInto('payroll_overrides').values({ tenant_id: ctx.tenantId, run_id: id, employee_id: b.employeeId, field: b.field, ...set })
        .onConflict((oc) => oc.columns(['run_id', 'employee_id', 'field']).doUpdateSet(set)).execute();
      await writeAudit(tx, auditOf(ctx), 'payroll_override', null, 'create', null, { runId: id, ...b });
      return detail(tx, ctx, id, await computeRun(tx, ctx, run));
    });
    return reply.status(201).send(out);
  });
  app.delete<{ Params: { id: string; employeeId: string; field: string } }>('/payroll/runs/:id/overrides/:employeeId/:field', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.run');
    const id = parse(z.uuid(), req.params.id), employeeId = parse(z.uuid(), req.params.employeeId);
    return ctx.tx(async (tx) => {
      const run = await editable(tx, ctx, id);
      const del = await tx.deleteFrom('payroll_overrides').where('run_id', '=', id).where('employee_id', '=', employeeId).where('field', '=', req.params.field).returning('id').executeTakeFirst();
      if (!del) throw notFound('Override');
      await writeAudit(tx, auditOf(ctx), 'payroll_override', null, 'delete', { runId: id, employeeId, field: req.params.field }, null);
      return detail(tx, ctx, id, await computeRun(tx, ctx, run));
    });
  });

  app.post<{ Params: { id: string } }>('/payroll/runs/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.run');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const run = await editable(tx, ctx, id);
      await tx.updateTable('payroll_lines').set({ is_live: false }).where('run_id', '=', id).execute();
      await tx.updateTable('payroll_runs').set({ status: 'cancelled' }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'payroll_run', id, 'cancel', { status: run.status }, { status: 'cancelled' });
      return runJson(await getRun(tx, ctx, id));
    });
  });

  app.post<{ Params: { id: string } }>('/payroll/runs/:id/approve', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.approve');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const run = await getRun(tx, ctx, id, true);
      if (run.status !== 'computed') throw conflict(`Only a computed run can be approved. This one is ${run.status}.`, 'RUN_STATE', { status: run.status });
      if ((await makers(tx, run)).has(ctx.userId)) throw new AppError(403, 'SELF_APPROVAL', MAKER_MSG);
      const lines = await loadLines(tx, id);
      if (!lines.length) throw conflict('The run has no employees.', 'RUN_EMPTY');
      const entry = await postAccrual(tx, ctx, run, lines);
      await onPayrollApproved(tx, ctx, run, lines.map((l) => l.employee_id)); // claims and loans (migration 049)
      for (const l of lines) if (l.esi_covered_until) await tx.updateTable('employees').set({ esi_covered_until: l.esi_covered_until }).where('id', '=', l.employee_id).execute();
      await tx.updateTable('payroll_runs').set({ status: 'approved', approved_by: ctx.userId, approved_at: new Date(), accrual_entry_id: entry }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'payroll_run', id, 'approve', { status: 'computed' }, { status: 'approved', entryId: entry });
      return detail(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/payroll/runs/:id/pay', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.approve');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ payDate: z.string().refine(isValidDate, 'Use YYYY-MM-DD').optional(), accountId: z.uuid().optional() }), req.body ?? {});
    return ctx.tx(async (tx) => {
      const run = await getRun(tx, ctx, id, true);
      if (run.status !== 'approved') throw conflict(`Only an approved run can be paid. This one is ${run.status}.`, 'RUN_STATE', { status: run.status });
      const sys = await systemAccounts(tx, ctx);
      let bank = sys.bank;
      if (b.accountId) {
        const a = await tx.selectFrom('accounts').select('id').where('id', '=', b.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!a) throw badRequest('Account not found.', { accountId: 'Not found' });
        bank = a.id;
      }
      const payable = await ensureAccount(tx, ctx, 'Net Salary Payable', 'liability', 2450);
      const payDate = b.payDate ?? todayIst();
      const entry = await postJournal(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId }, {
        date: payDate, voucherType: 'wages', voucherId: run.id, number: run.number, narration: `Salary paid for ${run.number}`,
        lines: [{ accountId: payable, amount: run.net, locationId: run.location_id }, { accountId: bank, amount: -run.net, locationId: run.location_id }],
      });
      await tx.updateTable('payroll_runs').set({ status: 'posted', paid_by: ctx.userId, paid_at: new Date(), pay_date: payDate, payout_entry_id: entry }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'payroll_run', id, 'pay', { status: 'approved' }, { status: 'posted', entryId: entry, payDate });
      return detail(tx, ctx, id);
    });
  });

  // Statutory summary and files -----------------------------------------------------------------

  async function finalRun(tx: Tx, ctx: RequestContext, id: string) {
    const run = await getRun(tx, ctx, id);
    if (run.status === 'draft' || run.status === 'cancelled') throw conflict('Compute the run first.', 'RUN_STATE', { status: run.status });
    return run;
  }
  const stateName = (code: string | null) => PT_RULES.find((r) => r.stateCode === code)?.state ?? (code ? `State ${code}` : 'Not set');

  app.get<{ Params: { id: string } }>('/payroll/runs/:id/statutory', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const run = await finalRun(tx, ctx, id);
      const lines = await loadLines(tx, id);
      const sum = (f: (l: LineRow) => number) => round2(lines.reduce((s, l) => s + f(l), 0));
      const members = lines.filter((l) => l.pf_wage > 0 && l.pf_employee + l.pf_eps + l.pf_epf_employer > 0).length;
      const byState = new Map<string, { employees: number; amount: number }>();
      for (const l of lines.filter((x) => x.pt > 0)) {
        const k = l.pt_state_code ?? '';
        const cur = byState.get(k) ?? { employees: 0, amount: 0 };
        byState.set(k, { employees: cur.employees + 1, amount: round2(cur.amount + l.pt) });
      }
      return {
        runId: id, month: run.month.slice(0, 7), status: run.status,
        pf: {
          members, wages: sum((l) => l.pf_wage), employee: sum((l) => l.pf_employee), eps: sum((l) => l.pf_eps), epfEmployer: sum((l) => l.pf_epf_employer),
          edli: sum((l) => l.pf_edli), admin: establishmentAdmin(sum((l) => l.pf_admin), members),
          total: round2(sum((l) => l.pf_employee + l.pf_eps + l.pf_epf_employer + l.pf_edli) + establishmentAdmin(sum((l) => l.pf_admin), members)),
        },
        esi: { members: lines.filter((l) => l.esi_employee + l.esi_employer > 0).length, wages: sum((l) => (l.esi_employee + l.esi_employer > 0 ? l.esi_wage : 0)), employee: sum((l) => l.esi_employee), employer: sum((l) => l.esi_employer), total: sum((l) => l.esi_employee + l.esi_employer) },
        pt: [...byState.entries()].map(([code, v]) => ({ stateCode: code, state: stateName(code || null), ...v })),
        lwf: { employee: sum((l) => l.lwf_employee), employer: sum((l) => l.lwf_employer) },
        tds: sum((l) => l.tds),
        note: 'Rates and tables need a CA check before real filing.',
      };
    });
  });

  const fileKinds = ['bank', 'ecr', 'esi', 'pt'] as const;
  app.get<{ Params: { id: string; kind: string } }>('/payroll/runs/:id/files/:kind', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.view');
    const id = parse(z.uuid(), req.params.id);
    const kind = parse(z.enum(fileKinds), req.params.kind);
    const { name, type, body } = await ctx.tx(async (tx) => {
      const run = await finalRun(tx, ctx, id);
      if (kind === 'bank' && run.status !== 'approved' && run.status !== 'posted') throw conflict('Approve the run before making the bank file.', 'RUN_STATE', { status: run.status });
      const lines = await loadLines(tx, id);
      const emps = await tx.selectFrom('employees').selectAll().where('id', 'in', lines.map((l) => l.employee_id).concat('00000000-0000-0000-0000-000000000000')).execute();
      const emp = (eid: string) => emps.find((e) => e.id === eid)!;
      const m = run.month.slice(0, 7);
      if (kind === 'bank') {
        const rows = lines.filter((l) => l.net > 0 && emp(l.employee_id).salary_mode === 'bank');
        const missing = rows.filter((l) => !emp(l.employee_id).bank_account || !emp(l.employee_id).bank_ifsc);
        if (missing.length) throw conflict(`Bank details are missing for ${missing.map((l) => l.emp_name).join(', ')}.`, 'MISSING_BANK', { employees: missing.map((l) => l.emp_name) });
        return { name: `salary-${m}.csv`, type: 'text/csv; charset=utf-8', body: toCsv(['Employee code', 'Name', 'Account number', 'IFSC', 'Bank', 'Amount', 'Narration'],
          rows.map((l) => [l.emp_code, l.emp_name, emp(l.employee_id).bank_account, emp(l.employee_id).bank_ifsc, emp(l.employee_id).bank_name, l.net.toFixed(2), `Salary ${m}`])) };
      }
      if (kind === 'ecr') {
        const rows = lines.filter((l) => l.pf_wage > 0 && l.pf_employee + l.pf_eps + l.pf_epf_employer > 0);
        const missing = rows.filter((l) => !emp(l.employee_id).uan);
        if (missing.length) throw conflict(`UAN is missing for ${missing.map((l) => l.emp_name).join(', ')}.`, 'MISSING_UAN', { employees: missing.map((l) => l.emp_name) });
        const ecrCeiling = ratesInForce(await companyRateRows(tx, ctx.companyId), run.month, null).epf.ceiling;
        const text = rows.map((l) => {
          const e = emp(l.employee_id);
          const ceiling = ecrCeiling;
          const epfWage = e.pf_higher_wage ? l.pf_wage : Math.min(l.pf_wage, ceiling);
          const epsWage = Math.min(l.pf_wage, ceiling);
          return [e.uan, l.emp_name.toUpperCase(), Math.round(l.gross), Math.round(epfWage), Math.round(epsWage), Math.round(epsWage), l.pf_employee, l.pf_eps, l.pf_epf_employer, Math.max(0, Math.round(l.working_days - l.paid_days)), 0].join('#~#');
        }).join('\n');
        return { name: `ecr-${m}.txt`, type: 'text/plain; charset=utf-8', body: `${text}\n` };
      }
      if (kind === 'esi') {
        const rows = lines.filter((l) => l.esi_employee + l.esi_employer > 0);
        const missing = rows.filter((l) => !emp(l.employee_id).esi_number);
        if (missing.length) throw conflict(`ESI number is missing for ${missing.map((l) => l.emp_name).join(', ')}.`, 'MISSING_ESI', { employees: missing.map((l) => l.emp_name) });
        return { name: `esi-${m}.csv`, type: 'text/csv; charset=utf-8', body: toCsv(['IP number', 'IP name', 'No of days', 'Total monthly wages', 'Reason code for zero days', 'Last working day'],
          rows.map((l) => [emp(l.employee_id).esi_number, l.emp_name, Math.round(l.paid_days), l.esi_wage.toFixed(2), '', emp(l.employee_id).leaving_date ?? ''])) };
      }
      const byState = new Map<string, { employees: number; amount: number }>();
      for (const l of lines.filter((x) => x.pt > 0)) {
        const k = l.pt_state_code ?? '';
        const cur = byState.get(k) ?? { employees: 0, amount: 0 };
        byState.set(k, { employees: cur.employees + 1, amount: round2(cur.amount + l.pt) });
      }
      return { name: `pt-${m}.csv`, type: 'text/csv; charset=utf-8', body: toCsv(['State code', 'State', 'Employees', 'Professional tax'], [...byState.entries()].map(([c, v]) => [c, stateName(c || null), v.employees, v.amount.toFixed(2)])) };
    });
    return reply.header('content-disposition', `attachment; filename="${name}"`).type(type).send(body);
  });

  // Payslips and self service -----------------------------------------------------------------

  app.get('/payroll/me', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.self');
    return ctx.tx(async (tx) => {
      const e = await myEmployee(tx, ctx);
      return e ? { employee: { id: e.id, code: e.code, name: e.name, department: e.department, designation: e.designation, joiningDate: e.joining_date } } : { employee: null };
    });
  });

  app.get('/payroll/payslips', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.self');
    const q = parse(pagingQuery.extend({ employeeId: z.uuid().optional(), month: monthField.optional(), mine: z.enum(['true', 'false']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      const me = await myEmployee(tx, ctx);
      const mineOnly = !ctx.can('payroll.view') || q.mine === 'true';
      let base = tx.selectFrom('payroll_lines as l').innerJoin('payroll_runs as r', 'r.id', 'l.run_id').innerJoin('employees as e', 'e.id', 'l.employee_id')
        .where('l.company_id', '=', ctx.companyId).where('l.is_live', '=', true);
      if (mineOnly) {
        if (!me) return { data: [], total: 0 };
        base = base.where('l.employee_id', '=', me.id).where('r.status', 'in', ['approved', 'posted']);
      } else {
        base = base.where('r.status', '<>', 'cancelled');
        const scope = scopedLocationIds(ctx);
        if (scope) base = base.where('e.location_id', 'in', scope);
        if (q.employeeId) base = base.where('l.employee_id', '=', q.employeeId);
      }
      if (q.month) base = base.where('l.month', '=', q.month);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.select(['l.id', 'l.employee_id', 'l.month', 'l.gross', 'l.net', 'r.status', 'r.id as run_id', 'e.name', 'e.code']).orderBy('l.month', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map((r) => ({ id: r.id, employeeId: r.employee_id, employeeName: r.name, employeeCode: r.code, month: r.month.slice(0, 7), gross: r.gross, net: r.net, runId: r.run_id, runStatus: r.status })), total };
    });
  });

  app.get<{ Params: { id: string } }>('/payroll/payslips/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.self');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const l = await tx.selectFrom('payroll_lines').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!l) throw notFound('Payslip');
      const run = await getRun(tx, ctx, l.run_id);
      const me = await myEmployee(tx, ctx);
      const own = me?.id === l.employee_id;
      if (!ctx.can('payroll.view') && !own) throw notFound('Payslip');
      if (!ctx.can('payroll.view') && run.status !== 'approved' && run.status !== 'posted') throw notFound('Payslip');
      const e = await tx.selectFrom('employees').selectAll().where('id', '=', l.employee_id).executeTakeFirstOrThrow();
      const c = await tx.selectFrom('companies').select(['name', 'legal_name', 'address', 'pan', 'tan', 'gstin']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const ytdRows = await tx.selectFrom('payroll_lines').select(['gross', 'net', 'tds', 'pf_employee', 'pt', 'esi_employee', 'other_ded_total', 'lwf_employee']).where('employee_id', '=', l.employee_id)
        .where('is_live', '=', true).where('month', '>=', fyStartOf(l.month)).where('month', '<=', l.month).execute();
      const t = (f: (r: (typeof ytdRows)[number]) => number) => round2(ytdRows.reduce((s, r) => s + f(r), 0));
      const earnings = (l.earnings as { name: string; amount: number }[]).map((x) => ({ name: x.name, amount: x.amount }));
      for (const a of (l.adjustments as AdjustmentInput[]).filter((x) => x.kind === 'earning')) earnings.push({ name: a.label, amount: a.amount });
      const deductions = [
        { name: 'Provident fund', amount: l.pf_employee }, { name: 'ESI', amount: l.esi_employee }, { name: 'Professional tax', amount: l.pt },
        { name: 'Labour welfare fund', amount: l.lwf_employee }, { name: 'Income tax (TDS)', amount: l.tds },
        ...(l.other_deductions as { label: string; amount: number }[]).map((d) => ({ name: d.label, amount: d.amount })),
      ].filter((d) => d.amount > 0);
      const employer = [
        { name: 'Provident fund (employer)', amount: round2(l.pf_eps + l.pf_epf_employer) }, { name: 'EDLI and PF admin', amount: round2(l.pf_edli + l.pf_admin) },
        { name: 'ESI (employer)', amount: l.esi_employer }, { name: 'LWF (employer)', amount: l.lwf_employer },
      ].filter((d) => d.amount > 0);
      const mask = (v: string | null) => (v ? `${'X'.repeat(Math.max(0, v.length - 4))}${v.slice(-4)}` : null);
      return {
        id: l.id, runId: l.run_id, runNumber: run.number, runStatus: run.status, month: l.month.slice(0, 7),
        company: { name: c.legal_name ?? c.name, address: c.address, pan: c.pan, tan: c.tan },
        employee: { id: e.id, code: e.code, name: e.name, designation: e.designation, department: e.department, joiningDate: e.joining_date, pan: mask(e.pan), uan: e.uan, esiNumber: e.esi_number, bankAccount: mask(e.bank_account), bankName: e.bank_name },
        workingDays: l.working_days, paidDays: l.paid_days, lopDays: l.lop_days, earnings, deductions, employerContributions: employer,
        gross: l.gross, totalDeductions: dedOf(l), net: l.net,
        ytd: { gross: t((r) => r.gross), deductions: t((r) => r.gross - r.net), tds: t((r) => r.tds), net: t((r) => r.net) },
      };
    });
  });
}

documentRoute('POST', '/payroll/runs', { body: createBody });
documentRoute('POST', '/payroll/runs/:id/adjustments', { body: adjBody });
documentRoute('POST', '/payroll/runs/:id/overrides', { body: ovBody });
