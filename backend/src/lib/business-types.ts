import { PERMISSION_KEYS } from '../auth/permissions.ts';

/*
 * The business catalogue. To add a module: add it to MODULES, add its permissions to auth/permissions.ts,
 * then list its key in the `modules` of the types that use it. To add a business type: add one `type(...)` call.
 * Everything here is data; nothing else in the backend branches on a business type.
 */

export interface ModuleDef { key: string; label: string; description: string; indiaOnly?: boolean }
export const MODULES: readonly ModuleDef[] = [
  { key: 'sales', label: 'Sales', description: 'Invoices, credit notes, receipts and sales orders' },
  { key: 'pos', label: 'Counter billing', description: 'Register sessions, fast counter sales, split payments, returns and receipts' },
  { key: 'fulfilment', label: 'Fulfilment', description: 'Pick lists, shipments and sales returns' },
  { key: 'purchases', label: 'Purchases', description: 'Purchase orders, bills, payments and expenses' },
  { key: 'inventory', label: 'Stock', description: 'Stock, transfers, reorder and stock counts' },
  { key: 'construction', label: 'Construction', description: 'Projects, BOQ, site reports, labour and subcontracts' },
  { key: 'real_estate', label: 'Real estate sales', description: 'Units, bookings, demands and RERA' },
  { key: 'clinic', label: 'Patient care', description: 'Patients, doctors, appointments, consultations, prescriptions, wards and in-patient stays' },
  { key: 'education', label: 'Students and fees', description: 'Admissions, classes or batches, fee plans, fee collection and attendance' },
  { key: 'funds', label: 'Funds and budgets', description: 'Funds and schemes, budget heads, sanctions, spending control and utilisation certificates' },
  { key: 'donations', label: 'Donations', description: 'Donors, donation receipts with 80G, donor statements and Form 10BD data' },
  { key: 'memberships', label: 'Memberships', description: 'Plans, members, renewals, recurring bills, dues and check-in' },
  { key: 'job_cards', label: 'Job cards', description: 'Repair intake, estimates, parts and labour, status and job bills' },
  { key: 'legal', label: 'Legal practice', description: 'Matters, court diary, deadlines, time and expenses, and fee bills' },
  { key: 'hotel', label: 'Hotel front office', description: 'Rooms, rates, reservations, check-in and out, folios and housekeeping' },
  { key: 'restaurant', label: 'Restaurant', description: 'Menu, tables, orders, kitchen tickets and bills' },
  { key: 'manufacturing', label: 'Manufacturing', description: 'Bills of materials, production orders, material planning, job work and quality checks' },
  { key: 'warehouse', label: 'Warehouse', description: 'Bins, batches and expiry, serial numbers, putaway and picking by bin, first-expiry-first-out' },
  { key: 'channels', label: 'Online channels', description: 'Marketplace and web store orders, SKU mapping and settlement reconciliation' },
  { key: 'gst', label: 'GST', description: 'GST returns, 2B reconciliation and rates', indiaOnly: true },
  { key: 'tds', label: 'TDS', description: 'TDS deductions, challans and returns', indiaOnly: true },
  { key: 'income_tax', label: 'Income tax', description: 'Tax calculators, advance tax and ITR data', indiaOnly: true },
  { key: 'einvoice', label: 'E-invoice', description: 'IRN and e-way bill', indiaOnly: true },
  { key: 'payroll', label: 'HR and payroll', description: 'Employees, salary structures, leave, monthly payroll, PF, ESI, professional tax, TDS and payslips' },
  { key: 'fixed_assets', label: 'Fixed assets', description: 'Asset register and depreciation' },
  { key: 'accounting', label: 'Accounting', description: 'Chart of accounts, journals and financial statements' },
  { key: 'reports', label: 'Reports', description: 'Registers, ageing and valuation' },
  { key: 'controls', label: 'Controls', description: 'Approvals, custom fields, cost centres and imports' },
  { key: 'multi_company', label: 'Multiple companies', description: 'Several companies, inter-company and consolidation' },
];
export const MODULE_KEYS: readonly string[] = MODULES.map((m) => m.key);
export const INDIA_ONLY_MODULES: readonly string[] = MODULES.filter((m) => m.indiaOnly).map((m) => m.key);

/** Default plan limits. The owner may change this table; there is no billing. */
export interface PlanDef { id: string; name: string; maxUsers: number | null; allowedModules: readonly string[] | null; simplifiedMenu: boolean; features: string[] }
export const PLANS: readonly PlanDef[] = [
  { id: 'solo', name: 'Solo', maxUsers: 1, simplifiedMenu: true, features: ['1 user', '1 company', 'Simplified menu'],
    allowedModules: ['sales', 'purchases', 'inventory', 'gst', 'tds', 'income_tax', 'einvoice', 'fixed_assets', 'accounting', 'reports'] },
  { id: 'team', name: 'Team', maxUsers: 10, allowedModules: null, simplifiedMenu: false, features: ['Up to 10 users', 'Roles and locations'] },
  { id: 'business', name: 'Business', maxUsers: 50, allowedModules: null, simplifiedMenu: false, features: ['Up to 50 users', 'All modules'] },
  { id: 'enterprise', name: 'Enterprise', maxUsers: null, allowedModules: null, simplifiedMenu: false,
    features: ['Unlimited users', 'Single sign-on', 'Approvals', 'Multiple companies'] },
];
export const PLAN_IDS: readonly string[] = PLANS.map((p) => p.id);
export const planOf = (id: string): PlanDef => PLANS.find((p) => p.id === id) ?? PLANS[2]!;

/** Words a company can rename. Values are the singular defaults. */
export const TERM_DEFAULTS: Record<string, string> = {
  customer: 'Customer', vendor: 'Vendor', item: 'Item', invoice: 'Invoice', bill: 'Bill', project: 'Project',
  sales_order: 'Sales order', receipt: 'Receipt', location: 'Location', stock: 'Stock',
};
export const TERM_KEYS: readonly string[] = Object.keys(TERM_DEFAULTS);

export const GROUPS: readonly { id: string; name: string }[] = [
  { id: 'retail', name: 'Retail and trade' }, { id: 'online', name: 'Online selling' }, { id: 'food', name: 'Food' },
  { id: 'health', name: 'Healthcare' }, { id: 'professional', name: 'Professional services' },
  { id: 'construction', name: 'Construction and property' }, { id: 'manufacturing', name: 'Manufacturing' },
  { id: 'education', name: 'Education' }, { id: 'hospitality', name: 'Hospitality and travel' },
  { id: 'logistics', name: 'Logistics' }, { id: 'agriculture', name: 'Agriculture' }, { id: 'services', name: 'Local services' },
  { id: 'nonprofit', name: 'Non-profit' }, { id: 'public', name: 'Public sector' }, { id: 'corporate', name: 'Companies' },
  { id: 'general', name: 'General' },
];

export interface RoleTemplate { name: string; description: string; permissions: string[] }
export interface QuickAction { label: string; route: string; permission: string }
export interface BusinessType {
  id: string; name: string; group: string; description: string; icon: string;
  modules: string[]; roles: RoleTemplate[]; terms: Record<string, string>; quickActions: QuickAction[];
}

// Permission bundles used to build role templates.
const pk = (...k: string[]) => k;
const BASE = pk('dashboard.view', 'items.view', 'parties.view', 'locations.view');
const SELL = pk('invoices.view', 'invoices.create', 'parties.create', 'parties.edit', 'payments.view', 'payments.create',
  'credit_notes.view', 'credit_notes.create', 'sales_orders.view', 'sales_orders.manage');
