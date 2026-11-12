import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

type Api = ReturnType<typeof client>;

async function clinic() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'Care Clinic', name: 'Owner', email: uniqueEmail('cl'), password: 'Secret@123', stateCode: '24', businessType: 'clinic',
  });
  expect(res.status).toBe(201);
  const me = (await client(env.app, res.body.accessToken)('GET', '/me')).body;
  const companyId = me.companies[0].id as string;
  const api = client(env.app, res.body.accessToken, companyId);
  await api('POST', '/locations', { type: 'store', name: 'Main' });
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
  const doctor = (await api('POST', '/clinic/doctors', {
    name: 'Dr Mehta', speciality: 'General medicine', registrationNo: 'GMC-12345', consultFee: 500, followUpFee: 200, followUpDays: 7,
    slotMinutes: 15, workingHours: [0, 1, 2, 3, 4, 5, 6].map((day) => ({ day, from: '09:00', to: '13:00' })),
  })).body;
  return { api, as, doctor, companyId };
}

const patientBody = (over: Record<string, unknown> = {}) => ({
  name: 'Ravi Shah', sex: 'male', ageYears: 41, phone: '9825012345', address: 'Navrangpura, Ahmedabad', bloodGroup: 'B+',
  allergies: 'Penicillin', ...over,
});
const tomorrow = () => addDays(todayIst(), 1);

describe('clinic patients', () => {
  it('registers a patient with a party and UHID, searches, and warns on duplicates', async () => {
    const c = await clinic();
    const res = await c.api('POST', '/clinic/patients', patientBody({ notes: 'Prefers morning visits' }));
    expect(res.status).toBe(201);
    expect(res.body.uhid).toMatch(/^UHID\/\d{2}-\d{2}\/00001$/);
    expect(res.body.ageYears).toBe(41);
    const party = (await c.api('GET', `/parties?q=Ravi`)).body.data.find((p: { id: string }) => p.id === res.body.partyId);
    expect(party.type).toBe('customer');
    const dup = await c.api('POST', '/clinic/patients', patientBody({ name: 'ravi shah' }));
    expect(dup.status).toBe(409);
    expect(dup.body.error?.code ?? dup.body.code).toBe('DUPLICATE_PATIENT');
    const forced = await c.api('POST', '/clinic/patients', patientBody({ force: true }));
    expect(forced.status).toBe(201);
    expect(forced.body.uhid).toMatch(/00002$/);
    expect((await c.api('POST', '/clinic/patients', patientBody({ name: 'X', phone: '98', ageYears: undefined }))).status).toBe(400);
    for (const q of ['Ravi', '98250', res.body.uhid.slice(-5)]) {
      const list = await c.api('GET', `/clinic/patients?q=${encodeURIComponent(q)}`);
      expect(list.body.data.length).toBeGreaterThan(0);
      expect(JSON.stringify(list.body)).not.toContain('Prefers morning');
    }
  });
});

