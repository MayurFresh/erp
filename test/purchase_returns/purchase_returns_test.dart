import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/api_exception.dart';
import 'package:onematrix/features/documents/credit_limit_dialog.dart';
import 'package:onematrix/features/invoices/invoice_model.dart';
import 'package:onematrix/features/purchase_returns/purchase_return_model.dart';
import 'package:onematrix/features/sales_orders/sales_order_models.dart';

const _json = {
  'id': 'r1',
  'number': 'DN/26-27/00001',
  'purchaseId': 'p1',
  'purchaseNumber': 'PUR/26-27/00003',
  'partyId': 'v1',
  'partyName': 'Vendor One',
  'kind': 'goods',
  'status': 'posted',
  'reason': 'Damaged',
  'returnDate': '2026-11-13',
  'placeOfSupply': '24',
  'supplyType': 'intra',
  'subtotal': 1600,
  'cgst': 144,
  'sgst': 144,
  'total': 1888,
  'appliedAmount': 1888,
  'stockValue': 1600,
  'lines': [
    {
      'purchaseLineId': 'l1',
      'itemId': 'i1',
      'itemName': 'Cement',
      'description': 'Cement 50kg',
      'qty': 4,
      'unit': 'bag',
      'gstRate': 18,
      'taxableValue': 1600,
      'cgst': 144,
      'sgst': 144,
      'lineTotal': 1888,
      'stockValue': 1600,
    },
  ],
};

void main() {
  test('parses a debit note and maps lines for the shared views', () {
    final r = PurchaseReturn.fromJson(_json);
    expect(r.number, 'DN/26-27/00001');
    expect(r.isGoods, isTrue);
    expect(r.status, DocStatus.posted);
    expect(r.total, 1888);
    expect(r.taxLines.single.qty, 4);
    expect(r.taxLines.single.rate, 400);
  });

  test('a price line shows as one adjustment', () {
    final r = PurchaseReturn.fromJson({
      ..._json,
      'kind': 'price',
      'lines': [
        {
          ...(_json['lines']! as List).first as Map<String, dynamic>,
          'qty': 0,
          'taxableValue': 500,
        },
      ],
    });
    final line = r.taxLines.single;
    expect(line.qty, 1);
    expect(line.rate, 500);
    expect(line.description, startsWith('Price reduction'));
  });

  test('draft sends qty for goods, amount for price, and skips blanks', () {
    final goods = PurchaseReturnDraft(
      purchaseId: 'p1',
      kind: 'goods',
      reason: 'Damaged',
      lines: const {'l1': 4, 'l2': 0},
    ).toJson();
    expect(goods['lines'], [
      {'purchaseLineId': 'l1', 'qty': 4.0},
    ]);
    final price = PurchaseReturnDraft(
      purchaseId: 'p1',
      kind: 'price',
      reason: 'Discount',
      lines: const {'l1': 500},
    ).toJson();
    expect(price['lines'], [
      {'purchaseLineId': 'l1', 'amount': 500.0},
    ]);
  });

  test('credit override flag is only sent when set', () {
    const draft = InvoiceDraft(locationId: 'a', partyId: 'b', lines: []);
    expect(draft.toJson().containsKey('allowOverLimit'), isFalse);
    expect(draft.withOverLimit().toJson()['allowOverLimit'], isTrue);
    const order = SalesOrderInput(locationId: 'a', partyId: 'b', lines: []);
    expect(order.toJson().containsKey('allowOverLimit'), isFalse);
    expect(order.withOverLimit().toJson()['allowOverLimit'], isTrue);
  });

  const limitError = ApiException(409, 'CREDIT_LIMIT_EXCEEDED', 'Over', {
    'creditLimit': 10000,
    'owes': 5900,
    'thisDocument': 5900,
    'over': 1800,
  });

  test('recognises the credit limit error', () {
    expect(creditLimitError(limitError), isNotNull);
    expect(creditLimitError(const ApiException(409, 'CONFLICT', 'x')), isNull);
  });

  Future<bool?> show(WidgetTester t, {required bool canOverride, String tap = ''}) async {
    bool? result;
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => result = await confirmCreditLimit(
              context,
              limitError,
              canOverride: canOverride,
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    return result;
  }

  testWidgets('dialog shows the figures and offers Bill anyway with permission', (t) async {
    await show(t, canOverride: true);
    expect(find.text('Credit limit exceeded'), findsOneWidget);
    expect(find.textContaining('10,000'), findsOneWidget);
    expect(find.textContaining('1,800'), findsOneWidget);
    expect(find.text('Bill anyway'), findsOneWidget);
  });

  testWidgets('dialog has no Bill anyway without permission', (t) async {
    await show(t, canOverride: false);
    expect(find.text('Bill anyway'), findsNothing);
    expect(find.text('Go back'), findsOneWidget);
  });
}
