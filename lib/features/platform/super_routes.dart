/// Platform super admin screens (API "Platform super admin" section).
///
/// Wired into `router.dart` (`...superAdminRoutes()` in the shell) and
/// `nav.dart` (first group, "Platform"). Everything here needs the client-side
/// permission [Perm.platformAdmin], which `SessionState.permissions` adds when
/// `GET /me` says `isPlatformAdmin`. The server checks again on every call.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'super_account_detail_screen.dart';
import 'super_accounts_screen.dart';
import 'super_activity_screen.dart';
import 'super_overview_screen.dart';

const List<NavEntry> superAdminNavEntries = [
  NavEntry(
    path: '/platform/overview',
    label: 'Overview',
    icon: Icons.insights_outlined,
    selectedIcon: Icons.insights,
    permission: Perm.platformAdmin,
  ),
  NavEntry(
    path: '/platform/accounts',
    label: 'Accounts',
    icon: Icons.domain_outlined,
    selectedIcon: Icons.domain,
    permission: Perm.platformAdmin,
  ),
  NavEntry(
    path: '/platform/activity',
    label: 'Activity',
    icon: Icons.history_outlined,
    selectedIcon: Icons.history,
    permission: Perm.platformAdmin,
  ),
];

List<RouteBase> superAdminRoutes() => [
  GoRoute(
    path: '/platform/overview',
    pageBuilder: (_, state) => sectionPage(state, const SuperOverviewScreen()),
  ),
  GoRoute(
    path: '/platform/accounts',
    pageBuilder: (_, state) => sectionPage(
      state,
      SuperAccountsScreen(
        key: queryKey(state),
        initialStatus: state.uri.queryParameters['status'],
      ),
    ),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            SuperAccountDetailScreen(tenantId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/platform/activity',
    pageBuilder: (_, state) => sectionPage(state, const SuperActivityScreen()),
  ),
];
