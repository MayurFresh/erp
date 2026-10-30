import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { toCsv } from '../lib/csv.ts';
import { daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { form140Due, fyMonths, quarterRange, tdsDepositDue } from '../lib/due-dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { pickRule, TDS_DEFAULTS } from '../lib/income-tax.ts';
import { moneyField } from '../lib/numbers.ts';
import { nextNumber } from '../lib/series.ts';
import { parse, docDate } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { canFile, type PrefileCheck } from '../lib/prefile.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const fyField = z.string().regex(/^\d{4}-\d{2}$/, 'Use a financial year such as 2026-27');
const quarterField = z.coerce.number().int().min(1).max(4);

const deductionQuery = z.object({
  fy: fyField.optional(),
  quarter: quarterField.optional(),
  sectionCode: z.string().trim().min(1).max(20).optional(),
  partyId: z.uuid().optional(),
  challan: z.enum(['none', 'any']).optional(),
  status: z.enum(['active', 'cancelled', 'all']).default('active'),
  includeZero: z.enum(['true', 'false']).optional(),
  limit: z.coerce.number().int().min(1).max(1000).default(500),
  offset: z.coerce.number().int().min(0).default(0),
});
const challanBody = z.object({
  depositDate: docDate,
  bsrCode: z.string().regex(/^\d{7}$/, 'BSR code is 7 digits'),
  challanSerial: z.string().regex(/^\d{5}$/, 'Challan serial is 5 digits'),
  paidFromAccountId: z.uuid(),
  deductionIds: z.array(z.uuid()).min(1).max(500),
  interest: moneyField.optional(),
  lateFee: moneyField.optional(),
});
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });

function deductionSelect(tx: Tx, companyId: string) {
  return tx.selectFrom('tds_deductions as d')
    .innerJoin('parties as p', 'p.id', 'd.party_id')
    .leftJoin('tds_challans as c', 'c.id', 'd.challan_id')
    .leftJoin('tds_sections as s', 's.id', 'd.section_id')
    .select(['d.id', 'd.source_type', 'd.source_id', 'd.number', 'd.deduction_date', 'd.party_id', 'p.name as party_name', 'd.pan',
      'd.section_code', 'd.gross', 'd.base', 'd.rate', 'd.amount', 'd.status', 'd.challan_id', 'c.number as challan_number',
      'c.challan_serial', 'c.bsr_code', 'c.deposit_date', 's.new_ref'])
    .where('d.company_id', '=', companyId);
}
type DeductionRow = Awaited<ReturnType<ReturnType<typeof deductionSelect>['execute']>>[number];

const deductionJson = (r: DeductionRow) => ({
  id: r.id, sourceType: r.source_type, sourceId: r.source_id, number: r.number, date: r.deduction_date, partyId: r.party_id,
  partyName: r.party_name, pan: r.pan, sectionCode: r.section_code, gross: r.gross, base: r.base, rate: r.rate, amount: r.amount,
  status: r.status, challanId: r.challan_id, challanNumber: r.challan_number,
});

function challanSelect(tx: Tx, companyId: string) {
  return tx.selectFrom('tds_challans as c')
    .innerJoin('accounts as a', 'a.id', 'c.paid_from_account_id')
    .innerJoin('users as u', 'u.id', 'c.created_by')
    .select(['c.id', 'c.number', 'c.deposit_date', 'c.bsr_code', 'c.challan_serial', 'c.tax_amount', 'c.interest', 'c.late_fee', 'c.total',
      'c.paid_from_account_id', 'a.name as paid_from_name', 'c.status', 'c.created_at', 'c.created_by', 'u.name as created_by_name',
      'c.cancelled_at', 'c.cancel_reason'])
    .where('c.company_id', '=', companyId);
}
type ChallanRow = Awaited<ReturnType<ReturnType<typeof challanSelect>['execute']>>[number];

