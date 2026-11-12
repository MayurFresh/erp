import type { FastifyInstance } from 'fastify';
import type { AppDeps } from '../app.ts';
import { sql } from 'kysely';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { lockItems } from '../accounting/costing.ts';
import { postJournal } from '../accounting/journal.ts';
import { contextFor, type RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { assertPeriodOpen } from '../accounting/journal.ts';
import { isValidDate, todayIst } from '../lib/dates.ts';
import { AppError, badRequest, conflict, notFound } from '../lib/errors.ts';
import { validateCustom, customFieldDefs, type CustomEntity } from '../lib/custom-fields.ts';
import { gstin as gstinField, stateCode as stateField } from '../lib/india.ts';
import { enqueue, registerJobHandler } from '../lib/jobs.ts';
import { notify } from '../lib/notify.ts';
import { moneyField, percentField, qtyField } from '../lib/numbers.ts';
import { pagingQuery } from '../lib/paging.ts';
import { assertGstRates } from '../lib/rates.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { documentRoute } from '../lib/openapi.ts';

type Kind = 'items' | 'parties' | 'opening_stock' | 'account_balances';
const KINDS = ['items', 'parties', 'opening_stock', 'account_balances'] as const;
const KIND_PERMISSION: Record<Kind, string> = {
  items: 'items.create', parties: 'parties.create', opening_stock: 'stock.adjust', account_balances: 'accounts.journal',
};
const MAX_ROWS = 5000;
const MAX_BYTES = 2 * 1024 * 1024;
const round2 = (n: number) => Math.round(n * 100) / 100;

const TEMPLATES: Record<Kind, string> = {
  items: 'name,sku,hsn,unit,gstRate,salePrice,purchasePrice,trackStock,reorderLevel\n'
    + 'Steel rod 12mm,STL-12,7214,kg,18,72,60,yes,50\nSite inspection,,9983,hr,18,1500,0,no,0\n',
  parties: 'type,name,gstin,stateCode,pan,phone,email,address,pincode,creditLimit,creditDays,openingBalance,openingType\n'
    + 'customer,Sharma Traders,,27,,9820012345,sharma@example.com,"12 MG Road, Pune",411001,100000,30,25000,dr\n'
    + 'vendor,Bharat Steels,,29,,,,,560001,0,45,,\n',
  opening_stock: 'sku,itemName,locationCode,qty,rate\nSTL-12,,MAIN,100,60\n,Cement 50kg bag,MAIN,40,310\n',
  account_balances: 'accountCode,debit,credit\n1010,50000,\n3000,,50000\n',
};

// ---- CSV ----------------------------------------------------------------------------------------------

/** Parses CSV or tab-separated text; the delimiter comes from the header row. Blank lines are skipped. */
export function parseCsv(text: string): string[][] {
  const src = text.replace(/^﻿/, '');
  const firstLine = src.split(/\r?\n/, 1)[0] ?? '';
  let inQ = false; let commas = 0; let tabs = 0;
  for (const ch of firstLine) {
    if (ch === '"') inQ = !inQ;
    else if (!inQ && ch === ',') commas++;
    else if (!inQ && ch === '\t') tabs++;
  }
  const delim = tabs > commas ? '\t' : ',';
  const rows: string[][] = [];
  let row: string[] = []; let cell = ''; inQ = false;
  const endRow = () => {
    row.push(cell); cell = '';
    if (row.some((c) => c.trim() !== '')) rows.push(row);
    row = [];
  };
  for (let i = 0; i < src.length; i++) {
    const ch = src[i]!;
    if (inQ) {
      if (ch === '"') { if (src[i + 1] === '"') { cell += '"'; i++; } else inQ = false; } else cell += ch;
    } else if (ch === '"' && cell === '') inQ = true;
    else if (ch === delim) { row.push(cell); cell = ''; }
    else if (ch === '\n') endRow();
    else if (ch !== '\r') cell += ch;
  }
  if (cell !== '' || row.length) endRow();
  return rows;
}

const norm = (h: string) => h.trim().toLowerCase().replace(/[\s_-]+/g, '');

// ---- Analysis ----------------------------------------------------------------------------------------

interface ImportError { row: number; column: string | null; message: string }
interface Options { asOf: string | null; updateExisting: boolean }
interface Plan { action: 'create' | 'update' | 'skip'; data: Record<string, unknown> }
interface Analysis { totalRows: number; validRows: number; errors: ImportError[]; plans: Plan[]; preview: object[] }

const yes = new Set(['yes', 'y', 'true', '1']);
const no = new Set(['no', 'n', 'false', '0']);

class Rows {
  errors: ImportError[] = [];
  bad = new Set<number>();
  readonly records: Record<string, string>[];
  constructor(records: Record<string, string>[]) { this.records = records; }
  err(row: number, column: string | null, message: string) { this.errors.push({ row, column, message }); this.bad.add(row); }
  get(r: Record<string, string>, col: string): string { return (r[norm(col)] ?? '').trim(); }
  /** Validates a cell with a zod schema; blank cells give undefined. */
  field<T>(row: number, r: Record<string, string>, col: string, schema: z.ZodType<T>): T | undefined {
    const v = this.get(r, col);
    if (v === '') return undefined;
    const res = schema.safeParse(v.replace(/,/g, '') === v || !/^[\d,.]+$/.test(v) ? v : v.replace(/,/g, ''));
    if (!res.success) { this.err(row, col, res.error.issues[0]?.message ?? 'Invalid'); return undefined; }
    return res.data;
  }
  required(row: number, r: Record<string, string>, col: string): string {
    const v = this.get(r, col);
    if (!v) this.err(row, col, 'Required');
    return v;
  }
  dup(seen: Set<string>, key: string, row: number, col: string) {
    if (seen.has(key)) this.err(row, col, 'Duplicate of an earlier row in this file');
    seen.add(key);
  }
}

function finish(rows: Rows, plans: Plan[], previewOf: (p: Plan) => object): Analysis {
  return {
    totalRows: rows.records.length, validRows: rows.records.length - rows.bad.size, errors: rows.errors, plans,
    preview: plans.slice(0, 20).map(previewOf),
  };
}

async function customOf(
  tx: Tx, ctx: RequestContext, rows: Rows, n: number, r: Record<string, string>, entity: CustomEntity,
  existing?: Record<string, string | number | boolean>,
): Promise<Record<string, string | number | boolean>> {
  const input: Record<string, string> = {};
  for (const [h, v] of Object.entries(r)) if (h.startsWith('custom.') && v.trim() !== '') input[h.slice(7)] = v.trim();
  const defs = await customFieldDefs(tx, ctx.companyId, entity);
  const typed: Record<string, string | number | boolean | null> = {};
  for (const [k, v] of Object.entries(input)) {
    const def = defs.find((d) => d.key.toLowerCase() === k);
    const key = def?.key ?? k;
    typed[key] = def?.type === 'number' ? (Number.isNaN(Number(v)) ? v : Number(v)) : def?.type === 'boolean' ? (yes.has(v.toLowerCase()) ? true : no.has(v.toLowerCase()) ? false : v) : v;
  }
  try {
    return await validateCustom(tx, ctx.companyId, entity, typed, existing);
  } catch (e) {
    if (e instanceof AppError) {
      const det = (e.details ?? {}) as Record<string, string>;
      const entries = Object.entries(det);
      for (const [k, m] of entries.length ? entries : [[`custom.`, e.message] as [string, string]]) rows.err(n, k, m);
      return existing ?? {};
    }
    throw e;
  }
}

async function analyseItems(tx: Tx, ctx: RequestContext, rows: Rows, opts: Options): Promise<Analysis> {
  const existing = await tx.selectFrom('items').selectAll().where('company_id', '=', ctx.companyId).execute();
  const bySku = new Map(existing.filter((i) => i.sku).map((i) => [i.sku!.toLowerCase(), i]));
  const byName = new Map(existing.map((i) => [i.name.toLowerCase(), i]));
  const seen = new Set<string>();
  const rateOk = new Map<string, string | null>();
  const plans: Plan[] = [];
  for (const [idx, r] of rows.records.entries()) {
    const n = idx + 1;
    const name = rows.required(n, r, 'name');
    const sku = rows.get(r, 'sku');
    const unit = rows.required(n, r, 'unit');
    const hsn = rows.field(n, r, 'hsn', z.string().regex(/^\d{4,8}$/, 'HSN/SAC must be 4–8 digits'));
    const gstRate = rows.field(n, r, 'gstRate', percentField);
    if (rows.get(r, 'gstRate') === '') rows.err(n, 'gstRate', 'Required');
    const salePrice = rows.field(n, r, 'salePrice', moneyField);
    const purchasePrice = rows.field(n, r, 'purchasePrice', moneyField);
    const reorder = rows.field(n, r, 'reorderLevel', qtyField.refine((v) => v >= 0, 'Cannot be negative'));
    const ts = rows.get(r, 'trackStock').toLowerCase();
    if (ts && !yes.has(ts) && !no.has(ts)) rows.err(n, 'trackStock', 'Use yes or no');
    const trackStock = ts ? yes.has(ts) : undefined;
    if (name) rows.dup(seen, sku ? `s:${sku.toLowerCase()}` : `n:${name.toLowerCase()}`, n, sku ? 'sku' : 'name');
    if (gstRate !== undefined) {
      const k = `${gstRate}|${hsn ?? ''}`;
      if (!rateOk.has(k)) {
        try { await assertGstRates(tx, opts.asOf ?? todayIst(), [{ rate: gstRate, hsn: hsn ?? null, field: 'gstRate' }]); rateOk.set(k, null); }
        catch (e) { rateOk.set(k, e instanceof AppError ? e.message : 'Invalid GST rate'); }
      }
      if (rateOk.get(k)) rows.err(n, 'gstRate', rateOk.get(k)!);
    }
    const match = (sku ? bySku.get(sku.toLowerCase()) : undefined) ?? (name ? byName.get(name.toLowerCase()) : undefined);
    if (match && !opts.updateExisting) rows.err(n, sku ? 'sku' : 'name', 'Already exists');
    const custom = await customOf(tx, ctx, rows, n, r, 'item', match && opts.updateExisting ? match.custom : undefined);
    const data: Record<string, unknown> = {
      name, sku: sku || null, hsn_code: hsn ?? null, unit, gst_rate: gstRate, sale_price: salePrice, purchase_price: purchasePrice,
      track_stock: trackStock, reorder_level: reorder, custom,
    };
    plans.push(match && opts.updateExisting ? { action: 'update', data: { ...data, id: match.id } } : { action: 'create', data });
  }
  return finish(rows, plans, (p) => ({ action: p.action, name: p.data.name, sku: p.data.sku, unit: p.data.unit, gstRate: p.data.gst_rate, salePrice: p.data.sale_price }));
}

async function analyseParties(tx: Tx, ctx: RequestContext, rows: Rows, opts: Options): Promise<Analysis> {
  const existing = await tx.selectFrom('parties').selectAll().where('company_id', '=', ctx.companyId).execute();
  const withOpening = new Set((await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select('jl.party_id').where('je.company_id', '=', ctx.companyId).where('je.voucher_type', '=', 'opening').where('jl.party_id', 'is not', null)
    .execute()).map((x) => x.party_id!));
  const seen = new Set<string>();
  const plans: Plan[] = [];
  for (const [idx, r] of rows.records.entries()) {
    const n = idx + 1;
    const type = rows.get(r, 'type').toLowerCase();
    if (!['customer', 'vendor', 'both'].includes(type)) rows.err(n, 'type', 'Use customer, vendor or both');
    const name = rows.required(n, r, 'name');
    const g = rows.field(n, r, 'gstin', gstinField);
    let state = rows.field(n, r, 'stateCode', stateField);
    if (g && state && g.slice(0, 2) !== state) rows.err(n, 'stateCode', 'Does not match GSTIN');
    state = state ?? g?.slice(0, 2);
    const pan = rows.field(n, r, 'pan', z.string().regex(/^[A-Z]{5}[0-9]{4}[A-Z]$/, 'Not a valid PAN'));
    const email = rows.field(n, r, 'email', z.email());
    const pincode = rows.field(n, r, 'pincode', z.string().regex(/^\d{6}$/, 'Pincode is 6 digits'));
    const creditLimit = rows.field(n, r, 'creditLimit', moneyField);
    const creditDays = rows.field(n, r, 'creditDays', z.coerce.number().int().min(0).max(365));
    const opening = rows.field(n, r, 'openingBalance', moneyField);
    const ot = rows.get(r, 'openingType').toLowerCase();
    if (opening && opening > 0 && !['dr', 'cr'].includes(ot)) rows.err(n, 'openingType', 'Use dr or cr');
    if (opening && opening > 0 && !opts.asOf) rows.err(n, 'openingBalance', 'Set the as-of date for opening balances');
    const phone = rows.get(r, 'phone'); const address = rows.get(r, 'address');
    if (name) rows.dup(seen, g ? `g:${g}` : `n:${type}:${name.toLowerCase()}`, n, g ? 'gstin' : 'name');
    const match = (g ? existing.find((p) => p.gstin === g) : undefined)
      ?? existing.find((p) => p.name.toLowerCase() === name.toLowerCase() && p.type === type);
    if (match && !opts.updateExisting) rows.err(n, g ? 'gstin' : 'name', 'Already exists');
    if (match && opening && opening > 0 && withOpening.has(match.id)) rows.err(n, 'openingBalance', 'This party already has an opening balance');
    const custom = await customOf(tx, ctx, rows, n, r, 'party', match && opts.updateExisting ? match.custom : undefined);
    const data: Record<string, unknown> = {
      type, name, gstin: g ?? null, state_code: state ?? null, pan: pan ?? null, phone: phone || null, email: email ?? null,
      address: address || null, pincode: pincode ?? null, credit_limit: creditLimit, credit_days: creditDays, custom,
      opening: opening && opening > 0 ? { amount: opening, side: ot } : null,
    };
    plans.push(match && opts.updateExisting ? { action: 'update', data: { ...data, id: match.id } } : { action: 'create', data });
  }
  if (opts.asOf && plans.some((p) => p.data.opening)) await periodCheck(tx, ctx, rows, opts.asOf);
  return finish(rows, plans, (p) => ({ action: p.action, type: p.data.type, name: p.data.name, gstin: p.data.gstin, opening: p.data.opening }));
}

async function periodCheck(tx: Tx, ctx: RequestContext, rows: Rows, asOf: string) {
  try { await assertPeriodOpen(tx, ctx.companyId, asOf); }
  catch (e) { if (e instanceof AppError) rows.err(0, 'asOf', e.message); else throw e; }
}

async function analyseOpeningStock(tx: Tx, ctx: RequestContext, rows: Rows, opts: Options): Promise<Analysis> {
  const items = await tx.selectFrom('items').select(['id', 'name', 'sku', 'track_stock', 'unit']).where('company_id', '=', ctx.companyId).execute();
  const locs = await tx.selectFrom('locations').select(['id', 'code', 'name', 'is_active']).where('company_id', '=', ctx.companyId).execute();
  const seen = new Set<string>();
  const plans: Plan[] = [];
  for (const [idx, r] of rows.records.entries()) {
    const n = idx + 1;
    const sku = rows.get(r, 'sku'); const iname = rows.get(r, 'itemName');
    if (!sku && !iname) rows.err(n, 'sku', 'Give a sku or an itemName');
    const item = sku ? items.find((i) => i.sku?.toLowerCase() === sku.toLowerCase())
      : iname ? items.find((i) => i.name.toLowerCase() === iname.toLowerCase()) : undefined;
    if ((sku || iname) && !item) rows.err(n, sku ? 'sku' : 'itemName', 'Item not found');
    if (item && !item.track_stock) rows.err(n, sku ? 'sku' : 'itemName', 'Stock is not tracked for this item');
    const code = rows.required(n, r, 'locationCode');
    const loc = code ? locs.find((l) => l.code?.toLowerCase() === code.toLowerCase()) : undefined;
    if (code && !loc) rows.err(n, 'locationCode', 'Location not found');
    if (loc && !loc.is_active) rows.err(n, 'locationCode', 'Location is inactive');
    if (loc && !ctx.canAccessLocation(loc.id)) rows.err(n, 'locationCode', 'You do not have access to this location');
    const qty = rows.field(n, r, 'qty', qtyField.refine((v) => v > 0, 'Must be more than zero'));
    if (rows.get(r, 'qty') === '') rows.err(n, 'qty', 'Required');
    const rate = rows.field(n, r, 'rate', moneyField);
    if (rows.get(r, 'rate') === '') rows.err(n, 'rate', 'Required');
    if (item && loc) rows.dup(seen, `${item.id}|${loc.id}`, n, sku ? 'sku' : 'itemName');
    plans.push({ action: 'create', data: { itemId: item?.id, itemName: item?.name, unit: item?.unit, locationId: loc?.id, locationCode: code, qty, rate } });
  }
  if (!opts.asOf) rows.err(0, 'asOf', 'Set the as-of date');
  else await periodCheck(tx, ctx, rows, opts.asOf);
  return finish(rows, plans, (p) => ({ action: p.action, itemName: p.data.itemName, locationCode: p.data.locationCode, qty: p.data.qty, rate: p.data.rate }));
}

const REFUSED_SUBTYPES = new Set(['receivables', 'payables', 'inventory', 'tax']);

async function analyseBalances(tx: Tx, ctx: RequestContext, rows: Rows, opts: Options): Promise<Analysis> {
  const accounts = await tx.selectFrom('accounts').select(['id', 'code', 'name', 'subtype', 'system_key', 'is_active']).where('company_id', '=', ctx.companyId).execute();
  const seen = new Set<string>();
  const plans: Plan[] = [];
  for (const [idx, r] of rows.records.entries()) {
    const n = idx + 1;
    const code = rows.required(n, r, 'accountCode');
    const acc = code ? accounts.find((a) => a.code === code) : undefined;
    if (code && !acc) rows.err(n, 'accountCode', 'Account not found');
    if (acc && !acc.is_active) rows.err(n, 'accountCode', 'Account is inactive');
    if (acc && (REFUSED_SUBTYPES.has(acc.subtype) || acc.system_key === 'intercompany')) {
      rows.err(n, 'accountCode', 'Use the parties or stock import for this account');
    }
    if (acc?.system_key === 'opening_balances') rows.err(n, 'accountCode', 'Opening Balances receives the difference automatically');
    const debit = rows.field(n, r, 'debit', moneyField) ?? 0;
    const credit = rows.field(n, r, 'credit', moneyField) ?? 0;
    if ((debit > 0) === (credit > 0)) rows.err(n, 'debit', 'Enter either a debit or a credit');
    if (code) rows.dup(seen, code, n, 'accountCode');
    plans.push({ action: 'create', data: { accountId: acc?.id, accountCode: code, accountName: acc?.name, debit, credit } });
  }
  if (!opts.asOf) rows.err(0, 'asOf', 'Set the as-of date');
  else await periodCheck(tx, ctx, rows, opts.asOf);
  return finish(rows, plans, (p) => ({ action: p.action, accountCode: p.data.accountCode, accountName: p.data.accountName, debit: p.data.debit, credit: p.data.credit }));
}

export async function analyse(tx: Tx, ctx: RequestContext, kind: Kind, csv: string, opts: Options): Promise<Analysis> {
  const table = parseCsv(csv);
  if (!table.length) throw badRequest('The file is empty. The first row must be the column names.', { csv: 'Empty' });
  const header = table[0]!.map(norm);
  const body = table.slice(1);
  if (!body.length) throw badRequest('The file has no data rows.', { csv: 'No rows' });
  if (body.length > MAX_ROWS) throw badRequest(`At most ${MAX_ROWS} rows per import.`, { csv: 'Too many rows' });
  const required: Record<Kind, string[]> = {
    items: ['name', 'unit', 'gstrate'], parties: ['type', 'name'], opening_stock: ['locationcode', 'qty', 'rate'], account_balances: ['accountcode'],
  };
  const missing = required[kind].filter((c) => !header.includes(c));
  if (kind === 'opening_stock' && !header.includes('sku') && !header.includes('itemname')) missing.push('sku or itemName');
  const records = body.map((cells) => Object.fromEntries(header.map((h, i) => [h, cells[i] ?? ''])));
  const rows = new Rows(records);
  if (missing.length) {
    for (const m of missing) rows.err(0, m, 'Column is missing');
    return { totalRows: records.length, validRows: 0, errors: rows.errors, plans: [], preview: [] };
  }
  const fn = { items: analyseItems, parties: analyseParties, opening_stock: analyseOpeningStock, account_balances: analyseBalances }[kind];
  const a = await fn(tx, ctx, rows, opts);
  // File-level problems (row 0) invalidate every row.
  if (rows.errors.some((e) => e.row === 0)) a.validRows = 0;
  a.errors.sort((x, y) => x.row - y.row);
  return a;
}

// ---- Writing -----------------------------------------------------------------------------------------

interface Result { created: number; updated: number; skipped: number }

const defined = (o: Record<string, unknown>, drop: string[] = []) =>
  Object.fromEntries(Object.entries(o).filter(([k, v]) => v !== undefined && !drop.includes(k)));

async function apply(tx: Tx, ctx: RequestContext, kind: Kind, plans: Plan[], opts: Options): Promise<Result> {
  const res: Result = { created: 0, updated: 0, skipped: 0 };
  const who = auditOf(ctx);
  const acc = await systemAccounts(tx, ctx);
  if (kind === 'items') {
    for (const p of plans) {
      const d = p.data;
      if (p.action === 'update') {
        const set = defined({ ...d, sku: d.sku || undefined, hsn_code: d.hsn_code ?? undefined, updated_at: new Date() }, ['id']);
        await tx.updateTable('items').set(set).where('id', '=', d.id as string).execute();
        res.updated++;
      } else {
        await tx.insertInto('items').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, name: d.name as string, sku: d.sku as string | null,
          hsn_code: d.hsn_code as string | null, unit: d.unit as string, gst_rate: d.gst_rate as number,
          sale_price: (d.sale_price as number | undefined) ?? 0, purchase_price: (d.purchase_price as number | undefined) ?? 0,
          track_stock: (d.track_stock as boolean | undefined) ?? true, reorder_level: (d.reorder_level as number | undefined) ?? 0,
          custom: d.custom as Record<string, string | number | boolean>,
        }).execute();
        res.created++;
      }
    }
  } else if (kind === 'parties') {
    for (const p of plans) {
      const d = p.data;
      let id: string;
      if (p.action === 'update') {
        id = d.id as string;
        const set = defined({ ...d, gstin: d.gstin ?? undefined, state_code: d.state_code ?? undefined, pan: d.pan ?? undefined,
          phone: d.phone ?? undefined, email: d.email ?? undefined, address: d.address ?? undefined, pincode: d.pincode ?? undefined }, ['id', 'opening']);
        await tx.updateTable('parties').set(set).where('id', '=', id).execute();
        res.updated++;
      } else {
        const row = await tx.insertInto('parties').values({
          tenant_id: ctx.tenantId, company_id: ctx.companyId, type: d.type as string, name: d.name as string,
          gstin: d.gstin as string | null, state_code: d.state_code as string | null, phone: d.phone as string | null,
          email: d.email as string | null, address: d.address as string | null, pan: d.pan as string | null,
          pincode: d.pincode as string | null, credit_limit: (d.credit_limit as number | undefined) ?? 0,
          credit_days: (d.credit_days as number | undefined) ?? 0, udyam_no: null, msme_category: null, tds_section_id: null,
          custom: d.custom as Record<string, string | number | boolean>,
        }).returning('id').executeTakeFirstOrThrow();
        id = row.id;
        res.created++;
      }
      const op = d.opening as { amount: number; side: string } | null;
      if (op) {
        const dr = op.side === 'dr';
        await postJournal(tx, who, {
          date: opts.asOf!, voucherType: 'opening', voucherId: null, number: null, narration: `Opening balance: ${d.name}`,
          lines: dr
            ? [{ accountId: acc.receivables, amount: op.amount, partyId: id }, { accountId: acc.opening_balances, amount: -op.amount }]
            : [{ accountId: acc.opening_balances, amount: op.amount }, { accountId: acc.payables, amount: -op.amount, partyId: id }],
        });
      }
    }
  } else if (kind === 'opening_stock') {
    await lockItems(tx, ctx.companyId, [...new Set(plans.map((p) => p.data.itemId as string))]);
    for (const p of plans) {
      const d = p.data;
      const qty = d.qty as number; const rate = d.rate as number;
      const value = round2(qty * rate);
      const mv = await tx.insertInto('stock_moves').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: d.locationId as string, item_id: d.itemId as string,
        qty, rate, cost_rate: rate, value, ref_type: 'opening', ref_id: null, note: 'CSV import', created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      if (value > 0) {
        await postJournal(tx, who, {
          date: opts.asOf!, voucherType: 'stock', voucherId: mv.id, number: null,
          narration: `Opening stock: ${d.itemName} ${qty} ${d.unit}`,
          lines: [{ accountId: acc.inventory, amount: value, locationId: d.locationId as string }, { accountId: acc.opening_balances, amount: -value, locationId: d.locationId as string }],
        });
      }
      res.created++;
    }
  } else {
    const lines = plans.map((p) => ({ accountId: p.data.accountId as string, amount: round2((p.data.debit as number) - (p.data.credit as number)) }));
    const diff = round2(lines.reduce((s, l) => s + l.amount, 0));
    await postJournal(tx, who, {
      date: opts.asOf!, voucherType: 'opening', voucherId: null, number: null, narration: 'Opening balances (CSV import)',
      lines: [...lines, { accountId: acc.opening_balances, amount: -diff }],
    });
    res.created = plans.length;
  }
  return res;
}

