import { systemAccounts } from '../accounting/accounts.ts';
import { issue, lockItems, positions } from '../accounting/costing.ts';
import { postJournal } from '../accounting/journal.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest, conflict } from '../lib/errors.ts';
import { auditOf } from './audit.ts';
import { requireStock } from './stock.ts';

export const round2 = (n: number) => Math.round(n * 100) / 100;
export const round3 = (n: number) => Math.round(n * 1000) / 1000;
export const round4 = (n: number) => Math.round(n * 10_000) / 10_000;

export const showCost = (ctx: RequestContext) => ctx.can('items.view_cost');

// Bill of materials structure -------------------------------------------------------------------------

export interface BomLineDef { kind: string; itemId: string; qty: number; scrapPct: number; rate: number }
export interface BomDef { id: string; itemId: string; outputQty: number; lines: BomLineDef[] }
export interface ExplodeNode { itemId: string; qty: number; bomId: string | null; children: ExplodeNode[] }

/** Active BOMs of the company by finished item. `override` replaces or adds one (used to test a draft before activating). */
export async function activeBoms(tx: Tx, companyId: string, override?: BomDef): Promise<Map<string, BomDef>> {
  const boms = await tx.selectFrom('mfg_boms').select(['id', 'item_id', 'output_qty'])
    .where('company_id', '=', companyId).where('status', '=', 'active').execute();
  const ids = boms.map((b) => b.id);
  const lines = ids.length ? await tx.selectFrom('mfg_bom_lines').selectAll().where('bom_id', 'in', ids).orderBy('line_no').execute() : [];
  const map = new Map<string, BomDef>();
  for (const b of boms) {
    map.set(b.item_id, {
      id: b.id, itemId: b.item_id, outputQty: b.output_qty,
      lines: lines.filter((l) => l.bom_id === b.id).map((l) => ({ kind: l.kind, itemId: l.item_id, qty: l.qty, scrapPct: l.scrap_pct, rate: l.rate })),
    });
  }
  if (override) map.set(override.itemId, override);
  return map;
}

/** Total quantity of one component for `qty` of the finished item, with scrap. */
export const componentNeed = (bom: BomDef, line: BomLineDef, qty: number) =>
  (qty / bom.outputQty) * line.qty * (1 + line.scrapPct / 100);

/**
 * Explodes a BOM for `qty`. Components that have their own active BOM are expanded; the others are raw material.
 * Throws 409 BOM_CYCLE when a component leads back to an item above it.
 */
export function explode(defs: Map<string, BomDef>, root: BomDef, qty: number) {
  const raw = new Map<string, number>();
  const walk = (bom: BomDef, q: number, path: string[]): ExplodeNode[] => {
    if (path.length > 12) throw conflict('This bill of materials has too many levels.', 'BOM_CYCLE');
    const nodes: ExplodeNode[] = [];
    for (const l of bom.lines) {
      if (l.kind !== 'component') continue;
      if (path.includes(l.itemId)) throw conflict('A component leads back to the item being made.', 'BOM_CYCLE', { itemId: l.itemId });
      const need = componentNeed(bom, l, q);
      const child = defs.get(l.itemId);
      if (child) {
        nodes.push({ itemId: l.itemId, qty: round3(need), bomId: child.id, children: walk(child, need, [...path, l.itemId]) });
      } else {
        raw.set(l.itemId, (raw.get(l.itemId) ?? 0) + need);
        nodes.push({ itemId: l.itemId, qty: round3(need), bomId: null, children: [] });
      }
    }
    return nodes;
  };
  const tree = walk(root, qty, [root.itemId]);
  return { tree, raw: new Map([...raw].map(([k, v]) => [k, round3(v)])) };
}

// Stock helpers ---------------------------------------------------------------------------------------

export interface CostedLine { itemId: string; qty: number; costRate: number; value: number }

/** Takes stock out of a location at average cost and writes the stock moves. Checks availability first. */
export async function takeStock(
  tx: Tx, ctx: RequestContext, location: { id: string; name: string }, lines: { itemId: string; qty: number }[],
  refType: string, refId: string, note: string,
): Promise<CostedLine[]> {
  const ids = [...new Set(lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').select(['id', 'name', 'unit', 'track_stock', 'purchase_price'])
    .where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  for (const id of ids) {
    const it = items.find((x) => x.id === id);
    if (!it) throw badRequest('Item not found.', { itemId: 'Not found' });
    if (!it.track_stock) throw badRequest(`Stock is not tracked for ${it.name}.`, { itemId: 'Stock not tracked' });
  }
  await lockItems(tx, ctx.companyId, ids);
  const totals = new Map<string, number>();
  for (const l of lines) totals.set(l.itemId, (totals.get(l.itemId) ?? 0) + l.qty);
  for (const [id, qty] of totals) await requireStock(tx, ctx, location, items.find((x) => x.id === id)!, qty);
  const pos = await positions(tx, ctx.companyId, ids);
  const costed = lines.map((l) => {
    const it = items.find((x) => x.id === l.itemId)!;
    const out = issue(pos.get(l.itemId)!, l.qty, it.purchase_price);
    pos.set(l.itemId, out.after);
    return { itemId: l.itemId, qty: l.qty, costRate: out.costRate, value: out.value };
  });
  await tx.insertInto('stock_moves').values(costed.map((c) => ({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: location.id, item_id: c.itemId, qty: -c.qty, rate: null,
    cost_rate: c.costRate, value: -c.value, ref_type: refType, ref_id: refId, note, created_by: ctx.userId,
  }))).execute();
  return costed;
}

/** Puts stock into a location with a known value (cost_rate = value / qty). */
export async function putStock(
  tx: Tx, ctx: RequestContext, locationId: string,
  lines: { itemId: string; qty: number; value: number }[], refType: string, refId: string, note: string,
) {
  const rows = lines.filter((l) => l.qty > 0);
  if (!rows.length) return;
  await lockItems(tx, ctx.companyId, rows.map((l) => l.itemId));
  await tx.insertInto('stock_moves').values(rows.map((l) => ({
    tenant_id: ctx.tenantId, company_id: ctx.companyId, location_id: locationId, item_id: l.itemId, qty: l.qty, rate: null,
    cost_rate: round4(l.value / l.qty), value: l.value, ref_type: refType, ref_id: refId, note, created_by: ctx.userId,
  }))).execute();
}

export type AccountKey = Awaited<ReturnType<typeof systemAccounts>>;

/** Posts a journal from signed amounts by account key. Zero amounts are dropped. */
export async function post(
  tx: Tx, ctx: RequestContext, o: {
    date: string; type: 'issue' | 'stock'; voucherId: string; number: string | null; narration: string; locationId: string;
    lines: [keyof AccountKey, number][];
  },
) {
  const acc = await systemAccounts(tx, ctx);
  const lines = o.lines.filter(([, a]) => Math.round(a * 100) !== 0)
    .map(([k, a]) => ({ accountId: acc[k], amount: a, locationId: o.locationId }));
  if (lines.length < 2) return;
  await postJournal(tx, auditOf(ctx), {
    date: o.date, voucherType: o.type, voucherId: o.voucherId, number: o.number, narration: o.narration, lines,
  });
}
