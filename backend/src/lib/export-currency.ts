import type { Kysely } from 'kysely';
import { z } from 'zod';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest } from './errors.ts';
import { isValidDate } from './dates.ts';
import { optionalText } from './india.ts';

/**
 * Export / SEZ invoices, foreign-currency invoices and TCS on sales: the parts that plug into invoice creation.
 * Tables are new (migration 056) and read through an untyped handle. Routes live in modules/export-currency.ts.
 */

export const db = (tx: Tx) => tx as unknown as Kysely<any>;
export const round2 = (n: number) => Math.round(n * 100) / 100;

export const CATEGORIES = ['export_igst', 'export_lut', 'sez_igst', 'sez_lut', 'deemed'] as const;
export type Category = (typeof CATEGORIES)[number];
export const CATEGORY_LABEL: Record<Category, string> = {
  export_igst: 'Export with payment of IGST', export_lut: 'Export under LUT, without payment of tax',
  sez_igst: 'Supply to SEZ with payment of IGST', sez_lut: 'Supply to SEZ under LUT, without payment of tax',
  deemed: 'Deemed export',
};

/** Rule 46 (third proviso) endorsements, CBIC text. */
export const DECLARATION_WITH_TAX = 'SUPPLY MEANT FOR EXPORT/SUPPLY TO SEZ UNIT OR SEZ DEVELOPER FOR AUTHORISED OPERATIONS ON PAYMENT OF INTEGRATED TAX';
export const DECLARATION_LUT = 'SUPPLY MEANT FOR EXPORT/SUPPLY TO SEZ UNIT OR SEZ DEVELOPER FOR AUTHORISED OPERATIONS UNDER BOND OR LETTER OF UNDERTAKING WITHOUT PAYMENT OF INTEGRATED TAX';
export const declarationFor = (c: Category | null) =>
  c === 'export_igst' || c === 'sez_igst' ? DECLARATION_WITH_TAX : c === 'export_lut' || c === 'sez_lut' ? DECLARATION_LUT : null;

const isLut = (c: Category | null) => c === 'export_lut' || c === 'sez_lut';
const isForeignSupply = (c: Category | null) => c !== null && c !== 'deemed';

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');

/** Optional fields merged into the invoice create body. */
export const extShape = {
  exportInfo: z.object({
    category: z.enum(CATEGORIES),
    shippingBillNo: optionalText(30),
    shippingBillDate: dateField.nullable().optional(),
    portCode: optionalText(10),
    country: optionalText(60),
  }).optional(),
  /** Foreign currency: line rates are in this currency; `rate` is rupees per unit (taken from the rate table when left out). */
  currency: z.object({
    code: z.string().regex(/^[A-Z]{3}$/, 'Three capital letters'),
    rate: z.coerce.number().positive().max(1e6).optional(),
  }).optional(),
  tcs: z.object({ natureId: z.uuid().optional(), off: z.boolean().optional() }).optional(),
};
export interface ExtInput {
  exportInfo?: { category: Category; shippingBillNo?: string | null; shippingBillDate?: string | null; portCode?: string | null; country?: string | null };
  currency?: { code: string; rate?: number };
  tcs?: { natureId?: string; off?: boolean };
}

export interface ExtPlan {
  category: Category | null;
  noTax: boolean;
  forceInter: boolean;
  placeOfSupply: string | null;
  export: ExtInput['exportInfo'] | null;
  lutId: string | null;
  fx: { code: string; rate: number; decimals: number } | null;
  tcs: { natureId: string; section: string; rate: number; threshold: number; onlyItems: Set<string> | null; base: 'taxable' | 'total' } | null;
}
export const emptyPlan = (): ExtPlan => ({ category: null, noTax: false, forceInter: false, placeOfSupply: null, export: null, lutId: null, fx: null, tcs: null });

export async function settingsOf(tx: Tx, ctx: { companyId: string }) {
  const r = await db(tx).selectFrom('export_settings').selectAll().where('company_id', '=', ctx.companyId).executeTakeFirst();
  return { tcsEnabled: r?.tcs_enabled === true, tcsBase: (r?.tcs_base ?? 'taxable') as 'taxable' | 'total' };
}

