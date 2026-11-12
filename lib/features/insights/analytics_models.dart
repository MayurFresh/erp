import '../../core/json.dart';

/// Key figures for one period. A `null` field was hidden by the server for
/// this user's role.
class Kpis {
  const Kpis(this.values);

  factory Kpis.fromJson(Json json) => Kpis({
    for (final e in json.entries)
      if (asDoubleOrNull(e.value) != null) e.key: asDoubleOrNull(e.value)!,
  });

  final Map<String, double> values;

  double? operator [](String key) => values[key];
  double get sales => values['sales'] ?? 0;
  double get purchases => values['purchases'] ?? 0;
  double get expenses => values['expenses'] ?? 0;
  double? get collections => values['collections'];
  double? get payments => values['payments'];
  double? get receivables => values['receivables'];
  double? get payables => values['payables'];
  double? get cashAndBank => values['cashAndBank'];
  double? get grossProfit => values['grossProfit'];
  double? get netProfit => values['netProfit'];
  double? get stockValue => values['stockValue'];
}

class TrendPoint {
  const TrendPoint(this.month, this.sales, this.purchases, this.expenses);
  final String month;
  final double sales, purchases, expenses;
}

class CashPoint {
  const CashPoint(this.month, this.cashIn, this.cashOut);
  final String month;
  final double cashIn, cashOut;
}

class RankedRow {
  const RankedRow({
    required this.id,
    required this.name,
    required this.amount,
    this.share,
    this.count,
    this.qty,
    this.unit,
  });
  final String id, name;
  final double amount;
  final double? share, qty;
  final int? count;
  final String? unit;
}

class AgeingBuckets {
  const AgeingBuckets({
    this.notDue = 0,
    this.d1to30 = 0,
    this.d31to60 = 0,
    this.d61to90 = 0,
    this.d90plus = 0,
    this.total = 0,
  });

  factory AgeingBuckets.fromJson(Json j) => AgeingBuckets(
    notDue: asDouble(j['notDue']),
    d1to30: asDouble(j['d1_30']),
    d31to60: asDouble(j['d31_60']),
    d61to90: asDouble(j['d61_90']),
    d90plus: asDouble(j['d90plus']),
    total: asDouble(j['total']),
  );

  final double notDue, d1to30, d31to60, d61to90, d90plus, total;

  double get over60 => d61to90 + d90plus;
  List<(String, double)> get labelled => [
    ('Not due', notDue),
    ('1 to 30 days late', d1to30),
    ('31 to 60 days late', d31to60),
    ('61 to 90 days late', d61to90),
    ('Over 90 days late', d90plus),
  ];
}

/// Response of `GET /analytics/overview`.
class Analytics {
  const Analytics({
    required this.from,
    required this.to,
    required this.previousFrom,
    required this.previousTo,
    required this.current,
    required this.previous,
    required this.trend,
    this.cashFlow,
    this.topCustomers = const [],
    this.topItems = const [],
    this.salesByLocation = const [],
    this.expensesByCategory = const [],
    this.receivableAgeing = const AgeingBuckets(),
    this.payableAgeing = const AgeingBuckets(),
  });

  factory Analytics.fromJson(Json j) {
    final kpis = asJson(j['kpis']);
    final ageing = asJson(j['ageing']);
    return Analytics(
      from: asString(j['from']),
      to: asString(j['to']),
      previousFrom: asString(j['previousFrom']),
      previousTo: asString(j['previousTo']),
      current: Kpis.fromJson(asJson(kpis['current'])),
      previous: Kpis.fromJson(asJson(kpis['previous'])),
      trend: [
        for (final r in asJsonList(j['trend']))
          TrendPoint(
            asString(r['month']),
            asDouble(r['sales']),
            asDouble(r['purchases']),
            asDouble(r['expenses']),
          ),
      ],
      cashFlow: j['cashFlow'] == null
          ? null
          : [
              for (final r in asJsonList(j['cashFlow']))
                CashPoint(
                  asString(r['month']),
                  asDouble(r['cashIn']),
                  asDouble(r['cashOut']),
                ),
            ],
      topCustomers: [
        for (final r in asJsonList(j['topCustomers']))
          RankedRow(
            id: asString(r['partyId']),
            name: asString(r['name']),
            amount: asDouble(r['amount']),
            share: asDoubleOrNull(r['share']),
            count: asInt(r['invoices']),
          ),
      ],
      topItems: [
        for (final r in asJsonList(j['topItems']))
          RankedRow(
            id: asString(r['itemId']),
            name: asString(r['name']),
            amount: asDouble(r['amount']),
            qty: asDoubleOrNull(r['qty']),
            unit: asStringOrNull(r['unit']),
          ),
      ],
      salesByLocation: [
        for (final r in asJsonList(j['salesByLocation']))
          RankedRow(
            id: asString(r['locationId']),
            name: asString(r['name']),
            amount: asDouble(r['amount']),
          ),
      ],
      expensesByCategory: [
        for (final r in asJsonList(j['expensesByCategory']))
          RankedRow(
            id: asString(r['accountId']),
            name: asString(r['category']),
            amount: asDouble(r['amount']),
          ),
      ],
      receivableAgeing: AgeingBuckets.fromJson(asJson(ageing['receivables'])),
      payableAgeing: AgeingBuckets.fromJson(asJson(ageing['payables'])),
    );
  }

  final String from, to, previousFrom, previousTo;
  final Kpis current, previous;
  final List<TrendPoint> trend;

  /// Null when the user may not see money movements.
  final List<CashPoint>? cashFlow;
  final List<RankedRow> topCustomers,
      topItems,
      salesByLocation,
      expensesByCategory;
  final AgeingBuckets receivableAgeing, payableAgeing;

  List<double> get salesSpark => [for (final t in trend) t.sales];
  List<double> get purchasesSpark => [for (final t in trend) t.purchases];
  List<double> get expensesSpark => [for (final t in trend) t.expenses];
}
