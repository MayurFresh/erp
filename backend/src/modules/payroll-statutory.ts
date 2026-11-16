// Statutory payroll: dated rates, Labour Code wages rule, gratuity report, bonus, leave encashment, shifts and overtime.
// Full and final settlement is in payroll-fnf.ts. Maths is in lib/payroll/statutory.ts and rates.ts.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { basicFlags, loadStatSettings, wageRuleFor, companyRateRows, type StatSettings } from '../lib/payroll/load.ts';
import { round2 } from '../lib/payroll/money.ts';
import { BUILT_IN_RATES, ratesInForce, type RateRow } from '../lib/payroll/rates.ts';
import { BONUS_MAX_PCT, BONUS_MIN_PCT, bonusFor, encashment, gratuityFigures, monthlyWages, type GratuityFigures, type WageLine } from '../lib/payroll/statutory.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { ensureLeaveTypes, leaveBalances, salaryFor } from './hr.ts';
import { computeRun, getRun } from './payroll.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const monthField = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM').transform((v) => `${v}-01`);
const lastDay = (m: string) => `${m.slice(0, 8)}${String(new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)), 0)).getUTCDate()).padStart(2, '0')}`;
const fyField = z.coerce.number().int().min(2000).max(2100);

/** Wage figures for an employee from the salary revision in force on a date. */
export async function wagesOf(tx: Tx, ctx: { companyId: string }, employeeId: string, asOf: string, stat: StatSettings, basics?: Map<string, boolean>) {
  const flags = basics ?? await basicFlags(tx, ctx.companyId);
  const monthStart = `${asOf.slice(0, 7)}-01`;
  const sal = await salaryFor(tx, employeeId, monthStart, lastDay(monthStart));
  if (!sal) return null;
  const lines: WageLine[] = sal.lines.filter((l) => l.kind === 'earning').map((l) => ({ code: l.code, amount: l.amount, isBasic: flags.get(l.component_id) ?? false }));
  return { ...monthlyWages(lines, wageRuleFor(stat, asOf)), monthlyGross: round2(lines.reduce((s, l) => s + l.amount, 0)) };
}

const settingsBody = z.object({
  wagesRuleEnabled: z.boolean(), wagesRuleFrom: dateField, wagesRulePercent: z.coerce.number().min(1).max(100), minimumWage: moneyField,
  bonusPct: z.coerce.number().min(BONUS_MIN_PCT, `At least ${BONUS_MIN_PCT}`).max(BONUS_MAX_PCT, `At most ${BONUS_MAX_PCT}`),
  bonusEligibilityCeiling: moneyField, bonusCalcCeiling: moneyField, bonusMinDays: z.coerce.number().int().min(0).max(366),
  gratuityYears: z.coerce.number().int().min(1).max(30), gratuityFixedTermYears: z.coerce.number().int().min(1).max(30),
  gratuityCap: moneyField, leaveExemptCap: moneyField, otMultiplier: z.coerce.number().min(1).max(5), hoursPerDay: z.coerce.number().min(1).max(24),
}).partial();

const num = z.coerce.number().min(0).max(1e9);
const rateBody = z.discriminatedUnion('kind', [
  z.object({ kind: z.literal('epf'), effectiveFrom: dateField, note: optionalText(300), config: z.object({
    ceiling: num, epsCeiling: num.optional(), epsBps: num.default(833), edliBps: num.default(50), adminBps: num.default(50), adminMin: num.default(500) }) }),
  z.object({ kind: z.literal('esi'), effectiveFrom: dateField, note: optionalText(300), config: z.object({
    ceiling: num, employeeBps: num.default(75), employerBps: num.default(325), dailyExempt: num.default(176) }) }),
  z.object({ kind: z.literal('pt'), stateCode: z.string().regex(/^\d{2}$/), effectiveFrom: dateField, note: optionalText(300), config: z.object({
    periodicity: z.enum(['monthly', 'half_yearly']), deductMonths: z.array(z.number().int().min(1).max(12)).optional(),
    monthOverride: z.array(z.object({ month: z.number().int().min(1).max(12), amount: num, minSlabAmount: num })).optional(),
    slabs: z.array(z.object({ from: num, to: num.nullable(), amount: num, sex: z.enum(['M', 'F']).optional() })).min(1) }) }),
  z.object({ kind: z.literal('lwf'), stateCode: z.string().regex(/^\d{2}$/), effectiveFrom: dateField, note: optionalText(300), config: z.object({
    employee: num, employer: num, months: z.array(z.number().int().min(1).max(12)).min(1) }) }),
]);

