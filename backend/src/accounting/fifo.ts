import { sql } from 'kysely';
import type { Tx } from '../db/database.ts';
import { todayIst } from '../lib/dates.ts';

/**
 * FIFO receipt layers. Layers are rebuilt from stock_moves: a positive move is a receipt layer,
 * a negative move consumes the oldest layers first, and a value-only move (qty 0) spreads over what is left.
 */

export interface Layer { qty: number; rate: number; date: string }
export interface MoveFacts { qty: number; value: number; /** IST date of the move, YYYY-MM-DD */ d: string; /** age date carried by a transfer receipt; the layer keeps it */ ld?: string }
export interface ValuationSetting { method: 'average' | 'fifo'; effectiveFrom: string | null }

const round3 = (n: number) => Math.round(n * 1000) / 1000;

export async function valuationSetting(tx: Tx, companyId: string): Promise<ValuationSetting> {
  const r = await sql<{ method: 'average' | 'fifo'; effective_from: string }>`
    select method, effective_from::text as effective_from from stock_valuation_settings where company_id = ${companyId}`.execute(tx);
  const row = r.rows[0];
  return row ? { method: row.method, effectiveFrom: row.effective_from } : { method: 'average', effectiveFrom: null };
}

/** True when FIFO costs issues made today. */
export const fifoActive = (s: ValuationSetting) => s.method === 'fifo' && s.effectiveFrom !== null && s.effectiveFrom <= todayIst();

/**
 * Walks the moves (oldest first) and returns the layers left. With `rebaseBefore`, the layers standing before that date
 * are rescaled so their value equals the ledger value then: the switch to FIFO does not move the books.
 */
export function replayLayers(moves: MoveFacts[], rebaseBefore?: string): Layer[] {
  const layers: Layer[] = [];
  let rebased = rebaseBefore === undefined;
  let ledger = 0;
  const rebase = () => {
    rebased = true;
    const qty = layers.reduce((s, l) => s + l.qty, 0);
    const value = layers.reduce((s, l) => s + l.qty * l.rate, 0);
    if (qty <= 0) return;
    if (value > 0) for (const l of layers) l.rate *= Math.max(ledger, 0) / value;
    else for (const l of layers) l.rate = Math.max(ledger, 0) / qty;
  };
  for (const m of moves) {
    if (!rebased && m.d >= rebaseBefore!) rebase();
    if (!rebased) ledger += m.value;
    if (m.qty > 0) {
      const layer = { qty: m.qty, rate: m.value / m.qty, date: m.ld ?? m.d };
      // A transferred layer keeps its original date, so it goes in date order among the layers.
      const at = m.ld ? layers.findIndex((x) => x.date > layer.date) : -1;
      if (at < 0) layers.push(layer); else layers.splice(at, 0, layer);
    }
    else if (m.qty < 0) {
      let need = -m.qty;
      while (need > 0.0005 && layers.length) {
        const l = layers[0]!;
        const take = Math.min(l.qty, need);
        l.qty = round3(l.qty - take);
        need = round3(need - take);
        if (l.qty <= 0.0005) layers.shift();
      }
    } else if (m.value !== 0) {
      const qty = layers.reduce((s, l) => s + l.qty, 0);
      if (qty > 0) for (const l of layers) l.rate += m.value / qty;
    }
  }
  if (!rebased) rebase();
  return layers;
}

const MOVE_ORDER = sql`created_at, (qty < 0), id`;

/** Layers per item across all locations, for costing an issue. */
export async function companyLayers(tx: Tx, companyId: string, itemIds: string[], setting: ValuationSetting): Promise<Map<string, Layer[]>> {
  const out = new Map<string, Layer[]>();
  if (!itemIds.length) return out;
  const rows = await sql<{ item_id: string; qty: number; value: number; d: string; ld: string | null }>`
    select item_id, qty::float8 as qty, value::float8 as value, ((created_at at time zone 'Asia/Kolkata')::date)::text as d, layer_date::text as ld
    from stock_moves where company_id = ${companyId} and item_id in (${sql.join(itemIds)})
    order by ${MOVE_ORDER}`.execute(tx);
  const by = new Map<string, MoveFacts[]>();
  for (const id of itemIds) by.set(id, []);
  for (const r of rows.rows) by.get(r.item_id)!.push({ qty: Number(r.qty), value: Number(r.value), d: r.d, ...(r.ld ? { ld: r.ld } : {}) });
  for (const [id, moves] of by) out.set(id, replayLayers(moves, setting.effectiveFrom ?? undefined));
  return out;
}

