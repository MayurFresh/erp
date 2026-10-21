import type { Tx } from '../db/database.ts';

export type DocType =
  | 'purchase' | 'receipt' | 'payment' | 'credit_note' | 'transfer' | 'expense' | 'journal'
  | 'indent' | 'issue' | 'wage_sheet';

const PREFIX: Record<DocType, string> = {
  purchase: 'PUR', receipt: 'RCT', payment: 'PAY', credit_note: 'CN', transfer: 'TRF', expense: 'EXP', journal: 'JV',
  indent: 'IND', issue: 'ISS', wage_sheet: 'WG',
};

/** Next gapless number such as `PAY/26-27/00001`; the series row stays locked until commit. */
export async function nextNumber(
  tx: Tx, who: { tenantId: string; companyId: string }, docType: DocType, fy: string,
): Promise<string> {
  const row = await tx.insertInto('doc_series')
    .values({ tenant_id: who.tenantId, company_id: who.companyId, doc_type: docType, fy, next_no: 2 })
    .onConflict((oc) => oc.columns(['company_id', 'doc_type', 'fy']).doUpdateSet((eb) => ({ next_no: eb('doc_series.next_no', '+', 1) })))
    .returning('next_no')
    .executeTakeFirstOrThrow();
  return `${PREFIX[docType]}/${fy.slice(2)}/${String(row.next_no - 1).padStart(5, '0')}`;
}
