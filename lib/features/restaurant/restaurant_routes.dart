/// Routes and menu entries of the restaurant module (API Wave 2: Restaurant).
///
/// Wired in `router.dart` (`...restaurantRoutes()`) and `nav.dart`
/// (`NavGroup('Restaurant', restaurantNavEntries)`, module `restaurant`).
/// `/restaurant` redirects to the floor. The order screen lives at
/// `/restaurant/order/:id` (singular) so it opens for anyone who can take
/// orders without matching the takeaway list entry.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../shell/nav.dart';
import '../shell/routing.dart';
import 'floor_screen.dart';
import 'floor_setup_screen.dart';
import 'kitchen_screen.dart';
import 'menu_setup_screen.dart';
import 'order_screen.dart';
import 'orders_screen.dart';
import 'rest_perms.dart';

/// Menu group "Restaurant", in order. Specific paths come before shorter
/// ones that share a prefix.
const List<NavEntry> restaurantNavEntries = [
  NavEntry(
    path: '/restaurant/floor',
    label: 'Tables',
    icon: Icons.table_restaurant_outlined,
    selectedIcon: Icons.table_restaurant,
    permission: RestPerm.orders,
  ),
  NavEntry(
    path: '/restaurant/orders',
    label: 'Takeaway and delivery',
    icon: Icons.takeout_dining_outlined,
    selectedIcon: Icons.takeout_dining,
    permission: RestPerm.orders,
  ),
  NavEntry(
    path: '/restaurant/kitchen',
    label: 'Kitchen',
    icon: Icons.soup_kitchen_outlined,
    selectedIcon: Icons.soup_kitchen,
    permission: RestPerm.kitchen,
  ),
  NavEntry(
    path: '/restaurant/menu',
    label: 'Menu',
    icon: Icons.restaurant_menu_outlined,
    selectedIcon: Icons.restaurant_menu,
    permission: RestPerm.manage,
  ),
  NavEntry(
    path: '/restaurant/setup',
    label: 'Floor setup',
    icon: Icons.grid_view_outlined,
    selectedIcon: Icons.grid_view,
    permission: RestPerm.manage,
  ),
];

List<RouteBase> restaurantRoutes() => [
  GoRoute(path: '/restaurant', redirect: (_, _) => '/restaurant/floor'),
  GoRoute(
    path: '/restaurant/floor',
    pageBuilder: (_, state) => sectionPage(state, const FloorScreen()),
  ),
  GoRoute(
    path: '/restaurant/orders',
    pageBuilder: (_, state) => sectionPage(state, const OrdersScreen()),
  ),
  GoRoute(
    path: '/restaurant/order/:id',
    builder: (_, state) => OrderScreen(
      key: ValueKey(state.pathParameters['id']),
      orderId: state.pathParameters['id']!,
    ),
  ),
  GoRoute(
    path: '/restaurant/kitchen',
    pageBuilder: (_, state) => sectionPage(state, const KitchenScreen()),
  ),
  GoRoute(
    path: '/restaurant/menu',
    pageBuilder: (_, state) => sectionPage(state, const MenuSetupScreen()),
  ),
  GoRoute(
    path: '/restaurant/setup',
    pageBuilder: (_, state) => sectionPage(state, const FloorSetupScreen()),
  ),
];
