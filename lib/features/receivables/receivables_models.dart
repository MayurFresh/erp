import '../../core/json.dart';
import '../accounts/account_model.dart';

/// Yearly interest is shown on overdue bills only; it is never posted.
class AgeingSplit {
  const AgeingSplit({
    this.basis = 'receivable',
    this.notDue = 0,
    this.d1to30 = 0,
    this.d31to60 = 0,
    this.d61to90 = 0,
    this.d90plus = 0,
    this.total = 0,
  });

  factory AgeingSplit.fromJson(Json j) => AgeingSplit(
    basis: asString(j['basis'], 'receivable'),
    notDue: asDouble(j['notDue']),
    d1to30: asDouble(j['d1_30']),
    d31to60: asDouble(j['d31_60']),
    d61to90: asDouble(j['d61_90']),
    d90plus: asDouble(j['d90plus']),
    total: asDouble(j['total']),
  );

  final String basis;
  final double notDue;
  final double d1to30;
  final double d31to60;
  final double d61to90;
  final double d90plus;
  final double total;

  /// Label and amount pairs in display order.
  List<(String, double)> get buckets => [
    ('Not due', notDue),
    ('1 to 30 days', d1to30),
    ('31 to 60 days', d31to60),
    ('61 to 90 days', d61to90),
    ('Over 90 days', d90plus),
  ];

  double get overdue => d1to30 + d31to60 + d61to90 + d90plus;
}

class OpenBill {
  const OpenBill({
    required this.type,
    required this.id,
    required this.number,
    this.date,
    this.dueDate,
    this.total = 0,
    this.amountDue = 0,
    this.daysOverdue = 0,
    this.interestDue,
  });

  factory OpenBill.fromJson(Json j) => OpenBill(
    type: asString(j['type']),
    id: asString(j['id']),
    number: asString(j['number']),
    date: asStringOrNull(j['date']),
    dueDate: asStringOrNull(j['dueDate']),
    total: asDouble(j['total']),
    amountDue: asDouble(j['amountDue']),
    daysOverdue: asInt(j['daysOverdue']),
    interestDue: asDoubleOrNull(j['interestDue']),
  );

  final String type;
  final String id;
  final String number;
  final String? date;
  final String? dueDate;
  final double total;
  final double amountDue;
  final int daysOverdue;
  final double? interestDue;
}

class StatementRow {
  const StatementRow({
    required this.type,
    this.date,
    this.number,
    this.dueDate,
    this.debit = 0,
    this.credit = 0,
    this.balance = 0,
  });

  final String type;
  final String? date;
  final String? number;
  final String? dueDate;
  final double debit;
  final double credit;
  final double balance;
}

/// `GET /parties/:id/statement`: the party ledger plus open bills, ageing and
/// optional interest.
class PartyStatement {
  const PartyStatement({
    required this.ledger,
    required this.rows,
    this.partyName = '',
    this.partyPhone,
    this.openBills = const [],
    this.ageing = const AgeingSplit(),
    this.payablesAgeing,
    this.openTotal = 0,
    this.interestPct = 0,
    this.interestTotal = 0,
    this.doNotRemind = false,
  });

  factory PartyStatement.fromJson(Json j) {
    final ledger = Ledger.fromJson(j);
    final party = asJson(j['party']);
    return PartyStatement(
      ledger: ledger,
      rows: [
        for (final l in asJsonList(j['lines']))
          StatementRow(
            type: asString(l['type'] ?? l['voucherType']),
            date: asStringOrNull(l['date']),
            number: asStringOrNull(l['number']),
            dueDate: asStringOrNull(l['dueDate']),
            debit: asDouble(l['debit']),
            credit: asDouble(l['credit']),
            balance: asDouble(l['balance']),
          ),
      ],
      partyName: asString(party['name']),
      partyPhone: asStringOrNull(party['phone']),
      openBills: asJsonList(j['openBills']).map(OpenBill.fromJson).toList(),
      ageing: AgeingSplit.fromJson(asJson(j['ageing'])),
      payablesAgeing: j['payablesAgeing'] == null
          ? null
          : AgeingSplit.fromJson(asJson(j['payablesAgeing'])),
      openTotal: asDouble(j['openTotal']),
      interestPct: asDouble(j['overdueInterestPct']),
      interestTotal: asDouble(j['interestTotal']),
      doNotRemind: asBool(j['doNotRemind']),
    );
  }

  final Ledger ledger;
  final List<StatementRow> rows;
  final String partyName;
  final String? partyPhone;
  final List<OpenBill> openBills;
  final AgeingSplit ageing;
  final AgeingSplit? payablesAgeing;
  final double openTotal;
  final double interestPct;
  final double interestTotal;
  final bool doNotRemind;

  bool get showInterest => interestPct > 0;
}

