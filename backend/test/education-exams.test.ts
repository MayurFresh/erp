import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function school() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Green Valley School', name: 'Owner', email: uniqueEmail('ex'), password: 'Secret@123', stateCode: '24', businessType: 'school',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  await api('POST', '/locations', { type: 'store', name: 'Office' });
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const as = async (roleName: string) => {
    const email = uniqueEmail(roleName.replace(/\W/g, ''));
    const made = await api('POST', '/users', { name: roleName, email, password: 'Secret@123', roleId: roles.find((r) => r.name === roleName)!.id });
    expect(made.status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    return { api: client(env.app, li.body.accessToken, companyId), userId: made.body.id as string };
  };
  const year = (await api('POST', '/education/years', { name: '2026-27', startDate: '2026-04-01', endDate: '2027-03-31' })).body;
  const cls = (await api('POST', '/education/classes', { yearId: year.id, name: 'Class 5', section: 'A' })).body;
  const names = ['Asha', 'Bhavin', 'Chirag', 'Dev'];
  const students: { id: string; name: string }[] = [];
  for (const [i, n] of names.entries()) {
    const r = await api('POST', '/education/students', { name: n, sex: 'female', classId: cls.id, rollNo: String(i + 1), guardianName: `P ${n}`, guardianPhone: `98250${20000 + i}` });
    expect(r.status, JSON.stringify(r.body)).toBe(201);
    students.push(r.body);
  }
  const subj = async (name: string) => (await api('POST', '/education/subjects', { classId: cls.id, name })).body;
  const maths = await subj('Mathematics');
  const english = await subj('English');
  const term = (await api('POST', '/education/exam-terms', { yearId: year.id, name: 'Unit test 1' })).body;
  const papers = await api('PUT', `/education/exam-terms/${term.id}/papers`, {
    classId: cls.id, papers: [{ subjectId: maths.id, maxMarks: 50, passMarks: 17 }, { subjectId: english.id, maxMarks: 50 }],
  });
  expect(papers.status, JSON.stringify(papers.body)).toBe(200);
  const [pm, pe] = [papers.body.data.find((p: { subject: string }) => p.subject === 'Mathematics'), papers.body.data.find((p: { subject: string }) => p.subject === 'English')];
  return { api, as, year, cls, students, maths, english, term, pm, pe, base: `/education/exam-terms/${term.id}/classes/${cls.id}` };
}
type S = Awaited<ReturnType<typeof school>>;

async function fill(s: S, skipLast = false) {
  const data: [number | null, number | null, boolean?][] = [[48, 45], [40, 38], [30, 30], [16, null, true]];
  const entries = s.students.flatMap((st, i) => {
    const [m, e, absentEnglish] = data[i]!;
    return [
      { paperId: s.pm.id, studentId: st.id, marks: m },
      ...(skipLast && i === 3 ? [] : [absentEnglish ? { paperId: s.pe.id, studentId: st.id, absent: true } : { paperId: s.pe.id, studentId: st.id, marks: e }]),
    ];
  });
  return s.api('PUT', `${s.base}/marks`, { entries });
}