const COUNTER = pk('invoices.view', 'invoices.create', 'parties.create', 'payments.view', 'payments.create', 'stock.view', 'pos.use');
const BUY = pk('purchases.view', 'purchases.create', 'purchase_orders.view', 'purchase_orders.manage', 'grn.manage');
const STOCK = pk('stock.view', 'stock.adjust', 'items.create', 'items.edit', 'transfers.view', 'transfers.create',
  'transfers.receive', 'stock_counts.manage', 'grn.manage', 'purchase_orders.view');
const BOOKS = pk('accounts.view', 'accounts.manage', 'accounts.journal', 'expenses.view', 'expenses.create', 'expenses.cancel',
  'payments.view', 'payments.create', 'payments.cancel', 'reports.view', 'bank.reconcile', 'items.view_cost', 'invoices.view',
  'purchases.view', 'purchases.create', 'credit_notes.view', 'audit.view', 'data.export');
const TAX = pk('gst.view', 'gst.manage', 'tds.view', 'tds.manage', 'einvoice.manage', 'tax.view', 'tax.manage', 'compliance.view', 'compliance.manage');
const SITE = pk('projects.view', 'indents.view', 'indents.create', 'consumption.view', 'consumption.create', 'dpr.view', 'dpr.create',
  'labour.view', 'attendance.mark', 'stock.view', 'transfers.view', 'transfers.receive');
const REST_ORDERS = pk('restaurant.orders');
const REST_COUNTER = pk('restaurant.orders', 'restaurant.settle');
const REST_KITCHEN = pk('restaurant.kitchen');
const REST_MANAGE = pk('restaurant.orders', 'restaurant.kitchen', 'restaurant.settle', 'restaurant.manage');
const MFG_SUPERVISOR = pk('manufacturing.view', 'manufacturing.orders', 'manufacturing.issue', 'manufacturing.output', 'stock.view');
const MFG_STORE = pk('manufacturing.view', 'manufacturing.issue');
const MFG_QUALITY = pk('manufacturing.view', 'manufacturing.inspect');
const MFG_MANAGE = pk('manufacturing.view', 'manufacturing.bom', 'manufacturing.orders', 'manufacturing.issue', 'manufacturing.output',
  'manufacturing.inspect', 'manufacturing.manage', 'purchase_orders.view', 'purchase_orders.manage', 'items.view_cost');
const LEGAL_WORK = pk('legal.view', 'legal.work');
const LEGAL_MANAGE = pk('legal.view', 'legal.work', 'legal.manage');
const EDU_OFFICE = pk('education.view', 'education.admissions', 'education.fees');
const EDU_FEES = pk('education.view', 'education.fees');
const EDU_TEACHER = pk('education.view', 'education.attendance', 'education.exams');
const EDU_MANAGE = pk('education.view', 'education.admissions', 'education.fees', 'education.attendance', 'education.manage', 'education.exams', 'education.exams_manage');
const HOTEL_FO = pk('hotel.view', 'hotel.front_office');
const HOTEL_HK = pk('hotel.view', 'hotel.housekeeping');
const CLINIC_FD = pk('clinic.view', 'clinic.front_desk');
const CLINIC_DOC = pk('clinic.view', 'clinic.consult');
const CLINIC_IPD = pk('clinic.ipd');
const CLINIC_IPD_DESK = pk('clinic.ipd', 'clinic.ipd_manage');
const MEM_DESK = pk('memberships.view', 'memberships.manage', 'memberships.checkin');
const MEM_DOOR = pk('memberships.view', 'memberships.checkin');
const JC_ADVISOR = pk('job_cards.view', 'job_cards.create');
const JC_TECH = pk('job_cards.work');
const FUNDS_ENTRY = pk('funds.view', 'funds.entry');
const DON_ENTRY = pk('donations.view', 'donations.create');
const DON_MANAGE = pk('donations.view', 'donations.create', 'donations.manage');
const WH_WORK = pk('warehouse.view', 'warehouse.pick');
const READ = PERMISSION_KEYS.filter((k) => k.endsWith('.view'));
const FULL = [...PERMISSION_KEYS];
const NO_SECURITY = FULL.filter((k) => !['roles.manage', 'security.manage', 'companies.create'].includes(k));

const role = (name: string, description: string, ...bundles: string[][]): RoleTemplate =>
  ({ name, description, permissions: [...new Set(bundles.flat())] });

const PAY_HR = pk('payroll.view', 'payroll.employees', 'payroll.leave_approve', 'payroll.run', 'payroll.self');
const rHr = role('HR Manager', 'Employees, leave, salary structures and payroll runs; the owner approves', BASE, PAY_HR, pk('reports.view'));
const rAuditor = role('Auditor', 'Read-only with audit log', READ, pk('items.view_cost', 'audit.view'));
const rAccountsClerk = role('Accounts Clerk', 'Enters spending against budget heads and funds', BASE, BOOKS, FUNDS_ENTRY);

const QA = {
  invoice: { label: 'New invoice', route: '/invoices/new', permission: 'invoices.create' },
  receipt: { label: 'Record receipt', route: '/receipts/new', permission: 'payments.create' },
  expense: { label: 'Add expense', route: '/expenses/new', permission: 'expenses.create' },
  customer: { label: 'Add customer', route: '/parties/new', permission: 'parties.create' },
  item: { label: 'Add item', route: '/items/new', permission: 'items.create' },
  bill: { label: 'Enter purchase bill', route: '/purchases/new', permission: 'purchases.create' },
  payment: { label: 'Pay a vendor', route: '/payments/new', permission: 'payments.create' },
  order: { label: 'New sales order', route: '/sales-orders/new', permission: 'sales_orders.manage' },
  stock: { label: 'Check stock', route: '/stock', permission: 'stock.view' },
  projects: { label: 'Projects', route: '/projects', permission: 'projects.view' },
  indent: { label: 'Material indent', route: '/indents', permission: 'indents.view' },
  units: { label: 'Units', route: '/units', permission: 'units.view' },
  clinic: { label: 'Front desk', route: '/clinic', permission: 'clinic.view' },
  hotel: { label: 'Front office', route: '/hotel', permission: 'hotel.view' },
  legal: { label: 'Court diary', route: '/legal', permission: 'legal.view' },
  education: { label: 'Students and fees', route: '/education', permission: 'education.view' },
  memberships: { label: 'Memberships', route: '/memberships', permission: 'memberships.view' },
  checkin: { label: 'Check-in', route: '/memberships/check-in', permission: 'memberships.checkin' },
  jobcard: { label: 'New job card', route: '/job-cards/new', permission: 'job_cards.create' },
  jobcards: { label: 'Job cards', route: '/job-cards', permission: 'job_cards.view' },
};
const qa = (label: string, base: keyof typeof QA, relabel?: string): QuickAction => ({ ...QA[base], label: relabel || label || QA[base].label });

