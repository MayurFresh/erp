import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../core/money.dart';
import '../items/item_picker.dart';
import 'pricing_models.dart';

/// An editable item rate: item, "from quantity" and rate.
class RowDraft {
  RowDraft({
    required this.itemId,
    required this.itemName,
    double minQty = 1,
    double? rate,
  }) : minQty = TextEditingController(text: formatPlain(minQty)),
       rate = TextEditingController(text: formatPlain(rate));

  factory RowDraft.from(PriceRow r) => RowDraft(
    itemId: r.itemId,
    itemName: r.itemName,
    minQty: r.minQty,
    rate: r.rate,
  );

  final String itemId;
  final String itemName;
  final TextEditingController minQty;
  final TextEditingController rate;
  final Key key = UniqueKey();

  PriceRow? toRow() {
    final q = parseNumber(minQty.text);
    final r = parseNumber(rate.text);
    if (q == null || q <= 0 || r == null || r < 0) return null;
    return PriceRow(itemId: itemId, itemName: itemName, rate: r, minQty: q);
  }

  void dispose() {
    minQty.dispose();
    rate.dispose();
  }
}

/// Rows of item rates with quantity slabs: "from quantity X the rate is Y".
/// The same item can appear on several rows with different quantities.
class PriceRowsEditor extends ConsumerWidget {
  const PriceRowsEditor({
    super.key,
    required this.rows,
    required this.onChanged,
    this.emptyText = 'No item prices yet.',
  });

  final List<RowDraft> rows;
  final VoidCallback onChanged;
  final String emptyText;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    Widget num(TextEditingController c, String label, int decimals) =>
        TextFormField(
          controller: c,
          keyboardType: decimalKeyboard,
          inputFormatters: <TextInputFormatter>[decimalInput(decimals: decimals)],
          decoration: InputDecoration(labelText: label),
          validator: (v) {
            final n = parseNumber(v ?? '');
            return n == null || n < 0 || (label.startsWith('From') && n <= 0)
                ? 'Enter a number'
                : null;
          },
          onChanged: (_) => onChanged(),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              emptyText,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        for (final r in rows)
          Padding(
            key: r.key,
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(r.itemName, style: theme.textTheme.titleSmall),
                    ),
                    IconButton(
                      tooltip: 'Remove price',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        rows.remove(r);
                        r.dispose();
                        onChanged();
                      },
                    ),
                  ],
                ),
                FormRow(
                  breakpoint: 420,
                  children: [
                    num(r.minQty, 'From quantity', 3),
                    num(r.rate, 'Rate', 2),
                  ],
                ),
                const Divider(height: 1),
              ],
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: () async {
              final item = await pickItem(context, ref);
              if (item == null) return;
              rows.add(RowDraft(itemId: item.id, itemName: item.name, rate: item.salePrice));
              onChanged();
            },
            icon: const Icon(Icons.add),
            label: const Text('Add item price'),
          ),
        ),
      ],
    );
  }
}
