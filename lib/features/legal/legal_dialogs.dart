import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'legal_models.dart';
import 'legal_repository.dart';

const _dialogWidth = 560.0;

Widget _gap() => const SizedBox(height: 12);

/// Create or edit a matter. Pops the saved [Matter].
class MatterFormDialog extends ConsumerStatefulWidget {
  const MatterFormDialog({super.key, this.matter, required this.canManage});

  final Matter? matter;
  final bool canManage;

  @override
  ConsumerState<MatterFormDialog> createState() => _MatterFormDialogState();
}

class _MatterFormDialogState extends ConsumerState<MatterFormDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.matter?.title);
  late final _opposing = TextEditingController(
    text: widget.matter?.opposingParty,
  );
  late final _court = TextEditingController(text: widget.matter?.court);
  late final _caseType = TextEditingController(text: widget.matter?.caseType);
  late final _caseNo = TextEditingController(text: widget.matter?.caseNo);
  late final _caseYear = TextEditingController(
    text: widget.matter?.caseYear?.toString(),
  );
  late final _stage = TextEditingController(text: widget.matter?.stage);
  late final _fee = TextEditingController(
    text: (widget.matter?.agreedFee ?? 0) > 0
        ? formatPlain(widget.matter!.agreedFee)
        : '',
  );
  late final _rate = TextEditingController(
    text: widget.matter?.hourlyRate == null
        ? ''
        : formatPlain(widget.matter!.hourlyRate),
  );
  late final _notes = TextEditingController(text: widget.matter?.notes);
  late String? _clientId = widget.matter?.clientId;
  late String? _clientName = widget.matter?.clientName;
  late DateTime? _filing = parseApiDate(widget.matter?.filingDate);
  late String _feeType = widget.matter?.feeType ?? 'hourly';
  late String? _advocateId = widget.matter?.advocateId;
  late final Set<String> _team = {
    for (final p in widget.matter?.team ?? const <Person>[]) p.id,
  };
  bool _saving = false;

  bool get _editing => widget.matter != null;

  @override
  void dispose() {
    for (final c in [
      _title,
      _opposing,
      _court,
      _caseType,
      _caseNo,
      _caseYear,
      _stage,
      _fee,
      _rate,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickClient() async {
    final p = await pickParty(context, ref, type: PartyType.customer);
    if (p != null) {
      setState(() {
        _clientId = p.id;
        _clientName = p.name;
      });
    }
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    final repo = ref.read(legalRepositoryProvider);
    final body = <String, Object?>{
      'title': _title.text.trim(),
      'clientId': _clientId,
      'opposingParty': trimmedOrNull(_opposing.text),
      'court': trimmedOrNull(_court.text),
      'caseType': trimmedOrNull(_caseType.text),
      'caseNo': trimmedOrNull(_caseNo.text),
      'caseYear': int.tryParse(_caseYear.text.trim()),
      'filingDate': _filing == null ? null : apiDate(_filing!),
      'stage': trimmedOrNull(_stage.text),
      'feeType': _feeType,
      'agreedFee': _feeType == 'hourly' ? 0 : parseNumber(_fee.text) ?? 0,
      'hourlyRate': _feeType == 'hourly' ? parseNumber(_rate.text) : null,
      'notes': trimmedOrNull(_notes.text),
      if (widget.canManage && _advocateId != null) 'advocateId': _advocateId,
      if (widget.canManage || !_editing) 'teamIds': _team.toList(),
      if (_editing) 'expectedUpdatedAt': widget.matter!.updatedAt,
    };
    try {
      final saved = await repo.saveMatter(widget.matter?.id, body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(legalStaffProvider).value ?? const <Person>[];
    return AlertDialog(
      title: Text(_editing ? 'Edit matter' : 'New matter'),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _title,
                  autofocus: !_editing,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: 'Matter title',
                    errorText: serverError('title'),
                  ),
                  validator: (v) => requiredField(v, 'Title'),
                ),
                _gap(),
                PickerField(
                  label: 'Client',
                  value: _clientName,
                  errorText: serverError('clientId'),
                  validator: () => _clientId == null ? 'Choose a client' : null,
                  onTap: _pickClient,
                ),
                _gap(),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _opposing,
                      decoration: const InputDecoration(
                        labelText: 'Opposing party',
                      ),
                    ),
                    TextFormField(
                      controller: _court,
                      decoration: const InputDecoration(
                        labelText: 'Court or forum',
                      ),
                    ),
                  ],
                ),
                _gap(),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _caseType,
                      decoration: const InputDecoration(labelText: 'Case type'),
                    ),
                    TextFormField(
                      controller: _stage,
                      decoration: const InputDecoration(labelText: 'Stage'),
                    ),
                  ],
                ),
                _gap(),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _caseNo,
                      decoration: const InputDecoration(
                        labelText: 'Case number',
                      ),
                    ),
                    TextFormField(
                      controller: _caseYear,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(4),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Case year',
                        errorText: serverError('caseYear'),
                      ),
                    ),
                  ],
                ),
                _gap(),
                DateField(
                  label: 'Filing date',
                  value: _filing,
                  lastDate: today(),
                  firstDate: DateTime(1990),
                  onChanged: (d) => setState(() => _filing = d),
                  onCleared: () => setState(() => _filing = null),
                ),
                _gap(),
                FormRow(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _feeType,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Fee arrangement',
                      ),
                      items: [
                        for (final e in feeTypes.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) =>
                          setState(() => _feeType = v ?? 'hourly'),
                    ),
                    if (_feeType == 'hourly')
                      TextFormField(
                        controller: _rate,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput()],
                        decoration: InputDecoration(
                          labelText: 'Hourly rate',
                          helperText: 'Used when the person has no rate',
                          errorText: serverError('hourlyRate'),
                        ),
                      )
                    else
                      TextFormField(
                        controller: _fee,
                        keyboardType: decimalKeyboard,
                        inputFormatters: [decimalInput()],
                        decoration: InputDecoration(
                          labelText: _feeType == 'per_hearing'
                              ? 'Fee per hearing'
                              : _feeType == 'retainer'
                              ? 'Retainer'
                              : 'Agreed fee',
                          errorText: serverError('agreedFee'),
                        ),
                      ),
                  ],
                ),
                if (widget.canManage) ...[
                  _gap(),
                  DropdownButtonFormField<String?>(
                    initialValue: staff.any((p) => p.id == _advocateId)
                        ? _advocateId
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Responsible advocate',
                    ),
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Me')),
                      for (final p in staff)
                        DropdownMenuItem(value: p.id, child: Text(p.name)),
                    ],
                    onChanged: (v) => setState(() => _advocateId = v),
                  ),
                ],
                if (staff.isNotEmpty && (widget.canManage || !_editing)) ...[
                  _gap(),
                  Text('Team', style: Theme.of(context).textTheme.labelLarge),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final p in staff)
                        FilterChip(
                          label: Text(p.name),
                          selected: _team.contains(p.id),
                          onSelected: (on) => setState(
                            () => on ? _team.add(p.id) : _team.remove(p.id),
                          ),
                        ),
                    ],
                  ),
                ],
                _gap(),
                TextFormField(
                  controller: _notes,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Notes'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving' : 'Save'),
        ),
      ],
    );
  }
}

