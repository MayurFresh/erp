import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/claims/loans_screens.dart';
import 'package:onematrix/features/hr/gratuity_provision_screen.dart';

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/hr/hr_routes.dart';

import '../controls/controls_harness.dart';
import '../hr/hr_harness.dart';
import '../hr/statutory_harness.dart';
import '../support/fake_backend.dart';

const narrow = Size(320, 1400);

Map<String, Object?> provision({bool posted = false}) => {
  'asOf': '2026-11-18',
  'cap': 2000000,
  'eligibleYears': 5,
  'skipped': [],
  'data': [
    {
      'employeeId': 'e1',
      'code': 'E0001',
      'name': 'Anil Kumar',
      'joiningDate': '2018-04-01',
      'completedYears': 8,
      'countedYears': 9,
      'wages': 30000,
      'underYears': false,
      'capped': false,
      'provision': 155769,
    },
    {
      'employeeId': 'e2',
      'code': 'E0002',
      'name': 'Bela Shah',
      'joiningDate': '2025-01-01',
      'completedYears': 1,
      'countedYears': 2,
      'wages': 20000,
      'underYears': true,
      'capped': false,
      'provision': 23077,
    },
  ],
  'totals': {
    'provision': 178846,
    'underYears': 23077,
    'balance': 100000,
    'toPost': 78846,
    'lastPostedOn': '2026-10-31',
    'lastPostedTotal': 100000,
    'changeSinceLast': 78846,
  },
  'posted': posted ? {'id': 'p1', 'amount': 78846} : null,
};

Map<String, Object?> loan() => {
  'id': 'l1',
  'number': 'LON/26-27/00001',
  'employeeName': 'Meera Rao',
  'kind': 'loan',
  'purpose': 'Bike',
  'amount': 12000,
  'interestRate': 12,
  'instalment': 2000,
  'status': 'active',
  'outstanding': 12120,
  'caReview': false,
  'nextDueMonth': '2026-11',
  'schedule': [
    {
      'seq': 1,
      'dueMonth': '2026-11',
      'principal': 1880,
      'interest': 120,
      'amount': 2000,
      'status': 'due',
      'paidAmount': 500,
    },
  ],
};

class ProvisionFake implements HttpClientAdapter {
  ProvisionFake(Set<String> perms, this.posted) : _other = StatFake(perms);
  final StatFake _other;
  final bool posted;
  final List<RequestOptions> calls = [];
  int posts = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async {
    if (o.path == '/payroll/gratuity/provision') {
      if (o.method == 'POST') {
        posts++;
        return _json(201, {'id': 'p1'});
      }
      calls.add(o);
      return _json(200, provision(posted: posted));
    }
    return _other.fetch(o, s, c);
  }

  ResponseBody _json(int status, Object body) => ResponseBody.fromString(
    jsonEncode(body),
    status,
    headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    },
  );

  @override
  void close({bool force = false}) {}
}

class ProvisionHarness {
  ProvisionHarness(this.api);
  final ProvisionFake api;
}

Future<ProvisionHarness> bootProvision(
  WidgetTester tester,
  Size size, {
  Set<String>? perms,
  bool posted = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = ProvisionFake(
    perms ?? {...FakeBackend.allPermissions, ...hrPerms},
    posted,
  );
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  final router = GoRouter(
    initialLocation: '/hr/gratuity-provision',
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(
          appBar: AppBar(title: const Text('OneMatrix')),
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
  return ProvisionHarness(backend);
}

void main() {
  test(
    'the provision date is today for this month and month end for others',
    () {
      expect(
        provisionDateOf('2026-11', now: DateTime(2026, 11, 18)),
        '2026-11-18',
      );
      expect(
        provisionDateOf('2026-10', now: DateTime(2026, 11, 18)),
        '2026-10-31',
      );
      expect(
        provisionDateOf('2026-02', now: DateTime(2026, 11, 18)),
        '2026-02-28',
      );
    },
  );

  testWidgets('provision table flags staff under five years and posts', (
    t,
  ) async {
    final h = await bootProvision(t, narrow);
    expect(find.text('Anil Kumar (E0001)'), findsOneWidget);
    expect(find.textContaining('under 5 years'), findsWidgets);
    expect(find.text('Provision needed'), findsOneWidget);
    expect(find.text('To post'), findsOneWidget);
    expect(find.textContaining('Change since'), findsOneWidget);
    expect(
      h.api.calls.last.queryParameters['asOf'],
      startsWith('${DateTime.now().year}-'),
    );
    await t.ensureVisible(find.text('Post'));
    await t.tap(find.text('Post'));
    await t.pumpAndSettle();
    expect(find.textContaining('adds'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Post').last);
    await t.pumpAndSettle();
    expect(h.api.posts, 1);
  });

  testWidgets('no Post button without payroll.approve', (t) async {
    await bootProvision(
      t,
      narrow,
      perms: {...FakeBackend.allPermissions, ...hrPerms}
        ..remove('payroll.approve'),
    );
    expect(find.text('Anil Kumar (E0001)'), findsOneWidget);
    expect(find.text('Post'), findsNothing);
  });

  testWidgets('Post is disabled once the date is posted', (t) async {
    await bootProvision(t, narrow, posted: true);
    expect(find.text('Already posted for this date'), findsOneWidget);
  });

  testWidgets('foreclosure dialog shows principal and interest', (t) async {
    final b = FakeControlsBackend()
      ..on('GET /loans/l1', loan())
      ..on('GET /accounts', {
        'data': [
          {'id': 'a1', 'name': 'Bank', 'subtype': 'bank'},
        ],
      })
      ..on('GET /loans/l1/foreclosure', {
        'payDate': '2026-11-15',
        'principal': 12000,
        'interest': 60,
        'total': 12060,
      })
      ..on('POST /loans/l1/foreclose', {'id': 'l1'});
    await pumpControls(
      t,
      const LoanDetailScreen(loanId: 'l1'),
      b,
      size: narrow,
      permissions: {'loans.manage'},
    );
    expect(find.textContaining('already recovered'), findsOneWidget);
    await t.tap(find.text('Foreclose'));
    await t.pumpAndSettle();
    await t.tap(find.text('Bank'));
    await t.pumpAndSettle();
    expect(find.text('Interest to date'), findsOneWidget);
    expect(find.text('Principal'), findsOneWidget);
    expect(find.textContaining('12,060'), findsOneWidget);
    await t.tap(find.widgetWithText(FilledButton, 'Foreclose'));
    await t.pumpAndSettle();
    expect(
      b.last('POST', '/loans/l1/foreclose')!.data,
      containsPair('payDate', '2026-11-15'),
    );
  });
}
