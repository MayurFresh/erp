import type { FastifyInstance } from 'fastify';
import { randomUUID } from 'node:crypto';
import { sql } from 'kysely';
import { z } from 'zod';
import { lockItems, locationQty } from '../accounting/costing.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, isValidDate, todayIst } from '../lib/dates.ts';
import { effectiveModules } from '../lib/entitlements.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { definedOnly, nullableText, optionalText } from '../lib/india.ts';
import { moneyField, qtyField } from '../lib/numbers.ts';
import { likeTerm, pagingQuery } from '../lib/paging.ts';
import { assertFresh } from '../lib/stale.ts';
import { parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';
import { getLocation } from './locations.ts';
import { documentRoute } from '../lib/openapi.ts';

/*
 * Warehouse depth. wh_moves is an append-only sub-ledger that says where inside a location the stock sits (bin and
 * batch). It never touches stock_moves: invoices, purchases, POS and manufacturing post stock exactly as before.
 * On hand minus what wh_moves covers is "unassigned" stock, which receipts tag into bins and batches.
 */

const dateField = z.string().refine(isValidDate, 'Use YYYY-MM-DD');
const blank = (v: unknown) => (typeof v === 'string' && v.trim() === '' ? null : v);
const optDate = z.preprocess(blank, dateField.nullable().optional());
const posQty = qtyField.refine((v) => v > 0, 'Must be more than zero');
const round3 = (n: number) => Math.round(n * 1000) / 1000;
const BIN_KINDS = ['storage', 'receiving', 'dispatch', 'quarantine'] as const;

const use = (ctx: RequestContext) => ctx.require('warehouse.view', 'warehouse.pick', 'warehouse.manage');
const work = (ctx: RequestContext) => ctx.require('warehouse.pick', 'warehouse.manage');
const manage = (ctx: RequestContext) => ctx.require('warehouse.manage');

interface Settings { fefo: boolean; blockExpired: boolean; expiryWarnDays: number }
async function loadSettings(tx: Tx, companyId: string): Promise<Settings> {
  const r = await tx.selectFrom('wh_settings').selectAll().where('company_id', '=', companyId).executeTakeFirst();
  return { fefo: r?.fefo ?? true, blockExpired: r?.block_expired ?? true, expiryWarnDays: r?.expiry_warn_days ?? 90 };
}

interface Balance {
  binId: string | null; binCode: string | null; batchId: string | null; batchNo: string | null; expiryDate: string | null;
  mfgDate: string | null; qty: number; batchAt: Date | null;
}

/** Positive bin and batch balances of an item at a location. */
async function balances(tx: Tx, companyId: string, locationId: string, itemId: string | null, extra?: { binId?: string }): Promise<(Balance & { itemId: string })[]> {
  let q = tx.selectFrom('wh_moves as m')
    .leftJoin('wh_bins as b', 'b.id', 'm.bin_id')
    .leftJoin('wh_batches as t', 't.id', 'm.batch_id')
    .where('m.company_id', '=', companyId).where('m.location_id', '=', locationId)
    .groupBy(['m.item_id', 'm.bin_id', 'm.batch_id', 'b.code', 't.batch_no', 't.expiry_date', 't.mfg_date', 't.created_at'])
    .having((eb) => eb(eb.fn.sum('m.qty'), '>', 0))
    .select((eb) => ['m.item_id', 'm.bin_id', 'm.batch_id', 'b.code as bin_code', 't.batch_no', 't.expiry_date', 't.mfg_date', 't.created_at as batch_at',
      eb.fn.sum<number>('m.qty').as('qty')]);
  if (itemId) q = q.where('m.item_id', '=', itemId);
  if (extra?.binId) q = q.where('m.bin_id', '=', extra.binId);
  const rows = await q.execute();
  return rows.map((r) => ({
    itemId: r.item_id, binId: r.bin_id, binCode: r.bin_code, batchId: r.batch_id, batchNo: r.batch_no,
    expiryDate: r.expiry_date, mfgDate: r.mfg_date, qty: Number(r.qty), batchAt: r.batch_at,
  }));
}

/** First expiry first out (or oldest batch first when FEFO is off); batches without expiry go last. */
function pickOrder(rows: Balance[], fefo: boolean): Balance[] {
  const t = (d: Date | null) => (d ? new Date(d).getTime() : 0);
  return [...rows].sort((a, b) => {
    if (fefo) {
      const ea = a.expiryDate ?? '9999-12-31';
      const eb = b.expiryDate ?? '9999-12-31';
      if (ea !== eb) return ea < eb ? -1 : 1;
    }
    return t(a.batchAt) - t(b.batchAt) || (a.binCode ?? '').localeCompare(b.binCode ?? '');
  });
}

const isExpired = (expiry: string | null) => !!expiry && expiry < todayIst();

async function taggedQty(tx: Tx, companyId: string, locationId: string, itemId: string): Promise<number> {
  const r = await tx.selectFrom('wh_moves').select((eb) => eb.fn.coalesce(eb.fn.sum<number>('qty'), sql<number>`0`).as('qty'))
    .where('company_id', '=', companyId).where('location_id', '=', locationId).where('item_id', '=', itemId).executeTakeFirstOrThrow();
  return Number(r.qty);
}

async function itemOf(tx: Tx, ctx: RequestContext, itemId: string) {
  const item = await tx.selectFrom('items').select(['id', 'name', 'track_stock', 'unit']).where('id', '=', itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!item) throw notFound('Item');
  if (!item.track_stock) throw badRequest('Stock is not tracked for this item.', { itemId: 'Stock not tracked' });
  return item;
}
async function ruleOf(tx: Tx, itemId: string) {
  const r = await tx.selectFrom('wh_item_rules').selectAll().where('item_id', '=', itemId).executeTakeFirst();
  return { tracking: (r?.tracking ?? 'none') as 'none' | 'batch' | 'serial', shelfLifeDays: r?.shelf_life_days ?? null, defaultBinId: r?.default_bin_id ?? null };
}
async function binOf(tx: Tx, ctx: RequestContext, binId: string, locationId: string) {
  const b = await tx.selectFrom('wh_bins').selectAll().where('id', '=', binId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!b) throw notFound('Bin');
  if (b.location_id !== locationId) throw badRequest('This bin belongs to another location.', { binId: 'Wrong location' });
  if (!b.is_active) throw badRequest('This bin is switched off.', { binId: 'Inactive bin' });
  return b;
}
async function binQty(tx: Tx, companyId: string, binId: string): Promise<number> {
  const r = await tx.selectFrom('wh_moves').select((eb) => eb.fn.coalesce(eb.fn.sum<number>('qty'), sql<number>`0`).as('qty'))
    .where('company_id', '=', companyId).where('bin_id', '=', binId).executeTakeFirstOrThrow();
  return Number(r.qty);
}
async function checkCapacity(tx: Tx, companyId: string, bin: { id: string; code: string; capacity_qty: number | null }, add: number) {
  if (bin.capacity_qty == null) return;
  const now = await binQty(tx, companyId, bin.id);
  if (now + add > Number(bin.capacity_qty) + 0.0005) {
    throw conflict(`Bin ${bin.code} holds ${now} of ${Number(bin.capacity_qty)}; ${add} more will not fit.`, 'BIN_FULL',
      { binId: bin.id, held: now, capacity: Number(bin.capacity_qty), adding: add });
  }
}

const binJson = (b: { id: string; location_id: string; code: string; name: string | null; zone: string | null; kind: string; capacity_qty: number | null; is_active: boolean; updated_at: Date }) => ({
  id: b.id, locationId: b.location_id, code: b.code, name: b.name, zone: b.zone, kind: b.kind,
  capacityQty: b.capacity_qty == null ? null : Number(b.capacity_qty), isActive: b.is_active, updatedAt: b.updated_at,
});
const batchJson = (b: { id: string; item_id: string; batch_no: string; mfg_date: string | null; expiry_date: string | null; mrp: number | null; updated_at: Date }) => ({
  id: b.id, itemId: b.item_id, batchNo: b.batch_no, mfgDate: b.mfg_date, expiryDate: b.expiry_date,
  mrp: b.mrp == null ? null : Number(b.mrp), expired: isExpired(b.expiry_date), updatedAt: b.updated_at,
});
const serialJson = (s: { id: string; item_id: string; serial_no: string; batch_id: string | null; location_id: string; bin_id: string | null; status: string; warranty_until: string | null; issued_ref: string | null }) => ({
  id: s.id, itemId: s.item_id, serialNo: s.serial_no, batchId: s.batch_id, locationId: s.location_id, binId: s.bin_id,
  status: s.status, warrantyUntil: s.warranty_until, issuedRef: s.issued_ref,
});

const binFields = {
  locationId: z.uuid(),
  code: z.string().trim().min(1, 'Required').max(30),
  name: optionalText(100),
  zone: optionalText(40),
  kind: z.enum(BIN_KINDS).default('storage'),
  capacityQty: z.preprocess(blank, posQty.nullable().optional()),
};
const binPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(),
  code: binFields.code.optional(), name: nullableText(100), zone: nullableText(40), kind: z.enum(BIN_KINDS).optional(),
  capacityQty: binFields.capacityQty, isActive: z.boolean().optional(),
});
const batchFields = {
  itemId: z.uuid(),
  batchNo: z.string().trim().min(1, 'Required').max(50),
  mfgDate: optDate, expiryDate: optDate,
  mrp: z.preprocess(blank, moneyField.nullable().optional()),
};
const batchPatch = z.object({
  expectedUpdatedAt: z.string().max(40).optional(), mfgDate: optDate, expiryDate: optDate, mrp: batchFields.mrp,
});
const settingsBody = z.object({
  fefo: z.boolean().optional(), blockExpired: z.boolean().optional(), expiryWarnDays: z.coerce.number().int().min(0).max(3650).optional(),
});
const ruleBody = z.object({
  tracking: z.enum(['none', 'batch', 'serial']).optional(),
  shelfLifeDays: z.preprocess(blank, z.coerce.number().int().min(1).max(36500).nullable().optional()),
  defaultBinId: z.preprocess(blank, z.uuid().nullable().optional()),
});
const batchInline = z.object({ batchNo: batchFields.batchNo, mfgDate: optDate, expiryDate: optDate, mrp: batchFields.mrp });
const serialNos = z.array(z.string().trim().min(1).max(80)).max(2000);
const receiptBody = z.object({
  locationId: z.uuid(), itemId: z.uuid(), binId: z.uuid().optional(), qty: posQty,
  batchId: z.uuid().optional(), batch: batchInline.optional(), serialNos: serialNos.optional(),
  warrantyUntil: optDate, note: optionalText(300),
});
const putawayBody = z.object({
  locationId: z.uuid(), itemId: z.uuid(), fromBinId: z.uuid().nullable().optional(), toBinId: z.uuid(),
  batchId: z.uuid().nullable().optional(), qty: posQty, serialNos: serialNos.optional(), note: optionalText(300),
});
const pickBody = z.object({
  locationId: z.uuid(), refType: optionalText(40), refId: z.uuid().optional(), note: optionalText(300),
  lines: z.array(z.object({
    itemId: z.uuid(), qty: posQty, binId: z.uuid().optional(), batchId: z.uuid().optional(), serialNos: serialNos.optional(),
  })).min(1, 'Add at least one line').max(200),
});
const stockQuery = pagingQuery.extend({ locationId: z.uuid(), itemId: z.uuid().optional(), binId: z.uuid().optional() });
const fefoQuery = z.object({ locationId: z.uuid(), itemId: z.uuid(), qty: z.coerce.number().positive().optional() });
const expiryQuery = pagingQuery.extend({ days: z.coerce.number().int().min(0).max(3650).optional(), locationId: z.uuid().optional() });

