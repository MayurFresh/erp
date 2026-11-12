/// Permission keys from the API contract.
abstract final class Perm {
  static const posUse = 'pos.use';
  static const posManage = 'pos.manage';
  /// Not a company permission: the client adds it for platform super admins (`GET /me` isPlatformAdmin).
  static const platformAdmin = 'platform.admin';
  static const dashboardView = 'dashboard.view';
  static const itemsView = 'items.view';
  static const itemsCreate = 'items.create';
  static const itemsEdit = 'items.edit';
  static const itemsViewCost = 'items.view_cost';
  static const partiesView = 'parties.view';
  static const partiesCreate = 'parties.create';
  static const partiesEdit = 'parties.edit';
  static const locationsView = 'locations.view';
  static const locationsManage = 'locations.manage';
  static const stockView = 'stock.view';
  static const stockAdjust = 'stock.adjust';
  static const invoicesView = 'invoices.view';
  static const invoicesCreate = 'invoices.create';
  static const invoicesCancel = 'invoices.cancel';
  static const usersManage = 'users.manage';
  static const rolesManage = 'roles.manage';
  static const integrationsManage = 'integrations.manage';
  static const auditView = 'audit.view';
  static const companyManage = 'company.manage';
  static const purchasesView = 'purchases.view';
  static const purchasesCreate = 'purchases.create';
  static const purchasesCancel = 'purchases.cancel';
  static const paymentsView = 'payments.view';
  static const paymentsCreate = 'payments.create';
  static const paymentsCancel = 'payments.cancel';
  static const creditNotesView = 'credit_notes.view';
  static const creditNotesCreate = 'credit_notes.create';
  static const creditNotesCancel = 'credit_notes.cancel';
  static const transfersView = 'transfers.view';
  static const transfersCreate = 'transfers.create';
  static const transfersReceive = 'transfers.receive';
  static const expensesView = 'expenses.view';
  static const expensesCreate = 'expenses.create';
  static const expensesCancel = 'expenses.cancel';
  static const accountsView = 'accounts.view';
  static const accountsManage = 'accounts.manage';
  static const accountsJournal = 'accounts.journal';
  static const reportsView = 'reports.view';
  static const approvalsView = 'approvals.view';
  static const approvalsManage = 'approvals.manage';
  static const importsRun = 'imports.run';
  static const companiesCreate = 'companies.create';
  static const securityManage = 'security.manage';
  static const purchaseOrdersView = 'purchase_orders.view';
  static const purchaseOrdersManage = 'purchase_orders.manage';
  static const grnManage = 'grn.manage';
  static const purchasesOverride = 'purchases.override';
  static const stockCountsManage = 'stock_counts.manage';
  static const stockCountsApprove = 'stock_counts.approve';
  static const salesOrdersView = 'sales_orders.view';
  static const salesOrdersManage = 'sales_orders.manage';
  static const fulfilmentManage = 'fulfilment.manage';
  static const returnsManage = 'returns.manage';
  static const channelsView = 'channels.view';
  static const channelsManage = 'channels.manage';
  static const settlementsManage = 'settlements.manage';
  static const restaurantOrders = 'restaurant.orders';
  static const restaurantKitchen = 'restaurant.kitchen';
  static const restaurantSettle = 'restaurant.settle';
  static const restaurantManage = 'restaurant.manage';
  static const clinicView = 'clinic.view';
  static const clinicFrontDesk = 'clinic.front_desk';
  static const clinicConsult = 'clinic.consult';
  static const clinicManage = 'clinic.manage';
  static const clinicIpd = 'clinic.ipd';
  static const clinicIpdManage = 'clinic.ipd_manage';
  static const membershipsView = 'memberships.view';
  static const membershipsManage = 'memberships.manage';
  static const membershipsCheckin = 'memberships.checkin';
  static const jobCardsView = 'job_cards.view';
  static const jobCardsCreate = 'job_cards.create';
  static const jobCardsWork = 'job_cards.work';
  static const jobCardsManage = 'job_cards.manage';
  static const fundsView = 'funds.view';
  static const fundsEntry = 'funds.entry';
  static const fundsManage = 'funds.manage';
  static const donationsView = 'donations.view';
  static const donationsCreate = 'donations.create';
  static const donationsManage = 'donations.manage';
  static const hotelView = 'hotel.view';
  static const hotelFrontOffice = 'hotel.front_office';
  static const hotelHousekeeping = 'hotel.housekeeping';
  static const hotelManage = 'hotel.manage';
  static const legalView = 'legal.view';
  static const legalWork = 'legal.work';
  static const legalManage = 'legal.manage';
  static const educationView = 'education.view';
  static const educationAdmissions = 'education.admissions';
  static const educationFees = 'education.fees';
  static const educationAttendance = 'education.attendance';
  static const educationManage = 'education.manage';
  static const educationExams = 'education.exams';
  static const educationExamsManage = 'education.exams_manage';
  static const payrollView = 'payroll.view';
  static const payrollEmployees = 'payroll.employees';
  static const payrollLeaveApprove = 'payroll.leave_approve';
  static const payrollRun = 'payroll.run';
  static const payrollApprove = 'payroll.approve';
  static const payrollSelf = 'payroll.self';
  static const manufacturingView = 'manufacturing.view';
  static const manufacturingBom = 'manufacturing.bom';
  static const manufacturingOrders = 'manufacturing.orders';
  static const manufacturingIssue = 'manufacturing.issue';
  static const manufacturingOutput = 'manufacturing.output';
  static const manufacturingInspect = 'manufacturing.inspect';
  static const manufacturingManage = 'manufacturing.manage';
  static const warehouseView = 'warehouse.view';
  static const warehousePick = 'warehouse.pick';
  static const warehouseManage = 'warehouse.manage';
}

/// A set of granted permissions for the active company.
class PermissionSet {
  const PermissionSet(this._keys);

  static const PermissionSet none = PermissionSet(<String>{});

  final Set<String> _keys;

  bool can(String permission) => _keys.contains(permission);

  bool canAny(Iterable<String> permissions) => permissions.any(can);

  /// A copy that also holds [permission].
  PermissionSet plus(String permission) => PermissionSet({..._keys, permission});

  @override
  bool operator ==(Object other) =>
      other is PermissionSet &&
      other._keys.length == _keys.length &&
      other._keys.containsAll(_keys);

  @override
  int get hashCode => Object.hashAllUnordered(_keys);
}
