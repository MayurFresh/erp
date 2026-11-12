import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';

/// `/education/attendance`: pick a class to mark today. Teachers see the
/// classes they teach; managers see all.
class AttendanceListScreen extends ConsumerWidget {
  const AttendanceListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(Perm.educationManage);
    return CGate(
      anyOf: const [Perm.educationAttendance, Perm.educationManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Attendance'),
          Expanded(
            child: AsyncValueView<List<EduClass>>(
              value: ref.watch(eduClassesProvider),
              onRetry: () => ref.invalidate(eduClassesProvider),
              data: (all) {
                final list = [
                  for (final c in all)
                    if (c.isActive && (manage || c.mine)) c,
                ];
                if (list.isEmpty) {
                  return const EmptyView(
                    icon: Icons.fact_check_outlined,
                    message: 'No class is assigned to you. Ask the principal.',
                  );
                }
                return ListView(
                  padding: EdgeInsets.fromLTRB(
                    pageGutter(context),
                    0,
                    pageGutter(context),
                    24,
                  ),
                  children: [
                    for (final c in list)
                      Card(
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          minTileHeight: 64,
                          onTap: () =>
                              context.go('/education/attendance/${c.id}'),
                          title: Text(c.label),
                          subtitle: Text(
                            [
                              '${c.students} students',
                              if (c.detail.isNotEmpty) c.detail,
                            ].join('  |  '),
                          ),
                          trailing: const Icon(Icons.chevron_right),
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

final eduRosterProvider = FutureProvider.autoDispose.family<Roster, String>((
  ref,
  classId,
) {
  ref.watch(activeCompanyIdProvider);
  return ref.watch(eduRepositoryProvider).roster(classId);
});

/// `/education/attendance/:classId`: everyone starts as present. Tap a row
/// to cycle present, absent, late. Built for a phone: big rows, one save.
class AttendanceMarkScreen extends ConsumerWidget {
  const AttendanceMarkScreen({super.key, required this.classId});

  final String classId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => CGate(
    anyOf: const [Perm.educationAttendance, Perm.educationManage],
    child: AsyncValueView<Roster>(
      value: ref.watch(eduRosterProvider(classId)),
      onRetry: () => ref.invalidate(eduRosterProvider(classId)),
      data: (r) => _Marking(key: ValueKey('${r.classId}-${r.date}'), roster: r),
    ),
  );
}

class _Marking extends ConsumerStatefulWidget {
  const _Marking({super.key, required this.roster});

  final Roster roster;

  @override
  ConsumerState<_Marking> createState() => _MarkingState();
}

class _MarkingState extends ConsumerState<_Marking> {
  late final List<RosterEntry> _rows = [
    for (final s in widget.roster.students)
      RosterEntry(
        studentId: s.studentId,
        name: s.name,
        rollNo: s.rollNo,
        status: s.status,
      ),
  ];
  bool _saving = false;
  bool _changed = false;

  static const _next = {
    'present': 'absent',
    'absent': 'late',
    'late': 'present',
  };

  int _count(String s) => _rows.where((r) => r.status == s).length;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(eduRepositoryProvider)
          .saveAttendance(widget.roster.classId, widget.roster.date, _rows);
      if (!mounted) return;
      ref.bumpEdu(const [EduKind.attendance]);
      ref.invalidate(eduRosterProvider(widget.roster.classId));
      setState(() => _changed = false);
      showSuccess(context, 'Attendance saved');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Color colour(String s) => switch (s) {
      'absent' => scheme.error,
      'late' => const Color(0xFFB45309),
      _ => const Color(0xFF1A7F4B),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: widget.roster.label,
          subtitle:
              'Attendance for ${formatDate(widget.roster.date)}'
              '${widget.roster.marked ? '  |  saved earlier, changes update it' : ''}',
          actions: [
            TextButton.icon(
              onPressed: () => context.go(
                '/education/attendance/${widget.roster.classId}/sheet',
              ),
              icon: const Icon(Icons.calendar_view_month_outlined),
              label: const Text('Month sheet'),
            ),
          ],
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 16,
                  children: [
                    Text('Present ${_count('present')}'),
                    Text('Absent ${_count('absent')}'),
                    Text('Late ${_count('late')}'),
                  ],
                ),
              ),
              TextButton(
                onPressed: _saving
                    ? null
                    : () => setState(() {
                        for (final r in _rows) {
                          r.status = 'present';
                        }
                        _changed = true;
                      }),
                child: const Text('All present'),
              ),
            ],
          ),
        ),
        Expanded(
          child: BottomBarLayout(
            maxWidth: 720,
            bar: FilledButton.icon(
              style: bigButton,
              onPressed: _saving || _rows.isEmpty ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(
                _changed || !widget.roster.marked
                    ? 'Save attendance'
                    : 'Save again',
              ),
            ),
            child: _rows.isEmpty
                ? const EmptyView(
                    icon: Icons.groups_outlined,
                    message: 'No students in this class yet.',
                  )
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: ListView.builder(
                        padding: EdgeInsets.symmetric(
                          horizontal: pageGutter(context),
                          vertical: 4,
                        ),
                        itemCount: _rows.length,
                        itemBuilder: (context, i) {
                          final r = _rows[i];
                          final c = colour(r.status);
                          return Card(
                            margin: const EdgeInsets.only(bottom: 6),
                            child: InkWell(
                              key: ValueKey('mark-${r.studentId}'),
                              borderRadius: BorderRadius.circular(8),
                              onTap: _saving
                                  ? null
                                  : () => setState(() {
                                      r.status = _next[r.status] ?? 'present';
                                      _changed = true;
                                    }),
                              child: Container(
                                constraints: const BoxConstraints(
                                  minHeight: 60,
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  border: Border(
                                    left: BorderSide(color: c, width: 5),
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    SizedBox(
                                      width: 34,
                                      child: Text(
                                        r.rollNo ?? '',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ),
                                    Expanded(
                                      child: Text(
                                        r.name,
                                        style: theme.textTheme.titleSmall,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      switch (r.status) {
                                        'absent' => 'Absent',
                                        'late' => 'Late',
                                        _ => 'Present',
                                      },
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(color: c),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

/// `/education/attendance/:classId/sheet`: the month at a glance.
class AttendanceSheetScreen extends ConsumerStatefulWidget {
  const AttendanceSheetScreen({super.key, required this.classId});

  final String classId;

  @override
  ConsumerState<AttendanceSheetScreen> createState() => _SheetState();
}

class _SheetState extends ConsumerState<AttendanceSheetScreen> {
  late DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  String get _key => apiDate(_month).substring(0, 7);

  void _shift(int by) =>
      setState(() => _month = DateTime(_month.year, _month.month + by));

  @override
  Widget build(BuildContext context) {
    final sheet = ref.watch(
      eduSheetProvider((classId: widget.classId, month: _key)),
    );
    return CGate(
      anyOf: const [Perm.educationView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Monthly attendance',
            subtitle: monthLabel(_key),
            actions: [
              IconButton(
                tooltip: 'Previous month',
                onPressed: () => _shift(-1),
                icon: const Icon(Icons.chevron_left),
              ),
              IconButton(
                tooltip: 'Next month',
                onPressed: () => _shift(1),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView<AttendanceSheet>(
              value: sheet,
              onRetry: () => ref.invalidate(eduSheetProvider),
              data: (s) => s.rows.isEmpty
                  ? const EmptyView(
                      icon: Icons.fact_check_outlined,
                      message: 'No attendance recorded this month.',
                    )
                  : SingleChildScrollView(
                      padding: EdgeInsets.symmetric(
                        horizontal: pageGutter(context),
                      ),
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: DataTable(
                          columnSpacing: 10,
                          headingRowHeight: 36,
                          dataRowMinHeight: 34,
                          dataRowMaxHeight: 40,
                          columns: [
                            const DataColumn(label: Text('Roll')),
                            const DataColumn(label: Text('Name')),
                            for (var d = 1; d <= s.days; d++)
                              DataColumn(label: Text('$d')),
                            const DataColumn(
                              label: Text('Absent'),
                              numeric: true,
                            ),
                            const DataColumn(
                              label: Text('Late'),
                              numeric: true,
                            ),
                            const DataColumn(
                              label: Text('Present %'),
                              numeric: true,
                            ),
                          ],
                          rows: [
                            for (final r in s.rows)
                              DataRow(
                                cells: [
                                  DataCell(Text(r.rollNo ?? '')),
                                  DataCell(
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(
                                        maxWidth: 180,
                                      ),
                                      child: Text(
                                        r.name,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ),
                                  for (var d = 1; d <= s.days; d++)
                                    DataCell(
                                      Text(switch (r.marks[d]) {
                                        'present' => 'P',
                                        'absent' => 'A',
                                        'late' => 'L',
                                        _ => '',
                                      }),
                                    ),
                                  DataCell(Text('${r.stats.absent}')),
                                  DataCell(Text('${r.stats.late}')),
                                  DataCell(Text(r.stats.percentLabel)),
                                ],
                              ),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
