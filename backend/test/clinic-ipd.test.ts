import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { sql } from 'kysely';
import { withTenant } from '../src/db/database.ts';
import { addDays, todayIst } from '../src/lib/dates.ts';
import { client, setupTestApp, teardown, uniqueEmail, type TestEnv } from './helpers.ts';

let env: TestEnv;
beforeAll(async () => { env = await setupTestApp(); });
afterAll(async () => { await teardown(env); });

async function hospital() {
  const res = await client(env.app)('POST', '/auth/signup', {
    businessName: 'City Hospital', name: 'Owner', email: uniqueEmail('ipd'), password: 'Secret@123', stateCode: '24', businessType: 'hospital',
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
    expect((await api('POST', '/users', { name: roleName, email, password: 'Secret@123', roleId: role.id })).status).toBe(201);
    const li = await client(env.app)('POST', '/auth/login', { email, password: 'Secret@123' });
    return client(env.app, li.body.accessToken, companyId);
  };
  const doctor = (await api('POST', '/clinic/doctors', {
    name: 'Dr Mehta', consultFee: 500, followUpFee: 200, followUpDays: 7, slotMinutes: 15, workingHours: [],
  })).body;
  const ward = (await api('POST', '/clinic/ipd/wards', { name: 'General ward', kind: 'general' })).body;
  const pvt = (await api('POST', '/clinic/ipd/wards', { name: 'Private', kind: 'private' })).body;
  const bed = async (wardId: string, bedNo: string, dailyRate: number) => (await api('POST', '/clinic/ipd/beds', { wardId, bedNo, dailyRate })).body;
  const accounts = (await api('GET', '/accounts')).body.data as { id: string; subtype: string }[];
  const cash = accounts.find((a) => a.subtype === 'cash')!;
  const patient = async (name: string, phone: string) => (await api('POST', '/clinic/patients', { name, sex: 'male', ageYears: 40, phone })).body;
  const tenantId = JSON.parse(Buffer.from(res.body.accessToken.split('.')[1], 'base64url').toString()).tid as string;
  return { api, as, doctor, ward, pvt, bed, cash, patient, tenantId };
}

describe('clinic IPD', () => {
  it('admits to a bed, blocks double booking, transfers, charges and discharges with a GST-exempt bill and deposits adjusted', async () => {
    const h = await hospital();
    const b1 = await h.bed(h.ward.id, 'G1', 1000);
    const b2 = await h.bed(h.pvt.id, 'P1', 3000);
    expect((await h.api('POST', '/clinic/ipd/beds', { wardId: h.ward.id, bedNo: 'g1', dailyRate: 5 })).status).toBe(409);
    const p1 = await h.patient('Ravi Shah', '9825012345');
    const p2 = await h.patient('Meena Patel', '9825099999');

    const adm = await h.api('POST', '/clinic/ipd/admissions', {
      patientId: p1.id, doctorId: h.doctor.id, bedId: b1.id, provisionalDiagnosis: 'Dengue',
      deposit: { accountId: h.cash.id, mode: 'cash', amount: 5000 },
    });
    expect(adm.status, JSON.stringify(adm.body)).toBe(201);
    expect(adm.body.number).toMatch(/^IPD\/\d{2}-\d{2}\/00001$/);
    expect(adm.body.totals).toMatchObject({ bed: 1000, deposits: 5000, balance: -4000 });
    expect(adm.body.provisionalDiagnosis).toBe('Dengue');

    expect((await h.api('POST', '/clinic/ipd/admissions', { patientId: p2.id, doctorId: h.doctor.id, bedId: b1.id })).body.error?.code).toBe('BED_TAKEN');
    expect((await h.api('POST', '/clinic/ipd/admissions', { patientId: p1.id, doctorId: h.doctor.id, bedId: b2.id })).body.error?.code).toBe('ALREADY_ADMITTED');

    let board = (await h.api('GET', '/clinic/ipd/board')).body;
    expect(board.counts).toMatchObject({ total: 2, occupied: 1, available: 1 });
    expect(board.wards[0].beds[0].admission.patientName).toBe('Ravi Shah');

    // Same-day transfer moves the day's charge to the new bed.
    const tr = await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/transfer`, { bedId: b2.id, reason: 'Wants a private room' });
    expect(tr.status, JSON.stringify(tr.body)).toBe(200);
    expect(tr.body.bed.bedNo).toBe('P1');
    expect(tr.body.totals.bed).toBe(3000);
    board = (await h.api('GET', '/clinic/ipd/board')).body;
    expect(board.counts).toMatchObject({ occupied: 1, cleaning: 1 });
    expect((await h.api('PATCH', `/clinic/ipd/beds/${b1.id}`, { status: 'available' })).status).toBe(200);
    expect((await h.api('PATCH', `/clinic/ipd/beds/${b2.id}`, { status: 'available' })).status).toBe(409);
    // Posting again the same day adds nothing.
    expect((await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/bed-charges`)).body.added).toBe(0);

    // A service and a medicine; the medicine item keeps its own tax rate.
    const medRes = (await h.api('POST', '/items', { name: 'Inj Ceftriaxone', unit: 'NOS', gstRate: 5, hsnCode: '3004', salePrice: 100, trackStock: false }));
    expect(medRes.status, JSON.stringify(medRes.body)).toBe(201);
    const med = medRes.body;
    const add1 = await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/charges`, { kind: 'service', description: 'Doctor visit', qty: 1, rate: 800 });
    expect(add1.status, JSON.stringify(add1.body)).toBe(201);
    const add2 = await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/charges`, { kind: 'medicine', itemId: med.id, qty: 4 });
    expect(add2.status, JSON.stringify(add2.body)).toBe(201);
    expect(add2.body.totals).toMatchObject({ service: 800, medicine: 400, bed: 3000, total: 4200 });
    const wrong = add2.body.charges.find((c: { description: string }) => c.description === 'Doctor visit');
    const voided = await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/charges/${wrong.id}/void`, { reason: 'Entered twice' });
    expect(voided.body.totals.service).toBe(0);
    const bedCharge = add2.body.charges.find((c: { kind: string; isVoid: boolean }) => c.kind === 'bed' && !c.isVoid);
    expect((await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/charges/${bedCharge.id}/void`, { reason: 'x' })).status).toBe(400);

    // Discharge needs a summary.
    const noSum = await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/discharge`, {});
    expect(noSum.status).toBe(400);
    const out = await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/discharge`, {
      diagnosis: 'Dengue fever', treatment: 'IV fluids, antibiotics', advice: 'Rest', condition: 'Stable', followupDate: todayIst(),
    });
    expect(out.status, JSON.stringify(out.body)).toBe(200);
    // 3000 bed + 400 medicine + 5% GST on medicine = 3420. Bed days are GST exempt.
    expect(out.body.invoice.total).toBe(3420);
    expect(out.body.depositsApplied).toBe(3420);
    expect(out.body.balanceDue).toBe(0);
    expect(out.body.refundDue).toBe(1580);
    const inv = (await h.api('GET', `/invoices/${out.body.invoice.id}`)).body;
    expect(inv.amountPaid).toBe(3420);
    expect(inv.taxTotal).toBe(20);
    const bedLine = inv.lines.find((l: { description: string }) => l.description.startsWith('Bed P1'));
    expect(bedLine.gstRate).toBe(0);
    expect(out.body.admission.status).toBe('discharged');
    expect((await h.api('POST', `/clinic/ipd/admissions/${adm.body.id}/discharge`, {})).body.error?.code).toBe('NOT_ADMITTED');
    board = (await h.api('GET', '/clinic/ipd/board')).body;
    expect(board.counts.cleaning).toBe(1);
    expect(board.admitted).toBe(0);

    const sum = (await h.api('GET', `/clinic/ipd/admissions/${adm.body.id}/discharge-summary`)).body;
    expect(sum.summary.diagnosis).toBe('Dengue fever');
    expect(sum.patient.uhid).toMatch(/^UHID/);
    expect(sum.medicines[0].name).toBe('Inj Ceftriaxone');
  });

  it('takes a later deposit, collects the balance at discharge and refuses unpaid balance unless credit is allowed', async () => {
    const h = await hospital();
    const bed = await h.bed(h.ward.id, 'G1', 1500);
    const p = await h.patient('Kiran Desai', '9898012345');
    const adm = (await h.api('POST', '/clinic/ipd/admissions', { patientId: p.id, doctorId: h.doctor.id, bedId: bed.id })).body;
    const dep = await h.api('POST', `/clinic/ipd/admissions/${adm.id}/deposits`, { accountId: h.cash.id, mode: 'upi', amount: 500 });
    expect(dep.status).toBe(201);
    expect(dep.body.deposits).toHaveLength(1);
    await h.api('POST', `/clinic/ipd/admissions/${adm.id}/charges`, { kind: 'service', description: 'Dressing', qty: 2, rate: 100 });
    const summary = { diagnosis: 'Fracture', treatment: 'Cast' };
    const due = await h.api('POST', `/clinic/ipd/admissions/${adm.id}/discharge`, summary);
    expect(due.status).toBe(409);
    expect(due.body.error.code).toBe('BALANCE_DUE');
    expect(due.body.error.details.due).toBe(1200);
    const ok = await h.api('POST', `/clinic/ipd/admissions/${adm.id}/discharge`, { ...summary, payment: { accountId: h.cash.id, mode: 'cash', amount: 1200 } });
    expect(ok.status, JSON.stringify(ok.body)).toBe(200);
    expect(ok.body.balanceDue).toBe(0);
    const inv = (await h.api('GET', `/invoices/${ok.body.invoice.id}`)).body;
    expect(inv.amountPaid).toBe(1700);
  });

  it('keeps clinical text from staff without clinic.consult and enforces roles', async () => {
    const h = await hospital();
    const bed = await h.bed(h.ward.id, 'G1', 1000);
    const bed2 = await h.bed(h.ward.id, 'G2', 1000);
    const p = await h.patient('Suresh Joshi', '9427011223');
    const front = await h.as('Front Desk');
    const nurse = await h.as('Nurse');
    const pharm = await h.as('Pharmacist');
    expect((await pharm('GET', '/clinic/ipd/board')).status).toBe(403);
    expect((await nurse('POST', '/clinic/ipd/admissions', { patientId: p.id, doctorId: h.doctor.id, bedId: bed.id })).status).toBe(403);
    expect((await nurse('POST', '/clinic/ipd/wards', { name: 'X' })).status).toBe(403);
    const adm = await front('POST', '/clinic/ipd/admissions', { patientId: p.id, doctorId: h.doctor.id, bedId: bed.id, provisionalDiagnosis: 'x' });
    expect(adm.status).toBe(400);
    const ok = await front('POST', '/clinic/ipd/admissions', { patientId: p.id, doctorId: h.doctor.id, bedId: bed.id });
    expect(ok.status, JSON.stringify(ok.body)).toBe(201);
    expect(ok.body.summary).toBeUndefined();
    // The nurse may add charges but not discharge; front desk cannot write the summary.
    expect((await nurse('POST', `/clinic/ipd/admissions/${ok.body.id}/charges`, { kind: 'service', description: 'Nebulisation', rate: 150 })).status).toBe(201);
    expect((await nurse('POST', `/clinic/ipd/admissions/${ok.body.id}/discharge`, {})).status).toBe(403);
    expect((await front('PATCH', `/clinic/ipd/admissions/${ok.body.id}/summary`, { diagnosis: 'Asthma' })).status).toBe(403);
    expect((await front('POST', `/clinic/ipd/admissions/${ok.body.id}/discharge`, { diagnosis: 'Asthma', treatment: 'x' })).status).toBe(403);
    const owner = await h.api('PATCH', `/clinic/ipd/admissions/${ok.body.id}/summary`, { diagnosis: 'Asthma', treatment: 'Nebulisation' });
    expect(owner.body.summary.diagnosis).toBe('Asthma');
    expect((await front('GET', `/clinic/ipd/admissions/${ok.body.id}`)).body.summary).toBeUndefined();
    expect((await front('GET', `/clinic/ipd/admissions?status=admitted`)).body.total).toBe(1);
    // Settings routes also answer to PUT.
    expect((await h.api('PUT', `/clinic/ipd/beds/${bed2.id}`, { dailyRate: 1200 })).status).toBe(200);
    // Ward in use cannot be switched off.
    expect((await h.api('PATCH', `/clinic/ipd/wards/${h.ward.id}`, { isActive: false })).body.error?.code).toBe('WARD_IN_USE');
  });
});

