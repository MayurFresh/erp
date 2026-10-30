import type { FastifyInstance } from 'fastify';
import { sql } from 'kysely';
import { z } from 'zod';
import { systemAccounts, type SystemKey } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { toCsv } from '../lib/csv.ts';
import { addDays, daysBetween, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { addPeriodMonths, addYearsToDate, fyMonths, fyOfPeriod, gstr1Due, gstr3bDue, GST_TIME_BAR_YEARS, monthEnd } from '../lib/due-dates.ts';
import { filedRecord } from '../lib/filing-json.ts';
import { GSTR9C_ABOVE, GSTR9_MANDATORY_ABOVE, UNVERIFIED_PENALTY_FIGURES, gstInterest, gstLateFee } from '../lib/gst-penalties.ts';
import { setoff as runSetoff, sumHeads, zeroHeads, type Heads } from '../lib/gst-setoff.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { moneyField } from '../lib/numbers.ts';
import { canFile, type PrefileCheck } from '../lib/prefile.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, notes, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { addTax, buildGstr1, buildGstr3b, itcReversalRows, loadOutward, round2, zeroTax, type OutDoc, type Tax } from './gst-returns.ts';

const periodField = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM');
const fyField = z.string().regex(/^\d{4}-\d{2}$/, 'Use a financial year such as 2026-27').refine((v) => (Number(v.slice(0, 4)) + 1) % 100 === Number(v.slice(5)), 'Not a financial year');
const splitField = z.enum(['cgst_first', 'sgst_first']);
const paise = (r: number) => Math.round(r * 100);
const rupees = (p: number) => p / 100;
const headsP = (h: { igst: number; cgst: number; sgst: number; cess?: number }): Heads => ({ igst: paise(h.igst), cgst: paise(h.cgst), sgst: paise(h.sgst), cess: paise(h.cess ?? 0) });
const headsR = (h: Heads): Heads => ({ igst: rupees(h.igst), cgst: rupees(h.cgst), sgst: rupees(h.sgst), cess: rupees(h.cess) });
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });

// ---- Balances ---------------------------------------------------------------------------------

async function accountBalance(tx: Tx, accountId: string): Promise<number> {
  const r = await tx.selectFrom('journal_lines').select([(eb) => eb.fn.sum<number>('debit').as('d'), (eb) => eb.fn.sum<number>('credit').as('c')])
    .where('account_id', '=', accountId).executeTakeFirstOrThrow();
  return round2(Number(r.d ?? 0) - Number(r.c ?? 0));
}

async function latestSnapshot(tx: Tx, companyId: string, ledger: 'credit' | 'cash', onOrBefore: string | null) {
  let q = tx.selectFrom('gst_ledger_balances').select(['igst', 'cgst', 'sgst', 'cess']).where('company_id', '=', companyId).where('ledger', '=', ledger);
  if (onOrBefore) q = q.where('as_of', '<=', onOrBefore);
  return q.orderBy('as_of', 'desc').orderBy('created_at', 'desc').limit(1).executeTakeFirst();
}

/** Turnover of a financial year: posted invoices less posted credit notes (taxable value). */
export async function turnoverOf(tx: Tx, companyId: string, fy: string): Promise<number> {
  const from = `${fy.slice(0, 4)}-04-01`;
  const to = `${Number(fy.slice(0, 4)) + 1}-03-31`;
  const i = await tx.selectFrom('invoices').select((eb) => eb.fn.sum<number>('subtotal').as('s'))
    .where('company_id', '=', companyId).where('status', '=', 'posted').where('invoice_date', '>=', from).where('invoice_date', '<=', to).executeTakeFirstOrThrow();
  const c = await tx.selectFrom('credit_notes').select((eb) => eb.fn.sum<number>('subtotal').as('s'))
    .where('company_id', '=', companyId).where('status', '=', 'posted').where('note_date', '>=', from).where('note_date', '<=', to).executeTakeFirstOrThrow();
  return round2(Number(i.s ?? 0) - Number(c.s ?? 0));
}
export const previousFy = (fy: string) => `${Number(fy.slice(0, 4)) - 1}-${String(Number(fy.slice(0, 4)) % 100).padStart(2, '0')}`;

// ---- Set-off ----------------------------------------------------------------------------------

