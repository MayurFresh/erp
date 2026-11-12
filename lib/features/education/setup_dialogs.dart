import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';

Widget _cancel(BuildContext context, bool saving) => TextButton(
  onPressed: saving ? null : () => Navigator.of(context).maybePop(),
  child: const Text('Cancel'),
);

/// Add or edit an academic year. Pops `true`.
class YearDialog extends ConsumerStatefulWidget {
  const YearDialog({super.key, this.year});

  final EduYear? year;

  @override
  ConsumerState<YearDialog> createState() => _YearDialogState();
}

class _YearDialogState extends ConsumerState<YearDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.year?.name);
  late DateTime? _start = parseApiDate(widget.year?.startDate);
  late DateTime? _end = parseApiDate(widget.year?.endDate);
  late bool _current = widget.year?.isCurrent ?? false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !validateAndReveal(_formKey)) return;
    if (_start == null || _end == null || !_end!.isAfter(_start!)) {
      showErrorSnackBar(context, 'Choose a start date and a later end date.');
      return;
    }
    setState(() => _saving = true);
    try {
      await ref.read(eduRepositoryProvider).saveYear(widget.year?.id, {
        'name': _name.text.trim(),
        'startDate': apiDate(_start!),
        'endDate': apiDate(_end!),
        'isCurrent': _current,
        if (widget.year != null) 'expectedUpdatedAt': widget.year!.updatedAt,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.year == null ? 'Add academic year' : 'Edit academic year',
    ),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                autofocus: widget.year == null,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: '2026-27',
                  errorText: serverError('name'),
                ),
                validator: (v) => requiredField(v, 'Name'),
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  DateField(
                    label: 'Starts',
                    value: _start,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                    onChanged: (d) => setState(() => _start = d),
                  ),
                  DateField(
                    label: 'Ends',
                    value: _end,
                    firstDate: DateTime(2000),
                    lastDate: DateTime(2100),
                    onChanged: (d) => setState(() => _end = d),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Current year'),
                value: _current,
                onChanged: (v) => setState(() => _current = v),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      _cancel(context, _saving),
      BusyButton(
        busy: _saving,
        onPressed: _saving ? null : _save,
        label: 'Save',
      ),
    ],
  );
}

/// Add or edit a class or batch. Pops `true`.
class ClassDialog extends ConsumerStatefulWidget {
  const ClassDialog({
    super.key,
    this.cls,
    this.years = const [],
    this.batch = false,
  });

  final EduClass? cls;
  final List<EduYear> years;
  final bool batch;

  @override
  ConsumerState<ClassDialog> createState() => _ClassDialogState();
}

