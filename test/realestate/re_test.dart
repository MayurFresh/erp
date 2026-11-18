import 'package:flutter/material.dart' show Key;
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/company/company_model.dart';
import 'package:onematrix/features/payments/payment_model.dart';
import 'package:onematrix/features/realestate/demand_pdf.dart';
import 'package:onematrix/features/realestate/re_models.dart';

import 're_harness.dart';

void main() {
  group('models', () {
    test('Unit.fromJson', () {
      final u = Unit.fromJson(unitJson);
      expect(u.code, 'A-101');
      expect(u.status, UnitStatus.available);
      expect(u.status.bookable, isTrue);
      expect(u.listPrice, 6500000);
    });

    test('Booking.fromJson and helpers', () {
      final b = Booking.fromJson(bookingJson);
      expect(b.stages, hasLength(2));
      expect(b.undemandedStages.single.id, 's2');
      expect(b.allDemanded, isFalse);
      expect(b.preAgreementCap, 650000);
      expect(b.totals.due, 682500);
    });

    test('Demand.fromJson', () {
      final d = Demand.fromJson(demandJson);
      expect(d.total, 682500);
      expect(d.stageNames, 'On booking');
      expect(d.isCancelled, isFalse);
    });

    test('ProjectRera.fromJson', () {
      final r = ProjectRera.fromJson({
        'projectId': 'pr1',
        'required': 700000,
        'shortfall': 200000,
      });
      expect(r.hasShortfall, isTrue);
    });

    test('unknown status falls back instead of throwing', () {
      expect(
        Unit.fromJson({...unitJson, 'status': 'weird'}).status,
        UnitStatus.available,
      );
    });
  });

  group('plan stages', () {
    ({String name, double? pct}) s(String n, double? p) => (name: n, pct: p);

    test('must sum to 100', () {
      expect(stagesError([s('a', 10), s('b', 90)]), isNull);
      expect(stagesError([s('a', 10), s('b', 80)]), isNotNull);
      expect(
        stagesError([s('a', 33.33), s('b', 33.33), s('c', 33.34)]),
        isNull,
      );
    });

    test('rejects empty, unnamed and missing pct', () {
      expect(stagesError([]), isNotNull);
      expect(stagesError([s('', 100)]), isNotNull);
      expect(stagesError([s('a', null)]), isNotNull);
      expect(stagesError([s('a', 0), s('b', 100)]), isNotNull);
    });

    test('at most 30 stages', () {
      expect(
        stagesError([for (var i = 0; i < 31; i++) s('s$i', 100 / 31)]),
        isNotNull,
      );
    });
  });

  test('generateUnitCodes builds wing-floor-unit codes', () {
    final codes = generateUnitCodes(
      wing: 'a',
      firstFloor: 1,
      floors: 2,
      unitsPerFloor: 3,
    );
    expect(codes.map((c) => c.code), [
      'A-101',
      'A-102',
      'A-103',
      'A-201',
      'A-202',
      'A-203',
    ]);
    expect(codes.first.floor, 1);
    expect(
      generateUnitCodes(
        wing: '',
        firstFloor: 0,
        floors: 1,
        unitsPerFloor: 1,
      ).single.code,
      '001',
    );
  });

  test('payments accept ra_bill and demand allocations', () {
    for (final (type, label, route) in [
      ('demand', 'Demand', '/demands/x1'),
      ('ra_bill', 'RA bill', '/ra-bills/x1'),
    ]) {
      final a = PaymentAllocation.fromJson({
        'docType': type,
        'docId': 'x1',
        'docNumber': 'N1',
        'docTotal': 10,
        'amount': 5,
      });
      expect(a.docTypeLabel, label);
      expect(a.route, route);
      final o = OpenDoc.fromJson({'id': 'x1', 'number': 'N1', 'docType': type});
      expect(o.kindLabel, label);
    }
  });

  test('demand letter PDF builds', () async {
    final bytes = await buildDemandPdf(
      Demand.fromJson(demandJson),
      const Company(id: 'c1', name: 'OneMatrix', stateCode: '29'),
    );
    expect(String.fromCharCodes(bytes.sublist(0, 5)), '%PDF-');
    expect(bytes.length, greaterThan(1000));
  });

  for (final size in reTestWidths) {
    testWidgets('lists render at ${size.width.toInt()} px', (tester) async {
      final app = await bootRe(tester, size);
      const routes = {
        '/units': 'A-101',
        '/payment-plans': 'Construction linked',
        '/payment-plans/new': 'Save plan',
        '/payment-plans/pl1': 'Σ 100% of 100%',
        '/bookings': 'BK/26-27/00001',
        '/bookings/new': 'Create booking',
        '/bookings/bk1': 'Payment schedule',
        '/demands': 'DM/26-27/00001',
        '/demands/dm1': 'Stages',
        '/rera': 'Shortfall of',
      };
      for (final MapEntry(key: route, value: marker) in routes.entries) {
        await app.go(route);
        expect(find.textContaining(marker), findsWidgets, reason: route);
        app.expectClean('$route at $size');
      }
    });
  }

  testWidgets('stacking view groups units by wing and floor', (tester) async {
    final app = await bootRe(tester, reTestWidths.last);
    await app.go('/units?projectId=pr1');
    await tester.tap(find.text('Stacking'));
    await tester.pumpAndSettle();
    expect(find.text('A-201'), findsOneWidget);
    expect(find.textContaining('Wing A'), findsOneWidget);
    app.expectClean('stacking');
  });

  testWidgets('plan editor blocks save until stages sum to 100', (
    tester,
  ) async {
    final app = await bootRe(tester, reTestWidths.first);
    await app.go('/payment-plans/new');
    expect(find.byKey(const Key('plan-sum')), findsOneWidget);
    expect(find.textContaining('Σ 100% of 100%'), findsOneWidget);
    await tester.tap(find.text('Add stage'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('plan-error')), findsOneWidget);
    app.expectClean('plan editor');
  });

  testWidgets('screens lock without permission', (tester) async {
    final app = await bootRe(
      tester,
      reTestWidths.first,
      permissions: {'dashboard.view'},
    );
    for (final r in ['/units', '/bookings', '/demands']) {
      await app.go(r);
      expect(find.textContaining('You do not have access'), findsOneWidget);
    }
  });
}
