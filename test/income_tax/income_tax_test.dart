import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/api_exception.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/features/auth/session.dart';
import 'package:onematrix/features/company/company_model.dart';
import 'package:onematrix/features/compliance/compliance_repository.dart';
import 'package:onematrix/features/compliance/tax_perms.dart';
import 'package:onematrix/features/income_tax/ca_check_screen.dart';
import 'package:onematrix/features/income_tax/it_models.dart';
import 'package:onematrix/features/income_tax/it_repository.dart';
import 'package:onematrix/features/income_tax/itr_pack_screen.dart';
import 'package:onematrix/features/income_tax/tax_calculators_screen.dart';
import 'package:onematrix/features/income_tax/tax_payments_screen.dart';
import 'package:onematrix/features/income_tax/tds_file_screen.dart';
import 'package:onematrix/features/settings/company_profile_screen.dart';

const _calc = {
  'taxable': 1000000,
  'slabs': [
    {'from': 0, 'to': 400000, 'rate': 0, 'tax': 0},
    {'from': 400000, 'to': null, 'rate': 10, 'tax': 60000},
  ],
  'baseTax': 60000,
  'rebate': 0,
  'surcharge': 0,
  'cess': 2400,
  'total': 62400,
};

class FakeTax implements IncomeTaxRepository {
  bool caNeeded = true;
  int txtCalls = 0;

  @override
  Future<List<TaxPayment>> payments(String taxYear) async => [
    TaxPayment.fromJson({
      'id': 't1',
      'number': 'TAX-0001',
      'kind': 'advance_tax',
      'taxYear': '2026-27',
      'date': '2026-09-15',
      'amount': 25000,
      'bsrCode': '0510308',
      'challanSerial': '00123',
      'paidFromAccountName': 'HDFC Bank',
      'status': 'posted',
    }),
  ];

  @override
  Future<RegimeResult> regime(Map<String, dynamic> body) async =>
      RegimeResult.fromJson({
        'taxYear': body['taxYear'],
        'new': _calc,
        'old': {..._calc, 'total': 80000},
        'better': 'new',
        'saving': 17600,
        'unverified': ['Slabs for 2026-27'],
      });

  @override
  Future<ItrPack> itrPack(String taxYear, String form) async =>
      ItrPack.fromJson({
        'taxYear': taxYear,
        'form': form,
        'entity': 'private_company',
        'company': {'name': 'Acme Builders', 'pan': 'ABCDE1234F'},
        'pnl': {
          'netProfit': 500000,
          'lines': [
            {
              'schedule': 'P&L',
              'label': 'Revenue',
              'amount': 900000,
              'accounts': [],
            },
          ],
        },
        'balanceSheet': {'lines': []},
        'depreciation': [],
        'adjustments': [
          {
            'label': 'Book depreciation',
            'amount': 5000,
            'kind': 'add',
            'reason': 'Added back',
          },
        ],
        'tdsCredits': [
          {'deductorName': 'Buyer Ltd', 'tan': null, 'amount': 1200},
        ],
        'taxesPaid': [],
        'incomeEstimate': 495000,
        'steps': ['Open the ITR utility.'],
        'warnings': ['Marginal relief ignored.'],
        'unverified': ['Rates'],
      });

  @override
  Future<CaRequired> caRequired(String taxYear) async => CaRequired.fromJson({
    'taxYear': taxYear,
    'needed': caNeeded,
    'items': [
      {
        'id': 'company_audit',
        'severity': 'required',
        'title': 'Statutory audit',
        'reason': 'Company',
        'law': 'Companies Act',
        'canSelfFile': null,
      },
      {
        'id': 'gst_9c',
        'severity': 'advised',
        'title': 'GSTR-9C review',
        'reason': 'Turnover above Rs 5 crore',
        'law': '',
        'canSelfFile': 'GSTR-9 and the books, not the certification',
      },
    ],
    'figures': {},
  });

  @override
  Future<TdsPrefile> tdsPrefile(String fy, int quarter) async =>
      TdsPrefile.fromJson({
        'canFile': false,
        'checks': [
          {
            'id': 'tan',
            'title': 'TAN set',
            'status': 'fail',
            'detail': 'Add the TAN',
          },
        ],
      });

  @override
  Future<TdsDefaults> tdsDefaults(String fy) async => TdsDefaults.fromJson({
    'fy': fy,
    'deposits': [],
    'statements': [],
    'interest': 0,
    'lateFee': 0,
    'unverified': [],
  });

