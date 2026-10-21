import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/app_harness.dart';
import '../support/fake_backend.dart';

/// Opens every screen through the real router at phone, tablet, laptop and
/// desktop widths against the fake backend, failing on any layout error
/// (overflow, unbounded constraints) or runtime error.
void main() {
  // Route → a text that only appears once the screen has loaded its data.
  const routes = {
    '/dashboard': 'Receivables',
    '/invoices': 'INV/26-27/00002',
    '/invoices/new': 'Add item',
    '/invoices/new?partyId=p1': 'Mumbai Infra Projects LLP',
    '/invoices/inv1': 'Deliver to gate 2',
    '/credit-notes': 'CN/26-27/00001',
    '/credit-notes/new': 'Choose an invoice first.',
    '/credit-notes/new?invoiceId=inv1': 'Return qty',
    '/credit-notes/cn1': 'Damaged bags',
    '/receipts': 'RCT/26-27/00001',
    '/receipts/new': 'Choose a customer to see',
    '/receipts/new?partyId=p1&docId=inv1&amount=521': 'INV/26-27/00003',
    '/receipts/pay1': 'UTR123456',
    '/purchases': 'PUR/26-27/00002',
    '/purchases/new': 'Add item',
    '/purchases/new?partyId=p2': 'Bengaluru Steel Suppliers',
    '/purchases/pur1': 'BSS/2026/118',
    '/payments': 'PAY/26-27/00001',
    '/payments/new?partyId=p2&docId=pur1&amount=8000': 'PUR/26-27/00001',
    '/payments/pay2': 'Bills settled',
    '/expenses': 'EXP/26-27/00001',
    '/expenses/new': 'Amount before GST',
    '/expenses/exp1': 'Diesel for generator',
    '/items': 'Site supervision (per day)',
    '/items/new': 'Create item',
    '/items/i1': 'Save changes',
    '/stock': 'Site A — Tower 1',
    '/stock?lowOnly=true': 'Low stock only',
    '/stock/moves?itemId=i1&locationId=l1&title=Cement': 'Transfer in',
    '/transfers': 'TRF/26-27/00002',
    '/transfers/new': 'Send transfer',
    '/transfers/trf1': 'Vehicle KA-01-AB-1234',
    '/parties': 'Bengaluru Steel Suppliers',
    '/parties/new': 'Create party',
    '/parties/p1': 'Receivable ₹12,500.00',
    '/parties/p1/edit': 'accounts@mumbai-infra.in',
    '/parties/p2': 'Payable ₹8,000.00',
    '/locations': 'SA-T1',
    '/users': 'Ravi Kumar',
    '/users/new': 'Create user',
    '/audit': 'Asha Rao',
    '/no-access': 'Ask an administrator',
  };

  for (final size in testWidths) {
    testWidgets('all screens render at ${size.width.toInt()} px', (
      tester,
    ) async {
      final app = await bootApp(tester, size);
      // Restored session lands on the dashboard.
      expect(find.text('Sales today'), findsOneWidget);

      for (final MapEntry(key: route, value: marker) in routes.entries) {
        await app.go(route);
        expect(
          find.textContaining(marker),
          findsWidgets,
          reason: '$route should show "$marker" at $size',
        );
        app.expectClean('route $route at $size');
      }
    });

    testWidgets('menu opens at ${size.width.toInt()} px', (tester) async {
      final app = await bootApp(tester, size);
      if (size.width < 900) {
        await tester.tap(find.byTooltip('Open navigation menu'));
        await tester.pumpAndSettle();
      }
      // The menu scrolls: every group heading and the last entry can be
      // reached.
      final menu = find
          .descendant(
            of: find.byType(NavigationDrawer),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final label in [
        'OVERVIEW',
        'SALES',
        'PURCHASES',
        'INVENTORY',
        'MASTERS',
        'ADMINISTRATION',
        'Audit log',
      ]) {
        await tester.scrollUntilVisible(
          find.text(label),
          100,
          scrollable: menu,
        );
        expect(find.text(label), findsOneWidget, reason: label);
      }
      await tester.tap(find.text('Audit log'));
      await tester.pumpAndSettle();
      expect(app.router.state.uri.path, '/audit');
      app.expectClean('menu at $size');
    });
  }

  testWidgets('screens cope with a v1.0 server (no v1.1 fields)', (
    tester,
  ) async {
    final app = await bootApp(tester, const Size(1440, 900), v11: false);
    expect(find.text('Receivables'), findsNothing);
    expect(find.text('Sales today'), findsOneWidget);
    for (final route in ['/invoices', '/invoices/inv1', '/parties/p1']) {
      await app.go(route);
      app.expectClean(route);
    }
    expect(find.text('Receipts & credit notes'), findsNothing);
  });

  for (final size in testWidths) {
    testWidgets('long names and big amounts fit at ${size.width.toInt()} px', (
      tester,
    ) async {
      final app = await bootApp(tester, size);
      const longName =
          'Shree Venkateshwara Infrastructure Developers & Contractors '
          'Private Limited (Unit 2)';
      Map<String, Object?> long(Map<String, Object?> json) => {
        ...json,
        'partyName': longName,
        'name': longName,
        'locationName': 'Central Warehouse — Whitefield Industrial Area',
        'fromLocationName': 'Central Warehouse — Whitefield Industrial Area',
        'toLocationName': 'Site B — Tower 14, Phase 3 Extension',
        'accountName': 'Repairs & Maintenance — Heavy Machinery',
        'description': 'Diesel and lubricants for the generator at site B',
        'total': 123456789.99,
        'amount': 98765432.10,
        'amountDue': 12345678.90,
        'unallocated': 1234567.89,
      };
      (int, Object?) page(List<Map<String, Object?>> rows) =>
          (200, {'data': rows.map(long).toList(), 'total': rows.length});
      app.backend.overrides.addAll({
        'GET /invoices': page([FakeBackend.invoiceRow]),
        'GET /invoices/inv1': (200, long(FakeBackend.invoiceDetail)),
        'GET /purchases': page([FakeBackend.purchaseRow]),
        'GET /purchases/pur1': (200, long(FakeBackend.purchaseDetail)),
        'GET /payments': page([FakeBackend.receipt]),
        'GET /payments/pay1': (200, long(FakeBackend.receipt)),
        'GET /credit-notes': page([FakeBackend.creditNote]),
        'GET /transfers': page([FakeBackend.transfer]),
        'GET /transfers/trf1': (200, long(FakeBackend.transfer)),
        'GET /expenses': page([FakeBackend.expense]),
        'GET /expenses/exp1': (200, long(FakeBackend.expense)),
        'GET /parties': page([FakeBackend.customer, FakeBackend.vendor]),
        'GET /parties/p1': (
          200,
          {...long(FakeBackend.customer), 'balance': 123456789.5},
        ),
      });
      for (final route in [
        '/invoices',
        '/invoices/inv1',
        '/purchases',
        '/purchases/pur1',
        '/receipts',
        '/receipts/pay1',
        '/credit-notes',
        '/transfers',
        '/transfers/trf1',
        '/expenses',
        '/expenses/exp1',
        '/parties',
        '/parties/p1',
      ]) {
        await app.go(route);
        app.expectClean('$route with long text at $size');
      }
    });
  }
}
