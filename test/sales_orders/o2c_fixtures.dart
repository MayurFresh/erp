import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

export '../controls/controls_harness.dart';

const o2cPerms = {
  'sales_orders.view',
  'sales_orders.manage',
  'fulfilment.manage',
  'returns.manage',
  'invoices.view',
};

const narrow = Size(320, 640);
const wide = Size(1440, 900);

Map<String, Object?> orderLine({
  String id = 'l1',
  String name = 'Brake pad',
  double ordered = 5,
  double reserved = 5,
  double picked = 0,
  double packed = 0,
  double dispatched = 0,
  double returned = 0,
  double short = 0,
}) => {
  'id': id,
  'lineNo': 1,
  'itemId': 'i-$id',
  'itemName': name,
  'sku': 'BRK-RED',
  'barcode': '8901234567890',
  'unit': 'pcs',
  'description': '',
  'qtyOrdered': ordered,
  'rate': 100,
  'discountPct': 0,
  'gstRate': 18,
  'allowBackorder': false,
  'qtyReserved': reserved,
  'qtyPicked': picked,
  'qtyPacked': packed,
  'qtyDispatched': dispatched,
  'qtyReturned': returned,
  'qtyCancelled': 0,
  'qtyOpen': ordered - dispatched,
  'qtyShort': short,
};

Map<String, Object?> orderJson({
  String id = 'o1',
  String status = 'draft',
  List<Object?>? lines,
  List<Object?> events = const [],
  List<Object?> shipments = const [],
}) => {
  'id': id,
  'number': 'SO/26-27/0001',
  'status': status,
  'source': 'manual',
  'locationId': 'loc1',
  'locationName': 'Main warehouse',
  'partyId': 'p1',
  'partyName': 'Acme Traders Private Limited',
  'orderDate': '2026-11-01',
  'subtotal': 500,
  'taxTotal': 90,
  'total': 590,
  'createdAt': '2026-11-01T10:00:00Z',
  'createdBy': {'id': 'u1', 'name': 'Rita'},
  'lines': lines ?? [orderLine()],
  'events': events,
  'shipments': shipments,
  'returns': <Object?>[],
};

Future<void> noOverflow(WidgetTester tester) async {
  expect(tester.takeException(), isNull);
}
