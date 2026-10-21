import '../../../core/json.dart';
import 'common_models.dart';

enum Trade {
  mason('mason', 'Mason'),
  carpenter('carpenter', 'Carpenter'),
  barBender('bar_bender', 'Bar bender'),
  helper('helper', 'Helper'),
  electrician('electrician', 'Electrician'),
  plumber('plumber', 'Plumber'),
  painter('painter', 'Painter'),
  welder('welder', 'Welder'),
  operator('operator', 'Operator'),
  other('other', 'Other');

  const Trade(this.api, this.label);

  final String api;
  final String label;

  static Trade parse(Object? value) => Trade.values.firstWhere(
    (t) => t.api == value,
    orElse: () => Trade.other,
  );

  static Trade? tryParse(Object? value) {
    for (final t in Trade.values) {
      if (t.api == value) return t;
    }
    return null;
  }
}

/// Label for a trade value; unknown values are humanised.
String tradeLabel(String trade) =>
    Trade.tryParse(trade)?.label ?? humanize(trade);

enum Skill {
  unskilled('unskilled', 'Unskilled'),
  semiSkilled('semi_skilled', 'Semi-skilled'),
  skilled('skilled', 'Skilled'),
  highlySkilled('highly_skilled', 'Highly skilled');

  const Skill(this.api, this.label);

  final String api;
  final String label;

  static Skill parse(Object? value) => Skill.values.firstWhere(
    (s) => s.api == value,
    orElse: () => Skill.unskilled,
  );
}

class Worker {
  const Worker({
    required this.id,
    required this.name,
    this.phone,
    this.trade = Trade.helper,
    this.skill = Skill.unskilled,
    this.dailyRate = 0,
    this.contractorPartyId,
    this.contractorName,
    this.siteId,
    this.siteName,
    this.aadhaarLast4,
    this.bocwRegNo,
    this.photoFileId,
    this.joinedOn,
    this.isActive = true,
    this.createdAt,
  });

  factory Worker.fromJson(Json json) => Worker(
    id: asString(json['id']),
    name: asString(json['name']),
    phone: asStringOrNull(json['phone']),
    trade: Trade.parse(json['trade']),
    skill: Skill.parse(json['skill']),
    dailyRate: asDouble(json['dailyRate']),
    contractorPartyId: asStringOrNull(json['contractorPartyId']),
    contractorName: asStringOrNull(json['contractorName']),
    siteId: asStringOrNull(json['siteId']),
    siteName: asStringOrNull(json['siteName']),
    aadhaarLast4: asStringOrNull(json['aadhaarLast4']),
    bocwRegNo: asStringOrNull(json['bocwRegNo']),
    photoFileId: asStringOrNull(json['photoFileId']),
    joinedOn: asStringOrNull(json['joinedOn']),
    isActive: asBool(json['isActive'], true),
    createdAt: asDateTimeOrNull(json['createdAt']),
  );

  final String id;
  final String name;
  final String? phone;
  final Trade trade;
  final Skill skill;
  final double dailyRate;
  final String? contractorPartyId;
  final String? contractorName;

  /// Home site.
  final String? siteId;
  final String? siteName;
  final String? aadhaarLast4;
  final String? bocwRegNo;
  final String? photoFileId;
  final String? joinedOn;
  final bool isActive;
  final DateTime? createdAt;

  /// Create / PATCH fields as stored (`isActive` only matters for PATCH).
  Json toInputJson() => {
    'name': name,
    'phone': phone,
    'trade': trade.api,
    'skill': skill.api,
    'dailyRate': dailyRate,
    'contractorPartyId': contractorPartyId,
    'siteId': siteId,
    'aadhaarLast4': aadhaarLast4,
    'bocwRegNo': bocwRegNo,
    'joinedOn': joinedOn,
    'isActive': isActive,
  };
}

enum AttendanceStatus {
  present('present', 'Present', 'P'),
  halfDay('half_day', 'Half day', 'H'),
  absent('absent', 'Absent', 'A');

  const AttendanceStatus(this.api, this.label, this.short);

  final String api;
  final String label;
  final String short;

  /// `null` = not marked.
  static AttendanceStatus? parse(Object? value) {
    for (final s in AttendanceStatus.values) {
      if (s.api == value) return s;
    }
    return null;
  }

  /// Days counted for wages: present 1, half day 0.5, absent 0.
  double get days => switch (this) {
    AttendanceStatus.present => 1,
    AttendanceStatus.halfDay => 0.5,
    AttendanceStatus.absent => 0,
  };
}

class AttendanceRow {
  const AttendanceRow({
    required this.workerId,
    required this.workerName,
    this.trade = '',
    this.contractorName,
    this.status,
    this.otHours = 0,
  });

  factory AttendanceRow.fromJson(Json json) => AttendanceRow(
    workerId: asString(json['workerId']),
    workerName: asString(json['workerName']),
    trade: asString(json['trade']),
    contractorName: asStringOrNull(json['contractorName']),
    status: AttendanceStatus.parse(json['status']),
    otHours: asDouble(json['otHours']),
  );

  final String workerId;
  final String workerName;
  final String trade;
  final String? contractorName;

  /// `null` = not marked.
  final AttendanceStatus? status;
  final double otHours;

  AttendanceRow copyWith({
    AttendanceStatus? status,
    bool clearStatus = false,
    double? otHours,
  }) => AttendanceRow(
    workerId: workerId,
    workerName: workerName,
    trade: trade,
    contractorName: contractorName,
    status: clearStatus ? null : (status ?? this.status),
    otHours: otHours ?? this.otHours,
  );

