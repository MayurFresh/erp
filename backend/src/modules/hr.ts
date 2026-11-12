// HR: employees, salary structures, leave, holidays and monthly attendance totals. Payroll runs are in payroll.ts.
// Salary figures are sensitive: anything with pay in it needs payroll.view.
import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { clipToMonth, countLeaveDays, leaveYear } from '../lib/payroll/leave.ts';
import { resolveAmounts, splitCtc, type ComponentDef } from '../lib/payroll/structure.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { documentRoute } from '../lib/openapi.ts';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const blankToNull = (v: unknown) => (v === '' ? null : v);
const nullableDate = z.preprocess(blankToNull, dateField.nullable().optional());
const nullableUuid = z.preprocess(blankToNull, z.uuid().nullable().optional());
const monthField = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM').transform((v) => `${v}-01`);

// Helpers shared with payroll.ts --------------------------------------------------------------

export async function myEmployee(tx: Tx, ctx: RequestContext) {
  return tx.selectFrom('employees').selectAll().where('company_id', '=', ctx.companyId).where('user_id', '=', ctx.userId).executeTakeFirst();
}

export async function getEmployee(tx: Tx, ctx: RequestContext, id: string) {
  const e = await tx.selectFrom('employees').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!e) throw notFound('Employee');
  const scope = scopedLocationIds(ctx);
  if (scope && !(e.location_id && scope.includes(e.location_id)) && !(await isSelf(tx, ctx, e.id))) throw notFound('Employee');
  return e;
}
async function isSelf(tx: Tx, ctx: RequestContext, employeeId: string) {
  const me = await myEmployee(tx, ctx);
  return me?.id === employeeId;
}
/** Staff who manage people may read the directory; pay needs payroll.view. */
const requireDirectory = (ctx: RequestContext) => ctx.require('payroll.view', 'payroll.employees', 'payroll.leave_approve', 'payroll.run');

const DEFAULT_COMPONENTS = [
  { code: 'BASIC', name: 'Basic', calc: 'fixed', percent: null, is_basic: true, pf_wage: true, sort_order: 1 },
  { code: 'HRA', name: 'House rent allowance', calc: 'pct_basic', percent: 40, is_basic: false, pf_wage: false, sort_order: 2 },
  { code: 'CONV', name: 'Conveyance allowance', calc: 'fixed', percent: null, is_basic: false, pf_wage: false, sort_order: 3 },
  { code: 'SPECIAL', name: 'Special allowance', calc: 'fixed', percent: null, is_basic: false, pf_wage: false, sort_order: 4 },
] as const;

export async function ensureComponents(tx: Tx, ctx: { tenantId: string; companyId: string }) {
  const n = await tx.selectFrom('salary_components').select('id').where('company_id', '=', ctx.companyId).limit(1).executeTakeFirst();
  if (n) return;
  await tx.insertInto('salary_components').values(DEFAULT_COMPONENTS.map((c) => ({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, code: c.code, name: c.name, kind: 'earning', calc: c.calc, percent: c.percent,
    is_basic: c.is_basic, pf_wage: c.pf_wage, sort_order: c.sort_order,
  }))).onConflict((oc) => oc.doNothing()).execute();
}

export async function ensureLeaveTypes(tx: Tx, ctx: { tenantId: string; companyId: string }) {
  const n = await tx.selectFrom('leave_types').select('id').where('company_id', '=', ctx.companyId).limit(1).executeTakeFirst();
  if (n) return;
  await tx.insertInto('leave_types').values([
    { code: 'CL', name: 'Casual leave', is_paid: true, yearly_quota: 8, carry_forward_limit: 0 },
    { code: 'SL', name: 'Sick leave', is_paid: true, yearly_quota: 6, carry_forward_limit: 0 },
    { code: 'EL', name: 'Earned leave', is_paid: true, yearly_quota: 12, carry_forward_limit: 30 },
    { code: 'LOP', name: 'Leave without pay', is_paid: false, yearly_quota: 0, carry_forward_limit: 0 },
  ].map((t) => ({ ...t, tenant_id: ctx.tenantId, company_id: ctx.companyId }))).onConflict((oc) => oc.doNothing()).execute();
}

const toDef = (c: { id: string; code: string; name: string; kind: string; calc: string; percent: number | null; is_basic: boolean }): ComponentDef =>
  ({ id: c.id, code: c.code, name: c.name, kind: c.kind as 'earning' | 'deduction', calc: c.calc as ComponentDef['calc'], percent: c.percent, isBasic: c.is_basic });

export const componentJson = (c: Awaited<ReturnType<typeof loadComponents>>[number]) => ({
  id: c.id, code: c.code, name: c.name, kind: c.kind, calc: c.calc, percent: c.percent, isBasic: c.is_basic, taxable: c.taxable,
  pfWage: c.pf_wage, esiWage: c.esi_wage, proRata: c.pro_rata, isActive: c.is_active, sortOrder: c.sort_order, updatedAt: c.updated_at,
});
async function loadComponents(tx: Tx, companyId: string) {
  return tx.selectFrom('salary_components').selectAll().where('company_id', '=', companyId).orderBy('sort_order').orderBy('code').execute();
}

/** The salary revision in force for a month: latest starting on or before the month start, else the earliest before month end. */
export async function salaryFor(tx: Tx, employeeId: string, monthStart: string, monthEnd: string) {
  const rev = await tx.selectFrom('employee_salaries').selectAll().where('employee_id', '=', employeeId)
    .where('effective_from', '<=', monthStart).orderBy('effective_from', 'desc').limit(1).executeTakeFirst()
    ?? await tx.selectFrom('employee_salaries').selectAll().where('employee_id', '=', employeeId)
      .where('effective_from', '<=', monthEnd).orderBy('effective_from').limit(1).executeTakeFirst();
  if (!rev) return null;
  const lines = await tx.selectFrom('employee_salary_lines as l').innerJoin('salary_components as c', 'c.id', 'l.component_id')
    .select(['l.component_id', 'l.amount', 'c.code', 'c.name', 'c.kind', 'c.taxable', 'c.pf_wage', 'c.esi_wage', 'c.pro_rata', 'c.sort_order'])
    .where('l.salary_id', '=', rev.id).orderBy('c.sort_order').execute();
  return { ...rev, lines };
}

// Employee JSON ---------------------------------------------------------------------------------

type EmpRow = Awaited<ReturnType<typeof getEmployee>>;
const maskTail = (v: string | null) => (v ? `${'X'.repeat(Math.max(0, v.length - 4))}${v.slice(-4)}` : null);

function employeeJson(e: EmpRow, opts: { full: boolean; gross?: number | null; locationName?: string | null }) {
  const base = {
    id: e.id, code: e.code, name: e.name, department: e.department, designation: e.designation, locationId: e.location_id,
    locationName: opts.locationName ?? null, status: e.status, joiningDate: e.joining_date, leavingDate: e.leaving_date,
    phone: e.phone, email: e.email, userId: e.user_id, aadhaarLast4: e.aadhaar_last4, uanSet: !!e.uan, panSet: !!e.pan,
    updatedAt: e.updated_at,
  };
  const pay = opts.gross === undefined ? {} : { monthlyGross: opts.gross };
  if (!opts.full) return { ...base, ...pay };
  return {
    ...base, ...pay, fatherSpouseName: e.father_spouse_name, dob: e.dob, sex: e.sex, reportingTo: e.reporting_to, pan: e.pan,
    aadhaarMasked: e.aadhaar_masked, uan: e.uan, esiNumber: e.esi_number, bankName: e.bank_name, bankAccount: e.bank_account,
    bankIfsc: e.bank_ifsc, salaryMode: e.salary_mode, taxRegime: e.tax_regime, pfApplicable: e.pf_applicable,
    pfHigherWage: e.pf_higher_wage, esiApplicable: e.esi_applicable, esiCoveredUntil: e.esi_covered_until,
    ptStateCode: e.pt_state_code, previousIncome: e.previous_income, previousTds: e.previous_tds, notes: e.notes,
  };
}

