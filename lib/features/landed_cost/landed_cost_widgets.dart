import 'package:flutter/material.dart';

import '../../core/money.dart';
import 'landed_cost_models.dart';

/// Allocation of the charges per line: a table from 720px, stacked rows below.
/// With [weightFields], the weight column is editable (weight basis).
class LcLinesView extends StatelessWidget {
  const LcLinesView({super.key, required this.lines, this.weightFields});

  final List<LcLine> lines;
  final Map<String, TextEditingController>? weightFields;

  Widget _weight(LcLine l) {
    final c = weightFields?[l.docLineId];
    if (c == null) return Text(formatQty(l.weight));
    return SizedBox(
      width: 110,
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const InputDecoration(labelText: 'Weight', isDense: true),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 720) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Document')),
                DataColumn(label: Text('Item')),
                DataColumn(label: Text('Qty'), numeric: true),
                DataColumn(label: Text('Value'), numeric: true),
                DataColumn(label: Text('Weight')),
                DataColumn(label: Text('Added cost'), numeric: true),
                DataColumn(label: Text('To stock'), numeric: true),
                DataColumn(label: Text('To cost of sales'), numeric: true),
                DataColumn(label: Text('Landed rate'), numeric: true),
              ],
              rows: [
                for (final l in lines)
                  DataRow(
                    cells: [
                      DataCell(Text(l.docNumber)),
                      DataCell(Text(l.itemName)),
                      DataCell(Text(formatQty(l.qty))),
                      DataCell(Text(formatMoney(l.baseValue))),
                      DataCell(_weight(l)),
                      DataCell(Text(formatMoney(l.allocated))),
                      DataCell(Text(formatMoney(l.toInventory))),
                      DataCell(Text(formatMoney(l.toCogs))),
                      DataCell(Text(formatMoney(l.landedUnitCost))),
                    ],
                  ),
              ],
            ),
          );
        }
        return Column(
          children: [
            for (final l in lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(l.itemName, style: theme.textTheme.titleSmall),
                      Text(
                        '${l.docNumber} · ${formatQty(l.qty)} units · '
                        '${formatMoney(l.baseValue)}',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (weightFields?[l.docLineId] != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: _weight(l),
                        ),
                      const SizedBox(height: 6),
                      _kv('Added cost', formatMoney(l.allocated)),
                      _kv('To stock', formatMoney(l.toInventory)),
                      _kv('To cost of sales', formatMoney(l.toCogs)),
                      _kv('Landed rate', formatMoney(l.landedUnitCost)),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _kv(String k, String v) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 1),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: Text(k)),
        const SizedBox(width: 8),
        Flexible(child: Text(v, textAlign: TextAlign.end)),
      ],
    ),
  );
}
