import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'hr_harness.dart';

const _sizes = [Size(390, 844), Size(1440, 900)];

void main() {
  for (final size in _sizes) {
    final w = size.width.toInt();
    group('at $w px', () {
      testWidgets('overview shows head count, run and leave', (tester) async {
        final h = await bootHr(tester, size);
        expect(find.text('Employees'), findsWidgets);
        expect(find.text('12'), findsOneWidget);
        expect(find.textContaining('Payroll November 2026'), findsOneWidget);
        expect(find.text('Ravi Nair'), findsOneWidget);
        h.expectClean('overview');
      });

      testWidgets('employee list and file', (tester) async {
        final h = await bootHr(tester, size, initial: '/hr/employees');
        expect(find.textContaining('Asha Verma'), findsOneWidget);
        await tester.tap(find.textContaining('Asha Verma'));
        await tester.pumpAndSettle();
        expect(h.router.state.uri.path, '/hr/employees/e1');
        expect(find.text('XXXX XXXX 1234'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('Casual leave'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.textContaining('10 left of 12'), findsOneWidget);
        h.expectClean('employee file');
      });

      testWidgets('leave: approve posts once', (tester) async {
        final h = await bootHr(tester, size, initial: '/leave');
        expect(find.text('Family function'), findsOneWidget);
        await tester.tap(find.text('Approve'));
        await tester.pumpAndSettle();
        expect(h.backend.count('POST', '/leave-applications/la1/approve'), 1);
        h.expectClean('leave');
      });

      testWidgets(
        'attendance register: tap a day, save sends only the change',
        (tester) async {
          final h = await bootHr(tester, size, initial: '/hr/attendance');
          expect(find.textContaining('Asha Verma'), findsOneWidget);
          // Day 3 is unmarked; one tap marks it present.
          await tester.tap(find.byKey(const ValueKey('att-e1-3')));
          await tester.pump();
          await tester.tap(find.text('Save'));
          await tester.pumpAndSettle();
          expect(h.backend.count('PATCH', '/attendance-days'), 1);
          final body = h.backend.last('PATCH', '/attendance-days').data as Map;
          expect(body['month'], '2026-11');
          expect((body['rows'] as List).single['days'], [
            {'day': '2026-11-03', 'status': 'present'},
          ]);
          h.expectClean('attendance');
        },
      );

      testWidgets('payroll run: lines, approve', (tester) async {
        final h = await bootHr(tester, size, initial: '/payroll/r1');
        expect(find.textContaining('Payroll November 2026'), findsOneWidget);
        expect(
          find.text('Asha Verma (E0001)'),
          size.width < 720 ? findsOneWidget : findsNothing,
        );
        expect(find.textContaining('34,800'), findsWidgets);
        await tester.tap(find.text('Approve'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Yes, approve'));
        await tester.pumpAndSettle();
        expect(h.backend.count('POST', '/payroll/runs/r1/approve'), 1);
        h.expectClean('run');
      });

      testWidgets('payslip and my pay', (tester) async {
        final h = await bootHr(tester, size, initial: '/my-pay');
        expect(find.textContaining('October 2026'), findsOneWidget);
        await tester.tap(find.textContaining('October 2026'));
        await tester.pumpAndSettle();
        expect(h.router.state.uri.path, '/payslip/ps1');
        expect(find.text('Provident fund'), findsOneWidget);
        expect(find.text('Print or save PDF'), findsOneWidget);
        h.expectClean('payslip');
      });

      testWidgets('setup lists components, leave types and holidays', (
        tester,
      ) async {
        final h = await bootHr(tester, size, initial: '/hr/setup');
        expect(find.text('HRA (earning)'), findsOneWidget);
        expect(find.text('Casual leave'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.textContaining('Diwali'),
          300,
          scrollable: find.byType(Scrollable).first,
        );
        h.expectClean('setup');
      });
    });
  }

  testWidgets('add employee posts the typed name', (tester) async {
    final h = await bootHr(
      tester,
      const Size(390, 844),
      initial: '/hr/employees',
    );
    await tester.tap(find.text('Add employee'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name *'),
      'Meera Joshi',
    );
    await tester.tap(find.widgetWithText(TextFormField, 'Joining date *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save'));
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/employees'), 1);
    expect(h.backend.last('POST', '/employees').data['name'], 'Meera Joshi');
    h.expectClean('employee added');
  });

  testWidgets('leave adjustment posts days and reason', (tester) async {
    final h = await bootHr(
      tester,
      const Size(390, 844),
      initial: '/hr/employees/e1',
    );
    await tester.scrollUntilVisible(
      find.text('Adjust'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Adjust'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Leave type *'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Casual leave').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Days (+ or -) *'),
      '-1.5',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Reason *'),
      'Unrecorded absence',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final b =
        h.backend.last('POST', '/employees/e1/leave-adjustments').data as Map;
    expect(b['days'], -1.5);
    expect(b['reason'], 'Unrecorded absence');
    expect(b['leaveTypeId'], 'lt1');
    h.expectClean('adjust');
  });

  testWidgets('self service user sees no payroll screens', (tester) async {
    final h = await bootHr(
      tester,
      const Size(390, 844),
      initial: '/payroll',
      permissions: {'payroll.self'},
    );
    expect(find.textContaining('do not have access'), findsOneWidget);
    h.expectClean('gate');
  });
}
