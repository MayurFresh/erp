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
import 'package:onematrix/features/receivables/receivables_routes.dart';

import '../support/fake_backend.dart';

const receivablesSizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

Map<String, Object?> statementJson({double pct = 18}) => {
  'accountId': 'a1',
  'accountName': 'Acme Traders: party ledger',
  'from': '2026-04-01',
  'to': '2026-11-13',
  'openingBalance': 1180,
  'closingBalance': 1950,
  'totalDebit': 2950,
  'totalCredit': 2180,
  'lines': [
    {'entryId': 'e1', 'date': '2026-10-04', 'voucherType': 'sales', 'type': 'sales', 'voucherId': 'i1', 'number': 'INV/26-27/00002', 'narration': null, 'debit': 2360, 'credit': 0, 'balance': 3540, 'dueDate': '2026-11-03'},
    {'entryId': 'e2', 'date': '2026-10-24', 'voucherType': 'receipt', 'type': 'receipt', 'voucherId': 'r1', 'number': 'REC/26-27/00001', 'narration': null, 'debit': 0, 'credit': 1590, 'balance': 1950, 'dueDate': null},
  ],
  'party': {'id': 'p1', 'name': 'Acme Traders', 'type': 'customer', 'phone': '9825012345', 'email': 'a@x.in'},
  'doNotRemind': false,
  'openBills': [
    {'type': 'invoice', 'id': 'i1', 'number': 'INV/26-27/00002', 'date': '2026-10-04', 'dueDate': '2026-11-03', 'total': 2360, 'amountDue': 1180, 'daysOverdue': 10, 'interestDue': pct > 0 ? 5.82 : null},
    {'type': 'invoice', 'id': 'i2', 'number': 'INV/26-27/00003', 'date': '2026-11-08', 'dueDate': '2026-12-08', 'total': 590, 'amountDue': 590, 'daysOverdue': 0, 'interestDue': pct > 0 ? 0 : null},
  ],
  'ageing': {'basis': 'receivable', 'notDue': 590, 'd1_30': 1180, 'd31_60': 0, 'd61_90': 180, 'd90plus': 0, 'total': 1950},
  'payablesAgeing': null,
  'openTotal': 1950,
  'overdueInterestPct': pct,
  'interestTotal': pct > 0 ? 12.03 : 0,
};

const reminderSettingsJson = {
  'enabled': true,
  'daysBefore': 3,
  'onDueDate': true,
  'repeatEveryDays': 7,
  'maxRepeats': 3,
  'channels': ['email', 'whatsapp'],
  'overdueInterestPct': 0,
};

Map<String, Object?> recurringJson(String id, String status, {String? lastError}) => {
  'id': id,
  'name': 'Shop rent',
  'partyId': 'p1',
  'partyName': 'Acme Traders',
  'locationId': 'l1',
  'locationName': 'Main',
  'lines': [
    {'itemId': 'i1', 'itemName': 'Rent', 'qty': 1, 'rate': 25000, 'discountPct': 0, 'description': null},
  ],
  'frequency': 'monthly',
  'startDate': '2026-01-31',
  'endDate': null,
  'maxRuns': null,
  'dayOfMonth': 31,
  'status': status,
  'nextDate': status == 'ended' ? null : '2026-11-30',
  'runsDone': 2,
  'autoSend': true,
  'sendChannels': ['email'],
  'notes': null,
  'lastError': lastError,
  'invoices': [
    {'period': '2026-10-31', 'invoiceId': 'v2', 'number': 'INV/26-27/00010', 'invoiceDate': '2026-10-31', 'total': 29500, 'amountPaid': 0, 'status': 'posted'},
    {'period': '2026-09-30', 'invoiceId': 'v1', 'number': 'INV/26-27/00004', 'invoiceDate': '2026-09-30', 'total': 29500, 'amountPaid': 29500, 'status': 'posted'},
  ],
  'upcoming': ['2026-11-30', '2026-12-31'],
};

class ReceivablesFakeBackend implements HttpClientAdapter {
  ReceivablesFakeBackend(Set<String> permissions, {this.pct = 18})
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final double pct;
  final List<RequestOptions> calls = [];

  Map<String, Object?> body(String method, String path) {
    final o = calls.lastWhere((r) => r.method == method && r.path == path);
    final data = o.data;
    return data is Map
        ? Map<String, Object?>.from(data)
        : jsonDecode(data as String) as Map<String, Object?>;
  }

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  (int, Object?)? _route(RequestOptions o) => switch ('${o.method} ${o.path}') {
    'GET /parties/p1/statement' => (200, statementJson(pct: pct)),
    'GET /reminders/settings' => (200, reminderSettingsJson),
    'PATCH /reminders/settings' => (200, reminderSettingsJson),
    'GET /reminders/excluded' => (200, {'data': [{'partyId': 'p9', 'name': 'Opted Out Co', 'phone': null, 'email': null}]}),
    'POST /reminders/run' => (200, {'enabled': true, 'parties': 2, 'invoices': 3, 'queued': 1, 'skipped': 1}),
    'GET /reminders/log' => (200, {'data': [
      {'id': 'g1', 'partyId': 'p1', 'partyName': 'Acme Traders', 'invoiceId': 'i1', 'invoiceNumber': 'INV/26-27/00002', 'step': 'due', 'stepLabel': 'On due date', 'stepDate': '2026-11-03', 'runDate': '2026-11-03', 'channels': ['email', 'whatsapp'], 'status': 'queued', 'note': null, 'delivery': 'sent', 'amount': 1770},
      {'id': 'g2', 'partyId': 'p2', 'partyName': 'No Contact', 'invoiceId': 'i3', 'invoiceNumber': 'INV/26-27/00005', 'step': 'before', 'stepLabel': 'Before due date', 'stepDate': '2026-11-01', 'runDate': '2026-11-01', 'channels': <String>[], 'status': 'skipped', 'note': 'No email or phone', 'delivery': 'none', 'amount': 500},
    ], 'total': 2}),
    'PATCH /parties/p9/reminders' => (200, {'partyId': 'p9', 'doNotRemind': false}),
    'GET /recurring-invoices' => (200, {'data': [recurringJson('t1', 'active'), recurringJson('t2', 'paused', lastError: 'Closed books')], 'total': 2}),
    'GET /recurring-invoices/t1' => (200, recurringJson('t1', 'active')),
    'POST /recurring-invoices/t1/pause' => (200, recurringJson('t1', 'paused')),
    'POST /recurring-invoices/run' => (200, {'templates': 1, 'created': [{'templateId': 't1'}], 'errors': <Object?>[]}),
    'POST /recurring-invoices' => (201, recurringJson('t3', 'active')),
    _ => null,
  };

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    final r = _route(options);
    if (r == null) return _core.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString(jsonEncode(r.$2), r.$1, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

class ReceivablesHarness {
  ReceivablesHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final ReceivablesFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<ReceivablesHarness> bootReceivables(
  WidgetTester tester,
  Size size, {
  required String location,
  Set<String>? permissions,
  double pct = 18,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = ReceivablesFakeBackend(permissions ?? FakeBackend.allPermissions, pct: pct);
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(baseUrl: 'http://fake/api/v1', tokenStore: store, httpClientAdapter: backend);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(appBar: AppBar(title: const Text('OneMatrix')), body: child),
        routes: receivablesRoutes(),
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
  return ReceivablesHarness(tester, router, backend);
}
