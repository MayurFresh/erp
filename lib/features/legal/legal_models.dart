import '../../core/json.dart';

const feeTypes = {
  'fixed_stage': 'Fixed fee per stage',
  'per_hearing': 'Fee per hearing',
  'hourly': 'Hourly',
  'retainer': 'Retainer',
};

const matterStatuses = {
  'open': 'Open',
  'disposed': 'Disposed',
  'closed': 'Closed',
};

const disbTypes = {
  'court_fee': 'Court fee',
  'stamp_duty': 'Stamp duty',
  'clerkage': 'Clerkage',
  'other': 'Other expense',
};

const taskKinds = {
  'limitation': 'Limitation date',
  'filing': 'Filing',
  'other': 'Other',
};

/// "2h 05m" for a count of minutes.
String durationLabel(int minutes) {
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '${m}m';
  return '${h}h ${m.toString().padLeft(2, '0')}m';
}

class Person {
  const Person(this.id, this.name);

  factory Person.fromJson(Json j) =>
      Person(asString(j['id']), asString(j['name']));

  final String id;
  final String name;
}

class Hearing {
  const Hearing({
    required this.id,
    required this.matterId,
    required this.date,
    required this.status,
    this.court,
    this.purpose,
    this.outcome,
    this.updatedAt,
  });

