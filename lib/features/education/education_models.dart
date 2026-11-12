import '../../core/json.dart';

String sexName(String s) => switch (s) {
  'male' => 'Male',
  'female' => 'Female',
  _ => 'Other',
};

String studentStatusName(String s) => switch (s) {
  'left' => 'Left',
  'passed_out' => 'Passed out',
  _ => 'Active',
};

class EduYear {
  const EduYear({
    required this.id,
    required this.name,
    required this.startDate,
    required this.endDate,
    required this.isCurrent,
    this.updatedAt,
  });

  factory EduYear.fromJson(Json j) => EduYear(
    id: asString(j['id']),
    name: asString(j['name']),
    startDate: asString(j['startDate']),
    endDate: asString(j['endDate']),
    isCurrent: asBool(j['isCurrent']),
    updatedAt: j['updatedAt']?.toString(),
  );

  final String id;
  final String name;
  final String startDate;
  final String endDate;
  final bool isCurrent;
  final String? updatedAt;
}

class EduClass {
  const EduClass({
    required this.id,
    required this.yearId,
    required this.kind,
    required this.name,
    required this.label,
    this.section,
    this.course,
    this.timing,
    this.teacherUserId,
    this.teacherName,
    this.capacity,
    this.isActive = true,
    this.students = 0,
    this.mine = false,
    this.attendanceMarked = false,
    this.present = 0,
    this.absent = 0,
    this.late = 0,
    this.updatedAt,
  });

  factory EduClass.fromJson(Json j) => EduClass(
    id: asString(j['id']),
    yearId: asString(j['yearId']),
    kind: asString(j['kind'], 'class'),
    name: asString(j['name']),
    label: asString(j['label'], asString(j['name'])),
    section: j['section'] as String?,
    course: j['course'] as String?,
    timing: j['timing'] as String?,
    teacherUserId: j['teacherUserId'] as String?,
    teacherName: j['teacherName'] as String?,
    capacity: j['capacity'] == null ? null : asInt(j['capacity']),
    isActive: asBool(j['isActive'], true),
    students: asInt(j['students']),
    mine: asBool(j['mine']),
    attendanceMarked: asBool(j['attendanceMarked']),
    present: asInt(j['present']),
    absent: asInt(j['absent']),
    late: asInt(j['late']),
    updatedAt: j['updatedAt']?.toString(),
  );

  final String id;
  final String yearId;
  final String kind;
  final String name;
  final String label;
  final String? section;
  final String? course;
  final String? timing;
  final String? teacherUserId;
  final String? teacherName;
  final int? capacity;
  final bool isActive;
  final int students;
  final bool mine;
  final bool attendanceMarked;
  final int present;
  final int absent;
  final int late;
  final String? updatedAt;

  bool get isBatch => kind == 'batch';

  String get detail => [?course, ?timing, ?teacherName].join('  |  ');
}

class EduHome {
  const EduHome({
    required this.today,
    required this.year,
    required this.classes,
    this.feesCollectedToday,
    this.duesTotal = 0,
    this.defaultersCount = 0,
  });

  factory EduHome.fromJson(Json j) => EduHome(
    today: asString(j['today']),
    year: asJsonOrNull(j['year']) == null
        ? null
        : EduYear.fromJson(asJson(j['year'])),
    classes: asJsonList(j['classes']).map(EduClass.fromJson).toList(),
    feesCollectedToday: j['feesCollectedToday'] == null
        ? null
        : asDouble(j['feesCollectedToday']),
    duesTotal: asDouble(j['duesTotal']),
    defaultersCount: asInt(j['defaultersCount']),
  );

  final String today;
  final EduYear? year;
  final List<EduClass> classes;

  /// `null` for people who cannot see money.
  final double? feesCollectedToday;
  final double duesTotal;
  final int defaultersCount;
}

class StudentBrief {
  const StudentBrief({
    required this.id,
    required this.admissionNo,
    required this.name,
    required this.sex,
    required this.guardianName,
    required this.guardianPhone,
    required this.status,
    this.classId,
    this.className,
    this.rollNo,
  });

  factory StudentBrief.fromJson(Json j) => StudentBrief(
    id: asString(j['id']),
    admissionNo: asString(j['admissionNo']),
    name: asString(j['name']),
    sex: asString(j['sex'], 'other'),
    guardianName: asString(j['guardianName']),
    guardianPhone: asString(j['guardianPhone']),
    status: asString(j['status'], 'active'),
    classId: j['classId'] as String?,
    className: j['className'] as String?,
    rollNo: j['rollNo'] as String?,
  );

  final String id;
  final String admissionNo;
  final String name;
  final String sex;
  final String guardianName;
  final String guardianPhone;
  final String status;
  final String? classId;
  final String? className;
  final String? rollNo;