describe('exams', () => {
  it('sets up subjects, terms and papers with checks', async () => {
    const s = await school();
    expect((await s.api('POST', '/education/subjects', { classId: s.cls.id, name: 'mathematics' })).body.error?.code).toBe('DUPLICATE_SUBJECT');
    expect((await s.api('POST', '/education/exam-terms', { yearId: s.year.id, name: 'UNIT TEST 1' })).body.error?.code).toBe('DUPLICATE_TERM');
    const bad = await s.api('PUT', `/education/exam-terms/${s.term.id}/papers`, { classId: s.cls.id, papers: [{ subjectId: s.maths.id, maxMarks: 50, passMarks: 60 }] });
    expect(bad.status).toBe(400);
    const list = await s.api('GET', '/education/exam-terms');
    expect(list.body.data[0]).toMatchObject({ papers: 2, classes: 1, published: false });
    const copy = await s.api('POST', '/education/classes/' + (await s.api('POST', '/education/classes', { yearId: s.year.id, name: 'Class 5', section: 'B' })).body.id + '/subjects/copy', { fromClassId: s.cls.id });
    expect(copy.body.added).toBe(2);
  });

  it('enters marks, rejects too-high marks, keeps absent separate and clears', async () => {
    const s = await school();
    const over = await s.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pm.id, studentId: s.students[0]!.id, marks: 51 }] });
    expect(over.status).toBe(400);
    const both = await s.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pm.id, studentId: s.students[0]!.id, marks: 5, absent: true }] });
    expect(both.status).toBe(400);
    const ok = await fill(s);
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    const dev = ok.body.students.find((x: { name: string }) => x.name === 'Dev');
    expect(dev.marks[s.pe.id]).toEqual({ marks: null, absent: true });
    const one = await s.api('GET', `${s.base}/marks?subjectId=${s.maths.id}`);
    expect(one.body.papers).toHaveLength(1);
    const clear = await s.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pm.id, studentId: s.students[0]!.id, marks: null }] });
    expect(clear.body.students[0].marks[s.pm.id]).toBeNull();
    expect((await s.api('PUT', `/education/exam-terms/${s.term.id}/papers`, { classId: s.cls.id, papers: [{ subjectId: s.english.id, maxMarks: 50 }] })).body.error?.code).toBe('PAPER_HAS_MARKS');
  });

  it('computes totals, grades, pass and rank with ties', async () => {
    const s = await school();
    await fill(s);
    const r = (await s.api('GET', `${s.base}/results`)).body;
    const by = (n: string) => r.students.find((x: { name: string }) => x.name === n);
    expect(by('Asha')).toMatchObject({ total: 93, maxTotal: 100, percentage: 93, grade: 'A1', rank: 1, result: 'pass' });
    expect(by('Bhavin')).toMatchObject({ total: 78, grade: 'B1', rank: 2 });
    expect(by('Chirag')).toMatchObject({ total: 60, grade: 'C1', rank: 3, result: 'pass' });
    expect(by('Dev')).toMatchObject({ total: 16, grade: 'E', rank: 4, result: 'fail' });
    await s.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pm.id, studentId: s.students[2]!.id, marks: 48 }, { paperId: s.pe.id, studentId: s.students[2]!.id, marks: 30 }] });
    const t = (await s.api('GET', `${s.base}/results`)).body;
    expect(t.students.filter((x: { rank: number }) => x.rank === 1)).toHaveLength(1);
    expect(t.students.find((x: { name: string }) => x.name === 'Chirag').rank).toBe(2);
  });

  it('publishes only when complete, then locks marks; reopen unlocks', async () => {
    const s = await school();
    await fill(s, true);
    const no = await s.api('POST', `/education/exam-terms/${s.term.id}/publish`);
    expect(no.status).toBe(409);
    expect(no.body.error?.code).toBe('MARKS_INCOMPLETE');
    await s.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pe.id, studentId: s.students[3]!.id, absent: true }] });
    const pub = await s.api('POST', `/education/exam-terms/${s.term.id}/publish`);
    expect(pub.status, JSON.stringify(pub.body)).toBe(200);
    expect(pub.body.published).toBe(true);
    const edit = await s.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pm.id, studentId: s.students[0]!.id, marks: 1 }] });
    expect(edit.status).toBe(409);
    expect(edit.body.error?.code).toBe('TERM_PUBLISHED');
    expect((await s.api('PUT', `/education/exam-terms/${s.term.id}/papers`, { classId: s.cls.id, papers: [] })).body.error?.code).toBe('TERM_PUBLISHED');
    const card = (await s.api('GET', `/education/exam-terms/${s.term.id}/students/${s.students[0]!.id}/report-card`)).body;
    expect(card).toMatchObject({ draft: false, rank: 1, grade: 'A1', classSize: 4, year: '2026-27' });
    expect(card.subjects).toHaveLength(2);
    const all = await s.api('GET', `${s.base}/report-cards`);
    expect(all.body.data).toHaveLength(4);
    expect((await s.api('POST', `/education/exam-terms/${s.term.id}/reopen`)).body.published).toBe(false);
    expect((await s.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pm.id, studentId: s.students[0]!.id, marks: 1 }] })).status).toBe(200);
  });

  it('grading scale is editable and validated; PUT and PATCH both work', async () => {
    const s = await school();
    const def = await s.api('GET', '/education/exam-settings');
    expect(def.body).toMatchObject({ isDefault: true, passPercent: 33 });
    expect(def.body.grades[0]).toEqual({ grade: 'A1', minPct: 91 });
    expect((await s.api('PUT', '/education/exam-settings', { grades: [{ grade: 'A', minPct: 50 }, { grade: 'B', minPct: 10 }] })).status).toBe(400);
    const put = await s.api('PUT', '/education/exam-settings', { grades: [{ grade: 'A', minPct: 80 }, { grade: 'B', minPct: 50 }, { grade: 'C', minPct: 0 }] });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    const pat = await s.api('PATCH', '/education/exam-settings', { passPercent: 40 });
    expect(pat.body).toMatchObject({ passPercent: 40, isDefault: false });
    await fill(s);
    const r = (await s.api('GET', `${s.base}/results`)).body;
    expect(r.students.find((x: { name: string }) => x.name === 'Asha').grade).toBe('A');
    expect(r.students.find((x: { name: string }) => x.name === 'Chirag').grade).toBe('B');
  });

  it('teachers enter marks only for their own class and cannot set up or publish', async () => {
    const s = await school();
    const t = await s.as('Teacher');
    expect((await t.api('GET', s.base + '/marks')).status).toBe(403);
    await s.api('PATCH', `/education/classes/${s.cls.id}`, { teacherUserId: t.userId });
    const grid = await t.api('GET', s.base + '/marks');
    expect(grid.status).toBe(200);
    const put = await t.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pm.id, studentId: s.students[0]!.id, marks: 40 }] });
    expect(put.status, JSON.stringify(put.body)).toBe(200);
    expect((await t.api('POST', `/education/exam-terms/${s.term.id}/publish`)).status).toBe(403);
    expect((await t.api('POST', '/education/subjects', { classId: s.cls.id, name: 'Art' })).status).toBe(403);
    expect((await t.api('PUT', '/education/exam-settings', { grades: [{ grade: 'A', minPct: 0 }, { grade: 'B', minPct: 50 }] })).status).toBe(403);
  });

  it('saves teacher remarks and co-scholastic grades, shows them in results and cards, and locks on publish', async () => {
    const s = await school();
    await fill(s);
    const t = await s.as('Teacher');
    const other = await s.as('Teacher');
    await s.api('PATCH', `/education/classes/${s.cls.id}`, { teacherUserId: t.userId });
    const rem = `${s.base}/remarks`;
    expect((await other.api('GET', rem)).status).toBe(403);
    const view = (await t.api('GET', rem)).body;
    expect(view.areas).toEqual(['Work education', 'Art education', 'Health and physical education', 'Discipline']);
    expect(view.coGrades.map((g: { grade: string }) => g.grade)).toEqual(['A', 'B', 'C']);
    const bad = await t.api('PUT', rem, { entries: [{ studentId: s.students[0]!.id, areas: { Discipline: 'Z' } }] });
    expect(bad.status).toBe(400);
    expect((await t.api('PUT', rem, { entries: [{ studentId: s.students[0]!.id, areas: { Painting: 'A' } }] })).status).toBe(400);
    const ok = await t.api('PUT', rem, { entries: [{ studentId: s.students[0]!.id, remark: 'Bright and helpful.', areas: { Discipline: 'A', 'Art education': 'B' } }] });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    const res = (await s.api('GET', `${s.base}/results`)).body.students.find((x: { name: string }) => x.name === 'Asha');
    expect(res.remark).toBe('Bright and helpful.');
    expect(res.coScholastic.find((c: { area: string }) => c.area === 'Discipline').grade).toBe('A');
    const clear = await t.api('PUT', rem, { entries: [{ studentId: s.students[0]!.id, remark: '', areas: { 'Art education': null } }] });
    expect(clear.body.students[0].remark).toBeNull();
    await t.api('PUT', rem, { entries: [{ studentId: s.students[0]!.id, remark: 'Bright and helpful.' }] });
    // editable areas and grade scale
    expect((await s.api('PUT', `/education/classes/${s.cls.id}/co-areas`, { areas: ['Music', 'Discipline'] })).body.areas).toEqual(['Music', 'Discipline']);
    const sc = await s.api('PATCH', '/education/exam-settings', { coGrades: [{ grade: 'Good', label: 'Good' }, { grade: 'Fair', label: 'Fair' }] });
    expect(sc.body.coGrades[0].grade).toBe('Good');
    expect((await t.api('PUT', `/education/classes/${s.cls.id}/co-areas`, { areas: ['X'] })).status).toBe(403);
    await s.api('PUT', `${s.base}/marks`, { entries: [{ paperId: s.pe.id, studentId: s.students[3]!.id, absent: true }] });
    expect((await s.api('POST', `/education/exam-terms/${s.term.id}/publish`)).status).toBe(200);
    const lock = await t.api('PUT', rem, { entries: [{ studentId: s.students[0]!.id, remark: 'Changed' }] });
    expect(lock.status).toBe(409);
    const card = (await s.api('GET', `/education/exam-terms/${s.term.id}/students/${s.students[0]!.id}/report-card`)).body;
    expect(card.remark).toBe('Bright and helpful.');
    expect(card.coScholastic).toHaveLength(2);
  });
});
