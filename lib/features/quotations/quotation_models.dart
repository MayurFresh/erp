import '../../core/entered_unit.dart';
import '../../core/json.dart';

const Map<String, String> quotationKinds = {
  'quotation': 'Quotation',
  'proforma': 'Proforma invoice',
};

const Map<String, String> quotationStatuses = {
  'draft': 'Draft',
  'sent': 'Sent',
  'accepted': 'Accepted',
  'declined': 'Declined',
  'converted': 'Converted',
  'cancelled': 'Cancelled',
  'expired': 'Expired',
};

String kindLabel(String kind) => quotationKinds[kind] ?? 'Quotation';

class QuotationLine {
  const QuotationLine({
    required this.id,
    required this.lineNo,
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.qty,
    required this.rate,
    this.hsn,
    this.description = '',
    this.discountPct = 0,
    this.discountAmount = 0,
    this.gstRate = 0,
    this.taxable = 0,
    this.tax = 0,
    this.total = 0,
    this.entered,
  });

  factory QuotationLine.fromJson(Json j) => QuotationLine(
    id: asString(j['id']),
    lineNo: asInt(j['lineNo']),
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    unit: asString(j['unit']),
    hsn: asStringOrNull(j['hsn']),
    description: asString(j['description']),
    qty: asDouble(j['qty']),
    rate: asDouble(j['rate']),
    discountPct: asDouble(j['discountPct']),
    discountAmount: asDouble(j['discountAmount']),
    gstRate: asDouble(j['gstRate']),
    taxable: asDouble(j['taxable']),
    tax: asDouble(j['tax']),
    total: asDouble(j['total']),
    entered: EnteredUnit.fromJson(j),
  );

  final EnteredUnit? entered;
  final String id;
  final int lineNo;
  final String itemId;
  final String itemName;
  final String unit;
  final String? hsn;
  final String description;
  final double qty;
  final double rate;
  final double discountPct;
  final double discountAmount;
  final double gstRate;
  final double taxable;
  final double tax;
  final double total;
}

class TaxSplit {
  const TaxSplit({this.cgst = 0, this.sgst = 0, this.igst = 0});

  factory TaxSplit.fromJson(Json? j) => j == null
      ? const TaxSplit()
      : TaxSplit(
          cgst: asDouble(j['cgst']),
          sgst: asDouble(j['sgst']),
          igst: asDouble(j['igst']),
        );

  final double cgst;
  final double sgst;
  final double igst;
}

class Quotation {
  const Quotation({
    required this.id,
    required this.kind,
    required this.number,
    required this.status,
    required this.partyId,
    required this.partyName,
    this.fy,
    this.expired = false,
    this.locationId = '',
    this.locationName = '',
    this.contactId,
    this.dealId,
    this.quoteDate,
    this.validUntil,
    this.placeOfSupply,
    this.subtotal = 0,
    this.taxTotal = 0,
    this.total = 0,
    this.notes,
    this.terms,
    this.revisionOf,
    this.salesOrderId,
    this.invoiceId,
    this.sentAt,
    this.acceptedAt,
    this.declinedAt,
    this.declineReason,
    this.createdByName,
    this.createdAt,
    this.updatedAt,
    this.lines = const [],
    this.taxSplit = const TaxSplit(),
  });

  factory Quotation.fromJson(Json j) => Quotation(
    id: asString(j['id']),
    kind: asString(j['kind'], 'quotation'),
    number: asString(j['number']),
    fy: asStringOrNull(j['fy']),
    status: asString(j['status'], 'draft'),
    expired: asBool(j['expired']),
    locationId: asString(j['locationId']),
    locationName: asString(j['locationName']),
    partyId: asString(j['partyId']),
    partyName: asString(j['partyName']),
    contactId: asStringOrNull(j['contactId']),
    dealId: asStringOrNull(j['dealId']),
    quoteDate: asStringOrNull(j['quoteDate']),
    validUntil: asStringOrNull(j['validUntil']),
    placeOfSupply: asStringOrNull(j['placeOfSupply']),
    subtotal: asDouble(j['subtotal']),
    taxTotal: asDouble(j['taxTotal']),
    total: asDouble(j['total']),
    notes: asStringOrNull(j['notes']),
    terms: asStringOrNull(j['terms']),
    revisionOf: asStringOrNull(j['revisionOf']),
    salesOrderId: asStringOrNull(j['salesOrderId']),
    invoiceId: asStringOrNull(j['invoiceId']),
    sentAt: asDateTimeOrNull(j['sentAt']),
    acceptedAt: asDateTimeOrNull(j['acceptedAt']),
    declinedAt: asDateTimeOrNull(j['declinedAt']),
    declineReason: asStringOrNull(j['declineReason']),
    createdByName: asJsonOrNull(j['createdBy'])?['name']?.toString(),
    createdAt: asDateTimeOrNull(j['createdAt']),
    updatedAt: asDateTimeOrNull(j['updatedAt']),
    lines: [for (final l in asJsonList(j['lines'])) QuotationLine.fromJson(l)],
    taxSplit: TaxSplit.fromJson(asJsonOrNull(j['taxSplit'])),
  );

