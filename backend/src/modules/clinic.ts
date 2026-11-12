import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import { createPayment } from './payments.ts';
import { documentRoute } from '../lib/openapi.ts';

/*
 * Clinic and hospital OPD. Clinical text (vitals, notes, diagnosis, prescriptions, patient notes) is returned
 * only to users with clinic.consult and is never written to the audit log; audit entries list field names only.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const timeField = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/, 'Use HH:MM');
const SEXES = ['male', 'female', 'other'] as const;
const BLOOD = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'] as const;
const APPT_STATUSES = ['booked', 'arrived', 'in_consultation', 'done', 'cancelled', 'no_show'] as const;
const LIVE = ['booked', 'arrived', 'in_consultation', 'done'];
const STATUS_ORDER = ['in_consultation', 'arrived', 'booked', 'done', 'no_show', 'cancelled'];
const round2 = (n: number) => Math.round(n * 100) / 100;
const blank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? undefined : v);

const phoneField = z.string().trim().min(5, 'Enter a phone number').max(20).regex(/^[0-9+() -]+$/, 'Digits only');
const patientFields = {
  name: z.string().trim().min(1, 'Required').max(200),
  sex: z.enum(SEXES),
  dob: z.preprocess(blank, dateField.optional()),
  ageYears: z.preprocess(blank, z.coerce.number().int().min(0).max(130).optional()),
  phone: phoneField,
  address: optionalText(500),
  bloodGroup: z.preprocess(blank, z.enum(BLOOD).optional()),
  allergies: optionalText(500),
  emergencyName: optionalText(100),
  emergencyPhone: optionalText(20),
  notes: optionalText(2000),
};
const patientCreate = z.object(patientFields).extend({ force: z.boolean().optional() })
  .refine((b) => b.dob || b.ageYears !== undefined, { message: 'Give a date of birth or an age', path: ['dob'] });
const patientPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: patientFields.name.optional(), sex: z.enum(SEXES).optional(),
  dob: z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional()),
  ageYears: z.preprocess((v) => (v === '' ? null : v), z.coerce.number().int().min(0).max(130).nullable().optional()),
  phone: phoneField.optional(), address: nullableText(500),
  bloodGroup: z.preprocess((v) => (v === '' ? null : v), z.enum(BLOOD).nullable().optional()),
  allergies: nullableText(500), emergencyName: nullableText(100), emergencyPhone: nullableText(20), notes: nullableText(2000),
});

const hoursField = z.array(z.object({ day: z.number().int().min(0).max(6), from: timeField, to: timeField })
  .refine((h) => h.from < h.to, 'End must be after start')).max(28);
const doctorFields = {
  name: z.string().trim().min(1, 'Required').max(120),
  userId: z.uuid().nullable().optional(),
  speciality: nullableText(100),
  registrationNo: nullableText(60),
  consultFee: moneyField,
  followUpFee: moneyField,
  followUpDays: z.coerce.number().int().min(0).max(365),
  slotMinutes: z.coerce.number().int().min(5).max(240),
  workingHours: hoursField,
  isActive: z.boolean(),
};
const doctorCreate = z.object({
  ...doctorFields,
  followUpFee: doctorFields.followUpFee.default(0), followUpDays: doctorFields.followUpDays.default(7),
  slotMinutes: doctorFields.slotMinutes.default(15), workingHours: doctorFields.workingHours.default([]),
  isActive: doctorFields.isActive.default(true),
});
const doctorPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  name: doctorFields.name.optional(), userId: doctorFields.userId, speciality: doctorFields.speciality,
  registrationNo: doctorFields.registrationNo, consultFee: doctorFields.consultFee.optional(),
  followUpFee: doctorFields.followUpFee.optional(), followUpDays: doctorFields.followUpDays.optional(),
  slotMinutes: doctorFields.slotMinutes.optional(), workingHours: doctorFields.workingHours.optional(),
  isActive: doctorFields.isActive.optional(),
});

const apptCreate = z.object({
  patientId: z.uuid(), doctorId: z.uuid(),
  date: dateField.optional(), startTime: timeField.optional(), walkIn: z.boolean().optional(), reason: optionalText(300),
});
const apptStatus = z.object({ status: z.enum(['arrived', 'cancelled', 'no_show']), reason: optionalText(300) });
const apptReschedule = z.object({ date: dateField, startTime: timeField, doctorId: z.uuid().optional() });
const apptList = z.object({
  date: dateField.optional(), doctorId: z.uuid().optional(), patientId: z.uuid().optional(), status: z.enum(APPT_STATUSES).optional(),
});

const optNum = (max: number) => z.preprocess((v) => (v === '' || v === null ? undefined : v), z.coerce.number().min(0).max(max).optional());
const vitalsField = z.object({
  bpSys: optNum(300), bpDia: optNum(200), pulse: optNum(300), tempC: optNum(50), spo2: optNum(100), weightKg: optNum(700), heightCm: optNum(300),
}).partial();
const rxLine = z.object({
  itemId: z.uuid().nullable().optional(),
  medicine: z.string().trim().min(1, 'Name the medicine').max(200),
  dose: optionalText(60), frequency: optionalText(60),
  days: z.preprocess((v) => (v === '' || v === null ? undefined : v), z.coerce.number().int().min(1).max(3650).optional()),
  instructions: optionalText(200),
});
const visitStart = z.union([z.object({ appointmentId: z.uuid() }), z.object({ patientId: z.uuid(), doctorId: z.uuid() })]);
const visitPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  vitals: vitalsField.optional(),
  complaints: nullableText(2000), findings: nullableText(2000), diagnosis: nullableText(1000),
  testsAdvised: nullableText(1000), advice: nullableText(2000),
  followupDate: z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional()),
  rx: z.array(rxLine).max(60).optional(),
});
const billBody = z.object({
  locationId: z.uuid().optional(),
  includeConsultation: z.boolean().optional(),
  lines: z.array(z.object({
    itemId: z.uuid(), qty: qtyField.refine((v) => v > 0, 'Must be more than zero'),
    rate: moneyField.optional(), discountPct: percentField.optional(), description: optionalText(300),
  })).max(100).default([]),
  payment: z.object({
    accountId: z.uuid(), mode: z.enum(['cash', 'bank', 'upi', 'cheque', 'card']),
    amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), reference: optionalText(60),
  }).optional(),
});

// Helpers ---------------------------------------------------------------------------------------

const hm = (t: string | null) => (t ? t.slice(0, 5) : null);
const toMin = (t: string) => Number(t.slice(0, 2)) * 60 + Number(t.slice(3, 5));
const fromMin = (m: number) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`;
const weekday = (date: string) => new Date(`${date}T00:00:00Z`).getUTCDay();

interface Hours { day: number; from: string; to: string }

function ageOf(p: { dob: string | null; age_years: number | null; created_at: Date }): number | null {
  const today = todayIst();
  if (p.dob) {
    let a = Number(today.slice(0, 4)) - Number(p.dob.slice(0, 4));
    if (today.slice(5) < p.dob.slice(5)) a -= 1;
    return Math.max(a, 0);
  }
  if (p.age_years === null) return null;
  return p.age_years + (Number(today.slice(0, 4)) - new Date(p.created_at).getUTCFullYear());
}

function patientJson(p: Awaited<ReturnType<typeof loadPatientRow>>, canNotes: boolean) {
  return {
    id: p.id, partyId: p.party_id, uhid: p.uhid, name: p.name, sex: p.sex, dob: p.dob, ageYears: ageOf(p), phone: p.phone,
    address: p.address, bloodGroup: p.blood_group, allergies: p.allergies, emergencyName: p.emergency_name,
    emergencyPhone: p.emergency_phone, ...(canNotes ? { notes: p.notes } : {}), isActive: p.is_active,
    createdAt: p.created_at, updatedAt: p.updated_at,
  };
}
const patientBrief = (p: { id: string; uhid: string; name: string; phone: string; sex: string; dob: string | null; age_years: number | null; created_at: Date }) =>
  ({ id: p.id, uhid: p.uhid, name: p.name, phone: p.phone, sex: p.sex, ageYears: ageOf(p) });

async function loadPatientRow(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('clinic_patients').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Patient');
  return row;
}

async function loadDoctorRow(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('clinic_doctors').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Doctor');
  return row;
}

function doctorJson(d: Awaited<ReturnType<typeof loadDoctorRow>>) {
  return {
    id: d.id, userId: d.user_id, name: d.name, speciality: d.speciality, registrationNo: d.registration_no,
    consultFee: d.consult_fee, followUpFee: d.follow_up_fee, followUpDays: d.follow_up_days, slotMinutes: d.slot_minutes,
    workingHours: d.working_hours as Hours[], isActive: d.is_active, updatedAt: d.updated_at,
  };
}

function apptSelect(tx: Tx) {
  return tx.selectFrom('clinic_appointments as a')
    .innerJoin('clinic_patients as p', 'p.id', 'a.patient_id')
    .innerJoin('clinic_doctors as d', 'd.id', 'a.doctor_id')
    .leftJoin('clinic_visits as v', 'v.appointment_id', 'a.id')
    .leftJoin('invoices as i', 'i.id', 'v.invoice_id')
    .select(['a.id', 'a.appt_date', 'a.start_time', 'a.end_time', 'a.token_no', 'a.kind', 'a.status', 'a.reason', 'a.cancel_reason',
      'a.arrived_at', 'a.updated_at', 'a.patient_id', 'a.doctor_id', 'p.uhid', 'p.name as patient_name', 'p.phone', 'p.sex',
      'p.dob', 'p.age_years', 'p.created_at as patient_created', 'd.name as doctor_name', 'v.id as visit_id', 'v.invoice_id',
      'i.number as invoice_number', 'i.status as invoice_status']);
}
type ApptRow = Awaited<ReturnType<ReturnType<typeof apptSelect>['execute']>>[number];

function apptJson(a: ApptRow) {
  return {
    id: a.id, date: a.appt_date, startTime: hm(a.start_time), endTime: hm(a.end_time), tokenNo: a.token_no, kind: a.kind,
    status: a.status, reason: a.reason, cancelReason: a.cancel_reason, arrivedAt: a.arrived_at, updatedAt: a.updated_at,
    patient: patientBrief({ id: a.patient_id, uhid: a.uhid, name: a.patient_name, phone: a.phone, sex: a.sex, dob: a.dob, age_years: a.age_years, created_at: a.patient_created }),
    doctor: { id: a.doctor_id, name: a.doctor_name },
    visitId: a.visit_id, billed: !!a.invoice_id && a.invoice_status !== 'cancelled', invoiceNumber: a.invoice_number,
  };
}

async function loadAppt(tx: Tx, ctx: RequestContext, id: string) {
  const row = await apptSelect(tx).where('a.id', '=', id).where('a.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!row) throw notFound('Appointment');
  return row;
}

/** Checks a requested slot against the doctor's weekly hours and grid. No hours set means any time. */
function checkSlot(doc: { working_hours: unknown; slot_minutes: number }, date: string, start: string) {
  const hours = (doc.working_hours as Hours[]).filter((h) => h.day === weekday(date));
  if ((doc.working_hours as Hours[]).length === 0) return { end: fromMin(toMin(start) + doc.slot_minutes) };
  const s = toMin(start);
  const w = hours.find((h) => s >= toMin(h.from) && s + doc.slot_minutes <= toMin(h.to));
  if (!w) throw badRequest('The doctor is not available at that time.', { startTime: 'Outside working hours' });
  if ((s - toMin(w.from)) % doc.slot_minutes !== 0) {
    throw badRequest(`Slots start every ${doc.slot_minutes} minutes from ${w.from}.`, { startTime: 'Not on a slot' });
  }
  return { end: fromMin(s + doc.slot_minutes) };
}

