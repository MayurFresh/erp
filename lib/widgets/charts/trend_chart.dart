import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_card.dart';
import 'chart_format.dart';
import 'chart_theme.dart';

/// Line or area chart over a shared x axis (usually months).
/// With more than one series a legend is drawn above the plot.
class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.labels,
    required this.series,
    this.area = true,
    this.height = 200,
    this.currency = true,
    this.tooltipLabels,
  });

  final List<String> labels;
  final List<ChartSeries> series;
  final bool area;
  final double height;
  final bool currency;

  /// Longer x labels for the tooltip (e.g. `April 2026`).
  final List<String>? tooltipLabels;

  @override
  Widget build(BuildContext context) {
    final pal = ChartPalette.of(context);
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: pal.label);
    var maxV = 0.0, minV = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        maxV = math.max(maxV, v);
        minV = math.min(minV, v);
      }
    }
    final top = niceCeil(maxV);
    final bottom = minV < 0 ? -niceCeil(-minV) : 0.0;
    final colors = [
      for (var i = 0; i < series.length; i++) series[i].color ?? pal.at(i),
    ];
    return Semantics(
      label:
          'Line chart. ${series.map((s) => s.name).join(', ')} over ${labels.length} periods.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (series.length > 1) ...[
            ChartLegend(
              items: [
                for (var i = 0; i < series.length; i++)
                  (series[i].name, colors[i]),
              ],
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            height: height,
            child: LayoutBuilder(
              builder: (context, box) {
                final every = math.max(
                  1,
                  (labels.length / math.max(1, box.maxWidth / 46)).ceil(),
                );
                return LineChart(
                  LineChartData(
                    minY: bottom,
                    maxY: top,
                    minX: 0,
                    maxX: math.max(1, labels.length - 1).toDouble(),
                    gridData: FlGridData(
                      drawVerticalLine: false,
                      horizontalInterval: (top - bottom) / 4,
                      getDrawingHorizontalLine: (_) =>
                          FlLine(color: pal.grid, strokeWidth: 1),
                    ),
                    borderData: FlBorderData(show: false),
                    titlesData: FlTitlesData(
                      topTitles: const AxisTitles(),
                      rightTitles: const AxisTitles(),
                      leftTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 56,
                          interval: (top - bottom) / 4,
                          getTitlesWidget: (v, meta) => SideTitleWidget(
                            meta: meta,
                            child: Text(
                              formatCompact(
                                v,
                                currency: currency,
                                maxDecimals: 1,
                              ),
                              style: style,
                            ),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          interval: 1,
                          getTitlesWidget: (v, meta) {
                            final i = v.round();
                            if (v != i ||
                                i < 0 ||
                                i >= labels.length ||
                                i % every != 0) {
                              return const SizedBox.shrink();
                            }
                            return SideTitleWidget(
                              meta: meta,
                              child: Text(labels[i], style: style),
                            );
                          },
                        ),
                      ),
                    ),
                    lineTouchData: LineTouchData(
                      touchTooltipData: LineTouchTooltipData(
                        getTooltipColor: (_) => pal.tooltipBg,
                        fitInsideHorizontally: true,
                        fitInsideVertically: true,
                        getTooltipItems: (spots) => [
                          for (final s in spots)
                            LineTooltipItem(
                              '${s.barIndex == 0 ? '${(tooltipLabels ?? labels)[s.x.round()]}\n' : ''}'
                              '${series[s.barIndex].name}: ${formatCompact(s.y, currency: currency, maxDecimals: 2)}',
                              TextStyle(
                                color: pal.tooltipText,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                        ],
                      ),
                    ),
                    lineBarsData: [
                      for (var i = 0; i < series.length; i++)
                        LineChartBarData(
                          spots: [
                            for (var j = 0; j < series[i].values.length; j++)
                              FlSpot(j.toDouble(), series[i].values[j]),
                          ],
                          isCurved: false,
                          color: colors[i],
                          barWidth: 2.5,
                          dotData: FlDotData(show: labels.length <= 14),
                          belowBarData: BarAreaData(
                            show: area && i == 0,
                            color: colors[i].withValues(alpha: 0.14),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
