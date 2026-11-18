import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/pdf_kit.dart';
import 'package:onematrix/core/pdf_fonts.dart';
import 'package:onematrix/features/insights/analytics_models.dart';
import 'package:onematrix/features/insights/insights_rules.dart';
import 'package:onematrix/features/reports/client_report/client_report_model.dart';
import 'package:onematrix/features/reports/client_report/client_report_pdf.dart';
import 'package:onematrix/features/reports/report_models.dart';

import '../support/fake_backend.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const stock = [
    StockValuationRow(
      itemId: '1',
      name: 'Steel rod 12mm',
      unit: 'kg',
      qty: 1200,
      avgCost: 62,
      value: 74400,
    ),
    StockValuationRow(
      itemId: '2',
      name: 'Cement 50kg',
      unit: 'bag',
      qty: 300,
      avgCost: 380,
      value: 114000,
    ),
  ];

  Future<ClientReportInput> input(
    Set<ReportSection> s, {
    Analytics? analytics,
    List<StockValuationRow> stockRows = stock,
  }) async {
    final a = analytics ?? Analytics.fromJson(FakeBackend.analytics);
    return ClientReportInput(
      brand: PdfBrand(
        companyName: 'Demo Traders Pvt Ltd',
        colorHex: '#0B6157',
        idLine: 'GSTIN 27ABCDE1234F1Z5',
        contactLine: 'accounts@demotraders.in',
      ),
      theme: await pdfTheme(),
      analytics: a,
      sections: s,
      takeaways: buildTakeaways(a),
      periodLabel: '01 Apr 2026 to 21 Oct 2026',
      generatedOn: '21 Oct 2026',
      recipient: 'Acme Industries',
      preparedBy: 'Finance team',
      notes: 'Collections improved after the August follow-up.',
      stockRows: stockRows,
      stockTotal: stockRows.isEmpty ? null : 188400,
    );
  }

  for (final slides in [false, true]) {
    test('builds ${slides ? 'slides' : 'report'}', () async {
      final bytes = await buildClientReportPdf(
        await input(ReportSection.values.toSet()),
        slides: slides,
      );
      expect(bytes.length, greaterThan(5000));
      final dir = Platform.environment['SAMPLE_DIR'];
      if (dir != null) {
        File(
          '$dir/client_${slides ? 'slides' : 'report'}.pdf',
        ).writeAsBytesSync(bytes);
      }
    });
  }

  test('builds with a single section', () async {
    final bytes = await buildClientReportPdf(
      await input({ReportSection.summary}),
      slides: false,
    );
    expect(bytes.length, greaterThan(2000));
  });

  void sample(String name, List<int> bytes) {
    final dir = Platform.environment['SAMPLE_DIR'];
    if (dir != null) File('$dir/$name.pdf').writeAsBytesSync(bytes);
  }

  for (final slides in [false, true]) {
    final kind = slides ? 'slides' : 'report';

    test('$kind for one month draws its charts', () async {
      final json = Map<String, dynamic>.of(FakeBackend.analytics);
      json['trend'] = (json['trend'] as List).sublist(2);
      json['cashFlow'] = (json['cashFlow'] as List).sublist(1);
      final bytes = await buildClientReportPdf(
        await input(
          ReportSection.values.toSet(),
          analytics: Analytics.fromJson(json),
        ),
        slides: slides,
      );
      expect(bytes.length, greaterThan(5000));
      sample('client_month_$kind', bytes);
    });

    test('$kind with no months, stock or projects still builds', () async {
      final json = Map<String, dynamic>.of(FakeBackend.analytics);
      json['trend'] = const [];
      json['cashFlow'] = null;
      final bytes = await buildClientReportPdf(
        await input(
          ReportSection.values.toSet(),
          analytics: Analytics.fromJson(json),
          stockRows: const [],
        ),
        slides: slides,
      );
      expect(bytes.length, greaterThan(2000));
      sample('client_empty_$kind', bytes);
    });

    test('$kind with a long stock list runs over pages', () async {
      final bytes = await buildClientReportPdf(
        await input(
          ReportSection.values.toSet(),
          stockRows: [
            for (var k = 0; k < 200; k++)
              StockValuationRow(
                itemId: '$k',
                name: 'Long item name $k, ' * 6,
                unit: 'kg',
                qty: 10,
                avgCost: 10,
                value: 100.0 + k,
              ),
          ],
        ),
        slides: slides,
      );
      expect(bytes.length, greaterThan(5000));
      sample('client_long_$kind', bytes);
    });
  }
}
