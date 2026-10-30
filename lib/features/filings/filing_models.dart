import '../../core/json.dart';

/// One pre-filing check (`GET /gst/prefile-check`, TDS equivalent).
class PrefileCheck {
  const PrefileCheck({
    required this.id,
    required this.title,
    required this.status,
    this.detail = '',
    this.count,
    this.link,
  });

  factory PrefileCheck.fromJson(Json j) => PrefileCheck(
    id: asString(j['id']),
    title: asString(j['title']),
    status: asString(j['status'], 'skip'),
    detail: asString(j['detail']),
    count: asInt(j['count'], -1) < 0 ? null : asInt(j['count']),
    link: asStringOrNull(j['link']),
  );

  /// `pass`, `warn`, `fail` or `skip`.
  final String id;
  final String title;
  final String status;
  final String detail;
  final int? count;
  final String? link;

  bool get failed => status == 'fail';
}

/// A filed-return record (`/filings`).
class Filing {
  const Filing({
    required this.id,
    required this.returnType,
    required this.period,
    required this.status,
    required this.filedOn,
    this.arn,
    this.amountPaid,
    this.notes,
    this.exportSha256,
    this.acknowledgedFailures = const [],
    this.setoffEntryId,
    this.createdAt = '',
    this.createdByName = '',
    this.cancelledAt,
    this.cancelReason,
  });

  factory Filing.fromJson(Json j) => Filing(
    id: asString(j['id']),
    returnType: asString(j['returnType']),
    period: asString(j['period']),
    status: asString(j['status'], 'filed'),
    filedOn: asString(j['filedOn']),
    arn: asStringOrNull(j['arn']),
    amountPaid: asDoubleOrNull(j['amountPaid']),
    notes: asStringOrNull(j['notes']),
    exportSha256: asStringOrNull(j['exportSha256']),
    acknowledgedFailures: asJsonList(
      j['acknowledgedFailures'],
    ).map(PrefileCheck.fromJson).toList(),
    setoffEntryId: asStringOrNull(j['setoffEntryId']),
    createdAt: asString(j['createdAt']),
    createdByName: asString(asJsonOrNull(j['createdBy'])?['name']),
    cancelledAt: asStringOrNull(j['cancelledAt']),
    cancelReason: asStringOrNull(j['cancelReason']),
  );

  final String id;
  final String returnType;
  final String period;
  final String status;
  final String filedOn;
  final String? arn;
  final double? amountPaid;
  final String? notes;
  final String? exportSha256;
  final List<PrefileCheck> acknowledgedFailures;
  final String? setoffEntryId;
  final String createdAt;
  final String createdByName;
  final String? cancelledAt;
  final String? cancelReason;

  bool get cancelled => status == 'cancelled';
}

/// A row of `GET /filings/calendar`.
class FilingCalendarRow {
  const FilingCalendarRow({
    required this.returnType,
    required this.period,
    required this.label,
    required this.dueDate,
    required this.status,
    this.filingId,
    this.daysLate,
    this.estimateLateFee,
    this.estimateInterest,
  });

  factory FilingCalendarRow.fromJson(Json j) {
    final est = asJsonOrNull(j['estimate']);
    return FilingCalendarRow(
      returnType: asString(j['returnType']),
      period: asString(j['period']),
      label: asString(j['label']),
      dueDate: asString(j['dueDate']),
      status: asString(j['status'], 'upcoming'),
      filingId: asStringOrNull(j['filingId']),
      daysLate: j['daysLate'] == null ? null : asInt(j['daysLate']),
      estimateLateFee: est == null ? null : asDouble(est['lateFee']),
      estimateInterest: est == null ? null : asDouble(est['interest']),
    );
  }

  final String returnType;
  final String period;
  final String label;
  final String dueDate;

  /// `filed`, `due`, `overdue` or `upcoming`.
  final String status;
  final String? filingId;
  final int? daysLate;
  final double? estimateLateFee;
  final double? estimateInterest;

  bool get needsYou => status == 'due' || status == 'overdue';
}

/// Display name of a `returnType`.
String returnTypeLabel(String t) => switch (t) {
  'gstr1' => 'GSTR-1',
  'iff' => 'IFF',
  'gstr3b' => 'GSTR-3B',
  'pmt06' => 'PMT-06',
  'gstr9' => 'GSTR-9',
  'gstr9c' => 'GSTR-9C',
  'tds_140' => 'TDS Form 140',
  'itr' => 'ITR',
  'advance_tax' => 'Advance tax',
  _ => t,
};

/// Client path of the wizard for a calendar row; null where none exists.
String? filingRoute(String returnType, String period) => switch (returnType) {
  'gstr1' || 'gstr3b' || 'pmt06' || 'iff' => '/gst-filing/$period',
  'gstr9' || 'gstr9c' => '/gst/gstr9?fy=$period',
  'tds_140' => '/tds',
  'advance_tax' => '/advance-tax',
  _ => null,
};

/// `unverified` list of any response, empty when absent.
List<String> unverifiedOf(Json j) => asStringList(j['unverified']);

/// Contract financial-year label (`2026-27`) for the year containing [d].
String contractFy(DateTime d) {
  final start = d.month >= 4 ? d.year : d.year - 1;
  return '$start-${((start + 1) % 100).toString().padLeft(2, '0')}';
}
