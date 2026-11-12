import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/providers.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/restaurant/rest_repository.dart';
import 'package:progen_erp/features/restaurant/restaurant_routes.dart';

import '../support/fake_backend.dart';

const restPerms = {
  'restaurant.orders',
  'restaurant.kitchen',
  'restaurant.settle',
  'restaurant.manage',
};

Map<String, Object?> _menu(String id, String name, double price, String cat, String diet) => {
  'itemId': id,
  'name': name,
  'price': price,
  'gstRate': 5,
  'categoryId': cat,
  'categoryName': cat == 'c1' ? 'Mains' : 'Drinks',
  'diet': diet,
  'available': true,
  'availableToday': true,
  'station': 'Main',
};

/// Restaurant endpoints with a little state; everything else goes to the
/// shared fake backend.
class RestFakeBackend implements HttpClientAdapter {
  RestFakeBackend(Set<String> permissions) : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final List<RequestOptions> calls = [];

  RequestOptions last(String method, String path) =>
      calls.lastWhere((r) => r.method == method && r.path == path);

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  final menu = [
    _menu('m1', 'Paneer Tikka', 240, 'c1', 'veg'),
    _menu('m2', 'Butter Chicken', 320, 'c1', 'non_veg'),
    _menu('m3', 'Masala Chaas', 60, 'c2', 'veg'),
  ];

  final lines = <Map<String, Object?>>[];
  var sent = false;
  var kotStatus = 'new';

  Map<String, Object?> get order => {
    'id': 'o1',
    'number': 'O261112-001',
    'kind': 'dine_in',
    'status': 'open',
    'tableId': 't1',
    'tableName': 'T1',
    'areaName': 'Ground floor',
    'covers': 2,
    'captain': {'id': 'u1', 'name': 'Owner'},
    'createdAt': DateTime.now().toIso8601String(),
    'lines': lines,
    'kots': sent
        ? [
            {'id': 'k1', 'kotNo': 12, 'station': 'Main', 'status': 'new'},
          ]
        : [],
    'bill': _bill(),
  };

  Map<String, Object?> _bill() {
    final gross = lines.fold<double>(0, (s, l) => s + (l['amount'] as double));
    final tax = gross * 0.05;
    return {
      'lines': [
        for (final l in lines)
          {'name': l['name'], 'qty': l['qty'], 'rate': l['rate'], 'amount': l['amount'], 'gstRate': 5},
      ],
      'gross': gross,
      'taxTotal': tax,
      'total': (gross + tax).roundToDouble(),
      'gstSummary': [],
    };
  }

  Map<String, Object?> get kot => {
    'id': 'k1',
    'kotNo': 12,
    'station': 'Main',
    'status': kotStatus,
    'orderNumber': 'O261112-001',
    'kind': 'dine_in',
    'tableName': 'T1',
    'covers': 2,
    'createdAt': DateTime.now().subtract(const Duration(minutes: 4)).toIso8601String(),
    'lines': [
      {'id': 'l9', 'name': 'PNR TIKKA', 'qty': 2, 'note': 'less spicy', 'state': 'sent', 'kitchenStatus': kotStatus},
      {'id': 'l10', 'name': 'Dal Tadka', 'qty': 1, 'state': 'sent', 'kitchenStatus': kotStatus},
    ],
  };

  Map<String, Object?> _page(List<Object?> d) => {'data': d, 'total': d.length};

  Map<String, Object?> get floor => {
    'areas': [
      {
        'id': 'a1',
        'name': 'Ground floor',
        'sortOrder': 1,
        'isActive': true,
        'tables': [
          {
            'id': 't1', 'areaId': 'a1', 'name': 'T1', 'seats': 4, 'isActive': true, 'status': 'occupied',
            'order': {'id': 'o1', 'number': 'O261112-001', 'covers': 2, 'amount': 650, 'unsentLines': 1, 'readyLines': 0,
              'openedAt': DateTime.now().subtract(const Duration(minutes: 18)).toIso8601String()},
          },
          {'id': 't2', 'areaId': 'a1', 'name': 'T2', 'seats': 2, 'isActive': true, 'status': 'free', 'order': null},
          {
            'id': 't3', 'areaId': 'a1', 'name': 'T3', 'seats': 6, 'isActive': true, 'status': 'bill_printed',
            'order': {'id': 'o3', 'number': 'O261112-002', 'covers': 5, 'amount': 1260, 'unsentLines': 0, 'readyLines': 2,
              'openedAt': DateTime.now().subtract(const Duration(minutes: 70)).toIso8601String()},
          },
        ],
      },
      {
        'id': 'a2',
        'name': 'Terrace',
        'sortOrder': 2,
        'isActive': true,
        'tables': [
          {'id': 't4', 'areaId': 'a2', 'name': 'R1', 'seats': 4, 'isActive': true, 'status': 'free', 'order': null},
        ],
      },
    ],
  };

