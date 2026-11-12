import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:progen_erp/core/pdf_brand.dart';
import 'package:progen_erp/core/pdf_fonts.dart';
import 'package:progen_erp/features/accounts/account_model.dart';
import 'package:progen_erp/features/company/company_model.dart';
import 'package:progen_erp/features/credit_notes/credit_note_model.dart';
import 'package:progen_erp/features/credit_notes/credit_note_pdf.dart';
import 'package:progen_erp/features/parties/party_model.dart';
import 'package:progen_erp/features/parties/statement_pdf.dart';
import 'package:progen_erp/features/payments/payment_model.dart';
import 'package:progen_erp/features/payments/payment_pdf.dart';
import 'package:progen_erp/features/purchase_orders/po_models.dart';
import 'package:progen_erp/features/purchase_orders/po_pdf.dart';
import 'package:progen_erp/features/reports/report_export.dart';
import 'package:progen_erp/features/reports/report_pdf.dart';
import 'package:progen_erp/features/sales_orders/sales_order_models.dart';
import 'package:progen_erp/features/sales_orders/sales_order_pdf.dart';

import '../support/fake_backend.dart';

/// Every document PDF builds with the real font. Set SAMPLE_DIR to write the
/// files for a visual check and SAMPLE_LOGO for a logo image.
void main() {
  final out = Platform.environment['SAMPLE_DIR'];
  final logoPath = Platform.environment['SAMPLE_LOGO'];
  final company = Company.fromJson({
    ...FakeBackend.company,
    'brandColor': '#1E5AA0',
    'address': '14 Industrial Estate, Andheri East, Mumbai',
  });
  final party = Party.fromJson(FakeBackend.customer);
  final line = {...FakeBackend.line};

  testWidgets('document PDFs build', (tester) async {
    await tester.runAsync(() async {
      final theme = await pdfTheme();
      final logo = logoPath == null ? null : File(logoPath).readAsBytesSync();
      final brand = pdfBrandFor(company, logo: logo);
      final files = <String, Uint8List>{};

      files['credit_note'] = await buildCreditNotePdf(
        CreditNote.fromJson({
          'invoiceNumber': 'INV/26-27/00001',
          'partyName': 'Mumbai Infra Projects LLP',
          'number': 'CN/26-27/00001',
          'noteDate': '2026-10-23',
          'reason': 'Damaged in transit',
          'placeOfSupply': '27',
          'supplyType': 'inter',
          'status': 'posted',
          'subtotal': 798,
          'igst': 223.44,
          'taxTotal': 223.44,
          'total': 1021,
          'lines': [line],
        }),
        company,
        party: party,
        theme: theme,
        brand: brand,
      );
      files['receipt'] = await buildPaymentPdf(
        Payment.fromJson({
          'kind': 'receipt',
          'number': 'RCT/26-27/00001',
          'date': '2026-10-22',
          'partyName': 'Mumbai Infra Projects LLP',
          'accountName': 'HDFC Current',
          'mode': 'upi',
          'reference': 'UTR 2026102212345',
          'amount': 5000,
          'allocated': 3000,
          'unallocated': 2000,
          'status': 'posted',
          'allocations': [
            {
              'docType': 'invoice',
              'docNumber': 'INV/26-27/00001',
              'docDate': '2026-10-21',
              'docTotal': 3000,
              'amount': 3000,
            },
          ],
        }),
        company,
        theme: theme,
        brand: brand,
      );
      files['po'] = await buildPurchaseOrderPdf(
        PurchaseOrder.fromJson({
          'number': 'PO/26-27/00004',
          'status': 'approved',
          'partyName': 'Shree Cement Traders',
          'locationName': 'Head Office',
          'orderDate': '2026-10-21',
          'expectedDate': '2026-10-30',
          'placeOfSupply': '29',
          'supplyType': 'intra',
          'subtotal': 798,
          'cgst': 111.72,
          'sgst': 111.72,
          'taxTotal': 223.44,
          'total': 1021,
          'notes': 'Deliver to gate 2 before noon.',
          'lines': [
            {
              'itemName': 'Portland Cement',
              'description': 'Portland Cement 53 Grade 50kg',
              'hsnCode': '2523',
              'qty': 20,
              'unit': 'bag',
              'rate': 420,
              'gstRate': 28,
              'lineTotal': 1021,
            },
          ],
        }),
        company,
        theme: theme,
        brand: brand,
      );
      files['quotation'] = await buildSalesOrderPdf(
        SalesOrder.fromJson({
          'id': 's1',
          'number': 'SO/26-27/00007',
          'status': 'draft',
          'partyName': 'Mumbai Infra Projects LLP',
          'locationName': 'Head Office',
          'orderDate': '2026-10-21',
          'placeOfSupply': '27',
          'subtotal': 8400,
          'taxTotal': 2352,
          'total': 10752,
          'lines': [
            {
              'id': 'l1',
              'itemName': 'Portland Cement',
              'description': 'Portland Cement 53 Grade 50kg',
              'unit': 'bag',
              'qtyOrdered': 20,
              'rate': 420,
              'gstRate': 28,
            },
          ],
        }),
        company,
        party: party,
        theme: theme,
        brand: brand,
      );
      files['statement'] = await buildStatementPdf(
        party,
        Ledger.fromJson({
          'accountName': 'Mumbai Infra Projects LLP',
          'from': '2026-04-01',
          'to': '2026-10-31',
          'openingBalance': 12000,
          'closingBalance': 15500,
          'totalDebit': 10000,
          'totalCredit': 6500,
          'lines': [
            for (var i = 0; i < 80; i++)
              {
                'entryId': 'e$i',
                'date': '2026-05-${(i % 28 + 1).toString().padLeft(2, '0')}',
                'voucherType': i.isEven ? 'sales' : 'receipt',
                'number': 'DOC/$i',
                'narration': 'Entry $i',
                'debit': i.isEven ? 125 : 0,
                'credit': i.isEven ? 0 : 81.25,
                'balance': 12000 + i * 43.75,
              },
          ],
        }),
        company,
        theme: theme,
        brand: brand,
      );
      files['report'] = await buildReportPdf(
        const ReportExport(
          title: 'Sales register',
          subtitle: '01 Apr 2026 - 31 Oct 2026',
          columns: [
            ExportColumn('Date'),
            ExportColumn('Invoice'),
            ExportColumn('Customer'),
            ExportColumn('Amount', CellKind.money),
          ],
          rows: [
            ['2026-10-21', 'INV/1', 'Mumbai Infra Projects LLP', 12345.5],
            ['2026-10-22', 'INV/2', 'Shree Traders', 99000],
          ],
          totals: ['', '', 'Total', 111345.5],
        ),
        companyName: company.name,
        theme: theme,
        brand: brand,
      );
      for (final e in files.entries) {
        expect(latin1.decode(e.value.sublist(0, 5)), '%PDF-', reason: e.key);
        if (out != null) File('$out/${e.key}.pdf').writeAsBytesSync(e.value);
      }
    });
  });
}
