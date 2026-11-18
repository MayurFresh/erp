import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/landed_cost/landed_cost_form_screen.dart';
import 'package:onematrix/features/landed_cost/landed_cost_models.dart';
import 'package:onematrix/features/landed_cost/landed_cost_screens.dart';
import 'package:onematrix/features/landed_cost/landed_cost_widgets.dart';
import 'package:onematrix/features/rfq/rfq_form_screen.dart';
import 'package:onematrix/features/rfq/rfq_models.dart';
import 'package:onematrix/features/rfq/rfq_screens.dart';

import '../quotations/quotation_fixtures.dart';

const perms = {
  'purchases.view',
  'purchases.create',
  'purchases.cancel',
  'purchase_orders.view',
  'purchase_orders.manage',
  'parties.view',
  'locations.view',
  'items.view',
};

Map<String, Object?> lcLineJson() => {
  'docType': 'purchase',
  'docId': 'b1',
  'docLineId': 'bl1',
  'docNumber': 'PUR/26-27/00001',
  'itemName': 'Brake pad',
  'qty': 10,
  'baseValue': 1000,
  'weight': 0,
  'onHandPct': 60,
  'allocated': 200,
  'toInventory': 120,
  'toCogs': 80,
  'landedUnitCost': 120,
};

Map<String, Object?> lcJson({String status = 'posted'}) => {
  'id': 'lc1',
  'number': 'LCV/26-27/00001',
  'status': status,
  'voucherDate': '2026-11-10',
  'basis': 'value',
  'chargesTotal': 200,
  'igstTotal': 18,
  'inventoryTotal': 120,
  'cogsTotal': 80,
  'charges': [
    {'kind': 'freight', 'amount': 150, 'igstAmount': 0},
    {'kind': 'customs_duty', 'amount': 50, 'igstAmount': 18},
  ],
  'lines': [lcLineJson()],
};

Map<String, Object?> quote(
  String party,
  String name,
  double total, {
  int lead = 5,
  bool lowest = false,
  bool fastest = false,
}) => {
  'partyId': party,
  'partyName': name,
  'rate': 100,
  'discountPct': 0,
  'gstRate': 18,
  'leadDays': lead,
  'total': total,
  'taxable': total,
  'isLowest': lowest,
  'isFastest': fastest,
};

Map<String, Object?> rfqJson({String status = 'quotes_received', String? chosen}) => {
  'id': 'r1',
  'number': 'RFQ/26-27/00001',
  'status': status,
  'rfqDate': '2026-11-10',
  'dueDate': null,
  'locationId': 'l1',
  'locationName': 'Head Office',
  'vendors': [
    {'partyId': 'v1', 'partyName': 'Vendor One', 'sentAt': '2026-11-10', 'total': 1180},
    {'partyId': 'v2', 'partyName': 'Vendor Two', 'sentAt': '2026-11-10', 'total': 1121},
  ],
  'lines': [
    {
      'id': 'rl1',
      'lineNo': 1,
      'itemId': 'i1',
      'itemName': 'Brake pad',
      'qty': 10,
      'unit': 'pcs',
      'chosenPartyId': chosen,
      'quotes': [
        quote('v1', 'Vendor One', 1180, lead: 3, fastest: true),
        quote('v2', 'Vendor Two', 1121, lead: 9, lowest: true),
      ],
    },
  ],
  'purchaseOrders': <Object?>[],
};

