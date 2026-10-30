import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { parseCsv } from '../lib/csv.ts';
import { addDays, daysBetween, isValidDate, todayIst } from '../lib/dates.ts';
import { addPeriodMonths, monthEnd } from '../lib/due-dates.ts';
import { badRequest, notFound } from '../lib/errors.ts';
import { parse } from '../lib/validate.ts';
import { writeAudit, auditOf } from './audit.ts';
import { systemAccounts } from '../accounting/accounts.ts';
import { filedRecord } from '../lib/filing-json.ts';

export const round2 = (n: number) => Math.round(n * 100) / 100;
const periodField = z.string().regex(/^\d{4}-(0[1-9]|1[0-2])$/, 'Use YYYY-MM');
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const B2CL_LIMIT = 100000;

export interface Tax { taxable: number; igst: number; cgst: number; sgst: number }
export const zeroTax = (): Tax => ({ taxable: 0, igst: 0, cgst: 0, sgst: 0 });
export const addTax = (a: Tax, b: Tax, sign = 1): Tax => ({
  taxable: round2(a.taxable + sign * b.taxable), igst: round2(a.igst + sign * b.igst),
  cgst: round2(a.cgst + sign * b.cgst), sgst: round2(a.sgst + sign * b.sgst),
});
type RateRow = Tax & { rate: number };

function addRateRow(rows: RateRow[], rate: number, t: Tax, sign = 1) {
  let r = rows.find((x) => x.rate === rate);
  if (!r) { r = { rate, ...zeroTax() }; rows.push(r); }
  Object.assign(r, addTax(r, t, sign));
}
const sortRates = (rows: RateRow[]) => rows.sort((a, b) => a.rate - b.rate);
const ddmmyyyy = (d: string) => `${d.slice(8, 10)}-${d.slice(5, 7)}-${d.slice(0, 4)}`;

// ---- Outward supplies -----------------------------------------------------------------------

export interface OutLine extends Tax { rate: number; hsn: string; description: string; unit: string; qty: number }
export interface OutDoc {
  id: string; number: string; date: string; partyName: string; gstin: string; pos: string; supply: string; value: number;
  cancelled: boolean; invoiceId: string; invoiceNumber: string; lines: OutLine[];
}

/** Posted-or-cancelled invoices and credit notes dated in the period, with their lines. */
export async function loadOutward(tx: Tx, companyId: string, from: string, to: string) {
  const invs = await tx.selectFrom('invoices as i').innerJoin('parties as p', 'p.id', 'i.party_id')
    .select(['i.id', 'i.number', 'i.invoice_date', 'p.name', 'p.gstin', 'i.place_of_supply', 'i.supply_type', 'i.total', 'i.status'])
    .where('i.company_id', '=', companyId).where('i.invoice_date', '>=', from).where('i.invoice_date', '<=', to)
    .orderBy('i.number').execute();
  const live = invs.filter((i) => i.status === 'posted');
  const invLines = live.length
    ? await tx.selectFrom('invoice_lines').select(['invoice_id', 'hsn_code', 'description', 'unit', 'qty', 'taxable_value', 'gst_rate', 'cgst', 'sgst', 'igst'])
      .where('invoice_id', 'in', live.map((i) => i.id)).execute()
    : [];
  const toLine = (l: { hsn_code: string | null; description: string; unit: string; qty: number; taxable_value: number; gst_rate: number; cgst: number; sgst: number; igst: number }): OutLine => ({
    rate: l.gst_rate, hsn: l.hsn_code ?? '', description: l.description, unit: l.unit, qty: l.qty,
    taxable: l.taxable_value, igst: l.igst, cgst: l.cgst, sgst: l.sgst,
  });
  const invoices: OutDoc[] = live.map((i) => ({
    id: i.id, number: i.number, date: i.invoice_date, partyName: i.name, gstin: i.gstin ?? '', pos: i.place_of_supply, supply: i.supply_type,
    value: i.total, cancelled: false, invoiceId: i.id, invoiceNumber: i.number,
    lines: invLines.filter((l) => l.invoice_id === i.id).map(toLine),
  }));

  const cns = await tx.selectFrom('credit_notes as n').innerJoin('invoices as i', 'i.id', 'n.invoice_id').innerJoin('parties as p', 'p.id', 'n.party_id')
    .select(['n.id', 'n.number', 'n.note_date', 'p.name', 'p.gstin', 'n.place_of_supply', 'n.supply_type', 'n.total', 'n.status', 'i.id as invoice_id',
      'i.number as invoice_number', 'i.total as invoice_total'])
    .where('n.company_id', '=', companyId).where('n.note_date', '>=', from).where('n.note_date', '<=', to)
    .orderBy('n.number').execute();
  const liveCn = cns.filter((n) => n.status === 'posted');
  const cnLines = liveCn.length
    ? await tx.selectFrom('credit_note_lines').select(['credit_note_id', 'hsn_code', 'description', 'unit', 'qty', 'taxable_value', 'gst_rate', 'cgst', 'sgst', 'igst'])
      .where('credit_note_id', 'in', liveCn.map((n) => n.id)).execute()
    : [];
  const creditNotes: (OutDoc & { invoiceValue: number })[] = liveCn.map((n) => ({
    id: n.id, number: n.number, date: n.note_date, partyName: n.name, gstin: n.gstin ?? '', pos: n.place_of_supply, supply: n.supply_type,
    value: n.total, cancelled: false, invoiceId: n.invoice_id, invoiceNumber: n.invoice_number, invoiceValue: n.invoice_total,
    lines: cnLines.filter((l) => l.credit_note_id === n.id).map(toLine),
  }));
  return {
    invoices, creditNotes,
    invoiceDocs: { all: invs.map((i) => i.number), cancelled: invs.filter((i) => i.status !== 'posted').length },
    cnDocs: { all: cns.map((n) => n.number), cancelled: cns.filter((n) => n.status !== 'posted').length },
  };
}