// Module sets.
const SHOP = ['sales', 'purchases', 'inventory', 'accounting', 'reports', 'gst', 'tds', 'income_tax', 'einvoice', 'payroll'];
const POS = [...SHOP, 'pos'];
const TRADE = [...SHOP, 'fulfilment', 'fixed_assets', 'controls'];
const SERVICE = ['sales', 'purchases', 'accounting', 'reports', 'gst', 'tds', 'income_tax', 'einvoice', 'fixed_assets', 'payroll'];
const BUILD = [...TRADE, 'construction'];
const NGO = ['sales', 'purchases', 'accounting', 'reports', 'tds', 'income_tax', 'fixed_assets', 'payroll'];
const BIG = [...TRADE, 'multi_company', 'channels'];
const ONLINE = [...TRADE, 'channels'];
const CH_WORK = pk('channels.view', 'channels.manage');
const CH_BOOKS = pk('channels.view', 'settlements.manage');

const type = (id: string, name: string, group: string, description: string, icon: string, modules: string[],
  roles: RoleTemplate[], terms: Record<string, string> = {}, quickActions: QuickAction[] = []): BusinessType =>
  ({
    id, name, group, description, icon, modules, roles, quickActions,
    // Where a sale is called a bill, purchases need their own word.
    terms: terms.invoice === 'Bill' && !terms.bill ? { ...terms, bill: 'Purchase bill' } : terms,
  });

// Roles reused by several types.
const rOwner = role('Owner', 'Everything, including roles', FULL);
const rShopOwner = role('Shop Owner', 'Runs the shop; everything except security settings', NO_SECURITY);
const rCounter = role('Counter Staff', 'Bills and receipts at the counter; no cost prices', BASE, COUNTER);
const rStoreStaff = role('Store', 'Stock in and out, counts and transfers', BASE, STOCK, WH_WORK);
const rAccounts = (n = 'Accounts') => role(n, 'Books, payments, GST and reports', BASE, SELL, BOOKS, TAX);
const rPurchase = role('Purchase Manager', 'Purchase orders, bills and vendors', BASE, BUY, pk('payments.view', 'stock.view'));