  String get line =>
      [admissionNo, ?className, if (rollNo != null) 'Roll $rollNo'].join('  ');
}

class Concession {
  const Concession({
    required this.id,
    required this.headId,
    required this.headName,
    required this.kind,
    required this.value,
    required this.reason,
  });

  factory Concession.fromJson(Json j) => Concession(
    id: asString(j['id']),
    headId: asString(j['headId']),
    headName: asString(j['headName']),
    kind: asString(j['kind']),
    value: asDouble(j['value']),
    reason: asString(j['reason']),
  );

  final String id;
  final String headId;
  final String headName;
  final String kind;
  final double value;
  final String reason;
}

class Student {
  const Student({
    required this.brief,
    required this.partyId,
    this.dob,
    this.guardianRelation,
    this.address,
    this.admissionDate,
    this.notes,
    this.updatedAt,
    this.concessions = const [],
    this.due,
    this.overdue,
  });

  factory Student.fromJson(Json j) => Student(
    brief: StudentBrief.fromJson(j),
    partyId: asString(j['partyId']),
    dob: j['dob'] as String?,
    guardianRelation: j['guardianRelation'] as String?,
    address: j['address'] as String?,
    admissionDate: j['admissionDate'] as String?,
    notes: j['notes'] as String?,
    updatedAt: j['updatedAt']?.toString(),
    concessions: asJsonList(j['concessions']).map(Concession.fromJson).toList(),
    due: asJsonOrNull(j['dues']) == null
        ? null
        : asDouble(asJson(j['dues'])['due']),
    overdue: asJsonOrNull(j['dues']) == null
        ? null
        : asDouble(asJson(j['dues'])['overdue']),
  );

  final StudentBrief brief;
  final String partyId;
  final String? dob;
  final String? guardianRelation;
  final String? address;
  final String? admissionDate;
  final String? notes;
  final String? updatedAt;
  final List<Concession> concessions;

  /// `null` for people without the fees permission.
  final double? due;
  final double? overdue;

  String get id => brief.id;
  String get name => brief.name;
}

class FeeHead {
  const FeeHead({
    required this.id,
    required this.name,
    required this.gstRate,
    required this.isActive,
  });

  factory FeeHead.fromJson(Json j) => FeeHead(
    id: asString(j['id']),
    name: asString(j['name']),
    gstRate: asDouble(j['gstRate']),
    isActive: asBool(j['isActive'], true),
  );

  final String id;
  final String name;
  final double gstRate;
  final bool isActive;
}

class PlanLine {
  const PlanLine(this.headId, this.amount);

  final String headId;
  final double amount;
}

class Instalment {
  const Instalment({
    required this.id,
    required this.seq,
    required this.label,
    required this.dueDate,
    required this.lines,
    required this.total,
  });

  factory Instalment.fromJson(Json j) => Instalment(
    id: asString(j['id']),
    seq: asInt(j['seq']),
    label: asString(j['label']),
    dueDate: asString(j['dueDate']),
    lines: [
      for (final l in asJsonList(j['lines']))
        PlanLine(asString(l['headId']), asDouble(l['amount'])),
    ],
    total: asDouble(j['total']),
  );

  final String id;
  final int seq;
  final String label;
  final String dueDate;
  final List<PlanLine> lines;
  final double total;
}

class FeePlan {
  const FeePlan({
    required this.name,
    required this.lateKind,
    required this.lateValue,
    required this.instalments,
    this.lateHeadId,
  });

  factory FeePlan.fromJson(Json j) {
    final late = asJson(j['late']);
    return FeePlan(
      name: asString(j['name']),
      lateKind: asString(late['kind'], 'none'),
      lateValue: asDouble(late['value']),
      lateHeadId: late['headId'] as String?,
      instalments: asJsonList(
        j['instalments'],
      ).map(Instalment.fromJson).toList(),
    );
  }

  final String name;
  final String lateKind;
  final double lateValue;
  final String? lateHeadId;
  final List<Instalment> instalments;

  double get yearTotal => instalments.fold(0, (s, i) => s + i.total);
}

class DemandResult {
  const DemandResult({
    required this.label,
    required this.dueDate,
    required this.count,
    required this.alreadyBilled,
    required this.nothingToBill,
    required this.amount,
    required this.lateFeeCount,
    required this.lateFeeAmount,
    required this.concessionAmount,
    required this.created,
  });

  factory DemandResult.fromJson(Json j) => DemandResult(
    label: asString(j['label']),
    dueDate: asString(j['dueDate']),
    count: asInt(j['count']),
    alreadyBilled: asInt(j['alreadyBilled']),
    nothingToBill: asInt(j['nothingToBill']),
    amount: asDouble(j['amount']),
    lateFeeCount: asInt(j['lateFeeCount']),
    lateFeeAmount: asDouble(j['lateFeeAmount']),
    concessionAmount: asDouble(j['concessionAmount']),
    created: asInt(j['created']),
  );

