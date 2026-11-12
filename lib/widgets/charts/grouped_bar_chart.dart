import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import 'chart_card.dart';
import 'chart_format.dart';
import 'chart_theme.dart';

/// Side-by-side bars per label, one bar per series (e.g. cash in vs cash out).
class GroupedBarChart extends StatelessWidget {
  const GroupedBarChart({
    super.key,
    required this.labels,
    required this.series,
    this.height = 200,
    this.currency = true,
  });

  final List<String> labels;
  final List<ChartSeries> series;
  final double height;
  final bool currency;

  @override
  Widget build(BuildContext context) {
    final pal = ChartPalette.of(context);
    final style = Theme.of(
      context,
    ).textTheme.labelSmall?.copyWith(color: pal.label);
    var maxV = 0.0;
    for (final s in series) {
      for (final v in s.values) {
        maxV = math.max(maxV, v);
      }
    }
    final top = niceCeil(maxV);
    final colors = [
      for (var i = 0; i < series.length; i++) series[i].color ?? pal.at(i),
    ];
    return Semantics(
      label:
          'Bar chart. ${series.map((s) => s.name).join(', ')} for ${labels.length} periods.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ChartLegend(
            items: [
              for (var i = 0; i < series.length; i++)
                (series[i].name, colors[i]),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: height,
            child: LayoutBuilder(
              builder: (context, box) {
                final plot = math.max(60.0, box.maxWidth - 56);
                final group = plot / math.max(1, labels.length);
                final rod = math.max(
                  3.0,
                  math.min(
                    labels.length < 4 ? 32.0 : 14.0,
                    (group - 6) / series.length,
                  ),
                );
                final every = math.max(
                  1,
                  (labels.length / math.max(1, box.maxWidth / 46)).ceil(),
                );
                return BarChart(
                  BarChartData(
                    maxY: top,
                    minY: 0,
                    alignment: BarChartAlignment.spaceAround,
                    gridData: FlGridData(
                      drawVerticalLine: false,
                      horizontalInterval: top / 4,
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
                          interval: top / 4,
                          getTitlesWidget: (v, meta) => SideTitleWidget(
                            meta: meta,
                            child: Text(
                              formatCompact(v, currency: currency),
                              style: style,
                            ),
                          ),
                        ),
                      ),
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 22,
                          getTitlesWidget: (v, meta) {
                            final i = v.round();
                            if (i < 0 || i >= labels.length || i % every != 0) {
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
                    barTouchData: BarTouchData(
                      touchTooltipData: BarTouchTooltipData(
                        getTooltipColor: (_) => pal.tooltipBg,
                        fitInsideHorizontally: true,
                        fitInsideVertically: true,
                        getTooltipItem: (group, gi, r, ri) => BarTooltipItem(
                          '${labels[group.x]}\n${series[ri].name}: ${formatCompact(r.toY, currency: currency, maxDecimals: 2)}',
                          TextStyle(
                            color: pal.tooltipText,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    barGroups: [
                      for (var i = 0; i < labels.length; i++)
                        BarChartGroupData(
                          x: i,
                          barsSpace: 2,
                          barRods: [
                            for (var s = 0; s < series.length; s++)
                              BarChartRodData(
                                toY: i < series[s].values.length
                                    ? math.max(0, series[s].values[i])
                                    : 0,
                                color: colors[s],
                                width: rod,
                                borderRadius: const BorderRadius.vertical(
                                  top: Radius.circular(2),
                                ),
                              ),
                          ],
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
