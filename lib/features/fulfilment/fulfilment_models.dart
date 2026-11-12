import '../../core/json.dart';

const Map<String, String> shipmentStatuses = {
  'booked': 'Booked',
  'in_transit': 'In transit',
  'delivered': 'Delivered',
  'rto_initiated': 'Return to origin started',
  'rto_delivered': 'Returned to origin',
  'lost': 'Lost',
};

/// Statuses a shipment may move to from [status].
List<String> nextShipmentStatuses(String status) => switch (status) {
  'booked' => ['in_transit', 'delivered', 'rto_initiated', 'lost'],
  'in_transit' => ['delivered', 'rto_initiated', 'lost'],
  'rto_initiated' => ['rto_delivered', 'lost', 'delivered'],
  _ => const [],
};

class PickListSummary {
  const PickListSummary({
    required this.id,
    required this.number,
    required this.status,
    required this.locationId,
    this.locationName = '',
    this.orderNumbers = const [],
    this.totalTarget = 0,
    this.totalPicked = 0,
    this.createdAt,
    this.completedAt,
  });

  factory PickListSummary.fromJson(Json j) => PickListSummary(
    id: asString(j['id']),
    number: asString(j['number']),
    status: asString(j['status']),
    locationId: asString(j['locationId']),
    locationName: asString(j['locationName']),
    orderNumbers: asStringList(j['orderNumbers']),
    totalTarget: asDouble(j['totalTarget']),
    totalPicked: asDouble(j['totalPicked']),
    createdAt: asDateTimeOrNull(j['createdAt']),
    completedAt: asDateTimeOrNull(j['completedAt']),
  );

  final String id;
  final String number;
  final String status;
  final String locationId;
  final String locationName;
  final List<String> orderNumbers;
  final double totalTarget;
  final double totalPicked;
  final DateTime? createdAt;
  final DateTime? completedAt;

  bool get isOpen => status == 'open';
}

class PickLine {
  const PickLine({
    required this.id,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qtyTarget,
    required this.qtyPicked,
    this.lineNo = 0,
    this.orderId = '',
    this.orderNumber = '',
    this.orderLineId = '',
    this.sku,
    this.barcode,
  });

  factory PickLine.fromJson(Json j) => PickLine(
    id: asString(j['id']),
    lineNo: asInt(j['lineNo']),
    orderId: asString(j['orderId']),
    orderNumber: asString(j['orderNumber']),
    orderLineId: asString(j['orderLineId']),
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    sku: asStringOrNull(j['sku']),
    barcode: asStringOrNull(j['barcode']),
    unit: asString(j['unit']),
    qtyTarget: asDouble(j['qtyTarget']),
    qtyPicked: asDouble(j['qtyPicked']),
  );

  final String id;
  final int lineNo;
  final String orderId;
  final String orderNumber;
  final String orderLineId;
  final String itemId;
  final String itemName;
  final String? sku;
  final String? barcode;
  final String unit;
  final double qtyTarget;
  final double qtyPicked;

  bool get done => qtyPicked >= qtyTarget;
}

class PickList {
  const PickList({required this.summary, required this.lines});

  factory PickList.fromJson(Json j) => PickList(
    summary: PickListSummary.fromJson(j),
    lines: asJsonList(j['lines']).map(PickLine.fromJson).toList(),
  );

  final PickListSummary summary;
  final List<PickLine> lines;
}

/// What a scan did, shown under the scan field.
class ScanResult {
  const ScanResult({
    required this.duplicate,
    required this.itemName,
    required this.qty,
  });

  factory ScanResult.fromJson(Json j) => ScanResult(
    duplicate: asBool(j['duplicate']),
    itemName: asString(asJsonOrNull(j['item'])?['name']),
    qty: asDouble(j['qty']),
  );

  final bool duplicate;
  final String itemName;
  final double qty;
}

class Shipment {
  const Shipment({
    required this.id,
    required this.number,
    required this.status,
    this.orderId = '',
    this.orderNumber = '',
    this.invoiceId,
    this.invoiceNumber,
    this.invoiceTotal = 0,
    this.partyName = '',
    this.courier,
    this.awb,
    this.mode = 'prepaid',
    this.codAmount = 0,
    this.notes,
    this.dispatchedAt,
    this.deliveredAt,
    this.lines = const [],
    this.history = const [],
    this.returnId,
  });

  factory Shipment.fromJson(Json j) => Shipment(
    id: asString(j['id']),
    number: asString(j['number']),
    status: asString(j['status']),
    orderId: asString(j['orderId']),
    orderNumber: asString(j['orderNumber']),
    invoiceId: asStringOrNull(j['invoiceId']),
    invoiceNumber: asStringOrNull(j['invoiceNumber']),
    invoiceTotal: asDouble(j['invoiceTotal']),
    partyName: asString(j['partyName']),
    courier: asStringOrNull(j['courier']),
    awb: asStringOrNull(j['awb']),
    mode: asString(j['mode'], 'prepaid'),
    codAmount: asDouble(j['codAmount']),
    notes: asStringOrNull(j['notes']),
    dispatchedAt: asDateTimeOrNull(j['dispatchedAt']),
    deliveredAt: asDateTimeOrNull(j['deliveredAt']),
    lines: asJsonList(j['lines']).map(ShipmentLine.fromJson).toList(),
    history: asJsonList(j['history']).map(ShipmentEvent.fromJson).toList(),
    returnId: asStringOrNull(j['returnId']),
  );

  final String id;
  final String number;
  final String status;
  final String orderId;
  final String orderNumber;
  final String? invoiceId;
  final String? invoiceNumber;
  final double invoiceTotal;
  final String partyName;
  final String? courier;
  final String? awb;
  final String mode;
  final double codAmount;
  final String? notes;
  final DateTime? dispatchedAt;
  final DateTime? deliveredAt;
  final List<ShipmentLine> lines;
  final List<ShipmentEvent> history;
  final String? returnId;
}

class ShipmentLine {
  const ShipmentLine({
    required this.id,
    required this.itemName,
    required this.unit,
    required this.qty,
  });

  factory ShipmentLine.fromJson(Json j) => ShipmentLine(
    id: asString(j['id']),
    itemName: asString(j['itemName']),
    unit: asString(j['unit']),
    qty: asDouble(j['qty']),
  );

  final String id;
  final String itemName;
  final String unit;
  final double qty;
}

class ShipmentEvent {
  const ShipmentEvent({required this.status, this.note, this.at, this.by});

  factory ShipmentEvent.fromJson(Json j) => ShipmentEvent(
    status: asString(j['status']),
    note: asStringOrNull(j['note']),
    at: asDateTimeOrNull(j['at']),
    by: asStringOrNull(j['by']),
  );

  final String status;
  final String? note;
  final DateTime? at;
  final String? by;
}
