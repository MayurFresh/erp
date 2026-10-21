import '../../core/json.dart';
import '../documents/document_models.dart';

export '../documents/document_models.dart'
    show DocStatus, PaymentStatus, Settlement, TaxLine, TaxSummary, UserRef;

typedef InvoiceLine = TaxLine;
typedef InvoiceStatus = DocStatus;
typedef InvoiceDraftLine = DraftLine;

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
