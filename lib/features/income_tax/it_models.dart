import '../../core/json.dart';
import '../fixed_assets/fa_models.dart';

/// `TaxPayment` (API v1.6 §6).
class TaxPayment {
  const TaxPayment({
    required this.id,
    required this.number,
    required this.kind,
    required this.taxYear,
    required this.date,
    required this.amount,
    required this.bsrCode,
    required this.challanSerial,
    required this.paidFromAccountName,
    required this.status,
    this.cin,
  });

  factory TaxPayment.fromJson(Json j) => TaxPayment(
    id: asString(j['id']),
    number: asString(j['number']),
    kind: asString(j['kind']),
    taxYear: asString(j['taxYear']),
    date: asString(j['date']),
    amount: asDouble(j['amount']),
    bsrCode: asString(j['bsrCode']),
    challanSerial: asString(j['challanSerial']),
    cin: asStringOrNull(j['cin']),
    paidFromAccountName: asString(j['paidFromAccountName']),
    status: asString(j['status'], 'posted'),
  );

  final String id;
  final String number;

  /// `advance_tax`, `self_assessment` or `other`.
  final String kind;
  final String taxYear;
  final String date;
  final double amount;
  final String bsrCode;
  final String challanSerial;
  final String? cin;
  final String paidFromAccountName;
  final String status;

  bool get cancelled => status == 'cancelled';
  String get kindLabel => taxKindLabels[kind] ?? kind;
}

const Map<String, String> taxKindLabels = {
  'advance_tax': 'Advance tax',
  'self_assessment': 'Self-assessment tax',
  'other': 'Other',
};

class TaxSlab {
  const TaxSlab({
    required this.from,
    this.to,
    required this.rate,
    required this.tax,
  });

  factory TaxSlab.fromJson(Json j) => TaxSlab(
    from: asDouble(j['from']),
    to: asDoubleOrNull(j['to']),
    rate: asDouble(j['rate']),
    tax: asDouble(j['tax']),
  );

  final double from;
  final double? to;
  final double rate;
  final double tax;
}

class TaxCalc {
  const TaxCalc({
    required this.taxable,
    required this.slabs,
    required this.baseTax,
    required this.rebate,
    required this.surcharge,
    required this.cess,
    required this.total,
  });

  factory TaxCalc.fromJson(Json j) => TaxCalc(
    taxable: asDouble(j['taxable']),
    slabs: asJsonList(j['slabs']).map(TaxSlab.fromJson).toList(),
    baseTax: asDouble(j['baseTax']),
    rebate: asDouble(j['rebate']),
    surcharge: asDouble(j['surcharge']),
    cess: asDouble(j['cess']),
    total: asDouble(j['total']),
  );

  final double taxable;
  final List<TaxSlab> slabs;
  final double baseTax;
  final double rebate;
  final double surcharge;
  final double cess;
  final double total;
}

class RegimeResult {
  const RegimeResult({
    required this.taxYear,
    required this.newRegime,
    required this.oldRegime,
    required this.better,
    required this.saving,
    this.unverified = const [],
  });

  factory RegimeResult.fromJson(Json j) => RegimeResult(
    taxYear: asString(j['taxYear']),
    newRegime: TaxCalc.fromJson(asJson(j['new'])),
    oldRegime: TaxCalc.fromJson(asJson(j['old'])),
    better: asString(j['better'], 'new'),
    saving: asDouble(j['saving']),
    unverified: asStringList(j['unverified']),
  );

  final String taxYear;
  final TaxCalc newRegime;
  final TaxCalc oldRegime;

  /// `new` or `old`.
  final String better;
  final double saving;
  final List<String> unverified;
}

class PresumptiveResult {
  const PresumptiveResult({
    required this.eligible,
    required this.limit,
    required this.deemedIncome,
    required this.declaredBelowDeemed,
    this.auditRisk,
    this.notes = const [],
    this.unverified = const [],
  });

  factory PresumptiveResult.fromJson(Json j) => PresumptiveResult(
    eligible: asBool(j['eligible']),
    limit: asDouble(j['limit']),
    deemedIncome: asDouble(j['deemedIncome']),
    declaredBelowDeemed: asBool(j['declaredBelowDeemed']),
    auditRisk: asStringOrNull(j['auditRisk']),
    notes: asStringList(j['notes']),
    unverified: asStringList(j['unverified']),
  );

  final bool eligible;
  final double limit;
  final double deemedIncome;
  final bool declaredBelowDeemed;
  final String? auditRisk;
  final List<String> notes;
  final List<String> unverified;
}

class Instalment {
  const Instalment({
    required this.dueDate,
    required this.cumulativePct,
    required this.cumulativeDue,
    required this.paidByDate,
    required this.shortfall,
    required this.interest425,
  });

