import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../core/permissions.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../parties/party_model.dart';
import '../../parties/party_picker.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../common/photo_widgets.dart';
import '../data/construction_repository.dart';
import '../data/photo_source.dart';
import '../models/labour_models.dart';
import '../../../widgets/busy.dart';

/// Creates a worker or patches an existing worker record.
class WorkerFormScreen extends ConsumerStatefulWidget {
  const WorkerFormScreen({super.key, this.workerId});

  final String? workerId;

  @override
  ConsumerState<WorkerFormScreen> createState() => _WorkerFormScreenState();
}

class _WorkerFormScreenState extends ConsumerState<WorkerFormScreen>
    with DirtyTracking<WorkerFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _rate = TextEditingController();
  final _aadhaar = TextEditingController();
  final _bocw = TextEditingController();
  Trade _trade = Trade.helper;
  Skill _skill = Skill.unskilled;
  String? _siteId;
  String? _contractorPartyId;
  String? _contractorName;
  String? _photoFileId;
  DateTime? _joinedOn;
  bool _active = true;
  bool _loading = false;
  bool _busy = false;
  Worker? _original;

  bool get _editing => widget.workerId != null;

  @override
  void initState() {
    super.initState();
    final id = widget.workerId;
    if (id != null) _load(id);
  }

  @override
  void dispose() {
    for (final controller in [_name, _phone, _rate, _aadhaar, _bocw]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load(String id) async {
    setState(() => _loading = true);
    try {
      final worker = await ref.read(constructionRepositoryProvider).worker(id);
      if (!mounted) return;
      setState(() {
        _original = worker;
        _name.text = worker.name;
        _phone.text = worker.phone ?? '';
        _rate.text = formatPlain(worker.dailyRate);
        _aadhaar.text = worker.aadhaarLast4 ?? '';
        _bocw.text = worker.bocwRegNo ?? '';
        _trade = worker.trade;
        _skill = worker.skill;
        _siteId = worker.siteId;
        _contractorPartyId = worker.contractorPartyId;
        _contractorName = worker.contractorName;
        _photoFileId = worker.photoFileId;
        _joinedOn = parseApiDate(worker.joinedOn);
        _active = worker.isActive;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showErrorSnackBar(context, error);
    }
  }

  Future<void> _pickContractor() async {
    final party = await pickParty(context, ref, type: PartyType.vendor);
    if (party == null || !mounted) return;
    setState(() {
      _contractorPartyId = party.id;
      _contractorName = party.name;
    });
  }

  Future<void> _attachPhoto() async {
    final source = ref.read(photoSourceProvider);
    final unavailable = source.unavailableMessage;
    if (unavailable != null) {
      showInfoSnackBar(context, unavailable);
      return;
    }
    final picked = await source.pick(camera: true);
    if (picked == null || !mounted) return;
    setState(() => _busy = true);
    try {
      final file = await ref
          .read(constructionRepositoryProvider)
          .uploadPhoto(picked);
      if (!mounted) return;
      setState(() {
        _photoFileId = file.id;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showErrorSnackBar(context, error);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    final rate = double.tryParse(_rate.text.trim());
    if (rate == null || rate < 0) {
      markSaved();
      showInfoSnackBar(context, 'Enter a valid daily rate.');
      return;
    }
    setState(() => _busy = true);
    try {
      final body = <String, dynamic>{
        'name': _name.text.trim(),
        'phone': _phone.text.trim().isEmpty ? null : _phone.text.trim(),
        'trade': _trade.api,
        'skill': _skill.api,
        'dailyRate': rate,
        'contractorPartyId': _contractorPartyId,
        'siteId': _siteId,
        'aadhaarLast4': _aadhaar.text.trim().isEmpty
            ? null
            : _aadhaar.text.trim(),
        'bocwRegNo': _bocw.text.trim().isEmpty ? null : _bocw.text.trim(),
        'photoFileId': _photoFileId,
        'joinedOn': _joinedOn == null ? null : apiDate(_joinedOn!),
        if (_editing) 'isActive': _active,
      };
      final repo = ref.read(constructionRepositoryProvider);
      final saved = _editing
          ? await repo.updateWorker(_original!, body)
          : await repo.createWorker(body);
      ref.bumpC(const [CKind.workers, CKind.attendance]);
      if (!mounted) return;
      showSuccess(context, '${saved.name} saved');
      context.go('/workers/${saved.id}');
    } catch (error) {
      if (!mounted) return;
      showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    if (_loading) return const LoadingView();
    return CGate(
      anyOf: const [CPerm.labourManage],
      child: Form(
        key: _formKey,
        onChanged: markDirty,
        child: BottomBarLayout(
          bar: Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                style: bigOutlinedButton,
                onPressed: _busy ? null : () => leave('/workers'),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: bigButton,
                onPressed: _busy ? null : _save,
                child: Text(_editing ? 'Save changes' : 'Add worker'),
              ),
            ],
          ),
          child: CPage(
            maxWidth: 760,
            children: [
              SectionCard(
                title: 'Worker',
                child: FormRow(
                  children: [
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) => requiredField(value, 'Name'),
                    ),
                    TextFormField(
                      controller: _phone,
                      keyboardType: TextInputType.phone,
                      validator: validatePhone,
                      decoration: const InputDecoration(
                        labelText: 'Phone',
                        prefixIcon: Icon(Icons.phone_outlined),
                      ),
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Work',
                child: FormRow(
                  children: [
                    DropdownButtonFormField<Trade>(
                      isExpanded: true,
                      key: ValueKey('trade-${_trade.api}'),
                      initialValue: _trade,
                      decoration: const InputDecoration(labelText: 'Trade'),
                      items: [
                        for (final trade in Trade.values)
                          DropdownMenuItem(
                            value: trade,
                            child: Text(trade.label),
                          ),
                      ],
                      onChanged: (value) => setState(() => _trade = value!),
                    ),
                    DropdownButtonFormField<Skill>(
                      isExpanded: true,
                      key: ValueKey('skill-${_skill.api}'),
                      initialValue: _skill,
                      decoration: const InputDecoration(
                        labelText: 'Skill level',
                      ),
                      items: [
                        for (final skill in Skill.values)
                          DropdownMenuItem(
                            value: skill,
                            child: Text(skill.label),
                          ),
                      ],
                      onChanged: (value) => setState(() => _skill = value!),
                    ),
                    TextFormField(
                      controller: _rate,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput(decimals: 2)],
                      decoration: const InputDecoration(
                        labelText: 'Daily rate',
                        prefixText: '₹ ',
                      ),
                      validator: (value) =>
                          requiredNumber(value, label: 'Daily rate'),
                    ),
                  ],
                ),
              ),

              SectionCard(
                title: 'Site and contractor',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FormRow(
                      children: [
                        SiteField(
                          label: 'Home site',
                          value: _siteId,
                          // The server needs a home site only from users
                          // limited to some locations.
                          required:
                              ref.watch(sessionProvider).value?.locationIds !=
                              null,
                          onChanged: (value) => setState(() => _siteId = value),
                        ),
                        DateField(
                          label: 'Joined on',
                          value: _joinedOn,
                          onChanged: (value) =>
                              setState(() => _joinedOn = value),
                          onCleared: () => setState(() => _joinedOn = null),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    InputDecorator(
                      decoration: InputDecoration(
                        labelText: 'Labour contractor',
                        prefixIcon: const Icon(Icons.engineering_outlined),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _contractorName ?? 'Direct worker',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (_contractorPartyId != null)
                            IconButton(
                              tooltip: 'Clear contractor',
                              onPressed: () => setState(() {
                                _contractorPartyId = null;
                                _contractorName = null;
                              }),
                              icon: const Icon(Icons.close),
                            ),
                          TextButton(
                            style: TextButton.styleFrom(
                              minimumSize: kTapTarget,
                            ),
                            // Listing vendors needs parties.view.
                            onPressed:
                                ref
                                    .watch(permissionsProvider)
                                    .can(Perm.partiesView)
                                ? _pickContractor
                                : null,
                            child: Text(
                              _contractorPartyId == null ? 'Choose' : 'Change',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Statutory details',
                child: FormRow(
                  children: [
                    TextFormField(
                      controller: _aadhaar,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      decoration: const InputDecoration(
                        labelText: 'Aadhaar last 4 digits',
                        counterText: '',
                      ),
                      validator: (value) {
                        final text = value?.trim() ?? '';
                        if (text.isNotEmpty &&
                            !RegExp(r'^\d{4}$').hasMatch(text)) {
                          return 'Use the last 4 digits';
                        }
                        return null;
                      },
                    ),
                    TextFormField(
                      controller: _bocw,
                      decoration: const InputDecoration(
                        labelText: 'BOCW registration number',
                      ),
                    ),
                  ],
                ),
              ),
              SectionCard(
                title: 'Photo',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (_photoFileId == null) const Text('No photo attached.'),
                    if (_photoFileId != null)
                      FileThumb(fileId: _photoFileId!, size: 160),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          style: bigOutlinedButton,
                          onPressed: _busy ? null : _attachPhoto,
                          icon: const Icon(Icons.photo_camera_outlined),
                          label: const Text('Take photo'),
                        ),
                        if (_photoFileId != null)
                          TextButton(
                            onPressed: () =>
                                setState(() => _photoFileId = null),
                            child: const Text('Remove photo'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (_editing)
                SectionCard(
                  title: 'Status',
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active worker'),
                    subtitle: const Text(
                      'Inactive workers stay in wage history but cannot be marked.',
                    ),
                    value: _active,
                    onChanged: (value) => setState(() => _active = value),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
