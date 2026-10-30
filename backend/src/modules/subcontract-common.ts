import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { badRequest, notFound } from '../lib/errors.ts';
import { scopedLocationIds } from '../lib/scope.ts';

export const round2 = (n: number) => Math.round(n * 100) / 100;
export const toPaise = (n: number) => BigInt(Math.round(n * 100));
export const fromPaise = (p: bigint) => Number(p) / 100;

/** num × mul ÷ div, rounded half up (inputs are non-negative integers). */
function divRound(n: bigint, d: bigint): bigint {
  return (2n * n + d) / (2n * d);
}

/** `amount` (rupees) × `pct` ÷ 100, to the paisa, half up. */
export function pctOf(amount: number, pct: number): number {
  return fromPaise(divRound(toPaise(amount) * BigInt(Math.round(pct * 100)), 10000n));
}

/** qty (3 decimals) × rate (rupees), to the paisa, half up. */
export function lineAmount(qty: number, rate: number): number {
  return fromPaise(divRound(BigInt(Math.round(qty * 1000)) * toPaise(rate), 1000n));
}

/** Default TDS rate: 1% for individuals/HUF (PAN 4th char P or H), else 2%. GSTIN-only parties use GSTIN chars 3–12. */
export function defaultTdsPct(party: { pan: string | null; gstin: string | null }): number {
  const pan = party.pan ?? (party.gstin ? party.gstin.slice(2, 12) : null);
  const c = pan && pan.length === 10 ? pan[3] : null;
  return c === 'P' || c === 'H' ? 1 : 2;
}

export interface RaInputs {
  gstPct: number; retentionPct: number; advanceRecoveryPct: number; tdsPct: number; cessPct: number;
  intraState: boolean; advanceBalance: number;
  lines: { prevQty: number; cumQty: number; qty: number; rate: number }[];
  overrides?: { retention?: number; advanceRecovery?: number; tds?: number; cess?: number; otherDeduction?: number };
}

export function computeRaBill(i: RaInputs) {
  const lines = i.lines.map((l, idx) => {
    if (l.cumQty < l.prevQty - 1e-9 || l.cumQty > l.qty + 1e-9) {
      throw badRequest(`Line ${idx + 1}: cumulative quantity must be between ${l.prevQty} and ${l.qty}.`, { [`lines.${idx}.cumQty`]: `Between ${l.prevQty} and ${l.qty}` });
    }
    const thisQty = Math.round((l.cumQty - l.prevQty) * 1000) / 1000;
    return { ...l, thisQty, amount: lineAmount(thisQty, l.rate) };
  });
  const gross = round2(lines.reduce((s, l) => s + l.amount, 0));
  const gst = pctOf(gross, i.gstPct);
  const cgst = i.intraState ? fromPaise(toPaise(gst) / 2n) : 0;
  const sgst = i.intraState ? round2(gst - cgst) : 0;
  const igst = i.intraState ? 0 : gst;
  const o = i.overrides ?? {};
  const pick = (name: string, v: number | undefined, def: number) => {
    const x = v ?? def;
    if (x < 0 || x > gross + 1e-9) throw badRequest(`${name} must be between 0 and the gross amount.`, { [name]: 'Out of range' });
    return x;
  };
  const retention = pick('retention', o.retention, pctOf(gross, i.retentionPct));
  const tds = pick('tds', o.tds, pctOf(gross, i.tdsPct));
  const cess = pick('cess', o.cess, pctOf(gross, i.cessPct));
  const advanceRecovery = pick('advanceRecovery', o.advanceRecovery, Math.min(i.advanceBalance, pctOf(gross, i.advanceRecoveryPct)));
  if (advanceRecovery > i.advanceBalance + 1e-9) {
    throw badRequest(`Advance recovery cannot exceed the advance balance of ₹${i.advanceBalance}.`, { advanceRecovery: `At most ${i.advanceBalance}` });
  }
  const otherDeduction = pick('otherDeduction', o.otherDeduction, 0);
  const totalDeductions = round2(retention + advanceRecovery + tds + cess + otherDeduction);
  const netPayable = round2(gross + gst - totalDeductions);
  if (netPayable < 0) throw badRequest('Deductions exceed the bill amount.', { netPayable: 'Negative' });
  return { lines, gross, cgst, sgst, igst, gst, retention, advanceRecovery, tds, cess, otherDeduction, totalDeductions, netPayable };
}

/** Project ids the caller may see: null = all. A project is visible when any of its sites is in scope. */
export async function visibleProjectIds(tx: Tx, ctx: RequestContext): Promise<string[] | null> {
  const scope = scopedLocationIds(ctx);
  if (!scope) return null;
  const rows = await tx.selectFrom('locations').select('project_id').distinct()
    .where('company_id', '=', ctx.companyId).where('id', 'in', scope).where('project_id', 'is not', null).execute();
  const ids = rows.map((r) => r.project_id!);
  return ids.length ? ids : ['00000000-0000-0000-0000-000000000000'];
}

export async function requireProjectVisible(tx: Tx, ctx: RequestContext, projectId: string, what: string): Promise<void> {
  const ids = await visibleProjectIds(tx, ctx);
  if (ids && !ids.includes(projectId)) throw notFound(what);
}

/** Location dimension for subcontract vouchers: the project's first site by name. */
export async function projectLocationId(tx: Tx, projectId: string): Promise<string | null> {
  const r = await tx.selectFrom('locations').select('id').where('project_id', '=', projectId)
    .orderBy('name').limit(1).executeTakeFirst();
  return r?.id ?? null;
}

export async function advanceFigures(tx: Tx, workOrderId: string) {
  const paid = await tx.selectFrom('contractor_advances').select((eb) => eb.fn.sum<number>('amount').as('v'))
    .where('work_order_id', '=', workOrderId).where('cancelled_at', 'is', null).executeTakeFirstOrThrow();
  const bills = await tx.selectFrom('ra_bills')
    .select((eb) => [eb.fn.sum<number>('advance_recovery').as('adv'), eb.fn.sum<number>('retention').as('ret')])
    .where('work_order_id', '=', workOrderId).where('status', '=', 'approved').executeTakeFirstOrThrow();
  const released = await tx.selectFrom('retention_releases').select((eb) => eb.fn.sum<number>('amount').as('v'))
    .where('work_order_id', '=', workOrderId).executeTakeFirstOrThrow();
  const p = round2(Number(paid.v ?? 0)); const r = round2(Number(bills.adv ?? 0));
  const held = round2(Number(bills.ret ?? 0)); const rel = round2(Number(released.v ?? 0));
  return {
    advance: { paid: p, recovered: r, balance: round2(p - r) },
    retention: { held, released: rel, balance: round2(held - rel) },
  };
}

/** Latest approved bill's cumQty per work-order line. */
export async function latestCumQtys(tx: Tx, workOrderId: string): Promise<Map<string, number>> {
  const latest = await tx.selectFrom('ra_bills').select('id').where('work_order_id', '=', workOrderId)
    .where('status', '=', 'approved').orderBy('bill_seq', 'desc').limit(1).executeTakeFirst();
  const map = new Map<string, number>();
  if (!latest) return map;
  const rows = await tx.selectFrom('ra_bill_lines').select(['work_order_line_id', 'cum_qty']).where('ra_bill_id', '=', latest.id).execute();
  for (const r of rows) map.set(r.work_order_line_id, r.cum_qty);
  return map;
}

export const user = (id: string, name: string) => ({ id, name });