const challanJson = (r: ChallanRow, deductions?: ReturnType<typeof deductionJson>[]) => ({
  id: r.id, number: r.number, depositDate: r.deposit_date, bsrCode: r.bsr_code, challanSerial: r.challan_serial,
  taxAmount: r.tax_amount, interest: r.interest, lateFee: r.late_fee, total: r.total, paidFromAccountId: r.paid_from_account_id,
  paidFromAccountName: r.paid_from_name, status: r.status, createdAt: r.created_at, createdBy: { id: r.created_by, name: r.created_by_name },
  cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason, ...(deductions ? { deductions } : {}),
});

async function loadChallan(tx: Tx, ctx: RequestContext, id: string) {
  const row = await challanSelect(tx, ctx.companyId).where('c.id', '=', id).executeTakeFirst();
  if (!row) throw notFound('TDS challan');
  const ds = await deductionSelect(tx, ctx.companyId).where('d.challan_id', '=', id).orderBy('d.deduction_date').orderBy('d.number').execute();
  return challanJson(row, ds.map(deductionJson));
}

/** Monthly TDS: deducted, deposited (in a posted challan) and pending, with due dates. Shared with the alerts. */
export async function tdsMonths(tx: Tx, companyId: string, fy: string, today = todayIst()) {
  const months = fyMonths(fy);
  const rows = await tx.selectFrom('tds_deductions')
    .select(['deduction_date', 'amount', 'challan_id'])
    .where('company_id', '=', companyId).where('status', '=', 'active').where('amount', '>', 0)
    .where('deduction_date', '>=', `${months[0]}-01`).where('deduction_date', '<=', `${months[11]}-31`).execute();
  return months.map((month) => {
    const mine = rows.filter((r) => r.deduction_date.slice(0, 7) === month);
    const deducted = round2(mine.reduce((s, r) => s + r.amount, 0));
    const deposited = round2(mine.filter((r) => r.challan_id).reduce((s, r) => s + r.amount, 0));
    const pending = round2(deducted - deposited);
    const dueDate = tdsDepositDue(month);
    return { month, deducted, deposited, pending, dueDate, overdue: pending > 0 && dueDate < today };
  });
}

/** Whole months, counting a part month as a month, from `from` to `to` (0 when `to` is not after `from`). */
function monthsOrPart(from: string, to: string): number {
  if (to <= from) return 0;
  const m = (Number(to.slice(0, 4)) - Number(from.slice(0, 4))) * 12 + Number(to.slice(5, 7)) - Number(from.slice(5, 7));
  return Math.max(1, to.slice(8, 10) > from.slice(8, 10) ? m + 1 : m);
}

async function filedOn(tx: Tx, companyId: string, fy: string, quarter: number): Promise<string | null> {
  const r = await tx.selectFrom('statutory_filings').select('filed_on')
    .where('company_id', '=', companyId).where('return_type', '=', 'tds_140').where('period', '=', `${fy}-Q${quarter}`).where('status', '=', 'filed').executeTakeFirst();
  return r ? r.filed_on : null;
}

