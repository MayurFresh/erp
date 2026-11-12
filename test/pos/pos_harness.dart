import 'dart:async';
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
import 'package:progen_erp/features/pos/pos_routes.dart';

import '../support/fake_backend.dart';

const posSizes = [Size(390, 844), Size(1440, 900)];

Map<String, Object?> posItemJson(
  String id,
  String name,
  double price, {
  String? barcode,
  double stock = 20,
  double gst = 5,
}) => {
  'id': id,
  'name': name,
  'sku': name.substring(0, 3).toUpperCase(),
  'barcode': barcode,
  'unit': 'nos',
  'price': price,
  'gstRate': gst,
  'trackStock': true,
  'stock': stock,
};

final posItems = [
  posItemJson('i1', 'Basmati Rice 1 kg', 100, barcode: '8901000100011'),
  posItemJson('i2', 'Bath Soap', 50, barcode: '8901000100080', gst: 18),
  posItemJson('i3', 'Tea Powder', 120, barcode: '8901000100059'),
];

const posSessionJson = {
  'id': 'ps1',
  'locationId': 'l1',
  'locationName': 'Main Counter',
  'userId': 'u1',
  'userName': 'Sana',
  'status': 'open',
  'openingFloat': 500,
  'openedAt': '2026-11-12T04:00:00.000Z',
};

const posSaleJson = {
  'id': 'sale1',
  'sessionId': 'ps1',
  'invoiceId': 'inv1',
  'number': 'INV/26-27/00007',
  'date': '2026-11-12',
  'createdAt': '2026-11-12T05:00:00.000Z',
  'locationName': 'Main Counter',
  'cashier': 'Sana',
  'company': {
    'name': 'Demo Stores',
    'gstin': '24ABCDE1234F1Z5',
    'address': 'Ahmedabad',
    'phone': '9999999999',
  },
  'customer': {'id': 'p9', 'name': 'Walk-in Customer', 'isWalkIn': true},
  'lines': [
    {
      'invoiceLineId': 'il1',
      'description': 'Basmati Rice 1 kg',
      'hsnCode': '1006',
      'qty': 1,
      'unit': 'nos',
      'rate': 100,
      'discountPct': 0,
      'gstRate': 5,
      'taxableValue': 100,
      'lineTotal': 105,
      'returnedQty': 0,
    },
  ],
  'taxSummary': [
    {'rate': 5, 'taxable': 100, 'cgst': 2.5, 'sgst': 2.5, 'igst': 0},
  ],
  'subtotal': 100,
  'taxTotal': 5,
  'roundOff': 0,
  'discountTotal': 0,
  'total': 105,
  'payments': [
    {'mode': 'cash', 'amount': 105},
  ],
  'tenderedCash': 200,
  'changeDue': 95,
  'creditAmount': 0,
};

/// The POS endpoints; everything else goes to the shared backend.
class PosFakeBackend implements HttpClientAdapter {
  PosFakeBackend(Set<String> permissions, {this.hasSession = true})
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  bool hasSession;
  bool inclusive = false;
  bool closed = false;
  bool heldOnClose = false;
  final List<RequestOptions> posts = [];

  /// Completes the pending `POST /pos/sales`; null answers at once.
  Completer<void>? holdSale;
  final List<RequestOptions> sales = [];

