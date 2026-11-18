import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/api_exception.dart';
import 'package:onematrix/core/permissions.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/features/auth/session.dart';
import 'package:onematrix/features/compliance/compliance_repository.dart';
import 'package:onematrix/features/filings/filing_models.dart';
import 'package:onematrix/features/filings/filing_screens.dart';
import 'package:onematrix/features/filings/filing_widgets.dart';
import 'package:onematrix/features/filings/filings_repository.dart';
import 'package:onematrix/features/filings/needs_you_card.dart';
import 'package:onematrix/features/gst_filing/gst_filing_models.dart';
import 'package:onematrix/features/gst_filing/gst_filing_repository.dart';
import 'package:onematrix/features/gst_filing/gst_filing_screen.dart';
import 'package:onematrix/features/gst_filing/gstr9_screen.dart';
import 'package:onematrix/features/gst_filing/itc_reversals_screen.dart';
import 'package:onematrix/features/gst_filing/ledger_payments.dart';
import 'package:onematrix/features/gst_filing/setoff_view.dart';
import 'package:onematrix/features/gst_filing/worksheet_view.dart';

const _heads0 = {'igst': 0, 'cgst': 0, 'sgst': 0, 'cess': 0};

final setoffJson = <String, dynamic>{
  'period': '2026-09',
  'igstSplit': 'cgst_first',
  'liability': {'igst': 40, 'cgst': 50, 'sgst': 30, 'cess': 0},
  'rcm': _heads0,
  'credit': {
    'opening': {'igst': 100, 'cgst': 0, 'sgst': 0, 'cess': 0},
    'itc': _heads0,
    'total': {'igst': 100, 'cgst': 0, 'sgst': 0, 'cess': 0},
  },
  'matrix': [
    {'from': 'igst', 'to': 'igst', 'amount': 40},
    {'from': 'igst', 'to': 'cgst', 'amount': 50},
    {'from': 'igst', 'to': 'sgst', 'amount': 10},
  ],
  'creditUsed': {'igst': 100, 'cgst': 0, 'sgst': 0, 'cess': 0},
  'creditCarryForward': _heads0,
  'cash': {
    'tax': {'igst': 0, 'cgst': 0, 'sgst': 20, 'cess': 0},
    'interest': 0,
    'lateFee': 0,
    'total': 20,
  },
  'cashBalance': {'books': 0, 'portal': null},
  'shortfall': {
    'igst': 0,
    'cgst': 0,
    'sgst': 20,
    'cess': 0,
    'interest': 0,
    'lateFee': 0,
    'total': 20,
  },
  'pmt06': {
    'amounts': {
      'igst': 0,
      'cgst': 0,
      'sgst': 20,
      'cess': 0,
      'interest': 0,
      'lateFee': 0,
    },
    'steps': ['Open Payments on the portal'],
  },
  'late': {'dueDate': '2026-10-20', 'daysLate': 0, 'interest': 0, 'lateFee': 0},
  'unverified': ['lateFeeCap'],
};

const _tax = {'taxable': 1000, 'igst': 0, 'cgst': 135, 'sgst': 135};

final sheetJson = <String, dynamic>{
  'period': '2026-09',
  'outward': _tax,
  'zeroRated': {'taxable': 0, 'igst': 0, 'cgst': 0, 'sgst': 0},
  'zeroNil': {'taxable': 10},
  'nonGst': {'taxable': 0},
  'inwardRcm': {'taxable': 100, 'igst': 0, 'cgst': 9, 'sgst': 9},
  'interStateUnregistered': [
    {'placeOfSupply': '29', 'taxable': 200, 'igst': 36},
  ],
  'inwardExempt': {'inter': 5, 'intra': 6},
  'itc': {
    'rcm': {'taxable': 0, 'igst': 0, 'cgst': 9, 'sgst': 9},
    'others': {'taxable': 0, 'igst': 0, 'cgst': 50, 'sgst': 50},
    'reversed': {
      'rule42_43': {'taxable': 0, 'igst': 0, 'cgst': 0, 'sgst': 0},
      'rule37': {'taxable': 0, 'igst': 0, 'cgst': 1, 'sgst': 1},
    },
    'reclaimed': {'taxable': 0, 'igst': 0, 'cgst': 0, 'sgst': 0},
    'net': {'taxable': 0, 'igst': 0, 'cgst': 58, 'sgst': 58},
    'others2b': null,
  },
  'payableNoCross': {'igst': 0, 'cgst': 77, 'sgst': 77},
  'filing': null,
  'warnings': <String>[],
  'unverified': <String>[],
};

