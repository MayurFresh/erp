import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/theme.dart';
import 'package:onematrix/features/finance_reports/budgets_screen.dart';
import 'package:onematrix/features/finance_reports/cash_flow_screen.dart';
import 'package:onematrix/features/finance_reports/cheque_pdf.dart';
import 'package:onematrix/features/finance_reports/finance_models.dart';
import 'package:onematrix/features/finance_reports/ratios_screen.dart';

Map<String, dynamic> _flow({double profit = 11000, double diff = 0}) => {
  'from': '2026-04-01',
  'to': '2026-06-30',
  'netProfit': profit,
  'openingCash': 0,
  'closingCash': 99000,
  'netChange': 99000,
  'computedChange': 99000 - diff,
  'difference': diff,
  'reconciles': diff == 0,
  'sections': [
    {
      'key': 'operating',
      'title': 'Cash flow from operating activities',
      'total': 5000,
      'lines': [
        {'key': 'net_profit', 'label': 'Net profit for the period', 'group': 'profit', 'amount': profit, 'accounts': []},
        {
          'key': 'receivables', 'label': 'Trade receivables', 'group': 'working_capital', 'amount': -30000,
          'accounts': [
            {'accountId': 'a1', 'code': '1100', 'name': 'Accounts Receivable', 'amount': -30000},
          ],
        },
      ],
    },
    {'key': 'investing', 'title': 'Cash flow from investing activities', 'total': -30000, 'lines': []},
    {'key': 'financing', 'title': 'Cash flow from financing activities', 'total': 124000, 'lines': []},
  ],
};

Widget _host(List<Widget> children, {double width = 320}) => MediaQuery(
  data: MediaQueryData(size: Size(width, 800)),
  child: MaterialApp(
    theme: AppTheme.light,
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
    ),
  ),
);

