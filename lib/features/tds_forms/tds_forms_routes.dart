/// Routes and menu entries of the TDS section map, certificates and returns.
///
/// Wire-up (lead engineer): add `...tdsFormsRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart` and `tdsFormsNavEntries` to a
/// group in `nav.dart`.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../compliance/tax_perms.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'certificates_screen.dart';
import 'section_map_screen.dart';
import 'tds_returns_screen.dart';

const List<NavEntry> tdsFormsNavEntries = [
  NavEntry(
    path: '/tds-returns',
    label: 'TDS returns',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: TaxPerm.tdsView,
  ),
  NavEntry(
    path: '/tds-certificates',
    label: 'TDS certificates',
    icon: Icons.description_outlined,
    selectedIcon: Icons.description,
    permission: TaxPerm.tdsView,
  ),
  NavEntry(
    path: '/tds-map',
    label: 'TDS section map',
    icon: Icons.swap_horiz_outlined,
    selectedIcon: Icons.swap_horiz,
    permission: TaxPerm.tdsView,
  ),
];

List<RouteBase> tdsFormsRoutes() => [
  GoRoute(
    path: '/tds-returns',
    pageBuilder: (_, state) => sectionPage(state, const TdsReturnsScreen()),
  ),
  GoRoute(
    path: '/tds-certificates',
    pageBuilder: (_, state) => sectionPage(state, const CertificatesScreen()),
  ),
  GoRoute(
    path: '/tds-map',
    pageBuilder: (_, state) => sectionPage(state, const SectionMapScreen()),
  ),
];
