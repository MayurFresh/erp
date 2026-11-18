import 'package:flutter/material.dart' show TextField;
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/features/finance_reports/finance_exports.dart';
import 'package:onematrix/features/finance_reports/finance_models.dart';
import 'package:onematrix/features/landed_cost/landed_cost_form_screen.dart';
import 'package:onematrix/features/landed_cost/landed_cost_models.dart';
import 'package:onematrix/features/credit_notes/credit_note_model.dart';
import 'package:onematrix/features/export_currency/payables_screen.dart';
import 'package:onematrix/features/payments/payment_detail_screen.dart';

import '../landed_cost_rfq/landed_cost_rfq_test.dart' show perms;
import '../quotations/quotation_fixtures.dart';

Map<String, dynamic> _flow(double profit) => {
  'from': '2026-04-01',
  'to': '2026-06-30',
  'netProfit': profit,
  'openingCash': 0,
  'closingCash': 99000,
  'netChange': 99000,
  'computedChange': 99000,
  'difference': 0,
  'reconciles': true,
  'sections': [
    {
      'key': 'operating',
      'title': 'Operating',
      'total': 5000,
      'lines': [
        {'key': 'net_profit', 'label': 'Net profit', 'group': 'profit', 'amount': profit, 'accounts': []},
      ],
    },
  ],
};

Map<String, dynamic> _ratios(double v) => {
  'from': '2026-04-01',
  'to': '2026-06-30',
  'ratios': [
    {'key': 'current', 'label': 'Current ratio', 'group': 'liquidity', 'unit': 'times', 'value': v, 'formula': 'a / b'},
  ],
};

Map<String, dynamic> _payment({String mode = 'cheque', String kind = 'payment'}) => {
  'id': 'p1', 'companyId': 'c1', 'kind': kind, 'number': 'PAY/26-27/00001', 'date': '2026-11-10',
  'partyId': 'v1', 'partyName': 'Vendor One', 'accountId': 'a1', 'accountName': 'HDFC Bank', 'mode': mode,
  'amount': 5000, 'allocated': 0, 'unallocated': 5000, 'tdsAmount': 0, 'status': 'posted', 'allocations': [],
};

