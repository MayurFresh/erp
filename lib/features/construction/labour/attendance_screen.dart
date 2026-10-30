import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/labour_models.dart';

/// Bulk attendance sheet for one site and date.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key, this.initialSiteId, this.initialDate});

  final String? initialSiteId;
  final String? initialDate;

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  String? _siteId;
  late DateTime _date;
  List<AttendanceRow> _rows = const [];

  /// Rows as last loaded / saved, to send only what changed.
  Map<String, AttendanceRow> _saved = const {};
  bool _locked = false;
  bool _loading = false;
  bool _saving = false;
  Object? _loadError;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _siteId = widget.initialSiteId;
    _date = parseApiDate(widget.initialDate) ?? today();
    if (_siteId != null) _load();
  }

  void _show(AttendanceSheet sheet) {
    _rows = sheet.rows;
    _saved = {for (final r in sheet.rows) r.workerId: r};
    _locked = sheet.locked;
  }

  Future<void> _load() async {
    final site = _siteId;
    if (site == null) return;
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _loadError = null;
      _locked = false;
      _rows = const [];
      _saved = const {};
    });
    try {
      final sheet = await ref
          .read(constructionRepositoryProvider)
          .attendance(site, apiDate(_date));
      if (!mounted || generation != _generation) return;
      setState(() {
        _show(sheet);
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadError = error;
      });
    }
  }

  /// Marked rows that differ from what the server has.
  List<AttendanceRow> get _changed => [
    for (final row in _rows)
      if (row.status != null &&
          (_saved[row.workerId]?.status != row.status ||
              _saved[row.workerId]?.otHours != row.otHours))
        row,
  ];

  bool get _dirty => _changed.isNotEmpty;

  /// Asks before throwing away unsaved marks (site or date change).
  Future<bool> _canLeave() async {
    if (!_dirty) return true;
    return confirm(
      context,
      title: 'Discard unsaved attendance?',
      message: 'You have marked ${_changed.length} workers without saving.',
      confirmLabel: 'Discard',
      cancelLabel: 'Keep editing',
      destructive: true,
    );
  }

  void _update(AttendanceRow row, AttendanceStatus? status, {double? otHours}) {
    setState(() {
      _rows = [
        for (final item in _rows)
          if (item.workerId == row.workerId)
            item.copyWith(
              status: status,
              clearStatus: status == null,
              otHours: status == AttendanceStatus.absent ? 0 : otHours,
            )
          else
            item,
      ];
    });
  }

  void _markAllPresent() {
    setState(() {
      _rows = [
        for (final row in _rows)
          row.status == null
              ? row.copyWith(status: AttendanceStatus.present)
              : row,
      ];
    });
  }

  Future<void> _save() async {
    final site = _siteId;
    if (site == null || _locked) return;
    final changed = _changed;
    if (changed.isEmpty) {
      showInfoSnackBar(context, 'Nothing new to save.');
      return;
    }
    setState(() => _saving = true);
    try {
      final sheet = await ref
          .read(constructionRepositoryProvider)
          .saveAttendance(site, apiDate(_date), changed);
      ref.bumpC(const [CKind.attendance, CKind.wages]);
      if (!mounted) return;
      setState(() => _show(sheet));
      showSuccess(
        context,
        'Attendance saved for ${changed.length} '
        '${changed.length == 1 ? 'worker' : 'workers'}',
      );
    } catch (error) {
      if (!mounted) return;
      // 409 LOCKED: a wage sheet was approved meanwhile.
      if (apiError(error)?.code == 'LOCKED') setState(() => _locked = true);
      showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final summary = AttendanceSummary.of(_rows);
    final canMark = perms.can(CPerm.attendanceMark) && !_locked;
    final theme = Theme.of(context);

    final Widget body;
    if (_loading) {
      body = const LoadingView();
    } else if (_siteId == null) {
      body = const EmptyView(
        icon: Icons.location_on_outlined,
        message: 'Choose a site to mark attendance.',
      );
    } else if (_loadError != null) {
      body = ErrorView(error: _loadError!, onRetry: _load);
    } else if (_rows.isEmpty) {
      body = const EmptyView(
        icon: Icons.groups_outlined,
        message: 'No active workers have this site as their home site.',
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
        itemCount: _rows.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1000),
            child: _AttendanceRowCard(
              key: ValueKey(_rows[index].workerId),
              row: _rows[index],
              enabled: canMark,
              onChanged: (status, otHours) =>
                  _update(_rows[index], status, otHours: otHours),
            ),
          ),
        ),
      );
    }

    final counts = Wrap(
      spacing: 16,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _Count('Present', summary.present, Colors.green.shade800),
        _Count('Half', summary.halfDay, Colors.orange.shade900),
        _Count('Absent', summary.absent, theme.colorScheme.error),
        _Count('Not marked', summary.unmarked, theme.colorScheme.outline),
        Text(
          'OT ${formatQty(summary.otHours)} h · '
          '${formatQty(summary.manDays)} man-days',
          style: theme.textTheme.bodyMedium,
        ),
      ],
    );

    return CGate(
      anyOf: const [CPerm.labourView, CPerm.attendanceMark],
      child: BottomBarLayout(
        bar: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            counts,
            if (canMark && _rows.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 12,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: _saving || summary.unmarked == 0
                        ? null
                        : _markAllPresent,
                    icon: const Icon(Icons.done_all),
                    label: const Text('Mark all present'),
                  ),
                  FilledButton.icon(
                    style: bigButton,
                    onPressed: _saving ? null : _save,
                    icon: _saving
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.save_outlined),
                    label: Text(_dirty ? 'Save (${_changed.length})' : 'Save'),
                  ),
                ],
              ),
            ],
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: 'Attendance',
              subtitle: _locked
                  ? 'Locked by an approved or paid wage sheet'
                  : '${summary.marked} of ${summary.total} marked',
            ),
            FilterBar(
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 320),
                  child: SiteField(
                    value: _siteId,
                    onChanged: (value) async {
                      if (value == _siteId || !await _canLeave()) return;
                      setState(() => _siteId = value);
                      if (value != null) _load();
                    },
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: 'Previous day',
                      constraints: BoxConstraints.tight(kTapTarget),
                      onPressed: () =>
                          _changeDate(_date.subtract(const Duration(days: 1))),
                      icon: const Icon(Icons.chevron_left),
                    ),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 200),
                        child: DateField(
                          label: 'Date',
                          value: _date,
                          lastDate: today(),
                          onChanged: _changeDate,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Next day',
                      constraints: BoxConstraints.tight(kTapTarget),
                      onPressed: _date.isBefore(today())
                          ? () =>
                                _changeDate(_date.add(const Duration(days: 1)))
                          : null,
                      icon: const Icon(Icons.chevron_right),
                    ),
                  ],
                ),
              ],
            ),
            if (_locked)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.lock_outline),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'This date is covered by an approved or paid wage '
                        'sheet and cannot be changed.',
                      ),
                    ),
                  ],
                ),
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }

  Future<void> _changeDate(DateTime value) async {
    if (DateUtils.isSameDay(value, _date) || !await _canLeave()) return;
    setState(() => _date = value);
    _load();
  }
}

