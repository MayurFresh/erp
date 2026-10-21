import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/money.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

/// Walks through the main create flows and dialogs against the fake backend.
void main() {
  const desktop = Size(1440, 900);
  const phone = Size(360, 740);

  String fieldText(WidgetTester tester, Finder field) =>
      tester.widget<TextFormField>(field).controller!.text;

  Future<void> pick(WidgetTester tester, String field, String option) async {
    await tester.tap(find.text(field));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> settlePreview(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
  }

  testWidgets('invoice create shows live preview totals', (tester) async {
    final app = await bootApp(tester, desktop);
    await app.go('/invoices/new');

    await pick(tester, 'Customer', 'Mumbai Infra Projects LLP');
    await pick(tester, 'Add item', 'Portland Cement 53 Grade 50kg');
    // Two locations: pick one.
    await tester.tap(find.text('Billing location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Head Office (HO)').last);
    await settlePreview(tester);

    final backend = app.backend;
    expect(backend.count('POST', '/invoices/preview'), 1);
    final body = backend.last('POST', '/invoices/preview').data as Map;
    expect(body['locationId'], 'l1');
    expect(body['partyId'], 'p1');
    expect((body['lines'] as List).single, {
      'itemId': 'i1',
      'qty': 1.0,
      'rate': 420.0,
    });
    expect(find.text('IGST'), findsWidgets);
    expect(find.text('₹1,021.00'), findsWidgets);

    // Typing quickly triggers one more preview after the debounce.
    final qty = find.widgetWithText(TextFormField, 'Qty');
    await tester.enterText(qty, '2');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(qty, '25');
    await settlePreview(tester);
    expect(backend.count('POST', '/invoices/preview'), 2);
    app.expectClean('invoice create');
  });

  testWidgets('purchase create previews at the item purchase price', (
    tester,
  ) async {
    final app = await bootApp(tester, phone);
    await app.go('/purchases/new');

    await pick(tester, 'Vendor', 'Bengaluru Steel Suppliers');
    await tester.ensureVisible(find.text('Add item'));
    await pick(tester, 'Add item', 'Portland Cement 53 Grade 50kg');
    await tester.ensureVisible(find.text('Receiving location'));
    await tester.tap(find.text('Receiving location'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Head Office (HO)').last);
    await settlePreview(tester);

    final body = app.backend.last('POST', '/purchases/preview').data as Map;
    expect(body['partyId'], 'p2');
    expect(body['billDate'], apiDate(DateTime.now()));
    expect((body['lines'] as List).single, {
      'itemId': 'i1',
      'qty': 1.0,
      'rate': 380.0,
    });
    expect(find.text('₹9,728.00'), findsWidgets);
    app.expectClean('purchase create');
  });

  testWidgets('record receipt from an invoice pre-fills its due', (
    tester,
  ) async {
    final app = await bootApp(tester, desktop);
    await app.go('/invoices/inv1');
    expect(find.text('Partly paid'), findsOneWidget);
    expect(find.text('RCT/26-27/00001'), findsOneWidget); // settlement
    await tester.tap(find.text('Record receipt'));
    await tester.pumpAndSettle();

    final amount = find.widgetWithText(TextFormField, 'Amount received');
    final allocations = find.widgetWithText(TextFormField, 'Allocate ₹');
    expect(fieldText(tester, amount), '521');
    expect(find.text('Mumbai Infra Projects LLP'), findsOneWidget);
    // inv3 (older) first, then inv1 which gets the whole amount.
    expect(fieldText(tester, allocations.at(0)), '');
    expect(fieldText(tester, allocations.at(1)), '521');

    // Auto-allocate fills the oldest first.
    await tester.tap(find.text('Auto-allocate'));
    await tester.pumpAndSettle();
    expect(fieldText(tester, allocations.at(0)), '521');
    expect(fieldText(tester, allocations.at(1)), '');

    // A bigger amount covers both and leaves an advance.
    await tester.enterText(amount, '3000');
    await tester.pumpAndSettle();
    expect(fieldText(tester, allocations.at(0)), '2000');
    expect(fieldText(tester, allocations.at(1)), '521');
    expect(find.text('₹479.00'), findsOneWidget);

    await tester.tap(find.text('Save receipt'));
    await tester.pumpAndSettle();
    final body = app.backend.last('POST', '/payments').data as Map;
    expect(body, {
      'kind': 'receipt',
      'partyId': 'p1',
      'date': apiDate(DateTime.now()),
      'accountId': 'a-cash',
      'mode': 'cash',
      'amount': 3000.0,
      'allocations': [
        {'docId': 'inv3', 'amount': 2000.0},
        {'docId': 'inv1', 'amount': 521.0},
      ],
    });
    expect(app.router.state.uri.path, '/receipts/pay1');
    app.expectClean('receipt');
  });

  testWidgets('allocations cannot exceed what is due', (tester) async {
    final app = await bootApp(tester, phone);
    await app.go('/payments/new?partyId=p2&docId=pur1&amount=9000');
    final allocation = find.widgetWithText(TextFormField, 'Allocate ₹');
    expect(fieldText(tester, allocation), '8000');
    await tester.enterText(allocation, '8500');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save payment'));
    await tester.tap(find.text('Save payment'));
    await tester.pumpAndSettle();
    expect(find.text('More than due'), findsOneWidget);
    expect(app.backend.count('POST', '/payments'), 0);
    app.expectClean('allocation validation');
  });

  testWidgets('credit note previews the returned quantity', (tester) async {
    final app = await bootApp(tester, phone);
    await app.go('/credit-notes/new?invoiceId=inv1');
    expect(find.text('Max 1'), findsOneWidget); // 2 sold, 1 returned

    final qty = find.widgetWithText(TextFormField, 'Return qty');
    await tester.enterText(qty, '1');
    await settlePreview(tester);
    final preview = app.backend.last('POST', '/credit-notes/preview').data;
    expect((preview as Map)['lines'], [
      {'invoiceLineId': 'line1', 'qty': 1.0},
    ]);
    expect(preview['restock'], true);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Reason'),
      'Damaged',
    );
    await tester.ensureVisible(find.text('Save credit note'));
    await tester.tap(find.text('Save credit note'));
    await tester.pumpAndSettle();
    final body = app.backend.last('POST', '/credit-notes').data as Map;
    expect(body['reason'], 'Damaged');
    expect(body['invoiceId'], 'inv1');
    expect(app.router.state.uri.path, '/credit-notes/cn1');
    app.expectClean('credit note');
  });

  testWidgets('dialogs fit a phone', (tester) async {
    final app = await bootApp(tester, phone);
    final backend = app.backend;

    await app.go('/stock');
    await tester.tap(find.text('Adjust stock'));
    await tester.pumpAndSettle();
    expect(find.text('Opening stock'), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Choose an item'), findsOneWidget);
    expect(find.text('Quantity is required'), findsOneWidget);
    expect(backend.count('POST', '/stock/adjustments'), 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await app.go('/locations');
    await tester.tap(find.text('New location'));
    await tester.pumpAndSettle();
    expect(find.text('29 · Karnataka'), findsOneWidget); // company state
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    // On phones secondary actions live in the "More actions" menu.
    await app.go('/invoices/inv1');
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Share on WhatsApp'), findsOneWidget);
    expect(find.text('Create credit note'), findsOneWidget);
    await tester.tap(find.text('Cancel invoice'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel invoice').last);
    await tester.pumpAndSettle();
    expect(find.text('A reason is required'), findsOneWidget);
    await tester.tap(find.text('Keep invoice'));
    await tester.pumpAndSettle();
    app.expectClean('invoice cancel dialog');

    // Receipts applied: the refusal is explained, not just a snackbar.
    backend.overrides['POST /invoices/inv1/cancel'] = FakeBackend.error(
      409,
      'HAS_SETTLEMENTS',
      'Receipts or credit notes are applied to this invoice',
    );
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel invoice'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Wrong rate');
    await tester.tap(find.text('Cancel invoice').last);
    await tester.pumpAndSettle();
    expect(find.text('Cannot cancel this invoice'), findsOneWidget);
    expect(find.text('CN/26-27/00001'), findsWidgets);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    app.expectClean('has settlements');

    await app.go('/transfers/trf1');
    await tester.tap(find.text('Receive'));
    await tester.pumpAndSettle();
    expect(find.textContaining('added to Site A'), findsOneWidget);
    await tester.tap(find.text('Receive').last);
    await tester.pumpAndSettle();
    expect(backend.count('POST', '/transfers/trf1/receive'), 1);
    app.expectClean('transfer receive');

    await app.go('/receipts/pay1');
    await tester.tap(find.text('Cancel receipt'));
    await tester.pumpAndSettle();
    expect(find.textContaining('allocations are released'), findsOneWidget);
    await tester.tap(find.text('Keep it'));
    await tester.pumpAndSettle();

    await app.go('/parties/p1');
    await tester.tap(find.byTooltip('More actions'));
    await tester.pumpAndSettle();
    expect(find.text('Record receipt'), findsOneWidget);
    expect(find.text('New bill'), findsNothing); // a customer
    await tester.tapAt(const Offset(10, 700));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Switch company'));
    await tester.pumpAndSettle();
    expect(find.text('Second Company With A Long Name'), findsOneWidget);
    await tester.tapAt(const Offset(10, 700));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text('Create a business account'), findsOneWidget);
    expect(backend.count('POST', '/auth/logout'), 1);
    app.expectClean('phone dialogs');
  });

  testWidgets('signing in lands on the requested page', (tester) async {
    final app = await bootApp(tester, phone, restore: false);
    expect(find.text('Create a business account'), findsOneWidget);
    await app.go('/items');
    expect(find.byKey(const Key('login.email')), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('login.email')),
      'owner@demo.in',
    );
    await tester.enterText(
      find.byKey(const Key('login.password')),
      'Demo@1234',
    );
    await tester.tap(find.byKey(const Key('login.submit')));
    await tester.pumpAndSettle();

    expect(app.backend.count('POST', '/auth/login'), 1);
    expect(find.text('Site supervision (per day)'), findsOneWidget);
    app.expectClean('login');
  });

  testWidgets('menu and buttons follow permissions', (tester) async {
    await bootApp(tester, desktop, permissions: {'items.view', 'stock.view'});
    // No dashboard permission: home is the first permitted section.
    expect(find.text('Items'), findsWidgets);
    expect(find.text('Stock'), findsOneWidget);
    expect(find.text('INVENTORY'), findsOneWidget);
    // Groups without permitted entries are hidden.
    expect(find.text('SALES'), findsNothing);
    expect(find.text('OVERVIEW'), findsNothing);
    expect(find.text('Dashboard'), findsNothing);
    expect(find.text('Transfers'), findsNothing);
    expect(find.text('New item'), findsNothing);
    expect(find.text('Purchase price'), findsNothing);
  });

  testWidgets('invoice actions follow permissions', (tester) async {
    final app = await bootApp(tester, desktop, permissions: {'invoices.view'});
    await app.go('/invoices/inv1');
    expect(find.text('Print'), findsOneWidget);
    expect(find.text('Record receipt'), findsNothing);
    expect(find.text('Create credit note'), findsNothing);
    expect(find.text('Cancel invoice'), findsNothing);
    // Settlements are listed but cannot be opened without payments.view.
    await tester.tap(find.text('RCT/26-27/00001'));
    await tester.pumpAndSettle();
    expect(app.router.state.uri.path, '/invoices/inv1');
    app.expectClean('read-only invoice');
  });
}
