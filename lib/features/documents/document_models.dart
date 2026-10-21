/// Pieces shared by the money documents (invoices, purchases, credit notes,
/// receipts and payments, expenses).
library;

import '../../core/json.dart';

class UserRef {
  const UserRef({required this.id, required this.name});

  factory UserRef.fromJson(Json json) =>
      UserRef(id: asString(json['id']), name: asString(json['name']));

  static UserRef? maybe(Object? value) {
    final json = asJsonOrNull(value);
    return json == null ? null : UserRef.fromJson(json);
  }

  final String id;
  final String name;
}

/// `posted` / `cancelled`, used by every money document.
enum DocStatus {
  posted('Posted'),
  cancelled('Cancelled');

  const DocStatus(this.label);

  final String label;

  static DocStatus parse(Object? value) =>
      value == 'cancelled' ? DocStatus.cancelled : DocStatus.posted;
}

enum PaymentStatus {
  unpaid('Unpaid'),
  partial('Partly paid'),
  paid('Paid');

  const PaymentStatus(this.label);

  final String label;

  /// `null` when absent (older servers) or unknown.
  static PaymentStatus? parse(Object? value) {
    for (final status in values) {
      if (status.name == value) return status;
    }
    return null;
  }
}

/// A receipt, payment or credit note applied to an invoice or purchase.
class Settlement {
  const Settlement({
    required this.kind,
    required this.id,
    required this.number,
    required this.amount,
    this.date,
  });

  factory Settlement.fromJson(Json json) => Settlement(
    kind: asString(json['kind']),
    id: asString(json['id']),
    number: asString(json['number']),
    date: asStringOrNull(json['date']),
    amount: asDouble(json['amount']),
  );

  static List<Settlement>? listOrNull(Object? value) => value is List
      ? asJsonList(value).map(Settlement.fromJson).toList()
      : null;

  /// `receipt`, `payment` or `credit_note`.
  final String kind;
  final String id;
  final String number;
  final String? date;
  final double amount;

  String get kindLabel => switch (kind) {
    'receipt' => 'Receipt',
    'payment' => 'Payment',
    'credit_note' => 'Credit note',
    _ => kind,
  };

  /// App route of the settling document.
  String get route => switch (kind) {
    'receipt' => '/receipts/$id',
    'payment' => '/payments/$id',
    'credit_note' => '/credit-notes/$id',
    _ => '/',
  };
}

/// Totals shared by GST documents (invoice, purchase, credit note).
abstract interface class TaxSummary {
  double get subtotal;
  double get cgst;
  double get sgst;
  double get igst;
  double get taxTotal;
  double get roundOff;
  double get total;

  /// State code.
  String get placeOfSupply;
  bool get isInterState;
}

/// A line of an invoice, purchase or credit note.
class TaxLine {
  const TaxLine({
    required this.itemId,
    required this.description,
    required this.qty,
    required this.unit,
    required this.rate,
    this.id,
    this.invoiceLineId,
    this.hsnCode,
    this.discountPct = 0,
    this.taxableValue = 0,
    this.gstRate = 0,
    this.cgst = 0,
    this.sgst = 0,
    this.igst = 0,
    this.lineTotal = 0,
    this.returnedQty = 0,
  });

  factory TaxLine.fromJson(Json json) => TaxLine(
    id: asStringOrNull(json['id']),
    invoiceLineId: asStringOrNull(json['invoiceLineId']),
    itemId: asString(json['itemId']),
    description: asString(json['description']),
    hsnCode: asStringOrNull(json['hsnCode']),
    qty: asDouble(json['qty']),
    unit: asString(json['unit']),
    rate: asDouble(json['rate']),
    discountPct: asDouble(json['discountPct']),
    taxableValue: asDouble(json['taxableValue']),
    gstRate: asDouble(json['gstRate']),
    cgst: asDouble(json['cgst']),
    sgst: asDouble(json['sgst']),
    igst: asDouble(json['igst']),
    lineTotal: asDouble(json['lineTotal']),
    returnedQty: asDouble(json['returnedQty']),
  );

  static List<TaxLine>? listOrNull(Object? value) =>
      value is List ? asJsonList(value).map(TaxLine.fromJson).toList() : null;

  /// `null` in previews.
  final String? id;

  /// Credit note lines only: the invoice line being returned.
  final String? invoiceLineId;
  final String itemId;
  final String description;
  final String? hsnCode;
  final double qty;
  final String unit;
  final double rate;
  final double discountPct;
  final double taxableValue;
  final double gstRate;
  final double cgst;
  final double sgst;
  final double igst;
  final double lineTotal;

  /// Invoice detail only: quantity already returned on credit notes.
  final double returnedQty;

  double get taxTotal => cgst + sgst + igst;

  /// Quantity that can still be returned.
  double get returnableQty {
    final left = qty - returnedQty;
    return left > 0 ? left : 0;
  }
}

/// A line of a create / preview body: `{ itemId, qty, rate?, discountPct?,
/// description? }`.
class DraftLine {
  const DraftLine({
    required this.itemId,
    required this.qty,
    this.rate,
    this.discountPct,
    this.description,
  });

  final String itemId;
  final double qty;
  final double? rate;
  final double? discountPct;
  final String? description;

  Json toJson() => withoutNulls({
    'itemId': itemId,
    'qty': qty,
    'rate': rate,
    'discountPct': discountPct,
    'description': description,
  });
}
