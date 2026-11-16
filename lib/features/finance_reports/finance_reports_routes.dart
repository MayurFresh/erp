/// Routes and menu entries of v1.15 finance reports and controls: cash flow,
/// ratios, year-end close, budgets and cheques.
///
/// Wire-up (lead engineer): add `...financeReportRoutes()` to the routes of
/// the authenticated `ShellRoute` in `router.dart`, and
/// [financeReportNavEntries] to a group in `nav.dart` (for example Reports or
/// Accounting).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'budgets_screen.dart';
import 'cash_flow_screen.dart';
import 'cheques_screen.dart';
import 'ratios_screen.dart';
import 'year_end_screen.dart';

const List<NavEntry> financeReportNavEntries = [
  NavEntry(
    path: '/cash-flow',
    label: 'Cash flow',
    icon: Icons.waterfall_chart_outlined,
    selectedIcon: Icons.waterfall_chart,
    permission: Perm.finreportsView,
  ),
  NavEntry(
    path: '/ratios',
    label: 'Ratio analysis',
    icon: Icons.percent_outlined,
    selectedIcon: Icons.percent,
    permission: Perm.finreportsView,
  ),
  NavEntry(
    path: '/budgets',
    label: 'Budgets',
    icon: Icons.savings_outlined,
    selectedIcon: Icons.savings,
    permission: Perm.finreportsView,
    createPermission: Perm.finreportsManage,
  ),
  NavEntry(
    path: '/cheques',
    label: 'Cheques',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    permission: Perm.chequesView,
    createPermission: Perm.chequesManage,
  ),
  NavEntry(
    path: '/year-end',
    label: 'Year-end close',
    icon: Icons.event_available_outlined,
    selectedIcon: Icons.event_available,
    permission: Perm.booksLock,
  ),
];

List<RouteBase> financeReportRoutes() => [
  GoRoute(
    path: '/cash-flow',
    pageBuilder: (c, s) => sectionPage(s, const CashFlowScreen()),
  ),
  GoRoute(
    path: '/cash-flow/mapping',
    pageBuilder: (c, s) => sectionPage(s, const CashFlowMappingScreen()),
  ),
  GoRoute(
    path: '/ratios',
    pageBuilder: (c, s) => sectionPage(s, const RatiosScreen()),
  ),
  GoRoute(
    path: '/budgets',
    pageBuilder: (c, s) => sectionPage(s, const BudgetVarianceScreen()),
  ),
  GoRoute(
    path: '/budgets/edit',
    pageBuilder: (c, s) => sectionPage(
      s,
      BudgetEditScreen(key: queryKey(s), fy: s.uri.queryParameters['fy']),
    ),
  ),
  GoRoute(
    path: '/cheques',
    pageBuilder: (c, s) => sectionPage(s, const ChequesScreen()),
  ),
  GoRoute(
    path: '/year-end',
    pageBuilder: (c, s) => sectionPage(s, const YearEndScreen()),
  ),
];