// ---- Routes --------------------------------------------------------------------------------------------

const optionsBody = z.object({ asOf: z.string().refine(isValidDate, 'Use YYYY-MM-DD').nullable().optional(), updateExisting: z.boolean().optional() });
const createBody = z.object({
  kind: z.enum(KINDS),
  csv: z.string().min(1, 'Paste or upload the CSV'),
  fileName: z.string().trim().max(200).nullable().optional(),
  options: optionsBody.optional(),
});
const listQuery = pagingQuery;

type JobRowT = {
  id: string; kind: string; status: string; file_name: string | null; total_rows: number; valid_rows: number; errors: unknown;
  preview: unknown; options: unknown; result: unknown; error: string | null; job_id: string | null; created_by: string;
  created_by_name: string; created_at: Date; finished_at: Date | null;
};

function importJson(r: JobRowT, detail: boolean) {
  const opts = (r.options ?? {}) as Partial<Options>;
  return {
    id: r.id, kind: r.kind, status: r.status, fileName: r.file_name, totalRows: r.total_rows, validRows: r.valid_rows,
    ...(detail ? { errors: (r.errors as ImportError[]).slice(0, 200), preview: r.preview as object[] } : {}),
    options: { asOf: opts.asOf ?? null, updateExisting: opts.updateExisting ?? false },
    result: (r.result as Result | null) ?? null, error: r.error, jobId: r.job_id,
    createdBy: { id: r.created_by, name: r.created_by_name }, createdAt: r.created_at, finishedAt: r.finished_at,
  };
}

