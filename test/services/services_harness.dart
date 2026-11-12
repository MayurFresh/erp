import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/business_profile.dart';
import 'package:progen_erp/core/money.dart';
import 'package:progen_erp/core/providers.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/job_cards/job_card_routes.dart';
import 'package:progen_erp/features/memberships/memberships_routes.dart';

import '../support/fake_backend.dart';

const servicesTestSizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

final _today = apiDate(DateTime.now());

Map<String, Object?> memberJson(
  String id,
  String name,
  String status, {
  String? flat,
  String? plan = 'Monthly',
}) => {
  'id': id,
  'memberNo': 'MEM/26-27/0000${id.substring(1)}',
  'name': name,
  'phone': '98250111$id',
  'flatNo': flat,
  'wing': flat == null ? null : 'A',
  'areaSqft': flat == null ? null : 1000,
  'status': status,
  'plan': plan == null ? null : {'id': 'pl1', 'name': plan},
  'startDate': _today,
  'endDate': _today,
  'daysLeft': 3,
};

const planJson = {
  'id': 'pl1',
  'name': 'Monthly',
  'billing': 'upfront',
  'rateBasis': 'fixed',
  'durationUnit': 'months',
  'durationCount': 1,
  'price': 1500,
  'gstRate': 18,
  'joiningFee': 500,
  'freezeDays': 5,
  'isActive': true,
};

Map<String, Object?> jobJson(
  String id,
  String status, {
  String asset = 'GJ01AB1234 - Maruti Swift',
}) => {
  'id': id,
  'number': 'JOB/26-27/0000${id.substring(1)}',
  'kind': 'vehicle',
  'asset': asset,
  'vehicleNo': 'GJ01AB1234',
  'make': 'Maruti',
  'model': 'Swift',
  'odometer': 42000,
  'complaints': 'Brake noise',
  'accessories': 'Spare wheel',
  'promisedDate': _today,
  'status': status,
  'nextStatuses': switch (status) {
    'estimate_sent' => ['approved', 'cancelled'],
    'in_progress' => ['ready', 'cancelled'],
    'ready' => ['delivered', 'in_progress'],
    _ => ['estimate_sent', 'cancelled'],
  },
  'customer': {'id': 'c1', 'name': 'Karan Shah', 'phone': '9825012345'},
  'technician': {'id': 'u2', 'name': 'Ramesh'},
  'overdue': false,
  'subtotal': 1950,
  'canEditLines': status != 'ready',
  'approvedAt': null,
  'approvedBy': null,
  'lines': [
    {
      'id': 'l1',
      'kind': 'part',
      'itemId': 'i1',
      'itemName': 'Brake pad',
      'qty': 2,
      'rate': 800,
      'discountPct': 0,
      'amount': 1600,
      'gstRate': 18,
      'issued': false,
      'unit': 'NOS',
    },
    {
      'id': 'l2',
      'kind': 'labour',
      'itemId': 'i2',
      'itemName': 'Brake service',
      'qty': 1,
      'rate': 350,
      'discountPct': 0,
      'amount': 350,
      'gstRate': 18,
      'issued': false,
      'unit': 'NOS',
    },
  ],
  'totals': {
    'parts': 1600,
    'labour': 350,
    'subtotal': 1950,
    'tax': 351,
    'total': 2301,
    'roundOff': 0,
  },
  'invoice': null,
  'statusMessage':
      'Hello Karan Shah, your GJ01AB1234 - Maruti Swift (job JOB/26-27/00001) at Test is received.',
  'updatedAt': '2026-11-12T09:00:00.000Z',
};

