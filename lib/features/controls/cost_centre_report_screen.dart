import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../auth/session.dart';
import '../reports/report_export.dart';
import '../reports/report_period.dart';
import '../reports/report_widgets.dart';
import 'controls_models.dart';
import 'controls_repository.dart';
import '../../core/app_colors.dart';

final _costCentreReportProvider = FutureProvider.autoDispose
    .family<CostCentreReport, DateRange>((ref, range) {
      ref.watch(activeCompanyIdProvider);
      return ref
          .watch(controlsRepositoryProvider)
          .costCentreReport(from: range.apiFrom, to: range.apiTo);
    });

ReportExport _export(CostCentreReport r, String period) => ReportExport(
  title: 'Cost centre report',
  subtitle: period,
  fileStem: 'Cost-centres-${r.from}-${r.to}',
  columns: const [
    ExportColumn('Code'),
    ExportColumn('Cost centre'),
    ExportColumn('Income', CellKind.money),
    ExportColumn('Expense', CellKind.money),
    ExportColumn('Net', CellKind.money),
  ],
  rows: [
    for (final x in r.rows) [x.code, x.name, x.income, x.expense, x.net],
  ],
  totals: [null, 'Total', r.totals.income, r.totals.expense, r.totals.net],
);

/// `/cost-centre-report`: income, expense and net per cost centre.
class CostCentreReportScreen extends ConsumerStatefulWidget {
  const CostCentreReportScreen({super.key});

  @override
  ConsumerState<CostCentreReportScreen> createState() =>
      _CostCentreReportScreenState();
}

class _CostCentreReportScreenState
    extends ConsumerState<CostCentreReportScreen> {
  DateRange _range = DateRange.fyToDate();

  @override
  Widget build(BuildContext context) {
    final value = ref.watch(_costCentreReportProvider(_range));
    final theme = Theme.of(context);
    Color netColor(double n) =>
        n < 0 ? theme.colorScheme.error : context.colors.success;
    return ReportPage(
      title: 'Cost centre report',
      subtitle: _range.label,
      export: value.value == null ? null : _export(value.value!, _range.label),
      controls: [
        PeriodButton(
          value: _range,
          onChanged: (r) => setState(() => _range = r),
        ),
      ],
      body: ReportBody<CostCentreReport>(
        value: value,
        onRetry: () => ref.invalidate(_costCentreReportProvider(_range)),
        isEmpty: (r) => r.rows.isEmpty,
        emptyMessage: 'No income or expenses in this period.',
        builder: (r) => [
          StatRow(
            children: [
              StatTile(label: 'Income', value: formatMoney(r.totals.income)),
              StatTile(label: 'Expense', value: formatMoney(r.totals.expense)),
              StatTile(
                label: 'Net',
                value: formatMoney(r.totals.net),
                color: netColor(r.totals.net),
              ),
            ],
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (context, c) => c.maxWidth >= 640
                ? Card(
                    margin: EdgeInsets.zero,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minWidth: c.maxWidth),
                        child: DataTable(
                          columns: const [
                            DataColumn(label: Text('Cost centre')),
                            DataColumn(label: Text('Income'), numeric: true),
                            DataColumn(label: Text('Expense'), numeric: true),
                            DataColumn(label: Text('Net'), numeric: true),
                          ],
                          rows: [
                            for (final x in [...r.rows, r.totals])
                              DataRow(
                                cells: [
                                  DataCell(
                                    Text(
                                      x == r.totals
                                          ? 'Total'
                                          : x.code == null
                                          ? x.name
                                          : '${x.code} · ${x.name}',
                                      style: x == r.totals
                                          ? const TextStyle(
                                              fontWeight: FontWeight.w600,
                                            )
                                          : null,
                                    ),
                                  ),
                                  DataCell(Text(formatMoney(x.income))),
                                  DataCell(Text(formatMoney(x.expense))),
                                  DataCell(
                                    Text(
                                      formatMoney(x.net),
                                      style: TextStyle(color: netColor(x.net)),
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
                  )
                : Column(
                    children: [
                      for (final x in r.rows)
                        Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            title: Text(
                              x.code == null ? x.name : '${x.code} · ${x.name}',
                            ),
                            subtitle: Text(
                              'Income ${formatMoney(x.income)}\n'
                              'Expense ${formatMoney(x.expense)}',
                            ),
                            isThreeLine: true,
                            trailing: Text(
                              formatMoney(x.net),
                              style: TextStyle(
                                color: netColor(x.net),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}
