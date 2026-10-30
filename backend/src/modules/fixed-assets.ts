import type { FastifyInstance } from 'fastify';
import { z } from 'zod';
import { systemAccounts } from '../accounting/accounts.ts';
import { postJournal, reverseEntry } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { addDays, daysBetween, financialYear, fyStart, todayIst } from '../lib/dates.ts';
import { blockDepreciation, bookDepreciation, HALF_RATE_DAYS } from '../lib/depreciation.ts';
import { badRequest, conflict, notFound } from '../lib/errors.ts';
import { nullableText } from '../lib/india.ts';
import { likeTerm } from '../lib/paging.ts';
import { nextNumber } from '../lib/series.ts';
import { docDate, money, name, notes, parse } from '../lib/validate.ts';
import { auditOf, writeAudit } from './audit.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;
const fyField = z.string().regex(/^\d{4}-\d{2}$/, 'Use a financial year such as 2026-27');
const cancelBody = z.object({ reason: z.string().trim().min(3, 'Give a reason').max(300) });
const optText = (max: number) => nullableText(max);

const createBody = z.object({
  name,
  blockCode: z.string().trim().min(1).max(40),
  bookMethod: z.enum(['slm', 'wdv']),
  usefulLifeYears: z.coerce.number().min(1).max(100),
  residualPct: z.coerce.number().min(0).max(99.99).optional(),
  cost: money.refine((v) => v > 0, 'Must be above zero'),
  gstItc: money.optional(),
  purchaseDate: docDate,
  putToUseDate: docDate,
  sourceAccountId: z.uuid(),
  openingAccDep: money.optional(),
  locationId: z.uuid().nullable().optional(),
  supplierName: optText(200), billNo: optText(50), serialNo: optText(100), tagNo: optText(100), custodian: optText(200), notes: optText(2000),
}).refine((b) => b.putToUseDate >= b.purchaseDate, { message: 'Must be on or after the purchase date', path: ['putToUseDate'] })
  .refine((b) => (b.openingAccDep ?? 0) <= b.cost, { message: 'Cannot exceed the cost', path: ['openingAccDep'] });

const patchBody = z.object({
  name: name.optional(),
  locationId: z.uuid().nullable().optional(),
  serialNo: optText(100), tagNo: optText(100), custodian: optText(200), notes: optText(2000),
  usefulLifeYears: z.coerce.number().min(1).max(100).optional(),
  residualPct: z.coerce.number().min(0).max(99.99).optional(),
});
const listQuery = z.object({
  status: z.enum(['active', 'disposed']).optional(),
  blockCode: z.string().trim().max(40).optional(),
  q: z.string().trim().max(100).optional(),
  locationId: z.uuid().optional(),
});
const runBody = z.object({ toDate: docDate, assetIds: z.array(z.uuid()).min(1).max(500).optional() });
const disposeBody = z.object({
  date: docDate, saleValue: money, receivedInAccountId: z.uuid().optional(), notes: notes.optional(),
});
const openingBody = z.object({ fy: fyField, blockCode: z.string().trim().min(1).max(40), openingWdv: money });

// --- IT blocks ---------------------------------------------------------------------------------

interface BlockRow { code: string; name: string; rate: number; effective_from: string; verified: boolean }

/** The block rate rows in force at `date` (latest effective_from on or before it; earliest if none yet). */
async function blocksAt(tx: Tx, date: string): Promise<Map<string, BlockRow>> {
  const rows = await tx.selectFrom('it_depreciation_blocks').selectAll().orderBy('effective_from').execute();
  const m = new Map<string, BlockRow>();
  for (const r of rows) {
    const cur = m.get(r.code);
    if (!cur || r.effective_from <= date) m.set(r.code, { ...r, rate: Number(r.rate) });
  }
  return m;
}

