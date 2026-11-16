/// Routes and menu entry for landed cost vouchers.
///
/// Wire-up (lead engineer): add `...landedCostRoutes()` to the authenticated
/// `ShellRoute` in `router.dart` and [landedCostNavEntry] to the Purchases
/// group in `nav.dart`.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'landed_cost_form_screen.dart';
import 'landed_cost_screens.dart';

const NavEntry landedCostNavEntry = NavEntry(
  path: '/landed-costs',
  label: 'Landed cost',
  icon: Icons.local_shipping_outlined,
  selectedIcon: Icons.local_shipping,
  permission: Perm.purchasesView,
  createPermission: Perm.purchasesCreate,
);

List<RouteBase> landedCostRoutes() => [
  GoRoute(
    path: '/landed-costs',
    pageBuilder: (_, state) => sectionPage(state, const LandedCostsScreen()),
    routes: [
      GoRoute(
        path: 'new',
        pageBuilder: (_, state) =>
            sectionPage(state, const LandedCostFormScreen()),
      ),
      GoRoute(
        path: 'report',
        pageBuilder: (_, state) =>
            sectionPage(state, const LandedCostReportScreen()),
      ),
      GoRoute(
        path: ':id',
        pageBuilder: (_, state) => sectionPage(
          state,
          LandedCostDetailScreen(id: state.pathParameters['id']!),
        ),
      ),
    ],
  ),
];
