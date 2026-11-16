import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseVoucher } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, financialYear, isValidDate, todayIst } from '../lib/dates.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { db, fxAccount, rateOn, round2, settingsOf } from '../lib/export-currency.ts';
import { optionalText } from '../lib/india.ts';
import { moneyField } from '../lib/numbers.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

/** Export settings, LUT, currencies, rates, foreign receipts, revaluation and TCS setup/report. See docs/API.md v1.20. */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const codeField = z.string().regex(/^[A-Z]{3}$/, 'Three capital letters');
const rateField = z.coerce.number().positive().max(1e6);
const d10 = (v: unknown) => (v ? String(v).slice(0, 10) : null);

const DEFAULT_CURRENCIES = [
  ['USD', 'US dollar', '$', 2], ['EUR', 'Euro', 'EUR', 2], ['GBP', 'Pound sterling', 'GBP', 2], ['AED', 'UAE dirham', 'AED', 2],
  ['SGD', 'Singapore dollar', 'S$', 2], ['JPY', 'Japanese yen', 'JPY', 0],
] as const;

const DEFAULT_NATURES = [
  // section_old is the Income-tax Act 1961 reference; section_new the Income-tax Act 2025 (section 394). Rates are editable.
  ['alcohol', 'Alcoholic liquor for human consumption', '206C(1)', '394(1)', 1, 0],
  ['tendu', 'Tendu leaves', '206C(1)', '394(1)', 5, 0],
  ['timber_lease', 'Timber obtained under a forest lease', '206C(1)', '394(1)', 2.5, 0],
  ['timber_other', 'Timber obtained by any mode other than a forest lease', '206C(1)', '394(1)', 2.5, 0],
  ['forest_produce', 'Any other forest produce (not tendu or timber)', '206C(1)', '394(1)', 2.5, 0],
  ['scrap', 'Scrap', '206C(1)', '394(1)', 1, 0],
  ['minerals', 'Coal, lignite or iron ore', '206C(1)', '394(1)', 1, 0],
  ['vehicle', 'Motor vehicle above 10 lakh', '206C(1F)', '394(1)', 1, 1_000_000],
] as const;

async function ensureNatures(tx: Tx, ctx: RequestContext) {
  const any = await db(tx).selectFrom('tcs_natures').select('id').where('company_id', '=', ctx.companyId).limit(1).executeTakeFirst();
  if (any) return;
  await db(tx).insertInto('tcs_natures').values(DEFAULT_NATURES.map(([code, label, o, n, rate, threshold]) => ({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, code, label, section_old: o, section_new: n, rate, threshold,
  }))).onConflict((oc) => oc.doNothing()).execute();
}
const natureJson = (r: any) => ({
  id: r.id, code: r.code, label: r.label, sectionOld: r.section_old, sectionNew: r.section_new, rate: Number(r.rate),
  threshold: Number(r.threshold), isActive: r.is_active,
});

const settingsBody = z.object({ tcsEnabled: z.boolean().optional(), tcsBase: z.enum(['taxable', 'total']).optional() });
const lutBody = z.object({ fy: z.string().regex(/^[0-9]{4}-[0-9]{2}$/, 'Like 2026-27'), lutNo: z.string().trim().min(1).max(40), arn: optionalText(40), validFrom: dateField, validTo: dateField });
const currencyBody = z.object({ code: codeField, name: z.string().trim().min(1).max(60), symbol: z.string().trim().min(1).max(6), decimals: z.coerce.number().int().min(0).max(4).default(2) });
const rateBody = z.object({ code: codeField, date: dateField, rate: rateField, note: optionalText(200) });
const partyBody = z.object({ defaultCurrency: codeField.nullable().optional(), tcsNatureId: z.uuid().nullable().optional(), tcsExempt: z.boolean().optional() });
const receiptBody = z.object({
  partyId: z.uuid(), accountId: z.uuid(), date: docDate.optional(), mode: z.enum(['cash', 'bank', 'upi', 'cheque', 'card']).default('bank'),
  reference: optionalText(60), currency: codeField, fcAmount: z.coerce.number().positive().max(1e10), rate: rateField,
  allocations: z.array(z.object({ invoiceId: z.uuid(), fcAmount: z.coerce.number().positive() })).max(200).optional(),
});
const revalBody = z.object({ asOf: dateField, rates: z.record(codeField, rateField).optional() });
const natureBody = z.object({
  code: z.string().trim().min(1).max(30), label: z.string().trim().min(1).max(120), sectionOld: z.string().trim().min(1).max(30),
  sectionNew: optionalText(30), rate: z.coerce.number().min(0).max(100), threshold: moneyField.optional(),
});
const naturePatch = natureBody.partial().extend({ isActive: z.boolean().optional() });
const reportQuery = z.object({ from: dateField, to: dateField });

