/// Permission keys from the API contract.
abstract final class Perm {
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
}

/// A set of granted permissions for the active company.
class PermissionSet {
  const PermissionSet(this._keys);

  static const PermissionSet none = PermissionSet(<String>{});

  final Set<String> _keys;

  bool can(String permission) => _keys.contains(permission);

  bool canAny(Iterable<String> permissions) => permissions.any(can);

  @override
  bool operator ==(Object other) =>
      other is PermissionSet &&
      other._keys.length == _keys.length &&
      other._keys.containsAll(_keys);

  @override
  int get hashCode => Object.hashAllUnordered(_keys);
}
