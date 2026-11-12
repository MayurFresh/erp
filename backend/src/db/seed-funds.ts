// Demo funds, budget heads, sanctions, donors and donations. Not called from seed.ts; the lead wires it in.
import type { Tx } from './database.ts';
import { postJournal } from '../accounting/journal.ts';
import { systemAccounts } from '../accounting/accounts.ts';
import { financialYear, todayIst } from '../lib/dates.ts';
import { nextNumber } from '../lib/series.ts';

export interface FundsSeedWho { tenantId: string; companyId: string; userId: string }

async function account(tx: Tx, w: FundsSeedWho, name: string, type: 'income' | 'equity', code: string): Promise<string> {
  const ex = await tx.selectFrom('accounts').select('id').where('company_id', '=', w.companyId).where('name', '=', name).executeTakeFirst();
  if (ex) return ex.id;
  const row = await tx.insertInto('accounts').values({ tenant_id: w.tenantId, company_id: w.companyId, code, name, type, subtype: 'other', system_key: null, is_system: false })
    .onConflict((oc) => oc.doNothing()).returning('id').executeTakeFirst();
  if (row) return row.id;
  const alt = await tx.selectFrom('accounts').select('id').where('company_id', '=', w.companyId).where('code', '=', code).executeTakeFirstOrThrow();
  return alt.id;
}

export async function seedFundsDemo(tx: Tx, w: FundsSeedWho) {
  const today = todayIst(), fy = financialYear(today);
  const sys = await systemAccounts(tx, w);
  const expense = await tx.selectFrom('accounts').select('id').where('company_id', '=', w.companyId).where('type', '=', 'expense').orderBy('code').executeTakeFirstOrThrow();
  const base = { tenant_id: w.tenantId, company_id: w.companyId, created_by: w.userId };

  const head = async (level: string, code: string, name: string, parent: string | null, amount = 0) =>
    (await tx.insertInto('budget_heads').values({ ...base, fy, level, code, name, parent_id: parent, account_id: level === 'object' ? expense.id : null, budget_estimate: amount })
      .returning('id').executeTakeFirstOrThrow()).id;
  const m1 = await head('major', '2202', 'General education', null);
  const n1 = await head('minor', '2202.01', 'Elementary education', m1);
  const salaries = await head('object', '2202.01.01', 'Salaries', n1, 1200000);
  await head('object', '2202.01.02', 'Office expenses', n1, 150000);
  await head('object', '2202.01.03', 'Repairs and maintenance', n1, 300000);
  const m2 = await head('major', '2210', 'Medical and public health', null);
  const n2 = await head('minor', '2210.01', 'Urban health services', m2);
  await head('object', '2210.01.01', 'Medicines and supplies', n2, 400000);
  await head('object', '2210.01.02', 'Equipment', n2, 250000);

  const grant = (await tx.insertInto('funds').values({
    ...base, name: 'State education grant 2026-27', kind: 'grant', sponsor: 'Department of Education', sanction_no: 'ED/GR/2026/118', sanction_date: `${fy.slice(0, 4)}-05-12`,
    total_amount: 1500000, period_from: `${fy.slice(0, 4)}-04-01`, period_to: `${Number(fy.slice(0, 4)) + 1}-03-31`, return_unspent: true,
  }).returning('id').executeTakeFirstOrThrow()).id;
  await tx.insertInto('funds').values({ ...base, name: 'Own funds', kind: 'own', total_amount: 0 }).execute();

  const grantIncome = await account(tx, w, 'Grants Received', 'income', '4800');
  const number = await nextNumber(tx, w, 'grant_receipt', fy);
  const r = await tx.insertInto('fund_receipts').values({ ...base, number, fund_id: grant, receipt_date: today, amount: 600000, account_id: sys.bank, reference: 'RTGS 4455667', narration: 'First instalment' })
    .returning('id').executeTakeFirstOrThrow();
  await postJournal(tx, { tenantId: w.tenantId, companyId: w.companyId, userId: w.userId }, {
    date: today, voucherType: 'journal', voucherId: r.id, number, narration: 'Grant received for State education grant 2026-27',
    lines: [{ accountId: sys.bank, amount: 600000 }, { accountId: grantIncome, amount: -600000 }],
  });
  await tx.insertInto('fund_sanctions').values({ ...base, number: await nextNumber(tx, w, 'sanction', fy), head_id: salaries, fund_id: grant, purpose: 'Teacher salaries, Q1', amount: 300000 }).execute();

  const donorIncome = await account(tx, w, 'Donations Received', 'income', '4850');
  const donors = [
    { name: 'Meena Patel', phone: '9825099999', pan: 'ABCDE1234F', address: 'Satellite, Ahmedabad' },
    { name: 'Kiran Desai', phone: '9898012345', pan: 'BCDEF2345G', address: 'Navrangpura, Ahmedabad' },
    { name: 'Suresh Joshi', phone: '9427011223', pan: null, address: 'Maninagar, Ahmedabad' },
  ];
  const made: { id: string; name: string }[] = [];
  for (const d of donors) {
    const party = await tx.insertInto('parties').values({ tenant_id: w.tenantId, company_id: w.companyId, type: 'customer', name: d.name, phone: d.phone, address: d.address, pan: d.pan,
      state_code: '24', gstin: null, email: null, pincode: null, udyam_no: null, msme_category: null, tds_section_id: null }).returning('id').executeTakeFirstOrThrow();
    made.push(await tx.insertInto('donors').values({ ...base, party_id: party.id, name: d.name, phone: d.phone, pan: d.pan, address: d.address }).returning(['id', 'name']).executeTakeFirstOrThrow());
  }
  const gifts: [number, number, string, boolean][] = [[0, 5000, 'upi', true], [1, 25000, 'bank', true], [2, 1500, 'cash', false]];
  for (const [i, amount, mode, tax] of gifts) {
    const receiptNo = await nextNumber(tx, w, 'donation_receipt', fy);
    const acct = mode === 'cash' ? sys.cash : sys.bank;
    const row = await tx.insertInto('donations').values({ ...base, receipt_no: receiptNo, donor_id: made[i]!.id, donation_date: today, amount, mode, tax_80g: tax, deduction_eligible: tax, account_id: acct, fy })
      .returning('id').executeTakeFirstOrThrow();
    await postJournal(tx, { tenantId: w.tenantId, companyId: w.companyId, userId: w.userId }, {
      date: today, voucherType: 'journal', voucherId: row.id, number: receiptNo, narration: `Donation from ${made[i]!.name} by ${mode}`,
      lines: [{ accountId: acct, amount }, { accountId: donorIncome, amount: -amount }],
    });
  }
  await tx.insertInto('funds_settings').values({ tenant_id: w.tenantId, company_id: w.companyId, overspend_mode: 'warn', reg_80g_no: 'AAATD1234E/12A/2022-23/80G', reg_80g_from: '2022-04-01', reg_80g_to: '2027-03-31', trust_pan: 'AAATD1234E' })
    .onConflict((oc) => oc.column('company_id').doNothing()).execute();
}
