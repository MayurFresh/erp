/// Cash flow, ratios, year-end, budgets and cheques: plain models for the
/// v1.15 finance reports API. Pure Dart.
library;

import '../../core/json.dart';
import '../../core/money.dart';

// ---------------------------------------------------------------- Cash flow

class CfAccountAmount {
  const CfAccountAmount({
    required this.accountId,
    required this.code,
    required this.name,
    required this.amount,
  });
  factory CfAccountAmount.fromJson(Json j) => CfAccountAmount(
    accountId: asStringOrNull(j['accountId']),
    code: asString(j['code']),
    name: asString(j['name']),
    amount: asDouble(j['amount']),
  );
  final String? accountId;
  final String code;
  final String name;
  final double amount;
}

class CfLine {
  const CfLine({
    required this.key,
    required this.label,
    required this.group,
    required this.amount,
    required this.accounts,
  });
  factory CfLine.fromJson(Json j) => CfLine(
    key: asString(j['key']),
    label: asString(j['label']),
    group: asString(j['group']),
    amount: asDouble(j['amount']),
    accounts: asJsonList(j['accounts']).map(CfAccountAmount.fromJson).toList(),
  );
  final String key;
  final String label;
  final String group;
  final double amount;
  final List<CfAccountAmount> accounts;
}

class CfSection {
  const CfSection({
    required this.key,
    required this.title,
    required this.total,
    required this.lines,
  });
  factory CfSection.fromJson(Json j) => CfSection(
    key: asString(j['key']),
    title: asString(j['title']),
    total: asDouble(j['total']),
    lines: asJsonList(j['lines']).map(CfLine.fromJson).toList(),
  );
  final String key;
  final String title;
  final double total;
  final List<CfLine> lines;
}

class CashFlow {
  const CashFlow({
    required this.from,
    required this.to,
    required this.netProfit,
    required this.openingCash,
    required this.closingCash,
    required this.netChange,
    required this.computedChange,
    required this.difference,
    required this.reconciles,
    required this.sections,
  });
  factory CashFlow.fromJson(Json j) => CashFlow(
    from: asString(j['from']),
    to: asString(j['to']),
    netProfit: asDouble(j['netProfit']),
    openingCash: asDouble(j['openingCash']),
    closingCash: asDouble(j['closingCash']),
    netChange: asDouble(j['netChange']),
    computedChange: asDouble(j['computedChange']),
    difference: asDouble(j['difference']),
    reconciles: asBool(j['reconciles']),
    sections: asJsonList(j['sections']).map(CfSection.fromJson).toList(),
  );
  final String from;
  final String to;
  final double netProfit;
  final double openingCash;
  final double closingCash;
  final double netChange;
  final double computedChange;
  final double difference;
  final bool reconciles;
  final List<CfSection> sections;

  CfSection? section(String key) {
    for (final s in sections) {
      if (s.key == key) return s;
    }
    return null;
  }
}

class CashFlowReport {
  const CashFlowReport({required this.current, this.previous});
  factory CashFlowReport.fromJson(Json j) => CashFlowReport(
    current: CashFlow.fromJson(asJson(j['current'])),
    previous: asJsonOrNull(j['previous']) == null
        ? null
        : CashFlow.fromJson(asJson(j['previous'])),
  );
  final CashFlow current;
  final CashFlow? previous;

  /// The amount of line [key] in the comparison period, or null.
  double? previousLine(String sectionKey, String key) {
    final line = previous
        ?.section(sectionKey)
        ?.lines
        .where((l) => l.key == key)
        .firstOrNull;
    return previous == null ? null : (line?.amount ?? 0);
  }
}

class CfMappingRow {
  const CfMappingRow({
    required this.accountId,
    required this.code,
    required this.name,
    required this.type,
    required this.defaultCategory,
    required this.category,
    required this.effective,
  });
  factory CfMappingRow.fromJson(Json j) => CfMappingRow(
    accountId: asString(j['accountId']),
    code: asString(j['code']),
    name: asString(j['name']),
    type: asString(j['type']),
    defaultCategory: asString(j['defaultCategory']),
    category: asStringOrNull(j['category']),
    effective: asString(j['effective']),
  );
  final String accountId;
  final String code;
  final String name;
  final String type;
  final String defaultCategory;
  final String? category;
  final String effective;
}

const Map<String, String> cfCategoryLabels = {
  'operating': 'Operating (working capital)',
  'investing': 'Investing',
  'financing': 'Financing',
  'noncash': 'Non-cash item (provision)',
};

// ------------------------------------------------------------------- Ratios