void main() {
  group('cash flow and ratio exports', () {
    test('cash flow rows carry sections, totals and last year', () {
      final r = CashFlowReport.fromJson({'current': _flow(11000), 'previous': _flow(8000)});
      final e = cashFlowExport(r);
      expect(e.columns.map((c) => c.label), ['Section', 'Line', 'Amount', 'Last year']);
      expect(e.rows.first, ['Cash flow', 'Net profit', 11000.0, 8000.0]);
      expect(e.rows.any((x) => x[1] == 'Total Operating' && x[2] == 5000.0), isTrue);
      final csv = e.toCsv();
      expect(csv, contains('Closing'));
      expect(csv, contains('99000.00'));
      expect(e.fileStem, 'Cash-flow-2026-04-01-2026-06-30');
    });

    test('cash flow without a comparison has no last year column', () {
      final e = cashFlowExport(CashFlowReport.fromJson({'current': _flow(11000)}));
      expect(e.columns.length, 3);
      expect(e.rows.every((x) => x.length == 3), isTrue);
    });

    test('ratios are written as shown on screen', () {
      final r = RatioReport.fromJson({'current': _ratios(1.5), 'previous': _ratios(1.2)});
      final e = ratiosExport(r);
      expect(e.rows.single, ['Liquidity', 'Current ratio', '1.5 times', '1.2 times', 'a / b']);
      expect(e.toCsv(), contains('1.5 times'));
    });
  });

  group('landed cost source', () {
    test('a source replaces the credit side in the body', () {
      final c = ChargeDraft(amount: 300)
        ..sourceType = 'expense'
        ..sourceId = 'e1';
      expect(c.hasCreditSide, isTrue);
      expect(c.toJson(), {'kind': 'freight', 'amount': 300.0, 'sourceType': 'expense', 'sourceId': 'e1'});
      c.clearSource();
      expect(c.hasCreditSide, isFalse);
    });

    for (final size in [narrow, wide]) {
      testWidgets('form offers expense and vendor bill sources at ${size.width.toInt()}px', (tester) async {
        final b = FakeControlsBackend();
        await pumpRouted(tester, const LandedCostFormScreen(), b, size: size, permissions: perms);
        expect(find.text('From an expense'), findsOneWidget);
        expect(find.text('From a vendor bill'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('print cheque on payment detail', () {
    testWidgets('shows for a cheque payment with cheque permission', (tester) async {
      final b = FakeControlsBackend()..on('GET /payments/p1', _payment());
      await pumpRouted(tester, const PaymentDetailScreen(paymentId: 'p1'), b, size: wide, permissions: {...perms, 'payments.view', 'cheques.manage'});
      expect(find.text('Print cheque'), findsOneWidget);
    });

    testWidgets('hidden for bank transfers, receipts and without permission', (tester) async {
      var b = FakeControlsBackend()..on('GET /payments/p1', _payment(mode: 'bank'));
      await pumpRouted(tester, const PaymentDetailScreen(paymentId: 'p1'), b, size: wide, permissions: {...perms, 'payments.view', 'cheques.manage'});
      expect(find.text('Print cheque'), findsNothing);
      b = FakeControlsBackend()..on('GET /payments/p1', _payment(kind: 'receipt'));
      await pumpRouted(tester, const PaymentDetailScreen(paymentId: 'p1'), b, size: wide, permissions: {...perms, 'payments.view', 'cheques.manage'});
      expect(find.text('Print cheque'), findsNothing);
      b = FakeControlsBackend()..on('GET /payments/p1', _payment());
      await pumpRouted(tester, const PaymentDetailScreen(paymentId: 'p1'), b, size: wide, permissions: {...perms, 'payments.view'});
      expect(find.text('Print cheque'), findsNothing);
    });
  });

  test('credit note reads tcsReversed', () {
    expect(CreditNote.fromJson({'id': 'n1', 'tcsReversed': 250}).tcsReversed, 250);
    expect(CreditNote.fromJson({'id': 'n1'}).tcsReversed, 0);
  });

  group('foreign payables screen', () {
    final open = {
      'data': [
        {'purchaseId': 'b1', 'number': 'PUR/26-27/00001', 'date': '2026-10-01', 'partyId': 'v1', 'currency': 'USD', 'rate': 80, 'fcTotal': 100, 'inrOutstanding': 8000, 'fcOutstanding': 100},
      ],
    };
    for (final size in [narrow, wide]) {
      testWidgets('lists open bills and revalues at ${size.width.toInt()}px', (tester) async {
        final b = FakeControlsBackend()
          ..on('GET /fx/payables', open)
          ..on('POST /fx/payables/revaluation/preview', {'rows': [], 'total': 400});
        await pumpRouted(tester, const ForeignPayablesScreen(), b, size: size, permissions: {...perms, 'fx.view', 'fx.manage'});
        expect(find.textContaining('PUR/26-27/00001'), findsOneWidget);
        expect(find.text('Tag a bill'), findsOneWidget);
        await tester.enterText(find.widgetWithText(TextField, 'Closing rate for USD'), '84');
        await tester.ensureVisible(find.text('Preview'));
        await tester.tap(find.text('Preview'));
        await tester.pumpAndSettle();
        expect((b.last('POST', '/fx/payables/revaluation/preview')!.data as Map)['rates'], {'USD': 84});
        expect(find.textContaining('loss of'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }

    testWidgets('read-only user cannot tag or post', (tester) async {
      final b = FakeControlsBackend()..on('GET /fx/payables', open);
      await pumpRouted(tester, const ForeignPayablesScreen(), b, size: wide, permissions: {'fx.view'});
      expect(find.text('Tag a bill'), findsNothing);
    });
  });
}
