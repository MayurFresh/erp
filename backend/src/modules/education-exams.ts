import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { isValidDate } from '../lib/dates.ts';
import { badRequest, conflict, forbidden, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { documentRoute } from '../lib/openapi.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

/*
 * Exams and report cards for schools and coaching institutes. Subjects belong to a class; an exam term (Unit test 1,
 * Half yearly) has one paper per subject with its maximum marks. Marks are entered per paper and student, absence is
 * its own flag. Results, grades and ranks are computed on read. Publishing a term locks its marks.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const num = (max: number) => z.coerce.number().min(0).max(max);
const blank = (v: unknown) => (v === '' ? undefined : v);
const round2 = (n: number) => Math.round(n * 100) / 100;

export const DEFAULT_GRADES = [
  { grade: 'A1', minPct: 91 }, { grade: 'A2', minPct: 81 }, { grade: 'B1', minPct: 71 }, { grade: 'B2', minPct: 61 },
  { grade: 'C1', minPct: 51 }, { grade: 'C2', minPct: 41 }, { grade: 'D', minPct: 33 }, { grade: 'E', minPct: 0 },
];
type Grade = { grade: string; minPct: number };
export const DEFAULT_CO_GRADES = [{ grade: 'A', label: 'Very good' }, { grade: 'B', label: 'Good' }, { grade: 'C', label: 'Needs work' }];
export const DEFAULT_CO_AREAS = ['Work education', 'Art education', 'Health and physical education', 'Discipline'];
type CoGrade = { grade: string; label: string };

const settingsBody = z.object({
  grades: z.array(z.object({ grade: z.string().trim().min(1, 'Required').max(10), minPct: num(100) })).min(2, 'Add at least two grades').max(20)
    .refine((g) => new Set(g.map((x) => x.grade.toLowerCase())).size === g.length, 'A grade name is repeated')
    .refine((g) => new Set(g.map((x) => x.minPct)).size === g.length, 'Two grades start at the same percentage')
    .refine((g) => g.some((x) => x.minPct === 0), 'The lowest grade must start at 0'),
  passPercent: num(100).optional(),
  coGrades: z.array(z.object({ grade: z.string().trim().min(1).max(10), label: z.string().trim().max(40).default('') })).min(2).max(6)
    .refine((g) => new Set(g.map((x) => x.grade.toLowerCase())).size === g.length, 'A grade name is repeated').optional(),
});
const settingsPatch = settingsBody.partial();

const subjectBody = z.object({ classId: z.uuid(), name: z.string().trim().min(1, 'Required').max(80), code: optionalText(20), seq: z.coerce.number().int().min(0).max(999).optional() });
const subjectPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(), name: z.string().trim().min(1).max(80).optional(), code: nullableText(20),
  seq: z.coerce.number().int().min(0).max(999).optional(), isActive: z.boolean().optional(),
});
const subjectCopy = z.object({ fromClassId: z.uuid() });

const termBody = z.object({
  yearId: z.uuid(), name: z.string().trim().min(1, 'Required').max(80), seq: z.coerce.number().int().min(0).max(999).optional(),
  startDate: z.preprocess(blank, dateField.optional()), endDate: z.preprocess(blank, dateField.optional()),
});
const termPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(), name: z.string().trim().min(1).max(80).optional(), seq: z.coerce.number().int().min(0).max(999).optional(),
  startDate: z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional()),
  endDate: z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional()),
});
const papersBody = z.object({
  classId: z.uuid(),
  papers: z.array(z.object({
    subjectId: z.uuid(), maxMarks: num(1000).refine((v) => v > 0, 'Must be more than zero'),
    passMarks: z.preprocess(blank, num(1000).nullable().optional()), examDate: z.preprocess(blank, dateField.nullable().optional()),
  })).max(40),
});
const entriesBody = z.object({
  entries: z.array(z.object({
    paperId: z.uuid(), studentId: z.uuid(), marks: z.preprocess(blank, num(1000).nullable().optional()), absent: z.boolean().optional(),
  })).min(1).max(5000),
});
const coAreasBody = z.object({ areas: z.array(z.string().trim().min(1).max(80)).max(12) });
const remarksBody = z.object({
  entries: z.array(z.object({
    studentId: z.uuid(), remark: z.string().trim().max(500).optional(),
    areas: z.record(z.string(), z.string().trim().min(1).max(10).nullable()).optional(),
  })).min(1).max(2000),
});
const marksQuery = z.object({ subjectId: z.uuid().optional() });
const termList = z.object({ yearId: z.uuid().optional() });

export const gradeFor = (grades: Grade[], pct: number): string => {
  const sorted = [...grades].sort((a, b) => b.minPct - a.minPct);
  return (sorted.find((g) => pct + 1e-9 >= g.minPct) ?? sorted[sorted.length - 1]!).grade;
};

async function settings(tx: Tx, ctx: RequestContext) {
  const row = await tx.selectFrom('edu_exam_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst();
  return {
    grades: (row?.grades as Grade[] | undefined) ?? DEFAULT_GRADES, passPercent: Number(row?.pass_percent ?? 33),
    coGrades: (row?.co_grades as CoGrade[] | null | undefined) ?? DEFAULT_CO_GRADES,
    isDefault: !row, updatedAt: row?.updated_at ?? null,
  };
}

const needManage = (ctx: RequestContext) => ctx.require('education.exams_manage', 'education.manage');
const isManager = (ctx: RequestContext) => ctx.can('education.exams_manage') || ctx.can('education.manage');

async function loadClass(tx: Tx, ctx: RequestContext, id: string) {
  const row = await tx.selectFrom('edu_classes').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row) throw notFound('Class or batch');
  return row;
}
async function loadTerm(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('edu_exam_terms').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Exam term');
  return row;
}
const label = (c: { name: string; section: string | null }) => (c.section ? `${c.name} ${c.section}` : c.name);

/** Reading results: managers see every class, teachers with exams only their own. */
function canReadClass(ctx: RequestContext, cls: { teacher_user_id: string | null }) {
  ctx.require('education.exams', 'education.exams_manage', 'education.manage');
  if (!isManager(ctx) && cls.teacher_user_id !== ctx.userId) throw forbidden('You can see exam marks only for your own classes.');
}

const subjectJson = (s: { id: string; class_id: string; name: string; code: string | null; seq: number; is_active: boolean; updated_at: Date }) => ({
  id: s.id, classId: s.class_id, name: s.name, code: s.code, seq: s.seq, isActive: s.is_active, updatedAt: s.updated_at,
});
const termJson = (t: Awaited<ReturnType<typeof loadTerm>>, extra: Record<string, unknown> = {}) => ({
  id: t.id, yearId: t.year_id, name: t.name, seq: t.seq, startDate: t.start_date, endDate: t.end_date, status: t.status,
  published: t.status === 'published', publishedAt: t.published_at, updatedAt: t.updated_at, ...extra,
});

async function papersOf(tx: Tx, termId: string, classId: string) {
  const rows = await tx.selectFrom('edu_exam_papers as p').innerJoin('edu_subjects as s', 's.id', 'p.subject_id')
    .select(['p.id', 'p.subject_id', 's.name as subject', 's.code', 'p.max_marks', 'p.pass_marks', 'p.exam_date', 's.seq'])
    .where('p.term_id', '=', termId).where('p.class_id', '=', classId).orderBy('s.seq').orderBy('s.name').execute();
  return rows.map((r) => ({
    id: r.id, subjectId: r.subject_id, subject: r.subject, code: r.code, maxMarks: Number(r.max_marks),
    passMarks: r.pass_marks === null ? null : Number(r.pass_marks), examDate: r.exam_date,
  }));
}
type Paper = Awaited<ReturnType<typeof papersOf>>[number];

async function rosterOf(tx: Tx, ctx: RequestContext, classId: string, paperIds: string[]) {
  const withMarks = paperIds.length
    ? (await tx.selectFrom('edu_marks').select('student_id').where('paper_id', 'in', paperIds).execute()).map((r) => r.student_id) : [];
  const ids = [...new Set(withMarks)];
  return tx.selectFrom('edu_students').select(['id', 'name', 'roll_no', 'admission_no', 'status']).where('company_id', '=', ctx.companyId)
    .where((eb) => eb.or([eb.and([eb('class_id', '=', classId), eb('status', '=', 'active')]), ...(ids.length ? [eb('id', 'in', ids)] : [])]))
    .orderBy((eb) => eb.fn('lpad', [eb.fn.coalesce('roll_no', eb.val('')), eb.val(10), eb.val('0')])).orderBy('name').execute();
}

async function markGrid(tx: Tx, ctx: RequestContext, termId: string, classId: string, subjectId?: string) {
  const term = await loadTerm(tx, ctx, termId);
  const cls = await loadClass(tx, ctx, classId);
  canReadClass(ctx, cls);
  let papers = await papersOf(tx, termId, classId);
  if (subjectId) papers = papers.filter((p) => p.subjectId === subjectId);
  const students = await rosterOf(tx, ctx, classId, papers.map((p) => p.id));
  const marks = papers.length ? await tx.selectFrom('edu_marks').select(['paper_id', 'student_id', 'marks', 'absent'])
    .where('paper_id', 'in', papers.map((p) => p.id)).execute() : [];
  const by = new Map(marks.map((m) => [`${m.paper_id}:${m.student_id}`, m]));
  return {
    term: termJson(term), classId, label: label(cls), locked: term.status === 'published', papers,
    students: students.map((s) => ({
      studentId: s.id, name: s.name, rollNo: s.roll_no, admissionNo: s.admission_no,
      marks: Object.fromEntries(papers.map((p) => {
        const m = by.get(`${p.id}:${s.id}`);
        return [p.id, m ? { marks: m.marks === null ? null : Number(m.marks), absent: m.absent } : null];
      })),
    })),
  };
}

/** Totals, percentage, grade and class rank for each student. Rank is among students whose marks are all in. */
async function computeResults(tx: Tx, ctx: RequestContext, termId: string, classId: string) {
  const grid = await markGrid(tx, ctx, termId, classId);
  const cfg = await settings(tx, ctx);
  const maxTotal = grid.papers.reduce((a, p) => a + p.maxMarks, 0);
  const extras = await extrasOf(tx, termId, classId, grid.students.map((s) => s.studentId));
  const rows = grid.students.map((s) => {
    let total = 0; let entered = 0; let pass = true;
    const subjects = grid.papers.map((p) => {
      const m = s.marks[p.id];
      if (m) entered++;
      const got = m && !m.absent ? (m.marks ?? 0) : 0;
      total += got;
      const need = p.passMarks ?? round2((p.maxMarks * cfg.passPercent) / 100);
      const ok = !!m && !m.absent && got + 1e-9 >= need;
      if (m && !ok) pass = false;
      return {
        paperId: p.id, subjectId: p.subjectId, subject: p.subject, maxMarks: p.maxMarks, marks: m && !m.absent ? m.marks : null, absent: !!m?.absent,
        entered: !!m, grade: m ? (m.absent ? null : gradeFor(cfg.grades, (got / p.maxMarks) * 100)) : null, passed: m ? ok : null,
      };
    });
    const complete = grid.papers.length > 0 && entered === grid.papers.length;
    const percentage = maxTotal > 0 && entered > 0 ? round2((total / maxTotal) * 100) : null;
    return {
      studentId: s.studentId, name: s.name, rollNo: s.rollNo, admissionNo: s.admissionNo, subjects, total: round2(total), maxTotal, percentage, complete,
      grade: complete && percentage !== null ? gradeFor(cfg.grades, percentage) : null,
      result: complete ? (pass ? 'pass' : 'fail') : null, rank: null as number | null, ...extras.of(s.studentId),
    };
  });
  const done = rows.filter((r) => r.complete).sort((a, b) => b.total - a.total);
  done.forEach((r, i) => { r.rank = i > 0 && done[i - 1]!.total === r.total ? done[i - 1]!.rank : i + 1; });
  return { ...grid, grades: cfg.grades, passPercent: cfg.passPercent, maxTotal, ranked: done.length, students: rows };
}

async function areasOf(tx: Tx, classId: string): Promise<string[]> {
  const rows = await tx.selectFrom('edu_co_areas').select('name').where('class_id', '=', classId).orderBy('seq').orderBy('name').execute();
  return rows.length ? rows.map((r) => r.name) : DEFAULT_CO_AREAS;
}

/** Remarks and co-scholastic grades of a class for one term, keyed by student. */
async function extrasOf(tx: Tx, termId: string, classId: string, studentIds: string[]) {
  const areas = await areasOf(tx, classId);
  const remarks = studentIds.length ? await tx.selectFrom('edu_term_remarks').select(['student_id', 'remark']).where('term_id', '=', termId).where('student_id', 'in', studentIds).execute() : [];
  const grades = studentIds.length ? await tx.selectFrom('edu_co_grades').select(['student_id', 'area', 'grade']).where('term_id', '=', termId).where('student_id', 'in', studentIds).execute() : [];
  return {
    areas,
    of: (id: string) => ({
      remark: remarks.find((r) => r.student_id === id)?.remark ?? null,
      coScholastic: areas.map((a) => ({ area: a, grade: grades.find((g) => g.student_id === id && g.area === a)?.grade ?? null })),
    }),
  };
}

async function schoolInfo(tx: Tx, ctx: RequestContext) {
  const c = await tx.selectFrom('companies').select(['name', 'address', 'phone']).where('id', '=', ctx.companyId).executeTakeFirst();
  return { name: c?.name ?? '', address: (c as { address?: string | null } | undefined)?.address ?? null, phone: (c as { phone?: string | null } | undefined)?.phone ?? null };
}

async function cardsFor(tx: Tx, ctx: RequestContext, termId: string, classId: string, only?: string) {
  const res = await computeResults(tx, ctx, termId, classId);
  const cls = await loadClass(tx, ctx, classId);
  const year = await tx.selectFrom('edu_years').select(['name', 'start_date', 'end_date']).where('id', '=', cls.year_id).executeTakeFirstOrThrow();
  const school = await schoolInfo(tx, ctx);
  const list = res.students.filter((s) => !only || s.studentId === only);
  const stu = list.length ? await tx.selectFrom('edu_students').select(['id', 'dob', 'guardian_name']).where('id', 'in', list.map((s) => s.studentId)).execute() : [];
  const att = list.length ? await tx.selectFrom('edu_attendance').select(['student_id', 'status']).where('student_id', 'in', list.map((s) => s.studentId))
    .where('att_date', '>=', year.start_date).where('att_date', '<=', year.end_date).execute() : [];
  return list.map((s) => {
    const mine = att.filter((a) => a.student_id === s.studentId);
    const extra = stu.find((x) => x.id === s.studentId);
    return {
      school, term: { id: res.term.id, name: res.term.name, published: res.locked, publishedAt: res.term.publishedAt },
      year: year.name, classLabel: res.label, classSize: res.ranked, draft: !res.locked,
      student: { id: s.studentId, name: s.name, rollNo: s.rollNo, admissionNo: s.admissionNo, dob: extra?.dob ?? null, guardianName: extra?.guardian_name ?? null },
      remark: s.remark, coScholastic: s.coScholastic, subjects: s.subjects, total: s.total, maxTotal: s.maxTotal, percentage: s.percentage, grade: s.grade, rank: s.rank, result: s.result, complete: s.complete,
      attendance: { marked: mine.length, present: mine.filter((a) => a.status !== 'absent').length },
      grades: res.grades,
    };
  });
}

export async function educationExamRoutes(app: FastifyInstance) {
  // Settings --------------------------------------------------------------------------------
  app.get('/education/exam-settings', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    return ctx.tx((tx) => settings(tx, ctx));
  });
  app.route({ method: ['PUT', 'PATCH'], url: '/education/exam-settings', handler: async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(req.method === 'PUT' ? settingsBody : settingsPatch, req.body);
    return ctx.tx(async (tx) => {
      const cur = await settings(tx, ctx);
      const grades = (b.grades ?? cur.grades).map((g) => ({ grade: g.grade, minPct: g.minPct }));
      const passPercent = b.passPercent ?? cur.passPercent;
      const coGrades = JSON.stringify((b.coGrades ?? cur.coGrades).map((g) => ({ grade: g.grade, label: g.label ?? '' })));
      await tx.insertInto('edu_exam_settings').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, grades: JSON.stringify(grades), pass_percent: passPercent, co_grades: coGrades })
        .onConflict((oc) => oc.column('company_id').doUpdateSet({ grades: JSON.stringify(grades), pass_percent: passPercent, co_grades: coGrades })).execute();
      await writeAudit(tx, auditOf(ctx), 'edu_exam_settings', ctx.companyId, 'update', null, { grades: grades.length, passPercent });
      return settings(tx, ctx);
    });
  } });

  // Subjects --------------------------------------------------------------------------------
  app.get('/education/subjects', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const q = parse(z.object({ classId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      let sel = tx.selectFrom('edu_subjects').selectAll().where('company_id', '=', ctx.companyId);
      if (q.classId) sel = sel.where('class_id', '=', q.classId);
      return { data: (await sel.orderBy('seq').orderBy('name').execute()).map(subjectJson) };
    });
  });
  app.post('/education/subjects', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(subjectBody, req.body);
    const out = await ctx.tx(async (tx) => {
      await loadClass(tx, ctx, b.classId);
      const dup = await tx.selectFrom('edu_subjects').select('id').where('class_id', '=', b.classId).where((eb) => eb(eb.fn('lower', ['name']), '=', b.name.toLowerCase())).executeTakeFirst();
      if (dup) throw conflict('This class already has a subject with this name.', 'DUPLICATE_SUBJECT');
      const n = await tx.selectFrom('edu_subjects').select((eb) => eb.fn.countAll<number>().as('n')).where('class_id', '=', b.classId).executeTakeFirstOrThrow();
      const row = await tx.insertInto('edu_subjects').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, class_id: b.classId, name: b.name, code: b.code ?? null, seq: b.seq ?? Number(n.n) + 1,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'edu_subject', row.id, 'create', null, { name: b.name });
      return subjectJson(row);
    });
    return reply.status(201).send(out);
  });
  app.patch<{ Params: { id: string } }>('/education/subjects/:id', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(subjectPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await tx.selectFrom('edu_subjects').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!before) throw notFound('Subject');
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'subject');
      if (b.name && b.name.toLowerCase() !== before.name.toLowerCase()) {
        const dup = await tx.selectFrom('edu_subjects').select('id').where('class_id', '=', before.class_id).where('id', '!=', id)
          .where((eb) => eb(eb.fn('lower', ['name']), '=', b.name!.toLowerCase())).executeTakeFirst();
        if (dup) throw conflict('This class already has a subject with this name.', 'DUPLICATE_SUBJECT');
      }
      await tx.updateTable('edu_subjects').set(definedOnly({ name: b.name, code: b.code, seq: b.seq, is_active: b.isActive }) as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'edu_subject', id, 'update', null, { fields: Object.keys(definedOnly({ ...b, expectedUpdatedAt: undefined })) });
      return subjectJson(await tx.selectFrom('edu_subjects').selectAll().where('id', '=', id).executeTakeFirstOrThrow());
    });
  });
  app.post<{ Params: { id: string } }>('/education/classes/:id/subjects/copy', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(subjectCopy, req.body);
    const out = await ctx.tx(async (tx) => {
      await loadClass(tx, ctx, id);
      await loadClass(tx, ctx, b.fromClassId);
      const have = new Set((await tx.selectFrom('edu_subjects').select('name').where('class_id', '=', id).execute()).map((r) => r.name.toLowerCase()));
      const src = (await tx.selectFrom('edu_subjects').selectAll().where('class_id', '=', b.fromClassId).where('is_active', '=', true).orderBy('seq').execute())
        .filter((s) => !have.has(s.name.toLowerCase()));
      for (const s of src) {
        await tx.insertInto('edu_subjects').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, class_id: id, name: s.name, code: s.code, seq: s.seq }).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'edu_class', id, 'subjects_copy', null, { from: b.fromClassId, added: src.length });
      return { added: src.length };
    });
    return reply.status(201).send(out);
  });

  // Terms and papers ------------------------------------------------------------------------
  app.get('/education/exam-terms', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.exams', 'education.exams_manage', 'education.manage');
    const q = parse(termList, req.query);
    return ctx.tx(async (tx) => {
      let sel = tx.selectFrom('edu_exam_terms').selectAll().where('company_id', '=', ctx.companyId);
      if (q.yearId) sel = sel.where('year_id', '=', q.yearId);
      const terms = await sel.orderBy('year_id').orderBy('seq').orderBy('created_at').execute();
      const papers = terms.length ? await tx.selectFrom('edu_exam_papers').select(['term_id', 'class_id']).where('term_id', 'in', terms.map((t) => t.id)).execute() : [];
      return { data: terms.map((t) => {
        const mine = papers.filter((p) => p.term_id === t.id);
        return termJson(t, { papers: mine.length, classes: new Set(mine.map((p) => p.class_id)).size });
      }) };
    });
  });
  app.post('/education/exam-terms', async (req, reply) => {
    const ctx = req.ctx;
    needManage(ctx);
    const b = parse(termBody, req.body);
    if (b.startDate && b.endDate && b.endDate < b.startDate) throw badRequest('End date is before the start date.', { endDate: 'Before start' });
    const out = await ctx.tx(async (tx) => {
      if (!(await tx.selectFrom('edu_years').select('id').where('id', '=', b.yearId).where('company_id', '=', ctx.companyId).executeTakeFirst())) throw notFound('Academic year');
      const dup = await tx.selectFrom('edu_exam_terms').select('id').where('company_id', '=', ctx.companyId).where('year_id', '=', b.yearId)
        .where((eb) => eb(eb.fn('lower', ['name']), '=', b.name.toLowerCase())).executeTakeFirst();
      if (dup) throw conflict('An exam with this name already exists in this year.', 'DUPLICATE_TERM');
      const n = await tx.selectFrom('edu_exam_terms').select((eb) => eb.fn.countAll<number>().as('n')).where('company_id', '=', ctx.companyId).where('year_id', '=', b.yearId).executeTakeFirstOrThrow();
      const row = await tx.insertInto('edu_exam_terms').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, year_id: b.yearId, name: b.name, seq: b.seq ?? Number(n.n) + 1,
        start_date: b.startDate ?? null, end_date: b.endDate ?? null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'edu_exam_term', row.id, 'create', null, { name: b.name });
      return termJson(row, { papers: 0, classes: 0 });
    });
    return reply.status(201).send(out);
  });
  app.patch<{ Params: { id: string } }>('/education/exam-terms/:id', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(termPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadTerm(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'exam');
      if (before.status === 'published') throw conflict('This exam is published. Reopen it to change it.', 'TERM_PUBLISHED');
      const s = b.startDate === undefined ? before.start_date : b.startDate;
      const e = b.endDate === undefined ? before.end_date : b.endDate;
      if (s && e && e < s) throw badRequest('End date is before the start date.', { endDate: 'Before start' });
      await tx.updateTable('edu_exam_terms').set(definedOnly({ name: b.name, seq: b.seq, start_date: b.startDate, end_date: b.endDate }) as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'edu_exam_term', id, 'update', null, { fields: Object.keys(definedOnly({ ...b, expectedUpdatedAt: undefined })) });
      return termJson(await loadTerm(tx, ctx, id));
    });
  });
  app.get<{ Params: { id: string } }>('/education/exam-terms/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.exams', 'education.exams_manage', 'education.manage');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const term = await loadTerm(tx, ctx, id);
      const classes = await tx.selectFrom('edu_classes').selectAll().where('company_id', '=', ctx.companyId).where('year_id', '=', term.year_id).where('is_active', '=', true)
        .orderBy('name').orderBy('section').execute();
      const papers = await tx.selectFrom('edu_exam_papers').select(['id', 'class_id']).where('term_id', '=', id).execute();
      const marks = papers.length ? await tx.selectFrom('edu_marks').select(['paper_id']).where('paper_id', 'in', papers.map((p) => p.id)).execute() : [];
      const marked = new Map<string, number>();
      for (const m of marks) marked.set(m.paper_id, (marked.get(m.paper_id) ?? 0) + 1);
      const visible = classes.filter((c) => isManager(ctx) || c.teacher_user_id === ctx.userId);
      const counts = visible.length ? await tx.selectFrom('edu_students').select(['class_id']).where('status', '=', 'active').where('class_id', 'in', visible.map((c) => c.id)).execute() : [];
      return {
        ...termJson(term),
        classes: visible.map((c) => {
          const mine = papers.filter((p) => p.class_id === c.id);
          const students = counts.filter((s) => s.class_id === c.id).length;
          const entered = mine.reduce((a, p) => a + (marked.get(p.id) ?? 0), 0);
          return { id: c.id, label: label(c), students, papers: mine.length, entered, expected: students * mine.length, mine: c.teacher_user_id === ctx.userId };
        }),
      };
    });
  });
  app.get<{ Params: { id: string } }>('/education/exam-terms/:id/papers', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.exams', 'education.exams_manage', 'education.manage');
    const id = parse(z.uuid(), req.params.id);
    const q = parse(z.object({ classId: z.uuid() }), req.query);
    return ctx.tx(async (tx) => {
      const term = await loadTerm(tx, ctx, id);
      const cls = await loadClass(tx, ctx, q.classId);
      canReadClass(ctx, cls);
      return { term: termJson(term), classId: q.classId, label: label(cls), data: await papersOf(tx, id, q.classId) };
    });
  });
  app.route<{ Params: { id: string } }>({ method: ['PUT', 'POST'], url: '/education/exam-terms/:id/papers', handler: async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(papersBody, req.body);
    return ctx.tx(async (tx) => {
      const term = await loadTerm(tx, ctx, id, true);
      if (term.status === 'published') throw conflict('This exam is published. Reopen it to change the papers.', 'TERM_PUBLISHED');
      const cls = await loadClass(tx, ctx, b.classId);
      if (cls.year_id !== term.year_id) throw badRequest('This class is in a different academic year.', { classId: 'Other year' });
      const subjects = new Map((await tx.selectFrom('edu_subjects').select(['id', 'class_id']).where('class_id', '=', b.classId).execute()).map((s) => [s.id, s]));
      const seen = new Set<string>();
      for (const p of b.papers) {
        if (!subjects.has(p.subjectId)) throw badRequest('A subject is not part of this class.', { papers: 'Unknown subject' });
        if (seen.has(p.subjectId)) throw badRequest('A subject is listed twice.', { papers: 'Repeated subject' });
        seen.add(p.subjectId);
        if (p.passMarks != null && p.passMarks > p.maxMarks) throw badRequest('Pass marks are above the maximum.', { papers: 'Pass above max' });
      }
      const existing = await tx.selectFrom('edu_exam_papers').select(['id', 'subject_id']).where('term_id', '=', id).where('class_id', '=', b.classId).forUpdate().execute();
      for (const e of existing.filter((x) => !seen.has(x.subject_id))) {
        const used = await tx.selectFrom('edu_marks').select('id').where('paper_id', '=', e.id).limit(1).executeTakeFirst();
        if (used) throw conflict('A removed subject already has marks. Clear the marks first.', 'PAPER_HAS_MARKS');
        await tx.deleteFrom('edu_exam_papers').where('id', '=', e.id).execute();
      }
      for (const p of b.papers) {
        const vals = { max_marks: p.maxMarks, pass_marks: p.passMarks ?? null, exam_date: p.examDate ?? null };
        const had = existing.find((x) => x.subject_id === p.subjectId);
        if (had) {
          if (p.maxMarks) {
            const over = await tx.selectFrom('edu_marks').select('id').where('paper_id', '=', had.id).where('marks', '>', p.maxMarks).limit(1).executeTakeFirst();
            if (over) throw conflict('Some entered marks are above the new maximum.', 'MARKS_ABOVE_MAX');
          }
          await tx.updateTable('edu_exam_papers').set(vals).where('id', '=', had.id).execute();
        } else {
          await tx.insertInto('edu_exam_papers').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, term_id: id, class_id: b.classId, subject_id: p.subjectId, ...vals }).execute();
        }
      }
      await writeAudit(tx, auditOf(ctx), 'edu_exam_term', id, 'papers', null, { classId: b.classId, papers: b.papers.length });
      return { term: termJson(term), classId: b.classId, label: label(cls), data: await papersOf(tx, id, b.classId) };
    });
  } });

  // Marks -----------------------------------------------------------------------------------
  app.get<{ Params: { id: string; classId: string } }>('/education/exam-terms/:id/classes/:classId/marks', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const classId = parse(z.uuid(), req.params.classId);
    const q = parse(marksQuery, req.query);
    return ctx.tx((tx) => markGrid(tx, ctx, id, classId, q.subjectId));
  });
  app.route<{ Params: { id: string; classId: string } }>({ method: ['PUT', 'POST'], url: '/education/exam-terms/:id/classes/:classId/marks', handler: async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const classId = parse(z.uuid(), req.params.classId);
    const b = parse(entriesBody, req.body);
    return ctx.tx(async (tx) => {
      const term = await loadTerm(tx, ctx, id, true);
      const cls = await loadClass(tx, ctx, classId);
      canReadClass(ctx, cls);
      if (term.status === 'published') throw conflict('This exam is published, so marks are locked.', 'TERM_PUBLISHED');
      const papers = new Map((await papersOf(tx, id, classId)).map((p) => [p.id, p]));
      const students = new Set((await rosterOf(tx, ctx, classId, [...papers.keys()])).map((s) => s.id));
      const rows: { paperId: string; studentId: string; marks: number | null; absent: boolean }[] = [];
      for (const [i, e] of b.entries.entries()) {
        const p = papers.get(e.paperId);
        if (!p) throw badRequest('A subject in the list is not part of this exam for this class.', { [`entries.${i}.paperId`]: 'Unknown paper' });
        if (!students.has(e.studentId)) throw badRequest('A student in the list is not in this class.', { [`entries.${i}.studentId`]: 'Unknown student' });
        const absent = e.absent === true;
        if (absent && e.marks != null) throw badRequest('Marks and absent cannot both be set.', { [`entries.${i}.marks`]: 'Absent' });
        if (e.marks != null && e.marks > p.maxMarks) throw badRequest(`Marks are above the maximum of ${p.maxMarks} for ${p.subject}.`, { [`entries.${i}.marks`]: `Above ${p.maxMarks}` });
        rows.push({ paperId: e.paperId, studentId: e.studentId, marks: absent ? null : (e.marks ?? null), absent });
      }
      let saved = 0; let cleared = 0;
      for (const r of rows) {
        if (!r.absent && r.marks === null) {
          await tx.deleteFrom('edu_marks').where('paper_id', '=', r.paperId).where('student_id', '=', r.studentId).execute();
          cleared++;
          continue;
        }
        await tx.insertInto('edu_marks').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, paper_id: r.paperId, student_id: r.studentId, marks: r.marks, absent: r.absent, entered_by: ctx.userId,
        }).onConflict((oc) => oc.columns(['paper_id', 'student_id']).doUpdateSet({ marks: r.marks, absent: r.absent, entered_by: ctx.userId })).execute();
        saved++;
      }
      await writeAudit(tx, auditOf(ctx), 'edu_exam_term', id, 'marks', null, { classId, saved, cleared });
      return markGrid(tx, ctx, id, classId);
    });
  } });

  // Remarks and co-scholastic grades ----------------------------------------------------------
  app.get<{ Params: { id: string } }>('/education/classes/:id/co-areas', async (req) => {
    const ctx = req.ctx;
    ctx.require('education.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      await loadClass(tx, ctx, id);
      const rows = await tx.selectFrom('edu_co_areas').select('id').where('class_id', '=', id).limit(1).executeTakeFirst();
      return { areas: await areasOf(tx, id), isDefault: !rows };
    });
  });
  app.route<{ Params: { id: string } }>({ method: ['PUT', 'POST'], url: '/education/classes/:id/co-areas', handler: async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(coAreasBody, req.body);
    const names = b.areas;
    if (new Set(names.map((n) => n.toLowerCase())).size !== names.length) throw badRequest('An area is listed twice.', { areas: 'Repeated' });
    return ctx.tx(async (tx) => {
      await loadClass(tx, ctx, id);
      await tx.deleteFrom('edu_co_areas').where('class_id', '=', id).execute();
      for (const [i, name] of names.entries()) {
        await tx.insertInto('edu_co_areas').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, class_id: id, name, seq: i + 1 }).execute();
      }
      await writeAudit(tx, auditOf(ctx), 'edu_class', id, 'co_areas', null, { areas: names.length });
      return { areas: await areasOf(tx, id), isDefault: names.length === 0 };
    });
  } });

  const remarksView = async (tx: Tx, ctx: RequestContext, termId: string, classId: string) => {
    const term = await loadTerm(tx, ctx, termId);
    const cls = await loadClass(tx, ctx, classId);
    canReadClass(ctx, cls);
    const students = await rosterOf(tx, ctx, classId, []);
    const ex = await extrasOf(tx, termId, classId, students.map((s) => s.id));
    return {
      term: termJson(term), classId, label: label(cls), locked: term.status === 'published', areas: ex.areas, coGrades: (await settings(tx, ctx)).coGrades,
      students: students.map((s) => ({ studentId: s.id, name: s.name, rollNo: s.roll_no, ...ex.of(s.id) })),
    };
  };
  app.get<{ Params: { id: string; classId: string } }>('/education/exam-terms/:id/classes/:classId/remarks', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const classId = parse(z.uuid(), req.params.classId);
    return ctx.tx((tx) => remarksView(tx, ctx, id, classId));
  });
  app.route<{ Params: { id: string; classId: string } }>({ method: ['PUT', 'POST'], url: '/education/exam-terms/:id/classes/:classId/remarks', handler: async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const classId = parse(z.uuid(), req.params.classId);
    const b = parse(remarksBody, req.body);
    return ctx.tx(async (tx) => {
      const term = await loadTerm(tx, ctx, id, true);
      const cls = await loadClass(tx, ctx, classId);
      canReadClass(ctx, cls);
      if (term.status === 'published') throw conflict('This exam is published, so remarks and grades are locked.', 'TERM_PUBLISHED');
      const areas = new Set(await areasOf(tx, classId));
      const allowed = new Set((await settings(tx, ctx)).coGrades.map((g) => g.grade));
      const students = new Set((await rosterOf(tx, ctx, classId, [])).map((s) => s.id));
      for (const [i, e] of b.entries.entries()) {
        if (!students.has(e.studentId)) throw badRequest('A student in the list is not in this class.', { [`entries.${i}.studentId`]: 'Unknown student' });
        for (const [area, g] of Object.entries(e.areas ?? {})) {
          if (!areas.has(area)) throw badRequest(`${area} is not a co-scholastic area of this class.`, { [`entries.${i}.areas`]: 'Unknown area' });
          if (g !== null && !allowed.has(g)) throw badRequest(`${g} is not a grade on the scale.`, { [`entries.${i}.areas`]: 'Unknown grade' });
        }
        if (e.remark !== undefined) {
          if (e.remark === '') await tx.deleteFrom('edu_term_remarks').where('term_id', '=', id).where('student_id', '=', e.studentId).execute();
          else {
            await tx.insertInto('edu_term_remarks').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, term_id: id, student_id: e.studentId, remark: e.remark, entered_by: ctx.userId })
              .onConflict((oc) => oc.columns(['term_id', 'student_id']).doUpdateSet({ remark: e.remark!, entered_by: ctx.userId })).execute();
          }
        }
        for (const [area, g] of Object.entries(e.areas ?? {})) {
          if (g === null) await tx.deleteFrom('edu_co_grades').where('term_id', '=', id).where('student_id', '=', e.studentId).where('area', '=', area).execute();
          else {
            await tx.insertInto('edu_co_grades').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, term_id: id, student_id: e.studentId, area, grade: g, entered_by: ctx.userId })
              .onConflict((oc) => oc.columns(['term_id', 'student_id', 'area']).doUpdateSet({ grade: g, entered_by: ctx.userId })).execute();
          }
        }
      }
      await writeAudit(tx, auditOf(ctx), 'edu_exam_term', id, 'remarks', null, { classId, students: b.entries.length });
      return remarksView(tx, ctx, id, classId);
    });
  } });

  // Results and report cards ----------------------------------------------------------------
  app.get<{ Params: { id: string; classId: string } }>('/education/exam-terms/:id/classes/:classId/results', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const classId = parse(z.uuid(), req.params.classId);
    return ctx.tx((tx) => computeResults(tx, ctx, id, classId));
  });
  app.get<{ Params: { id: string; classId: string } }>('/education/exam-terms/:id/classes/:classId/report-cards', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const classId = parse(z.uuid(), req.params.classId);
    return ctx.tx(async (tx) => ({ data: await cardsFor(tx, ctx, id, classId) }));
  });
  app.get<{ Params: { id: string; studentId: string } }>('/education/exam-terms/:id/students/:studentId/report-card', async (req) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const studentId = parse(z.uuid(), req.params.studentId);
    return ctx.tx(async (tx) => {
      const s = await tx.selectFrom('edu_students').select(['class_id']).where('id', '=', studentId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!s) throw notFound('Student');
      const papers = await tx.selectFrom('edu_marks as m').innerJoin('edu_exam_papers as p', 'p.id', 'm.paper_id').select('p.class_id')
        .where('m.student_id', '=', studentId).where('p.term_id', '=', id).limit(1).executeTakeFirst();
      const classId = s.class_id ?? papers?.class_id;
      if (!classId) throw notFound('Report card');
      const card = (await cardsFor(tx, ctx, id, classId, studentId))[0];
      if (!card) throw notFound('Report card');
      return card;
    });
  });

  // Publish and lock ------------------------------------------------------------------------
  app.post<{ Params: { id: string } }>('/education/exam-terms/:id/publish', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const term = await loadTerm(tx, ctx, id, true);
      if (term.status === 'published') throw conflict('This exam is already published.', 'TERM_PUBLISHED');
      const papers = await tx.selectFrom('edu_exam_papers').select(['id', 'class_id']).where('term_id', '=', id).execute();
      if (!papers.length) throw badRequest('Add subjects and maximum marks before publishing.', { papers: 'None' });
      const missing: string[] = [];
      for (const classId of new Set(papers.map((p) => p.class_id))) {
        const mine = papers.filter((p) => p.class_id === classId);
        const students = await tx.selectFrom('edu_students').select('id').where('class_id', '=', classId).where('status', '=', 'active').execute();
        const marks = await tx.selectFrom('edu_marks').select(['paper_id', 'student_id']).where('paper_id', 'in', mine.map((p) => p.id)).execute();
        const have = new Set(marks.map((m) => `${m.paper_id}:${m.student_id}`));
        const gaps = students.reduce((n, s) => n + mine.filter((p) => !have.has(`${p.id}:${s.id}`)).length, 0);
        if (gaps) missing.push(`${label(await loadClass(tx, ctx, classId))} (${gaps})`);
      }
      if (missing.length) throw conflict(`Marks are missing for: ${missing.join(', ')}. Enter them, or mark the student absent.`, 'MARKS_INCOMPLETE', { classes: missing });
      await tx.updateTable('edu_exam_terms').set({ status: 'published', published_at: new Date(), published_by: ctx.userId }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'edu_exam_term', id, 'publish', null, { name: term.name });
      return termJson(await loadTerm(tx, ctx, id));
    });
  });
  app.post<{ Params: { id: string } }>('/education/exam-terms/:id/reopen', async (req) => {
    const ctx = req.ctx;
    needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const term = await loadTerm(tx, ctx, id, true);
      if (term.status !== 'published') throw conflict('This exam is not published.', 'NOT_PUBLISHED');
      await tx.updateTable('edu_exam_terms').set({ status: 'draft', published_at: null, published_by: null }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'edu_exam_term', id, 'reopen', null, { name: term.name });
      return termJson(await loadTerm(tx, ctx, id));
    });
  });
}

