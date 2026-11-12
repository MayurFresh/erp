import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/states.dart';
import 'education_repository.dart';
import 'education_widgets.dart' show showSuccess;
import 'exam_data.dart';

Future<void> _run(
  BuildContext context,
  WidgetRef ref,
  Future<void> Function() job,
) async {
  try {
    await job();
    ref.read(examRevisionProvider(ExamKind.setup).notifier).bump();
  } catch (e) {
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

/// Name for a new exam term such as "Unit test 1". Pops `true`.
Future<bool?> showTermDialog(
  BuildContext context,
  WidgetRef ref, {
  required String yearId,
  ExamTerm? term,
}) {
  final name = TextEditingController(text: term?.name);
  return showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(term == null ? 'Add exam' : 'Rename exam'),
      content: SizedBox(
        width: 420,
        child: TextField(
          controller: name,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Name',
            hintText: 'Unit test 1, Half yearly, Annual',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () async {
            if (name.text.trim().isEmpty) return;
            try {
              await ref.read(examRepositoryProvider).saveTerm(term?.id, {
                'name': name.text.trim(),
                if (term == null) 'yearId': yearId,
                if (term != null) 'expectedUpdatedAt': term.updatedAt,
              });
              ref.read(examRevisionProvider(ExamKind.setup).notifier).bump();
              if (ctx.mounted) Navigator.of(ctx).pop(true);
            } catch (e) {
              if (ctx.mounted) showErrorSnackBar(ctx, e);
            }
          },
          child: const Text('Save'),
        ),
      ],
    ),
  );
}

/// Grading scale and pass percentage.
Future<void> showGradesDialog(
  BuildContext context,
  WidgetRef ref,
  ExamSettings s,
) => showDialog<void>(
  context: context,
  builder: (ctx) => _GradesDialog(settings: s),
);

class _GradesDialog extends ConsumerStatefulWidget {
  const _GradesDialog({required this.settings});
  final ExamSettings settings;
  @override
  ConsumerState<_GradesDialog> createState() => _GradesDialogState();
}

class _GradesDialogState extends ConsumerState<_GradesDialog> {
  late final List<(TextEditingController, TextEditingController)> _rows = [
    for (final g in widget.settings.grades)
      (
        TextEditingController(text: g.grade),
        TextEditingController(text: fmtMarks(g.minPct)),
      ),
  ];
  late final _pass = TextEditingController(
    text: fmtMarks(widget.settings.passPercent),
  );
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(examRepositoryProvider).saveSettings({
        'grades': [
          for (final r in _rows)
            {
              'grade': r.$1.text.trim(),
              'minPct': double.tryParse(r.$2.text.trim()) ?? 0,
            },
        ],
        'passPercent': double.tryParse(_pass.text.trim()) ?? 33,
      });
      ref.read(examRevisionProvider(ExamKind.setup).notifier).bump();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Grading scale'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'A student gets the first grade whose minimum percentage '
                'they reach. The lowest grade must start at 0.',
              ),
            ),
            const SizedBox(height: 8),
            for (final (i, r) in _rows.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: ValueKey('grade-$i'),
                        controller: r.$1,
                        decoration: const InputDecoration(labelText: 'Grade'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: ValueKey('grade-min-$i'),
                        controller: r.$2,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'From %'),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove grade',
                      onPressed: _rows.length <= 2
                          ? null
                          : () => setState(() => _rows.removeAt(i)),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(
                  () => _rows.add((
                    TextEditingController(),
                    TextEditingController(),
                  )),
                ),
                icon: const Icon(Icons.add),
                label: const Text('Add grade'),
              ),
            ),
            TextField(
              controller: _pass,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Pass mark, percent of each paper',
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}

/// Subjects of one class: add, rename, switch off.
class SubjectsPanel extends ConsumerStatefulWidget {
  const SubjectsPanel({super.key});
  @override
  ConsumerState<SubjectsPanel> createState() => _SubjectsPanelState();
}

class _SubjectsPanelState extends ConsumerState<SubjectsPanel> {
  String? _classId;
  final _name = TextEditingController();

  Future<void> _add() async {
    final n = _name.text.trim();
    if (n.isEmpty || _classId == null) return;
    await _run(
      context,
      ref,
      () => ref.read(examRepositoryProvider).saveSubject(null, {
        'classId': _classId,
        'name': n,
      }),
    );
    _name.clear();
  }