  factory Instalment.fromJson(Json j) => Instalment(
    dueDate: asString(j['dueDate']),
    cumulativePct: asDouble(j['cumulativePct']),
    cumulativeDue: asDouble(j['cumulativeDue']),
    paidByDate: asDouble(j['paidByDate']),
    shortfall: asDouble(j['shortfall']),
    interest425: asDouble(j['interest425']),
  );

  final String dueDate;
  final double cumulativePct;
  final double cumulativeDue;
  final double paidByDate;
  final double shortfall;
  final double interest425;
}

class AdvanceTax {
  const AdvanceTax({
    required this.taxYear,
    required this.entity,
    required this.estimatedIncome,
    required this.tax,
    required this.tdsCredit,
    required this.netTax,
    required this.required,
    required this.instalments,
    required this.interest424,
    required this.paid,
    required this.balance,
    this.unverified = const [],
  });

  factory AdvanceTax.fromJson(Json j) => AdvanceTax(
    taxYear: asString(j['taxYear']),
    entity: asString(j['entity']),
    estimatedIncome: asDouble(j['estimatedIncome']),
    tax: TaxCalc.fromJson(asJson(j['tax'])),
    tdsCredit: asDouble(j['tdsCredit']),
    netTax: asDouble(j['netTax']),
    required: asBool(j['required']),
    instalments: asJsonList(j['instalments']).map(Instalment.fromJson).toList(),
    interest424: asDouble(j['interest424']),
    paid: asDouble(j['paid']),
    balance: asDouble(j['balance']),
    unverified: asStringList(j['unverified']),
  );

  final String taxYear;
  final String entity;
  final double estimatedIncome;
  final TaxCalc tax;
  final double tdsCredit;
  final double netTax;
  final bool required;
  final List<Instalment> instalments;
  final double interest424;
  final double paid;
  final double balance;
  final List<String> unverified;
}

class PackLine {
  const PackLine({
    required this.schedule,
    required this.label,
    required this.amount,
    this.accounts = const [],
  });

  factory PackLine.fromJson(Json j) => PackLine(
    schedule: asString(j['schedule']),
    label: asString(j['label']),
    amount: asDouble(j['amount']),
    accounts: asStringList(j['accounts']),
  );

  final String schedule;
  final String label;
  final double amount;
  final List<String> accounts;
}

/// A block of named totals and the lines behind them (P&L, balance sheet).
class PackStatement {
  const PackStatement({required this.totals, required this.lines});

  factory PackStatement.fromJson(Json j) => PackStatement(
    totals: {
      for (final e in j.entries)
        if (e.key != 'lines' && e.value is num) e.key: asDouble(e.value),
    },
    lines: asJsonList(j['lines']).map(PackLine.fromJson).toList(),
  );

  final Map<String, double> totals;
  final List<PackLine> lines;
}

class Adjustment {
  const Adjustment({
    required this.label,
    required this.amount,
    required this.kind,
    this.reason = '',
  });

  factory Adjustment.fromJson(Json j) => Adjustment(
    label: asString(j['label']),
    amount: asDouble(j['amount']),
    kind: asString(j['kind'], 'add'),
    reason: asString(j['reason']),
  );

  final String label;
  final double amount;

  /// `add` or `less`.
  final String kind;
  final String reason;
}

class TdsCredit {
  const TdsCredit({required this.deductorName, this.tan, required this.amount});

  factory TdsCredit.fromJson(Json j) => TdsCredit(
    deductorName: asString(j['deductorName']),
    tan: asStringOrNull(j['tan']),
    amount: asDouble(j['amount']),
  );

  final String deductorName;
  final String? tan;
  final double amount;
}

class ItrPack {
  const ItrPack({
    required this.taxYear,
    required this.form,
    required this.entity,
    required this.companyName,
    required this.companyPan,
    required this.companyGstin,
    required this.companyAddress,
    required this.pnl,
    required this.balanceSheet,
    required this.depreciation,
    required this.adjustments,
    required this.tdsCredits,
    required this.taxesPaid,
    required this.incomeEstimate,
    required this.steps,
    required this.warnings,
    required this.unverified,
    this.presumptive,
  });

