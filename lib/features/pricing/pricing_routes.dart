/// Routes and menu entries of price lists, customer prices and schemes.
///
/// Wire-up (lead engineer): add `...pricingRoutes()` to the authenticated
/// `ShellRoute` in `router.dart` and [priceListNavEntry] to the Sales (or
/// Items) group in `nav.dart`. The schemes screen is reached from the price
/// lists page; [schemeNavEntry] is optional.
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../shell/nav.dart';
import '../shell/routing.dart';
import 'customer_prices_screen.dart';
import 'price_list_form_screen.dart';
import 'price_lists_screen.dart';
import 'price_schemes_screen.dart';

const NavEntry priceListNavEntry = NavEntry(
  path: '/price-lists',
  label: 'Price lists',
  icon: Icons.sell_outlined,
  selectedIcon: Icons.sell,
  permission: Perm.itemsView,
  createPermission: Perm.pricingManage,
);

const NavEntry schemeNavEntry = NavEntry(
  path: '/price-schemes',
  label: 'Schemes',
  icon: Icons.local_offer_outlined,
  selectedIcon: Icons.local_offer,
  permission: Perm.itemsView,
  createPermission: Perm.pricingManage,
);

List<RouteBase> pricingRoutes() => [
  GoRoute(
    path: '/price-lists',
    pageBuilder: (c, s) => sectionPage(s, const PriceListsScreen()),
  ),
  // Static segments before ':id' so "new" is not read as an id.
  GoRoute(
    path: '/price-lists/new',
    pageBuilder: (c, s) => sectionPage(s, const PriceListFormScreen()),
  ),
  GoRoute(
    path: '/price-lists/:id',
    pageBuilder: (c, s) => sectionPage(
      s,
      PriceListFormScreen(listId: s.pathParameters['id']),
    ),
  ),
  GoRoute(
    path: '/price-schemes',
    pageBuilder: (c, s) => sectionPage(s, const PriceSchemesScreen()),
  ),
  GoRoute(
    path: '/customer-prices/:partyId',
    pageBuilder: (c, s) => sectionPage(
      s,
      CustomerPricesScreen(partyId: s.pathParameters['partyId']!),
    ),
  ),
];
