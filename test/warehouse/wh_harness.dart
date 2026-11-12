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
import 'package:progen_erp/features/warehouse/warehouse_routes.dart';

import '../support/fake_backend.dart';

const whPerms = {'warehouse.view', 'warehouse.pick', 'warehouse.manage'};

Map<String, Object?> _bin(
  String id,
  String code,
  String kind, {
  double? cap,
  double held = 0,
}) => {
  'id': id,
  'locationId': 'l1',
  'code': code,
  'name': null,
  'zone': 'A',
  'kind': kind,
  'capacityQty': cap,
  'isActive': true,
  'heldQty': held,
  'updatedAt': '2026-11-12T10:00:00.000Z',
};

/// Warehouse endpoints; everything else goes to the shared fake backend.
class WhFakeBackend implements HttpClientAdapter {
  WhFakeBackend(Set<String> permissions)
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final List<RequestOptions> calls = [];

  RequestOptions last(String method, String path) =>
      calls.lastWhere((r) => r.method == method && r.path == path);

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  Map<String, Object?> _page(List<Object?> d) => {'data': d, 'total': d.length};

  (int, Object?)? _route(RequestOptions o) {
    if (o.path.startsWith('/warehouse/items/')) {
      return o.method == 'GET'
          ? (
              200,
              {
                'itemId': o.path.split('/').last,
                'itemName': 'Portland Cement',
                'tracking': 'none',
                'shelfLifeDays': null,
                'defaultBinId': null,
              },
            )
          : (200, o.data);
    }
    switch ('${o.method} ${o.path}') {
      case 'GET /warehouse/settings':
        return (
          200,
          {'fefo': true, 'blockExpired': true, 'expiryWarnDays': 90},
        );
      case 'PATCH /warehouse/settings':
        return (200, o.data);
      case 'GET /warehouse/bins':
        return (
          200,
          _page([
            _bin('b1', 'A-01', 'storage', cap: 100, held: 40),
            _bin('b2', 'Q-01', 'quarantine', held: 0),
          ]),
        );
      case 'POST /warehouse/bins':
      case 'PATCH /warehouse/bins/b1':
        return (200, _bin('b1', 'A-01', 'storage'));
      case 'GET /warehouse/stock':
        final withItem = o.queryParameters['itemId'] != null;
        return (
          200,
          {
            ..._page([
              {
                'itemId': 'i1',
                'itemName': 'Paracetamol 500',
                'sku': 'PCM',
                'unit': 'strip',
                'binId': 'b1',
                'binCode': 'A-01',
                'batchId': 'bt1',
                'batchNo': 'B-101',
                'expiryDate': '2027-03-31',
                'expired': false,
                'qty': 40,
              },
              {
                'itemId': 'i1',
                'itemName': 'Paracetamol 500',
                'sku': 'PCM',
                'unit': 'strip',
                'binId': 'b1',
                'binCode': 'A-01',
                'batchId': 'bt0',
                'batchNo': 'B-099',
                'expiryDate': '2026-10-01',
                'expired': true,
                'qty': 5,
              },
            ]),
            if (withItem)
              'summary': {'onHand': 60, 'tagged': 45, 'unassigned': 15},
          },
        );
      case 'POST /warehouse/putaway':
      case 'POST /warehouse/receipts':
        return (201, {'ok': true});
      case 'GET /warehouse/fefo':
        return (
          200,
          {
            'itemId': 'i1',
            'fefo': true,
            'candidates': [
              {
                'binId': 'b1',
                'binCode': 'A-01',
                'batchId': 'bt1',
                'batchNo': 'B-101',
                'expiryDate': '2027-03-31',
                'qty': 40,
              },
            ],
            'requested': 12,
            'enough': true,
            'plan': [
              {
                'binId': 'b1',
                'binCode': 'A-01',
                'batchId': 'bt1',
                'batchNo': 'B-101',
                'expiryDate': '2027-03-31',
                'qty': 12,
              },
            ],
          },
        );
      case 'POST /warehouse/picks':
        return (201, {'refId': 'r1', 'locationId': 'l1', 'lines': []});
      case 'POST /warehouse/picks/r1/invoice':
        return (
          201,
          {
            'pickRefId': 'r1',
            'invoice': {'number': 'INV-26-0001'},
          },
        );
      case 'GET /warehouse/serials':
        return (
          200,
          _page([
            {
              'id': 's1',
              'itemId': 'i2',
              'itemName': 'Mixer Grinder',
              'serialNo': 'MG-0001',
              'binId': 'b1',
              'status': 'in_stock',
              'warrantyUntil': '2027-11-01',
            },
            {
              'id': 's2',
              'itemId': 'i2',
              'itemName': 'Mixer Grinder',
              'serialNo': 'MG-0002',
              'binId': null,
              'status': 'issued',
              'issuedRef': 'invoice',
            },
          ]),
        );
      case 'GET /warehouse/expiry':
        return (
          200,
          {
            ..._page([
              {
                'itemId': 'i1',
                'itemName': 'Paracetamol 500',
                'locationName': 'Head Office',
                'batchNo': 'B-099',
                'expiryDate': '2026-10-01',
                'qty': 5,
                'expired': true,
              },
              {
                'itemId': 'i1',
                'itemName': 'Paracetamol 500',
                'locationName': 'Head Office',
                'batchNo': 'B-101',
                'expiryDate': '2026-12-01',
                'qty': 40,
                'expired': false,
              },
            ]),
            'days': 30,
          },
        );
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

class WhHarness {
  WhHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final WhFakeBackend backend;

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<WhHarness> bootWh(
  WidgetTester tester,
  Size size, {
  String initial = '/warehouse',
  Set<String>? permissions,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = WhFakeBackend(
    permissions ?? {...FakeBackend.allPermissions, ...whPerms},
  );
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
          appBar: AppBar(title: const Text('Progen')),
          body: child,
        ),
        routes: warehouseRoutes(),
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
  return WhHarness(tester, router, backend);
}
