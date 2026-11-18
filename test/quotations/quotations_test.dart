import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/company/company_model.dart';
import 'package:onematrix/features/quotations/quotation_detail_screen.dart';
import 'package:onematrix/features/quotations/quotation_form_screen.dart';
import 'package:onematrix/features/quotations/quotation_models.dart';
import 'package:onematrix/features/quotations/quotation_pdf.dart';
import 'package:onematrix/features/quotations/quotation_routes.dart';
import 'package:onematrix/features/quotations/quotations_screen.dart';

import 'quotation_fixtures.dart';

void main() {
  test('models parse the contract JSON', () {
    final q = Quotation.fromJson(
      qJson(
        status: 'sent',
        kind: 'proforma',
        expired: true,
        lines: [qLine(discountAmount: 25)],
      ),
    );
    expect(q.isProforma, isTrue);
    expect(q.number, 'PI/26-27/0001');
    expect(q.statusWord, 'expired');
    expect(q.total, 590);
    expect(q.taxSplit.cgst, 45);
    expect(q.lines.single.discountAmount, 25);
    expect(q.createdByName, 'Rita');
    expect(q.canConvert, isTrue);
    expect(Quotation.fromJson(qJson(status: 'draft')).statusWord, 'draft');
    final r = ConvertResult.fromJson({
      'quotation': qJson(status: 'converted'),
      'salesOrderId': 'so1',
      'invoiceId': null,
    });
    expect(r.salesOrderId, 'so1');
    expect(r.quotation.canConvert, isFalse);
  });

  test('input body carries fixed discounts and the deal', () {
    final body = QuotationInput(
      kind: 'proforma',
      locationId: 'l1',
      partyId: 'p1',
      dealId: 'd1',
      lines: const [
        QuotationLineInput(itemId: 'i1', qty: 2, rate: 100, discountAmount: 20),
        QuotationLineInput(itemId: 'i2', qty: 1, discountPct: 10),
      ],
    ).toJson();
    expect(body['dealId'], 'd1');
    final lines = body['lines']! as List;
    expect((lines[0] as Map)['discountAmount'], 20);
    expect((lines[0] as Map).containsKey('discountPct'), isFalse);
    expect((lines[1] as Map)['discountPct'], 10);
  });

  test('routes and nav entry', () {
    expect(quotationNavEntry.path, '/quotations');
    expect(quotationNavEntry.label, 'Quotations');
    expect(quotationRoutes(), hasLength(4));
  });

  test('PDF builds for a quotation and a proforma', () async {
    const company = Company(id: 'c1', name: 'OneMatrix Traders', stateCode: '29');
    for (final kind in ['quotation', 'proforma']) {
      final bytes = await buildQuotationPdf(
        Quotation.fromJson(qJson(kind: kind)),
        company,
      );
      expect(bytes.length, greaterThan(500));
    }
  });

  for (final size in [narrow, wide]) {
    final tag = '${size.width.toInt()}px';

    testWidgets('list renders, shows expired word, filters at $tag', (
      tester,
    ) async {
      final b = FakeControlsBackend()
        ..on(
          'GET /quotations',
          pageOf([
            qJson(status: 'sent', expired: true),
            qJson(id: 'q2', status: 'accepted', kind: 'proforma'),
          ]),
        );
      await pumpRouted(tester, const QuotationsScreen(), b, size: size);
      expect(find.text('QTN/26-27/0001'), findsOneWidget);
      expect(find.text('Expired'), findsWidgets);
      expect(find.text('Accepted'), findsWidgets);
      expect(find.text('New quotation'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byType(DropdownButtonFormField<String?>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Accepted').last);
      await tester.pumpAndSettle();
      expect(
        b.last('GET', '/quotations')!.queryParameters['status'],
        'accepted',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('list scoped to a customer sends partyId at $tag', (
      tester,
    ) async {
      final b = FakeControlsBackend()..on('GET /quotations', pageOf([]));
      await pumpRouted(
        tester,
        const QuotationsScreen(partyId: 'p1'),
        b,
        size: size,
      );
      expect(b.last('GET', '/quotations')!.queryParameters['partyId'], 'p1');
      expect(
        find.textContaining('Create your first quotation'),
        findsOneWidget,
      );
    });

    testWidgets('detail renders lines, totals and terms at $tag', (
      tester,
    ) async {
      final b = FakeControlsBackend()
        ..on('GET /quotations/q1', qJson(status: 'sent'));
      await pumpRouted(
        tester,
        const QuotationDetailScreen(quotationId: 'q1'),
        b,
        size: size,
      );
      expect(find.text('QTN/26-27/0001'), findsOneWidget);
      expect(find.text('Brake pad'), findsOneWidget);
      expect(find.text('CGST'), findsOneWidget);
      expect(find.text('Payment within 30 days'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('form renders at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /locations', pageOf([headOffice]))
        ..on('GET /quotations/q1', qJson())
        ..on('GET /parties/p1/contacts', {
          'data': [contactJson()],
        });
      await pumpRouted(
        tester,
        const QuotationFormScreen(quotationId: 'q1'),
        b,
        size: size,
      );
      expect(find.text('Edit QTN/26-27/0001'), findsOneWidget);
      expect(find.text('Quote date'), findsOneWidget);
      expect(find.text('Valid until'), findsOneWidget);
      expect(find.textContaining('Brake pad'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('form posts kind, deal, fixed discount and default validity', (
    tester,
  ) async {
    final b = FakeControlsBackend()
      ..on('GET /locations', pageOf([headOffice]))
      ..on('GET /parties/p1', {
        'id': 'p1',
        'companyId': 'c1',
        'name': 'Acme Traders',
        'type': 'customer',
      })
      ..on('GET /parties/p1/contacts', {
        'data': [contactJson()],
      })
      ..on('GET /items', pageOf([cementItem]))
      ..on('POST /quotations', qJson(id: 'q9'), status: 201);
    final visited = await pumpRouted(
      tester,
      const QuotationFormScreen(partyId: 'p1', dealId: 'd1'),
      b,
    );
    expect(find.text('Acme Traders'), findsOneWidget);

    await tester.tap(find.text('Proforma invoice'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Location'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Head Office').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add item'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Portland Cement'));
    await tester.pumpAndSettle();

    // Switch the discount to a fixed amount and type 20.
    await tester.tap(find.byTooltip('Switch to fixed amount'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Discount amount'),
      '20',
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();

    final req = b.last('POST', '/quotations')!;
    final body = req.data as Map;
    expect(body['kind'], 'proforma');
    expect(body['partyId'], 'p1');
    expect(body['dealId'], 'd1');
    expect(body['locationId'], 'l1');
    final quote = DateTime.parse(body['quoteDate'] as String);
    final valid = DateTime.parse(body['validUntil'] as String);
    expect(valid.difference(quote).inDays, 15);
    final line = (body['lines'] as List).single as Map;
    expect(line['itemId'], 'i1');
    expect(line['qty'], 1);
    expect(line['rate'], 420);
    expect(line['discountAmount'], 20);
    expect(line.containsKey('discountPct'), isFalse);
    expect(visited.last, '/quotations/q9');
  });

  group('detail actions', () {
    Future<FakeControlsBackend> open(
      WidgetTester tester,
      Map<String, Object?> q, {
      Set<String> permissions = qtnPerms,
      Size size = wide,
    }) async {
      final b = FakeControlsBackend()..on('GET /quotations/q1', q);
      await pumpRouted(
        tester,
        const QuotationDetailScreen(quotationId: 'q1'),
        b,
        size: size,
        permissions: permissions,
      );
      return b;
    }

    Finder action(String label) => find.widgetWithText(OutlinedButton, label);

    testWidgets('draft offers Send, Edit, Cancel and conversion', (
      tester,
    ) async {
      await open(tester, qJson());
      for (final label in [
        'Send',
        'Edit',
        'Cancel',
        'Convert to sales order',
        'Convert to invoice',
      ]) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Decline'), findsNothing);
    });

    testWidgets('sent offers Accept, Decline and Revise', (tester) async {
      await open(tester, qJson(status: 'sent'));
      for (final label in ['Accept', 'Decline', 'Revise', 'Edit']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Send'), findsNothing);
    });

    testWidgets('declined shows its reason and only Revise', (tester) async {
      await open(
        tester,
        qJson(status: 'declined', declineReason: 'Price too high'),
      );
      expect(find.text('Price too high'), findsOneWidget);
      expect(find.text('Revise'), findsOneWidget);
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Convert to invoice'), findsNothing);
    });

    testWidgets('converted links to its documents', (tester) async {
      await open(tester, qJson(status: 'converted', salesOrderId: 'so1'));
      expect(find.text('Open sales order'), findsOneWidget);
      expect(find.text('Cancel'), findsNothing);
      expect(find.text('Edit'), findsNothing);
    });

    testWidgets('permissions hide actions', (tester) async {
      await open(
        tester,
        qJson(status: 'sent'),
        permissions: {
          'quotations.view',
          'quotations.manage',
          'invoices.create',
        },
      );
      expect(find.text('Convert to sales order'), findsNothing);
      expect(find.text('Convert to invoice'), findsOneWidget);

      await open(
        tester,
        qJson(status: 'sent'),
        permissions: {'quotations.view'},
      );
      expect(find.text('Accept'), findsNothing);
      expect(find.text('Convert to invoice'), findsNothing);
      expect(find.text('Print'), findsOneWidget);
    });

    testWidgets('decline asks for a reason and posts it', (tester) async {
      final b = await open(tester, qJson(status: 'sent'));
      b.on('POST /quotations/q1/decline', qJson(status: 'declined'));
      await tester.tap(find.text('Decline'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextFormField), 'Too costly');
      await tester.tap(find.widgetWithText(FilledButton, 'Decline'));
      await tester.pumpAndSettle();
      expect(
        (b.last('POST', '/quotations/q1/decline')!.data as Map)['reason'],
        'Too costly',
      );
    });

    testWidgets('convert to sales order opens the new order', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /quotations/q1', qJson(status: 'accepted'))
        ..on('POST /quotations/q1/convert', {
          'quotation': qJson(status: 'converted', salesOrderId: 'so7'),
          'salesOrderId': 'so7',
          'invoiceId': null,
        });
      final visited = await pumpRouted(
        tester,
        const QuotationDetailScreen(quotationId: 'q1'),
        b,
      );
      await tester.tap(find.text('Convert to sales order'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create order'));
      await tester.pumpAndSettle();
      expect(
        (b.last('POST', '/quotations/q1/convert')!.data as Map)['to'],
        'sales_order',
      );
      expect(visited.last, '/sales-orders/so7');
    });

    testWidgets('NOT_STOCK_ITEMS is explained and offers an invoice', (
      tester,
    ) async {
      var calls = 0;
      final b = FakeControlsBackend()
        ..on('GET /quotations/q1', qJson(status: 'accepted'));
      b.routes['POST /quotations/q1/convert'] = (o) {
        calls++;
        if ((o.data as Map)['to'] == 'sales_order') {
          return (
            409,
            {
              'error': {
                'code': 'NOT_STOCK_ITEMS',
                'message': 'Service items cannot be ordered',
              },
            },
          );
        }
        return (
          200,
          {
            'quotation': qJson(status: 'converted', invoiceId: 'inv3'),
            'salesOrderId': null,
            'invoiceId': 'inv3',
          },
        );
      };
      final visited = await pumpRouted(
        tester,
        const QuotationDetailScreen(quotationId: 'q1'),
        b,
      );
      await tester.tap(find.text('Convert to sales order'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create order'));
      await tester.pumpAndSettle();
      expect(find.text('Cannot make a sales order'), findsOneWidget);
      expect(find.textContaining('service items'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Convert to invoice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create invoice'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(visited.last, '/invoices/inv3');
    });

    testWidgets('Send marks sent then offers the share choices', (
      tester,
    ) async {
      final b = await open(tester, qJson(contactId: 'c1'));
      b.on('POST /quotations/q1/send', qJson(status: 'sent'));
      await tester.tap(find.text('Send'));
      await tester.pumpAndSettle();
      expect(b.last('POST', '/quotations/q1/send'), isNotNull);
      expect(find.text('Share QTN/26-27/0001'), findsOneWidget);
      expect(find.text('Share PDF'), findsOneWidget);
      expect(find.text('WhatsApp message'), findsOneWidget);
    });

    testWidgets('detail has no overflow at 320px with long names', (
      tester,
    ) async {
      final q = qJson(status: 'sent');
      q['partyName'] = 'Very Long Customer Name Industries Private Limited';
      await open(tester, q, size: narrow);
      expect(tester.takeException(), isNull);
      expect(action('x'), findsNothing);
    });
  });

  test('WhatsApp text names number, total and validity', () {
    final text = quotationWhatsAppText(
      companyName: 'OneMatrix',
      quotation: Quotation.fromJson(qJson()),
      contactName: 'Meera',
    );
    expect(text, contains('Hello Meera'));
    expect(text, contains('QTN/26-27/0001'));
    expect(text, contains('Valid until'));
  });
}