/** Late-deposit interest and s.427 late fees for a financial year (API v1.6 §5). */
async function tdsDefaults(tx: Tx, companyId: string, fy: string, today = todayIst()) {
  const rule = pickRule(TDS_DEFAULTS, fy);
  const months = fyMonths(fy);
  const rows = await deductionSelect(tx, companyId).where('d.fy', '=', fy).where('d.status', '=', 'active').where('d.amount', '>', 0).execute();
  const deposits = months.map((month) => {
    const mine = rows.filter((r) => r.deduction_date.slice(0, 7) === month);
    const dueDate = tdsDepositDue(month);
    let interest = 0;
    let monthsLate = 0;
    for (const d of mine) {
      const end = d.deposit_date ?? today;
      if (end <= dueDate) continue;
      const m = monthsOrPart(d.deduction_date, end);
      monthsLate = Math.max(monthsLate, m);
      interest += (d.amount * rule.interestPctPerMonth * m) / 100;
    }
    const deposited = mine.filter((r) => r.deposit_date);
    return {
      month, deducted: round2(mine.reduce((a, r) => a + r.amount, 0)),
      depositDate: deposited.length === mine.length && deposited.length ? deposited.map((r) => r.deposit_date!).sort().at(-1)! : null,
      dueDate, monthsLate, interest: round2(interest),
    };
  });
  const statements = [];
  for (const quarter of [1, 2, 3, 4] as const) {
    const r = quarterRange(fy, quarter);
    const tds = round2(rows.filter((d) => d.deduction_date >= r.from && d.deduction_date <= r.to).reduce((a, d) => a + d.amount, 0));
    const dueDate = form140Due(fy, quarter);
    const filed = await filedOn(tx, companyId, fy, quarter);
    const daysLate = tds > 0 ? Math.max(0, daysBetween(dueDate, filed ?? today)) : 0;
    statements.push({ quarter, dueDate, filedOn: filed, daysLate, lateFee: round2(Math.min(daysLate * rule.lateFeePerDay, tds)) });
  }
  return {
    fy, deposits, statements,
    totals: { interest: round2(deposits.reduce((a, d) => a + d.interest, 0)), lateFee: round2(statements.reduce((a, d) => a + d.lateFee, 0)) },
    unverified: rule.verified ? [] : [rule.label],
  };
}

/** TDS pre-filing checks for a quarter's Form 140 (API v1.6 §5). Used by POST /filings for `tds_140`. */
export async function tdsPrefileCheck(tx: Tx, companyId: string, fy: string, quarter: 1 | 2 | 3 | 4): Promise<PrefileCheck[]> {
  const co = await tx.selectFrom('companies').select(['tan', 'responsible_person']).where('id', '=', companyId).executeTakeFirstOrThrow();
  const r = quarterRange(fy, quarter);
  const ds = await deductionSelect(tx, companyId).where('d.status', '=', 'active').where('d.amount', '>', 0)
    .where('d.deduction_date', '>=', r.from).where('d.deduction_date', '<=', r.to).execute();
  const checks: PrefileCheck[] = [];
  const add = (id: string, title: string, status: PrefileCheck['status'], detail: string, count: number | null = null, link: string | null = null) =>
    checks.push({ id, title, status, detail, count, link });

  add('tan', 'Deductor TAN', co.tan ? 'pass' : 'fail', co.tan ? `TAN ${co.tan}.` : 'Company TAN is missing. Add it in company settings.', null, co.tan ? null : '/settings/company');
  const rp = co.responsible_person as { name?: string } | null;
  add('responsible_person', 'Responsible person', rp?.name ? 'pass' : 'fail',
    rp?.name ? `${rp.name} will sign the statement.` : 'Add the deductor\'s responsible person in company settings.', null, rp?.name ? null : '/settings/company');
  const noPan = ds.filter((d) => !d.pan).length;
  add('pan_missing', 'Deductee PAN', noPan ? 'warn' : 'pass', noPan ? `${noPan} deduction${noPan > 1 ? 's' : ''} without PAN, deducted at 20%.` : 'Every deductee has a PAN.', noPan || null, noPan ? '/tds' : null);
  const open = ds.filter((d) => !d.challan_id).length;
  add('unchallaned', 'All deductions deposited', open ? 'fail' : 'pass',
    open ? `${open} deduction${open > 1 ? 's are' : ' is'} not in a challan. Deposit and record the challan first.` : 'Every deduction is in a challan.', open || null, open ? '/tds' : null);
  const challanIds = [...new Set(ds.map((d) => d.challan_id).filter((x): x is string => !!x))];
  let mismatched = 0;
  if (challanIds.length) {
    const cs = await challanSelect(tx, companyId).where('c.id', 'in', challanIds).where('c.status', '=', 'posted').execute();
    const all = await deductionSelect(tx, companyId).where('d.challan_id', 'in', challanIds).where('d.status', '=', 'active').execute();
    for (const c of cs) {
      const sum = round2(all.filter((d) => d.challan_id === c.id).reduce((a, d) => a + d.amount, 0));
      if (Math.abs(sum - c.tax_amount) > 0.005) mismatched += 1;
    }
  }
  add('challan_mismatch', 'Challan totals match', mismatched ? 'fail' : 'pass',
    mismatched ? `${mismatched} challan${mismatched > 1 ? 's do' : ' does'} not match its deductions.` : 'Challan tax equals the deductions in each challan.', mismatched || null);

  if (quarter > 1 && !(await filedOn(tx, companyId, fy, quarter - 1))) {
    add('sequence', 'Earlier quarter filed', 'warn', `Q${quarter - 1} is not marked as filed. File quarters in order.`);
  } else add('sequence', 'Earlier quarter filed', 'pass', quarter > 1 ? `Q${quarter - 1} is filed.` : 'This is the first quarter.');

  const def = await tdsDefaults(tx, companyId, fy);
  const st = def.statements[quarter - 1]!;
  add('late', 'Filing on time', st.lateFee > 0 ? 'warn' : 'pass', st.lateFee > 0 ? `${st.daysLate} days late. Late fee estimate Rs ${st.lateFee}.` : 'Within the due date.', st.daysLate || null);
  const qMonths = fyMonths(fy).slice((quarter - 1) * 3, quarter * 3);
  const interest = round2(def.deposits.filter((d) => qMonths.includes(d.month)).reduce((a, d) => a + d.interest, 0));
  add('interest', 'Deposited on time', interest > 0 ? 'warn' : 'pass', interest > 0 ? `Late deposit interest is about Rs ${interest}. Pay it with the next challan.` : 'No late deposit interest.', null);
  return checks;
}

