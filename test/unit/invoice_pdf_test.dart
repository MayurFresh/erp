import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/pdf_fonts.dart';
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

  testWidgets('embeds the bundled Noto Sans so ₹ prints', (tester) async {
    final theme = await tester.runAsync(pdfTheme);
    expect(theme, isNotNull);
    final bytes = (await tester.runAsync(
      () => buildInvoicePdf(invoice, company, party: party, theme: theme),
    ))!;
    expectPdf(bytes);
    expect(latin1.decode(bytes, allowInvalid: true), contains('NotoSans'));
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

  group('e-invoice block', () {
    const einv = {
      'irn': 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9',
      'ackNo': '112010012345678',
      'ackDate': '2026-10-21T10:15:00.000Z',
      'signedQrCode': 'eyJhbGciOiJSUzI1NiJ9.payload.signature',
      'status': 'active',
      'sandbox': false,
    };
    const ewb = {
      'ewbNo': '331001234567',
      'ewbDate': '2026-10-21T11:00:00.000Z',
      'validUntil': '2026-10-23T23:59:00.000Z',
      'status': 'active',
    };

    test('parses einvoice and ewaybill', () {
      final inv = Invoice.fromJson({
        ...FakeBackend.invoiceDetail,
        'einvoice': einv,
        'ewaybill': ewb,
      });
      expect(inv.hasActiveIrn, isTrue);
      expect(inv.einvoice!.ackNo, '112010012345678');
      expect(inv.ewaybill!.ewbNo, '331001234567');
      expect(invoice.hasActiveIrn, isFalse);
    });

    test('renders an IRN block with QR and e-way bill', () async {
      final inv = Invoice.fromJson({
        ...FakeBackend.invoiceDetail,
        'einvoice': einv,
        'ewaybill': ewb,
      });
      final plain = await buildInvoicePdf(invoice, company, party: party);
      final withIrn = await buildInvoicePdf(inv, company, party: party);
      expectPdf(withIrn);
      expect(withIrn.length, greaterThan(plain.length));
    });

    test('renders the sandbox marker', () async {
      final inv = Invoice.fromJson({
        ...FakeBackend.invoiceDetail,
        'einvoice': {...einv, 'sandbox': true},
      });
      expectPdf(await buildInvoicePdf(inv, company, party: party));
    });

    testWidgets('renders with the Unicode theme', (tester) async {
      final theme = await tester.runAsync(pdfTheme);
      final inv = Invoice.fromJson({
        ...FakeBackend.invoiceDetail,
        'einvoice': {...einv, 'sandbox': true},
        'ewaybill': ewb,
      });
      final bytes = (await tester.runAsync(
        () => buildInvoicePdf(inv, company, party: party, theme: theme),
      ))!;
      expectPdf(bytes);
    });

    test('cancelled IRN prints no block', () async {
      final inv = Invoice.fromJson({
        ...FakeBackend.invoiceDetail,
        'einvoice': {...einv, 'status': 'cancelled'},
      });
      expect(inv.hasActiveIrn, isFalse);
      expectPdf(await buildInvoicePdf(inv, company, party: party));
    });
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
