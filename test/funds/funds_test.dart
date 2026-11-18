import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/funds/funds_models.dart';
import 'package:onematrix/features/funds/funds_pdf.dart';

import 'funds_harness.dart';

void main() {
  group('funds home', () {
    for (final size in fundsTestSizes) {
      testWidgets(
        'shows budget bars, funds and sanctions waiting at ${size.width.toInt()}',
        (tester) async {
          final h = await bootFunds(tester, size);
          expect(find.text('Budget used by head'), findsOneWidget);
          expect(
            find.textContaining('2202  General education'),
            findsOneWidget,
          );
          expect(
            find.textContaining('re-appropriation request'),
            findsOneWidget,
          );
          await tester.scrollUntilVisible(
            find.text('State education grant'),
            300,
            scrollable: find.byType(Scrollable).last,
          );
          expect(find.text('State education grant'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.text('Teacher pay for the quarter'),
            300,
            scrollable: find.byType(Scrollable).last,
          );
          expect(find.text('Teacher pay for the quarter'), findsOneWidget);
          h.expectClean('funds home at ${size.width}');
        },
      );
    }

    testWidgets('an auditor sees the home without the New sanction button', (
      tester,
    ) async {
      final h = await bootFunds(
        tester,
        const Size(390, 844),
        permissions: auditorPermissions,
      );
      expect(find.text('Budget used by head'), findsOneWidget);
      expect(find.byKey(const ValueKey('new-sanction')), findsNothing);
      h.expectClean('auditor');
    });
  });

  group('budget and re-appropriation', () {
    testWidgets('lists heads with indentation and saves a re-appropriation', (
      tester,
    ) async {
      final h = await bootFunds(
        tester,
        const Size(390, 844),
        location: '/funds/budget',
      );
      expect(find.byKey(const ValueKey('head-2202.01.01')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('reappropriate')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('from')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('2202.01.01').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('to')));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('2202.01.02').last);
      await tester.pumpAndSettle();
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.at(0), '500');
      await tester.enterText(fields.at(1), 'FD/45');
      await tester.enterText(fields.at(2), 'Savings');
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      final sent = h.backend.body('POST', '/funds/reappropriations');
      expect(sent['fromHeadId'], 'h3');
      expect(sent['toHeadId'], 'h4');
      expect(sent['amount'], 500);
      expect(sent['orderNo'], 'FD/45');
      expect(sent['reason'], 'Savings');
      h.expectClean('reappropriation');
    });

    testWidgets('the form asks for the order number and reason', (
      tester,
    ) async {
      final h = await bootFunds(
        tester,
        const Size(390, 844),
        location: '/funds/budget',
      );
      await tester.tap(find.byKey(const ValueKey('reappropriate')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save').last);
      await tester.pumpAndSettle();
      expect(find.text('Choose a head'), findsWidgets);
      expect(h.backend.count('POST', '/funds/reappropriations'), 0);
    });
  });

  group('other funds screens', () {
    for (final size in const [Size(320, 700), Size(1440, 900)]) {
      testWidgets(
        'sanctions, funds, spending and reports render at ${size.width.toInt()}',
        (tester) async {
          final h = await bootFunds(tester, size, location: '/funds/sanctions');
          expect(find.byKey(const ValueKey('approve-s1')), findsOneWidget);
          await h.go('/funds/funds');
          expect(find.byKey(const ValueKey('grant-f1')), findsOneWidget);
          await h.go('/funds/spending');
          expect(find.text('Not yet linked'), findsOneWidget);
          await h.go('/funds/reports');
          expect(find.text('Budget against actual'), findsOneWidget);
          await tester.scrollUntilVisible(
            find.byKey(const ValueKey('uc-print')),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.byKey(const ValueKey('uc-print')), findsOneWidget);
          h.expectClean('funds screens at ${size.width}');
        },
      );
    }
  });

  group('donation entry', () {
    for (final size in const [Size(390, 844), Size(1440, 900)]) {
      testWidgets(
        'takes a donation at ${size.width.toInt()} and warns on cash over 2,000',
        (tester) async {
          final h = await bootFunds(tester, size, location: '/donations');
          expect(find.text('New donation'), findsOneWidget);
          await tester.ensureVisible(find.byKey(const ValueKey('donor-field')));
          await tester.tap(find.byKey(const ValueKey('donor-field')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Meena Patel').last);
          await tester.pumpAndSettle();
          await tester.enterText(find.byKey(const ValueKey('amount')), '3000');
          await tester.ensureVisible(find.byKey(const ValueKey('mode-cash')));
          await tester.tap(find.byKey(const ValueKey('mode-cash')));
          await tester.pumpAndSettle();
          expect(find.textContaining('Cash above Rs 2,000'), findsOneWidget);
          await tester.ensureVisible(find.byKey(const ValueKey('save-only')));
          await tester.tap(find.byKey(const ValueKey('save-only')));
          await tester.pumpAndSettle();
          final sent = h.backend.body('POST', '/donations');
          expect(sent['donorId'], 'dn1');
          expect(sent['amount'], 3000);
          expect(sent['mode'], 'cash');
          expect(sent['tax80g'], true);
          expect(h.backend.count('POST', '/donations'), 1);
          h.expectClean('donation entry at ${size.width}');
        },
      );
    }

    testWidgets('a volunteer without create rights has no entry card', (
      tester,
    ) async {
      final h = await bootFunds(
        tester,
        const Size(390, 844),
        location: '/donations',
        permissions: auditorPermissions,
      );
      expect(find.text('New donation'), findsNothing);
      expect(find.text('Recent receipts'), findsOneWidget);
      h.expectClean('view only');
    });

    testWidgets('donors, receipts and Form 10BD screens render at 320', (
      tester,
    ) async {
      final h = await bootFunds(
        tester,
        const Size(320, 700),
        location: '/donations/donors',
      );
      expect(find.text('Meena Patel'), findsOneWidget);
      await h.go('/donations/receipts');
      expect(find.textContaining('DON/26-27/00001'), findsOneWidget);
      await h.go('/donations/10bd');
      expect(find.textContaining('Check before filing'), findsOneWidget);
      expect(find.text('ABCDE1234F'), findsOneWidget);
      h.expectClean('donation screens');
    });
  });

  group('pdfs', () {
    test(
      'the donation receipt builds with 80G details and amount in words',
      () async {
        final data = ReceiptData.fromJson(receiptJson());
        expect(data.reg80gNo, startsWith('AAATS1234E'));
        final bytes = await buildReceiptPdf(data);
        expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
        expect(bytes.length, greaterThan(1500));
        expect(receiptFileName(data), 'donation-receipt-DON-26-27-00001.pdf');
      },
    );

    test(
      'a cash receipt over 2,000 builds with the no-deduction note',
      () async {
        final data = ReceiptData.fromJson({
          ...receiptJson(),
          'mode': 'cash',
          'amount': 2500,
          'deductionEligible': false,
        });
        expect(data.donation.deductionEligible, isFalse);
        expect((await buildReceiptPdf(data)).length, greaterThan(1500));
      },
    );

    test('the utilisation certificate builds and its figures add up', () async {
      final uc = UcData.fromJson(ucJson());
      expect(uc.opening + uc.received - uc.spent, uc.closing);
      expect(uc.spentByHead.fold<double>(0, (s, l) => s + l.amount), uc.spent);
      final bytes = await buildUcPdf(uc);
      expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
      expect(bytes.length, greaterThan(2000));
      expect(
        ucFileName(uc),
        startsWith('utilisation-certificate-State-education-grant-'),
      );
    });
  });
}
