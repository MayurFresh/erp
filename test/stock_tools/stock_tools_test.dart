import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:onematrix/features/stock_tools/label_pdf.dart';
import 'package:onematrix/features/stock_tools/stock_tools_models.dart';
import 'package:onematrix/features/stock_tools/unit_picker.dart';

void main() {
  group('units', () {
    final units = ItemUnits.fromJson({
      'baseUnit': 'nos',
      'units': [
        {'id': '1', 'name': 'box', 'factor': 12},
        {'id': '2', 'name': 'dozen', 'factor': 12.0},
      ],
      'defaultSaleUnit': 'box',
    });

    test('converts quantity and rate to the base unit', () {
      expect(units.names, ['nos', 'box', 'dozen']);
      expect(units.toBaseQty(2, 'box'), 24);
      expect(units.toBaseRate(1200, 'box'), 100);
      expect(units.toBaseRate(100, 'Box'), 8.3333);
      expect(units.toBaseQty(5, null), 5);
      expect(units.toBaseQty(5, 'nos'), 5);
    });

    test('kg and g', () {
      final kg = ItemUnits.fromJson({
        'baseUnit': 'kg',
        'units': [
          {'name': 'g', 'factor': 0.001},
        ],
      });
      expect(kg.toBaseQty(250, 'g'), 0.25);
    });

    test('default unit for a new line', () {
      expect(defaultLineUnit('nos', null, 'box', purchase: false), 'box');
      expect(defaultLineUnit('nos', null, 'box', purchase: true), isNull);
      expect(defaultLineUnit('nos', null, 'NOS', purchase: false), isNull);
    });
  });

  group('reports', () {
    test('ageing parses buckets with and without value', () {
      final r = AgeingReport.fromJson({
        'asOf': '2026-11-16',
        'buckets': ['0-30', '31-60', '61-90', '91-180', '180+'],
        'rows': [
          {
            'itemId': 'a', 'name': 'Pen', 'unit': 'nos', 'locationName': 'Main', 'qty': 14,
            'buckets': [
              {'qty': 3, 'value': 90},
              {'qty': 5, 'value': 100},
              {'qty': 0, 'value': 0},
              {'qty': 0, 'value': 0},
              {'qty': 6, 'value': 60},
            ],
            'value': 250,
          },
        ],
        'totals': {'qty': 14, 'value': 250, 'buckets': []},
      });
      expect(r.rows.single.buckets[4].qty, 6);
      expect(r.rows.single.buckets[1].value, 100);
      expect(r.totalValue, 250);
      final noCost = AgeingRow.fromJson({'name': 'x', 'buckets': [{'qty': 1}]});
      expect(noCost.buckets.single.value, isNull);
      expect(noCost.value, isNull);
    });

    test('movement and setting', () {
      final m = MovementRow.fromJson({'itemId': 'i', 'name': 'Idle', 'unit': 'nos', 'qty': 10, 'soldQty': 0, 'lastSaleDate': null, 'daysSinceSale': null});
      expect(m.lastSaleDate, isNull);
      expect(m.daysSinceSale, isNull);
      expect(ValuationSetting.fromJson({'method': 'fifo', 'effectiveFrom': '2026-11-16'}).isFifo, isTrue);
      expect(ValuationSetting.fromJson({'method': 'average'}).isFifo, isFalse);
    });
  });

  group('labels', () {
    test('sheet sizes hold 24, 40 and 65 labels and the roll holds one', () {
      expect(labelLayoutById('a4_24').perPage, 24);
      expect(labelLayoutById('a4_40').perPage, 40);
      expect(labelLayoutById('a4_65').perPage, 65);
      expect(labelLayoutById('roll_50x25').perPage, 1);
      expect(labelLayoutById('roll_50x25').widthMm, 50);
      expect(labelLayoutById('roll_50x25').heightMm, 25);
      for (final l in labelLayouts.where((l) => !l.thermal)) {
        expect(l.cols * l.widthMm, lessThanOrEqualTo(210));
        expect(l.rows * l.heightMm, lessThanOrEqualTo(297));
      }
    });

    test('pages and copies', () {
      const e = LabelEntry(name: 'Pen', price: 10, code: '123456', copies: 3);
      expect(expandLabels([e, e]).length, 6);
      expect(labelPages(labelLayoutById('a4_24'), 24), 1);
      expect(labelPages(labelLayoutById('a4_24'), 25), 2);
      expect(labelPages(labelLayoutById('a4_24'), 0), 0);
    });

    test('EAN-13 for a valid 13-digit code, Code 128 otherwise', () {
      expect(barcodeFor('4006381333931'), isA<pw.BarcodeEan>());
      expect(barcodeFor('SKU-100'), isNot(isA<pw.BarcodeEan>()));
      expect(barcodeFor('4006381333932'), isNot(isA<pw.BarcodeEan>()));
    });

    test('builds a PDF for each layout', () async {
      final entries = [
        const LabelEntry(name: 'Steel bottle 1 litre', price: 349.5, code: '4006381333931', copies: 30),
        const LabelEntry(name: 'Pen', price: 10, code: 'PEN-01', copies: 2),
      ];
      for (final l in labelLayouts) {
        final bytes = await buildLabelsPdf(entries, l);
        expect(String.fromCharCodes(bytes.take(4)), '%PDF');
      }
    });
  });
}
