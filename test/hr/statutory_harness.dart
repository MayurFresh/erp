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
import 'hr_harness.dart';

/// Statutory payroll endpoints; everything else goes to the HR fake.
class StatFake implements HttpClientAdapter {
  StatFake(Set<String> perms) : _hr = HrFakeBackend(perms);

  final HrFakeBackend _hr;
  final List<RequestOptions> calls = [];
  String fnfStatus = 'draft';

  int count(String method, String path) => calls.where((r) => r.method == method && r.path == path).length;
  RequestOptions last(String method, String path) => calls.lastWhere((r) => r.method == method && r.path == path);

  Map<String, Object?> get _fnf => {
    'id': 'f1',
    'number': 'FNF/26-27/00001',
    'employeeId': 'e1',
    'employeeName': 'Asha Verma',
    'employeeCode': 'E0001',
    'exitDate': '2026-11-10',
    'status': fnfStatus,
    'gross': 175000,
    'deductions': 21000,
    'tds': 1000,
    'net': 154000,
    'input': {'extraLines': []},
    'result': {
      'employee': {'name': 'Asha Verma', 'code': 'E0001', 'joiningDate': '2018-04-01'},
      'pendingSalaryPaid': false,
      'gratuity': {'eligible': true, 'completedYears': 8, 'countedYears': 9, 'payable': 155769},
      'leave': [
        {'leaveType': 'Earned leave', 'days': 5, 'amount': 5000},
      ],
      'oneTimeLines': [
        {'kind': 'earning', 'label': 'Gratuity', 'amount': 155769, 'taxable': false},
        {'kind': 'deduction', 'label': 'Notice period shortfall recovery', 'amount': 17333, 'taxable': false},
      ],
      'line': {
        'earnings': [
          {'name': 'Basic', 'amount': 10000},
        ],
        'pfEmployee': 1200,
        'tds': 1000,
        'warnings': [],
      },
    },
  };

  (int, Object?)? _route(RequestOptions o) {
    switch ('${o.method} ${o.path}') {
      case 'GET /payroll/statutory/settings':
        return (200, {'wagesRuleEnabled': false, 'wagesRuleFrom': '2025-11-21', 'wagesRulePercent': 50, 'minimumWage': 0, 'bonusPct': 8.33, 'bonusEligibilityCeiling': 21000, 'bonusCalcCeiling': 7000, 'gratuityYears': 5, 'gratuityFixedTermYears': 1, 'gratuityCap': 2000000, 'otMultiplier': 2, 'hoursPerDay': 8, 'notes': {'wagesRule': 'Off until you turn it on.'}});
      case 'PATCH /payroll/statutory/settings':
        return (200, {});
      case 'GET /payroll/statutory/rates':
        return (200, {'month': '2026-11', 'inForce': {'epf': {'ceiling': 25000}, 'esi': {'ceiling': 21000}}, 'data': [
          {'id': 'rr1', 'kind': 'epf', 'stateCode': null, 'effectiveFrom': '2027-04-01', 'config': {'ceiling': 30000}, 'source': 'company'},
          {'id': null, 'kind': 'epf', 'stateCode': null, 'effectiveFrom': '2000-01-01', 'config': {'ceiling': 15000}, 'source': 'built_in'},
        ]});
      case 'DELETE /payroll/statutory/rates/rr1':
        return (200, {'ok': true});
      case 'GET /payroll/gratuity/report':
        return (200, {'month': '2026-11', 'rules': {'years': 5, 'fixedTermYears': 1, 'cap': 2000000}, 'totals': {'accrued': 160000, 'payable': 155769, 'movement': 1500}, 'data': [
          {'employeeId': 'e1', 'code': 'E0001', 'name': 'Asha Verma', 'joiningDate': '2018-04-01', 'fixedTerm': false, 'wages': 30000, 'completedYears': 8, 'countedYears': 9, 'eligible': true, 'accrued': 155769, 'payable': 155769},
        ]});
      case 'GET /payroll/bonus/preview':
        return (200, {'fy': 2026, 'pct': 8.33, 'total': 583, 'data': [
          {'employeeId': 'e1', 'code': 'E0001', 'name': 'Asha Verma', 'monthlyWage': 12000, 'monthsPaid': 1, 'eligible': true, 'amount': 583, 'alreadyPaid': false},
          {'employeeId': 'e2', 'code': 'E0002', 'name': 'Ravi Nair', 'monthlyWage': 30000, 'monthsPaid': 1, 'eligible': false, 'reason': 'Wage is above the eligibility ceiling', 'amount': 0, 'alreadyPaid': false},
        ]});
      case 'POST /payroll/bonus/run':
        return (200, {'runId': 'r1', 'posted': 1, 'total': 583});
      case 'GET /payroll/leave-encashment/types':
        return (200, {'data': [
          {'leaveTypeId': 'lt1', 'code': 'EL', 'name': 'Earned leave', 'isPaid': true, 'encashable': true, 'maxDays': 5},
          {'leaveTypeId': 'lt2', 'code': 'LOP', 'name': 'Leave without pay', 'isPaid': false, 'encashable': false, 'maxDays': 0},
        ]});
      case 'GET /payroll/leave-encashment/preview':
        return (200, {'fy': 2026, 'total': 5000, 'data': [
          {'employeeId': 'e1', 'code': 'E0001', 'name': 'Asha Verma', 'leaveType': 'Earned leave', 'balance': 12, 'days': 5, 'amount': 5000},
        ]});
      case 'POST /payroll/leave-encashment/run':
        return (200, {'employees': 1, 'total': 5000});
      case 'GET /payroll/fnf':
        return (200, {'data': [_fnf]});
      case 'GET /payroll/fnf/f1':
        return (200, {..._fnf, 'company': {'name': 'Demo'}});
      case 'POST /payroll/fnf/f1/approve':
        fnfStatus = 'approved';
        return (200, _fnf);
      case 'POST /payroll/fnf/f1/pay':
        fnfStatus = 'paid';
        return (200, _fnf);
      case 'GET /payroll/shifts':
        return (200, {'data': [
          {'id': 'sh1', 'name': 'Day', 'startTime': '09:00', 'endTime': '18:00', 'breakMinutes': 60, 'isActive': true},
        ]});
      case 'GET /payroll/shift-log':
        return (200, {'month': '2026-11', 'data': [
          {'employeeId': 'e1', 'day': '2026-11-05', 'shiftId': 'sh1', 'otHours': 2},
        ], 'otTotals': []});
    }
    return null;
  }

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    final hit = _route(options);
    if (hit == null) return _hr.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString(jsonEncode(hit.$2), hit.$1, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

class StatHarness {
  StatHarness(this.tester, this.router, this.backend);
  final WidgetTester tester;
  final GoRouter router;
  final StatFake backend;

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

Future<StatHarness> bootStat(WidgetTester tester, Size size, String initial) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = StatFake({...FakeBackend.allPermissions, ...hrPerms});
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(baseUrl: 'http://fake/api/v1', tokenStore: store, httpClientAdapter: backend);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(appBar: AppBar(title: const Text('Progen')), body: child),
        routes: hrRoutes(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(ProviderScope(
    retry: (_, _) => null,
    overrides: [tokenStoreProvider.overrideWithValue(store), apiClientProvider.overrideWithValue(api)],
    child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return StatHarness(tester, router, backend);
}