export const BUSINESS_TYPES: readonly BusinessType[] = [
  // Retail and trade
  type('kirana', 'Kirana or grocery', 'retail', 'Daily-need shop with fast billing and many small items', 'store', POS,
    [rShopOwner, rCounter, rStoreStaff, rAccounts('Munim (Accounts)')], {},
    [qa('', 'invoice'), qa('', 'receipt'), qa('', 'stock'), qa('', 'bill')]),
  type('retail', 'General retail shop', 'retail', 'Any shop that sells goods to walk-in customers', 'shopping_bag', [...POS, 'warehouse'],
    [rShopOwner, rCounter, rStoreStaff, rAccounts()], { invoice: 'Bill' }, [qa('', 'invoice'), qa('', 'item'), qa('', 'stock'), qa('', 'expense')]),
  type('garments', 'Garments and fashion', 'retail', 'Clothing, footwear and accessories with sizes and seasons', 'checkroom', [...POS, 'channels'],
    [rShopOwner, role('Sales Staff', 'Bills and customers on the shop floor', BASE, COUNTER), rStoreStaff, rAccounts()], { invoice: 'Bill' },
    [qa('', 'invoice'), qa('', 'item'), qa('', 'stock'), qa('', 'bill')]),
  type('electronics', 'Electronics and mobile', 'retail', 'Phones, appliances and accessories; serial numbers and warranty', 'devices', [...TRADE, 'pos', 'job_cards', 'channels', 'warehouse'],
    [rShopOwner, rCounter, rStoreStaff, rAccounts(), role('Service Advisor', 'Receives repairs, writes estimates and bills', BASE, COUNTER, JC_ADVISOR), role('Technician', 'Works on assigned repairs', BASE, pk('stock.view'), JC_TECH)],
    { invoice: 'Bill' }, [qa('', 'invoice'), qa('', 'item'), qa('', 'stock'), qa('', 'jobcard')]),
  type('hardware', 'Hardware and building material', 'retail', 'Tools, paint, sanitary, electrical and building material', 'hardware', [...TRADE, 'pos', 'warehouse'],
    [rShopOwner, rCounter, rStoreStaff, rAccounts(), rPurchase], {}, [qa('', 'invoice'), qa('', 'order'), qa('', 'stock'), qa('', 'bill')]),
  type('medical_store', 'Medical store or pharmacy', 'retail', 'Medicines with batches and expiry, bills to patients', 'medication', [...POS, 'warehouse'],
    [role('Pharmacy Owner', 'Runs the pharmacy', NO_SECURITY), role('Pharmacist', 'Bills, stock and purchases', BASE, COUNTER, STOCK, BUY, WH_WORK), rCounter, rAccounts()],
    { customer: 'Patient', item: 'Medicine', invoice: 'Bill' }, [qa('', 'invoice'), qa('', 'item', 'Add medicine'), qa('', 'stock'), qa('', 'bill')]),
  type('jewellery', 'Jewellery', 'retail', 'Gold, silver and diamond jewellery with high-value bills', 'diamond', [...TRADE, 'pos'],
    [rShopOwner, role('Sales Staff', 'Bills and customers', BASE, COUNTER), role('Karigar Store', 'Stock of ornaments and raw metal', BASE, STOCK), rAccounts()], { invoice: 'Bill' },
    [qa('', 'invoice'), qa('', 'item'), qa('', 'stock'), qa('', 'bill')]),
  type('wholesale', 'Wholesaler or distributor', 'retail', 'Bulk selling to retailers with credit, orders and dispatch', 'warehouse', [...TRADE, 'channels', 'warehouse'],
    [rOwner, role('Sales Manager', 'Orders, customers and receipts', BASE, SELL), role('Warehouse', 'Pick, pack, dispatch and stock', BASE, STOCK, WH_WORK, pk('warehouse.manage', 'fulfilment.manage', 'returns.manage', 'sales_orders.view', 'stock.view')), rPurchase, rAccounts()],
    { customer: 'Retailer' }, [qa('', 'order'), qa('', 'invoice'), qa('', 'receipt'), qa('', 'stock')]),
  type('auto_parts', 'Auto parts', 'retail', 'Spare parts for vehicles with many part numbers', 'build', [...TRADE, 'pos', 'job_cards', 'warehouse'],
    [rShopOwner, rCounter, rStoreStaff, rAccounts(), rPurchase, role('Service Advisor', 'Receives fitting jobs, writes estimates and bills', BASE, COUNTER, JC_ADVISOR), role('Technician', 'Works on assigned jobs', BASE, pk('stock.view'), JC_TECH)],
    { item: 'Part' }, [qa('', 'invoice'), qa('', 'item', 'Add part'), qa('', 'stock'), qa('', 'jobcard')]),

  // Online selling
  type('d2c', 'D2C brand', 'online', 'Own brand sold through its website and apps', 'language', ONLINE,
    [rOwner, role('Operations', 'Orders, dispatch and returns', BASE, SELL, CH_WORK, pk('fulfilment.manage', 'returns.manage', 'stock.view', 'stock.adjust')), role('Warehouse', 'Pick, pack and stock', BASE, STOCK, pk('fulfilment.manage', 'returns.manage', 'sales_orders.view')), { ...rAccounts(), permissions: [...rAccounts().permissions, ...CH_BOOKS] }],
    { customer: 'Customer', invoice: 'Invoice' }, [qa('', 'order'), qa('', 'stock'), qa('', 'invoice'), qa('', 'bill')]),
  type('marketplace', 'Marketplace seller', 'online', 'Sells on Amazon, Flipkart, Meesho and similar', 'storefront', ONLINE,
    [rOwner, role('Catalogue and Orders', 'Items, orders and returns', BASE, SELL, CH_WORK, pk('items.create', 'items.edit', 'fulfilment.manage', 'returns.manage')), role('Packing', 'Pick, pack and dispatch', BASE, pk('fulfilment.manage', 'sales_orders.view', 'stock.view', 'returns.manage')), { ...rAccounts(), permissions: [...rAccounts().permissions, ...CH_BOOKS] }],
    {}, [qa('', 'order'), qa('', 'item'), qa('', 'stock'), qa('', 'bill')]),

  // Food
  type('restaurant', 'Restaurant', 'food', 'Dine-in and takeaway with a kitchen and a menu', 'restaurant', [...SHOP, 'restaurant'],
    [role('Manager', 'Runs the restaurant', NO_SECURITY), role('Cashier', 'Bills and receipts', BASE, COUNTER, REST_COUNTER), role('Captain', 'Takes orders and raises bills', BASE, pk('invoices.view', 'invoices.create', 'sales_orders.view', 'sales_orders.manage', 'parties.create', 'stock.view'), REST_ORDERS),
      role('Kitchen', 'Kitchen display, stock and material requests', BASE, pk('stock.view', 'indents.view', 'indents.create'), REST_KITCHEN), role('Store', 'Raw material stock and purchases', BASE, STOCK)],
    { item: 'Menu item', customer: 'Guest', invoice: 'Bill', bill: 'Purchase bill' }, [qa('', 'invoice'), qa('', 'item', 'Add menu item'), qa('', 'stock'), qa('', 'expense')]),
  type('cafe', 'Cafe or bakery', 'food', 'Counter-service cafe, bakery or sweet shop', 'local_cafe', [...POS, 'restaurant'],
    [rShopOwner, role('Cashier', 'Bills and receipts', BASE, COUNTER, REST_COUNTER), role('Baker', 'Kitchen display, stock and material requests', BASE, pk('stock.view', 'indents.view', 'indents.create'), REST_KITCHEN), rStoreStaff],
    { item: 'Menu item', invoice: 'Bill' }, [qa('', 'invoice'), qa('', 'item', 'Add menu item'), qa('', 'stock'), qa('', 'expense')]),
  type('cloud_kitchen', 'Cloud kitchen', 'food', 'Delivery-only kitchen working with food apps', 'ramen_dining', [...SHOP, 'restaurant'],
    [rShopOwner, role('Kitchen Manager', 'Menu, kitchen, stock and purchases', BASE, STOCK, BUY, REST_MANAGE), role('Order Desk', 'Bills and receipts', BASE, COUNTER, REST_COUNTER), rAccounts()],
    { item: 'Menu item', invoice: 'Bill' }, [qa('', 'invoice'), qa('', 'item', 'Add menu item'), qa('', 'stock'), qa('', 'bill')]),
  type('caterer', 'Caterer', 'food', 'Events and bulk food orders with advances', 'celebration', [...SERVICE, 'restaurant'],
    [rOwner, role('Event Manager', 'Orders, customers and receipts', BASE, SELL, REST_COUNTER), role('Kitchen', 'Kitchen display and menu', BASE, REST_KITCHEN, pk('restaurant.manage', 'stock.view')), role('Store', 'Raw material stock', BASE, STOCK), rAccounts()],
    { customer: 'Client', item: 'Dish or service', sales_order: 'Event order', project: 'Event' }, [qa('', 'order', 'New event order'), qa('', 'receipt', 'Record advance'), qa('', 'invoice'), qa('', 'expense')]),

  // Healthcare
  type('clinic', 'Clinic', 'health', 'Doctor or small clinic with consultations and a dispensary', 'medical_services', [...SERVICE, 'clinic'],
    [role('Administrator', 'Runs the clinic', NO_SECURITY), role('Doctor', 'Sees patients, writes notes and prescriptions', BASE, CLINIC_DOC, CLINIC_IPD, pk('invoices.view', 'invoices.create')),
      role('Nurse', 'Vitals and queue; no prescriptions', BASE, CLINIC_FD, CLINIC_IPD, pk('clinic.consult')), role('Front Desk', 'Registers patients, books appointments, bills and receipts', BASE, COUNTER, CLINIC_FD, CLINIC_IPD_DESK),
      role('Billing', 'Bills, receipts and credit notes', BASE, SELL, CLINIC_FD, CLINIC_IPD_DESK, pk('reports.view')), role('Pharmacist', 'Medicine stock and bills', BASE, COUNTER, STOCK), rAccounts()],
    { customer: 'Patient', item: 'Service or medicine', invoice: 'Bill' }, [qa('', 'clinic'), qa('', 'invoice'), qa('', 'customer', 'Add patient'), qa('', 'receipt'), qa('', 'expense')]),
  type('hospital', 'Hospital', 'health', 'Multi-department hospital with wards, pharmacy and billing', 'local_hospital', [...TRADE, 'clinic'],
    [role('Administrator', 'Runs the hospital', NO_SECURITY), role('Doctor', 'Sees patients, writes notes and prescriptions', BASE, CLINIC_DOC, CLINIC_IPD, pk('invoices.view')), role('Nurse', 'Vitals, queue, ward stock and material requests', BASE, CLINIC_DOC, CLINIC_IPD, pk('stock.view', 'indents.view', 'indents.create')),
      role('Front Desk', 'Registers patients, books appointments, bills and receipts', BASE, COUNTER, CLINIC_FD, CLINIC_IPD_DESK), role('Pharmacist', 'Medicine stock, bills and purchases', BASE, COUNTER, STOCK, BUY),
      role('Lab Technician', 'Lab consumables and stock', BASE, pk('stock.view', 'stock.adjust', 'indents.view', 'indents.create')), role('Billing', 'Bills, receipts and credit notes', BASE, SELL, CLINIC_FD, CLINIC_IPD_DESK, pk('payments.view', 'reports.view'))],
    { customer: 'Patient', vendor: 'Supplier', item: 'Service or medicine', invoice: 'Bill', location: 'Department' }, [qa('', 'clinic'), qa('', 'invoice'), qa('', 'customer', 'Add patient'), qa('', 'receipt'), qa('', 'stock')]),
  type('diagnostic_lab', 'Diagnostic lab', 'health', 'Pathology and imaging centre with test bills', 'biotech', [...SERVICE, 'clinic'],
    [role('Lab Manager', 'Runs the lab', NO_SECURITY), role('Lab Technician', 'Consumables and stock', BASE, pk('stock.view', 'stock.adjust', 'indents.create', 'indents.view'), CLINIC_FD), role('Front Desk', 'Registers patients, books sample collection, bills and receipts', BASE, COUNTER, CLINIC_FD), rAccounts()],
    { customer: 'Patient', item: 'Test', invoice: 'Bill' }, [qa('', 'clinic'), qa('', 'invoice'), qa('', 'customer', 'Add patient'), qa('', 'item', 'Add test'), qa('', 'expense')]),

  // Professional
  type('advocate', 'Advocates and law firm', 'professional', 'Cases, clients, fees and court expenses', 'gavel', [...SERVICE, 'legal'],
    [role('Managing Partner', 'Everything in the firm', NO_SECURITY),
      role('Senior Advocate', 'All matters, rates, fee bills and receipts', BASE, SELL, LEGAL_MANAGE, pk('expenses.view', 'expenses.create', 'projects.view')),
      role('Associate', 'Own matters: hearings, tasks and time; no fee bills', BASE, LEGAL_WORK, pk('invoices.view', 'expenses.view', 'expenses.create')),
      role('Clerk', 'Court diary, hearings and court fees', BASE, LEGAL_WORK, pk('expenses.create', 'expenses.view', 'payments.view', 'parties.create')),
      role('Accounts', 'Fee bills, receipts, books and GST', BASE, SELL, BOOKS, TAX, LEGAL_MANAGE)],
    { customer: 'Client', item: 'Service', project: 'Matter', invoice: 'Fee bill', receipt: 'Fee receipt' }, [qa('', 'legal'), qa('', 'invoice', 'New fee bill'), qa('', 'customer', 'Add client'), qa('', 'receipt', 'Record fee received'), qa('', 'expense', 'Add court expense')]),
  type('ca_firm', 'CA and accountants', 'professional', 'Chartered accountants and tax practitioners with many clients', 'calculate', SERVICE,
    [role('Partner', 'Everything in the firm', NO_SECURITY), role('Article Assistant', 'Enters data for clients', BASE, pk('invoices.view', 'purchases.view', 'purchases.create', 'expenses.create', 'expenses.view', 'accounts.view')), role('Manager', 'Filing and review', BASE, BOOKS, TAX), role('Accounts', 'Fee bills and receipts', BASE, SELL)],
    { customer: 'Client', item: 'Service', invoice: 'Fee bill' }, [qa('', 'invoice', 'New fee bill'), qa('', 'customer', 'Add client'), qa('', 'receipt'), qa('', 'expense')]),
  type('consultant', 'Consultants', 'professional', 'Advisory and consulting firms billing by project or hour', 'support_agent', SERVICE,
    [rOwner, role('Project Lead', 'Projects, clients and bills', BASE, SELL, pk('projects.view', 'expenses.create', 'expenses.view')), role('Consultant', 'Own projects and expenses', BASE, pk('projects.view', 'expenses.create', 'expenses.view')), rAccounts()],
    { customer: 'Client', item: 'Service', project: 'Engagement' }, [qa('', 'invoice'), qa('', 'customer', 'Add client'), qa('', 'receipt'), qa('', 'expense')]),
  type('architect', 'Architects and engineers', 'professional', 'Design practices billing by stage of a project', 'architecture', SERVICE,
    [rOwner, role('Principal Architect', 'Projects, clients and bills', BASE, SELL, pk('projects.view', 'projects.manage')), role('Design Team', 'Own projects and expenses', BASE, pk('projects.view', 'expenses.create', 'expenses.view')), rAccounts()],
    { customer: 'Client', item: 'Service', project: 'Project' }, [qa('', 'invoice', 'New stage bill'), qa('', 'customer', 'Add client'), qa('', 'receipt'), qa('', 'expense')]),
  type('it_services', 'IT and software services', 'professional', 'Software, agency and IT outsourcing', 'code', SERVICE,
    [rOwner, role('Delivery Manager', 'Projects, clients and bills', BASE, SELL, pk('projects.view', 'projects.manage')), role('Team Member', 'Own projects and expenses', BASE, pk('projects.view', 'expenses.create', 'expenses.view')), role('Finance', 'Books, GST and reports', BASE, SELL, BOOKS, TAX), role('HR and Admin', 'Users and expenses', BASE, pk('users.manage', 'expenses.view', 'expenses.create'))],
    { customer: 'Client', item: 'Service', project: 'Project' }, [qa('', 'invoice'), qa('', 'customer', 'Add client'), qa('', 'receipt'), qa('', 'expense')]),
  type('freelancer', 'Freelancer', 'professional', 'One person billing a few clients', 'person', ['sales', 'purchases', 'accounting', 'reports', 'gst', 'income_tax'],
    [rOwner, role('Assistant', 'Invoices and receipts', BASE, SELL)], { customer: 'Client', item: 'Service' },
    [qa('', 'invoice'), qa('', 'customer', 'Add client'), qa('', 'receipt'), qa('', 'expense')]),

  // Construction and property
  type('contractor', 'Contractor or builder', 'construction', 'Civil contractor with sites, labour and subcontractors', 'engineering', BUILD,
    [role('Owner', 'Everything, including roles', FULL), role('Project Manager', 'Projects, BOQ and approvals', BASE, SITE, pk('boq.manage', 'projects.manage', 'indents.approve', 'dpr.approve', 'labour.manage', 'wages.view', 'wages.manage', 'subcontracts.view', 'subcontracts.manage', 'reports.view')),
      role('Site Engineer', 'Site reports, indents and labour', BASE, SITE, pk('subcontracts.view')), role('Store Keeper', 'Site stock and material issue', BASE, STOCK, pk('consumption.create', 'consumption.view', 'indents.view')), rAccounts(), rPurchase],
    { customer: 'Client' }, [qa('', 'projects'), qa('', 'indent'), qa('', 'invoice', 'New RA invoice'), qa('', 'stock')]),
  type('real_estate', 'Real estate developer', 'construction', 'Plots, flats and villas sold with payment plans', 'apartment', [...BUILD, 'real_estate'],
    [rOwner, role('Sales Head', 'Units, bookings and demands', BASE, pk('units.view', 'units.manage', 'bookings.view', 'bookings.manage', 'invoices.view', 'payments.view', 'payments.create')), role('Project Manager', 'Projects and site work', BASE, SITE, pk('boq.manage', 'projects.manage', 'indents.approve', 'dpr.approve')), rAccounts(), role('CRM Executive', 'Bookings and customer follow-up', BASE, pk('units.view', 'bookings.view', 'bookings.manage'))],
    { customer: 'Buyer', item: 'Item' }, [qa('', 'units'), qa('', 'projects'), qa('', 'receipt'), qa('', 'invoice')]),
  type('interior', 'Interior designer', 'construction', 'Design and fit-out jobs billed in stages', 'chair', [...SERVICE, 'inventory', 'construction'],
    [rOwner, role('Design Lead', 'Projects, clients and bills', BASE, SELL, SITE, pk('projects.manage', 'boq.manage')), role('Site Supervisor', 'Site reports and material', BASE, SITE), rAccounts()],
    { customer: 'Client', project: 'Project' }, [qa('', 'projects'), qa('', 'invoice'), qa('', 'receipt'), qa('', 'expense')]),

  // Manufacturing
  type('manufacturer', 'Small manufacturer', 'manufacturing', 'Makes goods from raw material and sells to dealers', 'precision_manufacturing', [...TRADE, 'manufacturing', 'warehouse'],
    [rOwner, role('Production Manager', 'Bills of materials, production orders, material and quality', BASE, STOCK, MFG_MANAGE, pk('consumption.create', 'consumption.view', 'indents.view', 'indents.approve')), role('Production Supervisor', 'Runs production orders, issues material, records output', BASE, MFG_SUPERVISOR), role('Store', 'Raw material and finished stock', BASE, STOCK, MFG_STORE), role('Quality', 'Inspects production output', BASE, MFG_QUALITY), rPurchase, role('Sales Executive', 'Orders and invoices', BASE, SELL), rAccounts()],
    { customer: 'Dealer' }, [qa('', 'order'), qa('', 'invoice'), qa('', 'stock'), qa('', 'bill')]),
  type('job_work', 'Job work', 'manufacturing', 'Processes material sent by customers for a charge', 'handyman', [...TRADE, 'manufacturing'],
    [rOwner, role('Production Manager', 'Production orders, job work and quality', BASE, STOCK, MFG_MANAGE), role('Production Supervisor', 'Runs production orders, issues material, records output', BASE, MFG_SUPERVISOR), role('Quality', 'Inspects production output', BASE, MFG_QUALITY), role('Supervisor', 'Stock in and out', BASE, STOCK, MFG_STORE), role('Dispatch', 'Challans and dispatch', BASE, pk('fulfilment.manage', 'sales_orders.view', 'stock.view', 'invoices.view', 'invoices.create')), rAccounts()],
    { customer: 'Principal', item: 'Item or process' }, [qa('', 'invoice'), qa('', 'stock'), qa('', 'receipt'), qa('', 'expense')]),
  type('textile', 'Textile', 'manufacturing', 'Fabric traders, mills and processors', 'texture', [...TRADE, 'manufacturing'],
    [rOwner, role('Sales Manager', 'Orders, customers and receipts', BASE, SELL), role('Production Manager', 'Production orders, job work and quality', BASE, STOCK, MFG_MANAGE), role('Production Supervisor', 'Runs production orders, issues material, records output', BASE, MFG_SUPERVISOR), role('Quality', 'Inspects production output', BASE, MFG_QUALITY), role('Godown', 'Stock in and out', BASE, STOCK, MFG_STORE), rPurchase, rAccounts()],
    { customer: 'Party', item: 'Fabric or item' }, [qa('', 'order'), qa('', 'invoice'), qa('', 'stock'), qa('', 'bill')]),

  // Education
  type('school', 'School', 'education', 'School with fees, staff and a store', 'school', [...NGO, 'education'],
    [role('Principal', 'Everything in the school', NO_SECURITY), role('Accountant', 'Fees, payments and books', BASE, SELL, BOOKS, EDU_FEES), role('Office Staff', 'Admissions, fee bills and receipts', BASE, pk('invoices.view', 'invoices.create', 'payments.view', 'payments.create', 'parties.create'), EDU_OFFICE), role('Teacher', 'Marks attendance for their classes', BASE, EDU_TEACHER), role('Store In-charge', 'Stock and purchases', BASE, STOCK, BUY)],
    { customer: 'Parent', item: 'Fee or item', invoice: 'Fee bill', receipt: 'Fee receipt' }, [qa('', 'receipt', 'Collect fee'), qa('', 'invoice', 'New fee bill'), qa('', 'expense'), qa('', 'customer', 'Add parent')]),
  type('coaching', 'Coaching institute', 'education', 'Coaching classes with batches and monthly fees', 'menu_book', [...SERVICE, 'education'],
    [rOwner, role('Centre Manager', 'Batches, fees, students and expenses', BASE, SELL, pk('expenses.create', 'expenses.view', 'reports.view'), EDU_MANAGE), role('Front Desk', 'Admissions, fee receipts and enquiries', BASE, pk('invoices.view', 'invoices.create', 'payments.view', 'payments.create', 'parties.create'), EDU_OFFICE), role('Teacher', 'Marks attendance for their batches', BASE, EDU_TEACHER), role('Accountant', 'Fees, payments and books', BASE, SELL, BOOKS, TAX, EDU_FEES)],
    { customer: 'Student', item: 'Course or fee', invoice: 'Fee bill', receipt: 'Fee receipt' }, [qa('', 'receipt', 'Collect fee'), qa('', 'customer', 'Add student'), qa('', 'invoice', 'New fee bill'), qa('', 'expense')]),

  // Hospitality and travel
  type('hotel', 'Hotel or guest house', 'hospitality', 'Rooms, reservations, front office, restaurant and housekeeping', 'hotel', [...SHOP, 'restaurant', 'hotel'],
    [role('General Manager', 'Runs the property', NO_SECURITY), role('Front Office', 'Reservations, check-in and out, folios, bills and receipts', BASE, COUNTER, REST_COUNTER, HOTEL_FO), role('Kitchen', 'Kitchen display, stock and material requests', BASE, pk('stock.view', 'indents.view', 'indents.create'), REST_KITCHEN), role('Housekeeping', 'Room status, linen and supplies', BASE, pk('stock.view', 'indents.view', 'indents.create'), HOTEL_HK), role('Store', 'Stock and purchases', BASE, STOCK, BUY), role('Accounts', 'Bills, payments, GST and reports', BASE, SELL, BOOKS, TAX, pk('hotel.view'))],
    { customer: 'Guest', item: 'Room or item', invoice: 'Bill' }, [qa('', 'hotel'), qa('', 'invoice'), qa('', 'customer', 'Add guest'), qa('', 'receipt'), qa('', 'expense')]),
  type('travel', 'Travel agency', 'hospitality', 'Tickets, tours and visas with service fees', 'flight', SERVICE,
    [rOwner, role('Travel Consultant', 'Clients, bookings and bills', BASE, SELL), role('Ticketing', 'Bills and receipts', BASE, COUNTER), rAccounts()],
    { customer: 'Traveller', item: 'Service', project: 'Trip' }, [qa('', 'invoice'), qa('', 'customer', 'Add traveller'), qa('', 'receipt'), qa('', 'expense')]),

  // Logistics
  type('transporter', 'Transporter', 'logistics', 'Trucks and goods transport with freight bills', 'local_shipping', SERVICE,
    [rOwner, role('Dispatcher', 'Freight bills and receipts', BASE, COUNTER), role('Fleet Manager', 'Expenses and vendors', BASE, pk('expenses.create', 'expenses.view', 'purchases.view', 'purchases.create', 'assets.view')), rAccounts()],
    { customer: 'Consignor', item: 'Service', invoice: 'Freight bill' }, [qa('', 'invoice', 'New freight bill'), qa('', 'receipt'), qa('', 'expense', 'Add trip expense'), qa('', 'payment')]),

  // Agriculture
  type('farm', 'Farm or FPO', 'agriculture', 'Farms, farmer groups and agri produce', 'agriculture', ['sales', 'purchases', 'inventory', 'accounting', 'reports', 'gst', 'tds', 'income_tax', 'fixed_assets', 'payroll'],
    [rOwner, role('Farm Manager', 'Stock, purchases and expenses', BASE, STOCK, BUY, pk('expenses.create', 'expenses.view')), role('Store', 'Produce and input stock', BASE, STOCK), rAccounts()],
    { customer: 'Buyer', vendor: 'Farmer or supplier', item: 'Crop or input' }, [qa('', 'invoice'), qa('', 'bill'), qa('', 'stock'), qa('', 'expense')]),

  // Local services
  type('salon', 'Salon or spa', 'services', 'Services and retail products at the counter', 'content_cut', [...POS, 'memberships'],
    [rShopOwner, role('Receptionist', 'Bills, receipts and memberships', BASE, COUNTER, MEM_DESK), role('Stylist', 'Own bills', BASE, pk('invoices.view', 'invoices.create', 'stock.view')), rStoreStaff],
    { item: 'Service or product', invoice: 'Bill' }, [qa('', 'invoice'), qa('', 'item', 'Add service'), qa('', 'stock'), qa('', 'expense')]),
  type('gym', 'Gym or fitness', 'services', 'Memberships and renewals', 'fitness_center', [...SERVICE, 'memberships'],
    [rOwner, role('Front Desk', 'Enrols members, renews, bills and takes receipts', BASE, COUNTER, MEM_DESK), role('Trainer', 'Marks member visits', BASE, MEM_DOOR), rAccounts()], { customer: 'Member', item: 'Plan or product', invoice: 'Bill' },
    [qa('', 'memberships'), qa('', 'checkin'), qa('', 'receipt'), qa('', 'expense')]),
  type('garage', 'Garage or repair workshop', 'services', 'Vehicle or appliance repair with parts and labour', 'car_repair', [...SHOP, 'job_cards'],
    [rShopOwner, role('Service Advisor', 'Job cards, estimates, bills and receipts', BASE, COUNTER, JC_ADVISOR), role('Technician', 'Works on assigned jobs and issues parts', BASE, pk('stock.view'), JC_TECH), rStoreStaff, rAccounts()],
    { customer: 'Customer', item: 'Part or service', invoice: 'Job bill' }, [qa('', 'jobcard'), qa('', 'jobcards'), qa('', 'invoice', 'New job bill'), qa('', 'stock')]),

  // Non-profit
  type('ngo', 'NGO or trust', 'nonprofit', 'Donations, grants and projects with fund accounting', 'volunteer_activism', [...NGO, 'funds', 'donations'],
    [role('Managing Trustee', 'Everything in the trust', NO_SECURITY), role('Treasurer', 'Books, payments, funds and donations', BASE, BOOKS, pk('invoices.view'), FUNDS_ENTRY, DON_MANAGE), role('Programme Manager', 'Projects and expenses', BASE, pk('projects.view', 'projects.manage', 'expenses.create', 'expenses.view'), FUNDS_ENTRY), role('Accounts', 'Receipts, payments and vouchers', BASE, SELL, pk('expenses.view', 'expenses.create', 'accounts.view'), FUNDS_ENTRY, DON_ENTRY), rAuditor],
    { customer: 'Donor', item: 'Item', invoice: 'Receipt', project: 'Programme', vendor: 'Vendor' }, [qa('', 'receipt', 'Record donation'), qa('', 'expense'), qa('', 'payment'), qa('', 'customer', 'Add donor')]),
  type('housing_society', 'Housing society', 'nonprofit', 'Maintenance bills and expenses of a residential society', 'home_work', [...NGO, 'funds', 'memberships'],
    [role('Society Secretary', 'Everything in the society', NO_SECURITY), role('Treasurer', 'Books, payments, maintenance bills and reports', BASE, BOOKS, SELL, FUNDS_ENTRY, MEM_DESK), role('Committee Member', 'Reads accounts and reports', BASE, READ.filter((k) => k !== 'audit.view'))],
    { customer: 'Member', item: 'Charge', invoice: 'Maintenance bill', receipt: 'Receipt' }, [qa('', 'memberships', 'Maintenance bills'), qa('', 'receipt', 'Record payment'), qa('', 'expense'), qa('', 'customer', 'Add member')]),
  type('religious', 'Religious institution', 'nonprofit', 'Temple, church, mosque or gurdwara trust with donations', 'temple_hindu', [...NGO, 'funds', 'donations'],
    [role('Trustee', 'Everything in the trust', NO_SECURITY), role('Treasurer', 'Books, funds and donations', BASE, BOOKS, FUNDS_ENTRY, DON_MANAGE), role('Counter Volunteer', 'Donation receipts', BASE, pk('invoices.view', 'invoices.create', 'payments.view', 'payments.create', 'parties.create'), DON_ENTRY), rAuditor],
    { customer: 'Devotee', item: 'Seva or item', invoice: 'Receipt' }, [qa('', 'receipt', 'Record donation'), qa('', 'expense'), qa('', 'payment'), qa('', 'customer', 'Add devotee')]),

  // Public sector
  type('government', 'Government department', 'public', 'Office of a state or central department', 'account_balance', [...NGO, 'inventory', 'controls', 'funds'],
    [role('Head of Office', 'Everything in the office', NO_SECURITY), role('Drawing and Disbursing Officer', 'Payments, bills, sanctions and approvals', BASE, BOOKS, pk('approvals.view', 'purchase_orders.view', 'purchase_orders.manage'), FUNDS_ENTRY),
      role('Accounts Officer', 'Books, vouchers and reports', BASE, BOOKS, FUNDS_ENTRY), rAccountsClerk, role('Store Officer', 'Stock, receipts and issue', BASE, STOCK, BUY), role('Internal Auditor', 'Read-only with costs and audit', READ, pk('items.view_cost', 'audit.view'))],
    { customer: 'Beneficiary', vendor: 'Supplier', item: 'Item', invoice: 'Bill', location: 'Office' }, [qa('', 'bill'), qa('', 'payment'), qa('', 'expense'), qa('', 'stock')]),
  type('psu', 'PSU', 'public', 'Public sector undertaking with plants and many users', 'domain', [...BIG, 'funds'],
    [role('Director', 'Everything except security', NO_SECURITY), role('Finance Head', 'Books, tax and reports', BASE, SELL, BOOKS, TAX, pk('approvals.view'), FUNDS_ENTRY), role('Department Head', 'Own department approvals', BASE, pk('indents.view', 'indents.create', 'indents.approve', 'approvals.view', 'reports.view', 'purchase_orders.view')),
      role('Purchase Manager', 'Purchase orders and bills', BASE, BUY), role('Store Officer', 'Stock and receipts', BASE, STOCK), role('Internal Auditor', 'Read-only with costs and audit', READ, pk('items.view_cost', 'audit.view'))],
    { vendor: 'Supplier', location: 'Plant or office' }, [qa('', 'bill'), qa('', 'payment'), qa('', 'order'), qa('', 'stock')]),
  type('local_body', 'Local body', 'public', 'Municipality, panchayat or development authority', 'location_city', [...NGO, 'inventory', 'funds'],
    [role('Chief Officer', 'Everything in the office', NO_SECURITY), role('Accounts Officer', 'Books, vouchers and reports', BASE, BOOKS, SELL, FUNDS_ENTRY), rAccountsClerk, role('Revenue Clerk', 'Demand and receipts', BASE, pk('invoices.view', 'invoices.create', 'payments.view', 'payments.create', 'parties.create')), role('Store Officer', 'Stock and receipts', BASE, STOCK, BUY), role('Internal Auditor', 'Read-only with costs and audit', READ, pk('items.view_cost', 'audit.view'))],
    { customer: 'Taxpayer', item: 'Charge', invoice: 'Demand', receipt: 'Receipt', location: 'Ward or office' }, [qa('', 'invoice', 'New demand'), qa('', 'receipt'), qa('', 'expense'), qa('', 'payment')]),

  // Companies
  type('proprietorship', 'Proprietorship', 'corporate', 'Business owned by one person', 'person_pin', ONLINE,
    [rOwner, role('Manager', 'Runs daily work', NO_SECURITY), rHr, role('Staff', 'Invoices, receipts and stock view', BASE, COUNTER), rAccounts()], {}, [qa('', 'invoice'), qa('', 'receipt'), qa('', 'expense'), qa('', 'stock')]),
  type('partnership', 'Partnership firm', 'corporate', 'Firm run by two or more partners', 'handshake', ONLINE,
    [role('Managing Partner', 'Everything', FULL), role('Partner', 'Everything except roles and security', NO_SECURITY), role('Manager', 'Runs daily work', BASE, SELL, BUY, STOCK), rHr, rAccounts()], {}, [qa('', 'invoice'), qa('', 'receipt'), qa('', 'expense'), qa('', 'bill')]),
  type('llp', 'LLP', 'corporate', 'Limited liability partnership', 'groups', ONLINE,
    [role('Designated Partner', 'Everything', FULL), role('Partner', 'Everything except roles and security', NO_SECURITY), role('Finance Manager', 'Books, tax and reports', BASE, SELL, BOOKS, TAX), role('Manager', 'Runs daily work', BASE, SELL, BUY, STOCK), rHr], {}, [qa('', 'invoice'), qa('', 'receipt'), qa('', 'expense'), qa('', 'bill')]),
  type('pvt_ltd', 'Private limited company', 'corporate', 'Private company with directors and departments', 'corporate_fare', [...BIG, 'manufacturing'],
    [role('Director', 'Everything', FULL), role('Production Manager', 'Bills of materials, production orders and quality', BASE, STOCK, MFG_MANAGE), role('Finance Manager', 'Books, tax and reports', BASE, SELL, BOOKS, TAX, pk('approvals.view')), role('Department Head', 'Own department approvals', BASE, pk('indents.view', 'indents.create', 'indents.approve', 'approvals.view', 'reports.view')),
      role('HR Manager', 'Users, employees, leave and payroll runs', BASE, PAY_HR, pk('users.manage', 'expenses.view', 'expenses.create', 'reports.view')), role('Purchase Manager', 'Purchase orders and bills', BASE, BUY, pk('payments.view')), role('Sales Manager', 'Orders, customers and receipts', BASE, SELL)],
    {}, [qa('', 'invoice'), qa('', 'bill'), qa('', 'payment'), qa('', 'receipt')]),
  type('public_ltd', 'Public limited company', 'corporate', 'Listed or public company with audit and approvals', 'apartment', [...BIG, 'manufacturing'],
    [role('Managing Director', 'Everything', FULL), role('Production Manager', 'Bills of materials, production orders and quality', BASE, STOCK, MFG_MANAGE), role('Chief Financial Officer', 'Books, tax, reports and approvals', BASE, SELL, BOOKS, TAX, pk('approvals.view', 'approvals.manage', 'books.lock')), role('Company Secretary', 'Compliance and audit', BASE, pk('compliance.view', 'compliance.manage', 'audit.view', 'reports.view')),
      role('Department Head', 'Own department approvals', BASE, pk('indents.view', 'indents.create', 'indents.approve', 'approvals.view', 'reports.view')), role('Internal Auditor', 'Read-only with costs and audit', READ, pk('items.view_cost', 'audit.view')), rHr],
    {}, [qa('', 'invoice'), qa('', 'bill'), qa('', 'payment'), qa('', 'receipt')]),
  type('enterprise_group', 'Enterprise group', 'corporate', 'Group of companies with shared books and controls', 'hub', [...BIG, 'manufacturing'],
    [role('Group Chairman', 'Everything', FULL), role('Production Manager', 'Bills of materials, production orders and quality', BASE, STOCK, MFG_MANAGE), role('Group CFO', 'Books, tax, consolidation and approvals', BASE, SELL, BOOKS, TAX, pk('approvals.view', 'approvals.manage', 'books.lock', 'companies.create')), role('Company Head', 'Runs one company', NO_SECURITY), role('Group Auditor', 'Read-only with costs and audit', READ, pk('items.view_cost', 'audit.view')), rHr],
    {}, [qa('', 'invoice'), qa('', 'bill'), qa('', 'payment'), qa('', 'receipt')]),

  // General
  type('general', 'General business', 'general', 'Any other business; every module is on', 'business_center', [...MODULE_KEYS],
    [rOwner, role('Manager', 'Runs daily work', NO_SECURITY), role('Staff', 'Invoices, receipts and stock view', BASE, COUNTER), rAccounts()], {}, [qa('', 'invoice'), qa('', 'receipt'), qa('', 'expense'), qa('', 'stock')]),
];