class _ClassDialogState extends ConsumerState<ClassDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.cls?.name);
  late final _section = TextEditingController(text: widget.cls?.section);
  late final _course = TextEditingController(text: widget.cls?.course);
  late final _timing = TextEditingController(text: widget.cls?.timing);
  late final _teacherName = TextEditingController(
    text: widget.cls?.teacherName,
  );
  late final _capacity = TextEditingController(
    text: widget.cls?.capacity?.toString(),
  );
  late String? _yearId =
      widget.cls?.yearId ??
      (widget.years.where((y) => y.isCurrent).firstOrNull ??
              widget.years.firstOrNull)
          ?.id;
  late String? _teacherId = widget.cls?.teacherUserId;
  late bool _active = widget.cls?.isActive ?? true;
  bool _saving = false;

  bool get _batch => widget.cls?.isBatch ?? widget.batch;

  @override
  void dispose() {
    for (final c in [
      _name,
      _section,
      _course,
      _timing,
      _teacherName,
      _capacity,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    final editing = widget.cls != null;
    final body = <String, Object?>{
      'name': _name.text.trim(),
      'section': editing
          ? (trimmedOrNull(_section.text))
          : trimmedOrNull(_section.text),
      'course': trimmedOrNull(_course.text),
      'timing': trimmedOrNull(_timing.text),
      'teacherUserId': _teacherId,
      'teacherName': trimmedOrNull(_teacherName.text),
      'capacity': int.tryParse(_capacity.text.trim()),
      if (editing) 'isActive': _active,
      if (editing) 'expectedUpdatedAt': widget.cls!.updatedAt,
      if (!editing) 'yearId': _yearId,
      if (!editing) 'kind': _batch ? 'batch' : 'class',
    };
    try {
      await ref.read(eduRepositoryProvider).saveClass(widget.cls?.id, body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(eduStaffProvider).value ?? const [];
    final noun = _batch ? 'batch' : 'class';
    return AlertDialog(
      title: Text(widget.cls == null ? 'Add $noun' : 'Edit $noun'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (widget.cls == null) ...[
                  DropdownButtonFormField<String>(
                    initialValue: _yearId,
                    decoration: const InputDecoration(
                      labelText: 'Academic year',
                    ),
                    validator: (v) =>
                        v == null ? 'Add an academic year first' : null,
                    items: [
                      for (final y in widget.years)
                        DropdownMenuItem(value: y.id, child: Text(y.name)),
                    ],
                    onChanged: (v) => setState(() => _yearId = v),
                  ),
                  const SizedBox(height: 12),
                ],
                FormRow(
                  children: [
                    TextFormField(
                      controller: _name,
                      autofocus: widget.cls == null,
                      decoration: InputDecoration(
                        labelText: _batch ? 'Batch name' : 'Class',
                        hintText: _batch ? 'JEE morning' : 'Class 5',
                        errorText: serverError('name'),
                      ),
                      validator: (v) => requiredField(v, 'Name'),
                    ),
                    if (!_batch)
                      TextFormField(
                        controller: _section,
                        decoration: const InputDecoration(
                          labelText: 'Section',
                          hintText: 'A',
                        ),
                      ),
                  ],
                ),
                if (_batch) ...[
                  const SizedBox(height: 12),
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _course,
                        decoration: const InputDecoration(labelText: 'Course'),
                      ),
                      TextFormField(
                        controller: _timing,
                        decoration: const InputDecoration(
                          labelText: 'Timing',
                          hintText: '7 to 9 am',
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  key: ValueKey('teacher-$_teacherId-${staff.length}'),
                  initialValue: staff.any((p) => p.id == _teacherId)
                      ? _teacherId
                      : null,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Class teacher',
                    helperText: 'Can mark attendance for this class',
                  ),
                  items: [
                    const DropdownMenuItem<String?>(
                      value: null,
                      child: Text('None'),
                    ),
                    for (final p in staff)
                      DropdownMenuItem<String?>(
                        value: p.id,
                        child: Text(p.name),
                      ),
                  ],
                  onChanged: (v) => setState(() => _teacherId = v),
                ),
                const SizedBox(height: 12),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _teacherName,
                      decoration: const InputDecoration(
                        labelText: 'Teacher name for display',
                      ),
                    ),
                    TextFormField(
                      controller: _capacity,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Capacity'),
                    ),
                  ],
                ),
                if (widget.cls != null)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active'),
                    value: _active,
                    onChanged: (v) => setState(() => _active = v),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        _cancel(context, _saving),
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Save',
        ),
      ],
    );
  }
}

/// Add or edit a fee head. Pops `true`.
class HeadDialog extends ConsumerStatefulWidget {
  const HeadDialog({super.key, this.head});

  final FeeHead? head;

  @override
  ConsumerState<HeadDialog> createState() => _HeadDialogState();
}

class _HeadDialogState extends ConsumerState<HeadDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.head?.name);
  late final _gst = TextEditingController(
    text: formatPlain(widget.head?.gstRate ?? 0),
  );
  late bool _active = widget.head?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _gst.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(eduRepositoryProvider).saveHead(widget.head?.id, {
        'name': _name.text.trim(),
        'gstRate': parseNumber(_gst.text) ?? 0,
        if (widget.head != null) 'isActive': _active,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.head == null ? 'Add fee head' : 'Edit fee head'),
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                autofocus: widget.head == null,
                decoration: InputDecoration(
                  labelText: 'Name',
                  hintText: 'Tuition fee',
                  errorText: serverError('name'),
                ),
                validator: (v) => requiredField(v, 'Name'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _gst,
                keyboardType: decimalKeyboard,
                inputFormatters: [decimalInput()],
                decoration: InputDecoration(
                  labelText: 'GST rate (%)',
                  helperText:
                      'School tuition is exempt (0). Coaching is usually 18.',
                  errorText: serverError('gstRate'),
                ),
              ),
              if (widget.head != null)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      _cancel(context, _saving),
      BusyButton(
        busy: _saving,
        onPressed: _saving ? null : _save,
        label: 'Save',
      ),
    ],
  );
}

class _InstalmentEdit {
  _InstalmentEdit({String label = '', this.due, List<PlanLine>? lines})
    : label = TextEditingController(text: label),
      lines = [
        for (final l in lines ?? const <PlanLine>[])
          _LineEdit(l.headId, l.amount),
      ];

  final TextEditingController label;
  DateTime? due;
  final List<_LineEdit> lines;

  void dispose() {
    label.dispose();
    for (final l in lines) {
      l.dispose();
    }
  }
}