type ReceiveInput = z.infer<typeof receiptBody> & { refType?: string; refId?: string };
type PickInput = z.infer<typeof pickBody>;
interface Alloc { binId: string | null; binCode: string | null; batchId: string | null; batchNo: string | null; expiryDate: string | null; qty: number }

/** Plans which bins and batches an issue of `qty` comes from. Throws when the sub-ledger cannot cover it. */
function allocate(rows: Balance[], qty: number, s: Settings, want: { binId?: string; batchId?: string }, itemName: string): Alloc[] {
  let pool = rows.filter((r) => (want.binId ? r.binId === want.binId : true) && (want.batchId ? r.batchId === want.batchId : true));
  const explicit = !!(want.binId || want.batchId);
  if (s.blockExpired) {
    const expired = pool.filter((r) => isExpired(r.expiryDate));
    if (explicit && expired.length && expired.length === pool.length) {
      throw conflict(`${itemName} batch ${expired[0]!.batchNo ?? ''} expired on ${expired[0]!.expiryDate}.`, 'BATCH_EXPIRED', { batchId: expired[0]!.batchId });
    }
    pool = pool.filter((r) => !isExpired(r.expiryDate));
  }
  let left = qty;
  const out: Alloc[] = [];
  for (const r of pickOrder(pool, s.fefo)) {
    if (left <= 0.0005) break;
    const take = round3(Math.min(r.qty, left));
    out.push({ binId: r.binId, binCode: r.binCode, batchId: r.batchId, batchNo: r.batchNo, expiryDate: r.expiryDate, qty: take });
    left = round3(left - take);
  }
  if (left > 0.0005) {
    const have = round3(qty - left);
    throw conflict(`Only ${have} of ${itemName} can be picked from bins${s.blockExpired ? ' (expired batches are skipped)' : ''}.`,
      'INSUFFICIENT_BIN_STOCK', { available: have, required: qty });
  }
  return out;
}

// ---- hook for invoices, purchases and POS
/** Optional bin, batch and serial fields a document line may carry. */
export const whLineFields = {
  binId: z.uuid().optional(),
  batchId: z.uuid().optional(),
  batchNo: z.string().trim().min(1).max(50).optional(),
  expiry: optDate,
  serials: serialNos.optional(),
};
export interface WhDocLine { itemId: string; qty: number; binId?: string; batchId?: string; batchNo?: string; expiry?: string | null; serials?: string[] }
export interface WhDoc { locationId: string; refType: string; refId: string; note?: string | null; lines: WhDocLine[] }
/** Transactions listed here skip the hook (pick-to-sale has already taken the stock from bins). */
const skipHook = new WeakSet<object>();

/** Copies only the warehouse fields of a line, for callers that rebuild their lines. */
export function whExtras(l: Partial<WhDocLine> | undefined): Partial<WhDocLine> {
  if (!l) return {};
  return definedOnly({ binId: l.binId, batchId: l.batchId, batchNo: l.batchNo, expiry: l.expiry ?? undefined, serials: l.serials }) as Partial<WhDocLine>;
}