const fyEnd = (fy: string) => `${Number(fy.slice(0, 4)) + 1}-03-31`;
const nextFy = (fy: string) => `${Number(fy.slice(0, 4)) + 1}-${String((Number(fy.slice(0, 4)) + 2) % 100).padStart(2, '0')}`;

export interface ItBlockRow {
  blockCode: string; blockName: string; rate: number; openingWdv: number; additionsFull: number; additionsHalf: number;
  saleValue: number; depreciation: number; closingWdv: number; shortTermGain: number;
}

/** Income-tax block schedule for a financial year, chained from the first-year openings (API v1.6 §7). */
export async function itSchedule(tx: Tx, companyId: string, fy: string) {
  const [assets, openings] = await Promise.all([
    tx.selectFrom('fixed_assets').select(['block_code', 'cost', 'put_to_use_date', 'status', 'disposal_date', 'sale_value'])
      .where('company_id', '=', companyId).execute(),
    tx.selectFrom('it_block_openings').select(['fy', 'block_code', 'opening_wdv']).where('company_id', '=', companyId).execute(),
  ]);
  const rows: ItBlockRow[] = [];
  const unverified: string[] = [];
  const codes = [...new Set([...assets.map((a) => a.block_code), ...openings.map((o) => o.block_code)])].filter((c) => c !== 'land').sort();
  for (const code of codes) {
    const mine = assets.filter((a) => a.block_code === code);
    const opens = openings.filter((o) => o.block_code === code);
    const starts = [...opens.map((o) => o.fy)];
    if (!starts.length) starts.push(...mine.map((a) => financialYear(a.put_to_use_date)));
    if (!starts.length) continue;
    const start = starts.sort()[0]!;
    if (start > fy) continue;
    let prevClosing = 0;
    let result: ItBlockRow | null = null;
    let verified = true;
    let name = code;
    for (let f = start, n = 0; f <= fy && n < 60; f = nextFy(f), n++) {
      const blk = (await blocksAt(tx, `${f.slice(0, 4)}-04-01`)).get(code);
      if (!blk) break;
      name = blk.name;
      verified = blk.verified;
      const override = opens.find((o) => o.fy === f);
      const opening = override ? Number(override.opening_wdv) : prevClosing;
      let full = 0;
      let half = 0;
      let sale = 0;
      for (const a of mine) {
        if (financialYear(a.put_to_use_date) === f) {
          const days = daysBetween(a.put_to_use_date, fyEnd(f)) + 1;
          if (days >= HALF_RATE_DAYS) full += a.cost; else half += a.cost;
        }
        if (a.status === 'disposed' && a.disposal_date && financialYear(a.disposal_date) === f) sale += a.sale_value ?? 0;
      }
      const r = blockDepreciation({ rate: blk.rate, opening, additionsFull: full, additionsHalf: half, saleValue: sale });
      prevClosing = r.closingWdv;
      result = { blockCode: code, blockName: blk.name, rate: blk.rate, ...r };
    }
    if (!result) continue;
    const active = [result.openingWdv, result.additionsFull, result.additionsHalf, result.saleValue, result.depreciation, result.closingWdv].some((v) => v !== 0);
    if (!active) continue;
    rows.push(result);
    if (!verified) unverified.push(`Income-tax depreciation rate for ${name} (${result.rate}%)`);
  }
  const sum = (k: keyof ItBlockRow) => round2(rows.reduce((s, r) => s + (r[k] as number), 0));
  const totals = {
    openingWdv: sum('openingWdv'), additionsFull: sum('additionsFull'), additionsHalf: sum('additionsHalf'), saleValue: sum('saleValue'),
    depreciation: sum('depreciation'), closingWdv: sum('closingWdv'), shortTermGain: sum('shortTermGain'),
  };
  return { fy, rows, totals, unverified };
}

// --- Assets ------------------------------------------------------------------------------------

