import type { Generated, GeneratedAlways } from 'kysely';

// numeric columns are parsed to JS numbers and dates to 'YYYY-MM-DD' strings (see database.ts).

/** Custom field values by key (v1.7). */
export type CustomValues = Record<string, string | number | boolean>;

export interface TenantTable {
  id: string; name: string; created_at: Generated<Date>;
  status: Generated<string>; suspended_at: Date | null; suspended_reason: string | null;
}

export interface CompanyTable {
  id: Generated<string>; tenant_id: string; name: string; legal_name: string | null; gstin: string | null;
  state_code: string; pan: string | null; address: string | null; created_at: Generated<Date>;
  phone: string | null; email: string | null; website: string | null; bank_name: string | null;
  bank_account_no: string | null; bank_ifsc: string | null; upi_id: string | null;
  invoice_terms: string | null; invoice_footer: string | null;
  pincode: string | null; einvoice_enabled: Generated<boolean>; einvoice_mode: Generated<string>;
  tan: string | null; books_locked_until: string | null; msme_bank_rate: number | null; gst_filing: Generated<string>;
  constitution: string | null; responsible_person: unknown | null; itr_form: string | null;
  require_2fa: Generated<boolean>; cost_centre_required: Generated<boolean>; gsp_provider: string | null;
  po_receipt_tolerance_pct: Generated<number>; po_price_tolerance_pct: Generated<number>; count_approval_value: Generated<number>;
  pos_prices_include_tax: Generated<boolean | null>; pos_invoice_prefix: Generated<string>;
  business_type: Generated<string>; plan: Generated<string>; enabled_modules: string[] | null; terms: Generated<unknown>;
  country: Generated<string>; currency: Generated<string>; logo_file_id: string | null; brand_color: string | null;
}

export interface LocationTable {
  id: Generated<string>; tenant_id: string; company_id: string; parent_id: string | null; type: string;
  name: string; code: string | null; state_code: string; address: string | null;
  is_active: Generated<boolean>; created_at: Generated<Date>; project_id: Generated<string | null>;
  pincode: string | null; updated_at: Generated<Date>;
}

export interface UserTable {
  id: Generated<string>; tenant_id: string; name: string; email: string; phone: string | null;
  password_hash: string; is_active: Generated<boolean>; created_at: Generated<Date>;
  two_factor_secret_enc: string | null; two_factor_pending_enc: string | null; two_factor_enabled_at: Date | null;
  two_factor_last_step: number | null; recovery_codes: Generated<string[]>; failed_logins: Generated<number>;
  locked_until: Date | null; password_changed_at: Date | null;
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
  session_id: string; user_agent: string | null; ip: string | null; last_used_at: Date | null; amr: Generated<string>;
}

export interface ItemTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; sku: string | null; barcode: Generated<string | null>;
  hsn_code: string | null; unit: string; gst_rate: number; sale_price: Generated<number>;
  purchase_price: Generated<number>; track_stock: Generated<boolean>; reorder_level: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>; custom: Generated<CustomValues>;
}

export interface PartyTable {
  id: Generated<string>; tenant_id: string; company_id: string; type: string; name: string;
  gstin: string | null; state_code: string | null; phone: string | null; email: string | null;
  address: string | null; credit_limit: Generated<number>; created_at: Generated<Date>;
  credit_days: Generated<number>; pan: string | null; pincode: string | null;
  udyam_no: string | null; msme_category: string | null; tds_section_id: string | null; custom: Generated<CustomValues>;
  updated_at: Generated<Date>;
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
  custom: Generated<CustomValues>; cost_centre_id: string | null;
  reverse_charge: Generated<boolean>; rcm_tax: Generated<number>;
}

export interface InvoiceLineTable {
  id: Generated<string>; tenant_id: string; invoice_id: string; line_no: number; item_id: string;
  description: string; hsn_code: string | null; qty: number; unit: string; rate: number;
  discount_pct: number; taxable_value: number; gst_rate: number; cgst: number; sgst: number;
  igst: number; line_total: number; returned_qty: Generated<number>; discount_amount: number | null;
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
  created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface JournalEntryTable {
  id: Generated<string>; tenant_id: string; company_id: string; entry_date: string; voucher_type: string;
  voucher_id: string | null; number: string | null; narration: string | null; is_reversal: Generated<boolean>;
  reverses_id: string | null; created_by: string | null; created_at: Generated<Date>;
}

export interface JournalLineTable {
  id: Generated<string>; tenant_id: string; entry_id: string; line_no: number; account_id: string;
  party_id: string | null; location_id: string | null; debit: Generated<number>; credit: Generated<number>;
  cost_centre_id: Generated<string | null>;
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
  msme_due_date: string | null; custom: Generated<CustomValues>; cost_centre_id: string | null;
  purchase_order_id: Generated<string | null>; variance_accepted: Generated<boolean>;
}

export interface DocLineTable {
  id: Generated<string>; tenant_id: string; line_no: number; item_id: string; description: string;
  hsn_code: string | null; qty: number; unit: string; rate: number; discount_pct: number; taxable_value: number;
  gst_rate: number; cgst: number; sgst: number; igst: number; line_total: number;
}
export interface PurchaseLineTable extends DocLineTable {
  purchase_id: string; grn_line_id: Generated<string | null>; grni_value: Generated<number>; variance_value: Generated<number>;
}
export interface CreditNoteLineTable extends DocLineTable { credit_note_id: string; invoice_line_id: string; discount_amount: number | null }

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
  cost_centre_id: string | null;
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
  cost_centre_id: string | null;
}

// Construction pack ---------------------------------------------------------------

