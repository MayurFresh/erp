import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rest_harness.dart';

void main() {
  group('floor view', () {
    for (final size in const [Size(320, 700), Size(390, 844), Size(1440, 900)]) {
      testWidgets('shows areas, tables and running amounts at ${size.width.toInt()}px', (tester) async {
        final h = await bootRest(tester, size);
        expect(find.text('Ground floor'), findsOneWidget);
        expect(find.text('Terrace'), findsOneWidget);
        for (final t in ['T1', 'T2', 'T3', 'R1']) {
          expect(find.text(t), findsOneWidget, reason: t);
        }
        expect(find.textContaining('650'), findsWidgets);
        expect(find.textContaining('1,260'), findsWidgets);
        expect(find.textContaining('Bill printed'), findsWidgets);
        expect(find.textContaining('2 ready'), findsOneWidget);
        h.expectClean('floor at ${size.width}');
      });
    }

    testWidgets('opens the order of an occupied table', (tester) async {
      final h = await bootRest(tester, const Size(390, 844));
      await tester.tap(find.text('T1'));
      await tester.pumpAndSettle();
      expect(h.router.state.uri.path, '/restaurant/order/o1');
      h.expectClean('order opened from floor');
    });
  });

  group('order screen', () {
    testWidgets('adds items and sends one KOT even on a double tap (wide)', (tester) async {
      final h = await bootRest(tester, const Size(1440, 900), initial: '/restaurant/order/o1');
      expect(find.text('Table T1'), findsOneWidget);
      expect(find.text('Paneer Tikka'), findsOneWidget);
      expect(find.text('Send to kitchen'), findsOneWidget);

      await tester.tap(find.text('Paneer Tikka'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Butter Chicken'));
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/restaurant/orders/o1/lines'), 2);
      expect(find.text('Not sent yet (2)'), findsOneWidget);
      expect(find.text('Send to kitchen (2)'), findsOneWidget);

      // Tapping Paneer Tikka again raises the unsent quantity instead of adding a line.
      await tester.tap(find.descendant(of: find.byType(GridView), matching: find.text('Paneer Tikka')));
      await tester.pumpAndSettle();
      expect(h.backend.count('PATCH', '/restaurant/orders/o1/lines/l1'), 1);
      expect(h.backend.lines.first['qty'], 2.0);

      final send = find.text('Send to kitchen (2)');
      await tester.tap(send);
      await tester.tap(send, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/restaurant/orders/o1/send-kot'), 1);
      expect(find.text('With the kitchen'), findsOneWidget);
      expect(find.textContaining('KOT 12'), findsWidgets);
      h.expectClean('order screen');
    });

    testWidgets('filters the menu by search and category', (tester) async {
      final h = await bootRest(tester, const Size(1440, 900), initial: '/restaurant/order/o1');
      await tester.tap(find.widgetWithText(ChoiceChip, 'Drinks'));
      await tester.pumpAndSettle();
      expect(find.text('Masala Chaas'), findsOneWidget);
      expect(find.text('Paneer Tikka'), findsNothing);
      await tester.tap(find.widgetWithText(ChoiceChip, 'All'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'butter');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pumpAndSettle();
      expect(find.text('Butter Chicken'), findsOneWidget);
      expect(find.text('Paneer Tikka'), findsNothing);
      h.expectClean('menu filter');
    });

    testWidgets('works on a phone with menu and order tabs', (tester) async {
      final h = await bootRest(tester, const Size(360, 740), initial: '/restaurant/order/o1');
      expect(find.text('Menu'), findsOneWidget);
      await tester.tap(find.text('Paneer Tikka'));
      await tester.pumpAndSettle();
      expect(find.text('Order (1)'), findsOneWidget);
      await tester.tap(find.text('Order (1)'));
      await tester.pumpAndSettle();
      expect(find.text('Send to kitchen (1)'), findsOneWidget);
      expect(find.text('Print bill'), findsOneWidget);
      expect(find.text('Settle'), findsOneWidget);
      h.expectClean('phone order');
    });
  });

  group('settle', () {
    testWidgets('splits a payment between cash and UPI and posts once', (tester) async {
      final h = await bootRest(tester, const Size(1440, 900), initial: '/restaurant/order/o1');
      await tester.tap(find.text('Butter Chicken'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send to kitchen (1)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Settle'));
      await tester.pumpAndSettle();
      expect(find.text('Settle bill'), findsOneWidget);
      // 320 + 5% GST = 336.
      final amount = find.widgetWithText(TextField, 'Amount');
      await tester.enterText(amount, '200');
      await tester.pumpAndSettle();
      expect(find.text('Still to collect'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Settle ₹336.00'), findsOneWidget);
      await tester.tap(find.text('Split payment'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Amount'), findsNWidgets(2));
      expect(find.text('Collected'), findsOneWidget);

      final settle = find.widgetWithText(FilledButton, 'Settle ₹336.00');
      await tester.tap(settle);
      await tester.tap(settle, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/restaurant/orders/o1/settle'), 1);
      final body = h.backend.last('POST', '/restaurant/orders/o1/settle').data as Map;
      expect((body['payments'] as List).map((p) => (p as Map)['mode']), ['cash', 'upi']);
      expect((body['payments'] as List).fold<num>(0, (s, p) => s + ((p as Map)['amount'] as num)), 336);
      h.expectClean('settle');
    });
  });

  group('setup screens', () {
    testWidgets('menu setup lists entries by category', (tester) async {
      final h = await bootRest(tester, const Size(390, 844), initial: '/restaurant/menu');
      expect(find.text('Mains'), findsOneWidget);
      expect(find.text('Paneer Tikka'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(3));
      h.expectClean('menu setup');
    });

    testWidgets('floor setup lists areas, tables and the service charge', (tester) async {
      final h = await bootRest(tester, const Size(390, 844), initial: '/restaurant/setup');
      expect(find.text('Service charge'), findsOneWidget);
      expect(find.text('Terrace'), findsOneWidget);
      expect(find.text('T2'), findsOneWidget);
      h.expectClean('floor setup');
    });
  });

  group('kitchen display', () {
    testWidgets('renders tickets and advances the status', (tester) async {
      final h = await bootRest(tester, const Size(1024, 768), initial: '/restaurant/kitchen');
      expect(find.text('T1'), findsOneWidget);
      expect(find.textContaining('KOT 12'), findsOneWidget);
      expect(find.text('PNR TIKKA'), findsOneWidget);
      expect(find.text('less spicy'), findsOneWidget);
      expect(find.text('Start'), findsOneWidget);

      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      expect(h.backend.last('PATCH', '/restaurant/kots/k1/status').data, {'status': 'preparing'});
      expect(find.text('Ready'), findsWidgets);

      await tester.tap(find.widgetWithText(FilledButton, 'Ready'));
      await tester.pumpAndSettle();
      expect(h.backend.last('PATCH', '/restaurant/kots/k1/status').data, {'status': 'ready'});
      expect(find.widgetWithText(FilledButton, 'Served'), findsOneWidget);
      h.expectClean('kitchen');
    });

    testWidgets('fits a phone', (tester) async {
      final h = await bootRest(tester, const Size(360, 740), initial: '/restaurant/kitchen');
      expect(find.text('PNR TIKKA'), findsOneWidget);
      h.expectClean('kitchen on phone');
    });

    testWidgets('blocks a user without kitchen access', (tester) async {
      final h = await bootRest(
        tester,
        const Size(1024, 768),
        initial: '/restaurant/kitchen',
        permissions: {'dashboard.view', 'restaurant.orders'},
      );
      expect(find.textContaining('do not have access'), findsOneWidget);
      h.expectClean('kitchen gate');
    });
  });
}
