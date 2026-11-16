import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton, showSuccess;
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'timesheet_models.dart';
import 'timesheet_repository.dart';

/// `/timesheets`: the weekly entry grid. Each row is a customer and task; each
/// day is a field. On a phone the days wrap into rows of four.
class WeekScreen extends ConsumerStatefulWidget {
  const WeekScreen({super.key});

  @override
  ConsumerState<WeekScreen> createState() => _WeekScreenState();
}

class _WeekScreenState extends ConsumerState<WeekScreen> {
  DateTime _monday = mondayOf(DateTime.now());

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final week = ref.watch(weekProvider(apiDate(_monday)));
    final gutter = pageGutter(context);
    final end = _monday.add(const Duration(days: 6));
    return CGate(
      anyOf: const [Perm.timesheetsLog, Perm.timesheetsView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Timesheet',
            actions: [
              if (perms.can(Perm.timesheetsApprove))
                OutlinedButton(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/timesheets/approvals'),
                  child: const Text('Approvals'),
                ),
              if (perms.canAny(const [
                Perm.timesheetsView,
                Perm.timesheetsBill,
              ]))
                OutlinedButton(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/timesheets/billing'),
                  child: const Text('Billing'),
                ),
              if (perms.can(Perm.timesheetsView))
                OutlinedButton(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/timesheets/utilisation'),
                  child: const Text('Utilisation'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous week',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: () => setState(
                    () => _monday = _monday.subtract(const Duration(days: 7)),
                  ),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    '${apiDate(_monday)} to ${apiDate(end)}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: 'Next week',
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                  onPressed: () => setState(
                    () => _monday = _monday.add(const Duration(days: 7)),
                  ),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView<Week>(
              value: week,
              onRetry: () => ref.invalidate(weekProvider),
              data: (w) => _Grid(
                key: ValueKey(
                  '${w.weekStart}-${w.total}-${w.status}-${w.rows.length}',
                ),
                week: w,
                canLog: perms.can(Perm.timesheetsLog),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Grid extends ConsumerStatefulWidget {
  const _Grid({super.key, required this.week, required this.canLog});

  final Week week;
  final bool canLog;

  @override
  ConsumerState<_Grid> createState() => _GridState();
}

class _GridState extends ConsumerState<_Grid> {
  late final List<WeekRow> _rows = [...widget.week.rows];
  late final List<List<TextEditingController>> _cells = [
    for (final r in _rows) _controllersFor(r),
  ];
  bool _busy = false;

  List<TextEditingController> _controllersFor(WeekRow r) => [
    for (final h in r.hours)
      TextEditingController(text: h == 0 ? '' : hoursText(h)),
  ];

  @override
  void dispose() {
    for (final row in _cells) {
      for (final c in row) {
        c.dispose();
      }
    }
    super.dispose();
  }

  void _pull() {
    for (var i = 0; i < _rows.length; i++) {
      for (var d = 0; d < 7; d++) {
        _rows[i].hours[d] = double.tryParse(_cells[i][d].text.trim()) ?? 0;
      }
    }
  }

  double _dayTotal(int d) {
    var s = 0.0;
    for (var i = 0; i < _rows.length; i++) {
      s += double.tryParse(_cells[i][d].text.trim()) ?? 0;
    }
    return s;
  }

  Future<void> _addRow() async {
    Party? party;
    final task = TextEditingController();
    var billable = true;
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Add a row'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PickerField(
                label: 'Customer',
                value: party?.name,
                onTap: () async {
                  final p = await pickParty(ctx, ref, type: PartyType.customer);
                  if (p != null) set(() => party = p);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: task,
                decoration: const InputDecoration(labelText: 'Task'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Billable'),
                value: billable,
                onChanged: (v) => set(() => billable = v),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).maybePop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || party == null || task.text.trim().isEmpty) return;
    final row = WeekRow(
      partyId: party!.id,
      partyName: party!.name,
      task: task.text.trim(),
      billable: billable,
    );
    setState(() {
      _rows.add(row);
      _cells.add(_controllersFor(row));
    });
  }

  Future<void> _save({bool submit = false}) async {
    _pull();
    setState(() => _busy = true);
    try {
      final repo = ref.read(timesheetRepositoryProvider);
      await repo.saveWeek(widget.week.weekStart, _rows);
      if (submit) await repo.submit(widget.week.weekStart);
      ref.read(timesheetRevisionProvider.notifier).bump();
      if (mounted) {
        showSuccess(context, submit ? 'Week submitted' : 'Hours saved');
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gutter = pageGutter(context);
    final theme = Theme.of(context);
    final total = [
      for (var d = 0; d < 7; d++) _dayTotal(d),
    ].fold(0.0, (a, b) => a + b);
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.all(gutter),
            children: [
              Text(
                'Status: ${weekStatusLabel(widget.week.status)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              if (_rows.isEmpty)
                const EmptyView(
                  message: 'No hours this week. Add a row to start.',
                  icon: Icons.schedule_outlined,
                ),
              for (var i = 0; i < _rows.length; i++)
                Card(
                  margin: const EdgeInsets.only(bottom: 12),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _rows[i].partyName,
                          style: theme.textTheme.titleSmall,
                        ),
                        Text(
                          '${_rows[i].task}${_rows[i].billable ? '' : '  ·  not billable'}',
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (var d = 0; d < 7; d++)
                              SizedBox(
                                width: 64,
                                child: TextField(
                                  controller: _cells[i][d],
                                  enabled: widget.canLog && !_rows[i].locked(d),
                                  keyboardType:
                                      const TextInputType.numberWithOptions(
                                        decimal: true,
                                      ),
                                  textAlign: TextAlign.center,
                                  onChanged: (_) => setState(() {}),
                                  decoration: InputDecoration(
                                    labelText: dayNames[d],
                                    isDense: false,
                                    contentPadding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 14,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              if (widget.canLog)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: _busy ? null : _addRow,
                    icon: const Icon(Icons.add),
                    label: const Text('Add row'),
                  ),
                ),
            ],
          ),
        ),
        Material(
          elevation: 4,
          child: Padding(
            padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 8),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 8,
              children: [
                Text(
                  'Total ${hoursText(total)} h',
                  style: theme.textTheme.titleSmall,
                ),
                if (widget.canLog)
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton(
                        style: bigOutlinedButton,
                        onPressed: _busy ? null : () => _save(),
                        child: const Text('Save'),
                      ),
                      FilledButton(
                        style: bigButton,
                        onPressed: _busy ? null : () => _save(submit: true),
                        child: const Text('Save and submit'),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
