// Full and final settlement: draft -> approved (posted to the books, employee marked as left) -> paid.
// The exit month is worked out with the normal payroll line (computeLine), so PF, ESI, PT and TDS follow the same rules.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { computeLine, type AdjustmentInput } from '../lib/payroll/compute.ts';
import { basicFlags, companyRateRows, loadStatSettings, wageRuleFor } from '../lib/payroll/load.ts';
import { leaveYear } from '../lib/payroll/leave.ts';
import { round2 } from '../lib/payroll/money.ts';
import { prorate } from '../lib/payroll/proration.ts';
import { ratesInForce } from '../lib/payroll/rates.ts';
import { bonusFor, encashment, fnfLines, gratuityFigures, noticeAmount, toAdjustments, type FnfLine } from '../lib/payroll/statutory.ts';
import { nextNumber } from '../lib/series.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { leaveBalances, salaryFor } from './hr.ts';
import { ensureAccount, postAccrual, type LineRow } from './payroll.ts';
import { wagesOf } from './payroll-statutory.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const lastDay = (m: string) => `${m.slice(0, 8)}${String(new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)), 0)).getUTCDate()).padStart(2, '0')}`;
const fyStartOf = (m: string) => (Number(m.slice(5, 7)) >= 4 ? `${m.slice(0, 4)}-04-01` : `${Number(m.slice(0, 4)) - 1}-04-01`);

const inputBody = z.object({
  employeeId: z.uuid(), exitDate: dateField,
  noticeRequiredDays: z.coerce.number().int().min(0).max(365).default(0), noticeServedDays: z.coerce.number().int().min(0).max(365).default(0),
  noticeMode: z.enum(['none', 'recover', 'payout']).default('none'), lopDays: z.coerce.number().min(0).max(31).default(0),
  includeGratuity: z.boolean().default(true), includeLeave: z.boolean().default(true), includeBonus: z.boolean().default(false), leaveExempt: z.boolean().default(false),
  extraLines: z.array(z.object({ kind: z.enum(['earning', 'deduction']), label: z.string().trim().min(1).max(80), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), taxable: z.boolean().default(false) })).max(30).default([]),
  notes: optionalText(300),
});
type Input = z.infer<typeof inputBody>;

