import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/accounting/accounting_models.dart';
import 'package:progen_erp/features/reports/report_catalog.dart';
import 'package:progen_erp/features/reports/report_export.dart';
import 'package:progen_erp/features/reports/report_exports.dart';
import 'package:progen_erp/features/reports/report_models.dart';
import 'package:progen_erp/features/reports/report_pdf.dart';
import 'package:progen_erp/features/reports/report_period.dart';
import 'package:progen_erp/features/settings/settings_models.dart';
import 'package:progen_erp/core/permissions.dart';

import 'admin_fake_backend.dart';

void main() {
  group('report models', () {
    test('parse the contract shapes', () {
      final tb = TrialBalance.fromJson(AdminFakeBackend.trialBalance);
      expect(tb.rows, hasLength(5));
      expect(tb.isBalanced, isTrue);
      final pl = ProfitLoss.fromJson(AdminFakeBackend.profitLoss);
      expect(pl.revenue.total, 292873);
      expect(pl.otherIncome.rows, isEmpty);
      expect(pl.netProfit, lessThan(0));
      final bs = BalanceSheet.fromJson(AdminFakeBackend.balanceSheet);
      expect(bs.isBalanced, isTrue);
      expect(bs.equity.rows.last.accountId, isNull);
      final reg = Register.fromJson(AdminFakeBackend.salesRegister);
      expect(reg.postedCount, 1);
      expect(reg.cancelledCount, 1);
      expect(reg.rows.first.tax, 40410);
      final gst = GstSummary.fromJson(AdminFakeBackend.gstSummary);
      expect(gst.outward.creditNotes.gstRate, isNull);
      expect(gst.netPayable.total, -32287.86);
      expect(gst.hsn.first.hsnCode, '2523');
      final ageing = Ageing.fromJson(AdminFakeBackend.ageing);
      expect(ageing.rows.first.buckets.d31to60, 25000);
      expect(ageing.totals.overdue, 47000);
    });

    test('tolerate missing optional fields', () {
      expect(TrialBalance.fromJson({}).rows, isEmpty);
      final pl = ProfitLoss.fromJson({'netProfit': 5});
      expect(pl.isEmpty, isTrue);
      expect(pl.revenue.total, 0);
      expect(BalanceSheet.fromJson({}).isEmpty, isTrue);
      final row = RegisterRow.fromJson({
        'id': 'x',
        'number': 'N',
        'partyName': 'P',
      });
      expect(row.supplierInvoiceNo, isNull);
      expect(row.isCancelled, isFalse);
      expect(GstSummary.fromJson({}).isEmpty, isTrue);
      expect(StockValuation.fromJson({}).rows, isEmpty);
      expect(Ageing.fromJson({}).totals.total, 0);
      final entry = JournalEntry.fromJson({'id': 'j'});
      expect(entry.voucherType, 'journal');
      expect(entry.createdBy, isNull);
      expect(entry.lines, isEmpty);
    });

    test('net tax and optional money formatting', () {
      expect(formatNetTax(7695), '₹7,695.00');
      expect(formatNetTax(-47677.86), '₹47,677.86 credit c/f');
      expect(formatNetTax(-0.001), '₹0.00');
      expect(formatOptionalMoney(0), '—');
      expect(formatOptionalMoney(1234567.5), '₹12,34,567.50');
    });
  });

  group('ageing helpers', () {
    test('shares, oldest bucket and zero totals', () {
      final b = AgeingBuckets.fromJson(AdminFakeBackend.ageing['totals']);
      expect(b.values, [174350, 12000, 25000, 0, 10000]);
      final shares = b.shares;
      expect(shares.reduce((a, c) => a + c), closeTo(1, 1e-9));
      expect(formatShare(shares[0]), '79%');
      expect(b.oldestBucket, 4);
      const empty = AgeingBuckets();
      expect(empty.shares, [0, 0, 0, 0, 0]);
      expect(empty.oldestBucket, isNull);
    });
  });

  group('chart of accounts', () {
    test('groups by type in chart order and sorts by code', () {
      final accounts = AdminFakeBackend.accounts.map(Account.fromJson).toList()
        ..shuffle();
      final groups = groupAccounts(accounts);
      expect(groups.map((g) => g.label), [
        'Assets',
        'Liabilities',
        'Equity',
        'Income',
        'Expenses',
      ]);
      expect(groups.first.accounts.map((a) => a.code), [
        '1000',
        '1010',
        '1100',
        '1200',
      ]);
      expect(drCr(groups[1].total, (v) => '$v'), '392650.0 Cr');
    });

    test('search matches code prefix or name', () {
      final cash = Account.fromJson(AdminFakeBackend.accounts.first);
      expect(accountMatches(cash, '10'), isTrue);
      expect(accountMatches(cash, 'hand'), isTrue);
      expect(accountMatches(cash, '00'), isFalse);
      expect(accountTakesParty(cash), isFalse);
      expect(
        accountTakesParty(Account.fromJson(AdminFakeBackend.accounts[2])),
        isTrue,
      );
    });

    test('new account body omits empty code', () {
      expect(const NewAccount(name: 'Rent', type: 'expense').toJson(), {
        'name': 'Rent',
        'type': 'expense',
        'subtype': 'other',
      });
    });
  });

  group('manual journal draft', () {
    const cash = JournalDraftLine(
      accountId: 'a',
      accountSubtype: 'cash',
      debit: 100.1,
    );
    const bank = JournalDraftLine(
      accountId: 'b',
      accountSubtype: 'bank',
      credit: 100.1,
    );

    test('balances in paise, ignoring blank rows', () {
      const draft = JournalDraft(
        narration: 'Cash withdrawn',
        lines: [cash, JournalDraftLine(), bank],
      );
      expect(draft.filledLines, hasLength(2));
      expect(draft.isBalanced, isTrue);
      expect(draft.canSave, isTrue);
      expect(draft.toJson()['lines'], [
        {'accountId': 'a', 'debit': 100.1},
        {'accountId': 'b', 'credit': 100.1},
      ]);
    });

    test('reports why it cannot be saved', () {
      const unbalanced = JournalDraft(
        narration: 'ab',
        lines: [
          cash,
          JournalDraftLine(accountId: 'b', credit: 50),
        ],
      );
      expect(unbalanced.problems, [
        'Add a narration (at least 3 letters)',
        'Debits and credits must be equal',
      ]);
      expect(unbalanced.difference, closeTo(50.1, 1e-9));
      expect(
        journalDifferenceLabel(unbalanced.difference),
        'Debit exceeds credit by ₹50.10',
      );
      expect(journalDifferenceLabel(-5), 'Credit exceeds debit by ₹5.00');
      expect(journalDifferenceLabel(0.001), 'Balanced');
      expect(
        const JournalDraft(narration: 'x', lines: [cash]).problems,
        contains('Add at least 2 lines'),
      );
    });

    test('line rules: one side only, parties on AR/AP only', () {
      expect(const JournalDraftLine(debit: 5).error, 'Choose an account');
      expect(
        const JournalDraftLine(accountId: 'a', debit: 5, credit: 5).error,
        'Enter a debit or a credit, not both',
      );
      expect(
        const JournalDraftLine(accountId: 'a').error,
        'Enter a debit or credit',
      );
      expect(
        const JournalDraftLine(
          accountId: 'a',
          accountSubtype: 'cash',
          partyId: 'p',
          debit: 1,
        ).error,
        contains('receivable or payable'),
      );
      const ar = JournalDraftLine(
        accountId: 'a',
        accountSubtype: 'receivables',
        partyId: 'p',
        debit: 1,
      );
      expect(ar.error, isNull);
      expect(ar.toJson(), {'accountId': 'a', 'partyId': 'p', 'debit': 1.0});
      expect(journalLineIndex('lines.3.debit'), 3);
      expect(journalLineIndex('narration'), isNull);
    });

    test('entry totals and cancel rules', () {
      final manual = JournalEntry.fromJson(AdminFakeBackend.manualJournal);
      expect(manual.totalDebit, manual.totalCredit);
      expect(manual.canCancel, isTrue);
      expect(
        JournalEntry.fromJson(AdminFakeBackend.reversalJournal).canCancel,
        isFalse,
      );
      final sales = JournalEntry.fromJson(AdminFakeBackend.salesJournal);
      expect(sales.canCancel, isFalse);
      expect(sales.documentRoute, '/invoices/inv1');
      expect(sales.lines.first.accountLabel, '1100 · Accounts Receivable');
    });
  });

  group('CSV builder', () {
    test('escapes quotes, commas, line breaks and formula prefixes', () {
      expect(csvEscape('plain'), 'plain');
      expect(csvEscape('a,b'), '"a,b"');
      expect(csvEscape('say "hi"'), '"say ""hi"""');
      expect(csvEscape('line\nbreak'), '"line\nbreak"');
      expect(csvValue('=SUM(A1)', CellKind.text), "'=SUM(A1)");
      expect(csvValue(-5, CellKind.money), '-5.00');
      expect(csvValue(-0.001, CellKind.money), '0.00');
      expect(csvValue(12.5, CellKind.qty), '12.5');
      expect(csvValue(3, CellKind.qty), '3');
      expect(csvValue(null, CellKind.money), '');
      expect(
        buildCsv([
          ['a', 'b'],
          ['1', '2'],
        ]),
        'a,b\r\n1,2',
      );
      expect(
        safeFileName('Ledger — Cash in Hand / 2026'),
        'Ledger-Cash-in-Hand-2026',
      );
    });

    test('report exports line up with their columns', () {
      final exports = [
        trialBalanceExport(
          TrialBalance.fromJson(AdminFakeBackend.trialBalance),
        ),
        profitLossExport(ProfitLoss.fromJson(AdminFakeBackend.profitLoss)),
        balanceSheetExport(
          BalanceSheet.fromJson(AdminFakeBackend.balanceSheet),
        ),
        registerExport(
          Register.fromJson(AdminFakeBackend.purchaseRegister),
          purchase: true,
          period: 'Oct',
        ),
        registerExport(
          Register.fromJson(AdminFakeBackend.salesRegister),
          purchase: false,
          period: 'Oct',
          location: 'Head Office',
        ),
        gstSummaryExport(GstSummary.fromJson(AdminFakeBackend.gstSummary)),
        stockValuationExport(
          StockValuation.fromJson(AdminFakeBackend.stockValuation),
        ),
        ageingExport(
          Ageing.fromJson(AdminFakeBackend.ageing),
          AgeingType.receivables,
        ),
      ];
      for (final e in exports) {
        for (final row in [...e.rows, ?e.totals]) {
          expect(row, hasLength(e.columns.length), reason: e.title);
        }
        final lines = e.toCsv().split('\r\n');
        expect(
          lines.first.split(',').length,
          e.columns.length,
          reason: e.title,
        );
      }
      final pl = exports[1].toCsv();
      expect(pl, contains('Gross profit,,Gross profit,29776.10'));
      expect(pl, endsWith('Net profit,,Net loss,-15224.04'));
      final sales = exports[4];
      expect(sales.subtitle, 'Oct · Head Office');
      expect(sales.toCsv(), contains('Cancelled'));
      expect(exports[5].totals![1], 'Credit carried forward');
      expect(exports[7].columns.first.label, 'Customer');
    });

    test('ledger PDF and report PDF build', () async {
      final e = gstSummaryExport(
        GstSummary.fromJson(AdminFakeBackend.gstSummary),
      );
      final bytes = await buildReportPdf(
        e,
        companyName: 'Demo Builders & Traders',
      );
      expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
      final empty = await buildReportPdf(
        const ReportExport(
          title: 'Empty',
          columns: [ExportColumn('A')],
          rows: [],
        ),
      );
      expect(empty.length, greaterThan(500));
      expect(pdfValue(1234567.5, CellKind.money), '12,34,567.50');
    });
  });

  group('periods', () {
    test('financial year boundaries', () {
      expect(financialYearStart(DateTime(2026, 10, 21)), DateTime(2026, 4, 1));
      expect(financialYearStart(DateTime(2027, 3, 31)), DateTime(2026, 4, 1));
      expect(financialYearLabel(DateTime(2027, 1, 5)), 'FY 2026-27');
      final today = DateTime(2026, 10, 21);
      expect(DateRange.fyToDate(today).apiFrom, '2026-04-01');
      expect(
        RangePreset.lastMonth.resolve(today),
        DateRange(DateTime(2026, 9, 1), DateTime(2026, 9, 30)),
      );
      expect(
        RangePreset.thisQuarter.resolve(today).from,
        DateTime(2026, 10, 1),
      );
      expect(
        RangePreset.lastFy.resolve(today),
        DateRange(DateTime(2025, 4, 1), DateTime(2026, 3, 31)),
      );
      expect(AsOfPreset.endOfLastFy.resolve(today), DateTime(2026, 3, 31));
      expect(
        DateRange(DateTime(2026, 5, 2), DateTime(2026, 5, 1)).from,
        DateTime(2026, 5, 1),
      );
      expect(DateRange.fyToDate(today).label, '01 Apr 2026 – 21 Oct 2026');
    });
  });

  group('report catalog', () {
    test('paths sit under their section and follow permissions', () {
      expect(reportInfo('trial-balance').path, '/financials/trial-balance');
      expect(reportInfo('gst-summary').path, '/reports/gst-summary');
      final auditorish = PermissionSet({Perm.reportsView, Perm.accountsView});
      expect(
        visibleReports(auditorish).map((r) => r.name),
        isNot(contains('stock-valuation')),
      );
      expect(visibleReports(PermissionSet.none), isEmpty);
    });
  });

  group('settings models', () {
    final company = Company.fromJson(AdminFakeBackend.company);

    test(
      'company patch sends only changes, clears with null, upper-cases codes',
      () {
        final values = companyFormValues(company)
          ..['website'] = ''
          ..['bankIfsc'] = 'hdfc0009999'
          ..['phone'] = ' 079-4000-1234 ';
        expect(companyPatch(company, values), {
          'website': null,
          'bankIfsc': 'HDFC0009999',
        });
        expect(companyPatch(company, companyFormValues(company)), isEmpty);
      },
    );

    test('Indian identifiers', () {
      expect(validatePan('aaacd1234f'), isNull);
      expect(validatePan('AAAC1234F'), isNotNull);
      expect(validateIfsc('HDFC0001234'), isNull);
      expect(validateIfsc('HDFC1001234'), isNotNull);
      expect(validateUpi('demo@hdfcbank'), isNull);
      expect(validateUpi('demo'), isNotNull);
      expect(validateBankAccount('12345'), isNotNull);
      expect(panFromGstin('24AAACD1234F1Z5'), 'AAACD1234F');
    });

    test('permission grouping and role bodies', () {
      final defs = AdminFakeBackend.permissionDefs
          .map(PermissionDef.fromJson)
          .toList();
      final modules = groupPermissions(defs);
      expect(modules.keys.first, 'Dashboard');
      expect(modules['Invoices'], hasLength(3));
      expect(moduleSelection(modules['Invoices']!, {'invoices.view'}), isNull);
      expect(moduleSelection(modules['Invoices']!, {}), isFalse);
      final clerk = Role.fromJson(AdminFakeBackend.clerkRole);
      final same = RoleInput(
        name: clerk.name,
        permissions: clerk.permissions.toSet(),
      );
      expect(same.toPatchJson(clerk), isEmpty);
      final more = RoleInput(
        name: 'Billing',
        description: 'Invoices',
        permissions: {...clerk.permissions, 'invoices.cancel'},
      );
      expect(more.toPatchJson(clerk).keys, [
        'name',
        'description',
        'permissions',
      ]);
      expect(
        copyName('Owner', ['Owner', 'Copy of Owner']),
        'Copy of Owner (2)',
      );
    });

    test('user patch sends role and locations together', () {
      final u = UserRow.fromJson(AdminFakeBackend.userRow);
      expect(
        userPatch(
          u,
          name: u.name,
          phone: null,
          isActive: true,
          roleId: 'r2',
          locationIds: ['l2'],
        ),
        isEmpty,
      );
      expect(
        userPatch(
          u,
          name: u.name,
          phone: '98',
          isActive: false,
          roleId: 'r2',
          locationIds: null,
        ),
        {'phone': '98', 'isActive': false, 'roleId': 'r2', 'locationIds': null},
      );
    });
  });
}
