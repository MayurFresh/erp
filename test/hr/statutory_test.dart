import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/company/company_model.dart';
import 'package:progen_erp/features/hr/fnf_pdf.dart';

import 'statutory_harness.dart';

const _sizes = [Size(390, 844), Size(1440, 900)];

void main() {
  test('settlement lines split payments from deductions', () {
    final d = {
      'result': {
        'pendingSalaryPaid': false,
        'oneTimeLines': [
          {'kind': 'earning', 'label': 'Gratuity', 'amount': 1000},
          {'kind': 'deduction', 'label': 'Notice', 'amount': 200},
        ],
        'line': {
          'earnings': [
            {'name': 'Basic', 'amount': 500},
          ],
          'pfEmployee': 60,
          'tds': 0,
        },
      },
    };
    final l = fnfLines(d);
    expect(l.earnings.map((e) => e.$1), ['Pending salary: Basic', 'Gratuity']);
    expect(l.deductions.map((e) => e.$1), ['Notice', 'Provident fund']);
    final paid = fnfLines({
      'result': {'pendingSalaryPaid': true, 'oneTimeLines': [], 'line': {'earnings': [{'name': 'Basic', 'amount': 500}]}},
    });
    expect(paid.earnings, isEmpty);
  });

  test('the settlement PDF builds', () async {
    final bytes = await buildFnfPdf(
      {'number': 'FNF/1', 'exitDate': '2026-11-10', 'gross': 1000, 'deductions': 60, 'net': 940, 'result': {'employee': {'name': 'A', 'code': 'E1'}, 'oneTimeLines': [], 'line': {'earnings': [{'name': 'Basic', 'amount': 1000}], 'pfEmployee': 60}}},
      const Company(id: 'c', name: 'Demo', stateCode: '27'),
    );
    expect(bytes.length, greaterThan(500));
  });

  for (final size in _sizes) {
    final w = size.width.toInt();
    group('at $w px', () {
      testWidgets('settings show the ceiling in force and the rows added', (tester) async {
        final h = await bootStat(tester, size, '/hr/statutory');
        expect(find.text('Statutory settings'), findsWidgets);
        expect(find.text('Off'), findsOneWidget);
        expect(find.textContaining('25,000'), findsWidgets);
        expect(find.textContaining('from 2027-04-01'), findsOneWidget);
        await tester.tap(find.byTooltip('Remove'));
        await tester.pumpAndSettle();
        expect(h.backend.count('DELETE', '/payroll/statutory/rates/rr1'), 1);
        h.expectClean('settings');
      });

      testWidgets('gratuity report shows accrued and payable', (tester) async {
        final h = await bootStat(tester, size, '/hr/gratuity');
        expect(find.textContaining('Asha Verma'), findsOneWidget);
        expect(find.textContaining('9 counted'), findsOneWidget);
        expect(find.textContaining('1,55,769'), findsWidgets);
        h.expectClean('gratuity');
      });

      testWidgets('bonus: only eligible staff get an amount, posting happens once', (tester) async {
        final h = await bootStat(tester, size, '/hr/bonus');
        expect(find.text('Wage is above the eligibility ceiling'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Add bonus to the run'), 300, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        await tester.tap(find.textContaining('PAY/2611/001').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add bonus to the run'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add').last);
        await tester.pumpAndSettle();
        expect(h.backend.count('POST', '/payroll/bonus/run'), 1);
        expect(h.backend.last('POST', '/payroll/bonus/run').data, {'fy': h.backend.last('POST', '/payroll/bonus/run').data['fy'], 'runId': 'r1'});
        h.expectClean('bonus');
      });

      testWidgets('encashment lists types and the yearly amount', (tester) async {
        final h = await bootStat(tester, size, '/hr/encashment');
        expect(find.text('Up to 5 days'), findsOneWidget);
        expect(find.text('Not encashable'), findsOneWidget);
        expect(find.textContaining('Earned leave, 5 of 12 days'), findsOneWidget);
        h.expectClean('encashment');
      });

      testWidgets('shifts and overtime', (tester) async {
        final h = await bootStat(tester, size, '/hr/shifts');
        expect(find.textContaining('09:00 to 18:00'), findsOneWidget);
        expect(find.textContaining('2 hours'), findsOneWidget);
        h.expectClean('shifts');
      });

      testWidgets('settlement: list, detail and approve once', (tester) async {
        final h = await bootStat(tester, size, '/hr/fnf');
        expect(find.textContaining('FNF/26-27/00001'), findsOneWidget);
        await tester.tap(find.textContaining('Asha Verma'));
        await tester.pumpAndSettle();
        expect(h.router.state.uri.path, '/hr/fnf/f1');
        expect(find.text('Pending salary: Basic'), findsOneWidget);
        expect(find.text('Notice period shortfall recovery'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Approve and mark as left'), 300, scrollable: find.byType(Scrollable).first);
        await tester.tap(find.text('Approve and mark as left'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Approve').last);
        await tester.pumpAndSettle();
        expect(h.backend.count('POST', '/payroll/fnf/f1/approve'), 1);
        expect(find.text('Mark as paid'), findsOneWidget);
        h.expectClean('settlement');
      });
    });
  }
}
