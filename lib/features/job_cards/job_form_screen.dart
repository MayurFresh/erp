import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../construction/common/c_widgets.dart'
    show CGate, DateField, showSuccess;
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'job_models.dart';
import 'job_repository.dart';

/// `/job-cards/new`: receive a vehicle or device.
class JobFormScreen extends ConsumerStatefulWidget {
  const JobFormScreen({super.key});

  @override
  ConsumerState<JobFormScreen> createState() => _JobFormScreenState();
}

class _JobFormScreenState extends ConsumerState<JobFormScreen>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _vehicleNo = TextEditingController();
  final _make = TextEditingController();
  final _model = TextEditingController();
  final _odometer = TextEditingController();
  final _serial = TextEditingController();
  final _complaints = TextEditingController();
  final _accessories = TextEditingController();
  String _kind = 'vehicle';
  Party? _party;
  DateTime? _promised;
  String? _technicianId;
  bool _saving = false;

  @override
  void dispose() {
    for (final c in [
      _name,
      _phone,
      _vehicleNo,
      _make,
      _model,
      _odometer,
      _serial,
      _complaints,
      _accessories,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      final job = await ref.read(jobRepositoryProvider).create({
        'kind': _kind,
        if (_kind == 'vehicle') 'vehicleNo': trimmedOrNull(_vehicleNo.text),
        'make': trimmedOrNull(_make.text),
        'model': trimmedOrNull(_model.text),
        if (_kind == 'vehicle') 'odometer': int.tryParse(_odometer.text.trim()),
        if (_kind == 'device') 'serialNo': trimmedOrNull(_serial.text),
        if (_party != null)
          'partyId': _party!.id
        else
          'customer': {'name': _name.text.trim(), 'phone': _phone.text.trim()},
        'complaints': _complaints.text.trim(),
        'accessories': trimmedOrNull(_accessories.text),
        if (_promised != null) 'promisedDate': apiDate(_promised!),
        if (_technicianId != null) 'technicianId': _technicianId,
      });
      ref.bumpJobs(money: true);
      if (!mounted) return;
      showSuccess(context, 'Job card ${job.number} created');
      context.go('/job-cards/${job.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final techs =
        ref.watch(technicianListProvider).value ?? const <Technician>[];
    return CGate(
      anyOf: const [Perm.jobCardsCreate, Perm.jobCardsManage],
      child: Form(
        key: _formKey,
        child: FormPage(
          maxWidth: 760,
          bottomBar: FormActionBar(
            children: [
              TextButton(
                onPressed: _saving ? null : () => context.go('/job-cards'),
                child: const Text('Cancel'),
              ),
              BusyButton(
                busy: _saving,
                onPressed: _saving ? null : _save,
                label: 'Create job card',
              ),
            ],
          ),
          children: [
            Text('New job card', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(
                  value: 'vehicle',
                  label: Text('Vehicle'),
                  icon: Icon(Icons.directions_car_outlined),
                ),
                ButtonSegment(
                  value: 'device',
                  label: Text('Device'),
                  icon: Icon(Icons.smartphone_outlined),
                ),
              ],
              selected: {_kind},
              onSelectionChanged: (s) => setState(() => _kind = s.first),
            ),
            const SizedBox(height: 16),
            SectionCard(
              title: 'Customer',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PickerField(
                    label: 'Existing customer (optional)',
                    value: _party?.name,
                    onTap: () async {
                      final p = await pickParty(
                        context,
                        ref,
                        type: PartyType.customer,
                      );
                      if (p != null) setState(() => _party = p);
                    },
                  ),
                  if (_party != null)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton(
                        onPressed: () => setState(() => _party = null),
                        child: const Text('Use a new customer instead'),
                      ),
                    )
                  else ...[
                    const SizedBox(height: 12),
                    FormRow(
                      children: [
                        TextFormField(
                          controller: _name,
                          textCapitalization: TextCapitalization.words,
                          decoration: InputDecoration(
                            labelText: 'Customer name',
                            errorText: serverError('customer'),
                          ),
                          validator: (v) => requiredField(v, 'Name'),
                        ),
                        TextFormField(
                          controller: _phone,
                          keyboardType: TextInputType.phone,
                          decoration: const InputDecoration(labelText: 'Phone'),
                          validator: (v) => requiredField(v, 'Phone'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            SectionCard(
              title: _kind == 'vehicle' ? 'Vehicle' : 'Device',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_kind == 'vehicle')
                    TextFormField(
                      controller: _vehicleNo,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(
                        labelText: 'Vehicle number',
                        errorText: serverError('vehicleNo'),
                      ),
                      validator: (v) => requiredField(v, 'Vehicle number'),
                    ),
                  if (_kind == 'vehicle') const SizedBox(height: 12),
                  FormRow(
                    children: [
                      TextFormField(
                        controller: _make,
                        decoration: InputDecoration(
                          labelText: _kind == 'vehicle' ? 'Make' : 'Brand',
                        ),
                      ),
                      TextFormField(
                        controller: _model,
                        decoration: const InputDecoration(labelText: 'Model'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (_kind == 'vehicle')
                    TextFormField(
                      controller: _odometer,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Odometer (km)',
                      ),
                    )
                  else
                    TextFormField(
                      controller: _serial,
                      decoration: const InputDecoration(
                        labelText: 'Serial number or IMEI',
                      ),
                    ),
                ],
              ),
            ),
            SectionCard(
              title: 'Problem',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextFormField(
                    controller: _complaints,
                    minLines: 2,
                    maxLines: 5,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(
                      labelText: 'Complaints',
                      errorText: serverError('complaints'),
                    ),
                    validator: (v) => requiredField(v, 'Complaints'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _accessories,
                    decoration: const InputDecoration(
                      labelText: 'Accessories received',
                      helperText: 'Spare wheel, charger, SIM tray',
                    ),
                  ),
                  const SizedBox(height: 12),
                  FormRow(
                    children: [
                      DateField(
                        label: 'Promised date',
                        value: _promised,
                        firstDate: DateTime.now().subtract(
                          const Duration(days: 1),
                        ),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                        onChanged: (d) => setState(() => _promised = d),
                        onCleared: () => setState(() => _promised = null),
                      ),
                      DropdownButtonFormField<String?>(
                        initialValue: _technicianId,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Technician',
                        ),
                        items: [
                          const DropdownMenuItem<String?>(
                            value: null,
                            child: Text('Not assigned'),
                          ),
                          for (final t in techs)
                            DropdownMenuItem<String?>(
                              value: t.id,
                              child: Text(t.name),
                            ),
                        ],
                        onChanged: (v) => setState(() => _technicianId = v),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
