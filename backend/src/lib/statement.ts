import { systemAccounts } from '../accounting/accounts.ts';
import { ledger } from '../accounting/ledger.ts';
import type { RequestContext } from '../auth/context.ts';
import type { Tx } from '../db/database.ts';
import { notFound } from './errors.ts';
import { daysBetween } from './dates.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;

export interface Ageing { basis: 'receivable' | 'payable'; notDue: number; d1_30: number; d31_60: number; d61_90: number; d90plus: number; total: number }

const emptyAgeing = (basis: Ageing['basis']): Ageing => ({ basis, notDue: 0, d1_30: 0, d31_60: 0, d61_90: 0, d90plus: 0, total: 0 });

/** Simple interest on an overdue amount for the days past due, for display only. */
export function simpleInterest(amountDue: number, daysOverdue: number, yearlyPct: number): number {
  if (yearlyPct <= 0 || daysOverdue <= 0 || amountDue <= 0) return 0;
  return round2((amountDue * yearlyPct / 100) * (daysOverdue / 365));
}

export function ageingBucket(daysOverdue: number): keyof Omit<Ageing, 'basis' | 'total'> {
  return daysOverdue <= 0 ? 'notDue' : daysOverdue <= 30 ? 'd1_30' : daysOverdue <= 60 ? 'd31_60' : daysOverdue <= 90 ? 'd61_90' : 'd90plus';
}

export async function overdueInterestPct(tx: Tx, companyId: string): Promise<number> {
  const s = await tx.selectFrom('receivable_settings').select('overdue_interest_pct').where('company_id', '=', companyId).executeTakeFirst();
  return Number(s?.overdue_interest_pct ?? 0);
}

/** Statement of a customer or vendor: ledger lines with due dates, open bills, ageing and optional interest. */
export async function partyStatement(tx: Tx, ctx: RequestContext, partyId: string, from: string, to: string) {
  const party = await tx.selectFrom('parties')
    .select(['id', 'name', 'type', 'gstin', 'phone', 'email', 'address', 'no_reminders'])
    .where('id', '=', partyId).where('company_id', '=', ctx.companyId).executeTakeFirst();
  if (!party) throw notFound('Party');
  const acc = await systemAccounts(tx, ctx);
  const result = await ledger(tx, ctx.companyId, { accountIds: [acc.receivables, acc.payables], partyId, from, to });

  // Due dates of the bills that appear as rows.
  const salesIds = result.lines.filter((l) => l.voucherType === 'sales' && l.voucherId).map((l) => l.voucherId!);
  const purchaseIds = result.lines.filter((l) => l.voucherType === 'purchase' && l.voucherId).map((l) => l.voucherId!);
  const dues = new Map<string, string>();
  if (salesIds.length) {
    for (const r of await tx.selectFrom('invoices').select(['id', 'due_date']).where('id', 'in', salesIds).execute()) dues.set(r.id, r.due_date);
  }
  if (purchaseIds.length) {
    for (const r of await tx.selectFrom('purchases').select(['id', 'due_date']).where('id', 'in', purchaseIds).execute()) dues.set(r.id, r.due_date);
  }
  const lines = result.lines.map((l) => ({
    ...l, type: l.voucherType,
    dueDate: (l.voucherType === 'sales' || l.voucherType === 'purchase') && l.voucherId ? dues.get(l.voucherId) ?? null : null,
  }));

  const pct = await overdueInterestPct(tx, ctx.companyId);
  type Bill = { type: 'invoice' | 'purchase'; id: string; number: string; date: string; dueDate: string; total: number; amountDue: number; daysOverdue: number; interestDue: number | null };
  const bills: Bill[] = [];
  if (party.type !== 'vendor') {
    const rows = await tx.selectFrom('invoices').select(['id', 'number', 'invoice_date', 'due_date', 'total', 'amount_paid'])
      .where('company_id', '=', ctx.companyId).where('party_id', '=', partyId).where('status', '=', 'posted')
      .where('invoice_date', '<=', to).whereRef('amount_paid', '<', 'total').orderBy('due_date').orderBy('number').execute();
    for (const r of rows) {
      const amountDue = round2(r.total - r.amount_paid);
      const late = Math.max(daysBetween(r.due_date, to), 0);
      bills.push({
        type: 'invoice', id: r.id, number: r.number, date: r.invoice_date, dueDate: r.due_date, total: r.total, amountDue,
        daysOverdue: late, interestDue: pct > 0 ? simpleInterest(amountDue, late, pct) : null,
      });
    }
  }
  if (party.type !== 'customer') {
    const rows = await tx.selectFrom('purchases').select(['id', 'number', 'bill_date', 'due_date', 'net_payable', 'amount_paid'])
      .where('company_id', '=', ctx.companyId).where('party_id', '=', partyId).where('status', '=', 'posted')
      .where('bill_date', '<=', to).whereRef('amount_paid', '<', 'net_payable').orderBy('due_date').orderBy('number').execute();
    for (const r of rows) {
      bills.push({
        type: 'purchase', id: r.id, number: r.number, date: r.bill_date, dueDate: r.due_date, total: r.net_payable,
        amountDue: round2(r.net_payable - r.amount_paid), daysOverdue: Math.max(daysBetween(r.due_date, to), 0), interestDue: null,
      });
    }
  }
  const ageOf = (basis: Ageing['basis'], type: Bill['type']): Ageing => {
    const a = emptyAgeing(basis);
    for (const b of bills.filter((x) => x.type === type)) {
      const k = ageingBucket(daysBetween(b.dueDate, to));
      a[k] = round2(a[k] + b.amountDue);
      a.total = round2(a.total + b.amountDue);
    }
    return a;
  };
  const vendorOnly = party.type === 'vendor';
  const ageing = vendorOnly ? ageOf('payable', 'purchase') : ageOf('receivable', 'invoice');
  const payablesAgeing = party.type === 'both' ? ageOf('payable', 'purchase') : null;
  const interestTotal = round2(bills.reduce((s, b) => s + (b.interestDue ?? 0), 0));

  return {
    accountId: vendorOnly ? acc.payables : acc.receivables,
    accountName: `${party.name} — party ledger`,
    ...result, lines,
    party: { id: party.id, name: party.name, type: party.type, gstin: party.gstin, phone: party.phone, email: party.email, address: party.address },
    doNotRemind: party.no_reminders,
    openBills: bills, ageing, payablesAgeing, openTotal: ageing.total,
    overdueInterestPct: pct, interestTotal,
  };
}
