import '../../core/json.dart';
import '../documents/document_models.dart';

typedef PurchaseLine = TaxLine;

/// A purchase bill. GST follows the supplier's state against the location's.
class Purchase implements TaxSummary {
  const Purchase({
    required this.locationId,
    required this.partyId,
    required this.placeOfSupply,
    required this.supplyType,
    required this.status,
    this.id,
    this.companyId = '',
    this.locationName = '',
    this.partyName = '',
    this.partyGstin,
    this.number,
    this.supplierInvoiceNo,
    this.supplierInvoiceDate,
    this.fy,
    this.billDate,
    this.dueDate,
    this.subtotal = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.taxTotal = 0,
    this.roundOff = 0,
    this.total = 0,
    this.amountPaid = 0,
    this.amountDue = 0,
    this.paymentStatus,
    this.notes,
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
    this.lines,
    this.settlements,
    this.tdsSectionId,
    this.tdsSectionCode,
    this.tdsBase = 0,
    this.tdsRate = 0,
    this.tdsAmount = 0,
    this.netPayable,
    this.reverseCharge = false,
    this.rcmSelfInvoiceNo,
    this.msmeDueDate,
    this.msmeCategory,
  });

  factory Purchase.fromJson(Json json) => Purchase(
    id: asStringOrNull(json['id']),
    companyId: asString(json['companyId']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    partyGstin: asStringOrNull(json['partyGstin']),
    number: asStringOrNull(json['number']),
    supplierInvoiceNo: asStringOrNull(json['supplierInvoiceNo']),
    supplierInvoiceDate: asStringOrNull(json['supplierInvoiceDate']),
    fy: asStringOrNull(json['fy']),
    billDate: asStringOrNull(json['billDate']),
    dueDate: asStringOrNull(json['dueDate']),
    placeOfSupply: asString(json['placeOfSupply']),
    supplyType: asString(json['supplyType'], 'intra'),
    status: DocStatus.parse(json['status']),
    subtotal: asDouble(json['subtotal']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    taxTotal: asDouble(json['taxTotal']),
    roundOff: asDouble(json['roundOff']),
    total: asDouble(json['total']),
    amountPaid: asDouble(json['amountPaid']),
    amountDue: asDouble(json['amountDue']),
    paymentStatus: PaymentStatus.parse(json['paymentStatus']),
    notes: asStringOrNull(json['notes']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    lines: TaxLine.listOrNull(json['lines']),
    settlements: Settlement.listOrNull(json['settlements']),
    tdsSectionId: asStringOrNull(json['tdsSectionId']),
    tdsSectionCode: asStringOrNull(json['tdsSectionCode']),
    tdsBase: asDouble(json['tdsBase']),
    tdsRate: asDouble(json['tdsRate']),
    tdsAmount: asDouble(json['tdsAmount']),
    netPayable: asDoubleOrNull(json['netPayable']),
    reverseCharge: asBool(json['reverseCharge']),
    rcmSelfInvoiceNo: asStringOrNull(json['rcmSelfInvoiceNo']),
    msmeDueDate: asStringOrNull(json['msmeDueDate']),
    msmeCategory: asStringOrNull(json['msmeCategory']),
  );

  /// `null` in previews.
  final String? id;
  final String companyId;
  final String locationId;
  final String locationName;
  final String partyId;
  final String partyName;
  final String? partyGstin;

  /// Internal number, `PUR/26-27/00001`; `null` in previews.
  final String? number;
  final String? supplierInvoiceNo;
  final String? supplierInvoiceDate;
  final String? fy;
  final String? billDate;
  final String? dueDate;
  @override
  final String placeOfSupply;
  final String supplyType;
  final DocStatus status;
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
  final double amountPaid;
  final double amountDue;
  final PaymentStatus? paymentStatus;
  final String? notes;
  final DateTime? createdAt;
  final UserRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  /// Detail, create and preview.
  final List<PurchaseLine>? lines;

  /// Detail only (payments).
  final List<Settlement>? settlements;

  final String? tdsSectionId;
  final String? tdsSectionCode;
  final double tdsBase;
  final double tdsRate;
  final double tdsAmount;

  /// `total − tdsAmount` (API v1.4); null from an older server.
  final double? netPayable;
  final bool reverseCharge;
  final String? rcmSelfInvoiceNo;
  final String? msmeDueDate;

  /// `micro`/`small`/`medium` when the supplier is MSME.
  final String? msmeCategory;

  double get payable => netPayable ?? (total - tdsAmount);
  bool get isMsmeMicroSmall =>
      msmeCategory == 'micro' || msmeCategory == 'small';

  @override
  bool get isInterState => supplyType == 'inter';
  bool get isCancelled => status == DocStatus.cancelled;
}

/// Body of `POST /purchases` and `POST /purchases/preview`.
class PurchaseDraft {
  const PurchaseDraft({
    required this.locationId,
    required this.partyId,
    required this.lines,
    this.billDate,
    this.supplierInvoiceNo,
    this.supplierInvoiceDate,
    this.notes,
    this.tdsSectionId,
    this.reverseCharge = false,
  });

  /// Always sent: an explicit null means "no TDS" (the server would
  /// otherwise fall back to the vendor's section).
  final String? tdsSectionId;
  final bool reverseCharge;
  final String locationId;
  final String partyId;
  final String? billDate;
  final String? supplierInvoiceNo;
  final String? supplierInvoiceDate;
  final String? notes;
  final List<DraftLine> lines;

  Json toJson() => withoutNulls({
    'locationId': locationId,
    'partyId': partyId,
    'billDate': billDate,
    'supplierInvoiceNo': supplierInvoiceNo,
    'supplierInvoiceDate': supplierInvoiceDate,
    'notes': notes,
    'lines': [for (final line in lines) line.toJson()],
  })..addAll({'tdsSectionId': tdsSectionId, 'reverseCharge': reverseCharge});
}
