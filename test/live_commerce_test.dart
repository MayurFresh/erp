@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/auth/auth_repository.dart';
import 'package:progen_erp/features/controls/controls_repository.dart';
import 'package:progen_erp/features/purchase_orders/po_repository.dart';
import 'package:progen_erp/features/sales_orders/o2c_repository.dart';
import 'package:progen_erp/features/stock_counts/count_repository.dart';

/// v1.8 client models against the real API and the seeded demo data (seed-o2c.ts and
/// seed-p2p.ts). Read-only, so the suite can run repeatedly.
void main() {
  final baseUrl = Platform.environment['PROGEN_API'];

  group(
    'live commerce',
    skip: baseUrl == null || baseUrl.isEmpty
        ? 'Set PROGEN_API (e.g. http://localhost:8080/api/v1) to run'
        : false,
    () {
      late ApiClient api;
      late O2cRepository o2c;
      late PoRepository po;

      setUpAll(() async {
        api = ApiClient(baseUrl: baseUrl!, tokenStore: InMemoryTokenStore());
        final auth = AuthRepository(api);
        await auth.login('owner@demo.in', 'Demo@1234');
        await api.setCompany((await auth.me()).companies.first.id);
        o2c = O2cRepository(api);
        po = PoRepository(api);
      });

      tearDownAll(() => api.close());

      test('sales orders and reservations', () async {
        final orders = await o2c.orders();
        expect(orders.total, 6);
        expect(
          orders.data.map((o) => o.status),
          containsAll(['draft', 'confirmed', 'picking', 'dispatched']),
        );

        final confirmed = await o2c.order(
          orders.data.firstWhere((o) => o.status == 'confirmed').id,
        );
        final line = confirmed.lines.first;
        expect(line.qtyReserved, greaterThan(0));
        expect(line.qtyReserved, line.qtyOrdered);

        // Available stock excludes what is held for orders.
        final avail = await o2c.availability(
          locationId: confirmed.locationId,
          q: line.sku,
        );
        final row = avail.data.firstWhere((a) => a.itemId == line.itemId);
        expect(row.reserved, greaterThanOrEqualTo(line.qtyReserved));
        expect(row.available, closeTo(row.onHand - row.reserved, 0.001));
      });

      test('shipments, invoices and the RTO return', () async {
        final ships = await o2c.shipments();
        expect(ships.total, 3);
        expect(
          ships.data.map((s) => s.status).toSet(),
          {'in_transit', 'delivered', 'rto_delivered'},
        );
        for (final s in ships.data) {
          expect(s.invoiceNumber, isNotNull);
          expect(s.awb, isNotEmpty);
        }
        final cod = ships.data.firstWhere((s) => s.mode == 'cod');
        expect(cod.codAmount, greaterThan(0));

        final returns = await o2c.returns();
        final rto = returns.data.singleWhere((r) => r.type == 'rto');
        expect(rto.status, 'inspected');
        final detail = await o2c.salesReturn(rto.id);
        expect(detail.lines, isNotEmpty);
        expect(detail.lines.every((l) => l.disposition != null), isTrue);
      });

      test('purchase orders, receipts, bills and approval', () async {
        final pos = await po.list();
        expect(pos.total, 5);
        expect(
          pos.data.map((p) => p.status),
          containsAll([
            'draft',
            'pending_approval',
            'sent',
            'partially_received',
            'closed',
          ]),
        );

        final closed = await po.get(
          pos.data.firstWhere((p) => p.status == 'closed').id!,
        );
        expect(closed.receipts, isNotEmpty);
        expect(closed.bills, isNotEmpty);

        final pending = pos.data.firstWhere(
          (p) => p.status == 'pending_approval',
        );
        final mine = await ControlsRepository(
          api,
        ).approvals(scope: 'awaiting_me');
        final req = mine.data.firstWhere((r) => r.docType == 'purchase_order');
        expect(req.amount, pending.total);
        expect(req.canAct, isTrue);

        // Parses even when nothing is below reorder level.
        expect(await po.reorder(null), isA<List<Object>>());
      });

      test('posted stock count', () async {
        final counts = await StockCountsRepository(api).list();
        expect(counts.total, 1);
        final count = await StockCountsRepository(
          api,
        ).get(counts.data.single.id);
        expect(count.status, 'posted');
        expect(count.lines, isNotEmpty);
        expect(count.varianceValue, isNot(0));
      });
    },
  );
}