  final String id;
  final String kind;
  final String number;
  final String? fy;
  final String status;
  final bool expired;
  final String locationId;
  final String locationName;
  final String partyId;
  final String partyName;
  final String? contactId;
  final String? dealId;
  final String? quoteDate;
  final String? validUntil;
  final String? placeOfSupply;
  final double subtotal;
  final double taxTotal;
  final double total;
  final String? notes;
  final String? terms;
  final String? revisionOf;
  final String? salesOrderId;
  final String? invoiceId;
  final DateTime? sentAt;
  final DateTime? acceptedAt;
  final DateTime? declinedAt;
  final String? declineReason;
  final String? createdByName;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final List<QuotationLine> lines;
  final TaxSplit taxSplit;

  bool get isProforma => kind == 'proforma';

  /// The word shown for the state: "Expired" when the valid date passed
  /// while the document was still open.
  String get statusWord =>
      expired && (status == 'draft' || status == 'sent') ? 'expired' : status;

  /// Draft or sent: it can still be edited or sent on.
  bool get isEditable => status == 'draft' || status == 'sent';

  /// Declined, cancelled and converted documents are final.
  bool get canConvert =>
      status == 'draft' || status == 'sent' || status == 'accepted';

  bool get canCancel => status != 'cancelled' && status != 'converted';
}

class QuotationLineInput {
  const QuotationLineInput({
    required this.itemId,
    required this.qty,
    this.rate,
    this.discountPct = 0,
    this.discountAmount = 0,
    this.description,
    this.unit,
  });

  final String itemId;
  final double qty;
  final double? rate;
  final double discountPct;
  final double discountAmount;
  final String? description;

  /// Alternate unit that [qty] and [rate] are in; null means the item's own unit.
  final String? unit;

  Json toJson() => {
    'itemId': itemId,
    'qty': qty,
    if (rate != null) 'rate': rate,
    if (discountPct > 0) 'discountPct': discountPct,
    if (discountAmount > 0) 'discountAmount': discountAmount,
    if (description != null) 'description': description,
    if (unit != null) 'unit': unit,
  };
}

class QuotationInput {
  const QuotationInput({
    required this.kind,
    required this.locationId,
    required this.partyId,
    required this.lines,
    this.contactId,
    this.dealId,
    this.quoteDate,
    this.validUntil,
    this.notes,
    this.terms,
  });

  final String kind;
  final String locationId;
  final String partyId;
  final String? contactId;
  final String? dealId;
  final String? quoteDate;
  final String? validUntil;
  final String? notes;
  final String? terms;
  final List<QuotationLineInput> lines;

  Json toJson() => {
    'kind': kind,
    'locationId': locationId,
    'partyId': partyId,
    if (contactId != null) 'contactId': contactId,
    if (dealId != null) 'dealId': dealId,
    if (quoteDate != null) 'quoteDate': quoteDate,
    if (validUntil != null) 'validUntil': validUntil,
    if (notes != null) 'notes': notes,
    if (terms != null) 'terms': terms,
    'lines': [for (final l in lines) l.toJson()],
  };
}

class ConvertResult {
  const ConvertResult({
    required this.quotation,
    this.salesOrderId,
    this.invoiceId,
  });

  factory ConvertResult.fromJson(Json j) => ConvertResult(
    quotation: Quotation.fromJson(asJson(j['quotation'])),
    salesOrderId: asStringOrNull(j['salesOrderId']),
    invoiceId: asStringOrNull(j['invoiceId']),
  );

  final Quotation quotation;
  final String? salesOrderId;
  final String? invoiceId;
}
