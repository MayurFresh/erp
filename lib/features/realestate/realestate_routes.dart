/// Routes and menu entries of the real-estate pack (API v1.3).
///
/// Wire-up (lead engineer): add `...realEstateRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart`, and
/// `NavGroup('Real estate', realEstateNavEntries)` to `navGroups` in
/// `nav.dart`. `<path>` needs [NavEntry.permission]; `<path>/new` needs
/// [NavEntry.createPermission].
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../shell/nav.dart';
import '../shell/routing.dart';
import 'booking_detail_screen.dart';
import 'booking_form_screen.dart';
import 'bookings_screen.dart';
import 'demand_detail_screen.dart';
import 'demands_screen.dart';
import 'payment_plans_screen.dart';
import 're_perms.dart';
import 'rera_screen.dart';
import 'units_screen.dart';

/// Menu group "Real estate", in order.
const List<NavEntry> realEstateNavEntries = [
  NavEntry(
    path: '/units',
    label: 'Units',
    icon: Icons.meeting_room_outlined,
    selectedIcon: Icons.meeting_room,
    permission: RePerm.unitsView,
    createPermission: RePerm.unitsManage,
  ),
  NavEntry(
    path: '/payment-plans',
    label: 'Payment plans',
    icon: Icons.schedule_outlined,
    selectedIcon: Icons.schedule,
    permission: RePerm.unitsView,
    createPermission: RePerm.unitsManage,
  ),
  NavEntry(
    path: '/bookings',
    label: 'Bookings',
    icon: Icons.event_available_outlined,
    selectedIcon: Icons.event_available,
    permission: RePerm.bookingsView,
    createPermission: RePerm.bookingsManage,
  ),
  NavEntry(
    path: '/demands',
    label: 'Demands',
    icon: Icons.markunread_mailbox_outlined,
    selectedIcon: Icons.markunread_mailbox,
    permission: RePerm.bookingsView,
  ),
  NavEntry(
    path: '/rera',
    label: 'RERA account',
    icon: Icons.account_balance_outlined,
    selectedIcon: Icons.account_balance,
    permission: RePerm.bookingsView,
  ),
];

List<RouteBase> realEstateRoutes() => [
  GoRoute(
    path: '/units',
    pageBuilder: (_, state) => sectionPage(
      state,
      UnitsScreen(
        key: queryKey(state),
        initialProjectId: state.uri.queryParameters['projectId'],
      ),
    ),
  ),
  GoRoute(
    path: '/payment-plans',
    pageBuilder: (_, state) => sectionPage(state, const PaymentPlansScreen()),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const PlanFormScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            PlanFormScreen(planId: state.pathParameters['id']),
      ),
    ],
  ),
  GoRoute(
    path: '/bookings',
    pageBuilder: (_, state) => sectionPage(state, const BookingsScreen()),
    routes: [
      GoRoute(
        path: 'new',
        builder: (_, state) => BookingFormScreen(
          key: queryKey(state),
          unitId: state.uri.queryParameters['unitId'],
        ),
      ),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            BookingDetailScreen(bookingId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/demands',
    pageBuilder: (_, state) => sectionPage(state, const DemandsScreen()),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            DemandDetailScreen(demandId: state.pathParameters['id']!),
      ),
    ],
  ),
  GoRoute(
    path: '/rera',
    pageBuilder: (_, state) => sectionPage(state, const ReraScreen()),
  ),
];
