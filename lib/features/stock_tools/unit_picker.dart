import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  });

  final String itemId;
  final String? value;
  final ValueChanged<String?> onChanged;
  final bool purchase;

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
        onChanged: (v) => onChanged(v == units.baseUnit ? null : v),
      ),
    );
  }
}

/// The unit a new line starts in: the item's default for this side, if it is set.
String? defaultLineUnit(String baseUnit, String? purchaseDefault, String? saleDefault, {required bool purchase}) {
  final d = purchase ? purchaseDefault : saleDefault;
  return d == null || d.toLowerCase() == baseUnit.toLowerCase() ? null : d;
}