/// Add a hearing to a matter. Pops `true`.
class HearingDialog extends ConsumerStatefulWidget {
  const HearingDialog({super.key, required this.matter});

  final Matter matter;

  @override
  ConsumerState<HearingDialog> createState() => _HearingDialogState();
}

class _HearingDialogState extends ConsumerState<HearingDialog>
    with ServerFieldErrors {
  late final _court = TextEditingController(text: widget.matter.court);
  final _purpose = TextEditingController();
  DateTime _date = today();
  bool _saving = false;

  @override
  void dispose() {
    _court.dispose();
    _purpose.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await ref.read(legalRepositoryProvider).addHearing(widget.matter.id, {
        'hearingDate': apiDate(_date),
        'court': trimmedOrNull(_court.text),
        'purpose': trimmedOrNull(_purpose.text),
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
    title: const Text('Add hearing'),
    content: SizedBox(
      width: _dialogWidth,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DateField(
              label: 'Hearing date',
              value: _date,
              firstDate: DateTime(2000),
              lastDate: today().add(const Duration(days: 730)),
              errorText: serverError('hearingDate'),
              onChanged: (d) => setState(() => _date = d),
            ),
            _gap(),
            TextFormField(
              controller: _court,
              decoration: const InputDecoration(labelText: 'Court'),
            ),
            _gap(),
            TextFormField(
              controller: _purpose,
              decoration: const InputDecoration(
                labelText: 'Purpose, for example arguments',
              ),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? 'Saving' : 'Add hearing'),
      ),
    ],
  );
}

/// Record what happened at a hearing and, usually, the next date. Pops the
/// server warning (empty when a next date was set).
class OutcomeDialog extends ConsumerStatefulWidget {
  const OutcomeDialog({
    super.key,
    required this.hearingId,
    required this.matterTitle,
    required this.hearingDate,
  });

  final String hearingId;
  final String matterTitle;
  final String hearingDate;

  @override
  ConsumerState<OutcomeDialog> createState() => _OutcomeDialogState();
}

class _OutcomeDialogState extends ConsumerState<OutcomeDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _outcome = TextEditingController();
  final _purpose = TextEditingController();
  final _stage = TextEditingController();
  DateTime? _next;
  bool _saving = false;

  @override
  void dispose() {
    _outcome.dispose();
    _purpose.dispose();
    _stage.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final warning = await ref
          .read(legalRepositoryProvider)
          .recordOutcome(widget.hearingId, {
            'outcome': _outcome.text.trim(),
            'nextDate': _next == null ? null : apiDate(_next!),
            'nextPurpose': trimmedOrNull(_purpose.text),
            'stage': trimmedOrNull(_stage.text),
          });
      if (mounted) Navigator.of(context).pop(warning ?? '');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final first = parseApiDate(widget.hearingDate) ?? today();
    return AlertDialog(
      title: const Text('Record hearing outcome'),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${widget.matterTitle}, ${formatDate(widget.hearingDate)}',
                  style: theme.textTheme.bodyMedium,
                ),
                _gap(),
                TextFormField(
                  controller: _outcome,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'What happened',
                    errorText: serverError('outcome'),
                  ),
                  validator: (v) => requiredField(v, 'Outcome'),
                ),
                _gap(),
                DateField(
                  label: 'Next date',
                  value: _next,
                  firstDate: first,
                  lastDate: first.add(const Duration(days: 1095)),
                  errorText: serverError('nextDate'),
                  onChanged: (d) => setState(() => _next = d),
                  onCleared: () => setState(() => _next = null),
                ),
                if (_next == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'No next date. The matter will show under "No next date" until you add one.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                _gap(),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _purpose,
                      enabled: _next != null,
                      decoration: const InputDecoration(
                        labelText: 'Purpose of next date',
                      ),
                    ),
                    TextFormField(
                      controller: _stage,
                      decoration: const InputDecoration(
                        labelText: 'Update stage',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving' : 'Save outcome'),
        ),
      ],
    );
  }
}