String statementTypeLabel(String type) => switch (type) {
  'sales' => 'Invoice',
  'purchase' => 'Bill',
  'receipt' => 'Receipt',
  'payment' => 'Payment',
  'credit_note' => 'Credit note',
  'journal' => 'Journal',
  _ => _sentence(type.replaceAll('_', ' ')),
};

String _sentence(String s) =>
    s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

// Reminders -------------------------------------------------------------

class ReminderSettings {
  const ReminderSettings({
    this.enabled = false,
    this.daysBefore = 3,
    this.onDueDate = true,
    this.repeatEveryDays = 7,
    this.maxRepeats = 3,
    this.channels = const ['email', 'whatsapp'],
    this.overdueInterestPct = 0,
  });

  factory ReminderSettings.fromJson(Json j) => ReminderSettings(
    enabled: asBool(j['enabled']),
    daysBefore: j['daysBefore'] == null ? null : asInt(j['daysBefore']),
    onDueDate: asBool(j['onDueDate'], true),
    repeatEveryDays: asInt(j['repeatEveryDays'], 7),
    maxRepeats: asInt(j['maxRepeats'], 3),
    channels: asStringList(j['channels']),
    overdueInterestPct: asDouble(j['overdueInterestPct']),
  );

  final bool enabled;
  final int? daysBefore;
  final bool onDueDate;
  final int repeatEveryDays;
  final int maxRepeats;
  final List<String> channels;
  final double overdueInterestPct;

  Json toJson() => {
    'enabled': enabled,
    'daysBefore': daysBefore,
    'onDueDate': onDueDate,
    'repeatEveryDays': repeatEveryDays,
    'maxRepeats': maxRepeats,
    'channels': channels,
    'overdueInterestPct': overdueInterestPct,
  };

  /// One line describing the schedule, for the settings screen.
  String get summary {
    final steps = <String>[
      if (daysBefore != null)
        '$daysBefore ${daysBefore == 1 ? 'day' : 'days'} before the due date',
      if (onDueDate) 'on the due date',
      if (maxRepeats > 0)
        'then every $repeatEveryDays ${repeatEveryDays == 1 ? 'day' : 'days'} after it, up to $maxRepeats ${maxRepeats == 1 ? 'time' : 'times'}',
    ];
    return steps.isEmpty ? 'No steps are on.' : _sentence(steps.join(', '));
  }
}

class ReminderLogEntry {
  const ReminderLogEntry({
    required this.id,
    required this.partyId,
    required this.partyName,
    required this.invoiceNumber,
    required this.stepLabel,
    this.stepDate,
    this.runDate,
    this.channels = const [],
    this.status = 'queued',
    this.delivery = 'none',
    this.note,
    this.amount = 0,
  });

  factory ReminderLogEntry.fromJson(Json j) => ReminderLogEntry(
    id: asString(j['id']),
    partyId: asString(j['partyId']),
    partyName: asString(j['partyName']),
    invoiceNumber: asString(j['invoiceNumber']),
    stepLabel: asString(j['stepLabel']),
    stepDate: asStringOrNull(j['stepDate']),
    runDate: asStringOrNull(j['runDate']),
    channels: asStringList(j['channels']),
    status: asString(j['status']),
    delivery: asString(j['delivery'], 'none'),
    note: asStringOrNull(j['note']),
    amount: asDouble(j['amount']),
  );

  final String id;
  final String partyId;
  final String partyName;
  final String invoiceNumber;
  final String stepLabel;
  final String? stepDate;
  final String? runDate;
  final List<String> channels;
  final String status;
  final String delivery;
  final String? note;
  final double amount;
}

class ExcludedParty {
  const ExcludedParty({required this.partyId, required this.name});

  factory ExcludedParty.fromJson(Json j) => ExcludedParty(
    partyId: asString(j['partyId']),
    name: asString(j['name']),
  );

  final String partyId;
  final String name;
}

class ReminderRunResult {
  const ReminderRunResult({
    this.enabled = false,
    this.parties = 0,
    this.invoices = 0,
    this.queued = 0,
    this.skipped = 0,
  });

  factory ReminderRunResult.fromJson(Json j) => ReminderRunResult(
    enabled: asBool(j['enabled']),
    parties: asInt(j['parties']),
    invoices: asInt(j['invoices']),
    queued: asInt(j['queued']),
    skipped: asInt(j['skipped']),
  );

  final bool enabled;
  final int parties;
  final int invoices;
  final int queued;
  final int skipped;
}

// Recurring invoices ----------------------------------------------------

const recurringFrequencies = [
  'weekly',
  'monthly',
  'quarterly',
  'half_yearly',
  'yearly',
];

