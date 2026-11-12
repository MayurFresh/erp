// Demo clinic data: two doctors, eight patients and today's queue. Not called from seed.ts; the lead wires it in.
import type { Tx } from './database.ts';
import { addDays, financialYear, todayIst } from '../lib/dates.ts';
import { nextNumber } from '../lib/series.ts';

export interface ClinicSeedWho { tenantId: string; companyId: string; userId: string }

const PATIENTS: { name: string; sex: 'male' | 'female'; age: number; phone: string; blood?: string; allergy?: string }[] = [
  { name: 'Ravi Shah', sex: 'male', age: 41, phone: '9825012345', blood: 'B+', allergy: 'Penicillin' },
  { name: 'Meena Patel', sex: 'female', age: 34, phone: '9825099999', blood: 'O+' },
  { name: 'Kiran Desai', sex: 'male', age: 58, phone: '9898012345', blood: 'A+' },
  { name: 'Fatima Sheikh', sex: 'female', age: 29, phone: '9904123456' },
  { name: 'Suresh Joshi', sex: 'male', age: 66, phone: '9427011223', blood: 'AB+', allergy: 'Sulfa drugs' },
  { name: 'Anita Trivedi', sex: 'female', age: 47, phone: '9879055667' },
  { name: 'Baby of Pooja Mehta', sex: 'female', age: 2, phone: '9712233445' },
  { name: 'Harish Parmar', sex: 'male', age: 52, phone: '9824456789', blood: 'B-' },
];

