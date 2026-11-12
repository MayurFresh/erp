import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import 'chart_format.dart';
import 'chart_theme.dart';

class DonutSlice {
  const DonutSlice(this.label, this.value, {this.color});
  final String label;
  final double value;
  final Color? color;
}

/// Share of a total. Every slice is labelled directly in a list beside (or
/// under, when narrow) the ring with its value and percent; no colour-only key.
class DonutChart extends StatefulWidget {
  const DonutChart({
    super.key,
    required this.slices,
    this.centerLabel,
    this.currency = true,
    this.size = 150,
    this.onSliceTap,
  });

  final List<DonutSlice> slices;

  /// Small caption inside the ring, e.g. `Total`. The total value is added below it.
  final String? centerLabel;
  final bool currency;
  final double size;
  final void Function(int index)? onSliceTap;

  @override
  State<DonutChart> createState() => _DonutChartState();
}

class _DonutChartState extends State<DonutChart> {
  int? _hover;

  @override
  Widget build(BuildContext context) {
    final pal = ChartPalette.of(context);
    final theme = Theme.of(context);
    final slices = widget.slices.where((s) => s.value > 0).toList();
    final total = slices.fold<double>(0, (a, s) => a + s.value);
    Color colorOf(int i) => slices[i].color ?? pal.at(i);
    final ring = SizedBox(
      width: widget.size,
      height: widget.size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: widget.size * 0.32,
              startDegreeOffset: -90,
              pieTouchData: PieTouchData(
                touchCallback: (event, resp) {
                  final i = resp?.touchedSection?.touchedSectionIndex;
                  setState(
                    () => _hover =
                        (event.isInterestedForInteractions &&
                            i != null &&
                            i >= 0)
                        ? i
                        : null,
                  );
                  if (event is FlTapUpEvent && i != null && i >= 0) {
                    widget.onSliceTap?.call(i);
                  }
                },
              ),
              sections: [
                for (var i = 0; i < slices.length; i++)
                  PieChartSectionData(
                    value: slices[i].value,
                    color: colorOf(i),
                    showTitle: false,
                    radius: _hover == i
                        ? widget.size * 0.22
                        : widget.size * 0.18,
                  ),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.centerLabel != null)
                Text(
                  widget.centerLabel!,
                  style: theme.textTheme.labelSmall?.copyWith(color: pal.label),
                ),
              Text(
                formatCompact(
                  _hover == null ? total : slices[_hover!].value,
                  currency: widget.currency,
                ),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    final list = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < slices.length; i++)
          InkWell(
            onTap: widget.onSliceTap == null
                ? null
                : () => widget.onSliceTap!(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: colorOf(i),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      slices[i].label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${formatCompact(slices[i].value, currency: widget.currency)}  ${(slices[i].value / total * 100).round()}%',
                    style: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
    return Semantics(
      label: 'Donut chart of ${slices.length} parts.',
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth < 330) {
            return Column(
              children: [
                ring,
                const SizedBox(height: Space.md),
                list,
              ],
            );
          }
          return Row(
            children: [
              ring,
              const SizedBox(width: Space.lg),
              Expanded(child: list),
            ],
          );
        },
      ),
    );
  }
}