export async function buildSetoff(tx: Tx, ctx: RequestContext, period: string, igstSplit: 'cgst_first' | 'sgst_first', asOf: string = todayIst()) {
  const g3 = await buildGstr3b(tx, ctx, period);
  const company = await tx.selectFrom('companies').select('gst_filing').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const dueDate = gstr3bDue(period, company.gst_filing as 'monthly' | 'quarterly');
  const filedDate = g3.filing?.filedOn ?? asOf;
  const daysLate = Math.max(0, daysBetween(dueDate, filedDate));

  const snap = await latestSnapshot(tx, ctx.companyId, 'credit', dueDate);
  const opening = snap ? headsP(snap) : zeroHeads();
  const itcNet = headsP({ igst: Math.max(0, g3.itc.net.igst), cgst: Math.max(0, g3.itc.net.cgst), sgst: Math.max(0, g3.itc.net.sgst) });
  const credit: Heads = { igst: opening.igst + itcNet.igst, cgst: opening.cgst + itcNet.cgst, sgst: opening.sgst + itcNet.sgst, cess: opening.cess };
  const liability = headsP(g3.outward);
  const rcm = headsP(g3.inwardRcm);
  const first = runSetoff({ liability, rcm, credit, interest: 0, lateFee: 0, igstSplit });
  const nil = g3.outward.taxable === 0 && g3.zeroNil.taxable === 0 && sumHeads(rcm) === 0;
  const turnover = await turnoverOf(tx, ctx.companyId, previousFy(fyOfPeriod(period)));
  const interestP = paise(gstInterest(rupees(sumHeads(first.cash.tax)), daysLate));
  const lateFeeP = paise(gstLateFee(daysLate, nil, turnover));
  const r = runSetoff({ liability, rcm, credit, interest: interestP, lateFee: lateFeeP, igstSplit });

  const acc = await systemAccounts(tx, ctx);
  const books = await accountBalance(tx, acc.gst_cash);
  const portalSnap = await latestSnapshot(tx, ctx.companyId, 'cash', null);
  // The books balance is one number: it pays interest and late fee first, then IGST, CGST, SGST and cess.
  let avail = Math.max(0, paise(books));
  const short = { igst: 0, cgst: 0, sgst: 0, cess: 0, interest: 0, lateFee: 0 };
  for (const [k, need] of [['interest', r.cash.interest], ['lateFee', r.cash.lateFee], ['igst', r.cash.tax.igst], ['cgst', r.cash.tax.cgst], ['sgst', r.cash.tax.sgst], ['cess', r.cash.tax.cess]] as const) {
    const use = Math.min(avail, need);
    avail -= use;
    short[k] = need - use;
  }
  const shortTotal = short.igst + short.cgst + short.sgst + short.cess + short.interest + short.lateFee;
  const amounts = { igst: rupees(short.igst), cgst: rupees(short.cgst), sgst: rupees(short.sgst), cess: rupees(short.cess), interest: rupees(short.interest), lateFee: rupees(short.lateFee) };
  const steps = [
    'Sign in to the GST portal and open Services > Payments > Create Challan (PMT-06).',
    `Enter the amounts: IGST ${amounts.igst.toFixed(2)}, CGST ${amounts.cgst.toFixed(2)}, SGST ${amounts.sgst.toFixed(2)}, cess ${amounts.cess.toFixed(2)}, interest ${amounts.interest.toFixed(2)}, late fee ${amounts.lateFee.toFixed(2)}.`,
    'Pay by net banking, UPI or card, and wait for the CIN to show in the Electronic Cash Ledger.',
    'Record the payment here (CPIN, CIN and the account you paid from), then file GSTR-3B and pay the rest of the tax from the cash ledger.',
  ];
  return {
    period, igstSplit,
    liability: headsR(liability), rcm: headsR(rcm),
    credit: { opening: headsR(opening), itc: headsR(itcNet), total: headsR(credit) },
    matrix: r.matrix.map((m) => ({ ...m, amount: rupees(m.amount) })),
    creditUsed: headsR(r.creditUsed), creditCarryForward: headsR(r.creditCarryForward),
    cash: { tax: headsR(r.cash.tax), interest: rupees(r.cash.interest), lateFee: rupees(r.cash.lateFee), total: rupees(r.cash.total) },
    cashBalance: { books, portal: portalSnap ? { igst: portalSnap.igst, cgst: portalSnap.cgst, sgst: portalSnap.sgst, cess: portalSnap.cess } : null },
    shortfall: { ...amounts, total: rupees(shortTotal) },
    pmt06: { amounts, steps },
    late: { dueDate, daysLate, interest: rupees(r.cash.interest), lateFee: rupees(r.cash.lateFee) },
    unverified: daysLate > 0 ? [...UNVERIFIED_PENALTY_FIGURES] : [],
    _warnings: g3.warnings,
  };
}
type Setoff = Awaited<ReturnType<typeof buildSetoff>>;
export const publicSetoff = ({ _warnings, ...rest }: Setoff) => { void _warnings; return rest; };

/** Posts the gst_setoff journal for a 3B filing. 409 CASH_SHORTFALL when the GST Cash Ledger is short. */
export async function postSetoffJournal(tx: Tx, ctx: RequestContext, filingId: string, period: string, filedOn: string, igstSplit: 'cgst_first' | 'sgst_first') {
  const s = await buildSetoff(tx, ctx, period, igstSplit, filedOn);
  if (s.shortfall.total > 0) {
    const { total: _t, ...shortfall } = s.shortfall;
    void _t;
    throw conflict('The GST Cash Ledger balance is below the cash needed. Record a PMT-06 payment first.', 'CASH_SHORTFALL', { shortfall });
  }
  const acc = await systemAccounts(tx, ctx);
  const warnings: string[] = [];
  for (const [h, key] of [['igst', 'input_igst'], ['cgst', 'input_cgst'], ['sgst', 'input_sgst']] as const) {
    if (s.creditUsed[h] > 0 && (await accountBalance(tx, acc[key])) < s.creditUsed[h]) warnings.push(`Input ${h.toUpperCase()} in the books is below the credit used; check the credit ledger snapshot.`);
  }
  const L = s.liability;
  const rcmTax = round2(s.rcm.igst + s.rcm.cgst + s.rcm.sgst);
  const lines: { accountId: string; amount: number }[] = [
    { accountId: acc.output_igst, amount: L.igst }, { accountId: acc.output_cgst, amount: L.cgst }, { accountId: acc.output_sgst, amount: L.sgst },
    { accountId: acc.rcm_payable, amount: rcmTax }, { accountId: acc.cess_payable, amount: s.cash.tax.cess },
    { accountId: acc.tax_interest, amount: round2(s.cash.interest + s.cash.lateFee) },
    { accountId: acc.input_igst, amount: -s.creditUsed.igst }, { accountId: acc.input_cgst, amount: -s.creditUsed.cgst }, { accountId: acc.input_sgst, amount: -s.creditUsed.sgst },
    { accountId: acc.gst_cash, amount: -s.cash.total },
  ];
  const posting = lines.filter((l) => l.amount !== 0);
  // A nil return has nothing to set off: record the filing without a journal.
  if (posting.length === 0) return { entryId: null, warnings };
  const entryId = await postJournal(tx, auditOf(ctx), {
    date: filedOn, voucherType: 'gst_setoff', voucherId: filingId, number: null, narration: `GST set-off for ${period}`, lines: posting,
  });
  return { entryId, warnings };
}

