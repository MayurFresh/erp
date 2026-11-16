import { sql } from 'kysely';
import type { Tx } from '../db/database.ts';
import { todayIst } from '../lib/dates.ts';

/**
 * FIFO receipt layers. Layers are rebuilt from stock_moves: a positive move is a receipt layer,
 * a negative move consumes the oldest layers first, and a value-only move (qty 0) spreads over what is left.
 */

export interface Layer { qty: number; rate: number; date: string }
export interface MoveFacts { qty: number; value: number; /** IST date of the move, YYYY-MM-DD */ d: string }
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
    if (m.qty > 0) layers.push({ qty: m.qty, rate: m.value / m.qty, date: m.d });
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
  const rows = await sql<{ item_id: string; qty: number; value: number; d: string }>`
    select item_id, qty::float8 as qty, value::float8 as value, ((created_at at time zone 'Asia/Kolkata')::date)::text as d
    from stock_moves where company_id = ${companyId} and item_id in (${sql.join(itemIds)})
    order by ${MOVE_ORDER}`.execute(tx);
  const by = new Map<string, MoveFacts[]>();
  for (const id of itemIds) by.set(id, []);
  for (const r of rows.rows) by.get(r.item_id)!.push({ qty: Number(r.qty), value: Number(r.value), d: r.d });
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
  const rows = await sql<{ item_id: string; location_id: string; qty: number; value: number; d: string }>`
    select item_id, location_id, qty::float8 as qty, value::float8 as value, ((created_at at time zone 'Asia/Kolkata')::date)::text as d
    from stock_moves where ${where} order by ${MOVE_ORDER}`.execute(tx);
  const grouped = new Map<string, MoveGroup>();
  for (const r of rows.rows) {
    const k = `${r.item_id}:${r.location_id}`;
    const g = grouped.get(k) ?? { itemId: r.item_id, locationId: r.location_id, moves: [] };
    g.moves.push({ qty: Number(r.qty), value: Number(r.value), d: r.d });
    grouped.set(k, g);
  }
  return [...grouped.values()];
}
