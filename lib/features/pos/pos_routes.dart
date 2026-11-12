/// Counter billing (POS): routes and menu entries.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'pos_screen.dart';
import 'pos_session_screens.dart';

const List<NavEntry> posNavEntries = [
  NavEntry(
    path: '/pos',
    label: 'Counter billing',
    icon: Icons.point_of_sale_outlined,
    selectedIcon: Icons.point_of_sale,
    permission: Perm.posUse,
  ),
  NavEntry(
    path: '/pos/sessions',
    label: 'Register sessions',
    icon: Icons.lock_clock_outlined,
    selectedIcon: Icons.lock_clock,
    permission: Perm.posUse,
  ),
];

List<RouteBase> posRoutes() => [
  GoRoute(
    path: '/pos',
    pageBuilder: (_, state) => sectionPage(state, const PosScreen()),
    routes: [
      GoRoute(
        path: 'sessions',
        pageBuilder: (_, state) =>
            sectionPage(state, const PosSessionsScreen()),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) =>
                PosReportScreen(sessionId: state.pathParameters['id']!),
            routes: [
              GoRoute(
                path: 'close',
                builder: (_, state) =>
                    PosCloseScreen(sessionId: state.pathParameters['id']!),
              ),
            ],
          ),
        ],
      ),
    ],
  ),
];
