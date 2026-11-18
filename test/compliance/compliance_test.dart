import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/features/compliance/alerts_card.dart';
import 'package:onematrix/features/compliance/compliance_models.dart';
import 'package:onematrix/features/compliance/compliance_repository.dart';
import 'package:onematrix/features/compliance/compliance_widgets.dart';
import 'package:onematrix/features/compliance/gst_returns_screen.dart';
import 'package:onematrix/features/compliance/itc_ageing_screen.dart';
import 'package:onematrix/features/compliance/setup_health_screen.dart';

const _rates = [
  {'rate': 18, 'taxable': 1000, 'igst': 0, 'cgst': 90, 'sgst': 90},
];

final gstr1Json = <String, dynamic>{
  'period': '2026-09',
  'gstin': '27AAAPM1234C1Z5',
  'filing': 'monthly',
  'b2b': [
    {
      'invoiceId': 'i1',
      'number': 'INV/26-27/00001',
      'date': '2026-09-03',
      'partyName': 'Acme',
      'gstin': '27AAACA1234A1Z5',
      'placeOfSupply': '27',
      'invoiceValue': 1180,
      'rates': _rates,
    },
  ],
  'b2cl': [],
  'b2cs': [
    {
      'placeOfSupply': '27',
      'supplyType': 'intra',
      'rate': 18,
      'taxable': 500,
      'igst': 0,
      'cgst': 45,
      'sgst': 45,
    },
  ],
  'cdnr': [],
  'cdnur': [],
  'nil': {'interRegistered': 0, 'intraRegistered': 10},
  'hsn': [],
  'docs': [
    {'kind': 'invoice', 'from': 'A1', 'to': 'A9', 'total': 9, 'cancelled': 1},
  ],
  'totals': {'taxable': 1500, 'igst': 0, 'cgst': 135, 'sgst': 135},
  'ledger': {'igst': 0, 'cgst': 90, 'sgst': 90},
  'variance': {'igst': 0, 'cgst': 45, 'sgst': 45},
  'warnings': ['One invoice has no HSN'],
};

const gstr3bJson = <String, dynamic>{
  'period': '2026-09',
  'outward': {'taxable': 1500, 'igst': 0, 'cgst': 135, 'sgst': 135},
  'zeroNil': {'taxable': 10},
  'inwardRcm': {'taxable': 100, 'igst': 0, 'cgst': 9, 'sgst': 9},
  'interStateUnregistered': [
    {'placeOfSupply': '29', 'taxable': 200, 'igst': 36},
  ],
  'itc': {
    'rcm': {'taxable': 0, 'igst': 0, 'cgst': 9, 'sgst': 9},
    'others': {'taxable': 0, 'igst': 0, 'cgst': 50, 'sgst': 50},
    'reversed': {'taxable': 0, 'igst': 0, 'cgst': 0, 'sgst': 0},
    'net': {'taxable': 0, 'igst': 0, 'cgst': 59, 'sgst': 59},
  },
  'payable': {'igst': 0, 'cgst': 85, 'sgst': 85},
  'rcmCash': {'igst': 0, 'cgst': 9, 'sgst': 9},
  'warnings': <String>[],
};

const itcJson = <String, dynamic>{
  'asOf': '2026-10-29',
  'rows': [
    {
      'purchaseId': 'p1',
      'number': 'PUR/26-27/00001',
      'partyName': 'Vendor A',
      'billDate': '2026-05-10',
      'day180': '2026-11-06',
      'daysLeft': 8,
      'total': 1180,
      'unpaid': 1180,
      'itc': 180,
      'reversal': 180,
      'status': 'warn',
    },
  ],
  'totals': {'unpaid': 1180, 'itc': 180, 'reversal': 180},
};

class FakeRepo implements ComplianceRepository {
  FakeRepo({this.alertList = const [], this.failAlerts = false});

  final List<Alert> alertList;
  final bool failAlerts;

  @override
  Future<Gstr1> gstr1(String period) async => Gstr1.fromJson(gstr1Json);

  @override
  Future<Gstr3b> gstr3b(String period) async => Gstr3b.fromJson(gstr3bJson);

  @override
  Future<ItcAgeing> itcAgeing() async => ItcAgeing.fromJson(itcJson);

  @override
  Future<SetupHealth> health() async => SetupHealth.fromJson({
    'score': 67,
    'checks': [
      {
        'key': 'gstin',
        'ok': false,
        'severity': 'required',
        'title': 'Company GSTIN',
        'detail': 'Missing',
        'link': '/company',
      },
      {
        'key': 'loc',
        'ok': true,
        'severity': 'required',
        'title': 'One location',
        'detail': '',
        'link': '/locations',
      },
    ],
  });

