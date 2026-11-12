import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'education_models.dart';
import 'education_repository.dart';
import 'education_widgets.dart';

/// Admit a student, or edit one when [student] is given. Pops the saved
/// [Student].
class StudentFormDialog extends ConsumerStatefulWidget {
  const StudentFormDialog({super.key, this.student, this.classId});

  final Student? student;
  final String? classId;

  @override
  ConsumerState<StudentFormDialog> createState() => _StudentFormDialogState();
}

class _StudentFormDialogState extends ConsumerState<StudentFormDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.student?.name);
  late final _roll = TextEditingController(text: widget.student?.brief.rollNo);
  late final _guardian = TextEditingController(
    text: widget.student?.brief.guardianName,
  );
  late final _relation = TextEditingController(
    text: widget.student?.guardianRelation,
  );
  late final _phone = TextEditingController(
    text: widget.student?.brief.guardianPhone,
  );
  late final _address = TextEditingController(text: widget.student?.address);
  late final _notes = TextEditingController(text: widget.student?.notes);
  late String _sex = widget.student?.brief.sex ?? 'male';
  late String? _classId = widget.student?.brief.classId ?? widget.classId;
  late DateTime? _dob = parseApiDate(widget.student?.dob);
  bool _saving = false;

  bool get _editing => widget.student != null;

  @override
  void dispose() {
    for (final c in [
      _name,
      _roll,
      _guardian,
      _relation,
      _phone,
      _address,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool force = false}) async {
    if (_saving) return;
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    final repo = ref.read(eduRepositoryProvider);
    final body = <String, Object?>{
      'name': _name.text.trim(),
      'sex': _sex,
      'classId': _classId,
      'rollNo': trimmedOrNull(_roll.text),
      if (_dob != null) 'dob': apiDate(_dob!),
      'guardianName': _guardian.text.trim(),
      'guardianRelation': trimmedOrNull(_relation.text),
      'guardianPhone': _phone.text.trim(),
      'address': trimmedOrNull(_address.text),
      'notes': trimmedOrNull(_notes.text),
      if (force) 'force': true,
    };
    try {
      final saved = _editing
          ? await repo.updateStudent(widget.student!.id, {
              ...body,
              'expectedUpdatedAt': widget.student!.updatedAt,
            })
          : await repo.admit(body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      final api = apiError(e);
      if (api?.code == 'DUPLICATE_STUDENT' && mounted) {
        setState(() => _saving = false);
        if (await _confirmDuplicate(api!)) await _save(force: true);
        return;
      }
      if (mounted) {
        showSubmitError(
          e,
          onReload: () =>
              ref.invalidate(eduStudentProvider(widget.student!.id)),
        );
      }
    } finally {
      if (mounted && _saving) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDuplicate(ApiException e) async {
    final matches = asJsonList(e.details['matches']);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Possible duplicate'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(e.message),
              const SizedBox(height: 8),
              for (final m in matches)
                Text('${asString(m['name'])}  ${asString(m['admission_no'])}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Go back'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Admit anyway'),
          ),
        ],
      ),
    );
    return ok == true;
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_editing ? 'Edit student' : 'Admit student'),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                autofocus: !_editing,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Student name',
                  errorText: serverError('name'),
                ),
                validator: (v) => requiredField(v, 'Name'),
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  ClassDropdown(
                    value: _classId,
                    allowAll: true,
                    label: 'Class or batch',
                    errorText: serverError('classId'),
                    onChanged: (v) => setState(() => _classId = v),
                  ),
                  TextFormField(
                    controller: _roll,
                    decoration: InputDecoration(
                      labelText: 'Roll number',
                      errorText: serverError('rollNo'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _sex,
                    decoration: const InputDecoration(labelText: 'Sex'),
                    items: const [
                      DropdownMenuItem(value: 'male', child: Text('Male')),
                      DropdownMenuItem(value: 'female', child: Text('Female')),
                      DropdownMenuItem(value: 'other', child: Text('Other')),
                    ],
                    onChanged: (v) => setState(() => _sex = v ?? 'male'),
                  ),
                  DateField(
                    label: 'Date of birth',
                    value: _dob,
                    firstDate: DateTime(1990),
                    lastDate: today(),
                    onChanged: (d) => setState(() => _dob = d),
                    onCleared: () => setState(() => _dob = null),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _guardian,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Parent or guardian',
                  errorText: serverError('guardianName'),
                ),
                validator: (v) => requiredField(v, 'Parent name'),
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  TextFormField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(RegExp(r'[0-9+() -]')),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Parent phone',
                      errorText: serverError('guardianPhone'),
                    ),
                    validator: (v) => (v ?? '').trim().length < 5
                        ? 'Enter a phone number'
                        : null,
                  ),
                  TextFormField(
                    controller: _relation,
                    decoration: const InputDecoration(
                      labelText: 'Relation',
                      hintText: 'Father, mother, guardian',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _address,
                maxLines: 2,
                decoration: const InputDecoration(labelText: 'Address'),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notes,
                maxLines: 2,
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
      BusyButton(
        busy: _saving,
        onPressed: _saving ? null : _save,
        label: _editing ? 'Save' : 'Admit',
      ),
    ],
  );
}
