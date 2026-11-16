/// Routes, menu entries and the search field of platform extras: global
/// search, scheduled report emails, SMS settings and online payment links.
///
/// Wire-up (lead engineer):
/// - add `...platformExtrasRoutes()` to the authenticated `ShellRoute` in
///   `router.dart`;
/// - add `platformExtrasNavEntries` to a group in `nav.dart` (Reports for the
///   schedules, Settings for SMS and online payments, Sales for the links);
/// - put `const GlobalSearchField()` in the app bar (press "/" to focus it).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'payment_gateway_screens.dart';
import 'scheduled_report_screens.dart';
import 'search_screen.dart';
import 'sms_settings_screen.dart';

export 'search_screen.dart' show GlobalSearchField;

const NavEntry scheduledReportsNavEntry = NavEntry(
  path: '/scheduled-reports',
  label: 'Scheduled reports',
  icon: Icons.schedule_send_outlined,
  selectedIcon: Icons.schedule_send,
  permission: Perm.reportsView,
);

const NavEntry paymentLinksNavEntry = NavEntry(
  path: '/payment-links',
  label: 'Payment links',
  icon: Icons.link_outlined,
  selectedIcon: Icons.link,
  permission: Perm.paymentsView,
);

const NavEntry onlinePaymentsNavEntry = NavEntry(
  path: '/settings/payment-gateway',
  label: 'Online payments',
  icon: Icons.qr_code_2_outlined,
  selectedIcon: Icons.qr_code_2,
  permission: Perm.integrationsManage,
);

const NavEntry smsNavEntry = NavEntry(
  path: '/settings/sms',
  label: 'SMS',
  icon: Icons.sms_outlined,
  selectedIcon: Icons.sms,
  permission: Perm.integrationsManage,
);

const List<NavEntry> platformExtrasNavEntries = [
  scheduledReportsNavEntry,
  paymentLinksNavEntry,
  onlinePaymentsNavEntry,
  smsNavEntry,
];

List<RouteBase> platformExtrasRoutes() => [
  GoRoute(
    path: '/search',
    pageBuilder: (c, s) => sectionPage(
      s,
      SearchScreen(
        key: ValueKey(s.uri.queryParameters['q']),
        initialQuery: s.uri.queryParameters['q'] ?? '',
      ),
    ),
  ),
  GoRoute(
    path: '/scheduled-reports',
    pageBuilder: (c, s) => sectionPage(s, const ScheduledReportsScreen()),
  ),
  // Static segment before ':id' so "new" is not read as an id.
  GoRoute(
    path: '/scheduled-reports/new',
    pageBuilder: (c, s) => sectionPage(s, const ScheduledReportFormScreen()),
  ),
  GoRoute(
    path: '/scheduled-reports/:id',
    pageBuilder: (c, s) =>
        sectionPage(s, ScheduledReportFormScreen(id: s.pathParameters['id'])),
  ),
  GoRoute(
    path: '/payment-links',
    pageBuilder: (c, s) => sectionPage(s, const PaymentLinksScreen()),
  ),
  GoRoute(
    path: '/settings/payment-gateway',
    pageBuilder: (c, s) => sectionPage(s, const PaymentGatewayScreen()),
  ),
  GoRoute(
    path: '/settings/sms',
    pageBuilder: (c, s) => sectionPage(s, const SmsSettingsScreen()),
  ),
];