const ratesOf = (lines: OutLine[]): RateRow[] => {
  const rows: RateRow[] = [];
  for (const l of lines) addRateRow(rows, l.rate, l);
  return sortRates(rows);
};
const sumLines = (lines: OutLine[]): Tax => lines.reduce((s, l) => addTax(s, l), zeroTax());
const isB2cl = (d: OutDoc & { value: number }, invoiceValue: number) => !d.gstin && d.supply === 'inter' && invoiceValue > B2CL_LIMIT;

async function ledgerMovement(tx: Tx, ctx: RequestContext, from: string, to: string) {
  const acc = await systemAccounts(tx, ctx);
  const rows = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select(['jl.account_id', (eb) => eb.fn.sum<number>('jl.credit').as('c'), (eb) => eb.fn.sum<number>('jl.debit').as('d')])
    .where('je.company_id', '=', ctx.companyId).where('je.entry_date', '>=', from).where('je.entry_date', '<=', to)
    .where('jl.account_id', 'in', [acc.output_igst, acc.output_cgst, acc.output_sgst]).groupBy('jl.account_id').execute();
  const get = (id: string) => { const r = rows.find((x) => x.account_id === id); return round2(Number(r?.c ?? 0) - Number(r?.d ?? 0)); };
  return { igst: get(acc.output_igst), cgst: get(acc.output_cgst), sgst: get(acc.output_sgst) };
}

