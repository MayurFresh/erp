import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/company/company_model.dart';
import 'package:onematrix/features/export_currency/challan_detail_screen.dart';
import 'package:onematrix/features/export_currency/challan_pdf.dart';
import 'package:onematrix/features/export_currency/challans_screen.dart';
import 'package:onematrix/features/export_currency/currency_screen.dart';
import 'package:onematrix/features/export_currency/export_currency_routes.dart';
import 'package:onematrix/features/export_currency/export_fields_card.dart';
import 'package:onematrix/features/export_currency/export_models.dart';
import 'package:onematrix/features/export_currency/tcs_screen.dart';
import 'package:onematrix/features/invoices/invoice_model.dart';

import '../controls/controls_harness.dart';

const narrow = Size(320, 640);
const wide = Size(1440, 900);

const perms = {
  'challans.view',
  'challans.manage',
  'fx.view',
  'fx.manage',
  'tcs.view',
  'tcs.manage',
  'invoices.create',
  'accounts.view',
};

Map<String, Object?> challanJson({String status = 'open', double pending = 7}) => {
  'id': 'ch1',
  'number': 'DC/26-27/00001',
  'date': '2026-11-10',
  'reason': 'supply_on_approval',
  'reasonNote': null,
  'locationId': 'l1',
  'locationName': 'Warehouse',
  'toLocationId': null,
  'toLocationName': null,
  'partyId': 'p1',
  'consignee': {'name': 'Acme Traders', 'address': 'Surat', 'gstin': '24AAAAA0000A1Z5', 'stateCode': '24'},
  'consignor': {'name': 'OneMatrix Traders', 'gstin': '24BBBBB0000B1Z5', 'stateCode': '24'},
  'vehicleNo': 'GJ01AB1234',
  'transporter': null,
  'ewbNo': null,
  'notes': null,
  'status': status,
  'cancelReason': null,
  'taxableTotal': 1000,
  'taxTotal': 180,
  'lines': [
    {
      'id': 'cl1', 'lineNo': 1, 'itemId': 'i1', 'description': 'Brake pad', 'hsnCode': '8708', 'unit': 'nos',
      'qty': 10, 'provisional': false, 'rate': 100, 'gstRate': 18, 'taxableValue': 1000, 'cgst': 90, 'sgst': 90, 'igst': 0,
      'returnedQty': 3 - (7 - pending), 'invoicedQty': 0, 'pendingQty': pending,
    },
  ],
  'events': <Object?>[],
};

