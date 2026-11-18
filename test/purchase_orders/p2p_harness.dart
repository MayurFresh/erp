import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/auth/session.dart';
import 'package:onematrix/core/api_client.dart';

import 'package:onematrix/features/controls/controls_perms.dart';
import '../controls/controls_harness.dart';

export '../controls/controls_harness.dart'
    show FakeControlsBackend, pageOf, fakeApi;

/// Widths the pack is checked at: smallest phone and a wide desktop.
const p2pSizes = [Size(320, 640), Size(1440, 900)];

const allP2pPerms = {
  'purchase_orders.view',
  'purchase_orders.manage',
  'grn.manage',
  'purchases.view',
  'purchases.create',
  'purchases.override',
  'items.view_cost',
  'stock.view',
  'stock_counts.manage',
  'stock_counts.approve',
};

/// Pumps [child] with the app theme and stubbed session providers.
Future<void> pumpP2p(
  WidgetTester tester,
  Widget child,
  FakeControlsBackend backend, {
  Size size = const Size(1440, 900),
  Set<String> permissions = allP2pPerms,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ApiClient api = fakeApi(backend);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        permissionsProvider.overrideWithValue(PermissionSet(permissions)),
        activeCompanyIdProvider.overrideWithValue('c1'),
        currentUserIdProvider.overrideWithValue('u1'),
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Map<String, Object?> poLine({
  String id = 'pl1',
  String itemId = 'i1',
  String name = 'Cement 50kg',
  String sku = 'CEM50',
  double qty = 10,
  double received = 4,
  double billed = 0,
  double open = 6,
  double rate = 400,
}) => {
  'id': id,
  'lineNo': 1,
  'itemId': itemId,
  'itemName': name,
  'sku': sku,
  'description': name,
  'qty': qty,
  'unit': 'bag',
  'rate': rate,
  'discountPct': 0,
  'gstRate': 18,
  'taxableValue': qty * rate,
  'cgst': qty * rate * 0.09,
  'sgst': qty * rate * 0.09,
  'igst': 0,
  'lineTotal': qty * rate * 1.18,
  'receivedQty': received,
  'rejectedQty': 0,
  'billedQty': billed,
  'cancelledQty': 0,
  'openQty': open,
};

Map<String, Object?> poJson({
  String id = 'po1',
  String status = 'partially_received',
  bool withLines = true,
}) => {
  'id': id,
  'number': 'PO/26-27/00001',
  'status': status,
  'orderDate': '2026-11-01',
  'expectedDate': '2026-11-10',
  'locationId': 'l1',
  'locationName': 'Main store',
  'partyId': 'p1',
  'partyName': 'Acme Steel',
  'placeOfSupply': '27',
  'supplyType': 'intra',
  'subtotal': 4000,
  'cgst': 360,
  'sgst': 360,
  'igst': 0,
  'taxTotal': 720,
  'roundOff': 0,
  'total': 4720,
  'progress': {'ordered': 10, 'received': 4, 'billed': 0, 'cancelled': 0},
  if (withLines) 'lines': [poLine()],
  if (withLines) 'receipts': <Object?>[],
  if (withLines) 'bills': <Object?>[],
};

Map<String, Object?> grnJson({double billable = 4, double poRate = 400}) => {
  'id': 'g1',
  'number': 'GRN/26-27/00001',
  'status': 'posted',
  'receiptDate': '2026-11-02',
  'purchaseOrderId': 'po1',
  'purchaseOrderNumber': 'PO/26-27/00001',
  'partyId': 'p1',
  'partyName': 'Acme Steel',
  'locationId': 'l1',
  'locationName': 'Main store',
  'lines': [
    {
      'id': 'gl1',
      'poLineId': 'pl1',
      'itemId': 'i1',
      'itemName': 'Cement 50kg',
      'unit': 'bag',
      'receivedQty': 4,
      'acceptedQty': 4,
      'rejectedQty': 0,
      'poRate': poRate,
      'discountPct': 0,
      'unitCost': poRate,
      'gstRate': 18,
      'value': 4 * poRate,
      'billedQty': 0,
      'billableQty': billable,
    },
  ],
};

Map<String, Object?> countJson({
  String status = 'open',
  bool counted = false,
}) => {
  'id': 'c1',
  'number': 'CNT/26-27/00001',
  'status': status,
  'scope': 'all',
  'locationId': 'l1',
  'locationName': 'Main store',
  'snapshotAt': '2026-11-03T09:00:00Z',
  'thresholdValue': 10000,
  'summary': {
    'lines': 2,
    'counted': counted ? 1 : 0,
    'uncounted': 2,
    'withVariance': 0,
  },
  'lines': [
    {
      'itemId': 'i1',
      'itemName': 'Cement 50kg',
      'sku': 'CEM50',
      'unit': 'bag',
      'expectedQty': 10,
      'movedSince': 0,
      'expectedNow': 10,
      'countedQty': counted ? 8 : null,
      'varianceQty': counted ? -2 : null,
      'varianceValue': counted ? -800 : null,
    },
    {
      'itemId': 'i2',
      'itemName': 'Binding wire',
      'sku': 'WIRE1',
      'unit': 'kg',
      'expectedQty': 5,
      'movedSince': 0,
      'expectedNow': 5,
    },
  ],
};
