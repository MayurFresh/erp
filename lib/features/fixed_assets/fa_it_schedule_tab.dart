import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/validators.dart';
import '../../widgets/filter_dropdown.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../compliance/compliance_widgets.dart' show recentFys;
import '../compliance/tax_perms.dart';
import '../income_tax/it_widgets.dart';
import '../reports/report_widgets.dart' show tabularFigures;
import 'fa_models.dart';
import 'fa_repository.dart';

/// Income-tax block depreciation for a financial year, with the first-year
/// opening WDV editable per block.
class ItScheduleTab extends ConsumerStatefulWidget {
  const ItScheduleTab({super.key});

  @override
  ConsumerState<ItScheduleTab> createState() => _ItScheduleTabState();
}

class _ItScheduleTabState extends ConsumerState<ItScheduleTab> {
  late String _fy = recentFys().first;

  Future<void> _edit(ItBlockRow row) async {
    final value = await showDialog<double>(
      context: context,
      builder: (_) => OpeningWdvDialog(row: row, fy: _fy),
    );
    if (value == null || !mounted) return;
    ref.read(faRevisionProvider.notifier).bump();
    showInfoSnackBar(context, 'Opening WDV saved for ${row.blockName}');
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(TaxPerm.assetsManage);
    final schedule = ref.watch(itScheduleProvider(_fy));
    return Column(
      children: [
        FilterBar(
          children: [
            FilterDropdown<String>(
              label: 'Financial year',
              value: _fy,
              options: {for (final f in recentFys()) f: f},
              anyLabel: _fy,
              width: 180,
              onChanged: (v) => setState(() => _fy = v ?? _fy),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<ItSchedule>(
            value: schedule,
            onRetry: () => ref.invalidate(itScheduleProvider(_fy)),
            data: (s) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                UnverifiedNote(s.unverified),
                const Text(
                  'Block method: the full rate on opening WDV plus additions '
                  'used 180 days or more, less sale value; half the rate on '
                  'later additions. For the first year, enter each block\'s '
                  'opening WDV from your last return.',
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columns: const [
                      DataColumn(label: Text('Block')),
                      DataColumn(label: Text('Rate'), numeric: true),
                      DataColumn(label: Text('Opening WDV'), numeric: true),
                      DataColumn(
                        label: Text('Additions (full)'),
                        numeric: true,
                      ),
                      DataColumn(
                        label: Text('Additions (half)'),
                        numeric: true,
                      ),
                      DataColumn(label: Text('Sale value'), numeric: true),
                      DataColumn(label: Text('Depreciation'), numeric: true),
                      DataColumn(label: Text('Closing WDV'), numeric: true),
                      DataColumn(label: Text('Short-term gain'), numeric: true),
                    ],
                    rows: [
                      for (final r in s.rows) _row(r, manage),
                      if (s.totals != null) _totalRow(s.totals!),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  DataCell _n(double v) =>
      DataCell(Text(formatAmount(v), style: tabularFigures));

  DataRow _row(ItBlockRow r, bool manage) => DataRow(
    cells: [
      DataCell(
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(r.blockName, overflow: TextOverflow.ellipsis),
        ),
      ),
      DataCell(Text(formatPercent(r.rate), style: tabularFigures)),
      DataCell(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(formatAmount(r.openingWdv), style: tabularFigures),
            if (manage)
              IconButton(
                tooltip: 'Edit opening WDV of ${r.blockName}',
                visualDensity: VisualDensity.compact,
                onPressed: () => _edit(r),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
          ],
        ),
      ),
      _n(r.additionsFull),
      _n(r.additionsHalf),
      _n(r.saleValue),
      _n(r.depreciation),
      _n(r.closingWdv),
      _n(r.shortTermGain),
    ],
  );

  DataRow _totalRow(ItBlockRow t) {
    const bold = TextStyle(fontWeight: FontWeight.w700);
    DataCell b(double v) =>
        DataCell(Text(formatAmount(v), style: tabularFigures.merge(bold)));
    return DataRow(
      cells: [
        const DataCell(Text('Total', style: bold)),
        const DataCell(Text('')),
        b(t.openingWdv),
        b(t.additionsFull),
        b(t.additionsHalf),
        b(t.saleValue),
        b(t.depreciation),
        b(t.closingWdv),
        b(t.shortTermGain),
      ],
    );
  }
}

class OpeningWdvDialog extends ConsumerStatefulWidget {
  const OpeningWdvDialog({super.key, required this.row, required this.fy});

  final ItBlockRow row;
  final String fy;

  @override
  ConsumerState<OpeningWdvDialog> createState() => _OpeningWdvDialogState();
}

class _OpeningWdvDialogState extends ConsumerState<OpeningWdvDialog> {
  final _form = GlobalKey<FormState>();
  late final _value = TextEditingController(
    text: widget.row.openingWdv == 0 ? '' : '${widget.row.openingWdv}',
  );

  @override
  void dispose() {
    _value.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final v = parseIndianNumber(_value.text)!;
    try {
      await ref
          .read(fixedAssetRepositoryProvider)
          .setOpening(widget.fy, widget.row.blockCode, v);
      if (mounted) Navigator.pop(context, v);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Opening WDV, ${widget.row.blockName}'),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _value,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [moneyInput()],
        decoration: InputDecoration(
          labelText: 'Opening WDV for FY ${widget.fy}',
          prefixText: '₹ ',
          helperText: 'Written down value at the start of the year',
        ),
        validator: (v) => validateMoney(v, label: 'Opening WDV', min: 0),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      BusyButton(onPressed: _save, label: 'Save'),
    ],
  );
}