class _LineEdit {
  _LineEdit(this.headId, double amount)
    : amount = TextEditingController(
        text: amount > 0 ? formatPlain(amount) : '',
      );

  String? headId;
  final TextEditingController amount;

  void dispose() => amount.dispose();
}

/// The fee plan of one class: late fee rule and instalments with their heads.
/// Pops `true`.
class PlanDialog extends ConsumerStatefulWidget {
  const PlanDialog({super.key, required this.cls, this.plan});

  final EduClass cls;
  final FeePlan? plan;

  @override
  ConsumerState<PlanDialog> createState() => _PlanDialogState();
}

class _PlanDialogState extends ConsumerState<PlanDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _lateValue = TextEditingController(
    text: widget.plan == null || widget.plan!.lateKind == 'none'
        ? ''
        : formatPlain(widget.plan!.lateValue),
  );
  late String _lateKind = widget.plan?.lateKind ?? 'none';
  late String? _lateHead = widget.plan?.lateHeadId;
  late final List<_InstalmentEdit> _inst = [
    for (final i in widget.plan?.instalments ?? const <Instalment>[])
      _InstalmentEdit(
        label: i.label,
        due: parseApiDate(i.dueDate),
        lines: i.lines,
      ),
  ];
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (_inst.isEmpty) _inst.add(_InstalmentEdit(label: 'Term 1'));
  }

  @override
  void dispose() {
    _lateValue.dispose();
    for (final i in _inst) {
      i.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !validateAndReveal(_formKey)) return;
    for (final i in _inst) {
      if (i.due == null) {
        showErrorSnackBar(context, 'Choose a due date for ${i.label.text}.');
        return;
      }
      if (i.lines.isEmpty) {
        showErrorSnackBar(context, 'Add a fee head to ${i.label.text}.');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      await ref.read(eduRepositoryProvider).savePlan(widget.cls.id, {
        'name': '${widget.cls.label} fees',
        'late': {
          'kind': _lateKind,
          'value': _lateKind == 'none' ? 0 : parseNumber(_lateValue.text) ?? 0,
          'headId': _lateKind == 'none' ? null : _lateHead,
        },
        'instalments': [
          for (final i in _inst)
            {
              'label': i.label.text.trim(),
              'dueDate': apiDate(i.due!),
              'lines': [
                for (final l in i.lines)
                  {'headId': l.headId, 'amount': parseNumber(l.amount.text)},
              ],
            },
        ],
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final heads = [
      for (final h in ref.watch(eduHeadsProvider).value ?? const <FeeHead>[])
        if (h.isActive) h,
    ];
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text('Fee plan, ${widget.cls.label}'),
      content: SizedBox(
        width: 680,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final (n, i) in _inst.indexed) ...[
                  Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FormRow(
                            children: [
                              TextFormField(
                                controller: i.label,
                                decoration: const InputDecoration(
                                  labelText: 'Instalment',
                                ),
                                validator: (v) => requiredField(v, 'Name'),
                              ),
                              DateField(
                                label: 'Due date',
                                value: i.due,
                                firstDate: DateTime(2000),
                                lastDate: DateTime(2100),
                                onChanged: (d) => setState(() => i.due = d),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          for (final (k, l) in i.lines.indexed)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    flex: 3,
                                    child: DropdownButtonFormField<String>(
                                      key: ValueKey('h-$n-$k-${l.headId}'),
                                      initialValue:
                                          heads.any((h) => h.id == l.headId)
                                          ? l.headId
                                          : null,
                                      isExpanded: true,
                                      decoration: const InputDecoration(
                                        labelText: 'Fee head',
                                      ),
                                      validator: (v) =>
                                          v == null ? 'Choose' : null,
                                      items: [
                                        for (final h in heads)
                                          DropdownMenuItem(
                                            value: h.id,
                                            child: Text(
                                              h.name,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                      ],
                                      onChanged: (v) =>
                                          setState(() => l.headId = v),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    flex: 2,
                                    child: TextFormField(
                                      controller: l.amount,
                                      keyboardType: decimalKeyboard,
                                      inputFormatters: [decimalInput()],
                                      decoration: const InputDecoration(
                                        labelText: 'Amount',
                                      ),
                                      validator: (v) =>
                                          (parseNumber(v ?? '') ?? 0) <= 0
                                          ? 'Enter'
                                          : null,
                                    ),
                                  ),
                                  IconButton(
                                    tooltip: 'Remove head',
                                    icon: const Icon(Icons.close),
                                    onPressed: () => setState(() {
                                      i.lines.removeAt(k).dispose();
                                    }),
                                  ),
                                ],
                              ),
                            ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton.icon(
                                onPressed: heads.isEmpty
                                    ? null
                                    : () => setState(
                                        () => i.lines.add(_LineEdit(null, 0)),
                                      ),
                                icon: const Icon(Icons.add),
                                label: const Text('Add fee head'),
                              ),
                              if (_inst.length > 1)
                                TextButton.icon(
                                  onPressed: () => setState(() {
                                    _inst.removeAt(n).dispose();
                                  }),
                                  icon: const Icon(Icons.delete_outline),
                                  label: const Text('Remove instalment'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: () => setState(() {
                      final last = _inst.last;
                      _inst.add(
                        _InstalmentEdit(
                          label: 'Term ${_inst.length + 1}',
                          lines: [
                            for (final l in last.lines)
                              PlanLine(
                                l.headId ?? '',
                                parseNumber(l.amount.text) ?? 0,
                              ),
                          ],
                        ),
                      );
                    }),
                    icon: const Icon(Icons.add),
                    label: const Text('Add instalment (copies the last)'),
                  ),
                ),
                const SizedBox(height: 16),
                Text('Late fee', style: theme.textTheme.titleSmall),
                const SizedBox(height: 8),
                FormRow(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _lateKind,
                      decoration: const InputDecoration(labelText: 'Rule'),
                      items: const [
                        DropdownMenuItem(
                          value: 'none',
                          child: Text('No late fee'),
                        ),
                        DropdownMenuItem(
                          value: 'flat',
                          child: Text('Flat amount'),
                        ),
                        DropdownMenuItem(
                          value: 'percent',
                          child: Text('Percent of the instalment'),
                        ),
                        DropdownMenuItem(
                          value: 'per_day',
                          child: Text('Amount per day late'),
                        ),
                      ],
                      onChanged: (v) => setState(() => _lateKind = v ?? 'none'),
                    ),
                    if (_lateKind != 'none')
                      TextFormField(
                        controller: _lateValue,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput()],
                        decoration: InputDecoration(
                          labelText: _lateKind == 'percent'
                              ? 'Percent'
                              : 'Amount',
                        ),
                        validator: (v) => (parseNumber(v ?? '') ?? 0) <= 0
                            ? 'Enter a number'
                            : null,
                      ),
                  ],
                ),
                if (_lateKind != 'none') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: heads.any((h) => h.id == _lateHead)
                        ? _lateHead
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Fee head for the late fee',
                      helperText: 'Add a head named Late fee in Fee heads',
                    ),
                    validator: (v) => v == null ? 'Choose a head' : null,
                    items: [
                      for (final h in heads)
                        DropdownMenuItem(value: h.id, child: Text(h.name)),
                    ],
                    onChanged: (v) => setState(() => _lateHead = v),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        _cancel(context, _saving),
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Save plan',
        ),
      ],
    );
  }
}

