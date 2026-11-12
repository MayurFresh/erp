// Demo staff for HR and payroll: six employees with salary structures, leave types and festival holidays.
// Not called from seed.ts; the lead wires it in. Safe to call twice (skips when the company already has employees).
import type { Tx } from './database.ts';
import { ensureComponents, ensureLeaveTypes } from '../modules/hr.ts';

export interface PayrollSeedWho { tenantId: string; companyId: string; userId: string }

const STAFF = [
  { name: 'Meera Joshi', sex: 'F', designation: 'Accounts Manager', department: 'Finance', joined: '2021-06-01', basic: 32000, special: 14000, pan: 'AKQPJ1234M', uan: '101234567801' },
  { name: 'Rahul Deshmukh', sex: 'M', designation: 'Sales Executive', department: 'Sales', joined: '2022-09-15', basic: 18000, special: 7000, pan: 'BNFPD4521K', uan: '101234567802' },
  { name: 'Sunita Pawar', sex: 'F', designation: 'Store Keeper', department: 'Stores', joined: '2023-01-02', basic: 12000, special: 3000, pan: 'CXRPP7788L', uan: '101234567803' },
  { name: 'Imran Shaikh', sex: 'M', designation: 'Supervisor', department: 'Operations', joined: '2020-04-10', basic: 22000, special: 8000, pan: 'DLTPS3344Q', uan: '101234567804' },
  { name: 'Priya Nair', sex: 'F', designation: 'HR Executive', department: 'HR', joined: '2024-02-12', basic: 20000, special: 6000, pan: 'EQMPN9012R', uan: '101234567805' },
  { name: 'Vikram Rane', sex: 'M', designation: 'Driver', department: 'Operations', joined: '2023-08-21', basic: 11000, special: 2500, pan: 'FKWPR5566T', uan: '101234567806' },
];

export async function seedPayrollDemo(tx: Tx, w: PayrollSeedWho): Promise<{ employees: number }> {
  const have = await tx.selectFrom('employees').select('id').where('company_id', '=', w.companyId).limit(1).executeTakeFirst();
  if (have) return { employees: 0 };
  await ensureComponents(tx, w);
  await ensureLeaveTypes(tx, w);
  const comps = await tx.selectFrom('salary_components').select(['id', 'code', 'calc', 'percent']).where('company_id', '=', w.companyId).execute();
  const id = (code: string) => comps.find((c) => c.code === code)!.id;

  const holidays: [string, string][] = [['2026-01-26', 'Republic Day'], ['2026-08-15', 'Independence Day'], ['2026-10-02', 'Gandhi Jayanti'], ['2026-11-08', 'Diwali'], ['2026-12-25', 'Christmas']];
  for (const [d, name] of holidays) {
    await tx.insertInto('holidays').values({ tenant_id: w.tenantId, company_id: w.companyId, holiday_date: d, name, location_id: null })
      .onConflict((oc) => oc.doNothing()).execute();
  }

  let n = 0;
  for (const s of STAFF) {
    n += 1;
    const series = await tx.insertInto('doc_series').values({ tenant_id: w.tenantId, company_id: w.companyId, doc_type: 'employee', fy: 'all', next_no: 2 })
      .onConflict((oc) => oc.columns(['company_id', 'doc_type', 'fy']).doUpdateSet((eb) => ({ next_no: eb('doc_series.next_no', '+', 1) })))
      .returning('next_no').executeTakeFirstOrThrow();
    const emp = await tx.insertInto('employees').values({
      tenant_id: w.tenantId, company_id: w.companyId, code: `E${String(series.next_no - 1).padStart(4, '0')}`, name: s.name, sex: s.sex,
      joining_date: s.joined, designation: s.designation, department: s.department, pan: s.pan, uan: s.uan,
      bank_name: 'State Bank of India', bank_account: `3300${String(1000000 + n * 7919)}`, bank_ifsc: 'SBIN0001234', created_by: w.userId,
      dob: `199${n}-0${n}-1${n}`, esi_number: s.basic + s.special < 17000 ? `31000${100000 + n}` : null,
    }).returning('id').executeTakeFirstOrThrow();
    const rev = await tx.insertInto('employee_salaries').values({
      tenant_id: w.tenantId, employee_id: emp.id, effective_from: s.joined, ctc_annual: (s.basic * 1.4 + s.special) * 12, created_by: w.userId,
    }).returning('id').executeTakeFirstOrThrow();
    await tx.insertInto('employee_salary_lines').values([
      { tenant_id: w.tenantId, salary_id: rev.id, component_id: id('BASIC'), amount: s.basic },
      { tenant_id: w.tenantId, salary_id: rev.id, component_id: id('HRA'), amount: Math.round(s.basic * 0.4) },
      { tenant_id: w.tenantId, salary_id: rev.id, component_id: id('SPECIAL'), amount: s.special },
    ]).execute();
  }
  return { employees: n };
}
