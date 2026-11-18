import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/core/providers.dart';
import 'package:onematrix/core/token_store.dart';
import 'package:onematrix/features/auth/session.dart';

import '../controls/controls_harness.dart';

export '../controls/controls_harness.dart';

const narrow = Size(320, 640);
const wide = Size(1440, 900);

const qtnPerms = {
  'quotations.view',
  'quotations.manage',
  'sales_orders.manage',
  'invoices.create',
  'parties.view',
  'parties.edit',
  'locations.view',
  'items.view',
};

Map<String, Object?> qLine({
  String id = 'l1',
  String name = 'Brake pad',
  String itemId = 'i1',
  double qty = 5,
  double rate = 100,
  double discountPct = 0,
  double discountAmount = 0,
}) => {
  'id': id,
  'lineNo': 1,
  'itemId': itemId,
  'itemName': name,
  'unit': 'pcs',
  'hsn': '8708',
  'description': '',
  'qty': qty,
  'rate': rate,
  'discountPct': discountPct,
  'discountAmount': discountAmount,
  'gstRate': 18,
  'taxable': 500,
  'tax': 90,
  'total': 590,
};

Map<String, Object?> qJson({
  String id = 'q1',
  String status = 'draft',
  String kind = 'quotation',
  bool expired = false,
  List<Object?>? lines,
  String? declineReason,
  String? salesOrderId,
  String? invoiceId,
  String? contactId,
}) => {
  'id': id,
  'kind': kind,
  'number': kind == 'proforma' ? 'PI/26-27/0001' : 'QTN/26-27/0001',
  'fy': '2026-27',
  'status': status,
  'expired': expired,
  'locationId': 'l1',
  'locationName': 'Head Office',
  'partyId': 'p1',
  'partyName': 'Acme Traders Private Limited',
  'contactId': contactId,
  'dealId': null,
  'quoteDate': '2026-11-01',
  'validUntil': '2026-11-16',
  'placeOfSupply': '29',
  'subtotal': 500,
  'taxTotal': 90,
  'total': 590,
  'notes': 'Delivery in a week',
  'terms': 'Payment within 30 days',
  'revisionOf': null,
  'salesOrderId': salesOrderId,
  'invoiceId': invoiceId,
  'sentAt': null,
  'acceptedAt': null,
  'declinedAt': null,
  'declineReason': declineReason,
  'createdBy': {'id': 'u1', 'name': 'Rita'},
  'createdAt': '2026-11-01T10:00:00Z',
  'updatedAt': '2026-11-01T10:00:00Z',
  'lines': lines ?? [qLine()],
  'taxSplit': {'cgst': 45, 'sgst': 45, 'igst': 0},
};

Map<String, Object?> contactJson({
  String id = 'c1',
  String name = 'Meera Shah',
  bool primary = true,
}) => {
  'id': id,
  'name': name,
  'designation': 'Purchase manager',
  'phone': '9876543210',
  'email': 'meera@acme.in',
  'isPrimary': primary,
  'notes': null,
};

/// Pumps [child] at [path] inside a router with stub pages for the places the
/// screens navigate to. `visited` records the locations reached.
Future<List<String>> pumpRouted(
  WidgetTester tester,
  Widget child,
  FakeControlsBackend backend, {
  Size size = wide,
  Set<String> permissions = qtnPerms,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final visited = <String>[];
  Widget stub(GoRouterState s) {
    visited.add(s.uri.toString());
    return Scaffold(body: Text('stub ${s.uri}'));
  }

  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (c, s) => Scaffold(body: child),
      ),
      GoRoute(path: '/quotations/:id', builder: (c, s) => stub(s)),
      GoRoute(path: '/quotations', builder: (c, s) => stub(s)),
      GoRoute(path: '/sales-orders/:id', builder: (c, s) => stub(s)),
      GoRoute(path: '/invoices/:id', builder: (c, s) => stub(s)),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(fakeApi(backend)),
        permissionsProvider.overrideWithValue(PermissionSet(permissions)),
        activeCompanyIdProvider.overrideWithValue('c1'),
        tokenStoreProvider.overrideWithValue(InMemoryTokenStore()),
      ],
      child: MaterialApp.router(routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return visited;
}

const headOffice = {
  'id': 'l1',
  'companyId': 'c1',
  'type': 'branch',
  'name': 'Head Office',
  'code': 'HO',
  'stateCode': '29',
  'isActive': true,
};

const cementItem = {
  'id': 'i1',
  'companyId': 'c1',
  'name': 'Portland Cement',
  'unit': 'bag',
  'gstRate': 28,
  'salePrice': 420,
  'trackStock': true,
  'isActive': true,
};
