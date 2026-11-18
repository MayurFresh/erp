import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/business_profile.dart';
import 'package:onematrix/core/money.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

FakeBackend _backend(Map<String, Object?> company) {
  final fake = FakeBackend();
  final me = FakeBackend.me(FakeBackend.allPermissions);
  final companies = me['companies']! as List;
  companies[0] = {...(companies[0]! as Map<String, Object?>), ...company};
  fake.overrides['GET /me'] = (200, me);
  return fake;
}

void main() {
  tearDown(configureMoney);

  group('applyTerms', () {
    const hospital = BusinessProfile(
      terms: {'customer': 'Patient', 'invoice': 'Bill', 'item': 'Medicine'},
    );

    test('swaps the default words, plural and lower case', () {
      expect(
        applyTerms('Customers and vendors', hospital),
        'Patients and vendors',
      );
      expect(applyTerms('New invoice', hospital), 'New bill');
      expect(applyTerms('Choose a customer', hospital), 'Choose a patient');
      expect(applyTerms('Items', hospital), 'Medicines');
      expect(applyTerms('No parties found.', hospital), 'No patients found.');
    });

    test('a sale called a bill stays apart from a purchase bill', () {
      const restaurant = BusinessProfile(
        terms: {'invoice': 'Bill', 'bill': 'Purchase bill'},
      );
      expect(applyTerms('Invoices', restaurant), 'Bills');
      expect(applyTerms('New invoice', restaurant), 'New bill');
      expect(applyTerms('Bills', restaurant), 'Purchase bills');
      expect(
        applyTerms('Enter purchase bill', restaurant),
        'Enter purchase bill',
      );
      expect(applyTerms('E-way bill', restaurant), 'E-way bill');
    });

    test('keeps legal words', () {
      expect(applyTerms('Tax Invoice', hospital), 'Tax Invoice');
      expect(
        applyTerms('Generate e-way bill', hospital),
        'Generate e-way bill',
      );
      expect(applyTerms('Send e-invoice', hospital), 'Send e-invoice');
    });

    test('a general company is unchanged', () {
      expect(
        applyTerms('New customer', BusinessProfile.standard),
        'New customer',
      );
    });
  });

  testWidgets('a hospital sees Patient on the party list and form', (
    tester,
  ) async {
    final app = await bootApp(
      tester,
      const Size(1440, 900),
      backend: _backend({
        'businessType': 'hospital',
        'terms': {'customer': 'Patient', 'invoice': 'Bill'},
      }),
    );
    await app.go('/parties');
    expect(find.text('New patient'), findsOneWidget);
    expect(find.text('Patients'), findsWidgets);
    expect(find.text('Customers'), findsNothing);
    await app.go('/parties/new');
    expect(find.text('New patient'), findsWidgets);
    expect(find.text('Customer'), findsNothing);
    expect(find.text('Patient'), findsWidgets);
    app.expectClean('hospital parties');
  });

  testWidgets('a page title takes the sector word once', (tester) async {
    final app = await bootApp(
      tester,
      const Size(1440, 900),
      backend: _backend({
        'businessType': 'hospital',
        'terms': {
          'customer': 'Patient',
          'invoice': 'Bill',
          'bill': 'Purchase bill',
          'item': 'Service or medicine',
        },
      }),
    );
    await app.go('/invoices');
    expect(find.text('Sales bills'), findsOneWidget);
    expect(find.text('Sales purchase bills'), findsNothing);
    await app.go('/parties');
    expect(find.text('Patients'), findsWidgets);
    expect(find.text('Services'), findsOneWidget);
    expect(find.text('Service or med'), findsNothing);
    app.expectClean('hospital titles');
  });

  testWidgets('a general company sees Customer', (tester) async {
    final app = await bootApp(tester, const Size(1440, 900));
    await app.go('/parties');
    expect(find.text('Customers'), findsWidgets);
    expect(find.text('Patients'), findsNothing);
    await app.go('/parties/new');
    expect(find.text('Customer'), findsWidgets);
    app.expectClean('general parties');
  });
}
