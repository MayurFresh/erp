import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function school(businessType = 'school') {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Green Valley School', name: 'Owner', email: uniqueEmail('sc'), password: 'Secret@123', stateCode: '24', businessType,
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  await api('POST', '/locations', { type: 'store', name: 'Office' });
  const roles = (await api('GET', '/roles')).body.data as { id: string; name: string }[];
  const as = async (roleName: string) => {
    const email = uniqueEmail(roleName.replace(/\W/g, ''));
    const role = roles.find((r) => r.name === roleName)!;
    expect(role, roleName).toBeTruthy();
    const made = await api('POST', '/users', { name: roleName, email, password: 'Secret@123', roleId: role.id });
    expect(made.status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    return { api: client(env.app, li.body.accessToken, companyId), userId: made.body.id as string };
  };
  const today = todayIst();
  const year = (await api('POST', '/education/years', { name: '2026-27', startDate: '2026-04-01', endDate: '2027-03-31' })).body;
  const tuition = (await api('POST', '/education/fee-heads', { name: 'Tuition fee', gstRate: 0 })).body;
  const transport = (await api('POST', '/education/fee-heads', { name: 'Transport fee', gstRate: 0 })).body;
  const late = (await api('POST', '/education/fee-heads', { name: 'Late fee', gstRate: 0 })).body;
  const cash = ((await api('GET', '/accounts')).body.data as { id: string; subtype: string }[]).find((a) => a.subtype === 'cash')!;
  return { api, as, year, tuition, transport, late, cash, today, companyId };
}
type School = Awaited<ReturnType<typeof school>>;

const kid = (name: string, classId: string, over: Record<string, unknown> = {}) => ({
  name, sex: 'female', classId, guardianName: `Parent of ${name}`, guardianRelation: 'Mother', guardianPhone: `98250${Math.floor(10000 + Math.random() * 89999)}`, ...over,
});

async function withPlan(s: School, opts: { due?: string; late?: Record<string, unknown> } = {}) {
  const cls = (await s.api('POST', '/education/classes', { yearId: s.year.id, name: 'Class 5', section: 'A', capacity: 3 })).body;
  const plan = await s.api('PUT', `/education/classes/${cls.id}/fee-plan`, {
    name: 'Class 5 fees', late: opts.late ?? { kind: 'none' },
    instalments: [
      { label: 'Term 1', dueDate: opts.due ?? addDays(s.today, 30), lines: [{ headId: s.tuition.id, amount: 5000 }, { headId: s.transport.id, amount: 1000 }] },
      { label: 'Term 2', dueDate: addDays(s.today, 120), lines: [{ headId: s.tuition.id, amount: 5000 }] },
    ],
  });
  expect(plan.status, JSON.stringify(plan.body)).toBe(200);
  return { cls, plan: plan.body };
}

describe('students', () => {
  it('admits with a series number and a party, searches, warns on duplicates, enforces capacity', async () => {
    const s = await school();
    const { cls } = await withPlan(s);
    const a = await s.api('POST', '/education/students', kid('Diya Patel', cls.id, { guardianPhone: '9825011111', rollNo: '1' }));
    expect(a.status, JSON.stringify(a.body)).toBe(201);
    expect(a.body.admissionNo).toMatch(/^ADM\/\d{2}-\d{2}\/00001$/);
    const party = (await s.api('GET', '/parties?q=Diya')).body.data.find((p: { id: string }) => p.id === a.body.partyId);
    expect(party.type).toBe('customer');
    const dup = await s.api('POST', '/education/students', kid('diya patel', cls.id, { guardianPhone: '9825011111' }));
    expect(dup.status).toBe(409);
    expect(dup.body.error?.code ?? dup.body.code).toBe('DUPLICATE_STUDENT');
    expect((await s.api('POST', '/education/students', kid('Roll Clash', cls.id, { rollNo: '1' }))).status).toBe(409);
    for (const q of ['Diya', '98250111', a.body.admissionNo.slice(-5)]) {
      expect((await s.api('GET', `/education/students?q=${encodeURIComponent(q)}`)).body.data.length, q).toBeGreaterThan(0);
    }
    expect((await s.api('POST', '/education/students', kid('Second', cls.id))).status).toBe(201);
    expect((await s.api('POST', '/education/students', kid('Third', cls.id))).status).toBe(201);
    const full = await s.api('POST', '/education/students', kid('Fourth', cls.id));
    expect(full.status).toBe(409);
    expect(full.body.error?.code ?? full.body.code).toBe('CLASS_FULL');
    const patched = await s.api('PATCH', `/education/students/${a.body.id}`, { guardianPhone: '9825099999', expectedUpdatedAt: a.body.updatedAt });
    expect(patched.status).toBe(200);
    expect((await s.api('PATCH', `/education/students/${a.body.id}`, { notes: 'x', expectedUpdatedAt: a.body.updatedAt })).status).toBe(409);
  });
});

describe('promotion', () => {
  it('moves a whole class to the next year class and can pass students out', async () => {
    const s = await school();
    const { cls } = await withPlan(s);
    for (const n of ['A One', 'A Two']) await s.api('POST', '/education/students', kid(n, cls.id));
    const y2 = (await s.api('POST', '/education/years', { name: '2027-28', startDate: '2027-04-01', endDate: '2028-03-31', isCurrent: true })).body;
    expect((await s.api('GET', '/education/years')).body.data.filter((y: { isCurrent: boolean }) => y.isCurrent)).toHaveLength(1);
    const next = (await s.api('POST', '/education/classes', { yearId: y2.id, name: 'Class 6', section: 'A', capacity: 5 })).body;
    const r = await s.api('POST', '/education/promote', { fromClassId: cls.id, toClassId: next.id });
    expect(r.status).toBe(200);
    expect(r.body.moved).toBe(2);
    expect((await s.api('GET', `/education/students?classId=${next.id}`)).body.total).toBe(2);
    expect((await s.api('GET', `/education/students?classId=${cls.id}`)).body.total).toBe(0);
    const out = await s.api('POST', '/education/promote', { fromClassId: next.id, passOut: true });
    expect(out.body.passedOut).toBe(2);
    expect((await s.api('GET', '/education/students?status=passed_out')).body.total).toBe(2);
  });
});

describe('fee plan and demands', () => {
  it('reads a plan back, and demand generation is idempotent and skips billed students', async () => {
    const s = await school();
    const { cls, plan } = await withPlan(s);
    expect(plan.instalments).toHaveLength(2);
    expect(plan.instalments[0].total).toBe(6000);
    const a = (await s.api('POST', '/education/students', kid('Bill One', cls.id))).body;
    await s.api('POST', '/education/students', kid('Bill Two', cls.id));
    const body = { classId: cls.id, instalmentId: plan.instalments[0].id };
    const pre = await s.api('POST', '/education/demands/generate', { ...body, preview: true });
    expect(pre.status).toBe(200);
    expect(pre.body.count).toBe(2);
    expect(pre.body.amount).toBe(12000);
    expect((await s.api('GET', '/invoices')).body.data).toHaveLength(0);
    const run = await s.api('POST', '/education/demands/generate', body);
    expect(run.status, JSON.stringify(run.body)).toBe(201);
    expect(run.body.created).toBe(2);
    const inv = (await s.api('GET', `/invoices/${run.body.invoices[0].invoiceId}`)).body;
    expect(inv.total).toBe(6000);
    expect(inv.dueDate).toBe(plan.instalments[0].dueDate);
    // A new student joins, then the run is repeated.
    await s.api('POST', '/education/students', kid('Bill Three', cls.id));
    const again = await s.api('POST', '/education/demands/generate', { ...body, preview: true });
    expect(again.body.count).toBe(1);
    expect(again.body.alreadyBilled).toBe(2);
    const second = await s.api('POST', '/education/demands/generate', body);
    expect(second.body.created).toBe(1);
    const third = await s.api('POST', '/education/demands/generate', body);
    expect(third.body.created).toBe(0);
    expect((await s.api('GET', '/invoices')).body.data).toHaveLength(3);
    // A cancelled bill can be raised again.
    expect((await s.api('POST', `/invoices/${run.body.invoices.find((i: { studentId: string }) => i.studentId === a.id).invoiceId}/cancel`, { reason: 'Raised by mistake' })).status).toBe(200);
    expect((await s.api('POST', '/education/demands/generate', body)).body.created).toBe(1);
    // Unknown instalment and class without a plan.
    expect((await s.api('POST', '/education/demands/generate', { classId: cls.id, instalmentId: cls.id })).status).toBe(400);
    const bare = (await s.api('POST', '/education/classes', { yearId: s.year.id, name: 'Class 9' })).body;
    expect((await s.api('POST', '/education/demands/generate', { classId: bare.id, instalmentId: cls.id })).status).toBe(400);
  });

  it('applies a percent concession and an amount concession', async () => {
    const s = await school();
    const { cls, plan } = await withPlan(s);
    const a = (await s.api('POST', '/education/students', kid('Half Fee', cls.id))).body;
    const b = (await s.api('POST', '/education/students', kid('Flat Off', cls.id))).body;
    expect((await s.api('POST', `/education/students/${a.id}/concessions`, { headId: s.tuition.id, kind: 'percent', value: 50, reason: 'Staff child' })).status).toBe(201);
    expect((await s.api('POST', `/education/students/${b.id}/concessions`, { headId: s.transport.id, kind: 'amount', value: 1000, reason: 'Lives nearby' })).status).toBe(201);
    expect((await s.api('POST', `/education/students/${b.id}/concessions`, { headId: s.transport.id, kind: 'percent', value: 150, reason: 'x' })).status).toBe(400);
    const run = await s.api('POST', '/education/demands/generate', { classId: cls.id, instalmentId: plan.instalments[0].id });
    const totals = new Map<string, number>(run.body.invoices.map((i: { studentId: string; total: number }) => [i.studentId, i.total]));
    expect(totals.get(a.id)).toBe(3500);
    expect(totals.get(b.id)).toBe(5000);
    expect(run.body.concessionAmount).toBe(3500);
    expect((await s.api('GET', `/education/students/${a.id}`)).body.concessions).toHaveLength(1);
  });

  it('adds a late fee line only after the due date', async () => {
    const s = await school();
    const late = { kind: 'per_day', value: 10, headId: s.late.id };
    const { cls, plan } = await withPlan(s, { due: addDays(s.today, -5), late });
    await s.api('POST', '/education/students', kid('Late Payer', cls.id));
    const pre = await s.api('POST', '/education/demands/generate', { classId: cls.id, instalmentId: plan.instalments[0].id, preview: true });
    expect(pre.body.lateFeeCount).toBe(1);
    expect(pre.body.lateFeeAmount).toBe(50);
    const off = await s.api('POST', '/education/demands/generate', { classId: cls.id, instalmentId: plan.instalments[0].id, preview: true, applyLateFee: false });
    expect(off.body.lateFeeCount).toBe(0);
    const run = await s.api('POST', '/education/demands/generate', { classId: cls.id, instalmentId: plan.instalments[0].id });
    expect(run.body.invoices[0].total).toBe(6050);
    const inv = (await s.api('GET', `/invoices/${run.body.invoices[0].invoiceId}`)).body;
    expect(inv.lines.some((l: { description: string }) => /late/i.test(l.description))).toBe(true);
    // Not yet due: no late fee even with a rule.
    const s2 = await school();
    const p2 = await withPlan(s2, { late: { kind: 'flat', value: 100, headId: s2.late.id } });
    await s2.api('POST', '/education/students', kid('On Time', p2.cls.id));
    expect((await s2.api('POST', '/education/demands/generate', { classId: p2.cls.id, instalmentId: p2.plan.instalments[0].id, preview: true })).body.lateFeeCount).toBe(0);
    expect((await s2.api('PUT', `/education/classes/${p2.cls.id}/fee-plan`, { late: { kind: 'flat', value: 100 }, instalments: [{ label: 'T', dueDate: s2.today, lines: [{ headId: s2.tuition.id, amount: 1 }] }] })).status).toBe(400);
  });

  it('takes GST on a coaching fee head', async () => {
    const s = await school('coaching');
    const head = (await s.api('POST', '/education/fee-heads', { name: 'Course fee', gstRate: 18 })).body;
    const batch = (await s.api('POST', '/education/classes', { yearId: s.year.id, kind: 'batch', name: 'JEE Morning', course: 'JEE', timing: '7 to 9 am', teacherName: 'R K Sir' })).body;
    const plan = (await s.api('PUT', `/education/classes/${batch.id}/fee-plan`, { instalments: [{ label: 'Month 1', dueDate: addDays(s.today, 10), lines: [{ headId: head.id, amount: 1000 }] }] })).body;
    await s.api('POST', '/education/students', kid('Coach Kid', batch.id));
    const run = await s.api('POST', '/education/demands/generate', { classId: batch.id, instalmentId: plan.instalments[0].id });
    expect(run.body.invoices[0].total).toBe(1180);
  });
});

describe('collection and dues', () => {
  it('collects partially, oldest instalment first, lists dues and defaulters, and builds a receipt', async () => {
    const s = await school();
    const { cls, plan } = await withPlan(s, { due: addDays(s.today, -3) });
    const a = (await s.api('POST', '/education/students', kid('Pays Part', cls.id, { guardianName: 'Hetal Patel', guardianPhone: '9825055555' }))).body;
    await s.api('POST', '/education/students', kid('Pays None', cls.id));
    for (const n of plan.instalments) await s.api('POST', '/education/demands/generate', { classId: cls.id, instalmentId: n.id, applyLateFee: false });
    const dues0 = (await s.api('GET', '/education/dues')).body;
    expect(dues0.total).toBe(2);
    expect(dues0.dueTotal).toBe(22000);
    expect(dues0.overdueTotal).toBe(12000);
    expect((await s.api('GET', '/education/dues?overdue=true')).body.total).toBe(2);
    const row = (await s.api('GET', `/education/dues?q=Pays Part`)).body.data[0];
    expect(row.daysOverdue).toBe(3);
    expect(row.reminder).toContain('Hetal Patel');
    expect(row.reminder).toContain('Rs 6,000');

    const over = await s.api('POST', `/education/students/${a.id}/collect`, { accountId: s.cash.id, mode: 'cash', amount: 99999 });
    expect(over.status).toBe(400);
    const pay = await s.api('POST', `/education/students/${a.id}/collect`, { accountId: s.cash.id, mode: 'upi', amount: 4000, reference: 'UPI123' });
    expect(pay.status, JSON.stringify(pay.body)).toBe(201);
    expect(pay.body.balance).toBe(7000);
    expect(pay.body.allocations).toHaveLength(1);
    const ledger = (await s.api('GET', `/education/students/${a.id}/ledger`)).body;
    expect(ledger.paid).toBe(4000);
    expect(ledger.due).toBe(7000);
    expect(ledger.bills[0].due).toBe(2000);
    expect(ledger.receipts).toHaveLength(1);
    // Second payment spills into the next instalment.
    const pay2 = await s.api('POST', `/education/students/${a.id}/collect`, { accountId: s.cash.id, mode: 'cash', amount: 3000 });
    expect(pay2.body.allocations).toHaveLength(2);
    const rec = (await s.api('GET', `/education/receipts/${pay2.body.payment.id}`)).body;
    expect(rec.student.name).toBe('Pays Part');
    expect(rec.school.name).toBe('Green Valley School');
    expect(rec.paidFor).toHaveLength(2);
    expect(rec.balance).toBe(4000);
    const home = (await s.api('GET', '/education/home')).body;
    expect(home.feesCollectedToday).toBe(7000);
    expect(home.duesTotal).toBe(15000);
    expect(home.defaultersCount).toBe(1);
    // Pay everything: the student leaves the dues list.
    await s.api('POST', `/education/students/${a.id}/collect`, { accountId: s.cash.id, mode: 'cash', amount: 4000 });
    expect((await s.api('GET', '/education/dues')).body.total).toBe(1);
    expect((await s.api('POST', `/education/students/${a.id}/collect`, { accountId: s.cash.id, mode: 'cash', amount: 1 })).status).toBe(400);
  });
});

describe('attendance', () => {
  it('keeps one record per student per day, defaults to present and allows same-day edits', async () => {
    const s = await school();
    const teacher = await s.as('Teacher');
    const cls = (await s.api('POST', '/education/classes', { yearId: s.year.id, name: 'Class 7', teacherUserId: teacher.userId })).body;
    const other = (await s.api('POST', '/education/classes', { yearId: s.year.id, name: 'Class 8' })).body;
    const ids: string[] = [];
    for (const n of ['Asha', 'Bhavin', 'Chirag']) ids.push((await s.api('POST', '/education/students', kid(n, cls.id))).body.id);
    const empty = (await teacher.api('GET', `/education/classes/${cls.id}/attendance`)).body;
    expect(empty.marked).toBe(false);
    expect(empty.students.every((x: { status: string }) => x.status === 'present')).toBe(true);
    const save = await teacher.api('PUT', `/education/classes/${cls.id}/attendance`, { marks: [{ studentId: ids[1], status: 'absent' }, { studentId: ids[2], status: 'late' }] });
    expect(save.status, JSON.stringify(save.body)).toBe(200);
    const by = (r: { students: { studentId: string; status: string }[] }, i: number) => r.students.find((x) => x.studentId === ids[i])!.status;
    expect([by(save.body, 0), by(save.body, 1), by(save.body, 2)]).toEqual(['present', 'absent', 'late']);
    // Edit the same day: one row per student stays.
    const edit = await teacher.api('PUT', `/education/classes/${cls.id}/attendance`, { marks: [{ studentId: ids[1], status: 'present' }] });
    expect(by(edit.body, 1)).toBe('present');
    expect(by(edit.body, 2)).toBe('late');
    // Past day: teachers refused, manager allowed.
    const past = addDays(s.today, -1);
    expect((await teacher.api('PUT', `/education/classes/${cls.id}/attendance`, { date: past, marks: [] })).status).toBe(403);
    expect((await s.api('PUT', `/education/classes/${cls.id}/attendance`, { date: past, marks: [{ studentId: ids[0], status: 'absent' }] })).status).toBe(200);
    expect((await teacher.api('PUT', `/education/classes/${cls.id}/attendance`, { date: addDays(s.today, 1), marks: [] })).status).toBe(400);
    // Not their class.
    expect((await teacher.api('PUT', `/education/classes/${other.id}/attendance`, { marks: [] })).status).toBe(403);
    // Student not in the class.
    expect((await s.api('PUT', `/education/classes/${other.id}/attendance`, { marks: [{ studentId: ids[0], status: 'absent' }] })).status).toBe(400);
    const sheet = (await s.api('GET', `/education/classes/${cls.id}/attendance/sheet?month=${s.today.slice(0, 7)}`)).body;
    expect(sheet.workingDays).toBeGreaterThanOrEqual(1);
    const asha = sheet.students.find((x: { studentId: string }) => x.studentId === ids[0]);
    expect(asha.absent).toBe(past.slice(0, 7) === s.today.slice(0, 7) ? 1 : 0);
    const mine = (await s.api('GET', `/education/students/${ids[2]}/attendance`)).body;
    expect(mine.overall.late).toBe(1);
    expect(mine.overall.percentage).toBe(100);
    const home = (await teacher.api('GET', '/education/home')).body;
    const row = home.classes.find((c: { id: string }) => c.id === cls.id);
    expect(row.attendanceMarked).toBe(true);
    expect(row.mine).toBe(true);
    expect(home.feesCollectedToday).toBeNull();
  });
});

describe('permissions and roles', () => {
  it('keeps fees away from teachers, setup to managers, and gives school roles their permissions', async () => {
    const s = await school();
    const { cls, plan } = await withPlan(s);
    const stu = (await s.api('POST', '/education/students', kid('Perm Kid', cls.id))).body;
    await s.api('POST', '/education/demands/generate', { classId: cls.id, instalmentId: plan.instalments[0].id });
    const teacher = await s.as('Teacher');
    const office = await s.as('Office Staff');
    const accountant = await s.as('Accountant');
    expect((await teacher.api('GET', '/education/students')).status).toBe(200);
    expect((await teacher.api('POST', `/education/students/${stu.id}/collect`, { accountId: s.cash.id, mode: 'cash', amount: 100 })).status).toBe(403);
    expect((await teacher.api('GET', '/education/dues')).status).toBe(403);
    expect((await teacher.api('POST', '/education/demands/generate', { classId: cls.id, instalmentId: plan.instalments[1].id })).status).toBe(403);
    expect((await teacher.api('POST', '/education/students', kid('No Way', cls.id))).status).toBe(403);
    expect((await teacher.api('POST', '/education/classes', { yearId: s.year.id, name: 'X' })).status).toBe(403);
    expect((await office.api('POST', '/education/students', kid('Office Admit', cls.id))).status).toBe(201);
    expect((await office.api('POST', `/education/students/${stu.id}/collect`, { accountId: s.cash.id, mode: 'cash', amount: 100 })).status).toBe(201);
    expect((await office.api('POST', '/education/fee-heads', { name: 'Sports' })).status).toBe(403);
    expect((await office.api('POST', '/education/promote', { fromClassId: cls.id, passOut: true })).status).toBe(403);
    expect((await office.api('PUT', `/education/classes/${cls.id}/attendance`, { marks: [] })).status).toBe(403);
    expect((await accountant.api('GET', '/education/dues')).status).toBe(200);
    expect((await accountant.api('POST', '/education/students', kid('No', cls.id))).status).toBe(403);
    expect((await client(env.app)('GET', '/education/home')).status).toBe(401);
    expect((await s.api('GET', '/education/home')).status).toBe(200);
  });
});
