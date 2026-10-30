/// Routes and menu entries of income tax and the TDS filing pack
/// (API v1.6 §5, §6, §8).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../compliance/tax_perms.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'ca_check_screen.dart';
import 'itr_pack_screen.dart';
import 'tax_calculators_screen.dart';
import 'tax_payments_screen.dart';
import 'tds_file_screen.dart';

const List<NavEntry> incomeTaxNavEntries = [
  NavEntry(
    path: '/tax-payments',
    label: 'Tax payments',
    icon: Icons.payments_outlined,
    selectedIcon: Icons.payments,
    permission: TaxPerm.taxView,
    createPermission: TaxPerm.taxManage,
  ),
  NavEntry(
    path: '/tax-calculators',
    label: 'Tax calculators',
    icon: Icons.calculate_outlined,
    selectedIcon: Icons.calculate,
    permission: TaxPerm.taxView,
  ),
  NavEntry(
    path: '/itr-pack',
    label: 'ITR pack',
    icon: Icons.description_outlined,
    selectedIcon: Icons.description,
    permission: TaxPerm.taxView,
  ),
  NavEntry(
    path: '/ca-check',
    label: 'Do I need a CA?',
    icon: Icons.support_agent_outlined,
    selectedIcon: Icons.support_agent,
    permission: TaxPerm.taxView,
  ),
];

List<RouteBase> incomeTaxRoutes() => [
  GoRoute(
    path: '/tax-payments',
    pageBuilder: (_, state) => sectionPage(state, const TaxPaymentsScreen()),
  ),
  GoRoute(
    path: '/tax-calculators',
    pageBuilder: (_, state) => sectionPage(state, const TaxCalculatorsScreen()),
  ),
  // Target of the "Needs you" advance-tax rows.
  GoRoute(
    path: '/advance-tax',
    pageBuilder: (_, state) =>
        sectionPage(state, const TaxCalculatorsScreen(initialTab: 2)),
  ),
  GoRoute(
    path: '/itr-pack',
    pageBuilder: (_, state) => sectionPage(state, const ItrPackScreen()),
  ),
  GoRoute(
    path: '/ca-check',
    pageBuilder: (_, state) => sectionPage(state, const CaCheckScreen()),
  ),
  GoRoute(
    path: '/tds/file',
    builder: (_, state) => TdsFileScreen(
      fy: state.uri.queryParameters['fy'],
      quarter: int.tryParse(state.uri.queryParameters['quarter'] ?? ''),
    ),
  ),
];
