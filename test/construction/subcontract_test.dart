import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/construction/models/project_models.dart';
import 'package:onematrix/features/construction/models/subcontract_models.dart';

import 'support/construction_harness.dart';

Map<String, Object?> _page(List<Map<String, Object?>> rows) => {
  'data': rows,
  'total': rows.length,
};

final _wo = <String, Object?>{
  'id': 'wo1',
  'number': 'WO-0001',
  'projectId': 'p1',
  'projectName': 'Tower A',
  'contractorPartyId': 'c1',
  'contractorName': 'Sharma Civil Works',
  'date': '2026-04-01',
  'title': 'Brick work',
  'status': 'active',
  'retentionPct': 5,
  'advanceRecoveryPct': 10,
  'tdsPct': 1,
  'gstPct': 18,
  'itcEligible': true,
  'cessPct': 1,
  'totalValue': 500000,
  'billedGross': 100000,
  'hasFinalBill': false,
  'advance': {'paid': 50000, 'recovered': 10000, 'balance': 40000},
  'retention': {'held': 5000, 'released': 0, 'balance': 5000},
  'lines': [
    {
      'id': 'l1',
      'lineNo': 1,
      'description': 'Brick masonry',
      'unit': 'cum',
      'qty': 100,
      'rate': 5000,
      'amount': 500000,
      'billedQty': 20,
    },
  ],
};

final _bill = <String, Object?>{
  'id': 'rb1',
  'number': 'RA-0001',
  'workOrderId': 'wo1',
  'workOrderNumber': 'WO-0001',
  'projectId': 'p1',
  'projectName': 'Tower A',
  'contractorPartyId': 'c1',
  'contractorName': 'Sharma Civil Works',
  'billSeq': 1,
  'date': '2026-05-01',
  'status': 'approved',
  'isFinal': false,
  'gross': 100000,
  'cgst': 9000,
  'sgst': 9000,
  'igst': 0,
  'invoiceTotal': 118000,
  'retention': 5000,
  'advanceRecovery': 10000,
  'tds': 1000,
  'cess': 1000,
  'otherDeduction': 0,
  'totalDeductions': 17000,
  'netPayable': 101000,
  'amountPaid': 0,
  'amountDue': 101000,
  'paymentStatus': 'unpaid',
};

final _advance = <String, Object?>{
  'id': 'la1',
  'number': 'LA-0001',
  'workerId': 'w1',
  'workerName': 'Ramesh',
  'date': '2026-05-02',
  'amount': 2000,
  'recovered': 500,
  'balance': 1500,
  'status': 'open',
};

