/// Routes and menu entries of the legal practice pack (API Wave 2, module
/// `legal`).
///
/// Wired in `router.dart` (`...legalRoutes()`) and `nav.dart`
/// (`NavGroup('Legal practice', legalNavEntries)`).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'legal_home_screen.dart';
import 'legal_rates_screen.dart';
import 'matter_screen.dart';
import 'matters_screen.dart';

const List<NavEntry> legalNavEntries = [
  NavEntry(
    path: '/legal',
    label: 'Court diary',
    icon: Icons.event_note_outlined,
    selectedIcon: Icons.event_note,
    permission: Perm.legalView,
  ),
  NavEntry(
    path: '/legal/matters',
    label: 'Matters',
    icon: Icons.gavel_outlined,
    selectedIcon: Icons.gavel,
    permission: Perm.legalView,
  ),
  NavEntry(
    path: '/legal/rates',
    label: 'Rate card',
    icon: Icons.price_change_outlined,
    selectedIcon: Icons.price_change,
    permission: Perm.legalManage,
  ),
];

List<RouteBase> legalRoutes() => [
  GoRoute(
    path: '/legal',
    pageBuilder: (_, state) => sectionPage(state, const LegalHomeScreen()),
    routes: [
      GoRoute(
        path: 'rates',
        pageBuilder: (_, state) => sectionPage(state, const LegalRatesScreen()),
      ),
      GoRoute(
        path: 'matters',
        pageBuilder: (_, state) => sectionPage(state, const MattersScreen()),
        routes: [
          GoRoute(
            path: ':id',
            builder: (_, state) =>
                MatterScreen(matterId: state.pathParameters['id']!),
          ),
        ],
      ),
    ],
  ),
];
