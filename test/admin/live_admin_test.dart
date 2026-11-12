// Live checks of the accounting, reports and settings repositories against
// a running backend. Skipped unless PROGEN_API is set:
//
//   PROGEN_API=http://localhost:8080/api/v1 flutter test --reporter expanded test/admin/live_admin_test.dart
//
// Read-only against the demo company (owner@demo.in); posting and
// cancelling a journal happens in a freshly signed-up company.
@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/api_client.dart';
import 'package:progen_erp/core/token_store.dart';
import 'package:progen_erp/features/accounting/accounting_models.dart';
import 'package:progen_erp/features/accounting/accounting_repository.dart';
import 'package:progen_erp/features/auth/auth_models.dart';
import 'package:progen_erp/features/auth/auth_repository.dart';
import 'package:progen_erp/features/reports/report_models.dart';
import 'package:progen_erp/features/reports/reports_repository.dart';
import 'package:progen_erp/features/settings/settings_repository.dart';

void main() {
  final baseUrl = Platform.environment['PROGEN_API'];

  group(
    'live admin API',
    skip: baseUrl == null || baseUrl.isEmpty
        ? 'Set PROGEN_API (e.g. http://localhost:8080/api/v1) to run'
        : false,
    () {
      late ApiClient api;
      late AccountingRepository accounting;
      late ReportsRepository reports;
      late SettingsRepository settings;

      setUpAll(() async {
        api = ApiClient(baseUrl: baseUrl!, tokenStore: InMemoryTokenStore());
        final auth = AuthRepository(api);
        await auth.login('owner@demo.in', 'Demo@1234');
        final me = await auth.me();
        await api.setCompany(me.companies.first.id);
        accounting = AccountingRepository(api);
        reports = ReportsRepository(api);
        settings = SettingsRepository(api);
      });

      tearDownAll(() => api.close());

      double sum(Iterable<num> values) =>
          values.fold<double>(0, (s, v) => s + v);
      Matcher money(num v) => closeTo(v, 0.011);

      test('chart of accounts and a ledger add up', () async {
        final chart = await accounting.allAccounts();
        expect(chart.map((a) => a.code), containsAll(['1000', '1010', '4000']));
        final groups = groupAccounts(chart);
        expect(groups.first.type, 'asset');
        // Debit-positive balances net to zero across the whole chart.
        expect(sum(chart.map((a) => a.balance)), money(0));

        final cash = chart.firstWhere((a) => a.systemKey == 'cash');
        final ledger = await accounting.ledger(cash.id);
        expect(
          ledger.closingBalance,
          money(ledger.openingBalance + ledger.totalDebit - ledger.totalCredit),
        );
        expect(ledger.totalDebit, money(sum(ledger.lines.map((l) => l.debit))));
        if (ledger.lines.isNotEmpty) {
          expect(ledger.lines.last.balance, money(ledger.closingBalance));
        }
        expect(ledger.closingBalance, money(cash.balance));
      });

      test('trial balance totals match', () async {
        final tb = await reports.trialBalance();
        expect(tb.rows, isNotEmpty);
        expect(tb.totalDebit, money(tb.totalCredit));
        expect(tb.totalDebit, money(sum(tb.rows.map((r) => r.debit))));
        expect(tb.totalCredit, money(sum(tb.rows.map((r) => r.credit))));
      });

      test('balance sheet balances and P&L adds up', () async {
        final bs = await reports.balanceSheet();
        expect(bs.isBalanced, isTrue, reason: 'difference ${bs.difference}');
        expect(bs.totalAssets, money(bs.assets.total));
        expect(
          bs.totalLiabilitiesAndEquity,
          money(bs.liabilities.total + bs.equity.total),
        );
        expect(
          bs.assets.total,
          money(sum(bs.assets.rows.map((r) => r.amount))),
        );

        final pl = await reports.profitLoss();
        expect(pl.grossProfit, money(pl.revenue.total - pl.cogs.total));
        expect(
          pl.netProfit,
          money(pl.grossProfit + pl.otherIncome.total - pl.expenses.total),
        );
        final plRow = bs.equity.rows.where((r) => r.accountId == null);
        expect(plRow, hasLength(1), reason: 'equity carries a P&L row');
      });

      test('registers, GST, valuation and ageing parse and total', () async {
        final sales = await reports.salesRegister();
        final posted = sales.rows.where((r) => !r.isCancelled);
        expect(sales.totals.total, money(sum(posted.map((r) => r.total))));
        final purchases = await reports.purchaseRegister();
        expect(
          purchases.totals.taxable,
          money(
            sum(
              purchases.rows.where((r) => !r.isCancelled).map((r) => r.taxable),
            ),
          ),
        );
        final gst = await reports.gstSummary();
        expect(
          gst.netPayable.total,
          money(
            gst.netPayable.cgst + gst.netPayable.sgst + gst.netPayable.igst,
          ),
        );
        final valuation = await reports.stockValuation();
        expect(
          valuation.totalValue,
          money(sum(valuation.rows.map((r) => r.value))),
        );
        for (final type in AgeingType.values) {
          final a = await reports.ageing(type);
          expect(
            a.totals.total,
            money(sum(a.rows.map((r) => r.buckets.total))),
          );
          expect(a.totals.total, money(sum(a.totals.values)));
        }
      });

      test('company, permissions and roles', () async {
        final company = await settings.company();
        expect(company.name, isNotEmpty);
        final unchanged = await settings.updateCompany({});
        expect(unchanged.name, company.name);
        final defs = await settings.permissions();
        expect(defs.map((d) => d.key), contains('accounts.journal'));
        final roles = await settings.roles();
        expect(
          roles.where((r) => r.isSystem).map((r) => r.name),
          contains('Owner'),
        );
      });

      test('post and cancel a manual journal in a new company', () async {
        final fresh = ApiClient(
          baseUrl: baseUrl!,
          tokenStore: InMemoryTokenStore(),
        );
        addTearDown(fresh.close);
        final stamp = DateTime.now().microsecondsSinceEpoch;
        final auth = AuthRepository(fresh);
        await auth.signup(
          SignupRequest(
            businessName: 'Live Admin $stamp',
            name: 'Live Admin',
            email: 'liveadmin$stamp@example.com',
            password: 'Live@12345',
            stateCode: '24',
          ),
        );
        await fresh.setCompany((await auth.me()).companies.first.id);
        final repo = AccountingRepository(fresh);
        final chart = await repo.allAccounts();
        final cash = chart.firstWhere((a) => a.systemKey == 'cash');
        final capital = chart.firstWhere((a) => a.systemKey == 'capital');
        final draft = JournalDraft(
          narration: 'Capital introduced in cash',
          lines: [
            JournalDraftLine(
              accountId: cash.id,
              accountSubtype: cash.subtype,
              debit: 2500.5,
            ),
            JournalDraftLine(
              accountId: capital.id,
              accountSubtype: capital.subtype,
              credit: 2500.5,
            ),
          ],
        );
        expect(draft.canSave, isTrue);
        final entry = await repo.createJournal(draft);
        expect(entry.number, startsWith('JV/'));
        expect(entry.totalDebit, money(2500.5));

        final freshReports = ReportsRepository(fresh);
        var tb = await freshReports.trialBalance();
        expect(tb.totalDebit, money(tb.totalCredit));
        expect(tb.totalDebit, money(2500.5));

        final reversal = await repo.cancelJournal(entry.id, 'Entered twice');
        expect(reversal.isReversal, isTrue);
        final ledger = await repo.ledger(cash.id);
        expect(ledger.closingBalance, money(0));
        tb = await freshReports.trialBalance();
        expect(tb.totalDebit, money(tb.totalCredit));

        final book = await repo.journals(voucherType: 'journal');
        expect(
          book.data.map((e) => e.id),
          containsAll([entry.id, reversal.id]),
        );
      });
    },
  );
}
