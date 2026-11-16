import '../../core/json.dart';

/// Order states in lifecycle order, with the label shown to people.
const Map<String, String> salesOrderStatuses = {
  'draft': 'Draft',
  'confirmed': 'Confirmed',
  'picking': 'Picking',
  'packed': 'Packed',
  'partially_dispatched': 'Partly dispatched',
  'dispatched': 'Dispatched',
  'closed': 'Closed',
  'cancelled': 'Cancelled',
};

String statusLabel(String status) =>
    salesOrderStatuses[status] ??
    (status.isEmpty
        ? ''
        : status[0].toUpperCase() + status.substring(1).replaceAll('_', ' '));

class SalesOrderLine {
  const SalesOrderLine({
    required this.id,
    required this.lineNo,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qtyOrdered,
    required this.rate,
    this.sku,
    this.barcode,
    this.description = '',
    this.discountPct = 0,
    this.gstRate = 0,
    this.allowBackorder = false,
    this.qtyReserved = 0,
    this.qtyPicked = 0,
    this.qtyPacked = 0,
    this.qtyDispatched = 0,
    this.qtyReturned = 0,
    this.qtyCancelled = 0,
    this.qtyOpen = 0,
    this.qtyShort = 0,
  });

  factory SalesOrderLine.fromJson(Json j) => SalesOrderLine(
    id: asString(j['id']),
    lineNo: asInt(j['lineNo']),
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    sku: asStringOrNull(j['sku']),
    barcode: asStringOrNull(j['barcode']),
    unit: asString(j['unit']),
    description: asString(j['description']),
    qtyOrdered: asDouble(j['qtyOrdered']),
    rate: asDouble(j['rate']),
    discountPct: asDouble(j['discountPct']),
    gstRate: asDouble(j['gstRate']),
    allowBackorder: asBool(j['allowBackorder']),
    qtyReserved: asDouble(j['qtyReserved']),
    qtyPicked: asDouble(j['qtyPicked']),
    qtyPacked: asDouble(j['qtyPacked']),
    qtyDispatched: asDouble(j['qtyDispatched']),
    qtyReturned: asDouble(j['qtyReturned']),
    qtyCancelled: asDouble(j['qtyCancelled']),
    qtyOpen: asDouble(j['qtyOpen']),
    qtyShort: asDouble(j['qtyShort']),
  );

  final String id;
  final int lineNo;
  final String itemId;
  final String itemName;
  final String? sku;
  final String? barcode;
  final String unit;
  final String description;
  final double qtyOrdered;
  final double rate;
  final double discountPct;
  final double gstRate;
  final bool allowBackorder;
  final double qtyReserved;
  final double qtyPicked;
  final double qtyPacked;
  final double qtyDispatched;
  final double qtyReturned;
  final double qtyCancelled;
  final double qtyOpen;
  final double qtyShort;

  double get amount => qtyOrdered * rate * (1 - discountPct / 100);
}

class OrderEvent {
  const OrderEvent({
    required this.kind,
    required this.message,
    this.createdAt,
    this.by,
  });

  factory OrderEvent.fromJson(Json j) => OrderEvent(
    kind: asString(j['kind']),
    message: asString(j['message']),
    createdAt: asDateTimeOrNull(j['createdAt']),
    by: asStringOrNull(j['by']),
  );

  final String kind;
  final String message;
  final DateTime? createdAt;
  final String? by;
}

/// A shipment or return as listed on an order.
class LinkedDoc {
  const LinkedDoc({
    required this.id,
    required this.number,
    required this.status,
    this.detail,
  });

  factory LinkedDoc.fromJson(Json j) => LinkedDoc(
    id: asString(j['id']),
    number: asString(j['number']),
    status: asString(j['status']),
    detail: [
      asStringOrNull(j['courier']),
      asStringOrNull(j['awb']),
      asStringOrNull(j['invoiceNumber']),
      if (j['type'] == 'rto') 'Returned to origin',
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · '),
  );

  final String id;
  final String number;
  final String status;
  final String? detail;
}

class SalesOrder {
  const SalesOrder({
    required this.id,
    required this.number,
    required this.status,
    required this.locationId,
    required this.partyId,
    this.locationName = '',
    this.partyName = '',
    this.source = 'manual',
    this.externalRef,
    this.orderDate,
    this.expectedDate,
    this.placeOfSupply,
    this.subtotal = 0,
    this.taxTotal = 0,
    this.total = 0,
    this.notes,
    this.cancelReason,
    this.packVerified = false,
    this.createdAt,
    this.updatedAt,
    this.createdByName,
    this.lines = const [],
    this.events = const [],
    this.shipments = const [],
    this.returns = const [],
  });

