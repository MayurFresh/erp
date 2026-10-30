import type { Tx } from '../db/database.ts';

/** Filing register record (API v1.6 §1). */
export function filingSelect(tx: Tx, companyId: string) {
  return tx.selectFrom('statutory_filings as f').innerJoin('users as u', 'u.id', 'f.created_by')
    .select(['f.id', 'f.return_type', 'f.period', 'f.status', 'f.filed_on', 'f.arn', 'f.amount_paid', 'f.notes', 'f.export_sha256',
      'f.acknowledged_failures', 'f.setoff_entry_id', 'f.created_at', 'f.created_by', 'u.name as created_by_name', 'f.cancelled_at', 'f.cancel_reason'])
    .where('f.company_id', '=', companyId);
}
type FilingRow = Awaited<ReturnType<ReturnType<typeof filingSelect>['executeTakeFirstOrThrow']>>;

export const filingJson = (r: FilingRow) => ({
  id: r.id, returnType: r.return_type, period: r.period, status: r.status, filedOn: r.filed_on, arn: r.arn, amountPaid: r.amount_paid,
  notes: r.notes, exportSha256: r.export_sha256, acknowledgedFailures: (r.acknowledged_failures ?? []) as unknown[], setoffEntryId: r.setoff_entry_id,
  createdAt: r.created_at, createdBy: { id: r.created_by, name: r.created_by_name }, cancelledAt: r.cancelled_at, cancelReason: r.cancel_reason,
});
export type Filing = ReturnType<typeof filingJson>;

/** The filed record for a return and period, or null. */
export async function filedRecord(tx: Tx, companyId: string, returnType: string, period: string): Promise<Filing | null> {
  const r = await filingSelect(tx, companyId).where('f.return_type', '=', returnType).where('f.period', '=', period).where('f.status', '=', 'filed').executeTakeFirst();
  return r ? filingJson(r) : null;
}
