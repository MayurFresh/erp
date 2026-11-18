import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/money.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/funds/funds_routes.dart';

import '../support/fake_backend.dart';

const fundsTestSizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

final _today = apiDate(DateTime.now());

Map<String, Object?> headJson(
  String id,
  String level,
  String code,
  String name, {
  String? parent,
  double budget = 0,
  double actual = 0,
  double committed = 0,
  bool leaf = true,
}) => {
  'id': id,
  'fy': '2026-27',
  'parentId': parent,
  'level': level,
  'code': code,
  'name': name,
  'accountId': null,
  'accountName': null,
  'isLeaf': leaf,
  'isActive': true,
  'estimate': budget,
  'revised': null,
  'reappIn': 0,
  'reappOut': 0,
  'budget': budget,
  'actual': actual,
  'committed': committed,
  'available': budget - actual - committed,
  'percentUsed': budget == 0 ? 0 : (actual / budget * 1000).round() / 10,
  'percentCommitted': budget == 0
      ? 0
      : ((actual + committed) / budget * 1000).round() / 10,
  'updatedAt': '2026-11-01T10:00:00.000Z',
};

final majorHead = headJson(
  'h1',
  'major',
  '2202',
  'General education',
  budget: 10000,
  actual: 3000,
  committed: 2000,
  leaf: false,
);
final minorHead = headJson(
  'h2',
  'minor',
  '2202.01',
  'Elementary',
  parent: 'h1',
  budget: 10000,
  actual: 3000,
  committed: 2000,
  leaf: false,
);
final salaryHead = headJson(
  'h3',
  'object',
  '2202.01.01',
  'Salaries',
  parent: 'h2',
  budget: 6000,
  actual: 3000,
  committed: 1000,
);
final suppliesHead = headJson(
  'h4',
  'object',
  '2202.01.02',
  'Supplies',
  parent: 'h2',
  budget: 4000,
  committed: 1000,
);

const totalsJson = {
  'budget': 10000,
  'actual': 3000,
  'committed': 2000,
  'available': 5000,
};

const fundJson = {
  'id': 'f1',
  'name': 'State education grant',
  'kind': 'grant',
  'sponsor': 'Department of Education',
  'sanctionNo': 'ED/118',
  'sanctionDate': '2026-05-12',
  'totalAmount': 50000,
  'periodFrom': null,
  'periodTo': null,
  'returnUnspent': true,
  'status': 'active',
  'notes': null,
  'received': 20000,
  'spent': 3000,
  'committed': 2000,
  'balance': 17000,
  'updatedAt': '2026-11-01T10:00:00.000Z',
};

Map<String, Object?> sanctionJson(String id, String status) => {
  'id': id,
  'number': 'SAN/26-27/0000${id.substring(1)}',
  'purpose': 'Teacher pay for the quarter',
  'amount': 3000,
  'status': status,
  'head': {'id': 'h3', 'code': '2202.01.01', 'name': 'Salaries'},
  'fund': {'id': 'f1', 'name': 'State education grant'},
  'adminOrderNo': null,
  'financialOrderNo': null,
  'spent': 0,
  'committed': status == 'approved' ? 3000 : 0,
  'createdBy': 'Clerk',
  'createdAt': '2026-11-02T10:00:00.000Z',
};

const donorJson = {
  'id': 'dn1',
  'name': 'Meena Patel',
  'phone': '9825099999',
  'email': null,
  'pan': 'ABCDE1234F',
  'aadhaarMasked': null,
  'hasAadhaar': false,
  'address': 'Satellite, Ahmedabad',
  'isActive': true,
  'donated': 5000,
  'donations': 1,
  'updatedAt': '2026-11-01T10:00:00.000Z',
};