/** Open foreign invoices of a party in a currency: oldest first. */
async function openForeign(tx: Tx, ctx: RequestContext, partyId: string | null, currency: string | null, lock = false) {
  let q = db(tx).selectFrom('invoices as i').innerJoin('invoice_ext as e', 'e.invoice_id', 'i.id')
    .select(['i.id', 'i.number', 'i.invoice_date', 'i.total', 'i.amount_paid', 'i.party_id', 'e.currency_code', 'e.exchange_rate', 'e.fc_total'])
    .where('i.company_id', '=', ctx.companyId).where('i.status', '=', 'posted').where('e.currency_code', 'is not', null)
    .whereRef('i.amount_paid', '<', 'i.total').orderBy('i.invoice_date').orderBy('i.number');
  if (partyId) q = q.where('i.party_id', '=', partyId);
  if (currency) q = q.where('e.currency_code', '=', currency);
  if (lock) q = q.forUpdate('i');
  return (await q.execute()).map((r) => {
    const total = Number(r.total); const inr = round2(total - Number(r.amount_paid));
    const fcTotal = Number(r.fc_total);
    return {
      invoiceId: r.id as string, number: r.number as string, date: d10(r.invoice_date)!, partyId: r.party_id as string, currency: r.currency_code as string,
      rate: Number(r.exchange_rate), fcTotal, inrOutstanding: inr, fcOutstanding: Math.round(fcTotal * inr / total * 10_000) / 10_000,
    };
  });
}

async function revaluationRows(tx: Tx, ctx: RequestContext, asOf: string, given: Record<string, number> | undefined) {
  const open = (await openForeign(tx, ctx, null, null)).filter((o) => o.date <= asOf);
  const rates = new Map<string, number>();
  for (const code of new Set(open.map((o) => o.currency))) {
    const r = given?.[code] ?? (await rateOn(tx, ctx.companyId, code, asOf))?.rate;
    if (!r) throw badRequest(`No closing rate for ${code} on or before ${asOf}. Enter one.`, { rates: `Missing ${code}` });
    rates.set(code, r);
  }
  const rows = open.map((o) => {
    const closing = rates.get(o.currency)!;
    const revalued = round2(o.fcOutstanding * closing);
    return { ...o, closingRate: closing, carrying: o.inrOutstanding, revalued, adjustment: round2(revalued - o.inrOutstanding) };
  }).filter((r) => r.adjustment !== 0);
  return { rows, total: round2(rows.reduce((s, r) => s + r.adjustment, 0)) };
}