/// Add a task or deadline. Pops `true`.
class TaskDialog extends ConsumerStatefulWidget {
  const TaskDialog({super.key, required this.matterId});

  final String matterId;

  @override
  ConsumerState<TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends ConsumerState<TaskDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _title = TextEditingController();
  String _kind = 'filing';
  DateTime _due = today().add(const Duration(days: 7));
  String? _assignee;
  bool _saving = false;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(legalRepositoryProvider).addTask(widget.matterId, {
        'title': _title.text.trim(),
        'kind': _kind,
        'dueDate': apiDate(_due),
        if (_assignee != null) 'assigneeId': _assignee,
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final staff = ref.watch(legalStaffProvider).value ?? const <Person>[];
    return AlertDialog(
      title: const Text('Add task or deadline'),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _title,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: 'What is due',
                    errorText: serverError('title'),
                  ),
                  validator: (v) => requiredField(v, 'Title'),
                ),
                _gap(),
                FormRow(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _kind,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Kind'),
                      items: [
                        for (final e in taskKinds.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => _kind = v ?? 'other'),
                    ),
                    DateField(
                      label: 'Due date',
                      value: _due,
                      firstDate: DateTime(2000),
                      lastDate: today().add(const Duration(days: 3650)),
                      onChanged: (d) => setState(() => _due = d),
                    ),
                  ],
                ),
                _gap(),
                DropdownButtonFormField<String?>(
                  initialValue: _assignee,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Assigned to'),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('No one')),
                    for (final p in staff)
                      DropdownMenuItem(value: p.id, child: Text(p.name)),
                  ],
                  onChanged: (v) => setState(() => _assignee = v),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving' : 'Add'),
        ),
      ],
    );
  }
}

