import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_theme.dart';

/// Tiny trend line with no axes. Decorative: the figure beside it carries the meaning.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    this.color,
    this.height = 28,
    this.width,
  });

  final List<double> values;
  final Color? color;
  final double height;
  final double? width;

  @override
  Widget build(BuildContext context) {
    if (values.length < 2) return SizedBox(height: height, width: width);
    final c = color ?? ChartPalette.of(context).at(0);
    var lo = values.first, hi = values.first;
    for (final v in values) {
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    final pad = (hi - lo) == 0 ? 1.0 : (hi - lo) * 0.1;
    return ExcludeSemantics(
      child: SizedBox(
        height: height,
        width: width,
        child: LineChart(
          LineChartData(
            minY: lo - pad,
            maxY: hi + pad,
            gridData: const FlGridData(show: false),
            titlesData: const FlTitlesData(show: false),
            borderData: FlBorderData(show: false),
            lineTouchData: const LineTouchData(enabled: false),
            lineBarsData: [
              LineChartBarData(
                spots: [
                  for (var i = 0; i < values.length; i++)
                    FlSpot(i.toDouble(), values[i]),
                ],
                color: c,
                barWidth: 1.8,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: c.withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
