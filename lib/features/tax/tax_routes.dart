/// Routes and menu entries of the statutory masters (API v1.4).
///
/// Wire-up (lead engineer): add `...taxRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart`, and add `taxNavEntries` to a
/// group in `nav.dart` (e.g. `...taxNavEntries` into Administration).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../compliance/tax_perms.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'gst_rates_screen.dart';
import 'tds_sections_screen.dart';

/// Any signed-in user may read the masters, so the menu entries need a
/// permission everybody with reporting access has.
const List<NavEntry> taxNavEntries = [
  NavEntry(
    path: '/gst-rates',
    label: 'GST rates',
    icon: Icons.percent_outlined,
    selectedIcon: Icons.percent,
    permission: TaxPerm.gstView,
    createPermission: TaxPerm.gstManage,
  ),
  NavEntry(
    path: '/tds-sections',
    label: 'TDS sections',
    icon: Icons.receipt_long_outlined,
    selectedIcon: Icons.receipt_long,
    permission: TaxPerm.tdsView,
    createPermission: TaxPerm.tdsManage,
  ),
];

List<RouteBase> taxRoutes() => [
  GoRoute(
    path: '/gst-rates',
    pageBuilder: (_, state) => sectionPage(state, const GstRatesScreen()),
  ),
  GoRoute(
    path: '/tds-sections',
    pageBuilder: (_, state) => sectionPage(state, const TdsSectionsScreen()),
  ),
];
