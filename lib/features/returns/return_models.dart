import '../../core/json.dart';

const Map<String, String> returnStatuses = {
  'requested': 'Requested',
  'received': 'Received',
  'inspected': 'Inspected',
  'closed': 'Closed',
  'cancelled': 'Cancelled',
};

const Map<String, String> dispositions = {
  'restock': 'Restock',
  'damaged': 'Damaged',
  'scrap': 'Scrap',
};

class ReturnLine {
  const ReturnLine({
    required this.id,
    required this.itemName,
    required this.unit,
    required this.qty,
    this.lineNo = 0,
    this.qtyReceived = 0,
    this.disposition,
    this.note,
  });

  factory ReturnLine.fromJson(Json j) => ReturnLine(
    id: asString(j['id']),
    lineNo: asInt(j['lineNo']),
    itemName: asString(j['itemName']),
    unit: asString(j['unit']),
    qty: asDouble(j['qty']),
    qtyReceived: asDouble(j['qtyReceived']),
    disposition: asStringOrNull(j['disposition']),
    note: asStringOrNull(j['note']),
  );

  final String id;
  final int lineNo;
  final String itemName;
  final String unit;
  final double qty;
  final double qtyReceived;
  final String? disposition;
  final String? note;
}

class SalesReturn {
  const SalesReturn({
    required this.id,
    required this.number,
    required this.type,
    required this.status,
    this.reason = '',
    this.locationName = '',
    this.invoiceNumber,
    this.orderId,
    this.orderNumber,
    this.partyName = '',
    this.creditNoteId,
    this.creditNoteNumber,
    this.createdAt,
    this.lines = const [],
  });

  factory SalesReturn.fromJson(Json j) => SalesReturn(
    id: asString(j['id']),
    number: asString(j['number']),
    type: asString(j['type']),
    status: asString(j['status']),
    reason: asString(j['reason']),
    locationName: asString(j['locationName']),
    invoiceNumber: asStringOrNull(j['invoiceNumber']),
    orderId: asStringOrNull(j['orderId']),
    orderNumber: asStringOrNull(j['orderNumber']),
    partyName: asString(j['partyName']),
    creditNoteId: asStringOrNull(j['creditNoteId']),
    creditNoteNumber: asStringOrNull(j['creditNoteNumber']),
    createdAt: asDateTimeOrNull(j['createdAt']),
    lines: asJsonList(j['lines']).map(ReturnLine.fromJson).toList(),
  );

  final String id;
  final String number;
  final String type;
  final String status;
  final String reason;
  final String locationName;
  final String? invoiceNumber;
  final String? orderId;
  final String? orderNumber;
  final String partyName;
  final String? creditNoteId;
  final String? creditNoteNumber;
  final DateTime? createdAt;
  final List<ReturnLine> lines;

  bool get isRto => type == 'rto';
}
