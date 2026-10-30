/// Routes and menu entries of the fixed-asset register (API v1.6 §7).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../compliance/tax_perms.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'fa_detail_screen.dart';
import 'fa_form_screen.dart';
import 'fa_register_screen.dart';

const List<NavEntry> fixedAssetNavEntries = [
  NavEntry(
    path: '/fixed-assets',
    label: 'Fixed assets',
    icon: Icons.business_center_outlined,
    selectedIcon: Icons.business_center,
    permission: TaxPerm.assetsView,
    createPermission: TaxPerm.assetsManage,
  ),
];

List<RouteBase> fixedAssetRoutes() => [
  GoRoute(
    path: '/fixed-assets',
    pageBuilder: (_, state) => sectionPage(state, const FixedAssetsScreen()),
    routes: [
      GoRoute(path: 'new', builder: (_, _) => const FixedAssetFormScreen()),
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            FixedAssetDetailScreen(id: state.pathParameters['id']!),
        routes: [
          GoRoute(
            path: 'edit',
            builder: (_, state) =>
                FixedAssetFormScreen(id: state.pathParameters['id']),
          ),
        ],
      ),
    ],
  ),
];