const shiftBody = z.object({
  name: z.string().trim().min(1).max(60), startTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:MM'),
  endTime: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:MM'), breakMinutes: z.coerce.number().int().min(0).max(480).default(0), isActive: z.boolean().optional(),
});

export async function payrollStatutoryRoutes(app: FastifyInstance) {
  const settingsJson = (s: StatSettings) => ({ ...s });

  // Settings -----------------------------------------------------------------------------------------
  app.get('/payroll/statutory/settings', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view', 'payroll.employees');
    return ctx.tx(async (tx) => ({
      ...settingsJson(await loadStatSettings(tx, ctx.companyId)),
      notes: {
        wagesRule: 'Off until you turn it on. The Code on Wages 50% rule is reported in force from 21 Nov 2025; confirm with your CA before turning it on.',
        epfCeiling: 'The 25,000 EPF ceiling from 17 Sep 2026 comes from secondary sources of S.O. 5109(E); read the Gazette before filing.',
      },
    }));
  });
  for (const method of ['put', 'patch'] as const) {
    app[method]('/payroll/statutory/settings', async (req) => {
      const ctx = req.ctx; ctx.require('payroll.employees');
      const b = parse(settingsBody, req.body);
      return ctx.tx(async (tx) => {
        const cur = await loadStatSettings(tx, ctx.companyId);
        const n = { ...cur, ...Object.fromEntries(Object.entries(b).filter(([, v]) => v !== undefined)) } as StatSettings;
        const v = {
          wages_rule_enabled: n.wagesRuleEnabled, wages_rule_from: n.wagesRuleFrom, wages_rule_percent: n.wagesRulePercent, minimum_wage: n.minimumWage,
          bonus_pct: n.bonusPct, bonus_eligibility_ceiling: n.bonusEligibilityCeiling, bonus_calc_ceiling: n.bonusCalcCeiling, bonus_min_days: n.bonusMinDays,
          gratuity_years: n.gratuityYears, gratuity_fixed_term_years: n.gratuityFixedTermYears, gratuity_cap: n.gratuityCap, leave_exempt_cap: n.leaveExemptCap,
          ot_multiplier: n.otMultiplier, hours_per_day: n.hoursPerDay,
        };
        await tx.insertInto('payroll_statutory_settings').values({ company_id: ctx.companyId, tenant_id: ctx.tenantId, ...v })
          .onConflict((oc) => oc.column('company_id').doUpdateSet(v)).execute();
        await writeAudit(tx, auditOf(ctx), 'payroll_statutory_settings', ctx.companyId, 'update', cur, n);
        return settingsJson(n);
      });
    });
  }

  // Dated rates --------------------------------------------------------------------------------------
  app.get('/payroll/statutory/rates', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view', 'payroll.employees');
    const q = parse(z.object({ month: monthField.optional(), stateCode: z.string().regex(/^\d{2}$/).optional() }), req.query);
    return ctx.tx(async (tx) => {
      const company = await companyRateRows(tx, ctx.companyId);
      const month = q.month ?? `${todayIst().slice(0, 7)}-01`;
      const inForce = ratesInForce(company, month, q.stateCode ?? null);
      const rows: RateRow[] = [...BUILT_IN_RATES, ...company].sort((a, b) => a.kind.localeCompare(b.kind) || (a.stateCode ?? '').localeCompare(b.stateCode ?? '') || a.effectiveFrom.localeCompare(b.effectiveFrom));
      return { month: month.slice(0, 7), inForce, data: rows.map((r) => ({ id: r.id ?? null, kind: r.kind, stateCode: r.stateCode, effectiveFrom: r.effectiveFrom, config: r.config, note: r.note ?? null, source: r.source })) };
    });
  });
  app.post('/payroll/statutory/rates', async (req, reply) => {
    const ctx = req.ctx; ctx.require('payroll.employees');
    const b = parse(rateBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const state = 'stateCode' in b ? b.stateCode : null;
      const dup = await tx.selectFrom('payroll_rate_rows').select('id').where('company_id', '=', ctx.companyId).where('kind', '=', b.kind)
        .where('effective_from', '=', b.effectiveFrom).$if(!!state, (qb) => qb.where('state_code', '=', state)).$if(!state, (qb) => qb.where('state_code', 'is', null)).executeTakeFirst();
      if (dup) throw conflict('A row for this date already exists. Delete it first or pick another date.', 'RATE_EXISTS');
      const r = await tx.insertInto('payroll_rate_rows').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: b.kind, state_code: state, effective_from: b.effectiveFrom,
        config: JSON.stringify(b.kind === 'epf' ? { ...b.config, epsCeiling: b.config.epsCeiling ?? b.config.ceiling } : b.config), note: b.note ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'payroll_rate_row', r.id, 'create', null, b);
      return { id: r.id };
    });
    return reply.status(201).send(out);
  });
  app.delete<{ Params: { id: string } }>('/payroll/statutory/rates/:id', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.employees');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const d = await tx.deleteFrom('payroll_rate_rows').where('id', '=', id).where('company_id', '=', ctx.companyId).returning('id').executeTakeFirst();
      if (!d) throw notFound('Rate row');
      await writeAudit(tx, auditOf(ctx), 'payroll_rate_row', id, 'delete', null, null);
      return { ok: true };
    });
  });

  // Labour Code wages rule: employees affected in a run -------------------------------------------------
  app.get<{ Params: { id: string } }>('/payroll/runs/:id/wage-rule', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const run = await getRun(tx, ctx, id);
      const stat = await loadStatSettings(tx, ctx.companyId);
      const rule = wageRuleFor(stat, run.month);
      const rows = await tx.selectFrom('payroll_lines as l').innerJoin('employees as e', 'e.id', 'l.employee_id').leftJoin('payroll_line_extras as x', 'x.line_id', 'l.id')
        .select(['e.code', 'e.name', 'l.gross', 'l.pf_wage', 'x.wage_rule_addback']).where('l.run_id', '=', id).orderBy('e.code').execute();
      const affected = rows.filter((r) => (r.wage_rule_addback ?? 0) > 0);
      return {
        runId: id, month: run.month.slice(0, 7), active: rule.active, percent: rule.percent, employeeCount: rows.length,
        affected: affected.map((r) => ({ code: r.code, name: r.name, gross: r.gross, addback: r.wage_rule_addback, pfWage: r.pf_wage })),
        totalAddback: round2(affected.reduce((s, r) => s + (r.wage_rule_addback ?? 0), 0)),
      };
    });
  });

  // Employee flags --------------------------------------------------------------------------------------
  app.get<{ Params: { id: string } }>('/payroll/employees/:id/statutory', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const e = await tx.selectFrom('employees').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!e) throw notFound('Employee');
      const f = await tx.selectFrom('employee_statutory').select('fixed_term').where('employee_id', '=', id).executeTakeFirst();
      return { employeeId: id, fixedTerm: f?.fixed_term ?? false };
    });
  });
  for (const method of ['put', 'patch'] as const) {
    app[method]<{ Params: { id: string } }>('/payroll/employees/:id/statutory', async (req) => {
      const ctx = req.ctx; ctx.require('payroll.employees');
      const id = parse(z.uuid(), req.params.id);
      const b = parse(z.object({ fixedTerm: z.boolean() }), req.body);
      return ctx.tx(async (tx) => {
        const e = await tx.selectFrom('employees').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!e) throw notFound('Employee');
        await tx.insertInto('employee_statutory').values({ employee_id: id, tenant_id: ctx.tenantId, fixed_term: b.fixedTerm })
          .onConflict((oc) => oc.column('employee_id').doUpdateSet({ fixed_term: b.fixedTerm })).execute();
        return { employeeId: id, fixedTerm: b.fixedTerm };
      });
    });
  }

  // Gratuity liability ----------------------------------------------------------------------------------
  app.get('/payroll/gratuity/report', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    const q = parse(z.object({ month: monthField.optional() }), req.query);
    return ctx.tx(async (tx) => {
      const month = q.month ?? `${todayIst().slice(0, 7)}-01`;
      const asOf = lastDay(month);
      const prevEnd = (() => { const d = new Date(`${month}T00:00:00Z`); d.setUTCDate(0); return d.toISOString().slice(0, 10); })();
      const stat = await loadStatSettings(tx, ctx.companyId);
      const basics = await basicFlags(tx, ctx.companyId);
      const rules = { years: stat.gratuityYears, fixedTermYears: stat.gratuityFixedTermYears, cap: stat.gratuityCap };
      let eq = tx.selectFrom('employees').selectAll().where('company_id', '=', ctx.companyId).where('joining_date', '<=', asOf).where('status', '=', 'active')
        .where((eb) => eb.or([eb('leaving_date', 'is', null), eb('leaving_date', '>', asOf)]));
      const scope = scopedLocationIds(ctx);
      if (scope) eq = eq.where('location_id', 'in', scope);
      const emps = await eq.orderBy('code').execute();
      const flags = new Map((await tx.selectFrom('employee_statutory').select(['employee_id', 'fixed_term']).execute()).map((f) => [f.employee_id, f.fixed_term]));
      const data: (GratuityFigures & { employeeId: string; code: string; name: string; joiningDate: string; fixedTerm: boolean; wages: number; movement: number })[] = [];
      for (const e of emps) {
        const w = await wagesOf(tx, ctx, e.id, asOf, stat, basics);
        if (!w) continue;
        const fixedTerm = flags.get(e.id) ?? false;
        const now = gratuityFigures({ joining: e.joining_date, asOf, wages: w.wages, fixedTerm, rules });
        const before = prevEnd >= e.joining_date ? gratuityFigures({ joining: e.joining_date, asOf: prevEnd, wages: w.wages, fixedTerm, rules }).accrued : 0;
        data.push({ employeeId: e.id, code: e.code, name: e.name, joiningDate: e.joining_date, fixedTerm, wages: w.wages, ...now, movement: now.accrued - before });
      }
      const sum = (f: (r: (typeof data)[number]) => number) => round2(data.reduce((s, r) => s + f(r), 0));
      return { month: month.slice(0, 7), asOf, rules, data, totals: { accrued: sum((r) => r.accrued), payable: sum((r) => r.payable), movement: sum((r) => r.movement) } };
    });
  });

  // Statutory bonus -------------------------------------------------------------------------------------
  async function bonusPreview(tx: Tx, ctx: RequestContext, fy: number, pct: number) {
    const stat = await loadStatSettings(tx, ctx.companyId);
    const basics = await basicFlags(tx, ctx.companyId);
    const from = `${fy}-04-01`, to = `${fy + 1}-03-01`;
    const lines = await tx.selectFrom('payroll_lines').select(['employee_id', 'month', 'paid_days', 'working_days']).where('company_id', '=', ctx.companyId)
      .where('is_live', '=', true).where('month', '>=', from).where('month', '<=', to).orderBy('month').execute();
    const paid = await tx.selectFrom('bonus_payouts').select('employee_id').where('company_id', '=', ctx.companyId).where('fy', '=', fy).execute();
    const done = new Set(paid.map((p) => p.employee_id));
    const emps = await tx.selectFrom('employees').select(['id', 'code', 'name']).where('company_id', '=', ctx.companyId)
      .where('id', 'in', [...new Set(lines.map((l) => l.employee_id)), '00000000-0000-0000-0000-000000000000']).orderBy('code').execute();
    const rules = { pct, eligibilityCeiling: stat.bonusEligibilityCeiling, calcCeiling: stat.bonusCalcCeiling, minimumWage: stat.minimumWage, minDays: stat.bonusMinDays };
    const data = [];
    for (const e of emps) {
      const mine = lines.filter((l) => l.employee_id === e.id);
      const monthsPaid = mine.reduce((s, l) => s + (l.working_days > 0 ? l.paid_days / l.working_days : 0), 0);
      const daysWorked = mine.reduce((s, l) => s + l.paid_days, 0);
      const w = await wagesOf(tx, ctx, e.id, mine.at(-1)!.month, stat, basics);
      if (!w) continue;
      const r = bonusFor({ monthlyWage: w.wages, monthsPaid, daysWorked, rules });
      data.push({ employeeId: e.id, code: e.code, name: e.name, monthlyWage: w.wages, calcWage: r.calcWage, monthsPaid: Math.round(monthsPaid * 100) / 100,
        daysWorked: Math.round(daysWorked * 100) / 100, eligible: r.eligible, reason: r.reason, amount: r.amount, alreadyPaid: done.has(e.id) });
    }
    return { fy, pct, rules, data, total: round2(data.filter((d) => d.eligible && !d.alreadyPaid).reduce((s, d) => s + d.amount, 0)) };
  }
  const bonusQuery = z.object({ fy: fyField, pct: z.coerce.number().min(BONUS_MIN_PCT).max(BONUS_MAX_PCT).optional() });
  app.get('/payroll/bonus/preview', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    const q = parse(bonusQuery, req.query);
    return ctx.tx(async (tx) => bonusPreview(tx, ctx, q.fy, q.pct ?? (await loadStatSettings(tx, ctx.companyId)).bonusPct));
  });
  async function openRun(tx: Tx, ctx: RequestContext, runId: string) {
    const run = await getRun(tx, ctx, runId, true);
    if (run.status !== 'draft' && run.status !== 'computed') throw conflict(`This run is ${run.status} and can no longer be changed.`, 'RUN_LOCKED');
    return run;
  }
  app.post('/payroll/bonus/run', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.run');
    const b = parse(bonusQuery.extend({ runId: z.uuid() }), req.body);
    return ctx.tx(async (tx) => {
      const run = await openRun(tx, ctx, b.runId);
      const pct = b.pct ?? (await loadStatSettings(tx, ctx.companyId)).bonusPct;
      const pv = await bonusPreview(tx, ctx, b.fy, pct);
      const todo = pv.data.filter((d) => d.eligible && !d.alreadyPaid && d.amount > 0);
      for (const d of todo) {
        await tx.insertInto('bonus_payouts').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: d.employeeId, fy: b.fy, pct, amount: d.amount, run_id: run.id, created_by: ctx.userId }).execute();
        await tx.insertInto('payroll_adjustments').values({ tenant_id: ctx.tenantId, run_id: run.id, employee_id: d.employeeId, kind: 'earning', label: `Statutory bonus ${b.fy}-${String(b.fy + 1).slice(2)}`, amount: d.amount, taxable: true, reason: `${pct}% bonus`, created_by: ctx.userId }).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'bonus_run', run.id, 'create', null, { fy: b.fy, pct, employees: todo.length });
      if (todo.length) await computeRun(tx, ctx, run);
      return { runId: run.id, fy: b.fy, pct, posted: todo.length, total: round2(todo.reduce((s, d) => s + d.amount, 0)) };
    });
  });

  // Leave encashment ---------------------------------------------------------------------------------------
  app.get('/payroll/leave-encashment/types', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view', 'payroll.employees');
    return ctx.tx(async (tx) => {
      await ensureLeaveTypes(tx, ctx);
      const rows = await tx.selectFrom('leave_types as t').leftJoin('leave_type_encashment as x', 'x.leave_type_id', 't.id')
        .select(['t.id', 't.code', 't.name', 't.is_paid', 'x.encashable', 'x.max_days']).where('t.company_id', '=', ctx.companyId).where('t.is_active', '=', true).orderBy('t.code').execute();
      return { data: rows.map((r) => ({ leaveTypeId: r.id, code: r.code, name: r.name, isPaid: r.is_paid, encashable: r.encashable ?? false, maxDays: r.max_days ?? 0 })) };
    });
  });
  for (const method of ['put', 'patch'] as const) {
    app[method]<{ Params: { id: string } }>('/payroll/leave-encashment/types/:id', async (req) => {
      const ctx = req.ctx; ctx.require('payroll.employees');
      const id = parse(z.uuid(), req.params.id);
      const b = parse(z.object({ encashable: z.boolean(), maxDays: z.coerce.number().min(0).max(366) }), req.body);
      return ctx.tx(async (tx) => {
        const t = await tx.selectFrom('leave_types').select(['id', 'is_paid']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!t) throw notFound('Leave type');
        if (b.encashable && !t.is_paid) throw badRequest('Only paid leave can be encashed.', { encashable: 'Unpaid leave type' });
        await tx.insertInto('leave_type_encashment').values({ leave_type_id: id, tenant_id: ctx.tenantId, encashable: b.encashable, max_days: b.maxDays })
          .onConflict((oc) => oc.column('leave_type_id').doUpdateSet({ encashable: b.encashable, max_days: b.maxDays })).execute();
        await writeAudit(tx, auditOf(ctx), 'leave_type_encashment', id, 'update', null, b);
        return { leaveTypeId: id, ...b };
      });
    });
  }
  async function encashPreview(tx: Tx, ctx: RequestContext, fy: number) {
    const stat = await loadStatSettings(tx, ctx.companyId);
    const basics = await basicFlags(tx, ctx.companyId);
    const types = await tx.selectFrom('leave_type_encashment as x').innerJoin('leave_types as t', 't.id', 'x.leave_type_id')
      .select(['t.id', 't.code', 't.name', 'x.max_days']).where('t.company_id', '=', ctx.companyId).where('x.encashable', '=', true).where('t.is_active', '=', true).execute();
    const done = await tx.selectFrom('leave_encashments').select(['employee_id', 'leave_type_id', 'days']).where('company_id', '=', ctx.companyId).where('fy', '=', fy).execute();
    const emps = await tx.selectFrom('employees').select(['id', 'code', 'name']).where('company_id', '=', ctx.companyId).where('status', '=', 'active').orderBy('code').execute();
    const asOf = `${fy + 1}-03-31`;
    const data: { employeeId: string; code: string; name: string; leaveTypeId: string; leaveType: string; balance: number; days: number; wages: number; rate: number; amount: number }[] = [];
    for (const e of emps) {
      const w = await wagesOf(tx, ctx, e.id, asOf < todayIst() ? asOf : todayIst(), stat, basics);
      if (!w) continue;
      const bal = await leaveBalances(tx, ctx.companyId, e.id, fy);
      for (const t of types) {
        const b = bal.find((x) => x.leaveTypeId === t.id);
        if (!b || !b.balance || b.balance <= 0) continue;
        const already = done.filter((d) => d.employee_id === e.id && d.leave_type_id === t.id).reduce((s, d) => s + d.days, 0);
        const r = encashment({ balance: b.balance, maxDays: Math.max(0, t.max_days - already), wages: w.wages });
        if (r.days > 0) data.push({ employeeId: e.id, code: e.code, name: e.name, leaveTypeId: t.id, leaveType: t.name, balance: b.balance, days: r.days, wages: w.wages, rate: r.rate, amount: r.amount });
      }
    }
    return { fy, data, total: round2(data.reduce((s, d) => s + d.amount, 0)) };
  }
  app.get('/payroll/leave-encashment/preview', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    const q = parse(z.object({ fy: fyField }), req.query);
    return ctx.tx((tx) => encashPreview(tx, ctx, q.fy));
  });
  app.post('/payroll/leave-encashment/run', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.run');
    const b = parse(z.object({ fy: fyField, runId: z.uuid() }), req.body);
    return ctx.tx(async (tx) => {
      const run = await openRun(tx, ctx, b.runId);
      const pv = await encashPreview(tx, ctx, b.fy);
      const byEmp = new Map<string, number>();
      for (const d of pv.data) {
        await tx.insertInto('leave_adjustments').values({ tenant_id: ctx.tenantId, employee_id: d.employeeId, leave_type_id: d.leaveTypeId, fy: b.fy, days: -d.days, reason: 'Leave encashment', created_by: ctx.userId }).execute();
        await tx.insertInto('leave_encashments').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: d.employeeId, leave_type_id: d.leaveTypeId, fy: b.fy, days: d.days, amount: d.amount, kind: 'yearly', run_id: run.id, created_by: ctx.userId }).execute();
        byEmp.set(d.employeeId, (byEmp.get(d.employeeId) ?? 0) + d.amount);
      }
      for (const [employeeId, amount] of byEmp) {
        await tx.insertInto('payroll_adjustments').values({ tenant_id: ctx.tenantId, run_id: run.id, employee_id: employeeId, kind: 'earning', label: `Leave encashment ${b.fy}-${String(b.fy + 1).slice(2)}`, amount, taxable: true, reason: 'Yearly encashment', created_by: ctx.userId }).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'leave_encashment_run', run.id, 'create', null, { fy: b.fy, employees: byEmp.size });
      if (byEmp.size) await computeRun(tx, ctx, run);
      return { runId: run.id, fy: b.fy, employees: byEmp.size, total: pv.total };
    });
  });

  // Shifts and overtime ------------------------------------------------------------------------------------
  const shiftJson = (s: { id: string; name: string; start_time: string; end_time: string; break_minutes: number; is_active: boolean }) => ({
    id: s.id, name: s.name, startTime: s.start_time.slice(0, 5), endTime: s.end_time.slice(0, 5), breakMinutes: s.break_minutes, isActive: s.is_active,
  });
  app.get('/payroll/shifts', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view', 'payroll.employees', 'payroll.run');
    return ctx.tx(async (tx) => ({ data: (await tx.selectFrom('shifts').selectAll().where('company_id', '=', ctx.companyId).orderBy('start_time').execute()).map(shiftJson) }));
  });
  app.post('/payroll/shifts', async (req, reply) => {
    const ctx = req.ctx; ctx.require('payroll.employees');
    const b = parse(shiftBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('shifts').select('id').where('company_id', '=', ctx.companyId).where('name', '=', b.name).executeTakeFirst();
      if (dup) throw conflict('A shift with this name exists.', 'SHIFT_EXISTS');
      const r = await tx.insertInto('shifts').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, start_time: b.startTime, end_time: b.endTime, break_minutes: b.breakMinutes, is_active: b.isActive ?? true }).returningAll().executeTakeFirstOrThrow();
      return shiftJson(r);
    });
    return reply.status(201).send(out);
  });
  app.patch<{ Params: { id: string } }>('/payroll/shifts/:id', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.employees');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(shiftBody.partial(), req.body);
    return ctx.tx(async (tx) => {
      const set: Record<string, unknown> = {};
      if (b.name !== undefined) set.name = b.name;
      if (b.startTime !== undefined) set.start_time = b.startTime;
      if (b.endTime !== undefined) set.end_time = b.endTime;
      if (b.breakMinutes !== undefined) set.break_minutes = b.breakMinutes;
      if (b.isActive !== undefined) set.is_active = b.isActive;
      const r = Object.keys(set).length
        ? await tx.updateTable('shifts').set(set).where('id', '=', id).where('company_id', '=', ctx.companyId).returningAll().executeTakeFirst()
        : await tx.selectFrom('shifts').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!r) throw notFound('Shift');
      return shiftJson(r);
    });
  });
  app.get('/payroll/shift-log', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view', 'payroll.run');
    const q = parse(z.object({ month: monthField, employeeId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      let qb = tx.selectFrom('shift_logs').selectAll().where('company_id', '=', ctx.companyId).where('day', '>=', q.month).where('day', '<=', lastDay(q.month));
      if (q.employeeId) qb = qb.where('employee_id', '=', q.employeeId);
      const rows = await qb.orderBy('day').execute();
      const total = new Map<string, number>();
      for (const r of rows) total.set(r.employee_id, round2((total.get(r.employee_id) ?? 0) + r.ot_hours));
      return { month: q.month.slice(0, 7), data: rows.map((r) => ({ employeeId: r.employee_id, day: r.day, shiftId: r.shift_id, otHours: r.ot_hours })), otTotals: [...total].map(([employeeId, hours]) => ({ employeeId, hours })) };
    });
  });
  for (const method of ['put', 'patch'] as const) {
  app[method]('/payroll/shift-log', async (req) => {
      const ctx = req.ctx; ctx.require('payroll.run');
      const b = parse(z.object({ employeeId: z.uuid(), entries: z.array(z.object({ day: dateField, shiftId: z.uuid().nullable().optional(), otHours: z.coerce.number().min(0).max(24).default(0) })).min(1).max(62) }), req.body);
      return ctx.tx(async (tx) => {
        const e = await tx.selectFrom('employees').select('id').where('id', '=', b.employeeId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!e) throw notFound('Employee');
        for (const x of b.entries) {
          if (x.shiftId) {
            const s = await tx.selectFrom('shifts').select('id').where('id', '=', x.shiftId).where('company_id', '=', ctx.companyId).executeTakeFirst();
            if (!s) throw badRequest('Shift not found.', { shiftId: 'Not found' });
          }
          if (!x.shiftId && x.otHours === 0) {
            await tx.deleteFrom('shift_logs').where('employee_id', '=', b.employeeId).where('day', '=', x.day).execute();
            continue;
          }
          const v = { shift_id: x.shiftId ?? null, ot_hours: x.otHours, updated_by: ctx.userId };
          await tx.insertInto('shift_logs').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: b.employeeId, day: x.day, ...v })
            .onConflict((oc) => oc.columns(['employee_id', 'day']).doUpdateSet(v)).execute();
        }
        return { ok: true, saved: b.entries.length };
      });
    });
  }
}