async function hookActive(tx: Tx, ctx: RequestContext, doc: WhDoc): Promise<boolean> {
  if (skipHook.has(tx) || !doc.lines.length) return false;
  const c = await tx.selectFrom('companies').select(['enabled_modules', 'business_type', 'country', 'plan']).where('id', '=', ctx.companyId).executeTakeFirst();
  return !!c && effectiveModules(c).includes('warehouse');
}
const hasFields = (l: WhDocLine) => !!(l.binId || l.batchId || l.batchNo || l.serials?.length);

/** After a purchase posts: put received stock into the default bin (or the line's bin) with its batch and serials. */
export async function warehouseReceive(tx: Tx, ctx: RequestContext, doc: WhDoc): Promise<void> {
  if (!(await hookActive(tx, ctx, doc))) return;
  for (const l of doc.lines) {
    const item = await tx.selectFrom('items').select('track_stock').where('id', '=', l.itemId).executeTakeFirst();
    if (!item?.track_stock) continue;
    const rule = await ruleOf(tx, l.itemId);
    if (!hasFields(l) && rule.tracking === 'none' && !rule.defaultBinId) continue;
    let binId = l.binId;
    if (!binId && rule.defaultBinId) {
      const bin = await tx.selectFrom('wh_bins').select(['id', 'location_id', 'is_active']).where('id', '=', rule.defaultBinId).executeTakeFirst();
      if (bin?.is_active && bin.location_id === doc.locationId) binId = bin.id;
    }
    await receiveStock(tx, ctx, {
      locationId: doc.locationId, itemId: l.itemId, qty: l.qty, binId,
      batchId: l.batchId, batch: !l.batchId && l.batchNo ? { batchNo: l.batchNo, expiryDate: l.expiry ?? null } : undefined,
      serialNos: l.serials?.length ? l.serials : undefined, note: doc.note ?? undefined, refType: doc.refType, refId: doc.refId,
    });
  }
}

/** After an invoice or POS sale posts: take stock from bins (first expiry first, or the line's bin, batch and serials). */
export async function warehouseIssue(tx: Tx, ctx: RequestContext, doc: WhDoc): Promise<void> {
  if (!(await hookActive(tx, ctx, doc))) return;
  const lines: PickInput['lines'] = [];
  for (const l of doc.lines) {
    const item = await tx.selectFrom('items').select('track_stock').where('id', '=', l.itemId).executeTakeFirst();
    if (!item?.track_stock) continue;
    const rule = await ruleOf(tx, l.itemId);
    if (!hasFields(l) && rule.tracking === 'none' && !rule.defaultBinId) continue;
    if (rule.tracking === 'serial' && !l.serials?.length) continue; // serial items are issued only when serials are given
    let batchId = l.batchId;
    if (!batchId && l.batchNo) {
      const bt = await tx.selectFrom('wh_batches').select('id').where('company_id', '=', ctx.companyId).where('item_id', '=', l.itemId).where('batch_no', '=', l.batchNo).executeTakeFirst();
      if (!bt) throw notFound(`Batch ${l.batchNo}`);
      batchId = bt.id;
    }
    lines.push({ itemId: l.itemId, qty: l.qty, binId: l.binId, batchId, serialNos: l.serials?.length ? l.serials : undefined });
  }
  if (!lines.length) return;
  await pickLines(tx, ctx, { locationId: doc.locationId, refType: doc.refType, refId: doc.refId, note: doc.note ?? undefined, lines }, true);
}

async function receiveStock(tx: Tx, ctx: RequestContext, b: ReceiveInput) {
  const loc = await getLocation(tx, ctx, b.locationId);
  const item = await itemOf(tx, ctx, b.itemId);
  const rule = await ruleOf(tx, item.id);
  const bin = b.binId ? await binOf(tx, ctx, b.binId, loc.id) : null;
  await lockItems(tx, ctx.companyId, [item.id]);

  let batchId: string | null = b.batchId ?? null;
  if (b.batchId && b.batch) throw badRequest('Give either batchId or batch.', { batch: 'Use one' });
  if (batchId) {
    const e = await tx.selectFrom('wh_batches').select(['id', 'item_id', 'expiry_date']).where('id', '=', batchId).where('company_id', '=', ctx.companyId).executeTakeFirst();
    if (!e || e.item_id !== item.id) throw notFound('Batch');
    if (isExpired(e.expiry_date)) throw conflict('This batch has expired.', 'BATCH_EXPIRED', { batchId });
  } else if (b.batch) {
    const ex = await tx.selectFrom('wh_batches').selectAll().where('company_id', '=', ctx.companyId).where('item_id', '=', item.id).where('batch_no', '=', b.batch.batchNo).executeTakeFirst();
    if (ex) {
      batchId = ex.id;
      if (isExpired(ex.expiry_date)) throw conflict('This batch has expired.', 'BATCH_EXPIRED', { batchId });
    } else {
      const mfg = b.batch.mfgDate ?? null;
      let exp = b.batch.expiryDate ?? null;
      if (!exp && mfg && rule.shelfLifeDays) exp = addDays(mfg, rule.shelfLifeDays);
      if (mfg && exp && exp < mfg) throw badRequest('Expiry is before manufacture.', { expiryDate: 'Before manufacture date' });
      if (exp && isExpired(exp)) throw badRequest('This batch has already expired.', { expiryDate: 'Already expired' });
      const nb = await tx.insertInto('wh_batches').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: item.id, batch_no: b.batch.batchNo, mfg_date: mfg, expiry_date: exp, mrp: b.batch.mrp ?? null,
      }).returning('id').executeTakeFirstOrThrow();
      batchId = nb.id;
    }
  }
  if (rule.tracking === 'batch' && !batchId) throw badRequest(`${item.name} is tracked by batch. Give a batch.`, { batch: 'Required' });
  if (rule.tracking === 'serial' || b.serialNos?.length) {
    const n = b.serialNos?.length ?? 0;
    if (n !== b.qty) throw badRequest(`Give ${b.qty} serial numbers; got ${n}.`, { serialNos: 'Count must equal quantity' });
    if (new Set(b.serialNos!.map((x) => x.toLowerCase())).size !== n) throw badRequest('A serial number is repeated.', { serialNos: 'Duplicate' });
  }

  const onHand = await locationQty(tx, ctx.companyId, loc.id, item.id);
  const free = round3(onHand - (await taggedQty(tx, ctx.companyId, loc.id, item.id)));
  if (b.qty > free + 0.0005) {
    throw conflict(`Only ${Math.max(0, free)} ${item.unit} of ${item.name} at ${loc.name} is not yet placed in a bin. Receive the purchase first.`,
      'INSUFFICIENT_STOCK', { unassigned: Math.max(0, free), required: b.qty, onHand });
  }
  if (bin) await checkCapacity(tx, ctx.companyId, bin, b.qty);

  if (b.serialNos?.length) {
    const dup = await tx.selectFrom('wh_serials').select('serial_no').where('company_id', '=', ctx.companyId).where('item_id', '=', item.id)
      .where('serial_no', 'in', b.serialNos).executeTakeFirst();
    if (dup) throw conflict(`Serial ${dup.serial_no} is already recorded.`, 'DUPLICATE_SERIAL', { serialNos: dup.serial_no });
    await tx.insertInto('wh_serials').values(b.serialNos.map((sn) => ({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: item.id, serial_no: sn, batch_id: batchId, location_id: loc.id,
      bin_id: bin?.id ?? null, warranty_until: b.warrantyUntil ?? null,
      issued_ref: b.refType === 'purchase' && b.refId ? `recv:purchase:${b.refId}` : null,
    }))).execute();
  }
  const mv = await tx.insertInto('wh_moves').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: loc.id, item_id: item.id, bin_id: bin?.id ?? null, batch_id: batchId,
    qty: b.qty, kind: 'receipt', ref_type: b.refType ?? null, ref_id: b.refId ?? null, note: b.note ?? null, created_by: ctx.userId,
  }).returningAll().executeTakeFirstOrThrow();
  await writeAudit(tx, auditOf(ctx), 'wh_move', mv.id, 'receipt', null, { itemId: item.id, binId: bin?.id ?? null, batchId, qty: b.qty });
  return { id: mv.id, itemId: item.id, locationId: loc.id, binId: bin?.id ?? null, batchId, qty: b.qty, serialNos: b.serialNos ?? [] };
}

