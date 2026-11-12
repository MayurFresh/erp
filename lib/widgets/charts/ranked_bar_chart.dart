import 'package:flutter/material.dart';

import 'chart_format.dart';
import 'chart_theme.dart';

class RankedBar {
  const RankedBar(this.label, this.value, {this.caption, this.id});
  final String label;
  final double value;

  /// Small grey text after the value, e.g. `31%` or `12 invoices`.
  final String? caption;
  final String? id;
}

/// Horizontal bars sorted by size, each with its name above and its value at
/// the end. Plain widgets, so labels never collide and 320 px is fine.
class RankedBarChart extends StatelessWidget {
  const RankedBarChart({
    super.key,
    required this.bars,
    this.maxRows = 5,
    this.currency = true,
    this.color,
    this.onTap,
  });

  final List<RankedBar> bars;
  final int maxRows;
  final bool currency;
  final Color? color;
  final void Function(RankedBar bar)? onTap;

  @override
  Widget build(BuildContext context) {
    final pal = ChartPalette.of(context);
    final theme = Theme.of(context);
    final rows = ([
      ...bars,
    ]..sort((a, b) => b.value.compareTo(a.value))).take(maxRows).toList();
    final maxV = rows.isEmpty
        ? 1.0
        : rows.first.value <= 0
        ? 1.0
        : rows.first.value;
    final fill = color ?? pal.at(0);
    return Semantics(
      label: 'Ranked bars, ${rows.length} rows.',
      child: Column(
        children: [
          for (final r in rows)
            InkWell(
              onTap: onTap == null ? null : () => onTap!(r),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            r.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          formatCompact(r.value, currency: currency),
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (r.caption != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            r.caption!,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: pal.label,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    LayoutBuilder(
                      builder: (context, box) => Stack(
                        children: [
                          Container(
                            height: 8,
                            width: box.maxWidth,
                            decoration: BoxDecoration(
                              color: pal.grid,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          Container(
                            height: 8,
                            width: (box.maxWidth * (r.value / maxV)).clamp(
                              2.0,
                              box.maxWidth,
                            ),
                            decoration: BoxDecoration(
                              color: fill,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
