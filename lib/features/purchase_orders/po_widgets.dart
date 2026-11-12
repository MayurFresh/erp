import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../widgets/status_chip.dart';
import 'po_models.dart';

/// Status chip for a purchase order.
class PoStatusChip extends StatelessWidget {
  const PoStatusChip(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) => StatusChip(
    status,
    label: poStatusLabel(status),
    tone: status == 'pending_approval' ? StatusTone.warning : null,
  );
}

/// "Received 6 of 10" with a thin bar.
class QtyProgress extends StatelessWidget {
  const QtyProgress({
    super.key,
    required this.label,
    required this.done,
    required this.total,
  });

  final String label;
  final double done;
  final double total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fraction = total <= 0 ? 0.0 : (done / total).clamp(0.0, 1.0);
    return Semantics(
      label: '$label ${formatQty(done)} of ${formatQty(total)}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$label ${formatQty(done)} of ${formatQty(total)}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(value: fraction, minHeight: 4),
        ],
      ),
    );
  }
}

/// Per line received and billed quantities of a purchase order.
class PoLinesProgress extends StatelessWidget {
  const PoLinesProgress({super.key, required this.lines});

  final List<PoLine> lines;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) return const Text('No lines.');
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final (i, l) in lines.indexed) ...[
          if (i > 0) const Divider(height: 24),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(l.itemName, style: theme.textTheme.titleSmall),
                        Text(
                          '${formatQty(l.qty)} ${l.unit} at ${formatMoney(l.rate)}'
                          '${l.discountPct > 0 ? ', ${formatPercent(l.discountPct)} off' : ''}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    formatMoney(l.lineTotal),
                    style: theme.textTheme.titleSmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 24,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: 200,
                    child: QtyProgress(
                      label: 'Received',
                      done: l.receivedQty,
                      total: l.qty - l.cancelledQty,
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: QtyProgress(
                      label: 'Billed',
                      done: l.billedQty,
                      total: l.qty - l.cancelledQty,
                    ),
                  ),
                  if (l.rejectedQty > 0)
                    Text(
                      'Rejected ${formatQty(l.rejectedQty)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  if (l.cancelledQty > 0)
                    Text(
                      'Cancelled ${formatQty(l.cancelledQty)}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ],
          ),
        ],
      ],
    );
  }
}
