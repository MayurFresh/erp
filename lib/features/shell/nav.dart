import 'package:flutter/material.dart';

import '../../core/permissions.dart';

class NavEntry {
  const NavEntry({
    required this.path,
    required this.label,
    required this.icon,
    required this.selectedIcon,
    required this.permission,
    this.createPermission,
  });

  final String path;
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Needed to see the entry and open anything under [path].
  final String permission;

  /// Needed for `[path]/new`; defaults to [permission].
  final String? createPermission;
}

class NavGroup {
  const NavGroup(this.label, this.entries);

  final String label;
  final List<NavEntry> entries;
}

/// The whole menu, in order. To add a section, add a [NavEntry] to a group
/// (or a new [NavGroup]) and a matching route in `router.dart`; menu
/// filtering, the home page and route permissions follow from this list.
const List<NavGroup> navGroups = [
  NavGroup('Overview', [
    NavEntry(
      path: '/dashboard',
      label: 'Dashboard',
      icon: Icons.space_dashboard_outlined,
      selectedIcon: Icons.space_dashboard,
      permission: Perm.dashboardView,
    ),
  ]),
  NavGroup('Sales', [
    NavEntry(
      path: '/invoices',
      label: 'Invoices',
      icon: Icons.receipt_long_outlined,
      selectedIcon: Icons.receipt_long,
      permission: Perm.invoicesView,
      createPermission: Perm.invoicesCreate,
    ),
    NavEntry(
      path: '/credit-notes',
      label: 'Credit notes',
      icon: Icons.assignment_return_outlined,
      selectedIcon: Icons.assignment_return,
      permission: Perm.creditNotesView,
      createPermission: Perm.creditNotesCreate,
    ),
    NavEntry(
      path: '/receipts',
      label: 'Receipts',
      icon: Icons.call_received_outlined,
      selectedIcon: Icons.call_received,
      permission: Perm.paymentsView,
      createPermission: Perm.paymentsCreate,
    ),
  ]),
  NavGroup('Purchases', [
    NavEntry(
      path: '/purchases',
      label: 'Bills',
      icon: Icons.shopping_cart_outlined,
      selectedIcon: Icons.shopping_cart,
      permission: Perm.purchasesView,
      createPermission: Perm.purchasesCreate,
    ),
    NavEntry(
      path: '/payments',
      label: 'Payments',
      icon: Icons.call_made_outlined,
      selectedIcon: Icons.call_made,
      permission: Perm.paymentsView,
      createPermission: Perm.paymentsCreate,
    ),
    NavEntry(
      path: '/expenses',
      label: 'Expenses',
      icon: Icons.request_quote_outlined,
      selectedIcon: Icons.request_quote,
      permission: Perm.expensesView,
      createPermission: Perm.expensesCreate,
    ),
  ]),
  NavGroup('Inventory', [
    NavEntry(
      path: '/items',
      label: 'Items',
      icon: Icons.inventory_2_outlined,
      selectedIcon: Icons.inventory_2,
      permission: Perm.itemsView,
      createPermission: Perm.itemsCreate,
    ),
    NavEntry(
      path: '/stock',
      label: 'Stock',
      icon: Icons.warehouse_outlined,
      selectedIcon: Icons.warehouse,
      permission: Perm.stockView,
    ),
    NavEntry(
      path: '/transfers',
      label: 'Transfers',
      icon: Icons.local_shipping_outlined,
      selectedIcon: Icons.local_shipping,
      permission: Perm.transfersView,
      createPermission: Perm.transfersCreate,
    ),
  ]),
  NavGroup('Masters', [
    NavEntry(
      path: '/parties',
      label: 'Parties',
      icon: Icons.people_outline,
      selectedIcon: Icons.people,
      permission: Perm.partiesView,
      createPermission: Perm.partiesCreate,
    ),
    NavEntry(
      path: '/locations',
      label: 'Locations',
      icon: Icons.location_on_outlined,
      selectedIcon: Icons.location_on,
      permission: Perm.locationsView,
    ),
  ]),
  NavGroup('Administration', [
    NavEntry(
      path: '/users',
      label: 'Users',
      icon: Icons.manage_accounts_outlined,
      selectedIcon: Icons.manage_accounts,
      permission: Perm.usersManage,
    ),
    NavEntry(
      path: '/audit',
      label: 'Audit log',
      icon: Icons.history_outlined,
      selectedIcon: Icons.history,
      permission: Perm.auditView,
    ),
  ]),
];

/// Groups with only the entries [permissions] allow; empty groups dropped.
List<NavGroup> visibleNavGroups(PermissionSet permissions) => [
  for (final group in navGroups)
    if (group.entries.any((e) => permissions.can(e.permission)))
      NavGroup(group.label, [
        for (final entry in group.entries)
          if (permissions.can(entry.permission)) entry,
      ]),
];

/// Visible entries in menu order (flattened groups).
List<NavEntry> visibleNavEntries(PermissionSet permissions) => [
  for (final group in visibleNavGroups(permissions)) ...group.entries,
];

/// The first section the user may open.
String homePath(PermissionSet permissions) {
  final visible = visibleNavEntries(permissions);
  return visible.isEmpty ? '/no-access' : visible.first.path;
}

/// Permission needed to open [path]: `<entry>/new` needs the entry's create
/// permission, anything else under an entry needs its view permission.
String? requiredPermission(String path) {
  for (final group in navGroups) {
    for (final entry in group.entries) {
      if (path == '${entry.path}/new') {
        return entry.createPermission ?? entry.permission;
      }
      if (path == entry.path || path.startsWith('${entry.path}/')) {
        return entry.permission;
      }
    }
  }
  return null;
}

/// Index of the entry that owns [location] in [entries], or `null`.
int? navIndexFor(List<NavEntry> entries, String location) {
  for (var i = 0; i < entries.length; i++) {
    final path = entries[i].path;
    if (location == path || location.startsWith('$path/')) return i;
  }
  return null;
}