void main() {
  test('models parse the contract JSON', () {
    final c = Challan.fromJson(challanJson());
    expect(c.number, 'DC/26-27/00001');
    expect(c.consigneeName, 'Acme Traders');
    expect(c.lines.single.tax, 180);
    expect(c.canBill, isTrue);
    expect(c.canCancel, isFalse);
    expect(Challan.fromJson({...challanJson(), 'reason': 'job_work'}).canBill, isFalse);
    final e = InvoiceExt.fromJson({
      'category': 'export_lut', 'lutNo': 'AD1', 'currencyCode': 'USD', 'exchangeRate': 80,
      'fcTotal': 236, 'tcsAmount': 0, 'declaration': 'SUPPLY MEANT FOR EXPORT',
    });
    expect(e!.currencyCode, 'USD');
    expect(InvoiceExt.fromJson(null), isNull);
    expect(invoiceExtFacts(e).map((f) => f.$1), contains('LUT number'));
  });

  test('inputs build the request bodies', () {
    final body = const ChallanInput(
      locationId: 'l1',
      reason: 'branch_transfer',
      toLocationId: 'l2',
      lines: [ChallanLineInput(itemId: 'i1', qty: 5, provisional: true)],
    ).toJson();
    expect(body['toLocationId'], 'l2');
    expect((body['lines']! as List).single, {'itemId': 'i1', 'qty': 5.0, 'provisional': true});
    final choice = const ExportChoice(
      category: 'export_lut', shippingBillNo: 'SB1', currencyCode: 'USD', rate: 80, tcsOff: true,
    ).toJson();
    expect((choice['exportInfo']! as Map)['category'], 'export_lut');
    expect((choice['currency']! as Map)['rate'], 80);
    expect((choice['tcs']! as Map)['off'], true);
    expect(const ExportChoice(currencyCode: 'INR').toJson(), isEmpty);
    final draft = const InvoiceDraft(locationId: 'l', partyId: 'p', lines: [], extra: {'currency': {'code': 'USD'}}).toJson();
    expect(draft['currency'], {'code': 'USD'});
  });

  test('routes and nav entries', () {
    expect(exportCurrencyRoutes(), hasLength(6));
    expect(challanNavEntry.path, '/delivery-challans');
    expect(exportCurrencyNavEntries, hasLength(4));
    expect(payablesNavEntry.path, '/fx-payables');
  });

  test('challan PDF builds', () async {
    const company = Company(id: 'c1', name: 'OneMatrix Traders', stateCode: '24');
    final bytes = await buildChallanPdf(Challan.fromJson(challanJson()), company);
    expect(bytes.length, greaterThan(500));
    expect(challanFileName(Challan.fromJson(challanJson())), 'DC-26-27-00001.pdf');
  });

  for (final size in [narrow, wide]) {
    final tag = '${size.width.toInt()}px';

    testWidgets('challan list renders and filters at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /delivery-challans', pageOf([
          {'id': 'ch1', 'number': 'DC/26-27/00001', 'date': '2026-11-10', 'reason': 'job_work', 'consigneeName': 'Acme Traders', 'status': 'partly_closed'},
        ]));
      await pumpControls(tester, const ChallansScreen(), b, size: size, permissions: perms);
      expect(find.text('DC/26-27/00001'), findsOneWidget);
      expect(find.text('Partly closed'), findsWidgets);
      expect(find.text('New challan'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('challan detail shows pending quantity and actions at $tag', (tester) async {
      final b = FakeControlsBackend()..on('GET /delivery-challans/ch1', challanJson());
      await pumpControls(tester, const ChallanDetailScreen(challanId: 'ch1'), b, size: size, permissions: perms);
      expect(find.text('DC/26-27/00001'), findsWidgets);
      expect(find.textContaining('pending 7'), findsOneWidget);
      expect(find.textContaining('Tax for information'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('currency screen lists rates at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /fx/rates', {'data': [{'code': 'USD', 'date': '2026-11-10', 'rate': 83.2, 'note': 'Bank'}]})
        ..on('GET /fx/currencies', {'data': [{'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'decimals': 2, 'isActive': true}]})
        ..on('GET /export/luts', {'data': [{'id': 'u1', 'fy': '2026-27', 'lutNo': 'AD1', 'arn': null, 'validFrom': '2026-04-01', 'validTo': '2027-03-31'}]});
      await pumpControls(tester, const CurrencyScreen(), b, size: size, permissions: perms);
      expect(find.text('USD  83.2'), findsOneWidget);
      expect(find.text('Add rate'), findsOneWidget);
      await tester.tap(find.text('LUT'));
      await tester.pumpAndSettle();
      expect(find.text('2026-27  AD1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TCS screen shows settings, natures and the report at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /export/settings', {'tcsEnabled': false, 'tcsBase': 'taxable'})
        ..on('GET /tcs/natures', {'data': [{'id': 'n1', 'code': 'scrap', 'label': 'Scrap', 'sectionOld': '206C(1)', 'sectionNew': '394(1)', 'rate': 1, 'threshold': 0, 'isActive': true}]})
        ..on('GET /tcs/report', {'data': [{'invoiceId': 'i1', 'number': 'INV/1', 'date': '2026-11-10', 'partyName': 'Acme', 'pan': null, 'section': '206C(1)', 'rate': 5, 'base': 10000, 'tcs': 500}], 'total': 500, 'missingPan': 1});
      await pumpControls(tester, const TcsScreen(), b, size: size, permissions: perms);
      expect(find.text('Scrap', skipOffstage: false), findsOneWidget);
      expect(find.text('1%', skipOffstage: false), findsOneWidget);
      expect(find.textContaining('206C(1H)', skipOffstage: false), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Show report'), 300, scrollable: find.byType(Scrollable).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Show report'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Total collected'), findsOneWidget);
      expect(find.textContaining('without a PAN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('export fields card reports choices at $tag', (tester) async {
      final b = FakeControlsBackend()
        ..on('GET /fx/currencies', {'data': [{'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'decimals': 2, 'isActive': true}]})
        ..on('GET /fx/rates/latest', {'rate': 80, 'date': '2026-11-10', 'note': null});
      ExportChoice? last;
      await pumpControls(
        tester,
        SingleChildScrollView(child: ExportFieldsCard(invoiceDate: '2026-11-12', onChanged: (c) => last = c)),
        b,
        size: size,
        permissions: perms,
      );
      expect(find.text('Domestic sale in rupees'), findsOneWidget);
      await tester.tap(find.text('Domestic sale in rupees'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Do not collect TCS on this invoice'));
      await tester.pumpAndSettle();
      expect(last?.tcsOff, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
