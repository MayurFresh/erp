import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

void main() {
  for (final size in testWidths) {
    testWidgets('dashboard with analytics at ${size.width.toInt()} px', (
      tester,
    ) async {
      final app = await bootApp(tester, size);
      await app.go('/dashboard');
      app.expectClean('dashboard');
      expect(find.text('Sales and purchases by month'), findsOneWidget);
      expect(find.text('Receivables ageing'), findsOneWidget);
      expect(find.text('Top customers'), findsOneWidget);
      expect(find.text('Top items'), findsOneWidget);
      expect(find.text('Recent invoices'), findsOneWidget);
      expect(find.text('Net profit'), findsOneWidget);
    });
  }

  testWidgets('role without reports.view keeps the plain tiles and no charts', (
    tester,
  ) async {
    final perms = FakeBackend.allPermissions
        .where((p) => p != 'reports.view')
        .toSet();
    final app = await bootApp(tester, testWidths[3], permissions: perms);
    await app.go('/dashboard');
    app.expectClean('dashboard without reports');
    expect(find.text('Sales and purchases by month'), findsNothing);
    expect(find.text('Sales this month'), findsOneWidget);
    expect(find.text('Top items this month'), findsOneWidget);
  });

  testWidgets('hidden money fields leave no tile', (tester) async {
    final perms = FakeBackend.allPermissions
        .where((p) => p != 'reports.view')
        .toSet();
    final app = await bootApp(
      tester,
      testWidths[3],
      permissions: perms,
      v11: false,
    );
    await app.go('/dashboard');
    expect(find.text('Receivables'), findsNothing);
    expect(find.text('Cash and bank'), findsNothing);
  });
}
