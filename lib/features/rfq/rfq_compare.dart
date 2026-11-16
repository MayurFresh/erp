import 'package:flutter/material.dart';

import '../../core/money.dart';
import 'rfq_models.dart';

/// Comparison of vendor quotes line by line. A table from 720px, stacked
/// rows below. Tapping a quote picks that vendor for the line.
class RfqComparison extends StatelessWidget {
  const RfqComparison({
    super.key,
    required this.rfq,
    required this.canChoose,
    required this.onChoose,
  });

  final Rfq rfq;
  final bool canChoose;
  final void Function(RfqLine line, String? partyId) onChoose;

  String _badges(RfqQuote q) => [
    if (q.isLowest) 'Lowest',
    if (q.isFastest) 'Fastest',
  ].join(' · ');

  Widget _cell(BuildContext context, RfqLine l, String partyId) {
    final q = l.quoteBy(partyId);
    if (q == null) return const Text('No quote');
    final chosen = l.chosenPartyId == partyId;
    final theme = Theme.of(context);
    return InkWell(
      onTap: canChoose ? () => onChoose(l, chosen ? null : partyId) : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Wrap(
              spacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                if (chosen) const Icon(Icons.check_circle, size: 16),
                Text(
                  formatMoney(q.total),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            Text(
              [
                if (q.leadDays != null) '${q.leadDays} days',
                if (_badges(q).isNotEmpty) _badges(q),
                if (chosen) 'Chosen',
              ].join(' · '),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (rfq.lines.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, box) {
        if (box.maxWidth >= 720) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              dataRowMinHeight: 56,
              dataRowMaxHeight: 72,
              columns: [
                const DataColumn(label: Text('Item')),
                const DataColumn(label: Text('Qty'), numeric: true),
                for (final v in rfq.vendors)
                  DataColumn(label: Text(v.partyName)),
              ],
              rows: [
                for (final l in rfq.lines)
                  DataRow(
                    cells: [
                      DataCell(Text(l.itemName)),
                      DataCell(Text('${formatQty(l.qty)} ${l.unit}')),
                      for (final v in rfq.vendors)
                        DataCell(_cell(context, l, v.partyId)),
                    ],
                  ),
                DataRow(
                  cells: [
                    const DataCell(
                      Text('Vendor total', style: TextStyle(fontWeight: FontWeight.w600)),
                    ),
                    const DataCell(Text('')),
                    for (final v in rfq.vendors)
                      DataCell(Text(formatMoney(v.total))),
                  ],
                ),
              ],
            ),
          );
        }
        return Column(
          children: [
            for (final l in rfq.lines)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).dividerColor),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        '${l.itemName}, ${formatQty(l.qty)} ${l.unit}',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      for (final v in rfq.vendors)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 2),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                flex: 2,
                                child: Text(v.partyName),
                              ),
                              Expanded(
                                flex: 3,
                                child: _cell(context, l, v.partyId),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
