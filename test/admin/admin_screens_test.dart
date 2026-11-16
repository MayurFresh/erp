import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admin_fake_backend.dart';
import 'admin_harness.dart';

void main() {
  // Route → text that only appears once the screen has loaded.
  const routes = {
    '/accounts': 'Cash in Hand',
    '/accounts/a-cash': 'Opening balance',
    '/accounts/a-ar': 'All parties',
    '/journals': 'JV/26-27/00001',
    '/journals/new': 'Post journal',
    '/financials': 'Trial balance',
    '/financials/trial-balance': 'Debits equal credits',
    '/financials/profit-loss': 'Gross profit',
    '/financials/balance-sheet': 'Balanced — assets equal',
    '/reports': 'Sales register',
    '/reports/sales-register': 'INV/26-27/00001',
    '/reports/purchase-register': 'PUR/26-27/00001',
    '/reports/gst-summary': 'credit carried forward',
    '/reports/stock-valuation': 'Stock value',
    '/reports/receivables-ageing': '31–60 days',
    '/reports/payables-ageing': 'Mumbai Steel Suppliers',
    '/company': 'Bank & UPI',
    '/roles': 'Billing Clerk',
    '/roles/new': 'Create role',
    '/roles/new?from=r1': 'Copy of Owner',
    '/roles/r1': 'Built-in roles cannot be changed',
    '/roles/r3': 'Save changes',
    '/users/u2': 'supervisor@demo.in',
    '/users/new': 'New user stub',
    '/account': 'Change password',
  };

  for (final size in adminTestWidths) {
    testWidgets('admin screens render at ${size.width.toInt()} px', (
      tester,
    ) async {
      final app = await bootAdmin(tester, size);
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

    testWidgets(
      'day book expands and long names fit at ${size.width.toInt()} px',
      (tester) async {
        final app = await bootAdmin(tester, size);
        const long =
            'Shree Venkateshwara Infrastructure Developers & Contractors '
            'Private Limited (Unit 2)';
        app.backend.overrides['GET /reports/sales-register'] = (
          200,
          {
            ...AdminFakeBackend.salesRegister,
            'rows': [
              for (final r in AdminFakeBackend.salesRegister['rows'] as List)
                {...r as Map, 'partyName': long, 'total': 123456789.99},
            ],
          },
        );
        await app.go('/journals');
        await tester.tap(find.text('INV/26-27/00001'));
        await tester.pumpAndSettle();
        expect(find.textContaining('Patel Constructions'), findsWidgets);
        app.expectClean('expanded entry at $size');
        await app.go('/reports/sales-register');
        app.expectClean('long party names at $size');
      },
    );
  }

  testWidgets('manual journal: save stays disabled until balanced', (
    tester,
  ) async {
    final app = await bootAdmin(tester, const Size(1440, 900));
    await app.go('/journals/new');
    FilledButton post() => tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Post journal'),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(post().onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Narration'),
      'Cash to site',
    );
    Future<void> pick(int line, String account) async {
      await tester.tap(find.text('Account').at(line + 1)); // +1: grid header
      await tester.pumpAndSettle();
      await tester.tap(find.text(account).last);
      await tester.pumpAndSettle();
    }

    await pick(0, 'Cash in Hand');
    await pick(1, 'Bank Account');
    final amounts = find.widgetWithText(TextField, '0.00');
    await tester.enterText(amounts.at(0), '5000'); // line 1 debit
    await tester.enterText(amounts.at(3), '4000'); // line 2 credit
    await tester.pumpAndSettle();
    expect(find.text('Debit exceeds credit by ₹1,000.00'), findsOneWidget);
    expect(post().onPressed, isNull);

    await tester.enterText(amounts.at(3), '5000');
    await tester.pumpAndSettle();
    expect(find.text('Balanced'), findsOneWidget);
    expect(post().onPressed, isNotNull);

    await tester.tap(find.text('Post journal'));
    await tester.pumpAndSettle();
    final body = app.backend.last('POST', '/journals').data as Map;
    expect(body['narration'], 'Cash to site');
    expect(body['lines'], [
      {'accountId': 'a-cash', 'debit': 5000.0},
      {'accountId': 'a-bank', 'credit': 5000.0},
    ]);
    expect(app.router.state.uri.path, '/journals');
    app.expectClean('journal posted');
  });

  testWidgets('manual journal maps server line errors to rows', (tester) async {
    final app = await bootAdmin(tester, const Size(360, 740));
    app.backend.overrides['POST /journals'] = AdminFakeBackend.error(
      400,
      'VALIDATION_ERROR',
      'Line 2: account not found or inactive.',
      {'lines.1.accountId': 'Invalid'},
    );
    await app.go('/journals/new');
    await tester.enterText(find.byType(TextField).first, 'Test entry');
    for (final (i, name) in [(0, 'Cash in Hand'), (1, 'Bank Account')]) {
      await tester.ensureVisible(find.text('Account').at(i));
      await tester.tap(find.text('Account').at(i));
      await tester.pumpAndSettle();
      await tester.tap(find.text(name).last);
      await tester.pumpAndSettle();
    }
    await tester.enterText(find.widgetWithText(TextField, 'Debit').at(0), '10');
    await tester.enterText(
      find.widgetWithText(TextField, 'Credit').at(1),
      '10',
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Post journal'));
    await tester.tap(find.text('Post journal'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid'), findsOneWidget);
    app.expectClean('line error');
  });

  testWidgets('cancel a manual journal from the day book', (tester) async {
    final app = await bootAdmin(tester, const Size(768, 1024));
    await app.go('/journals');
    await tester.tap(find.text('JV/26-27/00001'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel journal').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Duplicate entry');
    await tester.tap(find.widgetWithText(FilledButton, 'Cancel journal'));
    await tester.pumpAndSettle();
    expect(app.backend.last('POST', '/journals/j1/cancel').data, {
      'reason': 'Duplicate entry',
    });
    expect(find.textContaining('reversed by JV/26-27/00002'), findsOneWidget);
    app.expectClean('journal cancelled');
  });

  testWidgets('create an account and rename a system account', (tester) async {
    final app = await bootAdmin(tester, const Size(360, 740));
    await tester.tap(find.text('New account'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Account name'),
      'Site Petty Cash',
    );
    await tester.tap(find.text('Expense').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Asset').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cash').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create account'));
    await tester.pumpAndSettle();
    expect(app.backend.last('POST', '/accounts').data, {
      'name': 'Site Petty Cash',
      'type': 'asset',
      'subtype': 'cash',
    });
    app.expectClean('account created');

    // Let the "Created …" SnackBar go away first.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byTooltip('Account actions').first);
    await tester.tap(find.byTooltip('Account actions').first);
    await tester.pumpAndSettle();
    expect(find.text('Deactivate'), findsNothing); // system account
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, 'Code'), findsNothing);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Account name'),
      'Cash at HO',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(app.backend.last('PATCH', '/accounts/a-cash').data, {
      'name': 'Cash at HO',
    });
    app.expectClean('account renamed');
  });

  testWidgets('company profile maps validation errors onto fields', (
    tester,
  ) async {
    final app = await bootAdmin(tester, const Size(1024, 768));
    app.backend.overrides['PATCH /company'] = AdminFakeBackend.error(
      400,
      'VALIDATION_ERROR',
      'Invalid input',
      {'bankIfsc': 'Invalid IFSC'},
    );
    await app.go('/company');
    // GSTIN from another state is caught on the device.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'GSTIN (optional)'),
      '27AAACD1234F1Z7',
    );
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.textContaining('GSTIN is for Maharashtra'));
    expect(find.textContaining('GSTIN is for Maharashtra'), findsOneWidget);
    expect(app.backend.count('PATCH', '/company'), 0);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'GSTIN (optional)'),
      '24AAACD1234F1Z5',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Phone'),
      '079-4000-9999',
    );
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(app.backend.last('PATCH', '/company').data, {
      'phone': '079-4000-9999',
    });
    expect(find.text('Invalid IFSC'), findsOneWidget);
    app.expectClean('company errors');
  });

  testWidgets('company profile is read-only without company.manage', (
    tester,
  ) async {
    final app = await bootAdmin(
      tester,
      const Size(360, 740),
      permissions: {'accounts.view'},
    );
    await app.go('/company');
    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('Save changes'), findsNothing);
    app.expectClean('read-only company');
  });

  testWidgets('duplicate a built-in role and save the copy', (tester) async {
    final app = await bootAdmin(tester, const Size(768, 1024));
    await app.go('/roles/r1');
    await tester.tap(find.text('Duplicate'));
    await tester.pumpAndSettle();
    expect(app.router.state.uri.toString(), '/roles/new?from=r1');
    // Untick the whole Administration module.
    await tester.tap(find.byKey(const Key('matrix-all-Administration')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Create role'));
    await tester.tap(find.text('Create role'));
    await tester.pumpAndSettle();
    final body = app.backend.last('POST', '/roles').data as Map;
    expect(body['name'], 'Copy of Owner');
    expect(body['permissions'], isNot(contains('users.manage')));
    expect(body['permissions'], contains('accounts.view'));
    app.expectClean('role duplicated');
  });

  testWidgets('user edit shows 403 and 409 refusals clearly', (tester) async {
    final app = await bootAdmin(tester, const Size(360, 740));
    await app.go('/users/u2');
    app.backend.overrides['PATCH /users/u2'] = AdminFakeBackend.error(
      403,
      'FORBIDDEN',
      'This user has access you do not have, so you cannot change them.',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Name'),
      'Ravi K',
    );
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.text('You cannot make this change'), findsOneWidget);
    expect(find.textContaining('access you do not have'), findsOneWidget);

    app.backend.overrides['PATCH /users/u2'] = AdminFakeBackend.error(
      409,
      'CONFLICT',
      'Every company needs at least one active Owner.',
    );
    await tester.ensureVisible(find.text('Save changes'));
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();
    expect(find.textContaining('without an Owner'), findsOneWidget);
    app.expectClean('user refusals');
  });

  testWidgets('reset a user password', (tester) async {
    final app = await bootAdmin(tester, const Size(360, 740));
    await app.go('/users/u2');
    await tester.tap(find.text('Reset password'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'New password'),
      'NewPass@123',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm password'),
      'NewPass@123',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Reset password'));
    await tester.pumpAndSettle();
    expect(app.backend.last('POST', '/users/u2/password').data, {
      'password': 'NewPass@123',
    });
    expect(find.textContaining('signed out everywhere'), findsOneWidget);
    app.expectClean('password reset');
  });

  testWidgets('own account: wrong current password lands on the field', (
    tester,
  ) async {
    final app = await bootAdmin(tester, const Size(360, 740));
    app.backend.overrides['POST /me/password'] = AdminFakeBackend.error(
      400,
      'VALIDATION_ERROR',
      'Current password is incorrect.',
      {'currentPassword': 'Incorrect'},
    );
    await app.go('/account');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Current password'),
      'wrong',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'New password'),
      'Better@123',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Confirm password'),
      'Better@123',
    );
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Change password'),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Change password'));
    await tester.pumpAndSettle();
    expect(find.text('Incorrect'), findsOneWidget);
    app.expectClean('wrong password');
  });

  testWidgets('Export CSV copies the report to the clipboard', (tester) async {
    final app = await bootAdmin(tester, const Size(1440, 900));
    await app.go('/financials/trial-balance');
    await tester.tap(find.text('Export CSV'));
    await tester.pumpAndSettle();
    expect(app.clipboard, startsWith('Code,Account,Type,Debit,Credit\r\n'));
    expect(app.clipboard, contains(',Total,,2871995.00,2871995.00'));
    expect(find.textContaining('Copied 5 rows as CSV'), findsOneWidget);

    // Phones get one Export menu.
    tester.view.physicalSize = const Size(360, 740);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export CSV (copy)'));
    await tester.pumpAndSettle();
    expect(app.clipboard, contains("Owner's Capital"));
    app.expectClean('export');
  });

  testWidgets('reports hub and valuation follow permissions', (tester) async {
    final app = await bootAdmin(
      tester,
      const Size(768, 1024),
      permissions: {'reports.view'},
    );
    await app.go('/reports');
    expect(find.text('Sales register'), findsOneWidget);
    expect(find.text('Trial balance'), findsNothing);
    expect(find.text('Stock valuation'), findsNothing);
    await app.go('/reports/stock-valuation');
    expect(
      find.textContaining('permission to see cost prices'),
      findsOneWidget,
    );
    expect(app.backend.count('GET', '/reports/stock-valuation'), 0);
    app.expectClean('permissions');
  });

  testWidgets('empty and error states', (tester) async {
    final app = await bootAdmin(tester, const Size(360, 740));
    app.backend.overrides['GET /reports/sales-register'] = (
      200,
      {'rows': [], 'totals': {}},
    );
    app.backend.overrides['GET /reports/gst-summary'] = AdminFakeBackend.error(
      500,
      'INTERNAL_ERROR',
      'Database unavailable',
    );
    await app.go('/reports/sales-register');
    expect(find.text('No invoices in this period.'), findsOneWidget);
    await app.go('/reports/gst-summary');
    expect(
      find.text('Something went wrong on our side. Try again.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
    app.expectClean('states');
  });
}
