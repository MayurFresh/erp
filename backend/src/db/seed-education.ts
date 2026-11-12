// Demo school data: one academic year, three classes with fee plans and a few students. Not called from seed.ts; the lead wires it in.
// Fee demands are not generated here: they go through the invoice service from the app.
import type { Tx } from './database.ts';
import { addDays, financialYear, todayIst } from '../lib/dates.ts';
import { nextNumber } from '../lib/series.ts';

export interface EducationSeedWho { tenantId: string; companyId: string; userId: string }

const STUDENTS: [string, 'male' | 'female', string, string, string][] = [
  ['Aarav Sharma', 'male', 'Rajesh Sharma', 'Father', '9825010001'],
  ['Diya Patel', 'female', 'Hetal Patel', 'Mother', '9825010002'],
  ['Vivaan Joshi', 'male', 'Mahesh Joshi', 'Father', '9825010003'],
  ['Ananya Desai', 'female', 'Kiran Desai', 'Father', '9825010004'],
  ['Kabir Shah', 'male', 'Nilesh Shah', 'Father', '9825010005'],
  ['Meera Trivedi', 'female', 'Anita Trivedi', 'Mother', '9825010006'],
  ['Ishaan Mehta', 'male', 'Sunil Mehta', 'Father', '9825010007'],
  ['Zoya Sheikh', 'female', 'Fatima Sheikh', 'Mother', '9825010008'],
];

export async function seedEducationDemo(tx: Tx, { tenantId, companyId, userId }: EducationSeedWho) {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', companyId).executeTakeFirstOrThrow();
  const today = todayIst();
  const y = Number(today.slice(0, 4)) - (today.slice(5, 7) < '04' ? 1 : 0);
  const year = await tx.insertInto('edu_years').values({
    tenant_id: tenantId, company_id: companyId, name: `${y}-${String(y + 1).slice(2)}`, start_date: `${y}-04-01`, end_date: `${y + 1}-03-31`, is_current: true,
  }).returning('id').executeTakeFirstOrThrow();

  const heads: Record<string, string> = {};
  for (const [name, hsn] of [['Tuition fee', '999293'], ['Transport fee', '999293'], ['Exam fee', '999293'], ['Late fee', '999293']] as const) {
    const item = await tx.insertInto('items').values({
      tenant_id: tenantId, company_id: companyId, name, sku: null, hsn_code: hsn, unit: 'NOS', gst_rate: 0, sale_price: 0, track_stock: false,
    }).returning('id').executeTakeFirstOrThrow();
    const h = await tx.insertInto('edu_fee_heads').values({ tenant_id: tenantId, company_id: companyId, item_id: item.id, name, gst_rate: 0 }).returning('id').executeTakeFirstOrThrow();
    heads[name] = h.id;
  }

  const classes = await tx.insertInto('edu_classes').values(
    [['Class 5', 'A'], ['Class 5', 'B'], ['Class 6', 'A']].map(([name, section]) => ({
      tenant_id: tenantId, company_id: companyId, year_id: year.id, kind: 'class', name: name!, section: section!, capacity: 40,
    })),
  ).returning(['id', 'name', 'section']).execute();

  for (const [i, c] of classes.entries()) {
    const tuition = 6000 + i * 500;
    const plan = await tx.insertInto('edu_fee_plans').values({
      tenant_id: tenantId, company_id: companyId, class_id: c.id, name: `${c.name} fees`, late_kind: 'flat', late_value: 100, late_head_id: heads['Late fee']!,
    }).returning('id').executeTakeFirstOrThrow();
    const dues = [`${y}-04-10`, `${y}-07-10`, `${y}-10-10`, `${y + 1}-01-10`];
    await tx.insertInto('edu_instalments').values(dues.map((d, n) => ({
      tenant_id: tenantId, plan_id: plan.id, seq: n + 1, label: `Term ${n + 1}`, due_date: d,
      lines: JSON.stringify([
        { headId: heads['Tuition fee']!, amount: tuition }, { headId: heads['Transport fee']!, amount: 1200 },
        ...(n % 2 === 0 ? [{ headId: heads['Exam fee']!, amount: 400 }] : []),
      ]) as never,
    }))).execute();
  }

  const fy = financialYear(today);
  const studentIds: { id: string; classId: string }[] = [];
  for (const [i, [name, sex, guardian, relation, phone]] of STUDENTS.entries()) {
    const cls = classes[i % classes.length]!;
    const party = await tx.insertInto('parties').values({
      tenant_id: tenantId, company_id: companyId, type: 'customer', name, phone, address: null, state_code: company.state_code,
      gstin: null, email: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
    }).returning('id').executeTakeFirstOrThrow();
    const stu = await tx.insertInto('edu_students').values({
      tenant_id: tenantId, company_id: companyId, party_id: party.id, admission_no: await nextNumber(tx, { tenantId, companyId }, 'student', fy),
      name, class_id: cls.id, roll_no: String(Math.floor(i / classes.length) + 1), dob: addDays(today, -365 * (10 + (i % 3))), sex,
      guardian_name: guardian, guardian_relation: relation, guardian_phone: phone, address: 'Navrangpura, Ahmedabad',
      admission_date: `${y}-04-02`, created_by: userId,
    }).returning('id').executeTakeFirstOrThrow();
    studentIds.push({ id: stu.id, classId: cls.id });
  }

  await seedEducationExams(tx, { tenantId, companyId, userId }, { yearId: year.id, y, classes, studentIds });
  return { yearId: year.id, classes: classes.length, students: STUDENTS.length };
}