/// Moves a class to the next class, or marks it passed out. Pops `true`.
class PromoteDialog extends ConsumerStatefulWidget {
  const PromoteDialog({super.key, required this.from});

  final EduClass from;

  @override
  ConsumerState<PromoteDialog> createState() => _PromoteDialogState();
}

class _PromoteDialogState extends ConsumerState<PromoteDialog> {
  String? _toId;
  bool _passOut = false;
  bool _saving = false;

  Future<void> _go() async {
    if (_saving) return;
    if (!_passOut && _toId == null) {
      showErrorSnackBar(context, 'Choose the next class.');
      return;
    }
    setState(() => _saving = true);
    try {
      final n = await ref.read(eduRepositoryProvider).promote({
        'fromClassId': widget.from.id,
        if (_passOut) 'passOut': true else 'toClassId': _toId,
      });
      if (mounted) {
        showSuccess(context, '$n students moved');
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Promote ${widget.from.label}'),
    content: SizedBox(
      width: 440,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Moves all ${widget.from.students} active students to the class you choose. '
            'Roll numbers are cleared. Add the next class under the new academic year first.',
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Last class: mark as passed out'),
            value: _passOut,
            onChanged: (v) => setState(() => _passOut = v),
          ),
          if (!_passOut)
            ClassDropdown(
              value: _toId,
              label: 'Next class',
              exclude: widget.from.id,
              onChanged: (v) => setState(() => _toId = v),
            ),
        ],
      ),
    ),
    actions: [
      _cancel(context, _saving),
      BusyButton(
        busy: _saving,
        onPressed: _saving ? null : _go,
        label: 'Promote',
      ),
    ],
  );
}
