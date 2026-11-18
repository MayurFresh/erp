import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/entered_unit.dart';
import 'package:onematrix/features/documents/document_models.dart';
import 'package:onematrix/features/documents/line_editor.dart';
import 'package:onematrix/features/items/item_model.dart';
import 'package:onematrix/features/quotations/quotation_models.dart';
import 'package:onematrix/features/sales_orders/sales_order_models.dart';
import 'package:onematrix/features/stock_tools/label_pdf.dart';
import 'package:onematrix/features/stock_tools/stock_tools_models.dart';
import 'package:onematrix/features/stock_tools/stock_tools_repository.dart';
import 'package:onematrix/features/stock_tools/unit_picker.dart';

void main() {
  group('entered unit on printed lines', () {
    test('reads the entered unit only when it is there', () {
      expect(EnteredUnit.fromJson({'qty': 24}), isNull);
      final e = EnteredUnit.fromJson({
        'enteredUnit': 'box',
        'enteredQty': 2,
        'enteredRate': 600,
      })!;
      expect(lineQtyText(24, 'nos', e), '2 box');
      expect(lineQtyText(24, 'nos', null), '24 nos');
      expect(lineRateText(50, e), '600.00');
      expect(lineRateText(50, null), '50.00');
    });

    test('invoice lines carry it', () {
      final l = TaxLine.fromJson({
        'itemId': 'i',
        'qty': 24,
        'unit': 'nos',
        'rate': 50,
        'enteredUnit': 'box',
        'enteredQty': 2,
        'enteredRate': 600,
      });
      expect(l.entered?.unit, 'box');
      expect(l.qty, 24);
    });

    test('a draft line sends its unit', () {
      const l = DraftLine(itemId: 'i', qty: 2, rate: 600, unit: 'box');
      expect(l.toJson()['unit'], 'box');
      expect(const DraftLine(itemId: 'i', qty: 2).toJson().containsKey('unit'), isFalse);
    });
  });

  test('saved quotation and order lines expose the entered unit for editing', () {
    final extra = {'enteredUnit': 'box', 'enteredQty': 2, 'enteredRate': 600};
    final q = QuotationLine.fromJson({'id': 'a', 'qty': 24, 'rate': 50, 'unit': 'nos', ...extra});
    expect((q.entered?.unit, q.entered?.qty, q.entered?.rate), ('box', 2.0, 600.0));
    final o = SalesOrderLine.fromJson({'id': 'b', 'qtyOrdered': 24, 'rate': 50, 'unit': 'nos', ...extra});
    expect(o.entered?.unit, 'box');
  });

  test('rate text follows a change of unit', () {
    expect(scaleRateText('50', 12), '600');
    expect(scaleRateText('600', 1 / 12), '50');
    expect(scaleRateText('', 12), '');
  });

  group('MRP on labels', () {
    test('the line reads as the rules ask', () {
      expect(mrpLine(129.5, false), 'MRP Rs 129.50 (incl. of all taxes)');
      expect(mrpLine(100, false), 'MRP Rs 100 (incl. of all taxes)');
    });

    test('a label with MRP still prints', () async {
      final bytes = await buildLabelsPdf(
        const [LabelEntry(name: 'Soap', price: 90, code: '8901234567890', copies: 2, mrp: 100)],
        labelLayoutById('a4_24'),
      );
      expect(bytes.length, greaterThan(500));
    });
  });

  testWidgets('the line editor offers the item\'s units and keeps the rate in step', (tester) async {
    const item = Item(
      id: 'i1',
      companyId: 'c',
      name: 'Tile',
      unit: 'nos',
      gstRate: 18,
      salePrice: 50,
    );
    final line = LineDraft(item, defaultRate: 50);
    var changed = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          itemUnitsProvider('i1').overrideWith(
            (ref) async => ItemUnits.fromJson({
              'baseUnit': 'nos',
              'units': [
                {'id': '1', 'name': 'box', 'factor': 12},
              ],
            }),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SizedBox(
                width: 360,
                child: LineEditor(
                  line: line,
                  preview: null,
                  errors: const {},
                  onChanged: () => changed++,
                  onRemove: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Unit'), findsOneWidget);
    await tester.tap(find.text('nos').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('box').last);
    await tester.pumpAndSettle();
    expect(line.unit, 'box');
    expect(line.rate.text, '600');
    expect(line.toDraft().unit, 'box');
    expect(changed, greaterThan(0));
  });

  testWidgets('no picker for an item without alternate units', (tester) async {
    const item = Item(id: 'i2', companyId: 'c', name: 'Pen', unit: 'nos', gstRate: 18, salePrice: 5);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          itemUnitsProvider('i2').overrideWith(
            (ref) async => ItemUnits.fromJson({'baseUnit': 'nos', 'units': []}),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LineEditor(
                line: LineDraft(item),
                preview: null,
                errors: const {},
                onChanged: () {},
                onRemove: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Unit'), findsNothing);
  });
}