/// The memberships and job card endpoints; everything else goes to the shared backend.
class ServicesFakeBackend implements HttpClientAdapter {
  ServicesFakeBackend(Set<String> permissions, {this.checkinRefuses = false})
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final bool checkinRefuses;
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
      'GET /memberships/summary' => (
        200,
        {
          'active': 12,
          'expiring': 3,
          'expired': 2,
          'frozen': 1,
          'total': 15,
          'visitsToday': 7,
          'duesMembers': 2,
          'duesAmount': 4500,
        },
      ),
      'GET /memberships/plans' => (
        200,
        {
          'data': [planJson],
        },
      ),
      'GET /memberships/members' => (
        200,
        _page([
          memberJson('1', 'Aarav Mehta', 'active'),
          memberJson('2', 'Isha Patel', 'expiring'),
          memberJson('3', 'Rohan Shah', 'expired'),
        ]),
      ),
      'GET /memberships/bills/preview' => (
        200,
        {'count': 4, 'alreadyBilled': 1, 'skipped': []},
      ),
      'POST /memberships/bills/generate' => (
        200,
        {'created': 4, 'total': 9000},
      ),
      'GET /memberships/dues' => (
        200,
        {
          'total': 4500,
          'data': [
            {
              'memberId': '1',
              'memberNo': 'MEM/26-27/00001',
              'name': 'Aarav Mehta',
              'phone': '9825011111',
              'flatNo': null,
              'wing': null,
              'due': 4500,
              'bills': 2,
              'reminder': 'Dear Aarav Mehta, your membership dues are pending.',
            },
          ],
        },
      ),
      'POST /memberships/checkin' =>
        checkinRefuses
            ? (
                409,
                {
                  'error': {
                    'code': 'MEMBERSHIP_EXPIRED',
                    'message':
                        'Membership expired on 2026-10-01 (42 days ago).',
                    'details': {'name': 'Rohan Shah'},
                  },
                },
              )
            : (
                200,
                {
                  'ok': true,
                  'name': 'Aarav Mehta',
                  'memberNo': 'MEM/26-27/00001',
                  'endDate': _today,
                  'daysLeft': 3,
                  'expiringSoon': true,
                  'repeatToday': false,
                },
              ),
      'GET /job-cards' => (
        200,
        {
          'data': [
            {...jobJson('1', 'received'), 'asset': 'GJ01AB1234 - Maruti Swift'},
            {...jobJson('2', 'in_progress', asset: 'GJ05CD7788 - Hyundai i20')},
            {...jobJson('3', 'ready', asset: 'S/N 3567 - Samsung A54')},
          ],
          'counts': {'received': 1, 'in_progress': 1, 'ready': 1},
        },
      ),
      'GET /job-cards/technicians' => (
        200,
        {
          'data': [
            {'id': 'u2', 'name': 'Ramesh'},
          ],
        },
      ),
      'GET /job-cards/j1' => (200, jobJson('j1', 'estimate_sent')),
      'POST /job-cards/j1/status' => (200, jobJson('j1', 'approved')),
      _ => null,
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.startsWith('/memberships') ||
        options.path.startsWith('/job-cards')) {
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

class ServicesHarness {
  ServicesHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final ServicesFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

const memberDeskPermissions = {
  'memberships.view',
  'memberships.manage',
  'memberships.checkin',
  'invoices.create',
  'payments.create',
};
const jobAdvisorPermissions = {
  'job_cards.view',
  'job_cards.create',
  'invoices.create',
  'payments.create',
  'items.view',
};
const technicianPermissions = {'job_cards.work'};

Future<ServicesHarness> bootServices(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  String location = '/memberships',
  bool checkinRefuses = false,
  BusinessProfile? profile,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms =
      permissions ??
      {
        ...FakeBackend.allPermissions,
        ...memberDeskPermissions,
        ...jobAdvisorPermissions,
        'job_cards.work',
        'job_cards.manage',
      };
  final backend = ServicesFakeBackend(perms, checkinRefuses: checkinRefuses);
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
        routes: [...membershipRoutes(), ...jobCardRoutes()],
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
        if (profile != null) businessProfileProvider.overrideWithValue(profile),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return ServicesHarness(tester, router, backend);
}
