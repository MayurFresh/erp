import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';

/// `/clinic/doctors`: doctor profiles, fees and weekly hours.
class DoctorsScreen extends ConsumerWidget {
  const DoctorsScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Doctor? d]) async {
    final saved = await showFormDialog<Doctor>(
      context: context,
      builder: (_) => DoctorFormDialog(doctor: d),
    );
    if (saved != null) {
      ref.bumpClinic(const [ClinicKind.doctors]);
      if (context.mounted) showSuccess(context, '${saved.name} saved');
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manage = ref.watch(permissionsProvider).can(Perm.clinicManage);
    return CGate(
      anyOf: const [Perm.clinicView],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Doctors',
            actions: [
              if (manage)
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => _edit(context, ref),
                  icon: const Icon(Icons.add),
                  label: const Text('Add doctor'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<List<Doctor>>(
              value: ref.watch(clinicDoctorsProvider),
              onRetry: () => ref.invalidate(clinicDoctorsProvider),
              data: (list) => list.isEmpty
                  ? const EmptyView(
                      icon: Icons.medical_services_outlined,
                      message: 'No doctors yet. Add the first one.',
                    )
                  : ListView(
                      padding: EdgeInsets.fromLTRB(
                        pageGutter(context),
                        0,
                        pageGutter(context),
                        24,
                      ),
                      children: [
                        for (final d in list)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: ListTile(
                                key: ValueKey('doctor-${d.id}'),
                                onTap: manage
                                    ? () => _edit(context, ref, d)
                                    : null,
                                title: Text(d.name),
                                subtitle: Text(
                                  [
                                    if (d.speciality != null) d.speciality!,
                                    'Fee ${formatMoney(d.consultFee)}',
                                    'Follow-up ${formatMoney(d.followUpFee)} within ${d.followUpDays} days',
                                    '${d.slotMinutes} min slots',
                                  ].join('  |  '),
                                ),
                                trailing: d.isActive
                                    ? null
                                    : const Pill('Inactive'),
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Range {
  _Range(this.day, this.from, this.to);

  int day;
  String from;
  String to;
}

/// Add or edit a doctor profile. Pops the saved [Doctor].
class DoctorFormDialog extends ConsumerStatefulWidget {
  const DoctorFormDialog({super.key, this.doctor});

  final Doctor? doctor;

  @override
  ConsumerState<DoctorFormDialog> createState() => _DoctorFormDialogState();
}

class _DoctorFormDialogState extends ConsumerState<DoctorFormDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.doctor?.name);
  late final _spec = TextEditingController(text: widget.doctor?.speciality);
  late final _reg = TextEditingController(text: widget.doctor?.registrationNo);
  late final _fee = TextEditingController(
    text: widget.doctor == null ? null : formatPlain(widget.doctor!.consultFee),
  );
  late final _followFee = TextEditingController(
    text: widget.doctor == null
        ? null
        : formatPlain(widget.doctor!.followUpFee),
  );
  late final _followDays = TextEditingController(
    text: '${widget.doctor?.followUpDays ?? 7}',
  );
  late final _slot = TextEditingController(
    text: '${widget.doctor?.slotMinutes ?? 15}',
  );
  late final List<_Range> _ranges = [
    for (final h in widget.doctor?.workingHours ?? const <WorkingHours>[])
      _Range(h.day, h.from, h.to),
  ];
  late bool _active = widget.doctor?.isActive ?? true;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _name,
      _spec,
      _reg,
      _fee,
      _followFee,
      _followDays,
      _slot,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _pickTime(_Range r, bool from) async {
    final cur = (from ? r.from : r.to).split(':');
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: int.parse(cur[0]),
        minute: int.parse(cur[1]),
      ),
    );
    if (t == null) return;
    final text =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    setState(() => from ? r.from = text : r.to = text);
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    for (final r in _ranges) {
      if (r.from.compareTo(r.to) >= 0) {
        showErrorSnackBar(
          context,
          '${weekdayNames[r.day]}: the end time must be after the start.',
        );
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final saved = await ref.read(clinicRepositoryProvider).saveDoctor(
        widget.doctor?.id,
        {
          'name': _name.text.trim(),
          'speciality': trimmedOrNull(_spec.text),
          'registrationNo': trimmedOrNull(_reg.text),
          'consultFee': parseNumber(_fee.text),
          'followUpFee': parseNumber(_followFee.text) ?? 0,
          'followUpDays': int.tryParse(_followDays.text.trim()) ?? 7,
          'slotMinutes': int.tryParse(_slot.text.trim()) ?? 15,
          'workingHours': [
            for (final r in _ranges) {'day': r.day, 'from': r.from, 'to': r.to},
          ],
          'isActive': _active,
          if (widget.doctor != null)
            'expectedUpdatedAt': widget.doctor!.updatedAt,
        },
      );
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.doctor == null ? 'Add doctor' : 'Edit doctor'),
    content: SizedBox(
      width: 600,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Name',
                  errorText: serverError('name'),
                ),
                validator: (v) => requiredField(v, 'Name'),
              ),
              const SizedBox(height: 12),
              FormRow(
                children: [
                  TextFormField(
                    controller: _spec,
                    decoration: const InputDecoration(labelText: 'Speciality'),
                  ),
                  TextFormField(
                    controller: _reg,
                    decoration: const InputDecoration(
                      labelText: 'Registration number',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 160,
                children: [
                  TextFormField(
                    controller: _fee,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    decoration: InputDecoration(
                      labelText: 'Consultation fee',
                      errorText: serverError('consultFee'),
                    ),
                    validator: (v) => requiredNumber(v, label: 'Fee', min: 0),
                  ),
                  TextFormField(
                    controller: _followFee,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    decoration: const InputDecoration(
                      labelText: 'Follow-up fee',
                    ),
                    validator: (v) => optionalNumber(v, min: 0),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              FormRow(
                minCellWidth: 160,
                children: [
                  TextFormField(
                    controller: _followDays,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Follow-up window (days)',
                    ),
                  ),
                  TextFormField(
                    controller: _slot,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Slot length (minutes)',
                    ),
                    validator: (v) {
                      final n = int.tryParse((v ?? '').trim());
                      return n == null || n < 5 || n > 240
                          ? 'Between 5 and 240'
                          : null;
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Weekly hours',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(
                      () => _ranges.add(_Range(1, '09:00', '13:00')),
                    ),
                    icon: const Icon(Icons.add),
                    label: const Text('Add hours'),
                  ),
                ],
              ),
              if (_ranges.isEmpty)
                const Text('No hours set: any time can be booked.'),
              for (final (i, r) in _ranges.indexed)
                Wrap(
                  key: ObjectKey(r),
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    SizedBox(
                      width: 130,
                      child: DropdownButtonFormField<int>(
                        initialValue: r.day,
                        isExpanded: true,
                        decoration: const InputDecoration(labelText: 'Day'),
                        items: [
                          for (final d in [1, 2, 3, 4, 5, 6, 0])
                            DropdownMenuItem(
                              value: d,
                              child: Text(weekdayNames[d]),
                            ),
                        ],
                        onChanged: (v) => setState(() => r.day = v ?? 1),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () => _pickTime(r, true),
                      child: Text('From ${r.from}'),
                    ),
                    OutlinedButton(
                      onPressed: () => _pickTime(r, false),
                      child: Text('To ${r.to}'),
                    ),
                    IconButton(
                      tooltip: 'Remove hours',
                      onPressed: () => setState(() => _ranges.removeAt(i)),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Taking appointments'),
                value: _active,
                onChanged: (v) => setState(() => _active = v),
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
        label: 'Save',
      ),
    ],
  );
}