function assetSelect(tx: Tx, companyId: string) {
  return tx.selectFrom('fixed_assets as f')
    .leftJoin('locations as l', 'l.id', 'f.location_id')
    .selectAll('f').select('l.name as location_name')
    .where('f.company_id', '=', companyId);
}
type AssetRow = Awaited<ReturnType<ReturnType<typeof assetSelect>['execute']>>[number];

function assetJson(r: AssetRow, blocks: Map<string, BlockRow>) {
  const opening = Number(r.opening_acc_dep);
  const total = round2(opening + Number(r.accumulated_dep));
  return {
    id: r.id, number: r.number, name: r.name, blockCode: r.block_code, blockName: blocks.get(r.block_code)?.name ?? r.block_code,
    bookMethod: r.book_method, usefulLifeYears: Number(r.useful_life_years), residualPct: Number(r.residual_pct), cost: Number(r.cost),
    gstItc: Number(r.gst_itc), purchaseDate: r.purchase_date, putToUseDate: r.put_to_use_date, locationId: r.location_id,
    locationName: r.location_name, supplierName: r.supplier_name, billNo: r.bill_no, serialNo: r.serial_no, tagNo: r.tag_no,
    custodian: r.custodian, notes: r.notes, openingAccDep: opening,
    /** Total accumulated depreciation: the opening amount plus what the runs have charged. */
    accumulatedDep: total, bookValue: round2(Number(r.cost) - total), depreciatedUntil: r.depreciated_until, status: r.status,
    disposal: r.status === 'disposed'
      ? { date: r.disposal_date, saleValue: Number(r.sale_value ?? 0), gainLoss: Number(r.gain_loss ?? 0), entryId: r.disposal_entry_id }
      : null,
    createdAt: r.created_at,
  };
}

async function loadAsset(tx: Tx, ctx: RequestContext, id: string) {
  const row = await assetSelect(tx, ctx.companyId).where('f.id', '=', id).executeTakeFirst();
  if (!row) throw notFound('Fixed asset');
  return assetJson(row, await blocksAt(tx, todayIst()));
}

async function checkPostingAccount(tx: Tx, ctx: RequestContext, id: string, field: string) {
  const acc = await systemAccounts(tx, ctx);
  const a = await tx.selectFrom('accounts').select(['id', 'is_active']).where('id', '=', id).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!a || !a.is_active) throw badRequest('Choose an active account.', { [field]: 'Not found or inactive' });
  if (id === acc.fixed_assets || id === acc.accumulated_depreciation) {
    throw badRequest('Fixed Assets and Accumulated Depreciation cannot be used here.', { [field]: 'Not allowed' });
  }
  return acc;
}

// --- Depreciation runs -------------------------------------------------------------------------

interface RunLine { assetId: string; number: string; name: string; from: string; to: string; days: number; amount: number }
interface PlanAsset {
  id: string; number: string; name: string; block_code: string; book_method: string; useful_life_years: number; residual_pct: number;
  cost: number; opening_acc_dep: number; accumulated_dep: number; put_to_use_date: string; depreciated_until: string | null;
}

/** Lines for one run up to `toDate`. `overlap` counts assets already depreciated to or past it. */
function planRun(assets: PlanAsset[], toDate: string) {
  const lines: RunLine[] = [];
  let overlap = 0;
  for (const a of assets) {
    if (a.block_code === 'land') continue;
    if (a.depreciated_until && a.depreciated_until >= toDate) { overlap++; continue; }
    const from = a.depreciated_until ? addDays(a.depreciated_until, 1) : a.put_to_use_date;
    if (from > toDate) continue;
    const days = daysBetween(from, toDate) + 1;
    const amount = bookDepreciation({
      method: a.book_method as 'slm' | 'wdv', cost: Number(a.cost), residualPct: Number(a.residual_pct), lifeYears: Number(a.useful_life_years),
      accumulated: Number(a.opening_acc_dep) + Number(a.accumulated_dep),
    }, days);
    if (amount > 0) lines.push({ assetId: a.id, number: a.number, name: a.name, from, to: toDate, days, amount });
  }
  return { lines, overlap };
}

