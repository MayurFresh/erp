/// Routes and menu entries of stock valuation and handling.
///
/// Wire-up (lead engineer): add `...stockToolRoutes()` to the authenticated `ShellRoute` in `router.dart`
/// and [stockToolNavEntries] to the Stock group in `nav.dart`. The item units screen has no menu entry:
/// link to `/items/<id>/units` from the item screen.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'item_units_screen.dart';
import 'labels_screen.dart';
import 'stock_tools_screens.dart';

const List<NavEntry> stockToolNavEntries = [
  NavEntry(
    path: '/stock-ageing',
    label: 'Stock ageing',
    icon: Icons.hourglass_empty_outlined,
    selectedIcon: Icons.hourglass_empty,
    permission: Perm.reportsView,
  ),
  NavEntry(
    path: '/slow-moving',
    label: 'Slow-moving stock',
    icon: Icons.trending_down_outlined,
    selectedIcon: Icons.trending_down,
    permission: Perm.reportsView,
  ),
  NavEntry(
    path: '/valuation-method',
    label: 'Valuation method',
    icon: Icons.balance_outlined,
    selectedIcon: Icons.balance,
    permission: Perm.stockView,
  ),
  NavEntry(
    path: '/labels',
    label: 'Barcode labels',
    icon: Icons.qr_code_2_outlined,
    selectedIcon: Icons.qr_code_2,
    permission: Perm.itemsView,
  ),
];

List<RouteBase> stockToolRoutes() => [
  GoRoute(path: '/stock-ageing', pageBuilder: (c, s) => sectionPage(s, const StockAgeingScreen())),
  GoRoute(path: '/slow-moving', pageBuilder: (c, s) => sectionPage(s, const SlowMovingScreen())),
  GoRoute(path: '/valuation-method', pageBuilder: (c, s) => sectionPage(s, const ValuationMethodScreen())),
  GoRoute(path: '/labels', pageBuilder: (c, s) => sectionPage(s, const LabelsScreen())),
  GoRoute(
    path: '/items/:id/units',
    pageBuilder: (c, s) => sectionPage(s, ItemUnitsScreen(itemId: s.pathParameters['id']!)),
  ),
];
