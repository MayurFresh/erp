import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';

const _bloodGroups = ['A+', 'A-', 'B+', 'B-', 'AB+', 'AB-', 'O+', 'O-'];

/// Register a patient, or edit one when [patient] is given. Pops the saved
/// [Patient].
class PatientFormDialog extends ConsumerStatefulWidget {
  const PatientFormDialog({super.key, this.patient, this.canEditNotes = false});

  final Patient? patient;
  final bool canEditNotes;

  @override
  ConsumerState<PatientFormDialog> createState() => _PatientFormDialogState();
}

class _PatientFormDialogState extends ConsumerState<PatientFormDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.patient?.name);
  late final _phone = TextEditingController(text: widget.patient?.brief.phone);
  late final _age = TextEditingController(
    text: widget.patient?.dob == null
        ? widget.patient?.brief.ageYears?.toString()
        : null,
  );
  late final _address = TextEditingController(text: widget.patient?.address);
  late final _allergies = TextEditingController(
    text: widget.patient?.allergies,
  );
  late final _emName = TextEditingController(
    text: widget.patient?.emergencyName,
  );
  late final _emPhone = TextEditingController(
    text: widget.patient?.emergencyPhone,
  );
  late final _notes = TextEditingController(text: widget.patient?.notes);
  late String _sex = widget.patient?.brief.sex ?? 'male';
  late String? _blood = widget.patient?.bloodGroup;
  late DateTime? _dob = parseApiDate(widget.patient?.dob);
  bool _saving = false;

  bool get _editing => widget.patient != null;

  @override
  void dispose() {
    for (final c in [
      _name,
      _phone,
      _age,
      _address,
      _allergies,
      _emName,
      _emPhone,
      _notes,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save({bool force = false}) async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    if (_dob == null && _age.text.trim().isEmpty) {
      showErrorSnackBar(context, 'Give a date of birth or an age.');
      return;
    }
    setState(() => _saving = true);
    final repo = ref.read(clinicRepositoryProvider);
    final body = <String, Object?>{
      'name': _name.text.trim(),
      'sex': _sex,
      'phone': _phone.text.trim(),
      if (_dob != null)
        'dob': apiDate(_dob!)
      else
        'ageYears': int.tryParse(_age.text.trim()),
      'address': trimmedOrNull(_address.text),
      'bloodGroup': _blood,
      'allergies': trimmedOrNull(_allergies.text),
      'emergencyName': trimmedOrNull(_emName.text),
      'emergencyPhone': trimmedOrNull(_emPhone.text),
      if (widget.canEditNotes) 'notes': trimmedOrNull(_notes.text),
      if (force) 'force': true,
    };
    try {
      final saved = _editing
          ? await repo.updatePatient(widget.patient!.id, {
              ...body,
              'expectedUpdatedAt': widget.patient!.updatedAt,
            })
          : await repo.createPatient(body);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      final api = apiError(e);
      if (api?.code == 'DUPLICATE_PATIENT' && mounted) {
        setState(() => _saving = false);
        if (await confirmDuplicate(context, api!)) {
          await _save(force: true);
        }
        return;
      }
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted && _saving) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_editing ? 'Edit patient' : 'Register patient'),
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
                  labelText: 'Full name',
                  errorText: serverError('name'),
                ),
                validator: (v) => requiredField(v, 'Name'),
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
                      labelText: 'Phone',
                      errorText: serverError('phone'),
                    ),
                    validator: (v) => (v ?? '').trim().length < 5
                        ? 'Enter a phone number'
                        : null,
                  ),
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
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  DateField(
                    label: 'Date of birth',
                    value: _dob,
                    firstDate: DateTime(1900),
                    lastDate: today(),
                    onChanged: (d) => setState(() => _dob = d),
                    onCleared: () => setState(() => _dob = null),
                  ),
                  TextFormField(
                    controller: _age,
                    enabled: _dob == null,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Age in years',
                      helperText: 'If the date of birth is not known',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  DropdownButtonFormField<String?>(
                    initialValue: _blood,
                    decoration: const InputDecoration(labelText: 'Blood group'),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('Not known'),
                      ),
                      for (final b in _bloodGroups)
                        DropdownMenuItem<String?>(value: b, child: Text(b)),
                    ],
                    onChanged: (v) => setState(() => _blood = v),
                  ),
                  TextFormField(
                    controller: _allergies,
                    decoration: const InputDecoration(labelText: 'Allergies'),
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
              FormRow(
                children: [
                  TextFormField(
                    controller: _emName,
                    decoration: const InputDecoration(
                      labelText: 'Emergency contact',
                    ),
                  ),
                  TextFormField(
                    controller: _emPhone,
                    keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(
                      labelText: 'Emergency phone',
                    ),
                  ),
                ],
              ),
              if (widget.canEditNotes) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Notes (clinical staff only)',
                  ),
                ),
              ],
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
        label: _editing ? 'Save' : 'Register',
      ),
    ],
  );
}

/// Books an appointment, or issues a walk-in token. Pops the [Appointment].
class BookDialog extends ConsumerStatefulWidget {
  const BookDialog({
    super.key,
    this.patient,
    this.doctorId,
    this.walkIn = false,
  });

  final PatientBrief? patient;
  final String? doctorId;
  final bool walkIn;

