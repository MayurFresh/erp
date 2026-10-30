import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { toCsv } from '../lib/csv.ts';
import { daysBetween, financialYear, todayIst } from '../lib/dates.ts';
import { advanceTaxDates } from '../lib/due-dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import {
  ADVANCE_TAX, CA_RULES, CASH_PAYMENT_LIMIT, entityOf, entityTax, individualTax, individualTaxable, pickRule, presumptiveCheck,
  regimeConfig, type Age, type Regime,
} from '../lib/income-tax.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, money, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { itSchedule } from './fixed-assets.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const taxYearField = z.string().regex(/^\d{4}-\d{2}$/, 'Use a tax year such as 2026-27')
  .refine((v) => (Number(v.slice(0, 4)) + 1) % 100 === Number(v.slice(5)), 'The second part must follow the first (2026-27)');
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const ageField = z.enum(['below60', '60to80', 'above80']);

const paymentBody = z.object({
  kind: z.enum(['advance_tax', 'self_assessment', 'other']),
  taxYear: taxYearField,
  date: docDate,
  amount: money.refine((v) => v > 0, 'Must be above zero'),
  bsrCode: z.string().regex(/^\d{7}$/, 'BSR code is 7 digits'),
  challanSerial: z.string().regex(/^\d{5}$/, 'Challan serial is 5 digits'),
  paidFromAccountId: z.uuid(),
});
const regimeBody = z.object({
  taxYear: taxYearField, age: ageField,
  salary: money.default(0), business: money.default(0), otherIncome: money.default(0),
  deductions: z.object({ s80c: money.optional(), s80d: money.optional(), homeLoanInterest: money.optional(), other: money.optional() }).optional(),
});
const presumptiveBody = z.object({
  taxYear: taxYearField, kind: z.enum(['business', 'profession']), digitalReceipts: money, cashReceipts: money, declaredProfit: z.coerce.number().min(-1e10).max(1e10).optional(),
});
const advanceQuery = z.object({
  taxYear: taxYearField.optional(), estimatedIncome: money.optional(), regime: z.enum(['new', 'old']).default('new'),
  presumptive: z.enum(['true', 'false']).default('false'),
});
const packQuery = z.object({
  taxYear: taxYearField.optional(), form: z.enum(['itr3', 'itr4']).optional(), format: z.enum(['json', 'csv']).default('json'),
});

const taxYearRange = (ty: string) => ({ from: `${ty.slice(0, 4)}-04-01`, to: `${Number(ty.slice(0, 4)) + 1}-03-31` });
const currentTaxYear = () => financialYear(todayIst());

// --- Payments ----------------------------------------------------------------------------------

function paymentSelect(tx: Tx, companyId: string) {
  return tx.selectFrom('tax_payments as t')
    .innerJoin('accounts as a', 'a.id', 't.paid_from_account_id')
    .innerJoin('users as u', 'u.id', 't.created_by')
    .select(['t.id', 't.number', 't.kind', 't.tax_year', 't.payment_date', 't.amount', 't.bsr_code', 't.challan_serial',
      't.paid_from_account_id', 'a.name as paid_from_name', 't.status', 't.created_at', 't.created_by', 'u.name as created_by_name',
      't.cancelled_at', 't.cancel_reason'])
    .where('t.company_id', '=', companyId);
}
type PaymentRow = Awaited<ReturnType<ReturnType<typeof paymentSelect>['execute']>>[number];

const paymentJson = (r: PaymentRow) => ({
  id: r.id, number: r.number, kind: r.kind, taxYear: r.tax_year, date: r.payment_date, amount: Number(r.amount), bsrCode: r.bsr_code,
  challanSerial: r.challan_serial,
  /** Challan identification number: BSR code, date (YYYYMMDD) and serial. */
  cin: `${r.bsr_code}${r.payment_date.replaceAll('-', '')}${r.challan_serial}`,
  paidFromAccountId: r.paid_from_account_id, paidFromAccountName: r.paid_from_name, status: r.status, createdAt: r.created_at,
  createdBy: { id: r.created_by, name: r.created_by_name }, cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
});

