import '../../core/json.dart';
import '../documents/document_models.dart';

/// A debit note: goods sent back to a vendor, or a price reduction, against one purchase bill.
class PurchaseReturn implements TaxSummary {
  const PurchaseReturn({
    required this.id,
    required this.purchaseId,
    required this.partyId,
    required this.kind,
    required this.status,
    required this.placeOfSupply,
    required this.supplyType,
    this.number = '',
    this.purchaseNumber = '',
    this.supplierInvoiceNo,
    this.partyName = '',
    this.partyGstin,
    this.locationName = '',
    this.reason = '',
    this.returnDate,
    this.reverseCharge = false,
    this.subtotal = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.taxTotal = 0,
    this.roundOff = 0,
    this.total = 0,
    this.tdsReversed = 0,
    this.appliedAmount = 0,
    this.stockValue = 0,
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
    this.lines,
  });

  factory PurchaseReturn.fromJson(Json json) => PurchaseReturn(
    id: asString(json['id']),
    number: asString(json['number']),
    purchaseId: asString(json['purchaseId']),
    purchaseNumber: asString(json['purchaseNumber']),
    supplierInvoiceNo: asStringOrNull(json['supplierInvoiceNo']),
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    partyGstin: asStringOrNull(json['partyGstin']),
    locationName: asString(json['locationName']),
    kind: asString(json['kind'], 'goods'),
    status: DocStatus.parse(json['status']),
    reason: asString(json['reason']),
    returnDate: asStringOrNull(json['returnDate']),
    placeOfSupply: asString(json['placeOfSupply']),
    supplyType: asString(json['supplyType'], 'intra'),
    reverseCharge: asBool(json['reverseCharge']),
    subtotal: asDouble(json['subtotal']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    taxTotal: asDouble(json['taxTotal']),
    roundOff: asDouble(json['roundOff']),
    total: asDouble(json['total']),
    tdsReversed: asDouble(json['tdsReversed']),
    appliedAmount: asDouble(json['appliedAmount']),
    stockValue: asDouble(json['stockValue']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    lines: json['lines'] is List
        ? asJsonList(json['lines']).map(PurchaseReturnLine.fromJson).toList()
        : null,
  );

  final String id;

  /// `DN/26-27/00001`.
  final String number;
  final String purchaseId;
  final String purchaseNumber;
  final String? supplierInvoiceNo;
  final String partyId;
  final String partyName;
  final String? partyGstin;
  final String locationName;

  /// `goods` or `price`.
  final String kind;
  final DocStatus status;
  final String reason;
  final String? returnDate;
  @override
  final String placeOfSupply;
  final String supplyType;
  final bool reverseCharge;
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
  final double tdsReversed;

  /// How much of the bill this note settled.
  final double appliedAmount;
  final double stockValue;
  final DateTime? createdAt;
  final UserRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;
  final List<PurchaseReturnLine>? lines;

  bool get isGoods => kind == 'goods';
  bool get isCancelled => status == DocStatus.cancelled;
  @override
  bool get isInterState => supplyType == 'inter';

  /// Lines in the shape the shared tax views and the PDF read.
  List<TaxLine> get taxLines => [
    for (final l in lines ?? const <PurchaseReturnLine>[]) l.toTaxLine(isGoods),
  ];
}

class PurchaseReturnLine {
  const PurchaseReturnLine({
    required this.purchaseLineId,
    required this.itemName,
    required this.description,
    required this.unit,
    this.itemId = '',
    this.hsnCode,
    this.qty = 0,
    this.gstRate = 0,
    this.taxableValue = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.lineTotal = 0,
    this.stockValue = 0,
  });

  factory PurchaseReturnLine.fromJson(Json json) => PurchaseReturnLine(
    purchaseLineId: asString(json['purchaseLineId']),
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    description: asString(json['description']),
    hsnCode: asStringOrNull(json['hsnCode']),
    qty: asDouble(json['qty']),
    unit: asString(json['unit']),
    gstRate: asDouble(json['gstRate']),
    taxableValue: asDouble(json['taxableValue']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    lineTotal: asDouble(json['lineTotal']),
    stockValue: asDouble(json['stockValue']),
  );

  final String purchaseLineId;
  final String itemId;
  final String itemName;
  final String description;
  final String? hsnCode;
  final double qty;
  final String unit;
  final double gstRate;
  final double taxableValue;
  final double cgst;
  final double sgst;
  final double igst;
  final double lineTotal;
  final double stockValue;

  /// A price line has no quantity: show it as one adjustment of its amount.
  TaxLine toTaxLine(bool goods) => TaxLine(
    itemId: itemId,
    description: goods ? description : 'Price reduction: $description',
    hsnCode: hsnCode,
    qty: goods ? qty : 1,
    unit: goods ? unit : 'nos',
    rate: goods && qty > 0 ? taxableValue / qty : taxableValue,
    taxableValue: taxableValue,
    gstRate: gstRate,
    cgst: cgst,
    sgst: sgst,
    igst: igst,
    lineTotal: lineTotal,
  );
}

/// Body of `POST /purchase-returns`.
class PurchaseReturnDraft {
  const PurchaseReturnDraft({
    required this.purchaseId,
    required this.kind,
    required this.reason,
    required this.lines,
    this.returnDate,
  });

  final String purchaseId;
  final String kind;
  final String reason;
  final String? returnDate;

  /// purchaseLineId → quantity (goods) or amount before GST (price).
  final Map<String, double> lines;

  Json toJson() => withoutNulls({
    'purchaseId': purchaseId,
    'kind': kind,
    'reason': reason,
    'returnDate': returnDate,
    'lines': [
      for (final MapEntry(:key, :value) in lines.entries)
        if (value > 0)
          {'purchaseLineId': key, kind == 'goods' ? 'qty' : 'amount': value},
    ],
  });
}