// ---- Pre-filing check -------------------------------------------------------------------------

const GSTIN_CHARS = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
export function gstinChecksumOk(g: string): boolean {
  if (!/^[0-9A-Z]{15}$/.test(g)) return false;
  let sum = 0;
  for (let i = 0; i < 14; i++) {
    const v = GSTIN_CHARS.indexOf(g[i]!) * (i % 2 === 0 ? 1 : 2);
    sum += Math.floor(v / 36) + (v % 36);
  }
  return GSTIN_CHARS[(36 - (sum % 36)) % 36] === g[14];
}

const exceeds = (a: Tax, b: Tax) => a.igst - b.igst > 1 || a.cgst - b.cgst > 1 || a.sgst - b.sgst > 1;

async function seriesGaps(numbers: string[]): Promise<number> {
  const groups = new Map<string, number[]>();
  for (const n of numbers) {
    const m = /^(.*?)(\d+)$/.exec(n);
    if (m) groups.set(m[1]!, [...(groups.get(m[1]!) ?? []), Number(m[2])]);
  }
  let gaps = 0;
  for (const nums of groups.values()) {
    nums.sort((a, b) => a - b);
    for (let i = 1; i < nums.length; i++) if (nums[i]! - nums[i - 1]! > 1) gaps++;
  }
  return gaps;
}

