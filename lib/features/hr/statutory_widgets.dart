import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import 'hr_models.dart';
import 'hr_repository.dart';

/// Previous and next buttons around a label, 48 px targets.
class StepperBar extends StatelessWidget {
  const StepperBar({super.key, required this.label, required this.onPrev, required this.onNext});

  final String label;
  final VoidCallback onPrev, onNext;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      IconButton(tooltip: 'Previous', icon: const Icon(Icons.chevron_left), onPressed: onPrev),
      Expanded(
        child: Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleSmall),
      ),
      IconButton(tooltip: 'Next', icon: const Icon(Icons.chevron_right), onPressed: onNext),
    ],
  );
}

String shiftMonth(String ym, int by) {
  var y = int.parse(ym.substring(0, 4)), m = int.parse(ym.substring(5, 7)) + by;
  while (m > 12) {
    m -= 12;
    y++;
  }
  while (m < 1) {
    m += 12;
    y--;
  }
  return '$y-${m.toString().padLeft(2, '0')}';
}

String currentMonth() {
  final n = DateTime.now();
  return '${n.year}-${n.month.toString().padLeft(2, '0')}';
}

/// April-March year start for today.
int currentFy() {
  final n = DateTime.now();
  return n.month >= 4 ? n.year : n.year - 1;
}

String fyLabel(int fy) => '$fy-${((fy + 1) % 100).toString().padLeft(2, '0')}';

/// Picks a payroll run that can still take adjustments (draft or computed).
class OpenRunPicker extends ConsumerWidget {
  const OpenRunPicker({super.key, required this.value, required this.onChanged});

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final runs = ref.watch(runsProvider).value ?? const <PayrollRun>[];
    final open = runs.where((r) => r.status == 'draft' || r.status == 'computed').toList();
    if (open.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: Space.sm),
        child: Text('Create a payroll run first. The amounts are added to a draft or computed run.'),
      );
    }
    return DropdownButtonFormField<String>(
      initialValue: open.any((r) => r.id == value) ? value : null,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Add to payroll run'),
      items: [
        for (final r in open) DropdownMenuItem(value: r.id, child: Text('${r.number}, ${monthLabel(r.month)} (${r.status})')),
      ],
      onChanged: onChanged,
    );
  }
}

/// Label on the left, value on the right; both wrap, so long text does not overflow at 320 px.
class StatRow extends StatelessWidget {
  const StatRow(this.label, this.amount, {super.key, this.bold = false, this.text});

  final String label;
  final num? amount;
  final String? text;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(
      fontWeight: bold ? FontWeight.w700 : null,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 3, child: Text(label, style: style)),
          const SizedBox(width: 8),
          Flexible(flex: 2, child: Text(text ?? formatMoney(amount), style: style, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}