  final String label;
  final String dueDate;
  final int count;
  final int alreadyBilled;
  final int nothingToBill;
  final double amount;
  final int lateFeeCount;
  final double lateFeeAmount;
  final double concessionAmount;
  final int created;
}

class DueRow {
  const DueRow({
    required this.student,
    required this.due,
    required this.overdue,
    required this.daysOverdue,
    required this.reminder,
    this.oldestDue,
  });

  factory DueRow.fromJson(Json j) => DueRow(
    student: StudentBrief.fromJson(j),
    due: asDouble(j['due']),
    overdue: asDouble(j['overdue']),
    daysOverdue: asInt(j['daysOverdue']),
    reminder: asString(j['reminder']),
    oldestDue: j['oldestDue'] as String?,
  );

  final StudentBrief student;
  final double due;
  final double overdue;
  final int daysOverdue;
  final String reminder;
  final String? oldestDue;
}

class DuesPage {
  const DuesPage(this.rows, this.total, this.dueTotal, this.overdueTotal);

  factory DuesPage.fromJson(Json j) => DuesPage(
    asJsonList(j['data']).map(DueRow.fromJson).toList(),
    asInt(j['total']),
    asDouble(j['dueTotal']),
    asDouble(j['overdueTotal']),
  );

  final List<DueRow> rows;
  final int total;
  final double dueTotal;
  final double overdueTotal;
}

class LedgerBill {
  const LedgerBill({
    required this.number,
    required this.label,
    required this.dueDate,
    required this.total,
    required this.paid,
    required this.due,
    required this.status,
    required this.overdue,
  });

  factory LedgerBill.fromJson(Json j) => LedgerBill(
    number: asString(j['number']),
    label: asString(j['label']),
    dueDate: asString(j['dueDate']),
    total: asDouble(j['total']),
    paid: asDouble(j['paid']),
    due: asDouble(j['due']),
    status: asString(j['status']),
    overdue: asBool(j['overdue']),
  );

  final String number;
  final String label;
  final String dueDate;
  final double total;
  final double paid;
  final double due;
  final String status;
  final bool overdue;
}

class LedgerReceipt {
  const LedgerReceipt({
    required this.id,
    required this.number,
    required this.date,
    required this.amount,
    required this.mode,
    required this.status,
  });

  factory LedgerReceipt.fromJson(Json j) => LedgerReceipt(
    id: asString(j['id']),
    number: asString(j['number']),
    date: asString(j['date']),
    amount: asDouble(j['amount']),
    mode: asString(j['mode']),
    status: asString(j['status']),
  );

  final String id;
  final String number;
  final String date;
  final double amount;
  final String mode;
  final String status;
}

class Ledger {
  const Ledger({
    required this.billed,
    required this.paid,
    required this.due,
    required this.bills,
    required this.receipts,
  });

  factory Ledger.fromJson(Json j) => Ledger(
    billed: asDouble(j['billed']),
    paid: asDouble(j['paid']),
    due: asDouble(j['due']),
    bills: asJsonList(j['bills']).map(LedgerBill.fromJson).toList(),
    receipts: asJsonList(j['receipts']).map(LedgerReceipt.fromJson).toList(),
  );

  final double billed;
  final double paid;
  final double due;
  final List<LedgerBill> bills;
  final List<LedgerReceipt> receipts;
}

class ReceiptHead {
  const ReceiptHead(this.description, this.amount);

  final String description;
  final double amount;
}

class ReceiptPaidFor {
  const ReceiptPaidFor({
    required this.invoiceNumber,
    required this.invoiceTotal,
    required this.paid,
    required this.heads,
    this.label,
  });

  factory ReceiptPaidFor.fromJson(Json j) => ReceiptPaidFor(
    invoiceNumber: asString(j['invoiceNumber']),
    invoiceTotal: asDouble(j['invoiceTotal']),
    paid: asDouble(j['paid']),
    label: j['label'] as String?,
    heads: [
      for (final h in asJsonList(j['heads']))
        ReceiptHead(asString(h['description']), asDouble(h['amount'])),
    ],
  );

  final String invoiceNumber;
  final double invoiceTotal;
  final double paid;
  final String? label;
  final List<ReceiptHead> heads;
}

class ReceiptData {
  const ReceiptData({
    required this.schoolName,
    required this.number,
    required this.date,
    required this.amount,
    required this.mode,
    required this.studentName,
    required this.admissionNo,
    required this.guardianName,
    required this.paidFor,
    required this.balance,
    this.schoolAddress,
    this.schoolPhone,
    this.reference,
    this.className,
    this.rollNo,
  });