export interface ProjectTable {
  id: Generated<string>; tenant_id: string; company_id: string; code: string; name: string;
  client_party_id: string | null; manager_user_id: string | null; status: Generated<string>;
  start_date: string | null; end_date: string | null; contract_value: Generated<number>; address: string | null;
  created_by: string | null; created_at: Generated<Date>; rera_reg_no: string | null; rera_account_id: string | null;
  custom: Generated<CustomValues>;  updated_at: Generated<Date>;
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
  is_active: Generated<boolean>; created_at: Generated<Date>;  updated_at: Generated<Date>;
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
  cancelled_at: Date | null; cancel_reason: string | null;  updated_at: Generated<Date>;
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
  cancelled_at: Date | null; cancel_reason: string | null;  updated_at: Generated<Date>;
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
  list_price: Generated<number>; status: Generated<string>; notes: string | null; created_at: Generated<Date>;  updated_at: Generated<Date>;
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
  cancelled_at: Date | null; cancel_reason: string | null;  updated_at: Generated<Date>;
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

// v1.7 enterprise platform ---------------------------------------------------------------

export interface MfaChallengeTable {
  id: string; tenant_id: string; user_id: string; attempts: Generated<number>; expires_at: Date; used_at: Date | null;
  created_at: Generated<Date>;
}

export interface PasswordResetTable {
  id: Generated<string>; tenant_id: string; user_id: string; token_hash: string; expires_at: Date; used_at: Date | null;
  created_at: Generated<Date>;
}

export interface SsoProviderTable {
  id: Generated<string>; tenant_id: string; name: string; issuer: string; client_id: string; client_secret_enc: string | null;
  email_domains: string[]; enforce: Generated<boolean>; auto_provision: Generated<boolean>; default_company_id: string | null;
  default_role_id: string | null; is_active: Generated<boolean>; created_by: string | null; created_at: Generated<Date>;
  updated_at: Generated<Date>;
}

export interface SsoStateTable {
  state: string; tenant_id: string; provider_id: string; nonce: string; code_verifier: string; return_to: string;
  expires_at: Date; created_at: Generated<Date>;
}

export interface SsoTicketTable {
  id: Generated<string>; tenant_id: string; ticket_hash: string; user_id: string; provider_id: string; expires_at: Date;
  used_at: Date | null; created_at: Generated<Date>;
}

export interface GspCredentialTable {
  id: Generated<string>; tenant_id: string; company_id: string; provider: string; values: Record<string, string>;
  updated_by: string | null; updated_at: Generated<Date>;
}

export interface GspSubmissionTable {
  id: Generated<string>; tenant_id: string; company_id: string; kind: string; period: string; provider: string;
  reference: string; status: string; response: unknown | null; created_by: string; created_at: Generated<Date>;
}

export interface JobTable {
  id: Generated<string>; tenant_id: string; company_id: string | null; kind: string; payload: Generated<unknown>;
  status: Generated<string>; attempts: Generated<number>; max_attempts: Generated<number>; run_after: Generated<Date>;
  started_at: Date | null; heartbeat_at: Date | null; finished_at: Date | null; result: unknown | null; error: string | null;
  dedupe_key: string | null;
  created_by: string | null; created_at: Generated<Date>;
}

export interface NotificationTable {
  id: Generated<string>; tenant_id: string; company_id: string | null; user_id: string; template: string; title: string;
  body: string; link: string | null; read_at: Date | null; created_at: Generated<Date>;
}

export interface NotificationOutboxTable {
  id: Generated<string>; tenant_id: string; company_id: string | null; channel: string; to_address: string | null;
  user_id: string | null; party_id: string | null; template: string; subject: string | null; body: string;
  data: Generated<unknown>; status: Generated<string>; attempts: Generated<number>; error: string | null;
  provider_ref: string | null; sent_at: Date | null; created_at: Generated<Date>;
}

export interface NotificationPrefTable {
  tenant_id: string; user_id: string; template: string; email: boolean; whatsapp: boolean | null; updated_at: Generated<Date>;
}

export interface ApprovalRuleTable {
  id: Generated<string>; tenant_id: string; company_id: string; doc_type: string; name: string; min_amount: number;
  location_id: string | null; is_active: Generated<boolean>; created_by: string | null; created_at: Generated<Date>;
  updated_at: Generated<Date>;
}

export interface ApprovalRuleLevelTable {
  id: Generated<string>; tenant_id: string; rule_id: string; level: number; approver_role_id: string | null;
  approver_user_id: string | null;
}

export interface ApprovalRequestTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; doc_type: string; status: Generated<string>;
  amount: number; doc_date: string; party_id: string | null; location_id: string | null; narration: string | null;
  payload: unknown; rule_id: string; rule_name: string; levels: unknown; current_level: Generated<number>;
  total_levels: number; requested_by: string; requested_at: Generated<Date>; decided_at: Date | null;
  document_id: string | null; document_number: string | null;
}

export interface ApprovalActionTable {
  id: Generated<string>; tenant_id: string; request_id: string; level: number | null; action: string; user_id: string;
  comment: string | null; created_at: Generated<Date>;
}

export interface CustomFieldTable {
  id: Generated<string>; tenant_id: string; company_id: string; entity: string; key: string; label: string; type: string;
  options: Generated<string[]>; required: Generated<boolean>; show_on_print: Generated<boolean>; sort_order: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface CostCentreTable {
  id: Generated<string>; tenant_id: string; company_id: string; code: string; name: string; parent_id: string | null;
  is_active: Generated<boolean>; created_at: Generated<Date>;  updated_at: Generated<Date>;
}

export interface ImportJobTable {
  id: Generated<string>; tenant_id: string; company_id: string; kind: string; status: string; file_name: string | null;
  csv: string; total_rows: Generated<number>; valid_rows: Generated<number>; errors: Generated<unknown>;
  preview: Generated<unknown>; options: Generated<unknown>; result: unknown | null; error: string | null;
  job_id: string | null; created_by: string; created_at: Generated<Date>; finished_at: Date | null;
}

export interface IntercompanyEntryTable {
  id: Generated<string>; tenant_id: string; number: string; entry_date: string; amount: number; narration: string;
  status: Generated<string>; from_company_id: string; from_account_id: string; from_entry_id: string;
  to_company_id: string; to_account_id: string; to_entry_id: string; created_by: string; created_at: Generated<Date>;
  cancelled_at: Date | null; cancel_reason: string | null;
}

// v1.8 order to cash (013_o2c.sql)
export interface SalesOrderTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; party_id: string; number: string; fy: string;
  order_date: string; expected_date: string | null; status: Generated<string>; source: Generated<string>;
  external_ref: string | null; place_of_supply: string; subtotal: Generated<number>; tax_total: Generated<number>;
  total: Generated<number>; notes: string | null; cancel_reason: string | null; confirmed_at: Date | null;
  cancelled_at: Date | null; closed_at: Date | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
  channel_id?: string | null;
}
export interface SalesOrderLineTable {
  id: Generated<string>; tenant_id: string; order_id: string; line_no: number; item_id: string; description: string;
  qty_ordered: number; rate: number; discount_pct: Generated<number>; gst_rate: number; allow_backorder: Generated<boolean>;
  qty_reserved: Generated<number>; qty_picked: Generated<number>; qty_packed: Generated<number>;
  qty_dispatched: Generated<number>; qty_returned: Generated<number>; qty_cancelled: Generated<number>;
}
export interface SalesOrderEventTable {
  id: Generated<string>; tenant_id: string; order_id: string; kind: string; message: string; created_by: string | null;
  created_at: Generated<Date>;
}
export interface StockReservationTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; item_id: string; order_line_id: string;
  qty: number; status: Generated<string>; note: string | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface PickListTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; number: string; status: Generated<string>;
  created_by: string; created_at: Generated<Date>; completed_at: Date | null;
}
export interface PickListLineTable {
  id: Generated<string>; tenant_id: string; pick_list_id: string; line_no: number; order_id: string; order_line_id: string;
  item_id: string; qty_target: number; qty_picked: Generated<number>;
}
export interface ScanEventTable {
  id: Generated<string>; tenant_id: string; company_id: string; kind: string; ref_id: string; scan_id: string;
  code: string | null; item_id: string; qty: number; result: unknown; created_by: string | null; created_at: Generated<Date>;
}
export interface ShipmentTable {
  id: Generated<string>; tenant_id: string; company_id: string; order_id: string; invoice_id: string; number: string;
  courier: string | null; awb: string | null; mode: Generated<string>; cod_amount: Generated<number>; status: Generated<string>;
  dispatch_key: string | null; notes: string | null; dispatched_at: Generated<Date>; delivered_at: Date | null;
  created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ShipmentLineTable {
  id: Generated<string>; tenant_id: string; shipment_id: string; order_line_id: string; invoice_line_id: string;
  item_id: string; qty: number;
}
export interface ShipmentStatusHistoryTable {
  id: Generated<string>; tenant_id: string; shipment_id: string; status: string; note: string | null;
  created_by: string | null; created_at: Generated<Date>;
}
export interface SalesReturnTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; invoice_id: string;
  order_id: string | null; shipment_id: string | null; party_id: string; number: string; type: Generated<string>;
  status: Generated<string>; reason: string; credit_note_id: string | null; received_at: Date | null;
  inspected_at: Date | null; closed_at: Date | null; created_by: string | null; created_at: Generated<Date>;
  updated_at: Generated<Date>;
}
export interface SalesReturnLineTable {
  id: Generated<string>; tenant_id: string; return_id: string; line_no: number; invoice_line_id: string;
  order_line_id: string | null; item_id: string; qty: number; qty_received: number | null;
  disposition: string | null; note: string | null;
}

