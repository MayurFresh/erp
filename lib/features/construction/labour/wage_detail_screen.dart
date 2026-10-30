import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/labour_models.dart';
import '../models/subcontract_models.dart';
import '../models/wage_math.dart';

/// Wage sheet detail with draft advances and the payment lifecycle.
class WageDetailScreen extends ConsumerStatefulWidget {
  const WageDetailScreen({super.key, required this.wageSheetId});

  final String wageSheetId;

  @override
  ConsumerState<WageDetailScreen> createState() => _WageDetailScreenState();
}

class _WageDetailScreenState extends ConsumerState<WageDetailScreen> {
  final Map<String, double> _advances = {};
  bool _busy = false;

  Future<void> _action(
    Future<WageSheet> Function() action,
    String done, {
    bool clearAdvances = false,
  }) async {
    setState(() => _busy = true);
    try {
      await action();
      if (clearAdvances) _advances.clear();
      ref.bumpC(const [CKind.wages, CKind.attendance]);
      ref.invalidate(wageSheetProvider(widget.wageSheetId));
      if (mounted) showSuccess(context, done);
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAdvances(WageSheet sheet) async {
    final rows = sheet.rows ?? const [];
    for (final row in rows) {
      final advance = _advances[row.workerId] ?? row.advance;
      if (advance < 0 || advance > row.gross + 0.004) {
        showInfoSnackBar(
          context,
          'Advance for ${row.workerName} cannot exceed gross wages.',
        );
        return;
      }
    }
    await _action(
      () => ref
          .read(constructionRepositoryProvider)
          .saveAdvances(widget.wageSheetId, Map.of(_advances)),
      'Advances saved',
      clearAdvances: true,
    );
  }

  /// Advances typed but not saved yet.
  bool _dirty(WageSheet sheet) => (sheet.rows ?? const []).any(
    (r) => WageRowView(r, _advances[r.workerId] ?? r.advance).advanceChanged,
  );

  /// Saves pending advances first so approving never drops them.
  Future<void> _approve(WageSheet sheet) async {
    final repo = ref.read(constructionRepositoryProvider);
    final pending = _dirty(sheet) ? Map.of(_advances) : null;
    await _action(
      () async {
        if (pending != null) await repo.saveAdvances(sheet.id, pending);
        return repo.approveWageSheet(sheet.id);
      },
      '${sheet.number} approved — attendance is now locked',
      clearAdvances: true,
    );
  }

  Future<void> _cancel(WageSheet sheet) async {
    final reason = await _reasonDialog(
      title: 'Cancel wage sheet',
      message:
          'Cancel ${sheet.number}? Attendance in this period can be changed '
          'again and a new wage sheet can be prepared.',
    );
    if (reason == null || !mounted) return;
    await _action(
      () => ref
          .read(constructionRepositoryProvider)
          .cancelWageSheet(widget.wageSheetId, reason),
      '${sheet.number} cancelled',
      clearAdvances: true,
    );
  }

  Future<void> _pay(WageSheet sheet) async {
    final result = await _paymentDialog(sheet);
    if (result == null || !mounted) return;
    await _action(
      () => ref
          .read(constructionRepositoryProvider)
          .payWageSheet(
            widget.wageSheetId,
            paidFromAccountId: result.accountId,
            date: apiDate(result.date),
          ),
      '${sheet.number} paid',
    );
  }

  Future<String?> _reasonDialog({
    required String title,
    required String message,
  }) => showReasonDialog(
    context,
    title: title,
    message: message,
    confirmLabel: 'Cancel wage sheet',
    cancelLabel: 'Keep it',
  );

  Future<({String accountId, DateTime date})?> _paymentDialog(
    WageSheet sheet,
  ) async {
    final accounts = await ref.read(payAccountsProvider.future);
    if (!mounted) return null;
    if (accounts.isEmpty) {
      showInfoSnackBar(
        context,
        'Create an active cash or bank account before paying wages.',
      );
      return null;
    }
    var accountId = accounts.first.id;
    var date = today();
    final result = await showDialog<({String accountId, DateTime date})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Pay wages'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Pay ${formatMoney(sheet.totalNet)} net for ${sheet.number}.',
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey('pay-account-$accountId'),
                  initialValue: accountId,
                  decoration: const InputDecoration(labelText: 'Pay from'),
                  items: [
                    for (final account in accounts)
                      DropdownMenuItem(
                        value: account.id,
                        child: Text(account.displayName),
                      ),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => accountId = value ?? accountId),
                ),
                const SizedBox(height: 12),
                DateField(
                  label: 'Payment date',
                  value: date,
                  lastDate: today(),
                  onChanged: (value) => setDialogState(() => date = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () =>
                  Navigator.of(context).pop((accountId: accountId, date: date)),
              child: const Text('Pay wages'),
            ),
          ],
        ),
      ),
    );
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.wagesView],
      child: AsyncValueView(
        value: ref.watch(wageSheetProvider(widget.wageSheetId)),
        onRetry: () => ref.invalidate(wageSheetProvider(widget.wageSheetId)),
        data: (sheet) {
          final rows = sheet.rows ?? const [];
          final totals = WageTotals.of(rows, _advances);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHeader(
                title: sheet.number,
                subtitle:
                    '${sheet.siteName} · '
                    '${formatDate(sheet.from)} – ${formatDate(sheet.to)}',
                actions: [
                  if (sheet.isDraft && perms.can(CPerm.wagesManage))
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy
                          ? null
                          : () => _action(
                              () => ref
                                  .read(constructionRepositoryProvider)
                                  .recomputeWageSheet(sheet.id),
                              'Recomputed from attendance',
                            ),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Recompute'),
                    ),
                  if (sheet.isDraft && perms.can(CPerm.wagesManage))
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: _busy ? null : () => _approve(sheet),
                      icon: const Icon(Icons.approval_outlined),
                      label: const Text('Approve'),
                    ),
                  if (sheet.status == WageSheetStatus.approved &&
                      perms.can(CPerm.wagesPay))
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: _busy ? null : () => _pay(sheet),
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('Pay wages'),
                    ),
                  if ((sheet.isDraft ||
                          sheet.status == WageSheetStatus.approved) &&
                      perms.can(CPerm.wagesManage))
                    IconButton(
                      tooltip: 'Cancel wage sheet',
                      onPressed: _busy ? null : () => _cancel(sheet),
                      icon: const Icon(Icons.cancel_outlined),
                    ),
                ],
              ),
              Expanded(
                child: CPage(
                  maxWidth: 1000,
                  children: [
                    SectionCard(
                      title: 'Summary',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FactsWrap(
                            facts: [
                              ('Status', sheet.status.label),
                              ('Workers', '${totals.workers}'),
                              ('Present days', formatQty(totals.days)),
                              ('Overtime', '${formatQty(totals.otHours)} h'),
                              ('Gross', formatMoney(totals.gross)),
                              ('Advances', formatMoney(totals.advance)),
                              ('Net', formatMoney(totals.net)),
                            ],
                          ),
                          if (sheet.status == WageSheetStatus.paid)
                            Padding(
                              padding: const EdgeInsets.only(top: 16),
                              child: Text(
                                'Paid on ${formatDate(sheet.paidAt)}.',
                                style: Theme.of(context).textTheme.bodyMedium,
                              ),
                            ),
                        ],
                      ),
                    ),

                    SectionCard(
                      title: 'Worker wages',
                      child: rows.isEmpty
                          ? const Text(
                              'No attendance was found for this period.',
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    final editable =
                                        sheet.isDraft &&
                                        perms.can(CPerm.wagesManage);
                                    double advanceOf(WageRow r) =>
                                        _advances[r.workerId] ?? r.advance;
                                    void setAdvance(WageRow r, double v) =>
                                        setState(
                                          () => _advances[r.workerId] = v,
                                        );
                                    if (constraints.maxWidth >= 860) {
                                      return _WageTable(
                                        rows: rows,
                                        totals: totals,
                                        editable: editable,
                                        advanceOf: advanceOf,
                                        onAdvance: setAdvance,
                                      );
                                    }
                                    return Column(
                                      children: [
                                        for (final row in rows) ...[
                                          _WageRowEditor(
                                            key: ValueKey(
                                              '${row.workerId}-${row.advance}',
                                            ),
                                            row: row,
                                            enabled: editable,
                                            initialAdvance: advanceOf(row),
                                            onChanged: (v) =>
                                                setAdvance(row, v),
                                          ),
                                          const SizedBox(height: 8),
                                        ],
                                      ],
                                    );
                                  },
                                ),
                                if (sheet.isDraft &&
                                    perms.can(CPerm.wagesManage) &&
                                    _dirty(sheet))
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: Align(
                                      alignment: Alignment.centerRight,
                                      child: FilledButton(
                                        style: bigButton,
                                        onPressed: _busy
                                            ? null
                                            : () => _saveAdvances(sheet),
                                        child: const Text('Save advances'),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WageRowEditor extends StatelessWidget {
  const _WageRowEditor({
    super.key,
    required this.row,
    required this.enabled,
    required this.initialAdvance,
    required this.onChanged,
  });

  final WageRow row;
  final bool enabled;
  final double initialAdvance;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final view = WageRowView(row, initialAdvance);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        row.workerName,
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        [
                          if (row.trade.isNotEmpty) tradeLabel(row.trade),
                          '${formatQty(row.presentDays)} days',
                          if (row.otHours > 0) '${formatQty(row.otHours)} h OT',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Text(
                  formatMoney(view.net),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 24,
              runSpacing: 8,
              children: [
                Text('Basic ${formatMoney(row.basic)}'),
                Text('OT ${formatMoney(row.otAmount)}'),
                Text('Gross ${formatMoney(row.gross)}'),
              ],
            ),
            if (enabled) ...[
              const SizedBox(height: 10),
              SizedBox(
                width: 240,
                child: TextFormField(
                  initialValue: formatPlain(initialAdvance),
                  keyboardType: decimalKeyboard,
                  inputFormatters: [decimalInput(decimals: 2)],
                  decoration: InputDecoration(
                    labelText: 'Advance recovered',
                    prefixText: '₹ ',
                    helperText: advanceHint(row),
                    helperMaxLines: 3,
                  ),
                  onChanged: (value) {
                    // An empty field means no advance.
                    final amount = value.trim().isEmpty
                        ? 0.0
                        : double.tryParse(value.trim());
                    if (amount != null) onChanged(amount);
                  },
                ),
              ),
            ] else if (row.advance > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Advance ${formatMoney(row.advance)}'),
              ),
            if (!enabled && row.advanceBalance > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Open advance balance ${formatMoney(row.advanceBalance)}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Open advance ₹x · cap ₹y": a recovery is capped at the lower of the
/// worker's open advance balance and 50% of gross.
String advanceHint(WageRow row) =>
    'Open advance ${formatMoney(row.advanceBalance)} · capped at '
    '${formatMoney(advanceCap(row.advanceBalance, row.gross))} '
    '(lower of balance and 50% of gross)';

/// Desktop / tablet table: days, OT, rate, basic, OT amount, gross,
/// advance (editable in draft) and net, with a totals row.
class _WageTable extends StatelessWidget {
  const _WageTable({
    required this.rows,
    required this.totals,
    required this.editable,
    required this.advanceOf,
    required this.onAdvance,
  });

  final List<WageRow> rows;
  final WageTotals totals;
  final bool editable;
  final double Function(WageRow) advanceOf;
  final void Function(WageRow, double) onAdvance;

  @override
  Widget build(BuildContext context) {
    const bold = TextStyle(fontWeight: FontWeight.w700);
    DataCell money(double v, {TextStyle? style}) =>
        DataCell(Text(formatMoney(v), style: style));
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        columnSpacing: 18,
        horizontalMargin: 8,
        dataRowMinHeight: 52,
        dataRowMaxHeight: 64,
        columns: const [
          DataColumn(label: Text('Worker')),
          DataColumn(label: Text('Days'), numeric: true),
          DataColumn(label: Text('OT h'), numeric: true),
          DataColumn(label: Text('Rate'), numeric: true),
          DataColumn(label: Text('Basic'), numeric: true),
          DataColumn(label: Text('OT amount'), numeric: true),
          DataColumn(label: Text('Gross'), numeric: true),
          DataColumn(label: Text('Advance bal.'), numeric: true),
          DataColumn(label: Text('Advance'), numeric: true),
          DataColumn(label: Text('Net'), numeric: true),
        ],
        rows: [
          for (final r in rows)
            DataRow(
              cells: [
                DataCell(
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Text(
                      [
                        r.workerName,
                        if (r.trade.isNotEmpty) tradeLabel(r.trade),
                      ].join(' · '),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                DataCell(Text(formatDays(r.presentDays))),
                DataCell(Text(formatQty(r.otHours))),
                money(r.dailyRate),
                money(r.basic),
                DataCell(
                  Tooltip(
                    message: overtimeExplanation(r.otHours, r.dailyRate),
                    child: Text(formatMoney(r.otAmount)),
                  ),
                ),
                money(r.gross),
                DataCell(
                  Tooltip(
                    message: advanceHint(r),
                    child: Text(formatMoney(r.advanceBalance)),
                  ),
                ),
                editable
                    ? DataCell(
                        SizedBox(
                          width: 110,
                          child: TextFormField(
                            key: ValueKey('adv-${r.workerId}-${r.advance}'),
                            initialValue: formatPlain(advanceOf(r)),
                            textAlign: TextAlign.right,
                            keyboardType: decimalKeyboard,
                            inputFormatters: [decimalInput()],
                            decoration: const InputDecoration(isDense: true),
                            onChanged: (value) {
                              final amount = value.trim().isEmpty
                                  ? 0.0
                                  : double.tryParse(value.trim());
                              if (amount != null) onAdvance(r, amount);
                            },
                          ),
                        ),
                      )
                    : money(advanceOf(r)),
                money(netPay(r.gross, advanceOf(r)), style: bold),
              ],
            ),
          DataRow(
            cells: [
              const DataCell(Text('Total', style: bold)),
              DataCell(Text(formatDays(totals.days), style: bold)),
              DataCell(Text(formatQty(totals.otHours), style: bold)),
              const DataCell(Text('')),
              money(totals.basic, style: bold),
              money(totals.otAmount, style: bold),
              money(totals.gross, style: bold),
              const DataCell(Text('')),
              money(totals.advance, style: bold),
              money(totals.net, style: bold),
            ],
          ),
        ],
      ),
    );
  }
}
