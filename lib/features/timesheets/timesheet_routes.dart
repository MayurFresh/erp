/// Routes and menu entries of timesheets (API 055, module `timesheets`).
///
/// Wire in `router.dart` (`...timesheetRoutes()`) and `nav.dart`
/// (`NavGroup('Timesheets', timesheetNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'approvals_screen.dart';
import 'billing_screen.dart';
import 'utilisation_screen.dart';
import 'week_screen.dart';

const List<NavEntry> timesheetNavEntries = [
  NavEntry(
    path: '/timesheets',
    label: 'Timesheet',
    icon: Icons.schedule_outlined,
    selectedIcon: Icons.schedule,
    permission: Perm.timesheetsLog,
  ),
  NavEntry(
    path: '/timesheets/approvals',
    label: 'Approve hours',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: Perm.timesheetsApprove,
  ),
  NavEntry(
    path: '/timesheets/billing',
    label: 'Bill time',
    icon: Icons.request_quote_outlined,
    selectedIcon: Icons.request_quote,
    permission: Perm.timesheetsBill,
  ),
  NavEntry(
    path: '/timesheets/utilisation',
    label: 'Utilisation',
    icon: Icons.pie_chart_outline,
    selectedIcon: Icons.pie_chart,
    permission: Perm.timesheetsView,
  ),
];

List<RouteBase> timesheetRoutes() => [
  GoRoute(
    path: '/timesheets',
    pageBuilder: (_, state) => sectionPage(state, const WeekScreen()),
    routes: [
      GoRoute(
        path: 'approvals',
        pageBuilder: (_, state) => sectionPage(state, const ApprovalsScreen()),
      ),
      GoRoute(
        path: 'billing',
        pageBuilder: (_, state) => sectionPage(state, const BillingScreen()),
      ),
      GoRoute(
        path: 'utilisation',
        pageBuilder: (_, state) =>
            sectionPage(state, const UtilisationScreen()),
      ),
    ],
  ),
];
