import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart' show CGate, DateField;
import 'funds_models.dart';
import 'funds_pdf.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

final _budgetReportProvider = FutureProvider.autoDispose
    .family<({List<HeadRow> data, Totals totals}), String>((ref, fy) {
      ref.watch(fundsRevisionProvider);
      return ref.watch(fundsRepositoryProvider).budgetVsActual(fy);
    });

final _fundWiseProvider = FutureProvider.autoDispose
    .family<List<FundWiseRow>, ({String from, String to})>((ref, r) {
      ref.watch(fundsRevisionProvider);
      return ref.watch(fundsRepositoryProvider).fundWise(r.from, r.to);
    });

/// `/funds/reports`: budget against actual, fund-wise receipts and payments, utilisation certificate.
class FundsReportsScreen extends ConsumerStatefulWidget {
  const FundsReportsScreen({super.key});

  @override
  ConsumerState<FundsReportsScreen> createState() => _FundsReportsScreenState();
}

class _FundsReportsScreenState extends ConsumerState<FundsReportsScreen> {
  late String _fy = currentFy();
  late DateTime _from = DateTime(int.parse(_fy.substring(0, 4)), 4, 1);
  late DateTime _to = DateUtils.dateOnly(DateTime.now());
  String? _fundId;
  bool _printing = false;

  void _setFy(String fy) => setState(() {
    _fy = fy;
    final y = int.parse(fy.substring(0, 4));
    _from = DateTime(y, 4, 1);
    _to = DateTime(y + 1, 3, 31);
  });

  Future<void> _uc() async {
    setState(() => _printing = true);
    try {
      final data = await ref
          .read(fundsRepositoryProvider)
          .utilisation(_fundId!, apiDate(_from), apiDate(_to));
      final (brand, theme) = await loadBrandAndTheme(ref);
      final bytes = await buildUcPdf(data, brand: brand, theme: theme);
      await printBytes(bytes, ucFileName(data));
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final funds = ref.watch(fundsListProvider).value ?? const <FundRow>[];
    final range = (from: apiDate(_from), to: apiDate(_to));
    return CGate(
      anyOf: const [Perm.fundsView, Perm.fundsEntry, Perm.fundsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Fund reports',
            actions: [FySelector(value: _fy, onChanged: _setFy)],
          ),
          Expanded(
            child: Gutter(
              children: [
                SectionCard(
                  title: 'Budget against actual',
                  child: ref
                      .watch(_budgetReportProvider(_fy))
                      .when(
                        loading: () => const LoadingView(),
                        error: (e, _) => ErrorView(error: e),
                        data: (r) => r.data.isEmpty
                            ? const Text('No budget heads for this year.')
                            : SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: DataTable(
                                  columnSpacing: 20,
                                  headingRowHeight: 40,
                                  dataRowMinHeight: 36,
                                  dataRowMaxHeight: 44,
                                  columns: const [
                                    DataColumn(label: Text('Head')),
                                    DataColumn(
                                      label: Text('Budget'),
                                      numeric: true,
                                    ),
                                    DataColumn(
                                      label: Text('Spent'),
                                      numeric: true,
                                    ),
                                    DataColumn(
                                      label: Text('Committed'),
                                      numeric: true,
                                    ),
                                    DataColumn(
                                      label: Text('Available'),
                                      numeric: true,
                                    ),
                                    DataColumn(
                                      label: Text('Used'),
                                      numeric: true,
                                    ),
                                  ],
                                  rows: [
                                    for (final h in r.data)
                                      DataRow(
                                        cells: [
                                          DataCell(
                                            Padding(
                                              padding: EdgeInsets.only(
                                                left: h.depth * 14.0,
                                              ),
                                              child: Text(
                                                h.label,
                                                style: TextStyle(
                                                  fontWeight: h.isLeaf
                                                      ? null
                                                      : FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            Text(formatAmount(h.budget)),
                                          ),
                                          DataCell(
                                            Text(formatAmount(h.actual)),
                                          ),
                                          DataCell(
                                            Text(formatAmount(h.committed)),
                                          ),
                                          DataCell(
                                            Text(formatAmount(h.available)),
                                          ),
                                          DataCell(
                                            Text(formatPercent(h.percentUsed)),
                                          ),
                                        ],
                                      ),
                                    DataRow(
                                      cells: [
                                        const DataCell(
                                          Text(
                                            'Total',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        DataCell(
                                          Text(formatAmount(r.totals.budget)),
                                        ),
                                        DataCell(
                                          Text(formatAmount(r.totals.actual)),
                                        ),
                                        DataCell(
                                          Text(
                                            formatAmount(r.totals.committed),
                                          ),
                                        ),
                                        DataCell(
                                          Text(
                                            formatAmount(r.totals.available),
                                          ),
                                        ),
                                        const DataCell(Text('')),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                      ),
                ),
                SectionCard(
                  title: 'Fund-wise receipts and payments',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      FormRow(
                        minCellWidth: 160,
                        children: [
                          DateField(
                            label: 'From',
                            value: _from,
                            onChanged: (d) => setState(() => _from = d),
                          ),
                          DateField(
                            label: 'To',
                            value: _to,
                            onChanged: (d) => setState(() => _to = d),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      ref
                          .watch(_fundWiseProvider(range))
                          .when(
                            loading: () => const LoadingView(),
                            error: (e, _) => ErrorView(error: e),
                            data: (rows) => rows.isEmpty
                                ? const Text('No funds yet.')
                                : SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: DataTable(
                                      columnSpacing: 20,
                                      columns: const [
                                        DataColumn(label: Text('Fund')),
                                        DataColumn(
                                          label: Text('Opening'),
                                          numeric: true,
                                        ),
                                        DataColumn(
                                          label: Text('Received'),
                                          numeric: true,
                                        ),
                                        DataColumn(
                                          label: Text('Spent'),
                                          numeric: true,
                                        ),
                                        DataColumn(
                                          label: Text('Closing'),
                                          numeric: true,
                                        ),
                                      ],
                                      rows: [
                                        for (final r in rows)
                                          DataRow(
                                            cells: [
                                              DataCell(Text(r.name)),
                                              DataCell(
                                                Text(formatAmount(r.opening)),
                                              ),
                                              DataCell(
                                                Text(formatAmount(r.received)),
                                              ),
                                              DataCell(
                                                Text(formatAmount(r.spent)),
                                              ),
                                              DataCell(
                                                Text(formatAmount(r.closing)),
                                              ),
                                            ],
                                          ),
                                      ],
                                    ),
                                  ),
                          ),
                    ],
                  ),
                ),
                SectionCard(
                  title: 'Utilisation certificate',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Uses the dates above. Choose the fund to certify.',
                      ),
                      const SizedBox(height: 10),
                      DropdownButtonFormField<String>(
                        key: const ValueKey('uc-fund'),
                        initialValue: _fundId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Fund or scheme',
                        ),
                        items: [
                          for (final f in funds)
                            DropdownMenuItem(
                              value: f.id,
                              child: Text(
                                f.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _fundId = v),
                      ),
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: BusyButton(
                          key: const ValueKey('uc-print'),
                          busy: _printing,
                          onPressed: _fundId == null || _printing ? null : _uc,
                          label: 'Print utilisation certificate',
                        ),
                      ),
                    ],
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