/** The FVU input draft. Caret-delimited, laid out after the 26Q v7.5 file format. */
function buildTxt(d: { fy: string; quarter: number; tan: string; pan: string | null; name: string; rp: { name: string; designation: string; pan: string; mobile: string; email: string };
  challans: ChallanRow[]; rows: DeductionRow[] }) {
  const ay = `${Number(d.fy.slice(0, 4)) + 1}-${String(Number(d.fy.slice(5)) + 1).padStart(2, '0')}`;
  const ddmmyyyy = (x: string) => `${x.slice(8, 10)}${x.slice(5, 7)}${x.slice(0, 4)}`;
  const total = round2(d.rows.reduce((a, r) => a + r.amount, 0));
  const lines = ['#PROGEN BETA: validate with FVU before upload'];
  lines.push(['FH', 1, 'NS1', 'R', ddmmyyyy(todayIst()), 1, 'D', d.tan, 1, 'Progen ERP', '', '', '', '', '', ''].join('^'));
  lines.push(['BH', 1, d.challans.length + d.rows.length, 1, '', d.tan, '', d.pan ?? '', ay, d.fy.replace('-', ''), `Q${d.quarter}`, d.name, d.rp.name, d.rp.designation, d.rp.pan,
    d.rp.mobile, d.rp.email, d.challans.length, total].join('^'));
  const idx = new Map(d.challans.map((c, i) => [c.id, i + 1]));
  for (const c of d.challans) {
    lines.push(['CD', 1, idx.get(c.id), c.challan_serial, c.bsr_code, ddmmyyyy(c.deposit_date), c.tax_amount.toFixed(2), c.interest.toFixed(2), c.late_fee.toFixed(2), c.total.toFixed(2)].join('^'));
  }
  d.rows.forEach((r, i) => {
    lines.push(['DD', 1, i + 1, idx.get(r.challan_id ?? '') ?? '', r.pan ?? 'PANNOTAVBL', r.party_name, r.new_ref ?? r.section_code, ddmmyyyy(r.deduction_date),
      r.gross.toFixed(2), r.base.toFixed(2), r.rate, r.amount.toFixed(2), r.pan ? '' : 'C'].join('^'));
  });
  return `${lines.join('\r\n')}\r\n`;
}

