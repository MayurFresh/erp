import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/providers.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/platform/notifications_screen.dart'
    show bellPollIntervalProvider;
import 'package:progen_erp/features/construction/data/construction_http.dart';
import 'package:progen_erp/features/construction/data/photo_source.dart';
import 'package:progen_erp/features/construction_routes.dart';
import 'package:progen_erp/widgets/layout.dart';

import 'construction_fake_backend.dart';

/// Phone, tablet, small laptop and desktop.
const constructionTestWidths = [
  Size(360, 740),
  Size(768, 1024),
  Size(1024, 768),
  Size(1440, 900),
];

class ConstructionHarness {
  ConstructionHarness(this.tester, this.router, this.backend);

  final WidgetTester tester;
  final GoRouter router;
  final ConstructionFakeBackend backend;

  Future<void> go(String location) async {
    router.go(location);
    await tester.pumpAndSettle();
  }

  /// Fails on layout errors (overflow etc.) and on unknown requests.
  void expectClean(String reason) {
    final error = tester.takeException();
    if (error is FlutterError) {
      // Show where an overflow comes from (takeException hides the report).
      debugPrint(error.diagnostics.map((d) => d.toString()).join('\n'));
    }
    expect(error, isNull, reason: reason);
    expect(
      find.textContaining('No fake for'),
      findsNothing,
      reason: 'unexpected request: $reason',
    );
  }
}

/// A [PhotoSource] that returns a fixed photo (no plugin needed).
class FakePhotoSource extends PhotoSource {
  int picks = 0;

  @override
  Future<PickedPhoto?> pick({required bool camera}) async {
    picks++;
    return PickedPhoto(
      name: camera ? 'camera.png' : 'gallery.png',
      mimeType: 'image/png',
      bytes: ConstructionFakeBackend.png,
    );
  }
}

/// Boots [constructionRoutes] inside a stand-in for the app shell against
/// [ConstructionFakeBackend] at [size]. The session is restored for real
/// (screens watch it).
Future<ConstructionHarness> bootConstruction(
  WidgetTester tester,
  Size size, {
  String initial = '/projects',
  Set<String>? permissions,
  PhotoSource? photos,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final backend = ConstructionFakeBackend(permissions: permissions);
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: backend,
  );
  final http = BridgedConstructionHttp(api, httpClientAdapter: backend);
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) => _TestShell(child: child),
        routes: constructionRoutes(),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        tokenStoreProvider.overrideWithValue(store),
        bellPollIntervalProvider.overrideWithValue(null),
        apiClientProvider.overrideWithValue(api),
        constructionHttpProvider.overrideWithValue(http),
        photoSourceProvider.overrideWithValue(
          photos ?? const UnavailablePhotoSource(),
        ),
      ],
      child: MaterialApp.router(theme: AppTheme.light, routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return ConstructionHarness(tester, router, backend);
}

/// Same geometry as `AppShell` (app bar; 256 px sidebar from
/// [kWideLayout]) so content widths match the real app, without depending
/// on the shared menu, which other packs are editing.
class _TestShell extends StatelessWidget {
  const _TestShell({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kWideLayout;
    return Scaffold(
      appBar: AppBar(title: const Text('Progen ERP')),
      body: wide
          ? Row(
              children: [
                const SizedBox(width: 256),
                const VerticalDivider(width: 1),
                Expanded(child: child),
              ],
            )
          : child,
    );
  }
}