async function pickLines(tx: Tx, ctx: RequestContext, b: PickInput, soft = false) {
  const loc = await getLocation(tx, ctx, b.locationId);
  const s = await loadSettings(tx, ctx.companyId);
  await lockItems(tx, ctx.companyId, b.lines.map((l) => l.itemId));
  const result: { itemId: string; qty: number; allocations: Alloc[]; serialNos: string[] }[] = [];
  const ref = b.refType ?? 'pick';
  const refId = b.refId ?? randomUUID();
  for (const line of b.lines) {
    const item = await itemOf(tx, ctx, line.itemId);
    const rule = await ruleOf(tx, item.id);
    let allocs: Alloc[];
    const sns = line.serialNos ?? [];
    if (rule.tracking === 'serial' || sns.length) {
      if (sns.length !== line.qty) throw badRequest(`Give ${line.qty} serial numbers for ${item.name}; got ${sns.length}.`, { serialNos: 'Count must equal quantity' });
      if (new Set(sns).size !== sns.length) throw badRequest('A serial number is repeated.', { serialNos: 'Duplicate' });
      const found = await tx.selectFrom('wh_serials as r').leftJoin('wh_bins as bn', 'bn.id', 'r.bin_id').leftJoin('wh_batches as bt', 'bt.id', 'r.batch_id')
        .select(['r.id', 'r.serial_no', 'r.bin_id', 'r.batch_id', 'r.status', 'r.location_id', 'bn.code as bin_code', 'bt.batch_no', 'bt.expiry_date'])
        .where('r.company_id', '=', ctx.companyId).where('r.item_id', '=', item.id).where('r.serial_no', 'in', sns).execute();
      for (const sn of sns) {
        const f = found.find((x) => x.serial_no === sn);
        if (!f) throw notFound(`Serial ${sn}`);
        if (f.status !== 'in_stock' || f.location_id !== loc.id) throw conflict(`Serial ${sn} is not in stock at ${loc.name}.`, 'SERIAL_NOT_AVAILABLE', { serialNo: sn });
        if (s.blockExpired && isExpired(f.expiry_date)) throw conflict(`Serial ${sn} is from an expired batch.`, 'BATCH_EXPIRED', { serialNo: sn });
      }
      const map = new Map<string, Alloc>();
      for (const f of found) {
        const k = `${f.bin_id}|${f.batch_id}`;
        const a = map.get(k) ?? { binId: f.bin_id, binCode: f.bin_code, batchId: f.batch_id, batchNo: f.batch_no, expiryDate: f.expiry_date, qty: 0 };
        a.qty += 1;
        map.set(k, a);
      }
      allocs = [...map.values()];
      await tx.updateTable('wh_serials').set({ status: 'issued', issued_ref: b.refType ? `${b.refType}:${refId}`.slice(0, 80) : 'pick', issued_at: new Date() })
        .where('company_id', '=', ctx.companyId).where('item_id', '=', item.id).where('serial_no', 'in', sns).execute();
    } else {
      const rows = await balances(tx, ctx.companyId, loc.id, item.id);
      let q = line.qty;
      if (soft && !line.binId && !line.batchId) {
        // Sales: take what the bins cover; the rest stays unassigned.
        q = Math.min(q, round3(rows.filter((r) => !(s.blockExpired && isExpired(r.expiryDate))).reduce((a, r) => a + r.qty, 0)));
      }
      allocs = q > 0.0005 ? allocate(rows, q, s, { binId: line.binId, batchId: line.batchId }, item.name) : [];
    }
    for (const a of allocs) {
      if (rule.tracking === 'serial' || sns.length) {
        const cur = (await balances(tx, ctx.companyId, loc.id, item.id)).find((r) => r.binId === a.binId && r.batchId === a.batchId);
        if (!cur || cur.qty + 0.0005 < a.qty) throw conflict(`Bin records for ${item.name} do not cover this pick.`, 'INSUFFICIENT_BIN_STOCK', { available: cur?.qty ?? 0, required: a.qty });
      }
      await tx.insertInto('wh_moves').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: loc.id, item_id: item.id, bin_id: a.binId, batch_id: a.batchId,
        qty: -a.qty, kind: 'pick', ref_type: ref, ref_id: refId, note: b.note ?? null, created_by: ctx.userId,
      }).execute();
    }
    result.push({ itemId: item.id, qty: line.qty, allocations: allocs, serialNos: sns });
  }
  await writeAudit(tx, auditOf(ctx), 'wh_move', refId, 'pick', null, { locationId: loc.id, lines: result.map((r) => ({ itemId: r.itemId, qty: r.qty })) });
  return { refId, locationId: loc.id, lines: result };
}

/**
 * Puts bin stock back when a document is cancelled or goods are returned: new opposite wh_moves (never edits old rows),
 * in the same bins and batches. `only` limits a return to some items and quantities. A document with no wh_moves does nothing.
 * An invoice raised from a pick list is reversed through the pick, and its link is cleared so the pick can be billed again.
 */
