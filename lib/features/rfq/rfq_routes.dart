/// Routes and menu entry for requests for quotation.
///
/// Wire-up (lead engineer): add `...rfqRoutes()` to the authenticated
/// `ShellRoute` in `router.dart` and [rfqNavEntry] to the Purchases group in
/// `nav.dart`, next to purchase orders.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'rfq_form_screen.dart';
import 'rfq_screens.dart';

const NavEntry rfqNavEntry = NavEntry(
  path: '/rfqs',
  label: 'Quotation requests',
  icon: Icons.request_quote_outlined,
  selectedIcon: Icons.request_quote,
  permission: Perm.purchaseOrdersView,
  createPermission: Perm.purchaseOrdersManage,
);

List<RouteBase> rfqRoutes() => [
  GoRoute(
    path: '/rfqs',
    pageBuilder: (_, state) => sectionPage(state, const RfqsScreen()),
    routes: [
      GoRoute(
        path: 'new',
        pageBuilder: (_, state) => sectionPage(state, const RfqFormScreen()),
      ),
      GoRoute(
        path: ':id',
        pageBuilder: (_, state) => sectionPage(
          state,
          RfqDetailScreen(rfqId: state.pathParameters['id']!),
        ),
        routes: [
          GoRoute(
            path: 'edit',
            pageBuilder: (_, state) => sectionPage(
              state,
              RfqFormScreen(
                key: ValueKey(state.pathParameters['id']),
                rfqId: state.pathParameters['id'],
              ),
            ),
          ),
        ],
      ),
    ],
  ),
];