class Ratio {
  const Ratio({
    required this.key,
    required this.label,
    required this.group,
    required this.unit,
    required this.value,
    required this.formula,
  });
  factory Ratio.fromJson(Json j) => Ratio(
    key: asString(j['key']),
    label: asString(j['label']),
    group: asString(j['group']),
    unit: asString(j['unit']),
    value: asDoubleOrNull(j['value']),
    formula: asString(j['formula']),
  );
  final String key;
  final String label;
  final String group;
  final String unit;
  final double? value;
  final String formula;

  /// `4.63 times`, `40% `, `27.3 days`, or a dash when it cannot be worked out.
  String format(double? v) {
    if (v == null) return 'Not available';
    final n = formatQty(double.parse(v.toStringAsFixed(2)));
    return switch (unit) {
      'percent' => '$n%',
      'days' => '$n days',
      _ => '$n times',
    };
  }

  String get text => format(value);
}

class RatioSet {
  const RatioSet({required this.from, required this.to, required this.ratios});
  factory RatioSet.fromJson(Json j) => RatioSet(
    from: asString(j['from']),
    to: asString(j['to']),
    ratios: asJsonList(j['ratios']).map(Ratio.fromJson).toList(),
  );
  final String from;
  final String to;
  final List<Ratio> ratios;

  Ratio? byKey(String key) => ratios.where((r) => r.key == key).firstOrNull;
}

class RatioReport {
  const RatioReport({required this.current, this.previous});
  factory RatioReport.fromJson(Json j) => RatioReport(
    current: RatioSet.fromJson(asJson(j['current'])),
    previous: asJsonOrNull(j['previous']) == null
        ? null
        : RatioSet.fromJson(asJson(j['previous'])),
  );
  final RatioSet current;
  final RatioSet? previous;
}

const Map<String, String> ratioGroupLabels = {
  'liquidity': 'Liquidity',
  'leverage': 'Leverage',
  'profitability': 'Profitability',
  'efficiency': 'Efficiency',
};

// --------------------------------------------------------------- Year-end

class YearEndPreview {
  const YearEndPreview({
    required this.fy,
    required this.from,
    required this.to,
    required this.income,
    required this.expenses,
    required this.profit,
    required this.equityAccountName,
    required this.willCreateEquityAccount,
    required this.closed,
    required this.canClose,
    required this.blockers,
    required this.steps,
  });
  factory YearEndPreview.fromJson(Json j) => YearEndPreview(
    fy: asString(j['fy']),
    from: asString(j['from']),
    to: asString(j['to']),
    income: asDouble(j['income']),
    expenses: asDouble(j['expenses']),
    profit: asDouble(j['profit']),
    equityAccountName: asString(j['equityAccountName']),
    willCreateEquityAccount: asBool(j['willCreateEquityAccount']),
    closed: asBool(j['closed']),
    canClose: asBool(j['canClose']),
    blockers: asStringList(j['blockers']),
    steps: asStringList(j['steps']),
  );
  final String fy;
  final String from;
  final String to;
  final double income;
  final double expenses;
  final double profit;
  final String equityAccountName;
  final bool willCreateEquityAccount;
  final bool closed;
  final bool canClose;
  final List<String> blockers;
  final List<String> steps;
}

class YearEndClose {
  const YearEndClose({
    required this.id,
    required this.fy,
    required this.closeDate,
    required this.profit,
    required this.equityAccountName,
    required this.status,
  });
  factory YearEndClose.fromJson(Json j) => YearEndClose(
    id: asString(j['id']),
    fy: asString(j['fy']),
    closeDate: asString(j['closeDate']),
    profit: asDouble(j['profit']),
    equityAccountName: asString(j['equityAccountName']),
    status: asString(j['status']),
  );
  final String id;
  final String fy;
  final String closeDate;
  final double profit;
  final String equityAccountName;
  final String status;
  bool get isClosed => status == 'closed';
}

/// `2026-27` for the financial year containing [d].
String fyLabelOf(DateTime d) {
  final start = d.month >= 4 ? d.year : d.year - 1;
  return '$start-${((start + 1) % 100).toString().padLeft(2, '0')}';
}

/// The twelve months of [fy] as `YYYY-MM`, April first.
List<String> fyMonths(String fy) {
  final y = int.parse(fy.substring(0, 4));
  return [
    for (var i = 0; i < 12; i++)
      () {
        final m = (i + 3) % 12 + 1;
        return '${m >= 4 ? y : y + 1}-${m.toString().padLeft(2, '0')}';
      }(),
  ];
}

const List<String> _monthNames = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// `2026-04` → `Apr 2026`.
String monthLabel(String ym) =>
    '${_monthNames[int.parse(ym.substring(5)) - 1]} ${ym.substring(0, 4)}';