export async function seedClinicDemo(tx: Tx, { tenantId, companyId, userId }: ClinicSeedWho) {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', companyId).executeTakeFirstOrThrow();
  const week = [1, 2, 3, 4, 5, 6].map((day) => ({ day, from: '09:00', to: '13:00' }));
  const evening = [1, 2, 3, 4, 5].map((day) => ({ day, from: '17:00', to: '20:00' }));
  const docs = await tx.insertInto('clinic_doctors').values([
    { tenant_id: tenantId, company_id: companyId, name: 'Dr Anil Mehta', speciality: 'General medicine', registration_no: 'G-12345',
      consult_fee: 500, follow_up_fee: 250, follow_up_days: 7, slot_minutes: 15, working_hours: JSON.stringify([...week, ...evening]) },
    { tenant_id: tenantId, company_id: companyId, name: 'Dr Nisha Rao', speciality: 'Paediatrics', registration_no: 'G-23456',
      consult_fee: 600, follow_up_fee: 300, follow_up_days: 10, slot_minutes: 20, working_hours: JSON.stringify(week) },
  ]).returning(['id', 'name']).execute();

  const fy = financialYear(todayIst());
  const patients: { id: string; name: string }[] = [];
  for (const p of PATIENTS) {
    const party = await tx.insertInto('parties').values({
      tenant_id: tenantId, company_id: companyId, type: 'customer', name: p.name, phone: p.phone, state_code: company.state_code,
      address: null, gstin: null, email: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
    }).returning('id').executeTakeFirstOrThrow();
    const row = await tx.insertInto('clinic_patients').values({
      tenant_id: tenantId, company_id: companyId, party_id: party.id, uhid: await nextNumber(tx, { tenantId, companyId }, 'patient', fy),
      name: p.name, sex: p.sex, age_years: p.age, phone: p.phone, blood_group: p.blood ?? null, allergies: p.allergy ?? null, created_by: userId,
    }).returning(['id', 'name']).executeTakeFirstOrThrow();
    patients.push(row);
  }

  // Today's queue for the first doctor: two arrived, one in consultation, two booked for later.
  const today = todayIst();
  const [gp, paed] = docs;
  const rows = [
    { doc: gp!, p: patients[0]!, kind: 'walk_in', status: 'in_consultation', token: 1, start: null as string | null },
    { doc: gp!, p: patients[2]!, kind: 'walk_in', status: 'arrived', token: 2, start: null },
    { doc: gp!, p: patients[4]!, kind: 'booked', status: 'arrived', token: 3, start: '09:30' },
    { doc: gp!, p: patients[5]!, kind: 'booked', status: 'booked', token: null, start: '10:00' },
    { doc: gp!, p: patients[7]!, kind: 'booked', status: 'booked', token: null, start: '10:15' },
    { doc: paed!, p: patients[6]!, kind: 'booked', status: 'arrived', token: 1, start: '09:20' },
    { doc: paed!, p: patients[3]!, kind: 'booked', status: 'booked', token: null, start: '09:40' },
  ];
  const slot = (doc: { name: string }) => (doc.name.includes('Rao') ? 20 : 15);
  for (const r of rows) {
    let end: string | null = null;
    if (r.start) {
      const m = Number(r.start.slice(0, 2)) * 60 + Number(r.start.slice(3)) + slot(r.doc);
      end = `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
    }
    await tx.insertInto('clinic_appointments').values({
      tenant_id: tenantId, company_id: companyId, patient_id: r.p.id, doctor_id: r.doc.id, appt_date: today, start_time: r.start, end_time: end,
      token_no: r.token, kind: r.kind, status: r.status, reason: 'Fever and cough', arrived_at: r.status === 'booked' ? null : new Date(),
      created_by: userId,
    }).execute();
  }
  // One past, closed visit for the first patient with a prescription, so the history screen has content.
  const visitDate = addDays(today, -3);
  const appt = await tx.insertInto('clinic_appointments').values({
    tenant_id: tenantId, company_id: companyId, patient_id: patients[0]!.id, doctor_id: gp!.id, appt_date: visitDate,
    start_time: '09:00', end_time: '09:15', kind: 'booked', status: 'done', reason: 'Fever', arrived_at: new Date(), created_by: userId,
  }).returning('id').executeTakeFirstOrThrow();
  const visit = await tx.insertInto('clinic_visits').values({
    tenant_id: tenantId, company_id: companyId, appointment_id: appt.id, patient_id: patients[0]!.id, doctor_id: gp!.id,
    visit_date: visitDate, status: 'closed', vitals: JSON.stringify({ bpSys: 128, bpDia: 82, pulse: 80, tempC: 38.1, spo2: 98, weightKg: 74 }),
    complaints: 'Fever and body ache for two days', findings: 'Throat congested, chest clear', diagnosis: 'Viral fever',
    tests_advised: 'CBC if fever persists', advice: 'Rest, fluids, light diet', followup_date: addDays(visitDate, 5), fee_kind: 'consultation',
    created_by: userId, closed_at: new Date(),
  }).returning('id').executeTakeFirstOrThrow();
  await tx.insertInto('clinic_rx_lines').values([
    { tenant_id: tenantId, visit_id: visit.id, line_no: 1, medicine: 'Paracetamol 500 mg', dose: '1 tablet', frequency: 'Three times a day', days: 3, instructions: 'After food' },
    { tenant_id: tenantId, visit_id: visit.id, line_no: 2, medicine: 'Cetirizine 10 mg', dose: '1 tablet', frequency: 'At night', days: 3, instructions: null },
  ]).execute();
  await seedClinicIpd(tx, { tenantId, companyId, userId }, docs[0]!.id, patients[1]!.id);
}

/** Wards, beds and one admitted patient (two nights in, with a deposit and a few charges). */
export async function seedClinicIpd(tx: Tx, { tenantId, companyId, userId }: ClinicSeedWho, doctorId: string, patientId: string) {
  const wardDefs: { name: string; kind: string; beds: [string, number][] }[] = [
    { name: 'General ward', kind: 'general', beds: [['G1', 1200], ['G2', 1200], ['G3', 1200], ['G4', 1200]] },
    { name: 'Semi-private', kind: 'semi_private', beds: [['S1', 2200], ['S2', 2200]] },
    { name: 'Private rooms', kind: 'private', beds: [['P1', 3500], ['P2', 3500]] },
    { name: 'ICU', kind: 'icu', beds: [['ICU1', 6000], ['ICU2', 6000]] },
  ];
  const beds: Record<string, { id: string; rate: number; ward: string }> = {};
  let order = 0;
  for (const w of wardDefs) {
    const ward = await tx.insertInto('clinic_wards').values({ tenant_id: tenantId, company_id: companyId, name: w.name, kind: w.kind, sort_order: order += 1 })
      .returning('id').executeTakeFirstOrThrow();
    for (const [no, rate] of w.beds) {
      const bed = await tx.insertInto('clinic_beds').values({ tenant_id: tenantId, company_id: companyId, ward_id: ward.id, bed_no: no, daily_rate: rate })
        .returning('id').executeTakeFirstOrThrow();
      beds[no] = { id: bed.id, rate, ward: w.name };
    }
  }
  const today = todayIst();
  const from = addDays(today, -2);
  const adm = await tx.insertInto('clinic_admissions').values({
    tenant_id: tenantId, company_id: companyId, admission_no: await nextNumber(tx, { tenantId, companyId }, 'admission', financialYear(today)),
    patient_id: patientId, doctor_id: doctorId, bed_id: beds.S1!.id, admit_date: from, expected_days: 4,
    provisional_diagnosis: 'Acute gastroenteritis with dehydration', created_by: userId,
  }).returning('id').executeTakeFirstOrThrow();
  const stay = await tx.insertInto('clinic_bed_stays').values({ tenant_id: tenantId, admission_id: adm.id, bed_id: beds.S1!.id, from_date: from, daily_rate: beds.S1!.rate })
    .returning('id').executeTakeFirstOrThrow();
  await tx.updateTable('clinic_beds').set({ status: 'occupied' }).where('id', '=', beds.S1!.id).execute();
  const charge = (date: string, kind: string, description: string, qty: number, rate: number, stayId: string | null = null) => ({
    tenant_id: tenantId, admission_id: adm.id, charge_date: date, kind, description, qty, rate, amount: qty * rate, bed_stay_id: stayId, created_by: userId,
  });
  await tx.insertInto('clinic_ipd_charges').values([
    charge(from, 'bed', 'Bed S1, Semi-private', 1, 2200, stay.id), charge(addDays(from, 1), 'bed', 'Bed S1, Semi-private', 1, 2200, stay.id),
    charge(today, 'bed', 'Bed S1, Semi-private', 1, 2200, stay.id),
    charge(from, 'service', 'IV cannulation and fluids set-up', 1, 350), charge(addDays(from, 1), 'service', 'Doctor visit', 2, 600),
    charge(addDays(from, 1), 'medicine', 'Inj Ondansetron 4 mg', 3, 45), charge(today, 'medicine', 'ORS sachets', 6, 20),
  ]).execute();
}