describe('clinic appointments', () => {
  it('rejects double booking, numbers walk-in tokens per doctor per day and follows the status flow', async () => {
    const c = await clinic();
    const p1 = (await c.api('POST', '/clinic/patients', patientBody())).body;
    const p2 = (await c.api('POST', '/clinic/patients', patientBody({ name: 'Meena Patel', phone: '9825099999', sex: 'female' }))).body;
    const doc2 = (await c.api('POST', '/clinic/doctors', { name: 'Dr Rao', consultFee: 300 })).body;
    const book = (patientId: string, startTime: string, doctorId = c.doctor.id) =>
      c.api('POST', '/clinic/appointments', { patientId, doctorId, date: tomorrow(), startTime });
    const a = await book(p1.id, '09:15');
    expect(a.status).toBe(201);
    expect(a.body.status).toBe('booked');
    const clash = await book(p2.id, '09:15');
    expect(clash.status).toBe(409);
    expect(clash.body.error?.code ?? clash.body.code).toBe('SLOT_TAKEN');
    expect((await book(p2.id, '09:20')).status).toBe(400); // off the 15 minute grid
    expect((await book(p2.id, '13:00')).status).toBe(400); // after hours
    expect((await book(p2.id, '09:15', doc2.id)).status).toBe(201); // other doctor, same time
    const slots = (await c.api('GET', `/clinic/doctors/${c.doctor.id}/slots?date=${tomorrow()}`)).body;
    expect(slots.data.find((s: { startTime: string }) => s.startTime === '09:15').free).toBe(false);
    expect(slots.data.find((s: { startTime: string }) => s.startTime === '09:30').free).toBe(true);

    // Cancelling frees the slot.
    expect((await c.api('POST', `/clinic/appointments/${a.body.id}/status`, { status: 'cancelled', reason: 'Patient asked' })).body.status).toBe('cancelled');
    expect((await book(p2.id, '09:15')).status).toBe(201);

    // Rescheduling.
    const r = await book(p1.id, '10:00');
    const moved = await c.api('POST', `/clinic/appointments/${r.body.id}/reschedule`, { date: tomorrow(), startTime: '10:30' });
    expect(moved.body.startTime).toBe('10:30');
    expect((await c.api('POST', `/clinic/appointments/${r.body.id}/reschedule`, { date: tomorrow(), startTime: '09:15' })).status).toBe(409);

    // Walk-in tokens count per doctor.
    const w = (patientId: string, doctorId: string) => c.api('POST', '/clinic/appointments', { patientId, doctorId, walkIn: true });
    const w1 = await w(p1.id, c.doctor.id);
    const w2 = await w(p2.id, c.doctor.id);
    const w3 = await w(p1.id, doc2.id);
    expect([w1.body.tokenNo, w2.body.tokenNo, w3.body.tokenNo]).toEqual([1, 2, 1]);
    expect(w1.body.status).toBe('arrived');
    const queue = (await c.api('GET', `/clinic/appointments?date=${todayIst()}&doctorId=${c.doctor.id}`)).body;
    expect(queue.data.map((x: { tokenNo: number }) => x.tokenNo)).toEqual([1, 2]);

    // Status flow: a cancelled one cannot arrive; done cannot be set by hand.
    expect((await c.api('POST', `/clinic/appointments/${w1.body.id}/status`, { status: 'no_show' })).status).toBe(409);
    expect((await c.api('POST', `/clinic/appointments/${w1.body.id}/status`, { status: 'done' })).status).toBe(400);
    expect((await c.api('POST', `/clinic/appointments/${r.body.id}/status`, { status: 'arrived' })).status).toBe(409); // tomorrow
    expect((await book(p1.id, '09:00')).status).toBe(201);
    const past = await c.api('POST', '/clinic/appointments', { patientId: p1.id, doctorId: c.doctor.id, date: addDays(todayIst(), -1), startTime: '09:00' });
    expect(past.status).toBe(400);
  });
});