export async function gstPrefileCheck(tx: Tx, ctx: RequestContext, period: string, ret: 'gstr1' | 'gstr3b'): Promise<PrefileCheck[]> {
  const today = todayIst();
  const company = await tx.selectFrom('companies').select(['gst_filing', 'einvoice_enabled']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const filing = company.gst_filing as 'monthly' | 'quarterly';
  const from = `${period}-01`;
  const to = monthEnd(period);
  const checks: PrefileCheck[] = [];
  const add = (id: string, title: string, status: PrefileCheck['status'], detail: string, count: number | null = null, link: string | null = null) =>
    checks.push({ id, title, status, detail, count, link });

  // sequence
  const mins = await Promise.all([
    tx.selectFrom('invoices').select((eb) => eb.fn.min('invoice_date').as('d')).where('company_id', '=', ctx.companyId).executeTakeFirst(),
    tx.selectFrom('purchases').select((eb) => eb.fn.min('bill_date').as('d')).where('company_id', '=', ctx.companyId).executeTakeFirst(),
    tx.selectFrom('expenses').select((eb) => eb.fn.min('expense_date').as('d')).where('company_id', '=', ctx.companyId).executeTakeFirst(),
    tx.selectFrom('credit_notes').select((eb) => eb.fn.min('note_date').as('d')).where('company_id', '=', ctx.companyId).executeTakeFirst(),
  ]);
  const firstDoc = mins.map((m) => m?.d as string | null | undefined).filter((d): d is string => !!d).sort()[0];
  const prev = addPeriodMonths(period, filing === 'quarterly' ? -3 : -1);
  const label = ret === 'gstr1' ? 'GSTR-1' : 'GSTR-3B';
  if (!firstDoc || firstDoc.slice(0, 7) >= period) add('sequence', 'Previous return filed', 'skip', 'This is the first period with documents.');
  else if (await filedRecord(tx, ctx.companyId, ret, prev)) add('sequence', 'Previous return filed', 'pass', `${label} for ${prev} is filed.`);
  else add('sequence', 'Previous return filed', 'fail', `${label} for ${prev} has no filed record. File it first, or record it in the register.`, null, '/filings');

  const g1 = await buildGstr1(tx, ctx, period);
  if (ret === 'gstr1') {
    const bad = [...g1.b2b, ...g1.cdnr].filter((d: { gstin: string }) => !gstinChecksumOk(d.gstin)).length;
    add('gstin', 'Customer GSTINs are valid', bad ? 'fail' : 'pass', bad ? `${bad} B2B document${bad > 1 ? 's have' : ' has'} a GSTIN that fails the checksum.` : 'All B2B GSTINs pass the checksum.', bad || null, '/gst-returns');
    if (!company.einvoice_enabled) add('irn_missing', 'B2B invoices have an IRN', 'skip', 'E-invoicing is off.');
    else {
      const ids = g1.b2b.map((i: { invoiceId: string }) => i.invoiceId);
      const rows = ids.length ? await tx.selectFrom('invoices').select(['id', 'irn']).where('id', 'in', ids).execute() : [];
      const missing = rows.filter((r) => !r.irn).length;
      add('irn_missing', 'B2B invoices have an IRN', missing ? 'fail' : 'pass', missing ? `${missing} B2B invoice${missing > 1 ? 's have' : ' has'} no IRN.` : 'Every B2B invoice has an IRN.', missing || null, '/invoices');
    }
    const invNos = (await tx.selectFrom('invoices').select('number').where('company_id', '=', ctx.companyId).where('invoice_date', '>=', from).where('invoice_date', '<=', to).execute()).map((r) => r.number);
    const cnNos = (await tx.selectFrom('credit_notes').select('number').where('company_id', '=', ctx.companyId).where('note_date', '>=', from).where('note_date', '<=', to).execute()).map((r) => r.number);
    const gaps = (await seriesGaps(invNos)) + (await seriesGaps(cnNos));
    add('doc_series', 'No gaps in document series', gaps ? 'warn' : 'pass', gaps ? `${gaps} gap${gaps > 1 ? 's' : ''} in the invoice or credit note numbers.` : 'Document numbers run without gaps.', gaps || null);
    const turnover = await turnoverOf(tx, ctx.companyId, previousFy(fyOfPeriod(period)));
    const digits = turnover > 50_000_000 ? 6 : 4;
    const short = g1.hsn.filter((h: { hsnCode: string }) => h.hsnCode.length < digits).length;
    add('hsn_digits', `HSN codes have ${digits} digits`, short ? 'warn' : 'pass', short ? `${short} HSN row${short > 1 ? 's have' : ' has'} fewer than ${digits} digits.` : `All HSN codes have at least ${digits} digits.`, short || null, '/items');
  }
  const v = g1.variance;
  const varBad = Math.abs(v.igst) > 1 || Math.abs(v.cgst) > 1 || Math.abs(v.sgst) > 1;
  add('ledger_variance', 'Return matches the tax ledger', varBad ? 'warn' : 'pass', varBad ? 'GSTR-1 totals differ from the output tax ledger by more than Rs 1.' : 'GSTR-1 totals match the output tax ledger.', null, '/gst-returns');

  if (ret === 'gstr3b') {
    const g3 = await buildGstr3b(tx, ctx, period);
    const g1Filed = await filedRecord(tx, ctx.companyId, 'gstr1', period);
    add('gstr1_filed', 'GSTR-1 is filed', g1Filed ? 'pass' : 'fail', g1Filed ? 'GSTR-1 is filed for this period.' : 'File GSTR-1 for this period first.', null, '/filings');
    const imp = await tx.selectFrom('gst_2b_imports').select('id').where('company_id', '=', ctx.companyId).where('period', '=', period).executeTakeFirst();
    if (!imp) add('ims_pending', 'IMS actions are done', 'skip', 'No 2B import for this period.');
    else {
      const n = await tx.selectFrom('gst_2b_lines').select((eb) => eb.fn.countAll<number>().as('n')).where('import_id', '=', imp.id).where('ims_action', 'in', ['pending', 'none']).executeTakeFirstOrThrow();
      const c = Number(n.n);
      add('ims_pending', 'IMS actions are done', c ? 'warn' : 'pass', c ? `${c} 2B line${c > 1 ? 's' : ''} still pending or without an IMS action.` : 'Every 2B line has an IMS action.', c || null, '/gst-returns');
    }
    if (!g3.itc.others2b) add('itc_vs_2b', 'ITC is within 2B', 'warn', 'No 2B import for this period, so ITC cannot be compared (DRC-01C risk).', null, '/gst-returns');
    else {
      const over = exceeds(g3.itc.others, g3.itc.others2b);
      add('itc_vs_2b', 'ITC is within 2B', over ? 'warn' : 'pass', over ? 'ITC in the books exceeds 2B by more than Rs 1 (DRC-01C risk).' : 'ITC in the books is within 2B.', null, '/gst-returns');
    }
    const rev = g3.itc.reversed.rule37;
    const rc = g3.itc.reclaimed;
    const has = rev.igst + rev.cgst + rev.sgst + rc.igst + rc.cgst + rc.sgst > 0;
    add('rule37', 'Rule 37 reversals', has ? 'warn' : 'pass', has ? 'Rule 37 reversals or reclaims apply. Include them in 4B(2) and 4D(1).' : 'No Rule 37 reversals or reclaims.', null, '/itc-ageing');
    const self = { purchases: await tx.selectFrom('purchases').select(['igst', 'cgst', 'sgst']).where('company_id', '=', ctx.companyId).where('status', '=', 'posted').where('reverse_charge', '=', true).where('rcm_self_invoice_no', 'is not', null).where('bill_date', '>=', from).where('bill_date', '<=', to).execute(),
      expenses: await tx.selectFrom('expenses').select(['igst', 'cgst', 'sgst']).where('company_id', '=', ctx.companyId).where('status', '=', 'posted').where('reverse_charge', '=', true).where('rcm_self_invoice_no', 'is not', null).where('expense_date', '>=', from).where('expense_date', '<=', to).execute() };
    const selfTax = [...self.purchases, ...self.expenses].reduce<Tax>((s, r) => addTax(s, { taxable: 0, igst: r.igst, cgst: r.cgst, sgst: r.sgst }), zeroTax());
    const tieBad = Math.abs(selfTax.igst - g3.inwardRcm.igst) > 1 || Math.abs(selfTax.cgst - g3.inwardRcm.cgst) > 1 || Math.abs(selfTax.sgst - g3.inwardRcm.sgst) > 1;
    add('rcm_tieout', 'RCM ties to self-invoices', tieBad ? 'fail' : 'pass', tieBad ? 'Table 3.1(d) differs from the RCM self-invoices of the period. Raise a self-invoice for each RCM bill.' : 'Table 3.1(d) ties to the RCM self-invoices.', null, '/rcm');
    const s = await buildSetoff(tx, ctx, period, 'cgst_first');
    add('cash_shortfall', 'Cash ledger covers the tax', s.shortfall.total > 0 ? 'warn' : 'pass',
      s.shortfall.total > 0 ? `Pay Rs ${s.shortfall.total.toFixed(2)} on PMT-06 before filing.` : 'The GST Cash Ledger covers the cash needed.', null, '/gst-returns');
  }

  const due = ret === 'gstr1' ? gstr1Due(period, filing) : gstr3bDue(period, filing);
  const daysLate = daysBetween(due, today);
  if (daysLate > 0) {
    const turnover = await turnoverOf(tx, ctx.companyId, previousFy(fyOfPeriod(period)));
    const fee = gstLateFee(daysLate, false, turnover);
    add('late', 'Filed on time', 'warn', `${daysLate} day${daysLate > 1 ? 's' : ''} past the due date ${due}. Late fee up to Rs ${fee.toFixed(2)} plus interest on cash tax (unverified figures).`, daysLate);
  } else add('late', 'Filed on time', 'pass', `Due ${due}.`);
  const limit = addYearsToDate(due, GST_TIME_BAR_YEARS);
  const left = daysBetween(today, limit);
  if (left < 0) add('time_bar', 'Within the 3-year limit', 'fail', `The 3-year limit ended on ${limit}.`, null);
  else if (left <= 90) add('time_bar', 'Within the 3-year limit', 'warn', `Only ${left} days left (limit ${limit}).`, left);
  else add('time_bar', 'Within the 3-year limit', 'pass', `Limit ${limit}.`);
  return checks;
}

// ---- GSTR-9 -----------------------------------------------------------------------------------

interface HsnAgg { hsnCode: string; description: string; unit: string; qty: number; rate: number; taxable: number; igst: number; cgst: number; sgst: number }

async function buildGstr9(tx: Tx, ctx: RequestContext, fy: string) {
  const months = fyMonths(fy);
  const from = `${months[0]}-01`;
  const to = monthEnd(months[11]!);
  const company = await tx.selectFrom('companies').select('gstin').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const o = await loadOutward(tx, ctx.companyId, from, to);
  const turnover = await turnoverOf(tx, ctx.companyId, fy);
  const today = todayIst();

  const sumLines = (docs: OutDoc[], pred: (d: OutDoc, rate: number) => boolean) =>
    docs.reduce((s, d) => d.lines.reduce((t, l) => (pred(d, l.rate) ? addTax(t, l) : t), s), zeroTax());
  const taxed = (_d: OutDoc, rate: number) => rate > 0;
  const b2b = sumLines(o.invoices, (d, r) => taxed(d, r) && !!d.gstin);
  const b2c = sumLines(o.invoices, (d, r) => taxed(d, r) && !d.gstin);
  const creditNotes = sumLines(o.creditNotes, taxed);
  const nilExempt = round2(sumLines(o.invoices, (_d, r) => r === 0).taxable - sumLines(o.creditNotes, (_d, r) => r === 0).taxable);

  const filings = await tx.selectFrom('statutory_filings').select(['return_type', 'period', 'setoff_entry_id']).where('company_id', '=', ctx.companyId)
    .where('status', '=', 'filed').where('period', 'in', months).where('return_type', 'in', ['gstr1', 'gstr3b']).execute();
  const isFiled = (t: string, p: string) => filings.some((f) => f.return_type === t && f.period === p);

  const acc = await systemAccounts(tx, ctx);
  const ledger = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select(['jl.account_id', sqlMonth, (eb) => eb.fn.sum<number>('jl.credit').as('c'), (eb) => eb.fn.sum<number>('jl.debit').as('d')])
    .where('je.company_id', '=', ctx.companyId).where('je.entry_date', '>=', from).where('je.entry_date', '<=', to)
    .where('jl.account_id', 'in', [acc.output_igst, acc.output_cgst, acc.output_sgst]).groupBy(['jl.account_id', monthExpr]).execute();

  const monthly: { period: string; gstr1: Tax; gstr3b: Tax; gstr1Filed: boolean; gstr3bFiled: boolean }[] = [];
  let rcm = zeroTax(); let others = zeroTax(); let rule37 = zeroTax(); let in3b = zeroTax(); let in2b: Tax | null = null;
  const payable = zeroHeads();
  const rcmPaidMonths = zeroTax();
  const warnings: string[] = [];
  const unfiled: string[] = [];
  const mismatched: string[] = [];
  for (const m of months) {
    const inMonth = (d: OutDoc) => d.date.slice(0, 7) === m;
    const inv = o.invoices.filter(inMonth);
    const cn = o.creditNotes.filter(inMonth);
    const g1t = addTax(sumLines(inv, () => true), sumLines(cn, () => true), -1);
    const g3t = addTax(sumLines(inv, taxed), sumLines(cn, taxed), -1);
    const f1 = isFiled('gstr1', m); const f3 = isFiled('gstr3b', m);
    monthly.push({ period: m, gstr1: g1t, gstr3b: g3t, gstr1Filed: f1, gstr3bFiled: f3 });
    if (m <= today.slice(0, 7) && m !== today.slice(0, 7)) {
      if (!f1) unfiled.push(`GSTR-1 ${m}`);
      if (!f3) unfiled.push(`GSTR-3B ${m}`);
    }
    const g3 = await buildGstr3b(tx, ctx, m);
    rcm = addTax(rcm, g3.itc.rcm); others = addTax(others, g3.itc.others);
    rule37 = addTax(rule37, (await itcReversalRows(tx, ctx.companyId, m)).totals.reversal);
    in3b = addTax(in3b, g3.itc.net);
    if (g3.itc.others2b) in2b = addTax(in2b ?? zeroTax(), g3.itc.others2b);
    for (const h of ['igst', 'cgst', 'sgst'] as const) payable[h] = round2(payable[h] + g3t[h] + g3.inwardRcm[h]);
    if (filings.some((f) => f.return_type === 'gstr3b' && f.period === m && f.setoff_entry_id)) {
      for (const h of ['igst', 'cgst', 'sgst'] as const) rcmPaidMonths[h] = round2(rcmPaidMonths[h] + g3.inwardRcm[h]);
    }
    const led = (acct: string) => { const r = ledger.find((x) => x.account_id === acct && x.month === m); return round2(Number(r?.c ?? 0) - Number(r?.d ?? 0)); };
    if (Math.abs(led(acc.output_igst) - g1t.igst) > 1 || Math.abs(led(acc.output_cgst) - g1t.cgst) > 1 || Math.abs(led(acc.output_sgst) - g1t.sgst) > 1) mismatched.push(m);
  }
  if (unfiled.length) warnings.push(`Not filed yet: ${unfiled.join(', ')}. The portal blocks GSTR-9 until every monthly return is filed.`);
  if (mismatched.length) warnings.push(`Month figures differ from the books after corrections: ${mismatched.join(', ')}.`);

  const setoffLines = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select(['jl.account_id', (eb) => eb.fn.sum<number>('jl.debit').as('d'), (eb) => eb.fn.sum<number>('jl.credit').as('c')])
    .where('je.company_id', '=', ctx.companyId).where('je.voucher_type', '=', 'gst_setoff').where('je.entry_date', '>=', from).where('je.entry_date', '<=', to)
    .groupBy('jl.account_id').execute();
  const net = (a: string) => { const r = setoffLines.find((x) => x.account_id === a); return round2(Number(r?.d ?? 0) - Number(r?.c ?? 0)); };
  const paidCredit = zeroHeads(); const paidCash = zeroHeads();
  for (const h of ['igst', 'cgst', 'sgst'] as const) {
    paidCredit[h] = round2(-net(acc[`input_${h}` as SystemKey]));
    paidCash[h] = round2(Math.max(0, net(acc[`output_${h}` as SystemKey]) - paidCredit[h]) + rcmPaidMonths[h]);
  }

  const outHsn = new Map<string, HsnAgg>();
  const bump = (m: Map<string, HsnAgg>, hsn: string, desc: string, unit: string, rate: number, qty: number, t: Tax, sign: number) => {
    const k = `${hsn}|${rate}|${unit}`;
    const r = m.get(k) ?? { hsnCode: hsn, description: desc, unit, qty: 0, rate, taxable: 0, igst: 0, cgst: 0, sgst: 0 };
    r.qty = Math.round((r.qty + sign * qty) * 1000) / 1000;
    r.taxable = round2(r.taxable + sign * t.taxable); r.igst = round2(r.igst + sign * t.igst); r.cgst = round2(r.cgst + sign * t.cgst); r.sgst = round2(r.sgst + sign * t.sgst);
    m.set(k, r);
  };
  for (const d of o.invoices) for (const l of d.lines) bump(outHsn, l.hsn, l.description, l.unit, l.rate, l.qty, l, 1);
  for (const d of o.creditNotes) for (const l of d.lines) bump(outHsn, l.hsn, l.description, l.unit, l.rate, l.qty, l, -1);
  const inHsn = new Map<string, HsnAgg>();
  const pl = await tx.selectFrom('purchase_lines as l').innerJoin('purchases as v', 'v.id', 'l.purchase_id')
    .select(['l.hsn_code', 'l.description', 'l.unit', 'l.gst_rate', 'l.qty', 'l.taxable_value', 'l.igst', 'l.cgst', 'l.sgst'])
    .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted').where('v.bill_date', '>=', from).where('v.bill_date', '<=', to).execute();
  for (const l of pl) bump(inHsn, l.hsn_code ?? '', l.description, l.unit, l.gst_rate, l.qty, { taxable: l.taxable_value, igst: l.igst, cgst: l.cgst, sgst: l.sgst }, 1);
  const hsnRows = (m: Map<string, HsnAgg>) => [...m.values()].sort((a, b) => a.hsnCode.localeCompare(b.hsnCode) || a.rate - b.rate);

  const filingExists = await tx.selectFrom('statutory_filings').select('id').where('company_id', '=', ctx.companyId).where('return_type', '=', 'gstr9').where('period', '=', fy).where('status', '=', 'filed').executeTakeFirst();
  void filingExists;
  return {
    fy, gstin: company.gstin, turnover, mandatory: turnover > GSTR9_MANDATORY_ABOVE, needs9c: turnover > GSTR9C_ABOVE,
    tables: {
      t4: { b2b, b2c, creditNotes, rcm: addTax(zeroTax(), rcmOutward(monthly, rcm)), net: addTax(addTax(addTax(b2b, b2c), creditNotes, -1), rcm) },
      t5: { nilExempt, nonGst: 0 },
      t6: { others, rcm },
      t7: { rule37, rule42_43: zeroTax() },
      t8: { itcIn3b: in3b, itcIn2b: in2b, difference: in2b ? addTax(in3b, in2b, -1) : null },
      t9: { payable, paidCredit, paidCash },
      t10_13: { note: 'Amendments and late reporting (tables 10 to 13) are not tracked in the books. Enter them from your portal records.' },
      t17: hsnRows(outHsn), t18: hsnRows(inHsn),
    },
    monthly, warnings, unverified: [] as string[],
  };
}
const rcmOutward = (_m: unknown, rcm: Tax) => rcm;
const monthExpr = sql<string>`to_char(je.entry_date, 'YYYY-MM')`;
const sqlMonth = monthExpr.as('month');

// ---- Payments (PMT-06) ------------------------------------------------------------------------

const paymentBody = z.object({
  date: docDate, cpin: z.string().regex(/^\d{14}$/, 'CPIN is 14 digits').optional(), cin: z.string().trim().min(1).max(30).optional(),
  paidFromAccountId: z.uuid(), igst: moneyField, cgst: moneyField, sgst: moneyField, cess: moneyField.optional(),
  interest: moneyField.optional(), lateFee: moneyField.optional(), period: periodField.optional(),
});

function paymentSelect(tx: Tx, companyId: string) {
  return tx.selectFrom('gst_payments as p').innerJoin('accounts as a', 'a.id', 'p.paid_from_account_id').innerJoin('users as u', 'u.id', 'p.created_by')
    .select(['p.id', 'p.number', 'p.payment_date', 'p.period', 'p.cpin', 'p.cin', 'p.paid_from_account_id', 'a.name as paid_from_name', 'p.igst', 'p.cgst', 'p.sgst', 'p.cess',
      'p.interest', 'p.late_fee', 'p.total', 'p.status', 'p.created_at', 'p.created_by', 'u.name as created_by_name', 'p.cancelled_at', 'p.cancel_reason'])
    .where('p.company_id', '=', companyId);
}
type PaymentRow = Awaited<ReturnType<ReturnType<typeof paymentSelect>['executeTakeFirstOrThrow']>>;
const paymentJson = (r: PaymentRow) => ({
  id: r.id, number: r.number, date: r.payment_date, period: r.period, cpin: r.cpin, cin: r.cin, paidFromAccountId: r.paid_from_account_id,
  paidFromAccountName: r.paid_from_name, igst: r.igst, cgst: r.cgst, sgst: r.sgst, cess: r.cess, interest: r.interest, lateFee: r.late_fee, total: r.total,
  status: r.status, createdAt: r.created_at, createdBy: { id: r.created_by, name: r.created_by_name }, cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
});

const snapshotBody = z.object({
  ledger: z.enum(['credit', 'cash']), asOf: docDate, igst: moneyField, cgst: moneyField, sgst: moneyField, cess: moneyField.optional(), note: notes.optional(),
});

export async function gstFilingRoutes(app: FastifyInstance) {
  // ---- ITC reversals ----
  app.get('/gst/itc-reversals', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ period: periodField, format: z.enum(['json', 'csv']).default('json') }), req.query);
    const r = await ctx.tx((tx) => itcReversalRows(tx, ctx.companyId, q.period));
    if (q.format === 'json') return r;
    const csv = toCsv(['purchaseId', 'number', 'partyName', 'supplierGstin', 'billDate', 'day180', 'kind', 'paymentId', 'base', 'igst', 'cgst', 'sgst'],
      r.rows.map((x) => [x.purchaseId, x.number, x.partyName, x.supplierGstin, x.billDate, x.day180, x.kind, x.paymentId, x.base, x.igst, x.cgst, x.sgst]));
    return reply.header('content-disposition', `attachment; filename="itc-reversals-${q.period}.csv"`).type('text/csv; charset=utf-8').send(csv);
  });

  // ---- Ledger snapshots ----
  const snapJson = (r: { id: string; ledger: string; as_of: string; igst: number; cgst: number; sgst: number; cess: number; note: string | null; created_at: Date; created_by: string; name: string }) => ({
    id: r.id, ledger: r.ledger, asOf: r.as_of, igst: r.igst, cgst: r.cgst, sgst: r.sgst, cess: r.cess, note: r.note, createdAt: r.created_at, createdBy: { id: r.created_by, name: r.name },
  });
  const snapSelect = (tx: Tx, companyId: string) => tx.selectFrom('gst_ledger_balances as b').innerJoin('users as u', 'u.id', 'b.created_by')
    .select(['b.id', 'b.ledger', 'b.as_of', 'b.igst', 'b.cgst', 'b.sgst', 'b.cess', 'b.note', 'b.created_at', 'b.created_by', 'u.name']).where('b.company_id', '=', companyId);

  app.get('/gst/ledger-balances', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    return ctx.tx(async (tx) => ({ data: (await snapSelect(tx, ctx.companyId).orderBy('b.as_of', 'desc').orderBy('b.created_at', 'desc').execute()).map(snapJson) }));
  });

  app.post('/gst/ledger-balances', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const b = parse(snapshotBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const row = await tx.insertInto('gst_ledger_balances').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, ledger: b.ledger, as_of: b.asOf, igst: b.igst, cgst: b.cgst, sgst: b.sgst, cess: b.cess ?? 0,
        note: b.note ?? null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'gst_ledger_balance', row.id, 'create', null, b);
      return snapJson(await snapSelect(tx, ctx.companyId).where('b.id', '=', row.id).executeTakeFirstOrThrow());
    });
    return reply.status(201).send(out);
  });

  // ---- Set-off ----
  app.get('/gst/setoff', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ period: periodField, igstSplit: splitField.default('cgst_first') }), req.query);
    return ctx.tx(async (tx) => publicSetoff(await buildSetoff(tx, ctx, q.period, q.igstSplit)));
  });

  // ---- PMT-06 payments ----
  app.post('/gst/payments', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const b = parse(paymentBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const from = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active']).where('id', '=', b.paidFromAccountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!from || !from.is_active || !['cash', 'bank'].includes(from.subtype)) throw badRequest('Choose an active cash or bank account.', { paidFromAccountId: 'Not a cash or bank account' });
      const cess = b.cess ?? 0; const interest = b.interest ?? 0; const lateFee = b.lateFee ?? 0;
      const total = round2(b.igst + b.cgst + b.sgst + cess + interest + lateFee);
      if (total <= 0) throw badRequest('Enter an amount to pay.', { igst: 'Total is zero' });
      const number = await nextNumber(tx, ctx, 'gst_payment', financialYear(b.date));
      const row = await tx.insertInto('gst_payments').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, payment_date: b.date, period: b.period ?? null, cpin: b.cpin ?? null, cin: b.cin ?? null,
        paid_from_account_id: from.id, igst: b.igst, cgst: b.cgst, sgst: b.sgst, cess, interest, late_fee: lateFee, total, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const acc = await systemAccounts(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date: b.date, voucherType: 'gst_payment', voucherId: row.id, number, narration: `GST paid by challan${b.cin ? ` ${b.cin}` : ''}`,
        lines: [{ accountId: acc.gst_cash, amount: total }, { accountId: from.id, amount: -total }],
      });
      await writeAudit(tx, auditOf(ctx), 'gst_payment', row.id, 'create', null, { number, total });
      return paymentJson(await paymentSelect(tx, ctx.companyId).where('p.id', '=', row.id).executeTakeFirstOrThrow());
    });
    return reply.status(201).send(out);
  });

  app.get('/gst/payments', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ fy: fyField.optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = paymentSelect(tx, ctx.companyId);
      if (q.fy) base = base.where('p.payment_date', '>=', `${q.fy.slice(0, 4)}-04-01`).where('p.payment_date', '<=', `${Number(q.fy.slice(0, 4)) + 1}-03-31`);
      const rows = await base.orderBy('p.payment_date', 'desc').orderBy('p.created_at', 'desc').execute();
      return { data: rows.map(paymentJson), total: rows.length };
    });
  });

  app.post<{ Params: { id: string } }>('/gst/payments/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const p = await tx.selectFrom('gst_payments').select(['id', 'status', 'number', 'total', 'payment_date']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!p) throw notFound('GST payment');
      if (p.status === 'cancelled') throw conflict('This payment is already cancelled.', 'ALREADY_CANCELLED');
      const acc = await systemAccounts(tx, ctx);
      const bal = await accountBalance(tx, acc.gst_cash);
      if (round2(bal - p.total) < 0) {
        const later = await tx.selectFrom('journal_entries as e').select('e.id').where('e.company_id', '=', ctx.companyId).where('e.voucher_type', '=', 'gst_setoff')
          .where('e.is_reversal', '=', false).where('e.entry_date', '>=', p.payment_date)
          .where((eb) => eb.not(eb.exists(eb.selectFrom('journal_entries as r').select('r.id').whereRef('r.reverses_id', '=', 'e.id')))).limit(1).executeTakeFirst();
        if (later) throw conflict('A GST set-off was posted after this payment and needs it. Cancel that filing first.', 'IN_USE');
      }
      await tx.updateTable('gst_payments').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${p.number}: ${reason}`);
      await writeAudit(tx, auditOf(ctx), 'gst_payment', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return paymentJson(await paymentSelect(tx, ctx.companyId).where('p.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  // ---- Pre-filing check ----
  app.get('/gst/prefile-check', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ period: periodField, return: z.enum(['gstr1', 'gstr3b']) }), req.query);
    const checks = await ctx.tx((tx) => gstPrefileCheck(tx, ctx, q.period, q.return));
    return { period: q.period, return: q.return, checks, canFile: canFile(checks) };
  });

  // ---- GSTR-9 ----
  app.get('/gst/gstr9', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ fy: fyField, format: z.enum(['json', 'csv']).default('json') }), req.query);
    const g = await ctx.tx((tx) => buildGstr9(tx, ctx, q.fy));
    if (q.format === 'json') return g;
    const taxRow = (name: string, t: Tax) => [name, t.taxable, t.igst, t.cgst, t.sgst];
    const t = g.tables;
    const section = (title: string, header: string[], rows: unknown[][]) => `${title}\r\n${toCsv(header, rows)}`;
    const taxHead = ['row', 'taxable', 'igst', 'cgst', 'sgst'];
    const hsnHead = ['hsnCode', 'description', 'unit', 'qty', 'rate', 'taxable', 'igst', 'cgst', 'sgst'];
    const hsn = (rows: HsnAgg[]) => rows.map((r) => [r.hsnCode, r.description, r.unit, r.qty, r.rate, r.taxable, r.igst, r.cgst, r.sgst]);
    const heads = (h: Heads) => [h.igst, h.cgst, h.sgst, h.cess];
    const csv = [
      section('Table 4', taxHead, [taxRow('b2b', t.t4.b2b), taxRow('b2c', t.t4.b2c), taxRow('creditNotes', t.t4.creditNotes), taxRow('rcm', t.t4.rcm), taxRow('net', t.t4.net)]),
      section('Table 5', ['row', 'taxable'], [['nilExempt', t.t5.nilExempt], ['nonGst', t.t5.nonGst]]),
      section('Table 6', taxHead, [taxRow('others', t.t6.others), taxRow('rcm', t.t6.rcm)]),
      section('Table 7', taxHead, [taxRow('rule37', t.t7.rule37), taxRow('rule42_43', t.t7.rule42_43)]),
      section('Table 8', taxHead, [taxRow('itcIn3b', t.t8.itcIn3b), ...(t.t8.itcIn2b ? [taxRow('itcIn2b', t.t8.itcIn2b)] : []), ...(t.t8.difference ? [taxRow('difference', t.t8.difference)] : [])]),
      section('Table 9', ['row', 'igst', 'cgst', 'sgst', 'cess'], [['payable', ...heads(t.t9.payable)], ['paidCredit', ...heads(t.t9.paidCredit)], ['paidCash', ...heads(t.t9.paidCash)]]),
      section('Table 17', hsnHead, hsn(t.t17)), section('Table 18', hsnHead, hsn(t.t18)),
      section('Monthly', ['period', 'gstr1Taxable', 'gstr1Igst', 'gstr1Cgst', 'gstr1Sgst', 'gstr3bTaxable', 'gstr3bIgst', 'gstr3bCgst', 'gstr3bSgst', 'gstr1Filed', 'gstr3bFiled'],
        g.monthly.map((m) => [m.period, m.gstr1.taxable, m.gstr1.igst, m.gstr1.cgst, m.gstr1.sgst, m.gstr3b.taxable, m.gstr3b.igst, m.gstr3b.cgst, m.gstr3b.sgst, m.gstr1Filed, m.gstr3bFiled])),
    ].join('\r\n');
    return reply.header('content-disposition', `attachment; filename="gstr9-${q.fy}.csv"`).type('text/csv; charset=utf-8').send(csv);
  });
}
void isValidDate; void addDays;
