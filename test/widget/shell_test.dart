import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/permissions.dart';
import 'package:progen_erp/core/theme.dart';
import 'package:progen_erp/features/auth/session.dart';
import 'package:progen_erp/features/shell/app_shell.dart';

import '../support/fixtures.dart';

void main() {
  Future<void> pumpShell(
    WidgetTester tester,
    SessionState session, {
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        key: UniqueKey(),
        overrides: [
          sessionProvider.overrideWith(() => FakeSessionController(session)),
        ],
        child: MaterialApp(
          theme: AppTheme.light,
          home: const AppShell(
            location: '/items',
            child: Center(child: Text('page body')),
          ),
        ),
      ),
    );
    await tester.pump(); // let the fake session resolve
  }

  final basePerms = {Perm.dashboardView, Perm.itemsView, Perm.invoicesView};

  testWidgets('hides menu entries without the permission (wide)', (
    tester,
  ) async {
    await pumpShell(tester, signedIn(basePerms));
    expect(find.text('page body'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Items'), findsOneWidget);
    expect(find.text('Invoices'), findsOneWidget);
    expect(find.text('Users'), findsNothing);
    expect(find.text('Audit log'), findsNothing);
    expect(find.text('Stock'), findsNothing);
  });

  testWidgets('shows the entry once the permission is granted', (tester) async {
    await pumpShell(tester, signedIn({...basePerms, Perm.usersManage}));
    expect(find.text('Users'), findsOneWidget);
  });

  testWidgets('phone layout uses a drawer with the same filtering', (
    tester,
  ) async {
    await pumpShell(tester, signedIn(basePerms), size: const Size(360, 720));
    // Title shows the current section; the menu lives in the drawer.
    expect(find.text('Items'), findsOneWidget);
    expect(find.text('Dashboard'), findsNothing);

    await tester.tap(find.byTooltip('Open navigation menu'));
    await tester.pumpAndSettle();
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('Users'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('company switcher appears only with several companies', (
    tester,
  ) async {
    await pumpShell(tester, signedIn(basePerms));
    expect(find.byTooltip('Switch company'), findsNothing);

    await pumpShell(
      tester,
      signedIn(
        basePerms,
        extra: [membership(basePerms, id: 'c2', name: 'Second Co')],
      ),
    );
    expect(find.byTooltip('Switch company'), findsOneWidget);
  });
}
