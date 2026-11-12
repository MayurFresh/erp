import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nullableText, optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { createInvoice } from './invoices.ts';
import { createPayment } from './payments.ts';
import { documentRoute } from '../lib/openapi.ts';

/*
 * Clinic in-patient care: wards, beds, admissions, bed transfers, deposits, daily charges, discharge and the final bill.
 * Diagnosis, treatment and advice are clinical text: returned and written only with clinic.consult, and never in audit entries.
 * Healthcare services are GST exempt: the bed and general service items carry 0%, as the OPD consultation item does. A
 * medicine or service picked from the item list keeps its own tax rate.
 */

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const WARD_KINDS = ['general', 'semi_private', 'private', 'icu', 'nicu', 'other'] as const;
const BED_STATUSES = ['available', 'occupied', 'cleaning', 'maintenance'] as const;
const MAX_DAYS = 400;

const wardCreate = z.object({
  name: z.string().trim().min(1, 'Required').max(100), kind: z.enum(WARD_KINDS).default('general'),
  sortOrder: z.coerce.number().int().min(0).max(9999).default(0), isActive: z.boolean().default(true),
});
const wardPatch = z.object({
  name: z.string().trim().min(1).max(100).optional(), kind: z.enum(WARD_KINDS).optional(),
  sortOrder: z.coerce.number().int().min(0).max(9999).optional(), isActive: z.boolean().optional(),
});
const bedCreate = z.object({
  wardId: z.uuid(), bedNo: z.string().trim().min(1, 'Required').max(30), dailyRate: moneyField, isActive: z.boolean().default(true),
});
const bedPatch = z.object({
  bedNo: z.string().trim().min(1).max(30).optional(), dailyRate: moneyField.optional(), wardId: z.uuid().optional(),
  status: z.enum(['available', 'cleaning', 'maintenance']).optional(), isActive: z.boolean().optional(),
});
const payBody = z.object({
  accountId: z.uuid(), mode: z.enum(['cash', 'bank', 'upi', 'cheque', 'card']),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), reference: optionalText(60),
});
const admitBody = z.object({
  patientId: z.uuid(), doctorId: z.uuid(), bedId: z.uuid(), expectedDays: z.coerce.number().int().min(1).max(365).optional(),
  provisionalDiagnosis: optionalText(1000), deposit: payBody.optional(),
});
const transferBody = z.object({ bedId: z.uuid(), reason: optionalText(300) });
const chargeBody = z.object({
  kind: z.enum(['service', 'medicine']), itemId: z.uuid().optional(), description: optionalText(300),
  qty: qtyField.refine((v) => v > 0, 'Must be more than zero').default(1), rate: moneyField.optional(), chargeDate: dateField.optional(),
});
const summaryFields = {
  diagnosis: nullableText(1000), treatment: nullableText(4000), advice: nullableText(2000), condition: nullableText(200),
  followupDate: z.preprocess((v) => (v === '' ? null : v), dateField.nullable().optional()),
};
const summaryPatch = z.object({ expectedUpdatedAt: z.string().max(40).optional(), ...summaryFields });
const dischargeBody = z.object({
  ...summaryFields, locationId: z.uuid().optional(), allowCredit: z.boolean().optional(), payment: payBody.optional(),
});
const listQuery = z.object({
  status: z.enum(['admitted', 'discharged']).optional(), q: z.string().trim().max(100).optional(), wardId: z.uuid().optional(),
  doctorId: z.uuid().optional(), limit: z.coerce.number().int().min(1).max(200).default(50), offset: z.coerce.number().int().min(0).default(0),
});

function needView(ctx: RequestContext) { ctx.require('clinic.ipd', 'clinic.ipd_manage'); }
function needManage(ctx: RequestContext) { ctx.require('clinic.ipd_manage'); }

type AdmRow = Awaited<ReturnType<typeof loadAdmission>>;

async function loadAdmission(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('clinic_admissions').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Admission');
  return row;
}

async function loadBed(tx: Tx, ctx: RequestContext, id: string, lock = false) {
  let q = tx.selectFrom('clinic_beds as b').innerJoin('clinic_wards as w', 'w.id', 'b.ward_id')
    .select(['b.id', 'b.bed_no', 'b.daily_rate', 'b.status', 'b.is_active', 'b.ward_id', 'b.updated_at', 'w.name as ward_name', 'w.is_active as ward_active'])
    .where('b.id', '=', id).where('b.company_id', '=', ctx.companyId);
  if (lock) q = q.forUpdate();
  const row = await q.executeTakeFirst();
  if (!row) throw notFound('Bed');
  return row;
}

async function activeParty(tx: Tx, ctx: RequestContext, patientId: string) {
  const p = await tx.selectFrom('clinic_patients').select(['id', 'party_id', 'name', 'uhid']).where('id', '=', patientId)
    .where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!p) throw notFound('Patient');
  return p;
}

