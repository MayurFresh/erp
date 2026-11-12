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
import 'package:progen_erp/features/hr/hr_routes.dart';

import '../support/fake_backend.dart';

const hrPerms = {
  'payroll.view',
  'payroll.employees',
  'payroll.leave_approve',
  'payroll.run',
  'payroll.approve',
  'payroll.self',
};

/// HR and payroll endpoints with a little state; the rest goes to the shared fake.
class HrFakeBackend implements HttpClientAdapter {
  HrFakeBackend(Set<String> permissions)
    : _core = FakeBackend(permissions: permissions);

  final FakeBackend _core;
  final List<RequestOptions> calls = [];

  int count(String method, String path) =>
      calls.where((r) => r.method == method && r.path == path).length;

  RequestOptions last(String method, String path) =>
      calls.lastWhere((r) => r.method == method && r.path == path);

  String leaveStatus = 'pending';
  String runStatus = 'computed';

  Map<String, Object?> get _line => {
    'id': 'pl1',
    'employeeId': 'e1',
    'code': 'E0001',
    'name': 'Asha Verma',
    'department': 'Accounts',
    'workingDays': 30,
    'paidDays': 29,
    'lopDays': 1,
    'gross': 41000,
    'deductions': 6200,
    'net': 34800,
    'pfEmployee': 1800,
    'esiEmployee': 0,
    'pt': 200,
    'lwfEmployee': 0,
    'tds': 0,
    'otherDeductionsTotal': 0,
    'earnings': [
      {'name': 'Basic', 'amount': 20500},
      {'name': 'HRA', 'amount': 10250},
    ],
    'warnings': [],
    'overrides': [],
  };

  Map<String, Object?> get run => {
    'id': 'r1',
    'number': 'PAY/2611/001',
    'month': '2026-11',
    'status': runStatus,
    'gross': 41000,
    'deductions': 6200,
    'net': 34800,
    'employerCost': 46000,
    'employeeCount': 1,
    'canApprove': true,
    'lines': [_line],
    'adjustments': [],
    'skipped': [],
  };

  Map<String, Object?> _page(List<Object?> d) => {'data': d, 'total': d.length};

  static const _emp = {
    'id': 'e1',
    'code': 'E0001',
    'name': 'Asha Verma',
    'department': 'Accounts',
    'designation': 'Accountant',
    'status': 'active',
    'joiningDate': '2024-04-01',
    'monthlyGross': 41000,
    'aadhaarMasked': 'XXXX XXXX 1234',
    'phone': '9876543210',
  };

