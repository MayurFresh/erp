import { partyBalances } from '../accounting/ledger.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { conflict } from '../lib/errors.ts';
import { auditOf, writeAudit } from './audit.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;

/** Order statuses whose unshipped quantity still counts as money the customer will owe. */
const OPEN_ORDER = ['draft', 'confirmed', 'picking', 'packed', 'partially_dispatched'];

/** What a customer owes now: the receivable on the ledger (never below zero) plus open sales orders not yet invoiced. */
export async function customerExposure(tx: Tx, companyId: string, partyId: string): Promise<{ ledger: number; openOrders: number; owes: number }> {
  const ledger = Math.max(0, (await partyBalances(tx, companyId, [partyId])).get(partyId) ?? 0);
  const lines = await tx.selectFrom('sales_order_lines as l').innerJoin('sales_orders as o', 'o.id', 'l.order_id')
    .select(['l.qty_ordered', 'l.qty_dispatched', 'l.qty_cancelled', 'l.rate', 'l.discount_pct', 'l.gst_rate'])
    .where('o.company_id', '=', companyId).where('o.party_id', '=', partyId).where('o.status', 'in', OPEN_ORDER).execute();
  let open = 0;
  for (const l of lines) {
    const qty = Math.max(0, l.qty_ordered - l.qty_dispatched - l.qty_cancelled);
    open += qty * l.rate * (1 - l.discount_pct / 100) * (1 + l.gst_rate / 100);
  }
  const openOrders = round2(open);
  return { ledger, openOrders, owes: round2(ledger + openOrders) };
}

export interface CreditCheck { allowOver?: boolean }

/**
 * Refuses a new customer document that takes the party over its credit limit (409 CREDIT_LIMIT_EXCEEDED).
 * `allowOver` lets it through for users with `parties.credit_override`, and leaves an audit row.
 * A limit of 0 means no limit. Callers opt in; sector flows (POS, clinic, hotel and so on) never call it.
 */
export async function enforceCreditLimit(tx: Tx, ctx: RequestContext, partyId: string, thisDocument: number, check: CreditCheck) {
  const party = await tx.selectFrom('parties').select(['id', 'name', 'credit_limit'])
    .where('id', '=', partyId).where('company_id', '=', ctx.companyId).forUpdate().executeTakeFirst();
  if (!party || !(party.credit_limit > 0)) return;
  const { ledger, openOrders, owes } = await customerExposure(tx, ctx.companyId, partyId);
  const over = round2(owes + thisDocument - party.credit_limit);
  if (over <= 0) return;
  const figures = { creditLimit: party.credit_limit, owes, thisDocument: round2(thisDocument), over };
  if (!check.allowOver) {
    throw conflict(`${party.name} would be ₹${over.toFixed(2)} over the credit limit of ₹${party.credit_limit.toFixed(2)}.`, 'CREDIT_LIMIT_EXCEEDED', figures);
  }
  ctx.require('parties.credit_override');
  await writeAudit(tx, auditOf(ctx), 'party', partyId, 'credit_override', null, { ...figures, ledger, openOrders });
}