  factory SalesOrder.fromJson(Json j) => SalesOrder(
    id: asString(j['id']),
    number: asString(j['number']),
    status: asString(j['status']),
    source: asString(j['source'], 'manual'),
    externalRef: asStringOrNull(j['externalRef']),
    locationId: asString(j['locationId']),
    locationName: asString(j['locationName']),
    partyId: asString(j['partyId']),
    partyName: asString(j['partyName']),
    orderDate: asStringOrNull(j['orderDate']),
    expectedDate: asStringOrNull(j['expectedDate']),
    placeOfSupply: asStringOrNull(j['placeOfSupply']),
    subtotal: asDouble(j['subtotal']),
    taxTotal: asDouble(j['taxTotal']),
    total: asDouble(j['total']),
    notes: asStringOrNull(j['notes']),
    cancelReason: asStringOrNull(j['cancelReason']),
    packVerified: asBool(j['packVerified']),
    createdAt: asDateTimeOrNull(j['createdAt']),
    updatedAt: asDateTimeOrNull(j['updatedAt']),
    createdByName: asStringOrNull(asJsonOrNull(j['createdBy'])?['name']),
    lines: asJsonList(j['lines']).map(SalesOrderLine.fromJson).toList(),
    events: asJsonList(j['events']).map(OrderEvent.fromJson).toList(),
    shipments: asJsonList(j['shipments']).map(LinkedDoc.fromJson).toList(),
    returns: asJsonList(j['returns']).map(LinkedDoc.fromJson).toList(),
  );

  final String id;
  final String number;
  final String status;
  final String source;
  final String? externalRef;
  final String locationId;
  final String locationName;
  final String partyId;
  final String partyName;
  final String? orderDate;
  final String? expectedDate;
  final String? placeOfSupply;
  final double subtotal;
  final double taxTotal;
  final double total;
  final String? notes;
  final String? cancelReason;
  final bool packVerified;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final String? createdByName;
  final List<SalesOrderLine> lines;
  final List<OrderEvent> events;
  final List<LinkedDoc> shipments;
  final List<LinkedDoc> returns;

  bool get isDraft => status == 'draft';
  bool get isFulfillable => const [
    'confirmed',
    'picking',
    'packed',
    'partially_dispatched',
  ].contains(status);
  bool get canCancel => isDraft || isFulfillable;

  double get totalOpen => lines.fold(0, (s, l) => s + l.qtyOpen);
  double get totalShort => lines.fold(0, (s, l) => s + l.qtyShort);
  double get unpicked => lines.fold(
    0,
    (s, l) => s + (l.qtyReserved - (l.qtyPicked - l.qtyDispatched)),
  );
  double get toPack => lines.fold(0, (s, l) => s + (l.qtyPicked - l.qtyPacked));
  double get readyToDispatch =>
      lines.fold(0, (s, l) => s + (l.qtyPacked - l.qtyDispatched));
}

/// An item with its numbers at one location, for the order item picker.
class Availability {
  const Availability({
    required this.itemId,
    required this.name,
    required this.unit,
    required this.salePrice,
    required this.onHand,
    required this.reserved,
    required this.available,
    this.sku,
    this.barcode,
    this.gstRate = 0,
  });

  factory Availability.fromJson(Json j) => Availability(
    itemId: asString(j['itemId']),
    name: asString(j['name']),
    sku: asStringOrNull(j['sku']),
    barcode: asStringOrNull(j['barcode']),
    unit: asString(j['unit']),
    salePrice: asDouble(j['salePrice']),
    gstRate: asDouble(j['gstRate']),
    onHand: asDouble(j['onHand']),
    reserved: asDouble(j['reserved']),
    available: asDouble(j['available']),
  );

  final String itemId;
  final String name;
  final String? sku;
  final String? barcode;
  final String unit;
  final double salePrice;
  final double gstRate;
  final double onHand;
  final double reserved;
  final double available;
}

/// One line of the create and edit body.
class OrderLineInput {
  const OrderLineInput({
    required this.itemId,
    required this.qty,
    this.rate,
    this.discountPct,
    this.allowBackorder = false,
  });

  final String itemId;
  final double qty;
  final double? rate;
  final double? discountPct;
  final bool allowBackorder;

  Json toJson() => {
    'itemId': itemId,
    'qty': qty,
    if (rate != null) 'rate': rate,
    if (discountPct != null) 'discountPct': discountPct,
    'allowBackorder': allowBackorder,
  };
}

class SalesOrderInput {
  const SalesOrderInput({
    required this.locationId,
    required this.partyId,
    required this.lines,
    this.orderDate,
    this.expectedDate,
    this.externalRef,
    this.notes,
    this.allowOverLimit = false,
  });

  final String locationId;
  final String partyId;

  /// Create even over the customer's credit limit (needs `parties.credit_override`).
  final bool allowOverLimit;

  SalesOrderInput withOverLimit() => SalesOrderInput(
    locationId: locationId,
    partyId: partyId,
    lines: lines,
    orderDate: orderDate,
    expectedDate: expectedDate,
    externalRef: externalRef,
    notes: notes,
    allowOverLimit: true,
  );

  final String? orderDate;
  final String? expectedDate;
  final String? externalRef;
  final String? notes;
  final List<OrderLineInput> lines;

  Json toJson() => {
    'locationId': locationId,
    'partyId': partyId,
    if (orderDate != null) 'orderDate': orderDate,
    'expectedDate': expectedDate,
    'externalRef': externalRef,
    'notes': notes,
    'lines': [for (final l in lines) l.toJson()],
    if (allowOverLimit) 'allowOverLimit': true,
  };
}
