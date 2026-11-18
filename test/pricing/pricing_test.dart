import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/pricing/bill_discount.dart';
import 'package:onematrix/features/pricing/price_prefill.dart';
import 'package:onematrix/features/pricing/pricing_models.dart';

class _Line with PricedLine {
  _Line(this.priceItemId, this.priceQty, {String rate = '', double? auto})
    : priceRateField = TextEditingController(text: rate),
      priceDiscountField = TextEditingController() {
    autoRate = auto;
  }

  @override
  final TextEditingController priceRateField;
  @override
  final TextEditingController priceDiscountField;
  @override
  final String priceItemId;
  @override
  final double priceQty;
}

void main() {
  group('bill discount', () {
    test('spreads in proportion and the shares add up exactly', () {
      final shares = spreadDiscount([100, 200, 300], 100);
      expect(shares, [16.67, 33.33, 50.0]);
      expect(shares.reduce((a, b) => a + b), closeTo(100, 1e-9));
    });

    test('rounding remainder goes to the last line', () {
      final shares = spreadDiscount([10, 10, 10], 10);
      expect(shares[0], 3.33);
      expect(shares[1], 3.33);
      expect(shares[2], 3.34);
    });

    test('lines with no value get nothing and the last valued line takes the rest', () {
      final shares = spreadDiscount([50, 0, 50, 0], 10);
      expect(shares, [5, 0, 5, 0]);
    });

    test('a share never exceeds its line', () {
      final shares = spreadDiscount([1, 99], 100);
      expect(shares[0], 1);
      expect(shares[1], 99);
    });

    test('percent and amount totals, capped at the bill', () {
      expect(billDiscountTotal(1000, const BillDiscount(value: 10, isPercent: true)), 100);
      expect(billDiscountTotal(1000, const BillDiscount(value: 250)), 250);
      expect(billDiscountTotal(1000, const BillDiscount(value: 5000)), 1000);
      expect(billDiscountTotal(0, const BillDiscount(value: 10)), 0);
      expect(billDiscountTotal(1000, const BillDiscount()), 0);
    });

    test('fixed discounts add the line discount to its share', () {
      final lines = [
        const BillLine(qty: 2, rate: 100, discountPct: 10), // 200 - 20 = 180
        const BillLine(qty: 1, rate: 120), // 120
      ];
      final fixed = fixedDiscounts(lines, const BillDiscount(value: 30));
      // bill discount 30 over 180 and 120: 18 and 12
      expect(fixed, [38, 12]);
    });

    test('a fixed line discount is kept as it is', () {
      final fixed = fixedDiscounts(
        const [BillLine(qty: 1, rate: 100, discountAmount: 15)],
        const BillDiscount(value: 10, isPercent: true),
      );
      expect(fixed, [23.5]); // 15 + 10% of 85
    });

    test('discountPctFor converts for percent-only documents', () {
      expect(discountPctFor(25, 200), 12.5);
      expect(discountPctFor(10, 0), 0);
    });
  });

  group('prefill', () {
    ResolvedPrice price(double rate, {double disc = 0}) =>
        ResolvedPrice(itemId: 'i', rate: rate, discountPct: disc);

    test('replaces a rate the form filled in', () {
      final l = _Line('i', 1, rate: '100', auto: 100);
      applyResolved([l], [price(90, disc: 5)]);
      expect(l.priceRateField.text, '90');
      expect(l.priceDiscountField.text, '5');
      expect(l.autoRate, 90);
    });

    test('keeps a rate the person typed', () {
      final l = _Line('i', 1, rate: '95', auto: 100);
      applyResolved([l], [price(90)]);
      expect(l.priceRateField.text, '95');
    });

    test('never touches lines of a saved document', () {
      final l = _Line('i', 1, rate: '100');
      applyResolved([l], [price(90, disc: 5)]);
      expect(l.priceRateField.text, '100');
      expect(l.priceDiscountField.text, '');
      expect(l.resolved, isNotNull);
    });

    test('clears a scheme discount that no longer applies', () {
      final l = _Line('i', 10, rate: '100', auto: 100);
      applyResolved([l], [price(100, disc: 5)]);
      expect(l.priceDiscountField.text, '5');
      applyResolved([l], [price(100)]);
      expect(l.priceDiscountField.text, '');
    });
  });

  group('models', () {
    test('resolved price parses', () {
      final p = ResolvedPrice.fromJson({
        'itemId': 'a',
        'rate': 80,
        'discountPct': 5,
        'source': 'scheme',
        'priceListName': null,
        'freeQty': 2,
        'freeItemId': 'b',
      });
      expect(p.rate, 80);
      expect(p.freeQty, 2);
      expect(p.freeItemId, 'b');
    });
  });

  for (final width in [320.0, 1200.0]) {
    testWidgets('scheme hint offers free goods at ${width.toInt()}px', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      var added = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SchemeHint(
              price: const ResolvedPrice(
                itemId: 'a',
                rate: 100,
                priceListName: 'Dealer',
                discountPct: 5,
                freeQty: 2,
                source: 'price_list',
              ),
              onAddFree: () => added++,
            ),
          ),
        ),
      );
      expect(find.textContaining('Price list Dealer'), findsOneWidget);
      await tester.tap(find.text('Add 2 free'));
      expect(added, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('bill discount field switches between amount and percent', (tester) async {
    final c = TextEditingController();
    var pct = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, set) => BillDiscountField(
              controller: c,
              isPercent: pct,
              appliedAmount: 40,
              onModeChanged: (v) => set(() => pct = v),
              onChanged: () {},
            ),
          ),
        ),
      ),
    );
    expect(find.text('Discount on bill'), findsOneWidget);
    expect(find.textContaining('off before tax'), findsOneWidget);
    await tester.tap(find.text('%'));
    await tester.pump();
    expect(pct, isTrue);
  });
}
