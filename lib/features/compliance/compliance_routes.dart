/// Routes and menu entries of the statutory core (API v1.4).
///
/// Wire-up (lead engineer): add `...complianceRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart`, and
/// `NavGroup('Compliance', complianceNavEntries)` to `navGroups` in
/// `nav.dart`. `/tds-challans/:id` lives outside `/tds`, so route permission
/// checks need an extra rule for it (`tds.view`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'bank_recon_screen.dart';
import 'compliance_docs_screen.dart';
import 'data_export_screen.dart';
import 'gst_2b_screen.dart';
import 'gst_returns_screen.dart';
import 'itc_ageing_screen.dart';
import 'msme_dues_screen.dart';
import 'setup_health_screen.dart';
import 'tax_perms.dart';
import 'tds_challan_screen.dart';
import 'tds_screen.dart';

/// Menu group "Compliance", in order.
const List<NavEntry> complianceNavEntries = [
  NavEntry(
    path: '/gst-returns',
    label: 'GST returns',
    icon: Icons.description_outlined,
    selectedIcon: Icons.description,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/gst-2b',
    label: 'GSTR-2B match',
    icon: Icons.compare_arrows_outlined,
    selectedIcon: Icons.compare_arrows,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/itc-ageing',
    label: 'ITC ageing',
    icon: Icons.hourglass_bottom_outlined,
    selectedIcon: Icons.hourglass_bottom,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/tds',
    label: 'TDS',
    icon: Icons.request_page_outlined,
    selectedIcon: Icons.request_page,
    permission: TaxPerm.tdsView,
  ),
  NavEntry(
    path: '/bank-reconciliation',
    label: 'Bank reconciliation',
    icon: Icons.account_balance_outlined,
    selectedIcon: Icons.account_balance,
    permission: TaxPerm.bankReconcile,
  ),
  NavEntry(
    path: '/msme-dues',
    label: 'MSME dues',
    icon: Icons.store_outlined,
    selectedIcon: Icons.store,
    permission: Perm.reportsView,
  ),
  NavEntry(
    path: '/compliance-docs',
    label: 'Licences',
    icon: Icons.badge_outlined,
    selectedIcon: Icons.badge,
    permission: TaxPerm.complianceView,
    createPermission: TaxPerm.complianceManage,
  ),
  NavEntry(
    path: '/setup-health',
    label: 'Setup health',
    icon: Icons.health_and_safety_outlined,
    selectedIcon: Icons.health_and_safety,
    permission: TaxPerm.complianceView,
  ),
  NavEntry(
    path: '/data-export',
    label: 'Data export',
    icon: Icons.download_outlined,
    selectedIcon: Icons.download,
    permission: TaxPerm.dataExport,
  ),
];

List<RouteBase> complianceRoutes() => [
  GoRoute(
    path: '/gst-returns',
    pageBuilder: (_, state) => sectionPage(state, const GstReturnsScreen()),
  ),
  GoRoute(
    path: '/gst-2b',
    pageBuilder: (_, state) => sectionPage(state, const Gst2bScreen()),
  ),
  GoRoute(
    path: '/itc-ageing',
    pageBuilder: (_, state) => sectionPage(state, const ItcAgeingScreen()),
  ),
  GoRoute(
    path: '/tds',
    pageBuilder: (_, state) => sectionPage(state, const TdsScreen()),
  ),
  GoRoute(
    path: '/tds-challans/:id',
    builder: (_, state) => TdsChallanScreen(id: state.pathParameters['id']!),
  ),
  GoRoute(
    path: '/bank-reconciliation',
    pageBuilder: (_, state) => sectionPage(state, const BankReconScreen()),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            BankStatementScreen(id: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/msme-dues',
    pageBuilder: (_, state) => sectionPage(state, const MsmeDuesScreen()),
  ),
  GoRoute(
    path: '/compliance-docs',
    pageBuilder: (_, state) => sectionPage(state, const ComplianceDocsScreen()),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const ComplianceDocFormScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            ComplianceDocFormScreen(id: state.pathParameters['id']),
      ),
    ],
  ),
  GoRoute(
    path: '/setup-health',
    pageBuilder: (_, state) => sectionPage(state, const SetupHealthScreen()),
  ),
  GoRoute(
    path: '/data-export',
    pageBuilder: (_, state) => sectionPage(state, const DataExportScreen()),
  ),
];
