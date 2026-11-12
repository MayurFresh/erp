import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/hotel/hotel_models.dart';
import 'package:progen_erp/features/hotel/hotel_pdf.dart';
import 'package:progen_erp/features/hotel/housekeeping_screen.dart';

import 'hotel_harness.dart';

/// What the shell needs besides the hotel permissions.
const baseDash = {'dashboard.view', 'payments.view'};

void main() {
  group('models and pdf', () {
    test('Folio.fromJson reads lines, payments and totals', () {
      final f = Folio.fromJson(folioJson());
      expect(f.lines, hasLength(2));
      expect(f.lines.first.canVoid, isFalse);
      expect(f.lines.last.canVoid, isTrue);
      expect(f.totals.balance, 1861);
      expect(f.payments.single.kind, 'advance');
      expect(f.reservation.inHouse, isTrue);
    });

    test('housekeeping steps go dirty, clean, inspected, dirty', () {
      expect(nextStep('dirty')!.status, 'clean');
      expect(nextStep('clean')!.status, 'inspected');
      expect(nextStep('inspected')!.status, 'dirty');
      expect(nextStep('out_of_order')!.status, 'dirty');
    });

    test('guest bill and registration card build', () async {
      final f = Folio.fromJson(folioJson());
      final bill = await buildGuestBillPdf(f);
      expect(String.fromCharCodes(bill.take(5)), '%PDF-');
      final card = await buildRegistrationCardPdf(f.reservation);
      expect(String.fromCharCodes(card.take(5)), '%PDF-');
      expect(billFileName(f), startsWith('guest-bill-RSV-'));
    });
  });

  for (final size in hotelTestSizes) {
    final w = size.width.toInt();

    testWidgets('front office home renders at ${w}px', (tester) async {
      final h = await bootHotel(tester, size);
      expect(find.text('Meena Patel'), findsOneWidget);
      expect(find.text('Kiran Desai'), findsWidgets);
      expect(find.text('Suresh Joshi'), findsOneWidget);
      expect(find.textContaining('3 of 9'), findsOneWidget);
      expect(find.text('Check in'), findsOneWidget);
      h.expectClean('home $w');
    });

    testWidgets('room board renders at ${w}px and opens a stay', (tester) async {
      final h = await bootHotel(tester, size, location: '/hotel/board');
      expect(find.text('101'), findsOneWidget);
      expect(find.text('102'), findsOneWidget);
      expect(find.text('Ravi Shah'), findsWidgets);
      h.expectClean('board $w');
      await tester.tap(find.text('Ravi Shah').first);
      await tester.pumpAndSettle();
      expect(find.text('Check out'), findsWidgets);
      h.expectClean('board to folio $w');
    });

    testWidgets('housekeeping renders at ${w}px', (tester) async {
      final h = await bootHotel(
        tester,
        size,
        location: '/hotel/housekeeping',
        permissions: {...housekeepingPermissions, ...baseDash},
      );
      expect(find.text('Room 102'), findsOneWidget);
      expect(find.text('Mark clean'), findsOneWidget);
      h.expectClean('housekeeping $w');
    });

    testWidgets('folio renders at ${w}px', (tester) async {
      final h = await bootHotel(tester, size, location: '/hotel/reservations/r1');
      expect(find.text('Ravi Shah'), findsWidgets);
      expect(find.textContaining('Laundry', skipOffstage: false), findsWidgets);
      expect(find.text('Check out'), findsWidgets);
      h.expectClean('folio $w');
    });

    testWidgets('reservation form renders at ${w}px', (tester) async {
      final h = await bootHotel(tester, size, location: '/hotel/reservations/new');
      expect(find.text('New reservation'), findsWidgets);
      expect(find.text('Save reservation'), findsOneWidget);
      h.expectClean('form $w');
    });
  }

  testWidgets('reservation form saves a booking for a new guest', (tester) async {
    final h = await bootHotel(tester, hotelTestSizes[1], location: '/hotel/reservations/new');
    await tester.enterText(find.widgetWithText(TextField, 'Guest name'), 'Ravi Shah');
    await tester.enterText(find.widgetWithText(TextField, 'Phone'), '9825012345');
    await tester.tap(find.text('Room type'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Deluxe').last);
    await tester.pumpAndSettle();
    expect(find.text('2 free'), findsOneWidget);
    await tester.ensureVisible(find.text('Save reservation'));
    await tester.tap(find.text('Save reservation'));
    await tester.pumpAndSettle();
    final b = h.backend.body('POST', '/hotel/reservations');
    expect((b['guest'] as Map)['name'], 'Ravi Shah');
    expect(((b['rooms'] as List).single as Map)['roomTypeId'], 't1');
    expect(h.backend.count('POST', '/hotel/reservations'), 1);
    h.expectClean('form save');
  });

  testWidgets('reservation form asks for a guest before saving', (tester) async {
    final h = await bootHotel(tester, hotelTestSizes[1], location: '/hotel/reservations/new');
    await tester.ensureVisible(find.text('Save reservation'));
    await tester.tap(find.text('Save reservation'));
    await tester.pumpAndSettle();
    expect(find.text('Enter the guest name and a phone number.'), findsOneWidget);
    expect(h.backend.count('POST', '/hotel/reservations'), 0);
  });

  testWidgets('check-out takes the balance and posts once', (tester) async {
    final h = await bootHotel(tester, hotelTestSizes[1], location: '/hotel/reservations/r1');
    await tester.tap(find.widgetWithText(FilledButton, 'Check out'));
    await tester.pumpAndSettle();
    expect(find.text('Take payment and check out'), findsOneWidget);
    // No account chosen yet.
    await tester.tap(find.text('Take payment and check out'));
    await tester.pumpAndSettle();
    expect(find.text('Choose the account the money goes to.'), findsOneWidget);
    await tester.tap(find.text('Deposit to'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownMenuItem<String>).last, warnIfMissed: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Take payment and check out'));
    await tester.pumpAndSettle();
    expect(h.backend.count('POST', '/hotel/reservations/r1/check-out'), 1);
    final b = h.backend.body('POST', '/hotel/reservations/r1/check-out');
    expect((b['payment'] as Map)['amount'], 1861);
    h.expectClean('check-out');
  });

  testWidgets('housekeeping one tap moves a dirty room to clean', (tester) async {
    final h = await bootHotel(
      tester,
      hotelTestSizes[1],
      location: '/hotel/housekeeping',
      permissions: {...housekeepingPermissions, ...baseDash},
    );
    await tester.tap(find.text('Mark clean'));
    await tester.pumpAndSettle();
    expect(h.backend.count('PATCH', '/hotel/rooms/ro2/status'), 1);
    expect(h.backend.body('PATCH', '/hotel/rooms/ro2/status')['status'], 'clean');
    h.expectClean('housekeeping tap');
  });

  testWidgets('housekeeping without the permission shows no change buttons', (tester) async {
    await bootHotel(
      tester,
      hotelTestSizes[1],
      location: '/hotel/housekeeping',
      permissions: {'hotel.view', ...baseDash},
    );
    expect(find.text('Room 102'), findsOneWidget);
    expect(find.text('Mark clean'), findsNothing);
  });
}
