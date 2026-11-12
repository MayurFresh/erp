import type { Tx } from '../db/database.ts';

export type DocType =
  | 'sanction' | 'grant_receipt' | 'donation_receipt'
  | 'member' | 'job_card' | 'payroll_run' | 'employee'
  | 'patient' | 'admission' | 'matter' | 'student' | 'reservation'
  | 'purchase' | 'receipt' | 'payment' | 'credit_note' | 'transfer' | 'expense' | 'journal'
  | 'indent' | 'issue' | 'wage_sheet'
  | 'labour_advance' | 'work_order' | 'contractor_advance' | 'ra_bill' | 'retention_release' | 'booking' | 'demand'
  | 'tds_challan' | 'rcm_invoice' | 'bank_entry'
  | 'gst_payment' | 'tax_payment' | 'fixed_asset' | 'depreciation_run'
  | 'approval_request' | 'intercompany'
  | 'production_order' | 'jobwork_challan'
  | 'sales_order' | 'pick_list' | 'shipment' | 'sales_return' | 'purchase_order' | 'grn' | 'stock_count';

const PREFIX: Record<DocType, string> = {
  sanction: 'SAN', grant_receipt: 'GRR', donation_receipt: 'DON',
  member: 'MEM', job_card: 'JOB', payroll_run: 'PRN', employee: 'EMP',
  patient: 'UHID', admission: 'IPD', reservation: 'RSV', matter: 'MAT', student: 'ADM',
  purchase: 'PUR', receipt: 'RCT', payment: 'PAY', credit_note: 'CN', transfer: 'TRF', expense: 'EXP', journal: 'JV',
  indent: 'IND', issue: 'ISS', wage_sheet: 'WG',
  labour_advance: 'LA', work_order: 'WO', contractor_advance: 'CA', ra_bill: 'RAB', retention_release: 'RR',
  booking: 'BKG', demand: 'DMD',
  tds_challan: 'TDC', rcm_invoice: 'RCM', bank_entry: 'BNK',
  gst_payment: 'GPM', tax_payment: 'ITP', fixed_asset: 'FA', depreciation_run: 'DEP',
  approval_request: 'APR', intercompany: 'ICE',
  production_order: 'MO', jobwork_challan: 'JWC',
  sales_order: 'SO', pick_list: 'PCK', shipment: 'SHP', sales_return: 'RMA', purchase_order: 'PO', grn: 'GRN', stock_count: 'CNT',
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
