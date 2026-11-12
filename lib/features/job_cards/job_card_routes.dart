/// Routes and menu entries of repair job cards (API Wave 2, module `job_cards`).
///
/// Wired in `router.dart` (`...jobCardRoutes()`) and `nav.dart`
/// (`NavGroup('Job cards', jobCardNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'job_board_screen.dart';
import 'job_detail_screen.dart';
import 'job_form_screen.dart';

const List<NavEntry> jobCardNavEntries = [
  NavEntry(
    path: '/job-cards',
    label: 'Job cards',
    icon: Icons.build_outlined,
    selectedIcon: Icons.build,
    permission: Perm.jobCardsView,
    createPermission: Perm.jobCardsCreate,
  ),
  NavEntry(
    path: '/job-cards/mine',
    label: 'My jobs',
    icon: Icons.engineering_outlined,
    selectedIcon: Icons.engineering,
    permission: Perm.jobCardsWork,
  ),
];

List<RouteBase> jobCardRoutes() => [
  GoRoute(
    path: '/job-cards',
    pageBuilder: (_, state) => sectionPage(state, const JobBoardScreen()),
    routes: [
      GoRoute(
        path: 'mine',
        pageBuilder: (_, state) =>
            sectionPage(state, const JobBoardScreen(mine: true)),
      ),
      GoRoute(path: 'new', builder: (_, _) => const JobFormScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            JobDetailScreen(jobId: state.pathParameters['id']!),
      ),
    ],
  ),
];
