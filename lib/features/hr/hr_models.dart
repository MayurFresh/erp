/// Models for HR and payroll (API v1.12). Hand-written, lenient like the rest of the app.
library;

import '../../core/json.dart';

String monthLabel(String ym) {
  const names = [
    'January', 'February', 'March', 'April', 'May', 'June', 'July',
    'August', 'September', 'October', 'November', 'December',
  ];
  if (ym.length < 7) return ym;
  final m = int.tryParse(ym.substring(5, 7)) ?? 1;
  return '${names[(m - 1).clamp(0, 11)]} ${ym.substring(0, 4)}';
}

/// 2.0 shows as 2 and 1.5 as 1.5.
String dayText(num n) => n == n.roundToDouble() ? '${n.toInt()}' : '$n';

/// `YYYY-MM` for a date.
String monthOf(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

class HrSummary {
  const HrSummary({
    required this.headCount,
    required this.joiners,
    required this.leavers,
    required this.pendingLeave,
    required this.onLeaveToday,
    required this.month,
    required this.runs,
    required this.birthdays,
    required this.departments,
  });

  factory HrSummary.fromJson(Json j) => HrSummary(
    headCount: asInt(j['headCount']),
    joiners: asInt(j['joinersThisMonth']),
    leavers: asInt(j['leaversThisMonth']),
    pendingLeave: asInt(j['pendingLeave']),
    onLeaveToday: asInt(j['onLeaveToday']),
    month: asString(j['month']),
    runs: asJsonList(j['payroll']).map(RunBrief.fromJson).toList(),
    birthdays: asJsonList(j['birthdays']),
    departments: asJsonList(j['departments']),
  );

  final int headCount, joiners, leavers, pendingLeave, onLeaveToday;
  final String month;
  final List<RunBrief> runs;
  final List<Json> birthdays;
  final List<Json> departments;
}

class RunBrief {
  const RunBrief({required this.id, required this.status, required this.net, required this.count});

  factory RunBrief.fromJson(Json j) => RunBrief(
    id: asString(j['id']),
    status: asString(j['status']),
    net: asDouble(j['net']),
    count: asInt(j['employeeCount']),
  );

  final String id, status;
  final double net;
  final int count;
}

class Employee {
  const Employee({
    required this.id,
    required this.code,
    required this.name,
    this.department,
    this.designation,
    this.locationName,
    this.status = 'active',
    this.joiningDate,
    this.leavingDate,
    this.monthlyGross,
    this.userId,
    this.raw = const {},
  });

  factory Employee.fromJson(Json j) => Employee(
    id: asString(j['id']),
    code: asString(j['code']),
    name: asString(j['name']),
    department: asStringOrNull(j['department']),
    designation: asStringOrNull(j['designation']),
    locationName: asStringOrNull(j['locationName']),
    status: asString(j['status'], 'active'),
    joiningDate: asStringOrNull(j['joiningDate']),
    leavingDate: asStringOrNull(j['leavingDate']),
    monthlyGross: asDoubleOrNull(j['monthlyGross']),
    userId: asStringOrNull(j['userId']),
    raw: j,
  );

  final String id, code, name, status;
  final String? department, designation, locationName, joiningDate, leavingDate, userId;
  final double? monthlyGross;

  /// The full file as the server sent it (only the file endpoint has every field).
  final Json raw;

  String? field(String key) => asStringOrNull(raw[key]);
  String get subtitle => [designation, department].whereType<String>().where((s) => s.isNotEmpty).join(' - ');
}

class SalaryComponent {
  const SalaryComponent({
    required this.id,
    required this.code,
    required this.name,
    required this.kind,
    required this.calc,
    this.percent,
    this.isBasic = false,
    this.taxable = true,
    this.pfWage = false,
    this.esiWage = true,
    this.proRata = true,
    this.isActive = true,
  });

  factory SalaryComponent.fromJson(Json j) => SalaryComponent(
    id: asString(j['id']),
    code: asString(j['code']),
    name: asString(j['name']),
    kind: asString(j['kind'], 'earning'),
    calc: asString(j['calc'], 'fixed'),
    percent: asDoubleOrNull(j['percent']),
    isBasic: asBool(j['isBasic']),
    taxable: asBool(j['taxable'], true),
    pfWage: asBool(j['pfWage']),
    esiWage: asBool(j['esiWage'], true),
    proRata: asBool(j['proRata'], true),
    isActive: asBool(j['isActive'], true),
  );

  final String id, code, name, kind, calc;
  final double? percent;
  final bool isBasic, taxable, pfWage, esiWage, proRata, isActive;

  bool get isEarning => kind == 'earning';
  String get calcLabel => switch (calc) {
    'pct_basic' => '${percent ?? 0}% of basic',
    'pct_gross' => '${percent ?? 0}% of earnings',
    _ => 'Fixed amount',
  };
}

class SalaryRevision {
  const SalaryRevision({
    required this.id,
    required this.effectiveFrom,
    required this.ctcAnnual,
    required this.monthlyGross,
    required this.lines,
    this.note,
  });

  factory SalaryRevision.fromJson(Json j) => SalaryRevision(
    id: asString(j['id']),
    effectiveFrom: asString(j['effectiveFrom']),
    ctcAnnual: asDouble(j['ctcAnnual']),
    monthlyGross: asDouble(j['monthlyGross']),
    note: asStringOrNull(j['note']),
    lines: asJsonList(j['lines']),
  );

  final String id, effectiveFrom;
  final double ctcAnnual, monthlyGross;
  final String? note;
  final List<Json> lines;
}

class LeaveType {
  const LeaveType({
    required this.id,
    required this.code,
    required this.name,
    required this.isPaid,
    required this.yearlyQuota,
    required this.carryForwardLimit,
  });

  factory LeaveType.fromJson(Json j) => LeaveType(
    id: asString(j['id']),
    code: asString(j['code']),
    name: asString(j['name']),
    isPaid: asBool(j['isPaid'], true),
    yearlyQuota: asDouble(j['yearlyQuota']),
    carryForwardLimit: asDouble(j['carryForwardLimit']),
  );

  final String id, code, name;
  final bool isPaid;
  final double yearlyQuota, carryForwardLimit;
}

class LeaveBalance {
  const LeaveBalance({
    required this.leaveTypeId,
    required this.code,
    required this.name,
    required this.isPaid,
    required this.quota,
    required this.taken,
    required this.pending,
    this.balance,
  });

  factory LeaveBalance.fromJson(Json j) => LeaveBalance(
    leaveTypeId: asString(j['leaveTypeId']),
    code: asString(j['code']),
    name: asString(j['name']),
    isPaid: asBool(j['isPaid'], true),
    quota: asDouble(j['quota']),
    taken: asDouble(j['taken']),
    pending: asDouble(j['pending']),
    balance: asDoubleOrNull(j['balance']),
  );

  final String leaveTypeId, code, name;
  final bool isPaid;
  final double quota, taken, pending;
  final double? balance;
}

class LeaveApplication {
  const LeaveApplication({
    required this.id,
    required this.employeeId,
    required this.employeeName,
    required this.leaveTypeName,
    required this.fromDate,
    required this.toDate,
    required this.days,
    required this.status,
    required this.isPaid,
    this.reason,
    this.decisionNote,
  });

  factory LeaveApplication.fromJson(Json j) => LeaveApplication(
    id: asString(j['id']),
    employeeId: asString(j['employeeId']),
    employeeName: asString(j['employeeName']),
    leaveTypeName: asString(j['leaveTypeName']),
    fromDate: asString(j['fromDate']),
    toDate: asString(j['toDate']),
    days: asDouble(j['days']),
    status: asString(j['status']),
    isPaid: asBool(j['isPaid'], true),
    reason: asStringOrNull(j['reason']),
    decisionNote: asStringOrNull(j['decisionNote']),
  );

  final String id, employeeId, employeeName, leaveTypeName, fromDate, toDate, status;
  final double days;
  final bool isPaid;
  final String? reason, decisionNote;
}

class Holiday {
  const Holiday({required this.id, required this.date, required this.name});

  factory Holiday.fromJson(Json j) => Holiday(
    id: asString(j['id']),
    date: asString(j['date']),
    name: asString(j['name']),
  );

  final String id, date, name;
}

class PayrollLine {
  const PayrollLine(this.json);

  final Json json;

  String get id => asString(json['id']);
  String get employeeId => asString(json['employeeId']);
  String get code => asString(json['code']);
  String get name => asString(json['name']);
  String get department => asString(json['department']);
  double get paidDays => asDouble(json['paidDays']);
  double get workingDays => asDouble(json['workingDays']);
  double get lopDays => asDouble(json['lopDays']);
  double get gross => asDouble(json['gross']);
  double get deductions => asDouble(json['deductions']);
  double get net => asDouble(json['net']);
  double get pfEmployee => asDouble(json['pfEmployee']);
  double get esiEmployee => asDouble(json['esiEmployee']);
  double get pt => asDouble(json['pt']);
  double get lwfEmployee => asDouble(json['lwfEmployee']);
  double get tds => asDouble(json['tds']);
  double get otherDeductions => asDouble(json['otherDeductionsTotal']);
  List<String> get warnings => asStringList(json['warnings']);
  List<Json> get earnings => asJsonList(json['earnings']);
  List<Json> get overrides => asJsonList(json['overrides']);
  Json? get tdsWorking => asJsonOrNull(json['tdsWorking']);
}

class PayrollRun {
  const PayrollRun({
    required this.id,
    required this.number,
    required this.month,
    required this.status,
    required this.gross,
    required this.deductions,
    required this.net,
    required this.employerCost,
    required this.employeeCount,
    this.lines = const [],
    this.skipped = const [],
    this.canApprove = false,
    this.updatedAt,
  });

  factory PayrollRun.fromJson(Json j) => PayrollRun(
    id: asString(j['id']),
    number: asString(j['number']),
    month: asString(j['month']),
    status: asString(j['status']),
    gross: asDouble(j['gross']),
    deductions: asDouble(j['deductions']),
    net: asDouble(j['net']),
    employerCost: asDouble(j['employerCost']),
    employeeCount: asInt(j['employeeCount']),
    lines: asJsonList(j['lines']).map(PayrollLine.new).toList(),
    skipped: asJsonList(j['skipped']),
    canApprove: asBool(j['canApprove']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id, number, month, status;
  final double gross, deductions, net, employerCost;
  final int employeeCount;
  final List<PayrollLine> lines;
  final List<Json> skipped;
  final bool canApprove;
  final String? updatedAt;

  bool get editable => status == 'draft' || status == 'computed';
}

class PayslipItem {
  const PayslipItem({
    required this.id,
    required this.employeeName,
    required this.month,
    required this.gross,
    required this.net,
    required this.runStatus,
  });

  factory PayslipItem.fromJson(Json j) => PayslipItem(
    id: asString(j['id']),
    employeeName: asString(j['employeeName']),
    month: asString(j['month']),
    gross: asDouble(j['gross']),
    net: asDouble(j['net']),
    runStatus: asString(j['runStatus']),
  );

  final String id, employeeName, month, runStatus;
  final double gross, net;
}

class Payslip {
  const Payslip(this.json);

  final Json json;

  String get month => asString(json['month']);
  Json get company => asJson(json['company']);
  Json get employee => asJson(json['employee']);
  List<Json> get earnings => asJsonList(json['earnings']);
  List<Json> get deductions => asJsonList(json['deductions']);
  List<Json> get employer => asJsonList(json['employerContributions']);
  double get gross => asDouble(json['gross']);
  double get totalDeductions => asDouble(json['totalDeductions']);
  double get net => asDouble(json['net']);
  double get paidDays => asDouble(json['paidDays']);
  double get workingDays => asDouble(json['workingDays']);
  double get lopDays => asDouble(json['lopDays']);
  Json get ytd => asJson(json['ytd']);
}

/// One marked day in the attendance register.
class AttendanceDay {
  const AttendanceDay({required this.employeeId, required this.day, required this.status});

  factory AttendanceDay.fromJson(Json j) => AttendanceDay(
    employeeId: asString(j['employeeId']),
    day: asString(j['day']),
    status: asString(j['status']),
  );

  final String employeeId, day, status;
}
