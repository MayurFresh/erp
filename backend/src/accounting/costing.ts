import { sql } from 'kysely';
import type { Tx } from '../db/database.ts';
import { companyLayers, fifoActive, valuationSetting, type Layer } from './fifo.ts';

/**
 * Weighted-average costing. An item's average cost is (sum of move values) ÷ (sum of qty)
 * across the whole company, so every stock move must store the value it added or removed.
 */

/** Serialises stock changes per item for the rest of the transaction. Sorted to avoid deadlocks. */
export async function lockItems(tx: Tx, companyId: string, itemIds: string[]): Promise<void> {
  for (const id of [...new Set(itemIds)].sort()) {
    await sql`select pg_advisory_xact_lock(hashtextextended(${`${companyId}:${id}`}, 0))`.execute(tx);
  }
}

/** `layers` is set only when the company costs issues by FIFO: the receipt layers left, oldest first. */
export interface Position { qty: number; value: number; layers?: Layer[] }

export async function positions(tx: Tx, companyId: string, itemIds: string[]): Promise<Map<string, Position>> {
  const result = new Map<string, Position>();
  for (const id of itemIds) result.set(id, { qty: 0, value: 0 });
  if (!itemIds.length) return result;
  const rows = await tx.selectFrom('stock_moves')
    .select((eb) => ['item_id', eb.fn.sum<number>('qty').as('qty'), eb.fn.sum<number>('value').as('value')])
    .where('company_id', '=', companyId).where('item_id', 'in', [...new Set(itemIds)])
    .groupBy('item_id').execute();
  for (const r of rows) result.set(r.item_id, { qty: Number(r.qty), value: Number(r.value) });
  const setting = await valuationSetting(tx, companyId);
  if (fifoActive(setting)) {
    const layers = await companyLayers(tx, companyId, [...new Set(itemIds)], setting);
    for (const [id, pos] of result) pos.layers = layers.get(id) ?? [];
  }
  return result;
}

/** Quantity of an item at one location. */
export async function locationQty(tx: Tx, companyId: string, locationId: string, itemId: string): Promise<number> {
  const row = await tx.selectFrom('stock_moves')
    .select((eb) => eb.fn.coalesce(eb.fn.sum<number>('qty'), sql<number>`0`).as('qty'))
    .where('company_id', '=', companyId).where('location_id', '=', locationId).where('item_id', '=', itemId)
    .executeTakeFirstOrThrow();
  return Number(row.qty);
}

const round2 = (n: number) => Math.round(n * 100) / 100;
const round4 = (n: number) => Math.round(n * 10_000) / 10_000;

export function averageCost(pos: Position, fallback: number): number {
  return pos.qty > 0 && pos.value > 0 ? pos.value / pos.qty : fallback;
}

/**
 * Value (positive) of issuing `qty` at the current average, and the updated position.
 * Issuing the last units takes the exact remaining value so no paise are stranded.
 */
export function issue(pos: Position, qty: number, fallback: number): { value: number; costRate: number; after: Position } {
  if (pos.layers) return issueFifo(pos, qty, fallback);
  const rate = averageCost(pos, fallback);
  const lastUnits = pos.qty > 0 && Math.abs(pos.qty - qty) < 0.0005;
  const value = lastUnits ? round2(Math.max(pos.value, 0)) : round2(qty * rate);
  return { value, costRate: round4(rate), after: { qty: round3(pos.qty - qty), value: round2(pos.value - value) } };
}

/** Receiving stock with a known total value. */
export function receive(pos: Position, qty: number, value: number): Position {
  const after: Position = { qty: round3(pos.qty + qty), value: round2(pos.value + value) };
  if (pos.layers) after.layers = qty > 0 ? [...pos.layers, { qty, rate: value / qty, date: '' }] : pos.layers;
  return after;
}

/** FIFO: takes the oldest layers first. Units beyond the layers (negative stock) cost at the fallback rate. */
function issueFifo(pos: Position, qty: number, fallback: number): { value: number; costRate: number; after: Position } {
  const rest = pos.layers!.map((l) => ({ ...l }));
  let need = qty;
  let taken = 0;
  while (need > 0.0005 && rest.length) {
    const l = rest[0]!;
    const take = Math.min(l.qty, need);
    taken += take * l.rate;
    l.qty = round3(l.qty - take);
    need = round3(need - take);
    if (l.qty <= 0.0005) rest.shift();
  }
  if (need > 0.0005) taken += need * averageCost(pos, fallback);
  const lastUnits = pos.qty > 0 && Math.abs(pos.qty - qty) < 0.0005;
  const value = lastUnits ? round2(Math.max(pos.value, 0)) : round2(taken);
  return {
    value, costRate: round4(qty > 0 ? value / qty : 0),
    after: { qty: round3(pos.qty - qty), value: round2(pos.value - value), layers: lastUnits ? [] : rest },
  };
}

function round3(n: number) {
  return Math.round(n * 1000) / 1000;
}
