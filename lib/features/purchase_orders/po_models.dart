import '../../core/json.dart';
import '../documents/document_models.dart';

/// Purchase order statuses, in lifecycle order.
const Map<String, String> poStatusLabels = {
  'draft': 'Draft',
  'pending_approval': 'Pending approval',
  'approved': 'Approved',
  'sent': 'Sent',
  'partially_received': 'Partly received',
  'received': 'Received',
  'closed': 'Closed',
  'cancelled': 'Cancelled',
};

String poStatusLabel(String status) => poStatusLabels[status] ?? status;

/// One line of a purchase order with its receipt and billing progress.
class PoLine {
  const PoLine({
    required this.itemId,
    required this.itemName,
    required this.qty,
    required this.unit,
    required this.rate,
    this.id,
    this.lineNo = 0,
    this.sku,
    this.description = '',
    this.hsnCode,
    this.discountPct = 0,
    this.gstRate = 0,
    this.taxableValue = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.lineTotal = 0,
    this.receivedQty = 0,
    this.rejectedQty = 0,
    this.billedQty = 0,
    this.cancelledQty = 0,
    this.openQty = 0,
  });

  factory PoLine.fromJson(Json json) => PoLine(
    id: asStringOrNull(json['id']),
    lineNo: asInt(json['lineNo']),
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    sku: asStringOrNull(json['sku']),
    description: asString(json['description']),
    hsnCode: asStringOrNull(json['hsnCode']),
    qty: asDouble(json['qty']),
    unit: asString(json['unit']),
    rate: asDouble(json['rate']),
    discountPct: asDouble(json['discountPct']),
    gstRate: asDouble(json['gstRate']),
    taxableValue: asDouble(json['taxableValue']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    lineTotal: asDouble(json['lineTotal']),
    receivedQty: asDouble(json['receivedQty']),
    rejectedQty: asDouble(json['rejectedQty']),
    billedQty: asDouble(json['billedQty']),
    cancelledQty: asDouble(json['cancelledQty']),
    openQty: asDouble(json['openQty']),
  );

  final String? id;
  final int lineNo;
  final String itemId;
  final String itemName;
  final String? sku;
  final String description;
  final String? hsnCode;
  final double qty;
  final String unit;
  final double rate;
  final double discountPct;
  final double gstRate;
  final double taxableValue;
  final double cgst;
  final double sgst;
  final double igst;
  final double lineTotal;
  final double receivedQty;
  final double rejectedQty;
  final double billedQty;
  final double cancelledQty;

  /// `qty - cancelledQty - receivedQty`.
  final double openQty;

  /// Net rate after the line discount (GST excluded).
  double get netRate => rate * (1 - discountPct / 100);

  /// Quantity received but not yet billed.
  double get unbilledQty => receivedQty - billedQty;

  TaxLine toTaxLine() => TaxLine(
    id: id,
    itemId: itemId,
    description: description.isEmpty ? itemName : description,
    hsnCode: hsnCode,
    qty: qty,
    unit: unit,
    rate: rate,
    discountPct: discountPct,
    taxableValue: taxableValue,
    gstRate: gstRate,
    cgst: cgst,
    sgst: sgst,
    igst: igst,
    lineTotal: lineTotal,
  );
}

class PoProgress {
  const PoProgress({
    this.ordered = 0,
    this.received = 0,
    this.billed = 0,
    this.cancelled = 0,
  });

  factory PoProgress.fromJson(Object? value) {
    final json = asJson(value);
    return PoProgress(
      ordered: asDouble(json['ordered']),
      received: asDouble(json['received']),
      billed: asDouble(json['billed']),
      cancelled: asDouble(json['cancelled']),
    );
  }

  final double ordered;
  final double received;
  final double billed;
  final double cancelled;
}

/// A short reference to a receipt or bill on a purchase order.
class DocRef {
  const DocRef({
    required this.id,
    required this.number,
    this.date,
    this.status = '',
    this.total,
  });

  factory DocRef.fromJson(Json json) => DocRef(
    id: asString(json['id']),
    number: asString(json['number']),
    date: asStringOrNull(json['receiptDate'] ?? json['billDate']),
    status: asString(json['status']),
    total: asDoubleOrNull(json['total']),
  );

