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
import 'package:progen_erp/features/crm/crm_models.dart';
import 'package:progen_erp/features/crm/crm_routes.dart';

import '../support/fake_backend.dart';

const crmAllPerms = {
  'crm.view',
  'crm.manage',
  'crm.all',
  'crm.settings',
  'quotations.view',
  'quotations.manage',
};

String _iso(DateTime t) => isoWithOffset(t);

Map<String, Object?> activity(
  String id, {
  required String title,
  required String subject,
  String kind = 'call',
  String? phone,
  double value = 0,
  String? source,
  bool overdue = false,
  Duration due = Duration.zero,
  String? dealId,
  String? leadId,
  Map<String, Object?>? balance,
}) => {
  'id': id,
  'kind': kind,
  'subject': subject,
  'notes': null,
  'dueAt': _iso(DateTime.now().add(due)),
  'doneAt': null,
  'outcome': null,
  'durationMin': null,
  'leadId': leadId,
  'dealId': dealId,
  'partyId': null,
  'title': title,
  'value': value,
  'source': source,
  'phone': phone,
  'ownerId': 'u1',
  'ownerName': 'Sunil Patil',
  'overdue': overdue,
  'createdAt': _iso(DateTime.now().subtract(const Duration(days: 3))),
  'partyBalance': balance,
};

Map<String, Object?> get todayJson => {
  'counts': {'dueToday': 6, 'overdue': 2, 'newLeads': 3},
  'overdue': [
    activity(
      'a1',
      title: 'Shree Ganesh Hardware',
      subject: 'Call back about quotation Q-0031',
      phone: '9876543210',
      value: 184500,
      source: 'indiamart',
      overdue: true,
      due: const Duration(days: -1),
      dealId: 'd1',
      balance: {'owes': 42000, 'overdue': 42000, 'oldestOverdueDays': 12},
    ),
    activity(
      'a3',
      title: 'Meena Patel',
      subject: 'Send revised AMC quote',
      phone: '9123456780',
      value: 36000,
      source: 'website',
      overdue: true,
      due: const Duration(days: -3),
      leadId: 'l2',
    ),
  ],
  'today': [
    activity(
      'a2',
      title: 'Rathi Builders',
      subject: 'Site visit at Wakad',
      kind: 'visit',
      value: 620000,
      due: const Duration(hours: 1),
      dealId: 'd2',
    ),
  ],
  'upcoming': <Object?>[],
  'month': {
    'month': '2026-11',
    'target': 600000,
    'won': 420000,
    'openCount': 14,
    'openValue': 1840000,
    'weightedValue': 790000,
  },
};

Map<String, Object?> deal(
  String id,
  String title,
  String stageId,
  String stage,
  double value, {
  bool overdue = false,
  int days = 2,
  Map<String, Object?>? balance,
}) => {
  'id': id,
  'title': title,
  'partyId': 'p1',
  'partyName': 'Shree Ganesh Hardware',
  'contactId': null,
  'leadId': null,
  'stageId': stageId,
  'stageName': stage,
  'stageKind': 'open',
  'value': value,
  'probability': null,
  'effectiveProbability': 50,
  'weightedValue': value / 2,
  'expectedClose': null,
  'ownerId': 'u1',
  'ownerName': 'Sunil Patil',
  'status': 'open',
  'lostReason': null,
  'wonAt': null,
  'lostAt': null,
  'stageChangedAt': _iso(DateTime.now()),
  'daysInStage': days,
  'notes': null,
  'nextFollowUp': {
    'id': 'a1',
    'kind': 'call',
    'subject': 'Call back about Q-0031',
    'dueAt': _iso(DateTime.now().subtract(const Duration(days: 1))),
  },
  'followUpOverdue': overdue,
  'partyBalance': balance,
  'quotationCount': 1,
};

const stagesJson = [
  {'id': 's1', 'name': 'New', 'probability': 10, 'kind': 'open', 'sort': 1, 'isActive': true},
  {'id': 's2', 'name': 'Contacted', 'probability': 20, 'kind': 'open', 'sort': 2, 'isActive': true},
  {'id': 's3', 'name': 'Quotation sent', 'probability': 50, 'kind': 'open', 'sort': 3, 'isActive': true},
  {'id': 's4', 'name': 'Negotiation', 'probability': 70, 'kind': 'open', 'sort': 4, 'isActive': true},
  {'id': 's5', 'name': 'Won', 'probability': 100, 'kind': 'won', 'sort': 5, 'isActive': true},
  {'id': 's6', 'name': 'Lost', 'probability': 0, 'kind': 'lost', 'sort': 6, 'isActive': true},
];