  factory ReceiptData.fromJson(Json j) {
    final school = asJson(j['school']);
    final r = asJson(j['receipt']);
    final s = asJson(j['student']);
    return ReceiptData(
      schoolName: asString(school['name']),
      schoolAddress: school['address'] as String?,
      schoolPhone: school['phone'] as String?,
      number: asString(r['number']),
      date: asString(r['date']),
      amount: asDouble(r['amount']),
      mode: asString(r['mode']),
      reference: r['reference'] as String?,
      studentName: asString(s['name']),
      admissionNo: asString(s['admissionNo']),
      guardianName: asString(s['guardianName']),
      className: s['className'] as String?,
      rollNo: s['rollNo'] as String?,
      paidFor: asJsonList(j['paidFor']).map(ReceiptPaidFor.fromJson).toList(),
      balance: asDouble(j['balance']),
    );
  }

  final String schoolName;
  final String? schoolAddress;
  final String? schoolPhone;
  final String number;
  final String date;
  final double amount;
  final String mode;
  final String? reference;
  final String studentName;
  final String admissionNo;
  final String guardianName;
  final String? className;
  final String? rollNo;
  final List<ReceiptPaidFor> paidFor;
  final double balance;
}

class CollectResult {
  const CollectResult(this.paymentId, this.balance);

  factory CollectResult.fromJson(Json j) => CollectResult(
    asString(asJson(j['payment'])['id']),
    asDouble(j['balance']),
  );

  final String paymentId;
  final double balance;
}

class RosterEntry {
  RosterEntry({
    required this.studentId,
    required this.name,
    required this.status,
    this.rollNo,
  });

  factory RosterEntry.fromJson(Json j) => RosterEntry(
    studentId: asString(j['studentId']),
    name: asString(j['name']),
    rollNo: j['rollNo'] as String?,
    status: asString(j['status'], 'present'),
  );

  final String studentId;
  final String name;
  final String? rollNo;

  /// `present`, `absent` or `late`.
  String status;
}

class Roster {
  const Roster({
    required this.classId,
    required this.label,
    required this.date,
    required this.marked,
    required this.students,
  });

  factory Roster.fromJson(Json j) => Roster(
    classId: asString(j['classId']),
    label: asString(j['label']),
    date: asString(j['date']),
    marked: asBool(j['marked']),
    students: asJsonList(j['students']).map(RosterEntry.fromJson).toList(),
  );

  final String classId;
  final String label;
  final String date;
  final bool marked;
  final List<RosterEntry> students;
}

class AttendanceStats {
  const AttendanceStats({
    required this.present,
    required this.absent,
    required this.late,
    required this.marked,
    this.percentage,
  });

  factory AttendanceStats.fromJson(Json j) => AttendanceStats(
    present: asInt(j['present']),
    absent: asInt(j['absent']),
    late: asInt(j['late']),
    marked: asInt(j['marked']),
    percentage: j['percentage'] == null ? null : asDouble(j['percentage']),
  );

  final int present;
  final int absent;
  final int late;
  final int marked;
  final double? percentage;

  String get percentLabel =>
      percentage == null ? 'No records' : '${percentage!.toStringAsFixed(1)}%';
}

class StudentAttendance {
  const StudentAttendance(this.overall, this.thisMonth);

  factory StudentAttendance.fromJson(Json j) => StudentAttendance(
    AttendanceStats.fromJson(asJson(j['overall'])),
    AttendanceStats.fromJson(asJson(j['thisMonth'])),
  );

  final AttendanceStats overall;
  final AttendanceStats thisMonth;
}

class SheetRow {
  const SheetRow({
    required this.studentId,
    required this.name,
    required this.marks,
    required this.stats,
    this.rollNo,
  });

  factory SheetRow.fromJson(Json j) => SheetRow(
    studentId: asString(j['studentId']),
    name: asString(j['name']),
    rollNo: j['rollNo'] as String?,
    marks: {
      for (final e in asJson(j['marks']).entries)
        int.parse(e.key): e.value.toString(),
    },
    stats: AttendanceStats.fromJson(j),
  );

  final String studentId;
  final String name;
  final String? rollNo;
  final Map<int, String> marks;
  final AttendanceStats stats;
}

class AttendanceSheet {
  const AttendanceSheet({
    required this.month,
    required this.days,
    required this.workingDays,
    required this.rows,
  });

  factory AttendanceSheet.fromJson(Json j) => AttendanceSheet(
    month: asString(j['month']),
    days: asInt(j['days']),
    workingDays: asInt(j['workingDays']),
    rows: asJsonList(j['students']).map(SheetRow.fromJson).toList(),
  );

  final String month;
  final int days;
  final int workingDays;
  final List<SheetRow> rows;
}