// ---- v1.8 B: procure to pay and stock counts (migration 014) ----
export interface PurchaseOrderTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; party_id: string; number: string; fy: string;
  order_date: string; expected_date: string | null; status: Generated<string>; place_of_supply: string; supply_type: string;
  subtotal: number; cgst: number; sgst: number; igst: number; round_off: number; total: number; notes: string | null;
  approval_request_id: string | null; submitted_at: Date | null; approved_at: Date | null; sent_at: Date | null;
  cancelled_at: Date | null; cancel_reason: string | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface PurchaseOrderLineTable extends DocLineTable {
  purchase_order_id: string; received_qty: Generated<number>; rejected_qty: Generated<number>;
  billed_qty: Generated<number>; cancelled_qty: Generated<number>;
}
export interface GoodsReceiptTable {
  id: Generated<string>; tenant_id: string; company_id: string; purchase_order_id: string; party_id: string; location_id: string;
  number: string; fy: string; receipt_date: string; challan_no: string | null; challan_date: string | null; vehicle_no: string | null;
  notes: string | null; status: Generated<string>; created_by: string; created_at: Generated<Date>;
  cancelled_at: Date | null; cancel_reason: string | null;
}
export interface GoodsReceiptLineTable {
  id: Generated<string>; tenant_id: string; goods_receipt_id: string; line_no: number; po_line_id: string; item_id: string;
  received_qty: number; accepted_qty: number; rejected_qty: number; reject_reason: string | null; unit_cost: number;
  value: Generated<number>; billed_qty: Generated<number>; cleared_value: Generated<number>;
}
export interface StockCountTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; number: string; fy: string;
  scope: string; status: Generated<string>; snapshot_at: Generated<Date>; notes: string | null; variance_value: number | null;
  approved_by: string | null; posted_by: string | null; posted_at: Date | null; cancelled_at: Date | null;
  cancel_reason: string | null; created_by: string; created_at: Generated<Date>;
}
export interface StockCountLineTable {
  id: Generated<string>; tenant_id: string; count_id: string; item_id: string; expected_qty: number;
  counted_qty: number | null; counted_at: Date | null; counted_by: string | null; variance_qty: number | null; variance_value: number | null;
}
export interface StockCountScanTable {
  id: Generated<string>; tenant_id: string; count_id: string; scan_id: string; item_id: string; code: string | null;
  mode: string; qty: number; created_by: string | null; created_at: Generated<Date>;
}

