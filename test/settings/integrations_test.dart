import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/providers.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/settings/integrations_screen.dart';

class IntegrationsFake implements HttpClientAdapter {
  final requests = <RequestOptions>[];
  final keys = <Map<String, Object?>>[
    {
      'id': 'k1',
      'name': 'Zapier',
      'prefix': 'pk_live_ab',
      'roleName': 'Accountant',
      'lastUsedAt': null,
      'expiresAt': null,
      'revokedAt': null,
    },
  ];
  final hooks = <Map<String, Object?>>[
    {
      'id': 'h1',
      'url': 'https://example.com/hook',
      'description': 'Orders',
      'events': ['invoice.created'],
      'isActive': true,
      'lastDelivery': null,
    },
  ];

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions o,
    Stream<Uint8List>? s,
    Future<void>? c,
  ) async {
    requests.add(o);
    final key = '${o.method} ${o.path}';
    (int, Object?) r = switch (key) {
      'GET /api-keys' => (200, {'data': keys}),
      'GET /roles' => (
        200,
        {
          'data': [
            {
              'id': 'r1',
              'name': 'Accountant',
              'isSystem': true,
              'permissions': <String>[],
            },
          ],
          'total': 1,
        },
      ),
      'POST /api-keys' => (
        201,
        {
          'id': 'k2',
          'name': 'New',
          'prefix': 'pk_live_cd',
          'key': 'pk_live_cd_SECRETVALUE',
        },
      ),
      'POST /api-keys/k1/revoke' => () {
        keys[0]['revokedAt'] = '2026-11-12T10:00:00Z';
        return (200, keys[0]);
      }(),
      'GET /webhooks' => (200, {'data': hooks}),
      'GET /webhooks/events' => (
        200,
        {
          'data': ['invoice.created', 'payment.received'],
        },
      ),
      'POST /webhooks' => (201, {'id': 'h2', 'secret': 'whsec_ABC123'}),
      'POST /webhooks/h1/test' => (202, {'deliveryId': 'd1'}),
      _ => (
        404,
        {
          'error': {'code': 'NOT_FOUND', 'message': 'No fake for $key'},
        },
      ),
    };
    return ResponseBody.fromString(
      jsonEncode(r.$2),
      r.$1,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }
}

Future<IntegrationsFake> boot(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = IntegrationsFake();
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: InMemoryTokenStore(),
    httpClientAdapter: fake,
  );
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: AppTheme.light,
        home: const Scaffold(body: IntegrationsScreen()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  for (final size in [const Size(320, 700), const Size(1440, 900)]) {
    testWidgets('create and revoke an API key at ${size.width.toInt()}', (
      tester,
    ) async {
      final fake = await boot(tester, size);
      expect(find.text('Zapier'), findsOneWidget);

      await tester.tap(find.byKey(const Key('key-new')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('key-save')));
      await tester.pump();
      expect(find.text('Required'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('key-name')), 'Reports');
      await tester.tap(find.byKey(const Key('key-role')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accountant').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('key-save')));
      await tester.pumpAndSettle();
      final post = fake.requests.lastWhere(
        (r) => r.method == 'POST' && r.path == '/api-keys',
      );
      expect(post.data, {'name': 'Reports', 'roleId': 'r1'});
      expect(find.text('pk_live_cd_SECRETVALUE'), findsOneWidget);
      await tester.tap(find.byKey(const Key('secret-done')));
      await tester.pumpAndSettle();
      expect(find.text('pk_live_cd_SECRETVALUE'), findsNothing);

      await tester.tap(find.byKey(const Key('revoke-k1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('revoke-confirm')));
      await tester.pumpAndSettle();
      expect(fake.requests.any((r) => r.path == '/api-keys/k1/revoke'), isTrue);
      expect(find.text('Revoked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('create and test a webhook at ${size.width.toInt()}', (
      tester,
    ) async {
      final fake = await boot(tester, size);
      await tester.tap(find.text('Webhooks'));
      await tester.pumpAndSettle();
      expect(find.text('https://example.com/hook'), findsOneWidget);

      await tester.tap(find.byKey(const Key('hook-new')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('hook-url')),
        'https://hooks.example.org/in',
      );
      await tester.tap(find.byKey(const Key('hook-save')));
      await tester.pump();
      expect(find.text('Pick at least one event'), findsOneWidget);
      await tester.tap(find.byKey(const Key('hook-event-payment.received')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('hook-save')));
      await tester.pumpAndSettle();
      final post = fake.requests.lastWhere(
        (r) => r.method == 'POST' && r.path == '/webhooks',
      );
      expect(post.data, {
        'url': 'https://hooks.example.org/in',
        'events': ['payment.received'],
      });
      expect(find.text('whsec_ABC123'), findsOneWidget);
      await tester.tap(find.byKey(const Key('secret-done')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('hook-menu-h1')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send test'));
      await tester.pumpAndSettle();
      expect(fake.requests.any((r) => r.path == '/webhooks/h1/test'), isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