export async function buildGstr1(tx: Tx, ctx: RequestContext, period: string) {
  const from = `${period}-01`;
  const to = monthEnd(period);
  const company = await tx.selectFrom('companies').select(['gstin', 'gst_filing']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const o = await loadOutward(tx, ctx.companyId, from, to);

  const b2b: any[] = [];
  const b2cl: any[] = [];
  const b2cs: { placeOfSupply: string; supplyType: 'intra' | 'inter'; rate: number; taxable: number; igst: number; cgst: number; sgst: number }[] = [];
  const cdnr: any[] = [];
  const cdnur: any[] = [];
  const nil = { interRegistered: 0, intraRegistered: 0, interUnregistered: 0, intraUnregistered: 0 };
  const hsnMap = new Map<string, { segment: 'b2b' | 'b2c'; hsnCode: string; description: string; unit: string; qty: number; rate: number } & Tax>();
  const bumpB2cs = (pos: string, supply: string, rate: number, t: Tax, sign: number) => {
    const st = supply === 'inter' ? 'inter' : 'intra';
    let r = b2cs.find((x) => x.placeOfSupply === pos && x.supplyType === st && x.rate === rate);
    if (!r) { r = { placeOfSupply: pos, supplyType: st, rate, ...zeroTax() }; b2cs.push(r); }
    Object.assign(r, addTax(r, t, sign));
  };
  const bumpHsn = (segment: 'b2b' | 'b2c', l: OutLine, sign: number) => {
    const key = `${segment}|${l.hsn}|${l.rate}|${l.unit}`;
    let r = hsnMap.get(key);
    if (!r) { r = { segment, hsnCode: l.hsn, description: l.description, unit: l.unit, qty: 0, rate: l.rate, ...zeroTax() }; hsnMap.set(key, r); }
    r.qty = Math.round((r.qty + sign * l.qty) * 1000) / 1000;
    Object.assign(r, addTax(r, l, sign));
  };
  const bumpNil = (d: { gstin: string; supply: string }, taxable: number, sign: number) => {
    const key = `${d.supply === 'inter' ? 'inter' : 'intra'}${d.gstin ? 'Registered' : 'Unregistered'}` as keyof typeof nil;
    nil[key] = round2(nil[key] + sign * taxable);
  };

  const class_ = new Map<string, 'b2b' | 'b2cl' | 'b2cs'>();
  for (const inv of o.invoices) {
    const kind = inv.gstin ? 'b2b' : isB2cl(inv, inv.value) ? 'b2cl' : 'b2cs';
    class_.set(inv.id, kind);
    if (kind === 'b2b') b2b.push({ invoiceId: inv.id, number: inv.number, date: inv.date, partyName: inv.partyName, gstin: inv.gstin, placeOfSupply: inv.pos, invoiceValue: inv.value, rates: ratesOf(inv.lines) });
    else if (kind === 'b2cl') b2cl.push({ invoiceId: inv.id, number: inv.number, date: inv.date, placeOfSupply: inv.pos, invoiceValue: inv.value, rates: ratesOf(inv.lines) });
    for (const l of inv.lines) {
      if (kind === 'b2cs') bumpB2cs(inv.pos, inv.supply, l.rate, l, 1);
      if (l.rate === 0) bumpNil(inv, l.taxable, 1);
      bumpHsn(inv.gstin ? 'b2b' : 'b2c', l, 1);
    }
  }
  for (const cn of o.creditNotes) {
    // A note follows the class its invoice had (the invoice may be dated in an earlier period).
    const kind = cn.gstin ? 'b2b' : isB2cl(cn, cn.invoiceValue) ? 'b2cl' : 'b2cs';
    if (kind === 'b2b') cdnr.push({ creditNoteId: cn.id, number: cn.number, date: cn.date, invoiceNumber: cn.invoiceNumber, partyName: cn.partyName, gstin: cn.gstin, placeOfSupply: cn.pos, noteValue: cn.value, rates: ratesOf(cn.lines) });
    else if (kind === 'b2cl') cdnur.push({ creditNoteId: cn.id, number: cn.number, date: cn.date, invoiceNumber: cn.invoiceNumber, placeOfSupply: cn.pos, noteValue: cn.value, rates: ratesOf(cn.lines) });
    for (const l of cn.lines) {
      if (kind === 'b2cs') bumpB2cs(cn.pos, cn.supply, l.rate, l, -1);
      if (l.rate === 0) bumpNil(cn, l.taxable, -1);
      bumpHsn(cn.gstin ? 'b2b' : 'b2c', l, -1);
    }
  }

  const invTotal = o.invoices.reduce((s, i) => addTax(s, sumLines(i.lines)), zeroTax());
  const cnTotal = o.creditNotes.reduce((s, i) => addTax(s, sumLines(i.lines)), zeroTax());
  const totals = addTax(invTotal, cnTotal, -1);
  const ledgerMv = await ledgerMovement(tx, ctx, from, to);
  const variance = { igst: round2(totals.igst - ledgerMv.igst), cgst: round2(totals.cgst - ledgerMv.cgst), sgst: round2(totals.sgst - ledgerMv.sgst) };

  const docRange = (kind: 'invoice' | 'credit_note', d: { all: string[]; cancelled: number }) =>
    d.all.length ? [{ kind, from: d.all[0]!, to: d.all[d.all.length - 1]!, total: d.all.length, cancelled: d.cancelled }] : [];
  const warnings: string[] = [];
  if (!company.gstin) warnings.push('Company GSTIN is missing. Add it in company settings.');
  const noHsn = o.invoices.reduce((n, i) => n + i.lines.filter((l) => !l.hsn).length, 0);
  if (noHsn) warnings.push(`${noHsn} invoice line${noHsn > 1 ? 's have' : ' has'} no HSN code.`);
  if (variance.igst || variance.cgst || variance.sgst) warnings.push('Return totals differ from the output tax ledger for this period. Check for cancelled or back-dated documents.');

  return {
    period, gstin: company.gstin, filing: company.gst_filing as 'monthly' | 'quarterly',
    b2b, b2cl, b2cs: b2cs.filter((r) => r.taxable || r.igst || r.cgst || r.sgst).sort((a, b) => a.placeOfSupply.localeCompare(b.placeOfSupply) || a.rate - b.rate),
    cdnr, cdnur, nil,
    hsn: [...hsnMap.values()].sort((a, b) => a.segment.localeCompare(b.segment) || a.hsnCode.localeCompare(b.hsnCode) || a.rate - b.rate),
    docs: [...docRange('invoice', o.invoiceDocs), ...docRange('credit_note', o.cnDocs)],
    totals, ledger: ledgerMv, variance, warnings,
  };
}
type Gstr1 = Awaited<ReturnType<typeof buildGstr1>>;

/** Unofficial GSTN offline-tool shaped JSON. */
function gstnJson(g: Gstr1) {
  const itms = (rates: RateRow[]) => rates.map((r, i) => ({ num: i + 1, itm_det: { rt: r.rate, txval: r.taxable, iamt: r.igst, camt: r.cgst, samt: r.sgst, csamt: 0 } }));
  const byCtin = <T extends { gstin: string }>(rows: T[]) => {
    const m = new Map<string, T[]>();
    for (const r of rows) m.set(r.gstin, [...(m.get(r.gstin) ?? []), r]);
    return [...m.entries()];
  };
  const hsnRows = g.hsn.map((h, i) => ({ num: i + 1, hsn_sc: h.hsnCode, desc: h.description, uqc: h.unit.toUpperCase(), qty: h.qty, rt: h.rate,
    val: round2(h.taxable + h.igst + h.cgst + h.sgst), txval: h.taxable, iamt: h.igst, camt: h.cgst, samt: h.sgst, csamt: 0 }));
  return {
    _note: 'Unofficial; check with the GST offline tool before upload',
    gstin: g.gstin, fp: `${g.period.slice(5, 7)}${g.period.slice(0, 4)}`,
    b2b: byCtin(g.b2b).map(([ctin, invs]) => ({ ctin, inv: invs.map((i) => ({ inum: i.number, idt: ddmmyyyy(i.date), val: i.invoiceValue, pos: i.placeOfSupply, rchrg: 'N', inv_typ: 'R', itms: itms(i.rates) })) })),
    b2cl: [...new Set(g.b2cl.map((i) => i.placeOfSupply))].map((pos) => ({ pos, inv: g.b2cl.filter((i) => i.placeOfSupply === pos).map((i) => ({ inum: i.number, idt: ddmmyyyy(i.date), val: i.invoiceValue, itms: itms(i.rates) })) })),
    b2cs: g.b2cs.map((r) => ({ sply_ty: r.supplyType === 'inter' ? 'INTER' : 'INTRA', pos: r.placeOfSupply, typ: 'OE', rt: r.rate, txval: r.taxable, iamt: r.igst, camt: r.cgst, samt: r.sgst, csamt: 0 })),
    cdnr: byCtin(g.cdnr).map(([ctin, notes]) => ({ ctin, nt: notes.map((n) => ({ ntty: 'C', nt_num: n.number, nt_dt: ddmmyyyy(n.date), val: n.noteValue, pos: n.placeOfSupply, rchrg: 'N', inv_typ: 'R', itms: itms(n.rates) })) })),
    cdnur: g.cdnur.map((n) => ({ typ: 'B2CL', ntty: 'C', nt_num: n.number, nt_dt: ddmmyyyy(n.date), val: n.noteValue, pos: n.placeOfSupply, itms: itms(n.rates) })),
    hsn: { data: hsnRows },
    doc_issue: { doc_det: g.docs.map((d, i) => ({ doc_num: d.kind === 'invoice' ? 1 : 5 + i, docs: [{ num: 1, from: d.from, to: d.to, totnum: d.total, cancel: d.cancelled, net_issue: d.total - d.cancelled }] })) },
  };
}

// ---- GSTR-3B -----------------------------------------------------------------------------------

export async function buildGstr3b(tx: Tx, ctx: RequestContext, period: string) {
  const from = `${period}-01`;
  const to = monthEnd(period);
  const company = await tx.selectFrom('companies').select(['gstin']).where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
  const o = await loadOutward(tx, ctx.companyId, from, to);
  let outward = zeroTax();
  let zeroNil = 0;
  const unreg = new Map<string, { taxable: number; igst: number }>();
  const apply = (d: OutDoc, sign: number) => {
    for (const l of d.lines) {
      if (l.rate > 0) outward = addTax(outward, l, sign); else zeroNil = round2(zeroNil + sign * l.taxable);
      if (!d.gstin && d.supply === 'inter' && l.rate > 0) {
        const r = unreg.get(d.pos) ?? { taxable: 0, igst: 0 };
        unreg.set(d.pos, { taxable: round2(r.taxable + sign * l.taxable), igst: round2(r.igst + sign * l.igst) });
      }
    }
  };
  o.invoices.forEach((d) => apply(d, 1));
  o.creditNotes.forEach((d) => apply(d, -1));

  const purchases = await tx.selectFrom('purchases').select(['subtotal', 'cgst', 'sgst', 'igst', 'reverse_charge'])
    .where('company_id', '=', ctx.companyId).where('status', '=', 'posted').where('bill_date', '>=', from).where('bill_date', '<=', to).execute();
  const expenses = await tx.selectFrom('expenses').select(['amount', 'cgst', 'sgst', 'igst', 'reverse_charge'])
    .where('company_id', '=', ctx.companyId).where('status', '=', 'posted').where('expense_date', '>=', from).where('expense_date', '<=', to).execute();
  let rcm = zeroTax();
  let others = zeroTax();
  const inward: (Tax & { rcm: boolean })[] = [
    ...purchases.map((p) => ({ taxable: p.subtotal, igst: p.igst, cgst: p.cgst, sgst: p.sgst, rcm: p.reverse_charge })),
    ...expenses.map((e) => ({ taxable: e.amount, igst: e.igst, cgst: e.cgst, sgst: e.sgst, rcm: e.reverse_charge })),
  ];
  for (const r of inward) {
    if (r.rcm) rcm = addTax(rcm, r);
    else if (r.igst + r.cgst + r.sgst > 0) others = addTax(others, r);
  }
  const [rev, others2b, inwardExempt, filing] = await Promise.all([
    itcReversalRows(tx, ctx.companyId, period),
    itcFrom2b(tx, ctx.companyId, period),
    inwardExemptOf(tx, ctx.companyId, from, to),
    filedRecord(tx, ctx.companyId, 'gstr3b', period),
  ]);
  const reversedRule37 = rev.totals.reversal;
  const reclaimed = rev.totals.reclaim;
  const net = addTax(addTax(addTax(rcm, others), reversedRule37, -1), reclaimed);
  const head = (h: 'igst' | 'cgst' | 'sgst') => Math.max(0, round2(outward[h] + rcm[h] - net[h]));
  const payable = { igst: head('igst'), cgst: head('cgst'), sgst: head('sgst') };
  const warnings: string[] = [];
  if (!company.gstin) warnings.push('Company GSTIN is missing. Add it in company settings.');
  warnings.push('Export invoices are not supported yet, so table 3.1(b) is 0.');
  if (rev.rows.length) warnings.push('ITC reversals or reclaims under Rule 37 apply this period. Include them in 4B(2) and 4D(1).');
  return {
    period, outward, zeroNil: { taxable: zeroNil }, inwardRcm: rcm,
    zeroRated: zeroTax(), nonGst: { taxable: 0 }, inwardExempt,
    interStateUnregistered: [...unreg.entries()].filter(([, v]) => v.taxable || v.igst).map(([placeOfSupply, v]) => ({ placeOfSupply, ...v })),
    itc: { rcm, others, reversed: { rule42_43: zeroTax(), rule37: reversedRule37 }, reclaimed, net, others2b },
    payable, payableNoCross: payable,
    rcmCash: { igst: rcm.igst, cgst: rcm.cgst, sgst: rcm.sgst },
    filing, warnings,
  };
}

/** Rule 37: purchases unpaid 180 days after the bill date reverse ITC; a later payment reclaims it (API v1.6 §2). */
export async function itcReversalRows(tx: Tx, companyId: string, period: string) {
  const from = `${period}-01`;
  const to = monthEnd(period);
  const dueIds = await tx.selectFrom('purchases').select('id').where('company_id', '=', companyId)
    .where('bill_date', '>=', addDays(from, -180)).where('bill_date', '<=', addDays(to, -180)).execute();
  const paidIds = await tx.selectFrom('payment_allocations as a').innerJoin('payments as p', 'p.id', 'a.payment_id')
    .select('a.doc_id').where('p.company_id', '=', companyId).where('p.status', '=', 'posted').where('a.doc_type', '=', 'purchase')
    .where('p.payment_date', '>=', from).where('p.payment_date', '<=', to).execute();
  const ids = [...new Set([...dueIds.map((r) => r.id), ...paidIds.map((r) => r.doc_id)])];
  const empty = { period, rows: [] as ItcRevRow[], totals: { reversal: zeroTax(), reclaim: zeroTax() } };
  if (!ids.length) return empty;
  const ps = await tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id')
    .select(['v.id', 'v.number', 'p.name', 'p.gstin', 'v.bill_date', 'v.subtotal', 'v.total', 'v.net_payable', 'v.cgst', 'v.sgst', 'v.igst'])
    .where('v.company_id', '=', companyId).where('v.id', 'in', ids).where('v.status', '=', 'posted').where('v.reverse_charge', '=', false)
    .orderBy('v.bill_date').orderBy('v.number').execute();
  const allocs = ps.length
    ? await tx.selectFrom('payment_allocations as a').innerJoin('payments as p', 'p.id', 'a.payment_id')
      .select(['a.doc_id', 'a.payment_id', 'a.amount', 'p.payment_date']).where('p.status', '=', 'posted').where('a.doc_type', '=', 'purchase')
      .where('a.doc_id', 'in', ps.map((x) => x.id)).orderBy('p.payment_date').orderBy('a.payment_id').execute()
    : [];
  const rows: ItcRevRow[] = [];
  const totals = { reversal: zeroTax(), reclaim: zeroTax() };
  const share = (v: number, part: number, total: number) => (total > 0 ? round2((v * part) / total) : 0);
  for (const p of ps) {
    if (p.cgst + p.sgst + p.igst <= 0 || p.total <= 0) continue;
    const day180 = addDays(p.bill_date, 180);
    const mine = allocs.filter((a) => a.doc_id === p.id);
    const paid180 = mine.filter((a) => a.payment_date <= day180).reduce((s, a) => s + a.amount, 0);
    const unpaid = Math.max(0, round2(p.net_payable - paid180));
    const base = { purchaseId: p.id, number: p.number, partyName: p.name, supplierGstin: p.gstin ?? '', billDate: p.bill_date, day180 };
    const rem = { igst: share(p.igst, unpaid, p.total), cgst: share(p.cgst, unpaid, p.total), sgst: share(p.sgst, unpaid, p.total) };
    if (unpaid > 0 && day180 >= from && day180 <= to) {
      const t = { taxable: share(p.subtotal, unpaid, p.total), ...rem };
      rows.push({ ...base, kind: 'reversal', paymentId: null, base: t.taxable, igst: t.igst, cgst: t.cgst, sgst: t.sgst });
      totals.reversal = addTax(totals.reversal, t);
    }
    if (unpaid <= 0) continue;
    for (const a of mine.filter((x) => x.payment_date > day180)) {
      const t = {
        taxable: share(p.subtotal, a.amount, p.total),
        igst: Math.min(share(p.igst, a.amount, p.total), rem.igst), cgst: Math.min(share(p.cgst, a.amount, p.total), rem.cgst),
        sgst: Math.min(share(p.sgst, a.amount, p.total), rem.sgst),
      };
      rem.igst = round2(rem.igst - t.igst); rem.cgst = round2(rem.cgst - t.cgst); rem.sgst = round2(rem.sgst - t.sgst);
      if (a.payment_date < from || a.payment_date > to || t.igst + t.cgst + t.sgst <= 0) continue;
      rows.push({ ...base, kind: 'reclaim', paymentId: a.payment_id, base: t.taxable, igst: t.igst, cgst: t.cgst, sgst: t.sgst });
      totals.reclaim = addTax(totals.reclaim, t);
    }
  }
  return { period, rows, totals };
}
export interface ItcRevRow {
  purchaseId: string; number: string; partyName: string; supplierGstin: string; billDate: string; day180: string;
  kind: 'reversal' | 'reclaim'; paymentId: string | null; base: number; igst: number; cgst: number; sgst: number;
}

/** ITC on 2B lines that are matched and not rejected or pending (null when no 2B was imported). */
export async function itcFrom2b(tx: Tx, companyId: string, period: string): Promise<Tax | null> {
  const imp = await tx.selectFrom('gst_2b_imports').select('id').where('company_id', '=', companyId).where('period', '=', period).executeTakeFirst();
  if (!imp) return null;
  const lines = await tx.selectFrom('gst_2b_lines').select(['taxable', 'igst', 'cgst', 'sgst', 'doc_type'])
    .where('import_id', '=', imp.id).where('match_status', '=', 'matched').where('itc_available', '=', true)
    .where('ims_action', 'not in', ['reject', 'pending']).execute();
  return lines.reduce((s, l) => addTax(s, l, l.doc_type === 'credit_note' ? -1 : 1), zeroTax());
}

/** Table 5: taxable value of purchase and expense lines at 0%, split by inter and intra state. */
async function inwardExemptOf(tx: Tx, companyId: string, from: string, to: string) {
  const c = await tx.selectFrom('companies').select('state_code').where('id', '=', companyId).executeTakeFirstOrThrow();
  const lines = await tx.selectFrom('purchase_lines as l').innerJoin('purchases as v', 'v.id', 'l.purchase_id')
    .select(['l.taxable_value', 'v.supply_type']).where('v.company_id', '=', companyId).where('v.status', '=', 'posted')
    .where('l.gst_rate', '=', 0).where('v.bill_date', '>=', from).where('v.bill_date', '<=', to).execute();
  const exp = await tx.selectFrom('expenses as e').leftJoin('parties as p', 'p.id', 'e.party_id')
    .select(['e.amount', 'p.state_code']).where('e.company_id', '=', companyId).where('e.status', '=', 'posted')
    .where('e.gst_rate', '=', 0).where('e.expense_date', '>=', from).where('e.expense_date', '<=', to).execute();
  let inter = 0; let intra = 0;
  for (const l of lines) if (l.supply_type === 'inter') inter += l.taxable_value; else intra += l.taxable_value;
  for (const e of exp) if (e.state_code && e.state_code !== c.state_code) inter += e.amount; else intra += e.amount;
  return { inter: round2(inter), intra: round2(intra) };
}

type Gstr3b = Awaited<ReturnType<typeof buildGstr3b>>;

/** Unofficial JSON shaped like the portal's 3B upload. */
function gstr3bGstn(g: Gstr3b, gstin: string | null) {
  const amt = (t: Tax) => ({ iamt: t.igst, camt: t.cgst, samt: t.sgst, csamt: 0 });
  const det = (t: Tax) => ({ txval: t.taxable, ...amt(t) });
  const zero = { iamt: 0, camt: 0, samt: 0, csamt: 0 };
  const rev = g.itc.reversed.rule37;
  return {
    _note: 'Unofficial; tables 3.1 and 3.2 are auto-filled on the portal',
    gstin, ret_period: `${g.period.slice(5, 7)}${g.period.slice(0, 4)}`,
    sup_details: {
      osup_det: det(g.outward), osup_zero: { txval: 0, ...zero }, osup_nil_exmp: { txval: g.zeroNil.taxable },
      isup_rev: det(g.inwardRcm), osup_nongst: { txval: g.nonGst.taxable },
    },
    inter_sup: { unreg_details: g.interStateUnregistered.map((r) => ({ pos: r.placeOfSupply, txval: r.taxable, iamt: r.igst })), comp_details: [], uin_details: [] },
    itc_elg: {
      itc_avl: [{ ty: 'ISRC', ...amt(g.itc.rcm) }, { ty: 'OTH', ...amt(g.itc.others) }],
      itc_rev: [{ ty: 'RUL', ...amt(rev) }, { ty: 'OTH', ...zero }],
      itc_net: amt(g.itc.net),
      itc_inelg: [{ ty: 'RUL', ...amt(g.itc.reclaimed) }, { ty: 'OTH', ...zero }],
    },
    inward_sup: { isup_details: [{ ty: 'GST', inter: g.inwardExempt.inter, intra: g.inwardExempt.intra }, { ty: 'NONGST', inter: 0, intra: 0 }] },
    intr_ltfee: { intr_details: zero },
  };
}

// ---- GSTR-2B import and reconciliation ------------------------------------------------------

export const normInvoiceNo = (s: string) => s.toUpperCase().replace(/[\s/\-]/g, '').replace(/^0+/, '');

interface ParsedLine {
  gstin: string; name: string | null; docType: 'invoice' | 'credit_note' | 'debit_note'; docNo: string; docDate: string;
  taxable: number; igst: number; cgst: number; sgst: number; cess: number; itcAvailable: boolean;
}

const num = (v: unknown) => { const n = Number(String(v ?? '').replace(/,/g, '')); return Number.isFinite(n) ? n : 0; };
function isoFromDdmmyyyy(s: string): string {
  const m = /^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$/.exec(s.trim());
  const iso = m ? `${m[3]}-${m[2]!.padStart(2, '0')}-${m[1]!.padStart(2, '0')}` : s.trim();
  if (!isValidDate(iso)) throw badRequest(`Invalid date "${s}". Use dd-mm-yyyy.`, { date: s });
  return iso;
}
function sumItems(items: any[] | undefined) {
  const t = { taxable: 0, igst: 0, cgst: 0, sgst: 0, cess: 0 };
  for (const it of items ?? []) {
    t.taxable += num(it.txval); t.igst += num(it.igst); t.cgst += num(it.cgst); t.sgst += num(it.sgst); t.cess += num(it.cess);
  }
  return { taxable: round2(t.taxable), igst: round2(t.igst), cgst: round2(t.cgst), sgst: round2(t.sgst), cess: round2(t.cess) };
}

function parse2bJson(json: any): ParsedLine[] {
  const doc = json?.data?.data?.docdata ?? json?.data?.docdata ?? json?.docdata ?? json?.data ?? json;
  const out: ParsedLine[] = [];
  for (const sup of Array.isArray(doc?.b2b) ? doc.b2b : []) {
    for (const inv of sup.inv ?? []) {
      out.push({ gstin: String(sup.ctin ?? '').toUpperCase(), name: sup.trdnm ?? null, docType: 'invoice', docNo: String(inv.inum ?? ''),
        docDate: isoFromDdmmyyyy(String(inv.dt ?? '')), ...sumItems(inv.items ?? inv.itms), itcAvailable: String(inv.itcavl ?? 'Y').toUpperCase() !== 'N' });
    }
  }
  for (const sup of Array.isArray(doc?.cdnr) ? doc.cdnr : []) {
    for (const nt of sup.nt ?? []) {
      out.push({ gstin: String(sup.ctin ?? '').toUpperCase(), name: sup.trdnm ?? null, docType: String(nt.typ ?? nt.ntty ?? 'C').toUpperCase().startsWith('D') ? 'debit_note' : 'credit_note',
        docNo: String(nt.ntnum ?? nt.nt_num ?? ''), docDate: isoFromDdmmyyyy(String(nt.dt ?? nt.nt_dt ?? '')), ...sumItems(nt.items ?? nt.itms),
        itcAvailable: String(nt.itcavl ?? 'Y').toUpperCase() !== 'N' });
    }
  }
  return out;
}

function parse2bCsv(text: string): ParsedLine[] {
  const rows = parseCsv(text);
  if (rows.length < 2) throw badRequest('The CSV has no rows.', { csv: 'Empty' });
  const key = (s: string) => s.toLowerCase().replace(/[^a-z0-9]/g, '');
  const head = rows[0]!.map(key);
  const col = (n: string) => head.indexOf(key(n));
  const missing = ['gstin', 'docNo', 'docDate', 'taxable'].filter((n) => col(n) < 0);
  if (missing.length) throw badRequest(`CSV is missing columns: ${missing.join(', ')}.`, { csv: `Missing ${missing.join(', ')}` });
  const get = (r: string[], n: string) => (col(n) >= 0 ? (r[col(n)] ?? '').trim() : '');
  return rows.slice(1).map((r) => {
    const t = get(r, 'docType').toLowerCase().replace(/[^a-z]/g, '');
    const docType = t.startsWith('credit') || t === 'cn' || t === 'cdn' ? 'credit_note' : t.startsWith('debit') || t === 'dn' ? 'debit_note' : 'invoice';
    return { gstin: get(r, 'gstin').toUpperCase(), name: get(r, 'name') || null, docType, docNo: get(r, 'docNo'), docDate: isoFromDdmmyyyy(get(r, 'docDate')),
      taxable: num(get(r, 'taxable')), igst: num(get(r, 'igst')), cgst: num(get(r, 'cgst')), sgst: num(get(r, 'sgst')), cess: num(get(r, 'cess')), itcAvailable: true } as ParsedLine;
  });
}

interface BookPurchase { id: string; number: string; gstin: string; norm: string; taxable: number; igst: number; cgst: number; sgst: number }
type MatchStatus = 'matched' | 'mismatch' | 'missing_in_books';

const taxOf = (t: Tax): Tax => ({ taxable: t.taxable, igst: t.igst, cgst: t.cgst, sgst: t.sgst });
function evaluate(line: Tax, book: Tax | null): MatchStatus {
  if (!book) return 'missing_in_books';
  const ok = Math.abs(line.igst - book.igst) <= 1 && Math.abs(line.cgst - book.cgst) <= 1 && Math.abs(line.sgst - book.sgst) <= 1 && Math.abs(line.taxable - book.taxable) <= 10;
  return ok ? 'matched' : 'mismatch';
}

async function bookPurchases(tx: Tx, companyId: string, period: string): Promise<BookPurchase[]> {
  const from = `${addPeriodMonths(period, -3)}-01`;
  const rows = await tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id')
    .select(['v.id', 'v.number', 'p.gstin', 'v.supplier_invoice_no', 'v.subtotal', 'v.igst', 'v.cgst', 'v.sgst'])
    .where('v.company_id', '=', companyId).where('v.status', '=', 'posted').where('v.bill_date', '>=', from).where('v.bill_date', '<=', monthEnd(period))
    .where('p.gstin', 'is not', null).execute();
  return rows.filter((r) => r.supplier_invoice_no).map((r) => ({ id: r.id, number: r.number, gstin: (r.gstin ?? '').toUpperCase(), norm: normInvoiceNo(r.supplier_invoice_no!),
    taxable: r.subtotal, igst: r.igst, cgst: r.cgst, sgst: r.sgst }));
}

function reconRow(l: any, purchase: { number: string; tax: Tax } | null) {
  const book = purchase ? purchase.tax : null;
  const lt = { taxable: l.taxable, igst: l.igst, cgst: l.cgst, sgst: l.sgst };
  return {
    id: l.id as string | null, status: l.match_status as string, supplierGstin: l.supplier_gstin, supplierName: l.supplier_name, docType: l.doc_type,
    docNo: l.doc_no, docDate: l.doc_date, taxable: l.taxable, igst: l.igst, cgst: l.cgst, sgst: l.sgst,
    purchaseId: l.purchase_id as string | null, purchaseNumber: purchase?.number ?? null, book,
    diff: book ? addTax(lt, book, -1) : null, imsAction: l.ims_action, note: l.note,
  };
}

async function loadRecon(tx: Tx, ctx: RequestContext, period: string, lineIds?: string[]) {
  const imp = await tx.selectFrom('gst_2b_imports').select(['id', 'created_at']).where('company_id', '=', ctx.companyId).where('period', '=', period).executeTakeFirst();
  if (!imp) return { importedAt: null as Date | null, rows: [] as ReturnType<typeof reconRow>[] };
  let q = tx.selectFrom('gst_2b_lines').selectAll().where('import_id', '=', imp.id);
  if (lineIds) q = q.where('id', 'in', lineIds);
  const lines = await q.orderBy('supplier_gstin').orderBy('doc_no').execute();
  const pids = lines.map((l) => l.purchase_id).filter((x): x is string => !!x);
  const ps = pids.length
    ? await tx.selectFrom('purchases').select(['id', 'number', 'subtotal', 'igst', 'cgst', 'sgst']).where('id', 'in', pids).execute()
    : [];
  const rows = lines.map((l) => {
    const p = ps.find((x) => x.id === l.purchase_id);
    return reconRow(l, p ? { number: p.number, tax: { taxable: p.subtotal, igst: p.igst, cgst: p.cgst, sgst: p.sgst } } : null);
  });
  return { importedAt: imp.created_at, rows, importId: imp.id };
}

async function missingIn2b(tx: Tx, ctx: RequestContext, period: string, importId: string) {
  const linked = (await tx.selectFrom('gst_2b_lines').select('purchase_id').where('import_id', '=', importId).where('purchase_id', 'is not', null).execute()).map((r) => r.purchase_id!);
  let q = tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id')
    .select(['v.id', 'v.number', 'p.gstin', 'p.name', 'v.supplier_invoice_no', 'v.supplier_invoice_date', 'v.bill_date', 'v.subtotal', 'v.igst', 'v.cgst', 'v.sgst'])
    .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted').where('v.reverse_charge', '=', false)
    .where('v.bill_date', '>=', `${period}-01`).where('v.bill_date', '<=', monthEnd(period)).where('p.gstin', 'is not', null);
  if (linked.length) q = q.where('v.id', 'not in', linked);
  return (await q.execute()).map((p) => {
    const book = { taxable: p.subtotal, igst: p.igst, cgst: p.cgst, sgst: p.sgst };
    return {
      id: null, status: 'missing_in_2b', supplierGstin: p.gstin ?? '', supplierName: p.name, docType: 'invoice', docNo: p.supplier_invoice_no ?? p.number,
      docDate: p.supplier_invoice_date ?? p.bill_date, taxable: 0, igst: 0, cgst: 0, sgst: 0, purchaseId: p.id, purchaseNumber: p.number,
      book, diff: null, imsAction: 'none', note: null,
    };
  });
}

// ---- ITC ageing (rule 37: 180 days) ---------------------------------------------------------

export async function itcAgeing(tx: Tx, companyId: string, asOf: string) {
  const rows = await tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id')
    .select(['v.id', 'v.number', 'p.name', 'v.bill_date', 'v.total', 'v.net_payable', 'v.amount_paid', 'v.cgst', 'v.sgst', 'v.igst'])
    .where('v.company_id', '=', companyId).where('v.status', '=', 'posted').where('v.reverse_charge', '=', false).where('v.bill_date', '<=', asOf)
    .whereRef('v.amount_paid', '<', 'v.net_payable').execute();
  const out = rows.filter((r) => r.cgst + r.sgst + r.igst > 0).map((r) => {
    const unpaid = round2(r.net_payable - r.amount_paid);
    const itc = round2(r.cgst + r.sgst + r.igst);
    const day180 = addDays(r.bill_date, 180);
    const daysLeft = daysBetween(asOf, day180);
    return {
      purchaseId: r.id, number: r.number, partyName: r.name, billDate: r.bill_date, day180, daysLeft, total: r.total, unpaid, itc,
      reversal: r.total > 0 ? round2((itc * unpaid) / r.total) : 0, status: (daysLeft <= 0 ? 'due' : daysLeft <= 60 ? 'warn' : 'ok') as 'ok' | 'warn' | 'due',
    };
  }).sort((a, b) => a.daysLeft - b.daysLeft);
  return { asOf, rows: out, totals: { unpaid: round2(out.reduce((s, r) => s + r.unpaid, 0)), itc: round2(out.reduce((s, r) => s + r.itc, 0)), reversal: round2(out.reduce((s, r) => s + r.reversal, 0)) } };
}

// ---- Routes -----------------------------------------------------------------------------------

export async function gstReturnRoutes(app: FastifyInstance) {
  app.get('/gst/gstr1', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ period: periodField, format: z.enum(['json', 'gstn']).default('json') }), req.query);
    const g = await ctx.tx((tx) => buildGstr1(tx, ctx, q.period));
    return q.format === 'gstn' ? gstnJson(g) : g;
  });

  app.get('/gst/gstr3b', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ period: periodField, format: z.enum(['json', 'gstn']).default('json') }), req.query);
    const g = await ctx.tx((tx) => buildGstr3b(tx, ctx, q.period));
    return q.format === 'gstn' ? gstr3bGstn(g, await ctx.tx((tx) => tx.selectFrom('companies').select('gstin').where('id', '=', ctx.companyId).executeTakeFirstOrThrow().then((c) => c.gstin))) : g;
  });

  app.post('/gst/2b-imports', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const body = parse(z.object({
      period: periodField, fileName: z.string().trim().max(200).optional(), data: z.record(z.string(), z.unknown()).optional(), csv: z.string().max(5_000_000).optional(),
    }), req.body);
    if ((body.data ? 1 : 0) + (body.csv ? 1 : 0) !== 1) throw badRequest('Send exactly one of data or csv.', { data: 'Send data or csv, not both' });
    const lines = body.data ? parse2bJson(body.data) : parse2bCsv(body.csv!);
    const bad = lines.find((l) => !l.gstin || !l.docNo);
    if (bad) throw badRequest('Every row needs a supplier GSTIN and document number.', { lines: 'Missing GSTIN or number' });
    const result = await ctx.tx(async (tx) => {
      await tx.deleteFrom('gst_2b_imports').where('company_id', '=', ctx.companyId).where('period', '=', body.period).execute();
      const imp = await tx.insertInto('gst_2b_imports').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, period: body.period, file_name: body.fileName ?? null, line_count: lines.length, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const books = await bookPurchases(tx, ctx.companyId, body.period);
      const used = new Set<string>();
      const counts = { matched: 0, mismatch: 0, missingInBooks: 0 };
      const values = lines.map((l) => {
        const cand = l.docType === 'invoice'
          ? books.find((b) => !used.has(b.id) && b.gstin === l.gstin && b.norm === normInvoiceNo(l.docNo))
          : undefined;
        if (cand) used.add(cand.id);
        const status = evaluate(l, cand ? taxOf(cand) : null);
        if (status === 'matched') counts.matched++; else if (status === 'mismatch') counts.mismatch++; else counts.missingInBooks++;
        return {
          tenant_id: ctx.tenantId, company_id: ctx.companyId, import_id: imp.id, supplier_gstin: l.gstin, supplier_name: l.name, doc_type: l.docType,
          doc_no: l.docNo, doc_date: l.docDate, taxable: l.taxable, igst: l.igst, cgst: l.cgst, sgst: l.sgst, cess: l.cess, itc_available: l.itcAvailable,
          purchase_id: cand?.id ?? null, match_status: status, note: null,
        };
      });
      for (let i = 0; i < values.length; i += 500) await tx.insertInto('gst_2b_lines').values(values.slice(i, i + 500)).execute();
      await writeAudit(tx, auditOf(ctx), 'gst_2b_import', imp.id, 'create', null, { period: body.period, lines: lines.length, ...counts });
      return { importId: imp.id, period: body.period, lines: lines.length, ...counts };
    });
    return reply.status(201).send(result);
  });

  app.get('/gst/2b-recon', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ period: periodField, status: z.enum(['matched', 'mismatch', 'missing_in_books', 'missing_in_2b']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      const r = await loadRecon(tx, ctx, q.period);
      const all = [...r.rows, ...(r.importId ? await missingIn2b(tx, ctx, q.period, r.importId) : [])];
      const sum = (rows: typeof all, pick: 'self' | 'book') => rows.reduce((s, x) => addTax(s, pick === 'book' && x.book ? x.book : x), zeroTax());
      const count = (s: string) => all.filter((x) => x.status === s).length;
      return {
        period: q.period, importedAt: r.importedAt,
        summary: {
          matched: count('matched'), mismatch: count('mismatch'), missingInBooks: count('missing_in_books'), missingIn2b: count('missing_in_2b'),
          itcMatched: sum(all.filter((x) => x.status === 'matched'), 'self'),
          itcAtRisk: sum(all.filter((x) => x.status === 'mismatch' || x.status === 'missing_in_2b'), 'book'),
        },
        rows: q.status ? all.filter((x) => x.status === q.status) : all,
      };
    });
  });

  app.patch<{ Params: { id: string } }>('/gst/2b-lines/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.manage');
    const id = parse(z.uuid(), req.params.id);
    const body = parse(z.object({
      imsAction: z.enum(['none', 'accept', 'reject', 'pending']).optional(), purchaseId: z.uuid().nullable().optional(), note: z.string().trim().max(300).nullable().optional(),
    }), req.body);
    return ctx.tx(async (tx) => {
      const line = await tx.selectFrom('gst_2b_lines').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!line) throw notFound('2B line');
      const set: Record<string, unknown> = {};
      if (body.imsAction !== undefined) set.ims_action = body.imsAction;
      if (body.note !== undefined) set.note = body.note;
      if (body.purchaseId !== undefined) {
        let status: MatchStatus = 'missing_in_books';
        if (body.purchaseId) {
          const p = await tx.selectFrom('purchases').select(['id', 'subtotal', 'igst', 'cgst', 'sgst']).where('id', '=', body.purchaseId).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
          if (!p) throw badRequest('Purchase not found.', { purchaseId: 'Not found' });
          const taken = await tx.selectFrom('gst_2b_lines').select('id').where('import_id', '=', line.import_id).where('purchase_id', '=', p.id).where('id', '!=', id).executeTakeFirst();
          if (taken) throw badRequest('That purchase is already linked to another 2B line.', { purchaseId: 'Already linked' });
          status = evaluate(line, { taxable: p.subtotal, igst: p.igst, cgst: p.cgst, sgst: p.sgst });
        }
        set.purchase_id = body.purchaseId;
        set.match_status = status;
      }
      if (Object.keys(set).length) await tx.updateTable('gst_2b_lines').set(set).where('id', '=', id).execute();
      const imp = await tx.selectFrom('gst_2b_imports').select('period').where('id', '=', line.import_id).executeTakeFirstOrThrow();
      const r = await loadRecon(tx, ctx, imp.period, [id]);
      return r.rows[0]!;
    });
  });

  app.get('/gst/itc-ageing', async (req) => {
    const ctx = req.ctx;
    ctx.require('gst.view');
    const q = parse(z.object({ asOf: dateField.optional() }), req.query);
    return ctx.tx((tx) => itcAgeing(tx, ctx.companyId, q.asOf ?? todayIst()));
  });
}
