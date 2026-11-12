/// Routes and menu entries of the manufacturing module (API "v1.13
/// Manufacturing").
///
/// Wired in `router.dart` (`...manufacturingRoutes()`) and `nav.dart`
/// (`NavGroup('Manufacturing', manufacturingNavEntries)`, module
/// `manufacturing`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../shell/nav.dart';
import '../shell/routing.dart';
import 'bom_list_screen.dart';
import 'bom_screen.dart';
import 'challan_screen.dart';
import 'jobwork_screen.dart';
import 'mfg_home_screen.dart';
import 'mfg_perms.dart';
import 'mfg_setup_screen.dart';
import 'order_screen.dart';
import 'orders_screen.dart';
import 'planning_screen.dart';

/// Menu group "Manufacturing". Specific paths come before shorter ones that
/// share a prefix.
const List<NavEntry> manufacturingNavEntries = [
  NavEntry(
    path: '/manufacturing/orders',
    label: 'Production orders',
    icon: Icons.precision_manufacturing_outlined,
    selectedIcon: Icons.precision_manufacturing,
    permission: MfgPerm.view,
  ),
  NavEntry(
    path: '/manufacturing/boms',
    label: 'Bills of materials',
    icon: Icons.account_tree_outlined,
    selectedIcon: Icons.account_tree,
    permission: MfgPerm.view,
  ),
  NavEntry(
    path: '/manufacturing/planning',
    label: 'Material planning',
    icon: Icons.inventory_outlined,
    selectedIcon: Icons.inventory,
    permission: MfgPerm.view,
  ),
  NavEntry(
    path: '/manufacturing/jobwork',
    label: 'Job work',
    icon: Icons.local_shipping_outlined,
    selectedIcon: Icons.local_shipping,
    permission: MfgPerm.view,
  ),
  NavEntry(
    path: '/manufacturing/setup',
    label: 'Production setup',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    permission: MfgPerm.bom,
  ),
  NavEntry(
    path: '/manufacturing',
    label: 'Production',
    icon: Icons.factory_outlined,
    selectedIcon: Icons.factory,
    permission: MfgPerm.view,
  ),
];

List<RouteBase> manufacturingRoutes() => [
  GoRoute(
    path: '/manufacturing',
    pageBuilder: (_, state) => sectionPage(state, const MfgHomeScreen()),
  ),
  GoRoute(
    path: '/manufacturing/orders',
    pageBuilder: (_, state) => sectionPage(
      state,
      OrdersScreen(
        key: queryKey(state),
        status: state.uri.queryParameters['status'] ?? '',
      ),
    ),
  ),
  GoRoute(
    path: '/manufacturing/orders/:id',
    builder: (_, state) => OrderScreen(
      key: ValueKey(state.pathParameters['id']),
      orderId: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/manufacturing/boms',
    pageBuilder: (_, state) => sectionPage(state, const BomListScreen()),
  ),
  // Before `/boms/:id`, so "new" is not read as an id.
  GoRoute(path: '/manufacturing/boms/new', builder: (_, _) => const BomScreen()),
  GoRoute(
    path: '/manufacturing/boms/:id',
    builder: (_, state) => BomScreen(
      key: ValueKey(state.pathParameters['id']),
      bomId: state.pathParameters['id'],
    ),
  ),
  GoRoute(
    path: '/manufacturing/planning',
    pageBuilder: (_, state) => sectionPage(state, const PlanningScreen()),
  ),
  GoRoute(
    path: '/manufacturing/jobwork',
    pageBuilder: (_, state) => sectionPage(state, const JobWorkScreen()),
  ),
  GoRoute(
    path: '/manufacturing/jobwork/:id',
    builder: (_, state) => ChallanScreen(
      key: ValueKey(state.pathParameters['id']),
      challanId: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/manufacturing/setup',
    pageBuilder: (_, state) => sectionPage(state, const MfgSetupScreen()),
  ),
];