export async function warehouseReverse(tx: Tx, ctx: RequestContext, refType: 'invoice' | 'purchase', refId: string, only?: Map<string, number>, cnId?: string): Promise<void> {
  const sources: { type: string; id: string }[] = [{ type: refType, id: refId }];
  const link = refType === 'invoice'
    ? await tx.selectFrom('wh_pick_links').select('pick_ref_id').where('invoice_id', '=', refId).executeTakeFirst() : undefined;
  if (link) sources.push({ type: 'pick', id: link.pick_ref_id });
  const left = new Map(only ?? []);
  for (const src of sources) {
    const rows = await tx.selectFrom('wh_moves').select(['location_id', 'item_id', 'bin_id', 'batch_id', 'qty', 'ref_type'])
      .where('company_id', '=', ctx.companyId).where('ref_id', '=', src.id).where('ref_type', 'in', [src.type, `${src.type}_reversal`, `${src.type}_again`]).execute();
    const groups = new Map<string, { locationId: string; itemId: string; binId: string | null; batchId: string | null; net: number }>();
    for (const r of rows) {
      const k = `${r.location_id}|${r.item_id}|${r.bin_id}|${r.batch_id}`;
      const g = groups.get(k) ?? { locationId: r.location_id, itemId: r.item_id, binId: r.bin_id, batchId: r.batch_id, net: 0 };
      g.net = round3(g.net + Number(r.qty));
      groups.set(k, g);
    }
    for (const g of groups.values()) {
      if (Math.abs(g.net) < 0.0005) continue;
      let amount = Math.abs(g.net);
      if (only) {
        const want = left.get(g.itemId) ?? 0;
        amount = Math.min(amount, want);
        left.set(g.itemId, round3(want - amount));
      }
      let qty = g.net < 0 ? amount : -amount; // sales come back, receipts go out
      if (qty < 0) {
        // Never take more out of a bin than it holds now.
        const cur = (await balances(tx, ctx.companyId, g.locationId, g.itemId)).find((r) => r.binId === g.binId && r.batchId === g.batchId);
        qty = -Math.min(amount, cur?.qty ?? 0);
      }
      if (Math.abs(qty) < 0.0005) continue;
      if (qty < 0 && src.type === 'purchase') {
        // Serials already sold or issued cannot go back with the purchase.
        const rule = await tx.selectFrom('wh_item_rules').select('tracking').where('company_id', '=', ctx.companyId).where('item_id', '=', g.itemId).executeTakeFirst();
        if (rule?.tracking === 'serial') {
          const held = await tx.selectFrom('wh_serials').select('id').where('company_id', '=', ctx.companyId).where('item_id', '=', g.itemId)
            .where('status', '=', 'in_stock').where('issued_ref', '=', `recv:purchase:${src.id}`).execute();
          if (held.length < Math.round(amount)) throw conflict('Some serial numbers from this purchase have already been sold or issued. Take the sales back first.', 'SERIAL_ALREADY_ISSUED');
        }
      }
      await tx.insertInto('wh_moves').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: g.locationId, item_id: g.itemId, bin_id: g.binId, batch_id: g.batchId,
        qty, kind: 'adjust', ref_type: `${src.type}_reversal`, ref_id: src.id, note: cnId ? `cn:${cnId}` : 'Reversed', created_by: ctx.userId,
      }).execute();
      // Serials follow: issued ones come back in stock; received ones leave.
      const tag = `${src.type}:${src.id}`;
      if (qty > 0) {
        const sn = await tx.selectFrom('wh_serials').select('id').where('company_id', '=', ctx.companyId).where('item_id', '=', g.itemId)
          .where('status', '=', 'issued').where('issued_ref', '=', tag).limit(Math.round(qty)).execute();
        if (sn.length) await tx.updateTable('wh_serials').set({ status: 'in_stock', issued_ref: cnId ? `ret:${cnId}` : null, issued_at: null }).where('id', 'in', sn.map((x) => x.id)).execute();
      } else if (src.type === 'purchase') {
        // Serials this purchase received leave stock with it.
        await tx.updateTable('wh_serials').set({ status: 'issued', issued_ref: `cancelled:purchase:${src.id}`.slice(0, 80), issued_at: new Date() })
          .where('company_id', '=', ctx.companyId).where('status', '=', 'in_stock').where('issued_ref', '=', `recv:purchase:${src.id}`).execute();
      }
    }
    if (src.type === 'pick' && !only) await tx.deleteFrom('wh_pick_links').where('pick_ref_id', '=', src.id).execute();
  }
}

/** Cancelling a credit note takes its returned stock out of the same bins and batches again (409 when the bins no longer hold it). */
export async function warehouseUnreturn(tx: Tx, ctx: RequestContext, cnId: string): Promise<void> {
  const rows = await tx.selectFrom('wh_moves').selectAll().where('company_id', '=', ctx.companyId).where('note', '=', `cn:${cnId}`).execute();
  for (const r of rows) {
    const qty = Number(r.qty);
    if (qty > 0) {
      const cur = (await balances(tx, ctx.companyId, r.location_id, r.item_id)).find((x) => x.binId === r.bin_id && x.batchId === r.batch_id);
      if ((cur?.qty ?? 0) + 0.0005 < qty) {
        throw conflict('The returned stock is no longer in its bin. Move it back before cancelling this credit note.', 'INSUFFICIENT_BIN_STOCK', { available: cur?.qty ?? 0, required: qty });
      }
    }
    await tx.insertInto('wh_moves').values({
      tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: r.location_id, item_id: r.item_id, bin_id: r.bin_id, batch_id: r.batch_id,
      qty: -qty, kind: 'adjust', ref_type: (r.ref_type ?? '').replace('_reversal', '_again'), ref_id: r.ref_id, note: `cn:${cnId}:cancelled`, created_by: ctx.userId,
    }).execute();
  }
  await tx.updateTable('wh_serials').set({ status: 'issued', issued_ref: `cancelled:cn:${cnId}`.slice(0, 80), issued_at: new Date() })
    .where('company_id', '=', ctx.companyId).where('status', '=', 'in_stock').where('issued_ref', '=', `ret:${cnId}`).execute();
}

