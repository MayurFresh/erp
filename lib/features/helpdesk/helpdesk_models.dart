import '../../core/json.dart';

/// Where a ticket stands against one SLA target.
class SlaState {
  const SlaState(this.state, this.minutesLeft);

  factory SlaState.fromJson(Object? v) {
    final j = asJson(v);
    return SlaState(
      asString(j['state'], 'pending'),
      j['minutesLeft'] == null ? null : asInt(j['minutesLeft']),
    );
  }

  /// `met`, `pending` or `breached`.
  final String state;
  final int? minutesLeft;

  bool get breached => state == 'breached';
}

/// Short countdown such as `2h 10m left`, `1d 3h late` or `Met`.
String slaText(SlaState s) {
  if (s.state == 'met') return 'Met';
  final m = s.minutesLeft ?? 0;
  final abs = m.abs();
  final String span;
  if (abs >= 1440) {
    span = '${abs ~/ 1440}d ${(abs % 1440) ~/ 60}h';
  } else if (abs >= 60) {
    span = '${abs ~/ 60}h ${abs % 60}m';
  } else {
    span = '${abs}m';
  }
  return m < 0 || s.breached ? '$span late' : '$span left';
}

String ticketStatusLabel(String s) => switch (s) {
  'new' => 'New',
  'open' => 'Open',
  'waiting' => 'Waiting on customer',
  'resolved' => 'Resolved',
  'closed' => 'Closed',
  _ => s,
};

const ticketChannels = {
  'phone': 'Phone',
  'email': 'Email',
  'whatsapp': 'WhatsApp',
  'walk_in': 'Walk-in',
  'portal': 'Portal',
};
const ticketPriorities = ['low', 'medium', 'high', 'urgent'];

String sentence(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).replaceAll('_', ' ');

class Ticket {
  Ticket.fromJson(Json j)
    : id = asString(j['id']),
      number = asString(j['number']),
      partyId = asString(j['partyId']),
      partyName = asString(j['partyName']),
      subject = asString(j['subject']),
      description = asStringOrNull(j['description']),
      channel = asString(j['channel']),
      category = asStringOrNull(j['category']),
      priority = asString(j['priority'], 'medium'),
      status = asString(j['status'], 'new'),
      serialNo = asStringOrNull(j['serialNo']),
      itemName = asStringOrNull(j['itemName']),
      contractId = asStringOrNull(j['contractId']),
      contractNumber = asStringOrNull(j['contractNumber']),
      covered = asBool(j['covered']),
      assigneeId = asStringOrNull(j['assigneeId']),
      assigneeName = asStringOrNull(j['assigneeName']),
      response = SlaState.fromJson(j['response']),
      resolution = SlaState.fromJson(j['resolution']),
      slaPaused = asBool(j['slaPaused']),
      updatedAt = asString(j['updatedAt']),
      messages = asJsonList(j['messages']).map(TicketMessage.fromJson).toList();

  final String id;
  final String number;
  final String partyId;
  final String partyName;
  final String subject;
  final String? description;
  final String channel;
  final String? category;
  final String priority;
  final String status;
  final String? serialNo;
  final String? itemName;
  final String? contractId;
  final String? contractNumber;
  final bool covered;
  final String? assigneeId;
  final String? assigneeName;
  final SlaState response;
  final SlaState resolution;

  /// True while the ticket waits on the customer; the SLA clock is stopped.
  final bool slaPaused;
  final String updatedAt;
  final List<TicketMessage> messages;

  bool get isOpen => status != 'resolved' && status != 'closed';
  bool get breached => response.breached || resolution.breached;
}

class TicketMessage {
  TicketMessage.fromJson(Json j)
    : id = asString(j['id']),
      kind = asString(j['kind']),
      body = asString(j['body']),
      author = asString(asJson(j['author'])['name']),
      createdAt = DateTime.tryParse(asString(j['createdAt']))?.toLocal();

  final String id;
  final String kind;
  final String body;
  final String author;
  final DateTime? createdAt;
}

class Visit {
  Visit.fromJson(Json j)
    : id = asString(j['id']),
      contractId = asString(j['contractId']),
      contractNumber = asString(j['contractNumber']),
      partyName = asString(j['partyName']),
      dueDate = asString(j['dueDate']),
      status = asString(j['status']),
      overdue = asBool(j['overdue']),
      technicianName = asStringOrNull(j['technicianName']),
      doneDate = asStringOrNull(j['doneDate']),
      notes = asStringOrNull(j['notes']),
      partsUsed = asJsonList(j['partsUsed']),
      partsLocationId = asStringOrNull(j['partsLocationId']),
      signatureName = asStringOrNull(j['signatureName']),
      signatureFileId = asStringOrNull(j['signatureFileId']),
      photoFileIds = [
        for (final f in (j['photoFileIds'] as List? ?? const [])) asString(f),
      ];

  final List<Json> partsUsed;
  final String? partsLocationId;
  final String? signatureName;
  final String? signatureFileId;
  final List<String> photoFileIds;
  final String id;
  final String contractId;
  final String contractNumber;
  final String partyName;
  final String dueDate;
  final String status;
  final bool overdue;
  final String? technicianName;
  final String? doneDate;
  final String? notes;
}

class ContractAsset {
  ContractAsset.fromJson(Json j)
    : itemName = asStringOrNull(j['itemName']),
      serialNo = asStringOrNull(j['serialNo']),
      description = asStringOrNull(j['description']);

  final String? itemName;
  final String? serialNo;
  final String? description;

  String get label => [
    itemName,
    if (serialNo != null) 'S/N $serialNo',
    description,
  ].whereType<String>().join(', ');
}

class Contract {
  Contract.fromJson(Json j)
    : id = asString(j['id']),
      number = asString(j['number']),
      partyName = asString(j['partyName']),
      title = asString(j['title']),
      startDate = asString(j['startDate']),
      endDate = asString(j['endDate']),
      value = asDouble(j['value']),
      billing = asString(j['billing']),
      billFrequency = asStringOrNull(j['billFrequency']),
      visitFrequency = asString(j['visitFrequency'], 'none'),
      status = asString(j['status']),
      daysLeft = asInt(j['daysLeft']),
      renewalDue = asBool(j['renewalDue']),
      billedAmount = asDouble(j['billedAmount']),
      assets = asJsonList(j['assets']).map(ContractAsset.fromJson).toList(),
      visits = asJsonList(j['visits']).map(Visit.fromJson).toList(),
      bills = asJsonList(j['bills']),
      links = asJsonList(j['links']);

  final String id;
  final String number;
  final String partyName;
  final String title;
  final String startDate;
  final String endDate;
  final double value;
  final String billing;
  final String? billFrequency;
  final String visitFrequency;
  final String status;
  final int daysLeft;
  final bool renewalDue;
  final double billedAmount;
  final List<ContractAsset> assets;
  final List<Visit> visits;
  final List<Json> bills;
  final List<Json> links;
}

String contractStatusLabel(String s) => switch (s) {
  'active' => 'Active',
  'expired' => 'Expired',
  'cancelled' => 'Cancelled',
  'renewed' => 'Renewed',
  _ => s,
};

const visitFrequencies = {
  'none': 'No visits',
  'monthly': 'Monthly',
  'quarterly': 'Every 3 months',
  'half_yearly': 'Every 6 months',
  'yearly': 'Yearly',
};
const billFrequencies = {
  'monthly': 'Monthly',
  'quarterly': 'Every 3 months',
  'half_yearly': 'Every 6 months',
  'yearly': 'Yearly',
};