async function serviceItem(tx: Tx, ctx: RequestContext, sku: string, name: string): Promise<string> {
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', ctx.companyId).where(sql`lower(sku)`, '=', sku.toLowerCase()).executeTakeFirst();
  if (found) return found.id;
  const row = await tx.insertInto('items').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, name, sku, hsn_code: '999311', unit: 'NOS', gst_rate: 0, sale_price: 0, track_stock: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

/** Posts one bed charge per night for every day not yet posted, up to `upTo` (today at most). Safe to repeat. */
async function syncBedCharges(tx: Tx, ctx: RequestContext, admissionId: string, upTo: string): Promise<number> {
  const stays = await tx.selectFrom('clinic_bed_stays as s').innerJoin('clinic_beds as b', 'b.id', 's.bed_id')
    .innerJoin('clinic_wards as w', 'w.id', 'b.ward_id')
    .select(['s.id', 's.from_date', 's.to_date', 's.daily_rate', 'b.bed_no', 'w.name as ward_name'])
    .where('s.admission_id', '=', admissionId).orderBy('s.from_date').orderBy('s.created_at').execute();
  let added = 0;
  for (const s of stays) {
    let end: string | null = s.to_date ? (s.to_date > s.from_date ? addDays(s.to_date, -1) : null) : upTo;
    if (!end) continue;
    if (end > upTo) end = upTo;
    for (let d = s.from_date, n = 0; d <= end && n < MAX_DAYS; d = addDays(d, 1), n += 1) {
      const res = await tx.insertInto('clinic_ipd_charges').values({
        tenant_id: ctx.tenantId, admission_id: admissionId, charge_date: d, kind: 'bed',
        description: `Bed ${s.bed_no}, ${s.ward_name}`, qty: 1, rate: s.daily_rate, amount: s.daily_rate, bed_stay_id: s.id, created_by: ctx.userId,
      }).onConflict((oc) => oc.doNothing()).executeTakeFirst();
      if (Number(res.numInsertedOrUpdatedRows ?? 0) > 0) added += 1;
    }
  }
  return added;
}

async function chargeTotals(tx: Tx, admissionId: string) {
  const rows = await tx.selectFrom('clinic_ipd_charges').select(['kind', sql<number>`coalesce(sum(amount), 0)`.as('amount')])
    .where('admission_id', '=', admissionId).where('is_void', '=', false).groupBy('kind').execute();
  const by = (k: string) => round2(Number(rows.find((r) => r.kind === k)?.amount ?? 0));
  const bed = by('bed'), service = by('service'), medicine = by('medicine');
  return { bed, service, medicine, total: round2(bed + service + medicine) };
}

async function depositRows(tx: Tx, admissionId: string) {
  return tx.selectFrom('clinic_ipd_deposits as d').innerJoin('payments as p', 'p.id', 'd.payment_id')
    .select(['d.id', 'd.payment_id', 'd.amount', 'd.created_at', 'p.number', 'p.mode', 'p.payment_date', 'p.status'])
    .where('d.admission_id', '=', admissionId).orderBy('d.created_at').execute();
}

/** Deposit left after the final bill and earlier refunds (0 until discharge). */
async function refundDueOf(tx: Tx, adm: { id: string; invoice_id: string | null; status: string }): Promise<number> {
  if (adm.status !== 'discharged' || !adm.invoice_id) return 0;
  const deps = (await depositRows(tx, adm.id)).filter((d) => d.status !== 'cancelled');
  const held = deps.reduce((s, d) => s + d.amount, 0);
  let applied = 0;
  if (deps.length) {
    const r = await tx.selectFrom('payment_allocations').select(sql<number>`coalesce(sum(amount), 0)`.as('n'))
      .where('doc_id', '=', adm.invoice_id).where('payment_id', 'in', deps.map((d) => d.payment_id)).executeTakeFirstOrThrow();
    applied = Number(r.n);
  }
  const ref = await tx.selectFrom('clinic_ipd_refunds').select(sql<number>`coalesce(sum(amount), 0)`.as('n')).where('admission_id', '=', adm.id).executeTakeFirstOrThrow();
  return Math.max(0, round2(held - applied - Number(ref.n)));
}

const daysBetween = (a: string, b: string) => Math.max(1, Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / 86400000));

function admissionBrief(r: {
  id: string; admission_no: string; status: string; admit_date: string; discharge_date: string | null; patient_id: string; uhid: string;
  patient_name: string; phone: string; doctor_id: string; doctor_name: string; bed_id: string | null; bed_no: string | null;
  ward_id: string | null; ward_name: string | null; invoice_id: string | null; expected_days: number | null;
}) {
  const end = r.discharge_date ?? todayIst();
  return {
    id: r.id, number: r.admission_no, status: r.status, admitDate: r.admit_date, dischargeDate: r.discharge_date,
    days: daysBetween(r.admit_date, end), expectedDays: r.expected_days,
    patient: { id: r.patient_id, uhid: r.uhid, name: r.patient_name, phone: r.phone },
    doctor: { id: r.doctor_id, name: r.doctor_name },
    bed: r.bed_id ? { id: r.bed_id, bedNo: r.bed_no, wardId: r.ward_id, wardName: r.ward_name } : null, invoiceId: r.invoice_id,
  };
}

function admissionSelect(tx: Tx) {
  return tx.selectFrom('clinic_admissions as a').innerJoin('clinic_patients as p', 'p.id', 'a.patient_id')
    .innerJoin('clinic_doctors as d', 'd.id', 'a.doctor_id').leftJoin('clinic_beds as b', 'b.id', 'a.bed_id')
    .leftJoin('clinic_wards as w', 'w.id', 'b.ward_id')
    .select(['a.id', 'a.admission_no', 'a.status', 'a.admit_date', 'a.discharge_date', 'a.patient_id', 'p.uhid', 'p.name as patient_name', 'p.phone',
      'a.doctor_id', 'd.name as doctor_name', 'a.bed_id', 'b.bed_no', 'b.ward_id', 'w.name as ward_name', 'a.invoice_id', 'a.expected_days',
      'a.admitted_at', 'a.updated_at', 'a.provisional_diagnosis', 'a.diagnosis', 'a.treatment', 'a.advice', 'a.condition', 'a.followup_date', 'a.discharged_at']);
}