/// Time, fee or court-expense entry with a simple timer. Pops `true`.
class EntryDialog extends ConsumerStatefulWidget {
  const EntryDialog({super.key, required this.matter, required this.canAddFee});

  final Matter matter;
  final bool canAddFee;

  @override
  ConsumerState<EntryDialog> createState() => _EntryDialogState();
}

class _EntryDialogState extends ConsumerState<EntryDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _minutes = TextEditingController();
  final _amount = TextEditingController();
  final _rate = TextEditingController();
  final _desc = TextEditingController();
  String _kind = 'time';
  String _disb = 'court_fee';
  bool _billable = true;
  DateTime _date = today();
  Timer? _ticker;
  DateTime? _startedAt;
  int _elapsed = 0;
  bool _saving = false;

  @override
  void dispose() {
    _ticker?.cancel();
    for (final c in [_minutes, _amount, _rate, _desc]) {
      c.dispose();
    }
    super.dispose();
  }

  void _toggleTimer() {
    if (_ticker != null) {
      _ticker!.cancel();
      _ticker = null;
      // Round up so a short stretch of work is never recorded as nothing.
      final mins = (_elapsed / 60).ceil().clamp(1, 1440);
      setState(() => _minutes.text = '$mins');
      return;
    }
    _startedAt = DateTime.now();
    _elapsed = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(
        () => _elapsed = DateTime.now().difference(_startedAt!).inSeconds,
      );
    });
    setState(() {});
  }

  String get _clock {
    final m = _elapsed ~/ 60, s = _elapsed % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (_ticker != null) _toggleTimer();
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    final body = <String, Object?>{
      'kind': _kind,
      'description': _desc.text.trim(),
      'entryDate': apiDate(_date),
      'billable': _billable,
      if (_kind == 'time') 'minutes': int.tryParse(_minutes.text.trim()),
      if (_kind == 'time' && _rate.text.trim().isNotEmpty)
        'rate': parseNumber(_rate.text),
      if (_kind != 'time') 'amount': parseNumber(_amount.text),
      if (_kind == 'disbursement') 'disbType': _disb,
    };
    try {
      await ref.read(legalRepositoryProvider).addEntry(widget.matter.id, body);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _ticker != null;
    return AlertDialog(
      title: const Text('Add time or expense'),
      content: SizedBox(
        width: _dialogWidth,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<String>(
                  showSelectedIcon: false,
                  segments: [
                    const ButtonSegment(value: 'time', label: Text('Time')),
                    if (widget.canAddFee)
                      const ButtonSegment(value: 'fee', label: Text('Fee')),
                    const ButtonSegment(
                      value: 'disbursement',
                      label: Text('Expense'),
                    ),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => setState(() => _kind = s.first),
                ),
                _gap(),
                TextFormField(
                  controller: _desc,
                  autofocus: true,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    labelText: 'Description',
                    errorText: serverError('description'),
                  ),
                  validator: (v) => requiredField(v, 'Description'),
                ),
                _gap(),
                if (_kind == 'time') ...[
                  TextFormField(
                    controller: _minutes,
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(4),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Minutes',
                      errorText: serverError('minutes'),
                    ),
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return n == null || n < 1 || n > 1440
                          ? 'Enter 1 to 1440'
                          : null;
                    },
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: _toggleTimer,
                      icon: Icon(
                        running
                            ? Icons.stop_circle_outlined
                            : Icons.timer_outlined,
                      ),
                      label: Text(running ? 'Stop $_clock' : 'Start timer'),
                    ),
                  ),
                  _gap(),
                  TextFormField(
                    controller: _rate,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    decoration: InputDecoration(
                      labelText: 'Hourly rate',
                      helperText: 'Leave blank to use your rate',
                      errorText: serverError('rate'),
                    ),
                  ),
                ] else ...[
                  if (_kind == 'disbursement') ...[
                    DropdownButtonFormField<String>(
                      initialValue: _disb,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Expense type',
                      ),
                      items: [
                        for (final e in disbTypes.entries)
                          DropdownMenuItem(value: e.key, child: Text(e.value)),
                      ],
                      onChanged: (v) => setState(() => _disb = v ?? 'other'),
                    ),
                    _gap(),
                  ],
                  TextFormField(
                    controller: _amount,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    decoration: InputDecoration(
                      labelText: 'Amount',
                      errorText: serverError('amount'),
                    ),
                    validator: (v) => (parseNumber(v ?? '') ?? 0) <= 0
                        ? 'Enter an amount'
                        : null,
                  ),
                ],
                _gap(),
                DateField(
                  label: 'Date',
                  value: _date,
                  firstDate: DateTime(2000),
                  lastDate: today(),
                  onChanged: (d) => setState(() => _date = d),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _billable,
                  onChanged: (v) => setState(() => _billable = v),
                  title: const Text('Bill the client'),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? 'Saving' : 'Save'),
        ),
      ],
    );
  }
}

