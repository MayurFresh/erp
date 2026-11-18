import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/channels/channels_routes.dart';

import '../support/fake_backend.dart';

const chWidths = [Size(390, 844), Size(1440, 900)];

const channelJson = {
  'id': 'ch1',
  'provider': 'amazon',
  'name': 'Amazon (file import)',
  'status': 'connected',
  'locationId': 'l1',
  'locationName': 'Online Fulfilment',
  'pricesIncludeTax': true,
  'orderStatus': 'confirmed',
  'tcsRate': 0.5,
  'tdsRate': 0.1,
  'listingCount': 3,
  'unmappedCount': 1,
  'orderCounts': {'processed': 4, 'failed': 1},
  'connector': {'stage': 'access_requested', 'note': 'No live connection yet.'},
  'updatedAt': '2026-11-05T10:00:00.000Z',
};

const inboxOk = {
  'id': 'in1',
  'connectionName': 'Amazon (file import)',
  'externalRef': '#1001',
  'status': 'processed',
  'salesOrderId': 'so1',
  'salesOrderNumber': 'SO/26-27/00001',
  'salesOrderStatus': 'confirmed',
  'orderDate': '2026-11-01',
  'total': 236,
  'lines': [
    {'sku': 'AMZ-BOTTLE', 'qty': 2},
  ],
};

const inboxFailed = {
  'id': 'in2',
  'connectionName': 'Amazon (file import)',
  'externalRef': '#1002',
  'status': 'failed',
  'errorCode': 'UNMAPPED_SKU',
  'error': 'Map this SKU to items first: AMZ-NEW.',
  'orderDate': '2026-11-02',
  'lines': [
    {'sku': 'AMZ-NEW', 'qty': 1},
  ],
};

const settlementJson = {
  'id': 'st1',
  'connectionId': 'ch1',
  'connectionName': 'Amazon (file import)',
  'settlementRef': 'SET-1',
  'payoutDate': '2026-11-08',
  'payout': 210.2,
  'linesTotal': 210.2,
  'difference': 0,
  'status': 'matched',
  'orders': [
    {
      'orderRef': '#1001',
      'orderNumber': 'SO/26-27/00001',
      'expected': 236,
      'received': 230,
      'difference': -6,
      'fees': -19.8,
      'matched': true,
    },
    {
      'orderRef': '#9000',
      'expected': null,
      'received': 10,
      'difference': null,
      'fees': 0,
      'matched': false,
    },
  ],
  'totals': {'sale': 240, 'commission': -20, 'tcs': -2},
  'unmatchedOrders': 1,
  'statutory': {
    'taxableValue': 200,
    'tcs': {'rate': 0.5, 'expected': -1, 'received': -2, 'difference': -1},
    'tds': {'rate': 0.1, 'expected': -0.2, 'received': -0.2, 'difference': 0},
    'note': 'Check rates before filing.',
  },
};

/// The v1.9 channel endpoints; everything else goes to the shared backend.
class ChFakeBackend implements HttpClientAdapter {
  ChFakeBackend(Set<String> permissions)
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final List<RequestOptions> calls = [];

  Map<String, Object?> _page(
    List<Object?> d, [
    Map<String, Object?> extra = const {},
  ]) => {'data': d, 'total': d.length, ...extra};

  /// Live channel state for the health screen tests.
  bool shopifyConnected = true;
  bool shopifyPush = false;

  Map<String, Object?> get shopifyHealth => {
    'id': 'sh1',
    'provider': 'shopify',
    'status': shopifyConnected ? 'connected' : 'not_connected',
    'statusReason': 'All good',
    'live': true,
    'hasCredentials': true,
    'credentials': [
      {
        'key': 'shopDomain',
        'label': 'Shop domain',
        'secret': false,
        'set': true,
      },
      {
        'key': 'accessToken',
        'label': 'Access token',
        'secret': true,
        'set': true,
      },
    ],
    'pushStock': shopifyPush,
    'lastCheckAt': '2026-11-10T09:00:00.000Z',
    'lastSuccessAt': '2026-11-10T09:00:00.000Z',
    'lastError': 'Rate limited',
    'lastErrorAt': '2026-11-09T09:00:00.000Z',
    'webhookRejects': 0,
    'inbox': {'received': 2, 'failed': 1, 'dead': 0},
    'unmapped': 3,
    'pushErrors': 0,
    'queuedJobs': 4,
  };

