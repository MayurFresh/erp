import type { Generated, GeneratedAlways } from 'kysely';

// numeric columns are parsed to JS numbers and dates to 'YYYY-MM-DD' strings (see database.ts).

export interface TenantTable { id: string; name: string; created_at: Generated<Date> }

export interface CompanyTable {
  id: Generated<string>; tenant_id: string; name: string; legal_name: string | null; gstin: string | null;
  state_code: string; pan: string | null; address: string | null; created_at: Generated<Date>;
  phone: string | null; email: string | null; website: string | null; bank_name: string | null;
  bank_account_no: string | null; bank_ifsc: string | null; upi_id: string | null;
  invoice_terms: string | null; invoice_footer: string | null;
  pincode: string | null; einvoice_enabled: Generated<boolean>; einvoice_mode: Generated<string>;
  tan: string | null; books_locked_until: string | null; msme_bank_rate: number | null; gst_filing: Generated<string>;
  constitution: string | null; responsible_person: unknown | null; itr_form: string | null;
}

export interface LocationTable {
  id: Generated<string>; tenant_id: string; company_id: string; parent_id: string | null; type: string;
  name: string; code: string | null; state_code: string; address: string | null;
  is_active: Generated<boolean>; created_at: Generated<Date>; project_id: Generated<string | null>;
  pincode: string | null;
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
  credit_days: Generated<number>; pan: string | null; pincode: string | null;
  udyam_no: string | null; msme_category: string | null; tds_section_id: string | null;
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
  irn: string | null; irn_ack_no: string | null; irn_ack_date: Date | null; irn_status: string | null;
  irn_signed_qr: string | null; irn_sandbox: Generated<boolean>; irn_cancelled_at: Date | null;
  irn_cancel_reason: string | null; ewb_no: string | null; ewb_date: Date | null; ewb_valid_until: Date | null;
  ewb_status: string | null; ewb_transport_mode: string | null; ewb_vehicle_no: string | null;
  ewb_distance_km: number | null; ewb_transporter_gstin: string | null; ewb_cancelled_at: Date | null;
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
  tds_section_id: string | null; tds_base: Generated<number>; tds_rate: Generated<number>; tds_amount: Generated<number>;
  net_payable: GeneratedAlways<number>; reverse_charge: Generated<boolean>; rcm_self_invoice_no: string | null;
  msme_due_date: string | null;
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
  cancel_reason: string | null; tds_amount: Generated<number>;
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
  cancel_reason: string | null; tds_section_id: string | null; tds_base: Generated<number>; tds_rate: Generated<number>;
  tds_amount: Generated<number>; reverse_charge: Generated<boolean>; rcm_self_invoice_no: string | null;
}

// Construction pack ---------------------------------------------------------------

export interface ProjectTable {
  id: Generated<string>; tenant_id: string; company_id: string; code: string; name: string;
  client_party_id: string | null; manager_user_id: string | null; status: Generated<string>;
  start_date: string | null; end_date: string | null; contract_value: Generated<number>; address: string | null;
  created_by: string | null; created_at: Generated<Date>; rera_reg_no: string | null; rera_account_id: string | null;
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
  rejected_by: string | null; rejected_at: Date | null; reject_reason: string | null;
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

// Phase 2b (migration 006) ----------------------------------------------------------------------

export interface LabourAdvanceTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; worker_id: string;
  site_id: string | null; advance_date: string; amount: number; recovered: Generated<number>;
  paid_from_account_id: string; notes: string | null; status: Generated<string>; created_by: string;
  created_at: Generated<Date>; cancelled_at: Date | null; cancel_reason: string | null;
}

export interface LabourAdvanceRecoveryTable {
  id: Generated<string>; tenant_id: string; labour_advance_id: string; wage_sheet_id: string; amount: number;
}

