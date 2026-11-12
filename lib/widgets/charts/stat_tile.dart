import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import 'chart_format.dart';
import 'chart_theme.dart';
import 'sparkline.dart';

/// Headline figure with change against the previous period and a sparkline.
/// [deltaPercent] null hides the change line (nothing to compare against).
/// [upIsGood] false for costs, where a rise is bad news.
class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.deltaPercent,
    this.upIsGood = true,
    this.spark,
    this.hint,
    this.onTap,
    this.sparkColor,
  });

  final String label;

  /// Already formatted, usually via [formatCompact].
  final String value;
  final double? deltaPercent;
  final bool upIsGood;
  final List<double>? spark;
  final String? hint;
  final VoidCallback? onTap;
  final Color? sparkColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pal = ChartPalette.of(context);
    final d = deltaPercent;
    Widget? delta;
    if (d != null) {
      final flat = d.abs() < 0.05;
      final good = flat ? null : (d > 0) == upIsGood;
      final color = good == null ? pal.label : (good ? pal.good : pal.bad);
      delta = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            flat
                ? Icons.remove
                : (d > 0 ? Icons.arrow_upward : Icons.arrow_downward),
            size: 13,
            color: color,
          ),
          const SizedBox(width: 2),
          Text(
            formatDeltaPercent(d),
            style: theme.textTheme.labelMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              'vs previous',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: pal.label),
            ),
          ),
        ],
      );
    }
    final body = Padding(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelMedium?.copyWith(color: pal.label),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          if (delta != null) ...[const SizedBox(height: 2), delta],
          if (hint != null)
            Text(
              hint!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(color: pal.label),
            ),
          if (spark != null && spark!.length > 1) ...[
            const SizedBox(height: 6),
            Sparkline(values: spark!, color: sparkColor),
          ],
        ],
      ),
    );
    return Semantics(
      label:
          '$label $value${d == null ? '' : ', ${formatDeltaPercent(d)} against the previous period'}',
      button: onTap != null,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: onTap == null ? body : InkWell(onTap: onTap, child: body),
      ),
    );
  }
}
