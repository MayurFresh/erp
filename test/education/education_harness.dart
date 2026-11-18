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
import 'package:onematrix/features/education/education_routes.dart';

import '../support/fake_backend.dart';
import 'exam_fakes.dart';

const eduTestSizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

final _today = apiDate(DateTime.now());

const eduYear = {
  'id': 'y1',
  'name': '2026-27',
  'startDate': '2026-04-01',
  'endDate': '2027-03-31',
  'isCurrent': true,
  'updatedAt': '2026-04-01T00:00:00.000Z',
};

Map<String, Object?> classJson(
  String id,
  String label, {
  int students = 3,
  bool mine = false,
  bool marked = false,
}) => {
  'id': id,
  'yearId': 'y1',
  'kind': 'class',
  'name': label.split(' ').take(2).join(' '),
  'section': label.split(' ').last,
  'label': label,
  'capacity': 40,
  'isActive': true,
  'students': students,
  'mine': mine,
  'attendanceMarked': marked,
  'present': marked ? 28 : 0,
  'absent': marked ? 2 : 0,
  'late': 0,
  'updatedAt': '2026-04-01T00:00:00.000Z',
};

const studentRow = {
  'id': 's1',
  'admissionNo': 'ADM/26-27/00001',
  'name': 'Diya Patel',
  'classId': 'c1',
  'className': 'Class 5 A',
  'rollNo': '1',
  'sex': 'female',
  'guardianName': 'Hetal Patel',
  'guardianPhone': '9825055555',
  'status': 'active',
};

final studentJson = <String, Object?>{
  ...studentRow,
  'partyId': 'party1',
  'dob': '2015-06-01',
  'guardianRelation': 'Mother',
  'address': 'Navrangpura, Ahmedabad',
  'admissionDate': '2026-04-02',
  'notes': null,
  'updatedAt': '2026-04-02T00:00:00.000Z',
  'concessions': [
    {
      'id': 'k1',
      'headId': 'h1',
      'headName': 'Tuition fee',
      'kind': 'percent',
      'value': 50,
      'reason': 'Staff child',
    },
  ],
  'dues': {'due': 7000, 'overdue': 2000},
};

Map<String, Object?> rosterJson({bool marked = false}) => {
  'classId': 'c1',
  'label': 'Class 5 A',
  'date': _today,
  'marked': marked,
  'students': [
    for (final (i, n) in ['Asha Shah', 'Bhavin Mehta', 'Chirag Joshi'].indexed)
      {
        'studentId': 'st$i',
        'name': n,
        'rollNo': '${i + 1}',
        'admissionNo': 'ADM/26-27/0000${i + 1}',
        'status': 'present',
        'recorded': marked,
      },
  ],
};

const ledgerJson = {
  'billed': 11000,
  'paid': 4000,
  'due': 7000,
  'bills': [
    {
      'invoiceId': 'i1',
      'number': 'INV/26-27/00011',
      'label': 'Term 1',
      'date': '2026-04-10',
      'dueDate': '2026-04-10',
      'total': 6000,
      'paid': 4000,
      'due': 2000,
      'status': 'posted',
      'lateFee': 0,
      'overdue': true,
    },
    {
      'invoiceId': 'i2',
      'number': 'INV/26-27/00012',
      'label': 'Term 2',
      'date': '2026-04-10',
      'dueDate': '2026-12-10',
      'total': 5000,
      'paid': 0,
      'due': 5000,
      'status': 'posted',
      'lateFee': 0,
      'overdue': false,
    },
  ],
  'receipts': [
    {
      'id': 'p1',
      'number': 'RCT/26-27/00001',
      'date': '2026-04-12',
      'amount': 4000,
      'mode': 'upi',
      'reference': 'UPI123',
      'status': 'posted',
    },
  ],
};

Map<String, Object?> receiptJson() => {
  'school': {
    'name': 'Green Valley School',
    'address': 'Ashram Road, Ahmedabad',
    'phone': '0791234567',
  },
  'receipt': {
    'id': 'p1',
    'number': 'RCT/26-27/00001',
    'date': '2026-04-12',
    'amount': 4000,
    'mode': 'upi',
    'reference': 'UPI123',
    'status': 'posted',
  },
  'student': {
    'id': 's1',
    'name': 'Diya Patel',
    'admissionNo': 'ADM/26-27/00001',
    'rollNo': '1',
    'guardianName': 'Hetal Patel',
    'className': 'Class 5 A',
  },
  'paidFor': [
    {
      'invoiceNumber': 'INV/26-27/00011',
      'label': 'Term 1',
      'invoiceTotal': 6000,
      'paid': 4000,
      'heads': [
        {'description': 'Tuition fee - Term 1', 'amount': 5000},
        {'description': 'Transport fee - Term 1', 'amount': 1000},
      ],
    },
  ],
  'balance': 7000,
};