class _Count extends StatelessWidget {
  const _Count(this.label, this.count, this.color);

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$count ',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.w800,
            fontSize: 18,
          ),
        ),
        TextSpan(text: label),
      ],
    ),
  );
}

/// One worker: name, a Present / Half / Absent segmented control (tap the
/// selected one again to clear) and an OT stepper. One line on wide screens.
class _AttendanceRowCard extends StatelessWidget {
  const _AttendanceRowCard({
    super.key,
    required this.row,
    required this.enabled,
    required this.onChanged,
  });

  final AttendanceRow row;
  final bool enabled;
  final void Function(AttendanceStatus? status, double? otHours) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          row.workerName,
          style: theme.textTheme.titleMedium,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        Text(
          [tradeLabel(row.trade), ?row.contractorName].join(' · '),
          style: theme.textTheme.bodySmall,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
    final working =
        row.status == AttendanceStatus.present ||
        row.status == AttendanceStatus.halfDay;
    final ot = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('OT', style: theme.textTheme.labelLarge),
        const SizedBox(width: 4),
        CountStepper(
          value: row.otHours,
          step: 0.5,
          max: 24,
          unit: 'h',
          compact: true,
          label: 'OT hours for ${row.workerName}',
          enabled: enabled && working,
          onChanged: (hours) => onChanged(row.status, hours),
        ),
      ],
    );
    final segments = SegmentedButton<AttendanceStatus>(
      emptySelectionAllowed: true,
      showSelectedIcon: false,
      style: SegmentedButton.styleFrom(
        minimumSize: const Size(0, 48),
        selectedBackgroundColor: switch (row.status) {
          AttendanceStatus.absent => theme.colorScheme.errorContainer,
          AttendanceStatus.halfDay => Colors.orange.shade100,
          _ => Colors.green.shade100,
        },
        selectedForegroundColor: Colors.black,
        textStyle: const TextStyle(fontWeight: FontWeight.w700),
      ),
      segments: [
        for (final status in AttendanceStatus.values)
          ButtonSegment(
            value: status,
            label: Text(
              status == AttendanceStatus.halfDay ? 'Half' : status.label,
            ),
          ),
      ],
      selected: {?row.status},
      onSelectionChanged: enabled
          ? (selected) =>
                onChanged(selected.isEmpty ? null : selected.first, row.otHours)
          : null,
    );
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 720) {
              return Row(
                children: [
                  Expanded(child: name),
                  const SizedBox(width: 12),
                  SizedBox(width: 300, child: segments),
                  const SizedBox(width: 12),
                  ot,
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(child: name),
                    const SizedBox(width: 8),
                    ot,
                  ],
                ),
                const SizedBox(height: 8),
                segments,
              ],
            );
          },
        ),
      ),
    );
  }
}