/** The rate for a currency on or before a date, or null. */
export async function rateOn(tx: Tx, companyId: string, code: string, date: string) {
  const r = await db(tx).selectFrom('exchange_rates').select(['rate', 'rate_date', 'note']).where('company_id', '=', companyId)
    .where('currency_code', '=', code).where('rate_date', '<=', date).orderBy('rate_date', 'desc').limit(1).executeTakeFirst();
  return r ? { rate: Number(r.rate), date: String(r.rate_date).slice(0, 10), note: r.note as string | null } : null;
}

/** Finds the LUT whose validity covers the date. */
export async function lutFor(tx: Tx, companyId: string, date: string) {
  return db(tx).selectFrom('export_luts').selectAll().where('company_id', '=', companyId)
    .where('valid_from', '<=', date).where('valid_to', '>=', date).orderBy('valid_to', 'desc').limit(1).executeTakeFirst();
}

/**
 * Checks the export, currency and TCS choices of an invoice. Saves nothing. `items` are the lines' item ids
 * (TCS may be set per item).
 */
export async function resolveExt(
  tx: Tx, ctx: RequestContext, input: ExtInput,
  p: { party: { id: string; gstin: string | null; state_code: string | null }; invoiceDate: string; itemIds: string[] },
): Promise<ExtPlan> {
  const plan = emptyPlan();
  const ex = input.exportInfo;
  if (ex) {
    plan.category = ex.category;
    plan.export = ex;
    if ((ex.category === 'sez_igst' || ex.category === 'sez_lut') && !p.party.gstin) {
      throw badRequest('A supply to an SEZ needs the SEZ unit GSTIN on the customer.', { exportInfo: 'Customer has no GSTIN' });
    }
    if (isLut(ex.category)) {
      const lut = await lutFor(tx, ctx.companyId, p.invoiceDate);
      if (!lut) {
        throw badRequest('There is no valid Letter of Undertaking for this invoice date. Add the LUT number and validity in export settings, or choose export with payment of IGST.',
          { exportInfo: 'No valid LUT' });
      }
      plan.lutId = lut.id as string;
      plan.noTax = true;
    }
    if (ex.category === 'export_igst' || ex.category === 'export_lut') plan.placeOfSupply = '96';
    if (isForeignSupply(ex.category)) plan.forceInter = true;
  }
  if (input.currency && input.currency.code !== 'INR') {
    const cur = await db(tx).selectFrom('currencies').select(['decimals', 'is_active']).where('company_id', '=', ctx.companyId)
      .where('code', '=', input.currency.code).executeTakeFirst();
    if (!cur || !cur.is_active) throw badRequest(`Add ${input.currency.code} under currencies first.`, { 'currency.code': 'Unknown currency' });
    let rate = input.currency.rate;
    if (rate === undefined) {
      const found = await rateOn(tx, ctx.companyId, input.currency.code, p.invoiceDate);
      if (!found) throw badRequest(`No exchange rate for ${input.currency.code} on or before ${p.invoiceDate}. Enter one.`, { 'currency.rate': 'Missing' });
      rate = found.rate;
    }
    plan.fx = { code: input.currency.code, rate, decimals: Number(cur.decimals) };
  }
  if (input.tcs?.off !== true) plan.tcs = await resolveTcs(tx, ctx, input, p);
  return plan;
}

