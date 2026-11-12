import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/money.dart';
import 'package:progen_erp/core/providers.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/legal/legal_routes.dart';

import '../support/fake_backend.dart';

const legalTestSizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

final _today = apiDate(DateTime.now());
final _tomorrow = apiDate(DateTime.now().add(const Duration(days: 1)));
final _lastWeek = apiDate(DateTime.now().subtract(const Duration(days: 7)));
final _nextMonth = apiDate(DateTime.now().add(const Duration(days: 30)));

const _updated = '2026-11-12T09:00:00.000Z';

Map<String, Object?> matterJson({
  String id = 'm1',
  String title = 'Mehta Traders v. Shree Steel Ltd',
  String? next,
}) => {
  'id': id,
  'matterNo': 'MAT/26-27/00001',
  'title': title,
  'clientId': 'c1',
  'clientName': 'Mehta Traders',
  'clientGstin': '27AAPFU0939F1ZV',
  'opposingParty': 'Shree Steel Ltd',
  'court': 'City Civil Court, Ahmedabad',
  'caseType': 'Recovery suit',
  'caseNo': 'CS 412',
  'caseYear': 2026,
  'filingDate': '2026-04-02',
  'stage': 'Evidence',
  'status': 'open',
  'advocateId': 'u1',
  'advocateName': 'Anita Shah',
  'team': [
    {'id': 'u2', 'name': 'Rohan Desai'},
  ],
  'feeType': 'hourly',
  'agreedFee': 0,
  'hourlyRate': 3000,
  'notes': 'Client prefers calls in the morning.',
  'nextHearingDate': next,
  'updatedAt': _updated,
};

Map<String, Object?> matterDetail() => {
  ...matterJson(next: _tomorrow),
  'hearings': [
    {
      'id': 'h1',
      'matterId': 'm1',
      'hearingDate': _tomorrow,
      'court': 'City Civil Court, Ahmedabad',
      'purpose': 'Cross examination',
      'status': 'scheduled',
      'outcome': null,
      'updatedAt': _updated,
    },
    {
      'id': 'h0',
      'matterId': 'm1',
      'hearingDate': _lastWeek,
      'court': 'City Civil Court, Ahmedabad',
      'purpose': 'Evidence',
      'status': 'held',
      'outcome': 'Plaintiff witness examined in chief.',
      'updatedAt': _updated,
    },
  ],
  'summary': {
    'unbilled': {'time': 7500, 'fee': 0, 'disbursement': 1200, 'nonBillable': 0},
    'openTasks': 2,
    'billedTotal': 11800,
    'billedPaid': 4000,
    'advanceReceived': 20000,
  },
};

Map<String, Object?> causeItem(String id, String date, {String title = 'Mehta Traders v. Shree Steel Ltd'}) => {
  'id': id,
  'matterId': 'm1',
  'matterNo': 'MAT/26-27/00001',
  'matterTitle': title,
  'clientName': 'Mehta Traders',
  'hearingDate': date,
  'court': 'City Civil Court, Ahmedabad',
  'purpose': 'Cross examination',
};

Map<String, Object?> homeJson() => {
  'today': _today,
  'tomorrow': _tomorrow,
  'hearings': [
    causeItem('h-today', _today, title: 'Patel v. Patel (partition)'),
    causeItem('h1', _tomorrow),
  ],
  'pendingOutcome': [causeItem('h-old', _lastWeek, title: 'Desai Infra v. NHAI')],
  'deadlines': [
    {
      'id': 't1',
      'matterId': 'm1',
      'matterNo': 'MAT/26-27/00001',
      'matterTitle': 'Patel v. Patel (partition)',
      'title': 'File written statement',
      'kind': 'filing',
      'dueDate': _lastWeek,
      'assigneeName': 'Anita Shah',
      'status': 'open',
      'overdue': true,
    },
  ],
  'withoutNextDate': [matterJson(id: 'm2', title: 'Shree Ganesh Society v. Registrar')],
};

