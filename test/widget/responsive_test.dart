import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../construction/support/construction_harness.dart';
import '../realestate/re_harness.dart';
import '../support/app_harness.dart';

/// Every main list, detail and form route at 320 x 640 with text scale 1.3:
/// no layout overflow and no runtime error.
const _small = Size(320, 640);

void _bigText(WidgetTester tester) {
  tester.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

String current = '';

String _where(FlutterErrorDetails d) {
  final lines = d.toString().split('\n');
  final head = lines.firstWhere(
    (l) => l.contains('overflowed'),
    orElse: () => lines.first,
  );
  final where = lines
      .where((l) => l.contains('lib/'))
      .take(2)
      .map((l) => l.trim().replaceAll(RegExp(r'.*?(?=lib/)'), ''));
  return '${head.trim()} @ ${where.join(' ; ')}';
}

void main() {
  const core = [
    '/dashboard',
    '/invoices',
    '/invoices/new',
    '/invoices/new?partyId=p1',
    '/invoices/inv1',
    '/credit-notes',
    '/credit-notes/new',
    '/credit-notes/new?invoiceId=inv1',
    '/credit-notes/cn1',
    '/receipts',
    '/receipts/new',
    '/receipts/new?partyId=p1&docId=inv1&amount=521',
    '/receipts/pay1',
    '/purchases',
    '/purchases/new',
    '/purchases/new?partyId=p2',
    '/purchases/pur1',
    '/payments',
    '/payments/new?partyId=p2&docId=pur1&amount=8000',
    '/payments/pay2',
    '/expenses',
    '/expenses/new',
    '/expenses/exp1',
    '/items',
    '/items/new',
    '/items/i1',
    '/stock',
    '/stock?lowOnly=true',
    '/stock/moves?itemId=i1&locationId=l1&title=Cement',
    '/transfers',
    '/transfers/new',
    '/transfers/trf1',
    '/parties',
    '/parties/new',
    '/parties/p1',
    '/parties/p1/edit',
    '/parties/p2',
    '/locations',
    '/users',
    '/users/new',
    '/audit',
    '/no-access',
  ];
  const construction = [
    '/projects',
    '/projects/new',
    '/projects/pr1',
    '/projects/pr1?tab=boq',
    '/projects/pr1?tab=costs',
    '/projects/pr1?tab=dprs',
    '/projects/pr1?tab=indents',
    '/projects/pr1/edit',
    '/dprs',
    '/dprs/new?locationId=l2',
    '/dprs/dpr1',
    '/dprs/dpr2',
    '/dprs/dpr1/edit',
    '/attendance?siteId=l2&date=2026-10-27',
    '/indents',
    '/indents/new',
    '/indents/ind1',
    '/indents/ind2/edit',
    '/issues',
    '/issues/new',
    '/issues/iss1',
    '/workers',
    '/workers/new',
    '/workers/w1',
    '/workers/w1/edit',
    '/wage-sheets',
    '/wage-sheets/new',
    '/wage-sheets/wg1',
  ];
  const realEstate = [
    '/units',
    '/payment-plans',
    '/payment-plans/new',
    '/payment-plans/pl1',
    '/bookings',
    '/bookings/new',
    '/bookings/bk1',
    '/demands',
    '/demands/dm1',
    '/rera',
  ];

  testWidgets('core screens fit 320 px at text scale 1.3', (tester) async {
    _bigText(tester);
    final failures = <String>[];
    final app = await bootApp(tester, _small);
    final orig = FlutterError.onError;
    FlutterError.onError = (d) {
      final m = '$current: ${_where(d)}';
      if (!failures.contains(m)) failures.add(m);
    };
    for (final route in core) {
      current = route;
      await app.go(route);
      tester.takeException();
    }
    FlutterError.onError = orig;
    expect(failures, isEmpty);
  });

  testWidgets('construction screens fit 320 px at text scale 1.3', (
    tester,
  ) async {
    _bigText(tester);
    final failures = <String>[];
    final app = await bootConstruction(tester, _small);
    final orig = FlutterError.onError;
    FlutterError.onError = (d) {
      final m = '$current: ${_where(d)}';
      if (!failures.contains(m)) failures.add(m);
    };
    for (final route in construction) {
      current = route;
      await app.go(route);
      tester.takeException();
    }
    FlutterError.onError = orig;
    expect(failures, isEmpty);
  });

  testWidgets('real estate screens fit 320 px at text scale 1.3', (
    tester,
  ) async {
    _bigText(tester);
    final failures = <String>[];
    final app = await bootRe(tester, _small);
    final orig = FlutterError.onError;
    FlutterError.onError = (d) {
      final m = '$current: ${_where(d)}';
      if (!failures.contains(m)) failures.add(m);
    };
    for (final route in realEstate) {
      current = route;
      await app.go(route);
      tester.takeException();
    }
    FlutterError.onError = orig;
    expect(failures, isEmpty);
  });
}
