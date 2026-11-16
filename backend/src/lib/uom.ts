import { sql } from 'kysely';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest } from './errors.ts';

/**
 * Alternate units of measure. Documents store quantity and rate in the item's base unit; the unit the user
 * typed is kept beside them (entered_unit, entered_qty) so the printed document reads as entered.
 */

interface Entered { unit: string; qty: number }
const enteredByLine = new WeakMap<object, Entered>();

type UnitLine = { itemId: string; qty: number; rate?: number | undefined; unit?: string | undefined };

/**
 * Converts the lines that name a unit, in place: qty becomes base units and a given rate becomes the rate per base unit.
 * A missing rate stays missing, so the item's own price applies. Safe to call twice on the same lines.
 */
export async function convertUnits(tx: Tx, ctx: RequestContext, lines: UnitLine[]): Promise<void> {
  const named = lines.filter((l) => l.unit && l.unit.trim() && !enteredByLine.has(l));
  if (!named.length) return;
  const ids = [...new Set(named.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').select(['id', 'unit']).where('company_id', '=', ctx.companyId).where('id', 'in', ids).execute();
  const units = await tx.selectFrom('item_units').select(['item_id', 'name', 'factor']).where('company_id', '=', ctx.companyId).where('item_id', 'in', ids).execute();
  const baseOf = new Map(items.map((i) => [i.id, i.unit]));
  lines.forEach((l, idx) => {
    if (!l.unit || !l.unit.trim() || enteredByLine.has(l)) return;
    const wanted = l.unit.trim().toLowerCase();
    const base = baseOf.get(l.itemId);
    if (base === undefined) return; // the item check in the caller reports it
    if (base.toLowerCase() === wanted) return;
    const u = units.find((x) => x.item_id === l.itemId && x.name.toLowerCase() === wanted);
    if (!u) throw badRequest(`Line ${idx + 1}: this item has no unit called ${l.unit.trim()}.`, { [`lines.${idx}.unit`]: 'Unknown unit' });
    const factor = Number(u.factor);
    const entered = { unit: u.name, qty: l.qty };
    l.qty = Math.round(l.qty * factor * 1000) / 1000;
    if (l.qty <= 0) throw badRequest(`Line ${idx + 1}: the quantity is too small in ${base}.`, { [`lines.${idx}.qty`]: 'Too small' });
    if (l.rate !== undefined) l.rate = Math.round((l.rate / factor) * 10_000) / 10_000;
    enteredByLine.set(l, entered);
  });
}

/** The entered unit and quantity of each line, in order; null where the line was in the base unit. */
export function enteredOf(lines: object[]): (Entered | null)[] {
  return lines.map((l) => enteredByLine.get(l) ?? null);
}

/** Stores the entered unit on the saved lines (line_no is the 1-based position). */
export async function saveEntered(tx: Tx, table: 'invoice_lines' | 'purchase_lines' | 'sales_order_lines' | 'quotation_lines',
  key: 'invoice_id' | 'purchase_id' | 'order_id' | 'quotation_id', docId: string, entered: (Entered | null)[]): Promise<void> {
  for (let i = 0; i < entered.length; i++) {
    const e = entered[i];
    if (!e) continue;
    await sql`update ${sql.table(table)} set entered_unit = ${e.unit}, entered_qty = ${e.qty} where ${sql.ref(key)} = ${docId} and line_no = ${i + 1}`.execute(tx);
  }
}

/** JSON fields for a stored line: the quantity and rate in the entered unit, or nulls. */
export function enteredJson(l: { entered_unit: string | null; entered_qty: number | null; qty?: number; rate: number }, baseQty?: number) {
  const qty = baseQty ?? l.qty ?? 0;
  const ok = l.entered_unit !== null && l.entered_qty !== null && Number(l.entered_qty) > 0;
  return {
    enteredUnit: ok ? l.entered_unit : null,
    enteredQty: ok ? Number(l.entered_qty) : null,
    enteredRate: ok ? Math.round(((Number(l.rate) * qty) / Number(l.entered_qty)) * 10_000) / 10_000 : null,
  };
}