String frequencyLabel(String f) => switch (f) {
  'weekly' => 'Weekly',
  'monthly' => 'Monthly',
  'quarterly' => 'Quarterly',
  'half_yearly' => 'Half-yearly',
  'yearly' => 'Yearly',
  _ => f,
};

class RecurringLine {
  const RecurringLine({
    required this.itemId,
    required this.itemName,
    this.qty = 1,
    this.rate,
    this.discountPct = 0,
    this.description,
  });

  factory RecurringLine.fromJson(Json j) => RecurringLine(
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    qty: asDouble(j['qty'], 1),
    rate: asDoubleOrNull(j['rate']),
    discountPct: asDouble(j['discountPct']),
    description: asStringOrNull(j['description']),
  );

  final String itemId;
  final String itemName;
  final double qty;
  final double? rate;
  final double discountPct;
  final String? description;

  Json toJson() => {
    'itemId': itemId,
    'qty': qty,
    if (rate != null) 'rate': rate,
    if (discountPct > 0) 'discountPct': discountPct,
    if (description != null && description!.isNotEmpty)
      'description': description,
  };
}

class RecurringInvoice {
  const RecurringInvoice({
    required this.id,
    required this.name,
    required this.partyId,
    required this.partyName,
    required this.locationId,
    this.locationName = '',
    this.lines = const [],
    required this.frequency,
    required this.startDate,
    this.endDate,
    this.maxRuns,
    this.dayOfMonth,
    required this.status,
    this.nextDate,
    this.runsDone = 0,
    this.autoSend = false,
    this.sendChannels = const [],
    this.notes,
    this.lastError,
    this.invoices = const [],
    this.upcoming = const [],
  });

  factory RecurringInvoice.fromJson(Json j) => RecurringInvoice(
    id: asString(j['id']),
    name: asString(j['name']),
    partyId: asString(j['partyId']),
    partyName: asString(j['partyName']),
    locationId: asString(j['locationId']),
    locationName: asString(j['locationName']),
    lines: asJsonList(j['lines']).map(RecurringLine.fromJson).toList(),
    frequency: asString(j['frequency'], 'monthly'),
    startDate: asString(j['startDate']),
    endDate: asStringOrNull(j['endDate']),
    maxRuns: j['maxRuns'] == null ? null : asInt(j['maxRuns']),
    dayOfMonth: j['dayOfMonth'] == null ? null : asInt(j['dayOfMonth']),
    status: asString(j['status'], 'active'),
    nextDate: asStringOrNull(j['nextDate']),
    runsDone: asInt(j['runsDone']),
    autoSend: asBool(j['autoSend']),
    sendChannels: asStringList(j['sendChannels']),
    notes: asStringOrNull(j['notes']),
    lastError: asStringOrNull(j['lastError']),
    invoices: asJsonList(j['invoices']).map(RecurringRunInvoice.fromJson).toList(),
    upcoming: asStringList(j['upcoming']),
  );

  final String id;
  final String name;
  final String partyId;
  final String partyName;
  final String locationId;
  final String locationName;
  final List<RecurringLine> lines;
  final String frequency;
  final String startDate;
  final String? endDate;
  final int? maxRuns;
  final int? dayOfMonth;
  final String status;
  final String? nextDate;
  final int runsDone;
  final bool autoSend;
  final List<String> sendChannels;
  final String? notes;
  final String? lastError;
  final List<RecurringRunInvoice> invoices;
  final List<String> upcoming;

  bool get isActive => status == 'active';
  bool get isPaused => status == 'paused';
  bool get isEnded => status == 'ended';
}

class RecurringRunInvoice {
  const RecurringRunInvoice({
    required this.period,
    required this.invoiceId,
    required this.number,
    this.invoiceDate,
    this.total = 0,
    this.amountPaid = 0,
    this.status = 'posted',
  });

  factory RecurringRunInvoice.fromJson(Json j) => RecurringRunInvoice(
    period: asString(j['period']),
    invoiceId: asString(j['invoiceId']),
    number: asString(j['number']),
    invoiceDate: asStringOrNull(j['invoiceDate']),
    total: asDouble(j['total']),
    amountPaid: asDouble(j['amountPaid']),
    status: asString(j['status'], 'posted'),
  );

  final String period;
  final String invoiceId;
  final String number;
  final String? invoiceDate;
  final double total;
  final double amountPaid;
  final String status;

  double get due => total - amountPaid;
}

class RecurringRunResult {
  const RecurringRunResult({this.templates = 0, this.created = 0, this.errors = const []});

  factory RecurringRunResult.fromJson(Json j) => RecurringRunResult(
    templates: asInt(j['templates']),
    created: asJsonList(j['created']).length,
    errors: [
      for (final e in asJsonList(j['errors']))
        '${asString(e['name'])}: ${asString(e['message'])}',
    ],
  );

  final int templates;
  final int created;
  final List<String> errors;
}
