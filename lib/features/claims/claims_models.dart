import '../../core/json.dart';

class ClaimCategory {
  const ClaimCategory({
    required this.id,
    required this.name,
    required this.gstItcAllowed,
    required this.requiresReceipt,
    required this.isActive,
    this.perClaimLimit,
    this.monthlyLimit,
    this.expenseAccountName = '',
  });

  factory ClaimCategory.fromJson(Json j) => ClaimCategory(
    id: asString(j['id']),
    name: asString(j['name']),
    gstItcAllowed: asBool(j['gstItcAllowed']),
    requiresReceipt: asBool(j['requiresReceipt']),
    isActive: asBool(j['isActive'], true),
    perClaimLimit: j['perClaimLimit'] == null ? null : asDouble(j['perClaimLimit']),
    monthlyLimit: j['monthlyLimit'] == null ? null : asDouble(j['monthlyLimit']),
    expenseAccountName: asString(j['expenseAccountName']),
  );

  final String id;
  final String name;
  final bool gstItcAllowed;
  final bool requiresReceipt;
  final bool isActive;
  final double? perClaimLimit;
  final double? monthlyLimit;
  final String expenseAccountName;
}

class ClaimLine {
  const ClaimLine({
    required this.categoryId,
    required this.categoryName,
    required this.expenseDate,
    required this.description,
    required this.amount,
    this.vendorGstin,
    this.gstAmount = 0,
    this.itcEligible = false,
    this.receiptFileId,
  });

  factory ClaimLine.fromJson(Json j) => ClaimLine(
    categoryId: asString(j['categoryId']),
    categoryName: asString(j['categoryName']),
    expenseDate: asString(j['expenseDate']),
    description: asString(j['description']),
    amount: asDouble(j['amount']),
    vendorGstin: asStringOrNull(j['vendorGstin']),
    gstAmount: asDouble(j['gstAmount']),
    itcEligible: asBool(j['itcEligible']),
    receiptFileId: asStringOrNull(j['receiptFileId']),
  );

  final String categoryId;
  final String categoryName;
  final String expenseDate;
  final String description;
  final double amount;
  final String? vendorGstin;
  final double gstAmount;
  final bool itcEligible;
  final String? receiptFileId;

  Json toBody() => {
    'categoryId': categoryId,
    'expenseDate': expenseDate,
    'description': description,
    'amount': amount,
    if ((vendorGstin ?? '').isNotEmpty) 'vendorGstin': vendorGstin,
    if (gstAmount > 0) 'gstAmount': gstAmount,
    if (receiptFileId != null) 'receiptFileId': receiptFileId,
  };
}

class Claim {
  const Claim({
    required this.id,
    required this.number,
    required this.employeeName,
    required this.purpose,
    required this.claimDate,
    required this.status,
    required this.total,
    required this.gstTotal,
    required this.lines,
    required this.canApprove,
    this.settlement,
    this.decisionNote,
    this.payDate,
  });

  factory Claim.fromJson(Json j) => Claim(
    id: asString(j['id']),
    number: asString(j['number']),
    employeeName: asString(j['employeeName']),
    purpose: asString(j['purpose']),
    claimDate: asString(j['claimDate']),
    status: asString(j['status']),
    total: asDouble(j['total']),
    gstTotal: asDouble(j['gstTotal']),
    lines: asJsonList(j['lines']).map(ClaimLine.fromJson).toList(),
    canApprove: asBool(j['canApprove']),
    settlement: asStringOrNull(j['settlement']),
    decisionNote: asStringOrNull(j['decisionNote']),
    payDate: asStringOrNull(j['payDate']),
  );

  final String id;
  final String number;
  final String employeeName;
  final String purpose;
  final String claimDate;
  final String status;
  final double total;
  final double gstTotal;
  final List<ClaimLine> lines;
  final bool canApprove;
  final String? settlement;
  final String? decisionNote;
  final String? payDate;

  bool get editable => status == 'draft' || status == 'rejected';
}

class SummaryRow {
  const SummaryRow(this.label, this.count, this.total);

  factory SummaryRow.fromJson(Json j) =>
      SummaryRow(asString(j['label']), asInt(j['count']), asDouble(j['total']));

  final String label;
  final int count;
  final double total;
}

class ScheduleRow {
  const ScheduleRow({
    required this.seq,
    required this.dueMonth,
    required this.principal,
    required this.interest,
    required this.amount,
    required this.status,
    this.paidAmount = 0,
  });

  factory ScheduleRow.fromJson(Json j) => ScheduleRow(
    seq: asInt(j['seq']),
    dueMonth: asString(j['dueMonth']),
    principal: asDouble(j['principal']),
    interest: asDouble(j['interest']),
    amount: asDouble(j['amount']),
    status: asString(j['status']),
    paidAmount: asDouble(j['paidAmount']),
  );

  final int seq;
  final double paidAmount;
  final String dueMonth;
  final double principal;
  final double interest;
  final double amount;
  final String status;
}

class Loan {
  const Loan({
    required this.id,
    required this.number,
    required this.employeeName,
    required this.kind,
    required this.purpose,
    required this.amount,
    required this.interestRate,
    required this.instalment,
    required this.status,
    required this.outstanding,
    required this.caReview,
    required this.schedule,
    this.nextDueMonth,
    this.perquisiteNote,
    this.startMonth = '',
    this.tenure = 0,
  });

  factory Loan.fromJson(Json j) => Loan(
    id: asString(j['id']),
    number: asString(j['number']),
    employeeName: asString(j['employeeName']),
    kind: asString(j['kind']),
    purpose: asString(j['purpose']),
    amount: asDouble(j['amount']),
    interestRate: asDouble(j['interestRate']),
    instalment: asDouble(j['instalment']),
    status: asString(j['status']),
    outstanding: asDouble(j['outstanding']),
    caReview: asBool(j['caReview']),
    schedule: asJsonList(j['schedule']).map(ScheduleRow.fromJson).toList(),
    nextDueMonth: asStringOrNull(j['nextDueMonth']),
    perquisiteNote: asStringOrNull(j['perquisiteNote']),
    startMonth: asString(j['startMonth']),
    tenure: asInt(j['tenure']),
  );

  final String id;
  final String number;
  final String employeeName;
  final String kind;
  final String purpose;
  final double amount;
  final double interestRate;
  final double instalment;
  final String status;
  final double outstanding;
  final bool caReview;
  final List<ScheduleRow> schedule;
  final String? nextDueMonth;
  final String? perquisiteNote;
  final String startMonth;
  final int tenure;

  String get kindLabel => kind == 'loan' ? 'Loan' : 'Advance';
}