  @override
  Widget build(BuildContext context) {
    final classes = ref.watch(eduClassesProvider).value ?? const [];
    final active = [
      for (final c in classes)
        if (c.isActive) c,
    ];
    _classId ??= active.isEmpty ? null : active.first.id;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('subject-class-$_classId'),
          initialValue: _classId,
          decoration: const InputDecoration(labelText: 'Class'),
          items: [
            for (final c in active)
              DropdownMenuItem(value: c.id, child: Text(c.label)),
          ],
          onChanged: (v) => setState(() => _classId = v),
        ),
        const SizedBox(height: 12),
        if (_classId != null) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'New subject',
                    hintText: 'Mathematics',
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _add, child: const Text('Add')),
            ],
          ),
          const SizedBox(height: 8),
          AsyncValueView<List<Subject>>(
            value: ref.watch(examSubjectsProvider(_classId!)),
            onRetry: () => ref.invalidate(examSubjectsProvider(_classId!)),
            data: (subs) => subs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('No subjects for this class yet.'),
                  )
                : Column(
                    children: [
                      for (final s in subs)
                        Card(
                          margin: const EdgeInsets.only(bottom: 6),
                          child: ListTile(
                            title: Text(s.name),
                            subtitle: s.isActive ? null : const Text('Off'),
                            trailing: Switch(
                              value: s.isActive,
                              onChanged: (v) => _run(
                                context,
                                ref,
                                () => ref
                                    .read(examRepositoryProvider)
                                    .saveSubject(s.id, {'isActive': v}),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
          ),
        ] else
          const EmptyView(
            icon: Icons.menu_book_outlined,
            message: 'Add a class under Classes and fee plans first.',
          ),
      ],
    );
  }
}

/// Which subjects an exam has for a class, and the maximum marks of each.
Future<void> showPapersDialog(
  BuildContext context,
  WidgetRef ref, {
  required String termId,
  required String classId,
  required String classLabel,
}) => showDialog<void>(
  context: context,
  builder: (ctx) =>
      _PapersDialog(termId: termId, classId: classId, label: classLabel),
);

class _PapersDialog extends ConsumerStatefulWidget {
  const _PapersDialog({
    required this.termId,
    required this.classId,
    required this.label,
  });
  final String termId;
  final String classId;
  final String label;
  @override
  ConsumerState<_PapersDialog> createState() => _PapersDialogState();
}

