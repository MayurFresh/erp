// Demo data for memberships and job cards. Not called from seed.ts; the lead wires it in.
// No invoices are written here: bills come from the app so numbering, tax and the ledger stay correct.
import type { Tx } from './database.ts';
import { addDays, financialYear, todayIst } from '../lib/dates.ts';
import { nextNumber } from '../lib/series.ts';
import { addMonths } from '../modules/services-common.ts';

export interface ServicesSeedWho { tenantId: string; companyId: string; userId: string }

async function partyOf(tx: Tx, w: ServicesSeedWho, name: string, phone: string, address: string | null) {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', w.companyId).executeTakeFirstOrThrow();
  return tx.insertInto('parties').values({
    tenant_id: w.tenantId, company_id: w.companyId, type: 'customer', name, phone, state_code: company.state_code, address,
    gstin: null, email: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
  }).returning('id').executeTakeFirstOrThrow();
}

async function itemOf(tx: Tx, w: ServicesSeedWho, name: string, sku: string, price: number, gst: number, tracked: boolean, unit = 'NOS') {
  const found = await tx.selectFrom('items').select('id').where('company_id', '=', w.companyId).where('sku', '=', sku).executeTakeFirst();
  if (found) return found.id;
  const row = await tx.insertInto('items').values({
    tenant_id: w.tenantId, company_id: w.companyId, name, sku, hsn_code: tracked ? '8708' : '999799', unit, gst_rate: gst,
    sale_price: price, purchase_price: tracked ? Math.round(price * 0.65) : 0, track_stock: tracked,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id;
}

/** Gym or salon plans, ten members in every state, and a few visits. Pass society: true for flats and maintenance. */
export async function seedMembershipsDemo(tx: Tx, w: ServicesSeedWho, opts: { society?: boolean } = {}) {
  const today = todayIst();
  const fy = financialYear(today);
  const plans: { id: string; months: number; price: number; perSqft: boolean }[] = [];
  const defs = opts.society
    ? [{ name: 'Monthly maintenance', billing: 'monthly', basis: 'per_sqft', unit: 'months', count: 1, price: 3, gst: 0, join: 0, freeze: 0 }]
    : [
      { name: 'Monthly', billing: 'upfront', basis: 'fixed', unit: 'months', count: 1, price: 1500, gst: 18, join: 500, freeze: 5 },
      { name: 'Quarterly', billing: 'upfront', basis: 'fixed', unit: 'months', count: 3, price: 4000, gst: 18, join: 500, freeze: 10 },
      { name: 'Annual', billing: 'upfront', basis: 'fixed', unit: 'months', count: 12, price: 12000, gst: 18, join: 0, freeze: 30 },
    ];
  for (const d of defs) {
    const item = await itemOf(tx, w, d.name, `MEM-${d.name.slice(0, 4).toUpperCase()}`, d.price, d.gst, false, d.basis === 'per_sqft' ? 'SQFT' : 'NOS');
    const row = await tx.insertInto('mem_plans').values({
      tenant_id: w.tenantId, company_id: w.companyId, item_id: item, name: d.name, billing: d.billing, rate_basis: d.basis,
      duration_unit: d.unit, duration_count: d.count, price: d.price, joining_fee: d.join, freeze_days: d.freeze,
    }).returning('id').executeTakeFirstOrThrow();
    plans.push({ id: row.id, months: d.count, price: d.price, perSqft: d.basis === 'per_sqft' });
  }
  const people = opts.society
    ? [['Mehta household', 'A', '101', 1050, 'owner'], ['Shah household', 'A', '102', 1050, 'tenant'], ['Patel household', 'A', '201', 1200, 'owner'],
      ['Desai household', 'B', '101', 800, 'owner'], ['Joshi household', 'B', '202', 800, 'tenant'], ['Iyer household', 'B', '301', 950, 'owner']]
    : [['Aarav Mehta', null, null, null, null], ['Isha Patel', null, null, null, null], ['Rohan Shah', null, null, null, null],
      ['Neha Desai', null, null, null, null], ['Vikram Joshi', null, null, null, null], ['Priya Iyer', null, null, null, null],
      ['Kabir Khan', null, null, null, null], ['Sana Qureshi', null, null, null, null], ['Dev Trivedi', null, null, null, null]];
  const offsets = [0, -10, -25, -40, -75, -120, -5, -20, -200];
  let i = 0;
  const memberIds: string[] = [];
  for (const [name, wing, flat, area, occ] of people as [string, string | null, string | null, number | null, string | null][]) {
    const phone = `98250${String(10000 + i * 137).slice(0, 5)}`;
    const party = await partyOf(tx, w, name, phone, flat ? `${wing} ${flat}` : null);
    const m = await tx.insertInto('mem_members').values({
      tenant_id: w.tenantId, company_id: w.companyId, party_id: party.id, member_no: await nextNumber(tx, w, 'member', fy), name, phone,
      emergency_name: flat ? null : 'Family', emergency_phone: flat ? null : '9825000001', flat_no: flat, wing, area_sqft: area, occupancy: occ,
      created_by: w.userId,
    }).returning('id').executeTakeFirstOrThrow();
    memberIds.push(m.id);
    const plan = plans[i % plans.length]!;
    const start = opts.society ? addDays(today, -200) : addDays(today, offsets[i % offsets.length]!);
    const end = plan.perSqft ? null : addDays(addMonths(start, plan.months), -1);
    await tx.insertInto('mem_subscriptions').values({
      tenant_id: w.tenantId, company_id: w.companyId, member_id: m.id, plan_id: plan.id, start_date: start, end_date: end,
      price: plan.price, created_by: w.userId,
    }).execute();
    i += 1;
  }
  if (!opts.society) {
    for (const id of memberIds.slice(0, 4)) {
      for (const d of [0, 1, 3]) {
        await tx.insertInto('mem_visits').values({ tenant_id: w.tenantId, company_id: w.companyId, member_id: id, visit_date: addDays(today, -d), checked_by: w.userId }).execute();
      }
    }
  }
  return { plans: plans.length, members: memberIds.length };
}

/** Parts and labour items, and six job cards from received to delivered. */
export async function seedJobCardsDemo(tx: Tx, w: ServicesSeedWho, opts: { technicianId?: string } = {}) {
  const today = todayIst();
  const fy = financialYear(today);
  const loc = await tx.selectFrom('locations').select('id').where('company_id', '=', w.companyId).orderBy('created_at').executeTakeFirstOrThrow();
  const pad = await itemOf(tx, w, 'Brake pad set', 'JC-BRAKE-PAD', 1200, 18, true);
  const oil = await itemOf(tx, w, 'Engine oil 4L', 'JC-OIL-4L', 1800, 18, true);
  const screen = await itemOf(tx, w, 'Phone screen', 'JC-SCREEN', 3500, 18, true);
  const service = await itemOf(tx, w, 'General service labour', 'JC-LAB-SERVICE', 800, 18, false);
  const fit = await itemOf(tx, w, 'Brake fitting labour', 'JC-LAB-BRAKE', 500, 18, false);
  const repl = await itemOf(tx, w, 'Screen replacement labour', 'JC-LAB-SCREEN', 600, 18, false);
  const jobs: { st: string; kind: string; veh?: string; make: string; model: string; who: string; phone: string; complaint: string; lines: [string, string, number, number][]; days: number; serial?: string }[] = [
    { st: 'received', kind: 'vehicle', veh: 'GJ01AB4521', make: 'Maruti', model: 'Swift', who: 'Karan Shah', phone: '9825012345', complaint: 'Brake noise while stopping', lines: [], days: 3 },
    { st: 'estimate_sent', kind: 'vehicle', veh: 'GJ05CD7788', make: 'Hyundai', model: 'i20', who: 'Meera Joshi', phone: '9825099001', complaint: 'Service due, engine oil leak', lines: [['labour', service, 1, 800], ['part', oil, 1, 1800]], days: 2 },
    { st: 'approved', kind: 'vehicle', veh: 'GJ01EF9090', make: 'Honda', model: 'City', who: 'Nilesh Patel', phone: '9898011122', complaint: 'Front brake pads worn', lines: [['part', pad, 1, 1200], ['labour', fit, 1, 500]], days: 1 },
    { st: 'in_progress', kind: 'vehicle', veh: 'GJ18GH1234', make: 'Tata', model: 'Nexon', who: 'Sana Qureshi', phone: '9904123456', complaint: 'Full service', lines: [['labour', service, 1, 800], ['part', oil, 1, 1800]], days: 1 },
    { st: 'ready', kind: 'device', make: 'Samsung', model: 'Galaxy A54', serial: '356789012345678', who: 'Dev Trivedi', phone: '9427011223', complaint: 'Cracked screen', lines: [['part', screen, 1, 3500], ['labour', repl, 1, 600]], days: 0 },
    { st: 'received', kind: 'device', make: 'Apple', model: 'iPhone 12', serial: '353456789012345', who: 'Pooja Mehta', phone: '9879055667', complaint: 'Battery drains fast', lines: [], days: 4 },
  ];
  let n = 0;
  for (const j of jobs) {
    const party = await partyOf(tx, w, j.who, j.phone, null);
    const now = new Date();
    const job = await tx.insertInto('job_cards').values({
      tenant_id: w.tenantId, company_id: w.companyId, location_id: loc.id, party_id: party.id, number: await nextNumber(tx, w, 'job_card', fy),
      kind: j.kind, vehicle_no: j.veh ?? null, make: j.make, model: j.model, odometer: j.kind === 'vehicle' ? 30000 + n * 4100 : null,
      serial_no: j.serial ?? null, complaints: j.complaint, accessories: j.kind === 'vehicle' ? 'Spare wheel, jack' : 'Charger',
      promised_date: addDays(today, j.days), technician_id: ['in_progress', 'ready', 'approved'].includes(j.st) ? opts.technicianId ?? null : null,
      status: j.st, estimate_sent_at: j.st === 'received' ? null : now, approved_at: ['approved', 'in_progress', 'ready'].includes(j.st) ? now : null,
      approved_by: ['approved', 'in_progress', 'ready'].includes(j.st) ? 'On phone' : null,
      started_at: ['in_progress', 'ready'].includes(j.st) ? now : null, ready_at: j.st === 'ready' ? now : null, created_by: w.userId,
    }).returning('id').executeTakeFirstOrThrow();
    let ln = 1;
    for (const [kind, item, qty, rate] of j.lines) {
      await tx.insertInto('job_card_lines').values({
        tenant_id: w.tenantId, job_card_id: job.id, line_no: ln++, kind, item_id: item, qty, rate,
        issued_at: kind === 'part' && ['in_progress', 'ready'].includes(j.st) ? now : null,
        issued_by: kind === 'part' && ['in_progress', 'ready'].includes(j.st) ? w.userId : null,
      }).execute();
    }
    n += 1;
  }
  return { jobs: jobs.length };
}
