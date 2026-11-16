import 'package:flutter/material.dart';

import '../../core/business_profile.dart';
import '../../core/permissions.dart';
import '../admin_routes.dart';
import '../construction_routes.dart';
import '../compliance/compliance_routes.dart';
import '../pos/pos_routes.dart';
import '../clinic/clinic_routes.dart';
import '../job_cards/job_card_routes.dart';
import '../quotations/quotation_routes.dart';
import '../crm/crm_routes.dart';
import '../pricing/pricing_routes.dart';
import '../purchase_returns/purchase_return_routes.dart';
import '../receivables/receivables_routes.dart';
import '../tds_forms/tds_forms_routes.dart';
import '../stock_tools/stock_tools_routes.dart';
import '../claims/claims_routes.dart';
import '../export_currency/export_currency_routes.dart';
import '../landed_cost/landed_cost_routes.dart';
import '../rfq/rfq_routes.dart';
import '../platform_extras/platform_extras_routes.dart';
import '../helpdesk/helpdesk_routes.dart';
import '../timesheets/timesheet_routes.dart';
import '../memberships/memberships_routes.dart';
import '../funds/funds_routes.dart';
import '../education/education_routes.dart';
import '../hotel/hotel_routes.dart';
import '../legal/legal_routes.dart';
import '../channels/channels_routes.dart';
import '../realestate/realestate_routes.dart';
import '../hr/hr_routes.dart';
import '../manufacturing/manufacturing_routes.dart';
import '../warehouse/warehouse_routes.dart';
import '../restaurant/restaurant_routes.dart';
import '../tax/tax_routes.dart';
import '../gst_filing/gst_filing_routes.dart';
import '../fixed_assets/fixed_asset_routes.dart';
import '../income_tax/income_tax_routes.dart';
import '../platform/platform_routes.dart';
import '../platform/super_routes.dart';
import '../controls/controls_routes.dart';
import '../purchase_orders/purchasing_routes.dart';
import '../sales_orders/sales_orders_routes.dart';

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
/// (or a new [NavGroup], or spread a pack's list, e.g. `...adminNavEntries`
/// into Administration or `NavGroup('Construction', constructionNavEntries)`)
/// and a matching route in `router.dart`. Menu filtering (empty groups
/// hidden), the home page and route permissions all follow from this list:
/// `<path>` and anything under it need [NavEntry.permission], `<path>/new`
/// needs [NavEntry.createPermission].
final List<NavGroup> navGroups = [
  NavGroup('Platform', superAdminNavEntries),
  NavGroup('Overview', [
    NavEntry(
      path: '/dashboard',
      label: 'Dashboard',
      icon: Icons.space_dashboard_outlined,
      selectedIcon: Icons.space_dashboard,
      permission: Perm.dashboardView,
    ),
    insightsNavEntry,
  ]),
  NavGroup('Leads and deals', crmNavEntries),
  NavGroup('Sales', [
    quotationNavEntry,
    salesOrderNavEntry,
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
      icon: Icons.move_to_inbox_outlined,
      selectedIcon: Icons.move_to_inbox,
      permission: Perm.paymentsView,
      createPermission: Perm.paymentsCreate,
    ),
    ...receivablesNavEntries,
    priceListNavEntry,
    schemeNavEntry,
    ...exportCurrencyNavEntries,
    paymentLinksNavEntry,
  ]),
  NavGroup('Fulfilment', fulfilmentNavEntries),
  NavGroup('Purchases', [
    purchaseOrderNavEntry,
    NavEntry(
      path: '/purchases',
      label: 'Bills',
      icon: Icons.shopping_cart_outlined,
      selectedIcon: Icons.shopping_cart,
      permission: Perm.purchasesView,
      createPermission: Perm.purchasesCreate,
    ),
    purchaseReturnNavEntry,
    rfqNavEntry,
    landedCostNavEntry,
    NavEntry(
      path: '/payments',
      label: 'Payments',
      icon: Icons.account_balance_wallet_outlined,
      selectedIcon: Icons.account_balance_wallet,
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
    ...stockPlanningNavEntries,
    ...stockToolNavEntries,
  ]),
  NavGroup('Construction', constructionNavEntries),
  NavGroup('Real estate', realEstateNavEntries),
  NavGroup('HR and payroll', [...hrNavEntries, ...claimsNavEntries]),
  NavGroup('Restaurant', restaurantNavEntries),
  NavGroup('Manufacturing', manufacturingNavEntries),
  NavGroup('Warehouse', warehouseNavEntries),
  NavGroup('Patient care', clinicNavEntries),
  NavGroup('Memberships', membershipNavEntries),
  NavGroup('Job cards', jobCardNavEntries),
  NavGroup('Funds and budget', fundsNavEntries),
  NavGroup('Donations', donationsNavEntries),
  NavGroup('Students and fees', educationNavEntries),
  NavGroup('Hotel', hotelNavEntries),
  NavGroup('Legal practice', legalNavEntries),
  NavGroup('Helpdesk', helpdeskNavEntries),
  NavGroup('Timesheets', timesheetNavEntries),
  NavGroup('Online channels', channelsNavEntries),
  NavGroup('Counter billing', posNavEntries),
  NavGroup('Compliance', [
    ...complianceNavEntries,
    ...taxNavEntries,
    ...tdsFormsNavEntries,
    ...gstFilingNavEntries,
  ]),
  NavGroup('Income tax & assets', [
    ...incomeTaxNavEntries,
    ...fixedAssetNavEntries,
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
  ...adminNavGroups,
  NavGroup('Controls', controlsNavEntries),
  NavGroup('Administration', [
    ...settingsNavEntries,
    onlinePaymentsNavEntry,
    smsNavEntry,
    ...platformNavEntries,
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

/// The module an entry belongs to, or `null` when it is always shown.
/// Menu groups map to one module each; the mixed groups are split by path.
String? moduleOfEntry(String groupLabel, String path) {
  if (path == insightsNavEntry.path) return 'reports';
  switch (groupLabel) {
    case 'Sales':
      return 'sales';
    case 'Leads and deals':
      return 'crm';
    case 'Fulfilment':
      return 'fulfilment';
    case 'Purchases':
      return 'purchases';
    case 'Construction':
      return 'construction';
    case 'Real estate':
      return 'real_estate';
    case 'HR and payroll':
      return 'payroll';
    case 'Restaurant':
      return 'restaurant';
    case 'Manufacturing':
      return 'manufacturing';
    case 'Warehouse':
      return 'warehouse';
    case 'Patient care':
      return 'clinic';
    case 'Memberships':
      return 'memberships';
    case 'Job cards':
      return 'job_cards';
    case 'Funds and budget':
      return 'funds';
    case 'Donations':
      return 'donations';
    case 'Students and fees':
      return 'education';
    case 'Hotel':
      return 'hotel';
    case 'Legal practice':
      return 'legal';
    case 'Helpdesk':
      return 'helpdesk';
    case 'Timesheets':
      return 'timesheets';
    case 'Online channels':
      return 'channels';
    case 'Counter billing':
      return 'pos';
    case 'Accounting':
      return 'accounting';
    case 'Reports':
      return 'reports';
    case 'Controls':
      return 'controls';
  }
  if (path == '/items') return null;
  if (groupLabel == 'Inventory') return 'inventory';
  const gst = [
    '/gst-returns',
    '/gst-2b',
    '/itc-ageing',
    '/gst-rates',
    '/gst-filing',
    '/gst/',
    '/filings',
  ];
  const tds = [
    '/tds',
    '/tds-sections',
    '/tds-returns',
    '/tds-certificates',
    '/tds-map',
  ];
  const incomeTax = [
    '/tax-payments',
    '/tax-calculators',
    '/itr-pack',
    '/ca-check',
    '/advance-tax',
  ];
  bool under(List<String> prefixes) => prefixes.any(
    (p) => path == p || path.startsWith(p.endsWith('/') ? p : '$p/'),
  );
  if (under(gst)) return 'gst';
  if (under(tds)) return 'tds';
  if (under(incomeTax)) return 'income_tax';
  if (path == '/fixed-assets' || path.startsWith('/fixed-assets/')) {
    return 'fixed_assets';
  }
  const multi = ['/companies', '/intercompany', '/consolidated'];
  if (under(multi)) return 'multi_company';
  return null;
}

/// The company's own word on the menu: Invoices → Bills, Items → Medicines.
String _label(NavEntry entry, BusinessProfile profile) {
  final key = switch (entry.path) {
    '/invoices' => 'invoice',
    '/receipts' => 'receipt',
    '/purchases' => 'bill',
    '/items' => 'item',
    '/projects' => 'project',
    '/sales-orders' => 'sales_order',
    '/locations' => 'location',
    _ => null,
  };
  if (entry.path == '/parties') {
    final customer = profile.term('customer', plural: true);
    final vendor = profile.term('vendor', plural: true);
    return customer == 'Customers' && vendor == 'Vendors'
        ? entry.label
        : '${menuWord(customer)} and ${menuWord(vendor)}';
  }
  return key == null ? entry.label : menuWord(profile.term(key, plural: true));
}

bool _shown(
  String group,
  NavEntry e,
  PermissionSet permissions,
  BusinessProfile profile,
) {
  if (!permissions.can(e.permission)) return false;
  if (profile.simplifiedMenu && kSoloHiddenPaths.contains(e.path)) return false;
  final module = moduleOfEntry(group, e.path);
  return module == null || profile.hasModule(module);
}

NavEntry _renamed(NavEntry e, BusinessProfile profile) {
  final label = _label(e, profile);
  return label == e.label
      ? e
      : NavEntry(
          path: e.path,
          label: label,
          icon: e.icon,
          selectedIcon: e.selectedIcon,
          permission: e.permission,
          createPermission: e.createPermission,
        );
}

/// Groups with only the entries [permissions] allow and the company's
/// modules keep; empty groups dropped. Permissions stay the real security
/// check; modules only shape the menu.
List<NavGroup> visibleNavGroups(
  PermissionSet permissions, {
  BusinessProfile profile = BusinessProfile.standard,
}) => [
  for (final group in navGroups)
    if (group.entries.any((e) => _shown(group.label, e, permissions, profile)))
      NavGroup(group.label, [
        for (final entry in group.entries)
          if (_shown(group.label, entry, permissions, profile))
            _renamed(entry, profile),
      ]),
];

/// Visible entries in menu order (flattened groups).
List<NavEntry> visibleNavEntries(
  PermissionSet permissions, {
  BusinessProfile profile = BusinessProfile.standard,
}) => [
  for (final group in visibleNavGroups(permissions, profile: profile))
    ...group.entries,
];

/// The first section the user may open.
String homePath(
  PermissionSet permissions, {
  BusinessProfile profile = BusinessProfile.standard,
}) {
  final visible = visibleNavEntries(permissions, profile: profile);
  return visible.isEmpty ? '/no-access' : visible.first.path;
}

/// Permission needed to open [path]: `<entry>/new` needs the entry's create
/// permission, anything else under an entry needs its view permission.
String? requiredPermission(String path) {
  // The longest matching entry wins, so `/clinic/doctor` is not judged by `/clinic`.
  NavEntry? best;
  var bestIsNew = false;
  for (final group in navGroups) {
    for (final entry in group.entries) {
      final isNew = path == '${entry.path}/new';
      if (isNew || path == entry.path || path.startsWith('${entry.path}/')) {
        if (best == null || entry.path.length > best.path.length) {
          best = entry;
          bestIsNew = isNew;
        }
      }
    }
  }
  if (best == null) return null;
  return bestIsNew
      ? (best.createPermission ?? best.permission)
      : best.permission;
}

/// Whether the company's modules (and plan) allow opening [path]. Paths
/// that are not a menu section are allowed.
bool moduleAllows(String path, BusinessProfile profile) {
  for (final group in navGroups) {
    for (final entry in group.entries) {
      if (path == entry.path || path.startsWith('${entry.path}/')) {
        if (profile.simplifiedMenu && kSoloHiddenPaths.contains(entry.path)) {
          return false;
        }
        final module = moduleOfEntry(group.label, entry.path);
        return module == null || profile.hasModule(module);
      }
    }
  }
  return true;
}

/// Index of the entry that owns [location] in [entries], or `null`.
/// The longest matching path wins, so `/crm/leads` selects Leads, not `/crm`.
int? navIndexFor(List<NavEntry> entries, String location) {
  int? best;
  for (var i = 0; i < entries.length; i++) {
    final path = entries[i].path;
    if (location == path || location.startsWith('$path/')) {
      if (best == null || path.length > entries[best].path.length) best = i;
    }
  }
  return best;
}