async function grossOf(tx: Tx, ids: string[]): Promise<Map<string, number>> {
  const out = new Map<string, number>();
  if (!ids.length) return out;
  const today = todayIst();
  const revs = await tx.selectFrom('employee_salaries').select(['id', 'employee_id', 'effective_from']).where('employee_id', 'in', ids)
    .where('effective_from', '<=', today).orderBy('effective_from', 'desc').execute();
  const pick = new Map<string, string>();
  for (const r of revs) if (!pick.has(r.employee_id)) pick.set(r.employee_id, r.id);
  const sids = [...pick.values()];
  if (!sids.length) return out;
  const lines = await tx.selectFrom('employee_salary_lines as l').innerJoin('salary_components as c', 'c.id', 'l.component_id')
    .select(['l.salary_id', 'l.amount']).where('l.salary_id', 'in', sids).where('c.kind', '=', 'earning').execute();
  for (const [emp, sid] of pick) out.set(emp, lines.filter((l) => l.salary_id === sid).reduce((s, l) => s + l.amount, 0));
  return out;
}

// Input schemas ---------------------------------------------------------------------------------

const aadhaarField = z.preprocess(blankToNull, z.string().trim().regex(/^\d{12}$/, 'Aadhaar has 12 digits').nullable().optional());
const empFields = {
  name: z.string().trim().min(1, 'Required').max(120),
  fatherSpouseName: optionalText(120), dob: nullableDate, sex: z.enum(['M', 'F', 'O']).optional(),
  email: optionalText(200), phone: optionalText(20),
  joiningDate: dateField, department: optionalText(80), designation: optionalText(80),
  locationId: nullableUuid, reportingTo: nullableUuid, userId: nullableUuid,
  pan: z.preprocess((v) => (typeof v === 'string' ? (v.trim() === '' ? null : v.trim().toUpperCase()) : v), z.string().regex(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'Invalid PAN').nullable().optional()),
  aadhaar: aadhaarField,
  uan: z.preprocess(blankToNull, z.string().trim().regex(/^\d{12}$/, 'UAN has 12 digits').nullable().optional()),
  esiNumber: nullableText(20), bankName: nullableText(80), bankAccount: nullableText(30),
  bankIfsc: z.preprocess((v) => (typeof v === 'string' ? (v.trim() === '' ? null : v.trim().toUpperCase()) : v), z.string().regex(/^[A-Z]{4}0[A-Z0-9]{6}$/, 'Invalid IFSC').nullable().optional()),
  salaryMode: z.enum(['bank', 'cash', 'cheque']).optional(), taxRegime: z.enum(['new', 'old']).optional(),
  pfApplicable: z.boolean().optional(), pfHigherWage: z.boolean().optional(), esiApplicable: z.boolean().optional(),
  ptStateCode: z.preprocess(blankToNull, z.string().regex(/^\d{2}$/).nullable().optional()),
  previousIncome: moneyField.optional(), previousTds: moneyField.optional(), notes: nullableText(500),
};
const createEmployee = z.object({ ...empFields, leavingDate: nullableDate });
const patchEmployee = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  ...Object.fromEntries(Object.entries(empFields).map(([k, v]) => [k, (v as z.ZodType).optional()])),
  leavingDate: nullableDate, status: z.enum(['active', 'inactive', 'left']).optional(),
}) as z.ZodObject<Record<string, z.ZodType>>;

const listQuery = pagingQuery.extend({
  status: z.enum(['active', 'inactive', 'left']).optional(), locationId: z.uuid().optional(), department: z.string().max(80).optional(),
});

const componentBody = z.object({
  code: z.string().trim().toUpperCase().min(1).max(20), name: z.string().trim().min(1).max(60),
  kind: z.enum(['earning', 'deduction']), calc: z.enum(['fixed', 'pct_basic', 'pct_gross']).default('fixed'),
  percent: z.coerce.number().min(0).max(1000).nullable().optional(), isBasic: z.boolean().optional(), taxable: z.boolean().optional(),
  pfWage: z.boolean().optional(), esiWage: z.boolean().optional(), proRata: z.boolean().optional(), sortOrder: z.coerce.number().int().optional(),
});
const componentPatch = componentBody.partial().extend({ isActive: z.boolean().optional() });

const salaryBody = z.object({
  effectiveFrom: dateField, ctcAnnual: moneyField.optional(), note: optionalText(300),
  lines: z.array(z.object({ componentId: z.uuid(), amount: moneyField.optional() })).max(40).optional(),
  basicPct: z.coerce.number().min(10).max(100).optional(),
});

const leaveTypeBody = z.object({
  code: z.string().trim().toUpperCase().min(1).max(10), name: z.string().trim().min(1).max(60), isPaid: z.boolean().default(true),
  yearlyQuota: z.coerce.number().min(0).max(366).default(0), carryForwardLimit: z.coerce.number().min(0).max(366).default(0),
});
const leaveTypePatch = leaveTypeBody.partial().extend({ isActive: z.boolean().optional() });

const applyBody = z.object({
  employeeId: z.uuid().optional(), leaveTypeId: z.uuid(), fromDate: dateField, toDate: dateField,
  halfDay: z.boolean().optional(), reason: optionalText(300),
});

async function holidaySet(tx: Tx, companyId: string, from: string, to: string, locationId: string | null): Promise<Set<string>> {
  const rows = await tx.selectFrom('holidays').select(['holiday_date', 'location_id']).where('company_id', '=', companyId)
    .where('holiday_date', '>=', from).where('holiday_date', '<=', to).execute();
  return new Set(rows.filter((r) => r.location_id === null || r.location_id === locationId).map((r) => r.holiday_date));
}

