import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/charts/charts.dart';
import '../../widgets/kpi_tile.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import 'crm_models.dart';
import 'crm_repository.dart';
import 'crm_widgets.dart';

String _pct(double? v) => v == null ? 'No data' : '${v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1)}%';

String _num(double v) => v.toStringAsFixed(v == v.roundToDouble() ? 0 : 1);

/// `/crm/numbers`: win rate, deal size, speed and where deals are lost.
class CrmNumbersScreen extends ConsumerStatefulWidget {
  const CrmNumbersScreen({super.key});

  @override
  ConsumerState<CrmNumbersScreen> createState() => _CrmNumbersScreenState();
}

class _CrmNumbersScreenState extends ConsumerState<CrmNumbersScreen> {
  int _range = 0;

  String get _key {
    final now = DateTime.now();
    final (from, to) = switch (_range) {
      0 => (DateTime(now.year, now.month, 1), now),
      1 => (DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 0)),
      _ => (now.subtract(const Duration(days: 90)), now),
    };
    return '${apiDate(from)}|${apiDate(to)}';
  }

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    final key = _key;
    return CrmGate(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Numbers',
            subtitle: 'How the sales work is going',
            actions: [CrmOwnerFilter()],
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.sm),
            child: Wrap(
              spacing: Space.sm,
              children: [
                for (final (i, l) in const ['This month', 'Last month', 'Last 90 days'].indexed)
                  ChoiceChip(
                    label: Text(l),
                    selected: _range == i,
                    onSelected: (_) => setState(() => _range = i),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(crmStatsProvider(key)),
              onRetry: () => ref.invalidate(crmStatsProvider(key)),
              data: (s) => _Body(stats: s),
            ),
          ),
        ],
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.stats});

  final CrmStats stats;

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final gutter = pageGutter(context);
    final tiles = <Widget>[
      KpiTile(
        label: 'Win rate',
        value: _pct(s.winRate),
        hint: s.winRate == null ? 'Nothing closed yet' : '${s.wonCount} won, ${s.lostCount} lost',
      ),
      KpiTile(
        label: 'Average deal size',
        value: s.wonCount == 0 ? 'No data' : crmMoney(s.avgDealSize),
        hint: '${s.wonCount} won ${s.wonCount == 1 ? 'deal' : 'deals'}',
      ),
      KpiTile(
        label: 'Average days to close',
        value: s.avgCycleDays == null ? 'No data' : _num(s.avgCycleDays!),
        hint: 'From created to won',
      ),
      KpiTile(
        label: 'Response time',
        value: s.avgResponseHours == null ? 'No data' : '${_num(s.avgResponseHours!)} h',
        hint: 'Enquiry to first contact',
        tone: (s.avgResponseHours ?? 0) > 24 ? StatusTone.warning : StatusTone.neutral,
      ),
      KpiTile(
        label: 'Target achievement',
        value: s.target > 0 ? _pct(s.achievementPct) : 'No target',
        hint: s.target > 0
            ? '${crmMoney(s.achievement)} of ${crmMoney(s.target)}'
            : 'Set one in settings',
      ),
      KpiTile(
        label: 'Coverage',
        value: s.coverage == null ? 'No data' : '${_num(s.coverage!)}x',
        hint: s.gap == 0 && s.target > 0
            ? 'Target met'
            : 'Open deals against the ${crmMoney(s.gap)} gap',
        tone: s.coverage != null && s.coverage! < 3 ? StatusTone.warning : StatusTone.neutral,
      ),
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: ListView(
          padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xxl),
          children: [
            LayoutBuilder(
              builder: (context, c) {
                final cols = c.maxWidth < 380 ? 1 : c.maxWidth < 700 ? 2 : 3;
                final w = (c.maxWidth - Space.md * (cols - 1)) / cols;
                return Wrap(
                  spacing: Space.md,
                  runSpacing: Space.md,
                  children: [for (final t in tiles) SizedBox(width: w, child: t)],
                );
              },
            ),
            const SizedBox(height: Space.md),
            ChartCard(
              title: 'Stage conversion',
              subtitle: 'Deals that entered a stage and moved on',
              isEmpty: s.stageConversion.isEmpty,
              child: _Rates(
                rows: [
                  for (final r in s.stageConversion)
                    (r.name, r.rate, '${r.advanced} of ${r.entered}'),
                ],
              ),
            ),
            const SizedBox(height: Space.md),
            ChartCard(
              title: 'Leads by source',
              subtitle: 'Share that became customers',
              isEmpty: s.bySource.isEmpty,
              child: _Rates(
                rows: [
                  for (final r in s.bySource)
                    (crmSourceLabel(r.source), r.rate, '${r.converted} of ${r.leads}'),
                ],
              ),
            ),
            const SizedBox(height: Space.md),
            ChartCard(
              title: 'Why deals were lost',
              isEmpty: s.lostReasons.isEmpty,
              child: RankedBarChart(
                currency: false,
                maxRows: 8,
                bars: [for (final r in s.lostReasons) RankedBar(r.$1, r.$2.toDouble())],
              ),
            ),
            if (s.byOwner != null) ...[
              const SizedBox(height: Space.md),
              ChartCard(
                title: 'By salesperson',
                subtitle: 'Won value',
                isEmpty: s.byOwner!.isEmpty,
                child: RankedBarChart(
                  maxRows: 10,
                  bars: [
                    for (final o in s.byOwner!)
                      RankedBar(
                        o.name,
                        o.wonValue,
                        caption: '${o.wonCount} won',
                      ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Rows of name, percent and a bar, in the order given.
class _Rates extends StatelessWidget {
  const _Rates({required this.rows});

  final List<(String, double, String)> rows;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        for (final (name, rate, note) in rows)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(name, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
                    ),
                    Text(
                      '${rate.round()}%',
                      style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(width: 6),
                    Text(note, style: theme.textTheme.labelSmall),
                  ],
                ),
                const SizedBox(height: 3),
                ClipRRect(
                  borderRadius: Radii.smallAll,
                  child: LinearProgressIndicator(
                    value: (rate / 100).clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: context.colors.hairline,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