export interface WorkOrderTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; project_id: string;
  contractor_party_id: string; order_date: string; title: string; scope: string | null; status: Generated<string>;
  retention_pct: Generated<number>; advance_recovery_pct: Generated<number>; tds_pct: Generated<number>;
  gst_pct: Generated<number>; itc_eligible: Generated<boolean>; cess_pct: Generated<number>;
  total_value: Generated<number>; created_by: string; created_at: Generated<Date>; closed_at: Date | null;
  cancelled_at: Date | null; cancel_reason: string | null;
}

export interface WorkOrderLineTable {
  id: Generated<string>; tenant_id: string; work_order_id: string; line_no: number; boq_line_id: string | null;
  description: string; unit: string; qty: number; rate: number; amount: number;
}

export interface ContractorAdvanceTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; work_order_id: string; advance_date: string;
  amount: number; paid_from_account_id: string; notes: string | null; created_by: string;
  created_at: Generated<Date>; cancelled_at: Date | null; cancel_reason: string | null;
}

export interface RaBillTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; work_order_id: string;
  bill_seq: number; bill_date: string; period_from: string | null; period_to: string | null; due_date: string;
  status: Generated<string>; is_final: Generated<boolean>; gross: Generated<number>; cgst: Generated<number>;
  sgst: Generated<number>; igst: Generated<number>; retention: Generated<number>;
  advance_recovery: Generated<number>; tds: Generated<number>; cess: Generated<number>;
  other_deduction: Generated<number>; other_deduction_note: string | null; net_payable: Generated<number>;
  amount_paid: Generated<number>; notes: string | null; reject_reason: string | null; created_by: string;
  created_at: Generated<Date>; submitted_at: Date | null; approved_by: string | null; approved_at: Date | null;
  cancelled_at: Date | null; cancel_reason: string | null;
}

export interface RaBillLineTable {
  id: Generated<string>; tenant_id: string; ra_bill_id: string; work_order_line_id: string;
  prev_qty: Generated<number>; cum_qty: number; this_qty: number; rate: number; amount: number;
}

export interface RetentionReleaseTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; work_order_id: string; release_date: string;
  amount: number; notes: string | null; created_by: string; created_at: Generated<Date>;
}

export interface UnitTable {
  id: Generated<string>; tenant_id: string; company_id: string; project_id: string; code: string;
  wing: string | null; floor: number | null; unit_type: string; carpet_area: number; balcony_area: number | null;
  list_price: Generated<number>; status: Generated<string>; notes: string | null; created_at: Generated<Date>;
}

export interface PaymentPlanTable {
  id: Generated<string>; tenant_id: string; company_id: string; project_id: string; name: string;
  is_active: Generated<boolean>; created_at: Generated<Date>;
}

export interface PaymentPlanStageTable {
  id: Generated<string>; tenant_id: string; payment_plan_id: string; sort_order: number; name: string; pct: number;
}

export interface BookingTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; project_id: string; unit_id: string;
  customer_party_id: string; booking_date: string; agreement_value: number; gst_pct: Generated<number>;
  payment_plan_id: string; status: Generated<string>; agreement_no: string | null; agreement_date: string | null;
  possession_date: string | null; notes: string | null; created_by: string; created_at: Generated<Date>;
  cancelled_at: Date | null; cancel_reason: string | null;
}

export interface BookingStageTable {
  id: Generated<string>; tenant_id: string; booking_id: string; sort_order: number; name: string; pct: number;
  amount: number; demand_id: string | null;
}

export interface DemandTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; booking_id: string; party_id: string;
  demand_date: string; due_date: string; amount: number; cgst: Generated<number>; sgst: Generated<number>;
  total: number; amount_paid: Generated<number>; status: Generated<string>; created_by: string;
  created_at: Generated<Date>; cancelled_at: Date | null; cancel_reason: string | null;
}

// Statutory core (v1.4) ------------------------------------------------------------

export interface GstRateTable {
  id: Generated<string>; tenant_id: string | null; rate: number; kind: string; label: string; effective_from: string;
  effective_to: string | null; is_legacy: Generated<boolean>; created_at: Generated<Date>;
}