class _PapersDialogState extends ConsumerState<_PapersDialog> {
  final Map<String, bool> _on = {};
  final Map<String, TextEditingController> _max = {};
  final Map<String, TextEditingController> _pass = {};
  bool _ready = false;
  bool _saving = false;
  List<Subject> _subjects = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(examRepositoryProvider);
    try {
      _subjects = [
        for (final s in await repo.subjects(widget.classId))
          if (s.isActive) s,
      ];
      final papers = await repo.papers(widget.termId, widget.classId);
      for (final s in _subjects) {
        final p = papers.where((x) => x.subjectId == s.id).firstOrNull;
        _on[s.id] = p != null;
        _max[s.id] = TextEditingController(
          text: p == null ? '' : fmtMarks(p.maxMarks),
        );
        _pass[s.id] = TextEditingController(text: fmtMarks(p?.passMarks));
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _save() async {
    final papers = <Map<String, Object?>>[];
    for (final s in _subjects) {
      if (_on[s.id] != true) continue;
      final max = double.tryParse(_max[s.id]!.text.trim());
      if (max == null || max <= 0) {
        showErrorSnackBar(context, 'Enter the maximum marks for ${s.name}.');
        return;
      }
      papers.add({
        'subjectId': s.id,
        'maxMarks': max,
        'passMarks': double.tryParse(_pass[s.id]!.text.trim()),
      });
    }
    setState(() => _saving = true);
    try {
      await ref
          .read(examRepositoryProvider)
          .savePapers(widget.termId, widget.classId, papers);
      ref.read(examRevisionProvider(ExamKind.setup).notifier).bump();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Subjects and marks, ${widget.label}'),
    content: SizedBox(
      width: 460,
      child: !_ready
          ? const SizedBox(
              height: 80,
              child: Center(child: CircularProgressIndicator()),
            )
          : _subjects.isEmpty
          ? const Text('Add subjects for this class first (Subjects tab).')
          : SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final s in _subjects)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        children: [
                          Checkbox(
                            key: ValueKey('paper-on-${s.name}'),
                            value: _on[s.id],
                            onChanged: (v) =>
                                setState(() => _on[s.id] = v ?? false),
                          ),
                          Expanded(child: Text(s.name)),
                          SizedBox(
                            width: 72,
                            child: TextField(
                              key: ValueKey('paper-max-${s.name}'),
                              controller: _max[s.id],
                              enabled: _on[s.id] == true,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(
                                  RegExp(r'[0-9.]'),
                                ),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Max',
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 72,
                            child: TextField(
                              controller: _pass[s.id],
                              enabled: _on[s.id] == true,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'Pass',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving || !_ready || _subjects.isEmpty ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}

/// Edit the co-scholastic grade scale (for example A, B, C with labels).
Future<void> showCoScaleDialog(
  BuildContext context,
  WidgetRef ref,
  ExamSettings s,
) => showDialog<void>(
  context: context,
  builder: (ctx) => _CoScaleDialog(settings: s),
);

class _CoScaleDialog extends ConsumerStatefulWidget {
  const _CoScaleDialog({required this.settings});
  final ExamSettings settings;
  @override
  ConsumerState<_CoScaleDialog> createState() => _CoScaleDialogState();
}

class _CoScaleDialogState extends ConsumerState<_CoScaleDialog> {
  late final List<(TextEditingController, TextEditingController)> _rows = [
    for (final g in widget.settings.coGrades)
      (
        TextEditingController(text: g.grade),
        TextEditingController(text: g.label),
      ),
  ];
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(examRepositoryProvider).saveSettings({
        'coGrades': [
          for (final r in _rows)
            {'grade': r.$1.text.trim(), 'label': r.$2.text.trim()},
        ],
      });
      ref.read(examRevisionProvider(ExamKind.setup).notifier).bump();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Co-scholastic grades'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, r) in _rows.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 72,
                      child: TextField(
                        key: ValueKey('co-grade-$i'),
                        controller: r.$1,
                        decoration: const InputDecoration(labelText: 'Grade'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        key: ValueKey('co-label-$i'),
                        controller: r.$2,
                        decoration: const InputDecoration(labelText: 'Meaning'),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Remove grade',
                      onPressed: _rows.length <= 2
                          ? null
                          : () => setState(() => _rows.removeAt(i)),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _rows.length >= 6
                    ? null
                    : () => setState(
                        () => _rows.add((
                          TextEditingController(),
                          TextEditingController(),
                        )),
                      ),
                icon: const Icon(Icons.add),
                label: const Text('Add grade'),
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: const Text('Save'),
      ),
    ],
  );
}

/// Co-scholastic areas of a class: add, rename, remove and reorder, then save.
class CoAreasPanel extends ConsumerStatefulWidget {
  const CoAreasPanel({super.key});
  @override
  ConsumerState<CoAreasPanel> createState() => _CoAreasPanelState();
}

class _CoAreasPanelState extends ConsumerState<CoAreasPanel> {
  String? _classId;
  String? _loaded;
  List<TextEditingController> _rows = [];
  final _new = TextEditingController();
  bool _saving = false;

  void _load(List<String> areas) {
    _rows = [for (final a in areas) TextEditingController(text: a)];
    _loaded = _classId;
  }

  Future<void> _save() async {
    final names = [
      for (final c in _rows)
        if (c.text.trim().isNotEmpty) c.text.trim(),
    ];
    setState(() => _saving = true);
    try {
      await ref.read(examRepositoryProvider).saveCoAreas(_classId!, names);
      ref.read(examRevisionProvider(ExamKind.setup).notifier).bump();
      _loaded = null;
      if (mounted) showSuccess(context, 'Areas saved');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final classes = [
      for (final c in ref.watch(eduClassesProvider).value ?? const [])
        if (c.isActive) c,
    ];
    _classId ??= classes.isEmpty ? null : classes.first.id;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('area-class-$_classId'),
          initialValue: _classId,
          decoration: const InputDecoration(labelText: 'Class'),
          items: [
            for (final c in classes)
              DropdownMenuItem(value: c.id, child: Text(c.label)),
          ],
          onChanged: (v) => setState(() {
            _classId = v;
            _loaded = null;
          }),
        ),
        const SizedBox(height: 8),
        if (_classId != null)
          AsyncValueView<List<String>>(
            value: ref.watch(examCoAreasProvider(_classId!)),
            onRetry: () => ref.invalidate(examCoAreasProvider(_classId!)),
            data: (areas) {
              if (_loaded != _classId) _load(areas);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ReorderableListView(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    buildDefaultDragHandles: false,
                    onReorderItem: (o, n) => setState(() {
                      _rows.insert(n, _rows.removeAt(o));
                    }),
                    children: [
                      for (final (i, c) in _rows.indexed)
                        Padding(
                          key: ObjectKey(c),
                          padding: const EdgeInsets.only(bottom: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  key: ValueKey('area-$i'),
                                  controller: c,
                                  decoration: const InputDecoration(
                                    isDense: true,
                                  ),
                                ),
                              ),
                              IconButton(
                                tooltip: 'Move up',
                                onPressed: i == 0
                                    ? null
                                    : () => setState(
                                        () => _rows.insert(
                                          i - 1,
                                          _rows.removeAt(i),
                                        ),
                                      ),
                                icon: const Icon(Icons.arrow_upward),
                              ),
                              IconButton(
                                tooltip: 'Move down',
                                onPressed: i >= _rows.length - 1
                                    ? null
                                    : () => setState(
                                        () => _rows.insert(
                                          i + 1,
                                          _rows.removeAt(i),
                                        ),
                                      ),
                                icon: const Icon(Icons.arrow_downward),
                              ),
                              IconButton(
                                tooltip: 'Remove area',
                                onPressed: () =>
                                    setState(() => _rows.removeAt(i)),
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _new,
                          decoration: const InputDecoration(
                            labelText: 'New area',
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          if (_new.text.trim().isEmpty) return;
                          setState(() {
                            _rows.add(
                              TextEditingController(text: _new.text.trim()),
                            );
                            _new.clear();
                          });
                        },
                        child: const Text('Add'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: _saving ? null : _save,
                    child: const Text('Save areas'),
                  ),
                ],
              );
            },
          ),
      ],
    );
  }
}
