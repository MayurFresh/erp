/// Routes and menu entries of online channels (API v1.9).
library;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../shell/nav.dart';
import '../shell/routing.dart';
import 'channels_perms.dart';
import 'channels_screen.dart';
import 'health_screen.dart';
import 'import_screen.dart';
import 'mapping_screen.dart';
import 'orders_screen.dart';
import 'settlements_screen.dart';

/// Menu group "Online channels", in order.
const List<NavEntry> channelsNavEntries = [
  NavEntry(
    path: '/channels',
    label: 'Channels',
    icon: Icons.storefront_outlined,
    selectedIcon: Icons.storefront,
    permission: ChPerm.view,
    createPermission: ChPerm.manage,
  ),
  NavEntry(
    path: '/channels/orders',
    label: 'Channel orders',
    icon: Icons.shopping_bag_outlined,
    selectedIcon: Icons.shopping_bag,
    permission: ChPerm.view,
  ),
  NavEntry(
    path: '/channels/import',
    label: 'Import orders',
    icon: Icons.upload_file_outlined,
    selectedIcon: Icons.upload_file,
    permission: ChPerm.manage,
  ),
  NavEntry(
    path: '/channels/mapping',
    label: 'SKU mapping',
    icon: Icons.link_outlined,
    selectedIcon: Icons.link,
    permission: ChPerm.view,
  ),
  NavEntry(
    path: '/channels/settlements',
    label: 'Settlements',
    icon: Icons.account_balance_wallet_outlined,
    selectedIcon: Icons.account_balance_wallet,
    permission: ChPerm.view,
  ),
];

List<RouteBase> channelsRoutes() => [
  GoRoute(
    path: '/channels',
    pageBuilder: (_, state) => sectionPage(state, const ChannelsScreen()),
  ),
  GoRoute(
    path: '/channels/:id/health',
    pageBuilder: (_, state) => sectionPage(
      state,
      ChannelHealthScreen(channelId: state.pathParameters['id']!),
    ),
  ),
  GoRoute(
    path: '/channels/orders',
    pageBuilder: (_, state) => sectionPage(
      state,
      ChannelOrdersScreen(
        key: queryKey(state),
        channelId: state.uri.queryParameters['channelId'],
      ),
    ),
  ),
  GoRoute(
    path: '/channels/import',
    pageBuilder: (_, state) => sectionPage(
      state,
      ChannelImportScreen(
        key: queryKey(state),
        channelId: state.uri.queryParameters['channelId'],
      ),
    ),
  ),
  GoRoute(
    path: '/channels/mapping',
    pageBuilder: (_, state) => sectionPage(
      state,
      SkuMappingScreen(
        key: queryKey(state),
        channelId: state.uri.queryParameters['channelId'],
      ),
    ),
  ),
  GoRoute(
    path: '/channels/settlements',
    pageBuilder: (_, state) => sectionPage(state, const SettlementsScreen()),
    routes: [
      GoRoute(
        path: ':id',
        builder: (_, state) =>
            SettlementScreen(settlementId: state.pathParameters['id']!),
      ),
    ],
  ),
];
