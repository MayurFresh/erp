/// Routes and menu entries of the v1.8 procure-to-pay pack: purchase orders,
/// goods receipts, bills from receipts, reorder suggestions and stock counts.
///
/// Wire-up (lead engineer): add `...purchasingRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart`, and add `purchasingNavEntries`
/// to a group in `nav.dart` (or [purchaseOrderNavEntry] and
/// [stockPlanningNavEntries] separately).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import '../stock_counts/stock_count_screen.dart';
import '../stock_counts/stock_counts_screen.dart';
import 'bill_from_grn_screen.dart';
import 'po_detail_screen.dart';
import 'po_form_screen.dart';
import 'purchase_orders_screen.dart';
import 'receive_goods_screen.dart';
import 'reorder_screen.dart';

/// Sits at the top of the Purchases group.
const NavEntry purchaseOrderNavEntry = NavEntry(
  path: '/purchase-orders',
  label: 'Purchase orders',
  icon: Icons.assignment_outlined,
  selectedIcon: Icons.assignment,
  permission: Perm.purchaseOrdersView,
  createPermission: Perm.purchaseOrdersManage,
);

/// Sit at the end of the Inventory group.
const List<NavEntry> stockPlanningNavEntries = [
  NavEntry(
    path: '/reorder',
    label: 'Reorder list',
    icon: Icons.add_shopping_cart_outlined,
    selectedIcon: Icons.add_shopping_cart,
    permission: Perm.purchaseOrdersView,
  ),
  NavEntry(
    path: '/stock-counts',
    label: 'Stock counts',
    icon: Icons.fact_check_outlined,
    selectedIcon: Icons.fact_check,
    permission: Perm.stockView,
  ),
];

const List<NavEntry> purchasingNavEntries = [
  purchaseOrderNavEntry,
  ...stockPlanningNavEntries,
];

List<RouteBase> purchasingRoutes() => [
  GoRoute(
    path: '/purchase-orders',
    pageBuilder: (_, state) => sectionPage(state, const PurchaseOrdersScreen()),
    routes: [
      GoRoute(
        path: 'new',
        pageBuilder: (_, state) => sectionPage(
          state,
          PoFormScreen(
            key: queryKey(state),
            initialPartyId: state.uri.queryParameters['partyId'],
          ),
        ),
      ),
      GoRoute(
        path: 'receipts/:grnId/bill',
        pageBuilder: (_, state) => sectionPage(
          state,
          BillFromGrnScreen(grnId: state.pathParameters['grnId']!),
        ),
      ),
      GoRoute(
        path: ':id',
        pageBuilder: (_, state) => sectionPage(
          state,
          PoDetailScreen(poId: state.pathParameters['id']!),
        ),
        routes: [
          GoRoute(
            path: 'edit',
            pageBuilder: (_, state) => sectionPage(
              state,
              PoFormScreen(poId: state.pathParameters['id']!),
            ),
          ),
          GoRoute(
            path: 'receive',
            pageBuilder: (_, state) => sectionPage(
              state,
              ReceiveGoodsScreen(poId: state.pathParameters['id']!),
            ),
          ),
        ],
      ),
    ],
  ),
  GoRoute(
    path: '/reorder',
    pageBuilder: (_, state) => sectionPage(state, const ReorderScreen()),
  ),
  GoRoute(
    path: '/stock-counts',
    pageBuilder: (_, state) => sectionPage(state, const StockCountsScreen()),
    routes: [
      GoRoute(
        path: ':id',
        pageBuilder: (_, state) => sectionPage(
          state,
          StockCountScreen(
            key: ValueKey(state.pathParameters['id']),
            countId: state.pathParameters['id']!,
          ),
        ),
      ),
    ],
  ),
];