  /// An entry of `PUT /attendance`, or `null` if not marked.
  Json? toEntry() {
    final s = status;
    if (s == null) return null;
    return {
      'workerId': workerId,
      'status': s.api,
      'otHours': s == AttendanceStatus.absent ? 0 : otHours,
    };
  }
}

/// `GET /attendance` and `PUT /attendance` response.
class AttendanceSheet {
  const AttendanceSheet({
    required this.siteId,
    required this.date,
    this.locked = false,
    this.rows = const [],
  });

  factory AttendanceSheet.fromJson(Json json) => AttendanceSheet(
    siteId: asString(json['siteId']),
    date: asString(json['date']),
    locked: asBool(json['locked']),
    rows: asJsonList(json['rows']).map(AttendanceRow.fromJson).toList(),
  );

  final String siteId;
  final String date;

  /// Inside an approved or paid wage sheet: read-only.
  final bool locked;
  final List<AttendanceRow> rows;
}

/// Counts shown at the bottom of the attendance screen.
class AttendanceSummary {
  const AttendanceSummary({
    this.present = 0,
    this.halfDay = 0,
    this.absent = 0,
    this.unmarked = 0,
    this.otHours = 0,
  });

  factory AttendanceSummary.of(Iterable<AttendanceRow> rows) {
    var present = 0, half = 0, absent = 0, unmarked = 0;
    var ot = 0.0;
    for (final row in rows) {
      switch (row.status) {
        case AttendanceStatus.present:
          present++;
        case AttendanceStatus.halfDay:
          half++;
        case AttendanceStatus.absent:
          absent++;
        case null:
          unmarked++;
      }
      if (row.status != null && row.status != AttendanceStatus.absent) {
        ot += row.otHours;
      }
    }
    return AttendanceSummary(
      present: present,
      halfDay: half,
      absent: absent,
      unmarked: unmarked,
      otHours: ot,
    );
  }

  final int present;
  final int halfDay;
  final int absent;
  final int unmarked;

  /// OT of workers marked present or half day.
  final double otHours;

  int get total => present + halfDay + absent + unmarked;
  int get marked => total - unmarked;

  /// Wage days: present + ½ × half day.
  double get manDays => present + halfDay * 0.5;

  /// Workers on site (present or half day).
  int get onSite => present + halfDay;
}

enum WageSheetStatus {
  draft('Draft'),
  approved('Approved'),
  paid('Paid'),
  cancelled('Cancelled');

  const WageSheetStatus(this.label);

  final String label;

  static WageSheetStatus parse(Object? value) => WageSheetStatus.values
      .firstWhere((s) => s.name == value, orElse: () => WageSheetStatus.draft);
}

class WageRow {
  const WageRow({
    required this.workerId,
    required this.workerName,
    this.trade = '',
    this.contractorName,
    this.dailyRate = 0,
    this.presentDays = 0,
    this.otHours = 0,
    this.basic = 0,
    this.otAmount = 0,
    this.gross = 0,
    this.advance = 0,
    this.net = 0,
  });

  factory WageRow.fromJson(Json json) => WageRow(
    workerId: asString(json['workerId']),
    workerName: asString(json['workerName']),
    trade: asString(json['trade']),
    contractorName: asStringOrNull(json['contractorName']),
    dailyRate: asDouble(json['dailyRate']),
    presentDays: asDouble(json['presentDays']),
    otHours: asDouble(json['otHours']),
    basic: asDouble(json['basic']),
    otAmount: asDouble(json['otAmount']),
    gross: asDouble(json['gross']),
    advance: asDouble(json['advance']),
    net: asDouble(json['net']),
  );

  final String workerId;
  final String workerName;
  final String trade;
  final String? contractorName;
  final double dailyRate;

  /// Half day = 0.5.
  final double presentDays;
  final double otHours;
  final double basic;
  final double otAmount;
  final double gross;
  final double advance;
  final double net;
}

class WageSheet {
  const WageSheet({
    required this.id,
    required this.number,
    required this.siteId,
    required this.siteName,
    required this.from,
    required this.to,
    this.status = WageSheetStatus.draft,
    this.totalGross = 0,
    this.totalDeductions = 0,
    this.totalNet = 0,
    this.paidFromAccountId,
    this.paidAt,
    this.createdAt,
    this.createdBy,
    this.rows,
  });

  factory WageSheet.fromJson(Json json) => WageSheet(
    id: asString(json['id']),
    number: asString(json['number']),
    siteId: asString(json['siteId']),
    siteName: asString(json['siteName']),
    from: asString(json['from']),
    to: asString(json['to']),
    status: WageSheetStatus.parse(json['status']),
    totalGross: asDouble(json['totalGross']),
    totalDeductions: asDouble(json['totalDeductions']),
    totalNet: asDouble(json['totalNet']),
    paidFromAccountId: asStringOrNull(json['paidFromAccountId']),
    paidAt: asDateTimeOrNull(json['paidAt']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: NamedRef.fromJsonOrNull(json['createdBy']),
    rows: json['rows'] is List
        ? asJsonList(json['rows']).map(WageRow.fromJson).toList()
        : null,
  );

  final String id;
  final String number;
  final String siteId;
  final String siteName;
  final String from;
  final String to;
  final WageSheetStatus status;
  final double totalGross;
  final double totalDeductions;
  final double totalNet;
  final String? paidFromAccountId;
  final DateTime? paidAt;
  final DateTime? createdAt;
  final NamedRef? createdBy;

  /// Detail only; `null` in lists.
  final List<WageRow>? rows;

  bool get isDraft => status == WageSheetStatus.draft;
}
