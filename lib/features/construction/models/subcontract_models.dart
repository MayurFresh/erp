import '../../../core/json.dart';
import 'common_models.dart';

/// Rounds to paise, half up (the server rule for every amount).
double round2(double value) => (value * 100 + 1e-7).roundToDouble() / 100;

/// `min(advanceBalance, 50% of gross)` rounded down to paise: the cap on a
/// wage-sheet advance recovery (Code on Wages).
double advanceCap(double advanceBalance, double gross) {
  final half = (gross * 50).floorToDouble() / 100;
  return advanceBalance < half ? advanceBalance : half;
}

// ---------------------------------------------------------- labour advances

enum LabourAdvanceStatus {
  open('Open'),
  recovered('Recovered'),
  cancelled('Cancelled');

  const LabourAdvanceStatus(this.label);

  final String label;

  static LabourAdvanceStatus parse(Object? value) => values.firstWhere(
    (s) => s.name == value,
    orElse: () => LabourAdvanceStatus.open,
  );
}

class AdvanceRecovery {
  const AdvanceRecovery({
    required this.wageSheetId,
    required this.wageSheetNumber,
    this.date,
    this.amount = 0,
  });

  factory AdvanceRecovery.fromJson(Json json) => AdvanceRecovery(
    wageSheetId: asString(json['wageSheetId']),
    wageSheetNumber: asString(json['wageSheetNumber']),
    date: asStringOrNull(json['date']),
    amount: asDouble(json['amount']),
  );

  final String wageSheetId;
  final String wageSheetNumber;
  final String? date;
  final double amount;
}

class LabourAdvance {
  const LabourAdvance({
    required this.id,
    required this.number,
    required this.workerId,
    required this.workerName,
    this.siteId,
    this.siteName,
    this.date,
    this.amount = 0,
    this.recovered = 0,
    this.balance = 0,
    this.paidFromAccountId,
    this.paidFromAccountName,
    this.notes,
    this.status = LabourAdvanceStatus.open,
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
    this.recoveries,
  });