  @override
  Future<String> tdsStatementTxt(String fy, int quarter) async {
    txtCalls++;
    throw const ApiException(409, 'PREFILE_FAILED', 'Blocked', {
      'checks': [
        {
          'id': 'unchallaned',
          'title': 'Deductions not in a challan',
          'status': 'fail',
          'detail': '3 rows',
        },
      ],
    });
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> pumpIt(
  WidgetTester tester,
  Widget child, {
  FakeTax? repo,
  Size size = const Size(900, 1000),
  double scale = 1,
  Set<String> perms = const {
    TaxPerm.taxView,
    TaxPerm.taxManage,
    TaxPerm.tdsView,
    TaxPerm.tdsManage,
    Perm.companyManage,
  },
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        incomeTaxRepositoryProvider.overrideWithValue(repo ?? FakeTax()),
        permissionsProvider.overrideWithValue(PermissionSet(perms)),
        accountOptionsProvider.overrideWith((ref) async => []),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('regime calculator renders the comparison', (tester) async {
    await pumpIt(tester, const TaxCalculatorsScreen());
    await tester.tap(find.text('Compare'));
    await tester.pumpAndSettle();
    expect(find.text('Better regime'), findsOneWidget);
    expect(find.text('New regime (lower tax)'), findsOneWidget);
    expect(find.text('Unverified'), findsOneWidget);
  });

  testWidgets('ITR pack renders sections and the unverified badge', (
    tester,
  ) async {
    await pumpIt(tester, const ItrPackScreen());
    expect(find.text('Profit and loss'), findsOneWidget);
    expect(find.text('Buyer Ltd'), findsOneWidget);
    expect(find.text('Unverified'), findsOneWidget);
    expect(find.text('Marginal relief ignored.'), findsOneWidget);
    expect(find.text('Print / PDF'), findsOneWidget);
  });

  testWidgets('CA screen words required and self-fileable items', (
    tester,
  ) async {
    await pumpIt(tester, const CaCheckScreen());
    expect(
      find.text('The law requires a chartered accountant for this.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('You can file this yourself. The app covers'),
      findsOneWidget,
    );
  });

  testWidgets('tax payment dialog validates BSR and serial', (tester) async {
    await pumpIt(tester, const TaxPaymentsScreen());
    expect(find.text('TAX-0001'), findsOneWidget);
    await tester.tap(find.text('Record payment'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Amount'),
      '1000',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'BSR code (7 digits)'),
      '123',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Challan serial (5 digits)'),
      '12',
    );
    await tester.tap(find.text('Record payment').last);
    await tester.pumpAndSettle();
    expect(find.text('BSR code must be 7 digits'), findsOneWidget);
    expect(find.text('Challan serial must be 5 digits'), findsOneWidget);
    expect(find.text('Choose cash or bank'), findsOneWidget);
  });

  testWidgets('TDS pack shows PREFILE_FAILED blockers on download', (
    tester,
  ) async {
    final repo = FakeTax();
    await pumpIt(
      tester,
      const TdsFileScreen(fy: '2026-27', quarter: 2),
      repo: repo,
    );
    expect(find.text('TAN set'), findsOneWidget);
    expect(find.text('BETA'), findsOneWidget);
    expect(find.textContaining('Validate it with the FVU'), findsOneWidget);
    final dl = find.text('Copy .txt file');
    await tester.ensureVisible(dl);
    await tester.tap(dl);
    await tester.pumpAndSettle();
    expect(repo.txtCalls, 1);
    expect(find.text('Deductions not in a challan'), findsOneWidget);
  });

  testWidgets('company profile validates the responsible person', (
    tester,
  ) async {
    await pumpIt(
      tester,
      const CompanyProfileForm(
        company: Company(id: 'c1', name: 'Acme', stateCode: '27'),
      ),
      size: const Size(900, 3000),
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'PAN (optional)').last,
      'bad',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Mobile (optional)').last,
      '123',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email (optional)').last,
      'nope',
    );
    final save = find.text('Save changes');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid PAN (ABCDE1234F)'), findsOneWidget);
    expect(find.text('Enter a valid 10-digit mobile'), findsOneWidget);
    // Empty optional values pass.
    await tester.enterText(
      find.widgetWithText(TextFormField, 'PAN (optional)').last,
      '',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Mobile (optional)').last,
      '',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Email (optional)').last,
      '',
    );
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('Enter a valid PAN (ABCDE1234F)'), findsNothing);
    expect(find.text('Enter a valid 10-digit mobile'), findsNothing);
  });

  testWidgets('income-tax screens fit 320 px at text scale 1.3', (
    tester,
  ) async {
    final failures = <String>[];
    final orig = FlutterError.onError;
    FlutterError.onError = (d) {
      failures.add(d.toString().split('\n').take(12).join('\n'));
    };
    final screens = <String, Widget>{
      'payments': const TaxPaymentsScreen(),
      'calculators': const TaxCalculatorsScreen(),
      'advance tax': const TaxCalculatorsScreen(initialTab: 2),
      'itr pack': const ItrPackScreen(),
      'ca check': const CaCheckScreen(),
      'tds file': const TdsFileScreen(fy: '2026-27', quarter: 1),
    };
    for (final e in screens.entries) {
      await pumpIt(tester, e.value, size: const Size(320, 640), scale: 1.3);
      tester.takeException();
      if (failures.isNotEmpty) failures.add('^^ ${e.key}');
    }
    FlutterError.onError = orig;
    expect(failures, isEmpty);
  });
}
