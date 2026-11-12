import 'package:flutter/material.dart';

import '../../core/business_profile.dart';
import '../../core/design_tokens.dart';

/// Frame for a chart: a plain title that says what it shows, an optional
/// one-line subtitle, an optional CSV export button, and an empty state.
class ChartCard extends StatelessWidget {
  const ChartCard({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.isEmpty = false,
    this.emptyText = 'No data for this period.',
    this.onExport,
    this.onTap,
    this.footer,
  });

  final String title;
  final String? subtitle;
  final Widget child;
  final bool isEmpty;
  final String emptyText;

  /// Shows a small download button that exports the chart's data as CSV.
  final VoidCallback? onExport;

  /// Opens the related list.
  final VoidCallback? onTap;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final body = Padding(
      padding: const EdgeInsets.all(Space.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.w(title),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        context.w(subtitle!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              if (onExport != null && !isEmpty)
                IconButton(
                  tooltip: 'Download as CSV',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.download_outlined, size: 20),
                  onPressed: onExport,
                ),
              if (onTap != null && !isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2, left: 4),
                  child: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: cs.onSurfaceVariant,
                  ),
                ),
            ],
          ),
          const SizedBox(height: Space.md),
          if (isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Space.xl),
              child: Center(
                child: Text(
                  emptyText,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            )
          else
            child,
          if (footer != null && !isEmpty) ...[
            const SizedBox(height: Space.sm),
            footer!,
          ],
        ],
      ),
    );
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? body : InkWell(onTap: onTap, child: body),
    );
  }
}

/// A row of colour keys. Used only when a chart has more than one series;
/// single-series charts need none.
class ChartLegend extends StatelessWidget {
  const ChartLegend({super.key, required this.items});
  final List<(String, Color)> items;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    return Wrap(
      spacing: Space.lg,
      runSpacing: Space.xs,
      children: [
        for (final (name, color) in items)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(name, style: style),
            ],
          ),
      ],
    );
  }
}
