/// Routes and menu entries of fund and budget control and donations (API Wave 2, modules `funds` and `donations`).
///
/// Wired in `router.dart` (`...fundsRoutes()`) and `nav.dart`
/// (`NavGroup('Funds and budget', fundsNavEntries)`, `NavGroup('Donations', donationsNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'budget_screen.dart';
import 'donations_home_screen.dart';
import 'donors_screen.dart';
import 'form10bd_screen.dart';
import 'funds_home_screen.dart';
import 'funds_list_screen.dart';
import 'funds_reports_screen.dart';
import 'receipts_screen.dart';
import 'sanctions_screen.dart';
import 'spending_screen.dart';

const List<NavEntry> fundsNavEntries = [
  NavEntry(
    path: '/funds',
    label: 'Funds home',
    icon: Icons.account_balance_outlined,
    selectedIcon: Icons.account_balance,
    permission: Perm.fundsView,
  ),
  NavEntry(
    path: '/funds/budget',
    label: 'Budget heads',
    icon: Icons.account_tree_outlined,
    selectedIcon: Icons.account_tree,
    permission: Perm.fundsView,
  ),
  NavEntry(
    path: '/funds/sanctions',
    label: 'Sanctions',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: Perm.fundsView,
  ),
  NavEntry(
    path: '/funds/spending',
    label: 'Link spending',
    icon: Icons.link_outlined,
    selectedIcon: Icons.link,
    permission: Perm.fundsEntry,
  ),
  NavEntry(
    path: '/funds/funds',
    label: 'Funds and grants',
    icon: Icons.savings_outlined,
    selectedIcon: Icons.savings,
    permission: Perm.fundsView,
  ),
  NavEntry(
    path: '/funds/reports',
    label: 'Fund reports',
    icon: Icons.assessment_outlined,
    selectedIcon: Icons.assessment,
    permission: Perm.fundsView,
  ),
];

const List<NavEntry> donationsNavEntries = [
  NavEntry(
    path: '/donations',
    label: 'Donations',
    icon: Icons.volunteer_activism_outlined,
    selectedIcon: Icons.volunteer_activism,
    permission: Perm.donationsView,
  ),
  NavEntry(
    path: '/donations/receipts',
    label: 'Receipts',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    permission: Perm.donationsView,
  ),
  NavEntry(
    path: '/donations/donors',
    label: 'Donors',
    icon: Icons.groups_outlined,
    selectedIcon: Icons.groups,
    permission: Perm.donationsView,
  ),
  NavEntry(
    path: '/donations/10bd',
    label: 'Form 10BD',
    icon: Icons.description_outlined,
    selectedIcon: Icons.description,
    permission: Perm.donationsManage,
  ),
];

List<RouteBase> fundsRoutes() => [
  GoRoute(
    path: '/funds',
    pageBuilder: (_, state) => sectionPage(state, const FundsHomeScreen()),
    routes: [
      GoRoute(
        path: 'budget',
        pageBuilder: (_, state) => sectionPage(state, const BudgetScreen()),
      ),
      GoRoute(
        path: 'sanctions',
        pageBuilder: (_, state) => sectionPage(state, const SanctionsScreen()),
      ),
      GoRoute(
        path: 'spending',
        pageBuilder: (_, state) => sectionPage(state, const SpendingScreen()),
      ),
      GoRoute(
        path: 'funds',
        pageBuilder: (_, state) => sectionPage(state, const FundsListScreen()),
      ),
      GoRoute(
        path: 'reports',
        pageBuilder: (_, state) =>
            sectionPage(state, const FundsReportsScreen()),
      ),
    ],
  ),
  GoRoute(
    path: '/donations',
    pageBuilder: (_, state) => sectionPage(state, const DonationsHomeScreen()),
    routes: [
      GoRoute(
        path: 'receipts',
        pageBuilder: (_, state) => sectionPage(state, const ReceiptsScreen()),
      ),
      GoRoute(
        path: 'donors',
        pageBuilder: (_, state) => sectionPage(state, const DonorsScreen()),
      ),
      GoRoute(
        path: '10bd',
        pageBuilder: (_, state) => sectionPage(state, const Form10bdScreen()),
      ),
    ],
  ),
];
