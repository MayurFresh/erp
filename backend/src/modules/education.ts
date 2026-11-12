import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import { createPayment } from './payments.ts';
import { documentRoute } from '../lib/openapi.ts';
import { educationExamRoutes } from './education-exams.ts';

/*
 * School and coaching administration. Students are linked to a party (the payer). Fee demands are normal invoices made
 * through the invoice service, fee receipts are normal payments. No ledger rows are written here.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const SEXES = ['male', 'female', 'other'] as const;
const STUDENT_STATUSES = ['active', 'left', 'passed_out'] as const;
const ATT = ['present', 'absent', 'late'] as const;
const MAX_BATCH = 500;
const round2 = (n: number) => Math.round(n * 100) / 100;
const blank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? undefined : v);
const phoneField = z.string().trim().min(5, 'Enter a phone number').max(20).regex(/^[0-9+() -]+$/, 'Digits only');

const yearBody = z.object({
  name: z.string().trim().min(1, 'Required').max(40), startDate: dateField, endDate: dateField, isCurrent: z.boolean().optional(),
});
const yearPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(), name: z.string().trim().min(1).max(40).optional(),
  startDate: dateField.optional(), endDate: dateField.optional(), isCurrent: z.boolean().optional(),
});

const optInt = (max: number) => z.preprocess((v) => (v === '' || v === null ? undefined : v), z.coerce.number().int().min(1).max(max).optional());
const classBody = z.object({
  yearId: z.uuid(), kind: z.enum(['class', 'batch']).default('class'), name: z.string().trim().min(1, 'Required').max(80),
  section: optionalText(20), course: optionalText(100), timing: optionalText(100),
  teacherUserId: z.uuid().nullable().optional(), teacherName: optionalText(100), capacity: optInt(2000),
});
const classPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(), name: z.string().trim().min(1).max(80).optional(),
  section: nullableText(20), course: nullableText(100), timing: nullableText(100),
  teacherUserId: z.uuid().nullable().optional(), teacherName: nullableText(100),
  capacity: z.preprocess((v) => (v === '' ? null : v), z.coerce.number().int().min(1).max(2000).nullable().optional()),
  isActive: z.boolean().optional(),
});

const studentFields = {
  name: z.string().trim().min(1, 'Required').max(200), sex: z.enum(SEXES),
  classId: z.uuid().nullable().optional(), rollNo: optionalText(20),
  dob: z.preprocess(blank, dateField.optional()),
  guardianName: z.string().trim().min(1, 'Required').max(200), guardianRelation: optionalText(40), guardianPhone: phoneField,
  address: optionalText(500), admissionDate: z.preprocess(blank, dateField.optional()), notes: optionalText(2000),
};
const studentCreate = z.object(studentFields).extend({ force: z.boolean().optional() });
const studentPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: studentFields.name.optional(), sex: z.enum(SEXES).optional(), classId: z.uuid().nullable().optional(), rollNo: nullableText(20),
  dob: z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional()),
  guardianName: studentFields.guardianName.optional(), guardianRelation: nullableText(40), guardianPhone: phoneField.optional(),
  address: nullableText(500), notes: nullableText(2000),
  status: z.enum(STUDENT_STATUSES).optional(),
});
const studentList = pagingQuery.extend({
  classId: z.uuid().optional(), status: z.enum(STUDENT_STATUSES).optional(), yearId: z.uuid().optional(),
});

const headBody = z.object({ name: z.string().trim().min(1, 'Required').max(80), gstRate: z.coerce.number().min(0).max(40).default(0) });
const headPatch = z.object({
  name: z.string().trim().min(1).max(80).optional(), gstRate: z.coerce.number().min(0).max(40).optional(), isActive: z.boolean().optional(),
});

const planBody = z.object({
  name: z.string().trim().min(1, 'Required').max(80).default('Fee plan'),
  late: z.object({
    kind: z.enum(['none', 'flat', 'percent', 'per_day']), value: moneyField.default(0), headId: z.uuid().nullable().optional(),
  }).default({ kind: 'none', value: 0 }),
  instalments: z.array(z.object({
    label: z.string().trim().min(1, 'Required').max(60), dueDate: dateField,
    lines: z.array(z.object({ headId: z.uuid(), amount: moneyField.refine((v) => v > 0, 'Must be more than zero') })).min(1, 'Add a fee head').max(30),
  })).min(1, 'Add at least one instalment').max(24),
});

const concessionBody = z.object({
  headId: z.uuid(), kind: z.enum(['percent', 'amount']), value: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  reason: z.string().trim().min(1, 'Give a reason').max(200),
});
const promoteBody = z.object({
  fromClassId: z.uuid(), toClassId: z.uuid().optional(), passOut: z.boolean().optional(), studentIds: z.array(z.uuid()).max(2000).optional(),
});
const generateBody = z.object({
  classId: z.uuid(), instalmentId: z.uuid(), preview: z.boolean().optional(), applyLateFee: z.boolean().default(true), locationId: z.uuid().optional(),
});
const duesQuery = pagingQuery.extend({ classId: z.uuid().optional(), overdue: z.enum(['true', 'false']).optional() });
const collectBody = z.object({
  accountId: z.uuid(), mode: z.enum(['cash', 'bank', 'upi', 'cheque', 'card']), amount: moneyField.refine((v) => v > 0, 'Must be more than zero'),
  reference: optionalText(60), date: dateField.optional(),
});
const attendanceQuery = z.object({ date: dateField.optional() });
const attendanceBody = z.object({
  date: dateField.optional(),
  marks: z.array(z.object({ studentId: z.uuid(), status: z.enum(ATT) })).max(2000),
});
const monthQuery = z.object({ month: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM').optional() });

// Helpers ---------------------------------------------------------------------------------------

type ClassRow = Awaited<ReturnType<typeof loadClass>>;
type StudentRow = Awaited<ReturnType<typeof loadStudent>>;

async function loadYear(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('edu_years').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Academic year');
  return row;
}
async function loadClass(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('edu_classes').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Class or batch');
  return row;
}
async function loadStudent(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('edu_students').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Student');
  return row;
}

const yearJson = (y: Awaited<ReturnType<typeof loadYear>>) => ({
  id: y.id, name: y.name, startDate: y.start_date, endDate: y.end_date, isCurrent: y.is_current, updatedAt: y.updated_at,
});
const classLabel = (c: { name: string; section: string | null }) => (c.section ? `${c.name} ${c.section}` : c.name);
const classJson = (c: ClassRow, extra: Record<string, unknown> = {}) => ({
  id: c.id, yearId: c.year_id, kind: c.kind, name: c.name, section: c.section, label: classLabel(c), course: c.course, timing: c.timing,
  teacherUserId: c.teacher_user_id, teacherName: c.teacher_name, capacity: c.capacity, isActive: c.is_active, updatedAt: c.updated_at, ...extra,
});
const studentBrief = (s: StudentRow, cls?: { name: string; section: string | null } | null) => ({
  id: s.id, admissionNo: s.admission_no, name: s.name, classId: s.class_id, className: cls ? classLabel(cls) : null, rollNo: s.roll_no,
  sex: s.sex, guardianName: s.guardian_name, guardianPhone: s.guardian_phone, status: s.status,
});
const studentJson = (s: StudentRow, cls?: { name: string; section: string | null } | null) => ({
  ...studentBrief(s, cls), partyId: s.party_id, dob: s.dob, guardianRelation: s.guardian_relation, address: s.address,
  admissionDate: s.admission_date, leftDate: s.left_date, notes: s.notes, createdAt: s.created_at, updatedAt: s.updated_at,
});

const needManage = (ctx: RequestContext) => ctx.require('education.manage');
const needFees = (ctx: RequestContext) => ctx.require('education.fees', 'education.manage');

function canMark(ctx: RequestContext, cls: ClassRow) {
  ctx.require('education.attendance', 'education.manage');
  if (!ctx.can('education.manage') && cls.teacher_user_id !== ctx.userId) throw forbidden('You can mark attendance only for your own classes.');
}

async function defaultLocation(tx: Tx, ctx: RequestContext, wanted?: string) {
  if (wanted) return wanted;
  const locs = await tx.selectFrom('locations').select('id').where('company_id', '=', ctx.companyId)
    .where('is_active', '=', true).orderBy('created_at').execute();
  const found = locs.find((l) => ctx.canAccessLocation(l.id));
  if (!found) throw badRequest('Add a location before billing.', { locationId: 'Required' });
  return found.id;
}

/** Open fee dues per student: raised through demands, invoice still posted and not fully paid. */
async function dueRows(tx: Tx, ctx: RequestContext, filter: { studentId?: string; classId?: string; q?: string } = {}) {
  const today = todayIst();
  let q = tx.selectFrom('edu_demands as d')
    .innerJoin('invoices as i', 'i.id', 'd.invoice_id')
    .innerJoin('edu_instalments as n', 'n.id', 'd.instalment_id')
    .innerJoin('edu_students as s', 's.id', 'd.student_id')
    .select(['d.id as demand_id', 's.id as student_id', 'i.id as invoice_id', 'i.number', 'i.total', 'i.amount_paid', 'i.due_date', 'n.label', 'n.seq'])
    .where('d.company_id', '=', ctx.companyId).where('d.status', '=', 'billed').where('i.status', '=', 'posted')
    .whereRef('i.amount_paid', '<', 'i.total');
  if (filter.studentId) q = q.where('s.id', '=', filter.studentId);
  if (filter.classId) q = q.where('s.class_id', '=', filter.classId);
  if (filter.q) {
    const t = likeTerm(filter.q);
    q = q.where((eb) => eb.or([eb('s.name', 'ilike', t), eb('s.admission_no', 'ilike', t), eb('s.guardian_phone', 'ilike', t)]));
  }
  const rows = await q.orderBy('i.due_date').orderBy('n.seq').execute();
  const by = new Map<string, { studentId: string; due: number; overdue: number; oldestDue: string | null; invoices: DueInvoice[] }>();
  for (const r of rows) {
    const amount = round2(r.total - r.amount_paid);
    const e = by.get(r.student_id) ?? { studentId: r.student_id, due: 0, overdue: 0, oldestDue: null, invoices: [] };
    const late = r.due_date < today;
    e.due = round2(e.due + amount);
    if (late) { e.overdue = round2(e.overdue + amount); e.oldestDue ??= r.due_date; }
    e.invoices.push({ invoiceId: r.invoice_id, number: r.number, label: r.label, dueDate: r.due_date, total: r.total, paid: r.amount_paid, due: amount, overdue: late });
    by.set(r.student_id, e);
  }
  return by;
}
interface DueInvoice { invoiceId: string; number: string; label: string; dueDate: string; total: number; paid: number; due: number; overdue: boolean }