  Object? _live(RequestOptions o) {
    if (!o.path.startsWith('/channels/sh1')) return null;
    final body = o.data is Map ? o.data as Map : const {};
    if (o.method == 'PATCH' && o.path == '/channels/sh1') {
      shopifyPush = body['pushStock'] == true;
      return {'id': 'sh1'};
    }
    return switch ((o.method, o.path)) {
      ('GET', '/channels/sh1/health') => shopifyHealth,
      ('PATCH', '/channels/sh1/credentials') => {'status': 'not_connected'},
      ('DELETE', '/channels/sh1/credentials') => {'status': 'not_connected'},
      ('POST', '/channels/sh1/check') => {
        'ok': true,
        'message': 'Connected to the shop',
        'status': 'connected',
      },
      ('POST', '/channels/sh1/sync') => {'jobId': 'j1'},
      _ => null,
    };
  }

  Object? _route(RequestOptions o) {
    final live = _live(o);
    if (live != null) return live;
    final status = o.queryParameters['status'];
    if (o.method == 'POST') {
      final body = o.data is Map ? o.data as Map : const {};
      return switch (o.path) {
        '/channels/ch1/orders/import' when body['dryRun'] == true => {
          'dryRun': true,
          'issues': [],
          'orders': [
            {
              'externalRef': '#2001',
              'action': 'create',
              'lines': [
                {'itemName': 'Steel bottle', 'qty': 2},
              ],
              'estimate': {'total': 236},
              'unmappedSkus': [],
            },
            {
              'externalRef': '#2002',
              'action': 'blocked',
              'reason': 'Map this SKU to items first: AMZ-NEW.',
              'lines': [],
              'unmappedSkus': ['AMZ-NEW'],
            },
            {
              'externalRef': '#1001',
              'action': 'duplicate',
              'reason': 'This order id was imported before.',
              'lines': [],
              'unmappedSkus': [],
            },
          ],
          'summary': {
            'total': 3,
            'create': 1,
            'duplicate': 1,
            'cancel': 0,
            'ignored': 0,
            'blocked': 1,
          },
        },
        '/channels/ch1/orders/import' => {
          'dryRun': false,
          'issues': [],
          'summary': {
            'total': 3,
            'created': 1,
            'duplicates': 1,
            'cancelled': 0,
            'ignored': 0,
            'failed': 1,
            'heldAsDraft': 0,
          },
        },
        '/channels/settlements/st1/post' => {
          ...settlementJson,
          'status': 'posted',
        },
        '/channels/inbox/in2/retry' => {'result': {}},
        _ => null,
      };
    }
    if (o.method != 'GET') return null;
    return switch (o.path) {
      '/channels' => _page([channelJson]),
      '/channels/ch1/listings' => _page([
        {
          'id': 'li1',
          'channelSku': 'AMZ-BOTTLE',
          'components': [
            {'itemId': 'i1', 'itemName': 'Steel bottle', 'qty': 1},
          ],
        },
        {
          'id': 'li2',
          'channelSku': 'AMZ-ECO-COMBO',
          'components': [
            {'itemId': 'i1', 'itemName': 'Steel bottle', 'qty': 1},
            {'itemId': 'i2', 'itemName': 'Bamboo toothbrush pack', 'qty': 2},
          ],
        },
      ]),
      '/channels/ch1/unmapped' => _page([
        {'channelSku': 'AMZ-NEW', 'title': 'New listing', 'seenCount': 2},
      ]),
      '/channels/inbox' => _page(
        status == 'failed' ? [inboxFailed] : [inboxOk, inboxFailed],
        {
          'counts': {'processed': 1, 'failed': 1},
        },
      ),
      '/channels/settlements' => _page([settlementJson]),
      '/channels/settlements/st1' => settlementJson,
      _ => null,
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    final body = _route(options);
    if (body == null) return _core.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString(
      jsonEncode(body),
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  @override
  void close({bool force = false}) {}
}

class ChHarness {
  ChHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final ChFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<ChHarness> bootCh(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  String initial = '/channels',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms =
      permissions ??
      {
        ...FakeBackend.allPermissions,
        'channels.view',
        'channels.manage',
        'settlements.manage',
      };
  final backend = ChFakeBackend(perms);
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          appBar: AppBar(title: const Text('OneMatrix')),
          body: child,
        ),
        routes: channelsRoutes(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        apiClientProvider.overrideWithValue(api),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return ChHarness(tester, router, backend);
}
