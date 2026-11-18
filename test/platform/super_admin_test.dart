import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/api_client.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/auth/auth_models.dart';
import 'package:onematrix/features/auth/session.dart';
import 'package:onematrix/features/platform/super_routes.dart';
import 'package:onematrix/features/shell/app_shell.dart';
import 'package:onematrix/features/shell/nav.dart';

import 'super_fake_backend.dart';

const phone = Size(390, 844);
const desktop = Size(1440, 900);

Future<(GoRouter, SuperFakeBackend, List<String?>)> boot(
  WidgetTester tester,
  Size size, {
  String initial = '/platform/overview',
  bool admin = true,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fake = SuperFakeBackend(admin: admin);
  final store = InMemoryTokenStore();
  await store.writeRefreshToken('refresh-1');
  final api = ApiClient(
    baseUrl: 'http://fake/api/v1',
    tokenStore: store,
    httpClientAdapter: fake,
  );
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(path: '/other', builder: (_, _) => const Text('Other stub')),
          ...superAdminRoutes(),
        ],
      ),
    ],
  );
  addTearDown(router.dispose);
  final clipboard = <String?>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard.add((call.arguments as Map)['text'] as String?);
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
  return (router, fake, clipboard);
}

void main() {
  group('menu', () {
    Me me({required bool admin}) => Me.fromJson({
      'user': {'id': 'u', 'name': 'A B', 'email': 'a@b.in'},
      'isPlatformAdmin': admin,
      'companies': <Object?>[],
    });

    test(
      'Platform group shows only for admins, first, and is the home page',
      () {
        final admin = SessionState(me: me(admin: true));
        final plain = SessionState(me: me(admin: false));
        expect(admin.permissions.can(Perm.platformAdmin), isTrue);
        expect(plain.permissions.can(Perm.platformAdmin), isFalse);
        final groups = visibleNavGroups(admin.permissions);
        expect(groups.first.label, 'Platform');
        expect(groups.first.entries.map((e) => e.label), [
          'Overview',
          'Accounts',
          'Activity',
        ]);
        expect(visibleNavGroups(plain.permissions), isEmpty);
        expect(homePath(admin.permissions), '/platform/overview');
        expect(
          requiredPermission('/platform/accounts/abc'),
          Perm.platformAdmin,
        );
      },
    );

    testWidgets('admin without a company sees the Platform menu', (
      tester,
    ) async {
      await boot(tester, desktop);
      expect(find.text('Platform'), findsWidgets);
      expect(find.text('Accounts'), findsWidgets);
      expect(find.text('Activity'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a normal user sees no Platform menu', (tester) async {
      await boot(tester, desktop, initial: '/other', admin: false);
      expect(find.text('Other stub'), findsOneWidget);
      expect(find.text('Platform'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  for (final (name, size) in [
    ('320', Size(320, 700)),
    ('390', phone),
    ('1440', desktop),
  ]) {
    group('screens at $name', () {
      testWidgets('overview', (tester) async {
        await boot(tester, size);
        expect(find.text('Platform overview'), findsOneWidget);
        expect(find.text('Accounts'), findsWidgets);
        expect(find.text('Suspended'), findsWidgets);
        expect(find.text('New accounts per month'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('No fake for'), findsNothing);
      });

      testWidgets('accounts list searches and filters', (tester) async {
        final (_, fake, _) = await boot(
          tester,
          size,
          initial: '/platform/accounts',
        );
        expect(find.text('Spice Route Kitchen'), findsOneWidget);
        expect(find.text('Patel Kirana Store'), findsOneWidget);
        await tester.enterText(find.byType(TextField).first, 'patel');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        expect(find.text('Spice Route Kitchen'), findsNothing);
        expect(find.text('Patel Kirana Store'), findsOneWidget);
        expect(
          fake.requests.where((r) => r.queryParameters['q'] == 'patel'),
          isNotEmpty,
        );
        expect(tester.takeException(), isNull);
      });
    });
  }

  testWidgets('suspend needs a reason, then suspends', (tester) async {
    final (_, fake, _) = await boot(
      tester,
      desktop,
      initial: '/platform/accounts/t1',
    );
    expect(find.text('Spice Route Kitchen'), findsWidgets);
    await tester.tap(find.byKey(const Key('suspend-tenant')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reason-ok')));
    await tester.pumpAndSettle();
    expect(find.text('Give a reason of at least 3 characters'), findsOneWidget);
    expect(fake.called('PATCH', '/platform/tenants/t1'), isFalse);

    await tester.enterText(find.byKey(const Key('reason-field')), 'Unpaid');
    await tester.tap(find.byKey(const Key('reason-ok')));
    await tester.pumpAndSettle();
    final patch = fake.requests.lastWhere((r) => r.method == 'PATCH');
    expect(patch.data, {'status': 'suspended', 'reason': 'Unpaid'});
    expect(find.byKey(const Key('suspended-note')), findsOneWidget);
    expect(find.byKey(const Key('reactivate-tenant')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reset link is confirmed, shown and copyable', (tester) async {
    final (_, fake, clipboard) = await boot(
      tester,
      phone,
      initial: '/platform/accounts/t1',
    );
    await tester.ensureVisible(find.byKey(const Key('user-menu-u1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('user-menu-u1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset link'));
    await tester.pumpAndSettle();
    expect(fake.called('POST', '/platform/users/u1/reset-link'), isFalse);
    await tester.tap(find.byKey(const Key('confirm-ok')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reset-link-text')), findsOneWidget);
    await tester.tap(find.byKey(const Key('reset-link-copy')));
    await tester.pumpAndSettle();
    expect(
      clipboard.single,
      'https://app.example/#/reset-password?token=abc123',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('activity lists platform changes', (tester) async {
    await boot(tester, phone, initial: '/platform/activity');
    expect(find.text('Suspended account'), findsOneWidget);
    expect(find.textContaining('Reason: Unpaid'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
