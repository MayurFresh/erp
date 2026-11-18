import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/clinic/ipd_models.dart';
import 'package:onematrix/features/clinic/ipd_pdf.dart';
import 'package:onematrix/widgets/layout.dart';

import 'clinic_harness.dart';

const ipdPermissions = {
  'clinic.view',
  'clinic.ipd',
  'clinic.ipd_manage',
  'clinic.consult',
  'invoices.create',
  'payments.create',
};

void main() {
  group('ipd models', () {
    test('IpdBoard keeps stays and lists free beds', () {
      final b = IpdBoard.fromJson(ipdBoardJson);
      expect(b.counts.occupied, 1);
      expect(b.wards.single.beds.first.stay?.patientName, 'Meena Patel');
      expect(b.freeBeds.map((e) => e.$2.bedNo), ['G2']);
      expect(BedStatus.parse('cleaning'), BedStatus.cleaning);
    });

    test('Admission reads totals, charges and the summary', () {
      final a = Admission.fromJson(admissionJson());
      expect(a.admitted, isTrue);
      expect(a.totals.balance, 800);
      expect(a.charges, hasLength(2));
      expect(a.deposits.single.amount, 1000);
      expect(a.notes.treatment, 'IV fluids');
      // Without clinic.consult the summary is absent.
      final hidden = Admission.fromJson(
        {...admissionJson(), 'clinical': false}
          ..remove('summary')
          ..remove('provisionalDiagnosis'),
      );
      expect(hidden.clinical, isFalse);
      expect(hidden.notes.diagnosis, isNull);
    });
  });

  group('discharge summary pdf', () {
    test('builds an A4 PDF', () async {
      final d = DischargeSummaryData.fromJson(dischargeSummaryJson());
      expect(d.medicines.single, startsWith('Inj Ondansetron'));
      final bytes = await buildDischargeSummaryPdf(d);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1500));
      expect(dischargeFileName(d), 'discharge-IPD-26-27-00001.pdf');
    });

    test('builds with no medicines and no notes', () async {
      final json = dischargeSummaryJson()
        ..['medicines'] = <Object?>[]
        ..['summary'] = <String, Object?>{};
      final bytes = await buildDischargeSummaryPdf(
        DischargeSummaryData.fromJson(json),
      );
      expect(bytes, isNotEmpty);
    });
  });

  for (final size in clinicTestSizes) {
    testWidgets('bed board renders at ${size.width.toInt()}px', (tester) async {
      final h = await bootClinic(
        tester,
        size,
        permissions: ipdPermissions,
        location: '/clinic/ipd',
      );
      h.expectClean('board');
      expect(find.text('General ward  (General)'), findsOneWidget);
      expect(find.text('Meena Patel'), findsOneWidget);
      expect(find.text('1 of 3 beds occupied'), findsOneWidget);
      expect(find.text('Cleaning'), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('bed-b1')));
      await tester.pumpAndSettle();
      h.expectClean('stay');
      expect(find.text('Discharge and bill'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('RCT/26-27/00005'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Doctor visit'), findsOneWidget);
      expect(find.text('RCT/26-27/00005'), findsOneWidget);
    });
  }

  testWidgets('a nurse sees the board but no admit or discharge buttons', (
    tester,
  ) async {
    final h = await bootClinic(
      tester,
      clinicTestSizes[1],
      permissions: {'clinic.view', 'clinic.ipd'},
      location: '/clinic/ipd',
    );
    h.expectClean('nurse board');
    expect(find.text('Admit patient'), findsNothing);
    expect(find.text('Wards and beds'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('bed-b1')));
    await tester.pumpAndSettle();
    expect(find.text('Add charge'), findsOneWidget);
    expect(find.text('Discharge and bill'), findsNothing);
    expect(find.text('Take deposit'), findsNothing);
  });

  testWidgets('adding a charge posts the kind, description and rate', (
    tester,
  ) async {
    final h = await bootClinic(
      tester,
      clinicTestSizes[1],
      permissions: ipdPermissions,
      location: '/clinic/ipd/stays/ad1',
    );
    await tester.tap(find.text('Add charge'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Nebulisation');
    await tester.enterText(fields.at(2), '150');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    final body = h.backend.body('POST', '/clinic/ipd/admissions/ad1/charges');
    expect(body['kind'], 'service');
    expect(body['description'], 'Nebulisation');
    expect(body['rate'], 150);
  });

  testWidgets('discharge sends the summary and shows the bill', (tester) async {
    final h = await bootClinic(
      tester,
      clinicTestSizes[2],
      permissions: ipdPermissions,
      location: '/clinic/ipd/stays/ad1',
    );
    await tester.tap(find.text('Discharge and bill'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(BusyButton));
    await tester.pumpAndSettle();
    final body = h.backend.body('POST', '/clinic/ipd/admissions/ad1/discharge');
    expect(body['diagnosis'], 'Gastroenteritis');
    expect(body['treatment'], 'IV fluids');
    expect(find.text('Discharged'), findsWidgets);
    expect(find.textContaining('INV/26-27/00009'), findsOneWidget);
    h.expectClean('discharge');
  });

  testWidgets('a discharged stay offers a refund of the deposit left', (
    tester,
  ) async {
    final h = await bootClinic(
      tester,
      clinicTestSizes[2],
      permissions: ipdPermissions,
      location: '/clinic/ipd',
      setup: (b) => b.dischargedStay = true,
    );
    await h.go('/clinic/ipd/stays/ad1');
    expect(find.text('Refund ₹500.00'), findsOneWidget);
    await tester.tap(find.text('Refund ₹500.00'));
    await tester.pumpAndSettle();
    expect(find.text('Refund due ₹500.00.'), findsOneWidget);
    expect(find.widgetWithText(TextField, '500'), findsOneWidget);
    h.expectClean('refund');
  });
}
