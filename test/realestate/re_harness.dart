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
import 'package:onematrix/features/realestate/realestate_routes.dart';

import '../support/fake_backend.dart';

const reTestWidths = [Size(390, 844), Size(768, 1024), Size(1280, 800)];

const unitJson = {
  'id': 'un1',
  'projectId': 'pr1',
  'projectName': 'Tower Heights',
  'code': 'A-101',
  'wing': 'A',
  'floor': 1,
  'unitType': '2 BHK',
  'carpetArea': 78.5,
  'listPrice': 6500000,
  'status': 'available',
};

const bookingJson = {
  'id': 'bk1',
  'number': 'BK/26-27/00001',
  'projectId': 'pr1',
  'projectName': 'Tower Heights',
  'unitId': 'un2',
  'unitCode': 'A-102',
  'customerPartyId': 'p1',
  'customerName': 'Mehta Family',
  'date': '2026-10-20',
  'agreementValue': 6500000,
  'gstPct': 5,
  'paymentPlanId': 'pl1',
  'paymentPlanName': 'Construction linked',
  'status': 'booked',
  'stages': [
    {
      'id': 's1',
      'name': 'On booking',
      'pct': 10,
      'amount': 650000,
      'sortOrder': 1,
      'demandId': 'dm1',
      'demandNumber': 'DM/26-27/00001',
    },
    {
      'id': 's2',
      'name': 'On possession',
      'pct': 90,
      'amount': 5850000,
      'sortOrder': 2,
    },
  ],
  'totals': {
    'demanded': 650000,
    'gst': 32500,
    'received': 0,
    'due': 682500,
    'undemanded': 5850000,
  },
};

const demandJson = {
  'id': 'dm1',
  'number': 'DM/26-27/00001',
  'bookingId': 'bk1',
  'bookingNumber': 'BK/26-27/00001',
  'projectId': 'pr1',
  'unitCode': 'A-102',
  'partyId': 'p1',
  'partyName': 'Mehta Family',
  'date': '2026-10-21',
  'dueDate': '2026-11-05',
  'stages': [
    {'id': 's1', 'name': 'On booking', 'pct': 10, 'amount': 650000},
  ],
  'amount': 650000,
  'cgst': 16250,
  'sgst': 16250,
  'total': 682500,
  'amountPaid': 0,
  'amountDue': 682500,
  'paymentStatus': 'unpaid',
  'status': 'open',
};

const _plan = {
  'id': 'pl1',
  'projectId': 'pr1',
  'name': 'Construction linked',
  'isActive': true,
  'stages': [
    {'id': 's1', 'name': 'On booking', 'pct': 10, 'sortOrder': 1},
    {'id': 's2', 'name': 'On possession', 'pct': 90, 'sortOrder': 2},
  ],
};

/// The v1.3 sales endpoints; everything else goes to the shared backend.
class ReFakeBackend implements HttpClientAdapter {
  ReFakeBackend(Set<String> permissions)
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;

  Map<String, Object?> _page(List<Object?> d) => {'data': d, 'total': d.length};

  Object? _route(RequestOptions o) {
    if (o.method != 'GET') return null;
    return switch (o.path) {
      '/units' => _page([
        unitJson,
        {...unitJson, 'id': 'un2', 'code': 'A-102', 'status': 'booked'},
        {...unitJson, 'id': 'un3', 'code': 'A-201', 'floor': 2},
      ]),
      '/projects' => _page([
        {'id': 'pr1', 'code': 'PRJ-1', 'name': 'Tower Heights'},
      ]),
      '/bookings' => _page([bookingJson]),
      '/bookings/bk1' => bookingJson,
      '/demands' => _page([demandJson]),
      '/demands/dm1' => demandJson,
      '/payment-plans/pl1' => _plan,
      '/payment-plans' => _page([_plan]),
      '/projects/pr1/rera' => {
        'projectId': 'pr1',
        'reraRegNo': 'PRM/KA/1',
        'collections': 1000000,
        'required': 700000,
        'deposited': 500000,
        'withdrawn': 0,
        'balance': 500000,
        'shortfall': 200000,
      },
      _ => null,
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
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

  @override
  void close({bool force = false}) {}
}

class ReHarness {
  ReHarness(this.tester, this.router);

  final WidgetTester tester;
  final GoRouter router;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<ReHarness> bootRe(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms =
      permissions ??
      {
        ...FakeBackend.allPermissions,
        'units.view',
        'units.manage',
        'bookings.view',
        'bookings.manage',
        'projects.view',
      };
  final backend = ReFakeBackend(perms);
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  final router = GoRouter(
    initialLocation: '/units',
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          appBar: AppBar(title: const Text('OneMatrix')),
          body: child,
        ),
        routes: realEstateRoutes(),
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
  return ReHarness(tester, router);
}
