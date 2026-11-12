/// Routes and menu entries of memberships (API Wave 2, module `memberships`).
///
/// Wired in `router.dart` (`...membershipRoutes()`) and `nav.dart`
/// (`NavGroup('Memberships', membershipNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'member_file_screen.dart';
import 'memberships_home_screen.dart';
import 'memberships_tools_screens.dart';

const List<NavEntry> membershipNavEntries = [
  NavEntry(
    path: '/memberships',
    label: 'Memberships',
    icon: Icons.card_membership_outlined,
    selectedIcon: Icons.card_membership,
    permission: Perm.membershipsView,
  ),
  NavEntry(
    path: '/memberships/check-in',
    label: 'Check-in',
    icon: Icons.login_outlined,
    selectedIcon: Icons.login,
    permission: Perm.membershipsCheckin,
  ),
  NavEntry(
    path: '/memberships/dues',
    label: 'Dues',
    icon: Icons.payments_outlined,
    selectedIcon: Icons.payments,
    permission: Perm.membershipsView,
  ),
];

List<RouteBase> membershipRoutes() => [
  GoRoute(
    path: '/memberships',
    pageBuilder: (_, state) =>
        sectionPage(state, const MembershipsHomeScreen()),
    routes: [
      GoRoute(
        path: 'check-in',
        pageBuilder: (_, state) => sectionPage(state, const CheckinScreen()),
      ),
      GoRoute(
        path: 'dues',
        pageBuilder: (_, state) => sectionPage(state, const MemDuesScreen()),
      ),
      GoRoute(
        path: 'bills',
        pageBuilder: (_, state) => sectionPage(state, const MemBillsScreen()),
      ),
      GoRoute(
        path: 'plans',
        pageBuilder: (_, state) => sectionPage(state, const MemPlansScreen()),
      ),
      GoRoute(
        path: 'members/:id',
        builder: (_, state) =>
            MemberFileScreen(memberId: state.pathParameters['id']!),
      ),
    ],
  ),
];
