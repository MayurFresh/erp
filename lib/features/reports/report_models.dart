/// Report payloads from `GET /reports/*` (v1.1 contract).
library;

import '../../core/json.dart';
import '../../core/money.dart';

/// Amounts this close to zero count as zero (paise rounding).
const double kMoneyEpsilon = 0.005;

bool isZeroAmount(num value) => value.abs() < kMoneyEpsilon;

// ---------------------------------------------------------------- Trial balance

class TrialBalanceRow {
  const TrialBalanceRow({
    required this.accountId,
    required this.code,
    required this.name,
    required this.type,
    this.debit = 0,
    this.credit = 0,
  });

  factory TrialBalanceRow.fromJson(Json json) => TrialBalanceRow(
    accountId: asString(json['accountId']),
    code: asString(json['code']),
    name: asString(json['name']),
    type: asString(json['type']),
    debit: asDouble(json['debit']),
    credit: asDouble(json['credit']),
  );

  final String accountId;
  final String code;
  final String name;
  final String type;
  final double debit;
  final double credit;
}

class TrialBalance {
  const TrialBalance({
    required this.rows,
    this.asOf,
    this.totalDebit = 0,
    this.totalCredit = 0,
  });

  factory TrialBalance.fromJson(Json json) => TrialBalance(
    asOf: asStringOrNull(json['asOf']),
    rows: asJsonList(json['rows']).map(TrialBalanceRow.fromJson).toList(),
    totalDebit: asDouble(json['totalDebit']),
    totalCredit: asDouble(json['totalCredit']),
  );

  final String? asOf;
  final List<TrialBalanceRow> rows;
  final double totalDebit;
  final double totalCredit;

  double get difference => totalDebit - totalCredit;
  bool get isBalanced => isZeroAmount(difference);
}

// ------------------------------------------------------- P&L and balance sheet

class StatementRow {
  const StatementRow({
    required this.name,
    this.accountId,
    this.code,
    this.amount = 0,
  });

  factory StatementRow.fromJson(Json json) => StatementRow(
    accountId: asStringOrNull(json['accountId']),
    code: asStringOrNull(json['code']),
    name: asString(json['name']),
    amount: asDouble(json['amount']),
  );

  /// `null` for computed rows such as "Profit & Loss" in equity.
  final String? accountId;
  final String? code;
  final String name;
  final double amount;
}

class StatementSection {
  const StatementSection({this.rows = const [], this.total = 0});

  static const empty = StatementSection();

  factory StatementSection.fromJson(Object? value) {
    final json = asJsonOrNull(value);
    if (json == null) return empty;
    return StatementSection(
      rows: asJsonList(json['rows']).map(StatementRow.fromJson).toList(),
      total: asDouble(json['total']),
    );
  }

  final List<StatementRow> rows;
  final double total;
}

class ProfitLoss {
  const ProfitLoss({
    this.from,
    this.to,
    this.revenue = StatementSection.empty,
    this.cogs = StatementSection.empty,
    this.grossProfit = 0,
    this.otherIncome = StatementSection.empty,
    this.expenses = StatementSection.empty,
    this.netProfit = 0,
  });

  factory ProfitLoss.fromJson(Json json) => ProfitLoss(
    from: asStringOrNull(json['from']),
    to: asStringOrNull(json['to']),
    revenue: StatementSection.fromJson(json['revenue']),
    cogs: StatementSection.fromJson(json['cogs']),
    grossProfit: asDouble(json['grossProfit']),
    otherIncome: StatementSection.fromJson(json['otherIncome']),
    expenses: StatementSection.fromJson(json['expenses']),
    netProfit: asDouble(json['netProfit']),
  );

  final String? from;
  final String? to;
  final StatementSection revenue;
  final StatementSection cogs;
  final double grossProfit;
  final StatementSection otherIncome;
  final StatementSection expenses;
  final double netProfit;

  bool get isEmpty => [
    revenue,
    cogs,
    otherIncome,
    expenses,
  ].every((s) => s.rows.isEmpty);
}

class BalanceSheet {
  const BalanceSheet({
    this.asOf,
    this.assets = StatementSection.empty,
    this.liabilities = StatementSection.empty,
    this.equity = StatementSection.empty,
    this.totalAssets = 0,
    this.totalLiabilitiesAndEquity = 0,
  });

