import type { Generated, GeneratedAlways } from 'kysely';

// numeric columns are parsed to JS numbers and dates to 'YYYY-MM-DD' strings (see database.ts).

export interface TenantTable { id: string; name: string; created_at: Generated<Date> }

export interface CompanyTable {
  id: Generated<string>; tenant_id: string; name: string; legal_name: string | null; gstin: string | null;
  state_code: string; pan: string | null; address: string | null; created_at: Generated<Date>;
  phone: string | null; email: string | null; website: string | null; bank_name: string | null;
  bank_account_no: string | null; bank_ifsc: string | null; upi_id: string | null;
  invoice_terms: string | null; invoice_footer: string | null;
}

export interface LocationTable {
  id: Generated<string>; tenant_id: string; company_id: string; parent_id: string | null; type: string;
  name: string; code: string | null; state_code: string; address: string | null;
  is_active: Generated<boolean>; created_at: Generated<Date>; project_id: Generated<string | null>;
}

export interface UserTable {
  id: Generated<string>; tenant_id: string; name: string; email: string; phone: string | null;
  password_hash: string; is_active: Generated<boolean>; created_at: Generated<Date>;
}

export interface RoleTable {
  id: Generated<string>; tenant_id: string; name: string; description: string | null;
  is_system: Generated<boolean>; permissions: string[]; created_at: Generated<Date>;
}

export interface UserRoleTable {
  id: Generated<string>; tenant_id: string; user_id: string; role_id: string; company_id: string;
  location_ids: string[] | null; valid_from: string | null; valid_to: string | null; created_at: Generated<Date>;
}

export interface RefreshTokenTable {
  id: string; tenant_id: string; user_id: string; expires_at: Date; revoked_at: Date | null; created_at: Generated<Date>;
}

export interface ItemTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; sku: string | null;
  hsn_code: string | null; unit: string; gst_rate: number; sale_price: Generated<number>;
  purchase_price: Generated<number>; track_stock: Generated<boolean>; reorder_level: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface PartyTable {
  id: Generated<string>; tenant_id: string; company_id: string; type: string; name: string;
  gstin: string | null; state_code: string | null; phone: string | null; email: string | null;
  address: string | null; credit_limit: Generated<number>; created_at: Generated<Date>;
  credit_days: Generated<number>;
}

export interface StockMoveTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; item_id: string;
  qty: number; rate: number | null; ref_type: string; ref_id: string | null; note: string | null;
  created_by: string | null; created_at: Generated<Date>; cost_rate: number | null; value: number;
}

export interface InvoiceSeriesTable { tenant_id: string; company_id: string; fy: string; next_no: number }

export interface InvoiceTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; party_id: string;
  number: string; fy: string; invoice_date: string; place_of_supply: string; supply_type: string;
  status: Generated<string>; subtotal: number; cgst: number; sgst: number; igst: number;
  round_off: number; total: number; notes: string | null; created_by: string; created_at: Generated<Date>;
  cancelled_at: Date | null; cancel_reason: string | null; due_date: string; amount_paid: Generated<number>;
}

export interface InvoiceLineTable {
  id: Generated<string>; tenant_id: string; invoice_id: string; line_no: number; item_id: string;
  description: string; hsn_code: string | null; qty: number; unit: string; rate: number;
  discount_pct: number; taxable_value: number; gst_rate: number; cgst: number; sgst: number;
  igst: number; line_total: number; returned_qty: Generated<number>;
}

export interface AuditLogTable {
  id: Generated<string>; tenant_id: string; company_id: string | null; user_id: string | null;
  entity: string; entity_id: string | null; action: string; before: unknown; after: unknown;
  created_at: Generated<Date>;
}

export interface DocSeriesTable { tenant_id: string; company_id: string; doc_type: string; fy: string; next_no: number }

export interface AccountTable {
  id: Generated<string>; tenant_id: string; company_id: string; code: string; name: string; type: string;
  subtype: Generated<string>; system_key: string | null; is_system: Generated<boolean>; is_active: Generated<boolean>;
  created_at: Generated<Date>;
}

export interface JournalEntryTable {
  id: Generated<string>; tenant_id: string; company_id: string; entry_date: string; voucher_type: string;
  voucher_id: string | null; number: string | null; narration: string | null; is_reversal: Generated<boolean>;
  reverses_id: string | null; created_by: string | null; created_at: Generated<Date>;
}