export async function tdsRoutes(app: FastifyInstance) {
  app.get('/tds/deductions', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(deductionQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = deductionSelect(tx, ctx.companyId);
      const fy = q.fy ?? (q.quarter ? financialYear(todayIst()) : undefined);
      if (fy) base = base.where('d.fy', '=', fy);
      if (q.quarter && fy) {
        const r = quarterRange(fy, q.quarter);
        base = base.where('d.deduction_date', '>=', r.from).where('d.deduction_date', '<=', r.to);
      }
      if (q.sectionCode) base = base.where('d.section_code', '=', q.sectionCode);
      if (q.partyId) base = base.where('d.party_id', '=', q.partyId);
      if (q.challan === 'none') base = base.where('d.challan_id', 'is', null);
      if (q.challan === 'any') base = base.where('d.challan_id', 'is not', null);
      if (q.status !== 'all') base = base.where('d.status', '=', q.status);
      if (q.includeZero !== 'true') base = base.where('d.amount', '>', 0);
      const { total } = await tx.selectFrom(base.as('b')).select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.orderBy('d.deduction_date', 'desc').orderBy('d.created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map(deductionJson), total };
    });
  });

  app.get('/tds/summary', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField.optional() }), req.query);
    const fy = q.fy ?? financialYear(todayIst());
    return ctx.tx(async (tx) => {
      const months = await tdsMonths(tx, ctx.companyId, fy);
      const quarters = [1, 2, 3, 4].map((quarter) => {
        const ms = months.slice((quarter - 1) * 3, quarter * 3);
        return { quarter, form: '140', dueDate: form140Due(fy, quarter as 1 | 2 | 3 | 4), amount: round2(ms.reduce((s, m) => s + m.deducted, 0)) };
      });
      const counts = await tx.selectFrom('tds_deductions').select(['deduction_date'])
        .where('company_id', '=', ctx.companyId).where('status', '=', 'active').where('amount', '>', 0).where('fy', '=', fy).execute();
      const qIndex = (d: string) => {
        const i = months.findIndex((m) => m.month === d.slice(0, 7));
        return i < 0 ? -1 : Math.floor(i / 3);
      };
      return {
        fy, months,
        quarters: quarters.map((r, i) => ({ ...r, rows: counts.filter((c) => qIndex(c.deduction_date) === i).length })),
      };
    });
  });

  app.post('/tds/challans', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tds.manage');
    const body = parse(challanBody, req.body);
    const challan = await ctx.tx(async (tx) => {
      const ids = [...new Set(body.deductionIds)];
      const paidFrom = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active'])
        .where('id', '=', body.paidFromAccountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!paidFrom || !paidFrom.is_active || !['cash', 'bank'].includes(paidFrom.subtype)) {
        throw badRequest('Choose an active cash or bank account.', { paidFromAccountId: 'Not a cash or bank account' });
      }
      const ds = await tx.selectFrom('tds_deductions').select(['id', 'amount', 'status', 'challan_id', 'number'])
        .where('company_id', '=', ctx.companyId).where('id', 'in', ids).orderBy('id').forUpdate().execute();
      if (ds.length !== ids.length) throw badRequest('Some deductions were not found.', { deductionIds: 'Not found' });
      const bad = ds.find((d) => d.status !== 'active' || d.challan_id || d.amount <= 0);
      if (bad) throw badRequest(`${bad.number} cannot go in a challan (cancelled, nil, or already deposited).`, { deductionIds: 'Not eligible' });

      const taxAmount = round2(ds.reduce((s, d) => s + d.amount, 0));
      const interest = body.interest ?? 0;
      const lateFee = body.lateFee ?? 0;
      const total = round2(taxAmount + interest + lateFee);
      const number = await nextNumber(tx, ctx, 'tds_challan', financialYear(body.depositDate));
      const row = await tx.insertInto('tds_challans').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, deposit_date: body.depositDate, bsr_code: body.bsrCode,
        challan_serial: body.challanSerial, tax_amount: taxAmount, interest, late_fee: lateFee, total,
        paid_from_account_id: paidFrom.id, created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      await tx.updateTable('tds_deductions').set({ challan_id: row.id }).where('id', 'in', ids).execute();

      const acc = await systemAccounts(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date: body.depositDate, voucherType: 'tds_challan', voucherId: row.id, number, narration: `TDS deposited, BSR ${body.bsrCode} serial ${body.challanSerial}`,
        lines: [
          { accountId: acc.tds_payable, amount: taxAmount },
          { accountId: acc.tax_interest, amount: round2(interest + lateFee) },
          { accountId: paidFrom.id, amount: -total },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'tds_challan', row.id, 'create', null, { number, taxAmount, interest, lateFee, deductions: ids.length });
      return loadChallan(tx, ctx, row.id);
    });
    return reply.status(201).send(challan);
  });

  app.get('/tds/challans', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField.optional(), status: z.enum(['posted', 'cancelled']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = challanSelect(tx, ctx.companyId);
      if (q.fy) base = base.where('c.deposit_date', '>=', `${q.fy.slice(0, 4)}-04-01`).where('c.deposit_date', '<=', `${Number(q.fy.slice(0, 4)) + 1}-03-31`);
      if (q.status) base = base.where('c.status', '=', q.status);
      const rows = await base.orderBy('c.deposit_date', 'desc').orderBy('c.created_at', 'desc').execute();
      return { data: rows.map((r) => challanJson(r)), total: rows.length };
    });
  });

  app.get<{ Params: { id: string } }>('/tds/challans/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx((tx) => loadChallan(tx, ctx, id));
  });

  app.post<{ Params: { id: string } }>('/tds/challans/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const c = await tx.selectFrom('tds_challans').select(['id', 'status', 'number'])
        .where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!c) throw notFound('TDS challan');
      if (c.status === 'cancelled') throw conflict('This challan is already cancelled.', 'ALREADY_CANCELLED');
      await tx.updateTable('tds_challans').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await tx.updateTable('tds_deductions').set({ challan_id: null }).where('challan_id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${c.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'tds_challan', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      const row = await challanSelect(tx, ctx.companyId).where('c.id', '=', id).executeTakeFirstOrThrow();
      return challanJson(row, []);
    });
  });

  app.get('/tds/statement', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField.optional(), quarter: quarterField.optional(), format: z.enum(['json', 'csv', 'txt']).default('json') }), req.query);
    const fy = q.fy ?? financialYear(todayIst());
    if (q.format === 'txt') {
      if (!q.quarter) throw badRequest('Choose a quarter (1 to 4) for the .txt file.', { quarter: 'Required' });
      const quarter = q.quarter as 1 | 2 | 3 | 4;
      const file = await ctx.tx(async (tx) => {
        const checks = await tdsPrefileCheck(tx, ctx.companyId, fy, quarter);
        if (!canFile(checks)) throw conflict('Fix the blockers before downloading the file.', 'PREFILE_FAILED', { checks });
        const co = await tx.selectFrom('companies').select(['name', 'legal_name', 'tan', 'pan', 'responsible_person']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
        const r = quarterRange(fy, quarter);
        const rows = await deductionSelect(tx, ctx.companyId).where('d.status', '=', 'active').where('d.amount', '>', 0)
          .where('d.deduction_date', '>=', r.from).where('d.deduction_date', '<=', r.to).orderBy('d.deduction_date').orderBy('d.number').execute();
        const ids = [...new Set(rows.map((x) => x.challan_id).filter((x): x is string => !!x))];
        const challans = ids.length ? await challanSelect(tx, ctx.companyId).where('c.id', 'in', ids).orderBy('c.deposit_date').execute() : [];
        const text = buildTxt({ fy, quarter, tan: co.tan!, pan: co.pan, name: co.legal_name ?? co.name, rp: co.responsible_person as never, challans, rows });
        return { text, name: `${co.tan}_140_${fy}_Q${quarter}.txt` };
      });
      return reply.header('content-disposition', `attachment; filename="${file.name}"`).type('text/plain; charset=utf-8').send(file.text);
    }
    const data = await ctx.tx(async (tx) => {
      const company = await tx.selectFrom('companies').select(['name', 'legal_name', 'tan', 'pan']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      let base = deductionSelect(tx, ctx.companyId).where('d.fy', '=', fy).where('d.status', '=', 'active').where('d.amount', '>', 0);
      if (q.quarter) {
        const r = quarterRange(fy, q.quarter);
        base = base.where('d.deduction_date', '>=', r.from).where('d.deduction_date', '<=', r.to);
      }
      const ds = await base.orderBy('d.deduction_date').orderBy('d.number').execute();
      const challanIds = [...new Set(ds.map((d) => d.challan_id).filter((x): x is string => !!x))];
      const challans = challanIds.length
        ? await challanSelect(tx, ctx.companyId).where('c.id', 'in', challanIds).where('c.status', '=', 'posted').orderBy('c.deposit_date').execute()
        : [];
      const warnings: string[] = [];
      if (!company.tan) warnings.push('Company TAN is missing. Add it in company settings before filing.');
      const noPan = ds.filter((d) => !d.pan).length;
      if (noPan) warnings.push(`${noPan} deduction${noPan > 1 ? 's' : ''} without PAN (deducted at the higher rate).`);
      const open = ds.filter((d) => !d.challan_id).length;
      if (open) warnings.push(`${open} deduction${open > 1 ? 's' : ''} not yet deposited in a challan.`);
      return {
        form: '140', fy, quarter: q.quarter ?? null,
        deductor: { name: company.legal_name ?? company.name, tan: company.tan, pan: company.pan },
        challans: challans.map((r) => challanJson(r)),
        rows: ds.map((d) => ({
          pan: d.pan, partyName: d.party_name, sectionCode: d.section_code, newRef: d.new_ref, date: d.deduction_date, gross: d.gross,
          base: d.base, rate: d.rate, amount: d.amount, challanSerial: d.challan_serial, bsrCode: d.bsr_code, depositDate: d.deposit_date,
        })),
        warnings,
      };
    });
    if (q.format === 'json') return data;
    const csv = toCsv(
      ['pan', 'partyName', 'sectionCode', 'newRef', 'date', 'gross', 'base', 'rate', 'amount', 'challanSerial', 'bsrCode', 'depositDate'],
      data.rows.map((r) => [r.pan, r.partyName, r.sectionCode, r.newRef, r.date, r.gross, r.base, r.rate, r.amount, r.challanSerial, r.bsrCode, r.depositDate]),
    );
    return reply.header('content-disposition', `attachment; filename="tds-statement-${fy}${q.quarter ? `-q${q.quarter}` : ''}.csv"`)
      .type('text/csv; charset=utf-8').send(csv);
  });

  app.get('/tds/prefile-check', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField.optional(), quarter: quarterField.default(1) }), req.query);
    const fy = q.fy ?? financialYear(todayIst());
    const checks = await ctx.tx((tx) => tdsPrefileCheck(tx, ctx.companyId, fy, q.quarter as 1 | 2 | 3 | 4));
    return { fy, quarter: q.quarter, checks, canFile: canFile(checks) };
  });

  app.get('/tds/defaults', async (req) => {
    const ctx = req.ctx;
    ctx.require('tds.view');
    const q = parse(z.object({ fy: fyField.optional() }), req.query);
    return ctx.tx((tx) => tdsDefaults(tx, ctx.companyId, q.fy ?? financialYear(todayIst())));
  });
}