async function postedPayments(tx: Tx, companyId: string, taxYear: string) {
  const rows = await paymentSelect(tx, companyId).where('t.tax_year', '=', taxYear).where('t.status', '=', 'posted').orderBy('t.payment_date').execute();
  return rows.map(paymentJson);
}

// --- Books figures -----------------------------------------------------------------------------

interface Tot { code: string; name: string; type: string; subtype: string; key: string | null; d: number; c: number }

async function totals(tx: Tx, companyId: string, from: string | null, to: string): Promise<Tot[]> {
  let q = tx.selectFrom('accounts as a')
    .innerJoin('journal_lines as jl', 'jl.account_id', 'a.id')
    .innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .where('a.company_id', '=', companyId).where('je.entry_date', '<=', to);
  if (from) q = q.where('je.entry_date', '>=', from);
  const rows = await q.groupBy(['a.id', 'a.code', 'a.name', 'a.type', 'a.subtype', 'a.system_key'])
    .select((eb) => ['a.code', 'a.name', 'a.type', 'a.subtype', 'a.system_key', eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
    .orderBy('a.code').execute();
  return rows.map((r) => ({ code: r.code, name: r.name, type: r.type, subtype: r.subtype, key: r.system_key, d: Number(r.d), c: Number(r.c) }));
}

const PNL_BUCKETS = [
  ['revenue', 'Revenue from operations'], ['otherIncome', 'Other income'], ['purchases', 'Purchases and cost of goods sold'],
  ['directExpenses', 'Direct expenses'], ['employeeCost', 'Employee cost'], ['financeCost', 'Finance cost and bank charges'],
  ['depreciationBooks', 'Depreciation (books)'], ['otherExpenses', 'Other expenses'],
] as const;
type Bucket = (typeof PNL_BUCKETS)[number][0];

function pnlBucket(t: Tot): Bucket {
  if (t.type === 'income') return ['sales', 'sales_returns', 'property_sales'].includes(t.key ?? '') ? 'revenue' : 'otherIncome';
  if (['cogs', 'purchases_nonstock'].includes(t.key ?? '')) return 'purchases';
  if (['material_consumed', 'site_labour', 'subcontract_cost', 'stock_loss'].includes(t.key ?? '')) return 'directExpenses';
  if (t.code === '6010') return 'employeeCost';
  if (t.code === '6070') return 'financeCost';
  if (t.key === 'depreciation') return 'depreciationBooks';
  return 'otherExpenses';
}

/** The P&L of a date range in the ITR pack's buckets. netProfit matches `GET /reports/profit-loss`. */
function pnlOf(rows: Tot[]) {
  const sums = Object.fromEntries(PNL_BUCKETS.map(([k]) => [k, 0])) as Record<Bucket, number>;
  const accounts = Object.fromEntries(PNL_BUCKETS.map(([k]) => [k, [] as string[]])) as Record<Bucket, string[]>;
  let net = 0;
  for (const t of rows) {
    if (t.type !== 'income' && t.type !== 'expense') continue;
    const amount = t.type === 'income' ? t.c - t.d : t.d - t.c;
    if (Math.abs(amount) < 0.005) continue;
    const k = pnlBucket(t);
    sums[k] += amount;
    accounts[k].push(`${t.code} ${t.name}`);
    net += t.type === 'income' ? amount : -amount;
  }
  const lines = PNL_BUCKETS.filter(([k]) => accounts[k].length).map(([k, label]) => ({ schedule: k, label, amount: round2(sums[k]), accounts: accounts[k] }));
  const r = Object.fromEntries(PNL_BUCKETS.map(([k]) => [k, round2(sums[k])])) as Record<Bucket, number>;
  return { ...r, netProfit: round2(net), lines };
}

async function cashShares(tx: Tx, companyId: string, from: string, to: string) {
  const rows = await tx.selectFrom('payments').select(['kind', 'mode', 'amount'])
    .where('company_id', '=', companyId).where('status', '<>', 'cancelled').where('payment_date', '>=', from).where('payment_date', '<=', to).execute();
  const sum = (kind: string, cash: boolean | null) => rows.filter((r) => r.kind === kind && (cash === null || (r.mode === 'cash') === cash))
    .reduce((s, r) => s + Number(r.amount), 0);
  const pct = (kind: string) => (sum(kind, null) > 0 ? (sum(kind, true) / sum(kind, null)) * 100 : 0);
  return {
    cashReceipts: round2(sum('receipt', true)), digitalReceipts: round2(sum('receipt', false)),
    cashReceiptsPct: round2(pct('receipt')), cashPaymentsPct: round2(pct('payment')),
  };
}

async function company(tx: Tx, companyId: string) {
  return tx.selectFrom('companies').select(['name', 'legal_name', 'pan', 'gstin', 'address', 'constitution', 'itr_form']).where('id', '=', companyId).executeTakeFirstOrThrow();
}

const monthsElapsed = (taxYear: string, today: string) => {
  const start = Number(taxYear.slice(0, 4)) * 12 + 3;
  const now = Number(today.slice(0, 4)) * 12 + Number(today.slice(5, 7)) - 1;
  return Math.min(12, Math.max(1, now - start + 1));
};

// --- CA check ----------------------------------------------------------------------------------

async function caRequired(tx: Tx, companyId: string, taxYear: string) {
  const { from, to } = taxYearRange(taxYear);
  const rule = pickRule(CA_RULES, taxYear);
  const co = await company(tx, companyId);
  const pnl = pnlOf(await totals(tx, companyId, from, to));
  const shares = await cashShares(tx, companyId, from, to);
  const turnover = pnl.revenue;
  const gst = await tx.selectFrom('invoices').select((eb) => eb.fn.sum<number>('subtotal').as('s'))
    .where('company_id', '=', companyId).where('status', '<>', 'cancelled').where('invoice_date', '>=', from).where('invoice_date', '<=', to).executeTakeFirst();
  const gstTurnover = round2(Number(gst?.s ?? 0));
  const foreign = await tx.selectFrom('invoices').select('id').where('company_id', '=', companyId).where('status', '<>', 'cancelled')
    .where('place_of_supply', '=', '96').limit(1).executeTakeFirst();
  const gains = await tx.selectFrom('fixed_assets').select('id').where('company_id', '=', companyId).where('status', '=', 'disposed')
    .where('disposal_date', '>=', from).where('disposal_date', '<=', to).where('gain_loss', '>', 0)
    .where('block_code', 'in', ['building', 'building_res', 'land']).limit(1).executeTakeFirst();

  const mostlyDigital = shares.cashReceiptsPct <= rule.maxCashSharePct && shares.cashPaymentsPct <= rule.maxCashSharePct;
  const auditLimit = mostlyDigital ? rule.taxAuditTurnoverMostlyDigital : rule.taxAuditTurnover;
  const unverifiedNote = rule.verified ? [] : [rule.label];
  type Item = { id: string; severity: 'required' | 'advised'; title: string; reason: string; law: string; canSelfFile: string | null };
  const items: Item[] = [];
  if (turnover > auditLimit) {
    items.push({
      id: 'tax_audit', severity: 'required', title: 'Tax audit report',
      reason: `Business turnover of Rs ${turnover.toLocaleString('en-IN')} is above Rs ${auditLimit.toLocaleString('en-IN')}${mostlyDigital ? ' (the higher limit, as cash receipts and payments are each 5% or less)' : ''}.`,
      law: 'Section 63 of the Income-tax Act 2025 (old 44AB)', canSelfFile: 'The app prepares the books, schedules and ITR data. The audit report itself needs a chartered accountant.',
    });
  }
  if (['private_company', 'public_company', 'llp'].includes(co.constitution ?? '')) {
    items.push({
      id: 'company_audit', severity: 'required', title: 'Statutory audit',
      reason: co.constitution === 'llp' ? 'LLPs are audited when turnover or contribution crosses the prescribed limits.' : 'Every company must have its accounts audited by a chartered accountant. ITR-6 also needs a digital signature.',
      law: co.constitution === 'llp' ? 'LLP Act 2008, section 34' : 'Companies Act 2013, section 139', canSelfFile: 'The app prepares the books and the ITR data pack. The audit and the digital signature are outside it.',
    });
  }
  if (gstTurnover > rule.gst9cTurnover) {
    items.push({
      id: 'gst_9c', severity: 'advised', title: 'GSTR-9C reconciliation',
      reason: `GST turnover of Rs ${gstTurnover.toLocaleString('en-IN')} is above Rs ${rule.gst9cTurnover.toLocaleString('en-IN')}.`,
      law: 'CGST Act, section 44', canSelfFile: 'GSTR-9C is self-certified. The app prepares the GSTR-9 pack. A review by a chartered accountant is advised.',
    });
  }
  if (foreign) {
    items.push({
      id: 'foreign', severity: 'advised', title: 'Foreign payments or exports',
      reason: 'There is an invoice with a foreign place of supply.', law: 'Forms 15CA and 15CB for remittances',
      canSelfFile: 'You can file 15CA Part A yourself. 15CB needs a chartered accountant for larger remittances.',
    });
  }
  if (gains) {
    items.push({
      id: 'capital_gains', severity: 'advised', title: 'Capital gain on a building or land',
      reason: 'A building or land was sold at a gain in this year.', law: 'Capital gains provisions', canSelfFile: 'The app shows the sale and the gain. The gain schedule is best reviewed by a chartered accountant.',
    });
  }
  if (!co.constitution) {
    items.push({
      id: 'constitution_missing', severity: 'advised', title: 'Business type not set',
      reason: 'Set the business type (proprietorship, partnership, company and so on) in company settings so the right checks apply.', law: 'Company settings', canSelfFile: null,
    });
  }
  return {
    taxYear, needed: items.some((i) => i.severity === 'required'), items,
    figures: { turnover, cashReceiptsPct: shares.cashReceiptsPct, professionalReceipts: null, gstTurnover },
    unverified: unverifiedNote,
  };
}

// --- Advance tax -------------------------------------------------------------------------------

async function advanceTax(tx: Tx, companyId: string, taxYear: string, opts: { estimatedIncome?: number; regime: Regime; presumptive: boolean }) {
  const { from, to } = taxYearRange(taxYear);
  const rule = pickRule(ADVANCE_TAX, taxYear);
  const co = await company(tx, companyId);
  const entity = entityOf(co.constitution);
  const today = todayIst();
  let income = opts.estimatedIncome;
  if (income === undefined) {
    const upTo = today < to ? today : to;
    const profit = pnlOf(await totals(tx, companyId, from, upTo)).netProfit;
    income = Math.max(0, round2((profit * 12) / monthsElapsed(taxYear, today)));
  }
  const unverified = new Set<string>();
  const calc = entity === 'individual' || entity === 'huf'
    ? individualTax(regimeConfig(opts.regime, taxYear), 'below60', income)
    : entityTax(entity, taxYear, income, false);
  calc.unverified.forEach((u) => unverified.add(u));
  if (!rule.verified) unverified.add(rule.label);

  const tdsRow = await tx.selectFrom('accounts as a').innerJoin('journal_lines as jl', 'jl.account_id', 'a.id').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select((eb) => [eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
    .where('a.company_id', '=', companyId).where('a.system_key', '=', 'tds_receivable').where('je.entry_date', '>=', from).where('je.entry_date', '<=', to).executeTakeFirst();
  const tdsCredit = Math.max(0, round2(Number(tdsRow?.d ?? 0) - Number(tdsRow?.c ?? 0)));
  const netTax = Math.max(0, round2(calc.calc.total - tdsCredit));
  const required = netTax >= rule.minNetTax;

  const pays = await tx.selectFrom('tax_payments').select(['kind', 'payment_date', 'amount'])
    .where('company_id', '=', companyId).where('tax_year', '=', taxYear).where('status', '=', 'posted').execute();
  const advancePays = pays.filter((p) => p.kind === 'advance_tax');
  const dates = advanceTaxDates(taxYear, opts.presumptive);
  const months = opts.presumptive ? [1] : rule.interest425Months;
  const instalments = dates.map((d, i) => {
    const cumulativeDue = round2((netTax * d.cumulativePct) / 100);
    const paidByDate = round2(advancePays.filter((p) => p.payment_date <= d.dueDate).reduce((s, p) => s + Number(p.amount), 0));
    const shortfall = Math.max(0, round2(cumulativeDue - paidByDate));
    const interest425 = required ? round2((shortfall * rule.interest425PctPerMonth * (months[i] ?? 1)) / 100) : 0;
    return { dueDate: d.dueDate, cumulativePct: d.cumulativePct, cumulativeDue, paidByDate, shortfall, interest425 };
  });
  const advancePaid = round2(advancePays.reduce((s, p) => s + Number(p.amount), 0));
  const paid = round2(pays.filter((p) => p.kind !== 'other').reduce((s, p) => s + Number(p.amount), 0));
  const interest424 = required && advancePaid < (netTax * rule.interest424ThresholdPct) / 100
    ? round2((Math.max(0, netTax - advancePaid) * rule.interest424PctPerMonth * rule.interest424Months) / 100) : 0;
  return {
    taxYear, entity, estimatedIncome: income, tax: calc.calc, tdsCredit, netTax, required, instalments, interest424, paid,
    balance: round2(netTax - paid), unverified: [...unverified],
  };
}

// --- ITR pack ----------------------------------------------------------------------------------

async function itrPack(ctx: RequestContext, tx: Tx, taxYear: string, formQ?: 'itr3' | 'itr4') {
  const { from, to } = taxYearRange(taxYear);
  const asOf = todayIst() < to ? todayIst() : to;
  const co = await company(tx, ctx.companyId);
  const form = formQ ?? co.itr_form ?? 'itr3';
  const rows = await totals(tx, ctx.companyId, from, to);
  const pnl = pnlOf(rows);

  // Balance sheet at the end of the year (or today).
  const all = await totals(tx, ctx.companyId, null, asOf);
  const bs = { capital: 0, loans: 0, payables: 0, otherLiabilities: 0, fixedAssetsNet: 0, inventory: 0, receivables: 0, cashBank: 0, otherAssets: 0 };
  const bsAccounts: Record<string, string[]> = {};
  const put = (k: keyof typeof bs, amount: number, t: Tot) => {
    if (Math.abs(amount) < 0.005) return;
    bs[k] += amount;
    (bsAccounts[k] ??= []).push(`${t.code} ${t.name}`);
  };
  let retained = 0;
  for (const t of all) {
    if (t.type === 'income') retained += t.c - t.d;
    else if (t.type === 'expense') retained -= t.d - t.c;
    else if (t.type === 'equity') put('capital', t.c - t.d, t);
    else if (t.type === 'liability') put(t.subtype === 'payables' ? 'payables' : /loan/i.test(t.name) ? 'loans' : 'otherLiabilities', t.c - t.d, t);
    else if (t.type === 'asset') {
      const k = t.subtype === 'cash' || t.subtype === 'bank' ? 'cashBank' : t.subtype === 'receivables' ? 'receivables'
        : t.subtype === 'inventory' ? 'inventory' : t.subtype === 'fixed_asset' ? 'fixedAssetsNet' : 'otherAssets';
      put(k, t.d - t.c, t);
    }
  }
  bs.capital += retained;
  const bsLabels: Record<string, string> = {
    capital: 'Capital and reserves', loans: 'Loans', payables: 'Trade payables', otherLiabilities: 'Other liabilities', fixedAssetsNet: 'Fixed assets (net)',
    inventory: 'Inventory', receivables: 'Trade receivables', cashBank: 'Cash and bank', otherAssets: 'Other assets',
  };
  const bsLines = Object.keys(bs).map((k) => ({ schedule: k, label: bsLabels[k]!, amount: round2(bs[k as keyof typeof bs]), accounts: bsAccounts[k] ?? [] }));

  const dep = await itSchedule(tx, ctx.companyId, taxYear);
  const tax = await tx.selectFrom('accounts as a').innerJoin('journal_lines as jl', 'jl.account_id', 'a.id').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select((eb) => [eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
    .where('a.company_id', '=', ctx.companyId).where('a.system_key', '=', 'tax_interest').where('je.entry_date', '>=', from).where('je.entry_date', '<=', to).executeTakeFirst();
  const taxInterest = round2(Number(tax?.d ?? 0) - Number(tax?.c ?? 0));
  const cashPays = await tx.selectFrom('payments').select(['amount']).where('company_id', '=', ctx.companyId).where('kind', '=', 'payment').where('mode', '=', 'cash')
    .where('status', '<>', 'cancelled').where('amount', '>', CASH_PAYMENT_LIMIT).where('payment_date', '>=', from).where('payment_date', '<=', to).execute();
  const cashFlag = round2(cashPays.reduce((s, r) => s + Number(r.amount), 0));

  type Adj = { label: string; amount: number; kind: 'add' | 'less'; reason: string };
  const adjustments: Adj[] = [];
  if (pnl.depreciationBooks) adjustments.push({ label: 'Book depreciation', amount: pnl.depreciationBooks, kind: 'add', reason: 'Added back; income-tax depreciation is claimed instead.' });
  if (dep.totals.depreciation) adjustments.push({ label: 'Income-tax depreciation', amount: dep.totals.depreciation, kind: 'less', reason: 'Block depreciation from the IT schedule.' });
  if (taxInterest) adjustments.push({ label: 'Interest and late fee on taxes', amount: taxInterest, kind: 'add', reason: 'Interest on taxes is not deductible.' });
  if (cashFlag) adjustments.push({ label: 'Cash payments above Rs 10,000', amount: cashFlag, kind: 'add', reason: 'Flagged as possibly disallowed (s.40A(3) equivalent). Review before filing.' });
  const adjusted = round2(pnl.netProfit + adjustments.reduce((s, a) => s + (a.kind === 'add' ? a.amount : -a.amount), 0));

  let presumptive: { digitalReceipts: number; cashReceipts: number; deemedIncome: number } | null = null;
  const unverified = new Set<string>(dep.unverified);
  if (form === 'itr4') {
    const sh = await cashShares(tx, ctx.companyId, from, to);
    const p = presumptiveCheck(taxYear, 'business', sh.digitalReceipts, sh.cashReceipts);
    p.unverified.forEach((u) => unverified.add(u));
    presumptive = { digitalReceipts: sh.digitalReceipts, cashReceipts: sh.cashReceipts, deemedIncome: p.deemedIncome };
  }

  const tds = await tx.selectFrom('payments as p').innerJoin('parties as pa', 'pa.id', 'p.party_id')
    .select(['pa.name', (eb) => eb.fn.sum<number>('p.tds_amount').as('amount')])
    .where('p.company_id', '=', ctx.companyId).where('p.kind', '=', 'receipt').where('p.status', '<>', 'cancelled').where('p.tds_amount', '>', 0)
    .where('p.payment_date', '>=', from).where('p.payment_date', '<=', to).groupBy('pa.name').orderBy('pa.name').execute();

  const warnings = [
    'Marginal relief on surcharge is ignored in the tax estimates.',
    ...(cashFlag ? [`Cash payments above Rs 10,000 total Rs ${cashFlag}. Check them before claiming the expense.`] : []),
    ...(!co.pan ? ['Company PAN is missing. Add it in company settings.'] : []),
    ...(unverified.size ? ['Some rates used here are not yet verified against the Act. See the unverified list.'] : []),
  ];
  const steps = [
    'Check the profit and loss and balance sheet figures against your books.',
    'Review the adjustments (depreciation, interest, cash payments).',
    'Confirm the taxes paid and the TDS credits against Form 26AS / AIS on the income-tax portal.',
    form === 'itr4' ? 'Enter the presumptive receipts and deemed income in ITR-4.' : 'Enter the profit and loss and balance sheet schedules in ITR-3.',
    'Pay any balance tax as self-assessment tax before filing, and record it here.',
    'File the return on incometax.gov.in, e-verify it, and keep the acknowledgement PDF.',
  ];
  const { lines: pnlLines, ...pnlSums } = pnl;
  return {
    taxYear, form, entity: entityOf(co.constitution),
    company: { name: co.legal_name ?? co.name, pan: co.pan, gstin: co.gstin, address: co.address },
    pnl: { ...pnlSums, lines: pnlLines },
    balanceSheet: { ...Object.fromEntries(Object.entries(bs).map(([k, v]) => [k, round2(v)])), lines: bsLines },
    depreciation: dep.rows, adjustments, presumptive,
    tdsCredits: tds.map((t) => ({ deductorName: t.name, tan: null as string | null, amount: Number(t.amount) })),
    taxesPaid: await postedPayments(tx, ctx.companyId, taxYear),
    incomeEstimate: presumptive ? presumptive.deemedIncome : adjusted, steps, warnings, unverified: [...unverified],
  };
}

export async function incomeTaxRoutes(app: FastifyInstance) {
  app.get('/tax/payments', async (req) => {
    const ctx = req.ctx;
    ctx.require('tax.view');
    const q = parse(z.object({ taxYear: taxYearField.optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = paymentSelect(tx, ctx.companyId);
      if (q.taxYear) base = base.where('t.tax_year', '=', q.taxYear);
      const rows = await base.orderBy('t.payment_date', 'desc').orderBy('t.created_at', 'desc').execute();
      return { data: rows.map(paymentJson), total: rows.length };
    });
  });

  app.post('/tax/payments', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tax.manage');
    const b = parse(paymentBody, req.body);
    const created = await ctx.tx(async (tx) => {
      const paidFrom = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active'])
        .where('id', '=', b.paidFromAccountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!paidFrom || !paidFrom.is_active || !['cash', 'bank'].includes(paidFrom.subtype)) {
        throw badRequest('Choose an active cash or bank account.', { paidFromAccountId: 'Not a cash or bank account' });
      }
      const number = await nextNumber(tx, ctx, 'tax_payment', financialYear(b.date));
      const row = await tx.insertInto('tax_payments').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, kind: b.kind, tax_year: b.taxYear, payment_date: b.date, amount: b.amount,
        bsr_code: b.bsrCode, challan_serial: b.challanSerial, paid_from_account_id: paidFrom.id, created_by: ctx.userId,
        cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      const acc = await systemAccounts(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date: b.date, voucherType: 'tax_payment', voucherId: row.id, number, narration: `Income tax paid (${b.kind.replace('_', ' ')}) ${b.taxYear}, BSR ${b.bsrCode} serial ${b.challanSerial}`,
        lines: [{ accountId: acc.advance_tax, amount: b.amount }, { accountId: paidFrom.id, amount: -b.amount }],
      });
      await writeAudit(tx, auditOf(ctx), 'tax_payment', row.id, 'create', null, { number, kind: b.kind, taxYear: b.taxYear, amount: b.amount });
      return paymentJson(await paymentSelect(tx, ctx.companyId).where('t.id', '=', row.id).executeTakeFirstOrThrow());
    });
    return reply.status(201).send(created);
  });

  app.post<{ Params: { id: string } }>('/tax/payments/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('tax.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const p = await tx.selectFrom('tax_payments').select(['id', 'status', 'number']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!p) throw notFound('Tax payment');
      if (p.status === 'cancelled') throw conflict('This payment is already cancelled.', 'ALREADY_CANCELLED');
      await reverseVoucher(tx, auditOf(ctx), id, todayIst(), `Cancelled ${p.number}: ${reason}`);
      await tx.updateTable('tax_payments').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'tax_payment', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return paymentJson(await paymentSelect(tx, ctx.companyId).where('t.id', '=', id).executeTakeFirstOrThrow());
    });
  });

  app.post('/tax/calc/regime', async (req) => {
    const ctx = req.ctx;
    ctx.require('tax.view');
    const b = parse(regimeBody, req.body);
    const run = (regime: Regime) => {
      const cfg = regimeConfig(regime, b.taxYear);
      const taxable = individualTaxable(cfg, b.age as Age, b);
      return individualTax(cfg, b.age as Age, taxable);
    };
    const n = run('new');
    const o = run('old');
    const better = o.calc.total < n.calc.total ? 'old' : 'new';
    return {
      taxYear: b.taxYear, new: n.calc, old: o.calc, better, saving: round2(Math.abs(n.calc.total - o.calc.total)),
      unverified: [...new Set([...n.unverified, ...o.unverified])],
    };
  });

  app.post('/tax/calc/presumptive', async (req) => {
    const ctx = req.ctx;
    ctx.require('tax.view');
    const b = parse(presumptiveBody, req.body);
    return presumptiveCheck(b.taxYear, b.kind, b.digitalReceipts, b.cashReceipts, b.declaredProfit);
  });

  app.get('/tax/advance-tax', async (req) => {
    const ctx = req.ctx;
    ctx.require('tax.view');
    const q = parse(advanceQuery, req.query);
    return ctx.tx((tx) => advanceTax(tx, ctx.companyId, q.taxYear ?? currentTaxYear(), {
      estimatedIncome: q.estimatedIncome, regime: q.regime, presumptive: q.presumptive === 'true',
    }));
  });

  app.get('/tax/itr-pack', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('tax.view');
    const q = parse(packQuery, req.query);
    const taxYear = q.taxYear ?? currentTaxYear();
    const pack = await ctx.tx((tx) => itrPack(ctx, tx, taxYear, q.form));
    if (q.format === 'json') return pack;
    const rows: unknown[][] = [
      ...pack.pnl.lines.map((l) => ['pnl', l.label, l.amount]), ['pnl', 'Net profit', pack.pnl.netProfit],
      ...pack.balanceSheet.lines.map((l) => ['balance_sheet', l.label, l.amount]),
      ...pack.depreciation.map((d) => ['it_depreciation', `${d.blockName} (${d.rate}%)`, d.depreciation]),
      ...pack.adjustments.map((a) => ['adjustment', `${a.kind === 'add' ? 'Add' : 'Less'}: ${a.label}`, a.amount]),
      ...pack.tdsCredits.map((t) => ['tds_credit', t.deductorName, t.amount]),
      ...pack.taxesPaid.map((t) => ['tax_paid', `${t.number} ${t.date}`, t.amount]),
      ['estimate', 'Income estimate', pack.incomeEstimate],
    ];
    return reply.header('content-disposition', `attachment; filename="itr-pack-${taxYear}.csv"`).type('text/csv; charset=utf-8').send(toCsv(['section', 'label', 'amount'], rows));
  });

  app.get('/tax/ca-required', async (req) => {
    const ctx = req.ctx;
    ctx.require('tax.view');
    const q = parse(z.object({ taxYear: taxYearField.optional() }), req.query);
    return ctx.tx((tx) => caRequired(tx, ctx.companyId, q.taxYear ?? currentTaxYear()));
  });
}

void daysBetween;
