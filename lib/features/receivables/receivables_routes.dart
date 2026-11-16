/// Routes and menu entries of statements, payment reminders and recurring
/// invoices (API v1.14).
///
/// Wire-up (lead engineer): add `...receivablesRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart`, and `receivablesNavEntries` to
/// a group in `nav.dart` (Sales or Accounts).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'recurring_screens.dart';
import 'reminder_screens.dart';
import 'statement_screen.dart';

const List<NavEntry> receivablesNavEntries = [
  NavEntry(
    path: '/recurring-invoices',
    label: 'Repeat invoices',
    icon: Icons.event_repeat_outlined,
    selectedIcon: Icons.event_repeat,
    permission: Perm.invoicesView,
    createPermission: Perm.invoicesCreate,
  ),
  NavEntry(
    path: '/reminders',
    label: 'Payment reminders',
    icon: Icons.notifications_active_outlined,
    selectedIcon: Icons.notifications_active,
    permission: Perm.paymentsView,
    createPermission: Perm.paymentsCreate,
  ),
];

List<RouteBase> receivablesRoutes() => [
  GoRoute(
    path: '/parties/:id/statement',
    pageBuilder: (c, s) =>
        sectionPage(s, StatementScreen(partyId: s.pathParameters['id']!)),
  ),
  GoRoute(
    path: '/recurring-invoices',
    pageBuilder: (c, s) => sectionPage(s, const RecurringListScreen()),
  ),
  // Static segments before ':id' so "new" is not read as an id.
  GoRoute(
    path: '/recurring-invoices/new',
    pageBuilder: (c, s) => sectionPage(s, const RecurringFormScreen()),
  ),
  GoRoute(
    path: '/recurring-invoices/:id',
    pageBuilder: (c, s) =>
        sectionPage(s, RecurringDetailScreen(id: s.pathParameters['id']!)),
  ),
  GoRoute(
    path: '/recurring-invoices/:id/edit',
    pageBuilder: (c, s) =>
        sectionPage(s, RecurringFormScreen(id: s.pathParameters['id'])),
  ),
  GoRoute(
    path: '/reminders',
    pageBuilder: (c, s) => sectionPage(s, const ReminderSettingsScreen()),
  ),
  GoRoute(
    path: '/reminders/log',
    pageBuilder: (c, s) => sectionPage(s, const ReminderLogScreen()),
  ),
];