  Object? _route(RequestOptions o) {
    final q = o.queryParameters['q'] as String?;
    return switch ((o.method, o.path)) {
      ('GET', '/pos/sessions/current') => {
        'session': hasSession ? posSessionJson : null,
        'openCount': hasSession ? 1 : 0,
      },
      ('GET', '/pos/items/frequent') => {'data': posItems},
      ('GET', '/pos/items') => () {
        final exact = posItems.where((i) => i['barcode'] == q).toList();
        if (exact.isNotEmpty) return {'exact': true, 'data': exact};
        final like = posItems
            .where(
              (i) => (i['name']! as String).toLowerCase().contains(
                (q ?? '').toLowerCase(),
              ),
            )
            .toList();
        return {'exact': false, 'data': like};
      }(),
      ('GET', '/pos/settings') => {'pricesIncludeTax': inclusive},
      ('GET', '/pos/held') => {
        'data': [_held],
      },
      ('GET', '/pos/sales') => {
        'total': 1,
        'data': [
          {
            'id': 'sale1',
            'number': 'INV/26-27/00007',
            'total': 105,
            'customerName': 'Walk-in Customer',
            'createdAt': '2026-11-12T05:00:00.000Z',
          },
        ],
      },
      ('GET', '/pos/sales/sale1') => posSaleJson,
      ('GET', '/pos/sessions/ps1/report') =>
        closed
            ? {
                ..._xReport,
                'kind': 'Z',
                'session': {...posSessionJson, 'status': 'closed'},
              }
            : _xReport,
      _ => null,
    };
  }

  static final Map<String, Object?> _xReport = {
    'kind': 'X',
    'session': posSessionJson,
    'sales': {
      'count': 2,
      'total': 164,
      'taxTotal': 14,
      'discountTotal': 0,
      'itemsSold': 3,
      'creditGiven': 0,
    },
    'payments': {'cash': 105, 'upi': 59, 'card': 0, 'other': 0},
    'refunds': {'cash': 0, 'upi': 0, 'card': 0, 'other': 0},
    'returns': {'count': 0, 'total': 0},
    'cashIn': 0,
    'cashOut': 0,
    'expected': {'cash': 605, 'upi': 59, 'card': 0, 'other': 0},
    'counted': null,
    'difference': null,
    'cashMoves': <Object?>[],
  };

  static const Map<String, Object?> _held = {
    'id': 'h1',
    'locationId': 'l1',
    'label': 'Mrs Rao',
    'total': 200,
    'createdBy': 'Sana',
    'createdAt': '2026-11-12T05:00:00.000Z',
    'payload': {
      'lines': [
        {
          'itemId': 'i1',
          'name': 'Basmati Rice 1 kg',
          'price': 100,
          'gstRate': 5,
          'unit': 'nos',
          'qty': 2,
          'discountPct': 0,
        },
      ],
    },
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.method == 'POST' &&
        options.path.startsWith('/pos/') &&
        options.path != '/pos/sales') {
      posts.add(options);
      if (options.path == '/pos/sessions/ps1/close') {
        final data = options.data as Map;
        if (heldOnClose && data['confirmHeld'] != true) {
          return _json({
            'error': {
              'code': 'HELD_BILLS',
              'message': '2 bills are still on hold from this session.',
              'details': {'count': 2},
            },
          }, 409);
        }
        closed = true;
        return _json(_xReport, 200);
      }
      if (options.path == '/pos/held/h1/resume') {
        return _json(_held, 200);
      }
      if (options.path == '/pos/sales/sale1/return') {
        return _json({
          ...posSaleJson,
          'returned': {'total': 105, 'refundAmount': 105},
        }, 201);
      }
    }
    if (options.method == 'POST' && options.path == '/pos/sales') {
      sales.add(options);
      if (holdSale != null) await holdSale!.future;
      return _json(posSaleJson, 201);
    }
    final body = _route(options);
    if (body == null) return _core.fetch(options, requestStream, cancelFuture);
    return _json(body, 200);
  }

  ResponseBody _json(Object body, int status) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

class PosHarness {
  PosHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final PosFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<PosHarness> bootPos(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  bool hasSession = true,
  bool inclusive = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms =
      permissions ?? {...FakeBackend.allPermissions, 'pos.use', 'pos.manage'};
  final backend = PosFakeBackend(perms, hasSession: hasSession)
    ..inclusive = inclusive;
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  final router = GoRouter(
    initialLocation: '/pos',
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(body: child),
        routes: posRoutes(),
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
  return PosHarness(tester, router, backend);
}