const runJson = (r: { id: string | null; number: string | null; lines: RunLine[]; toDate: string; entryId: string | null }) => ({
  id: r.id, number: r.number, fromDates: [...new Set(r.lines.map((l) => l.from))].sort(), toDate: r.toDate,
  lines: r.lines, total: round2(r.lines.reduce((s, l) => s + l.amount, 0)), entryId: r.entryId,
});

const planAssetCols = ['id', 'number', 'name', 'block_code', 'book_method', 'useful_life_years', 'residual_pct', 'cost',
  'opening_acc_dep', 'accumulated_dep', 'put_to_use_date', 'depreciated_until'] as const;

/** Posts a run: run row, lines, asset updates and the depreciation journal. Assets must be locked by the caller. */
async function postRun(tx: Tx, ctx: RequestContext, assets: PlanAsset[], lines: RunLine[], toDate: string) {
  const number = await nextNumber(tx, ctx, 'depreciation_run', financialYear(toDate));
  const total = round2(lines.reduce((s, l) => s + l.amount, 0));
  const run = await tx.insertInto('depreciation_runs').values({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, number, to_date: toDate, total, created_by: ctx.userId,
    cancelled_at: null, cancel_reason: null, entry_id: null,
  }).returning('id').executeTakeFirstOrThrow();
  for (const l of lines) {
    const a = assets.find((x) => x.id === l.assetId)!;
    await tx.insertInto('depreciation_run_lines').values({
      tenant_id: ctx.tenantId, run_id: run.id, asset_id: l.assetId, from_date: l.from, to_date: l.to, days: l.days, amount: l.amount,
      prev_depreciated_until: a.depreciated_until,
    }).execute();
    await tx.updateTable('fixed_assets')
      .set({ accumulated_dep: round2(Number(a.accumulated_dep) + l.amount), depreciated_until: l.to })
      .where('id', '=', l.assetId).execute();
  }
  const acc = await systemAccounts(tx, ctx);
  const entryId = await postJournal(tx, auditOf(ctx), {
    date: toDate, voucherType: 'depreciation', voucherId: run.id, number, narration: `Depreciation to ${toDate}`,
    lines: [{ accountId: acc.depreciation, amount: total }, { accountId: acc.accumulated_depreciation, amount: -total }],
  });
  await tx.updateTable('depreciation_runs').set({ entry_id: entryId }).where('id', '=', run.id).execute();
  await writeAudit(tx, auditOf(ctx), 'depreciation_run', run.id, 'create', null, { number, toDate, total, assets: lines.length });
  return { id: run.id, number, entryId };
}