async function build(tx: Tx, ctx: RequestContext, b: Input) {
  const emp = await tx.selectFrom('employees').selectAll().where('id', '=', b.employeeId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!emp) throw notFound('Employee');
  if (b.exitDate < emp.joining_date) throw badRequest('The exit date is before the joining date.', { exitDate: 'Before joining' });
  const stat = await loadStatSettings(tx, ctx.companyId);
  const basics = await basicFlags(tx, ctx.companyId);
  const settings = await tx.selectFrom('payroll_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst();
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const monthStart = `${b.exitDate.slice(0, 7)}-01`, monthEnd = lastDay(monthStart);
  const sal = await salaryFor(tx, emp.id, monthStart, b.exitDate);
  if (!sal) throw badRequest('This employee has no salary structure.', { employeeId: 'No salary structure' });
  const wages = (await wagesOf(tx, ctx, emp.id, b.exitDate, stat, basics))!;
  const divisor = (settings?.lop_divisor ?? 'calendar') as 'calendar' | '30' | '26';
  const paidLine = await tx.selectFrom('payroll_lines').select('id').where('employee_id', '=', emp.id).where('month', '=', monthStart).where('is_live', '=', true).executeTakeFirst();

  // Gratuity
  const flag = await tx.selectFrom('employee_statutory').select('fixed_term').where('employee_id', '=', emp.id).executeTakeFirst();
  const gr = gratuityFigures({ joining: emp.joining_date, asOf: b.exitDate, wages: wages.wages, fixedTerm: flag?.fixed_term ?? false,
    rules: { years: stat.gratuityYears, fixedTermYears: stat.gratuityFixedTermYears, cap: stat.gratuityCap } });
  const gratuityPayable = b.includeGratuity ? gr.payable : 0;

  // Leave encashment on exit
  const fy = leaveYear(b.exitDate);
  const leaveRows: { leaveType: string; leaveTypeId: string; balance: number; days: number; amount: number }[] = [];
  if (b.includeLeave) {
    const types = await tx.selectFrom('leave_type_encashment as x').innerJoin('leave_types as t', 't.id', 'x.leave_type_id').select(['t.id', 't.name', 'x.max_days'])
      .where('t.company_id', '=', ctx.companyId).where('x.encashable', '=', true).execute();
    const bal = await leaveBalances(tx, ctx.companyId, emp.id, fy);
    for (const t of types) {
      const bl = bal.find((x) => x.leaveTypeId === t.id)?.balance ?? 0;
      const r = encashment({ balance: bl, maxDays: t.max_days, wages: wages.wages });
      if (r.amount > 0) leaveRows.push({ leaveType: t.name, leaveTypeId: t.id, balance: bl, days: r.days, amount: r.amount });
    }
  }
  const leaveTotal = round2(leaveRows.reduce((s, r) => s + r.amount, 0));

  // Pro rata bonus for the year of exit
  let bonus = 0, bonusNote: string | null = null;
  if (b.includeBonus) {
    const done = await tx.selectFrom('bonus_payouts').select('id').where('employee_id', '=', emp.id).where('fy', '=', fy).executeTakeFirst();
    if (done) bonusNote = 'Bonus for this year is already paid.';
    else {
      const lines = await tx.selectFrom('payroll_lines').select(['paid_days', 'working_days', 'month']).where('employee_id', '=', emp.id).where('is_live', '=', true)
        .where('month', '>=', `${fy}-04-01`).where('month', '<=', monthStart).execute();
      let monthsPaid = lines.reduce((s, l) => s + (l.working_days > 0 ? l.paid_days / l.working_days : 0), 0);
      let days = lines.reduce((s, l) => s + l.paid_days, 0);
      if (!paidLine) {
        const pr = prorate({ monthStart, joining: emp.joining_date, leaving: b.exitDate, lopDays: b.lopDays, divisor });
        monthsPaid += pr.fraction; days += pr.paidDays;
      }
      const r = bonusFor({ monthlyWage: wages.wages, monthsPaid, daysWorked: days, rules: { pct: stat.bonusPct, eligibilityCeiling: stat.bonusEligibilityCeiling, calcCeiling: stat.bonusCalcCeiling, minimumWage: stat.minimumWage, minDays: stat.bonusMinDays } });
      bonus = r.amount; bonusNote = r.reason;
    }
  }

  const notice = noticeAmount({ required: b.noticeRequiredDays, served: b.noticeServedDays, mode: b.noticeMode, monthlyGross: wages.monthlyGross });
  const lines: FnfLine[] = fnfLines({
    gratuity: { payable: gratuityPayable, cap: stat.gratuityCap }, leave: { amount: leaveTotal, exempt: b.leaveExempt, cap: stat.leaveExemptCap },
    bonus, notice: { mode: b.noticeMode, amount: notice.amount }, extra: b.extraLines,
  });
  const adjustments: AdjustmentInput[] = toAdjustments(lines);

  // Exit month through the normal payroll line
  const ptState = emp.pt_state_code ?? company.state_code;
  const ytdRows = await tx.selectFrom('payroll_lines').select(['taxable_gross', 'tds', 'pt', 'pf_employee']).where('employee_id', '=', emp.id).where('is_live', '=', true)
    .where('month', '>=', fyStartOf(monthStart)).where('month', paidLine ? '<=' : '<', monthStart).execute();
  const ytd = ytdRows.reduce((s, r) => ({ taxable: s.taxable + r.taxable_gross, tds: s.tds + r.tds, pt: s.pt + r.pt, pfEmployee: s.pfEmployee + r.pf_employee }), { taxable: 0, tds: 0, pt: 0, pfEmployee: 0 });
  const rateRows = await companyRateRows(tx, ctx.companyId);
  const r = computeLine({
    monthStart, joining: emp.joining_date, leaving: b.exitDate, sex: emp.sex, lopDays: b.lopDays, divisor,
    components: paidLine ? [] : sal.lines.map((l) => ({ componentId: l.component_id, code: l.code, name: l.name, kind: l.kind as 'earning' | 'deduction', amount: l.amount, taxable: l.taxable, pfWage: l.pf_wage, esiWage: l.esi_wage, proRata: l.pro_rata })),
    adjustments, overrides: [],
    settings: { pfEnabled: !paidLine && (settings?.pf_enabled ?? true), esiEnabled: !paidLine && (settings?.esi_enabled ?? true), lwfEnabled: !paidLine && (settings?.lwf_enabled ?? false), ptEnabled: !paidLine && (settings?.pt_enabled ?? true), pfRate: settings?.pf_rate ?? 12 },
    employee: { pfApplicable: emp.pf_applicable, pfHigherWage: emp.pf_higher_wage, esiApplicable: emp.esi_applicable, esiCoveredUntil: emp.esi_covered_until, taxRegime: emp.tax_regime as 'new' | 'old', previousIncome: emp.previous_income, previousTds: emp.previous_tds },
    ptStateCode: ptState, ytd, rates: ratesInForce(rateRows, monthStart, ptState), wageRule: wageRuleFor(stat, monthStart),
  });
  void monthEnd;
  return {
    emp, lines, leaveRows, fy, bonus, bonusNote, gratuity: { ...gr, applied: gratuityPayable }, notice, wages, paidLine: !!paidLine, r,
    totals: { gross: r.gross, deductions: round2(r.gross - r.net), tds: r.tds, net: r.net },
  };
}
type Built = Awaited<ReturnType<typeof build>>;
const resultJson = (x: Built) => ({
  employee: { id: x.emp.id, code: x.emp.code, name: x.emp.name, designation: x.emp.designation, department: x.emp.department, joiningDate: x.emp.joining_date, pan: x.emp.pan },
  pendingSalaryPaid: x.paidLine, wages: x.wages, gratuity: x.gratuity, leave: x.leaveRows, leaveFy: x.fy, bonus: x.bonus, bonusNote: x.bonusNote, notice: x.notice,
  oneTimeLines: x.lines, line: x.r,
});

type Row = Awaited<ReturnType<typeof getFnf>>;
async function getFnf(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('fnf_settlements as f').innerJoin('employees as e', 'e.id', 'f.employee_id').selectAll('f').select(['e.name as emp_name', 'e.code as emp_code'])
    .where('f.id', '=', id).where('f.company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate('f');
  const r = await q.executeTakeFirst();
  if (!r) throw notFound('Settlement');
  return r;
}
const rowJson = (f: Row, detail = false) => ({
  id: f.id, number: f.number, employeeId: f.employee_id, employeeName: f.emp_name, employeeCode: f.emp_code, exitDate: f.exit_date, status: f.status,
  gross: f.gross, deductions: f.deductions, tds: f.tds, net: f.net, payDate: f.pay_date, createdAt: f.created_at,
  ...(detail ? {
    input: { noticeRequiredDays: f.notice_required_days, noticeServedDays: f.notice_served_days, noticeMode: f.notice_mode, lopDays: f.lop_days, includeGratuity: f.include_gratuity,
      includeLeave: f.include_leave, includeBonus: f.include_bonus, leaveExempt: f.leave_exempt, extraLines: f.extra_lines, notes: f.notes },
    result: f.result, accrualEntryId: f.accrual_entry_id, payoutEntryId: f.payout_entry_id, approvedAt: f.approved_at,
  } : {}),
});

export async function payrollFnfRoutes(app: FastifyInstance) {
  const inputOf = (f: Row): Input => ({
    employeeId: f.employee_id, exitDate: f.exit_date, noticeRequiredDays: f.notice_required_days, noticeServedDays: f.notice_served_days, noticeMode: f.notice_mode as Input['noticeMode'],
    lopDays: f.lop_days, includeGratuity: f.include_gratuity, includeLeave: f.include_leave, includeBonus: f.include_bonus, leaveExempt: f.leave_exempt,
    extraLines: f.extra_lines as Input['extraLines'], notes: f.notes ?? undefined,
  });
  const cols = (b: Input, x: Built) => ({
    exit_date: b.exitDate, notice_required_days: b.noticeRequiredDays, notice_served_days: b.noticeServedDays, notice_mode: b.noticeMode, lop_days: b.lopDays,
    include_gratuity: b.includeGratuity, include_leave: b.includeLeave, include_bonus: b.includeBonus, leave_exempt: b.leaveExempt,
    extra_lines: JSON.stringify(b.extraLines), notes: b.notes ?? null, result: JSON.stringify(resultJson(x)),
    gross: x.totals.gross, deductions: x.totals.deductions, tds: x.totals.tds, net: x.totals.net,
  });

  app.get('/payroll/fnf', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('fnf_settlements as f').innerJoin('employees as e', 'e.id', 'f.employee_id').selectAll('f').select(['e.name as emp_name', 'e.code as emp_code'])
        .where('f.company_id', '=', ctx.companyId).orderBy('f.created_at', 'desc').limit(200).execute();
      return { data: rows.map((r) => rowJson(r)) };
    });
  });
  app.post('/payroll/fnf/preview', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    const b = parse(inputBody, req.body);
    return ctx.tx(async (tx) => {
      const x = await build(tx, ctx, b);
      return { ...x.totals, result: resultJson(x) };
    });
  });
  app.post('/payroll/fnf', async (req, reply) => {
    const ctx = req.ctx; ctx.require('payroll.run');
    const b = parse(inputBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const live = await tx.selectFrom('fnf_settlements').select(['id', 'number']).where('employee_id', '=', b.employeeId).where('status', '<>', 'cancelled').executeTakeFirst();
      if (live) throw conflict(`Settlement ${live.number} already exists for this employee.`, 'FNF_EXISTS', { id: live.id });
      const x = await build(tx, ctx, b);
      const number = await nextNumber(tx, ctx, 'fnf', financialYear(b.exitDate));
      const ins = await tx.insertInto('fnf_settlements').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, number, employee_id: b.employeeId, created_by: ctx.userId, ...cols(b, x) }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'fnf_settlement', ins.id, 'create', null, { number, ...x.totals });
      return rowJson(await getFnf(tx, ctx, ins.id), true);
    });
    return reply.status(201).send(out);
  });
  app.get<{ Params: { id: string } }>('/payroll/fnf/:id', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const f = await getFnf(tx, ctx, id);
      const c = await tx.selectFrom('companies').select(['name', 'legal_name', 'address', 'pan', 'tan']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      return { ...rowJson(f, true), company: { name: c.legal_name ?? c.name, address: c.address, pan: c.pan, tan: c.tan } };
    });
  });
  for (const method of ['put', 'patch'] as const) {
    app[method]<{ Params: { id: string } }>('/payroll/fnf/:id', async (req) => {
      const ctx = req.ctx; ctx.require('payroll.run');
      const id = parse(z.uuid(), req.params.id);
      const patch = parse(inputBody.omit({ employeeId: true }).partial(), req.body);
      return ctx.tx(async (tx) => {
        const f = await getFnf(tx, ctx, id, true);
        if (f.status !== 'draft') throw conflict(`This settlement is ${f.status} and can no longer be changed.`, 'FNF_LOCKED');
        const b: Input = { ...inputOf(f), ...Object.fromEntries(Object.entries(patch).filter(([, v]) => v !== undefined)) } as Input;
        const x = await build(tx, ctx, b);
        await tx.updateTable('fnf_settlements').set(cols(b, x)).where('id', '=', id).execute();
        await writeAudit(tx, auditOf(ctx), 'fnf_settlement', id, 'update', null, x.totals);
        return rowJson(await getFnf(tx, ctx, id), true);
      });
    });
  }
  app.post<{ Params: { id: string } }>('/payroll/fnf/:id/cancel', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.run');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const f = await getFnf(tx, ctx, id, true);
      if (f.status !== 'draft') throw conflict(`Only a draft can be cancelled. This one is ${f.status}.`, 'FNF_STATE');
      await tx.updateTable('fnf_settlements').set({ status: 'cancelled' }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'fnf_settlement', id, 'cancel', { status: 'draft' }, { status: 'cancelled' });
      return rowJson(await getFnf(tx, ctx, id), true);
    });
  });

  app.post<{ Params: { id: string } }>('/payroll/fnf/:id/approve', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.approve');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const f = await getFnf(tx, ctx, id, true);
      if (f.status !== 'draft') throw conflict(`Only a draft can be approved. This one is ${f.status}.`, 'FNF_STATE');
      if (f.created_by === ctx.userId) throw new AppError(403, 'SELF_APPROVAL', 'You prepared this settlement, so someone else must approve it.');
      // Work it out again so the posting matches today's data.
      const b = inputOf(f);
      const x = await build(tx, ctx, b);
      const r = x.r;
      const pseudoRun = { id: f.id, number: f.number, month: `${f.exit_date.slice(0, 7)}-01`, location_id: null } as unknown as Parameters<typeof postAccrual>[2];
      const line = {
        earnings: r.earnings, adjustments: r.adjustments, pf_employee: r.pfEmployee, pf_eps: r.pfEps, pf_epf_employer: r.pfEpfEmployer, pf_edli: r.pfEdli, pf_admin: r.pfAdmin,
        esi_employee: r.esiEmployee, esi_employer: r.esiEmployer, pt: r.pt, lwf_employee: r.lwfEmployee, lwf_employer: r.lwfEmployer, tds: r.tds, other_ded_total: r.otherDedTotal, net: r.net,
      } as unknown as LineRow;
      const entry = await postAccrual(tx, ctx, pseudoRun, [line]);
      // Leave encashed and bonus paid are recorded so they cannot be paid twice.
      for (const l of x.leaveRows) {
        await tx.insertInto('leave_adjustments').values({ tenant_id: ctx.tenantId, employee_id: f.employee_id, leave_type_id: l.leaveTypeId, fy: x.fy, days: -l.days, reason: 'Leave encashment on exit', created_by: ctx.userId }).execute();
        await tx.insertInto('leave_encashments').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: f.employee_id, leave_type_id: l.leaveTypeId, fy: x.fy, days: l.days, amount: l.amount, kind: 'exit', settlement_id: f.id, created_by: ctx.userId }).execute();
      }
      if (x.bonus > 0) await tx.insertInto('bonus_payouts').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: f.employee_id, fy: x.fy, pct: 0, amount: x.bonus, created_by: ctx.userId }).onConflict((oc) => oc.doNothing()).execute();
      await tx.updateTable('employees').set({ leaving_date: f.exit_date, status: 'left' }).where('id', '=', f.employee_id).execute();
      await tx.updateTable('fnf_settlements').set({ ...cols(b, x), status: 'approved', approved_by: ctx.userId, approved_at: new Date(), accrual_entry_id: entry }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'fnf_settlement', id, 'approve', { status: 'draft' }, { status: 'approved', entryId: entry, ...x.totals });
      return rowJson(await getFnf(tx, ctx, id), true);
    });
  });

  app.post<{ Params: { id: string } }>('/payroll/fnf/:id/pay', async (req) => {
    const ctx = req.ctx; ctx.require('payroll.approve');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ payDate: dateField.optional(), accountId: z.uuid().optional() }), req.body ?? {});
    return ctx.tx(async (tx) => {
      const f = await getFnf(tx, ctx, id, true);
      if (f.status !== 'approved') throw conflict(`Only an approved settlement can be paid. This one is ${f.status}.`, 'FNF_STATE');
      const sys = await systemAccounts(tx, ctx);
      let bank = sys.bank;
      if (b.accountId) {
        const a = await tx.selectFrom('accounts').select('id').where('id', '=', b.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!a) throw badRequest('Account not found.', { accountId: 'Not found' });
        bank = a.id;
      }
      const payable = await ensureAccount(tx, ctx, 'Net Salary Payable', 'liability', 2450);
      const payDate = b.payDate ?? todayIst();
      let entry: string | null = null;
      if (f.net > 0) {
        entry = await postJournal(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId }, {
          date: payDate, voucherType: 'wages', voucherId: f.id, number: f.number, narration: `Full and final paid ${f.number}`,
          lines: [{ accountId: payable, amount: f.net, locationId: null }, { accountId: bank, amount: -f.net, locationId: null }],
        });
      }
      await tx.updateTable('fnf_settlements').set({ status: 'paid', paid_at: new Date(), pay_date: payDate, payout_entry_id: entry }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'fnf_settlement', id, 'pay', { status: 'approved' }, { status: 'paid', entryId: entry, payDate });
      return rowJson(await getFnf(tx, ctx, id), true);
    });
  });
}
