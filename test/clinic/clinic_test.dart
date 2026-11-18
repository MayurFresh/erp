import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/clinic/clinic_models.dart';
import 'package:onematrix/widgets/picker_field.dart';
import 'package:onematrix/features/clinic/rx_pdf.dart';

import 'clinic_harness.dart';

void main() {
  group('models', () {
    test('Visit.fromJson keeps the header when notes are hidden', () {
      final v = Visit.fromJson(
        {...visitJson, 'clinical': false}..removeWhere(
          (k, _) => {
            'diagnosis',
            'complaints',
            'rx',
            'vitals',
            'allergies',
          }.contains(k),
        ),
      );
      expect(v.clinical, isFalse);
      expect(v.rx, isEmpty);
      expect(v.diagnosis, isNull);
      expect(v.billed, isFalse);
    });

    test('Appointment.fromJson and statuses', () {
      final a = Appointment.fromJson(
        apptJson('a1', 'Ravi', 'in_consultation', token: 3),
      );
      expect(a.status, ApptStatus.inConsultation);
      expect(a.when, 'Token 3');
      expect(ApptStatus.parse('no_show'), ApptStatus.noShow);
      expect(ApptStatus.done.isOpen, isFalse);
    });
  });

  group('prescription pdf', () {
    test('builds an A5 PDF with the doctor, patient and Rx lines', () async {
      final data = PrescriptionData.fromJson(prescriptionJson());
      expect(data.rx, hasLength(2));
      expect(vitalsLine(data.vitals), contains('BP 130/85'));
      final bytes = await buildPrescriptionPdf(data);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(1500));
      expect(rxFileName(data), startsWith('prescription-UHID-26-27-00001-'));
    });

    test('builds with no medicines and no notes', () async {
      final json = prescriptionJson()..['rx'] = <Object?>[];
      final bytes = await buildPrescriptionPdf(PrescriptionData.fromJson(json));
      expect(bytes, isNotEmpty);
    });
  });

  for (final size in clinicTestSizes) {
    testWidgets('front desk queue renders at ${size.width.toInt()}px', (
      tester,
    ) async {
      final h = await bootClinic(tester, size);
      expect(
        find.textContaining('Dr Anil Mehta', findRichText: true),
        findsWidgets,
      );
      expect(find.text('Ravi Shah'), findsOneWidget);
      expect(find.text('With doctor'), findsOneWidget);
      expect(find.text('Waiting'), findsOneWidget);
      if (size.width > 400) {
        expect(find.text('Booked'), findsOneWidget);
        expect(find.text('Done'), findsOneWidget);
      }
      expect(find.text('Book appointment'), findsOneWidget);
      expect(find.text('Register patient'), findsOneWidget);
      expect(find.text('Walk-in token'), findsOneWidget);
      h.expectClean('front desk at ${size.width}');
    });
  }

  testWidgets('front desk books an appointment for a chosen patient and slot', (
    tester,
  ) async {
    final h = await bootClinic(tester, const Size(1440, 900));
    await tester.tap(find.text('Book appointment'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PickerField).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ravi Shah').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String?>).last);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Dr Anil Mehta').last);
    await tester.pumpAndSettle();
    expect(find.text('09:30'), findsOneWidget);
    // A taken slot cannot be chosen.
    await tester.tap(find.text('09:15').last, warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('09:30'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Book').last);
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/clinic/appointments'), 1);
    final body = h.backend.body('POST', '/clinic/appointments');
    expect(body['patientId'], 'pt1');
    expect(body['doctorId'], 'd1');
    expect(body['startTime'], '09:30');
    h.expectClean('book');
  });

  testWidgets('front desk without consult sees no clinical notes', (
    tester,
  ) async {
    final h = await bootClinic(
      tester,
      const Size(390, 844),
      permissions: {'dashboard.view', ...frontDeskPermissions},
      location: '/clinic/visits/v1',
      visit: {
        for (final e in visitJson.entries)
          if (!{
            'diagnosis',
            'complaints',
            'rx',
            'vitals',
            'allergies',
          }.contains(e.key))
            e.key: e.value,
        'clinical': false,
      },
    );
    expect(
      find.text('Clinical notes are only shown to clinical staff.'),
      findsOneWidget,
    );
    expect(find.text('Bill the visit'), findsOneWidget);
    expect(find.text('Fever for two days'), findsNothing);
    h.expectClean('front desk visit');
  });

  testWidgets('doctor opens the consultation form and saves', (tester) async {
    final h = await bootClinic(
      tester,
      const Size(390, 844),
      location: '/clinic/visits/v1',
    );
    expect(find.text('Ravi Shah'), findsOneWidget);
    expect(find.textContaining('Penicillin'), findsOneWidget);
    expect(find.text('Vitals'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(TextFormField, 'Diagnosis'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Diagnosis'),
      'Viral fever',
    );
    await tester.ensureVisible(find.text('Add line'));
    await tester.tap(find.text('Add line'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.widgetWithText(TextFormField, 'Medicine 2'),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Medicine 2'),
      'ORS sachets',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(h.backend.count('PATCH', '/clinic/visits/v1'), 1);
    final body = h.backend.body('PATCH', '/clinic/visits/v1');
    expect(body['diagnosis'], 'Viral fever');
    expect((body['rx'] as List), hasLength(2));
    expect((body['rx'] as List).last['medicine'], 'ORS sachets');
    expect(body['expectedUpdatedAt'], '2026-11-12T09:00:00.000Z');
    expect(find.text('Consultation saved'), findsOneWidget);
    h.expectClean('save');
  });

  testWidgets('consultation form asks before leaving with unsaved changes', (
    tester,
  ) async {
    final h = await bootClinic(
      tester,
      const Size(1440, 900),
      location: '/clinic/visits/v1',
    );
    await tester.ensureVisible(find.widgetWithText(TextFormField, 'Advice'));
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Advice'),
      'Rest',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.text('Advice'), findsWidgets);
    expect(h.backend.count('PATCH', '/clinic/visits/v1'), 0);
  });

  testWidgets('patient file shows visits and bills', (tester) async {
    final h = await bootClinic(
      tester,
      const Size(390, 844),
      location: '/clinic/patients/pt1',
    );
    expect(find.text('Ravi Shah'), findsOneWidget);
    expect(find.text('INV/26-27/00007'), findsOneWidget);
    expect(find.textContaining('Due'), findsOneWidget);
    expect(find.textContaining('Viral fever'), findsOneWidget);
    h.expectClean('patient file');
  });

  testWidgets('doctors setup lists the doctor with fees', (tester) async {
    final h = await bootClinic(
      tester,
      const Size(320, 700),
      location: '/clinic/doctors',
    );
    expect(find.text('Dr Anil Mehta'), findsOneWidget);
    expect(find.textContaining('15 min slots'), findsOneWidget);
    h.expectClean('doctors');
  });
}
