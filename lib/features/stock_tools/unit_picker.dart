import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import 'stock_tools_repository.dart';

/// Unit choice for a document line. Shows nothing when the item has no alternate units, so forms can
/// place it beside the quantity without clutter. [onChanged] gets the chosen unit name, or null for the base unit.
/// [purchase] picks the item's default purchase unit first, otherwise the default sale unit.
class LineUnitPicker extends ConsumerWidget {
  const LineUnitPicker({
    super.key,
    required this.itemId,
    required this.value,
    required this.onChanged,
    this.purchase = false,
    this.onRateScale,
  });

  final String itemId;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool purchase;

  /// Called with new factor / old factor when the unit changes, so the line's rate can follow (see [scaleRateText]).
  final ValueChanged<double>? onRateScale;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final units = ref.watch(itemUnitsProvider(itemId)).value;
    if (units == null || units.units.isEmpty) return const SizedBox.shrink();
    final selected = units.names.contains(value) ? value : units.baseUnit;
    return SizedBox(
      width: 110,
      child: DropdownButtonFormField<String>(
        initialValue: selected,
        isExpanded: true,
        decoration: const InputDecoration(labelText: 'Unit'),
        items: [for (final n in units.names) DropdownMenuItem(value: n, child: Text(n))],
        onChanged: (v) {
          final next = v == units.baseUnit ? null : v;
          final ratio = units.factorOf(next) / units.factorOf(value);
          onChanged(next);
          onRateScale?.call(ratio);
        },
      ),
    );
  }
}

/// The unit a new line starts in: the item's default for this side, if it is set.
String? defaultLineUnit(String baseUnit, String? purchaseDefault, String? saleDefault, {required bool purchase}) {
  final d = purchase ? purchaseDefault : saleDefault;
  return d == null || d.toLowerCase() == baseUnit.toLowerCase() ? null : d;
}

/// The item's default unit for a new line and the base units in it: (null, 1) for the base unit or when units cannot be read.
Future<(String?, double)> defaultUnitFor(WidgetRef ref, String itemId, {required bool purchase}) async {
  try {
    final u = await ref.read(itemUnitsProvider(itemId).future);
    final name = defaultLineUnit(u.baseUnit, u.defaultPurchaseUnit, u.defaultSaleUnit, purchase: purchase);
    return (name, u.factorOf(name));
  } catch (_) {
    return (null, 1.0);
  }
}

/// A rate typed for one unit, restated for another. Empty or unreadable text stays as it is.
String scaleRateText(String text, double ratio) {
  final v = parseNumber(text);
  if (v == null) return text;
  return formatPlain((v * ratio * 100).round() / 100);
}
