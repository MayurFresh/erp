import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/tds_forms/cert_pdf.dart';
import 'package:onematrix/features/tds_forms/tds_forms_widgets.dart';

Map<String, dynamic> salarySnap() => {
  'form': 'Form 130',
  'periodLabel': 'Tax year 2026-27',
  'notice': 'Working copy.',
  'unconfirmed': true,
  'deductor': {'name': 'Forms Test', 'tan': 'MUMP12345E', 'pan': 'AAACF1234C'},
  'employee': {'name': 'Asha Patil', 'pan': 'ABCDE1234F'},
  'partA': {
    'quarters': [
      {'quarter': 1, 'deducted': 37701, 'deposited': 12567},
    ],
    'deposits': [
      {
        'month': '2026-04',
        'bsrCode': '0510308',
        'challanSerial': '00123',
        'depositDate': '2026-05-05',
        'tds': 12567,
      },
    ],
    'totalDeducted': 37701,
    'totalDeposited': 12567,
  },
  'partB': {
    'regime': 'new',
    'grossSalary': 1800000,
    'totalIncome': 1725000,
    'netTaxPayable': 150800,
    'tdsTotal': 150800,
    'balance': 0,
    'chapterVIA': [],
  },
};

void main() {
  test('certificate PDF builds for salary and non-salary snapshots', () async {
    final bytes = await buildCertificatesPdf([
      salarySnap(),
      {
        'form': 'Form 131',
        'quarter': 1,
        'periodLabel': 'Tax year 2026-27',
        'notice': 'Working copy.',
        'deductor': {'name': 'Forms Test'},
        'deductee': {'name': 'Sharma Associates', 'pan': 'ABCDE1234F'},
        'rows': [
          {
            'date': '2026-05-10',
            'section': 's.393(1) Sl. 6(iii)',
            'amountPaid': 100000,
            'rate': 10,
            'tds': 10000,
          },
        ],
        'challans': [],
        'totalDeducted': 10000,
        'totalDeposited': 0,
      },
    ]);
    expect(bytes.length, greaterThan(1000));
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
  });

  test('file names are safe', () {
    expect(certFileName('salary', '2026-27', 'Asha Patil'), 'tds-salary-certificate-2026-27-Asha-Patil.pdf');
    expect(certFileName('non_salary', '2026-27', 'Q1'), 'tds-non-salary-certificate-2026-27-Q1.pdf');
  });

  testWidgets('period bar and check tile fit 320 px', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var q = 1;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              PeriodBar(fy: '2026-27', onFy: (_) {}, quarter: q, onQuarter: (v) => q = v),
              const CheckTile(
                check: {'title': 'Deductor TAN', 'status': 'fail', 'detail': 'Company TAN is missing.'},
              ),
              const UnconfirmedBadge(),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Fix'), findsOneWidget);
    expect(find.text('Unconfirmed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
