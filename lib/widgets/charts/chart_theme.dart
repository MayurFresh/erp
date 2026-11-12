import 'package:flutter/material.dart';

import '../../core/app_colors.dart';

/// Colours for charts, read from the theme so light and dark both work.
@immutable
class ChartPalette {
  const ChartPalette({
    required this.series,
    required this.grid,
    required this.label,
    required this.surface,
    required this.tooltipBg,
    required this.tooltipText,
    required this.good,
    required this.bad,
  });

  /// Categorical colours in a fixed order: teal, amber, indigo, rose, sky.
  final List<Color> series;
  final Color grid, label, surface, tooltipBg, tooltipText, good, bad;

  Color at(int i) => series[i % series.length];

  static ChartPalette of(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final c = context.colors;
    return ChartPalette(
      series: [for (final a in c.accents) a.fg],
      grid: c.hairline,
      label: cs.onSurfaceVariant,
      surface: cs.surface,
      tooltipBg: cs.inverseSurface,
      tooltipText: cs.onInverseSurface,
      good: c.success,
      bad: c.danger,
    );
  }
}

/// One named line or bar series. [values] lines up with the chart's labels.
class ChartSeries {
  const ChartSeries(this.name, this.values, {this.color});
  final String name;
  final List<double> values;
  final Color? color;
}
