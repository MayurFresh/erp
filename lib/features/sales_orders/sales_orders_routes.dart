/// Routes and menu entries of v1.8 order to cash: sales orders, pick lists,
/// packing, shipments and sales returns.
///
/// Wire-up (lead engineer): add `...salesOrderRoutes()` to the routes of the
/// authenticated `ShellRoute` in `router.dart`, and `salesNavEntries` to a
/// group in `nav.dart` (or [salesOrderNavEntry] and [fulfilmentNavEntries]
/// separately).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../fulfilment/pack_screen.dart';
import '../fulfilment/pick_lists_screen.dart';
import '../fulfilment/shipments_screens.dart';
import '../returns/return_create_screen.dart';
import '../returns/return_detail_screen.dart';
import '../returns/returns_screen.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'sales_order_detail_screen.dart';
import 'sales_order_form_screen.dart';
import 'sales_orders_screen.dart';

/// Sits at the top of the Sales group.
const NavEntry salesOrderNavEntry = NavEntry(
  path: '/sales-orders',
  label: 'Sales orders',
  icon: Icons.shopping_bag_outlined,
  selectedIcon: Icons.shopping_bag,
  permission: Perm.salesOrdersView,
  createPermission: Perm.salesOrdersManage,
);

/// The Fulfilment group: warehouse and delivery work after an order is confirmed.
const List<NavEntry> fulfilmentNavEntries = [
  NavEntry(
    path: '/pick-lists',
    label: 'Pick lists',
    icon: Icons.list_alt_outlined,
    selectedIcon: Icons.list_alt,
    permission: Perm.salesOrdersView,
  ),
  NavEntry(
    path: '/shipments',
    label: 'Shipments',
    icon: Icons.local_shipping_outlined,
    selectedIcon: Icons.local_shipping,
    permission: Perm.salesOrdersView,
  ),
  NavEntry(
    path: '/sales-returns',
    label: 'Sales returns',
    icon: Icons.undo_outlined,
    selectedIcon: Icons.undo,
    permission: Perm.salesOrdersView,
    createPermission: Perm.returnsManage,
  ),
];

const List<NavEntry> salesNavEntries = [
  salesOrderNavEntry,
  ...fulfilmentNavEntries,
];

List<RouteBase> salesOrderRoutes() => [
  GoRoute(
    path: '/sales-orders',
    pageBuilder: (c, s) => sectionPage(s, const SalesOrdersScreen()),
  ),
  // Static segments before ':id' so "new" is not read as an id.
  GoRoute(
    path: '/sales-orders/new',
    pageBuilder: (c, s) => sectionPage(s, const SalesOrderFormScreen()),
  ),
  GoRoute(
    path: '/sales-orders/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      SalesOrderDetailScreen(orderId: s.pathParameters['id']!),
    ),
  ),
  GoRoute(
    path: '/sales-orders/:id/edit',
    pageBuilder: (c, s) =>
        sectionPage(s, SalesOrderFormScreen(orderId: s.pathParameters['id'])),
  ),
  GoRoute(
    path: '/sales-orders/:id/pack',
    pageBuilder: (c, s) =>
        sectionPage(s, PackScreen(orderId: s.pathParameters['id']!)),
  ),
  GoRoute(
    path: '/pick-lists',
    pageBuilder: (c, s) => sectionPage(s, const PickListsScreen()),
  ),
  GoRoute(
    path: '/pick-lists/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      PickListDetailScreen(pickListId: s.pathParameters['id']!),
    ),
  ),
  GoRoute(
    path: '/shipments',
    pageBuilder: (c, s) => sectionPage(s, const ShipmentsScreen()),
  ),
  GoRoute(
    path: '/shipments/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      ShipmentDetailScreen(shipmentId: s.pathParameters['id']!),
    ),
  ),
  GoRoute(
    path: '/sales-returns',
    pageBuilder: (c, s) => sectionPage(s, const ReturnsScreen()),
  ),
  GoRoute(
    path: '/sales-returns/new',
    pageBuilder: (c, s) => sectionPage(
      s,
      ReturnCreateScreen(orderId: s.uri.queryParameters['orderId']),
    ),
  ),
  GoRoute(
    path: '/sales-returns/:id',
    pageBuilder: (c, s) =>
        sectionPage(s, ReturnDetailScreen(returnId: s.pathParameters['id']!)),
  ),
];