export async function fixedAssetRoutes(app: FastifyInstance) {
  app.get('/fixed-assets/blocks', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.view');
    return ctx.tx(async (tx) => {
      const blocks = await blocksAt(tx, todayIst());
      return { data: [...blocks.values()].map((b) => ({ code: b.code, name: b.name, rate: b.rate, effectiveFrom: b.effective_from, verified: b.verified })) };
    });
  });

  app.get('/fixed-assets/it-schedule', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.view');
    const q = parse(z.object({ fy: fyField.optional() }), req.query);
    return ctx.tx((tx) => itSchedule(tx, ctx.companyId, q.fy ?? financialYear(todayIst())));
  });

  app.post('/fixed-assets/it-openings', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.manage');
    const b = parse(openingBody, req.body);
    return ctx.tx(async (tx) => {
      const blk = (await blocksAt(tx, `${b.fy.slice(0, 4)}-04-01`)).get(b.blockCode);
      if (!blk) throw badRequest('Unknown block.', { blockCode: 'Not found' });
      await tx.insertInto('it_block_openings').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, fy: b.fy, block_code: b.blockCode, opening_wdv: b.openingWdv,
      }).onConflict((oc) => oc.columns(['company_id', 'fy', 'block_code']).doUpdateSet({ opening_wdv: b.openingWdv, updated_at: new Date() })).execute();
      await writeAudit(tx, auditOf(ctx), 'it_block_opening', null, 'update', null, b);
      return { fy: b.fy, blockCode: b.blockCode, openingWdv: b.openingWdv };
    });
  });

  app.get('/fixed-assets', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.view');
    const q = parse(listQuery, req.query);
    return ctx.tx(async (tx) => {
      let base = assetSelect(tx, ctx.companyId);
      if (q.status) base = base.where('f.status', '=', q.status);
      if (q.blockCode) base = base.where('f.block_code', '=', q.blockCode);
      if (q.locationId) base = base.where('f.location_id', '=', q.locationId);
      if (q.q) {
        const t = likeTerm(q.q);
        base = base.where((eb) => eb.or([eb('f.name', 'ilike', t), eb('f.number', 'ilike', t), eb('f.serial_no', 'ilike', t), eb('f.tag_no', 'ilike', t)]));
      }
      const rows = await base.orderBy('f.number').execute();
      const blocks = await blocksAt(tx, todayIst());
      const data = rows.map((r) => assetJson(r, blocks));
      return {
        data, total: data.length,
        totals: {
          cost: round2(data.reduce((s, a) => s + a.cost, 0)),
          accumulatedDep: round2(data.reduce((s, a) => s + a.accumulatedDep, 0)),
          bookValue: round2(data.reduce((s, a) => s + a.bookValue, 0)),
        },
      };
    });
  });

  app.get<{ Params: { id: string } }>('/fixed-assets/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.view');
    const id = parse(z.uuid(), req.params.id);
    return ctx.tx(async (tx) => {
      const asset = await loadAsset(tx, ctx, id);
      const row = await tx.selectFrom('fixed_assets').select('capitalise_entry_id').where('id', '=', id).executeTakeFirstOrThrow();
      const runs = await tx.selectFrom('depreciation_run_lines as l').innerJoin('depreciation_runs as r', 'r.id', 'l.run_id')
        .select(['l.to_date', 'l.amount', 'r.entry_id']).where('l.asset_id', '=', id).where('r.status', '=', 'posted').execute();
      const history: { date: string; kind: string; amount: number; entryId: string | null }[] = [
        { date: asset.putToUseDate, kind: 'capitalise', amount: asset.cost, entryId: row.capitalise_entry_id },
        ...runs.map((r) => ({ date: r.to_date, kind: 'depreciation', amount: Number(r.amount), entryId: r.entry_id })),
      ];
      if (asset.disposal) history.push({ date: asset.disposal.date!, kind: 'disposal', amount: asset.disposal.saleValue, entryId: asset.disposal.entryId });
      history.sort((a, b) => a.date.localeCompare(b.date));
      return { ...asset, history };
    });
  });

  app.post('/fixed-assets', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('assets.manage');
    const b = parse(createBody, req.body);
    const asset = await ctx.tx(async (tx) => {
      if (!(await blocksAt(tx, b.putToUseDate)).get(b.blockCode)) throw badRequest('Unknown block.', { blockCode: 'Not found' });
      const acc = await checkPostingAccount(tx, ctx, b.sourceAccountId, 'sourceAccountId');
      if (b.locationId) {
        const loc = await tx.selectFrom('locations').select('id').where('id', '=', b.locationId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!loc) throw badRequest('Location not found.', { locationId: 'Not found' });
      }
      const opening = b.openingAccDep ?? 0;
      const number = await nextNumber(tx, ctx, 'fixed_asset', financialYear(b.putToUseDate));
      // Opening accumulated depreciation is taken as charged up to the last financial year end.
      const lastYearEnd = addDays(fyStart(todayIst()), -1);
      const until = opening > 0 && b.putToUseDate <= lastYearEnd ? lastYearEnd : null;
      const row = await tx.insertInto('fixed_assets').values({
        tenant_id: ctx.tenantId, company_id: ctx.companyId, number, name: b.name, block_code: b.blockCode, book_method: b.bookMethod,
        useful_life_years: b.usefulLifeYears, residual_pct: b.residualPct ?? 5, cost: b.cost, gst_itc: b.gstItc ?? 0,
        purchase_date: b.purchaseDate, put_to_use_date: b.putToUseDate, location_id: b.locationId ?? null,
        supplier_name: b.supplierName ?? null, bill_no: b.billNo ?? null, serial_no: b.serialNo ?? null, tag_no: b.tagNo ?? null,
        custodian: b.custodian ?? null, notes: b.notes ?? null, opening_acc_dep: opening, depreciated_until: until,
        disposal_date: null, sale_value: null, gain_loss: null, capitalise_entry_id: null, disposal_entry_id: null, created_by: ctx.userId,
      }).returning('id').executeTakeFirstOrThrow();
      const entryId = await postJournal(tx, auditOf(ctx), {
        date: b.putToUseDate, voucherType: 'asset_capitalise', voucherId: row.id, number, narration: `Capitalised ${b.name}`,
        lines: [
          { accountId: acc.fixed_assets, amount: b.cost },
          { accountId: b.sourceAccountId, amount: -b.cost },
          { accountId: acc.opening_balances, amount: opening },
          { accountId: acc.accumulated_depreciation, amount: -opening },
        ],
      });
      await tx.updateTable('fixed_assets').set({ capitalise_entry_id: entryId }).where('id', '=', row.id).execute();
      await writeAudit(tx, auditOf(ctx), 'fixed_asset', row.id, 'create', null, { number, name: b.name, cost: b.cost, openingAccDep: opening });
      return loadAsset(tx, ctx, row.id);
    });
    return reply.status(201).send(asset);
  });

  app.patch<{ Params: { id: string } }>('/fixed-assets/:id', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(patchBody, req.body);
    return ctx.tx(async (tx) => {
      const a = await tx.selectFrom('fixed_assets').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!a) throw notFound('Fixed asset');
      if (a.status === 'disposed') throw conflict('This asset has been disposed of.', 'ASSET_DISPOSED');
      if (b.locationId) {
        const loc = await tx.selectFrom('locations').select('id').where('id', '=', b.locationId).where('company_id', '=', ctx.companyId).executeTakeFirst();
        if (!loc) throw badRequest('Location not found.', { locationId: 'Not found' });
      }
      const changes = Object.fromEntries(Object.entries({
        name: b.name, location_id: b.locationId, serial_no: b.serialNo, tag_no: b.tagNo, custodian: b.custodian, notes: b.notes,
        useful_life_years: b.usefulLifeYears, residual_pct: b.residualPct,
      }).filter(([, v]) => v !== undefined));
      if (Object.keys(changes).length) {
        await tx.updateTable('fixed_assets').set(changes).where('id', '=', id).execute();
        await writeAudit(tx, auditOf(ctx), 'fixed_asset', id, 'update', null, changes);
      }
      return loadAsset(tx, ctx, id);
    });
  });

  app.post('/fixed-assets/depreciation-runs', async (req, reply) => {
    const ctx = req.ctx;
    ctx.require('assets.manage');
    const b = parse(runBody, req.body);
    const { preview } = parse(z.object({ preview: z.enum(['true', 'false']).optional() }), req.query);
    const result = await ctx.tx(async (tx) => {
      let q = tx.selectFrom('fixed_assets').select([...planAssetCols])
        .where('company_id', '=', ctx.companyId).where('status', '=', 'active').orderBy('id');
      if (b.assetIds) q = q.where('id', 'in', [...new Set(b.assetIds)]);
      if (preview !== 'true') q = q.forUpdate();
      const assets = await q.execute();
      if (b.assetIds && assets.length !== new Set(b.assetIds).size) throw badRequest('Some assets were not found or are disposed.', { assetIds: 'Not found or disposed' });
      const { lines, overlap } = planRun(assets, b.toDate);
      if (preview === 'true') return { status: 200, body: runJson({ id: null, number: null, lines, toDate: b.toDate, entryId: null }) };
      if (!lines.length) {
        if (overlap) throw conflict('Every selected asset is already depreciated up to this date.', 'RUN_OVERLAP', { toDate: b.toDate });
        throw badRequest('There is nothing to depreciate up to this date.', { toDate: 'Nothing to depreciate' });
      }
      const posted = await postRun(tx, ctx, assets, lines, b.toDate);
      return { status: 201, body: runJson({ ...posted, lines, toDate: b.toDate }) };
    });
    return reply.status(result.status).send(result.body);
  });

  app.get('/fixed-assets/depreciation-runs', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.view');
    const q = parse(z.object({ fy: fyField.optional() }), req.query);
    return ctx.tx(async (tx) => {
      let base = tx.selectFrom('depreciation_runs').selectAll().where('company_id', '=', ctx.companyId);
      if (q.fy) base = base.where('to_date', '>=', `${q.fy.slice(0, 4)}-04-01`).where('to_date', '<=', fyEnd(q.fy));
      const runs = await base.orderBy('to_date', 'desc').orderBy('created_at', 'desc').execute();
      const lines = runs.length
        ? await tx.selectFrom('depreciation_run_lines as l').innerJoin('fixed_assets as a', 'a.id', 'l.asset_id')
          .select(['l.run_id', 'l.asset_id', 'a.number', 'a.name', 'l.from_date', 'l.to_date', 'l.days', 'l.amount'])
          .where('l.run_id', 'in', runs.map((r) => r.id)).orderBy('a.number').execute()
        : [];
      const data = runs.map((r) => {
        const ls: RunLine[] = lines.filter((l) => l.run_id === r.id).map((l) => ({
          assetId: l.asset_id, number: l.number, name: l.name, from: l.from_date, to: l.to_date, days: l.days, amount: Number(l.amount),
        }));
        return { ...runJson({ id: r.id, number: r.number, lines: ls, toDate: r.to_date, entryId: r.entry_id }), total: Number(r.total), status: r.status, createdAt: r.created_at, cancelReason: r.cancel_reason };
      });
      return { data, total: data.length };
    });
  });

  app.post<{ Params: { id: string } }>('/fixed-assets/depreciation-runs/:id/cancel', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.manage');
    const id = parse(z.uuid(), req.params.id);
    const { reason } = parse(cancelBody, req.body);
    return ctx.tx(async (tx) => {
      const run = await tx.selectFrom('depreciation_runs').selectAll().where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!run) throw notFound('Depreciation run');
      if (run.status === 'cancelled') throw conflict('This run is already cancelled.', 'ALREADY_CANCELLED');
      const latest = await tx.selectFrom('depreciation_runs').select('id').where('company_id', '=', ctx.companyId).where('status', '=', 'posted')
        .orderBy('created_at', 'desc').orderBy('number', 'desc').limit(1).executeTakeFirstOrThrow();
      if (latest.id !== id) throw conflict('Only the latest depreciation run can be cancelled.', 'NOT_LATEST', { latestRunId: latest.id });
      const lines = await tx.selectFrom('depreciation_run_lines').selectAll().where('run_id', '=', id).orderBy('asset_id').execute();
      const assets = lines.length
        ? await tx.selectFrom('fixed_assets').select(['id', 'status', 'accumulated_dep']).where('id', 'in', lines.map((l) => l.asset_id)).orderBy('id').forUpdate().execute()
        : [];
      if (assets.some((a) => a.status === 'disposed')) throw conflict('An asset in this run has been disposed of.', 'ASSET_DISPOSED');
      for (const l of lines) {
        const a = assets.find((x) => x.id === l.asset_id)!;
        await tx.updateTable('fixed_assets')
          .set({ accumulated_dep: round2(Math.max(0, Number(a.accumulated_dep) - Number(l.amount))), depreciated_until: l.prev_depreciated_until })
          .where('id', '=', l.asset_id).execute();
      }
      if (run.entry_id) await reverseEntry(tx, auditOf(ctx), run.entry_id, todayIst(), `Cancelled ${run.number}: ${reason}`);
      await tx.updateTable('depreciation_runs').set({ status: 'cancelled', cancelled_at: new Date(), cancel_reason: reason }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'depreciation_run', id, 'cancel', { status: 'posted' }, { status: 'cancelled', reason });
      return { id, number: run.number, status: 'cancelled', cancelReason: reason };
    });
  });

  app.post<{ Params: { id: string } }>('/fixed-assets/:id/dispose', async (req) => {
    const ctx = req.ctx;
    ctx.require('assets.manage');
    const id = parse(z.uuid(), req.params.id);
    const b = parse(disposeBody, req.body);
    return ctx.tx(async (tx) => {
      const a = await tx.selectFrom('fixed_assets').select([...planAssetCols, 'status', 'name']).where('id', '=', id).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
      if (!a) throw notFound('Fixed asset');
      if (a.status === 'disposed') throw conflict('This asset has already been disposed of.', 'ASSET_DISPOSED');
      if (b.date < a.put_to_use_date) throw badRequest('Cannot be before the put-to-use date.', { date: 'Before put-to-use date' });
      if (a.depreciated_until && a.depreciated_until > b.date) {
        throw conflict('Depreciation is already posted beyond this date. Cancel the later runs first.', 'RUN_OVERLAP', { depreciatedUntil: a.depreciated_until });
      }
      if (b.saleValue > 0 && !b.receivedInAccountId) throw badRequest('Choose where the sale amount was received.', { receivedInAccountId: 'Required when the sale value is above zero' });
      let acc = await systemAccounts(tx, ctx);
      if (b.receivedInAccountId) acc = await checkPostingAccount(tx, ctx, b.receivedInAccountId, 'receivedInAccountId');

      // Depreciation is first charged up to the disposal date.
      const { lines } = planRun([a], b.date);
      let current = a;
      if (lines.length) {
        await postRun(tx, ctx, [a], lines, b.date);
        current = { ...a, accumulated_dep: round2(Number(a.accumulated_dep) + lines[0]!.amount) };
      }
      const accTotal = round2(Number(current.opening_acc_dep) + Number(current.accumulated_dep));
      const cost = Number(a.cost);
      const gainLoss = round2(b.saleValue - (cost - accTotal));
      const entryId = await postJournal(tx, auditOf(ctx), {
        date: b.date, voucherType: 'asset_disposal', voucherId: id, number: a.number, narration: b.notes ? `Disposal of ${a.name}: ${b.notes}` : `Disposal of ${a.name}`,
        lines: [
          { accountId: acc.accumulated_depreciation, amount: accTotal },
          ...(b.saleValue > 0 ? [{ accountId: b.receivedInAccountId!, amount: b.saleValue }] : []),
          { accountId: acc.fixed_assets, amount: -cost },
          ...(gainLoss > 0 ? [{ accountId: acc.asset_gain, amount: -gainLoss }] : gainLoss < 0 ? [{ accountId: acc.asset_loss, amount: -gainLoss }] : []),
        ],
      });
      await tx.updateTable('fixed_assets').set({
        status: 'disposed', disposal_date: b.date, sale_value: b.saleValue, gain_loss: gainLoss, disposal_entry_id: entryId,
      }).where('id', '=', id).execute();
      await writeAudit(tx, auditOf(ctx), 'fixed_asset', id, 'dispose', null, { date: b.date, saleValue: b.saleValue, gainLoss });
      return loadAsset(tx, ctx, id);
    });
  });
}