  @override
  Future<List<Alert>> alerts() async {
    if (failAlerts) throw Exception('403');
    return alertList;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

Future<void> pump(
  WidgetTester tester,
  Widget child,
  Size size, {
  FakeRepo? repo,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      retry: (_, _) => null,
      overrides: [
        complianceRepositoryProvider.overrideWithValue(repo ?? FakeRepo()),
      ],
      child: MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const widths = [Size(390, 844), Size(768, 1024), Size(1280, 800)];

void main() {
  group('models', () {
    test('fyOf uses the API format and matches recentFys', () {
      expect(fyOf(DateTime(2027, 1, 5)), '2026-27');
      expect(fyOf(DateTime(2026, 4, 1)), '2026-27');
      expect(fyOf(DateTime(2026, 3, 31)), '2025-26');
      expect(
        recentFys(DateTime(2026, 10, 30)).first,
        fyOf(DateTime(2026, 10, 30)),
      );
    });
    test('Gstr1.fromJson', () {
      final g = Gstr1.fromJson(gstr1Json);
      expect(g.sections.map((s) => s.count), [1, 0, 1, 0, 0]);
      expect(g.sections.first.total.taxable, 1000);
      expect(g.sections.first.rows.single.value, 1180);
      expect(g.totals.cgst, 135);
      expect(g.hasVariance, isTrue);
      expect(g.docs.single.cancelled, 1);
      expect(g.nil['intraRegistered'], 10);
      expect(g.warnings, ['One invoice has no HSN']);
    });

    test('Gstr3b.fromJson', () {
      final g = Gstr3b.fromJson(gstr3bJson);
      expect(g.zeroNil, 10);
      expect(g.interState.single.igst, 36);
      expect(g.itcNet.cgst, 59);
      expect(g.payable.sgst, 85);
      expect(g.rcmCash.tax, 18);
    });

    test('ReconRow.fromJson', () {
      final r = ReconRow.fromJson({
        'id': null,
        'status': 'missing_in_2b',
        'supplierGstin': '27AAA',
        'docNo': 'X1',
        'taxable': 100,
        'igst': 18,
        'imsAction': 'none',
        'book': {'taxable': 100, 'igst': 18, 'cgst': 0, 'sgst': 0},
        'diff': null,
      });
      expect(r.id, isNull);
      expect(r.status, ReconStatus.missingIn2b);
      expect(r.tax.igst, 18);
      expect(r.book?.taxable, 100);
      expect(r.diff, isNull);
      expect(ReconStatus.parse('matched'), ReconStatus.matched);
    });

    test('BankLine.fromJson', () {
      final l = BankLine.fromJson({
        'id': 'l1',
        'lineNo': 2,
        'date': '2026-10-01',
        'description': 'NEFT',
        'reference': null,
        'withdrawal': 0,
        'deposit': 500,
        'balance': 1500,
        'status': 'matched',
        'match': {
          'journalLineId': 'j1',
          'number': 'RCT/1',
          'voucherType': 'receipt',
          'amount': 500,
        },
      });
      expect(l.isDeposit, isTrue);
      expect(l.amount, 500);
      expect(l.match?.number, 'RCT/1');
      expect(BankLine.fromJson({'id': 'x'}).status, 'unmatched');
    });

    test('Alert and ComplianceDoc', () {
      final a = Alert.fromJson({
        'kind': 'gstr1_due',
        'severity': 'overdue',
        'title': 'GSTR-1 due',
        'detail': '',
        'dueDate': '2026-11-11',
        'link': '/gst-returns',
      });
      expect(a.severity, 'overdue');
      expect(a.link, '/gst-returns');
      final d = ComplianceDoc.fromJson({
        'id': 'd1',
        'name': 'Shop licence',
        'category': 'licence',
        'expiryDate': '2026-11-18',
        'remindDays': 30,
        'status': 'expiring',
        'daysLeft': 20,
      });
      expect(d.daysLeft, 20);
      expect(d.status, 'expiring');
      expect(ComplianceDoc.fromJson({'id': 'n'}).daysLeft, isNull);
    });

    test('BankStatement difference', () {
      final s = BankStatement.fromJson({
        'id': 's',
        'closingBalance': 1000,
        'bookBalance': 900,
        'lines': [
          {'id': 'l1', 'status': 'unmatched'},
        ],
      });
      expect(s.difference, 100);
      expect(s.lineRows, hasLength(1));
      expect(s.lines, 1);
    });
  });

  group('screens', () {
    for (final size in widths) {
      testWidgets('ITC ageing at ${size.width}', (tester) async {
        await pump(tester, const ItcAgeingScreen(), size);
        expect(find.textContaining('PUR/26-27/00001'), findsOneWidget);
        expect(find.text('8 days left'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });

      testWidgets('GST returns at ${size.width}', (tester) async {
        await pump(tester, const GstReturnsScreen(), Size(size.width, 3000));
        expect(find.text('Variance against the ledger'), findsOneWidget);
        expect(find.text('B2B invoices'), findsOneWidget);
        await tester.tap(find.text('GSTR-3B'));
        await tester.pumpAndSettle();
        expect(find.textContaining('3.1 Outward'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('setup health shows score and checks', (tester) async {
      await pump(tester, const SetupHealthScreen(), widths[0]);
      expect(find.text('67%'), findsOneWidget);
      expect(find.text('Company GSTIN'), findsOneWidget);
    });

    testWidgets('alerts card hides on error and empty', (tester) async {
      await pump(
        tester,
        const AlertsCard(),
        widths[0],
        repo: FakeRepo(failAlerts: true),
      );
      expect(find.text('Alerts'), findsNothing);
      await pump(tester, const AlertsCard(), widths[0], repo: FakeRepo());
      expect(find.text('Alerts'), findsNothing);
    });

    testWidgets('alerts card lists alerts', (tester) async {
      final repo = FakeRepo(
        alertList: [
          Alert.fromJson({
            'kind': 'doc_expiry',
            'severity': 'warn',
            'title': 'Shop licence expires',
            'detail': '20 days',
            'dueDate': '2026-11-18',
            'link': '/compliance-docs',
          }),
        ],
      );
      await pump(tester, const AlertsCard(), widths[0], repo: repo);
      expect(find.text('Alerts'), findsOneWidget);
      expect(find.text('Shop licence expires'), findsOneWidget);
    });
  });
}