// ------------------------------------------------------------------ Budgets

class BudgetRow {
  const BudgetRow({
    required this.accountId,
    required this.code,
    required this.name,
    required this.type,
    required this.costCentreId,
    required this.costCentreName,
    required this.months,
    required this.total,
  });
  factory BudgetRow.fromJson(Json j) => BudgetRow(
    accountId: asString(j['accountId']),
    code: asString(j['code']),
    name: asString(j['name']),
    type: asString(j['type']),
    costCentreId: asStringOrNull(j['costCentreId']),
    costCentreName: asStringOrNull(j['costCentreName']),
    months: {
      for (final e in asJson(j['months']).entries) e.key: asDouble(e.value),
    },
    total: asDouble(j['total']),
  );
  final String accountId;
  final String code;
  final String name;
  final String type;
  final String? costCentreId;
  final String? costCentreName;
  final Map<String, double> months;
  final double total;
}

class Figures {
  const Figures({
    required this.budget,
    required this.actual,
    required this.variance,
    required this.percentUsed,
  });
  factory Figures.fromJson(Json j) => Figures(
    budget: asDouble(j['budget']),
    actual: asDouble(j['actual']),
    variance: asDouble(j['variance']),
    percentUsed: asDoubleOrNull(j['percentUsed']),
  );
  final double budget;
  final double actual;
  final double variance;
  final double? percentUsed;

  String get percentText =>
      percentUsed == null ? 'No budget' : '${formatQty(percentUsed)}% used';
}

class VarianceRow {
  const VarianceRow({
    required this.accountId,
    required this.code,
    required this.name,
    required this.type,
    required this.costCentreName,
    required this.month,
    required this.ytd,
    required this.annualBudget,
    required this.status,
  });
  factory VarianceRow.fromJson(Json j) => VarianceRow(
    accountId: asString(j['accountId']),
    code: asString(j['code']),
    name: asString(j['name']),
    type: asString(j['type']),
    costCentreName: asStringOrNull(j['costCentreName']),
    month: Figures.fromJson(asJson(j['month'])),
    ytd: Figures.fromJson(asJson(j['ytd'])),
    annualBudget: asDouble(j['annualBudget']),
    status: asString(j['status']),
  );
  final String accountId;
  final String code;
  final String name;
  final String type;
  final String? costCentreName;
  final Figures month;
  final Figures ytd;
  final double annualBudget;
  final String status;
}

class BudgetAlert {
  const BudgetAlert({
    required this.name,
    required this.level,
    required this.percentUsed,
    required this.scope,
  });
  factory BudgetAlert.fromJson(Json j) => BudgetAlert(
    name: asString(j['name']),
    level: asString(j['level']),
    percentUsed: asDouble(j['percentUsed']),
    scope: asString(j['scope']),
  );
  final String name;
  final String level;
  final double percentUsed;
  final String scope;

  String get text =>
      '$name is at ${formatQty(percentUsed)}% of the '
      '${scope == 'ytd' ? 'year to date' : 'month'} budget'
      '${level == 'over' ? ', over the limit' : ''}.';
}

class BudgetVariance {
  const BudgetVariance({
    required this.fy,
    required this.month,
    required this.rows,
    required this.alerts,
  });
  factory BudgetVariance.fromJson(Json j) => BudgetVariance(
    fy: asString(j['fy']),
    month: asString(j['month']),
    rows: asJsonList(j['rows']).map(VarianceRow.fromJson).toList(),
    alerts: asJsonList(j['alerts']).map(BudgetAlert.fromJson).toList(),
  );
  final String fy;
  final String month;
  final List<VarianceRow> rows;
  final List<BudgetAlert> alerts;
}

// ------------------------------------------------------------------ Cheques

class Cheque {
  const Cheque({
    required this.id,
    required this.direction,
    required this.bankAccountId,
    required this.bankAccountName,
    required this.chequeNo,
    required this.chequeDate,
    required this.partyId,
    required this.partyName,
    required this.amount,
    required this.status,
    required this.paymentId,
    required this.bounceReason,
    required this.bounceCharges,
  });
  factory Cheque.fromJson(Json j) => Cheque(
    id: asString(j['id']),
    direction: asString(j['direction']),
    bankAccountId: asString(j['bankAccountId']),
    bankAccountName: asString(j['bankAccountName']),
    chequeNo: asString(j['chequeNo']),
    chequeDate: asString(j['chequeDate']),
    partyId: asString(j['partyId']),
    partyName: asString(j['partyName']),
    amount: asDouble(j['amount']),
    status: asString(j['status']),
    paymentId: asStringOrNull(j['paymentId']),
    bounceReason: asStringOrNull(j['bounceReason']),
    bounceCharges: asDouble(j['bounceCharges']),
  );
  final String id;
  final String direction;
  final String bankAccountId;
  final String bankAccountName;
  final String chequeNo;
  final String chequeDate;
  final String partyId;
  final String partyName;
  final double amount;
  final String status;
  final String? paymentId;
  final String? bounceReason;
  final double bounceCharges;

