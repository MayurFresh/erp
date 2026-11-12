import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../widgets/charts/chart_card.dart';
import '../../widgets/charts/chart_format.dart';
import '../../widgets/charts/chart_theme.dart';
import '../../widgets/charts/donut_chart.dart';
import '../../widgets/charts/ranked_bar_chart.dart';
import '../../widgets/charts/stat_tile.dart';
import '../../widgets/charts/trend_chart.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'super_models.dart';
import 'super_repository.dart';
import 'super_widgets.dart';

/// `/platform/overview`: how many accounts exist and how they are spread.
class SuperOverviewScreen extends ConsumerWidget {
  const SuperOverviewScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(superOverviewProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Platform overview',
          subtitle: 'Every account on the platform',
        ),
        Expanded(
          child: AsyncValueView<SuperOverview>(
            value: overview,
            onRetry: () => ref.invalidate(superOverviewProvider),
            data: (o) => _Body(o),
          ),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.o);

  final SuperOverview o;

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, Space.xl),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Layout.contentMaxWidth),
          child: LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              final tileCols = w < 520 ? 2 : (w < 900 ? 3 : 6);
              final chartCols = w < 760 ? 1 : 2;
              final months = o.signupsByMonth;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FlowGrid(
                    equalHeight: true,
                    columns: tileCols,
                    children: [
                      (
                        1,
                        StatTile(
                          label: 'Accounts',
                          value: formatCompact(o.tenants, currency: false),
                          onTap: () => context.go('/platform/accounts'),
                        ),
                      ),
                      (
                        1,
                        StatTile(
                          label: 'Active',
                          value: formatCompact(
                            o.activeTenants,
                            currency: false,
                          ),
                        ),
                      ),
                      (
                        1,
                        StatTile(
                          label: 'Suspended',
                          value: formatCompact(
                            o.suspendedTenants,
                            currency: false,
                          ),
                          onTap: () =>
                              context.go('/platform/accounts?status=suspended'),
                        ),
                      ),
                      (
                        1,
                        StatTile(
                          label: 'Companies',
                          value: formatCompact(o.companies, currency: false),
                        ),
                      ),
                      (
                        1,
                        StatTile(
                          label: 'Users',
                          value: formatCompact(o.users, currency: false),
                        ),
                      ),
                      (
                        1,
                        StatTile(
                          label: 'Signed in, 30 days',
                          value: formatCompact(
                            o.signedInLast30Days,
                            currency: false,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.md),
                  FlowGrid(
                    columns: chartCols,
                    children: [
                      (
                        chartCols,
                        ChartCard(
                          title: 'New accounts per month',
                          subtitle: 'Last 12 months',
                          isEmpty: months.every((m) => m.$2 == 0),
                          child: TrendChart(
                            currency: false,
                            area: false,
                            labels: [for (final m in months) monthLabel(m.$1)],
                            tooltipLabels: [
                              for (final m in months)
                                monthLabel(m.$1, withYear: true),
                            ],
                            series: [
                              ChartSeries('Accounts', [
                                for (final m in months) m.$2.toDouble(),
                              ]),
                            ],
                          ),
                        ),
                      ),
                      (
                        1,
                        ChartCard(
                          title: 'By business type',
                          isEmpty: o.byBusinessType.isEmpty,
                          child: RankedBarChart(
                            currency: false,
                            maxRows: 8,
                            bars: [
                              for (final c in o.byBusinessType)
                                RankedBar(prettyKey(c.key), c.count.toDouble()),
                            ],
                          ),
                        ),
                      ),
                      (
                        1,
                        ChartCard(
                          title: 'By plan',
                          isEmpty: o.byPlan.isEmpty,
                          child: Center(
                            child: DonutChart(
                              currency: false,
                              centerLabel: 'Accounts',
                              slices: [
                                for (final c in o.byPlan)
                                  DonutSlice(
                                    prettyKey(c.key),
                                    c.count.toDouble(),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      (
                        1,
                        ChartCard(
                          title: 'By country',
                          isEmpty: o.byCountry.isEmpty,
                          child: RankedBarChart(
                            currency: false,
                            maxRows: 8,
                            bars: [
                              for (final c in o.byCountry)
                                RankedBar(c.key, c.count.toDouble()),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