export interface JournalLineTable {
  id: Generated<string>; tenant_id: string; entry_id: string; line_no: number; account_id: string;
  party_id: string | null; location_id: string | null; debit: Generated<number>; credit: Generated<number>;
}

interface DocTotals {
  subtotal: number; cgst: number; sgst: number; igst: number; round_off: number; total: number;
}

export interface PurchaseTable extends DocTotals {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; party_id: string;
  number: string; supplier_invoice_no: string | null; supplier_invoice_date: string | null; fy: string;
  bill_date: string; due_date: string; place_of_supply: string; supply_type: string; status: Generated<string>;
  amount_paid: Generated<number>; notes: string | null; created_by: string; created_at: Generated<Date>;
  cancelled_at: Date | null; cancel_reason: string | null; indent_id: Generated<string | null>;
}

export interface DocLineTable {
  id: Generated<string>; tenant_id: string; line_no: number; item_id: string; description: string;
  hsn_code: string | null; qty: number; unit: string; rate: number; discount_pct: number; taxable_value: number;
  gst_rate: number; cgst: number; sgst: number; igst: number; line_total: number;
}
export interface PurchaseLineTable extends DocLineTable { purchase_id: string }
export interface CreditNoteLineTable extends DocLineTable { credit_note_id: string; invoice_line_id: string }

export interface PaymentTable {
  id: Generated<string>; tenant_id: string; company_id: string; kind: string; number: string; payment_date: string;
  party_id: string; account_id: string; mode: string; reference: string | null; amount: number; notes: string | null;
  status: Generated<string>; created_by: string; created_at: Generated<Date>; cancelled_at: Date | null;
  cancel_reason: string | null;
}

export interface PaymentAllocationTable {
  id: Generated<string>; tenant_id: string; payment_id: string; doc_type: string; doc_id: string; amount: number;
}

export interface CreditNoteTable extends DocTotals {
  id: Generated<string>; tenant_id: string; company_id: string; invoice_id: string; location_id: string;
  party_id: string; number: string; fy: string; note_date: string; reason: string; restock: boolean;
  place_of_supply: string; supply_type: string; status: Generated<string>; applied_amount: Generated<number>;
  created_by: string; created_at: Generated<Date>; cancelled_at: Date | null; cancel_reason: string | null;
}

export interface TransferTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; from_location_id: string;
  to_location_id: string; status: Generated<string>; transfer_date: string; notes: string | null; created_by: string;
  created_at: Generated<Date>; received_by: string | null; received_at: Date | null; cancelled_at: Date | null;
  cancel_reason: string | null; indent_id: Generated<string | null>;
}

export interface TransferLineTable {
  id: Generated<string>; tenant_id: string; transfer_id: string; line_no: number; item_id: string; qty: number;
  cost_rate: number; value: number;
}

export interface ExpenseTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; expense_date: string;
  location_id: string; account_id: string; party_id: string | null; description: string; amount: number;
  gst_rate: number; cgst: number; sgst: number; igst: number; total: number; paid_from_account_id: string;
  status: Generated<string>; created_by: string; created_at: Generated<Date>; cancelled_at: Date | null;
  cancel_reason: string | null;
}

// Construction pack ---------------------------------------------------------------

export interface ProjectTable {
  id: Generated<string>; tenant_id: string; company_id: string; code: string; name: string;
  client_party_id: string | null; manager_user_id: string | null; status: Generated<string>;
  start_date: string | null; end_date: string | null; contract_value: Generated<number>; address: string | null;
  created_by: string | null; created_at: Generated<Date>;
}

export interface BoqLineTable {
  id: Generated<string>; tenant_id: string; project_id: string; code: string; description: string; unit: string;
  qty: number; rate: number; amount: GeneratedAlways<number>; material_budget: Generated<number>;
  labour_budget: Generated<number>; other_budget: Generated<number>; sort_order: Generated<number>;
  created_at: Generated<Date>;
}

export interface IndentTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; location_id: string;
  required_by: string | null; status: Generated<string>; notes: string | null; created_by: string;
  created_at: Generated<Date>; submitted_at: Date | null; approved_by: string | null; approved_at: Date | null;
  rejected_by: string | null; rejected_at: Date | null; reject_reason: string | null; closed_by: string | null;
  closed_at: Date | null;
}

export interface IndentLineTable {
  id: Generated<string>; tenant_id: string; indent_id: string; line_no: number; item_id: string; qty: number;
  approved_qty: number | null; boq_line_id: string | null;
}

