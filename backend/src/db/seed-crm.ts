// Demo leads, deals, follow-ups, contact persons and a monthly target. Run by seed-demo-accounts.ts inside withTenant.
// Phone numbers are placeholders (9000000001 style). No quotations or invoices are made here.
import type { Tx } from './database.ts';
import { addDays, todayIst } from '../lib/dates.ts';
import { ensureStages } from '../modules/crm-common.ts';

export interface CrmSeedWho { tenantId: string; companyId: string; userId: string }

export async function seedCrmDemo(tx: Tx, w: CrmSeedWho) {
  const had = await tx.selectFrom('crm_leads').select('id').where('company_id', '=', w.companyId).limit(1).executeTakeFirst();
  if (had) return;
  const ctx = { tenantId: w.tenantId, companyId: w.companyId, userId: w.userId } as never;
  const stages = await ensureStages(tx, ctx);
  const stage = (name: string) => stages.find((s) => s.name === name) ?? stages.find((s) => s.kind === 'open')!;
  const won = stages.find((s) => s.kind === 'won')!;
  const lostStage = stages.find((s) => s.kind === 'lost')!;
  const today = todayIst();
  const at = (date: string, hhmm: string) => new Date(`${date}T${hhmm}:00+05:30`);
  const ago = (days: number) => new Date(Date.now() - days * 86_400_000);

  // Customers: reuse the company's own, add two when it has fewer than four.
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', w.companyId).executeTakeFirstOrThrow();
  let parties = await tx.selectFrom('parties').select(['id', 'name']).where('company_id', '=', w.companyId)
    .where('type', 'in', ['customer', 'both']).orderBy('created_at').limit(4).execute();
  const extra = [['Shree Ganesh Traders', '9000000041'], ['Patel Engineering Works', '9000000042'], ['Mehta and Sons', '9000000043'], ['Om Sai Enterprises', '9000000044']];
  for (const [name, phone] of extra) {
    if (parties.length >= 4) break;
    const row = await tx.insertInto('parties').values({
      tenant_id: w.tenantId, company_id: w.companyId, type: 'customer', name: name!, phone: phone!, state_code: company.state_code,
      gstin: null, email: null, address: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
    }).returning(['id', 'name']).executeTakeFirstOrThrow();
    parties = [...parties, row];
  }
  const P = (i: number) => parties[i % parties.length]!.id;

  for (const [i, c] of [[0, [['Anil Shah', 'Purchase manager', '9000000051', true], ['Meena Shah', 'Accounts', '9000000052', false]]],
    [1, [['Kiran Patel', 'Owner', '9000000053', true]]]] as [number, [string, string, string, boolean][]][]) {
    for (const [name, designation, phone, primary] of c) {
      await tx.insertInto('party_contacts').values({
        tenant_id: w.tenantId, company_id: w.companyId, party_id: P(i), name, designation, phone, is_primary: primary,
      }).execute();
    }
  }

  // Leads: 8 across sources.
  const leadDefs = [
    { name: 'Rakesh Agarwal', co: 'Agarwal Hardware', phone: '9000000001', source: 'indiamart', ref: 'IM-DEMO-1001', city: 'Surat', st: '24', value: 150000, status: 'new', req: 'Needs 200 bags of cement and 2 tonnes TMT bar every month', age: 0.2 },
    { name: 'Sunita Verma', co: 'Verma Interiors', phone: '9000000002', source: 'indiamart', ref: 'IM-DEMO-1002', city: 'Indore', st: '23', value: 80000, status: 'contacted', req: 'Wants a rate for plywood and laminates', age: 2 },
    { name: 'Joshi Brothers', co: null, phone: '9000000003', source: 'justdial', ref: null, city: 'Pune', st: '27', value: 45000, status: 'qualified', req: 'Monthly supply for a small workshop', age: 4 },
    { name: 'Farah Khan', co: 'Khan Caterers', phone: '9000000004', source: 'website', ref: null, city: 'Hyderabad', st: '36', value: 60000, status: 'new', req: 'Asked for a quote through the website form', age: 1 },
    { name: 'Dinesh Rao', co: null, phone: '9000000005', source: 'walk_in', ref: null, city: 'Mysuru', st: '29', value: 36000, status: 'qualified', req: 'Walked in, wants a bulk price for 40 pieces', age: 6 },
    { name: 'Neha Kulkarni', co: 'Kulkarni Clinic', phone: '9000000006', source: 'referral', ref: null, city: 'Nashik', st: '27', value: 245000, status: 'converted', req: 'Referred by an existing customer', age: 12 },
    { name: 'Imran Sheikh', co: null, phone: '9000000007', source: 'phone', ref: null, city: 'Jaipur', st: '08', value: 20000, status: 'lost', req: 'Asked for a very low price', age: 15 },
    { name: 'Lakshmi Iyer', co: 'Iyer Stores', phone: '9000000008', source: 'whatsapp', ref: null, city: 'Chennai', st: '33', value: 95000, status: 'contacted', req: 'Messaged on WhatsApp about a trial order', age: 3 },
  ];
  const leadIds: string[] = [];
  for (const l of leadDefs) {
    const created = ago(l.age);
    const row = await tx.insertInto('crm_leads').values({
      tenant_id: w.tenantId, company_id: w.companyId, name: l.name, company_name: l.co, phone: l.phone, city: l.city, state_code: l.st,
      requirement: l.req, estimated_value: l.value, source: l.source, source_ref: l.ref, owner_id: w.userId, status: l.status,
      lost_reason: l.status === 'lost' ? 'Price too high' : null, first_contact_at: l.status === 'new' ? null : new Date(created.getTime() + 3_600_000),
      created_by: w.userId, created_at: created,
    }).returning('id').executeTakeFirstOrThrow();
    leadIds.push(row.id);
  }

  // Deals: three open, two won and one lost this month.
  const dealDefs = [
    { title: 'Monthly hardware supply', value: 36000, stage: stage('New'), party: 0, lead: null as number | null, status: 'open' },
    { title: 'Clinic fit-out materials', value: 245000, stage: stage('Quotation sent'), party: 1, lead: 5, status: 'open' },
    { title: 'Annual rate contract', value: 620000, stage: stage('Negotiation'), party: 2, lead: null, status: 'open' },
    { title: 'Workshop tools order', value: 85000, stage: won, party: 3, lead: null, status: 'won' },
    { title: 'Showroom lighting', value: 120000, stage: won, party: 0, lead: null, status: 'won' },
    { title: 'Bulk packaging', value: 150000, stage: lostStage, party: 1, lead: null, status: 'lost' },
  ];
  const dealIds: string[] = [];
  for (const [i, d] of dealDefs.entries()) {
    const created = ago(10 - i);
    const row = await tx.insertInto('crm_deals').values({
      tenant_id: w.tenantId, company_id: w.companyId, title: d.title, party_id: P(d.party), lead_id: d.lead === null ? null : leadIds[d.lead]!,
      stage_id: d.stage.id, value: d.value, owner_id: w.userId, status: d.status, created_by: w.userId, created_at: created,
      won_at: d.status === 'won' ? ago(1 + i % 2) : null, lost_at: d.status === 'lost' ? ago(2) : null,
      lost_reason: d.status === 'lost' ? 'Chose another supplier' : null, stage_changed_at: d.status === 'open' ? ago(2 + i) : ago(1),
      expected_close: d.status === 'open' ? addDays(today, 10 + i * 5) : null,
    }).returning('id').executeTakeFirstOrThrow();
    dealIds.push(row.id);
    await tx.insertInto('crm_deal_stage_history').values({ tenant_id: w.tenantId, deal_id: row.id, from_stage_id: null, to_stage_id: stage('New').id, changed_by: w.userId, changed_at: created }).execute();
    if (d.stage.id !== stage('New').id) {
      await tx.insertInto('crm_deal_stage_history').values({ tenant_id: w.tenantId, deal_id: row.id, from_stage_id: stage('New').id, to_stage_id: d.stage.id, changed_by: w.userId, changed_at: ago(1.5) }).execute();
    }
  }
  await tx.updateTable('crm_leads').set({ party_id: P(1), deal_id: dealIds[1]!, converted_at: ago(8) }).where('id', '=', leadIds[5]!).execute();

  // Follow-ups: 2 overdue, 3 due today, 3 coming up.
  const fu: [string, string, Date, { lead?: number; deal?: number }][] = [
    ['call', 'Call back about the rate list', at(addDays(today, -1), '11:00'), { lead: 1 }],
    ['call', 'Chase the signed quotation', at(addDays(today, -3), '16:00'), { deal: 1 }],
    ['call', 'Introduce our range', at(today, '23:00'), { lead: 0 }],
    ['visit', 'Visit the workshop', at(today, '23:15'), { lead: 2 }],
    ['whatsapp', 'Send catalogue and price list', at(today, '23:30'), { lead: 7 }],
    ['meeting', 'Negotiation meeting at their office', at(addDays(today, 2), '15:00'), { deal: 2 }],
    ['call', 'Confirm the quote for the website enquiry', at(addDays(today, 3), '12:00'), { lead: 3 }],
    ['task', 'Prepare sample box', at(addDays(today, 5), '10:00'), { deal: 0 }],
  ];
  for (const [kind, subject, due, ref] of fu) {
    await tx.insertInto('crm_activities').values({
      tenant_id: w.tenantId, company_id: w.companyId, kind, subject, due_at: due, owner_id: w.userId, created_by: w.userId,
      lead_id: ref.lead === undefined ? null : leadIds[ref.lead]!, deal_id: ref.deal === undefined ? null : dealIds[ref.deal]!,
    }).execute();
  }
  // A few done entries for the history.
  for (const [kind, subject, outcome, lead] of [['call', 'First call', 'Interested, asked for a quote', 1], ['call', 'Intro call', 'Will confirm next week', 2]] as [string, string, string, number][]) {
    await tx.insertInto('crm_activities').values({
      tenant_id: w.tenantId, company_id: w.companyId, kind, subject, outcome, done_at: ago(1), owner_id: w.userId, created_by: w.userId, lead_id: leadIds[lead]!, duration_min: 8,
    }).execute();
  }

  await tx.insertInto('crm_targets').values({ tenant_id: w.tenantId, company_id: w.companyId, user_id: null, month: `${today.slice(0, 7)}-01`, amount: 500000 }).execute();
}