  factory BalanceSheet.fromJson(Json json) => BalanceSheet(
    asOf: asStringOrNull(json['asOf']),
    assets: StatementSection.fromJson(json['assets']),
    liabilities: StatementSection.fromJson(json['liabilities']),
    equity: StatementSection.fromJson(json['equity']),
    totalAssets: asDouble(json['totalAssets']),
    totalLiabilitiesAndEquity: asDouble(json['totalLiabilitiesAndEquity']),
  );

  final String? asOf;
  final StatementSection assets;
  final StatementSection liabilities;
  final StatementSection equity;
  final double totalAssets;
  final double totalLiabilitiesAndEquity;

  double get difference => totalAssets - totalLiabilitiesAndEquity;
  bool get isBalanced => isZeroAmount(difference);
  bool get isEmpty =>
      assets.rows.isEmpty && liabilities.rows.isEmpty && equity.rows.isEmpty;
}

// ------------------------------------------------------------------ Registers

class RegisterRow {
  const RegisterRow({
    required this.id,
    required this.number,
    required this.partyName,
    this.date,
    this.supplierInvoiceNo,
    this.partyGstin,
    this.placeOfSupply,
    this.taxable = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.total = 0,
    this.status = 'posted',
  });

  factory RegisterRow.fromJson(Json json) => RegisterRow(
    id: asString(json['id']),
    number: asString(json['number']),
    supplierInvoiceNo: asStringOrNull(json['supplierInvoiceNo']),
    date: asStringOrNull(json['date']),
    partyName: asString(json['partyName']),
    partyGstin: asStringOrNull(json['partyGstin']),
    placeOfSupply: asStringOrNull(json['placeOfSupply']),
    taxable: asDouble(json['taxable']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    total: asDouble(json['total']),
    status: asString(json['status'], 'posted'),
  );

  final String id;
  final String number;

  /// Purchase register only.
  final String? supplierInvoiceNo;
  final String? date;
  final String partyName;
  final String? partyGstin;
  final String? placeOfSupply;
  final double taxable;
  final double cgst;
  final double sgst;
  final double igst;
  final double total;
  final String status;

  bool get isCancelled => status == 'cancelled';
  double get tax => cgst + sgst + igst;
}

class TaxAmounts {
  const TaxAmounts({
    this.taxable = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.total = 0,
  });

  factory TaxAmounts.fromJson(Object? value) {
    final json = asJson(value);
    return TaxAmounts(
      taxable: asDouble(json['taxable']),
      cgst: asDouble(json['cgst']),
      sgst: asDouble(json['sgst']),
      igst: asDouble(json['igst']),
      total: asDouble(json['total']),
    );
  }

  final double taxable;
  final double cgst;
  final double sgst;
  final double igst;
  final double total;

  double get tax => cgst + sgst + igst;
}

class Register {
  const Register({this.rows = const [], this.totals = const TaxAmounts()});

  factory Register.fromJson(Json json) => Register(
    rows: asJsonList(json['rows']).map(RegisterRow.fromJson).toList(),
    totals: TaxAmounts.fromJson(json['totals']),
  );

  final List<RegisterRow> rows;

  /// Cancelled rows count as zero here.
  final TaxAmounts totals;

  int get postedCount => rows.where((r) => !r.isCancelled).length;
  int get cancelledCount => rows.length - postedCount;
}

// ---------------------------------------------------------------- GST summary

class GstRateRow {
  const GstRateRow({
    this.gstRate,
    this.taxable = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
  });

  factory GstRateRow.fromJson(Object? value) {
    final json = asJson(value);
    return GstRateRow(
      gstRate: asDoubleOrNull(json['gstRate']),
      taxable: asDouble(json['taxable']),
      cgst: asDouble(json['cgst']),
      sgst: asDouble(json['sgst']),
      igst: asDouble(json['igst']),
    );
  }

  /// `null` on summary rows (credit notes, net, expenses, total).
  final double? gstRate;
  final double taxable;
  final double cgst;
  final double sgst;
  final double igst;

  double get tax => cgst + sgst + igst;
}

class GstCount {
  const GstCount({this.count = 0, this.taxable = 0, this.tax = 0});