function importSelect(tx: Tx) {
  return tx.selectFrom('import_jobs as j').innerJoin('users as u', 'u.id', 'j.created_by').selectAll('j').select('u.name as created_by_name');
}

function requireKind(ctx: RequestContext, kind: Kind) {
  ctx.require('imports.run');
  ctx.require(KIND_PERMISSION[kind]);
}

// The commit job: validate again, then write all rows or none.
registerJobHandler('import.commit', async (tx, job, deps) => {
  const { importId } = job.payload as { importId: string };
  const imp = await tx.selectFrom('import_jobs').selectAll().where('id', '=', importId).forUpdate().executeTakeFirst();
  if (!imp || imp.status !== 'queued') return { skipped: true };
  const ctx = await contextFor(tx, deps.db, imp.tenant_id, imp.created_by, imp.company_id);
  const opts = { asOf: null, updateExisting: false, ...(imp.options as Partial<Options>) } as Options;
  let failure: string | null = null;
  let result: Result | null = null;
  if (!ctx) failure = 'The user no longer has access to this company.';
  else {
    const kind = imp.kind as Kind;
    const a = await analyse(tx, ctx, kind, imp.csv, opts).catch((e) => { failure = e instanceof AppError ? e.message : String(e); return null; });
    if (a && a.errors.length) failure = `The file no longer validates: ${a.errors[0]!.message}${a.errors[0]!.column ? ` (${a.errors[0]!.column}, row ${a.errors[0]!.row})` : ''}.`;
    else if (a) {
      await sql`savepoint import_apply`.execute(tx);
      try {
        result = await apply(tx, ctx, kind, a.plans, opts);
        await writeAudit(tx, auditOf(ctx), 'import_job', imp.id, 'commit', null, { kind, ...result });
      } catch (e) {
        await sql`rollback to savepoint import_apply`.execute(tx);
        failure = e instanceof AppError ? e.message : 'The import could not be saved.';
        deps.log?.error(e, 'import.commit failed');
      }
    }
  }
  await tx.updateTable('import_jobs').set({
    status: failure ? 'failed' : 'done', result: result ? JSON.stringify(result) : null, error: failure, finished_at: new Date(),
  }).where('id', '=', imp.id).execute();
  await notify(tx, { tenantId: imp.tenant_id, companyId: imp.company_id }, {
    userIds: [imp.created_by], template: 'import_finished', link: `/imports/${imp.id}`,
    data: { status: failure ? 'failed' : 'done', kind: imp.kind, created: result?.created ?? 0, updated: result?.updated ?? 0, skipped: result?.skipped ?? 0, error: failure },
  });
  return { status: failure ? 'failed' : 'done' };
});