final gstr9Json = <String, dynamic>{
  'fy': '2026-27',
  'gstin': '27AAAPM1234C1Z5',
  'turnover': 25000000,
  'mandatory': true,
  'needs9c': false,
  'tables': {
    't4': {
      'b2b': _tax,
      'b2c': _tax,
      'creditNotes': _tax,
      'rcm': _tax,
      'net': _tax,
    },
    't5': {'nilExempt': 10, 'nonGst': 0},
    't6': {'others': _tax, 'rcm': _tax},
    't7': {'rule37': _tax, 'rule42_43': _tax},
    't8': {'itcIn3b': _tax, 'itcIn2b': null, 'difference': null},
    't9': {'payable': _heads0, 'paidCredit': _heads0, 'paidCash': _heads0},
    't10_13': {'note': 'Fill from amendments'},
    't17': [
      {
        'hsnCode': '9983',
        'description': 'Service',
        'taxable': 1,
        'igst': 0,
        'cgst': 0,
        'sgst': 0,
      },
    ],
    't18': [],
  },
  'monthly': [
    {
      'period': '2026-04',
      'gstr1': _tax,
      'gstr3b': _tax,
      'gstr1Filed': true,
      'gstr3bFiled': false,
    },
  ],
  'warnings': ['April 3B not filed'],
  'unverified': <String>[],
};

class FakeGst extends Fake implements GstFilingRepository {
  @override
  Future<PrefileResult> prefile(String period, String returnType) async =>
      PrefileResult.fromJson({
        'period': period,
        'return': returnType,
        'canFile': true,
        'checks': [
          {
            'id': 'sequence',
            'title': 'Previous return filed',
            'status': 'pass',
            'detail': '',
            'count': null,
            'link': null,
          },
          {
            'id': 'ims_pending',
            'title': 'IMS pending',
            'status': 'warn',
            'detail': '3 lines',
            'count': 3,
            'link': '/gst-2b',
          },
        ],
      });

  @override
  Future<String> gstr1Gstn(String period) async => '{"fp":"092026"}';

  @override
  Future<Gstr3bSheet> gstr3b(String period) async =>
      Gstr3bSheet.fromJson(sheetJson);

  @override
  Future<Setoff> setoff(String period, String igstSplit) async =>
      Setoff.fromJson({...setoffJson, 'igstSplit': igstSplit});

  @override
  Future<List<LedgerSnapshot>> ledgerBalances() async => [
    LedgerSnapshot.fromJson({
      'id': 'l1',
      'ledger': 'credit',
      'asOf': '2026-09-30',
      'igst': 100,
      'cgst': 0,
      'sgst': 0,
      'cess': 0,
      'note': 'portal',
    }),
  ];

  @override
  Future<List<GstPayment>> payments(String fy) async => [
    GstPayment.fromJson({
      'id': 'g1',
      'number': 'GPM/26-27/00001',
      'date': '2026-09-20',
      'period': '2026-09',
      'cpin': '',
      'cin': 'CIN1',
      'paidFromAccountName': 'HDFC',
      'igst': 0,
      'cgst': 0,
      'sgst': 20,
      'cess': 0,
      'interest': 0,
      'lateFee': 0,
      'total': 20,
      'status': 'posted',
    }),
  ];

  @override
  Future<ItcReversals> itcReversals(String period) async =>
      ItcReversals.fromJson({
        'period': period,
        'rows': [
          {
            'number': 'PUR/26-27/00001',
            'partyName': 'A very long supplier name private limited',
            'supplierGstin': '27AAACA1234A1Z5',
            'billDate': '2026-03-01',
            'day180': '2026-08-28',
            'kind': 'reversal',
            'base': 1000,
            'igst': 0,
            'cgst': 9,
            'sgst': 9,
          },
        ],
        'totals': {
          'reversal': {'taxable': 0, 'igst': 0, 'cgst': 9, 'sgst': 9},
          'reclaim': {'taxable': 0, 'igst': 0, 'cgst': 0, 'sgst': 0},
        },
      });

