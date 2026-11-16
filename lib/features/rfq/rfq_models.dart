import '../../core/json.dart';

const Map<String, String> rfqStatusLabels = {
  'draft': 'Draft',
  'sent': 'Sent',
  'quotes_received': 'Quotes received',
  'closed': 'Closed',
};

class RfqQuote {
  const RfqQuote({
    required this.partyId,
    required this.partyName,
    required this.rate,
    required this.discountPct,
    required this.gstRate,
    required this.total,
    required this.isLowest,
    required this.isFastest,
    this.leadDays,
    this.paymentTerms,
    this.validUntil,
    this.notes,
  });

  factory RfqQuote.fromJson(Json j) => RfqQuote(
    partyId: asString(j['partyId']),
    partyName: asString(j['partyName']),
    rate: asDouble(j['rate']),
    discountPct: asDouble(j['discountPct']),
    gstRate: asDouble(j['gstRate']),
    total: asDouble(j['total']),
    isLowest: asBool(j['isLowest']),
    isFastest: asBool(j['isFastest']),
    leadDays: asDoubleOrNull(j['leadDays'])?.toInt(),
    paymentTerms: asStringOrNull(j['paymentTerms']),
    validUntil: asStringOrNull(j['validUntil']),
    notes: asStringOrNull(j['notes']),
  );

  final String partyId;
  final String partyName;
  final double rate;
  final double discountPct;
  final double gstRate;
  final double total;
  final bool isLowest;
  final bool isFastest;
  final int? leadDays;
  final String? paymentTerms;
  final String? validUntil;
  final String? notes;
}

class RfqLine {
  const RfqLine({
    required this.id,
    required this.lineNo,
    required this.itemId,
    required this.itemName,
    required this.qty,
    required this.unit,
    required this.quotes,
    this.chosenPartyId,
    this.purchaseOrderId,
  });

  factory RfqLine.fromJson(Json j) => RfqLine(
    id: asString(j['id']),
    lineNo: asInt(j['lineNo']),
    itemId: asString(j['itemId']),
    itemName: asString(j['itemName']),
    qty: asDouble(j['qty']),
    unit: asString(j['unit']),
    chosenPartyId: asStringOrNull(j['chosenPartyId']),
    purchaseOrderId: asStringOrNull(j['purchaseOrderId']),
    quotes: asJsonList(j['quotes']).map(RfqQuote.fromJson).toList(),
  );

  final String id;
  final int lineNo;
  final String itemId;
  final String itemName;
  final double qty;
  final String unit;
  final String? chosenPartyId;
  final String? purchaseOrderId;
  final List<RfqQuote> quotes;

  RfqQuote? quoteBy(String partyId) {
    for (final q in quotes) {
      if (q.partyId == partyId) return q;
    }
    return null;
  }
}

class RfqVendor {
  const RfqVendor({
    required this.partyId,
    required this.partyName,
    required this.total,
    this.sentAt,
  });

  factory RfqVendor.fromJson(Json j) => RfqVendor(
    partyId: asString(j['partyId']),
    partyName: asString(j['partyName']),
    total: asDouble(j['total']),
    sentAt: asStringOrNull(j['sentAt']),
  );

  final String partyId;
  final String partyName;
  final double total;
  final String? sentAt;
}

class Rfq {
  const Rfq({
    required this.id,
    required this.number,
    required this.status,
    required this.rfqDate,
    required this.locationId,
    required this.locationName,
    required this.vendors,
    required this.lines,
    required this.orders,
    this.dueDate,
    this.notes,
    this.indentId,
    this.vendorCount = 0,
    this.lineCount = 0,
  });

  factory Rfq.fromJson(Json j) {
    final vendors = asJsonList(j['vendors']).map(RfqVendor.fromJson).toList();
    final lines = asJsonList(j['lines']).map(RfqLine.fromJson).toList();
    return Rfq(
      id: asString(j['id']),
      number: asString(j['number']),
      status: asString(j['status'], 'draft'),
      rfqDate: asString(j['rfqDate']),
      dueDate: asStringOrNull(j['dueDate']),
      locationId: asString(j['locationId']),
      locationName: asString(j['locationName']),
      notes: asStringOrNull(j['notes']),
      indentId: asStringOrNull(j['indentId']),
      vendors: vendors,
      lines: lines,
      orders: asJsonList(j['purchaseOrders']),
      vendorCount: j.containsKey('vendorCount')
          ? asInt(j['vendorCount'])
          : vendors.length,
      lineCount: j.containsKey('lineCount') ? asInt(j['lineCount']) : lines.length,
    );
  }

  final String id;
  final String number;
  final String status;
  final String rfqDate;
  final String? dueDate;
  final String locationId;
  final String locationName;
  final String? notes;
  final String? indentId;
  final List<RfqVendor> vendors;
  final List<RfqLine> lines;
  final List<Json> orders;
  final int vendorCount;
  final int lineCount;

  bool get isDraft => status == 'draft';
  bool get canQuote => status == 'sent' || status == 'quotes_received';
  bool get hasChoice => lines.any((l) => l.chosenPartyId != null);
}

/// Text to send a vendor by WhatsApp or email.
String rfqMessage(Rfq r, String vendorName) {
  final b = StringBuffer()
    ..writeln('Hello $vendorName,')
    ..writeln()
    ..writeln('Please quote for request ${r.number}:');
  for (final l in r.lines) {
    b.writeln('- ${l.itemName}: ${_q(l.qty)} ${l.unit}');
  }
  b
    ..writeln()
    ..writeln(
      'Give your rate, discount, GST, delivery time, payment terms and how '
      'long the quote is valid.',
    );
  if (r.dueDate != null) b.writeln('Please reply by ${r.dueDate}.');
  b
    ..writeln()
    ..write('Thank you');
  return b.toString();
}

String _q(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
