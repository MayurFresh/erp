import type { Tx } from '../db/database.ts';

export type AccountType = 'asset' | 'liability' | 'equity' | 'income' | 'expense';

interface SystemAccount { code: string; name: string; type: AccountType; subtype: string; key: string | null }

/** Created for every company on first use. Codes are fixed so reports and imports can rely on them. */
export const SYSTEM_ACCOUNTS: SystemAccount[] = [
  { code: '1000', name: 'Cash in Hand', type: 'asset', subtype: 'cash', key: 'cash' },
  { code: '1010', name: 'Bank Account', type: 'asset', subtype: 'bank', key: 'bank' },
  { code: '1100', name: 'Accounts Receivable', type: 'asset', subtype: 'receivables', key: 'receivables' },
  { code: '1200', name: 'Inventory', type: 'asset', subtype: 'inventory', key: 'inventory' },
  { code: '1210', name: 'Stock in Transit', type: 'asset', subtype: 'inventory', key: 'stock_in_transit' },
  { code: '1300', name: 'Input CGST', type: 'asset', subtype: 'tax', key: 'input_cgst' },
  { code: '1301', name: 'Input SGST', type: 'asset', subtype: 'tax', key: 'input_sgst' },
  { code: '1302', name: 'Input IGST', type: 'asset', subtype: 'tax', key: 'input_igst' },
  { code: '1310', name: 'TDS Receivable', type: 'asset', subtype: 'tax', key: 'tds_receivable' },
  { code: '1320', name: 'GST Cash Ledger', type: 'asset', subtype: 'tax', key: 'gst_cash' },
  { code: '1330', name: 'Advance Income Tax', type: 'asset', subtype: 'tax', key: 'advance_tax' },
  { code: '1400', name: 'Labour Advances', type: 'asset', subtype: 'other', key: 'labour_advances' },
  { code: '1410', name: 'Contractor Advances', type: 'asset', subtype: 'other', key: 'contractor_advances' },
  { code: '1500', name: 'Fixed Assets', type: 'asset', subtype: 'fixed_asset', key: 'fixed_assets' },
  { code: '1510', name: 'Accumulated Depreciation', type: 'asset', subtype: 'fixed_asset', key: 'accumulated_depreciation' },
  { code: '2000', name: 'Accounts Payable', type: 'liability', subtype: 'payables', key: 'payables' },
  { code: '2100', name: 'Output CGST', type: 'liability', subtype: 'tax', key: 'output_cgst' },
  { code: '2101', name: 'Output SGST', type: 'liability', subtype: 'tax', key: 'output_sgst' },
  { code: '2102', name: 'Output IGST', type: 'liability', subtype: 'tax', key: 'output_igst' },
  { code: '2110', name: 'TDS Payable', type: 'liability', subtype: 'tax', key: 'tds_payable' },
  { code: '2120', name: 'BOCW Cess Payable', type: 'liability', subtype: 'tax', key: 'cess_payable' },
  { code: '2130', name: 'GST Payable — Reverse Charge', type: 'liability', subtype: 'tax', key: 'rcm_payable' },
  { code: '2200', name: 'Retention Payable', type: 'liability', subtype: 'other', key: 'retention_payable' },
  { code: '2300', name: 'Customer Advances — Bookings', type: 'liability', subtype: 'other', key: 'booking_advances' },
  { code: '3000', name: "Owner's Capital", type: 'equity', subtype: 'other', key: 'capital' },
  { code: '3100', name: 'Opening Balances', type: 'equity', subtype: 'other', key: 'opening_balances' },
  { code: '4000', name: 'Sales', type: 'income', subtype: 'other', key: 'sales' },
  { code: '4010', name: 'Sales Returns', type: 'income', subtype: 'other', key: 'sales_returns' },
  { code: '4100', name: 'Property Sales', type: 'income', subtype: 'other', key: 'property_sales' },
  { code: '4900', name: 'Other Income', type: 'income', subtype: 'other', key: 'other_income' },
  { code: '4910', name: 'Gain on Sale of Assets', type: 'income', subtype: 'other', key: 'asset_gain' },
  { code: '5000', name: 'Cost of Goods Sold', type: 'expense', subtype: 'other', key: 'cogs' },
  { code: '5100', name: 'Purchases — Non-stock Items', type: 'expense', subtype: 'other', key: 'purchases_nonstock' },
  { code: '5200', name: 'Stock Shortage & Wastage', type: 'expense', subtype: 'other', key: 'stock_loss' },
  { code: '5300', name: 'Material Consumed at Sites', type: 'expense', subtype: 'other', key: 'material_consumed' },
  { code: '5310', name: 'Site Labour Wages', type: 'expense', subtype: 'other', key: 'site_labour' },
  { code: '5320', name: 'Subcontract Work', type: 'expense', subtype: 'other', key: 'subcontract_cost' },
  { code: '5400', name: 'Depreciation', type: 'expense', subtype: 'other', key: 'depreciation' },
  { code: '5900', name: 'Round Off', type: 'expense', subtype: 'other', key: 'round_off' },
  { code: '5910', name: 'Interest and Late Fee on Taxes', type: 'expense', subtype: 'other', key: 'tax_interest' },
  { code: '5920', name: 'Loss on Sale of Assets', type: 'expense', subtype: 'other', key: 'asset_loss' },
  { code: '6000', name: 'Rent', type: 'expense', subtype: 'other', key: null },
  { code: '6010', name: 'Salaries & Wages', type: 'expense', subtype: 'other', key: null },
  { code: '6020', name: 'Electricity', type: 'expense', subtype: 'other', key: null },
  { code: '6030', name: 'Transport & Freight', type: 'expense', subtype: 'other', key: null },
  { code: '6040', name: 'Office Expenses', type: 'expense', subtype: 'other', key: null },
  { code: '6050', name: 'Repairs & Maintenance', type: 'expense', subtype: 'other', key: null },
  { code: '6060', name: 'Professional Fees', type: 'expense', subtype: 'other', key: null },
  { code: '6070', name: 'Bank Charges', type: 'expense', subtype: 'other', key: null },
  { code: '6080', name: 'Travel & Conveyance', type: 'expense', subtype: 'other', key: null },
  { code: '6090', name: 'Miscellaneous Expenses', type: 'expense', subtype: 'other', key: null },
];

