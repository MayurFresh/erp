/// The unit and quantity a user typed on a document line when it was not the item's own unit.
/// Stock and tax stay in the base unit; printed documents read as entered.
library;

import 'json.dart';
import 'money.dart';

class EnteredUnit {
  const EnteredUnit({required this.unit, required this.qty, this.rate});

  final String unit;
  final double qty;

  /// Rate per [unit]; null when the server did not send one.
  final double? rate;

  /// Null unless the line was entered in another unit (`enteredUnit`, `enteredQty`, `enteredRate`).
  static EnteredUnit? fromJson(Json json) {
    final unit = asStringOrNull(json['enteredUnit']);
    final qty = asDoubleOrNull(json['enteredQty']);
    if (unit == null || unit.isEmpty || qty == null || qty <= 0) return null;
    return EnteredUnit(
      unit: unit,
      qty: qty,
      rate: asDoubleOrNull(json['enteredRate']),
    );
  }
}

/// "12 nos", or "2 box" when the line was entered in boxes.
String lineQtyText(double qty, String unit, EnteredUnit? entered) =>
    entered == null
    ? '${formatQty(qty)} $unit'
    : '${formatQty(entered.qty)} ${entered.unit}';

/// The rate in the unit the quantity is shown in.
String lineRateText(double rate, EnteredUnit? entered) =>
    formatAmount(entered?.rate ?? rate);
