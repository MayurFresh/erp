/// Routes and menu entries of the enterprise platform (API v1.7).
///
/// Wire-up (lead engineer), in `router.dart`:
///  * `...platformRoutes()` inside the authenticated `ShellRoute`;
///  * `...platformOpenRoutes()` at top level, next to /login;
///  * `/login`, `/signup`, `/forgot-password`, `/reset-password`,
///    `/sso/callback` and `/sso/done` are public auth pages in
///    `sessionRedirect`.
/// In `nav.dart`, add `...platformNavEntries` to Administration.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../auth/forgot_password_screen.dart';
import '../auth/reset_password_screen.dart';
import '../auth/sso_callback_screen.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'admin_security_screens.dart';
import 'companies_screens.dart';
import 'gsp_screens.dart';
import 'notifications_screen.dart';
import 'security_screen.dart';

const List<NavEntry> platformNavEntries = [
  NavEntry(
    path: '/companies',
    label: 'Companies',
    icon: Icons.business_outlined,
    selectedIcon: Icons.business,
    permission: Perm.accountsView,
    createPermission: Perm.companiesCreate,
  ),
  NavEntry(
    path: '/intercompany',
    label: 'Inter-company',
    icon: Icons.swap_horiz_outlined,
    selectedIcon: Icons.swap_horiz,
    permission: Perm.accountsView,
    createPermission: Perm.accountsJournal,
  ),
  NavEntry(
    path: '/consolidated',
    label: 'Consolidated',
    icon: Icons.stacked_line_chart_outlined,
    selectedIcon: Icons.stacked_line_chart,
    permission: Perm.accountsView,
  ),
  NavEntry(
    path: '/security',
    label: 'Security and SSO',
    icon: Icons.security_outlined,
    selectedIcon: Icons.security,
    permission: Perm.securityManage,
    createPermission: Perm.securityManage,
  ),
  NavEntry(
    path: '/jobs',
    label: 'Background jobs',
    icon: Icons.work_history_outlined,
    selectedIcon: Icons.work_history,
    permission: Perm.companyManage,
  ),
  NavEntry(
    path: '/outbox',
    label: 'Notification outbox',
    icon: Icons.outbox_outlined,
    selectedIcon: Icons.outbox,
    permission: Perm.companyManage,
  ),
  NavEntry(
    path: '/gsp-settings',
    label: 'GST provider',
    icon: Icons.cloud_sync_outlined,
    selectedIcon: Icons.cloud_sync,
    permission: 'einvoice.manage',
  ),
];

GoRoute _page(String path, Widget Function(GoRouterState) build) => GoRoute(
  path: path,
  pageBuilder: (_, state) => sectionPage(state, build(state)),
);

List<RouteBase> platformRoutes() => [
  _page('/account/security', (_) => const AccountSecurityScreen()),
  _page('/notifications', (_) => const NotificationsScreen()),
  _page('/companies', (_) => const CompaniesScreen()),
  _page('/companies/new', (_) => const CompanyCreateScreen()),
  _page('/intercompany', (_) => const IntercompanyScreen()),
  _page('/intercompany/new', (_) => const IntercompanyCreateScreen()),
  _page('/consolidated', (_) => const ConsolidatedScreen()),
  _page('/security', (_) => const SecurityAdminScreen()),
  _page('/security/new', (_) => const SsoProviderEditScreen()),
  _page(
    '/security/:id',
    (s) => SsoProviderEditScreen(
      key: ValueKey(s.pathParameters['id']),
      providerId: s.pathParameters['id'],
    ),
  ),
  _page('/jobs', (_) => const JobsScreen()),
  _page('/outbox', (_) => const OutboxScreen()),
  _page('/gsp-settings', (_) => const GspSettingsScreen()),
];

List<RouteBase> platformOpenRoutes() => [
  GoRoute(
    path: '/forgot-password',
    builder: (_, _) => const ForgotPasswordScreen(),
  ),
  GoRoute(
    path: '/reset-password',
    builder: (_, state) =>
        ResetPasswordScreen(token: state.uri.queryParameters['token'] ?? ''),
  ),
  for (final p in const ['/sso/callback', '/sso/done'])
    GoRoute(
      path: p,
      builder: (_, state) =>
          SsoCallbackScreen(ticket: state.uri.queryParameters['ticket'] ?? ''),
    ),
];
