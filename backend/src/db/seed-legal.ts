// Demo practice for an advocate: clients, matters at different stages, hearings, deadlines and billable work.
// Not called from seed.ts; the lead wires it in.
import type { Tx } from './database.ts';
import { addDays, financialYear, todayIst } from '../lib/dates.ts';
import { nextNumber } from '../lib/series.ts';

export interface LegalSeedWho { tenantId: string; companyId: string; userId: string }

const CLIENTS = [
  { name: 'Mehta Traders', gstin: '27AAPFU0939F1ZV', state: '27' },
  { name: 'Ravi Patel', gstin: null, state: null },
  { name: 'Shree Ganesh Cooperative Society', gstin: null, state: null },
  { name: 'Desai Infra Pvt Ltd', gstin: '27AAPFU0939F1ZV', state: '27' },
];

export async function seedLegalDemo(tx: Tx, { tenantId, companyId, userId }: LegalSeedWho) {
  const company = await tx.selectFrom('companies').select('state_code').where('id', '=', companyId).executeTakeFirstOrThrow();
  const today = todayIst();
  const fy = financialYear(today);
  const clients: string[] = [];
  for (const c of CLIENTS) {
    const row = await tx.insertInto('parties').values({
      tenant_id: tenantId, company_id: companyId, type: 'customer', name: c.name, state_code: c.state ?? company.state_code,
      gstin: c.gstin, phone: null, address: null, email: null, pan: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null,
    }).returning('id').executeTakeFirstOrThrow();
    clients.push(row.id);
  }
  const specs = [
    { title: 'Mehta Traders v. Shree Steel Ltd', c: 0, opp: 'Shree Steel Ltd', court: 'City Civil Court, Ahmedabad', type: 'Recovery suit', no: 'CS 412', year: 2026, stage: 'Evidence', fee: 'hourly', agreed: 0, rate: 3000, next: 4 },
    { title: 'Patel v. Patel (partition)', c: 1, opp: 'Harish Patel', court: 'District Court, Gandhinagar', type: 'Civil suit', no: 'RCS 88', year: 2025, stage: 'Written statement', fee: 'fixed_stage', agreed: 60000, rate: null, next: 0 },
    { title: 'Shree Ganesh Society v. Registrar', c: 2, opp: 'Registrar of Co-operative Societies', court: 'Gujarat High Court', type: 'Special civil application', no: 'SCA 1204', year: 2026, stage: 'Admission', fee: 'per_hearing', agreed: 7500, rate: null, next: 1 },
    { title: 'Desai Infra: arbitration against NHAI', c: 3, opp: 'NHAI', court: 'Arbitral Tribunal', type: 'Arbitration', no: 'ARB 12', year: 2025, stage: 'Statement of claim', fee: 'retainer', agreed: 25000, rate: null, next: null },
    { title: 'Patel: cheque bounce complaint', c: 1, opp: 'Kalpesh Soni', court: 'Metropolitan Magistrate, Ahmedabad', type: 'Section 138 NI Act', no: 'CC 2210', year: 2026, stage: 'Summons', fee: 'fixed_stage', agreed: 15000, rate: null, next: 9 },
  ];
  const ids: string[] = [];
  for (const s of specs) {
    const m = await tx.insertInto('legal_matters').values({
      tenant_id: tenantId, company_id: companyId, matter_no: await nextNumber(tx, { tenantId, companyId }, 'matter', fy),
      title: s.title, client_id: clients[s.c]!, opposing_party: s.opp, court: s.court, case_type: s.type, case_no: s.no, case_year: s.year,
      filing_date: addDays(today, -120), stage: s.stage, advocate_id: userId, fee_type: s.fee, agreed_fee: s.agreed, hourly_rate: s.rate,
      created_by: userId,
    }).returning('id').executeTakeFirstOrThrow();
    ids.push(m.id);
    if (s.next !== null) {
      await tx.insertInto('legal_hearings').values({
        tenant_id: tenantId, company_id: companyId, matter_id: m.id, hearing_date: addDays(today, s.next), court: s.court,
        purpose: s.stage, created_by: userId,
      }).execute();
    }
    // One past hearing with its outcome.
    await tx.insertInto('legal_hearings').values({
      tenant_id: tenantId, company_id: companyId, matter_id: m.id, hearing_date: addDays(today, -30), court: s.court, purpose: 'Appearance',
      status: 'held', outcome: 'Adjourned at the request of the other side.', recorded_by: userId, recorded_at: new Date(), created_by: userId,
    }).execute();
  }
  await tx.insertInto('legal_tasks').values([
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[1]!, title: 'File written statement', kind: 'filing', due_date: addDays(today, -2), assignee_id: userId, created_by: userId },
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[0]!, title: 'Affidavit of evidence', kind: 'filing', due_date: addDays(today, 3), assignee_id: userId, created_by: userId },
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[4]!, title: 'Limitation for revision petition', kind: 'limitation', due_date: addDays(today, 12), assignee_id: userId, created_by: userId },
  ]).execute();
  await tx.insertInto('legal_entries').values([
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[0]!, kind: 'time', user_id: userId, entry_date: addDays(today, -2), minutes: 150, rate: 3000, amount: 7500, description: 'Drafting affidavit of evidence' },
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[0]!, kind: 'time', user_id: userId, entry_date: addDays(today, -1), minutes: 45, rate: 3000, amount: 2250, description: 'Client conference' },
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[0]!, kind: 'disbursement', disb_type: 'court_fee', user_id: userId, entry_date: addDays(today, -5), amount: 1200, description: 'Court fee for exhibits' },
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[1]!, kind: 'fee', user_id: userId, entry_date: addDays(today, -10), amount: 30000, description: 'Fee for stage: pleadings' },
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[1]!, kind: 'disbursement', disb_type: 'stamp_duty', user_id: userId, entry_date: addDays(today, -10), amount: 500, description: 'Stamp paper for vakalatnama' },
    { tenant_id: tenantId, company_id: companyId, matter_id: ids[2]!, kind: 'disbursement', disb_type: 'clerkage', user_id: userId, entry_date: addDays(today, -3), amount: 300, description: 'Clerkage, High Court registry' },
  ]).execute();
  return { matterIds: ids };
}