describe('consultation, privacy and billing', () => {
  it('saves a consultation with a prescription, hides notes from front desk, bills with the follow-up fee and takes payment', async () => {
    const c = await clinic();
    const front = await c.as('Front Desk');
    const doctorUser = await c.as('Doctor');
    const p = (await front.api('POST', '/clinic/patients', patientBody())).body;
    expect(p.uhid).toBeTruthy();
    const walk = (await front.api('POST', '/clinic/appointments', { patientId: p.id, doctorId: c.doctor.id, walkIn: true })).body;

    // Front desk cannot start or read a consultation.
    expect((await front.api('POST', '/clinic/visits', { appointmentId: walk.id })).status).toBe(403);
    const visit = await doctorUser.api('POST', '/clinic/visits', { appointmentId: walk.id });
    expect(visit.status).toBe(201);
    expect((await doctorUser.api('POST', '/clinic/visits', { appointmentId: walk.id })).body.id).toBe(visit.body.id);
    const medRes = await c.api('POST', '/items', { name: 'Paracetamol 500', unit: 'NOS', gstRate: 5, hsnCode: '3004', salePrice: 20, trackStock: false });
    expect(medRes.status, JSON.stringify(medRes.body)).toBe(201);
    const med = medRes.body;

    const saved = await doctorUser.api('PATCH', `/clinic/visits/${visit.body.id}`, {
      vitals: { bpSys: 130, bpDia: 85, pulse: 78, tempC: 37.3, spo2: 98, weightKg: 72, heightCm: 172 },
      complaints: 'Fever for two days', findings: 'Throat congested', diagnosis: 'Viral fever', testsAdvised: 'CBC', advice: 'Rest and fluids',
      followupDate: addDays(todayIst(), 3),
      rx: [{ itemId: med.id, medicine: 'Paracetamol 500', dose: '1 tab', frequency: '1-1-1', days: 3, instructions: 'After food' },
        { medicine: 'ORS sachets', frequency: 'As needed', days: 3 }],
    });
    expect(saved.status).toBe(200);
    expect(saved.body.rx).toHaveLength(2);
    expect(saved.body.vitals.pulse).toBe(78);
    const stale = await doctorUser.api('PATCH', `/clinic/visits/${visit.body.id}`, { advice: 'x', expectedUpdatedAt: '2020-01-01T00:00:00Z' });
    expect(stale.status).toBe(409);

    // Front desk sees the visit header but no clinical text; lists carry none.
    const seen = await front.api('GET', `/clinic/visits/${visit.body.id}`);
    expect(seen.status).toBe(200);
    expect(seen.body.clinical).toBe(false);
    expect(JSON.stringify(seen.body)).not.toMatch(/Viral fever|Paracetamol|Fever for/);
    expect((await front.api('GET', `/clinic/visits/${visit.body.id}/prescription`)).status).toBe(403);
    expect((await front.api('PATCH', `/clinic/visits/${visit.body.id}`, { advice: 'no' })).status).toBe(403);
    const hist = await front.api('GET', `/clinic/patients/${p.id}/history`);
    expect(JSON.stringify(hist.body)).not.toMatch(/Viral fever/);
    expect(hist.body.visits).toHaveLength(1);
    const list = await front.api('GET', `/clinic/appointments?date=${todayIst()}`);
    expect(JSON.stringify(list.body)).not.toMatch(/Viral fever|Paracetamol/);
    expect((await doctorUser.api('GET', `/clinic/patients/${p.id}/history`)).body.visits[0].diagnosis).toBe('Viral fever');
    // Notes are not in the audit log.
    const audit = (await c.api('GET', '/audit?entity=clinic_visit')).body;
    expect(JSON.stringify(audit)).not.toMatch(/Viral fever|Paracetamol|Fever for/);

    const rx = (await doctorUser.api('GET', `/clinic/visits/${visit.body.id}/prescription`)).body;
    expect(rx.doctor.registrationNo).toBe('GMC-12345');
    expect(rx.clinic.name).toBe('Care Clinic');
    expect(rx.rx).toHaveLength(2);

    const done = await doctorUser.api('POST', `/clinic/visits/${visit.body.id}/complete`);
    expect(done.body.status).toBe('closed');
    expect((await front.api('GET', `/clinic/appointments?date=${todayIst()}`)).body.data[0].status).toBe('done');

    // Bill: consultation fee 500, plus a medicine line. Payment in full.
    const accounts = (await c.api('GET', '/accounts')).body.data as { id: string; subtype: string }[];
    const cash = accounts.find((a) => a.subtype === 'cash')!;
    const bill = await front.api('POST', `/clinic/visits/${visit.body.id}/bill`, {
      lines: [{ itemId: med.id, qty: 10 }], payment: { accountId: cash.id, mode: 'cash', amount: 100 },
    });
    expect(bill.status, JSON.stringify(bill.body)).toBe(201);
    expect(bill.body.feeKind).toBe('consultation');
    expect(bill.body.invoice.lines[0].rate).toBe(500);
    expect(bill.body.invoice.total).toBeGreaterThan(700);
    expect(bill.body.payment.amount).toBe(100);
    expect((await front.api('POST', `/clinic/visits/${visit.body.id}/bill`, {})).status).toBe(409);
    const inv = (await c.api('GET', `/invoices/${bill.body.invoice.id}`)).body;
    expect(inv.amountPaid).toBe(100);

    // Second visit inside the window is a follow-up at 200.
    const walk2 = (await front.api('POST', '/clinic/appointments', { patientId: p.id, doctorId: c.doctor.id, walkIn: true })).body;
    const v2 = (await doctorUser.api('POST', '/clinic/visits', { appointmentId: walk2.id })).body;
    const bill2 = await front.api('POST', `/clinic/visits/${v2.id}/bill`, {});
    expect(bill2.body.feeKind).toBe('follow_up');
    expect(bill2.body.invoice.lines[0].rate).toBe(200);
    expect(bill2.body.invoice.total).toBe(200);
    const h2 = (await front.api('GET', `/clinic/patients/${p.id}/history`)).body;
    expect(h2.visits.map((v: { feeKind: string }) => v.feeKind).sort()).toEqual(['consultation', 'follow_up']);
  });
});

