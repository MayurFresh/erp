/// Routes and menu entry of v1.14 purchase returns (debit notes).
///
/// Wire-up (lead engineer): add `...purchaseReturnRoutes()` to the routes of
/// the authenticated `ShellRoute` in `router.dart`, and
/// [purchaseReturnNavEntry] to the Purchases group in `nav.dart`.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'purchase_return_create_screen.dart';
import 'purchase_return_detail_screen.dart';
import 'purchase_returns_screen.dart';

const NavEntry purchaseReturnNavEntry = NavEntry(
  path: '/purchase-returns',
  label: 'Debit notes',
  icon: Icons.assignment_return_outlined,
  selectedIcon: Icons.assignment_return,
  permission: Perm.purchasesView,
  createPermission: Perm.purchasesCreate,
);

List<RouteBase> purchaseReturnRoutes() => [
  GoRoute(
    path: '/purchase-returns',
    pageBuilder: (c, s) => sectionPage(s, const PurchaseReturnsScreen()),
  ),
  // Static segment before ':id' so "new" is not read as an id.
  GoRoute(
    path: '/purchase-returns/new',
    pageBuilder: (c, s) => sectionPage(
      s,
      PurchaseReturnCreateScreen(
        initialPurchaseId: s.uri.queryParameters['purchaseId'],
      ),
    ),
  ),
  GoRoute(
    path: '/purchase-returns/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      PurchaseReturnDetailScreen(returnId: s.pathParameters['id']!),
    ),
  ),
];