export const BUSINESS_TYPE_IDS: readonly string[] = BUSINESS_TYPES.map((t) => t.id);
export const typeOf = (id: string): BusinessType => BUSINESS_TYPES.find((t) => t.id === id) ?? BUSINESS_TYPES.at(-1)!;

/** Modules a business type starts with in a country (tax modules are India only). */
export function defaultModules(typeId: string, country: string): string[] {
  const mods = typeOf(typeId).modules;
  return country === 'IN' ? [...mods] : mods.filter((m) => !INDIA_ONLY_MODULES.includes(m));
}

/** Clamps a module list to what the plan allows and, outside India, drops the Indian tax modules. */
export function clampModules(modules: string[], plan: string, country: string): string[] {
  const allowed = planOf(plan).allowedModules;
  return [...new Set(modules)].filter((m) => (!allowed || allowed.includes(m)) && (country === 'IN' || !INDIA_ONLY_MODULES.includes(m)));
}

/** Throws at start-up when the catalogue refers to a permission or module that does not exist. */
function validate() {
  for (const t of BUSINESS_TYPES) {
    for (const m of t.modules) if (!MODULE_KEYS.includes(m)) throw new Error(`${t.id}: unknown module ${m}`);
    for (const r of t.roles) for (const p of r.permissions) if (!PERMISSION_KEYS.includes(p)) throw new Error(`${t.id}/${r.name}: unknown permission ${p}`);
    for (const k of Object.keys(t.terms)) if (!TERM_KEYS.includes(k)) throw new Error(`${t.id}: unknown term ${k}`);
    if (!GROUPS.some((g) => g.id === t.group)) throw new Error(`${t.id}: unknown group ${t.group}`);
    for (const q of t.quickActions) if (!q.label.trim()) throw new Error(`${t.id}: quick action ${q.route} has no label`);
  }
}
validate();