async function resolveTcs(
  tx: Tx, ctx: RequestContext, input: ExtInput, p: { party: { id: string }; itemIds: string[] },
): Promise<ExtPlan['tcs']> {
  const s = await settingsOf(tx, ctx);
  if (!s.tcsEnabled) return null;
  let natureId = input.tcs?.natureId ?? null;
  let onlyItems: Set<string> | null = null;
  if (!natureId) {
    const ps = await db(tx).selectFrom('party_trade_settings').select(['tcs_nature_id', 'tcs_exempt']).where('party_id', '=', p.party.id).executeTakeFirst();
    if (ps?.tcs_exempt) return null;
    natureId = (ps?.tcs_nature_id as string | null) ?? null;
  }
  if (!natureId) {
    const rows = await db(tx).selectFrom('item_tcs').select(['item_id', 'tcs_nature_id']).where('item_id', 'in', p.itemIds.length ? p.itemIds : ['00000000-0000-0000-0000-000000000000']).execute();
    const natures = [...new Set(rows.map((r) => r.tcs_nature_id as string))];
    if (natures.length > 1) throw badRequest('Items on this invoice have different TCS natures. Bill them on separate invoices or choose one nature.', { tcs: 'Mixed natures' });
    if (natures.length === 1) { natureId = natures[0]!; onlyItems = new Set(rows.map((r) => r.item_id as string)); }
  }
  if (!natureId) return null;
  const n = await db(tx).selectFrom('tcs_natures').selectAll().where('id', '=', natureId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!n || !n.is_active) throw badRequest('TCS nature not found.', { 'tcs.natureId': 'Not found' });
  let rate = Number(n.rate);
  const pan = await db(tx).selectFrom('parties').select('pan').where('id', '=', p.party.id).executeTakeFirst().catch(() => undefined);
  // Section 206CC: collect at twice the rate, or 5%, whichever is higher, when the buyer has no PAN.
  if (pan && !pan.pan) rate = Math.max(rate * 2, 5);
  return { natureId, section: n.section_old as string, rate, threshold: Number(n.threshold), onlyItems, base: s.tcsBase };
}

/** TCS in whole rupees on the lines it applies to (section 288B rounding). */
export function tcsOn(plan: ExtPlan, lines: { itemId: string; taxable: number; total: number }[]) {
  const t = plan.tcs;
  if (!t) return { amount: 0, base: 0 };
  const sel = lines.filter((l) => !t.onlyItems || t.onlyItems.has(l.itemId));
  const base = round2(sel.reduce((s, l) => s + (t.base === 'total' ? l.total : l.taxable), 0));
  if (base <= 0 || base < t.threshold) return { amount: 0, base };
  return { amount: Math.round(base * t.rate / 100), base };
}

/** Rupee rate of a line in a foreign currency, rounded to paise. */
export const toInrRate = (plan: ExtPlan, rate: number | undefined, fallback: number) =>
  rate === undefined ? fallback : plan.fx ? round2(rate * plan.fx.rate) : rate;

/** Finds an account by name, or creates it on the first free code. */
async function ensureAccount(tx: Tx, who: { tenantId: string; companyId: string }, name: string, type: string, subtype: string, codes: string[]): Promise<string> {
  const q = db(tx);
  const found = await q.selectFrom('accounts').select('id').where('company_id', '=', who.companyId).where('name', '=', name).executeTakeFirst();
  if (found) return found.id as string;
  const used = new Set((await q.selectFrom('accounts').select('code').where('company_id', '=', who.companyId).execute()).map((r) => r.code as string));
  let code = codes.find((c) => !used.has(c));
  if (!code) { let n = Number(codes[0]); while (used.has(String(n))) n += 1; code = String(n); }
  const row = await q.insertInto('accounts').values({
    tenant_id: who.tenantId, company_id: who.companyId, code, name, type, subtype, is_system: false,
  }).returning('id').executeTakeFirstOrThrow();
  return row.id as string;
}
export const challanAccount = (tx: Tx, who: { tenantId: string; companyId: string }) => ensureAccount(tx, who, 'Stock out on Challan', 'asset', 'inventory', ['1215', '1216']);
export const fxAccount = (tx: Tx, who: { tenantId: string; companyId: string }) => ensureAccount(tx, who, 'Exchange Rate Gain or Loss', 'expense', 'other', ['5930', '5931']);
export const tcsPayableAccount = (tx: Tx, who: { tenantId: string; companyId: string }) => ensureAccount(tx, who, 'TCS Payable', 'liability', 'tax', ['2150', '2151']);

