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
import 'package:progen_erp/features/manufacturing/manufacturing_routes.dart';

import '../support/fake_backend.dart';

const mfgPerms = {
  'manufacturing.view',
  'manufacturing.bom',
  'manufacturing.orders',
  'manufacturing.issue',
  'manufacturing.output',
  'manufacturing.inspect',
  'manufacturing.manage',
  'purchase_orders.manage',
};

Map<String, Object?> mfgOrderJson({
  String status = 'in_progress',
  List<String>? actions,
}) => {
  'id': 'o1',
  'number': 'MO/26-27/0001',
  'status': status,
  'itemId': 'f1',
  'itemName': 'Steel Almirah',
  'unit': 'nos',
  'bomVersion': 2,
  'locationId': 'l1',
  'locationName': 'Factory',
  'qty': 10,
  'goodQty': 4,
  'rejectedQty': 1,
  'plannedEnd': '2026-12-01',
  'updatedAt': '2026-11-12T10:00:00.000Z',
  'nextActions': actions ?? ['issue', 'return', 'output', 'inspect', 'close'],
  'materials': [
    {
      'itemId': 'r1',
      'name': 'MS Sheet 18G',
      'unit': 'kg',
      'plannedQty': 400,
      'issuedQty': 300,
      'returnedQty': 0,
      'netQty': 300,
      'pendingQty': 100,
      'onHand': 40,
      'issuedValue': 21000,
    },
    {
      'itemId': 'r2',
      'name': 'Paint',
      'unit': 'ltr',
      'plannedQty': 20,
      'issuedQty': 20,
      'returnedQty': 0,
      'netQty': 20,
      'pendingQty': 0,
      'onHand': 5,
    },
  ],
  'steps': [
    {
      'operation': 'Cutting',
      'workCentreName': 'Shear line',
      'plannedMinutes': 120,
    },
  ],
  'outputs': [
    {
      'id': 'x1',
      'date': '2026-11-10',
      'goodQty': 4,
      'rejectedQty': 1,
      'minutes': 90,
      'unitCost': 5400,
      'byProducts': [],
    },
  ],
  'movements': [],
  'inspections': [],
  'cost': {
    'material': 21000,
    'conversion': 2600,
    'total': 23600,
    'unitCost': 5900,
    'lossValue': 0,
  },
  'variance': {
    'lines': [
      {
        'name': 'MS Sheet 18G',
        'unit': 'kg',
        'expectedQty': 200,
        'actualQty': 300,
        'varianceQty': 100,
        'varianceValue': 7000,
      },
    ],
    'yieldPct': 80,
    'completionPct': 40,
  },
};

Map<String, Object?> _bom({String status = 'draft'}) => {
  'id': 'b1',
  'itemId': 'f1',
  'itemName': 'Steel Almirah',
  'unit': 'nos',
  'version': 2,
  'status': status,
  'outputQty': 1,
  'updatedAt': '2026-11-12T09:00:00.000Z',
  'lines': [
    {
      'id': 'bl1',
      'kind': 'component',
      'itemId': 'r1',
      'name': 'MS Sheet 18G',
      'unit': 'kg',
      'qty': 40,
      'scrapPct': 5,
      'hasBom': false,
    },
    {
      'id': 'bl2',
      'kind': 'byproduct',
      'itemId': 'r3',
      'name': 'MS Offcuts',
      'unit': 'kg',
      'qty': 2,
      'scrapPct': 0,
      'rate': 30,
      'hasBom': false,
    },
  ],
  'steps': [
    {
      'id': 's1',
      'operation': 'Cutting',
      'workCentreId': 'w1',
      'workCentreName': 'Shear line',
      'minutesPerUnit': 12,
      'hourlyCost': 300,
    },
  ],
  'standardCost': {
    'material': 2100,
    'work': 60,
    'byProducts': 60,
    'unitCost': 2100,
    'basis': 'Purchase price of components',
  },
};

Map<String, Object?> _challan({String status = 'open'}) => {
  'id': 'j1',
  'number': 'JWC/26-27/0001',
  'status': status,
  'partyName': 'Shree Coaters',
  'locationName': 'Factory',
  'challanDate': '2026-11-01',
  'process': 'Powder coating',
  'ageDays': 11,
  'lines': [
    {
      'id': 'jl1',
      'name': 'Almirah body',
      'unit': 'nos',
      'returnName': 'Coated body',
      'qtySent': 10,
      'qtyReceived': 0,
      'qtyScrap': 0,
      'qtyPending': 10,
    },
  ],
  'receipts': [],
};

/// Manufacturing endpoints; everything else goes to the shared fake backend.
class MfgFakeBackend implements HttpClientAdapter {
  MfgFakeBackend(Set<String> permissions)
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final List<RequestOptions> calls = [];

  RequestOptions last(String method, String path) =>
      calls.lastWhere((r) => r.method == method && r.path == path);

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  Map<String, Object?>? _body(RequestOptions o) =>
      o.data is Map ? (o.data as Map).cast<String, Object?>() : null;

  Map<String, Object?> _page(List<Object?> d) => {'data': d, 'total': d.length};