Map<String, Object?> leadJson(String id, String name) => {
  'id': id,
  'name': name,
  'companyName': 'Arjun Traders',
  'phone': '9000011111',
  'email': null,
  'city': 'Pune',
  'stateCode': '27',
  'requirement': 'PVC pipes, 200 m',
  'estimatedValue': 74250,
  'source': 'justdial',
  'sourceRef': null,
  'ownerId': 'u1',
  'ownerName': 'Sunil Patil',
  'status': 'new',
  'lostReason': null,
  'partyId': null,
  'partyName': null,
  'dealId': null,
  'firstContactAt': null,
  'convertedAt': null,
  'nextFollowUp': null,
  'createdAt': _iso(DateTime.now().subtract(const Duration(hours: 2))),
  'updatedAt': _iso(DateTime.now()),
};

const statsJson = {
  'openCount': 14,
  'openValue': 1840000,
  'weightedValue': 790000,
  'wonCount': 5,
  'wonValue': 420000,
  'lostCount': 3,
  'winRate': 62.5,
  'avgDealSize': 84000,
  'avgCycleDays': 18,
  'target': 600000,
  'achievement': 420000,
  'gap': 180000,
  'achievementPct': 70,
  'coverage': 10.2,
  'avgResponseHours': 2.5,
  'stageConversion': [
    {'stageId': 's1', 'name': 'New', 'entered': 10, 'advanced': 6, 'rate': 60},
  ],
  'bySource': [
    {'source': 'indiamart', 'leads': 20, 'converted': 5, 'rate': 25},
  ],
  'lostReasons': [
    {'reason': 'Price too high', 'count': 2},
  ],
  'byOwner': [
    {'ownerId': 'u1', 'name': 'Sunil Patil', 'wonValue': 420000, 'wonCount': 5, 'openValue': 900000},
  ],
};

const overviewJson = {
  'party': {'id': 'p1', 'name': 'Shree Ganesh Hardware', 'phone': '9876543210', 'email': null, 'gstin': null},
  'owes': 42000,
  'overdue': 42000,
  'oldestOverdueDays': 12,
  'creditLimit': 200000,
  'creditUsedPct': 21,
  'sales12m': 680000,
  'avgDaysToPay': 21,
  'lastInvoiceDate': '2026-08-30',
  'openDeals': <Object?>[],
  'contacts': <Object?>[],
  'timeline': [
    {
      'at': '2026-11-10T10:00:00+05:30',
      'kind': 'quotation',
      'title': 'Q-0031 sent',
      'detail': 'valid 15 days',
      'refId': 'q1',
      'amount': 184500,
    },
  ],
};

/// CRM endpoints; everything else goes to the shared fake backend.
class CrmFakeBackend implements HttpClientAdapter {
  CrmFakeBackend(Set<String> permissions)
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final List<RequestOptions> calls = [];

  /// First `POST /crm/leads` without `force` answers 409.
  bool duplicate = false;

  RequestOptions last(String method, String path) =>
      calls.lastWhere((r) => r.method == method && r.path == path);

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  Map<String, Object?> _page(List<Object?> d) => {'data': d, 'total': d.length};

