import '../../core/json.dart';
import '../documents/document_models.dart';

/// A sales return against one invoice.
class CreditNote implements TaxSummary {
  const CreditNote({
    required this.invoiceId,
    required this.partyId,
    required this.placeOfSupply,
    required this.supplyType,
    required this.status,
    this.id,
    this.companyId = '',
    this.invoiceNumber = '',
    this.locationId = '',
    this.locationName = '',
    this.partyName = '',
    this.number,
    this.fy,
    this.noteDate,
    this.reason = '',
    this.restock = true,
    this.subtotal = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.taxTotal = 0,
    this.roundOff = 0,
    this.total = 0,
    this.createdAt,
    this.createdBy,
    this.cancelledAt,
    this.cancelReason,
    this.lines,
  });

  factory CreditNote.fromJson(Json json) => CreditNote(
    id: asStringOrNull(json['id']),
    companyId: asString(json['companyId']),
    invoiceId: asString(json['invoiceId']),
    invoiceNumber: asString(json['invoiceNumber']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    partyId: asString(json['partyId']),
    partyName: asString(json['partyName']),
    number: asStringOrNull(json['number']),
    fy: asStringOrNull(json['fy']),
    noteDate: asStringOrNull(json['noteDate']),
    reason: asString(json['reason']),
    restock: asBool(json['restock'], true),
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
    createdAt: asDateTimeOrNull(json['createdAt']),
    createdBy: UserRef.maybe(json['createdBy']),
    cancelledAt: asDateTimeOrNull(json['cancelledAt']),
    cancelReason: asStringOrNull(json['cancelReason']),
    lines: TaxLine.listOrNull(json['lines']),
  );

  /// `null` in previews.
  final String? id;
  final String companyId;
  final String invoiceId;
  final String invoiceNumber;
  final String locationId;
  final String locationName;
  final String partyId;
  final String partyName;

  /// `CN/26-27/00001`; `null` in previews.
  final String? number;
  final String? fy;
  final String? noteDate;
  final String reason;

  /// Whether returned goods went back into stock.
  final bool restock;
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
  final DateTime? createdAt;
  final UserRef? createdBy;
  final DateTime? cancelledAt;
  final String? cancelReason;

  /// Detail, create and preview; each has `invoiceLineId`.
  final List<TaxLine>? lines;

  @override
  bool get isInterState => supplyType == 'inter';
  bool get isCancelled => status == DocStatus.cancelled;
}

/// Body of `POST /credit-notes` and `POST /credit-notes/preview`.
class CreditNoteDraft {
  const CreditNoteDraft({
    required this.invoiceId,
    required this.reason,
    required this.lines,
    this.noteDate,
    this.restock = true,
  });

  final String invoiceId;
  final String? noteDate;
  final String reason;
  final bool restock;

  /// invoiceLineId → qty (only positive quantities are sent).
  final Map<String, double> lines;

  Json toJson() => withoutNulls({
    'invoiceId': invoiceId,
    'noteDate': noteDate,
    'reason': reason,
    'restock': restock,
    'lines': [
      for (final MapEntry(:key, :value) in lines.entries)
        if (value > 0) {'invoiceLineId': key, 'qty': value},
    ],
  });
}
