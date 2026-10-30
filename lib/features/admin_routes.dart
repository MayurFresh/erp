/// Accounting, reports and administration screens: routes and menu entries
/// for the lead to wire into `router.dart` and `nav.dart`.
///
/// Route permissions follow from the [NavEntry] list (see `nav.dart`):
/// `/accounts/**` and `/journals/**` need `accounts.view` (`/journals/new`
/// needs `accounts.journal`), `/financials/**` needs `accounts.view`,
/// `/reports/**` needs `reports.view` (stock valuation also checks
/// `items.view_cost` itself), `/company` needs `company.manage`,
/// `/roles/**` needs `roles.manage`. `/users/:id` falls under the existing
/// `/users` entry (`users.manage`). `/account` (my account / change
/// password) has no entry, so every signed-in user may open it — link it
/// from the user menu.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../core/permissions.dart';
import 'accounting/accounts_screen.dart';
import 'accounting/journal_create_screen.dart';
import 'accounting/journals_screen.dart';
import 'accounting/ledger_screen.dart';
import 'reports/financial_report_screens.dart';
import 'reports/gst_summary_screen.dart';
import 'reports/register_report_screen.dart';
import 'reports/report_models.dart' show AgeingType;
import 'reports/reports_hub_screen.dart';
import 'reports/stock_ageing_screens.dart';
import 'settings/company_profile_screen.dart';
import 'settings/my_account_screen.dart';
import 'settings/roles_screens.dart';
import 'settings/user_edit_screen.dart';
import 'shell/nav.dart';
import 'shell/routing.dart';

export 'settings/user_edit_screen.dart' show UserEditScreen;

/// Routes to add inside the authenticated `ShellRoute`. Spread them
/// **after** the existing `/users` route so `/users/new` keeps matching
/// before `/users/:id`.
List<RouteBase> adminRoutes() => [
  GoRoute(
    path: '/accounts',
    pageBuilder: (_, state) => sectionPage(state, const AccountsScreen()),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            AccountLedgerScreen(accountId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/journals',
    pageBuilder: (_, state) => sectionPage(state, const JournalsScreen()),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const JournalCreateScreen()),
    ],
  ),
  GoRoute(
    path: '/financials',
    pageBuilder: (_, state) =>
        sectionPage(state, const ReportsHubScreen(financials: true)),
    routes: [
      GoRoute(
        path: 'trial-balance',
        builder: (_, _) => const TrialBalanceScreen(),
      ),
      GoRoute(path: 'profit-loss', builder: (_, _) => const ProfitLossScreen()),
      GoRoute(
        path: 'balance-sheet',
        builder: (_, _) => const BalanceSheetScreen(),
      ),
    ],
  ),
  GoRoute(
    path: '/reports',
    pageBuilder: (_, state) => sectionPage(state, const ReportsHubScreen()),
    routes: [
      GoRoute(
        path: 'sales-register',
        builder: (_, _) => const RegisterReportScreen(purchase: false),
      ),
      GoRoute(
        path: 'purchase-register',
        builder: (_, _) => const RegisterReportScreen(purchase: true),
      ),
      GoRoute(path: 'gst-summary', builder: (_, _) => const GstSummaryScreen()),
      GoRoute(
        path: 'receivables-ageing',
        builder: (_, _) =>
            const AgeingReportScreen(type: AgeingType.receivables),
      ),
      GoRoute(
        path: 'payables-ageing',
        builder: (_, _) => const AgeingReportScreen(type: AgeingType.payables),
      ),
      GoRoute(
        path: 'stock-valuation',
        builder: (_, _) => const StockValuationScreen(),
      ),
    ],
  ),
  GoRoute(
    path: '/company',
    pageBuilder: (_, state) => sectionPage(state, const CompanyProfileScreen()),
  ),
  GoRoute(
    path: '/roles',
    pageBuilder: (_, state) => sectionPage(state, const RolesScreen()),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => RoleFormScreen(
          key: queryKey(state),
          copyFromId: state.uri.queryParameters['from'],
        ),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            RoleFormScreen(roleId: state.pathParameters['id']),
      ),
    ],
  ),
  GoRoute(
    path: '/account',
    pageBuilder: (_, state) => sectionPage(state, const MyAccountScreen()),
  ),
  GoRoute(
    path: '/users/:id',
    builder: (_, state) => UserEditScreen(userId: state.pathParameters['id']!),
  ),
];

/// Menu entries for an "Accounting" group.
const List<NavEntry> accountingNavEntries = [
  NavEntry(
    path: '/accounts',
    label: 'Chart of accounts',
    icon: Icons.account_tree_outlined,
    selectedIcon: Icons.account_tree,
    permission: Perm.accountsView,
    createPermission: Perm.accountsManage,
  ),
  NavEntry(
    path: '/journals',
    label: 'Day book',
    icon: Icons.menu_book_outlined,
    selectedIcon: Icons.menu_book,
    permission: Perm.accountsView,
    createPermission: Perm.accountsJournal,
  ),
  NavEntry(
    path: '/financials',
    label: 'Financials',
    icon: Icons.balance_outlined,
    selectedIcon: Icons.balance,
    permission: Perm.accountsView,
  ),
];

/// Menu entries for a "Reports" group.
const List<NavEntry> reportNavEntries = [
  NavEntry(
    path: '/reports',
    label: 'Reports',
    icon: Icons.insert_chart_outlined,
    selectedIcon: Icons.insert_chart,
    permission: Perm.reportsView,
  ),
];

/// Menu entries for the existing "Administration" group.
const List<NavEntry> settingsNavEntries = [
  NavEntry(
    path: '/company',
    label: 'Company profile',
    icon: Icons.business_outlined,
    selectedIcon: Icons.business,
    permission: Perm.companyManage,
  ),
  NavEntry(
    path: '/roles',
    label: 'Roles',
    icon: Icons.admin_panel_settings_outlined,
    selectedIcon: Icons.admin_panel_settings,
    permission: Perm.rolesManage,
    createPermission: Perm.rolesManage,
  ),
];

/// Every menu entry of this pack, in suggested order.
const List<NavEntry> adminNavEntries = [
  ...accountingNavEntries,
  ...reportNavEntries,
  ...settingsNavEntries,
];

/// Suggested grouping: two new groups (insert after "Masters") plus
/// [settingsNavEntries] spread into "Administration".
const List<NavGroup> adminNavGroups = [
  NavGroup('Accounting', accountingNavEntries),
  NavGroup('Reports', reportNavEntries),
];
