import 'package:flutter_test/flutter_test.dart';
import 'package:onematrix/core/money.dart';
import 'package:onematrix/features/insights/analytics_models.dart';
import 'package:onematrix/features/insights/insights_rules.dart';

Analytics make({
  double sales = 112000,
  double prevSales = 100000,
  double expenses = 10000,
  double prevExpenses = 10000,
  double? net,
  List<RankedRow> customers = const [],
  AgeingBuckets? ageing,
  List<CashPoint>? cash,
  List<TrendPoint> trend = const [],
}) => Analytics(
  from: '2026-10-01',
  to: '2026-10-31',
  previousFrom: '2026-09-01',
  previousTo: '2026-09-30',
  current: Kpis({
    'sales': sales,
    'purchases': 0,
    'expenses': expenses,
    'netProfit': ?net,
  }),
  previous: Kpis({
    'sales': prevSales,
    'purchases': 0,
    'expenses': prevExpenses,
  }),
  trend: trend,
  cashFlow: cash,
  topCustomers: customers,
  receivableAgeing: ageing ?? const AgeingBuckets(),
);

void main() {
  setUp(() => configureMoney());

  test('sales change and customer share', () {
    final t = buildTakeaways(
      make(
        customers: const [
          RankedRow(
            id: '1',
            name: 'Mumbai Infra Projects',
            amount: 34720,
            share: 31,
          ),
        ],
      ),
      versus: 'last month',
    ).map((e) => e.text).toList();
    expect(t[0], 'Sales are up 12% on last month, ₹1 L to ₹1.1 L.');
    expect(t[1], 'Mumbai Infra Projects is 31% of sales.');
  });

  test('a sales fall is a warning', () {
    final t = buildTakeaways(make(sales: 50000, prevSales: 100000));
    expect(t.first.tone, TakeawayTone.warning);
    expect(t.first.text, startsWith('Sales are down 50%'));
  });

  test('no sales at all', () {
    final t = buildTakeaways(make(sales: 0, prevSales: 0));
    expect(t.single.text, contains('No sales'));
  });

  test('half of sales from one customer', () {
    final t = buildTakeaways(
      make(
        customers: const [
          RankedRow(id: '1', name: 'A', amount: 60000, share: 60),
        ],
      ),
    );
    expect(t.any((e) => e.text.contains('More than half')), isTrue);
  });

  test('loss, margin and expense growth', () {
    expect(
      buildTakeaways(
        make(net: -5000),
      ).any((e) => e.text.contains('loss of ₹5K')),
      isTrue,
    );
    expect(
      buildTakeaways(
        make(net: 22400),
      ).any((e) => e.text.contains('margin of 20%')),
      isTrue,
    );
    final t = buildTakeaways(make(expenses: 15000));
    expect(t.any((e) => e.text.contains('Expenses rose 50%')), isTrue);
  });

  test('old receivables and cash outflow', () {
    final t = buildTakeaways(
      make(
        ageing: const AgeingBuckets(
          notDue: 50000,
          d90plus: 50000,
          total: 100000,
        ),
        cash: const [CashPoint('2026-10', 10000, 30000)],
      ),
    ).map((e) => e.text);
    expect(
      t.any((e) => e.contains('50%') && e.contains('60 days late')),
      isTrue,
    );
    expect(t.any((e) => e.contains('paid out ₹20K more')), isTrue);
  });

  test('hidden fields produce no lines and the list is capped', () {
    final t = buildTakeaways(make(), limit: 1);
    expect(t.length, 1);
    expect(
      buildTakeaways(make()).any((e) => e.text.contains('profit')),
      isFalse,
    );
  });

  test('model parses the API shape and tolerates hidden fields', () {
    final a = Analytics.fromJson({
      'from': '2026-04-01',
      'to': '2026-10-31',
      'previousFrom': 'x',
      'previousTo': 'y',
      'kpis': {
        'current': {'sales': 10, 'purchases': 2, 'expenses': 1},
        'previous': {'sales': 5, 'purchases': 1, 'expenses': 1},
      },
      'trend': [
        {'month': '2026-10', 'sales': 10, 'purchases': 2, 'expenses': 1},
      ],
      'topCustomers': [
        {
          'partyId': 'p',
          'name': 'A',
          'amount': 10,
          'invoices': 2,
          'share': 100,
        },
      ],
      'ageing': {
        'receivables': {
          'notDue': 1,
          'd1_30': 2,
          'd31_60': 0,
          'd61_90': 0,
          'd90plus': 3,
          'total': 6,
        },
        'payables': {},
      },
    });
    expect(a.cashFlow, isNull);
    expect(a.current.netProfit, isNull);
    expect(a.receivableAgeing.over60, 3);
    expect(a.topCustomers.single.count, 2);
  });
}