const isSlotClash = (err: unknown) => (err as { code?: string; constraint?: string }).code === '23505'
  && (err as { constraint?: string }).constraint === 'clinic_appt_slot_uq';

async function nextToken(tx: Tx, doctorId: string, date: string): Promise<number> {
  const r = await tx.selectFrom('clinic_appointments').select(sql<number>`coalesce(max(token_no), 0)`.as('m'))
    .where('doctor_id', '=', doctorId).where('appt_date', '=', date).executeTakeFirstOrThrow();
  return Number(r.m) + 1;
}

const RX_LINE_COLS = ['id', 'line_no', 'item_id', 'medicine', 'dose', 'frequency', 'days', 'instructions'] as const;
async function loadRx(tx: Tx, visitId: string) {
  const rows = await tx.selectFrom('clinic_rx_lines').select(RX_LINE_COLS).where('visit_id', '=', visitId).orderBy('line_no').execute();
  return rows.map((r) => ({ id: r.id, lineNo: r.line_no, itemId: r.item_id, medicine: r.medicine, dose: r.dose, frequency: r.frequency, days: r.days, instructions: r.instructions }));
}

async function loadVisitRow(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('clinic_visits').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Visit');
  return row;
}

async function visitJson(tx: Tx, ctx: RequestContext, v: Awaited<ReturnType<typeof loadVisitRow>>) {
  const patient = await loadPatientRow(tx, ctx, v.patient_id);
  const doctor = await loadDoctorRow(tx, ctx, v.doctor_id);
  const inv = v.invoice_id
    ? await tx.selectFrom('invoices').select(['id', 'number', 'total', 'amount_paid', 'status']).where('id', '=', v.invoice_id).executeTakeFirst()
    : undefined;
  const base = {
    id: v.id, appointmentId: v.appointment_id, date: v.visit_date, status: v.status, feeKind: v.fee_kind,
    patient: patientBrief(patient), doctor: { id: doctor.id, name: doctor.name },
    invoice: inv ? { id: inv.id, number: inv.number, total: inv.total, amountPaid: inv.amount_paid, status: inv.status } : null,
    updatedAt: v.updated_at, closedAt: v.closed_at,
  };
  if (!ctx.can('clinic.consult')) return { ...base, clinical: false };
  return {
    ...base, clinical: true, allergies: patient.allergies, vitals: v.vitals, complaints: v.complaints, findings: v.findings,
    diagnosis: v.diagnosis, testsAdvised: v.tests_advised, advice: v.advice, followupDate: v.followup_date, rx: await loadRx(tx, v.id),
  };
}