/// Choose unbilled entries and raise the fee bill. Pops the invoice number.
class BillDialog extends ConsumerStatefulWidget {
  const BillDialog({super.key, required this.matter, required this.entries});

  final Matter matter;
  final List<Entry> entries;

  @override
  ConsumerState<BillDialog> createState() => _BillDialogState();
}

class _BillDialogState extends ConsumerState<BillDialog> {
  late final Set<String> _chosen = {for (final e in widget.entries) e.id};
  bool _reverse = false;
  bool _saving = false;

  double get _total => widget.entries
      .where((e) => _chosen.contains(e.id))
      .fold(0, (s, e) => s + e.amount);
  double get _fees => widget.entries
      .where((e) => _chosen.contains(e.id) && e.kind != 'disbursement')
      .fold(0, (s, e) => s + e.amount);

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final number = await ref.read(legalRepositoryProvider).bill(
        widget.matter.id,
        {'entryIds': _chosen.toList(), if (_reverse) 'reverseCharge': true},
      );
      if (mounted) Navigator.of(context).pop(number);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasGstin = (widget.matter.clientGstin ?? '').isNotEmpty;
    final gst = _reverse ? 0.0 : _fees * 0.18;
    return AlertDialog(
      title: const Text('Bill from unbilled items'),
      content: SizedBox(
        width: _dialogWidth,
        child: widget.entries.isEmpty
            ? const Text('Nothing to bill. Add time, fees or expenses first.')
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      value: _chosen.length == widget.entries.length,
                      onChanged: (on) => setState(() {
                        _chosen.clear();
                        if (on == true) {
                          _chosen.addAll(widget.entries.map((e) => e.id));
                        }
                      }),
                      title: const Text('Select all'),
                    ),
                    const Divider(height: 1),
                    for (final e in widget.entries)
                      CheckboxListTile(
                        key: ValueKey('bill-${e.id}'),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                        value: _chosen.contains(e.id),
                        onChanged: (on) => setState(
                          () => on == true
                              ? _chosen.add(e.id)
                              : _chosen.remove(e.id),
                        ),
                        title: Text(
                          e.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${formatDate(e.date)}  |  ${e.kindLabel}',
                        ),
                        secondary: Text(formatMoney(e.amount)),
                      ),
                    const Divider(height: 1),
                    if (hasGstin)
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        value: _reverse,
                        onChanged: (v) => setState(() => _reverse = v),
                        title: const Text('Reverse charge'),
                        subtitle: const Text(
                          'No GST on the bill; the client pays it. Expenses are always without GST.',
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'Selected ${formatMoney(_total)}',
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      _reverse
                          ? 'Reverse charge: GST is not added.'
                          : 'GST at 18% on fees: about ${formatMoney(gst)}. The bill shows the exact total.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || _chosen.isEmpty ? null : _save,
          child: Text(_saving ? 'Creating' : 'Create bill'),
        ),
      ],
    );
  }
}