export interface TdsSectionTable {
  id: Generated<string>; tenant_id: string | null; code: string; new_ref: string | null; name: string;
  rate_individual: number; rate_other: number; rate_no_pan: number; threshold_single: number | null;
  threshold_aggregate: number | null; aggregate_mode: Generated<string>; effective_from: string;
  effective_to: string | null; verified: Generated<boolean>; is_active: Generated<boolean>; created_at: Generated<Date>;
}

export interface TdsChallanTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; deposit_date: string; bsr_code: string;
  challan_serial: string; tax_amount: number; interest: Generated<number>; late_fee: Generated<number>; total: number;
  paid_from_account_id: string; status: Generated<string>; created_by: string; created_at: Generated<Date>;
  cancelled_at: Date | null; cancel_reason: string | null;
}

export interface TdsDeductionTable {
  id: Generated<string>; tenant_id: string; company_id: string; source_type: string; source_id: string; number: string;
  party_id: string; pan: string | null; section_id: string | null; section_code: string; fy: string;
  deduction_date: string; gross: number; base: number; rate: number; amount: number; status: Generated<string>;
  challan_id: string | null; created_at: Generated<Date>;
}

export interface Gst2bImportTable {
  id: Generated<string>; tenant_id: string; company_id: string; period: string; file_name: string | null;
  line_count: Generated<number>; created_by: string; created_at: Generated<Date>;
}

export interface Gst2bLineTable {
  id: Generated<string>; tenant_id: string; company_id: string; import_id: string; supplier_gstin: string;
  supplier_name: string | null; doc_type: Generated<string>; doc_no: string; doc_date: string; taxable: Generated<number>;
  igst: Generated<number>; cgst: Generated<number>; sgst: Generated<number>; cess: Generated<number>;
  itc_available: Generated<boolean>; purchase_id: string | null; match_status: string; ims_action: Generated<string>;
  note: string | null;
}

export interface BankStatementTable {
  id: Generated<string>; tenant_id: string; company_id: string; account_id: string; file_name: string | null;
  from_date: string | null; to_date: string | null; closing_balance: number | null; created_by: string;
  created_at: Generated<Date>;
}

export interface BankStatementLineTable {
  id: Generated<string>; tenant_id: string; company_id: string; statement_id: string; line_no: number; txn_date: string;
  description: Generated<string>; reference: string | null; withdrawal: Generated<number>; deposit: Generated<number>;
  balance: number | null; status: Generated<string>; journal_line_id: string | null; matched_by: string | null;
  matched_at: Date | null;
}

export interface ComplianceDocTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; category: string; doc_no: string | null;
  issued_by: string | null; issue_date: string | null; expiry_date: string | null; remind_days: Generated<number>;
  location_id: string | null; file_id: string | null; notes: string | null; is_active: Generated<boolean>;
  created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface StatutoryFilingTable {
  id: Generated<string>; tenant_id: string; company_id: string; return_type: string; period: string;
  status: Generated<string>; filed_on: string; arn: string | null; amount_paid: number | null; notes: string | null;
  export_sha256: string | null; acknowledged_failures: Generated<unknown>; setoff_entry_id: string | null;
  created_by: string; created_at: Generated<Date>; cancelled_at: Date | null; cancel_reason: string | null;
}

export interface GstLedgerBalanceTable {
  id: Generated<string>; tenant_id: string; company_id: string; ledger: string; as_of: string;
  igst: Generated<number>; cgst: Generated<number>; sgst: Generated<number>; cess: Generated<number>;
  note: string | null; created_by: string; created_at: Generated<Date>;
}

export interface GstPaymentTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; payment_date: string;
  period: string | null; cpin: string | null; cin: string | null; paid_from_account_id: string;
  igst: Generated<number>; cgst: Generated<number>; sgst: Generated<number>; cess: Generated<number>;
  interest: Generated<number>; late_fee: Generated<number>; total: number; status: Generated<string>;
  created_by: string; created_at: Generated<Date>; cancelled_at: Date | null; cancel_reason: string | null;
}