/// The education endpoints; everything else goes to the shared backend.
class EduFakeBackend implements HttpClientAdapter {
  EduFakeBackend(Set<String> permissions)
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
      'GET /education/home' => (
        200,
        {
          'today': _today,
          'year': eduYear,
          'classes': [
            classJson('c1', 'Class 5 A', mine: true),
            classJson('c2', 'Class 6 A', students: 30, marked: true),
          ],
          'feesCollectedToday': 7000,
          'duesTotal': 15000,
          'defaultersCount': 2,
        },
      ),
      'GET /education/years' => (200, _page([eduYear])),
      'GET /education/classes' => (
        200,
        _page([
          classJson('c1', 'Class 5 A', mine: true),
          classJson('c2', 'Class 6 A', students: 30),
        ]),
      ),
      'GET /education/staff' => (
        200,
        {
          'data': [
            {'id': 'u1', 'name': 'Meena Teacher'},
          ],
        },
      ),
      'GET /education/fee-heads' => (
        200,
        _page([
          {'id': 'h1', 'name': 'Tuition fee', 'gstRate': 0, 'isActive': true},
          {'id': 'h2', 'name': 'Transport fee', 'gstRate': 0, 'isActive': true},
        ]),
      ),
      'GET /education/classes/c1/fee-plan' => (
        200,
        {
          'id': 'pl1',
          'classId': 'c1',
          'name': 'Class 5 A fees',
          'late': {'kind': 'none', 'value': 0, 'headId': null},
          'instalments': [
            {
              'id': 'n1',
              'seq': 1,
              'label': 'Term 1',
              'dueDate': '2026-04-10',
              'lines': [
                {'headId': 'h1', 'amount': 5000},
                {'headId': 'h2', 'amount': 1000},
              ],
              'total': 6000,
            },
            {
              'id': 'n2',
              'seq': 2,
              'label': 'Term 2',
              'dueDate': '2026-12-10',
              'lines': [
                {'headId': 'h1', 'amount': 5000},
              ],
              'total': 5000,
            },
          ],
        },
      ),
      'GET /education/students' => (200, _page([studentRow])),
      'GET /education/students/s1' => (200, studentJson),
      'GET /education/students/s1/ledger' => (200, ledgerJson),
      'GET /education/students/s1/attendance' => (
        200,
        {
          'month': _today.substring(0, 7),
          'overall': {
            'present': 18,
            'absent': 2,
            'late': 1,
            'marked': 21,
            'percentage': 90.5,
          },
          'thisMonth': {
            'present': 9,
            'absent': 1,
            'late': 0,
            'marked': 10,
            'percentage': 90,
          },
          'days': [],
        },
      ),
      'GET /education/classes/c1/attendance' => (200, rosterJson()),
      'POST /education/classes/c1/attendance' => (
        200,
        rosterJson(marked: true),
      ),
      'POST /education/demands/generate' => (
        o.data is Map && (o.data as Map)['preview'] == true ? 200 : 201,
        {
          'label': 'Term 1',
          'dueDate': '2026-04-10',
          'count': 28,
          'alreadyBilled': 2,
          'nothingToBill': 0,
          'amount': 168000,
          'lateFeeCount': 0,
          'lateFeeAmount': 0,
          'concessionAmount': 5000,
          'created': (o.data is Map && (o.data as Map)['preview'] == true)
              ? 0
              : 28,
          'invoices': [],
        },
      ),
      'GET /education/dues' => (
        200,
        {
          'total': 1,
          'dueTotal': 7000,
          'overdueTotal': 2000,
          'data': [
            {
              ...studentRow,
              'due': 7000,
              'overdue': 2000,
              'oldestDue': '2026-04-10',
              'daysOverdue': 31,
              'reminder':
                  'Dear Hetal Patel, the fee for Diya Patel (Class 5 A) has Rs 2,000 overdue.',
            },
          ],
        },
      ),
      'POST /education/students/s1/collect' => (
        201,
        {
          'payment': {'id': 'p2', 'amount': 3000},
          'balance': 4000,
          'allocations': [],
        },
      ),
      'GET /education/receipts/p1' ||
      'GET /education/receipts/p2' => (200, receiptJson()),
      _ => examRoute(o),
    };
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    if (options.path.startsWith('/education')) calls.add(options);
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

class EduHarness {
  EduHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final EduFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }
}

const officePermissions = {
  'education.view',
  'education.admissions',
  'education.fees',
  'invoices.create',
  'payments.create',
};
const teacherPermissions = {'education.view', 'education.attendance'};

Future<EduHarness> bootEdu(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  String location = '/education',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final perms =
      permissions ??
      {
        ...FakeBackend.allPermissions,
        ...officePermissions,
        ...teacherPermissions,
        'education.manage',
      };
  final backend = EduFakeBackend(perms);
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
        routes: educationRoutes(),
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
  return EduHarness(tester, router, backend);
}
