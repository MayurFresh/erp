import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/features/company/company_model.dart';
import 'package:progen_erp/features/invoices/invoice_model.dart';
import 'package:progen_erp/features/invoices/invoice_pdf.dart';
import 'package:progen_erp/features/parties/party_model.dart';

import '../support/fake_backend.dart';

void main() {
  final company = Company.fromJson(FakeBackend.company);
  final invoice = Invoice.fromJson(FakeBackend.invoiceDetail);
  final party = Party.fromJson(FakeBackend.customer);

  void expectPdf(Uint8List bytes) {
    expect(bytes.length, greaterThan(1000));
    expect(latin1.decode(bytes.sublist(0, 5)), '%PDF-');
  }

  test('builds an A4 tax invoice', () async {
    expectPdf(await buildInvoicePdf(invoice, company, party: party));
  });

  test('builds for cancelled, intra-state, many-line invoices', () async {
    final lines = [
      for (var i = 0; i < 60; i++)
        {
          ...FakeBackend.line,
          'id': 'l$i',
          'gstRate': i.isEven ? 18 : 5,
          'cgst': 10.5,
          'sgst': 10.5,
          'igst': 0,
        },
    ];
    final cancelled = Invoice.fromJson({
      ...FakeBackend.invoiceDetail,
      'status': 'cancelled',
      'supplyType': 'intra',
      'placeOfSupply': '29',
      'lines': lines,
    });
    expectPdf(await buildInvoicePdf(cancelled, company));
  });

  test('copes with a bare company and text outside Latin-1', () async {
    const bare = Company(
      id: 'c1',
      name: 'देसी Traders — ₹ “Best”',
      stateCode: '',
    );
    final odd = Invoice.fromJson({
      ...FakeBackend.invoiceRow,
      'partyName': 'ग्राहक — Site A',
      'dueDate': null,
      'amountPaid': null,
      'amountDue': null,
      'notes': null,
      'lines': [
        {...FakeBackend.line, 'description': 'Cement – 50 kg • grade 53'},
      ],
    });
    expectPdf(await buildInvoicePdf(odd, bare));
  });

  test('file name and share text', () {
    expect(invoiceFileName(invoice), 'INV-26-27-00001.pdf');
    final text = invoiceShareText(invoice, companyName: 'Demo Builders');
    expect(text, contains('Invoice INV/26-27/00001 from Demo Builders'));
    expect(text, contains('Total: ₹1,021.00'));
    expect(text, contains('Amount due: ₹521.00 by 20 Nov 2026'));
    final uri = whatsAppShareUri(text);
    expect(uri.host, 'wa.me');
    expect(uri.path, '/');
    expect(uri.queryParameters['text'], text);

    final paid = Invoice.fromJson({...FakeBackend.invoiceRow, 'amountDue': 0});
    expect(invoiceShareText(paid, companyName: 'X'), contains('Paid in full'));
  });
}