  Map<String, Object?>? _body(RequestOptions o) {
    final data = o.data;
    return data is Map ? data.cast<String, Object?>() : null;
  }

  (int, Object?)? _route(RequestOptions o) {
    final key = '${o.method} ${o.path}';
    switch (key) {
      case 'GET /restaurant/floor':
        return (200, floor);
      case 'GET /restaurant/menu':
        return (200, _page(menu));
      case 'GET /restaurant/categories':
        return (200, _page([
          {'id': 'c1', 'name': 'Mains', 'sortOrder': 1, 'isActive': true},
          {'id': 'c2', 'name': 'Drinks', 'sortOrder': 2, 'isActive': true},
        ]));
      case 'GET /restaurant/settings':
        return (200, {'serviceChargePct': 5, 'serviceChargeGst': 5, 'locationId': null, 'stations': ['Bar', 'Main']});
      case 'GET /restaurant/orders/o1':
        return (200, order);
      case 'POST /restaurant/orders/o1/lines':
        final items = (_body(o)!['items'] as List).cast<Map>();
        for (final i in items) {
          final m = menu.firstWhere((m) => m['itemId'] == i['itemId']);
          final qty = (i['qty'] as num).toDouble();
          lines.add({
            'id': 'l${lines.length + 1}', 'itemId': m['itemId'], 'name': m['name'], 'station': 'Main', 'qty': qty,
            'rate': m['price'], 'amount': qty * (m['price'] as double), 'state': 'draft', 'kitchenStatus': 'new',
          });
        }
        return (201, order);
      case 'POST /restaurant/orders/o1/send-kot':
        for (final l in lines) {
          l['state'] = 'sent';
          l['kotNo'] = 12;
        }
        sent = true;
        return (200, {'newKotIds': ['k1'], 'order': order});
      case 'POST /restaurant/orders/o1/settle':
        return (200, {
          'order': order,
          'invoice': {'id': 'inv1', 'number': 'INV/26-27/00001', 'total': _bill()['total']},
          'receipts': [],
        });
      case 'GET /restaurant/kots':
        return (200, {'data': [kot], 'total': 1});
      case 'GET /restaurant/kots/k1':
        return (200, kot);
      case 'PATCH /restaurant/kots/k1/status':
        kotStatus = _body(o)!['status']! as String;
        return (200, kot);
    }
    if (o.method == 'PATCH' && o.path.startsWith('/restaurant/orders/o1/lines/')) {
      final id = o.path.split('/').last;
      final l = lines.firstWhere((l) => l['id'] == id);
      final qty = (_body(o)!['qty'] as num).toDouble();
      l['qty'] = qty;
      l['amount'] = qty * (l['rate'] as double);
      return (200, {});
    }
    return null;
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls.add(options);
    final hit = _route(options);
    if (hit == null) return _core.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString(
      jsonEncode(hit.$2),
      hit.$1,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class RestHarness {
  RestHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final RestFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<RestHarness> bootRest(
  WidgetTester tester,
  Size size, {
  String initial = '/restaurant/floor',
  Set<String>? permissions,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = RestFakeBackend(permissions ?? {...FakeBackend.allPermissions, ...restPerms});
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(baseUrl: 'http://fake/api/v1', tokenStore: store, httpClientAdapter: backend);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(appBar: AppBar(title: const Text('Progen')), body: child),
        routes: restaurantRoutes(),
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
        restPollProvider.overrideWithValue(null),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return RestHarness(tester, router, backend);
}
