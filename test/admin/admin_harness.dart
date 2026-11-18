import 'package:onematrix/features/platform/notifications_screen.dart'
    show bellPollIntervalProvider;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/admin_routes.dart';
import 'package:onematrix/features/shell/app_shell.dart';

import 'admin_fake_backend.dart';

/// Phone, tablet, small laptop and desktop.
const adminTestWidths = [
  Size(360, 740),
  Size(768, 1024),
  Size(1024, 768),
  Size(1440, 900),
];

class AdminHarness {
  AdminHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final AdminFakeBackend backend;

  /// Text copied with `Clipboard.setData`.
  String? clipboard;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  /// Fails on layout errors (overflow etc.) and on unknown requests.
  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(
      find.textContaining('No fake for'),
      findsNothing,
      reason: 'unexpected request: $reason',
    );
  }
}

/// Boots the real shell (session restore, [AppShell]) with [adminRoutes]
/// against [AdminFakeBackend] at [size]. A stub `/users` route with `new`
/// comes first, as in `router.dart`, so `/users/:id` ordering is covered.
Future<AdminHarness> bootAdmin(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  String initial = '/accounts',
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final backend = AdminFakeBackend(permissions: permissions);
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
        builder: (context, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/users',
            builder: (_, _) => const Center(child: Text('Users list stub')),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, _) => const Center(child: Text('New user stub')),
              ),
            ],
          ),
          ...adminRoutes(),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  late final AdminHarness harness;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        harness.clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  harness = AdminHarness(tester, router, backend);

  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        apiClientProvider.overrideWithValue(api),
        bellPollIntervalProvider.overrideWithValue(null),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return harness;
}