export interface ClinicPatientTable {
  id: Generated<string>; tenant_id: string; company_id: string; party_id: string; uhid: string; name: string; sex: string;
  dob: string | null; age_years: number | null; phone: string; address: string | null; blood_group: string | null;
  allergies: string | null; emergency_name: string | null; emergency_phone: string | null; notes: string | null;
  is_active: Generated<boolean>; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ClinicDoctorTable {
  id: Generated<string>; tenant_id: string; company_id: string; user_id: string | null; name: string; speciality: string | null;
  registration_no: string | null; consult_fee: Generated<number>; follow_up_fee: Generated<number>; follow_up_days: Generated<number>;
  slot_minutes: Generated<number>; working_hours: Generated<unknown>; is_active: Generated<boolean>;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ClinicAppointmentTable {
  id: Generated<string>; tenant_id: string; company_id: string; patient_id: string; doctor_id: string; appt_date: string;
  start_time: string | null; end_time: string | null; token_no: number | null; kind: Generated<string>; status: Generated<string>;
  reason: string | null; cancel_reason: string | null; arrived_at: Date | null; created_by: string;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ClinicVisitTable {
  id: Generated<string>; tenant_id: string; company_id: string; appointment_id: string | null; patient_id: string; doctor_id: string;
  visit_date: string; status: Generated<string>; vitals: Generated<unknown>; complaints: string | null; findings: string | null;
  diagnosis: string | null; tests_advised: string | null; advice: string | null; followup_date: string | null;
  fee_kind: string | null; invoice_id: string | null; created_by: string; created_at: Generated<Date>;
  updated_at: Generated<Date>; closed_at: Date | null;
}
// Clinic IPD (039)
export interface ClinicWardTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; kind: Generated<string>; sort_order: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ClinicBedTable {
  id: Generated<string>; tenant_id: string; company_id: string; ward_id: string; bed_no: string; daily_rate: Generated<number>;
  status: Generated<string>; is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ClinicAdmissionTable {
  id: Generated<string>; tenant_id: string; company_id: string; admission_no: string; patient_id: string; doctor_id: string;
  bed_id: string | null; status: Generated<string>; admit_date: string; admitted_at: Generated<Date>; expected_days: number | null;
  provisional_diagnosis: string | null; discharge_date: string | null; discharged_at: Date | null; diagnosis: string | null;
  treatment: string | null; advice: string | null; condition: string | null; followup_date: string | null; invoice_id: string | null;
  created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ClinicBedStayTable {
  id: Generated<string>; tenant_id: string; admission_id: string; bed_id: string; from_date: string; to_date: string | null;
  daily_rate: number; reason: string | null; created_at: Generated<Date>;
}
export interface ClinicIpdChargeTable {
  id: Generated<string>; tenant_id: string; admission_id: string; charge_date: string; kind: string; item_id: string | null;
  description: string; qty: number; rate: number; amount: number; bed_stay_id: string | null; is_void: Generated<boolean>;
  void_reason: string | null; created_by: string; created_at: Generated<Date>;
}
export interface ClinicIpdDepositTable {
  id: Generated<string>; tenant_id: string; admission_id: string; payment_id: string; amount: number; created_at: Generated<Date>;
}
export interface ClinicIpdRefundTable {
  id: Generated<string>; tenant_id: string; admission_id: string; payment_id: string; amount: number; created_at: Generated<Date>;
}
// ---- Wave 2: funds and donations (028)
export interface FundsSettingsTable {
  id: Generated<string>; tenant_id: string; company_id: string; overspend_mode: Generated<string>; reg_80g_no: string | null;
  reg_80g_from: string | null; reg_80g_to: string | null; trust_pan: string | null; receipt_footer: string | null; updated_at: Generated<Date>;
}
export interface FundTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; kind: Generated<string>; sponsor: string | null;
  sanction_no: string | null; sanction_date: string | null; total_amount: Generated<number>; period_from: string | null; period_to: string | null;
  return_unspent: Generated<boolean>; status: Generated<string>; income_account_id: string | null; notes: string | null;
  created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface BudgetHeadTable {
  id: Generated<string>; tenant_id: string; company_id: string; fy: string; parent_id: string | null; level: string; code: string; name: string;
  account_id: string | null; budget_estimate: Generated<number>; revised_estimate: number | null; is_active: Generated<boolean>;
  created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface BudgetReappropriationTable {
  id: Generated<string>; tenant_id: string; company_id: string; fy: string; from_head_id: string; to_head_id: string; amount: number;
  order_no: string; order_date: string; reason: string; status: Generated<string>; created_by: string; decided_by: string | null;
  decided_at: Date | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface FundSanctionTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; head_id: string; fund_id: string; purpose: string; amount: number;
  status: Generated<string>; admin_order_no: string | null; admin_order_date: string | null; financial_order_no: string | null;
  financial_order_date: string | null; decision_note: string | null; created_by: string; decided_by: string | null; decided_at: Date | null;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface FundLinkTable {
  id: Generated<string>; tenant_id: string; company_id: string; source_type: string; source_id: string; head_id: string; fund_id: string;
  sanction_id: string | null; amount: number; note: string | null; created_by: string; created_at: Generated<Date>;
}
export interface FundReceiptTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; fund_id: string; receipt_date: string; amount: number;
  account_id: string; reference: string | null; narration: string | null; status: Generated<string>; created_by: string; created_at: Generated<Date>;
}
export interface DonorTable {
  id: Generated<string>; tenant_id: string; company_id: string; party_id: string; name: string; phone: string | null; email: string | null;
  pan: string | null; aadhaar: string | null; address: string | null; is_active: Generated<boolean>; created_by: string;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface DonationTable {
  id: Generated<string>; tenant_id: string; company_id: string; receipt_no: string; donor_id: string; donation_date: string; amount: number;
  mode: string; reference: string | null; fund_id: string | null; purpose: string | null; is_corpus: Generated<boolean>; tax_80g: Generated<boolean>;
  deduction_eligible: Generated<boolean>; warning: string | null; account_id: string; fy: string; status: Generated<string>;
  cancel_reason: string | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface ClinicRxLineTable {
  id: Generated<string>; tenant_id: string; visit_id: string; line_no: number; item_id: string | null; medicine: string;
  dose: string | null; frequency: string | null; days: number | null; instructions: string | null;
}

// Restaurant (023)
export interface RestaurantSettingsTable {
  company_id: string; tenant_id: string; service_charge_pct: Generated<number>; service_charge_gst: Generated<number>;
  location_id: string | null; updated_at: Generated<Date>;
}
export interface RestaurantCategoryTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; sort_order: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface RestaurantMenuTable {
  item_id: string; tenant_id: string; company_id: string; category_id: string | null; diet: Generated<string>;
  available: Generated<boolean>; station: Generated<string>; short_name: string | null;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface RestaurantAreaTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; sort_order: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface RestaurantTableTable {
  id: Generated<string>; tenant_id: string; company_id: string; area_id: string; name: string; seats: Generated<number>;
  sort_order: Generated<number>; is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface RestaurantCounterTable { company_id: string; tenant_id: string; kind: string; day: string; next_no: number }
export interface RestaurantOrderTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; number: string; order_date: string;
  kind: string; table_id: string | null; covers: number | null; captain_id: string | null; customer_party_id: string | null;
  customer_name: string | null; customer_phone: string | null; delivery_address: string | null; notes: string | null;
  status: Generated<string>; discount_pct: Generated<number>; discount_amount: Generated<number | null>; discount_reason: string | null;
  service_charge_pct: Generated<number>; bill_printed_at: Date | null; settled_at: Date | null; invoice_id: string | null;
  cancel_reason: string | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface RestaurantKotTable {
  id: Generated<string>; tenant_id: string; company_id: string; order_id: string; kot_date: string; kot_no: number;
  station: string; status: Generated<string>; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface RestaurantOrderLineTable {
  id: Generated<string>; tenant_id: string; order_id: string; item_id: string; name: string; short_name: string | null;
  station: string; qty: number; rate: number; note: string | null; state: Generated<string>;
  kitchen_status: Generated<string>; kot_id: string | null; cancel_reason: string | null; cancelled_by: string | null;
  cancelled_at: Date | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface HotelSettingsTable {
  id: Generated<string>; tenant_id: string; company_id: string; prices_include_tax: Generated<boolean>;
  check_in_time: Generated<string>; check_out_time: Generated<string>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface HotelRoomTypeTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; base_occupancy: Generated<number>;
  max_occupancy: Generated<number>; base_tariff: Generated<number>; extra_person_charge: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface HotelRoomTable {
  id: Generated<string>; tenant_id: string; company_id: string; room_type_id: string; number: string; floor: string | null;
  status: Generated<string>; status_reason: string | null; is_active: Generated<boolean>;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface HotelRatePlanTable {
  id: Generated<string>; tenant_id: string; company_id: string; room_type_id: string; name: string; meal: Generated<string>;
  weekday_tariff: number; weekend_tariff: number; is_active: Generated<boolean>;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface HotelReservationTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; party_id: string; arrival: string; departure: string;
  override_tariff: number | null; source: Generated<string>; source_name: string | null;
  status: Generated<string>; notes: string | null; cancel_reason: string | null; checked_in_at: Date | null;
  checked_out_at: Date | null; invoice_id: string | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface HotelReservationRoomTable {
  id: Generated<string>; tenant_id: string; company_id: string; reservation_id: string; room_type_id: string;
  room_id: string | null; rate_plan_id: string | null; arrival: string; departure: string; adults: Generated<number>; children: Generated<number>;
  live: Generated<boolean>; guest_name: string | null; guest_phone: string | null; guest_address: string | null;
  id_type: string | null; id_number: string | null; nationality: string | null; passport_no: string | null;
  visa_no: string | null; visa_type: string | null; visa_expiry: string | null; arrived_from: string | null;
  going_to: string | null; purpose: string | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface HotelFolioLineTable {
  id: Generated<string>; tenant_id: string; company_id: string; reservation_id: string; reservation_room_id: string | null;
  line_date: string; kind: string; charge_type: string; description: string; item_id: string | null; qty: Generated<number>;
  rate: number; amount: number; gst_rate: Generated<number>; source: Generated<string>; source_ref: string | null;
  voided: Generated<boolean>; void_reason: string | null; created_by: string; created_at: Generated<Date>;
}
export interface HotelFolioPaymentTable {
  id: Generated<string>; tenant_id: string; company_id: string; reservation_id: string; payment_id: string; kind: string;
  amount: number; created_at: Generated<Date>;
}

export interface WhSettingsTable {
  company_id: string; tenant_id: string; fefo: Generated<boolean>; block_expired: Generated<boolean>; expiry_warn_days: Generated<number>;
  updated_at: Generated<Date>;
}
export interface WhBinTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; code: string; name: string | null; zone: string | null;
  kind: Generated<string>; capacity_qty: number | null; is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface WhItemRuleTable {
  item_id: string; tenant_id: string; company_id: string; tracking: Generated<string>; shelf_life_days: number | null; default_bin_id: string | null; updated_at: Generated<Date>;
}
export interface WhPickLinkTable {
  pick_ref_id: string; tenant_id: string; company_id: string; invoice_id: string; created_by: string | null; created_at: Generated<Date>;
}
export interface WhBatchTable {
  id: Generated<string>; tenant_id: string; company_id: string; item_id: string; batch_no: string; mfg_date: string | null;
  expiry_date: string | null; mrp: number | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface WhSerialTable {
  id: Generated<string>; tenant_id: string; company_id: string; item_id: string; serial_no: string; batch_id: string | null;
  location_id: string; bin_id: string | null; status: Generated<string>; warranty_until: string | null; issued_ref: string | null;
  issued_at: Date | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface WhMoveTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; item_id: string; bin_id: string | null;
  batch_id: string | null; qty: number; kind: string; ref_type: string | null; ref_id: string | null; note: string | null;
  created_by: string | null; created_at: Generated<Date>;
}
export interface MemPlanTable {
  id: Generated<string>; tenant_id: string; company_id: string; item_id: string; name: string; billing: string; rate_basis: string;
  duration_unit: string; duration_count: number; price: number; joining_fee: number; freeze_days: number; is_active: Generated<boolean>;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface MemMemberTable {
  id: Generated<string>; tenant_id: string; company_id: string; party_id: string; member_no: string; name: string; phone: string | null;
  emergency_name: string | null; emergency_phone: string | null; photo_file_id: string | null; flat_no: string | null; wing: string | null;
  area_sqft: number | null; occupancy: string | null; notes: string | null; is_active: Generated<boolean>; created_by: string;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface MemSubscriptionTable {
  id: Generated<string>; tenant_id: string; company_id: string; member_id: string; plan_id: string; start_date: string;
  end_date: string | null; price: number; status: Generated<string>; frozen_from: string | null; freeze_days_used: Generated<number>;
  created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface MemBillTable {
  id: Generated<string>; tenant_id: string; company_id: string; member_id: string; subscription_id: string; period: string;
  invoice_id: string; created_at: Generated<Date>;
}
export interface MemVisitTable {
  id: Generated<string>; tenant_id: string; company_id: string; member_id: string; visit_date: string; visited_at: Generated<Date>;
  checked_by: string | null;
}
export interface JobCardTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; party_id: string; number: string; kind: string;
  vehicle_no: string | null; make: string | null; model: string | null; odometer: number | null; serial_no: string | null;
  complaints: string; accessories: string | null; photo_file_ids: Generated<string[]>; promised_date: string | null;
  technician_id: string | null; status: Generated<string>; estimate_sent_at: Date | null; approved_at: Date | null;
  approved_by: string | null; started_at: Date | null; ready_at: Date | null; delivered_at: Date | null; cancel_reason: string | null;
  invoice_id: string | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface JobCardLineTable {
  id: Generated<string>; tenant_id: string; job_card_id: string; line_no: number; kind: string; item_id: string;
  description: string | null; qty: number; rate: number; discount_pct: Generated<number>; issued_at: Date | null; issued_by: string | null;
}

// Manufacturing (032)
export interface MfgSettingsTable { company_id: string; tenant_id: string; overhead_pct: Generated<number>; updated_at: Generated<Date> }
export interface MfgWorkCentreTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; hourly_cost: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface MfgBomTable {
  id: Generated<string>; tenant_id: string; company_id: string; item_id: string; version: number; output_qty: Generated<number>;
  status: Generated<string>; note: string | null; activated_at: Date | null; created_by: string;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface MfgBomLineTable {
  id: Generated<string>; tenant_id: string; bom_id: string; line_no: number; kind: Generated<string>; item_id: string;
  qty: number; scrap_pct: Generated<number>; rate: Generated<number>;
}
export interface MfgBomStepTable {
  id: Generated<string>; tenant_id: string; bom_id: string; step_no: number; operation: string; work_centre_id: string; minutes_per_unit: number;
}
export interface MfgOrderTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; fy: string; item_id: string; bom_id: string;
  location_id: string; qty: number; planned_start: string | null; planned_end: string | null; status: Generated<string>;
  overhead_pct: Generated<number>; sales_order_id: string | null; notes: string | null; good_qty: Generated<number>;
  rejected_qty: Generated<number>; material_absorbed: Generated<number>; conversion_cost: Generated<number>;
  output_value: Generated<number>; loss_value: Generated<number>; released_at: Date | null; closed_at: Date | null;
  close_note: string | null; cancel_reason: string | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface MfgOrderMaterialTable {
  id: Generated<string>; tenant_id: string; order_id: string; item_id: string; planned_qty: number; issued_qty: Generated<number>;
  returned_qty: Generated<number>; issued_value: Generated<number>; returned_value: Generated<number>;
}
export interface MfgOrderStepTable {
  id: Generated<string>; tenant_id: string; order_id: string; step_no: number; operation: string; work_centre_id: string;
  minutes_per_unit: number; hourly_cost: Generated<number>;
}
export interface MfgMovementTable {
  id: Generated<string>; tenant_id: string; order_id: string; kind: string; item_id: string; qty: number;
  cost_rate: Generated<number>; value: Generated<number>; note: string | null; created_by: string; created_at: Generated<Date>;
}
export interface MfgOutputTable {
  id: Generated<string>; tenant_id: string; order_id: string; output_date: string; good_qty: number; rejected_qty: Generated<number>;
  minutes: Generated<number>; material_cost: Generated<number>; labour_cost: Generated<number>; overhead_cost: Generated<number>;
  byproduct_value: Generated<number>; unit_cost: Generated<number>; value: Generated<number>; loss_value: Generated<number>;
  note: string | null; created_by: string; created_at: Generated<Date>;
}
export interface MfgOutputByproductTable { id: Generated<string>; tenant_id: string; output_id: string; item_id: string; qty: number; value: Generated<number> }
export interface MfgInspectionTable {
  id: Generated<string>; tenant_id: string; order_id: string; output_id: string | null; pass_qty: Generated<number>;
  rework_qty: Generated<number>; reject_qty: Generated<number>; note: string | null; inspected_by: string; created_at: Generated<Date>;
}
export interface MfgJobworkChallanTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; fy: string; party_id: string; location_id: string;
  challan_date: string; process: string; expected_return: string | null; vehicle_no: string | null; notes: string | null;
  status: Generated<string>; cancel_reason: string | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface MfgJobworkLineTable {
  id: Generated<string>; tenant_id: string; challan_id: string; line_no: number; item_id: string; return_item_id: string;
  qty_sent: number; qty_received: Generated<number>; qty_scrap: Generated<number>; cost_rate: Generated<number>; value: Generated<number>;
}
export interface MfgJobworkReceiptTable {
  id: Generated<string>; tenant_id: string; challan_id: string; receipt_date: string; note: string | null; created_by: string; created_at: Generated<Date>;
}
export interface MfgJobworkReceiptLineTable {
  id: Generated<string>; tenant_id: string; receipt_id: string; line_id: string; qty_received: Generated<number>;
  qty_scrap: Generated<number>; value: Generated<number>;
}

export interface Database {
  purchase_orders: PurchaseOrderTable;
  purchase_order_lines: PurchaseOrderLineTable;
  goods_receipts: GoodsReceiptTable;
  goods_receipt_lines: GoodsReceiptLineTable;
  stock_counts: StockCountTable;
  stock_count_lines: StockCountLineTable;
  stock_count_scans: StockCountScanTable;
  mfa_challenges: MfaChallengeTable;
  password_resets: PasswordResetTable;
  sso_providers: SsoProviderTable;
  sso_states: SsoStateTable;
  sso_tickets: SsoTicketTable;
  gsp_credentials: GspCredentialTable;
  gsp_submissions: GspSubmissionTable;
  jobs: JobTable;
  api_keys: ApiKeyTable;
  webhook_endpoints: WebhookEndpointTable;
  webhook_deliveries: WebhookDeliveryTable;
  notifications: NotificationTable;
  notification_outbox: NotificationOutboxTable;
  notification_prefs: NotificationPrefTable;
  approval_rules: ApprovalRuleTable;
  approval_rule_levels: ApprovalRuleLevelTable;
  approval_requests: ApprovalRequestTable;
  approval_actions: ApprovalActionTable;
  custom_fields: CustomFieldTable;
  cost_centres: CostCentreTable;
  import_jobs: ImportJobTable;
  intercompany_entries: IntercompanyEntryTable;
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
  payroll_settings: PayrollSettingsTable;
  employees: EmployeeTable;
  salary_components: SalaryComponentTable;
  employee_salaries: EmployeeSalaryTable;
  employee_salary_lines: EmployeeSalaryLineTable;
  leave_types: LeaveTypeTable;
  leave_adjustments: LeaveAdjustmentTable;
  leave_applications: LeaveApplicationTable;
  holidays: HolidayTable;
  attendance_summaries: AttendanceSummaryTable;
  attendance_days: AttendanceDayTable;
  payroll_runs: PayrollRunTable;
  payroll_lines: PayrollLineTable;
  payroll_adjustments: PayrollAdjustmentTable;
  payroll_overrides: PayrollOverrideTable;
  payment_plans: PaymentPlanTable;
  payment_plan_stages: PaymentPlanStageTable;
  bookings: BookingTable;
  booking_stages: BookingStageTable;
  demands: DemandTable;
  pos_sessions: PosSessionTable;
  pos_cash_moves: PosCashMoveTable;
  pos_sales: PosSaleTable;
  pos_payments: PosPaymentTable;
  pos_returns: PosReturnTable;
  pos_held_bills: PosHeldBillTable;
  gst_rates: GstRateTable;
  tds_sections: TdsSectionTable;
  tds_challans: TdsChallanTable;
  tds_deductions: TdsDeductionTable;
  gst_2b_imports: Gst2bImportTable;
  gst_2b_lines: Gst2bLineTable;
  bank_statements: BankStatementTable;
  bank_statement_lines: BankStatementLineTable;
  compliance_docs: ComplianceDocTable;
  sales_orders: SalesOrderTable;
  channel_connections: ChannelConnectionTable;
  channel_listings: ChannelListingTable;
  channel_listing_components: ChannelListingComponentTable;
  channel_inbox: ChannelInboxTable;
  channel_unmapped: ChannelUnmappedTable;
  channel_settlements: ChannelSettlementTable;
  channel_settlement_lines: ChannelSettlementLineTable;
  sales_order_lines: SalesOrderLineTable;
  sales_order_events: SalesOrderEventTable;
  stock_reservations: StockReservationTable;
  pick_lists: PickListTable;
  pick_list_lines: PickListLineTable;
  scan_events: ScanEventTable;
  shipments: ShipmentTable;
  shipment_lines: ShipmentLineTable;
  shipment_status_history: ShipmentStatusHistoryTable;
  sales_returns: SalesReturnTable;
  sales_return_lines: SalesReturnLineTable;
  restaurant_settings: RestaurantSettingsTable;
  restaurant_categories: RestaurantCategoryTable;
  restaurant_menu: RestaurantMenuTable;
  restaurant_areas: RestaurantAreaTable;
  restaurant_tables: RestaurantTableTable;
  restaurant_counters: RestaurantCounterTable;
  restaurant_orders: RestaurantOrderTable;
  restaurant_kots: RestaurantKotTable;
  restaurant_order_lines: RestaurantOrderLineTable;
  mfg_settings: MfgSettingsTable;
  mfg_work_centres: MfgWorkCentreTable;
  mfg_boms: MfgBomTable;
  mfg_bom_lines: MfgBomLineTable;
  mfg_bom_steps: MfgBomStepTable;
  mfg_orders: MfgOrderTable;
  mfg_order_materials: MfgOrderMaterialTable;
  mfg_order_steps: MfgOrderStepTable;
  mfg_movements: MfgMovementTable;
  mfg_outputs: MfgOutputTable;
  mfg_output_byproducts: MfgOutputByproductTable;
  mfg_inspections: MfgInspectionTable;
  mfg_jobwork_challans: MfgJobworkChallanTable;
  mfg_jobwork_lines: MfgJobworkLineTable;
  mfg_jobwork_receipts: MfgJobworkReceiptTable;
  mfg_jobwork_receipt_lines: MfgJobworkReceiptLineTable;
  clinic_patients: ClinicPatientTable;
  clinic_doctors: ClinicDoctorTable;
  clinic_appointments: ClinicAppointmentTable;
  clinic_visits: ClinicVisitTable;
  clinic_rx_lines: ClinicRxLineTable;
  clinic_wards: ClinicWardTable;
  clinic_beds: ClinicBedTable;
  clinic_admissions: ClinicAdmissionTable;
  clinic_bed_stays: ClinicBedStayTable;
  clinic_ipd_charges: ClinicIpdChargeTable;
  clinic_ipd_deposits: ClinicIpdDepositTable;
  clinic_ipd_refunds: ClinicIpdRefundTable;
  mem_plans: MemPlanTable;
  wh_settings: WhSettingsTable;
  wh_bins: WhBinTable;
  wh_item_rules: WhItemRuleTable;
  wh_pick_links: WhPickLinkTable;
  wh_batches: WhBatchTable;
  wh_serials: WhSerialTable;
  wh_moves: WhMoveTable;
  mem_members: MemMemberTable;
  mem_subscriptions: MemSubscriptionTable;
  mem_bills: MemBillTable;
  mem_visits: MemVisitTable;
  job_cards: JobCardTable;
  job_card_lines: JobCardLineTable;
  funds_settings: FundsSettingsTable;
  funds: FundTable;
  budget_heads: BudgetHeadTable;
  budget_reappropriations: BudgetReappropriationTable;
  fund_sanctions: FundSanctionTable;
  fund_links: FundLinkTable;
  fund_receipts: FundReceiptTable;
  donors: DonorTable;
  donations: DonationTable;
  hotel_settings: HotelSettingsTable;
  hotel_room_types: HotelRoomTypeTable;
  hotel_rooms: HotelRoomTable;
  hotel_rate_plans: HotelRatePlanTable;
  hotel_reservations: HotelReservationTable;
  hotel_reservation_rooms: HotelReservationRoomTable;
  hotel_folio_lines: HotelFolioLineTable;
  hotel_folio_payments: HotelFolioPaymentTable;
  legal_matters: LegalMatterTable;
  legal_matter_team: LegalMatterTeamTable;
  legal_hearings: LegalHearingTable;
  legal_tasks: LegalTaskTable;
  legal_rates: LegalRateTable;
  legal_entries: LegalEntryTable;
  legal_bills: LegalBillTable;
  legal_receipts: LegalReceiptTable;
  legal_documents: LegalDocumentTable;
  edu_years: EduYearTable;
  edu_classes: EduClassTable;
  edu_students: EduStudentTable;
  edu_fee_heads: EduFeeHeadTable;
  edu_fee_plans: EduFeePlanTable;
  edu_instalments: EduInstalmentTable;
  edu_concessions: EduConcessionTable;
  edu_demands: EduDemandTable;
  edu_attendance: EduAttendanceTable;
  edu_subjects: EduSubjectTable;
  edu_exam_terms: EduExamTermTable;
  edu_exam_papers: EduExamPaperTable;
  edu_marks: EduMarkTable;
  edu_exam_settings: EduExamSettingsTable;
  edu_co_areas: EduCoAreaTable;
  edu_term_remarks: EduTermRemarkTable;
  edu_co_grades: EduCoGradeTable;
}

export interface PosSessionTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; user_id: string;
  status: Generated<string>; opening_float: Generated<number>; opened_at: Generated<Date>; closed_at: Date | null;
  closed_by: string | null; expected: unknown | null; counted: unknown | null; difference: unknown | null;
  notes: string | null; updated_at: Generated<Date>;
}
export interface PosCashMoveTable {
  id: Generated<string>; tenant_id: string; session_id: string; kind: string; amount: number; reason: string;
  created_by: string; created_at: Generated<Date>;
}
export interface PosSaleTable {
  id: Generated<string>; tenant_id: string; company_id: string; session_id: string; invoice_id: string; party_id: string;
  total: number; tax_total: Generated<number>; discount_total: Generated<number>; bill_discount: Generated<number>;
  item_qty: Generated<number>; tendered_cash: Generated<number>; change_due: Generated<number>; credit_amount: Generated<number>;
  created_by: string; created_at: Generated<Date>;
}
export interface PosPaymentTable {
  id: Generated<string>; tenant_id: string; sale_id: string; session_id: string; mode: string; amount: number;
  payment_id: string | null; reference: string | null;
}
export interface PosReturnTable {
  id: Generated<string>; tenant_id: string; company_id: string; session_id: string; sale_id: string; credit_note_id: string;
  total: number; refund_mode: string; refund_amount: number; reason: string; created_by: string; created_at: Generated<Date>;
}
export interface PosHeldBillTable {
  id: Generated<string>; tenant_id: string; company_id: string; location_id: string; session_id: string;
  label: string | null; payload: unknown; total: Generated<number>; created_by: string; created_at: Generated<Date>;
}

export interface LegalMatterTable {
  id: Generated<string>; tenant_id: string; company_id: string; matter_no: string; title: string; client_id: string;
  opposing_party: string | null; court: string | null; case_type: string | null; case_no: string | null; case_year: number | null;
  filing_date: string | null; stage: string | null; status: Generated<string>; advocate_id: string; fee_type: Generated<string>;
  agreed_fee: Generated<number>; hourly_rate: number | null; notes: string | null; closed_at: Date | null;
  created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface LegalMatterTeamTable { tenant_id: string; matter_id: string; user_id: string }
export interface LegalHearingTable {
  id: Generated<string>; tenant_id: string; company_id: string; matter_id: string; hearing_date: string; court: string | null;
  purpose: string | null; status: Generated<string>; outcome: string | null; next_hearing_id: string | null;
  recorded_by: string | null; recorded_at: Date | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface LegalTaskTable {
  id: Generated<string>; tenant_id: string; company_id: string; matter_id: string; title: string; kind: Generated<string>;
  due_date: string; assignee_id: string | null; status: Generated<string>; done_at: Date | null; notes: string | null;
  created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface LegalRateTable { tenant_id: string; company_id: string; user_id: string; hourly_rate: number; updated_at: Generated<Date> }
export interface LegalEntryTable {
  id: Generated<string>; tenant_id: string; company_id: string; matter_id: string; kind: string; disb_type: string | null;
  user_id: string; entry_date: string; minutes: number | null; rate: number | null; amount: number; billable: Generated<boolean>;
  description: string; hearing_id: string | null; invoice_id: string | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface LegalBillTable {
  id: Generated<string>; tenant_id: string; company_id: string; matter_id: string; invoice_id: string;
  reverse_charge: Generated<boolean>; created_by: string; created_at: Generated<Date>;
}
export interface LegalReceiptTable {
  id: Generated<string>; tenant_id: string; company_id: string; matter_id: string; payment_id: string; invoice_id: string | null;
  kind: string; created_by: string; created_at: Generated<Date>;
}
export interface LegalDocumentTable {
  id: Generated<string>; tenant_id: string; company_id: string; matter_id: string; file_id: string; label: string | null;
  created_by: string; created_at: Generated<Date>;
}

// Education (school and coaching)
export interface EduYearTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; start_date: string; end_date: string;
  is_current: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduClassTable {
  id: Generated<string>; tenant_id: string; company_id: string; year_id: string; kind: Generated<string>; name: string;
  section: string | null; course: string | null; timing: string | null; teacher_user_id: string | null; teacher_name: string | null;
  capacity: number | null; is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduStudentTable {
  id: Generated<string>; tenant_id: string; company_id: string; party_id: string; admission_no: string; name: string;
  class_id: string | null; roll_no: string | null; dob: string | null; sex: string; guardian_name: string;
  guardian_relation: string | null; guardian_phone: string; address: string | null; admission_date: string;
  status: Generated<string>; left_date: string | null; notes: string | null; created_by: string;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduFeeHeadTable {
  id: Generated<string>; tenant_id: string; company_id: string; item_id: string; name: string; gst_rate: Generated<number>;
  is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduFeePlanTable {
  id: Generated<string>; tenant_id: string; company_id: string; class_id: string; name: string; late_kind: Generated<string>;
  late_value: Generated<number>; late_head_id: string | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduInstalmentTable {
  id: Generated<string>; tenant_id: string; plan_id: string; seq: number; label: string; due_date: string; lines: Generated<unknown>;
}
export interface EduConcessionTable {
  id: Generated<string>; tenant_id: string; company_id: string; student_id: string; head_id: string; kind: string; value: number;
  reason: string; is_active: Generated<boolean>; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduDemandTable {
  id: Generated<string>; tenant_id: string; company_id: string; student_id: string; instalment_id: string; invoice_id: string;
  late_fee: Generated<number>; status: Generated<string>; created_by: string; created_at: Generated<Date>;
}
export interface EduAttendanceTable {
  id: Generated<string>; tenant_id: string; company_id: string; student_id: string; class_id: string; att_date: string;
  status: string; marked_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface EduSubjectTable {
  id: Generated<string>; tenant_id: string; company_id: string; class_id: string; name: string; code: string | null;
  seq: Generated<number>; is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduExamTermTable {
  id: Generated<string>; tenant_id: string; company_id: string; year_id: string; name: string; seq: Generated<number>;
  start_date: string | null; end_date: string | null; status: Generated<string>; published_at: Date | null; published_by: string | null;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduExamPaperTable {
  id: Generated<string>; tenant_id: string; company_id: string; term_id: string; class_id: string; subject_id: string;
  max_marks: number; pass_marks: number | null; exam_date: string | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduMarkTable {
  id: Generated<string>; tenant_id: string; company_id: string; paper_id: string; student_id: string; marks: number | null;
  absent: Generated<boolean>; entered_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduExamSettingsTable {
  id: Generated<string>; tenant_id: string; company_id: string; grades: unknown; pass_percent: Generated<number>; co_grades: unknown | null;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface EduCoAreaTable {
  id: Generated<string>; tenant_id: string; company_id: string; class_id: string; name: string; seq: Generated<number>;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduTermRemarkTable {
  id: Generated<string>; tenant_id: string; company_id: string; term_id: string; student_id: string; remark: string; entered_by: string;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface EduCoGradeTable {
  id: Generated<string>; tenant_id: string; company_id: string; term_id: string; student_id: string; area: string; grade: string; entered_by: string;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}

export interface ChannelConnectionTable {
  id: Generated<string>; tenant_id: string; company_id: string; provider: string; name: string; status: Generated<string>;
  status_reason: string | null; party_id: string; location_id: string; order_status: Generated<string>;
  prices_include_tax: Generated<boolean>; stock_buffer: Generated<number>; tcs_rate: Generated<number>; tds_rate: Generated<number>;
  csv_mapping: Generated<Record<string, string>>; settlement_aliases: Generated<Record<string, string>>;
  last_import_at: Date | null; last_error: string | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
  provider_version: string | null; credentials: string | null; push_stock: Generated<boolean>; cursors: Generated<Record<string, string>>;
  last_check_at: Date | null; last_success_at: Date | null; last_error_at: Date | null; webhook_rejects: Generated<number>;
}
export interface ChannelListingTable {
  id: Generated<string>; tenant_id: string; connection_id: string; channel_sku: string; title: string | null;
  external_id: string | null; is_active: Generated<boolean>; created_at: Generated<Date>; updated_at: Generated<Date>;
  pushed_qty: number | null; pushed_at: Date | null; push_error: string | null;
}
export interface ChannelListingComponentTable {
  id: Generated<string>; tenant_id: string; listing_id: string; item_id: string; qty: Generated<number>;
}
export interface ChannelInboxTable {
  id: Generated<string>; tenant_id: string; company_id: string; connection_id: string; event_id: string; topic: Generated<string>;
  source: Generated<string>; payload: unknown; status: Generated<string>; attempts: Generated<number>; error: string | null;
  error_code: string | null; sales_order_id: string | null; order_date: string | null; total: number | null;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ChannelUnmappedTable {
  id: Generated<string>; tenant_id: string; connection_id: string; channel_sku: string; title: string | null;
  seen_count: Generated<number>; first_seen_at: Generated<Date>; last_seen_at: Generated<Date>;
}
export interface ChannelSettlementTable {
  id: Generated<string>; tenant_id: string; company_id: string; connection_id: string; settlement_ref: string; payout_date: string;
  payout: number; lines_total: number; status: Generated<string>; bank_account_id: string | null; journal_entry_id: string | null;
  posted_at: Date | null; created_by: string; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface ChannelSettlementLineTable {
  id: Generated<string>; tenant_id: string; settlement_id: string; line_no: number; order_ref: string | null;
  sales_order_id: string | null; kind: string; label: string | null; amount: number;
}

// HR and payroll (migration 031)
export interface PayrollSettingsTable {
  company_id: string; tenant_id: string; lop_divisor: Generated<string>; pf_enabled: Generated<boolean>; esi_enabled: Generated<boolean>;
  lwf_enabled: Generated<boolean>; pt_enabled: Generated<boolean>; pf_rate: Generated<number>; pf_code: string | null;
  esi_code: string | null; pt_registration: string | null; updated_at: Generated<Date>;
}
export interface EmployeeTable {
  id: Generated<string>; tenant_id: string; company_id: string; code: string; user_id: string | null; name: string;
  father_spouse_name: string | null; dob: string | null; sex: string | null; email: string | null; phone: string | null;
  joining_date: string; leaving_date: string | null; department: string | null; designation: string | null;
  location_id: string | null; reporting_to: string | null; pan: string | null; aadhaar_masked: string | null; aadhaar_last4: string | null;
  uan: string | null; esi_number: string | null; bank_name: string | null; bank_account: string | null; bank_ifsc: string | null;
  salary_mode: Generated<string>; tax_regime: Generated<string>; pf_applicable: Generated<boolean>; pf_higher_wage: Generated<boolean>;
  esi_applicable: Generated<boolean>; esi_covered_until: string | null; pt_state_code: string | null;
  previous_income: Generated<number>; previous_tds: Generated<number>; status: Generated<string>; notes: string | null;
  created_by: string | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface SalaryComponentTable {
  id: Generated<string>; tenant_id: string; company_id: string; code: string; name: string; kind: string; calc: Generated<string>;
  percent: number | null; is_basic: Generated<boolean>; taxable: Generated<boolean>; pf_wage: Generated<boolean>;
  esi_wage: Generated<boolean>; pro_rata: Generated<boolean>; is_active: Generated<boolean>; sort_order: Generated<number>;
  updated_at: Generated<Date>;
}
export interface EmployeeSalaryTable {
  id: Generated<string>; tenant_id: string; employee_id: string; effective_from: string; ctc_annual: Generated<number>;
  note: string | null; created_by: string | null; created_at: Generated<Date>;
}
export interface EmployeeSalaryLineTable { id: Generated<string>; tenant_id: string; salary_id: string; component_id: string; amount: number }
export interface LeaveTypeTable {
  id: Generated<string>; tenant_id: string; company_id: string; code: string; name: string; is_paid: Generated<boolean>;
  yearly_quota: Generated<number>; carry_forward_limit: Generated<number>; is_active: Generated<boolean>; updated_at: Generated<Date>;
}
export interface LeaveAdjustmentTable {
  id: Generated<string>; tenant_id: string; employee_id: string; leave_type_id: string; fy: number; days: number; reason: string;
  created_by: string | null; created_at: Generated<Date>;
}
export interface LeaveApplicationTable {
  id: Generated<string>; tenant_id: string; company_id: string; employee_id: string; leave_type_id: string; from_date: string;
  to_date: string; half_day: Generated<boolean>; days: number; reason: string | null; status: Generated<string>;
  decided_by: string | null; decided_at: Date | null; decision_note: string | null; created_by: string | null;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface HolidayTable {
  id: Generated<string>; tenant_id: string; company_id: string; holiday_date: string; name: string; location_id: string | null;
}
export interface AttendanceSummaryTable {
  id: Generated<string>; tenant_id: string; company_id: string; employee_id: string; month: string; present_days: Generated<number>;
  paid_leave_days: Generated<number>; lop_days: Generated<number>; source: Generated<string>; updated_by: string | null;
  updated_at: Generated<Date>;
}
export interface AttendanceDayTable {
  id: Generated<string>; tenant_id: string; company_id: string; employee_id: string; day: string; status: string;
  updated_by: string | null; updated_at: Generated<Date>;
}
export interface PayrollRunTable {
  id: Generated<string>; tenant_id: string; company_id: string; number: string; month: string; location_id: string | null;
  status: Generated<string>; gross: Generated<number>; deductions: Generated<number>; net: Generated<number>;
  employer_cost: Generated<number>; employee_count: Generated<number>; notes: string | null; created_by: string | null;
  computed_by: string | null; computed_at: Date | null; approved_by: string | null; approved_at: Date | null;
  accrual_entry_id: string | null; paid_by: string | null; paid_at: Date | null; pay_date: string | null;
  payout_entry_id: string | null; created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface PayrollLineTable {
  id: Generated<string>; tenant_id: string; run_id: string; company_id: string; employee_id: string; month: string;
  is_live: Generated<boolean>; working_days: number; paid_days: number; lop_days: Generated<number>;
  earnings: Generated<unknown>; adjustments: Generated<unknown>; other_deductions: Generated<unknown>;
  gross: Generated<number>; taxable_gross: Generated<number>; pf_wage: Generated<number>; esi_wage: Generated<number>;
  pf_employee: Generated<number>; pf_eps: Generated<number>; pf_epf_employer: Generated<number>; pf_edli: Generated<number>;
  pf_admin: Generated<number>; esi_employee: Generated<number>; esi_employer: Generated<number>; esi_covered_until: string | null;
  pt: Generated<number>; pt_state_code: string | null; lwf_employee: Generated<number>; lwf_employer: Generated<number>;
  tds: Generated<number>; tds_working: unknown | null; other_ded_total: Generated<number>; net: Generated<number>;
  overrides: Generated<unknown>; warnings: Generated<unknown>; updated_at: Generated<Date>;
}
export interface PayrollAdjustmentTable {
  id: Generated<string>; tenant_id: string; run_id: string; employee_id: string; kind: string; label: string; amount: number;
  taxable: Generated<boolean>; reason: string | null; created_by: string | null; created_at: Generated<Date>;
}
export interface PayrollOverrideTable {
  id: Generated<string>; tenant_id: string; run_id: string; employee_id: string; field: string; value: number; reason: string;
  created_by: string | null; created_at: Generated<Date>;
}

export interface ApiKeyTable {
  id: Generated<string>; tenant_id: string; company_id: string; name: string; prefix: string; key_hash: string;
  role_id: string; created_by: string; expires_at: Date | null; last_used_at: Date | null; revoked_at: Date | null;
  created_at: Generated<Date>;
}
export interface WebhookEndpointTable {
  id: Generated<string>; tenant_id: string; company_id: string; url: string; description: string | null;
  secret_sealed: string; events: string[]; is_active: Generated<boolean>; created_by: string;
  created_at: Generated<Date>; updated_at: Generated<Date>;
}
export interface WebhookDeliveryTable {
  id: Generated<string>; tenant_id: string; endpoint_id: string; event: string; payload: unknown;
  status: Generated<string>; attempts: Generated<number>; response_status: number | null; error: string | null;
  next_attempt_at: Date | null; delivered_at: Date | null; created_at: Generated<Date>;
}