void main() {
  group('landed cost model', () {
    test('body needs a document and a charge with a credit side', () {
      final docs = [(type: 'purchase', id: 'b1')];
      expect(
        buildLandedCostBody(docs: docs, basis: 'value', charges: [ChargeDraft(amount: 100)], weights: {}),
        isNull,
      );
      expect(
        buildLandedCostBody(docs: [], basis: 'value', charges: [ChargeDraft(amount: 100, creditAccountId: 'a1')], weights: {}),
        isNull,
      );
      final body = buildLandedCostBody(
        docs: docs,
        basis: 'weight',
        charges: [
          ChargeDraft(kind: 'customs_duty', amount: 100, igstAmount: 18, creditAccountId: 'a1'),
          ChargeDraft(amount: 50, partyId: 'v1'),
          ChargeDraft(),
        ],
        weights: {'bl1': 2.5},
        notes: ' ',
      )!;
      expect(body['basis'], 'weight');
      final charges = body['charges']! as List;
      expect(charges, hasLength(2));
      expect((charges[0] as Map)['igstAmount'], 18);
      expect((charges[0] as Map)['creditAccountId'], 'a1');
      expect((charges[1] as Map)['partyId'], 'v1');
      expect(body['weights'], [
        {'docLineId': 'bl1', 'weight': 2.5},
      ]);
      expect(body.containsKey('notes'), isFalse);
    });

    test('voucher JSON parses', () {
      final v = LandedCost.fromJson(lcJson());
      expect(v.inventoryTotal, 120);
      expect(v.lines.single.onHandPct, 60);
      expect(v.charges.last.igstAmount, 18);
    });
  });

  test('rfq message lists the items and the reply date', () {
    final r = Rfq.fromJson({...rfqJson(), 'dueDate': '2026-11-20'});
    final m = rfqMessage(r, 'Vendor One');
    expect(m, contains('Hello Vendor One'));
    expect(m, contains('- Brake pad: 10 pcs'));
    expect(m, contains('reply by 2026-11-20'));
  });

  for (final size in [narrow, wide]) {
    final tag = '${size.width.toInt()}px';

    testWidgets('allocation lines render at $tag', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LcLinesView(lines: [LcLine.fromJson(lcLineJson())]),
            ),
          ),
        ),
      );
      expect(find.text('Brake pad'), findsOneWidget);
      expect(find.byType(DataTable), size == wide ? findsOneWidget : findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('landed cost detail shows split and cancel at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /landed-costs/lc1', lcJson())
        ..on('POST /landed-costs/lc1/cancel', lcJson(status: 'cancelled'));
      await pumpRouted(tester, const LandedCostDetailScreen(id: 'lc1'), b, size: size, permissions: perms);
      expect(find.text('LCV/26-27/00001'), findsWidgets);
      expect(find.textContaining('IGST paid on import'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('landed cost form asks for documents first at $tag', (tester) async {
      final b = FakeControlsBackend();
      await pumpRouted(tester, const LandedCostFormScreen(), b, size: size, permissions: perms);
      expect(find.text('Add purchase bill'), findsOneWidget);
      await tester.ensureVisible(find.text('Show allocation'));
      await tester.tap(find.text('Show allocation'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Add a bill or receipt'), findsOneWidget);
      expect(b.last('POST', '/landed-costs/preview'), isNull);
      expect(tester.takeException(), isNull);
    });

    testWidgets('rfq comparison marks lowest, fastest and chosen at $tag', (tester) async {
      final b = FakeControlsBackend()..on('GET /rfqs/r1', rfqJson(chosen: 'v2'));
      await pumpRouted(tester, const RfqDetailScreen(rfqId: 'r1'), b, size: size, permissions: perms);
      expect(find.textContaining('Lowest'), findsWidgets);
      expect(find.textContaining('Fastest'), findsWidgets);
      expect(find.textContaining('Chosen'), findsWidgets);
      expect(find.byType(DataTable), size == wide ? findsOneWidget : findsNothing);
      expect(find.text('Enter quote'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('choosing a quote patches the line choice', (tester) async {
    final b = FakeControlsBackend()
      ..on('GET /rfqs/r1', rfqJson())
      ..on('PATCH /rfqs/r1/choices', rfqJson(chosen: 'v1'));
    await pumpRouted(tester, const RfqDetailScreen(rfqId: 'r1'), b, size: narrow, permissions: perms);
    await tester.ensureVisible(find.textContaining('Fastest').first);
    await tester.tap(find.textContaining('Fastest').first);
    await tester.pumpAndSettle();
    final req = b.last('PATCH', '/rfqs/r1/choices')!;
    expect(req.data, {
      'choices': [
        {'lineId': 'rl1', 'partyId': 'v1'},
      ],
    });
  });

  testWidgets('create orders posts convert', (tester) async {
    final b = FakeControlsBackend()
      ..on('GET /rfqs/r1', rfqJson(chosen: 'v2'))
      ..on('POST /rfqs/r1/convert', rfqJson(status: 'closed', chosen: 'v2'));
    await pumpRouted(tester, const RfqDetailScreen(rfqId: 'r1'), b, size: wide, permissions: perms);
    await tester.tap(find.text('Create orders'));
    await tester.pumpAndSettle();
    expect(b.last('POST', '/rfqs/r1/convert'), isNotNull);
  });

  testWidgets('read-only users cannot choose, quote or convert', (tester) async {
    final b = FakeControlsBackend()..on('GET /rfqs/r1', rfqJson());
    await pumpRouted(tester, const RfqDetailScreen(rfqId: 'r1'), b, size: wide, permissions: {'purchase_orders.view'});
    expect(find.text('Enter quote'), findsNothing);
    expect(find.text('Create orders'), findsNothing);
    expect(find.text('Choose lowest'), findsNothing);
  });

  testWidgets('quote dialog saves the typed rate', (tester) async {
    final b = FakeControlsBackend()
      ..on('GET /rfqs/r1', rfqJson(status: 'sent'))
      ..on('PATCH /rfqs/r1/quotes', rfqJson());
    await pumpRouted(tester, const RfqDetailScreen(rfqId: 'r1'), b, size: wide, permissions: perms);
    await tester.tap(find.text('Enter quote').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Rate').first, '95');
    await tester.tap(find.text('Save quote'));
    await tester.pumpAndSettle();
    final data = b.last('PATCH', '/rfqs/r1/quotes')!.data as Map;
    expect(data['partyId'], 'v1');
    expect((data['quotes'] as List).single['rate'], 95);
  });

  testWidgets('rfq form needs a vendor', (tester) async {
    final b = FakeControlsBackend();
    await pumpRouted(tester, const RfqFormScreen(), b, size: narrow, permissions: perms);
    await tester.ensureVisible(find.text('Save request'));
    await tester.tap(find.text('Save request'));
    await tester.pumpAndSettle();
    expect(find.text('Choose at least one vendor.'), findsOneWidget);
    expect(b.last('POST', '/rfqs'), isNull);
  });
}