export interface IndentFulfilmentTable {
  id: Generated<string>; tenant_id: string; indent_line_id: string; source_type: string; source_id: string;
  qty: number; created_at: Generated<Date>;
}

export interface IssueTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; issue_date: string;
  location_id: string; boq_line_id: string | null; notes: string | null; status: Generated<string>;
  created_by: string; created_at: Generated<Date>; cancelled_at: Date | null; cancel_reason: string | null;
}

export interface IssueLineTable {
  id: Generated<string>; tenant_id: string; issue_id: string; line_no: number; item_id: string; qty: number;
  cost_rate: number; value: number;
}

export interface FileTable {
  id: string; tenant_id: string; company_id: string | null; name: string; mime_type: string; size: number;
  storage_key: string; created_by: string | null; created_at: Generated<Date>;
}

export interface DprTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; report_date: string;
  weather: string | null; status: Generated<string>; summary: string | null; hindrances: string | null;
  labour: unknown; equipment: unknown; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
  submitted_at: Date | null; approved_by: string | null; approved_at: Date | null;
}

export interface DprWorkTable {
  id: Generated<string>; tenant_id: string; dpr_id: string; line_no: number; boq_line_id: string | null;
  description: string; qty: number | null; unit: string | null;
}

export interface DprPhotoTable {
  id: Generated<string>; tenant_id: string; dpr_id: string; line_no: number; file_id: string; caption: string | null;
}

export interface WorkerTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; phone: string | null; trade: string;
  skill: Generated<string>; daily_rate: number; contractor_party_id: string | null; site_id: string | null;
  aadhaar_last4: string | null; bocw_reg_no: string | null; photo_file_id: string | null; joined_on: string | null;
  is_active: Generated<boolean>; created_at: Generated<Date>;
}

export interface AttendanceTable {
  id: Generated<string>; tenant_id: string; company_id: string; site_id: string; worker_id: string; att_date: string;
  status: string; ot_hours: Generated<number>; marked_by: string | null; marked_at: Generated<Date>;
}

export interface WageSheetTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; site_id: string; from_date: string;
  to_date: string; status: Generated<string>; total_gross: Generated<number>; total_deductions: Generated<number>;
  total_net: Generated<number>; approved_by: string | null; approved_at: Date | null;
  paid_from_account_id: string | null; paid_date: string | null; paid_at: Date | null; paid_by: string | null;
  created_by: string; created_at: Generated<Date>; cancelled_at: Date | null; cancel_reason: string | null;
}

export interface WageSheetRowTable {
  id: Generated<string>; tenant_id: string; wage_sheet_id: string; worker_id: string; daily_rate: number;
  present_days: number; ot_hours: number; basic: number; ot_amount: number; gross: number;
  advance: Generated<number>; net: number;
}

export interface Database {
  tenants: TenantTable;
  companies: CompanyTable;
  locations: LocationTable;
  users: UserTable;
  roles: RoleTable;
  user_roles: UserRoleTable;
  refresh_tokens: RefreshTokenTable;
  items: ItemTable;
  parties: PartyTable;
  stock_moves: StockMoveTable;
  invoice_series: InvoiceSeriesTable;
  invoices: InvoiceTable;
  invoice_lines: InvoiceLineTable;
  audit_log: AuditLogTable;
  doc_series: DocSeriesTable;
  accounts: AccountTable;
  journal_entries: JournalEntryTable;
  journal_lines: JournalLineTable;
  purchases: PurchaseTable;
  purchase_lines: PurchaseLineTable;
  payments: PaymentTable;
  payment_allocations: PaymentAllocationTable;
  credit_notes: CreditNoteTable;
  credit_note_lines: CreditNoteLineTable;
  transfers: TransferTable;
  transfer_lines: TransferLineTable;
  expenses: ExpenseTable;
  projects: ProjectTable;
  boq_lines: BoqLineTable;
  indents: IndentTable;
  indent_lines: IndentLineTable;
  indent_fulfilments: IndentFulfilmentTable;
  issues: IssueTable;
  issue_lines: IssueLineTable;
  files: FileTable;
  dprs: DprTable;
  dpr_work: DprWorkTable;
  dpr_photos: DprPhotoTable;
  workers: WorkerTable;
  attendance: AttendanceTable;
  wage_sheets: WageSheetTable;
  wage_sheet_rows: WageSheetRowTable;
}
