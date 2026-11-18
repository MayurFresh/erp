import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/fulfilment/pack_screen.dart';
import 'package:onematrix/features/fulfilment/pick_lists_screen.dart';
import 'package:onematrix/features/fulfilment/scan_panel.dart';
import 'package:onematrix/features/fulfilment/shipments_screens.dart';
import 'package:onematrix/features/returns/return_detail_screen.dart';
import 'package:onematrix/features/returns/returns_screen.dart';
import 'package:onematrix/features/sales_orders/dispatch_dialog.dart';
import 'package:onematrix/features/sales_orders/sales_order_detail_screen.dart';
import 'package:onematrix/features/sales_orders/sales_order_form_screen.dart';
import 'package:onematrix/features/sales_orders/sales_order_models.dart';
import 'package:onematrix/features/sales_orders/sales_orders_screen.dart';
import 'package:onematrix/features/fulfilment/fulfilment_models.dart';

import 'o2c_fixtures.dart';

Map<String, Object?> shipmentJson({String status = 'booked'}) => {
  'id': 's1',
  'number': 'SHP/26-27/0001',
  'orderId': 'o1',
  'orderNumber': 'SO/26-27/0001',
  'invoiceId': 'inv1',
  'invoiceNumber': 'INV/0001',
  'invoiceTotal': 590,
  'partyName': 'Acme Traders Private Limited',
  'courier': 'Delhivery',
  'awb': 'AWB123',
  'mode': 'prepaid',
  'codAmount': 0,
  'status': status,
  'lines': [
    {'id': 'sl1', 'itemName': 'Brake pad', 'unit': 'pcs', 'qty': 5},
  ],
  'history': [
    {'status': 'booked', 'at': '2026-11-01T11:00:00Z', 'by': 'Rita'},
  ],
};

Map<String, Object?> returnJson({String status = 'requested'}) => {
  'id': 'r1',
  'number': 'RMA/26-27/0001',
  'type': 'customer_return',
  'status': status,
  'reason': 'Damaged in transit',
  'locationName': 'Main warehouse',
  'orderId': 'o1',
  'orderNumber': 'SO/26-27/0001',
  'partyName': 'Acme Traders Private Limited',
  'lines': [
    {
      'id': 'rl1',
      'itemName': 'Brake pad',
      'unit': 'pcs',
      'qty': 2,
      'qtyReceived': status == 'requested' ? 0 : 2,
    },
  ],
};

