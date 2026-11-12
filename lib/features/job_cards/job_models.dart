import '../../core/json.dart';

const List<String> kJobStatuses = [
  'received',
  'estimate_sent',
  'approved',
  'in_progress',
  'ready',
  'delivered',
  'cancelled',
];

String jobStatusLabel(String s) => switch (s) {
  'received' => 'Received',
  'estimate_sent' => 'Estimate sent',
  'approved' => 'Approved',
  'in_progress' => 'In progress',
  'ready' => 'Ready',
  'delivered' => 'Delivered',
  _ => 'Cancelled',
};

/// The button label for moving a job to [status].
String jobActionLabel(String status) => switch (status) {
  'estimate_sent' => 'Send estimate',
  'approved' => 'Record approval',
  'in_progress' => 'Start work',
  'ready' => 'Mark ready',
  'delivered' => 'Deliver',
  'cancelled' => 'Cancel job',
  'received' => 'Back to received',
  _ => jobStatusLabel(status),
};

class JobBrief {
  const JobBrief({
    required this.id,
    required this.number,
    required this.asset,
    required this.status,
    required this.customerName,
    required this.overdue,
    required this.subtotal,
    this.customerPhone,
    this.technicianName,
    this.technicianId,
    this.promisedDate,
  });

  factory JobBrief.fromJson(Json j) {
    final c = asJson(j['customer']);
    final t = asJsonOrNull(j['technician']);
    return JobBrief(
      id: asString(j['id']),
      number: asString(j['number']),
      asset: asString(j['asset']),
      status: asString(j['status'], 'received'),
      customerName: asString(c['name']),
      customerPhone: asStringOrNull(c['phone']),
      technicianName: t == null ? null : asString(t['name']),
      technicianId: t == null ? null : asString(t['id']),
      promisedDate: asStringOrNull(j['promisedDate']),
      overdue: asBool(j['overdue']),
      subtotal: asDouble(j['subtotal']),
    );
  }

  final String id;
  final String number;
  final String asset;
  final String status;
  final String customerName;
  final String? customerPhone;
  final String? technicianName;
  final String? technicianId;
  final String? promisedDate;
  final bool overdue;
  final double subtotal;
}

class JobBoard {
  const JobBoard(this.jobs, this.counts);

  factory JobBoard.fromJson(Json j) => JobBoard(
    asJsonList(j['data']).map(JobBrief.fromJson).toList(),
    {for (final e in asJson(j['counts']).entries) e.key: asInt(e.value)},
  );

  final List<JobBrief> jobs;
  final Map<String, int> counts;
}

class JobLine {
  const JobLine({
    required this.id,
    required this.kind,
    required this.itemId,
    required this.itemName,
    required this.qty,
    required this.rate,
    required this.discountPct,
    required this.amount,
    required this.gstRate,
    required this.issued,
    required this.unit,
    this.description,
  });

  factory JobLine.fromJson(Json j) => JobLine(
    id: asString(j['id']),
    kind: asString(j['kind'], 'part'),
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    description: asStringOrNull(j['description']),
    qty: asDouble(j['qty']),
    rate: asDouble(j['rate']),
    discountPct: asDouble(j['discountPct']),
    amount: asDouble(j['amount']),
    gstRate: asDouble(j['gstRate']),
    issued: asBool(j['issued']),
    unit: asString(j['unit']),
  );

  final String id;
  final String kind;
  final String itemId;
  final String itemName;
  final String? description;
  final double qty;
  final double rate;
  final double discountPct;
  final double amount;
  final double gstRate;
  final bool issued;
  final String unit;

  bool get isPart => kind == 'part';
}

class JobTotals {
  const JobTotals({
    this.parts = 0,
    this.labour = 0,
    this.subtotal = 0,
    this.tax = 0,
    this.total = 0,
    this.roundOff = 0,
  });

  factory JobTotals.fromJson(Json j) => JobTotals(
    parts: asDouble(j['parts']),
    labour: asDouble(j['labour']),
    subtotal: asDouble(j['subtotal']),
    tax: asDouble(j['tax']),
    total: asDouble(j['total']),
    roundOff: asDouble(j['roundOff']),
  );

