import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:progen_erp/app.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/providers.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/router.dart';

import 'fake_backend.dart';

/// Phone, tablet, small laptop and desktop.
const testWidths = [
  Size(360, 740),
  Size(768, 1024),
  Size(1024, 768),
  Size(1440, 900),
];

class AppHarness {
  AppHarness(this.tester, this.container, this.backend);

  final WidgetTester tester;
  final ProviderContainer container;
  final FakeBackend backend;

  GoRouter get router => container.read(routerProvider);

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
    // Pages under a sub-route (e.g. the list below `/items/new`) may start
    // a request in the last frame; let its zero-length timer run.
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
  }

  /// Fails on layout errors (e.g. RenderFlex overflow) and on requests the
  /// fake backend does not know.
  void expectClean(String reason) {
    expect(tester.takeException(), isNull, reason: reason);
    expect(
      find.textContaining('No fake for'),
      findsNothing,
      reason: 'unexpected request: $reason',
    );
  }
}

/// Boots the real app (router, shell, session restore) against
/// [FakeBackend] at [size].
Future<AppHarness> bootApp(
  WidgetTester tester,
  Size size, {
  Set<String>? permissions,
  bool restore = true,
  bool v11 = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final backend = FakeBackend(permissions: permissions, v11: v11);
  final store = InMemoryTokenStore();
  if (restore) await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        apiClientProvider.overrideWithValue(api),
      ],
      child: const ProgenApp(),
    ),
  );
  await tester.pumpAndSettle();
  final container = ProviderScope.containerOf(
    tester.element(find.byType(ProgenApp)),
  );
  return AppHarness(tester, container, backend);
}