  factory Hearing.fromJson(Json j) => Hearing(
    id: asString(j['id']),
    matterId: asString(j['matterId']),
    date: asString(j['hearingDate']),
    status: asString(j['status'], 'scheduled'),
    court: asStringOrNull(j['court']),
    purpose: asStringOrNull(j['purpose']),
    outcome: asStringOrNull(j['outcome']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String matterId;
  final String date;
  final String status;
  final String? court;
  final String? purpose;
  final String? outcome;
  final String? updatedAt;

  bool get held => status == 'held';
}

/// A row of the cause list or a hearing awaiting its outcome.
class CauseItem {
  const CauseItem({
    required this.id,
    required this.matterId,
    required this.matterNo,
    required this.matterTitle,
    required this.clientName,
    required this.date,
    this.court,
    this.purpose,
    this.caseNo,
    this.advocateName,
  });

  factory CauseItem.fromJson(Json j) => CauseItem(
    id: asString(j['id']),
    matterId: asString(j['matterId']),
    matterNo: asString(j['matterNo']),
    matterTitle: asString(j['matterTitle']),
    clientName: asString(j['clientName']),
    date: asString(j['hearingDate']),
    court: asStringOrNull(j['court']),
    purpose: asStringOrNull(j['purpose']),
    caseNo: asStringOrNull(j['caseNo']),
    advocateName: asStringOrNull(j['advocateName']),
  );

  final String id;
  final String matterId;
  final String matterNo;
  final String matterTitle;
  final String clientName;
  final String date;
  final String? court;
  final String? purpose;
  final String? caseNo;
  final String? advocateName;
}

class LegalTask {
  const LegalTask({
    required this.id,
    required this.matterId,
    required this.title,
    required this.kind,
    required this.dueDate,
    required this.status,
    required this.overdue,
    this.matterNo,
    this.matterTitle,
    this.assigneeId,
    this.assigneeName,
    this.notes,
    this.updatedAt,
  });

  factory LegalTask.fromJson(Json j) => LegalTask(
    id: asString(j['id']),
    matterId: asString(j['matterId']),
    title: asString(j['title']),
    kind: asString(j['kind'], 'other'),
    dueDate: asString(j['dueDate']),
    status: asString(j['status'], 'open'),
    overdue: asBool(j['overdue']),
    matterNo: asStringOrNull(j['matterNo']),
    matterTitle: asStringOrNull(j['matterTitle']),
    assigneeId: asStringOrNull(j['assigneeId']),
    assigneeName: asStringOrNull(j['assigneeName']),
    notes: asStringOrNull(j['notes']),
    updatedAt: asStringOrNull(j['updatedAt']),
  );

  final String id;
  final String matterId;
  final String title;
  final String kind;
  final String dueDate;
  final String status;
  final bool overdue;
  final String? matterNo;
  final String? matterTitle;
  final String? assigneeId;
  final String? assigneeName;
  final String? notes;
  final String? updatedAt;

  bool get done => status == 'done';
}

class Entry {
  const Entry({
    required this.id,
    required this.matterId,
    required this.kind,
    required this.date,
    required this.amount,
    required this.billable,
    required this.billed,
    required this.description,
    this.disbType,
    this.minutes,
    this.rate,
    this.userName,
    this.invoiceNumber,
  });

  factory Entry.fromJson(Json j) => Entry(
    id: asString(j['id']),
    matterId: asString(j['matterId']),
    kind: asString(j['kind']),
    date: asString(j['entryDate']),
    amount: asDouble(j['amount']),
    billable: asBool(j['billable'], true),
    billed: asBool(j['billed']),
    description: asString(j['description']),
    disbType: asStringOrNull(j['disbType']),
    minutes: j['minutes'] == null ? null : asInt(j['minutes']),
    rate: asDoubleOrNull(j['rate']),
    userName: asStringOrNull(j['userName']),
    invoiceNumber: asStringOrNull(j['invoiceNumber']),
  );

  final String id;
  final String matterId;
  final String kind;
  final String date;
  final double amount;
  final bool billable;
  final bool billed;
  final String description;
  final String? disbType;
  final int? minutes;
  final double? rate;
  final String? userName;
  final String? invoiceNumber;

  String get kindLabel => switch (kind) {
    'time' => 'Time',
    'fee' => 'Fee',
    _ => disbTypes[disbType] ?? 'Expense',
  };

  String get detail => kind == 'time' && minutes != null
      ? '${durationLabel(minutes!)} by ${userName ?? ''}'.trim()
      : (userName ?? '');
}

class Unbilled {
  const Unbilled(this.time, this.fee, this.disbursement, this.nonBillable);

  factory Unbilled.fromJson(Json j) => Unbilled(
    asDouble(j['time']),
    asDouble(j['fee']),
    asDouble(j['disbursement']),
    asDouble(j['nonBillable']),
  );

  final double time;
  final double fee;
  final double disbursement;
  final double nonBillable;

  double get total => time + fee + disbursement;
}

class Matter {
  const Matter({
    required this.id,
    required this.matterNo,
    required this.title,
    required this.clientId,
    required this.clientName,
    required this.status,
    required this.advocateId,
    required this.advocateName,
    required this.feeType,
    required this.agreedFee,
    required this.team,
    this.clientGstin,
    this.opposingParty,
    this.court,
    this.caseType,
    this.caseNo,
    this.caseYear,
    this.filingDate,
    this.stage,
    this.hourlyRate,
    this.notes,
    this.nextHearingDate,
    this.updatedAt,
    this.hearings = const [],
    this.unbilled,
    this.openTasks = 0,
    this.billedTotal = 0,
    this.billedPaid = 0,
    this.advanceReceived = 0,
  });

  factory Matter.fromJson(Json j) {
    final summary = asJson(j['summary']);
    return Matter(
      id: asString(j['id']),
      matterNo: asString(j['matterNo']),
      title: asString(j['title']),
      clientId: asString(j['clientId']),
      clientName: asString(j['clientName']),
      clientGstin: asStringOrNull(j['clientGstin']),
      status: asString(j['status'], 'open'),
      advocateId: asString(j['advocateId']),
      advocateName: asString(j['advocateName']),
      feeType: asString(j['feeType'], 'hourly'),
      agreedFee: asDouble(j['agreedFee']),
      team: asJsonList(j['team']).map(Person.fromJson).toList(),
      opposingParty: asStringOrNull(j['opposingParty']),
      court: asStringOrNull(j['court']),
      caseType: asStringOrNull(j['caseType']),
      caseNo: asStringOrNull(j['caseNo']),
      caseYear: j['caseYear'] == null ? null : asInt(j['caseYear']),
      filingDate: asStringOrNull(j['filingDate']),
      stage: asStringOrNull(j['stage']),
      hourlyRate: asDoubleOrNull(j['hourlyRate']),
      notes: asStringOrNull(j['notes']),
      nextHearingDate: asStringOrNull(j['nextHearingDate']),
      updatedAt: asStringOrNull(j['updatedAt']),
      hearings: asJsonList(j['hearings']).map(Hearing.fromJson).toList(),
      unbilled: summary.isEmpty
          ? null
          : Unbilled.fromJson(asJson(summary['unbilled'])),
      openTasks: asInt(summary['openTasks']),
      billedTotal: asDouble(summary['billedTotal']),
      billedPaid: asDouble(summary['billedPaid']),
      advanceReceived: asDouble(summary['advanceReceived']),
    );
  }

  final String id;
  final String matterNo;
  final String title;
  final String clientId;
  final String clientName;
  final String? clientGstin;
  final String status;
  final String advocateId;
  final String advocateName;
  final String feeType;
  final double agreedFee;
  final List<Person> team;
  final String? opposingParty;
  final String? court;
  final String? caseType;
  final String? caseNo;
  final int? caseYear;
  final String? filingDate;
  final String? stage;
  final double? hourlyRate;
  final String? notes;
  final String? nextHearingDate;
  final String? updatedAt;
  final List<Hearing> hearings;
  final Unbilled? unbilled;
  final int openTasks;
  final double billedTotal;
  final double billedPaid;
  final double advanceReceived;

  bool get isOpen => status == 'open';

  /// "CS 412/2026" or an empty string.
  String get caseRef =>
      [if (caseNo != null && caseNo!.isNotEmpty) caseNo!].join() +
      (caseYear != null && caseNo != null ? '/$caseYear' : '');
}

class LegalHome {
  const LegalHome({
    required this.today,
    required this.tomorrow,
    required this.hearings,
    required this.pendingOutcome,
    required this.deadlines,
    required this.withoutNextDate,
  });

  factory LegalHome.fromJson(Json j) => LegalHome(
    today: asString(j['today']),
    tomorrow: asString(j['tomorrow']),
    hearings: asJsonList(j['hearings']).map(CauseItem.fromJson).toList(),
    pendingOutcome: asJsonList(
      j['pendingOutcome'],
    ).map(CauseItem.fromJson).toList(),
    deadlines: asJsonList(j['deadlines']).map(LegalTask.fromJson).toList(),
    withoutNextDate: asJsonList(
      j['withoutNextDate'],
    ).map(Matter.fromJson).toList(),
  );

  final String today;
  final String tomorrow;
  final List<CauseItem> hearings;
  final List<CauseItem> pendingOutcome;
  final List<LegalTask> deadlines;
  final List<Matter> withoutNextDate;
}

class BillRow {
  const BillRow(
    this.invoiceId,
    this.number,
    this.date,
    this.total,
    this.paid,
    this.status,
    this.reverseCharge,
  );

  factory BillRow.fromJson(Json j) => BillRow(
    asString(j['invoiceId']),
    asString(j['number']),
    asString(j['invoiceDate']),
    asDouble(j['total']),
    asDouble(j['amountPaid']),
    asString(j['status']),
    asBool(j['reverseCharge']),
  );

  final String invoiceId;
  final String number;
  final String date;
  final double total;
  final double paid;
  final String status;
  final bool reverseCharge;

  double get due => total - paid;
}

class ReceiptRow {
  const ReceiptRow(this.number, this.date, this.amount, this.kind, this.status);

  factory ReceiptRow.fromJson(Json j) => ReceiptRow(
    asString(j['number']),
    asString(j['date']),
    asDouble(j['amount']),
    asString(j['kind']),
    asString(j['status']),
  );

  final String number;
  final String date;
  final double amount;
  final String kind;
  final String status;
}

class Bills {
  const Bills(this.bills, this.receipts);

  factory Bills.fromJson(Json j) => Bills(
    asJsonList(j['bills']).map(BillRow.fromJson).toList(),
    asJsonList(j['receipts']).map(ReceiptRow.fromJson).toList(),
  );

  final List<BillRow> bills;
  final List<ReceiptRow> receipts;
}

class MatterDoc {
  const MatterDoc(this.id, this.name, this.label, this.size);

  factory MatterDoc.fromJson(Json j) => MatterDoc(
    asString(j['id']),
    asString(j['name']),
    asStringOrNull(j['label']),
    asInt(j['size']),
  );

  final String id;
  final String name;
  final String? label;
  final int size;
}