function needFrontDesk(ctx: RequestContext) { ctx.require('clinic.front_desk', 'clinic.manage'); }

/** The fee item for consultations: one service item per company, created on first bill. */
async function consultItem(tx: Tx, ctx: RequestContext): Promise<string> {
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId)
    .where(sql`lower(sku)`, '=', 'clinic-consult').executeTakeFirst();
  if (found) return found.id;
  const row = await tx.insertInto('items').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, name: 'Consultation', sku: 'CLINIC-CONSULT', hsn_code: '999312',
    unit: 'NOS', gst_rate: 0, sale_price: 0, track_stock: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

// Routes ----------------------------------------------------------------------------------------

export async function clinicRoutes(app: FastifyInstance) {
  // Patients ----------------------------------------------------------------------------------

  app.get('/clinic/patients', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.view');
    const q = parse(pagingQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('clinic_patients').where('company_id', '=', ctx.companyId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('name', 'ilike', t), eb('phone', 'ilike', t), eb('uhid', 'ilike', t)]));
      }
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.select(['id', 'uhid', 'name', 'sex', 'dob', 'age_years', 'phone', 'blood_group', 'is_active', 'created_at'])
        .orderBy('name').orderBy('uhid').limit(q.limit).offset(q.offset).execute();
      return {
        total: Number(total),
        data: rows.map((r) => ({ ...patientBrief(r), bloodGroup: r.blood_group, isActive: r.is_active })),
      };
    });
  });

  app.post('/clinic/patients', async (req, reply) => {
    const ctx = req.ctx;
    needFrontDesk(ctx);
    const body = parse(patientCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      if (!body.force) {
        const dup = await tx.selectFrom('clinic_patients').select(['id', 'uhid', 'name', 'phone'])
          .where('company_id', '=', ctx.companyId).where('phone', '=', body.phone)
          .where(sql`lower(name)`, '=', body.name.toLowerCase()).limit(5).execute();
        if (dup.length) {
          throw conflict('A patient with this name and phone is already registered.', 'DUPLICATE_PATIENT', { matches: dup });
        }
      }
      const company = await tx.selectFrom('companies').select('state_code').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const party = await tx.insertInto('parties').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, type: 'customer', name: body.name, phone: body.phone,
        address: body.address ?? null, state_code: company.state_code, gstin: null, email: null, pan: null, pincode: null,
        udyam_no: null, msme_category: null, tds_section_id: null,
      }).returning('id').executeTakeFirstOrThrow();
      const uhid = await nextNumber(tx, ctx, 'patient', financialYear(todayIst()));
      const row = await tx.insertInto('clinic_patients').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, party_id: party.id, uhid, name: body.name, sex: body.sex,
        dob: body.dob ?? null, age_years: body.dob ? null : body.ageYears ?? null, phone: body.phone, address: body.address ?? null,
        blood_group: body.bloodGroup ?? null, allergies: body.allergies ?? null, emergency_name: body.emergencyName ?? null,
        emergency_phone: body.emergencyPhone ?? null, notes: ctx.can('clinic.consult') ? body.notes ?? null : null,
        created_by: ctx.userId,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'clinic_patient', row.id, 'create', null, { uhid, partyId: party.id });
      return patientJson(row, ctx.can('clinic.consult'));
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/clinic/patients/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => patientJson(await loadPatientRow(tx, ctx, id), ctx.can('clinic.consult')));
  });

  app.patch<{ Params: { id: string } }>('/clinic/patients/:id', async (req) => {
    const ctx = req.ctx;
    needFrontDesk(ctx);
    const id = parse(z.uuid(), req.params.id);
    const body = parse(patientPatch, req.body);
    if (body.notes !== undefined && !ctx.can('clinic.consult')) throw badRequest('Only clinical staff can edit patient notes.', { notes: 'Not allowed' });
    return ctx.tx(async (tx) => {
      const before = await loadPatientRow(tx, ctx, id, true);
      assertFresh(before.updated_at, body.expectedUpdatedAt, 'patient');
      const changes = definedOnly({
        name: body.name, sex: body.sex, dob: body.dob, age_years: body.ageYears, phone: body.phone, address: body.address,
        blood_group: body.bloodGroup, allergies: body.allergies, emergency_name: body.emergencyName,
        emergency_phone: body.emergencyPhone, notes: body.notes,
      });
      if (!Object.keys(changes).length) return patientJson(before, ctx.can('clinic.consult'));
      const dob = 'dob' in changes ? changes.dob : before.dob;
      const age = 'age_years' in changes ? changes.age_years : before.age_years;
      if (!dob && (age === null || age === undefined)) throw badRequest('Give a date of birth or an age.', { dob: 'Required' });
      await tx.updateTable('clinic_patients').set(changes as never).where('id', '=', id).execute();
      if (body.name !== undefined || body.phone !== undefined || body.address !== undefined) {
        await tx.updateTable('parties').set(definedOnly({ name: body.name, phone: body.phone, address: body.address }) as never)
          .where('id', '=', before.party_id).execute();
      }
      const after = await loadPatientRow(tx, ctx, id);
      await writeAudit(tx, auditOf(ctx), 'clinic_patient', id, 'update', null, { fields: Object.keys(changes) });
      return patientJson(after, ctx.can('clinic.consult'));
    });
  });

  app.get<{ Params: { id: string } }>('/clinic/patients/:id/history', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const patient = await loadPatientRow(tx, ctx, id);
      const rows = await tx.selectFrom('clinic_visits as v')
        .innerJoin('clinic_doctors as d', 'd.id', 'v.doctor_id')
        .leftJoin('invoices as i', 'i.id', 'v.invoice_id')
        .select(['v.id', 'v.visit_date', 'v.status', 'v.diagnosis', 'v.fee_kind', 'v.followup_date', 'd.id as doctor_id', 'd.name as doctor_name',
          'i.id as invoice_id', 'i.number as invoice_number', 'i.total', 'i.amount_paid', 'i.status as invoice_status',
          (eb) => eb.selectFrom('clinic_rx_lines as r').select((e) => e.fn.countAll<number>().as('n')).whereRef('r.visit_id', '=', 'v.id').as('rx_count')])
        .where('v.patient_id', '=', id).where('v.company_id', '=', ctx.companyId)
        .orderBy('v.visit_date', 'desc').orderBy('v.created_at', 'desc').limit(200).execute();
      const clinical = ctx.can('clinic.consult');
      const appts = await apptSelect(tx).where('a.patient_id', '=', id).where('a.company_id', '=', ctx.companyId)
        .orderBy('a.appt_date', 'desc').limit(50).execute();
      return {
        patient: patientJson(patient, clinical),
        appointments: appts.map(apptJson),
        visits: rows.map((r) => ({
          id: r.id, date: r.visit_date, status: r.status, feeKind: r.fee_kind, followupDate: r.followup_date,
          doctor: { id: r.doctor_id, name: r.doctor_name },
          ...(clinical ? { diagnosis: r.diagnosis, rxCount: Number(r.rx_count ?? 0) } : {}),
          invoice: r.invoice_id ? { id: r.invoice_id, number: r.invoice_number, total: r.total, amountPaid: r.amount_paid, status: r.invoice_status } : null,
        })),
      };
    });
  });

  // Doctors -----------------------------------------------------------------------------------

  app.get('/clinic/doctors', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.view');
    const q = z.object({ activeOnly: z.enum(['true', 'false']).optional() }).parse(req.query ?? {});
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('clinic_doctors').selectAll().where('company_id', '=', ctx.companyId);
      if (q.activeOnly === 'true') base = base.where('is_active', '=', true);
      const rows = await base.orderBy('name').execute();
      return { data: rows.map(doctorJson), total: rows.length };
    });
  });

  async function checkDoctorUser(tx: Tx, ctx: RequestContext, userId: string | null | undefined, selfId?: string) {
    if (!userId) return;
    const u = await tx.selectFrom('user_roles').select('user_id').where('user_id', '=', userId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!u) throw badRequest('That user does not belong to this company.', { userId: 'Not found' });
    let q = tx.selectFrom('clinic_doctors').select('id').where('company_id', '=', ctx.companyId).where('user_id', '=', userId);
    if (selfId) q = q.where('id', '!=', selfId);
    if (await q.executeTakeFirst()) throw conflict('That user already has a doctor profile.', 'CONFLICT', { userId: 'Already linked' });
  }

  app.post('/clinic/doctors', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('clinic.manage');
    const b = parse(doctorCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      await checkDoctorUser(tx, ctx, b.userId);
      const row = await tx.insertInto('clinic_doctors').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, user_id: b.userId ?? null, name: b.name, speciality: b.speciality ?? null,
        registration_no: b.registrationNo ?? null, consult_fee: b.consultFee, follow_up_fee: b.followUpFee, follow_up_days: b.followUpDays,
        slot_minutes: b.slotMinutes, working_hours: JSON.stringify(b.workingHours), is_active: b.isActive,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'clinic_doctor', row.id, 'create', null, doctorJson(row));
      return doctorJson(row);
    });
    return reply.status(201).send(out);
  });

  app.patch<{ Params: { id: string } }>('/clinic/doctors/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(doctorPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadDoctorRow(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'doctor');
      if (b.userId !== undefined) await checkDoctorUser(tx, ctx, b.userId, id);
      const changes = definedOnly({
        user_id: b.userId, name: b.name, speciality: b.speciality, registration_no: b.registrationNo, consult_fee: b.consultFee,
        follow_up_fee: b.followUpFee, follow_up_days: b.followUpDays, slot_minutes: b.slotMinutes,
        working_hours: b.workingHours === undefined ? undefined : JSON.stringify(b.workingHours), is_active: b.isActive,
      });
      if (!Object.keys(changes).length) return doctorJson(before);
      await tx.updateTable('clinic_doctors').set(changes as never).where('id', '=', id).execute();
      const after = await loadDoctorRow(tx, ctx, id);
      await writeAudit(tx, auditOf(ctx), 'clinic_doctor', id, 'update', doctorJson(before), doctorJson(after));
      return doctorJson(after);
    });
  });

  app.get<{ Params: { id: string } }>('/clinic/doctors/:id/slots', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.view');
    const id = parse(z.uuid(), req.params.id);
    const { date } = parse(z.object({ date: dateField }), req.query);
    return ctx.tx(async (tx) => {
      const doc = await loadDoctorRow(tx, ctx, id);
      const taken = await tx.selectFrom('clinic_appointments').select('start_time').where('doctor_id', '=', id)
        .where('appt_date', '=', date).where('status', 'in', LIVE).where('start_time', 'is not', null).execute();
      const takenSet = new Set(taken.map((t) => hm(t.start_time)));
      const slots: { startTime: string; endTime: string; free: boolean }[] = [];
      for (const h of (doc.working_hours as Hours[]).filter((x) => x.day === weekday(date))) {
        for (let m = toMin(h.from); m + doc.slot_minutes <= toMin(h.to); m += doc.slot_minutes) {
          slots.push({ startTime: fromMin(m), endTime: fromMin(m + doc.slot_minutes), free: !takenSet.has(fromMin(m)) });
        }
      }
      return { date, slotMinutes: doc.slot_minutes, data: slots };
    });
  });

  // Appointments ------------------------------------------------------------------------------

  app.get('/clinic/appointments', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.view');
    const q = parse(apptList, req.query);
    return ctx.tx(async (tx) => {
      let base = apptSelect(tx).where('a.company_id', '=', ctx.companyId);
      if (q.date) base = base.where('a.appt_date', '=', q.date);
      if (!q.date && !q.patientId) base = base.where('a.appt_date', '=', todayIst());
      if (q.doctorId) base = base.where('a.doctor_id', '=', q.doctorId);
      if (q.patientId) base = base.where('a.patient_id', '=', q.patientId);
      if (q.status) base = base.where('a.status', '=', q.status);
      const rows = await base.orderBy('a.appt_date').orderBy('a.start_time').orderBy('a.token_no').limit(500).execute();
      rows.sort((x, y) => x.appt_date.localeCompare(y.appt_date)
        || STATUS_ORDER.indexOf(x.status) - STATUS_ORDER.indexOf(y.status)
        || (x.token_no ?? 1e9) - (y.token_no ?? 1e9) || (x.start_time ?? '').localeCompare(y.start_time ?? ''));
      return { data: rows.map(apptJson), total: rows.length };
    });
  });

  app.post('/clinic/appointments', async (req, reply) => {
    const ctx = req.ctx;
    needFrontDesk(ctx);
    const b = parse(apptCreate, req.body);
    const walkIn = b.walkIn === true;
    if (!walkIn && (!b.date || !b.startTime)) throw badRequest('Choose a date and a time.', { startTime: 'Required' });
    const date = walkIn ? todayIst() : b.date!;
    if (date < todayIst()) throw badRequest('That date has passed.', { date: 'In the past' });
    if (walkIn && b.date && b.date !== todayIst()) throw badRequest('Walk-ins are for today.', { date: 'Not today' });
    try {
      const id = await ctx.tx(async (tx) => {
        await loadPatientRow(tx, ctx, b.patientId);
        const doc = await loadDoctorRow(tx, ctx, b.doctorId, true); // the lock serialises tokens and slots per doctor
        if (!doc.is_active) throw badRequest('This doctor is not taking appointments.', { doctorId: 'Inactive' });
        let end: string | null = null;
        if (!walkIn) end = checkSlot(doc, date, b.startTime!).end;
        const token = walkIn ? await nextToken(tx, doc.id, date) : null;
        const row = await tx.insertInto('clinic_appointments').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, patient_id: b.patientId, doctor_id: doc.id, appt_date: date,
          start_time: walkIn ? null : b.startTime!, end_time: end, token_no: token, kind: walkIn ? 'walk_in' : 'booked',
          status: walkIn ? 'arrived' : 'booked', reason: b.reason ?? null, arrived_at: walkIn ? new Date() : null, created_by: ctx.userId,
        }).returning('id').executeTakeFirstOrThrow();
        await writeAudit(tx, auditOf(ctx), 'clinic_appointment', row.id, 'create', null, { patientId: b.patientId, doctorId: doc.id, date });
        return row.id;
      });
      return reply.status(201).send(apptJson(await ctx.tx((tx) => loadAppt(tx, ctx, id))));
    } catch (err) {
      if (isSlotClash(err)) throw conflict('That slot is already booked. Choose another time.', 'SLOT_TAKEN', { startTime: 'Already booked' });
      throw err;
    }
  });

  app.post<{ Params: { id: string } }>('/clinic/appointments/:id/status', async (req) => {
    const ctx = req.ctx;
    needFrontDesk(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(apptStatus, req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('clinic_appointments').selectAll().where('id', '=', id)
        .where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!cur) throw notFound('Appointment');
      const allowed: Record<string, string[]> = { booked: ['arrived', 'cancelled', 'no_show'], arrived: ['cancelled'] };
      if (!(allowed[cur.status] ?? []).includes(b.status)) {
        throw conflict(`An appointment that is ${cur.status.replace('_', ' ')} cannot be marked ${b.status.replace('_', ' ')}.`, 'BAD_STATUS');
      }
      const set: Record<string, unknown> = { status: b.status };
      if (b.status === 'arrived') {
        if (cur.appt_date !== todayIst()) throw conflict('Only today\'s appointments can be marked arrived.', 'BAD_STATUS');
        await loadDoctorRow(tx, ctx, cur.doctor_id, true);
        set.arrived_at = new Date();
        set.token_no = cur.token_no ?? await nextToken(tx, cur.doctor_id, cur.appt_date);
      }
      if (b.status === 'cancelled') set.cancel_reason = b.reason ?? null;
      await tx.updateTable('clinic_appointments').set(set as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_appointment', id, 'status', { status: cur.status }, { status: b.status });
      return apptJson(await loadAppt(tx, ctx, id));
    });
  });

  app.post<{ Params: { id: string } }>('/clinic/appointments/:id/reschedule', async (req) => {
    const ctx = req.ctx;
    needFrontDesk(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(apptReschedule, req.body);
    if (b.date < todayIst()) throw badRequest('That date has passed.', { date: 'In the past' });
    try {
      return await ctx.tx(async (tx) => {
        const cur = await tx.selectFrom('clinic_appointments').selectAll().where('id', '=', id)
          .where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
        if (!cur) throw notFound('Appointment');
        if (cur.status !== 'booked') throw conflict('Only a booked appointment can be rescheduled.', 'BAD_STATUS');
        const doc = await loadDoctorRow(tx, ctx, b.doctorId ?? cur.doctor_id, true);
        if (!doc.is_active) throw badRequest('This doctor is not taking appointments.', { doctorId: 'Inactive' });
        const { end } = checkSlot(doc, b.date, b.startTime);
        await tx.updateTable('clinic_appointments').set({
          doctor_id: doc.id, appt_date: b.date, start_time: b.startTime, end_time: end, token_no: null,
        }).where('id', '=', id).execute();
        await writeAudit(tx, auditOf(ctx), 'clinic_appointment', id, 'reschedule',
          { date: cur.appt_date, startTime: hm(cur.start_time) }, { date: b.date, startTime: b.startTime });
        return apptJson(await loadAppt(tx, ctx, id));
      });
    } catch (err) {
      if (isSlotClash(err)) throw conflict('That slot is already booked. Choose another time.', 'SLOT_TAKEN', { startTime: 'Already booked' });
      throw err;
    }
  });

  // Consultations -----------------------------------------------------------------------------

  app.post('/clinic/visits', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('clinic.consult');
    const b = parse(visitStart, req.body);
    const { visit, created } = await ctx.tx(async (tx) => {
      let apptId: string;
      if ('appointmentId' in b) {
        apptId = b.appointmentId;
      } else {
        await loadPatientRow(tx, ctx, b.patientId);
        const doc = await loadDoctorRow(tx, ctx, b.doctorId, true);
        const today = todayIst();
        const row = await tx.insertInto('clinic_appointments').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, patient_id: b.patientId, doctor_id: doc.id, appt_date: today,
          token_no: await nextToken(tx, doc.id, today), kind: 'walk_in', status: 'arrived', arrived_at: new Date(), created_by: ctx.userId,
        }).returning('id').executeTakeFirstOrThrow();
        apptId = row.id;
      }
      const appt = await tx.selectFrom('clinic_appointments').selectAll().where('id', '=', apptId)
        .where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!appt) throw notFound('Appointment');
      const existing = await tx.selectFrom('clinic_visits').select('id').where('appointment_id', '=', apptId).executeTakeFirst();
      if (existing) return { visit: await visitJson(tx, ctx, await loadVisitRow(tx, ctx, existing.id)), created: false };
      if (!['booked', 'arrived', 'in_consultation'].includes(appt.status)) {
        throw conflict(`This appointment is ${appt.status.replace('_', ' ')}.`, 'BAD_STATUS');
      }
      const set: Record<string, unknown> = { status: 'in_consultation' };
      if (!appt.token_no) set.token_no = await nextToken(tx, appt.doctor_id, appt.appt_date);
      if (!appt.arrived_at) set.arrived_at = new Date();
      await tx.updateTable('clinic_appointments').set(set as never).where('id', '=', apptId).execute();
      const row = await tx.insertInto('clinic_visits').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, appointment_id: apptId, patient_id: appt.patient_id, doctor_id: appt.doctor_id,
        visit_date: appt.appt_date, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'clinic_visit', row.id, 'create', null, { appointmentId: apptId });
      return { visit: await visitJson(tx, ctx, await loadVisitRow(tx, ctx, row.id)), created: true };
    });
    return reply.status(created ? 201 : 200).send(visit);
  });

  app.get<{ Params: { id: string } }>('/clinic/visits/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => visitJson(tx, ctx, await loadVisitRow(tx, ctx, id)));
  });

  app.patch<{ Params: { id: string } }>('/clinic/visits/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.consult');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(visitPatch, req.body);
    return ctx.tx(async (tx) => {
      const before = await loadVisitRow(tx, ctx, id, true);
      assertFresh(before.updated_at, b.expectedUpdatedAt, 'visit');
      const changes = definedOnly({
        vitals: b.vitals === undefined ? undefined : JSON.stringify(definedOnly(b.vitals)), complaints: b.complaints, findings: b.findings,
        diagnosis: b.diagnosis, tests_advised: b.testsAdvised, advice: b.advice, followup_date: b.followupDate,
      });
      if (b.followupDate && b.followupDate < before.visit_date) throw badRequest('Follow-up cannot be before the visit.', { followupDate: 'Too early' });
      if (b.rx) {
        const ids = [...new Set(b.rx.map((r) => r.itemId).filter((x): x is string => !!x))];
        if (ids.length) {
          const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
          if (found.length !== ids.length) throw badRequest('A medicine item was not found.', { rx: 'Item not found' });
        }
        await tx.deleteFrom('clinic_rx_lines').where('visit_id', '=', id).execute();
        if (b.rx.length) {
          await tx.insertInto('clinic_rx_lines').values(b.rx.map((r, i) => ({
            tenant_id: ctx.tenantId, visit_id: id, line_no: i + 1, item_id: r.itemId ?? null, medicine: r.medicine,
            dose: r.dose ?? null, frequency: r.frequency ?? null, days: r.days ?? null, instructions: r.instructions ?? null,
          }))).execute();
        }
      }
      // Touch the row even when only prescription lines changed, so updatedAt moves.
      await tx.updateTable('clinic_visits').set({ ...(changes as object), updated_at: sql`now()` } as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_visit', id, 'update', null,
        { fields: [...Object.keys(changes), ...(b.rx ? ['rx'] : [])] });
      return visitJson(tx, ctx, await loadVisitRow(tx, ctx, id));
    });
  });

  app.post<{ Params: { id: string } }>('/clinic/visits/:id/complete', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.consult');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const v = await loadVisitRow(tx, ctx, id, true);
      if (v.status === 'closed') return visitJson(tx, ctx, v);
      await tx.updateTable('clinic_visits').set({ status: 'closed', closed_at: new Date() }).where('id', '=', id).execute();
      if (v.appointment_id) await tx.updateTable('clinic_appointments').set({ status: 'done' }).where('id', '=', v.appointment_id).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_visit', id, 'complete', null, null);
      return visitJson(tx, ctx, await loadVisitRow(tx, ctx, id));
    });
  });

  app.get<{ Params: { id: string } }>('/clinic/visits/:id/prescription', async (req) => {
    const ctx = req.ctx;
    ctx.require('clinic.consult');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const v = await loadVisitRow(tx, ctx, id);
      const patient = await loadPatientRow(tx, ctx, v.patient_id);
      const doc = await loadDoctorRow(tx, ctx, v.doctor_id);
      const co = await tx.selectFrom('companies').select(['name', 'legal_name', 'address', 'phone', 'email', 'pincode'])
        .where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      return {
        clinic: { name: co.legal_name || co.name, address: co.address, pincode: co.pincode, phone: co.phone, email: co.email },
        doctor: { name: doc.name, speciality: doc.speciality, registrationNo: doc.registration_no },
        patient: { ...patientBrief(patient), allergies: patient.allergies, bloodGroup: patient.blood_group },
        visit: { id: v.id, date: v.visit_date, vitals: v.vitals, complaints: v.complaints, findings: v.findings, diagnosis: v.diagnosis,
          testsAdvised: v.tests_advised, advice: v.advice, followupDate: v.followup_date },
        rx: await loadRx(tx, id),
      };
    });
  });

  // Billing -----------------------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/clinic/visits/:id/bill', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('clinic.front_desk', 'clinic.consult', 'clinic.manage');
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(billBody, req.body);
    if (b.payment) ctx.require('payments.create');
    const out = await ctx.tx(async (tx) => {
      const v = await loadVisitRow(tx, ctx, id, true);
      if (v.invoice_id) {
        const inv = await tx.selectFrom('invoices').select('status').where('id', '=', v.invoice_id).executeTakeFirst();
        if (inv && inv.status !== 'cancelled') throw conflict('This visit is already billed.', 'ALREADY_BILLED');
      }
      const patient = await loadPatientRow(tx, ctx, v.patient_id);
      const doc = await loadDoctorRow(tx, ctx, v.doctor_id);
      const lines: { itemId: string; qty: number; rate?: number; discountPct?: number; description?: string }[] = [];
      let feeKind: 'consultation' | 'follow_up' | 'none' = 'none';
      if (b.includeConsultation !== false) {
        const since = addDays(v.visit_date, -doc.follow_up_days);
        const prior = await tx.selectFrom('clinic_visits as pv').innerJoin('invoices as i', 'i.id', 'pv.invoice_id')
          .select('pv.id').where('pv.patient_id', '=', v.patient_id).where('pv.doctor_id', '=', v.doctor_id)
          .where('pv.id', '!=', v.id).where('pv.fee_kind', '=', 'consultation').where('i.status', '!=', 'cancelled')
          .where('pv.visit_date', '>=', since).where('pv.visit_date', '<=', v.visit_date).limit(1).executeTakeFirst();
        feeKind = prior ? 'follow_up' : 'consultation';
        const fee = round2(prior ? doc.follow_up_fee : doc.consult_fee);
        const item = await consultItem(tx, ctx);
        lines.push({ itemId: item, qty: 1, rate: fee, description: `${prior ? 'Follow-up consultation' : 'Consultation'} - ${doc.name}` });
      }
      lines.push(...b.lines);
      if (!lines.length) throw badRequest('Add at least one line to bill.', { lines: 'Required' });

      let locationId = b.locationId;
      if (!locationId) {
        const locs = await tx.selectFrom('locations').select('id').where('company_id', '=', ctx.companyId)
          .where('is_active', '=', true).orderBy('created_at').execute();
        locationId = locs.find((l) => ctx.canAccessLocation(l.id))?.id;
        if (!locationId) throw badRequest('Add a location before billing.', { locationId: 'Required' });
      }
      const invoice = await createInvoice(ctx, tx, {
        locationId, partyId: patient.party_id, invoiceDate: v.visit_date, lines,
        notes: `Visit ${v.visit_date}, ${doc.name}. UHID ${patient.uhid}`, custom: undefined,
      } as never);
      await tx.updateTable('clinic_visits').set({ invoice_id: invoice.id, fee_kind: feeKind }).where('id', '=', id).execute();
      let payment = null;
      if (b.payment) {
        const pay = Math.min(b.payment.amount, invoice.total);
        payment = await createPayment(ctx, tx, {
          kind: 'receipt', partyId: patient.party_id, date: undefined, accountId: b.payment.accountId, mode: b.payment.mode,
          reference: b.payment.reference, amount: pay, tdsAmount: undefined, notes: `Visit ${patient.uhid}`,
          allocations: [{ docId: invoice.id, amount: pay }],
        } as never);
      }
      await writeAudit(tx, auditOf(ctx), 'clinic_visit', id, 'bill', null, { invoiceId: invoice.id, feeKind });
      return { invoice, payment, feeKind };
    });
    return reply.status(201).send(out);
  });
}

documentRoute('POST', '/clinic/patients', { body: patientCreate });
documentRoute('PATCH', '/clinic/patients/:id', { body: patientPatch });
documentRoute('POST', '/clinic/doctors', { body: doctorCreate });
documentRoute('PATCH', '/clinic/doctors/:id', { body: doctorPatch });
documentRoute('POST', '/clinic/appointments', { body: apptCreate });
documentRoute('POST', '/clinic/appointments/:id/status', { body: apptStatus });
documentRoute('POST', '/clinic/appointments/:id/reschedule', { body: apptReschedule });
documentRoute('POST', '/clinic/visits', { body: visitStart });
documentRoute('PATCH', '/clinic/visits/:id', { body: visitPatch });
documentRoute('POST', '/clinic/visits/:id/bill', { body: billBody });