void main() {
  group('subcontract models', () {
    test('WorkOrder.fromJson', () {
      final wo = WorkOrder.fromJson(_wo);
      expect(wo.status, WorkOrderStatus.active);
      expect(wo.advance.balance, 40000);
      expect(wo.retention.held, 5000);
      expect(wo.lines!.single.billedQty, 20);
      expect(wo.lines!.single.billedPct, 20);
    });

    test('RaBill.fromJson', () {
      final b = RaBill.fromJson(_bill);
      expect(b.status, RaBillStatus.approved);
      expect(b.paymentStatus, RaPaymentStatus.unpaid);
      expect(b.gst, 18000);
      expect(b.netPayable, 101000);
      expect(b.lines, isNull);
    });

    test('LabourAdvance.fromJson and unknown values', () {
      final a = LabourAdvance.fromJson(_advance);
      expect(a.status, LabourAdvanceStatus.open);
      expect(a.balance, 1500);
      expect(WorkOrder.fromJson({'id': 'x'}).lines, isNull);
    });

    test('CostSplit reads subcontract', () {
      expect(CostSplit.fromJson({'subcontract': 1200}).subcontract, 1200);
    });
  });

  group('RA bill net payable', () {
    const terms = RaTerms(
      gstPct: 18,
      retentionPct: 5,
      advanceRecoveryPct: 10,
      tdsPct: 1,
      cessPct: 1,
      advanceBalance: 40000,
    );
    const lines = [RaMeasure(rate: 5000, prevQty: 0, cumQty: 20)];

    test('defaults from the work order terms', () {
      final m = RaBillMath.compute(lines, terms);
      expect(m.gross, 100000);
      expect(m.gst, 18000);
      expect(m.retention, 5000);
      expect(m.advanceRecovery, 10000);
      expect(m.tds, 1000);
      expect(m.cess, 1000);
      expect(m.netPayable, 101000);
      expect(m.isNegative, isFalse);
    });

    test('advance recovery is capped by the balance', () {
      final m = RaBillMath.compute(
        lines,
        const RaTerms(advanceRecoveryPct: 50, advanceBalance: 8000),
      );
      expect(m.advanceRecovery, 8000);
    });

    test('previous quantity is deducted from the cumulative one', () {
      final m = RaBillMath.compute(const [
        RaMeasure(rate: 100, prevQty: 4.5, cumQty: 6.25),
      ], const RaTerms());
      expect(m.gross, 175);
    });

    test('overrides replace defaults and a negative net is flagged', () {
      final m = RaBillMath.compute(
        lines,
        terms,
        overrides: {'otherDeduction': 150000},
      );
      expect(m.otherDeduction, 150000);
      expect(m.netPayable, lessThan(0));
      expect(m.isNegative, isTrue);
    });

    test('rounds to paise', () {
      final m = RaBillMath.compute(const [
        RaMeasure(rate: 33.33, prevQty: 0, cumQty: 3),
      ], const RaTerms(gstPct: 18));
      expect(m.gross, 99.99);
      expect(m.gst, 18);
    });
  });

  group('subcontract list screens', () {
    final sizes = [
      const Size(390, 844),
      const Size(768, 1024),
      const Size(1280, 800),
    ];
    final routes = {
      '/work-orders': ('GET /work-orders', [_wo], 'Brick work'),
      '/ra-bills': ('GET /ra-bills', [_bill], 'RA-0001'),
      '/labour-advances': ('GET /labour-advances', [_advance], 'LA-0001'),
    };
    for (final size in sizes) {
      for (final MapEntry(key: route, value: (key, rows, marker))
          in routes.entries) {
        testWidgets('$route at ${size.width.toInt()} px', (tester) async {
          final app = await bootConstruction(tester, size);
          app.backend.overrides[key] = (200, _page(rows));
          await app.go(route);
          expect(find.textContaining(marker), findsWidgets);
          app.expectClean('$route at $size');
        });
      }
    }

    testWidgets('lists are locked without permission', (tester) async {
      final app = await bootConstruction(
        tester,
        const Size(390, 844),
        permissions: {'dashboard.view'},
      );
      for (final route in routes.keys) {
        await app.go(route);
        expect(find.textContaining('You do not have access'), findsOneWidget);
      }
    });
  });

  group('subcontract detail and form screens', () {
    final template = {
      ..._bill,
      'status': 'draft',
      'lines': [
        {
          'workOrderLineId': 'l1',
          'description': 'Brick masonry',
          'unit': 'cum',
          'rate': 5000,
          'qty': 100,
          'prevQty': 20,
          'cumQty': 20,
          'thisQty': 0,
          'amount': 0,
        },
      ],
    };
    for (final size in [const Size(390, 844), const Size(1280, 800)]) {
      testWidgets('render at ${size.width.toInt()} px', (tester) async {
        final app = await bootConstruction(tester, size);
        app.backend.overrides.addAll({
          'GET /work-orders/wo1': (200, _wo),
          'GET /work-orders/wo1/advances': (200, _page([])),
          'GET /work-orders/wo1/retention-releases': (200, _page([])),
          'GET /work-orders/wo1/ra-bill-template': (200, template),
          'GET /ra-bills': (200, _page([_bill])),
          'GET /ra-bills/rb1': (200, template),
        });
        await app.go('/work-orders/wo1');
        expect(find.textContaining('Brick masonry'), findsWidgets);
        app.expectClean('work order detail');
        await app.go('/ra-bills/new?workOrderId=wo1');
        expect(find.textContaining('Net payable'), findsWidgets);
        await tester.enterText(
          find.widgetWithText(TextFormField, 'Cumulative qty (cum)'),
          '30',
        );
        await tester.pump();
        expect(find.textContaining('50,000'), findsWidgets);
        app.expectClean('ra bill form');
        await app.go('/ra-bills/rb1');
        expect(find.textContaining('Measurements'), findsWidgets);
        app.expectClean('ra bill detail');
      });
    }
  });
}
