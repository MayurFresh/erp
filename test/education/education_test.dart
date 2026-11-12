import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:progen_erp/core/json.dart';
import 'package:progen_erp/features/education/education_models.dart';
import 'package:progen_erp/features/education/receipt_pdf.dart';
import 'package:progen_erp/widgets/picker_field.dart';

import 'education_harness.dart';

void main() {
  group('models and receipt pdf', () {
    test('Student.fromJson reads concessions and dues', () {
      final s = Student.fromJson(asJson(studentJson));
      expect(s.brief.admissionNo, 'ADM/26-27/00001');
      expect(s.concessions.single.headName, 'Tuition fee');
      expect(s.due, 7000);
      expect(s.overdue, 2000);
    });

    test('a teacher view has no money on the student', () {
      final s = Student.fromJson({...studentJson, 'dues': null});
      expect(s.due, isNull);
    });

    test(
      'builds an A5 receipt PDF with the heads paid and the balance',
      () async {
        final data = ReceiptData.fromJson(receiptJson());
        expect(data.paidFor.single.heads, hasLength(2));
        expect(data.balance, 7000);
        final bytes = await buildFeeReceiptPdf(data);
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(1500));
        expect(receiptFileName(data), 'fee-receipt-RCT-26-27-00001.pdf');
      },
    );

    test('builds a receipt that pays in full with no balance', () async {
      final j = receiptJson()..['balance'] = 0;
      final bytes = await buildFeeReceiptPdf(ReceiptData.fromJson(j));
      expect(bytes, isNotEmpty);
    });
  });

  for (final size in eduTestSizes) {
    testWidgets(
      'home shows attendance by class and money at ${size.width.toInt()}px',
      (tester) async {
        final h = await bootEdu(tester, size);
        expect(find.text('Students and fees'), findsWidgets);
        expect(find.text('Collected today'), findsOneWidget);
        expect(find.text('Defaulters'), findsOneWidget);
        expect(find.text('Collect fee'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('Class 6 A'), 200);
        expect(find.text('Class 6 A'), findsOneWidget);
        expect(find.text('Class 5 A'), findsOneWidget);
        expect(find.text('Not marked'), findsOneWidget);
        expect(find.textContaining('28 in, 2 absent'), findsOneWidget);
        h.expectClean('home at ${size.width}');
      },
    );

    testWidgets(
      'student file shows fees, receipts and attendance at ${size.width.toInt()}px',
      (tester) async {
        final h = await bootEdu(
          tester,
          size,
          location: '/education/students/s1',
        );
        expect(find.text('Diya Patel'), findsOneWidget);
        expect(find.textContaining('Hetal Patel'), findsWidgets);
        expect(find.text('Details'), findsOneWidget);
        expect(find.textContaining('Staff child'), findsOneWidget);
        expect(find.textContaining('Overall 90.5%'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('bill-INV/26-27/00011')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('receipt-RCT/26-27/00001')),
          findsOneWidget,
        );
        h.expectClean('student at ${size.width}');
      },
    );
  }

  testWidgets('a teacher sees no money on the home screen', (tester) async {
    final h = await bootEdu(
      tester,
      const Size(390, 844),
      permissions: {'dashboard.view', ...teacherPermissions},
    );
    expect(find.text('Class 5 A'), findsOneWidget);
    expect(find.text('Collect fee'), findsNothing);
    expect(find.text('Admit student'), findsNothing);
    h.expectClean('teacher home');
  });

  testWidgets(
    'attendance: everyone starts present, a tap marks absent, save posts once',
    (tester) async {
      final h = await bootEdu(
        tester,
        const Size(320, 700),
        location: '/education/attendance/c1',
      );
      expect(find.text('Present 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mark-st1')));
      await tester.pumpAndSettle();
      expect(find.text('Absent'), findsOneWidget);
      expect(find.text('Present 2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('mark-st2')));
      await tester.tap(find.byKey(const ValueKey('mark-st2')));
      await tester.pumpAndSettle();
      expect(find.text('Late'), findsWidgets);
      await tester.tap(find.text('Save attendance'));
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/education/classes/c1/attendance'), 1);
      final body = h.backend.body('POST', '/education/classes/c1/attendance');
      final marks = {
        for (final m in body['marks'] as List) m['studentId']: m['status'],
      };
      expect(marks, {'st0': 'present', 'st1': 'absent', 'st2': 'late'});
      expect(find.text('Attendance saved'), findsOneWidget);
      h.expectClean('attendance');
    },
  );

  testWidgets('collect fee: find a student, see dues, receive a part payment', (
    tester,
  ) async {
    final h = await bootEdu(
      tester,
      const Size(390, 844),
      location: '/education/collect',
    );
    expect(find.textContaining('Search for a student'), findsOneWidget);
    await tester.tap(find.byType(PickerField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diya Patel').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('due-INV/26-27/00011')), findsOneWidget);
    expect(find.byKey(const ValueKey('due-INV/26-27/00012')), findsOneWidget);
    expect(find.textContaining('Total due'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount received'),
      '3000',
    );
    await tester.ensureVisible(find.text('Receive payment'));
    await tester.tap(find.text('Receive payment'));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/education/students/s1/collect'), 1);
    final body = h.backend.body('POST', '/education/students/s1/collect');
    expect(body['amount'], 3000);
    expect(body['mode'], 'cash');
    expect(body['accountId'], isNotNull);
    expect(find.text('Fee received'), findsOneWidget);
    expect(find.textContaining('Balance due'), findsOneWidget);
    expect(find.text('Print receipt'), findsOneWidget);
    h.expectClean('collect');
  });

  testWidgets('collect fee refuses more than is due', (tester) async {
    final h = await bootEdu(
      tester,
      const Size(390, 844),
      location: '/education/collect?studentId=s1',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount received'),
      '9000',
    );
    await tester.ensureVisible(find.text('Receive payment'));
    await tester.tap(find.text('Receive payment'));
    await tester.pumpAndSettle();
    expect(find.text('More than is due'), findsOneWidget);
    expect(h.backend.count('POST', '/education/students/s1/collect'), 0);
  });

  testWidgets('generate fee bills: preview first, then post', (tester) async {
    final h = await bootEdu(
      tester,
      const Size(1440, 900),
      location: '/education/demands',
    );
    await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Class 5 A').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Term 1').last);
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/education/demands/generate'), 0);
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('28 bills to post'), findsOneWidget);
    expect(find.textContaining('2 students already billed'), findsOneWidget);
    expect(
      h.backend.body('POST', '/education/demands/generate')['preview'],
      true,
    );
    await tester.tap(find.text('Post 28 bills'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Post bills'));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/education/demands/generate'), 2);
    expect(find.textContaining('28 bills posted'), findsOneWidget);
    h.expectClean('demands');
  });

  testWidgets('dues list shows days overdue and a reminder to copy', (
    tester,
  ) async {
    final h = await bootEdu(
      tester,
      const Size(390, 844),
      location: '/education/dues',
    );
    expect(find.text('Diya Patel'), findsOneWidget);
    expect(find.text('31 days overdue'), findsOneWidget);
    expect(find.text('Copy reminder'), findsOneWidget);
    h.expectClean('dues');
  });

  testWidgets('setup lists classes, fee heads and plans at 320px', (
    tester,
  ) async {
    final h = await bootEdu(
      tester,
      const Size(320, 700),
      location: '/education/setup',
    );
    expect(find.text('Class 5 A'), findsOneWidget);
    await tester.ensureVisible(find.text('Fee plans'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fee plans'));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 instalments, '), findsOneWidget);
    await tester.ensureVisible(find.text('Fee heads'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fee heads'));
    await tester.pumpAndSettle();
    expect(find.text('Tuition fee'), findsOneWidget);
    h.expectClean('setup');
  });

  testWidgets('people without the fees permission are turned away from dues', (
    tester,
  ) async {
    await bootEdu(
      tester,
      const Size(390, 844),
      permissions: {'dashboard.view', ...teacherPermissions},
      location: '/education/dues',
    );
    expect(find.text('Diya Patel'), findsNothing);
  });
}
