/// Routes and menu entries of the GST self-filing kit (API v1.6).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../compliance/tax_perms.dart';
import '../filings/filing_screens.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'gst_filing_screen.dart';
import 'gstr9_screen.dart';
import 'itc_reversals_screen.dart';

const List<NavEntry> gstFilingNavEntries = [
  NavEntry(
    path: '/gst-filing',
    label: 'File GST',
    icon: Icons.task_alt_outlined,
    selectedIcon: Icons.task_alt,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/gst/itc-reversals',
    label: 'ITC reversals',
    icon: Icons.undo_outlined,
    selectedIcon: Icons.undo,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/gst/gstr9',
    label: 'GSTR-9 annual',
    icon: Icons.calendar_view_month_outlined,
    selectedIcon: Icons.calendar_view_month,
    permission: TaxPerm.gstView,
  ),
  NavEntry(
    path: '/filings',
    label: 'Filing register',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: TaxPerm.complianceView,
  ),
];

List<RouteBase> gstFilingRoutes() => [
  GoRoute(
    path: '/gst-filing',
    pageBuilder: (_, state) => sectionPage(state, const GstFilingScreen()),
    routes: [
      GoRoute(
        path: ':period',
        builder: (_, state) =>
            GstFilingScreen(period: state.pathParameters['period']),
      ),
    ],
  ),
  GoRoute(
    path: '/gst/itc-reversals',
    pageBuilder: (_, state) => sectionPage(state, const ItcReversalsScreen()),
  ),
  GoRoute(
    path: '/gst/gstr9',
    pageBuilder: (_, state) => sectionPage(
      state,
      Gstr9Screen(key: queryKey(state), fy: state.uri.queryParameters['fy']),
    ),
  ),
  GoRoute(
    path: '/filings',
    pageBuilder: (_, state) => sectionPage(state, const FilingRegisterScreen()),
    routes: [
      GoRoute(
        path: 'calendar',
        builder: (_, _) => const FilingCalendarScreen(),
      ),
    ],
  ),
];
