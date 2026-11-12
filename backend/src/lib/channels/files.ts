import { isValidDate } from '../dates.ts';
import { parseCsv } from '../csv.ts';
import { GENERIC_ORDER_COLUMNS, GENERIC_SETTLEMENT_ALIASES } from './registry.ts';
import type { NormalisedOrder, OrderCsvField, SettlementKind } from './types.ts';

const KINDS: readonly string[] = ['sale', 'refund', 'commission', 'fee', 'shipping', 'gst_on_fees', 'tcs', 'tds', 'reserve', 'reserve_release', 'adjustment'];

export interface RowIssue { row: number; message: string }

const norm = (h: string) => h.trim().toLowerCase().replace(/\s+/g, ' ');
const num = (v: string | undefined) => {
  if (v === undefined) return NaN;
  const t = v.replace(/[₹,\s]/g, '').replace(/^\((.*)\)$/, '-$1');
  return t === '' ? NaN : Number(t);
};

/** Accepts YYYY-MM-DD, DD-MM-YYYY, DD/MM/YYYY and an ISO timestamp. Returns null when it is not a real date. */
export function toIsoDate(v: string): string | null {
  const t = v.trim();
  let m = /^(\d{4})-(\d{2})-(\d{2})/.exec(t);
  let iso: string | null = null;
  if (m) iso = `${m[1]}-${m[2]}-${m[3]}`;
  else if ((m = /^(\d{1,2})[-/](\d{1,2})[-/](\d{4})$/.exec(t))) iso = `${m[3]}-${m[2]!.padStart(2, '0')}-${m[1]!.padStart(2, '0')}`;
  return iso && isValidDate(iso) ? iso : null;
}

function headerIndex(header: string[], wanted: Record<string, string>) {
  const idx = new Map(header.map((h, i) => [norm(h), i] as const));
  const out: Record<string, number | undefined> = {};
  for (const [k, col] of Object.entries(wanted)) out[k] = idx.get(norm(col));
  return out;
}

/** Reads an order file into neutral orders, one per order id. Bad rows are listed and left out. */
export function parseOrderFile(text: string, mapping: Record<string, string>, taxInclusive: boolean) {
  const rows = parseCsv(text);
  const issues: RowIssue[] = [];
  if (rows.length < 2) return { orders: [] as NormalisedOrder[], issues: [{ row: 1, message: 'The file has no rows.' }] };
  const cols = { ...GENERIC_ORDER_COLUMNS, ...mapping } as Record<OrderCsvField, string>;
  const ix = headerIndex(rows[0]!, cols);
  for (const f of ['orderId', 'sku', 'qty'] as const) {
    if (ix[f] === undefined) return { orders: [], issues: [{ row: 1, message: `Column "${cols[f]}" is missing.` }] };
  }
  const get = (r: string[], f: OrderCsvField) => (ix[f] === undefined ? undefined : r[ix[f]!]?.trim());
  const byRef = new Map<string, NormalisedOrder>();
  rows.slice(1).forEach((r, i) => {
    const row = i + 2;
    const ref = get(r, 'orderId');
    const sku = get(r, 'sku');
    const qty = num(get(r, 'qty'));
    if (!ref) return void issues.push({ row, message: 'Order id is empty.' });
    if (!sku) return void issues.push({ row, message: 'SKU is empty.' });
    if (!(qty > 0)) return void issues.push({ row, message: 'Quantity must be more than zero.' });
    let unit = num(get(r, 'unitPrice'));
    if (Number.isNaN(unit)) {
      const total = num(get(r, 'lineTotal'));
      unit = Number.isNaN(total) ? NaN : total / qty;
    }
    if (!(unit >= 0)) return void issues.push({ row, message: 'Price is missing or not a number.' });
    const dateText = get(r, 'orderDate');
    const date = dateText ? toIsoDate(dateText) : null;
    if (dateText && !date) return void issues.push({ row, message: `Date "${dateText}" is not valid.` });
    const status = (get(r, 'status') ?? '').toLowerCase();
    const cancelled = /^(cancel|cancelled|canceled)/.test(status);
    let o = byRef.get(ref);
    if (!o) {
      o = {
        externalRef: ref, orderDate: date ?? '', status: cancelled ? 'cancelled' : 'open', buyerName: get(r, 'buyerName') || null,
        shipToState: /^\d{2}$/.test(get(r, 'shipState') ?? '') ? get(r, 'shipState')! : null, taxInclusive, lines: [], shipping: 0, note: null,
      };
      byRef.set(ref, o);
    }
    o.lines.push({ sku, title: get(r, 'title') || null, qty, unitPrice: Math.round(unit * 100) / 100, discount: Math.max(num(get(r, 'discount')) || 0, 0) });
  });
  const orders = [...byRef.values()];
  for (const o of orders) if (!o.orderDate) { o.orderDate = ''; }
  return { orders, issues };
}

export interface ParsedSettlementLine { lineNo: number; orderRef: string | null; kind: SettlementKind; label: string; amount: number }
export interface ParsedSettlement {
  ref: string; payoutDate: string; declaredPayout: number | null; lines: ParsedSettlementLine[];
}

/**
 * Reads a settlement report: settlement_id, payout_date, order_id, type, amount. Positive amounts are money to the seller.
 * A row of type "payout" or "net payout" declares the amount paid into the bank; it is not a line.
 */
export function parseSettlementFile(text: string, aliases: Record<string, string>) {
  const rows = parseCsv(text);
  const issues: RowIssue[] = [];
  const result = new Map<string, ParsedSettlement>();
  if (rows.length < 2) return { settlements: [] as ParsedSettlement[], issues: [{ row: 1, message: 'The file has no rows.' }] };
  const ix = headerIndex(rows[0]!, { ref: 'settlement_id', date: 'payout_date', order: 'order_id', type: 'type', amount: 'amount' });
  for (const f of ['ref', 'date', 'type', 'amount'] as const) {
    if (ix[f] === undefined) return { settlements: [], issues: [{ row: 1, message: `Column "${f === 'ref' ? 'settlement_id' : f === 'date' ? 'payout_date' : f}" is missing.` }] };
  }
  const table: Record<string, string> = { ...GENERIC_SETTLEMENT_ALIASES };
  for (const [k, v] of Object.entries(aliases)) if (KINDS.includes(v)) table[norm(k)] = v;
  rows.slice(1).forEach((r, i) => {
    const row = i + 2;
    const cell = (k: string) => (ix[k] === undefined ? '' : (r[ix[k]!] ?? '').trim());
    const ref = cell('ref');
    const date = toIsoDate(cell('date'));
    const label = cell('type');
    const amount = num(cell('amount'));
    if (!ref) return void issues.push({ row, message: 'Settlement id is empty.' });
    if (!date) return void issues.push({ row, message: 'Payout date is not valid.' });
    if (Number.isNaN(amount)) return void issues.push({ row, message: 'Amount is not a number.' });
    let s = result.get(ref);
    if (!s) { s = { ref, payoutDate: date, declaredPayout: null, lines: [] }; result.set(ref, s); }
    const key = norm(label);
    if (key === 'payout' || key === 'net payout') { s.declaredPayout = Math.round(amount * 100) / 100; return; }
    const kind = table[key];
    if (!kind) return void issues.push({ row, message: `"${label}" is not a known line type. Add it to the channel's settlement labels.` });
    s.lines.push({ lineNo: s.lines.length + 1, orderRef: cell('order') || null, kind: kind as SettlementKind, label, amount: Math.round(amount * 100) / 100 });
  });
  return { settlements: [...result.values()], issues };
}