export async function exportCurrencyRoutes(app: FastifyInstance) {
  // Settings and LUT.
  const getSettings = async (req: any) => {
    const ctx = req.ctx as RequestContext; ctx.require('fx.view', 'tcs.view');
    return ctx.tx((tx) => settingsOf(tx, ctx));
  };
  const putSettings = async (req: any) => {
    const ctx = req.ctx as RequestContext; ctx.require('fx.manage', 'tcs.manage');
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await settingsOf(tx, ctx);
      const next = { tcsEnabled: b.tcsEnabled ?? cur.tcsEnabled, tcsBase: b.tcsBase ?? cur.tcsBase };
      await db(tx).insertInto('export_settings').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, tcs_enabled: next.tcsEnabled, tcs_base: next.tcsBase })
        .onConflict((oc) => oc.column('company_id').doUpdateSet({ tcs_enabled: next.tcsEnabled, tcs_base: next.tcsBase })).execute();
      await writeAudit(tx, auditOf(ctx), 'export_settings', null, 'update', cur, next);
      return next;
    });
  };
  app.get('/export/settings', getSettings);
  app.put('/export/settings', putSettings);
  app.patch('/export/settings', putSettings);

  const lutJson = (r: any) => ({ id: r.id, fy: r.fy, lutNo: r.lut_no, arn: r.arn, validFrom: d10(r.valid_from), validTo: d10(r.valid_to) });
  app.get('/export/luts', async (req) => {
    const ctx = req.ctx; ctx.require('fx.view');
    return ctx.tx(async (tx) => ({ data: (await db(tx).selectFrom('export_luts').selectAll().where('company_id', '=', ctx.companyId).orderBy('fy', 'desc').execute()).map(lutJson) }));
  });
  app.post('/export/luts', async (req, reply) => {
    const ctx = req.ctx; ctx.require('fx.manage');
    const b = parse(lutBody, req.body);
    if (b.validTo < b.validFrom) throw badRequest('Valid to is before valid from.', { validTo: 'Before start' });
    const row = await ctx.tx(async (tx) => {
      const dup = await db(tx).selectFrom('export_luts').select('id').where('company_id', '=', ctx.companyId).where('fy', '=', b.fy).executeTakeFirst();
      if (dup) throw conflict(`A LUT for ${b.fy} already exists. Edit it instead.`, 'DUPLICATE');
      const r = await db(tx).insertInto('export_luts').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, fy: b.fy, lut_no: b.lutNo, arn: b.arn ?? null, valid_from: b.validFrom, valid_to: b.validTo, created_by: ctx.userId }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'export_lut', r.id, 'create', null, { fy: b.fy, lutNo: b.lutNo });
      return r;
    });
    return reply.status(201).send(lutJson(row));
  });
  app.patch<{ Params: { id: string } }>('/export/luts/:id', async (req) => {
    const ctx = req.ctx; ctx.require('fx.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(lutBody.partial(), req.body);
    return ctx.tx(async (tx) => {
      const set: Record<string, unknown> = {};
      if (b.lutNo !== undefined) set.lut_no = b.lutNo;
      if (b.arn !== undefined) set.arn = b.arn;
      if (b.validFrom !== undefined) set.valid_from = b.validFrom;
      if (b.validTo !== undefined) set.valid_to = b.validTo;
      if (!Object.keys(set).length) throw badRequest('Nothing to change.');
      const r = await db(tx).updateTable('export_luts').set(set).where('id', '=', id).where('company_id', '=', ctx.companyId).returningAll().executeTakeFirst();
      if (!r) throw notFound('LUT');
      if (r.valid_to < r.valid_from) throw badRequest('Valid to is before valid from.', { validTo: 'Before start' });
      return lutJson(r);
    });
  });

  // Currencies and rates.
  const curJson = (r: any) => ({ code: r.code, name: r.name, symbol: r.symbol, decimals: Number(r.decimals), isActive: r.is_active });
  app.get('/fx/currencies', async (req) => {
    const ctx = req.ctx; ctx.require('fx.view', 'invoices.create');
    return ctx.tx(async (tx) => {
      let rows = await db(tx).selectFrom('currencies').selectAll().where('company_id', '=', ctx.companyId).orderBy('code').execute();
      if (!rows.length) {
        await db(tx).insertInto('currencies').values(DEFAULT_CURRENCIES.map(([code, name, symbol, decimals]) => ({ tenant_id: ctx.tenantId, company_id: ctx.companyId, code, name, symbol, decimals })))
          .onConflict((oc) => oc.doNothing()).execute();
        rows = await db(tx).selectFrom('currencies').selectAll().where('company_id', '=', ctx.companyId).orderBy('code').execute();
      }
      return { data: rows.map(curJson) };
    });
  });
  app.post('/fx/currencies', async (req, reply) => {
    const ctx = req.ctx; ctx.require('fx.manage');
    const b = parse(currencyBody, req.body);
    if (b.code === 'INR') throw badRequest('INR is the books currency.', { code: 'Reserved' });
    const r = await ctx.tx(async (tx) => {
      const dup = await db(tx).selectFrom('currencies').select('id').where('company_id', '=', ctx.companyId).where('code', '=', b.code).executeTakeFirst();
      if (dup) throw conflict(`${b.code} already exists.`, 'DUPLICATE');
      return db(tx).insertInto('currencies').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, code: b.code, name: b.name, symbol: b.symbol, decimals: b.decimals }).returningAll().executeTakeFirstOrThrow();
    });
    return reply.status(201).send(curJson(r));
  });
  const patchCurrency = async (req: any) => {
    const ctx = req.ctx as RequestContext; ctx.require('fx.manage');
    const code = parse(codeField, req.params.code);
    const b = parse(currencyBody.omit({ code: true }).partial().extend({ isActive: z.boolean().optional() }), req.body);
    return ctx.tx(async (tx) => {
      const set: Record<string, unknown> = {};
      if (b.name !== undefined) set.name = b.name;
      if (b.symbol !== undefined) set.symbol = b.symbol;
      if (b.decimals !== undefined) set.decimals = b.decimals;
      if (b.isActive !== undefined) set.is_active = b.isActive;
      if (!Object.keys(set).length) throw badRequest('Nothing to change.');
      const r = await db(tx).updateTable('currencies').set(set).where('company_id', '=', ctx.companyId).where('code', '=', code).returningAll().executeTakeFirst();
      if (!r) throw notFound('Currency');
      return curJson(r);
    });
  };
  app.patch('/fx/currencies/:code', patchCurrency);
  app.put('/fx/currencies/:code', patchCurrency);

  app.get('/fx/rates', async (req) => {
    const ctx = req.ctx; ctx.require('fx.view', 'invoices.create');
    const q = parse(z.object({ code: codeField.optional() }), req.query);
    return ctx.tx(async (tx) => {
      let s = db(tx).selectFrom('exchange_rates').selectAll().where('company_id', '=', ctx.companyId);
      if (q.code) s = s.where('currency_code', '=', q.code);
      const rows = await s.orderBy('rate_date', 'desc').limit(200).execute();
      return { data: rows.map((r) => ({ id: r.id, code: r.currency_code, date: d10(r.rate_date), rate: Number(r.rate), note: r.note })) };
    });
  });
  app.get('/fx/rates/latest', async (req) => {
    const ctx = req.ctx; ctx.require('fx.view', 'invoices.create');
    const q = parse(z.object({ code: codeField, date: dateField.optional() }), req.query);
    return ctx.tx(async (tx) => {
      const r = await rateOn(tx, ctx.companyId, q.code, q.date ?? todayIst());
      if (!r) throw notFound('Exchange rate');
      return r;
    });
  });
  app.post('/fx/rates', async (req, reply) => {
    const ctx = req.ctx; ctx.require('fx.manage');
    const b = parse(rateBody, req.body);
    await ctx.tx(async (tx) => {
      const cur = await db(tx).selectFrom('currencies').select('id').where('company_id', '=', ctx.companyId).where('code', '=', b.code).executeTakeFirst();
      if (!cur) throw badRequest(`Add ${b.code} under currencies first.`, { code: 'Unknown currency' });
      await db(tx).insertInto('exchange_rates').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, currency_code: b.code, rate_date: b.date, rate: b.rate, note: b.note ?? null, created_by: ctx.userId })
        .onConflict((oc) => oc.columns(['company_id', 'currency_code', 'rate_date']).doUpdateSet({ rate: b.rate, note: b.note ?? null })).execute();
    });
    return reply.status(201).send({ code: b.code, date: b.date, rate: b.rate, note: b.note ?? null });
  });

  // Party defaults.
  const getParty = async (req: any) => {
    const ctx = req.ctx as RequestContext; ctx.require('fx.view', 'tcs.view', 'invoices.create');
    const id = parse(z.uuid(), req.params.partyId);
    return ctx.tx(async (tx) => {
      const p = await tx.selectFrom('parties').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!p) throw notFound('Party');
      const r = await db(tx).selectFrom('party_trade_settings').selectAll().where('party_id', '=', id).executeTakeFirst();
      return { partyId: id, defaultCurrency: r?.default_currency ?? null, tcsNatureId: r?.tcs_nature_id ?? null, tcsExempt: r?.tcs_exempt === true };
    });
  };
  const putParty = async (req: any) => {
    const ctx = req.ctx as RequestContext; ctx.require('fx.manage', 'tcs.manage');
    const id = parse(z.uuid(), req.params.partyId);
    const b = parse(partyBody, req.body);
    return ctx.tx(async (tx) => {
      const p = await tx.selectFrom('parties').select('id').where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!p) throw notFound('Party');
      const cur = await db(tx).selectFrom('party_trade_settings').selectAll().where('party_id', '=', id).executeTakeFirst();
      const v = {
        default_currency: b.defaultCurrency === undefined ? cur?.default_currency ?? null : b.defaultCurrency,
        tcs_nature_id: b.tcsNatureId === undefined ? cur?.tcs_nature_id ?? null : b.tcsNatureId,
        tcs_exempt: b.tcsExempt ?? cur?.tcs_exempt ?? false,
      };
      await db(tx).insertInto('party_trade_settings').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, party_id: id, ...v })
        .onConflict((oc) => oc.column('party_id').doUpdateSet(v)).execute();
      return { partyId: id, defaultCurrency: v.default_currency, tcsNatureId: v.tcs_nature_id, tcsExempt: v.tcs_exempt };
    });
  };
  app.get('/fx/parties/:partyId', getParty);
  app.put('/fx/parties/:partyId', putParty);
  app.patch('/fx/parties/:partyId', putParty);

  app.get('/fx/outstanding', async (req) => {
    const ctx = req.ctx; ctx.require('fx.view', 'payments.view');
    const q = parse(z.object({ partyId: z.uuid().optional(), currency: codeField.optional() }), req.query);
    return ctx.tx(async (tx) => ({ data: await openForeign(tx, ctx, q.partyId ?? null, q.currency ?? null) }));
  });

  // Foreign receipts.
  app.post('/fx/receipts', async (req, reply) => {
    const ctx = req.ctx; ctx.require('payments.create', 'fx.manage');
    const b = parse(receiptBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const party = await tx.selectFrom('parties').select(['id', 'name', 'type']).where('id', '=', b.partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!party) throw badRequest('Party not found.', { partyId: 'Not found' });
      if (party.type === 'vendor') throw badRequest('Receipts are from customers.', { partyId: 'Not a customer' });
      const account = await tx.selectFrom('accounts').select(['id', 'subtype', 'is_active']).where('id', '=', b.accountId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!account || !account.is_active || !['cash', 'bank'].includes(account.subtype)) throw badRequest('Choose an active cash or bank account.', { accountId: 'Not a cash or bank account' });
      const date = b.date ?? todayIst();
      if (date > todayIst()) throw badRequest('Date cannot be in the future.', { date: 'In the future' });
      const open = await openForeign(tx, ctx, party.id, b.currency, true);
      let plan: { invoiceId: string; fc: number }[];
      if (b.allocations) {
        const seen = new Set<string>();
        plan = b.allocations.map((a, i) => {
          const o = open.find((x) => x.invoiceId === a.invoiceId);
          if (!o) throw badRequest(`Allocation ${i + 1}: invoice is not open in ${b.currency} for this customer.`, { [`allocations.${i}.invoiceId`]: 'Not open' });
          if (seen.has(a.invoiceId)) throw badRequest('Each invoice can be allocated once.', { [`allocations.${i}.invoiceId`]: 'Duplicate' });
          seen.add(a.invoiceId);
          if (a.fcAmount > o.fcOutstanding + 0.005) throw badRequest(`Only ${o.fcOutstanding} ${b.currency} is due on ${o.number}.`, { [`allocations.${i}.fcAmount`]: `At most ${o.fcOutstanding}` });
          return { invoiceId: a.invoiceId, fc: a.fcAmount };
        });
        if (plan.reduce((s, a) => s + a.fc, 0) > b.fcAmount + 0.005) throw badRequest('Allocations exceed the amount.', { allocations: 'More than the amount' });
      } else {
        let left = b.fcAmount; plan = [];
        for (const o of open) {
          if (left <= 0.00001) break;
          const take = Math.min(left, o.fcOutstanding);
          plan.push({ invoiceId: o.invoiceId, fc: take }); left -= take;
        }
      }
      const inrReceived = round2(b.fcAmount * b.rate);
      const allocRows = plan.map((a) => {
        const o = open.find((x) => x.invoiceId === a.invoiceId)!;
        const clearsAll = a.fc >= o.fcOutstanding - 0.005;
        const cleared = clearsAll ? o.inrOutstanding : Math.min(o.inrOutstanding, round2(a.fc * o.rate));
        return { ...a, cleared };
      });
      const allocatedFc = allocRows.reduce((s, a) => s + a.fc, 0);
      const advanceInr = round2(Math.max(0, b.fcAmount - allocatedFc) * b.rate);
      const inrCleared = round2(allocRows.reduce((s, a) => s + a.cleared, 0) + advanceInr);
      const gainLoss = round2(inrReceived - inrCleared);

      const number = await nextNumber(tx, ctx, 'receipt', financialYear(date));
      const pay = await tx.insertInto('payments').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: 'receipt', number, payment_date: date, party_id: party.id, account_id: account.id,
        mode: b.mode, reference: b.reference ?? null, amount: inrCleared, tds_amount: 0,
        notes: `${b.fcAmount} ${b.currency} at ${b.rate}`, created_by: ctx.userId, cancelled_at: null, cancel_reason: null,
      }).returning('id').executeTakeFirstOrThrow();
      if (allocRows.length) {
        await tx.insertInto('payment_allocations').values(allocRows.map((a) => ({ tenant_id: ctx.tenantId, payment_id: pay.id, doc_type: 'invoice' as const, doc_id: a.invoiceId, amount: a.cleared }))).execute();
        for (const a of allocRows) await tx.updateTable('invoices').set((eb) => ({ amount_paid: eb('amount_paid', '+', a.cleared) })).where('id', '=', a.invoiceId).execute();
      }
      await db(tx).insertInto('fx_receipts').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, payment_id: pay.id, currency_code: b.currency, fc_amount: b.fcAmount, receipt_rate: b.rate, inr_received: inrReceived, inr_cleared: inrCleared, gain_loss: gainLoss }).execute();
      if (allocRows.length) {
        await db(tx).insertInto('fx_receipt_lines').values(allocRows.map((a) => ({ tenant_id: ctx.tenantId, payment_id: pay.id, invoice_id: a.invoiceId, fc_amount: a.fc, inr_cleared: a.cleared }))).execute();
      }
      const acc = await systemAccounts(tx, ctx);
      const fx = await fxAccount(tx, ctx);
      await postJournal(tx, auditOf(ctx), {
        date, voucherType: 'receipt', voucherId: pay.id, number,
        narration: `Received from ${party.name}: ${b.fcAmount} ${b.currency} at ${b.rate}`,
        lines: [
          { accountId: account.id, amount: inrReceived },
          { accountId: acc.receivables, amount: -inrCleared, partyId: party.id },
          { accountId: fx, amount: -gainLoss },
        ],
      });
      await writeAudit(tx, auditOf(ctx), 'payment', pay.id, 'create', null, { number, currency: b.currency, fcAmount: b.fcAmount, rate: b.rate, gainLoss });
      return { id: pay.id, number, date, partyId: party.id, amount: inrCleared, status: 'posted', fx: { currency: b.currency, fcAmount: b.fcAmount, rate: b.rate, inrReceived, inrCleared, gainLoss } };
    });
    return reply.status(201).send(out);
  });

  // Revaluation.
  app.post('/fx/revaluation/preview', async (req) => {
    const ctx = req.ctx; ctx.require('fx.view');
    const b = parse(revalBody, req.body);
    return ctx.tx((tx) => revaluationRows(tx, ctx, b.asOf, b.rates));
  });
  app.get('/fx/revaluations', async (req) => {
    const ctx = req.ctx; ctx.require('fx.view');
    return ctx.tx(async (tx) => ({
      data: (await db(tx).selectFrom('fx_revaluations').select(['id', 'as_of', 'total_adjustment', 'status', 'created_at']).where('company_id', '=', ctx.companyId).orderBy('as_of', 'desc').execute())
        .map((r) => ({ id: r.id, asOf: d10(r.as_of), totalAdjustment: Number(r.total_adjustment), status: r.status, createdAt: r.created_at })),
    }));
  });
  app.post('/fx/revaluation', async (req, reply) => {
    const ctx = req.ctx; ctx.require('fx.manage');
    const b = parse(revalBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const dup = await db(tx).selectFrom('fx_revaluations').select('id').where('company_id', '=', ctx.companyId).where('as_of', '=', b.asOf).where('status', '=', 'posted').executeTakeFirst();
      if (dup) throw conflict(`A revaluation as of ${b.asOf} is already posted.`, 'ALREADY_POSTED');
      const r = await revaluationRows(tx, ctx, b.asOf, b.rates);
      if (!r.rows.length) throw badRequest('Nothing to revalue: no open foreign invoice changes at these rates.', { asOf: 'Nothing to post' });
      const acc = await systemAccounts(tx, ctx);
      const fx = await fxAccount(tx, ctx);
      const row = await db(tx).insertInto('fx_revaluations').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, as_of: b.asOf, total_adjustment: r.total, detail: JSON.stringify(r.rows), created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const number = `REV/${b.asOf}`;
      await postJournal(tx, auditOf(ctx), {
        date: b.asOf, voucherType: 'journal', voucherId: row.id, number, narration: `Revaluation of foreign receivables as of ${b.asOf}`,
        lines: [
          ...r.rows.map((x) => ({ accountId: acc.receivables, amount: x.adjustment, partyId: x.partyId })),
          { accountId: fx, amount: -r.total },
        ],
      });
      // Journal lines for the same party are separate lines; reversed the next day so the books return to cost.
      await reverseVoucher(tx, auditOf(ctx), row.id, addDays(b.asOf, 1), `Reversal of revaluation as of ${b.asOf}`);
      await writeAudit(tx, auditOf(ctx), 'fx_revaluation', row.id, 'create', null, { asOf: b.asOf, total: r.total });
      return { id: row.id, asOf: b.asOf, totalAdjustment: r.total, reversedOn: addDays(b.asOf, 1), rows: r.rows };
    });
    return reply.status(201).send(out);
  });

  // TCS.
  app.get('/tcs/natures', async (req) => {
    const ctx = req.ctx; ctx.require('tcs.view', 'fx.view', 'invoices.create');
    return ctx.tx(async (tx) => {
      await ensureNatures(tx, ctx);
      return { data: (await db(tx).selectFrom('tcs_natures').selectAll().where('company_id', '=', ctx.companyId).orderBy('label').execute()).map(natureJson) };
    });
  });
  app.post('/tcs/natures', async (req, reply) => {
    const ctx = req.ctx; ctx.require('tcs.manage');
    const b = parse(natureBody, req.body);
    const r = await ctx.tx(async (tx) => {
      const dup = await db(tx).selectFrom('tcs_natures').select('id').where('company_id', '=', ctx.companyId).where('code', '=', b.code).executeTakeFirst();
      if (dup) throw conflict('That code is already used.', 'DUPLICATE');
      return db(tx).insertInto('tcs_natures').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, code: b.code, label: b.label, section_old: b.sectionOld, section_new: b.sectionNew ?? null, rate: b.rate, threshold: b.threshold ?? 0 }).returningAll().executeTakeFirstOrThrow();
    });
    return reply.status(201).send(natureJson(r));
  });
  app.patch<{ Params: { id: string } }>('/tcs/natures/:id', async (req) => {
    const ctx = req.ctx; ctx.require('tcs.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(naturePatch, req.body);
    return ctx.tx(async (tx) => {
      const set: Record<string, unknown> = {};
      if (b.code !== undefined) set.code = b.code;
      if (b.label !== undefined) set.label = b.label;
      if (b.sectionOld !== undefined) set.section_old = b.sectionOld;
      if (b.sectionNew !== undefined) set.section_new = b.sectionNew;
      if (b.rate !== undefined) set.rate = b.rate;
      if (b.threshold !== undefined) set.threshold = b.threshold;
      if (b.isActive !== undefined) set.is_active = b.isActive;
      if (!Object.keys(set).length) throw badRequest('Nothing to change.');
      const r = await db(tx).updateTable('tcs_natures').set(set).where('id', '=', id).where('company_id', '=', ctx.companyId).returningAll().executeTakeFirst();
      if (!r) throw notFound('TCS nature');
      await writeAudit(tx, auditOf(ctx), 'tcs_nature', id, 'update', null, set);
      return natureJson(r);
    });
  });
  const putItemTcs = async (req: any) => {
    const ctx = req.ctx as RequestContext; ctx.require('tcs.manage');
    const itemId = parse(z.uuid(), req.params.itemId);
    const b = parse(z.object({ natureId: z.uuid().nullable() }), req.body);
    return ctx.tx(async (tx) => {
      const it = await tx.selectFrom('items').select('id').where('id', '=', itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!it) throw notFound('Item');
      await db(tx).deleteFrom('item_tcs').where('item_id', '=', itemId).execute();
      if (b.natureId) {
        const n = await db(tx).selectFrom('tcs_natures').select('id').where('id', '=', b.natureId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!n) throw badRequest('TCS nature not found.', { natureId: 'Not found' });
        await db(tx).insertInto('item_tcs').values({ tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: itemId, tcs_nature_id: b.natureId }).execute();
      }
      return { itemId, natureId: b.natureId };
    });
  };
  app.put('/tcs/items/:itemId', putItemTcs);
  app.patch('/tcs/items/:itemId', putItemTcs);
  app.get('/tcs/items', async (req) => {
    const ctx = req.ctx; ctx.require('tcs.view');
    return ctx.tx(async (tx) => ({
      data: (await db(tx).selectFrom('item_tcs').select(['item_id', 'tcs_nature_id']).where('company_id', '=', ctx.companyId).execute()).map((r) => ({ itemId: r.item_id, natureId: r.tcs_nature_id })),
    }));
  });

  app.get('/tcs/report', async (req) => {
    const ctx = req.ctx; ctx.require('tcs.view');
    const q = parse(reportQuery, req.query);
    return ctx.tx(async (tx) => {
      const rows = await db(tx).selectFrom('invoice_ext as e').innerJoin('invoices as i', 'i.id', 'e.invoice_id').innerJoin('parties as p', 'p.id', 'i.party_id')
        .select(['i.id', 'i.number', 'i.invoice_date', 'p.name', 'p.pan', 'e.tcs_section', 'e.tcs_rate', 'e.tcs_base', 'e.tcs_amount'])
        .where('i.company_id', '=', ctx.companyId).where('i.status', '=', 'posted').where('e.tcs_amount', '>', 0)
        .where('i.invoice_date', '>=', q.from).where('i.invoice_date', '<=', q.to).orderBy('i.invoice_date').orderBy('i.number').execute();
      const data = rows.map((r) => ({ invoiceId: r.id, number: r.number, date: d10(r.invoice_date), partyName: r.name, pan: r.pan ?? null, section: r.tcs_section, rate: Number(r.tcs_rate), base: Number(r.tcs_base), tcs: Number(r.tcs_amount) }));
      const bySection = new Map<string, { section: string; base: number; tcs: number }>();
      for (const r of data) {
        const s = bySection.get(r.section) ?? { section: r.section, base: 0, tcs: 0 };
        s.base = round2(s.base + r.base); s.tcs = round2(s.tcs + r.tcs); bySection.set(r.section, s);
      }
      return { from: q.from, to: q.to, data, totals: [...bySection.values()], total: round2(data.reduce((s, r) => s + r.tcs, 0)), missingPan: data.filter((r) => !r.pan).length };
    });
  });
}