  (int, Object?)? _route(RequestOptions o) {
    final body = o.data is Map
        ? (o.data as Map).cast<String, Object?>()
        : <String, Object?>{};
    switch ('${o.method} ${o.path}') {
      case 'GET /hr/summary':
        return (
          200,
          {
            'headCount': 12,
            'joinersThisMonth': 1,
            'leaversThisMonth': 0,
            'pendingLeave': 1,
            'onLeaveToday': 0,
            'month': '2026-11',
            'payroll': [
              {'id': 'r1', 'status': runStatus, 'net': 34800, 'count': 1},
            ],
            'birthdays': [
              {'name': 'Ravi Nair', 'date': '2026-11-20'},
            ],
            'departments': [
              {'name': 'Accounts', 'count': 5},
            ],
          },
        );
      case 'GET /employees':
        return (200, _page([_emp]));
      case 'POST /employees':
        return (201, {..._emp, 'id': 'e2', 'name': body['name']});
      case 'GET /employees/e1':
        return (200, {..._emp, 'updatedAt': '2026-11-01T00:00:00Z'});
      case 'GET /employees/e1/salary':
        return (
          200,
          _page([
            {
              'id': 's1',
              'effectiveFrom': '2024-04-01',
              'ctcAnnual': 600000,
              'monthlyGross': 41000,
              'lines': [
                {'name': 'Basic', 'amount': 20500},
              ],
            },
          ]),
        );
      case 'POST /employees/e1/salary':
        return (201, {});
      case 'GET /payroll/components':
        return (
          200,
          _page([
            {
              'id': 'c1',
              'code': 'BASIC',
              'name': 'Basic',
              'kind': 'earning',
              'calc': 'fixed',
              'isBasic': true,
            },
            {
              'id': 'c2',
              'code': 'HRA',
              'name': 'HRA',
              'kind': 'earning',
              'calc': 'pct_basic',
              'percent': 50,
            },
          ]),
        );
      case 'GET /leave-types':
        return (
          200,
          _page([
            {
              'id': 'lt1',
              'code': 'CL',
              'name': 'Casual leave',
              'isPaid': true,
              'yearlyQuota': 12,
              'carryForwardLimit': 0,
            },
          ]),
        );
      case 'GET /holidays':
        return (
          200,
          _page([
            {'id': 'h1', 'date': '2026-11-09', 'name': 'Diwali'},
          ]),
        );
      case 'GET /payroll/settings':
        return (
          200,
          {
            'lopDivisor': 'calendar',
            'pfEnabled': true,
            'esiEnabled': true,
            'ptEnabled': true,
            'lwfEnabled': false,
            'pfRate': 12,
          },
        );
      case 'GET /employees/e1/leave-balances':
        return (
          200,
          _page([
            {
              'leaveTypeId': 'lt1',
              'code': 'CL',
              'name': 'Casual leave',
              'isPaid': true,
              'quota': 12,
              'taken': 2,
              'pending': 0,
              'balance': 10,
            },
          ]),
        );
      case 'GET /attendance-days':
        return (
          200,
          _page([
            {'employeeId': 'e1', 'day': '2026-11-02', 'status': 'present'},
          ]),
        );
      case 'PATCH /attendance-days':
        return (200, _page([]));
      case 'POST /employees/e1/leave-adjustments':
        return (201, {'ok': true});
      case 'GET /payroll/runs/r1/files/bank':
        return (200, 'a,b');
      case 'GET /leave-applications':
        return (
          200,
          _page([
            {
              'id': 'la1',
              'employeeId': 'e1',
              'employeeName': 'Asha Verma',
              'leaveTypeName': 'Casual leave',
              'fromDate': '2026-11-18',
              'toDate': '2026-11-19',
              'days': 2,
              'status': leaveStatus,
              'isPaid': true,
              'reason': 'Family function',
            },
          ]),
        );
      case 'POST /leave-applications':
        return (201, {});
      case 'POST /leave-applications/la1/approve':
        leaveStatus = 'approved';
        return (200, {});
      case 'GET /payroll/runs':
        return (200, _page([run]));
      case 'POST /payroll/runs':
        return (201, run);
      case 'GET /payroll/runs/r1':
        return (200, run);
      case 'POST /payroll/runs/r1/compute':
        return (200, run);
      case 'POST /payroll/runs/r1/approve':
        runStatus = 'approved';
        return (200, run);
      case 'POST /payroll/runs/r1/adjustments':
        return (200, run);
      case 'GET /payroll/runs/r1/statutory':
        return (
          200,
          {
            'pf': {
              'members': 1,
              'wages': 15000,
              'employee': 1800,
              'employer': 1800,
            },
            'pt': [
              {'state': 'KA', 'total': 200},
            ],
          },
        );
      case 'GET /payroll/me':
        return (
          200,
          {
            'employee': {'id': 'e1', 'code': 'E0001', 'name': 'Asha Verma'},
          },
        );
      case 'GET /payroll/payslips':
        return (
          200,
          _page([
            {
              'id': 'ps1',
              'employeeName': 'Asha Verma',
              'month': '2026-10',
              'gross': 41000,
              'net': 34800,
              'runStatus': 'posted',
            },
          ]),
        );
      case 'GET /payroll/payslips/ps1':
        return (
          200,
          {
            'month': '2026-10',
            'company': {'name': 'Demo'},
            'employee': _emp,
            'earnings': [
              {'name': 'Basic', 'amount': 20500},
              {'name': 'HRA', 'amount': 20500},
            ],
            'deductions': [
              {'name': 'Provident fund', 'amount': 1800},
            ],
            'employerContributions': [],
            'gross': 41000,
            'totalDeductions': 1800,
            'net': 39200,
            'paidDays': 31,
            'workingDays': 31,
            'lopDays': 0,
            'ytd': {},
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

class HrHarness {
  HrHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final HrFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<HrHarness> bootHr(
  WidgetTester tester,
  Size size, {
  String initial = '/hr',
  Set<String>? permissions,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = HrFakeBackend(
    permissions ?? {...FakeBackend.allPermissions, ...hrPerms},
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
        routes: hrRoutes(),
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
  return HrHarness(tester, router, backend);
}
