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
import 'package:onematrix/features/platform_extras/extras_repository.dart';
import 'package:onematrix/features/platform_extras/platform_extras_routes.dart';

import '../support/fake_backend.dart';

const sizes = [Size(320, 700), Size(390, 844), Size(1440, 900)];

const reportJson = {
  'id': 'r1', 'name': 'Weekly sales', 'report': 'sales_register', 'reportLabel': 'Sales register',
  'filters': {'period': 'previous_week'}, 'frequency': 'weekly', 'weekday': 1, 'monthDay': null, 'time': '08:00',
  'recipientUserIds': <String>[], 'recipientEmails': ['boss@x.in'], 'isActive': true,
  'nextRunAt': '2026-11-23T02:30:00.000Z', 'lastRunAt': null,
};
const linkJson = {
  'id': 'l1', 'invoiceId': 'i1', 'invoiceNumber': 'INV/26-27/00001', 'partyName': 'Acme Traders', 'amount': 1180.0,
  'status': 'paid', 'shortUrl': 'https://rzp.io/i/abc', 'whatsappUrl': 'https://wa.me/919000000050?text=x',
  'expiresAt': '2026-11-20T00:00:00.000Z', 'paidAt': '2026-11-16T05:00:00.000Z', 'fee': 23.6,
};

class Backend implements HttpClientAdapter {
  Backend() : _core = FakeBackend(permissions: {...FakeBackend.allPermissions, 'integrations.manage'});
  final FakeBackend _core;
  final calls = <RequestOptions>[];

  int count(String m, String p) => calls.where((r) => r.method == m && r.path == p).length;
  Map<String, Object?> body(String m, String p) {
    final d = calls.lastWhere((r) => r.method == m && r.path == p).data;
    return d is Map ? Map<String, Object?>.from(d) : jsonDecode(d as String) as Map<String, Object?>;
  }

  (int, Object?)? _route(RequestOptions o) => switch ('${o.method} ${o.path}') {
    'GET /search' => (200, {'q': 'acme', 'groups': [
      {'kind': 'party', 'label': 'Parties', 'items': [{'id': 'p1', 'title': 'Acme Traders', 'subtitle': 'customer · 9000000050', 'route': '/parties/p1'}]},
      {'kind': 'invoice', 'label': 'Invoices', 'items': [{'id': 'i1', 'title': 'INV/26-27/00001', 'subtitle': 'Acme Traders · ₹1,180', 'route': '/invoices/i1'}]},
    ]}),
    'GET /scheduled-reports' => (200, {'data': [reportJson]}),
    'GET /scheduled-reports/catalogue' => (200, {'data': [
      {'key': 'sales_register', 'label': 'Sales register', 'ranged': true, 'allowed': true},
      {'key': 'profit_loss', 'label': 'Profit and loss', 'ranged': true, 'allowed': true},
    ]}),
    'GET /scheduled-reports/r1/runs' => (200, {'data': [
      {'id': 'x1', 'trigger': 'manual', 'status': 'sent', 'recipients': 1, 'rowCount': 4, 'error': null, 'ranAt': '2026-11-16T05:00:00.000Z'},
    ]}),
    'POST /scheduled-reports/r1/run' => (200, {'id': 'x2', 'trigger': 'manual', 'status': 'sent', 'recipients': 1, 'rowCount': 4, 'error': null, 'ranAt': '2026-11-16T05:00:00.000Z'}),
    'PATCH /scheduled-reports/r1' => (200, reportJson),
    'POST /scheduled-reports' => (201, reportJson),
    'GET /sms/settings' => (200, {'driver': 'log', 'enabled': false, 'dltEntityId': null, 'senderId': null, 'templates': [
      {'template': 'payment_link', 'label': 'Payment link to a customer', 'dltTemplateId': null, 'text': null},
    ]}),
    'PATCH /sms/settings' => (200, {'driver': 'log', 'enabled': true, 'dltEntityId': '1101234567890', 'senderId': null, 'templates': <Object?>[]}),
    'GET /payment-gateways' => (200, {'data': [{
      'id': 'g1', 'provider': 'razorpay', 'isActive': false, 'accountId': null, 'mode': 'test',
      'credentials': [{'key': 'keyId', 'label': 'Key id', 'secret': false, 'set': true}, {'key': 'keySecret', 'label': 'Key secret', 'secret': true, 'set': true}, {'key': 'webhookSecret', 'label': 'Webhook secret', 'secret': true, 'set': false}],
      'webhookUrl': 'http://x/api/v1/webhooks/payment-gateways/g1',
    }, {
      'id': 'g2', 'provider': 'cashfree', 'isActive': false, 'accountId': null, 'mode': null,
      'credentials': [{'key': 'keyId', 'label': 'App id', 'secret': false, 'set': false}, {'key': 'keySecret', 'label': 'Secret key', 'secret': true, 'set': false}],
      'webhookUrl': 'http://x/api/v1/webhooks/payment-gateways/g2',
    }]}),
    'PATCH /payment-gateways/cashfree' => (200, {'id': 'g2', 'provider': 'cashfree', 'isActive': false, 'credentials': <Object?>[]}),
    'PATCH /payment-gateways/razorpay' => (200, {'id': 'g1', 'isActive': false, 'credentials': <Object?>[]}),
    'GET /payment-links' => (200, {'data': [linkJson], 'total': 1}),
    _ => null,
  };

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls.add(options);
    final r = _route(options);
    if (r == null) return _core.fetch(options, requestStream, cancelFuture);
    return ResponseBody.fromString(jsonEncode(r.$2), r.$1, headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
  }