/** Leave balances by type for one employee in the April-March year starting `fy`. */
export async function leaveBalances(tx: Tx, companyId: string, employeeId: string, fy: number) {
  const types = await tx.selectFrom('leave_types').selectAll().where('company_id', '=', companyId).where('is_active', '=', true).orderBy('code').execute();
  const used = async (year: number) => {
    const rows = await tx.selectFrom('leave_applications').select(['leave_type_id', 'days']).where('employee_id', '=', employeeId)
      .where('status', '=', 'approved').where('from_date', '>=', `${year}-04-01`).where('from_date', '<=', `${year + 1}-03-31`).execute();
    return rows;
  };
  const adj = async (year: number) => tx.selectFrom('leave_adjustments').select(['leave_type_id', 'days']).where('employee_id', '=', employeeId).where('fy', '=', year).execute();
  const [u, a, pu, pa] = await Promise.all([used(fy), adj(fy), used(fy - 1), adj(fy - 1)]);
  const pending = await tx.selectFrom('leave_applications').select(['leave_type_id', 'days']).where('employee_id', '=', employeeId)
    .where('status', '=', 'pending').where('from_date', '>=', `${fy}-04-01`).where('from_date', '<=', `${fy + 1}-03-31`).execute();
  const sum = (rows: { leave_type_id: string; days: number }[], id: string) => rows.filter((r) => r.leave_type_id === id).reduce((s, r) => s + r.days, 0);
  return types.map((t) => {
    const prev = Math.max(0, t.yearly_quota + sum(pa, t.id) - sum(pu, t.id));
    const carried = t.is_paid ? Math.min(t.carry_forward_limit, prev) : 0;
    const taken = sum(u, t.id), adjusted = sum(a, t.id);
    return {
      leaveTypeId: t.id, code: t.code, name: t.name, isPaid: t.is_paid, quota: t.yearly_quota, carriedForward: carried,
      adjustments: adjusted, taken, pending: sum(pending, t.id),
      balance: t.is_paid ? Math.round((t.yearly_quota + carried + adjusted - taken) * 100) / 100 : null,
    };
  });
}

/** Approved leave inside a month, split into paid and unpaid days, for each employee. */
export async function leaveInMonth(tx: Tx, companyId: string, monthStart: string, employees: { id: string; location_id: string | null }[]) {
  const monthEnd = `${monthStart.slice(0, 8)}${String(new Date(Date.UTC(Number(monthStart.slice(0, 4)), Number(monthStart.slice(5, 7)), 0)).getUTCDate()).padStart(2, '0')}`;
  const apps = await tx.selectFrom('leave_applications as a').innerJoin('leave_types as t', 't.id', 'a.leave_type_id')
    .select(['a.employee_id', 'a.from_date', 'a.to_date', 'a.half_day', 't.is_paid']).where('a.company_id', '=', companyId)
    .where('a.status', '=', 'approved').where('a.from_date', '<=', monthEnd).where('a.to_date', '>=', monthStart).execute();
  const out = new Map<string, { paid: number; unpaid: number }>();
  for (const e of employees) {
    const hol = await holidaySet(tx, companyId, monthStart, monthEnd, e.location_id);
    let paid = 0, unpaid = 0;
    for (const a of apps.filter((x) => x.employee_id === e.id)) {
      const clip = clipToMonth(a.from_date, a.to_date, monthStart);
      if (!clip) continue;
      const d = countLeaveDays({ ...clip, halfDay: a.half_day, holidays: hol });
      if (a.is_paid) paid += d; else unpaid += d;
    }
    out.set(e.id, { paid, unpaid });
  }
  return out;
}

const leaveJson = (a: { id: string; employee_id: string; leave_type_id: string; from_date: string; to_date: string; half_day: boolean; days: number; reason: string | null; status: string; decided_by: string | null; decided_at: Date | null; decision_note: string | null; created_at: Date; updated_at: Date }, extra: { employeeName: string; employeeCode: string; leaveTypeName: string; isPaid: boolean }) => ({
  id: a.id, employeeId: a.employee_id, employeeName: extra.employeeName, employeeCode: extra.employeeCode, leaveTypeId: a.leave_type_id,
  leaveTypeName: extra.leaveTypeName, isPaid: extra.isPaid, fromDate: a.from_date, toDate: a.to_date, halfDay: a.half_day, days: a.days,
  reason: a.reason, status: a.status, decidedAt: a.decided_at, decisionNote: a.decision_note, createdAt: a.created_at, updatedAt: a.updated_at,
});

async function loadLeave(tx: Tx, ids: string[]) {
  if (!ids.length) return [];
  const rows = await tx.selectFrom('leave_applications as a').innerJoin('employees as e', 'e.id', 'a.employee_id')
    .innerJoin('leave_types as t', 't.id', 'a.leave_type_id')
    .selectAll('a').select(['e.name as employee_name', 'e.code as employee_code', 't.name as type_name', 't.is_paid']).where('a.id', 'in', ids).execute();
  return ids.map((id) => {
    const r = rows.find((x) => x.id === id)!;
    return leaveJson(r, { employeeName: r.employee_name, employeeCode: r.employee_code, leaveTypeName: r.type_name, isPaid: r.is_paid });
  });
}

// Routes ----------------------------------------------------------------------------------------

