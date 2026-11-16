import type { Tx } from '../db/database.ts';

/** Price resolution: customer price, then the party's price list, then the item's sale price. Schemes add a discount or free goods. */

export type PriceSource = 'customer' | 'price_list' | 'scheme' | 'item';

export interface ResolvedPrice {
  itemId: string;
  qty: number;
  rate: number;
  discountPct: number;
  source: PriceSource;
  priceListName: string | null;
  freeQty: number;
  freeItemId: string | null;
}

const round2 = (n: number) => Math.round(n * 100) / 100;
const inRange = (date: string, from: string | null, to: string | null) => (!from || from <= date) && (!to || to >= date);

/** The row with the largest minQty that is not above qty. */
function slab<T extends { min_qty: number }>(rows: T[], qty: number): T | undefined {
  let best: T | undefined;
  for (const r of rows) if (r.min_qty <= qty && (!best || r.min_qty > best.min_qty)) best = r;
  return best;
}

export async function resolvePrices(
  tx: Tx, companyId: string, partyId: string | null | undefined, lines: { itemId: string; qty: number }[], date: string,
): Promise<ResolvedPrice[]> {
  if (!lines.length) return [];
  const itemIds = [...new Set(lines.map((l) => l.itemId))];
  const items = await tx.selectFrom('items').select(['id', 'sale_price']).where('company_id', '=', companyId).where('id', 'in', itemIds).execute();
  const sale = new Map(items.map((i) => [i.id, i.sale_price]));

  const party = partyId
    ? await tx.selectFrom('parties').select(['id', 'price_list_id']).where('id', '=', partyId).where('company_id', '=', companyId).executeTakeFirst()
    : undefined;
  const custRows = party
    ? (await tx.selectFrom('customer_prices').selectAll().where('company_id', '=', companyId).where('party_id', '=', party.id)
      .where('item_id', 'in', itemIds).execute()).filter((r) => inRange(date, r.valid_from, r.valid_to))
    : [];
  const list = party?.price_list_id
    ? await tx.selectFrom('price_lists').selectAll().where('id', '=', party.price_list_id).where('company_id', '=', companyId).executeTakeFirst()
    : undefined;
  const listOk = list && list.is_active && inRange(date, list.valid_from, list.valid_to) ? list : undefined;
  const listRows = listOk
    ? await tx.selectFrom('price_list_items').selectAll().where('price_list_id', '=', listOk.id).where('item_id', 'in', itemIds).execute()
    : [];
  const schemes = (await tx.selectFrom('price_schemes').selectAll().where('company_id', '=', companyId).where('is_active', '=', true)
    .where('item_id', 'in', itemIds).execute()).filter((s) => inRange(date, s.valid_from, s.valid_to));

  return lines.map((l) => {
    const base = sale.get(l.itemId) ?? 0;
    let rate = base;
    let source: PriceSource = 'item';
    let priceListName: string | null = null;
    const cust = slab(custRows.filter((r) => r.item_id === l.itemId), l.qty);
    if (cust) {
      rate = cust.rate; source = 'customer';
    } else if (listOk) {
      const row = slab(listRows.filter((r) => r.item_id === l.itemId), l.qty);
      if (row) {
        rate = row.rate; source = 'price_list'; priceListName = listOk.name;
      } else if (listOk.mode === 'percent') {
        rate = round2(base * (1 + listOk.adjust_pct / 100)); source = 'price_list'; priceListName = listOk.name;
      }
    }
    let discountPct = 0;
    let freeQty = 0;
    let freeItemId: string | null = null;
    for (const s of schemes.filter((x) => x.item_id === l.itemId)) {
      if (s.kind === 'slab_discount' && s.min_qty! <= l.qty && s.discount_pct! > discountPct) discountPct = s.discount_pct!;
      if (s.kind === 'free_qty') {
        const free = Math.floor(l.qty / s.buy_qty!) * s.free_qty!;
        if (free > freeQty) { freeQty = free; freeItemId = s.free_item_id ?? s.item_id; }
      }
    }
    if (source === 'item' && (discountPct > 0 || freeQty > 0)) source = 'scheme';
    return { itemId: l.itemId, qty: l.qty, rate, discountPct, source, priceListName, freeQty, freeItemId };
  });
}

/**
 * For document lines that omit `rate`: the resolved rate per line index, or undefined where the line gave one
 * (or nothing differs from the item's sale price). Callers fall back to `item.sale_price` for undefined.
 */
export async function fallbackRates(
  tx: Tx, companyId: string, partyId: string, lines: { itemId: string; qty: number; rate?: number }[], date: string,
): Promise<(number | undefined)[]> {
  const missing = lines.map((l, idx) => ({ l, idx })).filter((x) => x.l.rate === undefined);
  const out: (number | undefined)[] = lines.map(() => undefined);
  if (!missing.length) return out;
  const res = await resolvePrices(tx, companyId, partyId, missing.map((x) => ({ itemId: x.l.itemId, qty: x.l.qty })), date);
  res.forEach((r, i) => { out[missing[i]!.idx] = r.rate; });
  return out;
}