Map<String, Object?> donationJson(
  String id, {
  num amount = 5000,
  String mode = 'upi',
  bool cancelled = false,
}) => {
  'id': id,
  'receiptNo': 'DON/26-27/0000${id.substring(1)}',
  'donorId': 'dn1',
  'donorName': 'Meena Patel',
  'donorPhone': '9825099999',
  'date': _today,
  'amount': amount,
  'mode': mode,
  'reference': 'UTR 11223344',
  'fundId': null,
  'fundName': null,
  'purpose': 'General',
  'isCorpus': false,
  'tax80g': true,
  'deductionEligible': true,
  'warning': null,
  'fy': '2026-27',
  'status': cancelled ? 'cancelled' : 'posted',
  'warnings': <String>[],
};

Map<String, Object?> receiptJson() => {
  ...donationJson('d1'),
  'donor': {
    'id': 'dn1',
    'name': 'Meena Patel',
    'phone': '9825099999',
    'pan': 'ABCDE1234F',
    'aadhaarMasked': null,
    'address': 'Satellite, Ahmedabad',
  },
  'trust': {
    'name': 'Seva Trust',
    'address': '12 Ashram Road, Ahmedabad',
    'phone': '079 5550 1234',
    'pan': 'AAATS1234E',
  },
  'reg80g': {
    'no': 'AAATS1234E/12AB/2021-22/80G',
    'from': '2021-04-01',
    'to': '2031-03-31',
  },
  'footer': 'Thank you for your support.',
};

Map<String, Object?> ucJson() => {
  'fund': fundJson,
  'company': {'name': 'Municipal Office', 'address': 'Civic Centre, Ahmedabad'},
  'from': '2026-04-01',
  'to': '2027-03-31',
  'opening': 1000,
  'received': 20000,
  'receipts': [
    {
      'id': 'r1',
      'fundId': 'f1',
      'number': 'GRR/26-27/00001',
      'date': '2026-06-01',
      'amount': 20000,
      'source': 'grant',
    },
  ],
  'spentByHead': [
    {'headId': 'h3', 'code': '2202.01.01', 'name': 'Salaries', 'amount': 3000},
    {'headId': 'h4', 'code': '2202.01.02', 'name': 'Supplies', 'amount': 500},
  ],
  'spent': 3500,
  'closing': 17500,
  'returnUnspent': true,
  'refundDue': 17500,
};

/// The funds and donations endpoints; everything else goes to the shared backend.
class FundsFakeBackend implements HttpClientAdapter {
  FundsFakeBackend(Set<String> permissions)
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