/// Record an advance or a receipt against a bill. Pops `true`.
class ReceiptDialog extends ConsumerStatefulWidget {
  const ReceiptDialog({super.key, required this.matter, required this.bills});

  final Matter matter;
  final List<BillRow> bills;

  @override
  ConsumerState<ReceiptDialog> createState() => _ReceiptDialogState();
}

class _ReceiptDialogState extends ConsumerState<ReceiptDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _amount = TextEditingController();
  final _reference = TextEditingController();
  late String _kind = _open.isEmpty ? 'advance' : 'fee';
  String? _invoiceId;
  String? _accountId;
  String _mode = 'bank';
  List<(String, String)> _accounts = const [];
  bool _saving = false;

  List<BillRow> get _open =>
      widget.bills.where((b) => b.status == 'posted' && b.due > 0.004).toList();

  @override
  void initState() {
    super.initState();
    _invoiceId = _open.isEmpty ? null : _open.first.invoiceId;
    ref.read(legalRepositoryProvider).cashAccounts().then((a) {
      if (mounted) {
        setState(() {
          _accounts = a;
          _accountId = a.isEmpty ? null : a.first.$1;
        });
      }
    });
  }

  @override
  void dispose() {
    _amount.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(legalRepositoryProvider).receipt(widget.matter.id, {
        'kind': _kind,
        'amount': parseNumber(_amount.text),
        'accountId': _accountId,
        'mode': _mode,
        'reference': trimmedOrNull(_reference.text),
        if (_kind == 'fee') 'invoiceId': _invoiceId,
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
    title: const Text('Record receipt'),
    content: SizedBox(
      width: _dialogWidth,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: 'fee',
                    label: const Text('Against a bill'),
                    enabled: _open.isNotEmpty,
                  ),
                  const ButtonSegment(value: 'advance', label: Text('Advance')),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
              _gap(),
              if (_kind == 'fee') ...[
                DropdownButtonFormField<String>(
                  initialValue: _invoiceId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Bill'),
                  items: [
                    for (final b in _open)
                      DropdownMenuItem(
                        value: b.invoiceId,
                        child: Text(
                          '${b.number}, due ${formatMoney(b.due)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (v) => setState(() => _invoiceId = v),
                ),
                _gap(),
              ],
              TextFormField(
                controller: _amount,
                autofocus: true,
                keyboardType: decimalKeyboard,
                inputFormatters: [decimalInput()],
                decoration: InputDecoration(
                  labelText: 'Amount received',
                  errorText: serverError('amount'),
                ),
                validator: (v) =>
                    (parseNumber(v ?? '') ?? 0) <= 0 ? 'Enter an amount' : null,
              ),
              _gap(),
              FormRow(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _accountId,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Paid into'),
                    items: [
                      for (final a in _accounts)
                        DropdownMenuItem(
                          value: a.$1,
                          child: Text(a.$2, overflow: TextOverflow.ellipsis),
                        ),
                    ],
                    onChanged: (v) => setState(() => _accountId = v),
                    validator: (v) => v == null ? 'Choose an account' : null,
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: _mode,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: 'Mode'),
                    items: const [
                      DropdownMenuItem(
                        value: 'bank',
                        child: Text('Bank transfer'),
                      ),
                      DropdownMenuItem(value: 'upi', child: Text('UPI')),
                      DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
                      DropdownMenuItem(value: 'cash', child: Text('Cash')),
                      DropdownMenuItem(value: 'card', child: Text('Card')),
                    ],
                    onChanged: (v) => setState(() => _mode = v ?? 'bank'),
                  ),
                ],
              ),
              _gap(),
              TextFormField(
                controller: _reference,
                decoration: const InputDecoration(labelText: 'Reference'),
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? 'Saving' : 'Save receipt'),
      ),
    ],
  );
}