describe('clinic permissions and roles', () => {
  it('limits setup to managers, gates billing and gives clinic roles the right permissions', async () => {
    const c = await clinic();
    const front = await c.as('Front Desk');
    const doctorUser = await c.as('Doctor');
    const p = (await c.api('POST', '/clinic/patients', patientBody())).body;
    expect((await front.api('POST', '/clinic/doctors', { name: 'Dr X', consultFee: 100 })).status).toBe(403);
    expect((await front.api('PATCH', `/clinic/doctors/${c.doctor.id}`, { consultFee: 900 })).status).toBe(403);
    expect((await doctorUser.api('POST', '/clinic/patients', patientBody({ name: 'Other', phone: '9000000001' }))).status).toBe(403);
    expect((await doctorUser.api('POST', '/clinic/appointments', { patientId: p.id, doctorId: c.doctor.id, walkIn: true })).status).toBe(403);
    expect((await front.api('GET', '/clinic/doctors')).body.data).toHaveLength(1);
    const roles = (await c.api('GET', '/roles')).body.data as { name: string; permissions: string[] }[];
    const perms = (n: string) => roles.find((r) => r.name === n)!.permissions;
    expect(perms('Front Desk')).toContain('clinic.front_desk');
    expect(perms('Front Desk')).not.toContain('clinic.consult');
    expect(perms('Doctor')).toContain('clinic.consult');
    expect(perms('Doctor')).not.toContain('clinic.manage');
    expect(perms('Administrator')).toContain('clinic.manage');
    expect(perms('Nurse')).toBeTruthy();
    expect(perms('Billing')).toContain('invoices.create');
    // The module is on by default for a clinic.
    const me = (await c.api('GET', '/me')).body;
    expect(me.companies[0].enabledModules).toContain('clinic');
    // A doctor linked to a user shows in the list; the same user cannot be linked twice.
    const linked = await c.api('POST', '/clinic/doctors', { name: 'Dr Linked', consultFee: 400, userId: doctorUser.userId });
    expect(linked.status).toBe(201);
    expect((await c.api('POST', '/clinic/doctors', { name: 'Dr Twice', consultFee: 400, userId: doctorUser.userId })).status).toBe(409);
    // Doctor without invoice permission cannot bill; unauthenticated is rejected.
    const walk = (await c.api('POST', '/clinic/appointments', { patientId: p.id, doctorId: c.doctor.id, walkIn: true })).body;
    const v = (await doctorUser.api('POST', '/clinic/visits', { appointmentId: walk.id })).body;
    const nurseLike = await c.as('Nurse');
    expect((await nurseLike.api('POST', `/clinic/visits/${v.id}/bill`, {})).status).toBe(403);
    expect((await client(env.app)('GET', '/clinic/patients')).status).toBe(401);
  });
});