  final String id;
  final String number;
  final String? date;
  final String status;
  final double? total;
}

class PurchaseOrder implements TaxSummary {
  const PurchaseOrder({
    required this.id,
    required this.number,
    required this.status,
    required this.locationId,
    required this.partyId,
    this.locationName = '',
    this.partyName = '',
    this.partyGstin,
    this.orderDate,
    this.expectedDate,
    this.placeOfSupply = '',
    this.supplyType = 'intra',
    this.subtotal = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.taxTotal = 0,
    this.roundOff = 0,
    this.total = 0,
    this.notes,
    this.approvalRequestId,
    this.sentAt,
    this.cancelledAt,
    this.cancelReason,
    this.createdAt,
    this.updatedAt,
    this.createdBy,
    this.progress = const PoProgress(),
    this.lines,
    this.receipts,
    this.bills,
  });

  factory PurchaseOrder.fromJson(Json json) => PurchaseOrder(
    id: asStringOrNull(json['id']),
    number: asStringOrNull(json['number']),
    status: asString(json['status'], 'draft'),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    partyGstin: asStringOrNull(json['partyGstin']),
    orderDate: asStringOrNull(json['orderDate']),
    expectedDate: asStringOrNull(json['expectedDate']),
    placeOfSupply: asString(json['placeOfSupply']),
    supplyType: asString(json['supplyType'], 'intra'),
    subtotal: asDouble(json['subtotal']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    taxTotal: asDouble(json['taxTotal']),
    roundOff: asDouble(json['roundOff']),
    total: asDouble(json['total']),
    notes: asStringOrNull(json['notes']),
    approvalRequestId: asStringOrNull(json['approvalRequestId']),
    sentAt: asDateTimeOrNull(json['sentAt']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    updatedAt: asDateTimeOrNull(json['updatedAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    progress: PoProgress.fromJson(json['progress']),
    lines: json['lines'] is List
        ? asJsonList(json['lines']).map(PoLine.fromJson).toList()
        : null,
    receipts: json['receipts'] is List
        ? asJsonList(json['receipts']).map(DocRef.fromJson).toList()
        : null,
    bills: json['bills'] is List
        ? asJsonList(json['bills']).map(DocRef.fromJson).toList()
        : null,
  );

  /// `null` in previews.
  final String? id;
  final String? number;
  final String status;
  final String locationId;
  final String locationName;
  final String partyId;
  final String partyName;
  final String? partyGstin;
  final String? orderDate;
  final String? expectedDate;
  @override
  final String placeOfSupply;
  final String supplyType;
  @override
  final double subtotal;
  @override
  final double cgst;
  @override
  final double sgst;
  @override
  final double igst;
  @override
  final double taxTotal;
  @override
  final double roundOff;
  @override
  final double total;
  final String? notes;
  final String? approvalRequestId;
  final DateTime? sentAt;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final UserRef? createdBy;
  final PoProgress progress;
  final List<PoLine>? lines;
  final List<DocRef>? receipts;
  final List<DocRef>? bills;

  @override
  bool get isInterState => supplyType == 'inter';
  bool get isDraft => status == 'draft';
  bool get isCancelled => status == 'cancelled';
  bool get canReceive =>
      status == 'approved' ||
      status == 'sent' ||
      status == 'partially_received';
  bool get canCancel => const {
    'draft',
    'pending_approval',
    'approved',
    'sent',
    'partially_received',
    'received',
  }.contains(status);

  List<TaxLine>? get taxLines => lines?.map((l) => l.toTaxLine()).toList();
}

/// Body of `POST /purchase-orders`, `PATCH /purchase-orders/:id` and
/// `POST /purchase-orders/preview`.
class PoDraft {
  const PoDraft({
    required this.locationId,
    required this.partyId,
    required this.lines,
    this.orderDate,
    this.expectedDate,
    this.notes,
  });

  final String locationId;
  final String partyId;
  final String? orderDate;
  final String? expectedDate;
  final String? notes;
  final List<DraftLine> lines;

  Json toJson() => withoutNulls({
    'locationId': locationId,
    'partyId': partyId,
    'orderDate': orderDate,
    'expectedDate': expectedDate,
    'notes': notes,
    'lines': [for (final l in lines) l.toJson()],
  });
}

class GrnLine {
  const GrnLine({
    required this.id,
    required this.poLineId,
    required this.itemId,
    required this.itemName,
    required this.unit,
    this.sku,
    this.receivedQty = 0,
    this.acceptedQty = 0,
    this.rejectedQty = 0,
    this.rejectReason,
    this.poRate = 0,
    this.discountPct = 0,
    this.unitCost = 0,
    this.gstRate = 0,
    this.value = 0,
    this.billedQty = 0,
    this.billableQty = 0,
  });

  factory GrnLine.fromJson(Json json) => GrnLine(
    id: asString(json['id']),
    poLineId: asString(json['poLineId']),
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    sku: asStringOrNull(json['sku']),
    unit: asString(json['unit']),
    receivedQty: asDouble(json['receivedQty']),
    acceptedQty: asDouble(json['acceptedQty']),
    rejectedQty: asDouble(json['rejectedQty']),
    rejectReason: asStringOrNull(json['rejectReason']),
    poRate: asDouble(json['poRate']),
    discountPct: asDouble(json['discountPct']),
    unitCost: asDouble(json['unitCost']),
    gstRate: asDouble(json['gstRate']),
    value: asDouble(json['value']),
    billedQty: asDouble(json['billedQty']),
    billableQty: asDouble(json['billableQty']),
  );

  final String id;
  final String poLineId;
  final String itemId;
  final String itemName;
  final String? sku;
  final String unit;
  final double receivedQty;
  final double acceptedQty;
  final double rejectedQty;
  final String? rejectReason;
  final double poRate;
  final double discountPct;
  final double unitCost;
  final double gstRate;
  final double value;
  final double billedQty;
  final double billableQty;
}

class GoodsReceipt {
  const GoodsReceipt({
    required this.id,
    required this.number,
    required this.status,
    this.receiptDate,
    this.purchaseOrderId = '',
    this.purchaseOrderNumber = '',
    this.partyId = '',
    this.partyName = '',
    this.locationId = '',
    this.locationName = '',
    this.challanNo,
    this.vehicleNo,
    this.notes,
    this.cancelledAt,
    this.cancelReason,
    this.lines = const [],
  });

  factory GoodsReceipt.fromJson(Json json) => GoodsReceipt(
    id: asString(json['id']),
    number: asString(json['number']),
    status: asString(json['status'], 'posted'),
    receiptDate: asStringOrNull(json['receiptDate']),
    purchaseOrderId: asString(json['purchaseOrderId']),
    purchaseOrderNumber: asString(json['purchaseOrderNumber']),
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    challanNo: asStringOrNull(json['challanNo']),
    vehicleNo: asStringOrNull(json['vehicleNo']),
    notes: asStringOrNull(json['notes']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    lines: asJsonList(json['lines']).map(GrnLine.fromJson).toList(),
  );

  final String id;
  final String number;
  final String status;
  final String? receiptDate;
  final String purchaseOrderId;
  final String purchaseOrderNumber;
  final String partyId;
  final String partyName;
  final String locationId;
  final String locationName;
  final String? challanNo;
  final String? vehicleNo;
  final String? notes;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final List<GrnLine> lines;

  bool get isCancelled => status == 'cancelled';
}

class ReorderSuggestion {
  const ReorderSuggestion({
    required this.itemId,
    required this.itemName,
    required this.locationId,
    required this.unit,
    this.sku,
    this.locationName = '',
    this.onHand = 0,
    this.reserved = 0,
    this.openPoQty = 0,
    this.position = 0,
    this.reorderLevel = 0,
    this.suggestedQty = 1,
    this.lastVendorId,
    this.lastVendorName,
    this.lastRate,
  });

  factory ReorderSuggestion.fromJson(Json json) => ReorderSuggestion(
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    sku: asStringOrNull(json['sku']),
    unit: asString(json['unit']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    onHand: asDouble(json['onHand']),
    reserved: asDouble(json['reserved']),
    openPoQty: asDouble(json['openPoQty']),
    position: asDouble(json['position']),
    reorderLevel: asDouble(json['reorderLevel']),
    suggestedQty: asDouble(json['suggestedQty'], 1),
    lastVendorId: asStringOrNull(json['lastVendorId']),
    lastVendorName: asStringOrNull(json['lastVendorName']),
    lastRate: asDoubleOrNull(json['lastRate']),
  );

  final String itemId;
  final String itemName;
  final String? sku;
  final String unit;
  final String locationId;
  final String locationName;
  final double onHand;
  final double reserved;
  final double openPoQty;
  final double position;
  final double reorderLevel;
  final double suggestedQty;
  final String? lastVendorId;
  final String? lastVendorName;
  final double? lastRate;

  String get key => '$itemId|$locationId';
}

/// Company-wide P2P settings (`GET/PUT /p2p/settings`).
class P2pSettings {
  const P2pSettings({
    this.receiptTolerancePct = 0,
    this.priceTolerancePct = 0,
    this.countApprovalValue = 10000,
  });

  factory P2pSettings.fromJson(Json json) => P2pSettings(
    receiptTolerancePct: asDouble(json['receiptTolerancePct']),
    priceTolerancePct: asDouble(json['priceTolerancePct']),
    countApprovalValue: asDouble(json['countApprovalValue'], 10000),
  );

  final double receiptTolerancePct;
  final double priceTolerancePct;
  final double countApprovalValue;
}
