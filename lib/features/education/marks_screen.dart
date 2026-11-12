import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'education_widgets.dart';
import 'exam_data.dart';

const _gate = [
  Perm.educationExams,
  Perm.educationExamsManage,
  Perm.educationManage,
];

/// `/education/exams/:termId/:classId/marks`. A grid on wide screens (type A
/// for absent), one student at a time on phones.
class MarksScreen extends ConsumerWidget {
  const MarksScreen({super.key, required this.termId, required this.classId});
  final String termId;
  final String classId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (termId: termId, classId: classId);
    return CGate(
      anyOf: _gate,
      child: AsyncValueView<MarkGrid>(
        value: ref.watch(examGridProvider(key)),
        onRetry: () => ref.invalidate(examGridProvider(key)),
        data: (g) => DefaultTabController(
          length: 2,
          child: Column(
            children: [
              const TabBar(
                tabs: [
                  Tab(text: 'Marks'),
                  Tab(text: 'Remarks and grades'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _MarksEditor(
                      key: ValueKey(
                        '${g.label}-${g.papers.length}-${g.students.length}',
                      ),
                      termId: termId,
                      classId: classId,
                      grid: g,
                    ),
                    RemarksPanel(termId: termId, classId: classId),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarksEditor extends ConsumerStatefulWidget {
  const _MarksEditor({
    super.key,
    required this.termId,
    required this.classId,
    required this.grid,
  });
  final String termId;
  final String classId;
  final MarkGrid grid;

  @override
  ConsumerState<_MarksEditor> createState() => _MarksEditorState();
}

class _MarksEditorState extends ConsumerState<_MarksEditor> {
  /// Edited text per `studentId|paperId`; absent when untouched.
  final Map<String, String> _edits = {};
  final Map<String, TextEditingController> _ctl = {};
  bool _saving = false;
  int _index = 0;

  String _k(String s, String p) => '$s|$p';

  String _text(MarkRow r, Paper p) {
    final e = _edits[_k(r.studentId, p.id)];
    if (e != null) return e;
    final c = r.cells[p.id]!;
    return c.absent ? 'A' : fmtMarks(c.marks);
  }

  TextEditingController _controller(MarkRow r, Paper p) => _ctl.putIfAbsent(
    _k(r.studentId, p.id),
    () => TextEditingController(text: _text(r, p)),
  );

  void _set(MarkRow r, Paper p, String v) {
    setState(() => _edits[_k(r.studentId, p.id)] = v.trim());
  }

  /// null when fine, otherwise a short problem.
  String? _problem(String v, Paper p) {
    if (v.isEmpty || v.toUpperCase() == 'A') return null;
    final n = double.tryParse(v);
    if (n == null) return 'Number or A';
    if (n > p.maxMarks) return 'Max ${fmtMarks(p.maxMarks)}';
    return null;
  }

  Future<void> _save() async {
    final entries = <Map<String, Object?>>[];
    for (final r in widget.grid.students) {
      for (final p in widget.grid.papers) {
        final v = _edits[_k(r.studentId, p.id)];
        if (v == null) continue;
        if (_problem(v, p) != null) {
          showErrorSnackBar(
            context,
            'Check ${r.name}, ${p.subject}: ${_problem(v, p)}.',
          );
          return;
        }
        final absent = v.toUpperCase() == 'A';
        entries.add({
          'paperId': p.id,
          'studentId': r.studentId,
          'absent': absent,
          'marks': absent || v.isEmpty ? null : double.parse(v),
        });
      }
    }
    if (entries.isEmpty) return;
    setState(() => _saving = true);
    try {
      await ref
          .read(examRepositoryProvider)
          .saveMarks(widget.termId, widget.classId, entries);
      ref.read(examRevisionProvider(ExamKind.marks).notifier).bump();
      ref.invalidate(
        examGridProvider((termId: widget.termId, classId: widget.classId)),
      );
      if (mounted) {
        _edits.clear();
        showSuccess(context, 'Marks saved');
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.grid;
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Marks, ${g.label}',
          subtitle: g.locked
              ? 'This exam is published. Marks are locked.'
              : wide
              ? 'Type the marks, or A for absent. Empty means not entered.'
              : null,
          actions: [
            TextButton(
              onPressed: () => context.go(
                '/education/exams/${widget.termId}/${widget.classId}/results',
              ),
              child: const Text('Results'),
            ),
          ],
        ),
        Expanded(
          child: g.papers.isEmpty || g.students.isEmpty
              ? const EmptyView(
                  icon: Icons.assignment_outlined,
                  message: 'Set up subjects and add students first.',
                )
              : BottomBarLayout(
                  maxWidth: wide ? 1100 : 560,
                  bar: g.locked
                      ? const SizedBox.shrink()
                      : FilledButton.icon(
                          style: bigButton,
                          onPressed: _saving || _edits.isEmpty ? null : _save,
                          icon: const Icon(Icons.check),
                          label: Text(
                            _edits.isEmpty
                                ? 'Save marks'
                                : 'Save ${_edits.length} changes',
                          ),
                        ),
                  child: wide ? _grid(g) : _single(g),
                ),
        ),
      ],
    );
  }

  Widget _field(MarkRow r, Paper p, bool locked, {bool big = false}) {
    final v = _text(r, p);
    return TextField(
      key: ValueKey('m-${r.rollNo ?? r.name}-${p.subject}'),
      controller: _controller(r, p),
      enabled: !locked,
      textAlign: big ? TextAlign.start : TextAlign.center,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.aA]'))],
      textInputAction: TextInputAction.next,
      onChanged: (t) => _set(r, p, t),
      decoration: InputDecoration(
        isDense: !big,
        labelText: big ? '${p.subject}, out of ${fmtMarks(p.maxMarks)}' : null,
        errorText: _problem(v, p),
        border: const OutlineInputBorder(),
      ),
    );
  }

  Widget _grid(MarkGrid g) => Scrollbar(
    child: SingleChildScrollView(
      padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columnSpacing: 16,
          dataRowMinHeight: 56,
          dataRowMaxHeight: 64,
          columns: [
            const DataColumn(label: Text('Roll')),
            const DataColumn(label: Text('Student')),
            for (final p in g.papers)
              DataColumn(
                label: Text('${p.subject}\n(${fmtMarks(p.maxMarks)})'),
              ),
          ],
          rows: [
            for (final r in g.students)
              DataRow(
                cells: [
                  DataCell(Text(r.rollNo ?? '')),
                  DataCell(Text(r.name)),
                  for (final p in g.papers)
                    DataCell(
                      SizedBox(width: 84, child: _field(r, p, g.locked)),
                    ),
                ],
              ),
          ],
        ),
      ),
    ),
  );

  Widget _single(MarkGrid g) {
    final r = g.students[_index.clamp(0, g.students.length - 1)];
    return ListView(
      padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
      children: [
        Row(
          children: [
            IconButton(
              tooltip: 'Previous student',
              onPressed: _index == 0 ? null : () => setState(() => _index--),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Column(
                children: [
                  Text(
                    r.name,
                    style: Theme.of(context).textTheme.titleMedium,
                    textAlign: TextAlign.center,
                  ),
                  Text(
                    '${r.rollNo == null ? '' : 'Roll ${r.rollNo}, '}'
                    '${_index + 1} of ${g.students.length}',
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Next student',
              onPressed: _index >= g.students.length - 1
                  ? null
                  : () => setState(() => _index++),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final p in g.papers)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _field(r, p, g.locked, big: true)),
                const SizedBox(width: 8),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FilterChip(
                    key: ValueKey('absent-${r.rollNo ?? r.name}-${p.subject}'),
                    label: const Text('Absent'),
                    selected: _text(r, p).toUpperCase() == 'A',
                    onSelected: g.locked
                        ? null
                        : (on) {
                            final c = _controller(r, p);
                            c.text = on ? 'A' : '';
                            _set(r, p, c.text);
                          },
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Class teacher remarks and co-scholastic grades. A list on wide screens,
/// one student at a time on phones.
class RemarksPanel extends ConsumerWidget {
  const RemarksPanel({super.key, required this.termId, required this.classId});
  final String termId;
  final String classId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (termId: termId, classId: classId);
    return AsyncValueView<RemarkSheet>(
      value: ref.watch(examRemarksProvider(key)),
      onRetry: () => ref.invalidate(examRemarksProvider(key)),
      data: (s) => s.students.isEmpty
          ? const EmptyView(
              icon: Icons.groups_outlined,
              message: 'No students in this class.',
            )
          : _RemarksEditor(
              key: ValueKey('rem-${s.students.length}-${s.areas.length}'),
              termId: termId,
              classId: classId,
              sheet: s,
            ),
    );
  }
}

class _RemarksEditor extends ConsumerStatefulWidget {
  const _RemarksEditor({
    super.key,
    required this.termId,
    required this.classId,
    required this.sheet,
  });
  final String termId;
  final String classId;
  final RemarkSheet sheet;

  @override
  ConsumerState<_RemarksEditor> createState() => _RemarksEditorState();
}

class _RemarksEditorState extends ConsumerState<_RemarksEditor> {
  final Map<String, String> _remark = {};
  final Map<String, Map<String, String?>> _grades = {};
  final Map<String, TextEditingController> _ctl = {};
  bool _saving = false;
  int _index = 0;

  int get _changes => {..._remark.keys, ..._grades.keys}.length;

  Widget _card(RemarkRow r) {
    final sheet = widget.sheet;
    final c = _ctl.putIfAbsent(
      r.studentId,
      () => TextEditingController(text: r.remark ?? ''),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${r.rollNo == null ? '' : '${r.rollNo}. '}${r.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            TextField(
              key: ValueKey('remark-${r.rollNo ?? r.name}'),
              controller: c,
              enabled: !sheet.locked,
              maxLength: 500,
              minLines: 1,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Class teacher remarks',
              ),
              onChanged: (v) => setState(() => _remark[r.studentId] = v.trim()),
            ),
            for (final a in sheet.areas)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(width: 190, child: Text(a)),
                    for (final g in sheet.scale)
                      ChoiceChip(
                        key: ValueKey('co-${r.rollNo ?? r.name}-$a-${g.grade}'),
                        label: Text(g.grade),
                        selected:
                            (_grades[r.studentId]?.containsKey(a) ?? false
                                ? _grades[r.studentId]![a]
                                : r.grades[a]) ==
                            g.grade,
                        onSelected: sheet.locked
                            ? null
                            : (on) => setState(
                                () => (_grades[r.studentId] ??= {})[a] = on
                                    ? g.grade
                                    : null,
                              ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final ids = {..._remark.keys, ..._grades.keys};
    final entries = [
      for (final id in ids)
        {
          'studentId': id,
          if (_remark.containsKey(id)) 'remark': _remark[id],
          if (_grades.containsKey(id)) 'areas': _grades[id],
        },
    ];
    setState(() => _saving = true);
    try {
      await ref
          .read(examRepositoryProvider)
          .saveRemarks(widget.termId, widget.classId, entries);
      ref.invalidate(
        examRemarksProvider((termId: widget.termId, classId: widget.classId)),
      );
      ref.read(examRevisionProvider(ExamKind.marks).notifier).bump();
      if (mounted) {
        _remark.clear();
        _grades.clear();
        showSuccess(context, 'Saved');
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sheet;
    final phone = MediaQuery.sizeOf(context).width < 720;
    final r = s.students[_index.clamp(0, s.students.length - 1)];
    return BottomBarLayout(
      maxWidth: 760,
      bar: s.locked
          ? const SizedBox.shrink()
          : FilledButton.icon(
              style: bigButton,
              onPressed: _saving || _changes == 0 ? null : _save,
              icon: const Icon(Icons.check),
              label: Text(
                _changes == 0 ? 'Save remarks' : 'Save $_changes students',
              ),
            ),
      child: ListView(
        padding: EdgeInsets.all(pageGutter(context)),
        children: [
          if (s.locked)
            const Padding(
              padding: EdgeInsets.only(bottom: 8),
              child: Text('This exam is published. Remarks are locked.'),
            ),
          if (phone) ...[
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous student',
                  onPressed: _index == 0
                      ? null
                      : () => setState(() => _index--),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Text(
                    '${_index + 1} of ${s.students.length}',
                    textAlign: TextAlign.center,
                  ),
                ),
                IconButton(
                  tooltip: 'Next student',
                  onPressed: _index >= s.students.length - 1
                      ? null
                      : () => setState(() => _index++),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            _card(r),
          ] else
            for (final x in s.students) _card(x),
        ],
      ),
    );
  }
}
