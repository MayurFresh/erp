import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_backend.dart';
import 'channels_harness.dart';

void main() {
  for (final size in chWidths) {
    final w = size.width.toInt();

    testWidgets('order inbox at $w: orders, statuses, filter and retry', (
      tester,
    ) async {
      final h = await bootCh(tester, size);
      await h.go('/channels/orders');
      expect(find.text('#1001'), findsOneWidget);
      expect(find.text('#1002'), findsOneWidget);
      expect(find.text('Done'), findsWidgets);
      expect(find.text('Needs attention'), findsWidgets);
      expect(find.textContaining('Map this SKU'), findsWidgets);
      h.expectClean('inbox');

      await tester.tap(find.byKey(const Key('orders-filter-failed')));
      await tester.pumpAndSettle();
      expect(
        h.backend.calls.any(
          (r) =>
              r.path == '/channels/inbox' &&
              r.queryParameters['status'] == 'failed',
        ),
        isTrue,
      );
      expect(find.text('#1001'), findsNothing);
      await tester.ensureVisible(find.text('Try again').first);
      await tester.tap(find.text('Try again').first);
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/channels/inbox/in2/retry'), 1);
      h.expectClean('after retry');
    });

    testWidgets('settlement at $w: expected against received, tax held, post', (
      tester,
    ) async {
      final h = await bootCh(
        tester,
        size,
        initial: '/channels/settlements/st1',
      );
      expect(find.text('Settlement SET-1'), findsOneWidget);
      expect(find.text('Expected and received, by order'), findsOneWidget);
      expect(find.text('#1001'), findsOneWidget);
      expect(find.text('#9000'), findsOneWidget);
      expect(find.textContaining('TCS (GST section 52)'), findsOneWidget);
      expect(find.textContaining('Check rates before filing'), findsOneWidget);
      h.expectClean('settlement');

      await tester.ensureVisible(find.byKey(const Key('settlement-post')));
      await tester.tap(find.byKey(const Key('settlement-post')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Post').last);
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/channels/settlements/st1/post'), 1);
      h.expectClean('after post');
    });
  }

  testWidgets('import shows a preview before anything is created', (
    tester,
  ) async {
    final h = await bootCh(
      tester,
      const Size(390, 844),
      initial: '/channels/import?channelId=ch1',
    );
    expect(find.byKey(const Key('import-run')), findsNothing);
    await tester.enterText(
      find.byKey(const Key('csv-text')),
      'order_id,sku,qty,unit_price\n#2001,AMZ-BOTTLE,2,118',
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('import-preview')));
    await tester.tap(find.byKey(const Key('import-preview')));
    await tester.pumpAndSettle();
    expect(
      h.backend.calls.where(
        (r) =>
            r.path == '/channels/ch1/orders/import' &&
            (r.data as Map)['dryRun'] == true,
      ),
      hasLength(1),
    );
    expect(find.text('#2001'), findsOneWidget);
    expect(find.text('Will create'), findsOneWidget);
    expect(find.text('Cannot import'), findsOneWidget);
    expect(find.text('Already imported'), findsWidgets);
    expect(find.text('Create 1 order'), findsOneWidget);
    expect(
      h.backend.calls.where(
        (r) =>
            r.path == '/channels/ch1/orders/import' &&
            (r.data as Map)['dryRun'] == false,
      ),
      isEmpty,
    );

    await tester.ensureVisible(find.byKey(const Key('import-run')));
    await tester.tap(find.byKey(const Key('import-run')));
    await tester.pumpAndSettle();
    expect(find.text('Import finished'), findsOneWidget);
    h.expectClean('import');
  });

  for (final size in const [Size(320, 640), Size(390, 844), Size(1440, 900)]) {
    testWidgets('channels and SKU mapping at ${size.width.toInt()}', (
      tester,
    ) async {
      final h = await bootCh(tester, size);
      expect(find.text('Amazon (file import)'), findsOneWidget);
      expect(find.text('Map SKUs (1)'), findsOneWidget);
      h.expectClean('channels');
      await h.go('/channels/mapping?channelId=ch1');
      expect(find.text('AMZ-NEW'), findsOneWidget);
      expect(find.text('AMZ-ECO-COMBO'), findsOneWidget);
      expect(find.textContaining('2 x Bamboo toothbrush pack'), findsOneWidget);
      h.expectClean('mapping');
    });
  }

  testWidgets('a user without manage rights sees no buttons that write', (
    tester,
  ) async {
    final perms = {...FakeBackend.allPermissions, 'channels.view'};
    final h = await bootCh(tester, const Size(390, 844), permissions: perms);
    expect(find.byKey(const Key('channel-add')), findsNothing);
    await h.go('/channels/settlements/st1');
    expect(find.byKey(const Key('settlement-post')), findsNothing);
    await h.go('/channels/import');
    expect(find.textContaining('do not have access'), findsOneWidget);
  });
}
