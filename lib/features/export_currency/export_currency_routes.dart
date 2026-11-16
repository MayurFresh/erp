/// Routes and menu entries of delivery challans, currencies and export, and
/// TCS on sales (docs/API.md v1.20).
///
/// Wire-up (lead engineer): add `...exportCurrencyRoutes()` to the routes of
/// the authenticated `ShellRoute` in `router.dart`, and
/// [exportCurrencyNavEntries] to a group in `nav.dart`.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'challan_detail_screen.dart';
import 'challan_form_screen.dart';
import 'challans_screen.dart';
import 'currency_screen.dart';
import 'tcs_screen.dart';

const NavEntry challanNavEntry = NavEntry(
  path: '/delivery-challans',
  label: 'Delivery challans',
  icon: Icons.local_shipping_outlined,
  selectedIcon: Icons.local_shipping,
  permission: Perm.challansView,
  createPermission: Perm.challansManage,
);

const NavEntry currencyNavEntry = NavEntry(
  path: '/currencies',
  label: 'Currencies',
  icon: Icons.currency_exchange_outlined,
  selectedIcon: Icons.currency_exchange,
  permission: Perm.fxView,
);

const NavEntry tcsNavEntry = NavEntry(
  path: '/tcs',
  label: 'TCS on sales',
  icon: Icons.account_balance_outlined,
  selectedIcon: Icons.account_balance,
  permission: Perm.tcsView,
);

const List<NavEntry> exportCurrencyNavEntries = [
  challanNavEntry,
  currencyNavEntry,
  tcsNavEntry,
];

List<RouteBase> exportCurrencyRoutes() => [
  GoRoute(
    path: '/delivery-challans',
    pageBuilder: (c, s) => sectionPage(s, const ChallansScreen()),
  ),
  // Static segment before ':id' so "new" is not read as an id.
  GoRoute(
    path: '/delivery-challans/new',
    pageBuilder: (c, s) => sectionPage(s, const ChallanFormScreen()),
  ),
  GoRoute(
    path: '/delivery-challans/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      ChallanDetailScreen(challanId: s.pathParameters['id']!),
    ),
  ),
  GoRoute(
    path: '/currencies',
    pageBuilder: (c, s) => sectionPage(s, const CurrencyScreen()),
  ),
  GoRoute(
    path: '/tcs',
    pageBuilder: (c, s) => sectionPage(s, const TcsScreen()),
  ),
];