documentRoute('PUT', '/education/exam-settings', { body: settingsBody });
documentRoute('PATCH', '/education/exam-settings', { body: settingsPatch });
documentRoute('POST', '/education/subjects', { body: subjectBody });
documentRoute('PATCH', '/education/subjects/:id', { body: subjectPatch });
documentRoute('POST', '/education/classes/:id/subjects/copy', { body: subjectCopy });
documentRoute('POST', '/education/exam-terms', { body: termBody });
documentRoute('PATCH', '/education/exam-terms/:id', { body: termPatch });
documentRoute('PUT', '/education/exam-terms/:id/papers', { body: papersBody });
documentRoute('POST', '/education/exam-terms/:id/papers', { body: papersBody });
documentRoute('PUT', '/education/exam-terms/:id/classes/:classId/marks', { body: entriesBody });
documentRoute('POST', '/education/exam-terms/:id/classes/:classId/marks', { body: entriesBody });
documentRoute('PUT', '/education/classes/:id/co-areas', { body: coAreasBody });
documentRoute('POST', '/education/classes/:id/co-areas', { body: coAreasBody });
documentRoute('PUT', '/education/exam-terms/:id/classes/:classId/remarks', { body: remarksBody });
documentRoute('POST', '/education/exam-terms/:id/classes/:classId/remarks', { body: remarksBody });