/** CSV import (v1.7 §10). */
export async function importRoutes(app: FastifyInstance, _deps?: AppDeps): Promise<void> {
  app.get<{ Params: { kind: string } }>('/imports/templates/:kind', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('imports.run');
    const kind = parse(z.enum(KINDS), req.params.kind);
    return reply.header('content-type', 'text/csv; charset=utf-8')
      .header('content-disposition', `attachment; filename="${kind}-template.csv"`).send(TEMPLATES[kind]);
  });

  app.post('/imports', { bodyLimit: 3 * 1024 * 1024 }, async (req, reply) => {
    const ctx = req.ctx;
    const body = parse(createBody, req.body);
    requireKind(ctx, body.kind);
    if (Buffer.byteLength(body.csv) > MAX_BYTES) throw badRequest('The file is over 2 MB.', { csv: 'Too large' });
    const opts: Options = { asOf: body.options?.asOf ?? null, updateExisting: body.options?.updateExisting ?? false };
    const job = await ctx.tx(async (tx) => {
      const a = await analyse(tx, ctx, body.kind, body.csv, opts);
      const row = await tx.insertInto('import_jobs').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, kind: body.kind, status: a.errors.length ? 'invalid' : 'validated',
        file_name: body.fileName ?? null, csv: body.csv, total_rows: a.totalRows, valid_rows: a.validRows,
        errors: JSON.stringify(a.errors.slice(0, 200)), preview: JSON.stringify(a.preview), options: JSON.stringify(opts),
        result: null, error: null, job_id: null, created_by: ctx.userId, finished_at: null,
      }).returning('id').executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'import_job', row.id, 'create', null, { kind: body.kind, rows: a.totalRows, errors: a.errors.length });
      return importJson(await importSelect(tx).where('j.id', '=', row.id).executeTakeFirstOrThrow(), true);
    });
    return reply.status(201).send(job);
  });

  app.get('/imports', async (req) => {
    const ctx = req.ctx;
    ctx.require('imports.run');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      const base = tx.selectFrom('import_jobs as j').where('j.company_id', '=', ctx.companyId);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await importSelect(tx).where('j.company_id', '=', ctx.companyId)
        .orderBy('j.created_at', 'desc').orderBy('j.id').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map((r) => importJson(r, false)), total: Number(total) };
    });
  });

  app.get<{ Params: { id: string } }>('/imports/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('imports.run');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const r = await importSelect(tx).where('j.id', '=', id).where('j.company_id', '=', ctx.companyId).executeTakeFirst();
      if (!r) throw notFound('Import');
      return importJson(r, true);
    });
  });

  app.post<{ Params: { id: string } }>('/imports/:id/commit', async (req, reply) => {
    const ctx = req.ctx;
    const id = parse(z.uuid(), req.params.id);
    const job = await ctx.tx(async (tx) => {
      const r = await tx.selectFrom('import_jobs').select(['id', 'kind', 'status']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!r) throw notFound('Import');
      requireKind(ctx, r.kind as Kind);
      if (r.status !== 'validated') throw conflict('Only a validated import can be committed.', 'NOT_VALIDATED');
      const jobId = await enqueue(tx, { tenantId: ctx.tenantId, companyId: ctx.companyId, userId: ctx.userId }, 'import.commit', { importId: id }, { dedupeKey: `import:${id}`, maxAttempts: 1 });
      await tx.updateTable('import_jobs').set({ status: 'queued', job_id: jobId }).where('id', '=', id).execute();
      return importJson(await importSelect(tx).where('j.id', '=', id).executeTakeFirstOrThrow(), true);
    });
    return reply.status(202).send(job);
  });
}

documentRoute('POST', '/imports', { body: createBody });