  @override
  Future<Gstr9Pack> gstr9(String fy) async => Gstr9Pack.fromJson(gstr9Json);
}

class FakeFilings extends Fake implements FilingsRepository {
  FakeFilings({this.errors = const [], this.rows = const []});

  /// Thrown one per `create` call, in order.
  final List<ApiException> errors;
  final List<FilingCalendarRow> rows;
  final bodies = <Map<String, dynamic>>[];

  @override
  Future<Filing> create(Map<String, dynamic> body) async {
    bodies.add(body);
    if (bodies.length <= errors.length) throw errors[bodies.length - 1];
    return Filing.fromJson({
      'id': 'f1',
      'returnType': body['returnType'],
      'period': body['period'],
      'status': 'filed',
      'filedOn': body['filedOn'],
    });
  }

  @override
  Future<List<FilingCalendarRow>> calendar(String fy) async => rows;

  @override
  Future<List<Filing>> list({String? returnType, String? fy}) async => [
    Filing.fromJson({
      'id': 'f1',
      'returnType': 'gstr3b',
      'period': '2026-08',
      'status': 'filed',
      'filedOn': '2026-09-20',
      'arn': 'AA270926000001A',
      'amountPaid': 1234,
      'createdBy': {'id': 'u', 'name': 'Owner'},
    }),
  ];
}

class FakeCompliance extends Fake implements ComplianceRepository {
  @override
  Future<List<AccountOption>> accounts() async => const [
    AccountOption(id: 'a1', code: '1010', name: 'HDFC', subtype: 'bank'),
  ];
}

ApiException _prefileFailed() =>
    const ApiException(409, 'PREFILE_FAILED', 'Checks failed', {
      'checks': [
        {
          'id': 'gstr1_filed',
          'title': 'GSTR-1 filed',
          'status': 'fail',
          'detail': 'Not filed',
          'count': null,
          'link': null,
        },
      ],
    });

