/// Routes and menu entries of the v1.7 controls pack: approvals, approval
/// rules, custom fields, cost centres (+ report) and CSV import.
///
/// Wire-up (lead engineer): add `...controlsRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart` (before any `/imports` or
/// `/approvals` catch-alls), and add `controlsNavEntries` to a group in
/// `nav.dart`, e.g. `...controlsNavEntries` into Administration.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../shell/nav.dart';
import '../shell/routing.dart';
import 'approval_rules_screen.dart';
import 'approvals_screens.dart';
import 'controls_perms.dart';
import 'cost_centre_report_screen.dart';
import 'cost_centres_screen.dart';
import 'custom_fields_admin_screen.dart';
import 'import_screens.dart';

/// Approvals are open to any signed-in user (the inbox shows what concerns
/// them); `dashboard.view` is the broadest permission the menu offers.
const List<NavEntry> controlsNavEntries = [
  NavEntry(
    path: '/approvals',
    label: 'Approvals',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: 'dashboard.view',
  ),
  NavEntry(
    path: '/approval-rules',
    label: 'Approval rules',
    icon: Icons.rule_outlined,
    selectedIcon: Icons.rule,
    permission: ControlsPerm.approvalsManage,
  ),
  NavEntry(
    path: '/custom-fields',
    label: 'Custom fields',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    permission: ControlsPerm.companyManage,
  ),
  NavEntry(
    path: '/cost-centres',
    label: 'Cost centres',
    icon: Icons.account_tree_outlined,
    selectedIcon: Icons.account_tree,
    permission: ControlsPerm.accountsManage,
  ),
  NavEntry(
    path: '/cost-centre-report',
    label: 'Cost centre report',
    icon: Icons.stacked_bar_chart_outlined,
    selectedIcon: Icons.stacked_bar_chart,
    permission: ControlsPerm.accountsView,
  ),
  NavEntry(
    path: '/imports',
    label: 'Import data',
    icon: Icons.upload_file_outlined,
    selectedIcon: Icons.upload_file,
    permission: ControlsPerm.importsRun,
  ),
];

List<RouteBase> controlsRoutes() => [
  GoRoute(
    path: '/approvals',
    pageBuilder: (_, state) => sectionPage(state, const ApprovalsScreen()),
    routes: [
      GoRoute(
        path: ':id',
        pageBuilder: (_, state) => sectionPage(
          state,
          ApprovalDetailScreen(id: state.pathParameters['id']!),
        ),
      ),
    ],
  ),
  GoRoute(
    path: '/approval-rules',
    pageBuilder: (_, state) => sectionPage(state, const ApprovalRulesScreen()),
  ),
  GoRoute(
    path: '/custom-fields',
    pageBuilder: (_, state) =>
        sectionPage(state, const CustomFieldsAdminScreen()),
  ),
  GoRoute(
    path: '/cost-centres',
    pageBuilder: (_, state) => sectionPage(state, const CostCentresScreen()),
  ),
  GoRoute(
    path: '/cost-centre-report',
    pageBuilder: (_, state) =>
        sectionPage(state, const CostCentreReportScreen()),
  ),
  GoRoute(
    path: '/imports',
    pageBuilder: (_, state) => sectionPage(state, const ImportsScreen()),
    routes: [
      GoRoute(
        path: ':id',
        pageBuilder: (_, state) => sectionPage(
          state,
          ImportJobScreen(id: state.pathParameters['id']!),
        ),
      ),
    ],
  ),
];