async function detail(tx: Tx, ctx: RequestContext, id: string) {
  const r = await admissionSelect(tx).where('a.id', '=', id).where('a.company_id', '=', ctx.companyId).executeTakeFirst();
  if (!r) throw notFound('Admission');
  const stays = await tx.selectFrom('clinic_bed_stays as s').innerJoin('clinic_beds as b', 'b.id', 's.bed_id').innerJoin('clinic_wards as w', 'w.id', 'b.ward_id')
    .select(['s.id', 's.from_date', 's.to_date', 's.daily_rate', 's.reason', 'b.id as bed_id', 'b.bed_no', 'w.name as ward_name'])
    .where('s.admission_id', '=', id).orderBy('s.from_date').orderBy('s.created_at').execute();
  const charges = await tx.selectFrom('clinic_ipd_charges').selectAll().where('admission_id', '=', id).orderBy('charge_date').orderBy('created_at').execute();
  const deposits = await depositRows(tx, id);
  const totals = await chargeTotals(tx, id);
  const held = round2(deposits.filter((d) => d.status !== 'cancelled').reduce((s, d) => s + d.amount, 0));
  let invoice: { id: string; number: string; total: number; amountPaid: number; status: string } | null = null;
  if (r.invoice_id) {
    const i = await tx.selectFrom('invoices').select(['id', 'number', 'total', 'amount_paid', 'status']).where('id', '=', r.invoice_id).executeTakeFirst();
    if (i) invoice = { id: i.id, number: i.number, total: i.total, amountPaid: i.amount_paid, status: i.status };
  }
  const clinical = ctx.can('clinic.consult');
  return {
    ...admissionBrief(r), admittedAt: r.admitted_at, dischargedAt: r.discharged_at, updatedAt: r.updated_at, clinical,
    ...(clinical ? {
      provisionalDiagnosis: r.provisional_diagnosis,
      summary: { diagnosis: r.diagnosis, treatment: r.treatment, advice: r.advice, condition: r.condition, followupDate: r.followup_date },
    } : {}),
    stays: stays.map((s) => ({ id: s.id, bedId: s.bed_id, bedNo: s.bed_no, wardName: s.ward_name, fromDate: s.from_date, toDate: s.to_date, dailyRate: s.daily_rate, reason: s.reason })),
    charges: charges.map((c) => ({
      id: c.id, date: c.charge_date, kind: c.kind, itemId: c.item_id, description: c.description, qty: c.qty, rate: c.rate, amount: c.amount,
      isVoid: c.is_void, voidReason: c.void_reason,
    })),
    deposits: deposits.map((d) => ({ id: d.id, paymentId: d.payment_id, number: d.number, mode: d.mode, date: d.payment_date, amount: d.amount, cancelled: d.status === 'cancelled' })),
    totals: { ...totals, deposits: held, balance: round2(totals.total - held) }, invoice,
    refundDue: await refundDueOf(tx, { id, invoice_id: r.invoice_id, status: r.status }),
  };
}

async function recordDeposit(tx: Tx, ctx: RequestContext, adm: AdmRow, partyId: string, p: z.infer<typeof payBody>) {
  ctx.require('payments.create');
  // allocations: [] keeps the receipt unallocated, so it is not applied to an older bill of the same patient.
  const receipt = await createPayment(ctx, tx, {
    kind: 'receipt', partyId, accountId: p.accountId, mode: p.mode, reference: p.reference, amount: p.amount,
    notes: `Deposit ${adm.admission_no}`, allocations: [],
  } as never);
  await tx.insertInto('clinic_ipd_deposits').values({ tenant_id: ctx.tenantId, admission_id: adm.id, payment_id: receipt.id, amount: p.amount }).execute();
  return receipt;
}