export interface SavedExt {
  category: Category | null; lutId: string | null; shippingBillNo: string | null; shippingBillDate: string | null; portCode: string | null; country: string | null;
  currencyCode: string | null; exchangeRate: number | null; fcTotal: number | null; tcsSection: string | null; tcsRate: number | null; tcsBase: number | null; tcsAmount: number;
  declaration: string | null; lutNo: string | null;
}

export async function saveExt(
  tx: Tx, ctx: RequestContext, invoiceId: string, plan: ExtPlan, figures: { total: number; tcsAmount: number; tcsBase: number },
) {
  if (!plan.category && !plan.fx && !figures.tcsAmount) return;
  const fcTotal = plan.fx ? Math.round(figures.total / plan.fx.rate * 10_000) / 10_000 : null;
  await db(tx).insertInto('invoice_ext').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, invoice_id: invoiceId, category: plan.category, lut_id: plan.lutId,
    shipping_bill_no: plan.export?.shippingBillNo ?? null, shipping_bill_date: plan.export?.shippingBillDate ?? null,
    port_code: plan.export?.portCode ?? null, country: plan.export?.country ?? null,
    currency_code: plan.fx?.code ?? null, exchange_rate: plan.fx?.rate ?? null, fc_total: fcTotal,
    tcs_nature_id: figures.tcsAmount ? plan.tcs!.natureId : null, tcs_section: figures.tcsAmount ? plan.tcs!.section : null,
    tcs_rate: figures.tcsAmount ? plan.tcs!.rate : null, tcs_base: figures.tcsAmount ? figures.tcsBase : null, tcs_amount: figures.tcsAmount,
  }).execute();
}

export async function loadExt(tx: Tx, invoiceId: string): Promise<SavedExt | null> {
  const r = await db(tx).selectFrom('invoice_ext as e').leftJoin('export_luts as l', 'l.id', 'e.lut_id')
    .select(['e.category', 'e.lut_id', 'e.shipping_bill_no', 'e.shipping_bill_date', 'e.port_code', 'e.country', 'e.currency_code', 'e.exchange_rate',
      'e.fc_total', 'e.tcs_section', 'e.tcs_rate', 'e.tcs_base', 'e.tcs_amount', 'l.lut_no'])
    .where('e.invoice_id', '=', invoiceId).executeTakeFirst();
  if (!r) return null;
  const n = (v: unknown) => (v === null || v === undefined ? null : Number(v));
  return {
    category: r.category, lutId: r.lut_id, shippingBillNo: r.shipping_bill_no, shippingBillDate: r.shipping_bill_date ? String(r.shipping_bill_date).slice(0, 10) : null,
    portCode: r.port_code, country: r.country, currencyCode: r.currency_code, exchangeRate: n(r.exchange_rate), fcTotal: n(r.fc_total),
    tcsSection: r.tcs_section, tcsRate: n(r.tcs_rate), tcsBase: n(r.tcs_base), tcsAmount: Number(r.tcs_amount ?? 0),
    declaration: declarationFor(r.category), lutNo: r.lut_no ?? null,
  };
}

/** Export and SEZ rows of the invoices, for GSTR-1 and GSTR-3B. */
export async function exportKinds(tx: Tx, companyId: string, invoiceIds: string[]) {
  const map = new Map<string, { category: Category; shippingBillNo: string | null; shippingBillDate: string | null; portCode: string | null }>();
  if (!invoiceIds.length) return map;
  const rows = await db(tx).selectFrom('invoice_ext').select(['invoice_id', 'category', 'shipping_bill_no', 'shipping_bill_date', 'port_code'])
    .where('company_id', '=', companyId).where('invoice_id', 'in', invoiceIds).where('category', 'is not', null).execute();
  for (const r of rows) {
    map.set(r.invoice_id, { category: r.category, shippingBillNo: r.shipping_bill_no, shippingBillDate: r.shipping_bill_date ? String(r.shipping_bill_date).slice(0, 10) : null, portCode: r.port_code });
  }
  return map;
}
export const isExportOrSez = (c: Category) => c !== 'deemed';