  factory LabourAdvance.fromJson(Json json) => LabourAdvance(
    id: asString(json['id']),
    number: asString(json['number']),
    workerId: asString(json['workerId']),
    workerName: asString(json['workerName']),
    siteId: asStringOrNull(json['siteId']),
    siteName: asStringOrNull(json['siteName']),
    date: asStringOrNull(json['date']),
    amount: asDouble(json['amount']),
    recovered: asDouble(json['recovered']),
    balance: asDouble(json['balance']),
    paidFromAccountId: asStringOrNull(json['paidFromAccountId']),
    paidFromAccountName: asStringOrNull(json['paidFromAccountName']),
    notes: asStringOrNull(json['notes']),
    status: LabourAdvanceStatus.parse(json['status']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: NamedRef.fromJsonOrNull(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    recoveries: json['recoveries'] is List
        ? asJsonList(json['recoveries']).map(AdvanceRecovery.fromJson).toList()
        : null,
  );

  final String id;
  final String number;
  final String workerId;
  final String workerName;
  final String? siteId;
  final String? siteName;
  final String? date;
  final double amount;
  final double recovered;
  final double balance;
  final String? paidFromAccountId;
  final String? paidFromAccountName;
  final String? notes;
  final LabourAdvanceStatus status;
  final DateTime? createdAt;
  final NamedRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  /// Detail only.
  final List<AdvanceRecovery>? recoveries;

  /// Only while nothing is recovered (`409` otherwise).
  bool get canCancel =>
      status != LabourAdvanceStatus.cancelled && recovered <= 0;
}

// -------------------------------------------------------------- work orders

enum WorkOrderStatus {
  draft('Draft'),
  active('Active'),
  closed('Closed'),
  cancelled('Cancelled');

  const WorkOrderStatus(this.label);

  final String label;

  static WorkOrderStatus parse(Object? value) => values.firstWhere(
    (s) => s.name == value,
    orElse: () => WorkOrderStatus.draft,
  );
}

class WorkOrderLine {
  const WorkOrderLine({
    required this.id,
    this.lineNo = 0,
    this.boqLineId,
    this.boqCode,
    required this.description,
    this.unit = '',
    this.qty = 0,
    this.rate = 0,
    this.amount = 0,
    this.billedQty = 0,
  });

  factory WorkOrderLine.fromJson(Json json) => WorkOrderLine(
    id: asString(json['id']),
    lineNo: asInt(json['lineNo']),
    boqLineId: asStringOrNull(json['boqLineId']),
    boqCode: asStringOrNull(json['boqCode']),
    description: asString(json['description']),
    unit: asString(json['unit']),
    qty: asDouble(json['qty']),
    rate: asDouble(json['rate']),
    amount: asDouble(json['amount']),
    billedQty: asDouble(json['billedQty']),
  );

  final String id;
  final int lineNo;
  final String? boqLineId;
  final String? boqCode;
  final String description;
  final String unit;
  final double qty;
  final double rate;
  final double amount;

  /// `cumQty` on the latest approved RA bill.
  final double billedQty;

  double get billedPct => qty <= 0 ? 0 : clampPct(billedQty / qty * 100);
}

class AdvanceSummary {
  const AdvanceSummary({this.paid = 0, this.recovered = 0, this.balance = 0});

  factory AdvanceSummary.fromJson(Json? json) => AdvanceSummary(
    paid: asDouble(json?['paid']),
    recovered: asDouble(json?['recovered']),
    balance: asDouble(json?['balance']),
  );

  final double paid;
  final double recovered;
  final double balance;
}

class RetentionSummary {
  const RetentionSummary({this.held = 0, this.released = 0, this.balance = 0});

  factory RetentionSummary.fromJson(Json? json) => RetentionSummary(
    held: asDouble(json?['held']),
    released: asDouble(json?['released']),
    balance: asDouble(json?['balance']),
  );

  final double held;
  final double released;
  final double balance;
}

class WorkOrder {
  const WorkOrder({
    required this.id,
    required this.number,
    required this.projectId,
    this.projectName = '',
    required this.contractorPartyId,
    this.contractorName = '',
    this.date,
    required this.title,
    this.scope,
    this.status = WorkOrderStatus.draft,
    this.retentionPct = 0,
    this.advanceRecoveryPct = 0,
    this.tdsPct = 0,
    this.gstPct = 0,
    this.itcEligible = true,
    this.cessPct = 0,
    this.totalValue = 0,
    this.billedGross = 0,
    this.hasFinalBill = false,
    this.advance = const AdvanceSummary(),
    this.retention = const RetentionSummary(),
    this.lines,
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
  });

  factory WorkOrder.fromJson(Json json) => WorkOrder(
    id: asString(json['id']),
    number: asString(json['number']),
    projectId: asString(json['projectId']),
    projectName: asString(json['projectName']),
    contractorPartyId: asString(json['contractorPartyId']),
    contractorName: asString(json['contractorName']),
    date: asStringOrNull(json['date']),
    title: asString(json['title']),
    scope: asStringOrNull(json['scope']),
    status: WorkOrderStatus.parse(json['status']),
    retentionPct: asDouble(json['retentionPct']),
    advanceRecoveryPct: asDouble(json['advanceRecoveryPct']),
    tdsPct: asDouble(json['tdsPct']),
    gstPct: asDouble(json['gstPct']),
    itcEligible: asBool(json['itcEligible'], true),
    cessPct: asDouble(json['cessPct']),
    totalValue: asDouble(json['totalValue']),
    billedGross: asDouble(json['billedGross']),
    hasFinalBill: asBool(json['hasFinalBill']),
    advance: AdvanceSummary.fromJson(asJsonOrNull(json['advance'])),
    retention: RetentionSummary.fromJson(asJsonOrNull(json['retention'])),
    lines: json['lines'] is List
        ? asJsonList(json['lines']).map(WorkOrderLine.fromJson).toList()
        : null,
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: NamedRef.fromJsonOrNull(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
  );

  final String id;
  final String number;
  final String projectId;
  final String projectName;
  final String contractorPartyId;
  final String contractorName;
  final String? date;
  final String title;
  final String? scope;
  final WorkOrderStatus status;

  /// Percentages are 0–100.
  final double retentionPct;
  final double advanceRecoveryPct;
  final double tdsPct;
  final double gstPct;
  final bool itcEligible;
  final double cessPct;
  final double totalValue;
  final double billedGross;
  final bool hasFinalBill;
  final AdvanceSummary advance;
  final RetentionSummary retention;

  /// Detail only.
  final List<WorkOrderLine>? lines;
  final DateTime? createdAt;
  final NamedRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  bool get isDraft => status == WorkOrderStatus.draft;
  bool get isActive => status == WorkOrderStatus.active;

  /// Share of the contract value billed (approved bills), 0–100.
  double get billedPct =>
      totalValue <= 0 ? 0 : clampPct(billedGross / totalValue * 100);
}

class ContractorAdvance {
  const ContractorAdvance({
    required this.id,
    required this.number,
    this.date,
    this.amount = 0,
    this.paidFromAccountName,
    this.notes,
    this.cancelledAt,
    this.cancelReason,
  });

  factory ContractorAdvance.fromJson(Json json) => ContractorAdvance(
    id: asString(json['id']),
    number: asString(json['number']),
    date: asStringOrNull(json['date']),
    amount: asDouble(json['amount']),
    paidFromAccountName: asStringOrNull(json['paidFromAccountName']),
    notes: asStringOrNull(json['notes']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
  );

  final String id;
  final String number;
  final String? date;
  final double amount;
  final String? paidFromAccountName;
  final String? notes;
  final DateTime? cancelledAt;
  final String? cancelReason;

  bool get isCancelled => cancelledAt != null;
}

class RetentionRelease {
  const RetentionRelease({
    required this.id,
    required this.number,
    this.date,
    this.amount = 0,
    this.notes,
  });

  factory RetentionRelease.fromJson(Json json) => RetentionRelease(
    id: asString(json['id']),
    number: asString(json['number']),
    date: asStringOrNull(json['date']),
    amount: asDouble(json['amount']),
    notes: asStringOrNull(json['notes']),
  );

  final String id;
  final String number;
  final String? date;
  final double amount;
  final String? notes;
}

// ----------------------------------------------------------------- RA bills

enum RaBillStatus {
  draft('Draft'),
  submitted('Submitted'),
  approved('Approved'),
  cancelled('Cancelled');

  const RaBillStatus(this.label);

  final String label;

  static RaBillStatus parse(Object? value) => values.firstWhere(
    (s) => s.name == value,
    orElse: () => RaBillStatus.draft,
  );
}

enum RaPaymentStatus {
  unpaid('Unpaid'),
  partial('Part paid'),
  paid('Paid');

  const RaPaymentStatus(this.label);

  final String label;

  static RaPaymentStatus parse(Object? value) => values.firstWhere(
    (s) => s.name == value,
    orElse: () => RaPaymentStatus.unpaid,
  );
}

class RaBillLine {
  const RaBillLine({
    required this.workOrderLineId,
    required this.description,
    this.unit = '',
    this.rate = 0,
    this.qty = 0,
    this.prevQty = 0,
    this.cumQty = 0,
    this.thisQty = 0,
    this.amount = 0,
  });

  factory RaBillLine.fromJson(Json json) => RaBillLine(
    workOrderLineId: asString(json['workOrderLineId']),
    description: asString(json['description']),
    unit: asString(json['unit']),
    rate: asDouble(json['rate']),
    qty: asDouble(json['qty']),
    prevQty: asDouble(json['prevQty']),
    cumQty: asDouble(json['cumQty']),
    thisQty: asDouble(json['thisQty']),
    amount: asDouble(json['amount']),
  );

  final String workOrderLineId;
  final String description;
  final String unit;
  final double rate;

  /// Work-order quantity (the ceiling for [cumQty]).
  final double qty;
  final double prevQty;
  final double cumQty;
  final double thisQty;
  final double amount;
}

class RaBill {
  const RaBill({
    required this.id,
    this.number = '',
    required this.workOrderId,
    this.workOrderNumber = '',
    this.projectId = '',
    this.projectName = '',
    this.contractorPartyId = '',
    this.contractorName = '',
    this.billSeq = 0,
    this.date,
    this.periodFrom,
    this.periodTo,
    this.dueDate,
    this.status = RaBillStatus.draft,
    this.isFinal = false,
    this.lines,
    this.gross = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.invoiceTotal = 0,
    this.retention = 0,
    this.advanceRecovery = 0,
    this.tds = 0,
    this.cess = 0,
    this.otherDeduction = 0,
    this.otherDeductionNote,
    this.totalDeductions = 0,
    this.netPayable = 0,
    this.amountPaid = 0,
    this.amountDue = 0,
    this.paymentStatus = RaPaymentStatus.unpaid,
    this.notes,
    this.rejectReason,
    this.createdAt,
    this.createdBy,
    this.submittedAt,
    this.approvedAt,
    this.approvedBy,
    this.cancelledAt,
    this.cancelReason,
  });

  factory RaBill.fromJson(Json json) => RaBill(
    id: asString(json['id']),
    number: asString(json['number']),
    workOrderId: asString(json['workOrderId']),
    workOrderNumber: asString(json['workOrderNumber']),
    projectId: asString(json['projectId']),
    projectName: asString(json['projectName']),
    contractorPartyId: asString(json['contractorPartyId']),
    contractorName: asString(json['contractorName']),
    billSeq: asInt(json['billSeq']),
    date: asStringOrNull(json['date']),
    periodFrom: asStringOrNull(json['periodFrom']),
    periodTo: asStringOrNull(json['periodTo']),
    dueDate: asStringOrNull(json['dueDate']),
    status: RaBillStatus.parse(json['status']),
    isFinal: asBool(json['isFinal']),
    lines: json['lines'] is List
        ? asJsonList(json['lines']).map(RaBillLine.fromJson).toList()
        : null,
    gross: asDouble(json['gross']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    invoiceTotal: asDouble(json['invoiceTotal']),
    retention: asDouble(json['retention']),
    advanceRecovery: asDouble(json['advanceRecovery']),
    tds: asDouble(json['tds']),
    cess: asDouble(json['cess']),
    otherDeduction: asDouble(json['otherDeduction']),
    otherDeductionNote: asStringOrNull(json['otherDeductionNote']),
    totalDeductions: asDouble(json['totalDeductions']),
    netPayable: asDouble(json['netPayable']),
    amountPaid: asDouble(json['amountPaid']),
    amountDue: asDouble(json['amountDue']),
    paymentStatus: RaPaymentStatus.parse(json['paymentStatus']),
    notes: asStringOrNull(json['notes']),
    rejectReason: asStringOrNull(json['rejectReason']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: NamedRef.fromJsonOrNull(json['createdBy']),
    submittedAt: asDateTimeOrNull(json['submittedAt']),
    approvedAt: asDateTimeOrNull(json['approvedAt']),
    approvedBy: NamedRef.fromJsonOrNull(json['approvedBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
  );

  final String id;
  final String number;
  final String workOrderId;
  final String workOrderNumber;
  final String projectId;
  final String projectName;
  final String contractorPartyId;
  final String contractorName;
  final int billSeq;
  final String? date;
  final String? periodFrom;
  final String? periodTo;
  final String? dueDate;
  final RaBillStatus status;
  final bool isFinal;

  /// Detail (and template) only.
  final List<RaBillLine>? lines;
  final double gross;
  final double cgst;
  final double sgst;
  final double igst;
  final double invoiceTotal;
  final double retention;
  final double advanceRecovery;
  final double tds;
  final double cess;
  final double otherDeduction;
  final String? otherDeductionNote;
  final double totalDeductions;
  final double netPayable;
  final double amountPaid;
  final double amountDue;
  final RaPaymentStatus paymentStatus;
  final String? notes;
  final String? rejectReason;
  final DateTime? createdAt;
  final NamedRef? createdBy;
  final DateTime? submittedAt;
  final DateTime? approvedAt;
  final NamedRef? approvedBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  bool get isDraft => status == RaBillStatus.draft;

  double get gst => round2(cgst + sgst + igst);
}

// -------------------------------------------------------------------- maths

/// One measurement line for [RaBillMath]: the work-order rate, the previous
/// cumulative quantity and the cumulative quantity measured now.
class RaMeasure {
  const RaMeasure({
    required this.rate,
    required this.prevQty,
    required this.cumQty,
  });

  final double rate;
  final double prevQty;
  final double cumQty;

  double get thisQty => cumQty - prevQty;

  /// `thisQty × rate`, to paise.
  double get amount => round2(thisQty * rate);
}

/// Percentages and balances of the work order that drive the default
/// deductions.
class RaTerms {
  const RaTerms({
    this.gstPct = 0,
    this.retentionPct = 0,
    this.advanceRecoveryPct = 0,
    this.tdsPct = 0,
    this.cessPct = 0,
    this.advanceBalance = 0,
  });

  factory RaTerms.of(WorkOrder wo) => RaTerms(
    gstPct: wo.gstPct,
    retentionPct: wo.retentionPct,
    advanceRecoveryPct: wo.advanceRecoveryPct,
    tdsPct: wo.tdsPct,
    cessPct: wo.cessPct,
    advanceBalance: wo.advance.balance,
  );

  final double gstPct;
  final double retentionPct;
  final double advanceRecoveryPct;
  final double tdsPct;
  final double cessPct;
  final double advanceBalance;
}

/// The API v1.3 RA bill calculation, for the live preview in the form.
/// The server stays authoritative.
class RaBillMath {
  const RaBillMath({
    required this.gross,
    required this.gst,
    required this.retention,
    required this.advanceRecovery,
    required this.tds,
    required this.cess,
    required this.otherDeduction,
  });

  /// [overrides] holds the deductions the user typed (`retention`,
  /// `advanceRecovery`, `tds`, `cess`, `otherDeduction`); the others use
  /// the defaults on gross. TDS is on the amount excluding GST.
  factory RaBillMath.compute(
    Iterable<RaMeasure> lines,
    RaTerms terms, {
    Map<String, double> overrides = const {},
  }) {
    final gross = round2(lines.fold(0.0, (sum, l) => sum + l.amount));
    double pct(double p) => round2(gross * p / 100);
    final advanceDefault = round2(
      [
        terms.advanceBalance,
        gross * terms.advanceRecoveryPct / 100,
      ].reduce((a, b) => a < b ? a : b),
    );
    return RaBillMath(
      gross: gross,
      gst: pct(terms.gstPct),
      retention: overrides['retention'] ?? pct(terms.retentionPct),
      advanceRecovery: overrides['advanceRecovery'] ?? advanceDefault,
      tds: overrides['tds'] ?? pct(terms.tdsPct),
      cess: overrides['cess'] ?? pct(terms.cessPct),
      otherDeduction: overrides['otherDeduction'] ?? 0,
    );
  }

  final double gross;

  /// CGST + SGST + IGST.
  final double gst;
  final double retention;
  final double advanceRecovery;
  final double tds;
  final double cess;
  final double otherDeduction;

  double get invoiceTotal => round2(gross + gst);

  double get totalDeductions =>
      round2(retention + advanceRecovery + tds + cess + otherDeduction);

  /// `gross + GST − retention − advance recovery − TDS − cess − other`.
  double get netPayable => round2(invoiceTotal - totalDeductions);

  /// A negative net payable is a `400`.
  bool get isNegative => netPayable < 0;
}
