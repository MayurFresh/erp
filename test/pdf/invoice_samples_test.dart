import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/pdf_brand.dart';
import 'package:progen_erp/core/pdf_fonts.dart';
import 'package:progen_erp/features/company/company_model.dart';
import 'package:progen_erp/features/invoices/invoice_model.dart';
import 'package:progen_erp/features/invoices/invoice_pdf.dart';
import 'package:progen_erp/features/parties/party_model.dart';

import '../support/fake_backend.dart';

/// Builds invoice samples with the real font. Set SAMPLE_DIR to also write
/// the PDFs to disk for a visual check, SAMPLE_LOGO for a logo image.
void main() {
  final out = Platform.environment['SAMPLE_DIR'];
  final logoPath = Platform.environment['SAMPLE_LOGO'];
  final company = Company.fromJson({
    ...FakeBackend.company,
    'brandColor': '#1E5AA0',
    'address': '14 Industrial Estate, Andheri East, Mumbai',
    'bankName': 'HDFC Bank',
    'bankAccountNo': '50100123456789',
    'bankIfsc': 'HDFC0001234',
    'upiId': 'progen@hdfcbank',
    'invoiceTerms': 'Payment within 30 days. Interest at 18% p.a. on late payment.',
  });
  final party = Party.fromJson(FakeBackend.customer);

  void expectPdf(Uint8List bytes) {
    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
  }

  testWidgets('invoice samples', (tester) async {
    await tester.runAsync(() async {
      final theme = await pdfTheme();
      final logo = logoPath == null ? null : File(logoPath).readAsBytesSync();
      final brand = pdfBrandFor(company, logo: logo);
      final base = Invoice.fromJson(FakeBackend.invoiceDetail);
      final many = Invoice.fromJson({
        ...FakeBackend.invoiceDetail,
        'lines': [
          for (var i = 0; i < 120; i++)
            {
              ...FakeBackend.line,
              'id': 'l$i',
              'hsnCode': i % 3 == 0 ? '2523' : (i % 3 == 1 ? '7214' : null),
              'description': i % 17 == 0
                  ? 'Long description line $i: Portland cement 53 grade, '
                        'ordinary, packed in 50 kg HDPE bags with batch '
                        'certificate and delivery to the site store room'
                  : 'Item $i',
              'gstRate': i.isEven ? 18 : 5,
            },
        ],
      });
      final bare = Invoice.fromJson({
        ...FakeBackend.invoiceDetail,
        'notes': null,
        'dueDate': null,
        'partyGstin': null,
      });
      const bareCompany = Company(id: 'c', name: 'Bare Co', stateCode: '27');
      for (final (name, inv, co) in [
        ('invoice', base, company),
        ('invoice_many', many, company),
        ('invoice_bare', bare, bareCompany),
      ]) {
        final bytes = await buildInvoicePdf(
          inv,
          co,
          party: party,
          theme: theme,
          brand: co == company ? brand : null,
        );
        expectPdf(bytes);
        if (out != null) File('$out/$name.pdf').writeAsBytesSync(bytes);
      }
    });
  });
}