export interface TaxPaymentTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; kind: string; tax_year: string;
  payment_date: string; amount: number; bsr_code: string; challan_serial: string; paid_from_account_id: string;
  status: Generated<string>; created_by: string; created_at: Generated<Date>; cancelled_at: Date | null;
  cancel_reason: string | null;
}

export interface ItDepreciationBlockTable {
  id: Generated<string>; code: string; name: string; rate: number; effective_from: string;
  effective_to: string | null; verified: Generated<boolean>;
}

export interface FixedAssetTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; name: string; block_code: string;
  book_method: string; useful_life_years: number; residual_pct: Generated<number>; cost: number;
  gst_itc: Generated<number>; purchase_date: string; put_to_use_date: string; location_id: string | null;
  supplier_name: string | null; bill_no: string | null; serial_no: string | null; tag_no: string | null;
  custodian: string | null; notes: string | null; opening_acc_dep: Generated<number>;
  accumulated_dep: Generated<number>; depreciated_until: string | null; status: Generated<string>;
  disposal_date: string | null; sale_value: number | null; gain_loss: number | null;
  capitalise_entry_id: string | null; disposal_entry_id: string | null; created_by: string; created_at: Generated<Date>;
}

export interface DepreciationRunTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; to_date: string; total: number;
  entry_id: string | null; status: Generated<string>; created_by: string; created_at: Generated<Date>;
  cancelled_at: Date | null; cancel_reason: string | null;
}

export interface DepreciationRunLineTable {
  id: Generated<string>; tenant_id: string; run_id: string; asset_id: string; from_date: string; to_date: string;
  days: number; amount: number; prev_depreciated_until: string | null;
}

export interface ItBlockOpeningTable {
  id: Generated<string>; tenant_id: string; company_id: string; fy: string; block_code: string;
  opening_wdv: number; updated_at: Generated<Date>;
}

export interface IdempotencyKeyTable {
  id: Generated<string>; tenant_id: string; user_id: string; key: string; method: string; path: string;
  body_hash: string; status: number | null; response: string | null; state: Generated<string>;
  created_at: Generated<Date>;
}

export interface Database {
  idempotency_keys: IdempotencyKeyTable;
  statutory_filings: StatutoryFilingTable;
  gst_ledger_balances: GstLedgerBalanceTable;
  gst_payments: GstPaymentTable;
  tax_payments: TaxPaymentTable;
  it_depreciation_blocks: ItDepreciationBlockTable;
  fixed_assets: FixedAssetTable;
  depreciation_runs: DepreciationRunTable;
  depreciation_run_lines: DepreciationRunLineTable;
  it_block_openings: ItBlockOpeningTable;
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
  labour_advances: LabourAdvanceTable;
  labour_advance_recoveries: LabourAdvanceRecoveryTable;
  work_orders: WorkOrderTable;
  work_order_lines: WorkOrderLineTable;
  contractor_advances: ContractorAdvanceTable;
  ra_bills: RaBillTable;
  ra_bill_lines: RaBillLineTable;
  retention_releases: RetentionReleaseTable;
  units: UnitTable;
  payment_plans: PaymentPlanTable;
  payment_plan_stages: PaymentPlanStageTable;
  bookings: BookingTable;
  booking_stages: BookingStageTable;
  demands: DemandTable;
  gst_rates: GstRateTable;
  tds_sections: TdsSectionTable;
  tds_challans: TdsChallanTable;
  tds_deductions: TdsDeductionTable;
  gst_2b_imports: Gst2bImportTable;
  gst_2b_lines: Gst2bLineTable;
  bank_statements: BankStatementTable;
  bank_statement_lines: BankStatementLineTable;
  compliance_docs: ComplianceDocTable;
}
