import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/layout.dart';
import '../reports/report_period.dart';
import '../reports/report_widgets.dart';
import 'cash_flow_screen.dart' show CompareSwitch;
import 'finance_exports.dart';
import 'finance_models.dart';
import 'finance_repository.dart';

/// `/ratios`: each ratio with its formula, this period against last year.
class RatiosScreen extends ConsumerStatefulWidget {
  const RatiosScreen({super.key});

  @override
  ConsumerState<RatiosScreen> createState() => _RatiosState();
}

class _RatiosState extends ConsumerState<RatiosScreen> {
  DateRange _range = DateRange.fyToDate();
  bool _compare = true;

  @override
  Widget build(BuildContext context) {
    final key = (from: _range.apiFrom, to: _range.apiTo, compare: _compare);
    final value = ref.watch(ratiosProvider(key));
    return ReportPage(
      title: 'Ratio analysis',
      subtitle: 'Liquidity, leverage, profitability and efficiency',
      export: value.value == null ? null : ratiosExport(value.value!),
      controls: [
        PeriodButton(value: _range, onChanged: (r) => setState(() => _range = r)),
        CompareSwitch(value: _compare, onChanged: (v) => setState(() => _compare = v)),
      ],
      body: ReportBody<RatioReport>(
        value: value,
        onRetry: () => ref.invalidate(ratiosProvider(key)),
        builder: ratioBlocks,
      ),
    );
  }
}

/// Ratio cards grouped by kind; public for tests.
List<Widget> ratioBlocks(RatioReport r) {
  final groups = <String, List<Ratio>>{};
  for (final x in r.current.ratios) {
    groups.putIfAbsent(x.group, () => []).add(x);
  }
  return [
    for (final g in groups.entries) ...[
      ReportSectionTitle(ratioGroupLabels[g.key] ?? g.key),
      for (final ratio in g.value)
        _RatioCard(ratio: ratio, previous: r.previous?.byKey(ratio.key)),
    ],
  ];
}

class _RatioCard extends StatelessWidget {
  const _RatioCard({required this.ratio, this.previous});
  final Ratio ratio;
  final Ratio? previous;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: SectionCard(
        title: ratio.label,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 24,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.end,
              children: [
                Text(ratio.text, style: theme.textTheme.headlineSmall?.merge(tabularFigures)),
                if (previous != null)
                  Text('Last year ${previous!.text}', style: muted),
              ],
            ),
            const SizedBox(height: 4),
            Text(ratio.formula, style: muted),
          ],
        ),
      ),
    );
  }
}