void main() {
  group('models', () {
    test('cash flow parses sections and the previous period', () {
      final r = CashFlowReport.fromJson({'current': _flow(), 'previous': _flow(profit: 8000)});
      expect(r.current.section('operating')!.total, 5000);
      expect(r.current.reconciles, isTrue);
      expect(r.previousLine('operating', 'net_profit'), 8000);
      expect(r.previousLine('operating', 'missing'), 0);
      expect(CashFlowReport.fromJson({'current': _flow()}).previousLine('operating', 'net_profit'), isNull);
    });

    test('ratio text follows the unit', () {
      const pct = Ratio(key: 'k', label: 'L', group: 'g', unit: 'percent', value: 40, formula: 'f');
      const days = Ratio(key: 'k', label: 'L', group: 'g', unit: 'days', value: 27.3, formula: 'f');
      const times = Ratio(key: 'k', label: 'L', group: 'g', unit: 'times', value: 4.63, formula: 'f');
      const none = Ratio(key: 'k', label: 'L', group: 'g', unit: 'times', value: null, formula: 'f');
      expect(pct.text, '40%');
      expect(days.text, '27.3 days');
      expect(times.text, '4.63 times');
      expect(none.text, 'Not available');
    });

    test('financial year months run April to March', () {
      final m = fyMonths('2026-27');
      expect(m.first, '2026-04');
      expect(m[8], '2026-12');
      expect(m.last, '2027-03');
      expect(fyLabelOf(DateTime(2027, 2, 1)), '2026-27');
      expect(monthLabel('2026-04'), 'Apr 2026');
    });

    test('cheque actions follow the status', () {
      Cheque c(String status, {String direction = 'received'}) => Cheque.fromJson({
        'id': 'c', 'direction': direction, 'status': status, 'chequeNo': '1', 'amount': 10,
      });
      expect(c('held').actions, ['deposit', 'clear', 'bounce', 'cancel']);
      expect(c('held', direction: 'issued').actions, ['clear', 'bounce', 'cancel']);
      expect(c('deposited').actions, ['clear', 'bounce']);
      expect(c('cleared').actions, ['bounce']);
      expect(c('bounced').actions, isEmpty);
    });

    test('cheque layout round trips', () {
      final l = ChequeLayout.fromJson({
        'widthMm': 202, 'heightMm': 92, 'dateGap': 5, 'isDefault': true,
        'date': {'x': 160, 'y': 10}, 'payee': {'x': 30, 'y': 22},
        'words': {'x': 30, 'y': 31, 'maxWidth': 120}, 'amount': {'x': 160, 'y': 40}, 'acPayee': {'x': 12, 'y': 8},
      });
      final j = l.toJson();
      expect((j['words'] as Map)['maxWidth'], 120);
      expect((j['date'] as Map)['x'], 160);
      expect(ChequeLayout.fromJson(j).fields['payee'], (30.0, 22.0));
    });

    test('budget alert wording', () {
      const a = BudgetAlert(name: 'Rent', level: 'over', percentUsed: 125, scope: 'month');
      expect(a.text, 'Rent is at 125% of the month budget, over the limit.');
    });
  });

  group('screens at 320 px', () {
    testWidgets('cash flow shows sections, the check and drill-down', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final r = CashFlowReport.fromJson({'current': _flow(), 'previous': _flow(profit: 8000)});
      await tester.pumpWidget(_host(cashFlowBlocks(r)));
      expect(find.text('Cash flow from operating activities'), findsOneWidget);
      expect(find.text('Reconciles to the change in cash and bank'), findsOneWidget);
      expect(find.textContaining('Last year'), findsWidgets);
      await tester.tap(find.text('Trade receivables'));
      await tester.pumpAndSettle();
      expect(find.text('Accounts Receivable'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('cash flow shows a difference when it does not reconcile', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final r = CashFlowReport.fromJson({'current': _flow(diff: 500)});
      await tester.pumpWidget(_host(cashFlowBlocks(r)));
      expect(find.textContaining('Difference'), findsOneWidget);
    });

    testWidgets('ratios show value, formula and last year', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Map<String, dynamic> set(double v) => {
        'from': 'a', 'to': 'b',
        'ratios': [
          {'key': 'current_ratio', 'label': 'Current ratio', 'group': 'liquidity', 'unit': 'times', 'value': v, 'formula': 'Current assets / current liabilities'},
          {'key': 'debtor_days', 'label': 'Debtor days', 'group': 'efficiency', 'unit': 'days', 'value': null, 'formula': 'Average receivables / sales x days'},
        ],
      };
      await tester.pumpWidget(_host(ratioBlocks(RatioReport.fromJson({'current': set(4.63), 'previous': set(3.1)}))));
      expect(find.text('4.63 times'), findsOneWidget);
      expect(find.text('Last year 3.1 times'), findsOneWidget);
      expect(find.text('Current assets / current liabilities'), findsOneWidget);
      expect(find.text('Not available'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('budget variance lists alerts and rows', (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      Map<String, dynamic> f(double b, double a) => {
        'budget': b, 'actual': a, 'variance': a - b, 'percentUsed': b == 0 ? null : a / b * 100,
      };
      final v = BudgetVariance.fromJson({
        'fy': '2026-27', 'month': '2026-04',
        'rows': [
          {'accountId': 'a', 'code': '6000', 'name': 'Rent', 'type': 'expense', 'month': f(4000, 5000), 'ytd': f(4000, 5000), 'annualBudget': 8000, 'status': 'over'},
        ],
        'alerts': [
          {'accountId': 'a', 'name': 'Rent', 'level': 'over', 'percentUsed': 125, 'scope': 'month'},
        ],
      });
      await tester.pumpWidget(_host(varianceBlocks(v)));
      expect(find.textContaining('Rent is at 125%'), findsOneWidget);
      expect(find.text('Over budget'), findsOneWidget);
      expect(find.text('125% used'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });

  test('cheque PDF is built at the leaf size', () async {
    final data = ChequePrint.fromJson({
      'chequeNo': '100001', 'dateText': '15042026', 'payee': 'Supplier', 'amount': 2000,
      'layout': {
        'widthMm': 202, 'heightMm': 92, 'dateGap': 5,
        'date': {'x': 160, 'y': 10}, 'payee': {'x': 30, 'y': 22},
        'words': {'x': 30, 'y': 31, 'maxWidth': 120}, 'amount': {'x': 160, 'y': 40}, 'acPayee': {'x': 12, 'y': 8},
      },
    });
    final bytes = await buildChequePdf(data);
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(chequeAmountText(2000), '**2,000.00/-');
  });
}
