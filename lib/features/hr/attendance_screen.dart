import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'hr_models.dart';
import 'hr_repository.dart';
import 'hr_widgets.dart';

/// Day marks in the order a tap cycles through them. Null is unmarked.
const _cycle = <String?>[
  null,
  'present',
  'absent',
  'half_day',
  'leave',
  'holiday',
  'week_off',
];
const _short = {
  'present': 'P',
  'absent': 'A',
  'half_day': '1/2',
  'leave': 'L',
  'holiday': 'Hol',
  'week_off': 'Off',
};
const _long = {
  'present': 'Present',
  'absent': 'Absent',
  'half_day': 'Half day',
  'leave': 'Leave',
  'holiday': 'Holiday',
  'week_off': 'Week off',
};

String? _next(String? s) => _cycle[(_cycle.indexOf(s) + 1) % _cycle.length];

final _attendanceProvider = FutureProvider.autoDispose
    .family<List<AttendanceDay>, String>((ref, month) {
      ref.watch(activeCompanyIdProvider);
      ref.watch(hrRevisionProvider);
      return ref.watch(hrRepositoryProvider).attendanceDays(month);
    });

/// `/hr/attendance`: month register. Phones get one card per employee,
/// wide screens a grid with a column for each day.
class AttendanceScreen extends ConsumerStatefulWidget {
  const AttendanceScreen({super.key});

  @override
  ConsumerState<AttendanceScreen> createState() => _AttendanceScreenState();
}

class _AttendanceScreenState extends ConsumerState<AttendanceScreen> {
  late String _month = monthOf(DateTime.now());
  // employeeId -> day number -> status, only what differs from the server.
  final Map<String, Map<int, String?>> _edits = {};
  bool _saving = false;

  int get _daysInMonth => DateUtils.getDaysInMonth(
    int.parse(_month.substring(0, 4)),
    int.parse(_month.substring(5, 7)),
  );

  String _date(int d) => '$_month-${d.toString().padLeft(2, '0')}';

  void _shift(int by) {
    final d = DateTime(
      int.parse(_month.substring(0, 4)),
      int.parse(_month.substring(5, 7)) + by,
    );
    setState(() {
      _month = monthOf(d);
      _edits.clear();
    });
  }

  String? _status(Map<String, Map<int, String>> saved, String emp, int day) {
    final e = _edits[emp];
    if (e != null && e.containsKey(day)) return e[day];
    return saved[emp]?[day];
  }

  void _tap(Map<String, Map<int, String>> saved, String emp, int day) {
    final now = _next(_status(saved, emp, day));
    setState(() {
      final e = _edits.putIfAbsent(emp, () => {});
      if (saved[emp]?[day] == now) {
        e.remove(day);
        if (e.isEmpty) _edits.remove(emp);
      } else {
        e[day] = now;
      }
    });
  }