  final double parts;
  final double labour;
  final double subtotal;
  final double tax;
  final double total;
  final double roundOff;
}

class JobInvoice {
  const JobInvoice({
    required this.id,
    required this.number,
    required this.total,
    required this.amountPaid,
    required this.balance,
    required this.status,
  });

  factory JobInvoice.fromJson(Json j) => JobInvoice(
    id: asString(j['id']),
    number: asString(j['number']),
    total: asDouble(j['total']),
    amountPaid: asDouble(j['amountPaid']),
    balance: asDouble(j['balance']),
    status: asString(j['status']),
  );

  final String id;
  final String number;
  final double total;
  final double amountPaid;
  final double balance;
  final String status;
}

class JobDetail {
  const JobDetail({
    required this.id,
    required this.number,
    required this.kind,
    required this.asset,
    required this.status,
    required this.nextStatuses,
    required this.complaints,
    required this.customerName,
    required this.lines,
    required this.totals,
    required this.canEditLines,
    required this.statusMessage,
    this.customerId,
    this.customerPhone,
    this.vehicleNo,
    this.make,
    this.model,
    this.odometer,
    this.serialNo,
    this.accessories,
    this.promisedDate,
    this.technicianId,
    this.technicianName,
    this.approvedAt,
    this.approvedBy,
    this.createdAt,
    this.invoice,
    this.updatedAt,
  });

  factory JobDetail.fromJson(Json j) {
    final c = asJson(j['customer']);
    final t = asJsonOrNull(j['technician']);
    final inv = asJsonOrNull(j['invoice']);
    return JobDetail(
      id: asString(j['id']),
      number: asString(j['number']),
      kind: asString(j['kind'], 'vehicle'),
      asset: asString(j['asset']),
      vehicleNo: asStringOrNull(j['vehicleNo']),
      make: asStringOrNull(j['make']),
      model: asStringOrNull(j['model']),
      odometer: j['odometer'] == null ? null : asInt(j['odometer']),
      serialNo: asStringOrNull(j['serialNo']),
      complaints: asString(j['complaints']),
      accessories: asStringOrNull(j['accessories']),
      promisedDate: asStringOrNull(j['promisedDate']),
      status: asString(j['status'], 'received'),
      nextStatuses: asStringList(j['nextStatuses']),
      customerId: asStringOrNull(c['id']),
      customerName: asString(c['name']),
      customerPhone: asStringOrNull(c['phone']),
      technicianId: t == null ? null : asString(t['id']),
      technicianName: t == null ? null : asString(t['name']),
      approvedAt: asStringOrNull(j['approvedAt']),
      approvedBy: asStringOrNull(j['approvedBy']),
      createdAt: asStringOrNull(j['createdAt']),
      lines: asJsonList(j['lines']).map(JobLine.fromJson).toList(),
      totals: JobTotals.fromJson(asJson(j['totals'])),
      canEditLines: asBool(j['canEditLines']),
      invoice: inv == null ? null : JobInvoice.fromJson(inv),
      statusMessage: asString(j['statusMessage']),
      updatedAt: asStringOrNull(j['updatedAt']),
    );
  }

  final String id;
  final String number;
  final String kind;
  final String asset;
  final String? vehicleNo;
  final String? make;
  final String? model;
  final int? odometer;
  final String? serialNo;
  final String complaints;
  final String? accessories;
  final String? promisedDate;
  final String status;
  final List<String> nextStatuses;
  final String? customerId;
  final String customerName;
  final String? customerPhone;
  final String? technicianId;
  final String? technicianName;
  final String? approvedAt;
  final String? approvedBy;
  final String? createdAt;
  final List<JobLine> lines;
  final JobTotals totals;
  final bool canEditLines;
  final JobInvoice? invoice;
  final String statusMessage;
  final String? updatedAt;

  bool get isVehicle => kind == 'vehicle';
  bool get hasUnissuedParts => lines.any((l) => l.isPart && !l.issued);
}

class Technician {
  const Technician(this.id, this.name);

  factory Technician.fromJson(Json j) =>
      Technician(asString(j['id']), asString(j['name']));

  final String id;
  final String name;
}