/** Countries offered at signup, with the currency and number-grouping locale they start with. */
export const COUNTRIES: readonly { code: string; name: string; currency: string; locale: string }[] = [
  { code: 'IN', name: 'India', currency: 'INR', locale: 'en_IN' }, { code: 'US', name: 'United States', currency: 'USD', locale: 'en_US' },
  { code: 'GB', name: 'United Kingdom', currency: 'GBP', locale: 'en_GB' }, { code: 'AE', name: 'United Arab Emirates', currency: 'AED', locale: 'en_AE' },
  { code: 'SG', name: 'Singapore', currency: 'SGD', locale: 'en_SG' }, { code: 'AU', name: 'Australia', currency: 'AUD', locale: 'en_AU' },
  { code: 'CA', name: 'Canada', currency: 'CAD', locale: 'en_CA' }, { code: 'DE', name: 'Germany', currency: 'EUR', locale: 'de_DE' },
  { code: 'FR', name: 'France', currency: 'EUR', locale: 'fr_FR' }, { code: 'NP', name: 'Nepal', currency: 'NPR', locale: 'en_IN' },
  { code: 'BD', name: 'Bangladesh', currency: 'BDT', locale: 'en_IN' }, { code: 'LK', name: 'Sri Lanka', currency: 'LKR', locale: 'en_IN' },
  { code: 'SA', name: 'Saudi Arabia', currency: 'SAR', locale: 'en_US' }, { code: 'ZA', name: 'South Africa', currency: 'ZAR', locale: 'en_ZA' },
  { code: 'KE', name: 'Kenya', currency: 'KES', locale: 'en_KE' }, { code: 'NG', name: 'Nigeria', currency: 'NGN', locale: 'en_NG' },
  { code: 'XX', name: 'Other country', currency: 'USD', locale: 'en_US' },
];
export const COUNTRY_CODES: readonly string[] = COUNTRIES.map((c) => c.code);
export const countryOf = (code: string) => COUNTRIES.find((c) => c.code === code) ?? COUNTRIES[0]!;