  @override
  ConsumerState<BookDialog> createState() => _BookDialogState();
}

class _BookDialogState extends ConsumerState<BookDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  late PatientBrief? _patient = widget.patient;
  late String? _doctorId = widget.doctorId;
  late bool _walkIn = widget.walkIn;
  DateTime _date = today();
  String? _slot;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    if (!_walkIn && _slot == null) {
      showErrorSnackBar(context, 'Choose a time slot.');
      return;
    }
    setState(() => _saving = true);
    try {
      final appt = await ref.read(clinicRepositoryProvider).book({
        'patientId': _patient!.id,
        'doctorId': _doctorId,
        if (_walkIn)
          'walkIn': true
        else ...{
          'date': apiDate(_date),
          'startTime': _slot,
        },
        'reason': trimmedOrNull(_reason.text),
      });
      if (mounted) Navigator.of(context).pop(appt);
    } catch (e) {
      if (mounted) {
        if (apiError(e)?.code == 'SLOT_TAKEN') setState(() => _slot = null);
        showSubmitError(e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final doctorId = _doctorId;
    final slots = !_walkIn && doctorId != null
        ? ref.watch(_slotsProvider((doctorId, apiDate(_date))))
        : null;
    return AlertDialog(
      title: Text(widget.walkIn ? 'Walk-in token' : 'Book appointment'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PatientPickerField(
                  value: _patient,
                  enabled: widget.patient == null,
                  onChanged: (p) => setState(() => _patient = p),
                ),
                const SizedBox(height: 12),
                DoctorDropdown(
                  value: _doctorId,
                  onChanged: (v) => setState(() {
                    _doctorId = v;
                    _slot = null;
                  }),
                ),
                const SizedBox(height: 12),
                if (!widget.walkIn)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Walk-in, no time slot'),
                    value: _walkIn,
                    onChanged: (v) => setState(() => _walkIn = v),
                  ),
                if (!_walkIn) ...[
                  DateField(
                    label: 'Date',
                    value: _date,
                    firstDate: today(),
                    lastDate: today().add(const Duration(days: 180)),
                    onChanged: (d) => setState(() {
                      _date = d;
                      _slot = null;
                    }),
                  ),
                  const SizedBox(height: 8),
                  if (slots == null)
                    const Text('Choose a doctor to see free times.')
                  else
                    slots.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, _) =>
                          Text(apiError(e)?.message ?? 'Could not load times.'),
                      data: (list) => list.isEmpty
                          ? const Text(
                              'The doctor has no times on this day. Pick another date.',
                            )
                          : Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final s in list)
                                  ChoiceChip(
                                    label: Text(s.startTime),
                                    selected: _slot == s.startTime,
                                    onSelected: s.free
                                        ? (_) => setState(
                                            () => _slot = s.startTime,
                                          )
                                        : null,
                                  ),
                              ],
                            ),
                    ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reason,
                  decoration: InputDecoration(
                    labelText: 'Reason (optional)',
                    errorText: serverError('reason'),
                  ),
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
          label: _walkIn ? 'Issue token' : 'Book',
        ),
      ],
    );
  }
}

final _slotsProvider = FutureProvider.autoDispose
    .family<List<Slot>, (String, String)>((ref, key) {
      ref.watchClinic(const [ClinicKind.appointments]);
      return ref.watch(clinicRepositoryProvider).slots(key.$1, key.$2);
    });

/// Move a booked appointment. Pops the updated [Appointment].
class RescheduleDialog extends ConsumerStatefulWidget {
  const RescheduleDialog({super.key, required this.appointment});

  final Appointment appointment;

  @override
  ConsumerState<RescheduleDialog> createState() => _RescheduleDialogState();
}

class _RescheduleDialogState extends ConsumerState<RescheduleDialog> {
  late DateTime _date = parseApiDate(widget.appointment.date) ?? today();
  String? _slot;
  bool _saving = false;

  Future<void> _save() async {
    if (_slot == null) {
      showErrorSnackBar(context, 'Choose a time slot.');
      return;
    }
    setState(() => _saving = true);
    try {
      final a = await ref.read(clinicRepositoryProvider).reschedule(
        widget.appointment.id,
        {'date': apiDate(_date), 'startTime': _slot},
      );
      if (mounted) Navigator.of(context).pop(a);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final slots = ref.watch(
      _slotsProvider((widget.appointment.doctorId, apiDate(_date))),
    );
    return AlertDialog(
      title: Text('Reschedule ${widget.appointment.patient.name}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DateField(
                label: 'New date',
                value: _date,
                firstDate: today(),
                lastDate: today().add(const Duration(days: 180)),
                onChanged: (d) => setState(() {
                  _date = d;
                  _slot = null;
                }),
              ),
              const SizedBox(height: 8),
              slots.when(
                loading: () => const LinearProgressIndicator(),
                error: (e, _) =>
                    Text(apiError(e)?.message ?? 'Could not load times.'),
                data: (list) => Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in list)
                      ChoiceChip(
                        label: Text(s.startTime),
                        selected: _slot == s.startTime,
                        onSelected: s.free
                            ? (_) => setState(() => _slot = s.startTime)
                            : null,
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
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Move',
        ),
      ],
    );
  }
}