export async function hrRoutes(app: FastifyInstance) {
  // Settings
  const settingsBody = z.object({
    lopDivisor: z.enum(['calendar', '30', '26']).optional(), pfEnabled: z.boolean().optional(), esiEnabled: z.boolean().optional(),
    lwfEnabled: z.boolean().optional(), ptEnabled: z.boolean().optional(), pfRate: z.union([z.literal(10), z.literal(12)]).optional(),
    pfCode: nullableText(30), esiCode: nullableText(30), ptRegistration: nullableText(30),
  });
  const settingsJson = (s: { lop_divisor: string; pf_enabled: boolean; esi_enabled: boolean; lwf_enabled: boolean; pt_enabled: boolean; pf_rate: number; pf_code: string | null; esi_code: string | null; pt_registration: string | null } | undefined) => ({
    lopDivisor: s?.lop_divisor ?? 'calendar', pfEnabled: s?.pf_enabled ?? true, esiEnabled: s?.esi_enabled ?? true,
    lwfEnabled: s?.lwf_enabled ?? false, ptEnabled: s?.pt_enabled ?? true, pfRate: s?.pf_rate ?? 12,
    pfCode: s?.pf_code ?? null, esiCode: s?.esi_code ?? null, ptRegistration: s?.pt_registration ?? null,
  });
  app.get('/payroll/settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.employees', 'payroll.run');
    return ctx.tx(async (tx) => settingsJson(await tx.selectFrom('payroll_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst()));
  });
  // PUT and PATCH: the Flutter ApiClient has no PUT.
  app.route({ method: ['PUT', 'PATCH'], url: '/payroll/settings', handler: async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const changes = definedOnly({
        lop_divisor: b.lopDivisor, pf_enabled: b.pfEnabled, esi_enabled: b.esiEnabled, lwf_enabled: b.lwfEnabled, pt_enabled: b.ptEnabled,
        pf_rate: b.pfRate, pf_code: b.pfCode, esi_code: b.esiCode, pt_registration: b.ptRegistration,
      });
      const before = await tx.selectFrom('payroll_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst();
      await tx.insertInto('payroll_settings').values({ company_id: ctx.companyId, tenant_id: ctx.tenantId, ...changes })
        .onConflict((oc) => oc.column('company_id').doUpdateSet({ company_id: ctx.companyId, ...changes })).execute();
      const after = await tx.selectFrom('payroll_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'payroll_settings', ctx.companyId, 'update', before ? settingsJson(before) : null, settingsJson(after));
      return settingsJson(after);
    });
  } });

  // Components
  app.get('/payroll/components', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.employees', 'payroll.run');
    return ctx.tx(async (tx) => {
      await ensureComponents(tx, ctx);
      const rows = await loadComponents(tx, ctx.companyId);
      return { data: rows.map(componentJson), total: rows.length };
    });
  });
  app.post('/payroll/components', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const b = parse(componentBody, req.body);
    if (b.calc !== 'fixed' && b.percent == null) throw badRequest('Enter the percent.', { percent: 'Required' });
    const row = await ctx.tx(async (tx) => {
      await ensureComponents(tx, ctx);
      const dup = await tx.selectFrom('salary_components').select('id').where('company_id', '=', ctx.companyId).where('code', '=', b.code).executeTakeFirst();
      if (dup) throw conflict('A component with this code already exists.', 'CONFLICT', { code: 'Already used' });
      if (b.isBasic) await tx.updateTable('salary_components').set({ is_basic: false }).where('company_id', '=', ctx.companyId).execute();
      const r = await tx.insertInto('salary_components').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, code: b.code, name: b.name, kind: b.kind, calc: b.calc, percent: b.percent ?? null,
        is_basic: b.isBasic ?? false, taxable: b.taxable ?? true, pf_wage: b.pfWage ?? false, esi_wage: b.esiWage ?? true,
        pro_rata: b.proRata ?? true, sort_order: b.sortOrder ?? 50,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'salary_component', r.id, 'create', null, componentJson(r));
      return componentJson(r);
    });
    return reply.status(201).send(row);
  });
  app.patch<{ Params: { id: string } }>('/payroll/components/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(componentPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('salary_components').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!before) throw notFound('Salary component');
      if (b.isBasic) await tx.updateTable('salary_components').set({ is_basic: false }).where('company_id', '=', ctx.companyId).execute();
      await tx.updateTable('salary_components').set(definedOnly({
        code: b.code, name: b.name, kind: b.kind, calc: b.calc, percent: b.percent, is_basic: b.isBasic, taxable: b.taxable, pf_wage: b.pfWage,
        esi_wage: b.esiWage, pro_rata: b.proRata, sort_order: b.sortOrder, is_active: b.isActive,
      })).where('id', '=', id).execute();
      const after = await tx.selectFrom('salary_components').selectAll().where('id', '=', id).executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'salary_component', id, 'update', componentJson(before), componentJson(after));
      return componentJson(after);
    });
  });

  // Employees
  app.get('/employees', async (req) => {
    const ctx = req.ctx;
    requireDirectory(ctx);
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('employees as e').leftJoin('locations as l', 'l.id', 'e.location_id').where('e.company_id', '=', ctx.companyId);
      const scope = scopedLocationIds(ctx);
      if (scope) base = base.where('e.location_id', 'in', scope);
      if (q.status) base = base.where('e.status', '=', q.status);
      if (q.locationId) base = base.where('e.location_id', '=', q.locationId);
      if (q.department) base = base.where('e.department', '=', q.department);
      if (q.q) base = base.where((eb) => eb.or([eb('e.name', 'ilike', likeTerm(q.q!)), eb('e.code', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll('e').select('l.name as location_name').orderBy('e.code').limit(q.limit).offset(q.offset).execute();
      const gross = ctx.can('payroll.view') ? await grossOf(tx, rows.map((r) => r.id)) : null;
      return {
        data: rows.map((r) => employeeJson(r, { full: false, locationName: r.location_name, gross: gross ? (gross.get(r.id) ?? 0) : undefined })),
        total,
      };
    });
  });

  app.get<{ Params: { id: string } }>('/employees/:id', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const me = await myEmployee(tx, ctx);
      if (me?.id !== id) requireDirectory(ctx);
      const e = await getEmployee(tx, ctx, id);
      const gross = ctx.can('payroll.view') || me?.id === id ? (await grossOf(tx, [id])).get(id) ?? 0 : undefined;
      const loc = e.location_id ? await tx.selectFrom('locations').select('name').where('id', '=', e.location_id).executeTakeFirst() : null;
      const json = employeeJson(e, { full: true, gross, locationName: loc?.name ?? null }) as Record<string, unknown>;
      if (!ctx.can('payroll.employees') && me?.id !== id) {
        // Others see only masked bank and tax identifiers.
        json.bankAccount = maskTail(e.bank_account); json.previousIncome = undefined; json.previousTds = undefined;
        if (!ctx.can('payroll.view')) json.pan = maskTail(e.pan);
      }
      return json;
    });
  });

  async function nextCode(tx: Tx, ctx: RequestContext): Promise<string> {
    const row = await tx.insertInto('doc_series')
      .values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, doc_type: 'employee', fy: 'all', next_no: 2 })
      .onConflict((oc) => oc.columns(['company_id', 'doc_type', 'fy']).doUpdateSet((eb) => ({ next_no: eb('doc_series.next_no', '+', 1) })))
      .returning('next_no').executeTakeFirstOrThrow();
    return `E${String(row.next_no - 1).padStart(4, '0')}`;
  }

  async function checkLinks(tx: Tx, ctx: RequestContext, b: { locationId?: string | null; userId?: string | null; reportingTo?: string | null }, selfId?: string) {
    if (b.locationId) {
      const l = await tx.selectFrom('locations').select('id').where('id', '=', b.locationId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!l) throw badRequest('Location not found.', { locationId: 'Not found' });
      ctx.requireLocation(b.locationId);
    }
    if (b.userId) {
      const u = await tx.selectFrom('users').select('id').where('id', '=', b.userId).executeTakeFirst();
      if (!u) throw badRequest('User not found.', { userId: 'Not found' });
      const taken = await tx.selectFrom('employees').select('id').where('company_id', '=', ctx.companyId).where('user_id', '=', b.userId)
        .$if(!!selfId, (qb) => qb.where('id', '<>', selfId!)).executeTakeFirst();
      if (taken) throw conflict('This user is already linked to another employee.', 'CONFLICT', { userId: 'Already linked' });
    }
    if (b.reportingTo) {
      if (b.reportingTo === selfId) throw badRequest('An employee cannot report to themselves.', { reportingTo: 'Invalid' });
      const m = await tx.selectFrom('employees').select('id').where('id', '=', b.reportingTo).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!m) throw badRequest('Manager not found.', { reportingTo: 'Not found' });
    }
  }

  app.post('/employees', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const b = parse(createEmployee, req.body);
    if (b.leavingDate && b.leavingDate < b.joiningDate) throw badRequest('Leaving date is before joining date.', { leavingDate: 'Before joining' });
    const out = await ctx.tx(async (tx) => {
      await checkLinks(tx, ctx, b);
      const code = await nextCode(tx, ctx);
      const e = await tx.insertInto('employees').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, code, user_id: b.userId ?? null, name: b.name,
        father_spouse_name: b.fatherSpouseName ?? null, dob: b.dob ?? null, sex: b.sex ?? null, email: b.email ?? null, phone: b.phone ?? null,
        joining_date: b.joiningDate, leaving_date: b.leavingDate ?? null, department: b.department ?? null, designation: b.designation ?? null,
        location_id: b.locationId ?? null, reporting_to: b.reportingTo ?? null, pan: b.pan ?? null,
        aadhaar_masked: b.aadhaar ? `XXXX XXXX ${b.aadhaar.slice(-4)}` : null, aadhaar_last4: b.aadhaar ? b.aadhaar.slice(-4) : null,
        uan: b.uan ?? null, esi_number: b.esiNumber ?? null, bank_name: b.bankName ?? null, bank_account: b.bankAccount ?? null,
        bank_ifsc: b.bankIfsc ?? null, salary_mode: b.salaryMode ?? 'bank', tax_regime: b.taxRegime ?? 'new',
        pf_applicable: b.pfApplicable ?? true, pf_higher_wage: b.pfHigherWage ?? false, esi_applicable: b.esiApplicable ?? true,
        pt_state_code: b.ptStateCode ?? null, previous_income: b.previousIncome ?? 0, previous_tds: b.previousTds ?? 0,
        status: b.leavingDate && b.leavingDate < todayIst() ? 'left' : 'active', notes: b.notes ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      const json = employeeJson(e, { full: true });
      await writeAudit(tx, auditOf(ctx), 'employee', e.id, 'create', null, { ...json, bankAccount: maskTail(e.bank_account) });
      return json;
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/employees/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchEmployee, req.body) as Record<string, any>;
    return ctx.tx(async (tx) => {
      const before = await getEmployee(tx, ctx, id);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'employee');
      await checkLinks(tx, ctx, b, id);
      const joining = b.joiningDate ?? before.joining_date;
      const leaving = b.leavingDate === undefined ? before.leaving_date : b.leavingDate;
      if (leaving && leaving < joining) throw badRequest('Leaving date is before joining date.', { leavingDate: 'Before joining' });
      const changes = definedOnly({
        name: b.name, father_spouse_name: b.fatherSpouseName, dob: b.dob, sex: b.sex, email: b.email, phone: b.phone,
        joining_date: b.joiningDate, leaving_date: b.leavingDate, department: b.department, designation: b.designation,
        location_id: b.locationId, reporting_to: b.reportingTo, user_id: b.userId, pan: b.pan, uan: b.uan, esi_number: b.esiNumber,
        bank_name: b.bankName, bank_account: b.bankAccount, bank_ifsc: b.bankIfsc, salary_mode: b.salaryMode, tax_regime: b.taxRegime,
        pf_applicable: b.pfApplicable, pf_higher_wage: b.pfHigherWage, esi_applicable: b.esiApplicable, pt_state_code: b.ptStateCode,
        previous_income: b.previousIncome, previous_tds: b.previousTds, notes: b.notes, status: b.status,
        aadhaar_masked: b.aadhaar === undefined ? undefined : b.aadhaar ? `XXXX XXXX ${String(b.aadhaar).slice(-4)}` : null,
        aadhaar_last4: b.aadhaar === undefined ? undefined : b.aadhaar ? String(b.aadhaar).slice(-4) : null,
      });
      if (b.leavingDate && !b.status) (changes as Record<string, unknown>).status = b.leavingDate <= todayIst() ? 'left' : 'active';
      if (!Object.keys(changes).length) return employeeJson(before, { full: true });
      await tx.updateTable('employees').set(changes).where('id', '=', id).execute();
      const after = await tx.selectFrom('employees').selectAll().where('id', '=', id).executeTakeFirstOrThrow();
      const mask = (e: typeof after) => ({ ...employeeJson(e, { full: true }), bankAccount: maskTail(e.bank_account) });
      await writeAudit(tx, auditOf(ctx), 'employee', id, 'update', mask(before), mask(after));
      return employeeJson(after, { full: true });
    });
  });

  // Salary revisions
  const salaryJson = (rev: NonNullable<Awaited<ReturnType<typeof salaryFor>>>) => ({
    id: rev.id, effectiveFrom: rev.effective_from, ctcAnnual: rev.ctc_annual, note: rev.note,
    monthlyGross: rev.lines.filter((l) => l.kind === 'earning').reduce((s, l) => s + l.amount, 0),
    lines: rev.lines.map((l) => ({ componentId: l.component_id, code: l.code, name: l.name, kind: l.kind, amount: l.amount })),
  });
  app.get<{ Params: { id: string } }>('/employees/:id/salary', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const me = await myEmployee(tx, ctx);
      if (me?.id !== id) ctx.require('payroll.view');
      await getEmployee(tx, ctx, id);
      const revs = await tx.selectFrom('employee_salaries').select(['id', 'effective_from']).where('employee_id', '=', id).orderBy('effective_from', 'desc').execute();
      const out = [];
      for (const r of revs) out.push(salaryJson((await salaryFor(tx, id, r.effective_from, r.effective_from))!));
      return { data: out, total: out.length };
    });
  });
  app.post<{ Params: { id: string } }>('/employees/:id/salary', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(salaryBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const emp = await getEmployee(tx, ctx, id);
      await ensureComponents(tx, ctx);
      const comps = (await loadComponents(tx, ctx.companyId)).filter((c) => c.is_active);
      const defs = comps.map(toDef);
      let amounts: Record<string, number>;
      if (b.lines?.length) {
        const given: Record<string, number | undefined> = {};
        for (const l of b.lines) {
          if (!comps.some((c) => c.id === l.componentId)) throw badRequest('Unknown salary component.', { lines: 'Unknown component' });
          given[l.componentId] = l.amount;
        }
        amounts = resolveAmounts(defs.filter((d) => given[d.id] !== undefined || d.calc !== 'fixed'), given);
      } else if (b.ctcAnnual) amounts = splitCtc(defs, b.ctcAnnual, b.basicPct ?? 50);
      else throw badRequest('Give the CTC or the component amounts.', { lines: 'Required' });
      const basic = comps.find((c) => c.is_basic);
      if (basic && !((amounts[basic.id] ?? 0) > 0)) throw badRequest('Basic pay must be more than zero.', { lines: 'Basic is required' });
      const gross = Object.entries(amounts).filter(([cid]) => comps.find((c) => c.id === cid)?.kind === 'earning').reduce((s, [, v]) => s + v, 0);
      if (!(gross > 0)) throw badRequest('Total earnings must be more than zero.', { lines: 'Required' });
      if (b.effectiveFrom < emp.joining_date) throw badRequest('A revision cannot start before the joining date.', { effectiveFrom: 'Before joining' });
      const dup = await tx.selectFrom('employee_salaries').select('id').where('employee_id', '=', id).where('effective_from', '=', b.effectiveFrom).executeTakeFirst();
      if (dup) throw conflict('A revision already starts on this date. Choose another date.', 'CONFLICT', { effectiveFrom: 'Already used' });
      const rev = await tx.insertInto('employee_salaries').values({
        tenant_id: ctx.tenantId, employee_id: id, effective_from: b.effectiveFrom, ctc_annual: b.ctcAnnual ?? gross * 12,
        note: b.note ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const rows = Object.entries(amounts).filter(([, v]) => v > 0).map(([componentId, amount]) => ({ tenant_id: ctx.tenantId, salary_id: rev.id, component_id: componentId, amount }));
      await tx.insertInto('employee_salary_lines').values(rows).execute();
      const saved = salaryJson((await salaryFor(tx, id, b.effectiveFrom, b.effectiveFrom))!);
      await writeAudit(tx, auditOf(ctx), 'employee_salary', rev.id, 'create', null, { employeeId: id, ...saved });
      return saved;
    });
    return reply.status(201).send(out);
  });

  // Leave types
  const typeJson = (t: { id: string; code: string; name: string; is_paid: boolean; yearly_quota: number; carry_forward_limit: number; is_active: boolean }) => ({
    id: t.id, code: t.code, name: t.name, isPaid: t.is_paid, yearlyQuota: t.yearly_quota, carryForwardLimit: t.carry_forward_limit, isActive: t.is_active,
  });
  app.get('/leave-types', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.employees', 'payroll.leave_approve', 'payroll.self', 'payroll.run');
    return ctx.tx(async (tx) => {
      await ensureLeaveTypes(tx, ctx);
      const rows = await tx.selectFrom('leave_types').selectAll().where('company_id', '=', ctx.companyId).orderBy('code').execute();
      return { data: rows.map(typeJson), total: rows.length };
    });
  });
  app.post('/leave-types', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const b = parse(leaveTypeBody, req.body);
    const out = await ctx.tx(async (tx) => {
      await ensureLeaveTypes(tx, ctx);
      const dup = await tx.selectFrom('leave_types').select('id').where('company_id', '=', ctx.companyId).where('code', '=', b.code).executeTakeFirst();
      if (dup) throw conflict('A leave type with this code already exists.', 'CONFLICT', { code: 'Already used' });
      const r = await tx.insertInto('leave_types').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, code: b.code, name: b.name, is_paid: b.isPaid, yearly_quota: b.yearlyQuota,
        carry_forward_limit: b.carryForwardLimit,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'leave_type', r.id, 'create', null, typeJson(r));
      return typeJson(r);
    });
    return reply.status(201).send(out);
  });
  app.patch<{ Params: { id: string } }>('/leave-types/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(leaveTypePatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('leave_types').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!before) throw notFound('Leave type');
      await tx.updateTable('leave_types').set(definedOnly({
        code: b.code, name: b.name, is_paid: b.isPaid, yearly_quota: b.yearlyQuota, carry_forward_limit: b.carryForwardLimit, is_active: b.isActive,
      })).where('id', '=', id).execute();
      const after = await tx.selectFrom('leave_types').selectAll().where('id', '=', id).executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'leave_type', id, 'update', typeJson(before), typeJson(after));
      return typeJson(after);
    });
  });

  // Holidays
  app.get('/holidays', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.employees', 'payroll.leave_approve', 'payroll.self', 'payroll.run');
    const q = parse(z.object({ year: z.coerce.number().int().min(2000).max(2100).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let qb = tx.selectFrom('holidays').selectAll().where('company_id', '=', ctx.companyId);
      if (q.year) qb = qb.where('holiday_date', '>=', `${q.year}-01-01`).where('holiday_date', '<=', `${q.year}-12-31`);
      const rows = await qb.orderBy('holiday_date').execute();
      return { data: rows.map((h) => ({ id: h.id, date: h.holiday_date, name: h.name, locationId: h.location_id })), total: rows.length };
    });
  });
  app.post('/holidays', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const b = parse(z.object({ date: dateField, name: z.string().trim().min(1).max(80), locationId: nullableUuid }), req.body);
    const out = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('holidays').select('id').where('company_id', '=', ctx.companyId).where('holiday_date', '=', b.date)
        .where((eb) => (b.locationId ? eb('location_id', '=', b.locationId) : eb('location_id', 'is', null))).executeTakeFirst();
      if (dup) throw conflict('This date is already a holiday.', 'CONFLICT', { date: 'Already added' });
      const h = await tx.insertInto('holidays').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, holiday_date: b.date, name: b.name, location_id: b.locationId ?? null })
        .returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'holiday', h.id, 'create', null, { date: b.date, name: b.name });
      return { id: h.id, date: h.holiday_date, name: h.name, locationId: h.location_id };
    });
    return reply.status(201).send(out);
  });
  app.delete<{ Params: { id: string } }>('/holidays/:id', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const h = await tx.selectFrom('holidays').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!h) throw notFound('Holiday');
      await tx.deleteFrom('holidays').where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'holiday', id, 'delete', { date: h.holiday_date, name: h.name }, null);
    });
    return reply.status(204).send();
  });

  // Leave applications
  const leaveList = pagingQuery.extend({
    status: z.enum(['pending', 'approved', 'rejected', 'cancelled']).optional(), employeeId: z.uuid().optional(), mine: z.enum(['true', 'false']).optional(),
  });
  app.get('/leave-applications', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.employees', 'payroll.leave_approve', 'payroll.self');
    const q = parse(leaveList, req.query);
    return ctx.tx(async (tx) => {
      const me = await myEmployee(tx, ctx);
      const seesAll = ctx.can('payroll.view') || ctx.can('payroll.employees') || ctx.can('payroll.leave_approve');
      let base = tx.selectFrom('leave_applications as a').where('a.company_id', '=', ctx.companyId);
      if (!seesAll || q.mine === 'true') {
        if (!me) return { data: [], total: 0 };
        base = base.where('a.employee_id', '=', me.id);
      } else {
        const scope = scopedLocationIds(ctx);
        if (scope) base = base.where('a.employee_id', 'in', (eb) => eb.selectFrom('employees').select('id').where('location_id', 'in', scope));
      }
      if (q.status) base = base.where('a.status', '=', q.status);
      if (q.employeeId) base = base.where('a.employee_id', '=', q.employeeId);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const ids = await base.select('a.id').orderBy('a.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: await loadLeave(tx, ids.map((r) => r.id)), total };
    });
  });

  app.post('/leave-applications', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.self', 'payroll.employees');
    const b = parse(applyBody, req.body);
    if (b.toDate < b.fromDate) throw badRequest('End date is before the start date.', { toDate: 'Before start' });
    if (b.halfDay && b.fromDate !== b.toDate) throw badRequest('A half day is for one date.', { halfDay: 'One date only' });
    const out = await ctx.tx(async (tx) => {
      const me = await myEmployee(tx, ctx);
      let emp;
      if (b.employeeId && b.employeeId !== me?.id) {
        ctx.require('payroll.employees');
        emp = await getEmployee(tx, ctx, b.employeeId);
      } else {
        if (!me) throw forbidden('Your login is not linked to an employee.');
        emp = me;
      }
      if (emp.status !== 'active') throw conflict('This employee is not active.', 'CONFLICT');
      await ensureLeaveTypes(tx, ctx);
      const lt = await tx.selectFrom('leave_types').selectAll().where('id', '=', b.leaveTypeId).where('company_id', '=', ctx.companyId).where('is_active', '=', true).executeTakeFirst();
      if (!lt) throw notFound('Leave type');
      const hol = await holidaySet(tx, ctx.companyId, b.fromDate, b.toDate, emp.location_id);
      const days = countLeaveDays({ from: b.fromDate, to: b.toDate, halfDay: b.halfDay, holidays: hol });
      if (days <= 0) throw badRequest('These dates are all holidays or weekly offs.', { fromDate: 'No working days' });
      const clash = await tx.selectFrom('leave_applications').select('id').where('employee_id', '=', emp.id).where('status', 'in', ['pending', 'approved'])
        .where('from_date', '<=', b.toDate).where('to_date', '>=', b.fromDate).executeTakeFirst();
      if (clash) throw conflict('There is already leave on some of these dates.', 'CONFLICT', { fromDate: 'Overlaps other leave' });
      if (lt.is_paid && lt.yearly_quota > 0) {
        const bal = (await leaveBalances(tx, ctx.companyId, emp.id, leaveYear(b.fromDate))).find((x) => x.leaveTypeId === lt.id)!;
        if (days > bal.balance! - bal.pending) {
          throw conflict(`Only ${Math.max(0, bal.balance! - bal.pending)} days of ${lt.name} are left.`, 'INSUFFICIENT_LEAVE', { balance: bal.balance, pending: bal.pending });
        }
      }
      const a = await tx.insertInto('leave_applications').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: emp.id, leave_type_id: lt.id, from_date: b.fromDate, to_date: b.toDate,
        half_day: b.halfDay ?? false, days, reason: b.reason ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const saved = (await loadLeave(tx, [a.id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'leave_application', a.id, 'create', null, saved);
      return saved;
    });
    return reply.status(201).send(out);
  });

  async function decide(ctx: RequestContext, id: string, action: 'approve' | 'reject' | 'cancel', note?: string) {
    return ctx.tx(async (tx) => {
      const a = await tx.selectFrom('leave_applications').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!a) throw notFound('Leave application');
      const me = await myEmployee(tx, ctx);
      if (action === 'cancel') {
        if (!(me?.id === a.employee_id || ctx.can('payroll.employees'))) throw forbidden();
        if (a.status !== 'pending' && a.status !== 'approved') throw conflict(`This application is already ${a.status}.`, 'CONFLICT');
      } else {
        ctx.require('payroll.leave_approve');
        if (a.status !== 'pending') throw conflict(`This application is already ${a.status}.`, 'CONFLICT');
        if (me?.id === a.employee_id) throw forbidden('You cannot decide your own leave.');
        await getEmployee(tx, ctx, a.employee_id);
        if (action === 'approve') {
          const lt = await tx.selectFrom('leave_types').selectAll().where('id', '=', a.leave_type_id).executeTakeFirstOrThrow();
          if (lt.is_paid && lt.yearly_quota > 0) {
            const bal = (await leaveBalances(tx, ctx.companyId, a.employee_id, leaveYear(a.from_date))).find((x) => x.leaveTypeId === lt.id)!;
            if (a.days > bal.balance!) throw conflict(`Only ${bal.balance} days of ${lt.name} are left.`, 'INSUFFICIENT_LEAVE', { balance: bal.balance });
          }
        }
      }
      const status = action === 'approve' ? 'approved' : action === 'reject' ? 'rejected' : 'cancelled';
      await tx.updateTable('leave_applications').set({ status, decided_by: ctx.userId, decided_at: new Date(), decision_note: note ?? null }).where('id', '=', id).execute();
      const after = (await loadLeave(tx, [id]))[0]!;
      await writeAudit(tx, auditOf(ctx), 'leave_application', id, action, { status: a.status }, { status });
      return after;
    });
  }
  const noteBody = z.object({ note: optionalText(300) });
  for (const action of ['approve', 'reject', 'cancel'] as const) {
    app.post<{ Params: { id: string } }>(`/leave-applications/:id/${action}`, async (req) => {
      const ctx = req.ctx;
      ctx.require('payroll.leave_approve', 'payroll.self', 'payroll.employees');
      return decide(ctx, parse(z.uuid(), req.params.id), action, parse(noteBody, req.body ?? {}).note);
    });
  }

  app.get<{ Params: { id: string } }>('/employees/:id/leave-balances', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const q = parse(z.object({ fy: z.coerce.number().int().min(2000).max(2100).optional() }), req.query);
    return ctx.tx(async (tx) => {
      const me = await myEmployee(tx, ctx);
      if (me?.id !== id) requireDirectory(ctx);
      await getEmployee(tx, ctx, id);
      await ensureLeaveTypes(tx, ctx);
      const fy = q.fy ?? leaveYear(todayIst());
      return { fy, data: await leaveBalances(tx, ctx.companyId, id, fy) };
    });
  });
  app.post<{ Params: { id: string } }>('/employees/:id/leave-adjustments', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(z.object({ leaveTypeId: z.uuid(), fy: z.coerce.number().int().min(2000).max(2100), days: z.coerce.number().min(-366).max(366).refine((v) => v !== 0, 'Cannot be zero'), reason: z.string().trim().min(2).max(200) }), req.body);
    await ctx.tx(async (tx) => {
      await getEmployee(tx, ctx, id);
      const lt = await tx.selectFrom('leave_types').select('id').where('id', '=', b.leaveTypeId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!lt) throw notFound('Leave type');
      const r = await tx.insertInto('leave_adjustments').values({ tenant_id: ctx.tenantId, employee_id: id, leave_type_id: b.leaveTypeId, fy: b.fy, days: b.days, reason: b.reason, created_by: ctx.userId }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'leave_adjustment', r.id, 'create', null, { employeeId: id, ...b });
    });
    return reply.status(201).send({ ok: true });
  });

  // Monthly attendance totals
  const attJson = (r: { employee_id: string; month: string; present_days: number; paid_leave_days: number; lop_days: number; source: string }) => ({
    employeeId: r.employee_id, month: r.month.slice(0, 7), presentDays: r.present_days, paidLeaveDays: r.paid_leave_days, lopDays: r.lop_days, source: r.source,
  });
  app.get('/attendance-summaries', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.employees', 'payroll.run');
    const q = parse(z.object({ month: monthField }), req.query);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('attendance_summaries').selectAll().where('company_id', '=', ctx.companyId).where('month', '=', q.month).execute();
      return { data: rows.map(attJson), total: rows.length };
    });
  });
  app.put('/attendance-summaries', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees', 'payroll.run');
    const b = parse(z.object({
      month: monthField,
      rows: z.array(z.object({
        employeeId: z.uuid(), presentDays: z.coerce.number().min(0).max(31).default(0), paidLeaveDays: z.coerce.number().min(0).max(31).default(0),
        lopDays: z.coerce.number().min(0).max(31).default(0),
      })).min(1).max(1000),
    }), req.body);
    return ctx.tx(async (tx) => {
      const live = await tx.selectFrom('payroll_runs').select('id').where('company_id', '=', ctx.companyId).where('month', '=', b.month)
        .where('status', 'in', ['approved', 'posted']).executeTakeFirst();
      if (live) throw conflict('Payroll for this month is already approved. Attendance cannot change.', 'RUN_LOCKED');
      for (const r of b.rows) {
        await getEmployee(tx, ctx, r.employeeId);
        const set = { present_days: r.presentDays, paid_leave_days: r.paidLeaveDays, lop_days: r.lopDays, source: 'manual', updated_by: ctx.userId };
        await tx.insertInto('attendance_summaries').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: r.employeeId, month: b.month, ...set })
          .onConflict((oc) => oc.columns(['employee_id', 'month']).doUpdateSet(set)).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'attendance_summary', null, 'update', null, { month: b.month, rows: b.rows.length });
      const rows = await tx.selectFrom('attendance_summaries').selectAll().where('company_id', '=', ctx.companyId).where('month', '=', b.month).execute();
      return { data: rows.map(attJson), total: rows.length };
    });
  });
  // Daily register. Saving it rewrites the month totals that payroll reads.
  const dayStatus = z.enum(['present', 'absent', 'half_day', 'leave', 'holiday', 'week_off']);
  const daysJson = async (tx: Tx, companyId: string, month: string) => {
    const end = lastDayOf(month);
    const rows = await tx.selectFrom('attendance_days').select(['employee_id', 'day', 'status']).where('company_id', '=', companyId)
      .where('day', '>=', month).where('day', '<=', end).orderBy('day').execute();
    return { data: rows.map((r) => ({ employeeId: r.employee_id, day: String(r.day).slice(0, 10), status: r.status })), total: rows.length };
  };
  const lastDayOf = (m: string) => `${m.slice(0, 8)}${String(new Date(Date.UTC(Number(m.slice(0, 4)), Number(m.slice(5, 7)), 0)).getUTCDate()).padStart(2, '0')}`;
  app.get('/attendance-days', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.view', 'payroll.employees', 'payroll.run');
    const q = parse(z.object({ month: monthField }), req.query);
    return ctx.tx((tx) => daysJson(tx, ctx.companyId, q.month));
  });
  for (const method of ['put', 'patch'] as const) app[method]('/attendance-days', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees', 'payroll.run');
    const b = parse(z.object({
      month: monthField,
      rows: z.array(z.object({
        employeeId: z.uuid(),
        days: z.array(z.object({ day: z.string().refine(isValidDate, 'Invalid date'), status: dayStatus.nullable() })).max(31),
      })).min(1).max(1000),
    }), req.body);
    return ctx.tx(async (tx) => {
      const live = await tx.selectFrom('payroll_runs').select('id').where('company_id', '=', ctx.companyId).where('month', '=', b.month)
        .where('status', 'in', ['approved', 'posted']).executeTakeFirst();
      if (live) throw conflict('Payroll for this month is already approved. Attendance cannot change.', 'RUN_LOCKED');
      const end = lastDayOf(b.month);
      for (const r of b.rows) {
        await getEmployee(tx, ctx, r.employeeId);
        for (const d of r.days) {
          if (d.day < b.month || d.day > end) throw badRequest(`${d.day} is outside the month`);
          if (d.status === null) {
            await tx.deleteFrom('attendance_days').where('employee_id', '=', r.employeeId).where('day', '=', d.day).execute();
          } else {
            await tx.insertInto('attendance_days').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: r.employeeId, day: d.day, status: d.status, updated_by: ctx.userId })
              .onConflict((oc) => oc.columns(['employee_id', 'day']).doUpdateSet({ status: d.status!, updated_by: ctx.userId })).execute();
          }
        }
        const all = await tx.selectFrom('attendance_days').select('status').where('employee_id', '=', r.employeeId).where('day', '>=', b.month).where('day', '<=', end).execute();
        const n = (st: string) => all.filter((x) => x.status === st).length;
        const set = { present_days: n('present') + n('half_day') / 2, paid_leave_days: n('leave'), lop_days: n('absent') + n('half_day') / 2, source: 'register', updated_by: ctx.userId };
        await tx.insertInto('attendance_summaries').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: r.employeeId, month: b.month, ...set })
          .onConflict((oc) => oc.columns(['employee_id', 'month']).doUpdateSet(set)).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'attendance_register', null, 'update', null, { month: b.month, employees: b.rows.length });
      return daysJson(tx, ctx.companyId, b.month);
    });
  });
  app.post('/attendance-summaries/derive', async (req) => {
    const ctx = req.ctx;
    ctx.require('payroll.employees', 'payroll.run');
    const b = parse(z.object({ month: monthField }), req.body);
    return ctx.tx(async (tx) => {
      const emps = await tx.selectFrom('employees').select(['id', 'location_id']).where('company_id', '=', ctx.companyId).where('status', '=', 'active').execute();
      const leave = await leaveInMonth(tx, ctx.companyId, b.month, emps);
      let n = 0;
      for (const e of emps) {
        const l = leave.get(e.id)!;
        const existing = await tx.selectFrom('attendance_summaries').select('source').where('employee_id', '=', e.id).where('month', '=', b.month).executeTakeFirst();
        if (existing?.source === 'manual') continue;
        const set = { paid_leave_days: l.paid, lop_days: l.unpaid, source: 'derived', updated_by: ctx.userId };
        await tx.insertInto('attendance_summaries').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, employee_id: e.id, month: b.month, ...set })
          .onConflict((oc) => oc.columns(['employee_id', 'month']).doUpdateSet(set)).execute();
        n += 1;
      }
      return { derived: n };
    });
  });

  // HR home
  app.get('/hr/summary', async (req) => {
    const ctx = req.ctx;
    requireDirectory(ctx);
    return ctx.tx(async (tx) => {
      const today = todayIst();
      const monthStart = `${today.slice(0, 7)}-01`;
      const scope = scopedLocationIds(ctx);
      const emps = await tx.selectFrom('employees').select(['id', 'name', 'dob', 'status', 'joining_date', 'leaving_date', 'department'])
        .where('company_id', '=', ctx.companyId).$if(!!scope, (qb) => qb.where('location_id', 'in', scope!)).execute();
      const active = emps.filter((e) => e.status === 'active');
      const pending = await tx.selectFrom('leave_applications').select((eb) => eb.fn.countAll<number>().as('n')).where('company_id', '=', ctx.companyId).where('status', '=', 'pending').executeTakeFirstOrThrow();
      const onLeave = await tx.selectFrom('leave_applications').select((eb) => eb.fn.countAll<number>().as('n')).where('company_id', '=', ctx.companyId)
        .where('status', '=', 'approved').where('from_date', '<=', today).where('to_date', '>=', today).executeTakeFirstOrThrow();
      const run = ctx.can('payroll.view') ? await tx.selectFrom('payroll_runs').select(['id', 'status', 'location_id', 'net', 'employee_count'])
        .where('company_id', '=', ctx.companyId).where('month', '=', monthStart).where('status', '<>', 'cancelled').execute() : [];
      const mmdd = (d: string) => d.slice(5);
      const in14 = new Date(Date.parse(`${today}T00:00:00Z`) + 14 * 86400000).toISOString().slice(0, 10);
      const birthdays = active.filter((e) => e.dob).map((e) => ({ id: e.id, name: e.name, date: `${today.slice(0, 4)}-${mmdd(e.dob!)}` }))
        .filter((e) => e.date >= today && e.date <= in14).sort((a, b) => a.date.localeCompare(b.date)).slice(0, 5);
      const byDept = new Map<string, number>();
      for (const e of active) byDept.set(e.department ?? 'No department', (byDept.get(e.department ?? 'No department') ?? 0) + 1);
      return {
        headCount: active.length, joinersThisMonth: emps.filter((e) => e.joining_date >= monthStart).length,
        leaversThisMonth: emps.filter((e) => e.leaving_date && e.leaving_date >= monthStart && e.leaving_date <= today).length,
        pendingLeave: pending.n, onLeaveToday: onLeave.n, month: monthStart.slice(0, 7),
        payroll: run.map((r) => ({ id: r.id, status: r.status, locationId: r.location_id, net: r.net, employeeCount: r.employee_count })),
        birthdays, departments: [...byDept.entries()].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count),
      };
    });
  });
}

documentRoute('POST', '/payroll/components', { body: componentBody });
documentRoute('PATCH', '/payroll/components/:id', { body: componentPatch });
documentRoute('POST', '/employees', { body: createEmployee });
documentRoute('PATCH', '/employees/:id', { body: patchEmployee });
documentRoute('POST', '/employees/:id/salary', { body: salaryBody });
documentRoute('POST', '/leave-types', { body: leaveTypeBody });
documentRoute('PATCH', '/leave-types/:id', { body: leaveTypePatch });
documentRoute('POST', '/leave-applications', { body: applyBody });