  @override
  void close({bool force = false}) {}
}

Future<(WidgetTester, Backend, GoRouter)> boot(WidgetTester tester, Size size, String location) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final backend = Backend();
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(baseUrl: 'http://fake/api/v1', tokenStore: store, httpClientAdapter: backend);
  final router = GoRouter(
    initialLocation: location,
    routes: [
      ShellRoute(
        builder: (context, state, child) => Scaffold(appBar: AppBar(title: const Text('OneMatrix'), actions: const [SizedBox(width: 200, child: GlobalSearchField())]), body: child),
        routes: platformExtrasRoutes(),
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
  return (tester, backend, router);
}

void clean(WidgetTester t) {
  expect(t.takeException(), isNull);
  expect(find.textContaining('No fake for'), findsNothing);
}

void main() {
  test('models parse', () {
    final r = ScheduledReport.fromJson(reportJson);
    expect(r.when, 'Every Monday at 08:00');
    expect(r.period, 'previous_week');
    expect(r.toJson()['weekday'], 1);
    expect(PaymentLink.fromJson(linkJson).statusLabel, 'Paid');
    expect(platformExtrasNavEntries.map((e) => e.label), contains('Scheduled reports'));
    expect(platformExtrasRoutes(), isNotEmpty);
  });

  for (final size in sizes) {
    final w = size.width.toInt();

    testWidgets('search lists groups and opens a result at $w px', (tester) async {
      final (_, backend, router) = await boot(tester, size, '/search?q=acme');
      expect(find.byKey(const ValueKey('search-input')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(find.text('Parties'), findsOneWidget);
      expect(find.text('Acme Traders'), findsOneWidget);
      expect(backend.count('GET', '/search'), greaterThanOrEqualTo(1));
      await tester.tap(find.text('Acme Traders'));
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/parties/p1');
      clean(tester);
    });

    testWidgets('scheduled reports list and form save at $w px', (tester) async {
      final (_, backend, router) = await boot(tester, size, '/scheduled-reports');
      expect(find.text('Weekly sales'), findsOneWidget);
      expect(find.textContaining('Every Monday at 08:00'), findsOneWidget);
      await tester.tap(find.text('Weekly sales'));
      await tester.pumpAndSettle();
      expect(find.text('Scheduled report'), findsOneWidget);
      expect(find.text('Sent to 1, 4 rows', skipOffstage: false), findsOneWidget);
      await tester.tap(find.text('Send now'));
      await tester.pumpAndSettle();
      expect(backend.count('POST', '/scheduled-reports/r1/run'), 1);
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(backend.count('PATCH', '/scheduled-reports/r1'), 1);
      expect(backend.body('PATCH', '/scheduled-reports/r1')['recipientEmails'], ['boss@x.in']);
      expect(router.routeInformationProvider.value.uri.path, '/scheduled-reports');
      clean(tester);
    });

    testWidgets('new schedule needs an email at $w px', (tester) async {
      final (_, backend, _) = await boot(tester, size, '/scheduled-reports/new');
      await tester.enterText(find.byKey(const ValueKey('report-name')), 'Daily');
      await tester.tap(find.text('Save schedule'));
      await tester.pumpAndSettle();
      expect(find.text('Add at least one email address.'), findsOneWidget);
      expect(backend.count('POST', '/scheduled-reports'), 0);
      clean(tester);
    });

    testWidgets('sms settings save at $w px', (tester) async {
      final (_, backend, _) = await boot(tester, size, '/settings/sms');
      expect(find.textContaining('log only'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('dlt-entity')), '1101234567890');
      await tester.tap(find.text('Save settings'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(backend.body('PATCH', '/sms/settings')['dltEntityId'], '1101234567890');
      clean(tester);
    });

    testWidgets('Cashfree keys are saved to their own route at $w px', (tester) async {
      final (_, backend, _) = await boot(tester, size, '/settings/payment-gateway');
      await tester.tap(find.byKey(const ValueKey('gw-provider-cashfree')));
      await tester.pumpAndSettle();
      expect(find.text('App id'), findsOneWidget);
      expect(find.byKey(const ValueKey('gw-webhook-secret')), findsNothing);
      expect(find.textContaining('payment-gateways/g2', skipOffstage: false), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('gw-key-id')), 'TEST1234abcd');
      await tester.enterText(find.byKey(const ValueKey('gw-key-secret')), 'cf_secret_123456');
      await tester.tap(find.text('Save settings'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      final sent = backend.body('PATCH', '/payment-gateways/cashfree');
      expect(sent['keyId'], 'TEST1234abcd');
      expect(sent['keySecret'], 'cf_secret_123456');
      expect(backend.count('PATCH', '/payment-gateways/razorpay'), 0);
      clean(tester);
    });

    testWidgets('payment gateway settings and links at $w px', (tester) async {
      final (_, backend, router) = await boot(tester, size, '/settings/payment-gateway');
      expect(find.text('Test mode'), findsOneWidget);
      expect(find.textContaining('payment-gateways/g1', skipOffstage: false), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('gw-webhook-secret')), 'whsec_123456');
      await tester.tap(find.text('Save settings'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      expect(backend.body('PATCH', '/payment-gateways/razorpay')['webhookSecret'], 'whsec_123456');
      expect(backend.body('PATCH', '/payment-gateways/razorpay').containsKey('keySecret'), isFalse);
      router.go('/payment-links');
      await tester.pumpAndSettle();
      expect(find.textContaining('INV/26-27/00001'), findsOneWidget);
      expect(find.text('Paid'), findsWidgets);
      clean(tester);
    });
  }
}
