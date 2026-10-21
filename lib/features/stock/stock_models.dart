import '../../core/json.dart';

class StockBalance {
  const StockBalance({
    required this.itemId,
    required this.itemName,
    required this.unit,
    required this.locationId,
    required this.locationName,
    required this.qty,
    this.sku,
    this.reorderLevel = 0,
    this.value,
  });

  factory StockBalance.fromJson(Json json) => StockBalance(
    itemId: asString(json['itemId']),
    itemName: asString(json['itemName']),
    sku: asStringOrNull(json['sku']),
    unit: asString(json['unit']),
    locationId: asString(json['locationId']),
    locationName: asString(json['locationName']),
    qty: asDouble(json['qty']),
    reorderLevel: asDouble(json['reorderLevel']),
    value: asDoubleOrNull(json['value']),
  );

  final String itemId;
  final String itemName;
  final String? sku;
  final String unit;
  final String locationId;
  final String locationName;
  final double qty;
  final double reorderLevel;

  /// Only with `items.view_cost`.
  final double? value;

  bool get isLow => qty <= reorderLevel;
}

class StockMove {
  const StockMove({
    required this.id,
    required this.itemId,
    required this.locationId,
    required this.qty,
    required this.refType,
    this.rate,
    this.costRate,
    this.value,
    this.refId,
    this.note,
    this.createdAt,
  });

  factory StockMove.fromJson(Json json) => StockMove(
    id: asString(json['id']),
    itemId: asString(json['itemId']),
    locationId: asString(json['locationId']),
    qty: asDouble(json['qty']),
    rate: asDoubleOrNull(json['rate']),
    costRate: asDoubleOrNull(json['costRate']),
    value: asDoubleOrNull(json['value']),
    refType: asString(json['refType']),
    refId: asStringOrNull(json['refId']),
    note: asStringOrNull(json['note']),
    createdAt: asDateTimeOrNull(json['createdAt']),
  );

  final String id;
  final String itemId;
  final String locationId;

  /// Positive = in, negative = out.
  final double qty;
  final double? rate;

  /// Weighted-average cost used for the move.
  final double? costRate;

  /// Signed stock value; only with `items.view_cost`.
  final double? value;

  /// `opening`, `adjustment`, `invoice`, `purchase`, `credit_note`,
  /// `transfer_out`, `transfer_in` and their `_cancel` variants.
  final String refType;
  final String? refId;
  final String? note;
  final DateTime? createdAt;

  String get refLabel => stockRefLabel(refType);

  /// The app route of the source document, if it has one.
  String? get refRoute {
    final id = refId;
    if (id == null) return null;
    return switch (refType) {
      'invoice' || 'invoice_cancel' => '/invoices/$id',
      'purchase' || 'purchase_cancel' => '/purchases/$id',
      'credit_note' || 'credit_note_cancel' => '/credit-notes/$id',
      'transfer_out' || 'transfer_in' || 'transfer_cancel' => '/transfers/$id',
      _ => null,
    };
  }
}

String stockRefLabel(String refType) => switch (refType) {
  'opening' => 'Opening stock',
  'adjustment' => 'Adjustment',
  'invoice' => 'Sale (invoice)',
  'invoice_cancel' => 'Invoice cancelled',
  'purchase' => 'Purchase',
  'purchase_cancel' => 'Purchase cancelled',
  'credit_note' => 'Sales return',
  'credit_note_cancel' => 'Sales return cancelled',
  'transfer_out' => 'Transfer out',
  'transfer_in' => 'Transfer in',
  'transfer_cancel' => 'Transfer cancelled',
  _ => refType,
};

class StockAdjustment {
  const StockAdjustment({
    required this.locationId,
    required this.itemId,
    required this.qty,
    this.rate,
    this.note,
    this.isOpening = false,
  });

  final String locationId;
  final String itemId;
  final double qty;
  final double? rate;
  final String? note;

  /// Opening stock is credited to Opening Balances instead of Other Income.
  final bool isOpening;

  Json toJson() => withoutNulls({
    'locationId': locationId,
    'itemId': itemId,
    'qty': qty,
    'rate': rate,
    'note': note,
    if (isOpening) 'isOpening': true,
  });
}
