import type { Tx } from '../db/database.ts';

const round2 = (n: number) => Math.round(n * 100) / 100;

export interface LedgerOptions { accountIds?: string[]; partyId?: string; from: string; to: string }

/** Lines of one or more accounts (optionally one party) with opening, running and closing balances (debit-positive). */
export async function ledger(tx: Tx, companyId: string, o: LedgerOptions) {

  let opening = tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .where('je.company_id', '=', companyId).where('je.entry_date', '<', o.from);
  let range = tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .leftJoin('parties as p', 'p.id', 'jl.party_id')
    .where('je.company_id', '=', companyId).where('je.entry_date', '>=', o.from).where('je.entry_date', '<=', o.to);
  if (o.accountIds) {
    const ids = o.accountIds.length ? o.accountIds : ['00000000-0000-0000-0000-000000000000'];
    opening = opening.where('jl.account_id', 'in', ids);
    range = range.where('jl.account_id', 'in', ids);
  }
  if (o.partyId) {
    opening = opening.where('jl.party_id', '=', o.partyId);
    range = range.where('jl.party_id', '=', o.partyId);
  }

  const open = await opening
    .select((eb) => [eb.fn.coalesce(eb.fn.sum<number>('jl.debit'), eb.lit(0)).as('d'), eb.fn.coalesce(eb.fn.sum<number>('jl.credit'), eb.lit(0)).as('c')])
    .executeTakeFirstOrThrow();
  const rows = await range
    .select(['jl.entry_id', 'je.entry_date', 'je.voucher_type', 'je.voucher_id', 'je.number', 'je.narration',
      'p.name as party_name', 'jl.debit', 'jl.credit'])
    .orderBy('je.entry_date').orderBy('je.created_at').orderBy('jl.line_no')
    .execute();

  const openingBalance = round2(Number(open.d) - Number(open.c));
  let balance = openingBalance;
  let totalDebit = 0;
  let totalCredit = 0;
  const lines = rows.map((r) => {
    balance = round2(balance + r.debit - r.credit);
    totalDebit += r.debit;
    totalCredit += r.credit;
    return {
      entryId: r.entry_id, date: r.entry_date, voucherType: r.voucher_type, voucherId: r.voucher_id, number: r.number,
      narration: r.narration, partyName: r.party_name, debit: r.debit, credit: r.credit, balance,
    };
  });
  return {
    from: o.from, to: o.to, openingBalance, closingBalance: balance,
    totalDebit: round2(totalDebit), totalCredit: round2(totalCredit), lines,
  };
}

/** Net balance of a party across receivables and payables: + they owe us, − we owe them. */
export async function partyBalances(tx: Tx, companyId: string, partyIds: string[]): Promise<Map<string, number>> {
  const result = new Map<string, number>();
  if (!partyIds.length) return result;
  const rows = await tx.selectFrom('journal_lines as jl').innerJoin('journal_entries as je', 'je.id', 'jl.entry_id')
    .select((eb) => ['jl.party_id', eb.fn.sum<number>('jl.debit').as('d'), eb.fn.sum<number>('jl.credit').as('c')])
    .where('je.company_id', '=', companyId).where('jl.party_id', 'in', partyIds)
    .groupBy('jl.party_id').execute();
  for (const r of rows) result.set(r.party_id!, round2(Number(r.d) - Number(r.c)));
  return result;
}