const inr = (n: number) => `Rs ${n.toLocaleString('en-IN', { minimumFractionDigits: n % 1 ? 2 : 0, maximumFractionDigits: 2 })}`;

function reminderText(school: string, s: { name: string; guardian_name: string }, cls: string | null, e: { due: number; overdue: number; oldestDue: string | null }) {
  const today = todayIst();
  const lead = `Dear ${s.guardian_name}, `;
  const what = `the fee for ${s.name}${cls ? ` (${cls})` : ''}`;
  if (e.overdue > 0 && e.oldestDue) {
    const days = daysBetween(e.oldestDue, today);
    return `${lead}${what} has ${inr(e.overdue)} overdue, unpaid for ${days} day${days === 1 ? '' : 's'}. Total due is ${inr(e.due)}. Please pay at the office or reply to this message. Thank you, ${school}.`;
  }
  return `${lead}${what} has ${inr(e.due)} due. Please pay at the office by the due date. Thank you, ${school}.`;
}

async function companyName(tx: Tx, ctx: RequestContext) {
  const c = await tx.selectFrom('companies').select(['name', 'legal_name', 'address', 'phone', 'gstin']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  return c;
}

async function headRows(tx: Tx, ctx: RequestContext) {
  return tx.selectFrom('edu_fee_heads').selectAll().where('company_id', '=', ctx.companyId).orderBy('name').execute();
}
const headJson = (h: { id: string; name: string; gst_rate: number; is_active: boolean; item_id: string }) =>
  ({ id: h.id, name: h.name, gstRate: h.gst_rate, isActive: h.is_active, itemId: h.item_id });

interface PlanLine { headId: string; amount: number }

async function loadPlanFor(tx: Tx, ctx: RequestContext, classId: string) {
  const plan = await tx.selectFrom('edu_fee_plans').selectAll().where('class_id', '=', classId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!plan) return null;
  const inst = await tx.selectFrom('edu_instalments').selectAll().where('plan_id', '=', plan.id).orderBy('seq').execute();
  return { plan, inst };
}
function planJson(p: NonNullable<Awaited<ReturnType<typeof loadPlanFor>>>) {
  return {
    id: p.plan.id, classId: p.plan.class_id, name: p.plan.name, updatedAt: p.plan.updated_at,
    late: { kind: p.plan.late_kind, value: p.plan.late_value, headId: p.plan.late_head_id },
    instalments: p.inst.map((n) => ({
      id: n.id, seq: n.seq, label: n.label, dueDate: n.due_date, lines: n.lines as PlanLine[],
      total: round2((n.lines as PlanLine[]).reduce((s, l) => s + l.amount, 0)),
    })),
  };
}

/** The lines one student is billed for in one instalment, after concessions and any late fee. */
function buildLines(
  inst: { label: string; due_date: string; lines: unknown },
  heads: Map<string, { id: string; name: string; item_id: string }>,
  concessions: Map<string, { kind: string; value: number }>,
  late: { kind: string; value: number; headId: string | null } | null,
  today: string,
) {
  const lines: { itemId: string; qty: number; rate: number; description: string }[] = [];
  let net = 0;
  let concession = 0;
  for (const l of inst.lines as PlanLine[]) {
    const head = heads.get(l.headId);
    if (!head) continue;
    const c = concessions.get(l.headId);
    const off = c ? Math.min(l.amount, round2(c.kind === 'percent' ? (l.amount * c.value) / 100 : c.value)) : 0;
    const rate = round2(l.amount - off);
    concession = round2(concession + off);
    if (rate <= 0) continue;
    net = round2(net + rate);
    lines.push({ itemId: head.item_id, qty: 1, rate, description: `${head.name} - ${inst.label}${off > 0 ? ' (after concession)' : ''}` });
  }
  let lateFee = 0;
  if (lines.length && late && late.kind !== 'none' && late.headId && today > inst.due_date) {
    const days = daysBetween(inst.due_date, today);
    lateFee = round2(late.kind === 'flat' ? late.value : late.kind === 'percent' ? (net * late.value) / 100 : late.value * days);
    const head = heads.get(late.headId);
    if (lateFee > 0 && head) {
      lines.push({ itemId: head.item_id, qty: 1, rate: lateFee, description: `${head.name} - ${inst.label} (${days} day${days === 1 ? '' : 's'} late)` });
    } else lateFee = 0;
  }
  return { lines, net, concession, lateFee };
}

function monthRange(month: string) {
  const from = `${month}-01`;
  const next = new Date(`${from}T00:00:00Z`);
  next.setUTCMonth(next.getUTCMonth() + 1);
  const to = addDays(next.toISOString().slice(0, 10), -1);
  return { from, to, days: Number(to.slice(8)) };
}

const rollOrder = sql`nullif(regexp_replace(coalesce(roll_no, ''), '\\D', '', 'g'), '')::int nulls last`;

function attStats(rows: { status: string }[]) {
  const present = rows.filter((r) => r.status === 'present').length;
  const late = rows.filter((r) => r.status === 'late').length;
  const absent = rows.filter((r) => r.status === 'absent').length;
  const marked = rows.length;
  return { present, late, absent, marked, percentage: marked ? Math.round(((present + late) / marked) * 1000) / 10 : null };
}

// Routes ----------------------------------------------------------------------------------------

export async function educationRoutes(app: FastifyInstance) {
  await educationExamRoutes(app);
  // Home --------------------------------------------------------------------------------------

  app.get('/education/home', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const today = todayIst();
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('edu_years').selectAll().where('company_id', '=', ctx.companyId)
        .orderBy('is_current', 'desc').orderBy('start_date', 'desc').limit(1).executeTakeFirst();
      const classes = cur
        ? await tx.selectFrom('edu_classes').selectAll().where('company_id', '=', ctx.companyId).where('year_id', '=', cur.id)
          .where('is_active', '=', true).orderBy('name').orderBy('section').execute()
        : [];
      const counts = await tx.selectFrom('edu_students').select(['class_id', sql<number>`count(*)`.as('n')])
        .where('company_id', '=', ctx.companyId).where('status', '=', 'active').groupBy('class_id').execute();
      const att = await tx.selectFrom('edu_attendance').select(['class_id', 'status', sql<number>`count(*)`.as('n')])
        .where('company_id', '=', ctx.companyId).where('att_date', '=', today).groupBy(['class_id', 'status']).execute();
      const collected = await tx.selectFrom('payments as p').innerJoin('edu_students as s', 's.party_id', 'p.party_id')
        .select(sql<number>`coalesce(sum(p.amount), 0)`.as('total'))
        .where('p.company_id', '=', ctx.companyId).where('p.kind', '=', 'receipt').where('p.status', '=', 'posted')
        .where('p.payment_date', '=', today).executeTakeFirstOrThrow();
      const dues = ctx.can('education.fees') || ctx.can('education.manage') ? await dueRows(tx, ctx) : new Map();
      const list = [...dues.values()];
      return {
        today, year: cur ? yearJson(cur) : null,
        classes: classes.map((c) => {
          const n = Number(counts.find((x) => x.class_id === c.id)?.n ?? 0);
          const a = (s: string) => Number(att.find((x) => x.class_id === c.id && x.status === s)?.n ?? 0);
          const marked = a('present') + a('absent') + a('late');
          return {
            ...classJson(c), students: n, attendanceMarked: marked > 0, present: a('present'), absent: a('absent'), late: a('late'),
            mine: c.teacher_user_id === ctx.userId,
          };
        }),
        feesCollectedToday: ctx.can('education.fees') || ctx.can('education.manage') ? round2(Number(collected.total)) : null,
        duesTotal: list.reduce((s, e) => round2(s + e.due), 0),
        defaultersCount: list.filter((e) => e.overdue > 0).length,
      };
    });
  });

  app.get('/education/staff', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    return ctx.tx(async (tx) => ({
      data: await tx.selectFrom('user_roles as ur').innerJoin('users as u', 'u.id', 'ur.user_id')
        .select(['u.id', 'u.name']).distinct().where('ur.company_id', '=', ctx.companyId).where('u.is_active', '=', true).orderBy('u.name').execute(),
    }));
  });

  // Academic years ----------------------------------------------------------------------------

  app.get('/education/years', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    return ctx.tx(async (tx) => ({
      data: (await tx.selectFrom('edu_years').selectAll().where('company_id', '=', ctx.companyId).orderBy('start_date', 'desc').execute()).map(yearJson),
    }));
  });

  app.post('/education/years', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(yearBody, req.body);
    if (b.endDate <= b.startDate) throw badRequest('End date must be after the start date.', { endDate: 'Before start' });
    const out = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('edu_years').select('id').where('company_id', '=', ctx.companyId).where('name', '=', b.name).executeTakeFirst();
      if (dup) throw conflict('An academic year with this name already exists.', 'DUPLICATE_YEAR');
      const first = !(await tx.selectFrom('edu_years').select('id').where('company_id', '=', ctx.companyId).executeTakeFirst());
      const makeCurrent = b.isCurrent ?? first;
      if (makeCurrent) await tx.updateTable('edu_years').set({ is_current: false }).where('company_id', '=', ctx.companyId).execute();
      const row = await tx.insertInto('edu_years').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, start_date: b.startDate, end_date: b.endDate, is_current: makeCurrent,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'edu_year', row.id, 'create', null, { name: b.name });
      return yearJson(row);
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/education/years/:id', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(yearPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadYear(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'academic year');
      const start = b.startDate ?? before.start_date;
      const end = b.endDate ?? before.end_date;
      if (end <= start) throw badRequest('End date must be after the start date.', { endDate: 'Before start' });
      if (b.isCurrent) await tx.updateTable('edu_years').set({ is_current: false }).where('company_id', '=', ctx.companyId).where('id', '!=', id).execute();
      await tx.updateTable('edu_years').set(definedOnly({ name: b.name, start_date: b.startDate, end_date: b.endDate, is_current: b.isCurrent }) as never)
        .where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'edu_year', id, 'update', null, { fields: Object.keys(definedOnly({ ...b, expectedUpdatedAt: undefined })) });
      return yearJson(await loadYear(tx, ctx, id));
    });
  });

  // Classes and batches -----------------------------------------------------------------------

  app.get('/education/classes', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const q = parse(z.object({ yearId: z.uuid().optional(), kind: z.enum(['class', 'batch']).optional(), active: z.enum(['true', 'false']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('edu_classes').selectAll().where('company_id', '=', ctx.companyId);
      if (q.yearId) base = base.where('year_id', '=', q.yearId);
      if (q.kind) base = base.where('kind', '=', q.kind);
      if (q.active) base = base.where('is_active', '=', q.active === 'true');
      const rows = await base.orderBy('name').orderBy('section').execute();
      const counts = await tx.selectFrom('edu_students').select(['class_id', sql<number>`count(*)`.as('n')])
        .where('company_id', '=', ctx.companyId).where('status', '=', 'active').groupBy('class_id').execute();
      return { data: rows.map((c) => classJson(c, { students: Number(counts.find((x) => x.class_id === c.id)?.n ?? 0), mine: c.teacher_user_id === ctx.userId })) };
    });
  });

  app.post('/education/classes', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(classBody, req.body);
    const out = await ctx.tx(async (tx) => {
      await loadYear(tx, ctx, b.yearId);
      if (b.teacherUserId) await assertTeacher(tx, ctx, b.teacherUserId);
      const dup = await tx.selectFrom('edu_classes').select('id').where('company_id', '=', ctx.companyId).where('year_id', '=', b.yearId)
        .where(sql`lower(name)`, '=', b.name.toLowerCase()).where(sql`coalesce(lower(section), '')`, '=', (b.section ?? '').toLowerCase()).executeTakeFirst();
      if (dup) throw conflict('This class or batch already exists in the year.', 'DUPLICATE_CLASS');
      const row = await tx.insertInto('edu_classes').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, year_id: b.yearId, kind: b.kind, name: b.name, section: b.section ?? null,
        course: b.course ?? null, timing: b.timing ?? null, teacher_user_id: b.teacherUserId ?? null, teacher_name: b.teacherName ?? null,
        capacity: b.capacity ?? null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'edu_class', row.id, 'create', null, { name: b.name });
      return classJson(row, { students: 0, mine: false });
    });
    return reply.status(201).send(out);
  });

  async function assertTeacher(tx: Tx, ctx: RequestContext, userId: string) {
    const u = await tx.selectFrom('user_roles').select('user_id').where('user_id', '=', userId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!u) throw badRequest('That person does not work in this business.', { teacherUserId: 'Not found' });
  }

  app.get<{ Params: { id: string } }>('/education/classes/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const c = await loadClass(tx, ctx, id);
      const n = await tx.selectFrom('edu_students').select(sql<number>`count(*)`.as('n')).where('class_id', '=', id).where('status', '=', 'active').executeTakeFirstOrThrow();
      return classJson(c, { students: Number(n.n), mine: c.teacher_user_id === ctx.userId });
    });
  });

  app.patch<{ Params: { id: string } }>('/education/classes/:id', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(classPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadClass(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'class');
      if (b.teacherUserId) await assertTeacher(tx, ctx, b.teacherUserId);
      const changes = definedOnly({
        name: b.name, section: b.section, course: b.course, timing: b.timing, teacher_user_id: b.teacherUserId,
        teacher_name: b.teacherName, capacity: b.capacity, is_active: b.isActive,
      });
      if (Object.keys(changes).length) {
        await tx.updateTable('edu_classes').set(changes as never).where('id', '=', id).execute();
        await writeAudit(tx, auditOf(ctx), 'edu_class', id, 'update', null, { fields: Object.keys(changes) });
      }
      return classJson(await loadClass(tx, ctx, id));
    });
  });

  // Fee heads ---------------------------------------------------------------------------------

  app.get('/education/fee-heads', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    return ctx.tx(async (tx) => ({ data: (await headRows(tx, ctx)).map(headJson) }));
  });

  app.post('/education/fee-heads', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(headBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('edu_fee_heads').select('id').where('company_id', '=', ctx.companyId).where(sql`lower(name)`, '=', b.name.toLowerCase()).executeTakeFirst();
      if (dup) throw conflict('A fee head with this name already exists.', 'DUPLICATE_HEAD');
      const item = await tx.insertInto('items').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, sku: null, hsn_code: '999293', unit: 'NOS',
        gst_rate: b.gstRate, sale_price: 0, track_stock: false,
      }).returning('id').executeTakeFirstOrThrow();
      const row = await tx.insertInto('edu_fee_heads').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: item.id, name: b.name, gst_rate: b.gstRate,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'edu_fee_head', row.id, 'create', null, { name: b.name, gstRate: b.gstRate });
      return headJson(row);
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/education/fee-heads/:id', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(headPatch, req.body);
    return ctx.tx(async (tx) => {
      const h = await tx.selectFrom('edu_fee_heads').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!h) throw notFound('Fee head');
      await tx.updateTable('edu_fee_heads').set(definedOnly({ name: b.name, gst_rate: b.gstRate, is_active: b.isActive }) as never).where('id', '=', id).execute();
      if (b.name !== undefined || b.gstRate !== undefined) {
        await tx.updateTable('items').set(definedOnly({ name: b.name, gst_rate: b.gstRate }) as never).where('id', '=', h.item_id).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'edu_fee_head', id, 'update', null, { fields: Object.keys(definedOnly({ ...b })) });
      return headJson(await tx.selectFrom('edu_fee_heads').selectAll().where('id', '=', id).executeTakeFirstOrThrow());
    });
  });

  // Fee plans ---------------------------------------------------------------------------------

  app.get<{ Params: { id: string } }>('/education/classes/:id/fee-plan', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await loadClass(tx, ctx, id);
      const p = await loadPlanFor(tx, ctx, id);
      if (!p) throw notFound('Fee plan');
      return planJson(p);
    });
  });

  // PUT is the contract; POST is accepted too for clients that only send POST, PATCH and GET.
  app.route<{ Params: { id: string } }>({ method: ['PUT', 'POST'], url: '/education/classes/:id/fee-plan', handler: async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(planBody, req.body);
    return ctx.tx(async (tx) => {
      await loadClass(tx, ctx, id, true);
      const heads = new Map((await headRows(tx, ctx)).map((h) => [h.id, h]));
      b.instalments.forEach((n, i) => {
        const seen = new Set<string>();
        for (const l of n.lines) {
          if (!heads.has(l.headId)) throw badRequest(`Instalment ${i + 1}: unknown fee head.`, { [`instalments.${i}.lines`]: 'Unknown head' });
          if (seen.has(l.headId)) throw badRequest(`Instalment ${i + 1}: a head is listed twice.`, { [`instalments.${i}.lines`]: 'Duplicate head' });
          seen.add(l.headId);
        }
      });
      if (b.late.kind !== 'none') {
        if (!b.late.headId || !heads.has(b.late.headId)) throw badRequest('Choose the fee head for late fees.', { 'late.headId': 'Required' });
        if (b.late.value <= 0) throw badRequest('Give the late fee amount.', { 'late.value': 'Required' });
        if (b.late.kind === 'percent' && b.late.value > 100) throw badRequest('A percentage cannot be over 100.', { 'late.value': 'Too high' });
      }
      const lateHead = b.late.kind === 'none' ? null : b.late.headId!;
      const existing = await loadPlanFor(tx, ctx, id);
      let planId: string;
      if (existing) {
        planId = existing.plan.id;
        await tx.updateTable('edu_fee_plans').set({ name: b.name, late_kind: b.late.kind, late_value: b.late.kind === 'none' ? 0 : b.late.value, late_head_id: lateHead }).where('id', '=', planId).execute();
        // Instalments are matched by position so ones already billed keep their id.
        for (let i = 0; i < b.instalments.length; i++) {
          const n = b.instalments[i]!;
          const found = existing.inst.find((x) => x.seq === i + 1);
          if (found) {
            await tx.updateTable('edu_instalments').set({ label: n.label, due_date: n.dueDate, lines: JSON.stringify(n.lines) as never }).where('id', '=', found.id).execute();
          } else {
            await tx.insertInto('edu_instalments').values({ tenant_id: ctx.tenantId, plan_id: planId, seq: i + 1, label: n.label, due_date: n.dueDate, lines: JSON.stringify(n.lines) as never }).execute();
          }
        }
        for (const gone of existing.inst.filter((x) => x.seq > b.instalments.length)) {
          const used = await tx.selectFrom('edu_demands').select('id').where('instalment_id', '=', gone.id).limit(1).executeTakeFirst();
          if (used) throw conflict(`Instalment ${gone.seq} already has fee bills and cannot be removed.`, 'PLAN_IN_USE');
          await tx.deleteFrom('edu_instalments').where('id', '=', gone.id).execute();
        }
      } else {
        const row = await tx.insertInto('edu_fee_plans').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, class_id: id, name: b.name, late_kind: b.late.kind,
          late_value: b.late.kind === 'none' ? 0 : b.late.value, late_head_id: lateHead,
        }).returning('id').executeTakeFirstOrThrow();
        planId = row.id;
        for (let i = 0; i < b.instalments.length; i++) {
          const n = b.instalments[i]!;
          await tx.insertInto('edu_instalments').values({ tenant_id: ctx.tenantId, plan_id: planId, seq: i + 1, label: n.label, due_date: n.dueDate, lines: JSON.stringify(n.lines) as never }).execute();
        }
      }
      await writeAudit(tx, auditOf(ctx), 'edu_fee_plan', planId, existing ? 'update' : 'create', null, { classId: id, instalments: b.instalments.length });
      return planJson((await loadPlanFor(tx, ctx, id))!);
    });
  } });

  // Students ----------------------------------------------------------------------------------

  app.get('/education/students', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const q = parse(studentList, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('edu_students as s').leftJoin('edu_classes as c', 'c.id', 's.class_id').where('s.company_id', '=', ctx.companyId);
      if (q.classId) base = base.where('s.class_id', '=', q.classId);
      if (q.yearId) base = base.where('c.year_id', '=', q.yearId);
      base = base.where('s.status', '=', q.status ?? 'active');
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('s.name', 'ilike', t), eb('s.admission_no', 'ilike', t), eb('s.guardian_phone', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll('s').select(['c.name as c_name', 'c.section as c_section'])
        .orderBy('s.name').orderBy('s.admission_no').limit(q.limit).offset(q.offset).execute();
      return { total: Number(total), data: rows.map((r) => studentBrief(r as never, r.c_name ? { name: r.c_name, section: r.c_section } : null)) };
    });
  });

  app.post('/education/students', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('education.admissions', 'education.manage');
    const b = parse(studentCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      let cls: ClassRow | undefined;
      if (b.classId) {
        cls = await loadClass(tx, ctx, b.classId, true);
        if (!cls.is_active) throw badRequest('This class is not active.', { classId: 'Inactive' });
        if (cls.capacity) {
          const n = await tx.selectFrom('edu_students').select(sql<number>`count(*)`.as('n')).where('class_id', '=', cls.id).where('status', '=', 'active').executeTakeFirstOrThrow();
          if (Number(n.n) >= cls.capacity) throw conflict(`${classLabel(cls)} is full (${cls.capacity} students).`, 'CLASS_FULL');
        }
      }
      if (!b.force) {
        const dup = await tx.selectFrom('edu_students').select(['id', 'admission_no', 'name', 'guardian_phone'])
          .where('company_id', '=', ctx.companyId).where('guardian_phone', '=', b.guardianPhone)
          .where(sql`lower(name)`, '=', b.name.toLowerCase()).limit(5).execute();
        if (dup.length) throw conflict('A student with this name and guardian phone is already admitted.', 'DUPLICATE_STUDENT', { matches: dup });
      }
      if (b.rollNo && b.classId) {
        const taken = await tx.selectFrom('edu_students').select('id').where('class_id', '=', b.classId).where('roll_no', '=', b.rollNo).where('status', '=', 'active').executeTakeFirst();
        if (taken) throw conflict('That roll number is already used in this class.', 'ROLL_TAKEN');
      }
      const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const party = await tx.insertInto('parties').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: b.name, phone: b.guardianPhone,
        address: b.address ?? null, state_code: company.state_code, gstin: null, email: null, pan: null, pincode: null,
        udyam_no: null, msme_category: null, tds_section_id: null,
      }).returning('id').executeTakeFirstOrThrow();
      const admissionDate = b.admissionDate ?? todayIst();
      const admissionNo = await nextNumber(tx, ctx, 'student', financialYear(admissionDate));
      const row = await tx.insertInto('edu_students').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, party_id: party.id, admission_no: admissionNo, name: b.name,
        class_id: b.classId ?? null, roll_no: b.rollNo ?? null, dob: b.dob ?? null, sex: b.sex, guardian_name: b.guardianName,
        guardian_relation: b.guardianRelation ?? null, guardian_phone: b.guardianPhone, address: b.address ?? null,
        admission_date: admissionDate, notes: b.notes ?? null, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'edu_student', row.id, 'create', null, { admissionNo, partyId: party.id });
      return studentJson(row, cls);
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/education/students/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const s = await loadStudent(tx, ctx, id);
      const cls = s.class_id ? await loadClass(tx, ctx, s.class_id) : null;
      const base = studentJson(s, cls);
      const concessions = await tx.selectFrom('edu_concessions as c').innerJoin('edu_fee_heads as h', 'h.id', 'c.head_id')
        .select(['c.id', 'c.head_id', 'h.name as head_name', 'c.kind', 'c.value', 'c.reason']).where('c.student_id', '=', id).where('c.is_active', '=', true).execute();
      const canFees = ctx.can('education.fees') || ctx.can('education.manage');
      const due = canFees ? (await dueRows(tx, ctx, { studentId: id })).get(id) : undefined;
      return {
        ...base, classYearId: cls?.year_id ?? null,
        concessions: concessions.map((c) => ({ id: c.id, headId: c.head_id, headName: c.head_name, kind: c.kind, value: c.value, reason: c.reason })),
        dues: canFees ? { due: due?.due ?? 0, overdue: due?.overdue ?? 0 } : null,
      };
    });
  });

  app.patch<{ Params: { id: string } }>('/education/students/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.admissions', 'education.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(studentPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadStudent(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'student');
      if (b.classId) {
        const cls = await loadClass(tx, ctx, b.classId);
        if (!cls.is_active) throw badRequest('This class is not active.', { classId: 'Inactive' });
      }
      const changes = definedOnly({
        name: b.name, sex: b.sex, class_id: b.classId, roll_no: b.rollNo, dob: b.dob, guardian_name: b.guardianName,
        guardian_relation: b.guardianRelation, guardian_phone: b.guardianPhone, address: b.address, notes: b.notes, status: b.status,
      }) as Record<string, unknown>;
      if (b.status && b.status !== 'active' && before.status === 'active') changes.left_date = todayIst();
      if (b.status === 'active') changes.left_date = null;
      const newClass = 'class_id' in changes ? changes.class_id : before.class_id;
      const newRoll = 'roll_no' in changes ? changes.roll_no : before.roll_no;
      if (newRoll && newClass && ('class_id' in changes || 'roll_no' in changes)) {
        const taken = await tx.selectFrom('edu_students').select('id').where('class_id', '=', newClass as string).where('roll_no', '=', newRoll as string)
          .where('status', '=', 'active').where('id', '!=', id).executeTakeFirst();
        if (taken) throw conflict('That roll number is already used in this class.', 'ROLL_TAKEN');
      }
      if (Object.keys(changes).length) {
        await tx.updateTable('edu_students').set(changes as never).where('id', '=', id).execute();
        if (b.name !== undefined || b.guardianPhone !== undefined || b.address !== undefined) {
          await tx.updateTable('parties').set(definedOnly({ name: b.name, phone: b.guardianPhone, address: b.address }) as never).where('id', '=', before.party_id).execute();
        }
        await writeAudit(tx, auditOf(ctx), 'edu_student', id, 'update', null, { fields: Object.keys(changes) });
      }
      const s = await loadStudent(tx, ctx, id);
      return studentJson(s, s.class_id ? await loadClass(tx, ctx, s.class_id) : null);
    });
  });

  // Concessions -------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/education/students/:id/concessions', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(concessionBody, req.body);
    if (b.kind === 'percent' && b.value > 100) throw badRequest('A percentage cannot be over 100.', { value: 'Too high' });
    const out = await ctx.tx(async (tx) => {
      await loadStudent(tx, ctx, id, true);
      const head = await tx.selectFrom('edu_fee_heads').select('name').where('id', '=', b.headId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!head) throw badRequest('Fee head not found.', { headId: 'Not found' });
      await tx.updateTable('edu_concessions').set({ is_active: false }).where('student_id', '=', id).where('head_id', '=', b.headId).where('is_active', '=', true).execute();
      const row = await tx.insertInto('edu_concessions').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, student_id: id, head_id: b.headId, kind: b.kind, value: b.value, reason: b.reason, created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'edu_student', id, 'concession', null, { headId: b.headId, kind: b.kind, value: b.value });
      return { id: row.id, headId: row.head_id, headName: head.name, kind: row.kind, value: row.value, reason: row.reason };
    });
    return reply.status(201).send(out);
  });

  app.delete<{ Params: { id: string } }>('/education/concessions/:id', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    await ctx.tx(async (tx) => {
      const r = await tx.updateTable('edu_concessions').set({ is_active: false }).where('id', '=', id).where('company_id', '=', ctx.companyId).where('is_active', '=', true).returning('student_id').executeTakeFirst();
      if (!r) throw notFound('Concession');
      await writeAudit(tx, auditOf(ctx), 'edu_student', r.student_id, 'concession_removed', null, { concessionId: id });
    });
    return reply.status(204).send();
  });

  // Promotion ---------------------------------------------------------------------------------

  app.post('/education/promote', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(promoteBody, req.body);
    if (!b.toClassId && !b.passOut) throw badRequest('Choose the next class, or mark the students as passed out.', { toClassId: 'Required' });
    if (b.toClassId === b.fromClassId) throw badRequest('Choose a different class.', { toClassId: 'Same class' });
    return ctx.tx(async (tx) => {
      const from = await loadClass(tx, ctx, b.fromClassId, true);
      const to = b.toClassId ? await loadClass(tx, ctx, b.toClassId, true) : null;
      if (to && !to.is_active) throw badRequest('The next class is not active.', { toClassId: 'Inactive' });
      let q = tx.selectFrom('edu_students').select(['id', 'name']).where('company_id', '=', ctx.companyId).where('class_id', '=', from.id).where('status', '=', 'active');
      if (b.studentIds) q = q.where('id', 'in', b.studentIds.length ? b.studentIds : ['00000000-0000-0000-0000-000000000000']);
      const students = await q.forUpdate().execute();
      if (to?.capacity) {
        const n = await tx.selectFrom('edu_students').select(sql<number>`count(*)`.as('n')).where('class_id', '=', to.id).where('status', '=', 'active').executeTakeFirstOrThrow();
        if (Number(n.n) + students.length > to.capacity) throw conflict(`${classLabel(to)} has room for ${Math.max(to.capacity - Number(n.n), 0)} more students.`, 'CLASS_FULL');
      }
      const ids = students.map((s) => s.id);
      if (ids.length) {
        if (to) await tx.updateTable('edu_students').set({ class_id: to.id, roll_no: null }).where('id', 'in', ids).execute();
        else await tx.updateTable('edu_students').set({ status: 'passed_out', left_date: todayIst() }).where('id', 'in', ids).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'edu_class', from.id, 'promote', null, { toClassId: to?.id ?? null, passOut: !to, count: ids.length });
      return { moved: ids.length, passedOut: to ? 0 : ids.length, from: classLabel(from), to: to ? classLabel(to) : null };
    });
  });

  // Fee demands -------------------------------------------------------------------------------

  app.post('/education/demands/generate', async (req, reply) => {
    const ctx = req.ctx;
    needFees(ctx);
    const b = parse(generateBody, req.body);
    if (!b.preview) ctx.require('invoices.create');
    const today = todayIst();
    const out = await ctx.tx(async (tx) => {
      const cls = await loadClass(tx, ctx, b.classId, true);
      const pl = await loadPlanFor(tx, ctx, cls.id);
      if (!pl) throw badRequest('This class has no fee plan yet.', { classId: 'No fee plan' });
      const inst = pl.inst.find((n) => n.id === b.instalmentId);
      if (!inst) throw badRequest('That instalment is not in this class fee plan.', { instalmentId: 'Not found' });
      const heads = new Map((await headRows(tx, ctx)).map((h) => [h.id, h]));
      const students = await tx.selectFrom('edu_students').selectAll().where('company_id', '=', ctx.companyId).where('class_id', '=', cls.id)
        .where('status', '=', 'active').orderBy('name').execute();
      // Demands whose invoice was cancelled no longer count as billed.
      await tx.updateTable('edu_demands').set({ status: 'void' })
        .where('instalment_id', '=', inst.id).where('status', '=', 'billed')
        .where('invoice_id', 'in', (eb) => eb.selectFrom('invoices').select('id').where('status', '=', 'cancelled')).execute();
      const billed = new Set((await tx.selectFrom('edu_demands').select('student_id').where('instalment_id', '=', inst.id).where('status', '=', 'billed').execute()).map((r) => r.student_id));
      const conc = await tx.selectFrom('edu_concessions').select(['student_id', 'head_id', 'kind', 'value']).where('company_id', '=', ctx.companyId).where('is_active', '=', true).execute();
      const late = b.applyLateFee && pl.plan.late_kind !== 'none' ? { kind: pl.plan.late_kind, value: pl.plan.late_value, headId: pl.plan.late_head_id } : null;

      const todo = students.filter((s) => !billed.has(s.id));
      const plans = todo.map((s) => {
        const m = new Map(conc.filter((c) => c.student_id === s.id).map((c) => [c.head_id, { kind: c.kind, value: c.value }]));
        return { s, ...buildLines(inst, heads, m, late, today) };
      });
      const billable = plans.filter((p) => p.lines.length);
      const summary = {
        classId: cls.id, instalmentId: inst.id, label: inst.label, dueDate: inst.due_date,
        count: billable.length, alreadyBilled: students.length - todo.length, nothingToBill: plans.length - billable.length,
        amount: round2(billable.reduce((s, p) => s + p.net + p.lateFee, 0)), lateFeeCount: billable.filter((p) => p.lateFee > 0).length,
        lateFeeAmount: round2(billable.reduce((s, p) => s + p.lateFee, 0)), concessionAmount: round2(billable.reduce((s, p) => s + p.concession, 0)),
      };
      if (b.preview) return { ...summary, preview: true, created: 0 };
      if (billable.length > MAX_BATCH) throw badRequest(`Bill at most ${MAX_BATCH} students at a time.`, { classId: 'Too many students' });
      if (!billable.length) return { ...summary, preview: false, created: 0, invoices: [] };
      const locationId = await defaultLocation(tx, ctx, b.locationId);
      const invoices: { studentId: string; invoiceId: string; number: string; total: number }[] = [];
      for (const p of billable) {
        const inv = await createInvoice(ctx, tx, {
          locationId, partyId: p.s.party_id, invoiceDate: today, lines: p.lines,
          notes: `${inst.label}. Admission no. ${p.s.admission_no}`, custom: undefined,
        } as never);
        await tx.updateTable('invoices').set({ due_date: inst.due_date }).where('id', '=', inv.id).execute();
        await tx.insertInto('edu_demands').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, student_id: p.s.id, instalment_id: inst.id, invoice_id: inv.id,
          late_fee: p.lateFee, created_by: ctx.userId,
        }).execute();
        invoices.push({ studentId: p.s.id, invoiceId: inv.id, number: inv.number, total: inv.total });
      }
      await writeAudit(tx, auditOf(ctx), 'edu_class', cls.id, 'generate_demands', null, { instalmentId: inst.id, created: invoices.length });
      return { ...summary, preview: false, created: invoices.length, invoices };
    });
    return reply.status(b.preview ? 200 : 201).send(out);
  });

  // Dues, reminders, collection ----------------------------------------------------------------

  app.get('/education/dues', async (req) => {
    const ctx = req.ctx;
    needFees(ctx);
    const q = parse(duesQuery, req.query);
    return ctx.tx(async (tx) => {
      const dues = await dueRows(tx, ctx, { classId: q.classId, q: q.q });
      let list = [...dues.values()];
      if (q.overdue === 'true') list = list.filter((e) => e.overdue > 0);
      const ids = list.map((e) => e.studentId);
      const studs = ids.length
        ? await tx.selectFrom('edu_students as s').leftJoin('edu_classes as c', 'c.id', 's.class_id').selectAll('s').select(['c.name as c_name', 'c.section as c_section'])
          .where('s.id', 'in', ids).execute()
        : [];
      const school = (await companyName(tx, ctx)).name;
      const today = todayIst();
      const rows = list.map((e) => {
        const s = studs.find((x) => x.id === e.studentId)!;
        const cname = s.c_name ? classLabel({ name: s.c_name, section: s.c_section }) : null;
        return {
          ...studentBrief(s as never, s.c_name ? { name: s.c_name, section: s.c_section } : null),
          due: e.due, overdue: e.overdue, oldestDue: e.oldestDue, daysOverdue: e.oldestDue ? daysBetween(e.oldestDue, today) : 0,
          reminder: reminderText(school, s, cname, e),
        };
      }).sort((a, b) => b.daysOverdue - a.daysOverdue || b.due - a.due || a.name.localeCompare(b.name));
      return {
        total: rows.length, dueTotal: round2(rows.reduce((s, r) => s + r.due, 0)), overdueTotal: round2(rows.reduce((s, r) => s + r.overdue, 0)),
        data: rows.slice(q.offset, q.offset + q.limit),
      };
    });
  });

  app.get<{ Params: { id: string } }>('/education/students/:id/ledger', async (req) => {
    const ctx = req.ctx;
    needFees(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const s = await loadStudent(tx, ctx, id);
      const bills = await tx.selectFrom('edu_demands as d').innerJoin('invoices as i', 'i.id', 'd.invoice_id').innerJoin('edu_instalments as n', 'n.id', 'd.instalment_id')
        .select(['i.id', 'i.number', 'i.invoice_date', 'i.due_date', 'i.total', 'i.amount_paid', 'i.status', 'n.label', 'd.late_fee'])
        .where('d.student_id', '=', id).where('d.status', '=', 'billed').orderBy('i.due_date').orderBy('i.number').execute();
      const receipts = await tx.selectFrom('payments').select(['id', 'number', 'payment_date', 'amount', 'mode', 'reference', 'status'])
        .where('company_id', '=', ctx.companyId).where('party_id', '=', s.party_id).where('kind', '=', 'receipt').orderBy('payment_date', 'desc').orderBy('number', 'desc').execute();
      const today = todayIst();
      const live = bills.filter((x) => x.status === 'posted');
      return {
        student: { id: s.id, name: s.name, admissionNo: s.admission_no },
        billed: round2(live.reduce((t, x) => t + x.total, 0)), paid: round2(live.reduce((t, x) => t + x.amount_paid, 0)),
        due: round2(live.reduce((t, x) => t + (x.total - x.amount_paid), 0)),
        bills: bills.map((x) => ({
          invoiceId: x.id, number: x.number, label: x.label, date: x.invoice_date, dueDate: x.due_date, total: x.total, paid: x.amount_paid,
          due: x.status === 'posted' ? round2(x.total - x.amount_paid) : 0, status: x.status, lateFee: x.late_fee,
          overdue: x.status === 'posted' && x.amount_paid < x.total && x.due_date < today,
        })),
        receipts: receipts.map((r) => ({ id: r.id, number: r.number, date: r.payment_date, amount: r.amount, mode: r.mode, reference: r.reference, status: r.status })),
      };
    });
  });

  app.post<{ Params: { id: string } }>('/education/students/:id/collect', async (req, reply) => {
    const ctx = req.ctx;
    needFees(ctx);
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(collectBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const s = await loadStudent(tx, ctx, id, true);
      const due = (await dueRows(tx, ctx, { studentId: id })).get(id);
      if (!due || due.due <= 0) throw badRequest('This student has no fees due.', { amount: 'Nothing due' });
      if (b.amount > due.due + 0.001) throw badRequest(`Only ${inr(due.due)} is due. Collect that or less.`, { amount: `At most ${due.due}` });
      // Oldest due date first, so a part payment clears the earliest instalment before the next.
      let left = b.amount;
      const allocations: { docId: string; amount: number }[] = [];
      for (const inv of due.invoices) {
        if (left <= 0.001) break;
        const take = round2(Math.min(left, inv.due));
        allocations.push({ docId: inv.invoiceId, amount: take });
        left = round2(left - take);
      }
      const payment = await createPayment(ctx, tx, {
        kind: 'receipt', partyId: s.party_id, date: b.date, accountId: b.accountId, mode: b.mode, reference: b.reference,
        amount: b.amount, tdsAmount: undefined, notes: `Fee ${s.admission_no}`, allocations,
      } as never);
      await writeAudit(tx, auditOf(ctx), 'edu_student', id, 'collect', null, { paymentId: payment.id, amount: b.amount });
      return { payment, balance: round2(due.due - b.amount), allocations };
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { paymentId: string } }>('/education/receipts/:paymentId', async (req) => {
    const ctx = req.ctx;
    needFees(ctx);
    const id = parse(z.uuid(), req.params.paymentId);
    return ctx.tx(async (tx) => {
      const p = await tx.selectFrom('payments').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).where('kind', '=', 'receipt').executeTakeFirst();
      if (!p) throw notFound('Receipt');
      const s = await tx.selectFrom('edu_students').selectAll().where('party_id', '=', p.party_id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!s) throw notFound('Student receipt');
      const cls = s.class_id ? await loadClass(tx, ctx, s.class_id) : null;
      const allocs = await tx.selectFrom('payment_allocations').selectAll().where('payment_id', '=', id).execute();
      const paidFor = [];
      for (const a of allocs) {
        const inv = await tx.selectFrom('invoices').select(['id', 'number', 'total']).where('id', '=', a.doc_id).executeTakeFirst();
        if (!inv) continue;
        const label = await tx.selectFrom('edu_demands as d').innerJoin('edu_instalments as n', 'n.id', 'd.instalment_id').select('n.label').where('d.invoice_id', '=', inv.id).executeTakeFirst();
        const lines = await tx.selectFrom('invoice_lines').select(['description', 'line_total']).where('invoice_id', '=', inv.id).orderBy('line_no').execute();
        paidFor.push({
          invoiceNumber: inv.number, label: label?.label ?? null, invoiceTotal: inv.total, paid: a.amount,
          heads: lines.map((l) => ({ description: l.description, amount: l.line_total })),
        });
      }
      const due = (await dueRows(tx, ctx, { studentId: s.id })).get(s.id);
      const c = await companyName(tx, ctx);
      return {
        school: { name: c.legal_name || c.name, address: c.address, phone: c.phone },
        receipt: { id: p.id, number: p.number, date: p.payment_date, amount: p.amount, mode: p.mode, reference: p.reference, status: p.status },
        student: { id: s.id, name: s.name, admissionNo: s.admission_no, rollNo: s.roll_no, guardianName: s.guardian_name, className: cls ? classLabel(cls) : null },
        paidFor, balance: due?.due ?? 0,
      };
    });
  });

  // Attendance --------------------------------------------------------------------------------

  async function roster(tx: Tx, ctx: RequestContext, cls: ClassRow, date: string) {
    const studs = await tx.selectFrom('edu_students').select(['id', 'name', 'roll_no', 'admission_no']).where('company_id', '=', ctx.companyId)
      .where('class_id', '=', cls.id).where('status', '=', 'active').orderBy(rollOrder).orderBy('name').execute();
    const marks = await tx.selectFrom('edu_attendance').select(['student_id', 'status']).where('class_id', '=', cls.id).where('att_date', '=', date).execute();
    const by = new Map(marks.map((m) => [m.student_id, m.status]));
    return {
      classId: cls.id, label: classLabel(cls), date, marked: marks.length > 0,
      students: studs.map((s) => ({ studentId: s.id, name: s.name, rollNo: s.roll_no, admissionNo: s.admission_no, status: by.get(s.id) ?? 'present', recorded: by.has(s.id) })),
    };
  }

  app.get<{ Params: { id: string } }>('/education/classes/:id/attendance', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(attendanceQuery, req.query);
    return ctx.tx(async (tx) => roster(tx, ctx, await loadClass(tx, ctx, id), q.date ?? todayIst()));
  });

  app.route<{ Params: { id: string } }>({ method: ['PUT', 'POST'], url: '/education/classes/:id/attendance', handler: async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const b = parse(attendanceBody, req.body);
    const date = b.date ?? todayIst();
    if (date > todayIst()) throw badRequest('Attendance cannot be marked for a future date.', { date: 'In the future' });
    return ctx.tx(async (tx) => {
      const cls = await loadClass(tx, ctx, id, true);
      canMark(ctx, cls);
      if (!ctx.can('education.manage') && date !== todayIst()) throw forbidden('Teachers can change attendance only on the same day. Ask the office.');
      const r = await roster(tx, ctx, cls, date);
      const valid = new Set(r.students.map((s) => s.studentId));
      for (const m of b.marks) if (!valid.has(m.studentId)) throw badRequest('A student in the list is not in this class.', { marks: 'Unknown student' });
      const sent = new Map(b.marks.map((m) => [m.studentId, m.status]));
      for (const s of r.students) {
        const status = sent.get(s.studentId) ?? (s.recorded ? undefined : 'present');
        if (!status) continue;
        await tx.insertInto('edu_attendance').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, student_id: s.studentId, class_id: id, att_date: date, status, marked_by: ctx.userId,
        }).onConflict((oc) => oc.columns(['student_id', 'att_date']).doUpdateSet({ status, class_id: id, marked_by: ctx.userId })).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'edu_class', id, 'attendance', null, { date, students: r.students.length });
      return roster(tx, ctx, cls, date);
    });
  } });

  app.get<{ Params: { id: string } }>('/education/classes/:id/attendance/sheet', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(monthQuery, req.query);
    const month = q.month ?? todayIst().slice(0, 7);
    const { from, to, days } = monthRange(month);
    return ctx.tx(async (tx) => {
      const cls = await loadClass(tx, ctx, id);
      const rows = await tx.selectFrom('edu_attendance').select(['student_id', 'att_date', 'status']).where('class_id', '=', id).where('att_date', '>=', from).where('att_date', '<=', to).execute();
      const studIds = new Set(rows.map((r) => r.student_id));
      const studs = await tx.selectFrom('edu_students').select(['id', 'name', 'roll_no', 'status']).where('company_id', '=', ctx.companyId)
        .where((eb) => eb.or([eb('class_id', '=', id), ...(studIds.size ? [eb('id', 'in', [...studIds])] : [])])).orderBy(rollOrder).orderBy('name').execute();
      const workingDays = new Set(rows.map((r) => r.att_date)).size;
      return {
        classId: id, label: classLabel(cls), month, from, to, days, workingDays,
        students: studs.map((s) => {
          const mine = rows.filter((r) => r.student_id === s.id);
          const marks: Record<string, string> = {};
          for (const r of mine) marks[String(Number(r.att_date.slice(8)))] = r.status;
          return { studentId: s.id, name: s.name, rollNo: s.roll_no, marks, ...attStats(mine) };
        }),
      };
    });
  });

  app.get<{ Params: { id: string } }>('/education/students/:id/attendance', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(monthQuery, req.query);
    const month = q.month ?? todayIst().slice(0, 7);
    const { from, to } = monthRange(month);
    return ctx.tx(async (tx) => {
      await loadStudent(tx, ctx, id);
      const all = await tx.selectFrom('edu_attendance').select(['att_date', 'status']).where('student_id', '=', id).orderBy('att_date').execute();
      const inMonth = all.filter((r) => r.att_date >= from && r.att_date <= to);
      return {
        month, overall: attStats(all), thisMonth: attStats(inMonth),
        days: inMonth.map((r) => ({ date: r.att_date, status: r.status })),
      };
    });
  });
}

documentRoute('POST', '/education/years', { body: yearBody });
documentRoute('PATCH', '/education/years/:id', { body: yearPatch });
documentRoute('POST', '/education/classes', { body: classBody });
documentRoute('PATCH', '/education/classes/:id', { body: classPatch });
documentRoute('POST', '/education/fee-heads', { body: headBody });
documentRoute('PATCH', '/education/fee-heads/:id', { body: headPatch });
documentRoute('PUT', '/education/classes/:id/fee-plan', { body: planBody });
documentRoute('POST', '/education/classes/:id/fee-plan', { body: planBody });
documentRoute('POST', '/education/students', { body: studentCreate });
documentRoute('PATCH', '/education/students/:id', { body: studentPatch });
documentRoute('POST', '/education/students/:id/concessions', { body: concessionBody });
documentRoute('POST', '/education/promote', { body: promoteBody });
documentRoute('POST', '/education/demands/generate', { body: generateBody });
documentRoute('POST', '/education/students/:id/collect', { body: collectBody });
documentRoute('PUT', '/education/classes/:id/attendance', { body: attendanceBody });
documentRoute('POST', '/education/classes/:id/attendance', { body: attendanceBody });
