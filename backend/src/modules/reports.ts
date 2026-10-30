import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { daysBetween, fyStart, isValidDate, todayIst } from '../lib/dates.ts';
import { scopedLocationIds } from '../lib/scope.ts';
import { visibleProjectIds } from './subcontract-common.ts';
import { parse } from '../lib/validate.ts';
import { msmeInterest } from '../lib/msme.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const round3 = (n: number) => Math.round(n * 1000) / 1000;
const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const rangeQuery = z.object({ from: dateField.optional(), to: dateField.optional(), locationId: z.uuid().optional() });
const asOfQuery = z.object({ asOf: dateField.optional() });

function range(q: { from?: string; to?: string }) {
  const to = q.to ?? todayIst();
  return { from: q.from ?? fyStart(to), to };
}

interface AccountTotal { id: string; code: string; name: string; type: string; system_key: string | null; d: number; c: number }

/** Debit and credit totals per account, optionally within a date range. */
async function accountTotals(tx: Tx, companyId: string, from: string | null, to: string): Promise<AccountTotal[]> {
  let q = tx.selectFrom('accounts as a')
    .innerJoin('journal_lines as jl', 'jl.account_id', 'a.id')
    .innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .where('a.company_id', '=', companyId).where('je.entry_date', '<=', to);
  if (from) q = q.where('je.entry_date', '>=', from);
  const rows = await q.groupBy(['a.id', 'a.code', 'a.name', 'a.type', 'a.system_key'])
    .select((eb) => ['a.id', 'a.code', 'a.name', 'a.type', 'a.system_key',
      eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
    .orderBy('a.code').execute();
  return rows.map((r) => ({ ...r, d: Number(r.d), c: Number(r.c) }));
}

const section = (rows: { id: string | null; code: string | null; name: string; amount: number }[]) => {
  const kept = rows.filter((r) => Math.abs(r.amount) >= 0.005).map((r) => ({ accountId: r.id, code: r.code, name: r.name, amount: round2(r.amount) }));
  return { rows: kept, total: round2(kept.reduce((s, r) => s + r.amount, 0)) };
};

type RateRow = { gstRate: number | null; taxable: number; cgst: number; sgst: number; igst: number };
const zeroRate = (gstRate: number | null): RateRow => ({ gstRate, taxable: 0, cgst: 0, sgst: 0, igst: 0 });
const addRate = (a: RateRow, b: Omit<RateRow, 'gstRate'>): RateRow => ({
  gstRate: a.gstRate, taxable: round2(a.taxable + b.taxable), cgst: round2(a.cgst + b.cgst),
  sgst: round2(a.sgst + b.sgst), igst: round2(a.igst + b.igst),
});
const subRate = (a: RateRow, b: Omit<RateRow, 'gstRate'>): RateRow => addRate(a, { taxable: -b.taxable, cgst: -b.cgst, sgst: -b.sgst, igst: -b.igst });

function scopeOf(ctx: RequestContext, locationId?: string) {
  const scope = scopedLocationIds(ctx);
  if (locationId) ctx.requireLocation(locationId);
  return { scope, locationId };
}

export async function reportRoutes(app: FastifyInstance) {
  app.get('/reports/trial-balance', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const asOf = parse(asOfQuery, req.query).asOf ?? todayIst();
    return ctx.tx(async (tx) => {
      await systemAccounts(tx, ctx);
      const rows = (await accountTotals(tx, ctx.companyId, null, asOf))
        .map((a) => ({ a, bal: round2(a.d - a.c) }))
        .filter((x) => x.bal !== 0)
        .map(({ a, bal }) => ({ accountId: a.id, code: a.code, name: a.name, type: a.type, debit: bal > 0 ? bal : 0, credit: bal < 0 ? -bal : 0 }));
      return {
        asOf, rows,
        totalDebit: round2(rows.reduce((s, r) => s + r.debit, 0)),
        totalCredit: round2(rows.reduce((s, r) => s + r.credit, 0)),
      };
    });
  });

  app.get('/reports/profit-loss', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const { from, to } = range(parse(rangeQuery, req.query));
    return ctx.tx(async (tx) => {
      const totals = await accountTotals(tx, ctx.companyId, from, to);
      const credit = (a: AccountTotal) => a.c - a.d;
      const debit = (a: AccountTotal) => a.d - a.c;
      const pick = (f: (a: AccountTotal) => boolean, amount: (a: AccountTotal) => number) =>
        section(totals.filter(f).map((a) => ({ id: a.id, code: a.code, name: a.name, amount: amount(a) })));
      const direct = ['cogs', 'purchases_nonstock'];
      const revenue = pick((a) => a.system_key === 'sales' || a.system_key === 'sales_returns', credit);
      const cogs = pick((a) => direct.includes(a.system_key ?? ''), debit);
      const otherIncome = pick((a) => a.type === 'income' && a.system_key !== 'sales' && a.system_key !== 'sales_returns', credit);
      const expenses = pick((a) => a.type === 'expense' && !direct.includes(a.system_key ?? ''), debit);
      const grossProfit = round2(revenue.total - cogs.total);
      return { from, to, revenue, cogs, grossProfit, otherIncome, expenses, netProfit: round2(grossProfit + otherIncome.total - expenses.total) };
    });
  });

  app.get('/reports/balance-sheet', async (req) => {
    const ctx = req.ctx;
    ctx.require('accounts.view');
    const asOf = parse(asOfQuery, req.query).asOf ?? todayIst();
    return ctx.tx(async (tx) => {
      const totals = await accountTotals(tx, ctx.companyId, null, asOf);
      const of = (type: string, sign: 1 | -1) =>
        totals.filter((a) => a.type === type).map((a) => ({ id: a.id, code: a.code, name: a.name, amount: sign * (a.d - a.c) }));
      const profit = totals.filter((a) => a.type === 'income' || a.type === 'expense').reduce((s, a) => s + (a.c - a.d), 0);
      const assets = section(of('asset', 1));
      const liabilities = section(of('liability', -1));
      const equity = section([...of('equity', -1), { id: null, code: null, name: 'Profit & Loss', amount: profit }]);
      return {
        asOf, assets, liabilities, equity,
        totalAssets: assets.total, totalLiabilitiesAndEquity: round2(liabilities.total + equity.total),
      };
    });
  });

  app.get('/reports/sales-register', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const q = parse(rangeQuery, req.query);
    const { from, to } = range(q);
    const { scope, locationId } = scopeOf(ctx, q.locationId);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('invoices as v').innerJoin('parties as p', 'p.id', 'v.party_id')
        .where('v.company_id', '=', ctx.companyId).where('v.invoice_date', '>=', from).where('v.invoice_date', '<=', to);
      if (scope) base = base.where('v.location_id', 'in', scope);
      if (locationId) base = base.where('v.location_id', '=', locationId);
      const rows = await base.select(['v.id', 'v.number', 'v.invoice_date', 'p.name', 'p.gstin', 'v.place_of_supply',
        'v.subtotal', 'v.cgst', 'v.sgst', 'v.igst', 'v.total', 'v.status'])
        .orderBy('v.invoice_date').orderBy('v.number').execute();
      return registerResult(rows.map((r) => ({
        id: r.id, number: r.number, date: r.invoice_date, partyName: r.name, partyGstin: r.gstin, placeOfSupply: r.place_of_supply,
        taxable: r.subtotal, cgst: r.cgst, sgst: r.sgst, igst: r.igst, total: r.total, status: r.status,
      })));
    });
  });

  app.get('/reports/purchase-register', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const q = parse(rangeQuery, req.query);
    const { from, to } = range(q);
    const { scope, locationId } = scopeOf(ctx, q.locationId);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id')
        .where('v.company_id', '=', ctx.companyId).where('v.bill_date', '>=', from).where('v.bill_date', '<=', to);
      if (scope) base = base.where('v.location_id', 'in', scope);
      if (locationId) base = base.where('v.location_id', '=', locationId);
      const rows = await base.select(['v.id', 'v.number', 'v.supplier_invoice_no', 'v.bill_date', 'p.name', 'p.gstin',
        'v.place_of_supply', 'v.subtotal', 'v.cgst', 'v.sgst', 'v.igst', 'v.total', 'v.status'])
        .orderBy('v.bill_date').orderBy('v.number').execute();
      return registerResult(rows.map((r) => ({
        id: r.id, number: r.number, supplierInvoiceNo: r.supplier_invoice_no, date: r.bill_date, partyName: r.name,
        partyGstin: r.gstin, placeOfSupply: r.place_of_supply, taxable: r.subtotal, cgst: r.cgst, sgst: r.sgst,
        igst: r.igst, total: r.total, status: r.status,
      })));
    });
  });

  app.get('/reports/gst-summary', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const { from, to } = range(parse(rangeQuery, req.query));
    const scope = scopedLocationIds(ctx);
    return ctx.tx(async (tx) => {
      let out = tx.selectFrom('invoice_lines as l').innerJoin('invoices as v', 'v.id', 'l.invoice_id')
        .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted')
        .where('v.invoice_date', '>=', from).where('v.invoice_date', '<=', to);
      if (scope) out = out.where('v.location_id', 'in', scope);
      const outRates = await out.groupBy('l.gst_rate').select((eb) => ['l.gst_rate',
        eb.fn.sum<number>('l.taxable_value').as('taxable'), eb.fn.sum<number>('l.cgst').as('cgst'),
        eb.fn.sum<number>('l.sgst').as('sgst'), eb.fn.sum<number>('l.igst').as('igst')]).orderBy('l.gst_rate').execute();

      let inv = tx.selectFrom('invoices as v').innerJoin('parties as p', 'p.id', 'v.party_id')
        .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted')
        .where('v.invoice_date', '>=', from).where('v.invoice_date', '<=', to);
      if (scope) inv = inv.where('v.location_id', 'in', scope);
      const split = await inv.select(['p.gstin', 'v.subtotal', 'v.cgst', 'v.sgst', 'v.igst']).execute();
      const b2b = { count: 0, taxable: 0, tax: 0 };
      const b2c = { count: 0, taxable: 0, tax: 0 };
      for (const r of split) {
        const t = r.gstin ? b2b : b2c;
        t.count += 1;
        t.taxable = round2(t.taxable + r.subtotal);
        t.tax = round2(t.tax + r.cgst + r.sgst + r.igst);
      }

      let cn = tx.selectFrom('credit_notes as n').where('n.company_id', '=', ctx.companyId).where('n.status', '=', 'posted')
        .where('n.note_date', '>=', from).where('n.note_date', '<=', to);
      if (scope) cn = cn.where('n.location_id', 'in', scope);
      const cnTotals = await cn.select((eb) => [eb.fn.sum<number>('n.subtotal').as('taxable'), eb.fn.sum<number>('n.cgst').as('cgst'),
        eb.fn.sum<number>('n.sgst').as('sgst'), eb.fn.sum<number>('n.igst').as('igst')]).executeTakeFirstOrThrow();
      const creditNotes = addRate(zeroRate(null), num(cnTotals));

      const byRate = outRates.map((r) => addRate(zeroRate(r.gst_rate), num(r)));
      const outTotal = byRate.reduce((s, r) => addRate(s, r), zeroRate(null));
      const net = subRate(outTotal, creditNotes);

      let inLines = tx.selectFrom('purchase_lines as l').innerJoin('purchases as v', 'v.id', 'l.purchase_id')
        .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted')
        .where('v.bill_date', '>=', from).where('v.bill_date', '<=', to);
      if (scope) inLines = inLines.where('v.location_id', 'in', scope);
      const inRates = await inLines.groupBy('l.gst_rate').select((eb) => ['l.gst_rate',
        eb.fn.sum<number>('l.taxable_value').as('taxable'), eb.fn.sum<number>('l.cgst').as('cgst'),
        eb.fn.sum<number>('l.sgst').as('sgst'), eb.fn.sum<number>('l.igst').as('igst')]).orderBy('l.gst_rate').execute();
      let exp = tx.selectFrom('expenses as e').where('e.company_id', '=', ctx.companyId).where('e.status', '=', 'posted')
        .where('e.expense_date', '>=', from).where('e.expense_date', '<=', to);
      if (scope) exp = exp.where('e.location_id', 'in', scope);
      const expTotals = await exp.select((eb) => [eb.fn.sum<number>('e.amount').as('taxable'), eb.fn.sum<number>('e.cgst').as('cgst'),
        eb.fn.sum<number>('e.sgst').as('sgst'), eb.fn.sum<number>('e.igst').as('igst')]).executeTakeFirstOrThrow();
      const inByRate = inRates.map((r) => addRate(zeroRate(r.gst_rate), num(r)));
      const expenses = addRate(zeroRate(null), num(expTotals));
      const inTotal = [...inByRate, expenses].reduce((s, r) => addRate(s, r), zeroRate(null));

      // HSN summary: invoice lines less credit-note lines.
      let hsnOut = tx.selectFrom('invoice_lines as l').innerJoin('invoices as v', 'v.id', 'l.invoice_id')
        .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted')
        .where('v.invoice_date', '>=', from).where('v.invoice_date', '<=', to);
      if (scope) hsnOut = hsnOut.where('v.location_id', 'in', scope);
      let hsnCn = tx.selectFrom('credit_note_lines as l').innerJoin('credit_notes as n', 'n.id', 'l.credit_note_id')
        .where('n.company_id', '=', ctx.companyId).where('n.status', '=', 'posted')
        .where('n.note_date', '>=', from).where('n.note_date', '<=', to);
      if (scope) hsnCn = hsnCn.where('n.location_id', 'in', scope);
      const hOut = await hsnOut.groupBy(['l.hsn_code', 'l.unit']).select((eb) => ['l.hsn_code', 'l.unit',
        eb.fn.sum<number>('l.qty').as('qty'), eb.fn.sum<number>('l.taxable_value').as('taxable'), eb.fn.sum<number>('l.cgst').as('cgst'),
        eb.fn.sum<number>('l.sgst').as('sgst'), eb.fn.sum<number>('l.igst').as('igst')]).execute();
      const hCn = await hsnCn.groupBy(['l.hsn_code', 'l.unit']).select((eb) => ['l.hsn_code', 'l.unit',
        eb.fn.sum<number>('l.qty').as('qty'), eb.fn.sum<number>('l.taxable_value').as('taxable'), eb.fn.sum<number>('l.cgst').as('cgst'),
        eb.fn.sum<number>('l.sgst').as('sgst'), eb.fn.sum<number>('l.igst').as('igst')]).execute();
      const hsn = new Map<string, { hsnCode: string | null; unit: string; qty: number; taxable: number; cgst: number; sgst: number; igst: number }>();
      const merge = (rows: typeof hOut, sign: 1 | -1) => {
        for (const r of rows) {
          const key = `${r.hsn_code ?? ''}|${r.unit}`;
          const e = hsn.get(key) ?? { hsnCode: r.hsn_code, unit: r.unit, qty: 0, taxable: 0, cgst: 0, sgst: 0, igst: 0 };
          e.qty = round3(e.qty + sign * Number(r.qty));
          e.taxable = round2(e.taxable + sign * Number(r.taxable));
          e.cgst = round2(e.cgst + sign * Number(r.cgst));
          e.sgst = round2(e.sgst + sign * Number(r.sgst));
          e.igst = round2(e.igst + sign * Number(r.igst));
          hsn.set(key, e);
        }
      };
      merge(hOut, 1);
      merge(hCn, -1);

      const netPayable = {
        cgst: round2(net.cgst - inTotal.cgst), sgst: round2(net.sgst - inTotal.sgst), igst: round2(net.igst - inTotal.igst), total: 0,
      };
      netPayable.total = round2(netPayable.cgst + netPayable.sgst + netPayable.igst);
      return {
        from, to,
        outward: { byRate, b2b, b2c, creditNotes, net },
        inward: { byRate: inByRate, expenses, total: inTotal },
        hsn: [...hsn.values()].sort((a, b) => (a.hsnCode ?? '').localeCompare(b.hsnCode ?? '')),
        netPayable,
      };
    });
  });

  app.get('/reports/stock-valuation', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    ctx.require('items.view_cost');
    const q = parse(z.object({ locationId: z.uuid().optional() }), req.query);
    const { scope, locationId } = scopeOf(ctx, q.locationId);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('stock_moves as m').innerJoin('items as i', 'i.id', 'm.item_id').where('m.company_id', '=', ctx.companyId);
      if (scope) base = base.where('m.location_id', 'in', scope);
      if (locationId) base = base.where('m.location_id', '=', locationId);
      const rows = await base.groupBy(['i.id', 'i.name', 'i.sku', 'i.unit'])
        .select((eb) => ['i.id', 'i.name', 'i.sku', 'i.unit', eb.fn.sum<number>('m.qty').as('qty'), eb.fn.sum<number>('m.value').as('value')])
        .orderBy('i.name').execute();
      const data = rows.map((r) => {
        const qty = round3(Number(r.qty));
        const value = round2(Number(r.value));
        return { itemId: r.id, name: r.name, sku: r.sku, unit: r.unit, qty, avgCost: qty > 0 ? Math.round((value / qty) * 100) / 100 : 0, value };
      }).filter((r) => r.qty !== 0 || r.value !== 0);
      return { rows: data, totalValue: round2(data.reduce((s, r) => s + r.value, 0)) };
    });
  });

  app.get('/reports/ageing', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const q = parse(z.object({ type: z.enum(['receivables', 'payables']).default('receivables'), asOf: dateField.optional() }), req.query);
    const asOf = q.asOf ?? todayIst();
    const scope = scopedLocationIds(ctx);
    return ctx.tx(async (tx) => {
      const docs: { party_id: string; name: string; due_date: string; total: number; amount_paid: number }[] = q.type === 'receivables'
        ? await (() => {
          let b = tx.selectFrom('invoices as v').innerJoin('parties as p', 'p.id', 'v.party_id')
            .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted').where('v.invoice_date', '<=', asOf)
            .whereRef('v.amount_paid', '<', 'v.total');
          if (scope) b = b.where('v.location_id', 'in', scope);
          return b.select(['p.id as party_id', 'p.name', 'v.due_date', 'v.total', 'v.amount_paid']).execute();
        })()
        : await (() => {
          let b = tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id')
            .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted').where('v.bill_date', '<=', asOf)
            .whereRef('v.amount_paid', '<', 'v.net_payable');
          if (scope) b = b.where('v.location_id', 'in', scope);
          return b.select(['p.id as party_id', 'p.name', 'v.due_date', 'v.net_payable as total', 'v.amount_paid']).execute();
        })();
      if (q.type === 'receivables') {
        let d = tx.selectFrom('demands as v').innerJoin('parties as p', 'p.id', 'v.party_id').innerJoin('bookings as bk', 'bk.id', 'v.booking_id')
          .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'open').where('v.demand_date', '<=', asOf)
          .whereRef('v.amount_paid', '<', 'v.total');
        const vis = await visibleProjectIds(tx, ctx);
        if (vis) d = d.where('bk.project_id', 'in', vis);
        docs.push(...await d.select(['p.id as party_id', 'p.name', 'v.due_date', 'v.total', 'v.amount_paid']).execute());
      } else {
        let d = tx.selectFrom('ra_bills as v').innerJoin('work_orders as w', 'w.id', 'v.work_order_id').innerJoin('parties as p', 'p.id', 'w.contractor_party_id')
          .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'approved').where('v.bill_date', '<=', asOf)
          .whereRef('v.amount_paid', '<', 'v.net_payable');
        const vis = await visibleProjectIds(tx, ctx);
        if (vis) d = d.where('w.project_id', 'in', vis);
        docs.push(...await d.select(['p.id as party_id', 'p.name', 'v.due_date', 'v.net_payable as total', 'v.amount_paid']).execute());
      }
      type Buckets = { notDue: number; d1_30: number; d31_60: number; d61_90: number; d90plus: number; total: number };
      const empty = (): Buckets => ({ notDue: 0, d1_30: 0, d31_60: 0, d61_90: 0, d90plus: 0, total: 0 });
      const byParty = new Map<string, { partyId: string; partyName: string } & Buckets>();
      const totals = empty();
      for (const d of docs) {
        const due = round2(d.total - d.amount_paid);
        const late = daysBetween(d.due_date, asOf);
        const key: keyof Buckets = late <= 0 ? 'notDue' : late <= 30 ? 'd1_30' : late <= 60 ? 'd31_60' : late <= 90 ? 'd61_90' : 'd90plus';
        const row = byParty.get(d.party_id) ?? { partyId: d.party_id, partyName: d.name, ...empty() };
        row[key] = round2(row[key] + due);
        row.total = round2(row.total + due);
        totals[key] = round2(totals[key] + due);
        totals.total = round2(totals.total + due);
        byParty.set(d.party_id, row);
      }
      return { asOf, rows: [...byParty.values()].sort((a, b) => b.total - a.total), totals };
    });
  });

  app.get('/reports/msme-dues', async (req) => {
    const ctx = req.ctx;
    ctx.require('reports.view');
    const q = parse(asOfQuery, req.query);
    const asOf = q.asOf ?? todayIst();
    const y = Number(asOf.slice(0, 4));
    const yearEnd = `${asOf.slice(5) >= '03-31' ? y : y - 1}-03-31`;
    return ctx.tx(async (tx) => {
      const co = await tx.selectFrom('companies').select('msme_bank_rate').where('id', '=', ctx.companyId).executeTakeFirstOrThrow();
      const scope = scopedLocationIds(ctx);
      let base = tx.selectFrom('purchases as v').innerJoin('parties as p', 'p.id', 'v.party_id')
        .select(['v.id', 'v.number', 'v.bill_date', 'v.msme_due_date', 'v.net_payable', 'v.amount_paid', 'p.id as party_id', 'p.name', 'p.udyam_no', 'p.msme_category'])
        .where('v.company_id', '=', ctx.companyId).where('v.status', '=', 'posted').where('v.msme_due_date', 'is not', null);
      if (scope) base = base.where('v.location_id', 'in', scope);
      const bills = await base.whereRef('v.amount_paid', '<', 'v.net_payable').orderBy('v.msme_due_date').execute();
      const rows = bills.map((b) => {
        const unpaid = round2(b.net_payable - b.amount_paid);
        const due = b.msme_due_date!;
        return {
          purchaseId: b.id, number: b.number, billDate: b.bill_date, msmeDueDate: due, partyId: b.party_id, partyName: b.name, udyamNo: b.udyam_no, category: b.msme_category,
          total: b.net_payable, unpaid, daysOverdue: Math.max(0, daysBetween(due, asOf)), interest: msmeInterest(unpaid, due, asOf, co.msme_bank_rate),
        };
      });
      // Section 43B(h): amounts past the due date and still unpaid at the last 31 March
      let yearEndDisallowance = 0;
      const old = bills.filter((b) => b.msme_due_date! < yearEnd && b.bill_date <= yearEnd);
      if (old.length) {
        const paid = await tx.selectFrom('payment_allocations as a').innerJoin('payments as y', 'y.id', 'a.payment_id')
          .select(['a.doc_id', (eb) => eb.fn.sum<number>('a.amount').as('paid')]).where('a.doc_type', '=', 'purchase').where('a.doc_id', 'in', old.map((b) => b.id))
          .where('y.status', '=', 'posted').where('y.payment_date', '<=', yearEnd).groupBy('a.doc_id').execute();
        const m = new Map(paid.map((p) => [p.doc_id, Number(p.paid)]));
        for (const b of old) yearEndDisallowance += Math.max(0, b.net_payable - (m.get(b.id) ?? 0));
      }
      const warnings: string[] = [];
      if (co.msme_bank_rate === null) warnings.push('Set the RBI bank rate in company settings to compute interest.');
      return {
        asOf, bankRate: co.msme_bank_rate, rows,
        totals: {
          unpaid: round2(rows.reduce((s, r) => s + r.unpaid, 0)),
          overdue: round2(rows.filter((r) => r.daysOverdue > 0).reduce((s, r) => s + r.unpaid, 0)),
          interest: round2(rows.reduce((s, r) => s + (r.interest ?? 0), 0)),
        },
        yearEnd, yearEndDisallowance: round2(yearEndDisallowance), warnings,
      };
    });
  });
}

function num(r: { taxable: unknown; cgst: unknown; sgst: unknown; igst: unknown }) {
  return { taxable: Number(r.taxable ?? 0), cgst: Number(r.cgst ?? 0), sgst: Number(r.sgst ?? 0), igst: Number(r.igst ?? 0) };
}

function registerResult<T extends { taxable: number; cgst: number; sgst: number; igst: number; total: number; status: string }>(rows: T[]) {
  const totals = { taxable: 0, cgst: 0, sgst: 0, igst: 0, total: 0 };
  for (const r of rows) {
    if (r.status !== 'posted') continue;
    totals.taxable = round2(totals.taxable + r.taxable);
    totals.cgst = round2(totals.cgst + r.cgst);
    totals.sgst = round2(totals.sgst + r.sgst);
    totals.igst = round2(totals.igst + r.igst);
    totals.total = round2(totals.total + r.total);
  }
  return { rows, totals };
}
