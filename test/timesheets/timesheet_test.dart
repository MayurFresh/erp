import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/timesheets/timesheet_models.dart';
import 'package:progen_erp/features/timesheets/timesheet_routes.dart';

import '../helpdesk/hd_harness.dart';

const _perms = {
  'timesheets.log',
  'timesheets.view',
  'timesheets.approve',
  'timesheets.bill',
};

Map<String, Object?> cell(String date, double hours, [String? status]) => {
  'id': hours > 0 ? 'e-$date' : null,
  'date': date,
  'hours': hours,
  'status': status,
};

Map<String, Object?> weekJson() => {
  'weekStart': '2026-11-09',
  'days': List.generate(7, (i) => '2026-11-${9 + i}'),
  'rows': [
    {
      'partyId': 'p1',
      'partyName': 'Acme Ltd',
      'task': 'Audit review',
      'billable': true,
      'entries': [
        cell('2026-11-09', 2, 'draft'),
        cell('2026-11-10', 3, 'approved'),
        for (var i = 2; i < 7; i++) cell('2026-11-${9 + i}', 0),
      ],
      'total': 5,
    },
  ],
  'dayTotals': [2, 3, 0, 0, 0, 0, 0],
  'total': 5,
  'status': 'mixed',
};

(int, Object?)? _handle(dynamic o) {
  switch ('${o.method} ${o.path}') {
    case 'GET /timesheets/week':
      return (200, weekJson());
    case 'PATCH /timesheets/week':
      return (200, weekJson());
    case 'POST /timesheets/submit':
      return (200, {'submitted': 1, 'status': 'submitted'});
    case 'GET /timesheets/entries':
      return (
        200,
        {
          'data': [
            {
              'id': 'e1',
              'userName': 'Ravi',
              'workDate': '2026-11-10',
              'partyName': 'Acme Ltd',
              'task': 'Audit review',
              'hours': 3,
              'billable': true,
              'rate': 1200,
              'amount': 3600,
              'status': 'submitted',
            },
          ],
          'total': 1,
        },
      );
    case 'POST /timesheets/approve':
      return (200, {'approved': 1});
    case 'GET /timesheets/unbilled':
      return (
        200,
        {
          'data': [
            {
              'partyId': 'p1',
              'partyName': 'Acme Ltd',
              'hours': 5,
              'amount': 6000,
              'entries': 2,
            },
          ],
        },
      );
    case 'GET /timesheets/settings':
      return (
        200,
        {
          'serviceItemId': null,
          'approvalRequired': true,
          'dailyTargetHours': 8,
        },
      );
    case 'GET /timesheets/rates':
      return (200, {'data': []});
    case 'POST /timesheets/bill':
      return (200, {'invoices': [], 'skipped': []});
  }
  return null;
}

void main() {
  test('mondayOf and hours text', () {
    expect(mondayOf(DateTime(2026, 11, 15)), DateTime(2026, 11, 9));
    expect(mondayOf(DateTime(2026, 11, 9)), DateTime(2026, 11, 9));
    expect(hoursText(2), '2');
    expect(hoursText(1.5), '1.5');
    expect(hoursText(0.25), '0.25');
  });

  test('week row sends only editable hours', () {
    final w = Week.fromJson(weekJson());
    final row = w.rows.single;
    expect(row.total, 5);
    expect(row.locked(1), isTrue);
    expect(row.locked(0), isFalse);
    expect(row.toJson()['hours'], [2.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0]);
  });

  for (final w in [320.0, 1200.0]) {
    testWidgets('week grid at ${w.toInt()}px', (tester) async {
      final b = await bootHd(
        tester,
        Size(w, 900),
        routes: timesheetRoutes(),
        initial: '/timesheets',
        extraPermissions: _perms,
        handler: _handle,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Acme Ltd'), findsOneWidget);
      expect(find.text('Audit review'), findsOneWidget);
      expect(find.text('Total 5 h'), findsOneWidget);
      // The approved day is locked.
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      expect(fields.where((f) => f.enabled == false), hasLength(1));
      await tester.enterText(find.widgetWithText(TextField, 'Wed'), '4');
      await tester.pump();
      expect(find.text('Total 9 h'), findsOneWidget);
      await tester.tap(find.text('Save and submit'));
      await tester.pumpAndSettle();
      final sent = b.last('PATCH', '/timesheets/week')!;
      final rows = (sent.data as Map)['rows'] as List;
      expect((rows.single as Map)['hours'], [
        2.0,
        0.0,
        4.0,
        0.0,
        0.0,
        0.0,
        0.0,
      ]);
      expect(b.last('POST', '/timesheets/submit'), isNotNull);
    });
  }

  testWidgets('approvals approve the submitted hours', (tester) async {
    final b = await bootHd(
      tester,
      const Size(390, 900),
      routes: timesheetRoutes(),
      initial: '/timesheets/approvals',
      extraPermissions: _perms,
      handler: _handle,
    );
    expect(find.text('Ravi: Acme Ltd'), findsOneWidget);
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();
    expect((b.last('POST', '/timesheets/approve')!.data as Map)['ids'], ['e1']);
  });

  testWidgets('billing lists unbilled time and bills a customer', (
    tester,
  ) async {
    final b = await bootHd(
      tester,
      const Size(320, 900),
      routes: timesheetRoutes(),
      initial: '/timesheets/billing',
      extraPermissions: _perms,
      handler: _handle,
    );
    expect(find.text('Acme Ltd'), findsOneWidget);
    expect(find.textContaining('5 h'), findsOneWidget);
    await tester.tap(find.text('Bill').first);
    await tester.pumpAndSettle();
    expect((b.last('POST', '/timesheets/bill')!.data as Map)['partyIds'], [
      'p1',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a user without approval rights is locked out of approvals', (
    tester,
  ) async {
    await bootHd(
      tester,
      const Size(390, 900),
      routes: timesheetRoutes(),
      initial: '/timesheets/approvals',
      extraPermissions: {'timesheets.log'},
      handler: _handle,
    );
    expect(find.textContaining('do not have access'), findsOneWidget);
  });
}