describe('clinic IPD stays, bills and refunds', () => {
  async function admitted(h: Awaited<ReturnType<typeof hospital>>, rate = 1000, deposit = 0) {
    const bed = await h.bed(h.ward.id, `A${Math.random().toString(36).slice(2, 6)}`, rate);
    const p = await h.patient(`Pat ${Math.random().toString(36).slice(2, 7)}`, '98250' + String(Math.floor(10000 + Math.random() * 89999)));
    const res = await h.api('POST', '/clinic/ipd/admissions', {
      patientId: p.id, doctorId: h.doctor.id, bedId: bed.id, ...(deposit ? { deposit: { accountId: h.cash.id, mode: 'cash', amount: deposit } } : {}),
    });
    expect(res.status, JSON.stringify(res.body)).toBe(201);
    return { adm: res.body, bed, p };
  }
  const summary = { diagnosis: 'Fever', treatment: 'Fluids' };

  it('splits bed charges by bed across days, frees the old bed and refuses a double booking', async () => {
    const h = await hospital();
    const { adm, bed } = await admitted(h, 1000);
    const bed2 = await h.bed(h.pvt.id, 'P9', 3000);
    const today = todayIst();
    // Pretend the patient came three days ago.
    await withTenant(env.db, h.tenantId, async (tx) => {
      await sql`update clinic_admissions set admit_date = ${addDays(today, -3)} where id = ${adm.id}`.execute(tx);
      await sql`update clinic_bed_stays set from_date = ${addDays(today, -3)} where admission_id = ${adm.id}`.execute(tx);
      await sql`delete from clinic_ipd_charges where admission_id = ${adm.id}`.execute(tx);
    });
    const tr = await h.api('POST', `/clinic/ipd/admissions/${adm.id}/transfer`, { bedId: bed2.id });
    expect(tr.status, JSON.stringify(tr.body)).toBe(200);
    const bedCharges = tr.body.charges.filter((c: { kind: string }) => c.kind === 'bed');
    expect(bedCharges.filter((c: { rate: number }) => c.rate === 1000)).toHaveLength(3);
    expect(bedCharges.filter((c: { rate: number }) => c.rate === 3000)).toHaveLength(1);
    expect(tr.body.stays).toHaveLength(2);
    expect(tr.body.stays[0].toDate).toBe(today);
    let wards = (await h.api('GET', '/clinic/ipd/wards')).body.data;
    const status = (id: string) => wards.flatMap((w: { beds: { id: string; status: string }[] }) => w.beds).find((b: { id: string }) => b.id === id).status;
    expect(status(bed.id)).toBe('cleaning');
    expect(status(bed2.id)).toBe('occupied');
    // Not free until cleaned, then it can be booked again, but only once.
    const p2 = await h.patient('Second Patient', '9811100001');
    const p3 = await h.patient('Third Patient', '9811100002');
    expect((await h.api('POST', '/clinic/ipd/admissions', { patientId: p2.id, doctorId: h.doctor.id, bedId: bed.id })).body.error?.code).toBe('BED_TAKEN');
    await h.api('PATCH', `/clinic/ipd/beds/${bed.id}`, { status: 'available' });
    expect((await h.api('POST', '/clinic/ipd/admissions', { patientId: p2.id, doctorId: h.doctor.id, bedId: bed.id })).status).toBe(201);
    expect((await h.api('POST', '/clinic/ipd/admissions', { patientId: p3.id, doctorId: h.doctor.id, bedId: bed.id })).body.error?.code).toBe('BED_TAKEN');
    // Concurrent admissions into one bed: exactly one wins.
    const bed3 = await h.bed(h.ward.id, 'C1', 500);
    const p4 = await h.patient('Fourth Patient', '9811100003');
    const p5 = await h.patient('Fifth Patient', '9811100004');
    const race = await Promise.all([p4, p5].map((p) => h.api('POST', '/clinic/ipd/admissions', { patientId: p.id, doctorId: h.doctor.id, bedId: bed3.id })));
    expect(race.map((r) => r.status).sort()).toEqual([201, 409]);
    wards = (await h.api('GET', '/clinic/ipd/wards')).body.data;
    expect(status(bed3.id)).toBe('occupied');
  });

  it('discharge with deposit above, equal to and below the bill', async () => {
    const h = await hospital();
    // Bill: one bed day of 1000 (exempt).
    const over = await admitted(h, 1000, 1500);
    const o = await h.api('POST', `/clinic/ipd/admissions/${over.adm.id}/discharge`, summary);
    expect(o.status, JSON.stringify(o.body)).toBe(200);
    expect(o.body.invoice.total).toBe(1000);
    expect(o.body.refundDue).toBe(500);
    expect(o.body.admission.refundDue).toBe(500);

    const equal = await admitted(h, 1000, 1000);
    const e = await h.api('POST', `/clinic/ipd/admissions/${equal.adm.id}/discharge`, summary);
    expect(e.body.balanceDue).toBe(0);
    expect(e.body.refundDue).toBe(0);
    expect((await h.api('GET', `/invoices/${e.body.invoice.id}`)).body.amountPaid).toBe(1000);

    const under = await admitted(h, 1000, 400);
    const noCredit = await h.api('POST', `/clinic/ipd/admissions/${under.adm.id}/discharge`, summary);
    expect(noCredit.body.error.code).toBe('BALANCE_DUE');
    expect(noCredit.body.error.details.due).toBe(600);
    const u = await h.api('POST', `/clinic/ipd/admissions/${under.adm.id}/discharge`, { ...summary, allowCredit: true });
    expect(u.status).toBe(200);
    expect(u.body.balanceDue).toBe(600);
    expect(u.body.refundDue).toBe(0);
    const inv = (await h.api('GET', `/invoices/${u.body.invoice.id}`)).body;
    expect(inv.total - inv.amountPaid).toBe(600);
    // Nothing to refund when the bill used the whole deposit.
    const none = await h.api('POST', `/clinic/ipd/admissions/${under.adm.id}/refund`, { accountId: h.cash.id, mode: 'cash', amount: 1 });
    expect(none.status).toBe(400);
  });

  it('refunds leftover deposit once, never more than is due, and audits it', async () => {
    const h = await hospital();
    const { adm } = await admitted(h, 1000, 1500);
    const body = { accountId: h.cash.id, mode: 'cash', amount: 200 };
    expect((await h.api('POST', `/clinic/ipd/admissions/${adm.id}/refund`, body)).body.error?.code).toBe('NOT_DISCHARGED');
    await h.api('POST', `/clinic/ipd/admissions/${adm.id}/discharge`, summary);
    expect((await h.api('POST', `/clinic/ipd/admissions/${adm.id}/refund`, { ...body, amount: 501 })).status).toBe(400);
    const front = await h.as('Front Desk');
    const first = await front('POST', `/clinic/ipd/admissions/${adm.id}/refund`, { ...body, reference: 'UTR1' });
    expect(first.status, JSON.stringify(first.body)).toBe(201);
    expect(first.body.refundDue).toBe(300);
    expect((await h.api('POST', `/clinic/ipd/admissions/${adm.id}/refund`, { ...body, amount: 301 })).status).toBe(400);
    const last = await h.api('POST', `/clinic/ipd/admissions/${adm.id}/refund`, { ...body, amount: 300 });
    expect(last.body.refundDue).toBe(0);
    const pays = (await h.api('GET', '/payments?kind=payment')).body.data as { amount: number; notes: string }[];
    expect(pays.filter((p) => p.notes?.startsWith('Deposit refund')).map((p) => p.amount).sort()).toEqual([200, 300]);
    const audit = await h.api('GET', `/audit?entityType=clinic_admission&entityId=${adm.id}`);
    if (audit.status === 200) expect(JSON.stringify(audit.body)).toContain('refund');
  });
});
