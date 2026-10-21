import type { Tx } from '../db/database.ts';

export interface Who { tenantId: string; companyId: string; userId: string | null }

export type VoucherType =
  | 'sales' | 'purchase' | 'receipt' | 'payment' | 'credit_note' | 'expense' | 'stock' | 'transfer' | 'journal'
  | 'issue' | 'wages';

/** A journal line. A signed `amount` is a debit when positive and a credit when negative. */
export interface JLine { accountId: string; amount: number; partyId?: string | null; locationId?: string | null }

export interface JEntry {
  date: string; voucherType: VoucherType; voucherId: string | null; number: string | null; narration: string | null; lines: JLine[];
}

const toPaise = (rupees: number) => Math.round(rupees * 100);

/**
 * Posts a balanced journal entry. Zero lines are dropped; the database checks the
 * balance again at commit, so an unbalanced entry can never be saved.
 */
export async function postJournal(tx: Tx, who: Who, e: JEntry): Promise<string> {
  const lines = e.lines.map((l) => ({ ...l, paise: toPaise(l.amount) })).filter((l) => l.paise !== 0);
  const sum = lines.reduce((s, l) => s + l.paise, 0);
  if (sum !== 0) throw new Error(`Unbalanced journal for ${e.voucherType} ${e.number ?? ''}: off by ${sum / 100}`);
  if (lines.length < 2) throw new Error(`Journal for ${e.voucherType} ${e.number ?? ''} needs at least two lines`);

  const entry = await tx.insertInto('journal_entries').values({
    tenant_id: who.tenantId, company_id: who.companyId, entry_date: e.date, voucher_type: e.voucherType,
    voucher_id: e.voucherId, number: e.number, narration: e.narration, reverses_id: null, created_by: who.userId,
  }).returning('id').executeTakeFirstOrThrow();

  await tx.insertInto('journal_lines').values(lines.map((l, i) => ({
    tenant_id: who.tenantId, entry_id: entry.id, line_no: i + 1, account_id: l.accountId,
    party_id: l.partyId ?? null, location_id: l.locationId ?? null,
    debit: l.paise > 0 ? l.paise / 100 : 0, credit: l.paise < 0 ? -l.paise / 100 : 0,
  }))).execute();
  return entry.id;
}

/** Posts the mirror image of one entry (debits become credits) and links it to the original. */
export async function reverseEntry(tx: Tx, who: Who, entryId: string, date: string, narration: string | null): Promise<string> {
  const original = await tx.selectFrom('journal_entries').selectAll().where('id', '=', entryId).executeTakeFirstOrThrow();
  const lines = await tx.selectFrom('journal_lines').selectAll().where('entry_id', '=', entryId).orderBy('line_no').execute();
  const reversal = await tx.insertInto('journal_entries').values({
    tenant_id: who.tenantId, company_id: who.companyId, entry_date: date, voucher_type: original.voucher_type,
    voucher_id: original.voucher_id, number: original.number, narration, is_reversal: true, reverses_id: entryId,
    created_by: who.userId,
  }).returning('id').executeTakeFirstOrThrow();
  await tx.insertInto('journal_lines').values(lines.map((l) => ({
    tenant_id: who.tenantId, entry_id: reversal.id, line_no: l.line_no, account_id: l.account_id,
    party_id: l.party_id, location_id: l.location_id, debit: l.credit, credit: l.debit,
  }))).execute();
  return reversal.id;
}

/** Reverses every not-yet-reversed entry posted for a document. */
export async function reverseVoucher(tx: Tx, who: Who, voucherId: string, date: string, narration: string): Promise<void> {
  const entries = await tx.selectFrom('journal_entries as e')
    .select('e.id')
    .where('e.voucher_id', '=', voucherId)
    .where('e.is_reversal', '=', false)
    .where((eb) => eb.not(eb.exists(eb.selectFrom('journal_entries as r').select('r.id').whereRef('r.reverses_id', '=', 'e.id'))))
    .orderBy('e.created_at')
    .execute();
  for (const e of entries) await reverseEntry(tx, who, e.id, date, narration);
}