/** Moving-average result of a move list: issues leave at the running average. */
export function replayAverage(moves: MoveFacts[]): { qty: number; value: number } {
  let qty = 0;
  let value = 0;
  for (const m of moves) {
    if (m.qty > 0) { qty = round3(qty + m.qty); value += m.value; }
    else if (m.qty < 0) {
      const out = -m.qty;
      const rate = qty > 0 && value > 0 ? value / qty : (m.value !== 0 ? -m.value / out : 0);
      const take = Math.abs(qty - out) < 0.0005 ? Math.max(value, 0) : out * rate;
      qty = round3(qty - out);
      value -= take;
    } else value += m.value;
  }
  return { qty, value };
}

export interface MoveGroup { itemId: string; locationId: string; moves: MoveFacts[] }

/** Moves per item and location up to a date, oldest first. */
export async function groupedMoves(tx: Tx, companyId: string, opts: { asOf: string; locationIds?: string[] | null; locationId?: string }): Promise<MoveGroup[]> {
  if (opts.locationIds && !opts.locationIds.length) return [];
  let where = sql`company_id = ${companyId} and ((created_at at time zone 'Asia/Kolkata')::date) <= ${opts.asOf}::date`;
  if (opts.locationIds) where = sql`${where} and location_id in (${sql.join(opts.locationIds)})`;
  if (opts.locationId) where = sql`${where} and location_id = ${opts.locationId}`;
  const rows = await sql<{ item_id: string; location_id: string; qty: number; value: number; d: string; ld: string | null }>`
    select item_id, location_id, qty::float8 as qty, value::float8 as value, ((created_at at time zone 'Asia/Kolkata')::date)::text as d, layer_date::text as ld
    from stock_moves where ${where} order by ${MOVE_ORDER}`.execute(tx);
  const grouped = new Map<string, MoveGroup>();
  for (const r of rows.rows) {
    const k = `${r.item_id}:${r.location_id}`;
    const g = grouped.get(k) ?? { itemId: r.item_id, locationId: r.location_id, moves: [] };
    g.moves.push({ qty: Number(r.qty), value: Number(r.value), d: r.d, ...(r.ld ? { ld: r.ld } : {}) });
    grouped.set(k, g);
  }
  return [...grouped.values()];
}

export interface Slice { qty: number; date: string; rate: number }

/** Takes qty off the oldest layers (in place) and says which layer dates it came from. What the layers cannot cover is left out. */
export function takeSlices(layers: Layer[], qty: number): Slice[] {
  const out: Slice[] = [];
  let need = qty;
  while (need > 0.0005 && layers.length) {
    const l = layers[0]!;
    const take = Math.min(l.qty, need);
    const last = out[out.length - 1];
    if (last && last.date === l.date && Math.abs(last.rate - l.rate) < 0.00005) last.qty = round3(last.qty + take);
    else out.push({ qty: round3(take), date: l.date, rate: l.rate });
    l.qty = round3(l.qty - take);
    need = round3(need - take);
    if (l.qty <= 0.0005) layers.shift();
  }
  return out;
}

/** The receipt layers standing at one location per item, for dating a transfer. */
export async function locationLayers(tx: Tx, companyId: string, locationId: string, itemIds: string[]): Promise<Map<string, Layer[]>> {
  const groups = await groupedMoves(tx, companyId, { asOf: todayIst(), locationId });
  const out = new Map<string, Layer[]>();
  for (const id of itemIds) out.set(id, []);
  for (const g of groups) if (out.has(g.itemId)) out.set(g.itemId, replayLayers(g.moves));
  return out;
}