  factory GstCount.fromJson(Object? value) {
    final json = asJson(value);
    return GstCount(
      count: asInt(json['count']),
      taxable: asDouble(json['taxable']),
      tax: asDouble(json['tax']),
    );
  }

  final int count;
  final double taxable;
  final double tax;
}

class GstOutward {
  const GstOutward({
    this.byRate = const [],
    this.b2b = const GstCount(),
    this.b2c = const GstCount(),
    this.creditNotes = const GstRateRow(),
    this.net = const GstRateRow(),
  });

  factory GstOutward.fromJson(Object? value) {
    final json = asJson(value);
    return GstOutward(
      byRate: asJsonList(json['byRate']).map(GstRateRow.fromJson).toList(),
      b2b: GstCount.fromJson(json['b2b']),
      b2c: GstCount.fromJson(json['b2c']),
      creditNotes: GstRateRow.fromJson(json['creditNotes']),
      net: GstRateRow.fromJson(json['net']),
    );
  }

  final List<GstRateRow> byRate;
  final GstCount b2b;
  final GstCount b2c;
  final GstRateRow creditNotes;
  final GstRateRow net;
}

class GstInward {
  const GstInward({
    this.byRate = const [],
    this.expenses = const GstRateRow(),
    this.total = const GstRateRow(),
  });

  factory GstInward.fromJson(Object? value) {
    final json = asJson(value);
    return GstInward(
      byRate: asJsonList(json['byRate']).map(GstRateRow.fromJson).toList(),
      expenses: GstRateRow.fromJson(json['expenses']),
      total: GstRateRow.fromJson(json['total']),
    );
  }

  final List<GstRateRow> byRate;
  final GstRateRow expenses;
  final GstRateRow total;
}

class HsnRow {
  const HsnRow({
    this.hsnCode,
    this.unit,
    this.qty = 0,
    this.taxable = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
  });

  factory HsnRow.fromJson(Json json) => HsnRow(
    hsnCode: asStringOrNull(json['hsnCode']),
    unit: asStringOrNull(json['unit']),
    qty: asDouble(json['qty']),
    taxable: asDouble(json['taxable']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
  );

  final String? hsnCode;
  final String? unit;
  final double qty;
  final double taxable;
  final double cgst;
  final double sgst;
  final double igst;

  double get tax => cgst + sgst + igst;
}

/// Output tax minus input credit per head; negative = credit carried
/// forward.
class GstNetPayable {
  const GstNetPayable({
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.total = 0,
  });

  factory GstNetPayable.fromJson(Object? value) {
    final json = asJson(value);
    return GstNetPayable(
      cgst: asDouble(json['cgst']),
      sgst: asDouble(json['sgst']),
      igst: asDouble(json['igst']),
      total: asDouble(json['total']),
    );
  }

  final double cgst;
  final double sgst;
  final double igst;
  final double total;
}

class GstSummary {
  const GstSummary({
    this.from,
    this.to,
    this.outward = const GstOutward(),
    this.inward = const GstInward(),
    this.hsn = const [],
    this.netPayable = const GstNetPayable(),
  });

  factory GstSummary.fromJson(Json json) => GstSummary(
    from: asStringOrNull(json['from']),
    to: asStringOrNull(json['to']),
    outward: GstOutward.fromJson(json['outward']),
    inward: GstInward.fromJson(json['inward']),
    hsn: asJsonList(json['hsn']).map(HsnRow.fromJson).toList(),
    netPayable: GstNetPayable.fromJson(json['netPayable']),
  );

  final String? from;
  final String? to;
  final GstOutward outward;
  final GstInward inward;
  final List<HsnRow> hsn;
  final GstNetPayable netPayable;

  bool get isEmpty =>
      outward.byRate.isEmpty &&
      inward.byRate.isEmpty &&
      hsn.isEmpty &&
      isZeroAmount(inward.expenses.taxable) &&
      isZeroAmount(outward.creditNotes.taxable);
}

/// `₹7,695.00` when payable, `₹47,677.86 credit c/f` when negative.
String formatNetTax(double amount) => amount < -kMoneyEpsilon
    ? '${formatMoney(-amount)} credit c/f'
    : formatMoney(isZeroAmount(amount) ? 0 : amount);

// ------------------------------------------------------------ Stock valuation

class StockValuationRow {
  const StockValuationRow({
    required this.itemId,
    required this.name,
    required this.unit,
    this.sku,
    this.qty = 0,
    this.avgCost = 0,
    this.value = 0,
  });

