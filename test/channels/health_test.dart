import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'channels_harness.dart';

void main() {
  for (final size in chWidths) {
    final w = size.width.toInt();

    testWidgets('connection health at $w: status, write-only credentials', (
      tester,
    ) async {
      final h = await bootCh(tester, size, initial: '/channels/sh1/health');
      expect(find.text('Connection health'), findsOneWidget);
      expect(find.textContaining('Last pull:'), findsOneWidget);
      expect(find.textContaining('Rate limited'), findsOneWidget);
      expect(find.text('Check connection'), findsOneWidget);
      expect(
        find.text('Queues and errors', skipOffstage: false),
        findsOneWidget,
      );
      expect(
        find.text('Queues and errors', skipOffstage: false),
        findsOneWidget,
      );
      // Saved values are never shown, only a marker.
      h.expectClean('health');

      await tester.ensureVisible(find.byKey(const Key('health-check')));
      await tester.tap(find.byKey(const Key('health-check')));
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/channels/sh1/check'), 1);

      await tester.ensureVisible(find.byKey(const Key('health-sync')));
      await tester.tap(find.byKey(const Key('health-sync')));
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/channels/sh1/sync'), 1);

      await tester.ensureVisible(find.byKey(const Key('health-push-stock')));
      await tester.tap(find.byKey(const Key('health-push-stock')));
      await tester.pumpAndSettle();
      expect(
        h.backend.calls.any(
          (r) =>
              r.method == 'PATCH' &&
              r.path == '/channels/sh1' &&
              (r.data as Map)['pushStock'] == true,
        ),
        isTrue,
      );

      await tester.dragUntilVisible(
        find.byKey(const Key('cred-accessToken')),
        find.byType(ListView).first,
        const Offset(0, -150),
      );
      expect(find.text('Saved'), findsNWidgets(2));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('cred-accessToken')))
            .obscureText,
        isTrue,
      );
      // Saving needs every field.
      await tester.ensureVisible(find.byKey(const Key('cred-save')));
      await tester.ensureVisible(find.byKey(const Key('cred-save')));
      await tester.tap(find.byKey(const Key('cred-save')));
      await tester.pumpAndSettle();
      expect(h.backend.count('PATCH', '/channels/sh1/credentials'), 0);
      await tester.enterText(
        find.byKey(const Key('cred-shopDomain')),
        'x.myshopify.com',
      );
      await tester.enterText(
        find.byKey(const Key('cred-accessToken')),
        'shpat_1',
      );
      await tester.ensureVisible(find.byKey(const Key('cred-save')));
      await tester.tap(find.byKey(const Key('cred-save')));
      await tester.pumpAndSettle();
      expect(h.backend.count('PATCH', '/channels/sh1/credentials'), 1);

      ScaffoldMessenger.of(
        tester.element(find.byKey(const Key('cred-save'))),
      ).clearSnackBars();
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('cred-remove')));
      await tester.tap(find.byKey(const Key('cred-remove')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cred-remove-confirm')));
      await tester.pumpAndSettle();
      expect(h.backend.count('DELETE', '/channels/sh1/credentials'), 1);
      expect(find.text('Queues and errors'), findsOneWidget);
      h.expectClean('after actions');
    });
  }
}