/** Exam sample data for an existing school: subjects, a draft Unit test 1 with marks, remarks and co-scholastic grades. */
export async function seedEducationExams(
  tx: Tx, { tenantId, companyId, userId }: EducationSeedWho,
  { yearId, y, classes, studentIds }: { yearId: string; y: number; classes: { id: string }[]; studentIds: { id: string; classId: string }[] },
) {
  // Exams: subjects per class, one published-ready term (Unit test 1, draft) with marks for every student; one is absent.
  const term = await tx.insertInto('edu_exam_terms').values({
    tenant_id: tenantId, company_id: companyId, year_id: yearId, name: 'Unit test 1', seq: 1, start_date: `${y}-07-15`, end_date: `${y}-07-22`,
  }).returning('id').executeTakeFirstOrThrow();
  let seq = 0;
  for (const c of classes) {
    for (const [n, name, max] of [[1, 'English', 25], [2, 'Mathematics', 25], [3, 'Science', 25], [4, 'Hindi', 25], [5, 'Gujarati', 25]] as const) {
      const subj = await tx.insertInto('edu_subjects').values({ tenant_id: tenantId, company_id: companyId, class_id: c.id, name, seq: n }).returning('id').executeTakeFirstOrThrow();
      const paper = await tx.insertInto('edu_exam_papers').values({
        tenant_id: tenantId, company_id: companyId, term_id: term.id, class_id: c.id, subject_id: subj.id, max_marks: max, pass_marks: 9, exam_date: `${y}-07-${14 + n}`,
      }).returning('id').executeTakeFirstOrThrow();
      for (const st of studentIds.filter((x) => x.classId === c.id)) {
        seq++;
        const absent = seq === 7;
        await tx.insertInto('edu_marks').values({
          tenant_id: tenantId, company_id: companyId, paper_id: paper.id, student_id: st.id, marks: absent ? null : 12 + ((seq * 7) % 14), absent, entered_by: userId,
        }).execute();
      }
    }
  }
  for (const [i, st] of studentIds.entries()) {
    if (i % 2 === 0) {
      await tx.insertInto('edu_term_remarks').values({
        tenant_id: tenantId, company_id: companyId, term_id: term.id, student_id: st.id, remark: 'Works steadily. Can do better in Mathematics with regular practice.', entered_by: userId,
      }).execute();
    }
    for (const [a, area] of ['Work education', 'Art education', 'Health and physical education', 'Discipline'].entries()) {
      await tx.insertInto('edu_co_grades').values({
        tenant_id: tenantId, company_id: companyId, term_id: term.id, student_id: st.id, area, grade: 'ABC'[(i + a) % 3]!, entered_by: userId,
      }).execute();
    }
  }
}
