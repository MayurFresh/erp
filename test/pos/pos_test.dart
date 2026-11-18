import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/money.dart';
import 'package:onematrix/features/pos/pos_cart.dart';
import 'package:onematrix/features/pos/pos_models.dart';
import 'package:onematrix/features/pos/pos_receipt_pdf.dart';

import 'pos_harness.dart';

PosItem item(double price, double gst) =>
    PosItem(id: 'x$price', name: 'X', price: price, gstRate: gst);

Future<void> scan(PosHarness h, String code) async {
  await h.tester.enterText(find.byKey(const Key('pos-search')), code);
  await h.tester.testTextInput.receiveAction(TextInputAction.search);
  await h.tester.pumpAndSettle();
}

void main() {
  group('totals and pay maths', () {
    test('computeTotals adds tax, applies discounts and rounds to the rupee', () {
      final t = computeTotals([
        CartLine(item: item(100, 5), qty: 2, discountPct: 10),
        CartLine(item: item(50, 18)),
      ], const BillDiscount.amount(10));
      // taxable: 180 + 50 = 230, minus 10 = 220 split pro rata; tax about 9 + 9 less pro rata.
      expect(t.subtotal, closeTo(220, 0.02));
      expect(t.total, t.total.roundToDouble());
      expect(t.total, closeTo(220 + t.tax, 0.5));
    });

    test('computePay splits cash and change', () {
      final c = computePay(210, cash: 100, upi: 100, card: 50);
      expect(c.cashApplied, 60);
      expect(c.change, 40);
      expect(c.short, 0);
      expect(c.covered, isTrue);
    });

    test('computePay reports a shortfall and non-cash overpayment', () {
      expect(computePay(105, cash: 100).short, 5);
      expect(computePay(105, cash: 100).covered, isFalse);
      expect(computePay(105, upi: 200).nonCashOver, isTrue);
      expect(computePay(105, cash: 500).change, 395);
    });
  });

  group('tax-inclusive totals', () {
    test('lines sum to the shown total and the tax is inside them', () {
      final lines = [
        CartLine(item: item(99.99, 5), qty: 3),
        CartLine(item: item(49.5, 18), qty: 7),
        CartLine(item: item(17.35, 5), qty: 2, discountPct: 12.5),
      ];
      final t = computeTotals(
        lines,
        const BillDiscount.amount(17.35),
        inclusive: true,
      );
      // 299.97 + 346.5 + 30.36 = 676.83; less 17.35 spread over the lines = about 659.48.
      expect(t.total, 659);
      expect(t.subtotal + t.tax, closeTo(659.48, 0.05));
      expect(t.subtotal + t.tax + t.roundOff, closeTo(659, 0.001));
      expect(t.tax, greaterThan(0));
    });

    test('a single MRP line shows exactly MRP', () {
      final t = computeTotals(
        [CartLine(item: item(100, 5))],
        null,
        inclusive: true,
      );
      expect(t.total, 100);
      expect(t.subtotal, 95.24);
      expect(t.tax, 4.76);
    });
  });

  group('receipt', () {
    test('builds 80 mm and 58 mm PDFs', () async {
      final sale = PosSale.fromJson(posSaleJson);
      final wide = await buildPosReceiptPdf(sale);
      final narrow = await buildPosReceiptPdf(sale, narrow: true);
      expect(wide.length, greaterThan(500));
      expect(narrow.length, greaterThan(500));
      expect(thermalFormat().width, closeTo(226.77, 0.1));
      expect(thermalFormat(narrow: true).width, closeTo(164.4, 0.2));
    });

    test('builds the session report PDF', () async {
      final r = SessionReport.fromJson({
        'kind': 'Z',
        'session': posSessionJson,
        'sales': {
          'count': 1,
          'total': 105,
          'taxTotal': 5,
          'discountTotal': 0,
          'itemsSold': 1,
          'creditGiven': 0,
        },
        'payments': {'cash': 105},
        'refunds': <String, Object?>{},
        'returns': {'count': 0, 'total': 0},
        'cashIn': 0,
        'cashOut': 0,
        'expected': {'cash': 605},
        'counted': {'cash': 600},
        'difference': {'cash': -5},
        'cashMoves': <Object?>[],
      });
      expect((await buildSessionReportPdf(r)).length, greaterThan(500));
    });
  });

  for (final size in posSizes) {
    group('counter at ${size.width.toInt()}px', () {
      testWidgets('shows search, quick items and a disabled Pay', (
        tester,
      ) async {
        final h = await bootPos(tester, size);
        expect(find.byKey(const Key('pos-search')), findsOneWidget);
        h.expectClean('counter');
        if (size.width >= 900) {
          expect(find.byKey(const Key('quick-i1')), findsOneWidget);
          expect(find.text('The bill is empty.'), findsOneWidget);
          expect(
            tester
                .widget<FilledButton>(find.byKey(const Key('pay-button')))
                .onPressed,
            isNull,
          );
        }
      });

      testWidgets(
        'scanning a barcode adds the item and a second scan makes qty 2',
        (tester) async {
          final h = await bootPos(tester, size);
          await scan(h, '8901000100011');
          expect(find.byKey(const Key('cart-lines')), findsOneWidget);
          expect(
            find.descendant(
              of: find.byKey(const Key('cart-lines')),
              matching: find.text('Basmati Rice 1 kg'),
            ),
            findsOneWidget,
          );
          expect(
            tester.widget<Text>(find.byKey(const Key('cart-total'))).data,
            contains('105'),
          );
          await scan(h, '8901000100011');
          expect(
            tester.widget<Text>(find.byKey(const Key('cart-total'))).data,
            contains('210'),
          );
          expect(
            tester
                .widget<Text>(
                  find.descendant(
                    of: find.byKey(const Key('qty-0')),
                    matching: find.byType(Text),
                  ),
                )
                .data,
            '2',
          );
          // The search box is cleared and ready for the next scan.
          expect(
            tester
                .widget<TextField>(find.byKey(const Key('pos-search')))
                .controller!
                .text,
            '',
          );
          h.expectClean('scan');
        },
      );

      testWidgets(
        'F9 opens the pay sheet; change is worked out as cash is typed',
        (tester) async {
          final h = await bootPos(tester, size);
          await scan(h, '8901000100011');
          await tester.sendKeyEvent(LogicalKeyboardKey.f9);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('pay-total')), findsOneWidget);
          await tester.enterText(find.byKey(const Key('pay-cash')), '200');
          await tester.pump();
          expect(
            tester.widget<Text>(find.byKey(const Key('pay-change'))).data,
            contains('95'),
          );
          expect(find.byKey(const Key('pay-short')), findsNothing);
          await tester.enterText(find.byKey(const Key('pay-cash')), '50');
          await tester.pump();
          expect(
            tester.widget<Text>(find.byKey(const Key('pay-short'))).data,
            contains('55'),
          );
          expect(
            tester
                .widget<OutlinedButton>(find.byKey(const Key('pay-save')))
                .onPressed,
            isNull,
          );
          // Esc closes the sheet and keeps the bill.
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('pay-total')), findsNothing);
          expect(find.byKey(const Key('cart-lines')), findsOneWidget);
          h.expectClean('pay');
        },
      );

      testWidgets('Save is disabled while saving and the sale is sent once', (
        tester,
      ) async {
        final h = await bootPos(tester, size);
        h.backend.holdSale = Completer<void>();
        await scan(h, '8901000100011');
        await tester.tap(find.byKey(const Key('pay-button')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('cash-exact')));
        await tester.pump();
        await tester.tap(find.byKey(const Key('pay-save')));
        await tester.pump();
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('pay-save')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<FilledButton>(find.byKey(const Key('pay-save-print')))
              .onPressed,
          isNull,
        );
        await tester.tap(
          find.byKey(const Key('pay-save')),
          warnIfMissed: false,
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(h.backend.sales, hasLength(1));
        expect(h.backend.sales.single.data['payments'], [
          {'mode': 'cash', 'amount': 105.0},
        ]);
        expect(h.backend.sales.single.headers['Idempotency-Key'], isNotNull);
        h.backend.holdSale!.complete();
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('pay-total')), findsNothing);
        expect(find.byKey(const Key('cart-lines')), findsNothing);
        h.expectClean('saved');
      });
    });
  }

  testWidgets('without an open session the counter asks to open one', (
    tester,
  ) async {
    final h = await bootPos(tester, posSizes.first, hasSession: false);
    expect(find.byKey(const Key('open-session')), findsOneWidget);
    expect(find.byKey(const Key('pos-search')), findsNothing);
    h.expectClean('open');
  });

  testWidgets(
    'inclusive prices: scan, pay and the sale carries the shown total',
    (tester) async {
      final h2 = await bootPos(tester, posSizes.last, inclusive: true);
      await scan(h2, '8901000100011');
      expect(
        tester.widget<Text>(find.byKey(const Key('cart-total'))).data,
        contains('100'),
      );
      await tester.tap(find.byKey(const Key('pay-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cash-exact')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('pay-save')));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(h2.backend.sales.single.data['expectedTotal'], 100);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('held bills list: resume puts the bill on the counter', (
    tester,
  ) async {
    final h = await bootPos(tester, posSizes.last);
    await tester.tap(find.byKey(const Key('held-button')));
    await tester.pumpAndSettle();
    expect(find.text('Mrs Rao'), findsOneWidget);
    expect(
      find.text(
        '1 lines  |  Sana  |  ${formatDateTime(DateTime.parse('2026-11-12T05:00:00.000Z').toLocal())}',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('held-h1')));
    await tester.pumpAndSettle();
    expect(h.backend.posts.map((r) => r.path), contains('/pos/held/h1/resume'));
    expect(
      tester.widget<Text>(find.byKey(const Key('cart-total'))).data,
      contains('210'),
    );
    h.expectClean('held');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('return dialog: find the bill, choose a quantity, refund', (
    tester,
  ) async {
    final h = await bootPos(tester, posSizes.last);
    await tester.tap(find.byKey(const Key('pos-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Return goods'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('return-search')), 'INV');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('sale-sale1')));
    await tester.pumpAndSettle();
    // A reason and a quantity are both needed.
    await tester.tap(find.byKey(const Key('return-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Enter a quantity to return.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('return-qty-il1')), '1');
    await tester.tap(find.byKey(const Key('return-submit')));
    await tester.pumpAndSettle();
    expect(find.text('Give a reason.'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('return-reason')),
      'Wrong item',
    );
    await tester.tap(find.byKey(const Key('return-submit')));
    await tester.pumpAndSettle();
    final post = h.backend.posts.singleWhere(
      (r) => r.path == '/pos/sales/sale1/return',
    );
    expect(post.data, {
      'lines': [
        {'invoiceLineId': 'il1', 'qty': 1.0},
      ],
      'reason': 'Wrong item',
      'refundMode': 'cash',
    });
    expect(find.byKey(const Key('return-submit')), findsNothing);
    h.expectClean('return');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'close screen: counts the drawer and confirms when bills are held',
    (tester) async {
      final h = await bootPos(tester, posSizes.first);
      h.backend.heldOnClose = true;
      await h.go('/pos/sessions/ps1/close');
      await tester.tap(find.byKey(const Key('close-session')));
      await tester.pumpAndSettle();
      expect(find.text('Enter the cash you counted.'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('count-cash')), '600');
      await tester.tap(find.byKey(const Key('close-session')));
      await tester.pumpAndSettle();
      expect(find.text('Bills are still on hold'), findsOneWidget);
      // Going back leaves the session open.
      await tester.tap(find.byKey(const Key('held-keep-open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('close-session')), findsOneWidget);
      await tester.tap(find.byKey(const Key('close-session')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('held-close-anyway')));
      await tester.pumpAndSettle();
      final closes = h.backend.posts
          .where((r) => r.path == '/pos/sessions/ps1/close')
          .toList();
      expect(closes.last.data, containsPair('confirmHeld', true));
      expect(closes.last.data['counted'], {'cash': 600.0});
      expect(find.text('Z report (closed)'), findsOneWidget);
      h.expectClean('close');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('the X report shows totals per mode', (tester) async {
    final h = await bootPos(tester, posSizes.last);
    await h.go('/pos/sessions/ps1');
    expect(find.text('X report (running)'), findsOneWidget);
    expect(find.byKey(const Key('mode-cash')), findsOneWidget);
    h.expectClean('report');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