/// Pumps a few frames; a [BusyButton] awaiting a dialog keeps spinning, so
/// `pumpAndSettle` would never return.
Future<void> tick(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> pump(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(800, 900),
  FakeFilings? filings,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        gstFilingRepositoryProvider.overrideWithValue(FakeGst()),
        filingsRepositoryProvider.overrideWithValue(filings ?? FakeFilings()),
        complianceRepositoryProvider.overrideWithValue(FakeCompliance()),
        permissionsProvider.overrideWithValue(
          const PermissionSet({'gst.view', 'gst.manage', 'compliance.view'}),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Button that opens [open] with a `WidgetRef`; the result goes to [out].
class _Host extends ConsumerWidget {
  const _Host(this.open, this.out);

  final Future<Object?> Function(BuildContext, WidgetRef) open;
  final List<Object?> out;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Center(
    child: ElevatedButton(
      onPressed: () async => out.add(await open(context, ref)),
      child: const Text('open'),
    ),
  );
}

FilingCalendarRow _row(
  String type,
  String status, {
  String period = '2026-09',
}) => FilingCalendarRow.fromJson({
  'returnType': type,
  'period': period,
  'label': '${returnTypeLabel(type)} $period',
  'dueDate': '2026-10-20',
  'status': status,
  'filingId': null,
  'daysLate': status == 'overdue' ? 9 : null,
  'estimate': null,
});

void main() {
  test('models parse the contract', () {
    final s = Setoff.fromJson(setoffJson);
    expect(s.matrix.length, 3);
    expect(s.cashTax.sgst, 20);
    expect(s.shortfallTotal, 20);
    expect(s.unverified, ['lateFeeCap']);
    final f = Filing.fromJson({
      'id': 'x',
      'returnType': 'gstr1',
      'period': '2026-09',
      'status': 'cancelled',
      'filedOn': '2026-10-01',
      'acknowledgedFailures': [
        {
          'id': 'a',
          'title': 'T',
          'status': 'fail',
          'detail': '',
          'count': 2,
          'link': '/x',
        },
      ],
    });
    expect(f.cancelled, isTrue);
    expect(f.acknowledgedFailures.single.count, 2);
    expect(Gstr3bSheet.fromJson(sheetJson).rule37.cgst, 1);
  });

  testWidgets('set-off view renders the matrix and PMT-06 amounts', (
    tester,
  ) async {
    String? split;
    await pump(
      tester,
      SingleChildScrollView(
        child: SetoffView(
          setoff: Setoff.fromJson(setoffJson),
          split: 'cgst_first',
          onSplit: (v) => split = v,
        ),
      ),
    );
    expect(find.text('Credit utilisation matrix'), findsOneWidget);
    expect(find.text('40.00'), findsWidgets);
    expect(find.text('50.00'), findsWidgets);
    expect(find.text('10.00'), findsWidgets);
    expect(find.text('PMT-06 amounts'), findsOneWidget);
    expect(find.textContaining('Cash shortfall'), findsOneWidget);
    expect(find.text('Unverified'), findsOneWidget);
    await tester.tap(find.text('SGST first'));
    expect(split, 'sgst_first');
  });

  testWidgets('mark filed: PREFILE_FAILED then acknowledgeFailures', (
    tester,
  ) async {
    final filings = FakeFilings(errors: [_prefileFailed()]);
    final out = <Object?>[];
    await pump(
      tester,
      _Host(
        (c, r) => showMarkFiledDialog(
          c,
          r,
          returnType: 'gstr3b',
          period: '2026-09',
          extra: const {'postSetoff': true},
        ),
        out,
      ),
      filings: filings,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'ARN'), 'AA1');
    await tester.tap(find.text('Mark filed'));
    await tick(tester);
    expect(find.text('Record anyway?'), findsOneWidget);
    expect(find.text('GSTR-1 filed'), findsOneWidget);
    await tester.tap(find.text('Record anyway'));
    await tick(tester);
    expect(filings.bodies.length, 2);
    expect(filings.bodies[0].containsKey('acknowledgeFailures'), isFalse);
    expect(filings.bodies[1]['acknowledgeFailures'], isTrue);
    expect(filings.bodies[1]['postSetoff'], isTrue);
    expect(filings.bodies[1]['arn'], 'AA1');
    expect((out.single as Filing).returnType, 'gstr3b');
  });

  testWidgets('mark filed: ALREADY_FILED shows a clear message', (
    tester,
  ) async {
    final filings = FakeFilings(
      errors: [const ApiException(409, 'ALREADY_FILED', 'x')],
    );
    final out = <Object?>[];
    await pump(
      tester,
      _Host(
        (c, r) =>
            showMarkFiledDialog(c, r, returnType: 'gstr1', period: '2026-09'),
        out,
      ),
      filings: filings,
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mark filed'));
    await tick(tester);
    expect(find.text('Already filed'), findsOneWidget);
    expect(
      find.textContaining('Cancel it in the filing register'),
      findsOneWidget,
    );
    expect(filings.bodies.length, 1);
  });

  testWidgets('3B filing: CASH_SHORTFALL offers a PMT-06 payment', (
    tester,
  ) async {
    final filings = FakeFilings(
      errors: [
        const ApiException(409, 'CASH_SHORTFALL', 'short', {
          'shortfall': {
            'igst': 0,
            'cgst': 0,
            'sgst': 20,
            'cess': 0,
            'interest': 1,
            'lateFee': 0,
          },
        }),
      ],
    );
    await pump(
      tester,
      const GstFilingScreen(period: '2026-09'),
      filings: filings,
    );
    await tester.ensureVisible(find.text('5 File 3B'));
    await tester.tap(find.text('5 File 3B'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Mark GSTR-3B filed'));
    await tick(tester);
    await tester.tap(find.text('Mark filed'));
    await tick(tester);
    expect(filings.bodies.single['postSetoff'], isTrue);
    expect(filings.bodies.single['igstSplit'], 'cgst_first');
    expect(find.text('Cash ledger is short'), findsOneWidget);
    expect(find.text('Shortfall ₹21.00'), findsOneWidget);
    await tester.tap(find.text('Record payment'));
    await tick(tester);
    expect(find.text('Record PMT-06 payment'), findsOneWidget);
  });

  testWidgets('worksheet: tick a row and tap a figure to copy', (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final sheet = Gstr3bSheet.fromJson(sheetJson);
    await pump(
      tester,
      SingleChildScrollView(
        child: WorksheetView(sheet: sheet, setoff: Setoff.fromJson(setoffJson)),
      ),
    );
    expect(find.textContaining('0 of'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tick-0')));
    await tester.pump();
    expect(find.textContaining('1 of'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('tick-0')));
    await tester.pump();
    expect(find.textContaining('0 of'), findsOneWidget);
    await tester.tap(find.textContaining('135.00', findRichText: true).first);
    await tester.pump();
    expect(copied, '135.00');
    final rows = worksheetRows(sheet, null).map((r) => r.code).toList();
    expect(rows.take(6), [
      '3.1(a)',
      '3.1(b)',
      '3.1(c)',
      '3.1(d)',
      '3.1(e)',
      '3.2',
    ]);
    expect(
      rows,
      containsAllInOrder([
        '4A(3)',
        '4A(5)',
        '4B(1)',
        '4B(2)',
        '4C',
        '4D(1)',
        '5',
      ]),
    );
  });

  group('NeedsYouCard', () {
    testWidgets('lists due and overdue rows only', (tester) async {
      await pump(
        tester,
        const NeedsYouCard(),
        filings: FakeFilings(
          rows: [
            _row('gstr1', 'overdue', period: '2026-08'),
            _row('gstr3b', 'due'),
            _row('pmt06', 'filed'),
            _row('gstr9', 'upcoming', period: '2026-27'),
          ],
        ),
      );
      expect(find.text('Needs you'), findsOneWidget);
      expect(find.text('GSTR-1 2026-08'), findsOneWidget);
      expect(find.text('GSTR-3B 2026-09'), findsOneWidget);
      expect(find.textContaining('9 days late'), findsOneWidget);
      expect(find.text('PMT-06 2026-09'), findsNothing);
      expect(find.text('GSTR-9 2026-27'), findsNothing);
    });

    testWidgets('hidden when nothing is due', (tester) async {
      await pump(
        tester,
        const NeedsYouCard(),
        filings: FakeFilings(rows: [_row('gstr1', 'filed')]),
      );
      expect(find.text('Needs you'), findsNothing);
    });
  });

  testWidgets('filing register lists filings', (tester) async {
    await pump(tester, const FilingRegisterScreen());
    expect(find.text('Filing register'), findsOneWidget);
    expect(find.text('AA270926000001A'), findsOneWidget);
  });

  group('320 px, text scale 1.3', () {
    final screens = <String, Widget Function()>{
      'filing register': () => const FilingRegisterScreen(),
      'filing calendar': () => const FilingCalendarScreen(),
      'itc reversals': () => const ItcReversalsScreen(),
      'gstr9': () => const Gstr9Screen(fy: '2026-27'),
      'ledger section': () => const SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: LedgerSnapshotSection(canManage: true),
        ),
      ),
      'payments section': () => const SingleChildScrollView(
        child: GstPaymentsSection(fy: '2026-27', canManage: true),
      ),
      'needs you': () => const NeedsYouCard(),
    };
    for (final e in screens.entries) {
      testWidgets(e.key, (tester) async {
        await pump(
          tester,
          e.value(),
          size: const Size(320, 640),
          textScale: 1.3,
          filings: FakeFilings(rows: [_row('gstr1', 'overdue')]),
        );
        expect(tester.takeException(), isNull);
      });
    }

    for (final tab in [
      '1 Checks',
      '2 GSTR-1',
      '3 Ledgers & set-off',
      '4 GSTR-3B sheet',
      '5 File 3B',
    ]) {
      testWidgets('wizard $tab', (tester) async {
        await pump(
          tester,
          const GstFilingScreen(period: '2026-09'),
          size: const Size(320, 640),
          textScale: 1.3,
        );
        await tester.ensureVisible(find.text(tab));
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('dialogs', (tester) async {
      final out = <Object?>[];
      await pump(
        tester,
        _Host(
          (c, r) => showMarkFiledDialog(
            c,
            r,
            returnType: 'gstr3b',
            period: '2026-09',
          ),
          out,
        ),
        size: const Size(320, 640),
        textScale: 1.3,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      await pump(
        tester,
        _Host(
          (c, r) => showGstPaymentDialog(
            c,
            r,
            period: '2026-09',
            prefill: Setoff.fromJson(setoffJson).pmt06,
          ),
          out,
        ),
        size: const Size(320, 640),
        textScale: 1.3,
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