export type SystemKey =
  | 'cash' | 'bank' | 'receivables' | 'inventory' | 'stock_in_transit' | 'input_cgst' | 'input_sgst' | 'input_igst'
  | 'payables' | 'output_cgst' | 'output_sgst' | 'output_igst' | 'capital' | 'opening_balances' | 'sales'
  | 'sales_returns' | 'other_income' | 'cogs' | 'purchases_nonstock' | 'stock_loss' | 'round_off'
  | 'labour_advances' | 'material_consumed' | 'site_labour'
  | 'contractor_advances' | 'tds_payable' | 'cess_payable' | 'retention_payable' | 'booking_advances'
  | 'property_sales' | 'subcontract_cost'
  | 'tds_receivable' | 'rcm_payable' | 'tax_interest'
  | 'gst_cash' | 'advance_tax' | 'fixed_assets' | 'accumulated_depreciation' | 'asset_gain' | 'depreciation' | 'asset_loss';

const KEYED = SYSTEM_ACCOUNTS.filter((a) => a.key !== null).length;

/** Returns the company's system account ids by key, creating the chart of accounts if needed. */
export async function systemAccounts(
  tx: Tx, who: { tenantId: string; companyId: string },
): Promise<Record<SystemKey, string>> {
  const load = () => tx.selectFrom('accounts').select(['id', 'system_key'])
    .where('company_id', '=', who.companyId).where('system_key', 'is not', null).execute();
  let rows = await load();
  if (rows.length < KEYED) {
    await tx.insertInto('accounts').values(SYSTEM_ACCOUNTS.map((a) => ({
      tenant_id: who.tenantId, company_id: who.companyId, code: a.code, name: a.name, type: a.type,
      subtype: a.subtype, system_key: a.key, is_system: true,
    }))).onConflict((oc) => oc.doNothing()).execute();
    rows = await load();
    // A company's own account may already use a standard code: give the system account the next free code.
    const missing = SYSTEM_ACCOUNTS.filter((a) => a.key !== null && !rows.some((r) => r.system_key === a.key));
    if (missing.length) {
      const used = new Set((await tx.selectFrom('accounts').select('code').where('company_id', '=', who.companyId).execute()).map((r) => r.code));
      for (const a of missing) {
        let code = Number(a.code);
        while (used.has(String(code))) code += 1;
        used.add(String(code));
        await tx.insertInto('accounts').values({
          tenant_id: who.tenantId, company_id: who.companyId, code: String(code), name: a.name, type: a.type,
          subtype: a.subtype, system_key: a.key, is_system: true,
        }).execute();
      }
      rows = await load();
    }
  }
  return Object.fromEntries(rows.map((r) => [r.system_key, r.id])) as Record<SystemKey, string>;
}
