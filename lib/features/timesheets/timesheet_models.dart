import '../../core/json.dart';

/// Monday of the week that holds [d].
DateTime mondayOf(DateTime d) {
  final day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

const dayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String hoursText(double h) {
  if (h == h.roundToDouble()) return h.toInt().toString();
  return h.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '');
}

class WeekRow {
  WeekRow({
    required this.partyId,
    required this.partyName,
    required this.task,
    required this.billable,
    this.projectId,
    this.matterId,
    this.ticketId,
    List<double>? hours,
    List<String?>? statuses,
  }) : hours = hours ?? List.filled(7, 0),
       statuses = statuses ?? List.filled(7, null);

  factory WeekRow.fromJson(Json j) {
    final cells = asJsonList(j['entries']);
    return WeekRow(
      partyId: asString(j['partyId']),
      partyName: asString(j['partyName']),
      task: asString(j['task']),
      billable: asBool(j['billable'], true),
      projectId: asStringOrNull(j['projectId']),
      matterId: asStringOrNull(j['matterId']),
      ticketId: asStringOrNull(j['ticketId']),
      hours: [for (final c in cells) asDouble(c['hours'])],
      statuses: [for (final c in cells) asStringOrNull(c['status'])],
    );
  }

  final String partyId;
  final String partyName;
  final String task;
  bool billable;
  final String? projectId;
  final String? matterId;
  final String? ticketId;
  final List<double> hours;
  final List<String?> statuses;

  bool locked(int day) =>
      statuses[day] == 'submitted' || statuses[day] == 'approved';

  double get total => hours.fold(0, (a, b) => a + b);

  Json toJson() => {
    'partyId': partyId,
    'task': task,
    'billable': billable,
    'projectId': ?projectId,
    'matterId': ?matterId,
    'ticketId': ?ticketId,
    // Locked cells stay on the server; only editable hours are sent.
    'hours': [for (var i = 0; i < 7; i++) locked(i) ? 0 : hours[i]],
  };
}

class Week {
  Week.fromJson(Json j)
    : weekStart = asString(j['weekStart']),
      rows = asJsonList(j['rows']).map(WeekRow.fromJson).toList(),
      status = asString(j['status'], 'draft'),
      total = asDouble(j['total']);

  final String weekStart;
  final List<WeekRow> rows;
  final String status;
  final double total;
}

String weekStatusLabel(String s) => switch (s) {
  'draft' => 'Draft',
  'submitted' => 'Submitted',
  'approved' => 'Approved',
  'rejected' => 'Sent back',
  _ => 'Mixed',
};

class TsEntry {
  TsEntry.fromJson(Json j)
    : id = asString(j['id']),
      userName = asString(j['userName']),
      workDate = asString(j['workDate']),
      partyName = asString(j['partyName']),
      task = asString(j['task']),
      hours = asDouble(j['hours']),
      billable = asBool(j['billable']),
      rate = asDouble(j['rate']),
      amount = asDouble(j['amount']),
      status = asString(j['status']);

  final String id;
  final String userName;
  final String workDate;
  final String partyName;
  final String task;
  final double hours;
  final bool billable;
  final double rate;
  final double amount;
  final String status;
}
