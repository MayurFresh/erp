// TDS section map, Form 16 / 16A (130 / 131 from 1 April 2026), 24Q / 26Q (138 / 140) data and checks. API: docs/API.md "TDS forms".
// Certificates here are working copies: the valid certificate is the one downloaded from TRACES after the statement is filed.
import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { toCsv } from '../lib/csv.ts';
import { daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { form140Due, fyMonths, monthEnd, quarterRange, tdsDepositDue } from '../lib/due-dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { moneyField } from '../lib/numbers.ts';
import { canFile, type PrefileCheck } from '../lib/prefile.ts';
import {
  formNamesFor, formNamesOn, lateDepositInterest, lateFilingFee, NEW_ACT_FROM, panValid, partB, periodLabel, TDS_INTEREST, lateDeductionInterest,
} from '../lib/tds-forms.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { tdsPrefileCheck } from './tds.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const fyField = z.string().regex(/^\d{4}-\d{2}$/, 'Use a financial year such as 2026-27');
const quarterField = z.coerce.number().int().min(1).max(4);
const NOTICE = 'This is a working copy built from your books. The valid certificate is the one downloaded from TRACES after the statement is filed.';

// ---- section map ------------------------------------------------------------------------------

type MapRow = { id: string; tenant_id: string | null; old_code: string; old_section: string; new_section: string; payment_code: string | null; nature: string;
  rate_text: string | null; threshold_text: string | null; kind: string; effective_from: string; confirmed: boolean; source_url: string | null; note: string | null; is_active: boolean };

/** The section reference to show for a code on a date: the old one before 1 April 2026, the map's new one on or after. */
export function referenceFor(rows: Pick<MapRow, 'old_code' | 'old_section' | 'new_section' | 'effective_from' | 'tenant_id'>[], code: string, date: string): string {
  const mine = rows.filter((r) => r.old_code === code).sort((a, b) => b.effective_from.localeCompare(a.effective_from) || (a.tenant_id ? -1 : 1));
  const hit = mine.find((r) => r.effective_from <= date);
  if (hit) return hit.new_section;
  return mine[0]?.old_section ?? `s.${code}`;
}

export async function loadMap(tx: Tx): Promise<MapRow[]> {
  return (await tx.selectFrom('tds_section_map').selectAll().where('is_active', '=', true).execute()) as MapRow[];
}

const mapJson = (r: MapRow, date: string) => ({
  id: r.id, oldCode: r.old_code, oldSection: r.old_section, newSection: r.new_section, paymentCode: r.payment_code, nature: r.nature,
  rateText: r.rate_text, thresholdText: r.threshold_text, kind: r.kind, effectiveFrom: r.effective_from, confirmed: r.confirmed,
  sourceUrl: r.source_url, note: r.note, isActive: r.is_active, system: r.tenant_id === null,
  reference: date >= r.effective_from ? r.new_section : r.old_section, form: formNamesOn(date).act,
});

const mapPatch = z.object({
  newSection: z.string().trim().min(1).max(60).optional(), paymentCode: z.string().trim().max(10).nullable().optional(),
  nature: z.string().trim().min(1).max(120).optional(), rateText: z.string().trim().max(60).nullable().optional(),
  thresholdText: z.string().trim().max(80).nullable().optional(), effectiveFrom: docDate.optional(), confirmed: z.boolean().optional(),
  sourceUrl: z.string().trim().max(300).nullable().optional(), note: z.string().trim().max(300).nullable().optional(), isActive: z.boolean().optional(),
});

// ---- shared loaders ---------------------------------------------------------------------------

async function deductor(tx: Tx, companyId: string) {
  const c = await tx.selectFrom('companies').select(['name', 'legal_name', 'tan', 'pan', 'address', 'responsible_person']).where('id', '=', companyId).executeTakeFirstOrThrow();
  const rp = c.responsible_person as { name?: string; designation?: string } | null;
  return { name: c.legal_name ?? c.name, address: c.address, tan: c.tan, pan: c.pan, responsiblePerson: rp?.name ?? null, designation: rp?.designation ?? null };
}

const fyBounds = (fy: string) => ({ from: `${fy.slice(0, 4)}-04-01`, to: `${Number(fy.slice(0, 4)) + 1}-03-31` });
const quarterOfMonth = (fy: string, month: string) => Math.floor(fyMonths(fy).indexOf(month) / 3) + 1;

async function salaryChallans(tx: Tx, companyId: string, fy: string) {
  const b = fyBounds(fy);
  const rows = await tx.selectFrom('tds_salary_challans').selectAll().where('company_id', '=', companyId).where('status', '=', 'posted')
    .where('month', '>=', b.from).where('month', '<=', b.to).orderBy('month').execute();
  return new Map(rows.map((r) => [r.month.slice(0, 7), r]));
}

const challanJson = (r: { id: string; month: string; deposit_date: string; bsr_code: string; challan_serial: string; amount: number; interest: number; late_fee: number; status: string }) => ({
  id: r.id, month: r.month.slice(0, 7), depositDate: r.deposit_date, bsrCode: r.bsr_code, challanSerial: r.challan_serial, amount: r.amount,
  interest: r.interest, lateFee: r.late_fee, status: r.status,
});

// ---- Form 16 / 130 ----------------------------------------------------------------------------

async function buildForm16(tx: Tx, ctx: RequestContext, fy: string, employeeId: string) {
  const e = await tx.selectFrom('employees').selectAll().where('id', '=', employeeId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!e) throw notFound('Employee');
  const b = fyBounds(fy);
  const lines = await tx.selectFrom('payroll_lines').select(['month', 'gross', 'taxable_gross', 'tds', 'pt', 'pf_employee'])
    .where('employee_id', '=', employeeId).where('is_live', '=', true).where('month', '>=', b.from).where('month', '<=', b.to).orderBy('month').execute();
  if (!lines.length) return null;
  const names = formNamesFor(fy);
  const challans = await salaryChallans(tx, ctx.companyId, fy);
  const sum = (f: (l: (typeof lines)[number]) => number) => round2(lines.reduce((s, l) => s + f(l), 0));
  const quarters = [1, 2, 3, 4].map((q) => {
    const ms = lines.filter((l) => quarterOfMonth(fy, l.month.slice(0, 7)) === q);
    const deducted = round2(ms.reduce((s, l) => s + l.tds, 0));
    const deposited = round2(ms.filter((l) => challans.has(l.month.slice(0, 7))).reduce((s, l) => s + l.tds, 0));
    return { quarter: q, deducted, deposited, receiptNumber: null as string | null };
  });
  const deposits = lines.filter((l) => l.tds > 0 && challans.has(l.month.slice(0, 7))).map((l) => {
    const c = challans.get(l.month.slice(0, 7))!;
    return { month: l.month.slice(0, 7), tds: l.tds, bsrCode: c.bsr_code, challanSerial: c.challan_serial, depositDate: c.deposit_date };
  });
  const regime = e.tax_regime as 'new' | 'old';
  const tdsTotal = sum((l) => l.tds);
  const b2 = partB({
    fy, regime, grossSalary: sum((l) => l.gross), taxableSalary: sum((l) => l.taxable_gross), previousIncome: e.previous_income, previousTds: e.previous_tds,
    employeePf: sum((l) => l.pf_employee), professionalTax: sum((l) => l.pt), tdsThisEmployer: tdsTotal,
  });
  const warnings: string[] = [];
  const co = await deductor(tx, ctx.companyId);
  if (!co.tan) warnings.push('Company TAN is missing.');
  if (!e.pan) warnings.push('Employee PAN is missing. The certificate shows PANNOTAVBL.');
  else if (!panValid(e.pan)) warnings.push('Employee PAN is not in the PAN format.');
  const open = round2(tdsTotal - quarters.reduce((s, q) => s + q.deposited, 0));
  if (open > 0) warnings.push(`Rs ${open} of the TDS has no salary challan recorded.`);
  if (b2.balance > 0) warnings.push(`Tax on total income is Rs ${b2.balance} more than the TDS deducted.`);
  if (b2.balance < 0) warnings.push(`TDS deducted is Rs ${-b2.balance} more than the tax on total income (refund claimed in the return).`);
  return {
    form: names.salaryCertificate, fy, periodLabel: periodLabel(fy), notice: NOTICE, unconfirmed: names.unconfirmed,
    deductor: co,
    employee: { id: e.id, code: e.code, name: e.name, pan: e.pan ?? 'PANNOTAVBL', designation: e.designation, regime },
    period: { from: e.joining_date > b.from ? e.joining_date : b.from, to: e.leaving_date && e.leaving_date < b.to ? e.leaving_date : b.to },
    partA: { quarters, deposits, totalDeducted: tdsTotal, totalDeposited: round2(quarters.reduce((s, q) => s + q.deposited, 0)) },
    partB: b2, warnings,
  };
}

// ---- Form 16A / 131 ---------------------------------------------------------------------------

async function buildForm16A(tx: Tx, ctx: RequestContext, fy: string, quarter: number, partyId?: string) {
  const r = quarterRange(fy, quarter);
  let q = tx.selectFrom('tds_deductions as d').innerJoin('parties as p', 'p.id', 'd.party_id').leftJoin('tds_challans as c', 'c.id', 'd.challan_id')
    .select(['d.party_id', 'p.name', 'p.address', 'd.pan', 'd.section_code', 'd.deduction_date', 'd.number', 'd.gross', 'd.base', 'd.rate', 'd.amount',
      'd.challan_id', 'c.bsr_code', 'c.challan_serial', 'c.deposit_date', 'c.status as challan_status'])
    .where('d.company_id', '=', ctx.companyId).where('d.status', '=', 'active').where('d.amount', '>', 0)
    .where('d.deduction_date', '>=', r.from).where('d.deduction_date', '<=', r.to);
  if (partyId) q = q.where('d.party_id', '=', partyId);
  const rows = await q.orderBy('d.deduction_date').orderBy('d.number').execute();
  const map = await loadMap(tx);
  const names = formNamesFor(fy);
  const co = await deductor(tx, ctx.companyId);
  const byParty = new Map<string, typeof rows>();
  for (const x of rows) byParty.set(x.party_id, [...(byParty.get(x.party_id) ?? []), x]);
  return [...byParty.entries()].map(([pid, rs]) => {
    const first = rs[0]!;
    const deposited = rs.filter((x) => x.challan_id && x.challan_status === 'posted');
    const challans = new Map<string, { bsrCode: string; challanSerial: string; depositDate: string; tds: number }>();
    for (const x of deposited) {
      const k = x.challan_id!;
      const cur = challans.get(k) ?? { bsrCode: x.bsr_code!, challanSerial: x.challan_serial!, depositDate: x.deposit_date!, tds: 0 };
      cur.tds = round2(cur.tds + x.amount);
      challans.set(k, cur);
    }
    const warnings: string[] = [];
    if (!first.pan) warnings.push('Deductee PAN is missing. TDS was deducted at the higher rate.');
    else if (!panValid(first.pan)) warnings.push('Deductee PAN is not in the PAN format.');
    if (!co.tan) warnings.push('Company TAN is missing.');
    const total = round2(rs.reduce((s, x) => s + x.amount, 0));
    const dep = round2(deposited.reduce((s, x) => s + x.amount, 0));
    if (total > dep) warnings.push(`Rs ${round2(total - dep)} has no challan yet.`);
    return {
      form: names.nonSalaryCertificate, fy, quarter, periodLabel: periodLabel(fy), notice: NOTICE, unconfirmed: names.unconfirmed, deductor: co,
      deductee: { partyId: pid, name: first.name, address: first.address, pan: first.pan ?? 'PANNOTAVBL' },
      rows: rs.map((x) => ({ date: x.deduction_date, number: x.number, sectionCode: x.section_code, section: referenceFor(map, x.section_code, x.deduction_date),
        amountPaid: x.gross, base: x.base, rate: x.rate, tds: x.amount, challanSerial: x.challan_serial, bsrCode: x.bsr_code, depositDate: x.deposit_date })),
      challans: [...challans.values()], totalDeducted: total, totalDeposited: dep, warnings,
    };
  });
}

// ---- returns ----------------------------------------------------------------------------------

type Check = PrefileCheck;
const mk = (id: string, title: string, status: Check['status'], detail: string, count: number | null = null): Check => ({ id, title, status, detail, count, link: null });

async function filedOn(tx: Tx, companyId: string, fy: string, quarter: number): Promise<string | null> {
  const r = await tx.selectFrom('statutory_filings').select('filed_on').where('company_id', '=', companyId).where('return_type', '=', 'tds_140')
    .where('period', '=', `${fy}-Q${quarter}`).where('status', '=', 'filed').executeTakeFirst();
  return r ? r.filed_on : null;
}

function feeFigures(fy: string, quarter: 1 | 2 | 3 | 4, tds: number, filed: string | null, today: string) {
  const dueDate = form140Due(fy, quarter);
  const daysLate = tds > 0 ? Math.max(0, daysBetween(dueDate, filed ?? today)) : 0;
  return { dueDate, filedOn: filed, daysLate, lateFee: lateFilingFee(daysLate, tds) };
}

async function salaryReturn(tx: Tx, ctx: RequestContext, fy: string, quarter: 1 | 2 | 3 | 4, today: string) {
  const names = formNamesFor(fy);
  const months = fyMonths(fy).slice((quarter - 1) * 3, quarter * 3);
  const co = await deductor(tx, ctx.companyId);
  const challans = await salaryChallans(tx, ctx.companyId, fy);
  const lines = await tx.selectFrom('payroll_lines as l').innerJoin('employees as e', 'e.id', 'l.employee_id')
    .select(['l.employee_id', 'e.code', 'e.name', 'e.pan', 'e.tax_regime', 'l.month', 'l.taxable_gross', 'l.tds'])
    .where('l.company_id', '=', ctx.companyId).where('l.is_live', '=', true).where('l.month', 'in', months.map((m) => `${m}-01`)).where('l.tds', '>', 0)
    .orderBy('e.code').orderBy('l.month').execute();
  const byEmp = new Map<string, typeof lines>();
  for (const l of lines) byEmp.set(l.employee_id, [...(byEmp.get(l.employee_id) ?? []), l]);
  const deductees = [];
  for (const [eid, ls] of byEmp) {
    const f = ls[0]!;
    deductees.push({
      employeeId: eid, code: f.code, name: f.name, pan: f.pan ?? 'PANNOTAVBL',
      rows: ls.map((l) => {
        const c = challans.get(l.month.slice(0, 7));
        return { month: l.month.slice(0, 7), paymentDate: monthEnd(l.month.slice(0, 7)), amountPaid: l.taxable_gross, tds: l.tds,
          bsrCode: c?.bsr_code ?? null, challanSerial: c?.challan_serial ?? null, depositDate: c?.deposit_date ?? null };
      }),
      annual: quarter === 4 ? (await buildForm16(tx, ctx, fy, eid))?.partB ?? null : null,
    });
  }
  const qc = months.map((m) => challans.get(m)).filter((c): c is NonNullable<typeof c> => !!c).map(challanJson);
  const tds = round2(lines.reduce((s, l) => s + l.tds, 0));
  const checks: Check[] = [];
  checks.push(mk('tan', 'Deductor TAN', co.tan ? 'pass' : 'fail', co.tan ? `TAN ${co.tan}.` : 'Company TAN is missing.'));
  checks.push(mk('responsible_person', 'Responsible person', co.responsiblePerson ? 'pass' : 'fail', co.responsiblePerson ? `${co.responsiblePerson} will sign.` : 'Add the responsible person in company settings.'));
  const noPan = deductees.filter((d) => d.pan === 'PANNOTAVBL').length;
  const badPan = deductees.filter((d) => d.pan !== 'PANNOTAVBL' && !panValid(d.pan)).length;
  checks.push(mk('pan_missing', 'Employee PAN', noPan ? 'warn' : 'pass', noPan ? `${noPan} employee${noPan > 1 ? 's' : ''} without PAN.` : 'Every employee has a PAN.', noPan || null));
  checks.push(mk('pan_format', 'PAN format', badPan ? 'fail' : 'pass', badPan ? `${badPan} PAN${badPan > 1 ? 's are' : ' is'} not in the format AAAAA9999A.` : 'All PANs are in the PAN format.', badPan || null));
  const undeposited = months.filter((m) => lines.some((l) => l.month.slice(0, 7) === m) && !challans.has(m));
  checks.push(mk('challan_link', 'Salary challan for each month', undeposited.length ? 'fail' : 'pass',
    undeposited.length ? `No challan recorded for ${undeposited.join(', ')}.` : 'Every month with TDS has a challan.', undeposited.length || null));
  const mismatch = months.filter((m) => {
    const c = challans.get(m);
    return c && Math.abs(c.amount - round2(lines.filter((l) => l.month.slice(0, 7) === m).reduce((s, l) => s + l.tds, 0))) > 0.005;
  });
  checks.push(mk('challan_amount', 'Challan equals payroll TDS', mismatch.length ? 'fail' : 'pass',
    mismatch.length ? `Challan amount differs from payroll TDS for ${mismatch.join(', ')}.` : 'Challan amounts equal the payroll TDS.', mismatch.length || null));
  let interest = 0;
  const interestRows = [];
  for (const m of months) {
    const t = round2(lines.filter((l) => l.month.slice(0, 7) === m).reduce((s, l) => s + l.tds, 0));
    if (!t) continue;
    const c = challans.get(m);
    const r = lateDepositInterest(t, monthEnd(m), tdsDepositDue(m), c?.deposit_date ?? today);
    interest += r.interest;
    interestRows.push({ month: m, tds: t, dueDate: tdsDepositDue(m), depositDate: c?.deposit_date ?? null, monthsLate: r.months, interest: r.interest });
  }
  const fee = feeFigures(fy, quarter, tds, await filedOn(tx, ctx.companyId, fy, quarter), today);
  checks.push(mk('interest', 'Deposited on time', interest > 0 ? 'warn' : 'pass', interest > 0 ? `Late deposit interest is about Rs ${round2(interest)}.` : 'No late deposit interest.'));
  checks.push(mk('late', 'Filing on time', fee.lateFee > 0 ? 'warn' : 'pass', fee.lateFee > 0 ? `${fee.daysLate} days late. Fee about Rs ${fee.lateFee}.` : 'Within the due date.', fee.daysLate || null));
  if (quarter === 4) {
    const short = deductees.filter((d) => d.annual && d.annual.balance > 0).length;
    checks.push(mk('annual_tax', 'Annual tax against TDS', short ? 'warn' : 'pass', short ? `${short} employee${short > 1 ? 's have' : ' has'} less TDS than the tax on total income.` : 'TDS covers the tax for every employee.', short || null));
  }
  return { kind: 'salary', form: names.salaryReturn, fy, quarter, periodLabel: periodLabel(fy), unconfirmed: names.unconfirmed, deductor: co, challans: qc, deductees,
    totalTds: tds, lateInterest: { rows: interestRows, total: round2(interest) }, lateFee: fee, interestRule: TDS_INTEREST, checks, canFile: canFile(checks) };
}

async function nonSalaryReturn(tx: Tx, ctx: RequestContext, fy: string, quarter: 1 | 2 | 3 | 4, today: string) {
  const names = formNamesFor(fy);
  const r = quarterRange(fy, quarter);
  const co = await deductor(tx, ctx.companyId);
  const map = await loadMap(tx);
  const ds = await tx.selectFrom('tds_deductions as d').innerJoin('parties as p', 'p.id', 'd.party_id').leftJoin('tds_challans as c', 'c.id', 'd.challan_id')
    .select(['d.number', 'p.name', 'd.pan', 'd.section_code', 'd.deduction_date', 'd.gross', 'd.base', 'd.rate', 'd.amount', 'd.challan_id', 'c.bsr_code', 'c.challan_serial', 'c.deposit_date'])
    .where('d.company_id', '=', ctx.companyId).where('d.status', '=', 'active').where('d.amount', '>', 0)
    .where('d.deduction_date', '>=', r.from).where('d.deduction_date', '<=', r.to).orderBy('d.deduction_date').orderBy('d.number').execute();
  const checks = await tdsPrefileCheck(tx, ctx.companyId, fy, quarter);
  const bad = ds.filter((d) => d.pan && !panValid(d.pan)).length;
  checks.push(mk('pan_format', 'PAN format', bad ? 'fail' : 'pass', bad ? `${bad} deduction${bad > 1 ? 's have' : ' has'} a PAN not in the format AAAAA9999A.` : 'All PANs are in the PAN format.', bad || null));
  let interest = 0;
  const rows = ds.map((d, i) => {
    const due = tdsDepositDue(d.deduction_date.slice(0, 7));
    const li = lateDepositInterest(d.amount, d.deduction_date, due, d.deposit_date ?? today);
    interest += li.interest;
    return { serial: i + 1, pan: d.pan ?? 'PANNOTAVBL', panValid: d.pan ? panValid(d.pan) : false, partyName: d.name, sectionCode: d.section_code,
      section: referenceFor(map, d.section_code, d.deduction_date), date: d.deduction_date, amountPaid: d.gross, base: d.base, rate: d.rate, tds: d.amount,
      bsrCode: d.bsr_code, challanSerial: d.challan_serial, depositDate: d.deposit_date, lateInterest: li.interest };
  });
  const tds = round2(ds.reduce((s, d) => s + d.amount, 0));
  const fee = feeFigures(fy, quarter, tds, await filedOn(tx, ctx.companyId, fy, quarter), today);
  return { kind: 'non_salary', form: names.nonSalaryReturn, fy, quarter, periodLabel: periodLabel(fy), unconfirmed: names.unconfirmed, deductor: co, rows,
    totalTds: tds, lateInterest: { total: round2(interest) }, lateFee: fee, interestRule: TDS_INTEREST, checks, canFile: canFile(checks) };
}

type ReturnData = Awaited<ReturnType<typeof salaryReturn>> | Awaited<ReturnType<typeof nonSalaryReturn>>;
function returnCsv(d: ReturnData): string {
  if (d.kind === 'non_salary') {
    const x = d as Awaited<ReturnType<typeof nonSalaryReturn>>;
    return toCsv(['serial', 'deductee_pan', 'deductee_name', 'section', 'section_code_old', 'payment_date', 'amount_paid', 'rate', 'tds', 'challan_bsr', 'challan_serial', 'deposit_date'],
      x.rows.map((r) => [r.serial, r.pan, r.partyName, r.section, r.sectionCode, r.date, r.amountPaid, r.rate, r.tds, r.bsrCode, r.challanSerial, r.depositDate]));
  }
  const x = d as Awaited<ReturnType<typeof salaryReturn>>;
  const head = ['record', 'employee_code', 'pan', 'name', 'month', 'payment_date', 'amount_paid', 'tds', 'challan_bsr', 'challan_serial', 'deposit_date',
    'gross_salary', 'standard_deduction', 'professional_tax', 'total_income', 'tax_on_income', 'rebate', 'cess', 'net_tax', 'regime'];
  const out: unknown[][] = [];
  for (const c of x.challans) out.push(['CHALLAN', '', '', '', c.month, '', '', c.amount, c.bsrCode, c.challanSerial, c.depositDate]);
  for (const e of x.deductees) {
    for (const r of e.rows) out.push(['DEDUCTEE', e.code, e.pan, e.name, r.month, r.paymentDate, r.amountPaid, r.tds, r.bsrCode, r.challanSerial, r.depositDate]);
    if (e.annual) out.push(['ANNUAL', e.code, e.pan, e.name, '', '', '', e.annual.tdsTotal, '', '', '', e.annual.totalSalary, e.annual.standardDeduction,
      e.annual.professionalTax, e.annual.totalIncome, e.annual.taxOnIncome, e.annual.rebate, e.annual.cess, e.annual.netTaxPayable, e.annual.regime]);
  }
  return toCsv(head, out);
}

// ---- routes -----------------------------------------------------------------------------------

const certBody = z.object({
  kind: z.enum(['salary', 'non_salary']), fy: fyField, quarter: quarterField.optional(),
  employeeId: z.uuid().optional(), partyId: z.uuid().optional(),
});
const salaryChallanBody = z.object({
  month: z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM'), depositDate: docDate,
  bsrCode: z.string().regex(/^\d{7}$/, 'BSR code is 7 digits'), challanSerial: z.string().regex(/^\d{5}$/, 'Challan serial is 5 digits'),
  amount: moneyField.refine((v) => v > 0, 'Must be more than zero'), interest: moneyField.optional(), lateFee: moneyField.optional(),
});
const interestBody = z.object({
  kind: z.enum(['late_deduction', 'late_deposit', 'late_filing']), tax: moneyField,
  dueOn: docDate.optional(), onDate: docDate.optional(), daysLate: z.number().int().min(0).max(5000).optional(),
});

export async function tdsFormsRoutes(app: FastifyInstance) {
  app.get('/tds/section-map', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ date: z.string().refine(isValidDate, 'Use YYYY-MM-DD').optional(), kind: z.enum(['tds', 'tcs', 'salary']).optional() }), req.query);
    const date = q.date ?? todayIst();
    return ctx.tx(async (tx) => {
      let rows = await tx.selectFrom('tds_section_map').selectAll().orderBy('old_code').orderBy('effective_from').execute() as MapRow[];
      if (q.kind) rows = rows.filter((r) => r.kind === q.kind);
      // A company's own row hides the system row for the same code and start date.
      const own = new Set(rows.filter((r) => r.tenant_id).map((r) => `${r.old_code}|${r.effective_from}`));
      rows = rows.filter((r) => r.tenant_id || !own.has(`${r.old_code}|${r.effective_from}`));
      return { date, forms: formNamesOn(date), newActFrom: NEW_ACT_FROM, data: rows.map((r) => mapJson(r, date)) };
    });
  });

  app.patch<{ Params: { id: string } }>('/tds/section-map/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(mapPatch, req.body);
    return ctx.tx(async (tx) => {
      const row = await tx.selectFrom('tds_section_map').selectAll().where('id', '=', id).executeTakeFirst() as MapRow | undefined;
      if (!row) throw notFound('Section map row');
      const set = {
        ...(b.newSection !== undefined ? { new_section: b.newSection } : {}), ...(b.paymentCode !== undefined ? { payment_code: b.paymentCode || null } : {}),
        ...(b.nature !== undefined ? { nature: b.nature } : {}), ...(b.rateText !== undefined ? { rate_text: b.rateText || null } : {}),
        ...(b.thresholdText !== undefined ? { threshold_text: b.thresholdText || null } : {}), ...(b.effectiveFrom !== undefined ? { effective_from: b.effectiveFrom } : {}),
        ...(b.confirmed !== undefined ? { confirmed: b.confirmed } : {}), ...(b.sourceUrl !== undefined ? { source_url: b.sourceUrl || null } : {}),
        ...(b.note !== undefined ? { note: b.note || null } : {}), ...(b.isActive !== undefined ? { is_active: b.isActive } : {}),
      };
      let after: MapRow;
      if (row.tenant_id === null) {
        // System rows are shared; a change becomes this company's own copy.
        const existing = await tx.selectFrom('tds_section_map').selectAll().where('tenant_id', '=', ctx.tenantId).where('old_code', '=', row.old_code)
          .where('effective_from', '=', set.effective_from ?? row.effective_from).executeTakeFirst() as MapRow | undefined;
        if (existing) after = await tx.updateTable('tds_section_map').set(set).where('id', '=', existing.id).returningAll().executeTakeFirstOrThrow() as MapRow;
        else {
          const { id: _id, tenant_id: _t, ...rest } = row;
          after = await tx.insertInto('tds_section_map').values({ ...rest, ...set, tenant_id: ctx.tenantId }).returningAll().executeTakeFirstOrThrow() as MapRow;
        }
      } else {
        after = await tx.updateTable('tds_section_map').set(set).where('id', '=', id).returningAll().executeTakeFirstOrThrow() as MapRow;
      }
      await writeAudit(tx, auditOf(ctx), 'tds_section_map', after.id, 'update', row, after);
      return mapJson(after, todayIst());
    });
  });

  app.get('/tds/forms/names', async (req) => {
    req.ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField.optional() }), req.query);
    const fy = q.fy ?? financialYear(todayIst());
    return { fy, periodLabel: periodLabel(fy), ...formNamesFor(fy), newActFrom: NEW_ACT_FROM };
  });

  app.post('/tds/interest-calc', async (req) => {
    req.ctx.require('tds.view');
    const b = parse(interestBody, req.body);
    const today = todayIst();
    if (b.kind === 'late_deduction') {
      if (!b.dueOn) throw badRequest('Give the date the tax should have been deducted.', { dueOn: 'Required' });
      const onDate = b.onDate ?? today;
      return { kind: b.kind, rate: TDS_INTEREST.lateDeductionPct, interest: lateDeductionInterest(b.tax, b.dueOn, onDate), rule: TDS_INTEREST };
    }
    if (b.kind === 'late_deposit') {
      if (!b.dueOn || !b.onDate) throw badRequest('Give the deduction date and the deposit date.', { dueOn: 'Required' });
      const dueDeposit = tdsDepositDue(b.dueOn.slice(0, 7));
      return { kind: b.kind, rate: TDS_INTEREST.lateDepositPct, dueDate: dueDeposit, ...lateDepositInterest(b.tax, b.dueOn, dueDeposit, b.onDate), rule: TDS_INTEREST };
    }
    return { kind: b.kind, perDay: TDS_INTEREST.lateFeePerDay, lateFee: lateFilingFee(b.daysLate ?? 0, b.tax), rule: TDS_INTEREST };
  });

  // Salary challans -------------------------------------------------------------------------
  app.get('/tds/salary-challans', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField.optional() }), req.query);
    const fy = q.fy ?? financialYear(todayIst());
    const b = fyBounds(fy);
    return ctx.tx(async (tx) => {
      const rows = await tx.selectFrom('tds_salary_challans').selectAll().where('company_id', '=', ctx.companyId)
        .where('month', '>=', b.from).where('month', '<=', b.to).orderBy('month').execute();
      const pay = await tx.selectFrom('payroll_lines').select(['month', 'tds']).where('company_id', '=', ctx.companyId).where('is_live', '=', true)
        .where('month', '>=', b.from).where('month', '<=', b.to).execute();
      const payroll = new Map<string, number>();
      for (const p of pay) payroll.set(p.month.slice(0, 7), round2((payroll.get(p.month.slice(0, 7)) ?? 0) + p.tds));
      return { fy, data: rows.map((r) => ({ ...challanJson(r), payrollTds: payroll.get(r.month.slice(0, 7)) ?? 0 })),
        months: fyMonths(fy).map((m) => ({ month: m, payrollTds: payroll.get(m) ?? 0, challan: rows.some((r) => r.status === 'posted' && r.month.slice(0, 7) === m) })) };
    });
  });

  app.post('/tds/salary-challans', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tds.manage');
    const b = parse(salaryChallanBody, req.body);
    const row = await ctx.tx(async (tx) => {
      const month = `${b.month}-01`;
      const dup = await tx.selectFrom('tds_salary_challans').select('id').where('company_id', '=', ctx.companyId).where('month', '=', month).where('status', '=', 'posted').executeTakeFirst();
      if (dup) throw conflict('A challan is already recorded for this month. Cancel it first.', 'DUPLICATE');
      const pay = await tx.selectFrom('payroll_lines').select(['tds']).where('company_id', '=', ctx.companyId).where('is_live', '=', true).where('month', '=', month).execute();
      const payroll = round2(pay.reduce((s, p) => s + p.tds, 0));
      if (!payroll) throw badRequest('No salary TDS in payroll for this month.', { month: 'No TDS' });
      if (Math.abs(payroll - b.amount) > 0.005) throw badRequest(`Challan amount must equal the payroll TDS of Rs ${payroll} for the month.`, { amount: `Payroll TDS is ${payroll}` });
      const r = await tx.insertInto('tds_salary_challans').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, month, deposit_date: b.depositDate, bsr_code: b.bsrCode, challan_serial: b.challanSerial,
        amount: b.amount, interest: b.interest ?? 0, late_fee: b.lateFee ?? 0, created_by: ctx.userId, cancel_reason: null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'tds_salary_challan', r.id, 'create', null, { month: b.month, amount: b.amount });
      return challanJson(r);
    });
    return reply.status(201).send(row);
  });

  app.post<{ Params: { id: string } }>('/tds/salary-challans/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(z.object({ reason: z.string().trim().min(3).max(300) }), req.body);
    return ctx.tx(async (tx) => {
      const c = await tx.selectFrom('tds_salary_challans').select(['id', 'status']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!c) throw notFound('Salary challan');
      if (c.status === 'cancelled') throw conflict('This challan is already cancelled.', 'ALREADY_CANCELLED');
      const r = await tx.updateTable('tds_salary_challans').set({ status: 'cancelled', cancel_reason: reason }).where('id', '=', id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'tds_salary_challan', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return challanJson(r);
    });
  });

  // Certificates ----------------------------------------------------------------------------
  app.get('/tds/form16', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    ctx.require('payroll.view');
    const q = parse(z.object({ fy: fyField, employeeId: z.uuid() }), req.query);
    const f = await ctx.tx((tx) => buildForm16(tx, ctx, q.fy, q.employeeId));
    if (!f) return reply.status(404).send({ error: { code: 'NOT_FOUND', message: 'No payroll in this year for the employee.' } });
    return f;
  });

  app.get('/tds/form16a', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField, quarter: quarterField, partyId: z.uuid().optional() }), req.query);
    return { data: await ctx.tx((tx) => buildForm16A(tx, ctx, q.fy, q.quarter, q.partyId)) };
  });

  app.post('/tds/certificates/generate', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tds.manage');
    const b = parse(certBody, req.body);
    if (b.kind === 'salary') ctx.require('payroll.view');
    if (b.kind === 'non_salary' && !b.quarter) throw badRequest('Choose a quarter.', { quarter: 'Required' });
    const out = await ctx.tx(async (tx) => {
      const names = formNamesFor(b.fy);
      const items: { employeeId: string | null; partyId: string | null; snap: unknown }[] = [];
      if (b.kind === 'salary') {
        let ids: string[];
        if (b.employeeId) ids = [b.employeeId];
        else {
          const bd = fyBounds(b.fy);
          ids = [...new Set((await tx.selectFrom('payroll_lines').select('employee_id').where('company_id', '=', ctx.companyId).where('is_live', '=', true)
            .where('month', '>=', bd.from).where('month', '<=', bd.to).execute()).map((r) => r.employee_id))];
        }
        for (const id of ids) { const f = await buildForm16(tx, ctx, b.fy, id); if (f) items.push({ employeeId: id, partyId: null, snap: f }); }
      } else {
        for (const f of await buildForm16A(tx, ctx, b.fy, b.quarter!, b.partyId)) items.push({ employeeId: null, partyId: f.deductee.partyId, snap: f });
      }
      await sql`select pg_advisory_xact_lock(hashtext(${ctx.companyId + b.kind + b.fy}))`.execute(tx);
      const form = b.kind === 'salary' ? names.salaryCertificate : names.nonSalaryCertificate;
      const result = [];
      for (const it of items) {
        let q = tx.selectFrom('tds_certificates').select(['id', 'seq', 'number']).where('company_id', '=', ctx.companyId).where('kind', '=', b.kind).where('fy', '=', b.fy);
        q = b.kind === 'salary' ? q.where('employee_id', '=', it.employeeId!) : q.where('party_id', '=', it.partyId!).where('quarter', '=', b.quarter!);
        const ex = await q.executeTakeFirst();
        if (ex) {
          await tx.updateTable('tds_certificates').set({ snapshot: JSON.stringify(it.snap), form_name: form, issued_at: new Date(), issued_by: ctx.userId }).where('id', '=', ex.id).execute();
          result.push({ id: ex.id, number: ex.number, snapshot: it.snap });
        } else {
          const max = await tx.selectFrom('tds_certificates').select((eb) => eb.fn.max('seq').as('m')).where('company_id', '=', ctx.companyId).where('kind', '=', b.kind).where('fy', '=', b.fy).executeTakeFirst();
          const seq = Number(max?.m ?? 0) + 1;
          const number = `${b.kind === 'salary' ? 'SAL' : 'NSL'}/${b.fy}/${String(seq).padStart(4, '0')}`;
          const r = await tx.insertInto('tds_certificates').values({
            tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: b.kind, fy: b.fy, quarter: b.kind === 'salary' ? null : b.quarter!,
            employee_id: it.employeeId, party_id: it.partyId, form_name: form, seq, number, snapshot: JSON.stringify(it.snap), issued_by: ctx.userId,
          }).returning('id').executeTakeFirstOrThrow();
          result.push({ id: r.id, number, snapshot: it.snap });
        }
      }
      await writeAudit(tx, auditOf(ctx), 'tds_certificate', ctx.companyId, 'create', null, { kind: b.kind, fy: b.fy, quarter: b.quarter ?? null, count: result.length });
      return { kind: b.kind, fy: b.fy, quarter: b.quarter ?? null, form, notice: NOTICE, count: result.length, data: result };
    });
    return reply.status(201).send(out);
  });

  app.get('/tds/certificates', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ kind: z.enum(['salary', 'non_salary']), fy: fyField, quarter: quarterField.optional() }), req.query);
    if (q.kind === 'salary') ctx.require('payroll.view');
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('tds_certificates').selectAll().where('company_id', '=', ctx.companyId).where('kind', '=', q.kind).where('fy', '=', q.fy);
      if (q.quarter) base = base.where('quarter', '=', q.quarter);
      const rows = await base.orderBy('seq').execute();
      return { data: rows.map((r) => ({ id: r.id, number: r.number, form: r.form_name, quarter: r.quarter, employeeId: r.employee_id, partyId: r.party_id, issuedAt: r.issued_at, snapshot: r.snapshot })) };
    });
  });

  // Returns ---------------------------------------------------------------------------------
  app.get('/tds/returns', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField, quarter: quarterField, kind: z.enum(['salary', 'non_salary']), format: z.enum(['json', 'csv']).default('json'),
      today: z.string().refine(isValidDate).optional() }), req.query);
    if (q.kind === 'salary') ctx.require('payroll.view');
    const quarter = q.quarter as 1 | 2 | 3 | 4;
    const today = q.today ?? todayIst();
    const data = await ctx.tx((tx): Promise<ReturnData> => (q.kind === 'salary' ? salaryReturn(tx, ctx, q.fy, quarter, today) : nonSalaryReturn(tx, ctx, q.fy, quarter, today)));
    if (q.format === 'json') return data;
    return reply.header('content-disposition', `attachment; filename="tds-${data.form}-${q.fy}-q${quarter}-working.csv"`).type('text/csv; charset=utf-8').send(returnCsv(data));
  });
}