  void _fillPresent(Map<String, Map<int, String>> saved, List<Employee> emps) {
    setState(() {
      for (final e in emps) {
        for (var d = 1; d <= _daysInMonth; d++) {
          if (_status(saved, e.id, d) != null) continue;
          final sunday =
              DateTime(
                int.parse(_month.substring(0, 4)),
                int.parse(_month.substring(5, 7)),
                d,
              ).weekday ==
              DateTime.sunday;
          _edits.putIfAbsent(e.id, () => {})[d] = sunday
              ? 'week_off'
              : 'present';
        }
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(hrRepositoryProvider).saveAttendanceDays(_month, [
        for (final e in _edits.entries)
          {
            'employeeId': e.key,
            'days': [
              for (final d in e.value.entries)
                {'day': _date(d.key), 'status': d.value},
            ],
          },
      ]);
      _edits.clear();
      ref.bumpHr();
      if (mounted) {
        showInfoSnackBar(
          context,
          'Attendance saved. Payroll will use these days.',
        );
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final days = ref.watch(_attendanceProvider(_month));
    final emps = ref.watch(employeesProvider((q: '', status: 'active')));
    final saved = <String, Map<int, String>>{};
    for (final d in days.value ?? const <AttendanceDay>[]) {
      saved.putIfAbsent(
        d.employeeId,
        () => {},
      )[int.parse(d.day.substring(8, 10))] = d.status;
    }
    final wide = MediaQuery.sizeOf(context).width >= 1000;
    return CGate(
      anyOf: const [Perm.payrollEmployees, Perm.payrollRun],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Attendance',
            actions: [
              OutlinedButton(
                onPressed: emps.hasValue
                    ? () => _fillPresent(saved, emps.value!)
                    : null,
                child: const Text('Fill blanks as present'),
              ),
              FilledButton(
                onPressed: _edits.isEmpty || _saving ? null : _save,
                child: Text(_saving ? 'Saving' : 'Save'),
              ),
            ],
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Previous month',
                  onPressed: () => _shift(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    monthLabel(_month),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                IconButton(
                  tooltip: 'Next month',
                  onPressed: () => _shift(1),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              pageGutter(context),
              0,
              pageGutter(context),
              Space.sm,
            ),
            child: Text(
              'Tap a day to change it: ${_long.values.join(', ')}. Absent days and half of each half day are loss of pay.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: AsyncValueView(
              value: emps,
              onRetry: () => ref.invalidate(employeesProvider),
              data: (list) {
                if (days.hasError) {
                  return ErrorView(
                    error: days.error!,
                    onRetry: () => ref.invalidate(_attendanceProvider),
                  );
                }
                if (list.isEmpty) {
                  return const EmptyView(
                    icon: Icons.badge_outlined,
                    message: 'No active employees.',
                  );
                }
                return wide ? _grid(list, saved) : _cards(list, saved);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _cell(
    Map<String, Map<int, String>> saved,
    String emp,
    int day, {
    double size = 30,
  }) {
    final s = _status(saved, emp, day);
    final scheme = Theme.of(context).colorScheme;
    final edited = _edits[emp]?.containsKey(day) ?? false;
    final bad = s == 'absent';
    return Semantics(
      button: true,
      label: '$day: ${_long[s] ?? 'not marked'}',
      child: InkWell(
        key: ValueKey('att-$emp-$day'),
        onTap: () => _tap(saved, emp, day),
        child: Container(
          width: size,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: s == null
                ? null
                : bad
                ? scheme.errorContainer
                : s == 'present'
                ? scheme.secondaryContainer
                : scheme.surfaceContainerHighest,
            border: Border.all(
              color: edited ? scheme.primary : scheme.outlineVariant,
            ),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            s == null ? '$day' : _short[s]!,
            style: TextStyle(
              fontSize: 11,
              color: s == null ? scheme.onSurfaceVariant : null,
            ),
          ),
        ),
      ),
    );
  }

  Widget _cards(List<Employee> list, Map<String, Map<int, String>> saved) =>
      ListView(
        padding: EdgeInsets.all(pageGutter(context)),
        children: [
          for (final e in list)
            HrCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${e.name} (${e.code})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2, bottom: Space.sm),
                    child: Text(
                      _totals(saved, e.id),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    runSpacing: 4,
                    children: [
                      for (var d = 1; d <= _daysInMonth; d++)
                        _cell(saved, e.id, d),
                    ],
                  ),
                ],
              ),
            ),
        ],
      );

  Widget _grid(List<Employee> list, Map<String, Map<int, String>> saved) =>
      SingleChildScrollView(
        padding: EdgeInsets.all(pageGutter(context)),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const SizedBox(width: 200, child: Text('Employee')),
                  for (var d = 1; d <= _daysInMonth; d++)
                    SizedBox(
                      width: 32,
                      child: Center(
                        child: Text(
                          '$d',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ),
                  const SizedBox(width: 12),
                  const SizedBox(
                    width: 150,
                    child: Text('Present / leave / LOP'),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              for (final e in list)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 200,
                        child: Text(
                          '${e.name} (${e.code})',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      for (var d = 1; d <= _daysInMonth; d++)
                        Padding(
                          padding: const EdgeInsets.only(right: 2),
                          child: _cell(saved, e.id, d),
                        ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 150,
                        child: Text(_totals(saved, e.id, short: true)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );

  String _totals(
    Map<String, Map<int, String>> saved,
    String emp, {
    bool short = false,
  }) {
    var p = 0.0, l = 0.0, lop = 0.0;
    for (var d = 1; d <= _daysInMonth; d++) {
      switch (_status(saved, emp, d)) {
        case 'present':
          p += 1;
        case 'half_day':
          p += .5;
          lop += .5;
        case 'leave':
          l += 1;
        case 'absent':
          lop += 1;
      }
    }
    return short
        ? '${dayText(p)} / ${dayText(l)} / ${dayText(lop)}'
        : 'Present ${dayText(p)}, leave ${dayText(l)}, loss of pay ${dayText(lop)}';
  }
}