export async function warehouseRoutes(app: FastifyInstance) {
  // ---- settings (PUT and PATCH do the same)
  const settingsOut = (s: Settings) => s;
  app.get('/warehouse/settings', async (req) => {
    const ctx = req.ctx; use(ctx);
    return ctx.tx(async (tx) => settingsOut(await loadSettings(tx, ctx.companyId)));
  });
  const saveSettings = async (req: { ctx: RequestContext; body: unknown }) => {
    const ctx = req.ctx; manage(ctx);
    const b = parse(settingsBody, req.body);
    return ctx.tx(async (tx) => {
      const cur = await loadSettings(tx, ctx.companyId);
      const next = { fefo: b.fefo ?? cur.fefo, blockExpired: b.blockExpired ?? cur.blockExpired, expiryWarnDays: b.expiryWarnDays ?? cur.expiryWarnDays };
      await tx.insertInto('wh_settings').values({
        company_id: ctx.companyId, tenant_id: ctx.tenantId, fefo: next.fefo, block_expired: next.blockExpired, expiry_warn_days: next.expiryWarnDays,
      }).onConflict((oc) => oc.column('company_id').doUpdateSet({ fefo: next.fefo, block_expired: next.blockExpired, expiry_warn_days: next.expiryWarnDays })).execute();
      await writeAudit(tx, auditOf(ctx), 'company', ctx.companyId, 'warehouse_settings', cur, next);
      return next;
    });
  };
  app.put('/warehouse/settings', saveSettings);
  app.patch('/warehouse/settings', saveSettings);

  // ---- bins
  app.get('/warehouse/bins', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(pagingQuery.extend({ locationId: z.uuid().optional(), kind: z.enum(BIN_KINDS).optional(), active: z.enum(['true', 'false']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('wh_bins').where('company_id', '=', ctx.companyId);
      if (q.locationId) base = base.where('location_id', '=', q.locationId);
      if (q.kind) base = base.where('kind', '=', q.kind);
      if (q.active) base = base.where('is_active', '=', q.active === 'true');
      if (q.q) base = base.where((eb) => eb.or([eb('code', 'ilike', likeTerm(q.q!)), eb('name', 'ilike', likeTerm(q.q!)), eb('zone', 'ilike', likeTerm(q.q!))]));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('code').limit(q.limit).offset(q.offset).execute();
      const held = rows.length ? await tx.selectFrom('wh_moves').select((eb) => ['bin_id', eb.fn.sum<number>('qty').as('qty')])
        .where('company_id', '=', ctx.companyId).where('bin_id', 'in', rows.map((r) => r.id)).groupBy('bin_id').execute() : [];
      return { data: rows.map((r) => ({ ...binJson(r), heldQty: Number(held.find((h) => h.bin_id === r.id)?.qty ?? 0) })), total: Number(total) };
    });
  });
  app.post('/warehouse/bins', async (req, reply) => {
    const ctx = req.ctx; manage(ctx);
    const b = parse(z.object(binFields), req.body);
    const row = await ctx.tx(async (tx) => {
      await getLocation(tx, ctx, b.locationId);
      const dup = await tx.selectFrom('wh_bins').select('id').where('company_id', '=', ctx.companyId).where('location_id', '=', b.locationId).where('code', '=', b.code).executeTakeFirst();
      if (dup) throw conflict(`Bin ${b.code} already exists at this location.`, 'DUPLICATE_BIN', { code: 'Already used' });
      const r = await tx.insertInto('wh_bins').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: b.locationId, code: b.code, name: b.name ?? null, zone: b.zone ?? null,
        kind: b.kind, capacity_qty: b.capacityQty ?? null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'wh_bin', r.id, 'create', null, binJson(r));
      return r;
    });
    return reply.status(201).send(binJson(row));
  });
  app.patch<{ Params: { id: string } }>('/warehouse/bins/:id', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const b = parse(binPatch, req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('wh_bins').selectAll().where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!cur) throw notFound('Bin');
      assertFresh(cur.updated_at, b.expectedUpdatedAt);
      if (b.code && b.code !== cur.code) {
        const dup = await tx.selectFrom('wh_bins').select('id').where('company_id', '=', ctx.companyId).where('location_id', '=', cur.location_id).where('code', '=', b.code).executeTakeFirst();
        if (dup) throw conflict(`Bin ${b.code} already exists at this location.`, 'DUPLICATE_BIN', { code: 'Already used' });
      }
      if (b.isActive === false && (await binQty(tx, ctx.companyId, cur.id)) > 0.0005) {
        throw conflict('This bin still holds stock. Put it away first.', 'BIN_NOT_EMPTY');
      }
      const patch = definedOnly({
        code: b.code, name: b.name, zone: b.zone, kind: b.kind, is_active: b.isActive,
        capacity_qty: b.capacityQty === undefined ? undefined : b.capacityQty,
      });
      const r = await tx.updateTable('wh_bins').set(patch).where('id', '=', cur.id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'wh_bin', r.id, 'update', binJson(cur), binJson(r));
      return binJson(r);
    });
  });

  // ---- item rules
  app.get<{ Params: { itemId: string } }>('/warehouse/items/:itemId', async (req) => {
    const ctx = req.ctx; use(ctx);
    return ctx.tx(async (tx) => {
      const item = await tx.selectFrom('items').select(['id', 'name']).where('id', '=', req.params.itemId).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!item) throw notFound('Item');
      return { itemId: item.id, itemName: item.name, ...(await ruleOf(tx, item.id)) };
    });
  });
  const saveRule = async (req: { ctx: RequestContext; body: unknown; params: { itemId: string } }) => {
    const ctx = req.ctx; manage(ctx);
    const b = parse(ruleBody, req.body);
    return ctx.tx(async (tx) => {
      const item = await itemOf(tx, ctx, req.params.itemId);
      const cur = await ruleOf(tx, item.id);
      const next = {
        tracking: b.tracking ?? cur.tracking, shelfLifeDays: b.shelfLifeDays === undefined ? cur.shelfLifeDays : b.shelfLifeDays,
        defaultBinId: b.defaultBinId === undefined ? cur.defaultBinId : b.defaultBinId,
      };
      if (next.defaultBinId) {
        const bin = await tx.selectFrom('wh_bins').select(['id', 'is_active']).where('id', '=', next.defaultBinId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!bin) throw notFound('Bin');
        if (!bin.is_active) throw badRequest('This bin is switched off.', { defaultBinId: 'Inactive bin' });
      }
      await tx.insertInto('wh_item_rules').values({
        item_id: item.id, tenant_id: ctx.tenantId, company_id: ctx.companyId, tracking: next.tracking, shelf_life_days: next.shelfLifeDays,
        default_bin_id: next.defaultBinId,
      }).onConflict((oc) => oc.column('item_id').doUpdateSet({ tracking: next.tracking, shelf_life_days: next.shelfLifeDays, default_bin_id: next.defaultBinId })).execute();
      await writeAudit(tx, auditOf(ctx), 'item', item.id, 'warehouse_rule', cur, next);
      return { itemId: item.id, itemName: item.name, ...next };
    });
  };
  app.put<{ Params: { itemId: string } }>('/warehouse/items/:itemId', saveRule);
  app.patch<{ Params: { itemId: string } }>('/warehouse/items/:itemId', saveRule);

  // ---- batches
  app.get('/warehouse/batches', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(pagingQuery.extend({ itemId: z.uuid().optional(), expiringInDays: z.coerce.number().int().min(0).max(3650).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('wh_batches as b').innerJoin('items as i', 'i.id', 'b.item_id').where('b.company_id', '=', ctx.companyId);
      if (q.itemId) base = base.where('b.item_id', '=', q.itemId);
      if (q.q) base = base.where((eb) => eb.or([eb('b.batch_no', 'ilike', likeTerm(q.q!)), eb('i.name', 'ilike', likeTerm(q.q!))]));
      if (q.expiringInDays != null) base = base.where('b.expiry_date', '<=', addDays(todayIst(), q.expiringInDays));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll('b').select('i.name as item_name').orderBy('b.expiry_date').orderBy('b.batch_no').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map((r) => ({ ...batchJson(r), itemName: r.item_name })), total: Number(total) };
    });
  });
  app.post('/warehouse/batches', async (req, reply) => {
    const ctx = req.ctx; work(ctx);
    const b = parse(z.object(batchFields), req.body);
    const row = await ctx.tx(async (tx) => {
      await itemOf(tx, ctx, b.itemId);
      const dup = await tx.selectFrom('wh_batches').select('id').where('company_id', '=', ctx.companyId).where('item_id', '=', b.itemId).where('batch_no', '=', b.batchNo).executeTakeFirst();
      if (dup) throw conflict(`Batch ${b.batchNo} already exists for this item.`, 'DUPLICATE_BATCH', { batchNo: 'Already used' });
      if (b.mfgDate && b.expiryDate && b.expiryDate < b.mfgDate) throw badRequest('Expiry is before manufacture.', { expiryDate: 'Before manufacture date' });
      const r = await tx.insertInto('wh_batches').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, item_id: b.itemId, batch_no: b.batchNo,
        mfg_date: b.mfgDate ?? null, expiry_date: b.expiryDate ?? null, mrp: b.mrp ?? null,
      }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'wh_batch', r.id, 'create', null, batchJson(r));
      return r;
    });
    return reply.status(201).send(batchJson(row));
  });
  app.patch<{ Params: { id: string } }>('/warehouse/batches/:id', async (req) => {
    const ctx = req.ctx; manage(ctx);
    const b = parse(batchPatch, req.body);
    return ctx.tx(async (tx) => {
      const cur = await tx.selectFrom('wh_batches').selectAll().where('id', '=', req.params.id).where('company_id', '=', ctx.companyId).executeTakeFirst();
      if (!cur) throw notFound('Batch');
      assertFresh(cur.updated_at, b.expectedUpdatedAt);
      const mfg = b.mfgDate === undefined ? cur.mfg_date : b.mfgDate;
      const exp = b.expiryDate === undefined ? cur.expiry_date : b.expiryDate;
      if (mfg && exp && exp < mfg) throw badRequest('Expiry is before manufacture.', { expiryDate: 'Before manufacture date' });
      const r = await tx.updateTable('wh_batches').set(definedOnly({ mfg_date: b.mfgDate, expiry_date: b.expiryDate, mrp: b.mrp }))
        .where('id', '=', cur.id).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'wh_batch', r.id, 'update', batchJson(cur), batchJson(r));
      return batchJson(r);
    });
  });

  // ---- serial numbers
  app.get('/warehouse/serials', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(pagingQuery.extend({ itemId: z.uuid().optional(), locationId: z.uuid().optional(), status: z.enum(['in_stock', 'issued']).optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('wh_serials as s').innerJoin('items as i', 'i.id', 's.item_id').where('s.company_id', '=', ctx.companyId);
      if (q.itemId) base = base.where('s.item_id', '=', q.itemId);
      if (q.locationId) base = base.where('s.location_id', '=', q.locationId);
      if (q.status) base = base.where('s.status', '=', q.status);
      if (q.q) base = base.where('s.serial_no', 'ilike', likeTerm(q.q));
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll('s').select('i.name as item_name').orderBy('s.serial_no').limit(q.limit).offset(q.offset).execute();
      return { data: rows.map((r) => ({ ...serialJson(r), itemName: r.item_name })), total: Number(total) };
    });
  });

  // ---- stock by bin and batch
  app.get('/warehouse/stock', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(stockQuery, req.query);
    return ctx.tx(async (tx) => {
      const loc = await getLocation(tx, ctx, q.locationId);
      const rows = await balances(tx, ctx.companyId, loc.id, q.itemId ?? null, { binId: q.binId });
      const names = rows.length ? await tx.selectFrom('items').select(['id', 'name', 'sku', 'unit']).where('id', 'in', [...new Set(rows.map((r) => r.itemId))]).execute() : [];
      rows.sort((a, b) => (a.binCode ?? '').localeCompare(b.binCode ?? '') || (a.expiryDate ?? '9999').localeCompare(b.expiryDate ?? '9999'));
      const page = rows.slice(q.offset, q.offset + q.limit);
      let unassigned: { itemId: string; onHand: number; tagged: number; unassigned: number } | null = null;
      if (q.itemId) {
        const onHand = await locationQty(tx, ctx.companyId, loc.id, q.itemId);
        const tagged = await taggedQty(tx, ctx.companyId, loc.id, q.itemId);
        unassigned = { itemId: q.itemId, onHand, tagged: round3(tagged), unassigned: Math.max(0, round3(onHand - tagged)) };
      }
      return {
        data: page.map((r) => {
          const n = names.find((x) => x.id === r.itemId);
          return {
            itemId: r.itemId, itemName: n?.name, sku: n?.sku, unit: n?.unit, binId: r.binId, binCode: r.binCode, batchId: r.batchId,
            batchNo: r.batchNo, mfgDate: r.mfgDate, expiryDate: r.expiryDate, expired: isExpired(r.expiryDate), qty: r.qty,
          };
        }),
        total: rows.length, ...(unassigned ? { summary: unassigned } : {}),
      };
    });
  });

  app.get('/warehouse/moves', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(pagingQuery.extend({ itemId: z.uuid().optional(), locationId: z.uuid().optional(), binId: z.uuid().optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('wh_moves').where('company_id', '=', ctx.companyId);
      if (q.itemId) base = base.where('item_id', '=', q.itemId);
      if (q.locationId) base = base.where('location_id', '=', q.locationId);
      if (q.binId) base = base.where('bin_id', '=', q.binId);
      const { total } = await base.select((eb) => eb.fn.countAll<number>().as('total')).executeTakeFirstOrThrow();
      const rows = await base.selectAll().orderBy('created_at', 'desc').limit(q.limit).offset(q.offset).execute();
      return {
        data: rows.map((m) => ({
          id: m.id, itemId: m.item_id, locationId: m.location_id, binId: m.bin_id, batchId: m.batch_id, qty: Number(m.qty), kind: m.kind,
          refType: m.ref_type, refId: m.ref_id, note: m.note, createdAt: m.created_at,
        })),
        total: Number(total),
      };
    });
  });

  // ---- FEFO suggestion and expiry report
  app.get('/warehouse/fefo', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(fefoQuery, req.query);
    return ctx.tx(async (tx) => {
      const loc = await getLocation(tx, ctx, q.locationId);
      const item = await itemOf(tx, ctx, q.itemId);
      const s = await loadSettings(tx, ctx.companyId);
      const rows = await balances(tx, ctx.companyId, loc.id, item.id);
      const order = pickOrder(rows.filter((r) => !(s.blockExpired && isExpired(r.expiryDate))), s.fefo);
      let plan: Alloc[] | null = null;
      if (q.qty) { try { plan = allocate(rows, q.qty, s, {}, item.name); } catch { plan = null; } }
      return {
        itemId: item.id, fefo: s.fefo,
        candidates: order.map((r) => ({ binId: r.binId, binCode: r.binCode, batchId: r.batchId, batchNo: r.batchNo, expiryDate: r.expiryDate, qty: r.qty })),
        ...(q.qty ? { requested: q.qty, plan, enough: plan !== null } : {}),
      };
    });
  });

  app.get('/warehouse/expiry', async (req) => {
    const ctx = req.ctx; use(ctx);
    const q = parse(expiryQuery, req.query);
    return ctx.tx(async (tx) => {
      const s = await loadSettings(tx, ctx.companyId);
      const days = q.days ?? s.expiryWarnDays;
      const limit = addDays(todayIst(), days);
      let base = tx.selectFrom('wh_moves as m')
        .innerJoin('wh_batches as t', 't.id', 'm.batch_id').innerJoin('items as i', 'i.id', 'm.item_id')
        .innerJoin('locations as l', 'l.id', 'm.location_id')
        .where('m.company_id', '=', ctx.companyId).where('t.expiry_date', '<=', limit);
      if (q.locationId) base = base.where('m.location_id', '=', q.locationId);
      const grouped = base.groupBy(['m.item_id', 'm.location_id', 'm.batch_id', 'i.name', 'l.name', 't.batch_no', 't.expiry_date'])
        .having((eb) => eb(eb.fn.sum('m.qty'), '>', 0))
        .select((eb) => ['m.item_id', 'm.location_id', 'm.batch_id', 'i.name as item_name', 'l.name as location_name', 't.batch_no', 't.expiry_date', eb.fn.sum<number>('m.qty').as('qty')]);
      const rows = await grouped.orderBy('t.expiry_date').orderBy('i.name').execute();
      const today = todayIst();
      const data = rows.slice(q.offset, q.offset + q.limit).map((r) => ({
        itemId: r.item_id, itemName: r.item_name, locationId: r.location_id, locationName: r.location_name, batchId: r.batch_id,
        batchNo: r.batch_no, expiryDate: r.expiry_date, qty: Number(r.qty), expired: !!r.expiry_date && r.expiry_date < today,
      }));
      return { data, total: rows.length, days };
    });
  });

  // ---- receive into a bin and batch
  app.post('/warehouse/receipts', async (req, reply) => {
    const ctx = req.ctx; work(ctx);
    const b = parse(receiptBody, req.body);
    const out = await ctx.tx((tx) => receiveStock(tx, ctx, b));
    return reply.status(201).send(out);
  });

  // ---- putaway: move placed stock from one bin to another
  app.post('/warehouse/putaway', async (req, reply) => {
    const ctx = req.ctx; work(ctx);
    const b = parse(putawayBody, req.body);
    const out = await ctx.tx(async (tx) => {
      const loc = await getLocation(tx, ctx, b.locationId);
      const item = await itemOf(tx, ctx, b.itemId);
      const to = await binOf(tx, ctx, b.toBinId, loc.id);
      const fromId = b.fromBinId ?? null;
      const batchId = b.batchId ?? null;
      if (fromId) await binOf(tx, ctx, fromId, loc.id).catch((e) => { if ((e as { status?: number }).status === 400) return null; throw e; });
      if (fromId === to.id) throw badRequest('Source and target bin are the same.', { toBinId: 'Same bin' });
      await lockItems(tx, ctx.companyId, [item.id]);
      const src = (await balances(tx, ctx.companyId, loc.id, item.id)).find((r) => r.binId === fromId && r.batchId === batchId);
      if (!src || src.qty + 0.0005 < b.qty) {
        throw conflict(`Only ${src?.qty ?? 0} ${item.unit} of ${item.name} is in that bin and batch.`, 'INSUFFICIENT_BIN_STOCK', { available: src?.qty ?? 0, required: b.qty });
      }
      if (isExpired(src.expiryDate) && to.kind !== 'quarantine') {
        throw conflict('Expired stock can only be moved to a quarantine bin.', 'BATCH_EXPIRED', { batchId });
      }
      await checkCapacity(tx, ctx.companyId, to, b.qty);
      if (b.serialNos?.length) {
        if (b.serialNos.length !== b.qty) throw badRequest(`Give ${b.qty} serial numbers; got ${b.serialNos.length}.`, { serialNos: 'Count must equal quantity' });
        const found = await tx.selectFrom('wh_serials').select('serial_no').where('company_id', '=', ctx.companyId).where('item_id', '=', item.id)
          .where('serial_no', 'in', b.serialNos).where('location_id', '=', loc.id).where('status', '=', 'in_stock')
          .where(fromId ? sql<boolean>`bin_id = ${fromId}` : sql<boolean>`bin_id is null`).execute();
        if (found.length !== b.serialNos.length) throw badRequest('A serial number is not in the source bin.', { serialNos: 'Not in source bin' });
        await tx.updateTable('wh_serials').set({ bin_id: to.id }).where('company_id', '=', ctx.companyId).where('item_id', '=', item.id).where('serial_no', 'in', b.serialNos).execute();
      }
      const base = { tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: loc.id, item_id: item.id, batch_id: batchId, ref_type: null, ref_id: null, note: b.note ?? null, created_by: ctx.userId };
      await tx.insertInto('wh_moves').values({ ...base, bin_id: fromId, qty: -b.qty, kind: 'putaway_out' }).execute();
      const inn = await tx.insertInto('wh_moves').values({ ...base, bin_id: to.id, qty: b.qty, kind: 'putaway_in' }).returningAll().executeTakeFirstOrThrow();
      await writeAudit(tx, auditOf(ctx), 'wh_move', inn.id, 'putaway', { binId: fromId }, { binId: to.id, itemId: item.id, batchId, qty: b.qty });
      return { itemId: item.id, fromBinId: fromId, toBinId: to.id, batchId, qty: b.qty };
    });
    return reply.status(201).send(out);
  });

  // ---- pick by bin (FEFO unless a bin or batch is named)
  app.post('/warehouse/picks', async (req, reply) => {
    const ctx = req.ctx; work(ctx);
    const b = parse(pickBody, req.body);
    const out = await ctx.tx((tx) => pickLines(tx, ctx, b));
    return reply.status(201).send(out);
  });
  // ---- turn a pick list into a sale (the stock already left the bins when it was picked)
  const saleBody = z.object({
    partyId: z.uuid(), invoiceDate: z.string().refine(isValidDate, 'Use YYYY-MM-DD').optional(), notes: optionalText(1000),
    lines: z.array(z.object({ itemId: z.uuid(), rate: moneyField.optional(), discountPct: z.coerce.number().min(0).max(100).optional() })).max(200).optional(),
  });
  app.post<{ Params: { refId: string } }>('/warehouse/picks/:refId/invoice', async (req, reply) => {
    const ctx = req.ctx; work(ctx); ctx.require('invoices.create');
    const b = parse(saleBody, req.body);
    const refId = parse(z.uuid(), req.params.refId);
    const { createInvoice } = await import('./invoices.ts');
    const out = await ctx.tx(async (tx) => {
      const moves = await tx.selectFrom('wh_moves').select(['location_id', 'item_id', 'qty']).where('company_id', '=', ctx.companyId)
        .where('ref_id', '=', refId).where('kind', '=', 'pick').where('ref_type', '=', 'pick').execute();
      if (!moves.length) throw notFound('Pick list');
      const linked = await tx.selectFrom('wh_pick_links').select('invoice_id').where('pick_ref_id', '=', refId).executeTakeFirst();
      if (linked) throw conflict('This pick list has already been billed.', 'PICK_ALREADY_BILLED', { invoiceId: linked.invoice_id });
      const qty = new Map<string, number>();
      for (const m of moves) qty.set(m.item_id, round3((qty.get(m.item_id) ?? 0) - Number(m.qty)));
      const over = new Map((b.lines ?? []).map((l) => [l.itemId, l]));
      // A pick whose invoice was cancelled has gone back to the bins: take it out again for the new sale.
      const reversed = await tx.selectFrom('wh_moves').select('id').where('company_id', '=', ctx.companyId).where('ref_id', '=', refId).where('ref_type', '=', 'pick_reversal').limit(1).executeTakeFirst();
      if (reversed) {
        await pickLines(tx, ctx, { locationId: moves[0]!.location_id, refType: 'pick_again', refId, lines: [...qty].filter(([, q]) => q > 0.0005).map(([itemId, q]) => ({ itemId, qty: q })) });
      }
      const lines = [...qty].filter(([, q]) => q > 0.0005).map(([itemId, q]) => ({ itemId, qty: q, rate: over.get(itemId)?.rate, discountPct: over.get(itemId)?.discountPct }));
      if (!lines.length) throw badRequest('Nothing picked on this list.', { refId: 'Empty pick list' });
      skipHook.add(tx);
      let inv;
      try {
        inv = await createInvoice(ctx, tx, { locationId: moves[0]!.location_id, partyId: b.partyId, invoiceDate: b.invoiceDate, notes: b.notes ?? 'Pick list sale', lines } as never);
      } finally { skipHook.delete(tx); }
      await tx.insertInto('wh_pick_links').values({ pick_ref_id: refId, tenant_id: ctx.tenantId, company_id: ctx.companyId, invoice_id: inv.id, created_by: ctx.userId }).execute();
      await writeAudit(tx, auditOf(ctx), 'invoice', inv.id, 'pick_to_sale', null, { pickRefId: refId });
      return { pickRefId: refId, invoice: inv };
    });
    return reply.status(201).send(out);
  });
}

documentRoute('PATCH', '/warehouse/bins/:id', { body: binPatch });
documentRoute('PATCH', '/warehouse/batches/:id', { body: batchPatch });
documentRoute('POST', '/warehouse/receipts', { body: receiptBody });
documentRoute('POST', '/warehouse/putaway', { body: putawayBody });
documentRoute('POST', '/warehouse/picks', { body: pickBody });