  factory StockValuationRow.fromJson(Json json) => StockValuationRow(
    itemId: asString(json['itemId']),
    name: asString(json['name']),
    sku: asStringOrNull(json['sku']),
    unit: asString(json['unit']),
    qty: asDouble(json['qty']),
    avgCost: asDouble(json['avgCost']),
    value: asDouble(json['value']),
  );

  final String itemId;
  final String name;
  final String? sku;
  final String unit;
  final double qty;
  final double avgCost;
  final double value;
}

class StockValuation {
  const StockValuation({this.rows = const [], this.totalValue = 0});

  factory StockValuation.fromJson(Json json) => StockValuation(
    rows: asJsonList(json['rows']).map(StockValuationRow.fromJson).toList(),
    totalValue: asDouble(json['totalValue']),
  );

  final List<StockValuationRow> rows;
  final double totalValue;
}

// --------------------------------------------------------------------- Ageing

enum AgeingType {
  receivables('Receivables ageing', 'Customers', 'Who owes you, by days overdue'),
  payables('Payables ageing', 'Vendors', 'What you owe, by days overdue');

  const AgeingType(this.title, this.partyLabel, this.description);

  final String title;
  final String partyLabel;
  final String description;
}

/// Column labels for [AgeingBuckets.values], in order.
const List<String> ageingBucketLabels = [
  'Not due',
  '1–30 days',
  '31–60 days',
  '61–90 days',
  '90+ days',
];

class AgeingBuckets {
  const AgeingBuckets({
    this.notDue = 0,
    this.d1to30 = 0,
    this.d31to60 = 0,
    this.d61to90 = 0,
    this.d90plus = 0,
    this.total = 0,
  });

  factory AgeingBuckets.fromJson(Object? value) {
    final json = asJson(value);
    return AgeingBuckets(
      notDue: asDouble(json['notDue']),
      d1to30: asDouble(json['d1_30']),
      d31to60: asDouble(json['d31_60']),
      d61to90: asDouble(json['d61_90']),
      d90plus: asDouble(json['d90plus']),
      total: asDouble(json['total']),
    );
  }

  final double notDue;
  final double d1to30;
  final double d31to60;
  final double d61to90;
  final double d90plus;
  final double total;

  /// In [ageingBucketLabels] order.
  List<double> get values => [notDue, d1to30, d31to60, d61to90, d90plus];

  /// Everything past its due date.
  double get overdue => d1to30 + d31to60 + d61to90 + d90plus;

  /// Share of [total] per bucket (0–1); all zero when nothing is open.
  List<double> get shares {
    if (total.abs() < kMoneyEpsilon) return List.filled(5, 0);
    return [for (final v in values) v / total];
  }

  /// Index of the oldest bucket holding money, or `null` when all are zero.
  int? get oldestBucket {
    final v = values;
    for (var i = v.length - 1; i >= 0; i--) {
      if (!isZeroAmount(v[i])) return i;
    }
    return null;
  }
}

class AgeingRow {
  const AgeingRow({
    required this.partyId,
    required this.partyName,
    this.buckets = const AgeingBuckets(),
  });

  factory AgeingRow.fromJson(Json json) => AgeingRow(
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    buckets: AgeingBuckets.fromJson(json),
  );

  final String partyId;
  final String partyName;
  final AgeingBuckets buckets;
}

class Ageing {
  const Ageing({
    this.asOf,
    this.rows = const [],
    this.totals = const AgeingBuckets(),
  });

  factory Ageing.fromJson(Json json) => Ageing(
    asOf: asStringOrNull(json['asOf']),
    rows: asJsonList(json['rows']).map(AgeingRow.fromJson).toList(),
    totals: AgeingBuckets.fromJson(json['totals']),
  );

  final String? asOf;
  final List<AgeingRow> rows;
  final AgeingBuckets totals;
}

/// `—` for zero amounts (keeps wide tables readable), else `₹1,234.00`.
String formatOptionalMoney(double amount) =>
    isZeroAmount(amount) ? '—' : formatMoney(amount);

/// `0.256` → `26%`; `0` → `0%`.
String formatShare(double share) => '${(share * 100).round()}%';