export async function clinicIpdRoutes(app: FastifyInstance) {
  // Wards and beds ---------------------------------------------------------------------------

  app.get('/clinic/ipd/wards', async (req) => {
    const ctx = req.ctx; needView(ctx);
    return ctx.tx(async (tx) => {
      const wards = await tx.selectFrom('clinic_wards').selectAll().where('company_id', '=', ctx.companyId).orderBy('sort_order').orderBy('name').execute();
      const beds = await tx.selectFrom('clinic_beds').selectAll().where('company_id', '=', ctx.companyId).orderBy('bed_no').execute();
      return {
        data: wards.map((w) => ({
          id: w.id, name: w.name, kind: w.kind, sortOrder: w.sort_order, isActive: w.is_active, updatedAt: w.updated_at,
          beds: beds.filter((b) => b.ward_id === w.id).map((b) => ({ id: b.id, bedNo: b.bed_no, dailyRate: b.daily_rate, status: b.status, isActive: b.is_active })),
        })),
      };
    });
  });

  app.post('/clinic/ipd/wards', async (req, reply) => {
    const ctx = req.ctx; needManage(ctx);
    const b = parse(wardCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const dup = await tx.selectFrom('clinic_wards').select('id').where('company_id', '=', ctx.companyId).where(sql`lower(name)`, '=', b.name.toLowerCase()).executeTakeFirst();
      if (dup) throw conflict('A ward with this name exists.', 'DUPLICATE_WARD');
      const row = await tx.insertInto('clinic_wards').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, name: b.name, kind: b.kind, sort_order: b.sortOrder, is_active: b.isActive,
      }).returning(['id', 'name', 'kind']).executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'clinic_ward', row.id, 'create', null, { name: b.name });
      return row;
    });
    return reply.status(201).send(out);
  });

  const patchWard = async (req: { ctx: RequestContext; params: unknown; body: unknown }) => {
    const ctx = req.ctx; needManage(ctx);
    const id = parse(z.uuid(), (req.params as { id: string }).id);
    const b = parse(wardPatch, req.body);
    return ctx.tx(async (tx) => {
      const w = await tx.selectFrom('clinic_wards').select(['id']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!w) throw notFound('Ward');
      if (b.name) {
        const dup = await tx.selectFrom('clinic_wards').select('id').where('company_id', '=', ctx.companyId).where('id', '!=', id).where(sql`lower(name)`, '=', b.name.toLowerCase()).executeTakeFirst();
        if (dup) throw conflict('A ward with this name exists.', 'DUPLICATE_WARD');
      }
      if (b.isActive === false) {
        const live = await tx.selectFrom('clinic_admissions as a').innerJoin('clinic_beds as bd', 'bd.id', 'a.bed_id').select('a.id')
          .where('bd.ward_id', '=', id).where('a.status', '=', 'admitted').limit(1).executeTakeFirst();
        if (live) throw conflict('Patients are admitted in this ward.', 'WARD_IN_USE');
      }
      const set: Record<string, unknown> = {};
      if (b.name !== undefined) set.name = b.name;
      if (b.kind !== undefined) set.kind = b.kind;
      if (b.sortOrder !== undefined) set.sort_order = b.sortOrder;
      if (b.isActive !== undefined) set.is_active = b.isActive;
      if (Object.keys(set).length) await tx.updateTable('clinic_wards').set(set as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_ward', id, 'update', null, { fields: Object.keys(set) });
      const r = await tx.selectFrom('clinic_wards').selectAll().where('id', '=', id).executeTakeFirstOrThrow();
      return { id: r.id, name: r.name, kind: r.kind, sortOrder: r.sort_order, isActive: r.is_active, updatedAt: r.updated_at };
    });
  };
  app.patch<{ Params: { id: string } }>('/clinic/ipd/wards/:id', patchWard as never);
  app.put<{ Params: { id: string } }>('/clinic/ipd/wards/:id', patchWard as never);

  app.post('/clinic/ipd/beds', async (req, reply) => {
    const ctx = req.ctx; needManage(ctx);
    const b = parse(bedCreate, req.body);
    const out = await ctx.tx(async (tx) => {
      const w = await tx.selectFrom('clinic_wards').select('id').where('id', '=', b.wardId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!w) throw notFound('Ward');
      const dup = await tx.selectFrom('clinic_beds').select('id').where('ward_id', '=', b.wardId).where(sql`lower(bed_no)`, '=', b.bedNo.toLowerCase()).executeTakeFirst();
      if (dup) throw conflict('This ward already has a bed with that number.', 'DUPLICATE_BED');
      const row = await tx.insertInto('clinic_beds').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, ward_id: b.wardId, bed_no: b.bedNo, daily_rate: b.dailyRate, is_active: b.isActive,
      }).returning(['id', 'bed_no', 'daily_rate', 'status']).executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'clinic_bed', row.id, 'create', null, { bedNo: b.bedNo });
      return { id: row.id, bedNo: row.bed_no, dailyRate: row.daily_rate, status: row.status };
    });
    return reply.status(201).send(out);
  });

  const patchBed = async (req: { ctx: RequestContext; params: unknown; body: unknown }) => {
    const ctx = req.ctx; needManage(ctx);
    const id = parse(z.uuid(), (req.params as { id: string }).id);
    const b = parse(bedPatch, req.body);
    return ctx.tx(async (tx) => {
      const bed = await loadBed(tx, ctx, id, true);
      const occupied = bed.status === 'occupied';
      if (occupied && (b.status !== undefined || b.isActive === false || b.wardId !== undefined)) {
        throw conflict('A patient is in this bed. Transfer or discharge first.', 'BED_OCCUPIED');
      }
      const wardId = b.wardId ?? bed.ward_id;
      if (b.wardId) {
        const w = await tx.selectFrom('clinic_wards').select('id').where('id', '=', b.wardId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!w) throw notFound('Ward');
      }
      if (b.bedNo !== undefined || b.wardId !== undefined) {
        const no = (b.bedNo ?? bed.bed_no).toLowerCase();
        const dup = await tx.selectFrom('clinic_beds').select('id').where('ward_id', '=', wardId).where('id', '!=', id).where(sql`lower(bed_no)`, '=', no).executeTakeFirst();
        if (dup) throw conflict('This ward already has a bed with that number.', 'DUPLICATE_BED');
      }
      const set: Record<string, unknown> = {};
      if (b.bedNo !== undefined) set.bed_no = b.bedNo;
      if (b.dailyRate !== undefined) set.daily_rate = b.dailyRate;
      if (b.wardId !== undefined) set.ward_id = b.wardId;
      if (b.status !== undefined) set.status = b.status;
      if (b.isActive !== undefined) set.is_active = b.isActive;
      if (Object.keys(set).length) await tx.updateTable('clinic_beds').set(set as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_bed', id, 'update', null, { fields: Object.keys(set) });
      const r = await loadBed(tx, ctx, id);
      return { id: r.id, bedNo: r.bed_no, dailyRate: r.daily_rate, status: r.status, isActive: r.is_active, wardId: r.ward_id };
    });
  };
  app.patch<{ Params: { id: string } }>('/clinic/ipd/beds/:id', patchBed as never);
  app.put<{ Params: { id: string } }>('/clinic/ipd/beds/:id', patchBed as never);

  // Bed board -----------------------------------------------------------------------------------

  app.get('/clinic/ipd/board', async (req) => {
    const ctx = req.ctx; needView(ctx);
    return ctx.tx(async (tx) => {
      const wards = await tx.selectFrom('clinic_wards').selectAll().where('company_id', '=', ctx.companyId).where('is_active', '=', true).orderBy('sort_order').orderBy('name').execute();
      const beds = await tx.selectFrom('clinic_beds').selectAll().where('company_id', '=', ctx.companyId).where('is_active', '=', true).orderBy('bed_no').execute();
      const adms = await admissionSelect(tx).where('a.company_id', '=', ctx.companyId).where('a.status', '=', 'admitted').execute();
      const count = { total: beds.length, available: 0, occupied: 0, cleaning: 0, maintenance: 0 };
      for (const b of beds) count[b.status as keyof typeof count] += 1;
      return {
        counts: count, admitted: adms.length,
        wards: wards.map((w) => ({
          id: w.id, name: w.name, kind: w.kind,
          beds: beds.filter((b) => b.ward_id === w.id).map((b) => {
            const a = adms.find((x) => x.bed_id === b.id);
            return {
              id: b.id, bedNo: b.bed_no, dailyRate: b.daily_rate, status: b.status,
              admission: a ? { id: a.id, number: a.admission_no, patientName: a.patient_name, uhid: a.uhid, doctorName: a.doctor_name, admitDate: a.admit_date, days: daysBetween(a.admit_date, todayIst()) } : null,
            };
          }),
        })),
      };
    });
  });

  // Admissions -----------------------------------------------------------------------------------

  app.get('/clinic/ipd/admissions', async (req) => {
    const ctx = req.ctx; needView(ctx);
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = admissionSelect(tx).where('a.company_id', '=', ctx.companyId);
      if (q.status) base = base.where('a.status', '=', q.status);
      if (q.wardId) base = base.where('b.ward_id', '=', q.wardId);
      if (q.doctorId) base = base.where('a.doctor_id', '=', q.doctorId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('p.name', 'ilike', t), eb('p.uhid', 'ilike', t), eb('p.phone', 'ilike', t), eb('a.admission_no', 'ilike', t)]));
      }
      const totalRow = await tx.selectFrom(base.as('x')).select((eb) => eb.fn.countAll<number>().as('n')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('a.admitted_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { total: Number(totalRow.n), data: rows.map(admissionBrief) };
    });
  });

  app.post('/clinic/ipd/admissions', async (req, reply) => {
    const ctx = req.ctx; needManage(ctx);
    const b = parse(admitBody, req.body);
    if (b.provisionalDiagnosis !== undefined && !ctx.can('clinic.consult')) throw badRequest('Only clinical staff can record a diagnosis.', { provisionalDiagnosis: 'Not allowed' });
    if (b.deposit) ctx.require('payments.create');
    const out = await ctx.tx(async (tx) => {
      const patient = await activeParty(tx, ctx, b.patientId);
      const doc = await tx.selectFrom('clinic_doctors').select(['id', 'is_active']).where('id', '=', b.doctorId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!doc) throw notFound('Doctor');
      if (!doc.is_active) throw badRequest('This doctor is not active.', { doctorId: 'Inactive' });
      const already = await tx.selectFrom('clinic_admissions').select('admission_no').where('patient_id', '=', b.patientId).where('status', '=', 'admitted').executeTakeFirst();
      if (already) throw conflict(`This patient is already admitted (${already.admission_no}).`, 'ALREADY_ADMITTED');
      const bed = await loadBed(tx, ctx, b.bedId, true);
      if (!bed.is_active || !bed.ward_active || bed.status !== 'available') throw conflict('That bed is not available.', 'BED_TAKEN', { status: bed.status });
      const today = todayIst();
      const number = await nextNumber(tx, ctx, 'admission', financialYear(today));
      const row = await tx.insertInto('clinic_admissions').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, admission_no: number, patient_id: b.patientId, doctor_id: b.doctorId, bed_id: b.bedId,
        admit_date: today, expected_days: b.expectedDays ?? null, provisional_diagnosis: b.provisionalDiagnosis ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.insertInto('clinic_bed_stays').values({ tenant_id: ctx.tenantId, admission_id: row.id, bed_id: b.bedId, from_date: today, daily_rate: bed.daily_rate }).execute();
      await tx.updateTable('clinic_beds').set({ status: 'occupied' }).where('id', '=', b.bedId).execute();
      await syncBedCharges(tx, ctx, row.id, today);
      const adm = await loadAdmission(tx, ctx, row.id);
      if (b.deposit) await recordDeposit(tx, ctx, adm, patient.party_id, b.deposit);
      await writeAudit(tx, auditOf(ctx), 'clinic_admission', row.id, 'admit', null, { number, bedId: b.bedId, doctorId: b.doctorId });
      return detail(tx, ctx, row.id);
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/clinic/ipd/admissions/:id', async (req) => {
    const ctx = req.ctx; needView(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => detail(tx, ctx, id));
  });

  app.post<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/transfer', async (req) => {
    const ctx = req.ctx; needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(transferBody, req.body);
    return ctx.tx(async (tx) => {
      const adm = await loadAdmission(tx, ctx, id, true);
      if (adm.status !== 'admitted') throw conflict('This patient is already discharged.', 'NOT_ADMITTED');
      if (adm.bed_id === b.bedId) throw badRequest('The patient is already in that bed.', { bedId: 'Same bed' });
      const bed = await loadBed(tx, ctx, b.bedId, true);
      if (!bed.is_active || !bed.ward_active || bed.status !== 'available') throw conflict('That bed is not available.', 'BED_TAKEN', { status: bed.status });
      const today = todayIst();
      // Nights up to the day before the move stay with the old bed; the move day belongs to the new bed.
      await syncBedCharges(tx, ctx, id, addDays(today, -1));
      const cur = await tx.selectFrom('clinic_bed_stays').select(['id', 'from_date']).where('admission_id', '=', id).where('to_date', 'is', null).executeTakeFirstOrThrow();
      await tx.deleteFrom('clinic_ipd_charges').where('bed_stay_id', '=', cur.id).where('kind', '=', 'bed').where('charge_date', '>=', today).execute();
      await tx.updateTable('clinic_bed_stays').set({ to_date: today }).where('id', '=', cur.id).execute();
      await tx.insertInto('clinic_bed_stays').values({ tenant_id: ctx.tenantId, admission_id: id, bed_id: b.bedId, from_date: today, daily_rate: bed.daily_rate, reason: b.reason ?? null }).execute();
      if (adm.bed_id) await tx.updateTable('clinic_beds').set({ status: 'cleaning' }).where('id', '=', adm.bed_id).execute();
      await tx.updateTable('clinic_beds').set({ status: 'occupied' }).where('id', '=', b.bedId).execute();
      await tx.updateTable('clinic_admissions').set({ bed_id: b.bedId }).where('id', '=', id).execute();
      await syncBedCharges(tx, ctx, id, today);
      await writeAudit(tx, auditOf(ctx), 'clinic_admission', id, 'transfer', null, { from: adm.bed_id, to: b.bedId });
      return detail(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/deposits', async (req, reply) => {
    const ctx = req.ctx; needManage(ctx);
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(payBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const adm = await loadAdmission(tx, ctx, id, true);
      if (adm.status !== 'admitted') throw conflict('This patient is already discharged.', 'NOT_ADMITTED');
      const patient = await activeParty(tx, ctx, adm.patient_id);
      await recordDeposit(tx, ctx, adm, patient.party_id, b);
      await writeAudit(tx, auditOf(ctx), 'clinic_admission', id, 'deposit', null, { amount: b.amount });
      return detail(tx, ctx, id);
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/charges', async (req, reply) => {
    const ctx = req.ctx; needView(ctx);
    const id = parse(z.uuid(), req.params.id);
    const b = parse(chargeBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const adm = await loadAdmission(tx, ctx, id, true);
      if (adm.status !== 'admitted') throw conflict('Charges can only be added while the patient is admitted.', 'NOT_ADMITTED');
      const date = b.chargeDate ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { chargeDate: 'In the future' });
      if (date < adm.admit_date) throw badRequest('Date is before the admission.', { chargeDate: 'Before admission' });
      let description = b.description ?? '';
      let rate = b.rate;
      let itemId: string | null = null;
      if (b.itemId) {
        const item = await tx.selectFrom('items').select(['id', 'name', 'sale_price', 'is_active']).where('id', '=', b.itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!item) throw badRequest('Item not found.', { itemId: 'Not found' });
        if (!item.is_active) throw badRequest('This item is inactive.', { itemId: 'Inactive' });
        itemId = item.id;
        description = description || item.name;
        rate = rate ?? item.sale_price;
      }
      if (!description) throw badRequest('Say what the charge is for.', { description: 'Required' });
      if (rate === undefined) throw badRequest('Enter a rate.', { rate: 'Required' });
      const row = await tx.insertInto('clinic_ipd_charges').values({
        tenant_id: ctx.tenantId, admission_id: id, charge_date: date, kind: b.kind, item_id: itemId, description, qty: b.qty, rate,
        amount: round2(b.qty * rate), created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'clinic_admission', id, 'charge', null, { chargeId: row.id, kind: b.kind, amount: round2(b.qty * rate) });
      return detail(tx, ctx, id);
    });
    return reply.status(201).send(out);
  });

  app.post<{ Params: { id: string; chargeId: string } }>('/clinic/ipd/admissions/:id/charges/:chargeId/void', async (req) => {
    const ctx = req.ctx; needManage(ctx);
    const id = parse(z.uuid(), req.params.id);
    const chargeId = parse(z.uuid(), req.params.chargeId);
    const b = parse(z.object({ reason: z.string().trim().min(1, 'Give a reason').max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const adm = await loadAdmission(tx, ctx, id, true);
      if (adm.status !== 'admitted') throw conflict('The stay is already billed.', 'NOT_ADMITTED');
      const c = await tx.selectFrom('clinic_ipd_charges').select(['id', 'kind', 'is_void']).where('id', '=', chargeId).where('admission_id', '=', id).executeTakeFirst();
      if (!c) throw notFound('Charge');
      if (c.kind === 'bed') throw badRequest('Bed charges follow the bed stays. Transfer the patient to change them.', { chargeId: 'Bed charge' });
      if (c.is_void) throw conflict('This charge is already removed.', 'ALREADY_VOID');
      await tx.updateTable('clinic_ipd_charges').set({ is_void: true, void_reason: b.reason }).where('id', '=', chargeId).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_admission', id, 'void_charge', null, { chargeId });
      return detail(tx, ctx, id);
    });
  });

  app.post<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/bed-charges', async (req) => {
    const ctx = req.ctx; needView(ctx);
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const adm = await loadAdmission(tx, ctx, id, true);
      if (adm.status !== 'admitted') throw conflict('This patient is already discharged.', 'NOT_ADMITTED');
      const added = await syncBedCharges(tx, ctx, id, todayIst());
      return { added, admission: await detail(tx, ctx, id) };
    });
  });

  // Daily run for every admitted patient (the "post today's bed charges" button on the board).
  app.post('/clinic/ipd/bed-charges/run', async (req) => {
    const ctx = req.ctx; needView(ctx);
    return ctx.tx(async (tx) => {
      const adms = await tx.selectFrom('clinic_admissions').select('id').where('company_id', '=', ctx.companyId).where('status', '=', 'admitted').forUpdate().execute();
      let added = 0;
      for (const a of adms) added += await syncBedCharges(tx, ctx, a.id, todayIst());
      return { admissions: adms.length, added };
    });
  });

  const patchSummary = async (req: { ctx: RequestContext; params: unknown; body: unknown }) => {
    const ctx = req.ctx; ctx.require('clinic.consult');
    const id = parse(z.uuid(), (req.params as { id: string }).id);
    const b = parse(summaryPatch, req.body);
    return ctx.tx(async (tx) => {
      const adm = await loadAdmission(tx, ctx, id, true);
      assertFresh(adm.updated_at, b.expectedUpdatedAt, 'admission');
      const set: Record<string, unknown> = {};
      if (b.diagnosis !== undefined) set.diagnosis = b.diagnosis;
      if (b.treatment !== undefined) set.treatment = b.treatment;
      if (b.advice !== undefined) set.advice = b.advice;
      if (b.condition !== undefined) set.condition = b.condition;
      if (b.followupDate !== undefined) set.followup_date = b.followupDate;
      if (Object.keys(set).length) await tx.updateTable('clinic_admissions').set(set as never).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_admission', id, 'summary', null, { fields: Object.keys(set) });
      return detail(tx, ctx, id);
    });
  };
  app.patch<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/summary', patchSummary as never);
  app.put<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/summary', patchSummary as never);

  // Discharge and final bill ---------------------------------------------------------------------

  app.post<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/discharge', async (req) => {
    const ctx = req.ctx; needManage(ctx);
    ctx.require('invoices.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(dischargeBody, req.body);
    const hasSummary = [b.diagnosis, b.treatment, b.advice, b.condition, b.followupDate].some((v) => v !== undefined);
    if (hasSummary) ctx.require('clinic.consult');
    if (b.payment) ctx.require('payments.create');
    return ctx.tx(async (tx) => {
      const adm = await loadAdmission(tx, ctx, id, true);
      if (adm.status !== 'admitted') throw conflict('This patient is already discharged.', 'NOT_ADMITTED');
      const diagnosis = b.diagnosis !== undefined ? b.diagnosis : adm.diagnosis;
      const treatment = b.treatment !== undefined ? b.treatment : adm.treatment;
      if (!diagnosis || !treatment) {
        throw badRequest('Write the discharge summary first: diagnosis and treatment are needed.', { diagnosis: diagnosis ? undefined : 'Required', treatment: treatment ? undefined : 'Required' });
      }
      const today = todayIst();
      const patient = await activeParty(tx, ctx, adm.patient_id);
      const doc = await tx.selectFrom('clinic_doctors').select('name').where('id', '=', adm.doctor_id).executeTakeFirstOrThrow();

      await tx.updateTable('clinic_bed_stays').set({ to_date: today }).where('admission_id', '=', id).where('to_date', 'is', null).execute();
      await syncBedCharges(tx, ctx, id, today);
      // A stay that starts and ends on one day is still billed one day.
      const bedCount = await tx.selectFrom('clinic_ipd_charges').select((eb) => eb.fn.countAll<number>().as('n')).where('admission_id', '=', id).where('kind', '=', 'bed').where('is_void', '=', false).executeTakeFirstOrThrow();
      if (Number(bedCount.n) === 0) {
        const last = await tx.selectFrom('clinic_bed_stays as s').innerJoin('clinic_beds as bd', 'bd.id', 's.bed_id').innerJoin('clinic_wards as w', 'w.id', 'bd.ward_id')
          .select(['s.id', 's.from_date', 's.daily_rate', 'bd.bed_no', 'w.name as ward_name']).where('s.admission_id', '=', id).orderBy('s.from_date', 'desc').orderBy('s.created_at', 'desc').executeTakeFirstOrThrow();
        await tx.insertInto('clinic_ipd_charges').values({
          tenant_id: ctx.tenantId, admission_id: id, charge_date: last.from_date, kind: 'bed', description: `Bed ${last.bed_no}, ${last.ward_name}`,
          qty: 1, rate: last.daily_rate, amount: last.daily_rate, bed_stay_id: last.id, created_by: ctx.userId,
        }).execute();
      }

      // Invoice lines: bed nights grouped per bed stay, then each service and medicine.
      const bedItem = await serviceItem(tx, ctx, 'CLINIC-IPD-BED', 'In-patient bed charges');
      const svcItem = await serviceItem(tx, ctx, 'CLINIC-IPD-SERVICE', 'Hospital services');
      const charges = await tx.selectFrom('clinic_ipd_charges').selectAll().where('admission_id', '=', id).where('is_void', '=', false).orderBy('charge_date').orderBy('created_at').execute();
      const lines: { itemId: string; qty: number; rate: number; description: string }[] = [];
      const stays = await tx.selectFrom('clinic_bed_stays').select(['id', 'from_date']).where('admission_id', '=', id).orderBy('from_date').orderBy('created_at').execute();
      for (const s of stays) {
        const nights = charges.filter((c) => c.kind === 'bed' && c.bed_stay_id === s.id);
        if (!nights.length) continue;
        lines.push({ itemId: bedItem, qty: nights.length, rate: nights[0]!.rate, description: `${nights[0]!.description}, ${nights.length} day${nights.length === 1 ? '' : 's'} from ${nights[0]!.charge_date}` });
      }
      for (const c of charges.filter((x) => x.kind !== 'bed')) {
        lines.push({ itemId: c.item_id ?? svcItem, qty: c.qty, rate: c.rate, description: c.description });
      }

      let locationId = b.locationId;
      if (!locationId) {
        const locs = await tx.selectFrom('locations').select('id').where('company_id', '=', ctx.companyId).where('is_active', '=', true).orderBy('created_at').execute();
        locationId = locs.find((l) => ctx.canAccessLocation(l.id))?.id;
        if (!locationId) throw badRequest('Add a location before billing.', { locationId: 'Required' });
      }
      const invoice = await createInvoice(ctx, tx, {
        locationId, partyId: patient.party_id, invoiceDate: today, lines,
        notes: `In-patient stay ${adm.admission_no}, ${adm.admit_date} to ${today}, ${doc.name}. UHID ${patient.uhid}`, custom: undefined,
      } as never);

      // Deposits settle the bill, oldest first; what is left stays as the patient's credit.
      let due = round2(invoice.total);
      const deps = (await depositRows(tx, id)).filter((d) => d.status !== 'cancelled');
      let applied = 0;
      for (const d of deps) {
        const take = round2(Math.min(due, d.amount));
        if (take <= 0) continue;
        await tx.insertInto('payment_allocations').values({ tenant_id: ctx.tenantId, payment_id: d.payment_id, doc_type: 'invoice', doc_id: invoice.id, amount: take }).execute();
        due = round2(due - take);
        applied = round2(applied + take);
      }
      if (applied > 0) await tx.updateTable('invoices').set((eb) => ({ amount_paid: eb('amount_paid', '+', applied) })).where('id', '=', invoice.id).execute();
      const depositTotal = round2(deps.reduce((s, d) => s + d.amount, 0));

      if (b.payment) {
        if (b.payment.amount > due + 0.005) throw badRequest(`Only ₹${due.toFixed(2)} is due.`, { payment: 'More than the balance' });
        await createPayment(ctx, tx, {
          kind: 'receipt', partyId: patient.party_id, accountId: b.payment.accountId, mode: b.payment.mode, reference: b.payment.reference,
          amount: b.payment.amount, notes: `Discharge ${adm.admission_no}`, allocations: [{ docId: invoice.id, amount: b.payment.amount }],
        } as never);
        due = round2(due - b.payment.amount);
      }
      if (due > 0.005 && !b.allowCredit) throw conflict(`₹${due.toFixed(2)} is still due. Take payment or allow credit.`, 'BALANCE_DUE', { due });

      const set: Record<string, unknown> = { status: 'discharged', discharge_date: today, discharged_at: new Date(), invoice_id: invoice.id, diagnosis, treatment };
      if (b.advice !== undefined) set.advice = b.advice;
      if (b.condition !== undefined) set.condition = b.condition;
      if (b.followupDate !== undefined) set.followup_date = b.followupDate;
      await tx.updateTable('clinic_admissions').set(set as never).where('id', '=', id).execute();
      if (adm.bed_id) await tx.updateTable('clinic_beds').set({ status: 'cleaning' }).where('id', '=', adm.bed_id).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_admission', id, 'discharge', null, { invoiceId: invoice.id, total: invoice.total });
      return {
        admission: await detail(tx, ctx, id), invoice: { id: invoice.id, number: invoice.number, total: invoice.total },
        depositsApplied: applied, balanceDue: due > 0.005 ? due : 0, refundDue: round2(depositTotal - applied) > 0.005 ? round2(depositTotal - applied) : 0, // same figure refundDueOf returns later
      };
    });
  });

  app.post<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/refund', async (req, reply) => {
    const ctx = req.ctx; needManage(ctx);
    ctx.require('payments.create');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(payBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const adm = await loadAdmission(tx, ctx, id, true);
      if (adm.status !== 'discharged') throw conflict('Refund the deposit after discharge.', 'NOT_DISCHARGED');
      const due = await refundDueOf(tx, adm);
      if (b.amount > due + 0.005) throw badRequest(`Only ₹${due.toFixed(2)} of deposit is left to refund.`, { amount: 'More than the refund due' });
      const patient = await activeParty(tx, ctx, adm.patient_id);
      const pay = await createPayment(ctx, tx, {
        kind: 'payment', partyId: patient.party_id, accountId: b.accountId, mode: b.mode, reference: b.reference, amount: b.amount,
        notes: `Deposit refund ${adm.admission_no}`, allocations: [],
      } as never, { customerRefund: true });
      await tx.insertInto('clinic_ipd_refunds').values({ tenant_id: ctx.tenantId, admission_id: id, payment_id: pay.id, amount: b.amount }).execute();
      await writeAudit(tx, auditOf(ctx), 'clinic_admission', id, 'refund', null, { amount: b.amount, paymentId: pay.id });
      return detail(tx, ctx, id);
    });
    return reply.status(201).send(out);
  });

  app.get<{ Params: { id: string } }>('/clinic/ipd/admissions/:id/discharge-summary', async (req) => {
    const ctx = req.ctx; ctx.require('clinic.consult');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const a = await loadAdmission(tx, ctx, id);
      const full = await admissionSelect(tx).where('a.id', '=', id).executeTakeFirstOrThrow();
      const p = await tx.selectFrom('clinic_patients').selectAll().where('id', '=', a.patient_id).executeTakeFirstOrThrow();
      const doc = await tx.selectFrom('clinic_doctors').select(['name', 'speciality', 'registration_no']).where('id', '=', a.doctor_id).executeTakeFirstOrThrow();
      const co = await tx.selectFrom('companies').select(['name', 'legal_name', 'address', 'phone', 'email', 'pincode']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const meds = await tx.selectFrom('clinic_ipd_charges').select(['description', 'qty']).where('admission_id', '=', id).where('kind', '=', 'medicine').where('is_void', '=', false).orderBy('charge_date').execute();
      return {
        hospital: { name: co.legal_name || co.name, address: co.address, pincode: co.pincode, phone: co.phone, email: co.email },
        doctor: { name: doc.name, speciality: doc.speciality, registrationNo: doc.registration_no },
        patient: { uhid: p.uhid, name: p.name, sex: p.sex, dob: p.dob, ageYears: p.age_years, phone: p.phone, address: p.address, bloodGroup: p.blood_group, allergies: p.allergies },
        admission: { number: a.admission_no, status: a.status, admitDate: a.admit_date, dischargeDate: a.discharge_date, days: admissionBrief(full).days, ward: full.ward_name, bed: full.bed_no },
        provisionalDiagnosis: a.provisional_diagnosis,
        summary: { diagnosis: a.diagnosis, treatment: a.treatment, advice: a.advice, condition: a.condition, followupDate: a.followup_date },
        medicines: meds.map((m) => ({ name: m.description, qty: m.qty })),
      };
    });
  });
}

documentRoute('POST', '/clinic/ipd/wards', { body: wardCreate });
documentRoute('PATCH', '/clinic/ipd/wards/:id', { body: wardPatch });
documentRoute('POST', '/clinic/ipd/beds', { body: bedCreate });
documentRoute('PATCH', '/clinic/ipd/beds/:id', { body: bedPatch });
documentRoute('POST', '/clinic/ipd/admissions', { body: admitBody });
documentRoute('POST', '/clinic/ipd/admissions/:id/transfer', { body: transferBody });
documentRoute('POST', '/clinic/ipd/admissions/:id/deposits', { body: payBody });
documentRoute('POST', '/clinic/ipd/admissions/:id/refund', { body: payBody });
documentRoute('POST', '/clinic/ipd/admissions/:id/charges', { body: chargeBody });
documentRoute('PATCH', '/clinic/ipd/admissions/:id/summary', { body: summaryPatch });
documentRoute('POST', '/clinic/ipd/admissions/:id/discharge', { body: dischargeBody });