const entriesJson = [
  {
    'id': 'e1',
    'matterId': 'm1',
    'kind': 'time',
    'minutes': 150,
    'rate': 3000,
    'amount': 7500,
    'entryDate': '2026-11-10',
    'billable': true,
    'billed': false,
    'description': 'Drafting affidavit of evidence',
    'userName': 'Anita Shah',
  },
  {
    'id': 'e2',
    'matterId': 'm1',
    'kind': 'disbursement',
    'disbType': 'court_fee',
    'amount': 1200,
    'entryDate': '2026-11-09',
    'billable': true,
    'billed': false,
    'description': 'Court fee for exhibits',
    'userName': 'Anita Shah',
  },
];

class LegalFakeBackend implements HttpClientAdapter {
  LegalFakeBackend(Set<String> permissions)
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final List<RequestOptions> calls = [];

  Map<String, Object?> _page(List<Object?> d) => {'data': d, 'total': d.length};

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
    'GET /legal/home' => (200, homeJson()),
    'GET /legal/staff' => (
      200,
      _page([
        {'id': 'u1', 'name': 'Anita Shah'},
        {'id': 'u2', 'name': 'Rohan Desai'},
      ]),
    ),
    'GET /legal/matters' => (
      200,
      _page([
        matterJson(next: _tomorrow),
        matterJson(id: 'm2', title: 'Patel v. Patel (partition)'),
      ]),
    ),
    'GET /legal/matters/m1' => (200, matterDetail()),
    'POST /legal/matters' => (201, matterJson(id: 'm9')),
    'GET /legal/tasks' => (
      200,
      _page([
        {
          'id': 't1',
          'matterId': 'm1',
          'title': 'File written statement',
          'kind': 'filing',
          'dueDate': _lastWeek,
          'status': 'open',
          'overdue': true,
        },
        {
          'id': 't2',
          'matterId': 'm1',
          'title': 'Limitation for appeal',
          'kind': 'limitation',
          'dueDate': _nextMonth,
          'status': 'open',
          'overdue': false,
        },
      ]),
    ),
    'GET /legal/entries' => (200, _page(entriesJson)),
    'POST /legal/matters/m1/entries' => (201, entriesJson.first),
    'GET /legal/matters/m1/bills' => (
      200,
      {
        'bills': [
          {
            'invoiceId': 'i1',
            'number': 'INV/26-27/00012',
            'invoiceDate': '2026-11-01',
            'total': 11800,
            'amountPaid': 4000,
            'status': 'posted',
            'reverseCharge': false,
          },
        ],
        'receipts': [],
      },
    ),
    'GET /legal/matters/m1/documents' => (200, _page([])),
    'POST /legal/hearings/h1/outcome' => (
      200,
      {'hearing': {}, 'next': null, 'feeEntryId': null, 'warning': 'No next date is set for this matter.'},
    ),
    'POST /legal/hearings/h-today/outcome' => (
      200,
      {'hearing': {}, 'next': {}, 'feeEntryId': null, 'warning': null},
    ),
    'POST /legal/matters/m1/bill' => (
      201,
      {'invoice': {'number': 'INV/26-27/00013'}, 'reverseCharge': false, 'entriesBilled': 2},
    ),
    _ => null,
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.startsWith('/legal')) calls.add(options);
    final r = _route(options);
    if (r == null) return _core.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString(
      jsonEncode(r.$2),
      r.$1,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

class LegalHarness {
  LegalHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final LegalFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

const legalViewPermissions = {'legal.view'};
const legalWorkPermissions = {'legal.view', 'legal.work'};

Future<LegalHarness> bootLegal(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  String location = '/legal',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms =
      permissions ??
      {
        ...FakeBackend.allPermissions,
        ...legalWorkPermissions,
        'legal.manage',
      };
  final backend = LegalFakeBackend(perms);
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  final router = GoRouter(
    initialLocation: location,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          appBar: AppBar(title: const Text('Progen')),
          body: child,
        ),
        routes: legalRoutes(),
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
  return LegalHarness(tester, router, backend);
}
