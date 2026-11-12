/// Routes and menu entries of the warehouse module (API "Wave 2: Warehouse
/// depth").
///
/// Wired in `router.dart` (`...warehouseRoutes()`) and `nav.dart`
/// (`NavGroup('Warehouse', warehouseNavEntries)`, module `warehouse`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../shell/nav.dart';
import '../shell/routing.dart';
import 'bins_screen.dart';
import 'expiry_screen.dart';
import 'item_rules_screen.dart';
import 'pick_screen.dart';
import 'serials_screen.dart';
import 'stock_screen.dart';
import 'wh_perms.dart';
import 'wh_settings_screen.dart';

/// Menu group "Warehouse". Specific paths come before the shorter `/warehouse`.
const List<NavEntry> warehouseNavEntries = [
  NavEntry(
    path: '/warehouse/bins',
    label: 'Bins',
    icon: Icons.grid_view_outlined,
    selectedIcon: Icons.grid_view,
    permission: WhPerm.view,
  ),
  NavEntry(
    path: '/warehouse/pick',
    label: 'Pick list',
    icon: Icons.checklist_outlined,
    selectedIcon: Icons.checklist,
    permission: WhPerm.view,
  ),
  NavEntry(
    path: '/warehouse/serials',
    label: 'Serial numbers',
    icon: Icons.qr_code_2_outlined,
    selectedIcon: Icons.qr_code_2,
    permission: WhPerm.view,
  ),
  NavEntry(
    path: '/warehouse/expiry',
    label: 'Expiry report',
    icon: Icons.event_busy_outlined,
    selectedIcon: Icons.event_busy,
    permission: WhPerm.view,
  ),
  NavEntry(
    path: '/warehouse/rules',
    label: 'Item rules',
    icon: Icons.rule_outlined,
    selectedIcon: Icons.rule,
    permission: WhPerm.manage,
  ),
  NavEntry(
    path: '/warehouse/settings',
    label: 'Warehouse settings',
    icon: Icons.tune_outlined,
    selectedIcon: Icons.tune,
    permission: WhPerm.manage,
  ),
  NavEntry(
    path: '/warehouse',
    label: 'Warehouse stock',
    icon: Icons.warehouse_outlined,
    selectedIcon: Icons.warehouse,
    permission: WhPerm.view,
  ),
];

List<RouteBase> warehouseRoutes() => [
  GoRoute(
    path: '/warehouse',
    pageBuilder: (_, state) => sectionPage(state, const WarehouseStockScreen()),
  ),
  GoRoute(
    path: '/warehouse/bins',
    pageBuilder: (_, state) => sectionPage(state, const BinsScreen()),
  ),
  GoRoute(
    path: '/warehouse/pick',
    pageBuilder: (_, state) => sectionPage(state, const PickScreen()),
  ),
  GoRoute(
    path: '/warehouse/serials',
    pageBuilder: (_, state) => sectionPage(state, const SerialsScreen()),
  ),
  GoRoute(
    path: '/warehouse/expiry',
    pageBuilder: (_, state) => sectionPage(state, const ExpiryScreen()),
  ),
  GoRoute(
    path: '/warehouse/rules',
    pageBuilder: (_, state) => sectionPage(state, const ItemRulesScreen()),
  ),
  GoRoute(
    path: '/warehouse/settings',
    pageBuilder: (_, state) => sectionPage(state, const WhSettingsScreen()),
  ),
];