  factory ItrPack.fromJson(Json j) {
    final c = asJson(j['company'] ?? const {});
    return ItrPack(
      taxYear: asString(j['taxYear']),
      form: asString(j['form']),
      entity: asString(j['entity']),
      companyName: asString(c['name']),
      companyPan: asString(c['pan']),
      companyGstin: asString(c['gstin']),
      companyAddress: asString(c['address']),
      pnl: PackStatement.fromJson(asJson(j['pnl'] ?? const {})),
      balanceSheet: PackStatement.fromJson(
        asJson(j['balanceSheet'] ?? const {}),
      ),
      depreciation: asJsonList(
        j['depreciation'],
      ).map(ItBlockRow.fromJson).toList(),
      adjustments: asJsonList(
        j['adjustments'],
      ).map(Adjustment.fromJson).toList(),
      presumptive: asJsonOrNull(j['presumptive']),
      tdsCredits: asJsonList(j['tdsCredits']).map(TdsCredit.fromJson).toList(),
      taxesPaid: asJsonList(j['taxesPaid']).map(TaxPayment.fromJson).toList(),
      incomeEstimate: asDouble(j['incomeEstimate']),
      steps: asStringList(j['steps']),
      warnings: asStringList(j['warnings']),
      unverified: asStringList(j['unverified']),
    );
  }

  final String taxYear;
  final String form;
  final String entity;
  final String companyName;
  final String companyPan;
  final String companyGstin;
  final String companyAddress;
  final PackStatement pnl;
  final PackStatement balanceSheet;
  final List<ItBlockRow> depreciation;
  final List<Adjustment> adjustments;
  final Json? presumptive;
  final List<TdsCredit> tdsCredits;
  final List<TaxPayment> taxesPaid;
  final double incomeEstimate;
  final List<String> steps;
  final List<String> warnings;
  final List<String> unverified;
}

class CaItem {
  const CaItem({
    required this.id,
    required this.severity,
    required this.title,
    required this.reason,
    this.law = '',
    this.canSelfFile,
  });

  factory CaItem.fromJson(Json j) => CaItem(
    id: asString(j['id']),
    severity: asString(j['severity'], 'advised'),
    title: asString(j['title']),
    reason: asString(j['reason']),
    law: asString(j['law']),
    canSelfFile: asStringOrNull(j['canSelfFile']),
  );

  final String id;

  /// `required` or `advised`.
  final String severity;
  final String title;
  final String reason;
  final String law;
  final String? canSelfFile;

  bool get isRequired => severity == 'required';
}

class CaRequired {
  const CaRequired({
    required this.taxYear,
    required this.needed,
    required this.items,
    required this.figures,
  });

  factory CaRequired.fromJson(Json j) => CaRequired(
    taxYear: asString(j['taxYear']),
    needed: asBool(j['needed']),
    items: asJsonList(j['items']).map(CaItem.fromJson).toList(),
    figures: asJson(j['figures'] ?? const {}),
  );

  final String taxYear;
  final bool needed;
  final List<CaItem> items;
  final Json figures;
}

// ----------------------------------------------------------- TDS filing pack

class TdsDepositDefault {
  const TdsDepositDefault({
    required this.month,
    required this.deducted,
    this.depositDate,
    required this.dueDate,
    required this.monthsLate,
    required this.interest,
  });

  factory TdsDepositDefault.fromJson(Json j) => TdsDepositDefault(
    month: asString(j['month']),
    deducted: asDouble(j['deducted']),
    depositDate: asStringOrNull(j['depositDate']),
    dueDate: asString(j['dueDate']),
    monthsLate: asInt(j['monthsLate']),
    interest: asDouble(j['interest']),
  );

  final String month;
  final double deducted;
  final String? depositDate;
  final String dueDate;
  final int monthsLate;
  final double interest;
}

class TdsStatementDefault {
  const TdsStatementDefault({
    required this.quarter,
    required this.dueDate,
    this.filedOn,
    required this.daysLate,
    required this.lateFee,
  });

  factory TdsStatementDefault.fromJson(Json j) => TdsStatementDefault(
    quarter: asInt(j['quarter']),
    dueDate: asString(j['dueDate']),
    filedOn: asStringOrNull(j['filedOn']),
    daysLate: asInt(j['daysLate']),
    lateFee: asDouble(j['lateFee']),
  );

  final int quarter;
  final String dueDate;
  final String? filedOn;
  final int daysLate;
  final double lateFee;
}

class TdsDefaults {
  const TdsDefaults({
    required this.fy,
    required this.deposits,
    required this.statements,
    required this.interest,
    required this.lateFee,
    this.unverified = const [],
  });

  factory TdsDefaults.fromJson(Json j) {
    final t = asJson(j['totals'] ?? const {});
    return TdsDefaults(
      fy: asString(j['fy']),
      deposits: asJsonList(
        j['deposits'],
      ).map(TdsDepositDefault.fromJson).toList(),
      statements: asJsonList(
        j['statements'],
      ).map(TdsStatementDefault.fromJson).toList(),
      interest: asDouble(t['interest']),
      lateFee: asDouble(t['lateFee']),
      unverified: asStringList(j['unverified']),
    );
  }

  final String fy;
  final List<TdsDepositDefault> deposits;
  final List<TdsStatementDefault> statements;
  final double interest;
  final double lateFee;
  final List<String> unverified;
}