  bool get received => direction == 'received';

  /// Actions that make sense for the current status.
  List<String> get actions => switch (status) {
    'held' => [if (received) 'deposit', 'clear', 'bounce', 'cancel'],
    'deposited' => ['clear', 'bounce'],
    'cleared' => ['bounce'],
    _ => const [],
  };
}

class ChequeBook {
  const ChequeBook({
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.name,
    required this.prefix,
    required this.fromNo,
    required this.toNo,
    required this.used,
    required this.isActive,
  });
  factory ChequeBook.fromJson(Json j) => ChequeBook(
    id: asString(j['id']),
    accountId: asString(j['accountId']),
    accountName: asString(j['accountName']),
    name: asStringOrNull(j['name']),
    prefix: asString(j['prefix']),
    fromNo: asInt(j['fromNo']),
    toNo: asInt(j['toNo']),
    used: asInt(j['used']),
    isActive: asBool(j['isActive'], true),
  );
  final String id;
  final String accountId;
  final String accountName;
  final String? name;
  final String prefix;
  final int fromNo;
  final int toNo;
  final int used;
  final bool isActive;
  int get leaves => toNo - fromNo + 1;
}

class ChequeLeaf {
  const ChequeLeaf({
    required this.no,
    required this.status,
    this.payee,
    this.amount,
  });
  factory ChequeLeaf.fromJson(Json j) => ChequeLeaf(
    no: asString(j['no']),
    status: asString(j['status']),
    payee: asStringOrNull(j['payee']),
    amount: asDoubleOrNull(j['amount']),
  );
  final String no;
  final String status;
  final String? payee;
  final double? amount;
}

/// Positions in millimetres from the top left of the leaf.
class ChequeLayout {
  const ChequeLayout({
    required this.widthMm,
    required this.heightMm,
    required this.fields,
    required this.wordsMaxWidth,
    required this.dateGap,
    this.isDefault = true,
  });
  factory ChequeLayout.fromJson(Json j) {
    Json pt(String k) => asJson(j[k]);
    return ChequeLayout(
      widthMm: asDouble(j['widthMm'], 202),
      heightMm: asDouble(j['heightMm'], 92),
      fields: {
        for (final k in chequeLayoutFields)
          k: (asDouble(pt(k)['x']), asDouble(pt(k)['y'])),
      },
      wordsMaxWidth: asDouble(pt('words')['maxWidth'], 120),
      dateGap: asDouble(j['dateGap'], 5),
      isDefault: asBool(j['isDefault'], true),
    );
  }
  final double widthMm;
  final double heightMm;
  final Map<String, (double, double)> fields;
  final double wordsMaxWidth;
  final double dateGap;
  final bool isDefault;

  Json toJson() => {
    'widthMm': widthMm,
    'heightMm': heightMm,
    for (final e in fields.entries)
      e.key: {
        'x': e.value.$1,
        'y': e.value.$2,
        if (e.key == 'words') 'maxWidth': wordsMaxWidth,
      },
    'dateGap': dateGap,
  };
}

const List<String> chequeLayoutFields = [
  'date',
  'payee',
  'words',
  'amount',
  'acPayee',
];

const Map<String, String> chequeFieldLabels = {
  'date': 'Date',
  'payee': 'Payee',
  'words': 'Amount in words',
  'amount': 'Amount in figures',
  'acPayee': 'A/C payee line',
};

class ChequePrint {
  const ChequePrint({
    required this.layout,
    required this.chequeNo,
    required this.dateText,
    required this.payee,
    required this.amount,
  });
  factory ChequePrint.fromJson(Json j) => ChequePrint(
    layout: ChequeLayout.fromJson(asJson(j['layout'])),
    chequeNo: asString(j['chequeNo']),
    dateText: asString(j['dateText']),
    payee: asString(j['payee']),
    amount: asDouble(j['amount']),
  );
  final ChequeLayout layout;
  final String chequeNo;

  /// DDMMYYYY, one box per digit on the leaf.
  final String dateText;
  final String payee;
  final double amount;
}

String chequeStatusLabel(String s) => switch (s) {
  'held' => 'Held',
  'deposited' => 'Deposited',
  'cleared' => 'Cleared',
  'bounced' => 'Bounced',
  'cancelled' => 'Cancelled',
  _ => s,
};