void main() {
  for (final size in [narrow, wide]) {
    final tag = '${size.width.toInt()}px';

    testWidgets('orders list renders at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /sales-orders', pageOf([orderJson(status: 'confirmed')]));
      await pumpControls(
        tester,
        const SalesOrdersScreen(),
        b,
        size: size,
        permissions: o2cPerms,
      );
      expect(find.text('SO/26-27/0001'), findsOneWidget);
      expect(find.text('Confirmed'), findsWidgets);
      expect(find.text('New order'), findsOneWidget);
      await noOverflow(tester);
    });

    testWidgets('order detail shows stages and timeline at $tag', (
      tester,
    ) async {
      final b = FakeControlsBackend()
        ..on(
          'GET /sales-orders/o1',
          orderJson(
            status: 'picking',
            lines: [orderLine(picked: 3, short: 0)],
            events: [
              {
                'kind': 'confirmed',
                'message': 'Order confirmed',
                'createdAt': '2026-11-01T10:05:00Z',
                'by': 'Rita',
              },
            ],
            shipments: [
              {
                'id': 's1',
                'number': 'SHP/1',
                'status': 'booked',
                'awb': 'AWB1',
              },
            ],
          ),
        );
      await pumpControls(
        tester,
        const SalesOrderDetailScreen(orderId: 'o1'),
        b,
        size: size,
        permissions: o2cPerms,
      );
      expect(find.text('SO/26-27/0001'), findsOneWidget);
      expect(find.text('Order confirmed'), findsOneWidget);
      expect(find.text('Brake pad'), findsOneWidget);
      expect(find.text('Picked'), findsWidgets);
      await noOverflow(tester);
    });

    testWidgets('shipment detail renders at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /shipments/s1', shipmentJson(status: 'in_transit'));
      await pumpControls(
        tester,
        const ShipmentDetailScreen(shipmentId: 's1'),
        b,
        size: size,
        permissions: o2cPerms,
      );
      expect(find.text('SHP/26-27/0001'), findsOneWidget);
      expect(find.text('AWB123'), findsOneWidget);
      await noOverflow(tester);
    });

    testWidgets('returns list renders at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /sales-returns', pageOf([returnJson()]));
      await pumpControls(
        tester,
        const ReturnsScreen(),
        b,
        size: size,
        permissions: o2cPerms,
      );
      expect(find.text('RMA/26-27/0001'), findsOneWidget);
      await noOverflow(tester);
    });

    testWidgets('pick list screen renders at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /pick-lists/pl1', {
          'id': 'pl1',
          'number': 'PCK/26-27/0001',
          'status': 'open',
          'locationId': 'loc1',
          'locationName': 'Main warehouse',
          'orderNumbers': ['SO/26-27/0001'],
          'totalTarget': 5,
          'totalPicked': 2,
          'lines': [
            {
              'id': 'pk1',
              'orderNumber': 'SO/26-27/0001',
              'itemName': 'Brake pad',
              'unit': 'pcs',
              'qtyTarget': 5,
              'qtyPicked': 2,
            },
          ],
        });
      await pumpControls(
        tester,
        const PickListDetailScreen(pickListId: 'pl1'),
        b,
        size: size,
        permissions: o2cPerms,
      );
      expect(find.byKey(const ValueKey('scan-field')), findsOneWidget);
      expect(find.text('2 / 5 pcs'), findsOneWidget);
      await noOverflow(tester);
    });
  }

  testWidgets('scan panel keeps focus, clears the field and shows results', (
    tester,
  ) async {
    final scans = <(String, String, double)>[];
    var fail = false;
    await pumpControls(
      tester,
      ScanPanel(
        onScan: (id, code, qty) async {
          scans.add((id, code, qty));
          if (fail) throw Exception('boom');
          return ScanResult(duplicate: false, itemName: 'Brake pad', qty: qty);
        },
      ),
      FakeControlsBackend(),
      size: narrow,
    );
    final field = find.byKey(const ValueKey('scan-field'));
    EditableText editable() => tester.widget<EditableText>(
      find.descendant(of: field, matching: find.byType(EditableText)),
    );
    expect(editable().focusNode.hasFocus, isTrue, reason: 'autofocus');

    await tester.enterText(field, '8901234567890');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(scans.single.$2, '8901234567890');
    expect(scans.single.$3, 1);
    expect(editable().controller.text, isEmpty);
    expect(editable().focusNode.hasFocus, isTrue, reason: 'focus kept');
    expect(find.textContaining('Added 1'), findsOneWidget);

    // Manual quantity applies once, then resets to 1.
    await tester.enterText(find.byKey(const ValueKey('scan-qty')), '3');
    await tester.enterText(field, 'SKU-2');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(scans.last.$3, 3);
    expect(scans.last.$1, isNot(scans.first.$1), reason: 'unique scan ids');
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('scan-qty')))
          .controller!
          .text,
      '1',
    );

    // Failure is shown, the previous success is replaced.
    fail = true;
    await tester.enterText(field, 'BAD');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.textContaining('BAD:'), findsOneWidget);
    expect(find.textContaining('Added 1'), findsNothing);

    // Clearing the result keeps focus in the scan field.
    await tester.tap(find.byTooltip('Clear result'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('scan-result')), findsNothing);
    expect(editable().focusNode.hasFocus, isTrue);

    // Empty input is ignored.
    final before = scans.length;
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(scans.length, before);
  });

  testWidgets('pack screen posts scans with an id, code and quantity', (
    tester,
  ) async {
    final b = FakeControlsBackend()
      ..on(
        'GET /sales-orders/o1',
        orderJson(status: 'picking', lines: [orderLine(picked: 5, packed: 1)]),
      )
      ..on('POST /sales-orders/o1/pack-scans', {
        'duplicate': false,
        'item': {'id': 'i-l1', 'name': 'Brake pad', 'sku': 'BRK-RED'},
        'qty': 1,
      });
    await pumpControls(
      tester,
      const PackScreen(orderId: 'o1'),
      b,
      size: wide,
      permissions: o2cPerms,
    );
    await tester.enterText(find.byKey(const ValueKey('scan-field')), 'BRK-RED');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final req = b.last('POST', '/sales-orders/o1/pack-scans')!;
    final body = req.data as Map;
    expect(body['code'], 'BRK-RED');
    expect(body['qty'], 1);
    expect((body['scanId'] as String).isNotEmpty, isTrue);
    expect(find.text('Packed 1 / 5 pcs'), findsOneWidget);
    expect(find.text('Mark as packed'), findsOneWidget);
  });

  testWidgets('dispatch retry reuses one Idempotency-Key', (tester) async {
    final order = SalesOrder.fromJson(
      orderJson(status: 'packed', lines: [orderLine(picked: 5, packed: 5)]),
    );
    final b = FakeControlsBackend();
    var calls = 0;
    b.routes['POST /sales-orders/o1/dispatch'] = (_) {
      calls++;
      if (calls == 1) {
        return (
          500,
          {
            'error': {'code': 'INTERNAL', 'message': 'Try again'},
          },
        );
      }
      return (201, shipmentJson());
    };
    Shipment? result;
    await pumpControls(
      tester,
      Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showDialog<Shipment>(
            context: context,
            builder: (_) => DispatchDialog(order: order),
          ),
          child: const Text('open'),
        ),
      ),
      b,
      size: narrow,
      permissions: o2cPerms,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Dispatch SO/26-27/0001'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Dispatch'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(result, isNull, reason: 'dialog stays open after a failure');

    await tester.tap(find.widgetWithText(FilledButton, 'Dispatch'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    final posts = b.requests
        .where((r) => r.path == '/sales-orders/o1/dispatch')
        .toList();
    final keys = posts.map((r) => r.headers['Idempotency-Key']).toSet();
    expect(keys.length, 1);
    expect(keys.single, isNotNull);
    expect(result?.number, 'SHP/26-27/0001');
  });

  testWidgets('draft order offers confirm and edit, not dispatch', (
    tester,
  ) async {
    final b = FakeControlsBackend()..on('GET /sales-orders/o1', orderJson());
    await pumpControls(
      tester,
      const SalesOrderDetailScreen(orderId: 'o1'),
      b,
      size: wide,
      permissions: o2cPerms,
    );
    expect(find.text('Confirm order'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Dispatch'), findsNothing);
  });

  testWidgets('read-only users see no order actions', (tester) async {
    final b = FakeControlsBackend()..on('GET /sales-orders/o1', orderJson());
    await pumpControls(
      tester,
      const SalesOrderDetailScreen(orderId: 'o1'),
      b,
      size: wide,
      permissions: const {'sales_orders.view'},
    );
    expect(find.text('Confirm order'), findsNothing);
    expect(find.text('Cancel order'), findsNothing);
  });

  testWidgets('return inspect sends a disposition per received line', (
    tester,
  ) async {
    final b = FakeControlsBackend()
      ..on('GET /sales-returns/r1', returnJson(status: 'received'))
      ..on('POST /sales-returns/r1/inspect', returnJson(status: 'inspected'));
    await pumpControls(
      tester,
      const ReturnDetailScreen(returnId: 'r1'),
      b,
      size: wide,
      permissions: o2cPerms,
    );
    await tester.tap(find.text('Inspect goods'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('disposition-rl1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Damaged').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save inspection'));
    await tester.pumpAndSettle();
    final body = b.last('POST', '/sales-returns/r1/inspect')!.data as Map;
    final line = (body['lines'] as List).single as Map;
    expect(line['lineId'], 'rl1');
    expect(line['disposition'], 'damaged');
  });

  testWidgets('order form requires at least one item', (tester) async {
    final b = FakeControlsBackend()..on('GET /locations', pageOf(<Object?>[]));
    await pumpControls(
      tester,
      const SalesOrderFormScreen(),
      b,
      size: narrow,
      permissions: o2cPerms,
    );
    expect(find.text('New sales order'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Save draft'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(find.text('Add at least one item'), findsOneWidget);
    expect(b.last('POST', '/sales-orders'), isNull);
  });
}
