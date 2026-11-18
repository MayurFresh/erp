import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/parties/party_model.dart';
import 'package:onematrix/features/parties/statement_pdf.dart';
import 'package:onematrix/features/receivables/receivables_models.dart';
import 'package:onematrix/features/receivables/receivables_routes.dart';
import 'package:onematrix/features/company/company_model.dart';

import 'receivables_harness.dart';

void main() {
  group('models', () {
    test('PartyStatement keeps the ledger and adds ageing, bills and interest', () {
      final s = PartyStatement.fromJson(statementJson());
      expect(s.ledger.closingBalance, 1950);
      expect(s.rows, hasLength(2));
      expect(s.rows.first.dueDate, '2026-11-03');
      expect(s.ageing.overdue, 1360);
      expect(s.ageing.buckets.first, ('Not due', 590.0));
      expect(s.openBills.first.interestDue, 5.82);
      expect(s.showInterest, isTrue);
      expect(PartyStatement.fromJson(statementJson(pct: 0)).showInterest, isFalse);
      expect(statementTypeLabel('credit_note'), 'Credit note');
    });

    test('ReminderSettings summary reads in plain words', () {
      final s = ReminderSettings.fromJson(reminderSettingsJson);
      expect(s.summary, '3 days before the due date, on the due date, then every 7 days after it, up to 3 times');
      expect(const ReminderSettings(daysBefore: null, onDueDate: false, maxRepeats: 0).summary, 'No steps are on.');
    });

    test('RecurringInvoice parses created invoices', () {
      final t = RecurringInvoice.fromJson(recurringJson('t1', 'active'));
      expect(t.invoices, hasLength(2));
      expect(t.invoices.last.due, 0);
      expect(t.lines.single.rate, 25000);
      expect(frequencyLabel('half_yearly'), 'Half-yearly');
    });
  });

  test('statement PDF builds with ageing and interest lines', () async {
    final s = PartyStatement.fromJson(statementJson());
    final party = Party.fromJson({'id': 'p1', 'type': 'customer', 'name': 'Acme Traders', 'stateCode': '24'});
    final bytes = await buildStatementPdf(
      party,
      s.ledger,
      const Company(id: 'c1', name: 'Test Co', stateCode: '24'),
      extraDetails: [for (final (l, a) in s.ageing.buckets) ('Ageing: $l', '$a')],
    );
    expect(String.fromCharCodes(bytes.take(5)), '%PDF-');
  });

  test('routes and menu entries are exported', () {
    expect(receivablesRoutes(), isNotEmpty);
    expect(receivablesNavEntries.map((e) => e.label), ['Repeat invoices', 'Payment reminders']);
  });

  for (final size in receivablesSizes) {
    final w = size.width.toInt();

    testWidgets('statement shows rows, ageing and interest at $w px', (tester) async {
      final h = await bootReceivables(tester, size, location: '/parties/p1/statement');
      expect(find.textContaining('Statement: Acme Traders'), findsOneWidget);
      expect(find.text('Ageing of what they owe'), findsOneWidget);
      expect(find.text('61 to 90 days'), findsOneWidget);
      expect(find.text('Open bills', skipOffstage: false), findsOneWidget);
      expect(find.textContaining('Interest', skipOffstage: false), findsWidgets);
      expect(find.text('Opening balance', skipOffstage: false), findsOneWidget);
      expect(h.backend.count('GET', '/parties/p1/statement'), greaterThanOrEqualTo(1));
      h.expectClean('statement at $w');
    });

    testWidgets('reminder settings save through PATCH at $w px', (tester) async {
      final h = await bootReceivables(tester, size, location: '/reminders');
      expect(find.text('Send reminders for unpaid invoices'), findsOneWidget);
      expect(find.text('Opted Out Co', skipOffstage: false), findsOneWidget);
      await tester.tap(find.text('Save settings'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(h.backend.count('PATCH', '/reminders/settings'), 1);
      expect(h.backend.body('PATCH', '/reminders/settings')['daysBefore'], 3);
      await tester.tap(find.text('Run now'));
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/reminders/run'), 1);
      expect(find.textContaining('1 reminders queued'), findsOneWidget);
      h.expectClean('settings at $w');
    });

    testWidgets('reminder log lists sent and skipped at $w px', (tester) async {
      final h = await bootReceivables(tester, size, location: '/reminders/log');
      expect(find.textContaining('Acme Traders: INV/26-27/00002'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text('Skipped'), findsOneWidget);
      expect(find.textContaining('No email or phone'), findsOneWidget);
      h.expectClean('log at $w');
    });

    testWidgets('recurring list, detail and pause at $w px', (tester) async {
      final h = await bootReceivables(tester, size, location: '/recurring-invoices');
      expect(find.text('Shop rent'), findsNWidgets(2));
      expect(find.text('Needs attention'), findsOneWidget);
      await h.go('/recurring-invoices/t1');
      expect(find.text('Invoices created'), findsOneWidget);
      expect(find.text('INV/26-27/00010', skipOffstage: false), findsOneWidget);
      expect(find.text('Paid', skipOffstage: false), findsOneWidget);
      await tester.tap(find.text('Pause').first);
      await tester.pumpAndSettle();
      expect(h.backend.count('POST', '/recurring-invoices/t1/pause'), 1);
      h.expectClean('recurring at $w');
    });

    testWidgets('recurring form asks for what is missing at $w px', (tester) async {
      final h = await bootReceivables(tester, size, location: '/recurring-invoices/new');
      expect(find.text('New recurring invoice'), findsWidgets);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Give it a name'), findsOneWidget);
      expect(find.text('Add at least one item'), findsOneWidget);
      expect(h.backend.count('POST', '/recurring-invoices'), 0);
      h.expectClean('form at $w');
    });
  }

  testWidgets('a user without invoice access sees the lock message', (tester) async {
    final h = await bootReceivables(
      tester,
      const Size(390, 844),
      location: '/recurring-invoices',
      permissions: {'dashboard.view'},
    );
    expect(find.textContaining('You do not have access'), findsOneWidget);
    h.expectClean('gate');
  });
}