  (int, Object?)? _route(RequestOptions o) {
    final key = '${o.method} ${o.path}';
    return switch (key) {
      'GET /funds/home' => (
        200,
        {
          'fy': '2026-27',
          'heads': [majorHead],
          'funds': [fundJson],
          'pendingSanctions': [sanctionJson('s1', 'pending')],
          'pendingReappropriations': 1,
          'overspendMode': 'warn',
          'totals': totalsJson,
        },
      ),
      'GET /funds/heads' => (
        200,
        {
          'fy': '2026-27',
          'years': ['2026-27'],
          'data': [majorHead, minorHead, salaryHead, suppliesHead],
          'totals': totalsJson,
        },
      ),
      'GET /funds/funds' => (200, _page([fundJson])),
      'GET /funds/sanctions' => (
        200,
        _page([sanctionJson('s1', 'pending'), sanctionJson('s2', 'approved')]),
      ),
      'GET /funds/reappropriations' => (200, _page([])),
      'POST /funds/reappropriations' => (
        201,
        {
          'id': 'ra1',
          'fy': '2026-27',
          'amount': 500,
          'orderNo': 'FD/45',
          'orderDate': _today,
          'reason': 'Savings',
          'status': 'approved',
          'fromHead': {'id': 'h3', 'code': '2202.01.01', 'name': 'Salaries'},
          'toHead': {'id': 'h4', 'code': '2202.01.02', 'name': 'Supplies'},
          'createdBy': 'Owner',
        },
      ),
      'GET /funds/settings' => (
        200,
        {
          'overspendMode': 'warn',
          'reg80gNo': 'AAATS1234E/12AB/2021-22/80G',
          'reg80gFrom': '2021-04-01',
          'reg80gTo': '2031-03-31',
          'trustPan': 'AAATS1234E',
          'receiptFooter': null,
        },
      ),
      'GET /funds/spendable' => (200, _page([])),
      'GET /funds/links' => (200, _page([])),
      'GET /funds/reports/budget-vs-actual' => (
        200,
        {
          'fy': '2026-27',
          'data': [majorHead, minorHead, salaryHead, suppliesHead],
          'totals': totalsJson,
        },
      ),
      'GET /funds/reports/fund-wise' => (
        200,
        {
          'from': '2026-04-01',
          'to': '2027-03-31',
          'data': [
            {
              'fundId': 'f1',
              'name': 'State education grant',
              'kind': 'grant',
              'totalAmount': 50000,
              'opening': 0,
              'received': 20000,
              'spent': 3000,
              'closing': 17000,
            },
          ],
          'totals': {
            'opening': 0,
            'received': 20000,
            'spent': 3000,
            'closing': 17000,
          },
        },
      ),
      'GET /funds/funds/f1/utilisation' => (200, ucJson()),
      'GET /donations/home' => (
        200,
        {
          'today': {
            'date': _today,
            'count': 1,
            'total': 5000,
            'byMode': {'cash': 0, 'upi': 5000, 'cheque': 0, 'bank': 0},
          },
          'year': {
            'fy': '2026-27',
            'count': 3,
            'total': 31500,
            'corpus': 0,
            'eligible80g': 30000,
          },
          'recent': [donationJson('d1')],
          'reg80g': {
            'no': 'AAATS1234E/12AB/2021-22/80G',
            'from': '2021-04-01',
            'to': '2031-03-31',
            'set': true,
          },
        },
      ),
      'GET /donations' => (
        200,
        _page([
          donationJson('d1'),
          donationJson('d2', amount: 2500, mode: 'cash'),
        ]),
      ),
      'GET /donations/d1' => (200, receiptJson()),
      'POST /donations' => (
        201,
        {...donationJson('d9'), 'warnings': <String>[]},
      ),
      'GET /donors' => (200, _page([donorJson])),
      'GET /donations/form-10bd' => (
        200,
        {
          'fy': '2026-27',
          'note':
              'Check before filing. Match the columns and codes with the current Form 10BD utility on the income tax portal.',
          'header': [
            'Sr No',
            'Section Code',
            'Donor ID Type',
            'Donor ID',
            'Donor Name',
            'Donor Address',
            'Donation Type',
            'Mode of Receipt',
            'Amount of Donation',
          ],
          'rows': [
            [
              1,
              '80G',
              'PAN',
              'ABCDE1234F',
              'Meena Patel',
              'Satellite',
              'Others',
              'Other modes',
              '5000.00',
            ],
          ],
          'skipped': <Object?>[],
          'total': 5000,
        },
      ),
      _ => null,
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.startsWith('/funds') ||
        options.path.startsWith('/donations') ||
        options.path.startsWith('/donors')) {
      calls.add(options);
    }
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

class FundsHarness {
  FundsHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final FundsFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

const managerPermissions = {
  'funds.view',
  'funds.entry',
  'funds.manage',
  'donations.view',
  'donations.create',
  'donations.manage',
};
const auditorPermissions = {'funds.view', 'donations.view'};

Future<FundsHarness> bootFunds(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  String location = '/funds',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms =
      permissions ?? {...FakeBackend.allPermissions, ...managerPermissions};
  final backend = FundsFakeBackend(perms);
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
          appBar: AppBar(title: const Text('OneMatrix')),
          body: child,
        ),
        routes: fundsRoutes(),
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
  return FundsHarness(tester, router, backend);
}