  (int, Object?)? _route(RequestOptions o) {
    final deals = [
      deal('d1', 'Shree Ganesh Hardware', 's3', 'Quotation sent', 184500,
          overdue: true,
          days: 15,
          balance: {'owes': 42000, 'overdue': 42000, 'oldestOverdueDays': 12}),
      deal('d2', 'Rathi Builders, Wakad tower', 's4', 'Negotiation', 620000),
    ];
    switch ('${o.method} ${o.path}') {
      case 'GET /crm/today':
        return (200, todayJson);
      case 'GET /crm/pipeline':
        return (
          200,
          {
            'openCount': 14,
            'openValue': 1840000,
            'weightedValue': 790000,
            'stages': [
              {'stageId': 's1', 'name': 'New', 'probability': 10, 'count': 5, 'value': 610000, 'weightedValue': 61000},
              {'stageId': 's3', 'name': 'Quotation sent', 'probability': 50, 'count': 4, 'value': 520000, 'weightedValue': 260000},
              {'stageId': 's4', 'name': 'Negotiation', 'probability': 70, 'count': 2, 'value': 370000, 'weightedValue': 259000},
            ],
          },
        );
      case 'GET /crm/stages':
        return (200, {'data': stagesJson});
      case 'GET /crm/settings':
        return (
          200,
          {
            'defaultOwnerId': null,
            'lostReasons': ['Price too high', 'Chose a competitor'],
            'hasIndiamartKey': true,
            'indiamartLastPullAt': null,
            'indiamartLastError': null,
          },
        );
      case 'PATCH /crm/settings':
        return (200, o.data);
      case 'GET /crm/owners':
        return (200, {'data': [{'id': 'u1', 'name': 'Sunil Patil'}]});
      case 'GET /crm/targets':
        return (
          200,
          {
            'month': o.queryParameters['month'],
            'rows': [
              {'userId': null, 'userName': 'Company', 'amount': 600000},
            ],
          },
        );
      case 'PATCH /crm/targets':
        return (200, o.data);
      case 'POST /crm/indiamart/pull':
        return (200, {'added': 3, 'skipped': 2, 'lastPullAt': _iso(DateTime.now())});
      case 'GET /crm/leads':
        return (200, _page([leadJson('l1', 'Arjun Traders')]));
      case 'GET /crm/leads/l1':
        return (
          200,
          {
            ...leadJson('l1', 'Arjun Traders'),
            'activities': <Object?>[],
            'matches': [
              {'partyId': 'p1', 'name': 'Arjun Traders Pvt', 'phone': '9000011111', 'gstin': null, 'balance': 0},
            ],
          },
        );
      case 'POST /crm/leads':
        if (duplicate && (o.data as Map)['force'] != true) {
          return (
            409,
            {
              'error': {
                'code': 'DUPLICATE_LEAD',
                'message': 'Duplicate',
                'details': {
                  'existing': {'id': 'l9', 'name': 'Arjun Traders', 'status': 'contacted'},
                },
              },
            },
          );
        }
        return (201, leadJson('l1', 'Arjun Traders'));
      case 'POST /crm/leads/l1/convert':
        return (200, {'lead': leadJson('l1', 'Arjun Traders'), 'partyId': 'p1', 'dealId': 'd1'});
      case 'GET /crm/deals':
        return (200, _page(deals));
      case 'GET /crm/deals/d1':
        return (
          200,
          {
            ...deals.first,
            'activities': [
              activity('a1', title: 'Shree Ganesh Hardware', subject: 'Call back about Q-0031', phone: '9876543210', overdue: true, due: const Duration(days: -1), dealId: 'd1'),
            ],
            'quotations': [
              {'id': 'q1', 'number': 'Q-0031', 'kind': 'quotation', 'status': 'sent', 'total': 184500, 'quoteDate': '2026-11-10'},
            ],
            'stageHistory': [
              {'fromStage': 'Contacted', 'toStage': 'Quotation sent', 'changedAt': '2026-11-10T10:00:00+05:30', 'changedBy': 'Sunil Patil'},
            ],
          },
        );
      case 'POST /crm/deals/d1/stage':
      case 'POST /crm/deals/d1/won':
      case 'POST /crm/deals/d1/lost':
      case 'POST /crm/activities':
      case 'POST /crm/activities/a1/done':
        return (200, {'ok': true});
      case 'GET /crm/parties/p1/overview':
        return (200, overviewJson);
      case 'GET /crm/stats':
        return (200, statsJson);
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

class CrmHarness {
  CrmHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final CrmFakeBackend backend;

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<CrmHarness> bootCrm(
  WidgetTester tester,
  Size size, {
  String initial = '/crm',
  Set<String>? permissions,
  void Function(CrmFakeBackend)? setup,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = CrmFakeBackend(
    permissions ?? {...FakeBackend.allPermissions, ...crmAllPerms},
  );
  setup?.call(backend);
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
        routes: [
          ...crmRoutes(),
          GoRoute(
            path: '/quotations',
            builder: (_, _) => const Text('Quotations list'),
          ),
        ],
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
  return CrmHarness(tester, router, backend);
}
