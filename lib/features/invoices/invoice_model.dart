import '../../core/json.dart';
import '../documents/document_models.dart';

export '../documents/document_models.dart'
    show DocStatus, PaymentStatus, Settlement, TaxLine, TaxSummary, UserRef;

typedef InvoiceLine = TaxLine;
typedef InvoiceStatus = DocStatus;
typedef InvoiceDraftLine = DraftLine;

/// `Invoice.einvoice` (API v1.3): the IRN and acknowledgement.
class EInvoice {
  const EInvoice({
    required this.irn,
    required this.status,
    this.ackNo = '',
    this.ackDate,
    this.signedQrCode = '',
    this.sandbox = false,
    this.cancelledAt,
    this.cancelReason,
  });

  static EInvoice? maybe(Object? value) {
    final json = asJsonOrNull(value);
    if (json == null) return null;
    return EInvoice(
      irn: asString(json['irn']),
      ackNo: asString(json['ackNo']),
      ackDate: asDateTimeOrNull(json['ackDate']),
      signedQrCode: asString(json['signedQrCode']),
      status: asString(json['status'], 'active'),
      sandbox: asBool(json['sandbox']),
      cancelledAt: asDateTimeOrNull(json['cancelledAt']),
      cancelReason: asStringOrNull(json['cancelReason']),
    );
  }

  final String irn;
  final String ackNo;
  final DateTime? ackDate;
  final String signedQrCode;

  /// `active` or `cancelled`.
  final String status;
  final bool sandbox;
  final DateTime? cancelledAt;
  final String? cancelReason;

  bool get isActive => status == 'active';

  /// An IRN can be cancelled within 24 hours of the acknowledgement.
  DateTime? get cancelDeadline => ackDate?.add(const Duration(hours: 24));

  bool canCancelAt(DateTime now) {
    final deadline = cancelDeadline;
    return isActive && (deadline == null || now.isBefore(deadline));
  }
}

/// `Invoice.ewaybill` (API v1.3).
class EWayBill {
  const EWayBill({
    required this.ewbNo,
    required this.status,
    this.ewbDate,
    this.validUntil,
    this.transportMode = 'road',
    this.vehicleNo,
    this.distanceKm = 0,
    this.transporterGstin,
    this.cancelledAt,
  });

  static EWayBill? maybe(Object? value) {
    final json = asJsonOrNull(value);
    if (json == null) return null;
    return EWayBill(
      ewbNo: asString(json['ewbNo']),
      ewbDate: asDateTimeOrNull(json['ewbDate']),
      validUntil: asDateTimeOrNull(json['validUntil']),
      status: asString(json['status'], 'active'),
      transportMode: asString(json['transportMode'], 'road'),
      vehicleNo: asStringOrNull(json['vehicleNo']),
      distanceKm: asInt(json['distanceKm']),
      transporterGstin: asStringOrNull(json['transporterGstin']),
      cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    );
  }

  final String ewbNo;
  final DateTime? ewbDate;
  final DateTime? validUntil;
  final String status;
  final String transportMode;
  final String? vehicleNo;
  final int distanceKm;
  final String? transporterGstin;
  final DateTime? cancelledAt;

  bool get isActive => status == 'active';

  bool canCancelAt(DateTime now) {
    final date = ewbDate;
    return isActive &&
        (date == null || now.isBefore(date.add(const Duration(hours: 24))));
  }
}

class Invoice implements TaxSummary {
  const Invoice({
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
    this.fy,
    this.invoiceDate,
    this.dueDate,
    this.subtotal = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.taxTotal = 0,
    this.roundOff = 0,
    this.total = 0,
    this.amountPaid,
    this.amountDue,
    this.paymentStatus,
    this.notes,
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
    this.lines,
    this.settlements,
    this.einvoice,
    this.ewaybill,
  });

  factory Invoice.fromJson(Json json) => Invoice(
    id: asStringOrNull(json['id']),
    companyId: asString(json['companyId']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    partyGstin: asStringOrNull(json['partyGstin']),
    number: asStringOrNull(json['number']),
    fy: asStringOrNull(json['fy']),
    invoiceDate: asStringOrNull(json['invoiceDate']),
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
    amountPaid: asDoubleOrNull(json['amountPaid']),
    amountDue: asDoubleOrNull(json['amountDue']),
    paymentStatus: PaymentStatus.parse(json['paymentStatus']),
    notes: asStringOrNull(json['notes']),
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    lines: TaxLine.listOrNull(json['lines']),
    settlements: Settlement.listOrNull(json['settlements']),
    einvoice: EInvoice.maybe(json['einvoice']),
    ewaybill: EWayBill.maybe(json['ewaybill']),
  );

  /// `null` in previews.
  final String? id;
  final String companyId;
  final String locationId;
  final String locationName;
  final String partyId;
  final String partyName;
  final String? partyGstin;

  /// `null` in previews, e.g. `INV/26-27/00001`.
  final String? number;
  final String? fy;

  /// `YYYY-MM-DD`.
  final String? invoiceDate;

  /// `YYYY-MM-DD`: invoice date + the party's credit days.
  final String? dueDate;

  @override
  final String placeOfSupply;

  /// `intra` or `inter`.
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

  /// Receipts allocated + credit notes against it. The v1.1 payment fields
  /// are `null` when the server does not send them.
  final double? amountPaid;

  /// 0 for cancelled invoices.
  final double? amountDue;
  final PaymentStatus? paymentStatus;
  final String? notes;
  final DateTime? createdAt;
  final UserRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  /// Present on detail, create and preview; absent in lists.
  final List<InvoiceLine>? lines;

  /// Detail only.
  final List<Settlement>? settlements;

  /// GST e-invoice (API v1.3); `null` until an IRN is generated.
  final EInvoice? einvoice;
  final EWayBill? ewaybill;

  /// An IRN exists and has not been cancelled.
  bool get hasActiveIrn => einvoice?.isActive ?? false;

  @override
  bool get isInterState => supplyType == 'inter';
  bool get isCancelled => status == DocStatus.cancelled;

  /// Whether any line can still be returned on a credit note.
  bool get hasReturnableQty =>
      (lines ?? const <InvoiceLine>[]).any((l) => l.returnableQty > 0);
}

/// Body of `POST /invoices` and `POST /invoices/preview`.
class InvoiceDraft {
  const InvoiceDraft({
    required this.locationId,
    required this.partyId,
    required this.lines,
    this.invoiceDate,
    this.notes,
  });

  final String locationId;
  final String partyId;

  /// `YYYY-MM-DD`; server defaults to today.
  final String? invoiceDate;
  final String? notes;
  final List<InvoiceDraftLine> lines;

  Json toJson() => withoutNulls({
    'locationId': locationId,
    'partyId': partyId,
    'invoiceDate': invoiceDate,
    'notes': notes,
    'lines': [for (final line in lines) line.toJson()],
  });
}