  (int, Object?)? _route(RequestOptions o) {
    switch ('${o.method} ${o.path}') {
      case 'GET /items':
        return (
          200,
          _page([
            FakeBackend.item,
            {
              ...FakeBackend.item,
              'id': 'i3',
              'name': 'MS Sheet 18G',
              'sku': 'MS-18',
              'unit': 'kg',
            },
          ]),
        );
      case 'POST /manufacturing/boms':
        return (201, _bom());
      case 'POST /manufacturing/orders':
        return (201, mfgOrderJson());
      case 'POST /manufacturing/mrp/purchase-order':
        return (201, {'number': 'PO/26-27/0009'});
      case 'POST /manufacturing/jobwork':
        return (201, _challan());
      case 'GET /manufacturing/home':
        return (
          200,
          {
            'ordersByStatus': {
              'draft': 1,
              'released': 2,
              'in_progress': 3,
              'completed': 7,
              'cancelled': 0,
            },
            'shortagesCount': 2,
            'todayOutput': [
              {
                'name': 'Steel Almirah',
                'unit': 'nos',
                'goodQty': 4,
                'rejectedQty': 1,
              },
            ],
            'openJobWork': 1,
          },
        );
      case 'GET /manufacturing/settings':
        return (200, {'overheadPct': 10});
      case 'PATCH /manufacturing/settings':
        return (200, {'overheadPct': _body(o)!['overheadPct']});
      case 'GET /manufacturing/work-centres':
        return (
          200,
          _page([
            {
              'id': 'w1',
              'name': 'Shear line',
              'isActive': true,
              'hourlyCost': 300,
              'updatedAt': 'u',
            },
          ]),
        );
      case 'GET /manufacturing/boms':
        return (
          200,
          _page([
            {
              'id': 'b1',
              'itemId': 'f1',
              'itemName': 'Steel Almirah',
              'unit': 'nos',
              'version': 2,
              'status': 'draft',
              'outputQty': 1,
              'lineCount': 2,
            },
          ]),
        );
      case 'GET /manufacturing/boms/b1':
        return (200, _bom());
      case 'PATCH /manufacturing/boms/b1':
        return (200, _bom());
      case 'POST /manufacturing/boms/b1/activate':
        return (200, _bom(status: 'active'));
      case 'GET /manufacturing/explode':
        return (
          200,
          {
            'itemId': 'f1',
            'itemName': 'Steel Almirah',
            'qty': 5,
            'tree': [
              {
                'itemId': 'r1',
                'name': 'MS Sheet 18G',
                'unit': 'kg',
                'qty': 210,
                'children': [],
              },
            ],
            'raw': [
              {
                'itemId': 'r1',
                'name': 'MS Sheet 18G',
                'unit': 'kg',
                'qty': 210,
                'onHand': 40,
              },
            ],
          },
        );
      case 'GET /manufacturing/orders':
        return (
          200,
          _page([
            {
              'id': 'o1',
              'number': 'MO/26-27/0001',
              'status': 'in_progress',
              'itemName': 'Steel Almirah',
              'unit': 'nos',
              'qty': 10,
              'goodQty': 4,
              'rejectedQty': 1,
            },
          ]),
        );
      case 'GET /manufacturing/orders/o1':
        return (200, mfgOrderJson());
      case 'POST /manufacturing/orders/o1/issue':
      case 'POST /manufacturing/orders/o1/output':
      case 'POST /manufacturing/orders/o1/close':
        return (200, mfgOrderJson());
      case 'GET /manufacturing/mrp':
        return (
          200,
          {
            'shortages': [
              {
                'itemId': 'r1',
                'name': 'MS Sheet 18G',
                'unit': 'kg',
                'required': 500,
                'onHand': 40,
                'onOrder': 100,
                'shortage': 360,
              },
            ],
            'shortagesCount': 1,
          },
        );
      case 'GET /manufacturing/jobwork':
        return (
          200,
          _page([
            {
              'id': 'j1',
              'number': 'JWC/26-27/0001',
              'status': 'open',
              'partyName': 'Shree Coaters',
              'process': 'Powder coating',
              'challanDate': '2026-11-01',
            },
          ]),
        );
      case 'GET /manufacturing/jobwork/j1':
        return (200, _challan());
      case 'POST /manufacturing/jobwork/j1/receive':
        return (200, _challan(status: 'partially_returned'));
      case 'GET /manufacturing/jobwork/itc04':
        return (
          200,
          {
            'note': 'Check before filing',
            'rows': [
              {
                'jobWorker': 'Shree Coaters',
                'item': 'Almirah body',
                'unit': 'nos',
                'qtySent': 10,
                'qtyReceived': 0,
                'qtyScrap': 0,
                'qtyPending': 10,
                'oldestPendingDays': 400,
                'overdue': true,
              },
            ],
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

class MfgHarness {
  MfgHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final MfgFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<MfgHarness> bootMfg(
  WidgetTester tester,
  Size size, {
  String initial = '/manufacturing',
  Set<String>? permissions,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = MfgFakeBackend(
    permissions ?? {...FakeBackend.allPermissions, ...mfgPerms},
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
        routes: manufacturingRoutes(),
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
  return MfgHarness(tester, router, backend);
}
