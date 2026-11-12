import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/company/company_model.dart';
import 'package:progen_erp/features/legal/legal_models.dart';
import 'package:progen_erp/features/legal/matter_pdf.dart';

import 'legal_harness.dart';

void main() {
  group('models and pdf', () {
    test('Matter.fromJson reads the file with its summary', () {
      final m = Matter.fromJson(matterDetail());
      expect(m.caseRef, 'CS 412/2026');
      expect(m.hearings, hasLength(2));
      expect(m.hearings.last.held, isTrue);
      expect(m.unbilled!.total, 8700);
      expect(m.advanceReceived, 20000);
      expect(durationLabel(150), '2h 30m');
      expect(durationLabel(45), '45m');
    });

    test('status PDF builds, with and without a next hearing', () async {
      const co = Company(id: 'c', name: 'Shah and Associates', stateCode: '24');
      final bytes = await buildMatterStatusPdf(Matter.fromJson(matterDetail()), co);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      final bare = matterDetail()..['hearings'] = <Object?>[];
      final b2 = await buildMatterStatusPdf(Matter.fromJson(bare), co);
      expect(b2, isNotEmpty);
      expect(matterPdfName(Matter.fromJson(bare)), 'matter-status-MAT-26-27-00001.pdf');
    });
  });

  for (final size in legalTestSizes) {
    final w = size.width.toInt();

    testWidgets('legal home renders at ${w}px', (tester) async {
      final h = await bootLegal(tester, size);
      expect(find.text('Court diary'), findsWidgets);
      expect(find.text('Patel v. Patel (partition)'), findsWidgets);
      expect(find.text('Mehta Traders v. Shree Steel Ltd'), findsWidgets);
      expect(find.textContaining('Today,'), findsOneWidget);
      expect(find.textContaining('Tomorrow,'), findsOneWidget);
      expect(find.text('File written statement'), findsOneWidget);
      expect(find.textContaining('Overdue since'), findsOneWidget);
      expect(find.text('Shree Ganesh Society v. Registrar'), findsOneWidget);
      expect(find.text('Outcome not recorded'), findsOneWidget);
      h.expectClean('home at $w');
    });

    testWidgets('matter file renders at ${w}px and switches tabs', (tester) async {
      final h = await bootLegal(tester, size, location: '/legal/matters/m1');
      expect(find.text('Mehta Traders v. Shree Steel Ltd'), findsWidgets);
      expect(find.text('Overview'), findsOneWidget);
      expect(find.textContaining('CS 412/2026'), findsOneWidget);
      expect(find.text('Add hearing'), findsOneWidget);
      expect(find.text('Create bill'), findsOneWidget);
      Future<void> tab(String name) async {
        final f = find.byKey(ValueKey('tab-$name'));
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pumpAndSettle();
      }

      await tab('hearings');
      expect(find.text('Plaintiff witness examined in chief.'), findsOneWidget);
      expect(find.text('Record outcome'), findsOneWidget);
      await tab('tasks');
      expect(find.text('Limitation for appeal'), findsOneWidget);
      await tab('entries');
      expect(find.text('Drafting affidavit of evidence'), findsOneWidget);
      await tab('bills');
      expect(find.textContaining('INV/26-27/00012'), findsOneWidget);
      h.expectClean('matter at $w');
    });
  }

  testWidgets('matter list shows matters and opens one', (tester) async {
    final h = await bootLegal(tester, const Size(390, 844), location: '/legal/matters');
    expect(find.text('Patel v. Patel (partition)'), findsOneWidget);
    await tester.tap(find.text('Mehta Traders v. Shree Steel Ltd'));
    await tester.pumpAndSettle();
    expect(find.text('Overview'), findsOneWidget);
    h.expectClean('list');
  });

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('hearing outcome without a next date warns and saves at ${size.width.toInt()}px', (tester) async {
      final h = await bootLegal(tester, size);
      await tester.tap(find.byKey(const ValueKey('hearing-h1')).first.evaluate().isEmpty
          ? find.text('Outcome').last
          : find.descendant(of: find.byKey(const ValueKey('hearing-h1')), matching: find.text('Outcome')));
      await tester.pumpAndSettle();
      expect(find.text('Record hearing outcome'), findsOneWidget);
      expect(find.textContaining('No next date.'), findsOneWidget);
      await tester.tap(find.text('Save outcome'));
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/legal/hearings/h1/outcome'), 0, reason: 'outcome text is required');
      await tester.enterText(find.byType(TextFormField).first, 'Adjourned for arguments');
      await tester.tap(find.text('Save outcome'));
      await tester.pumpAndSettle();
      final body = h.backend.body('POST', '/legal/hearings/h1/outcome');
      expect(body['outcome'], 'Adjourned for arguments');
      expect(body['nextDate'], isNull);
      expect(find.textContaining('No next date is set'), findsOneWidget);
      h.expectClean('outcome');
    });
  }

  testWidgets('hearing outcome with a next date sends it', (tester) async {
    final h = await bootLegal(tester, const Size(1440, 900));
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('hearing-h-today')), matching: find.text('Outcome')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'Evidence closed');
    await tester.tap(find.text('Next date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No next date.'), findsNothing);
    await tester.tap(find.text('Save outcome'));
    await tester.pumpAndSettle();
    final body = h.backend.body('POST', '/legal/hearings/h-today/outcome');
    expect(body['nextDate'], isA<String>());
    expect(find.text('Record hearing outcome'), findsNothing);
    h.expectClean('outcome with date');
  });

  for (final size in [const Size(320, 700), const Size(1440, 900)]) {
    testWidgets('time entry saves at ${size.width.toInt()}px', (tester) async {
      final h = await bootLegal(tester, size, location: '/legal/matters/m1');
      await tester.tap(find.text('Time or expense'));
      await tester.pumpAndSettle();
      expect(find.text('Start timer'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/legal/matters/m1/entries'), 0, reason: 'description and minutes are required');
      await tester.enterText(find.widgetWithText(TextFormField, 'Description'), 'Client conference');
      await tester.enterText(find.widgetWithText(TextFormField, 'Minutes'), '45');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      final body = h.backend.body('POST', '/legal/matters/m1/entries');
      expect(body['kind'], 'time');
      expect(body['minutes'], 45);
      expect(body['description'], 'Client conference');
      expect(body['billable'], true);
      expect(body.containsKey('rate'), isFalse);
      expect(find.text('Add time or expense'), findsNothing);
      h.expectClean('entry');
    });
  }

  testWidgets('bill dialog lists unbilled items and creates the bill', (tester) async {
    final h = await bootLegal(tester, const Size(390, 844), location: '/legal/matters/m1');
    await tester.tap(find.text('Create bill'));
    await tester.pumpAndSettle();
    expect(find.text('Drafting affidavit of evidence'), findsOneWidget);
    expect(find.text('Court fee for exhibits'), findsOneWidget);
    expect(find.textContaining('Selected'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bill-e2')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create bill').last);
    await tester.pumpAndSettle();
    final body = h.backend.body('POST', '/legal/matters/m1/bill');
    expect(body['entryIds'], ['e1']);
    expect(find.textContaining('INV/26-27/00013'), findsOneWidget);
    h.expectClean('bill');
  });

  testWidgets('a viewer sees the diary without edit actions', (tester) async {
    final h = await bootLegal(
      tester,
      const Size(390, 844),
      permissions: {'dashboard.view', ...legalViewPermissions},
    );
    expect(find.text('Court diary'), findsWidgets);
    expect(find.text('Outcome'), findsNothing);
    expect(find.text('New matter'), findsNothing);
    await h.go('/legal/matters/m1');
    expect(find.text('Add hearing'), findsNothing);
    expect(find.text('Create bill'), findsNothing);
    expect(find.text('Status PDF'), findsOneWidget);
    h.expectClean('viewer');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('without legal access the screen is locked', (tester) async {
    await bootLegal(tester, const Size(390, 844), permissions: {'dashboard.view'});
    expect(find.textContaining('do not have access'), findsOneWidget);
  });
}
