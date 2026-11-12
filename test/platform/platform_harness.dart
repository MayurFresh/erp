import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/providers.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/auth/login_screen.dart';
import 'package:progen_erp/features/platform/platform_routes.dart';
import 'package:progen_erp/features/shell/app_shell.dart';

import 'platform_fake_backend.dart';

const phone = Size(360, 740);
const desktop = Size(1440, 900);

class PlatformHarness {
  PlatformHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final PlatformFakeBackend backend;
  String? clipboard;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(find.textContaining('No fake for'), findsNothing, reason: reason);
  }

  /// Unmounts the app so the bell's periodic timer is cancelled.
  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 10));
  }

  Future<void> type(String key, String text) async {
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pump();
  }

  Future<void> tap(String key) async {
    final f = find.byKey(Key(key));
    await tester.ensureVisible(f);
    await tester.tap(f);
    await tester.pumpAndSettle();
  }
}

/// Boots the shell with [platformRoutes] and the open routes. [signedIn]
/// false starts without a refresh token (login screen).
Future<PlatformHarness> bootPlatform(
  WidgetTester tester,
  Size size, {
  String initial = '/notifications',
  bool signedIn = true,
  PlatformFakeBackend? backend,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final fake = backend ?? PlatformFakeBackend();
  final store = InMemoryTokenStore();
  if (signedIn) await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: fake,
  );
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      GoRoute(path: '/login', builder: (_, _) => const LoginScreen()),
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('Home stub')),
      ),
      ...platformOpenRoutes(),
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/approvals',
            builder: (_, _) => const Text('Approvals stub'),
          ),
          GoRoute(path: '/', builder: (_, _) => const Text('Root stub')),
          ...platformRoutes(),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);

  late final PlatformHarness harness;
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
  harness = PlatformHarness(tester, router, fake);
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
  return harness;
}
