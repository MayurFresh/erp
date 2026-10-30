import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/india_states.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/state_dropdown.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'parties_repository.dart';
import '../tax/tax_pickers.dart';
import 'party_model.dart';
import '../../widgets/busy.dart';

/// Create (`/parties/new`) or edit (`/parties/:id`) a customer or vendor.
class PartyFormScreen extends ConsumerWidget {
  const PartyFormScreen({super.key, this.partyId});

  final String? partyId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = partyId;
    if (id == null) return const PartyForm();
    return AsyncValueView(
      value: ref.watch(partyProvider(id)),
      onRetry: () => ref.invalidate(partyProvider(id)),
      data: (party) => PartyForm(key: ValueKey(party.id), party: party),
    );
  }
}

class PartyForm extends ConsumerStatefulWidget {
  const PartyForm({super.key, this.party});

  final Party? party;

  @override
  ConsumerState<PartyForm> createState() => _PartyFormState();
}

class _PartyFormState extends ConsumerState<PartyForm>
    with ServerFieldErrors, DirtyTracking<PartyForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _gstin;
  late final TextEditingController _pan;
  late final TextEditingController _pincode;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _creditLimit;
  late final TextEditingController _creditDays;
  late final TextEditingController _udyam;
  String? _msme;
  String? _tdsSectionId;
  late PartyType _type;
  String? _stateCode;
  bool _saving = false;

  bool get _editing => widget.party != null;

  @override
  void initState() {
    super.initState();
    final p = widget.party;
    _name = TextEditingController(text: p?.name);
    _gstin = TextEditingController(text: p?.gstin);
    _pan = TextEditingController(text: p?.pan);
    _pincode = TextEditingController(text: p?.pincode);
    _phone = TextEditingController(text: p?.phone);
    _email = TextEditingController(text: p?.email);
    _address = TextEditingController(text: p?.address);
    _creditLimit = TextEditingController(text: formatPlain(p?.creditLimit));
    _creditDays = TextEditingController(text: '${p?.creditDays ?? 0}');
    _udyam = TextEditingController(text: p?.udyamNo);
    _msme = p?.msmeCategory;
    _tdsSectionId = p?.tdsSectionId;
    _type = p?.type ?? PartyType.customer;
    _stateCode = p?.stateCode;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _gstin,
      _pan,
      _pincode,
      _phone,
      _email,
      _address,
      _creditLimit,
      _creditDays,
      _udyam,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _gstinChanged(String value) {
    clearServerError('gstin');
    final text = value.trim().toUpperCase();
    final derived = stateCodeFromGstin(text);
    if (isValidGstin(text) && derived != null && derived != _stateCode) {
      setState(() => _stateCode = derived);
    }
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    final gstin = trimmedOrNull(_gstin.text.toUpperCase());
    final body = <String, dynamic>{
      'type': _type.name,
      'name': _name.text.trim(),
      'gstin': gstin,
      'stateCode': _stateCode ?? stateCodeFromGstin(gstin),
      'phone': trimmedOrNull(_phone.text),
      'email': trimmedOrNull(_email.text),
      'address': trimmedOrNull(_address.text),
      'pan': trimmedOrNull(_pan.text.toUpperCase()),
      'pincode': trimmedOrNull(_pincode.text),
      'creditLimit': parseNumber(_creditLimit.text) ?? 0,
      'creditDays': int.tryParse(_creditDays.text.trim()) ?? 0,
      'udyamNo': trimmedOrNull(_udyam.text.toUpperCase()),
      'msmeCategory': _msme,
      'tdsSectionId': _tdsSectionId,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(partiesRepositoryProvider);
      final original = widget.party;
      final saved = original == null
          ? await repo.create(body)
          : await repo.update(original, body);
      ref.bump(const [DataKind.parties]);
      if (!mounted) return;
      markSaved();
      showInfoSnackBar(context, 'Saved "${saved.name}"');
      context.go('/parties/${saved.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final canSave = _editing
        ? perms.can(Perm.partiesEdit)
        : perms.can(Perm.partiesCreate);

    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        children: [
          Text(
            _editing ? 'Edit party' : 'New party',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<PartyType>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: PartyType.customer,
                      label: Text('Customer'),
                    ),
                    ButtonSegment(
                      value: PartyType.vendor,
                      label: Text('Vendor'),
                    ),
                    ButtonSegment(value: PartyType.both, label: Text('Both')),
                  ],
                  selected: {_type},
                  onSelectionChanged: canSave
                      ? (s) => setState(() => _type = s.first)
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  enabled: canSave,
                  decoration: const InputDecoration(labelText: 'Name'),
                  textCapitalization: TextCapitalization.words,
                  forceErrorText: serverError('name'),
                  onChanged: (_) => clearServerError('name'),
                  validator: (v) => requiredField(v, 'Name'),
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _gstin,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'GSTIN (optional)',
                        helperText: 'Sets the state automatically',
                        counterText: '',
                      ),
                      maxLength: 15,
                      textCapitalization: TextCapitalization.characters,
                      forceErrorText: serverError('gstin'),
                      onChanged: _gstinChanged,
                      validator: (v) {
                        final error = validateGstin(v);
                        if (error != null) return error;
                        final code = stateCodeFromGstin(
                          v?.trim().toUpperCase(),
                        );
                        if (code != null &&
                            _stateCode != null &&
                            code != _stateCode) {
                          return 'GSTIN is from state $code, not $_stateCode';
                        }
                        return null;
                      },
                    ),
                    StateDropdown(
                      value: _stateCode,
                      required: false,
                      label: 'State (place of supply)',
                      enabled: canSave,
                      errorText: serverError('stateCode'),
                      onChanged: (v) {
                        clearServerError('stateCode');
                        setState(() => _stateCode = v);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Contact',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    TextFormField(
                      controller: _phone,
                      enabled: canSave,
                      decoration: const InputDecoration(labelText: 'Phone'),
                      keyboardType: TextInputType.phone,
                      validator: validatePhone,
                      forceErrorText: serverError('phone'),
                      onChanged: (_) => clearServerError('phone'),
                    ),
                    TextFormField(
                      controller: _email,
                      enabled: canSave,
                      decoration: const InputDecoration(labelText: 'Email'),
                      keyboardType: TextInputType.emailAddress,
                      forceErrorText: serverError('email'),
                      onChanged: (_) => clearServerError('email'),
                      validator: (v) => validateEmail(v, required: false),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _address,
                  enabled: canSave,
                  decoration: const InputDecoration(labelText: 'Address'),
                  minLines: 2,
                  maxLines: 4,
                  forceErrorText: serverError('address'),
                  onChanged: (_) => clearServerError('address'),
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _pan,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'PAN (optional)',
                        counterText: '',
                      ),
                      maxLength: 10,
                      textCapitalization: TextCapitalization.characters,
                      forceErrorText: serverError('pan'),
                      onChanged: (_) => clearServerError('pan'),
                      validator: validatePan,
                    ),
                    TextFormField(
                      controller: _pincode,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'PIN code (optional)',
                        helperText: 'Needed for e-invoices',
                        counterText: '',
                      ),
                      maxLength: 6,
                      keyboardType: TextInputType.number,
                      forceErrorText: serverError('pincode'),
                      onChanged: (_) => clearServerError('pincode'),
                      validator: validatePincode,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    TextFormField(
                      controller: _creditLimit,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'Credit limit',
                        prefixText: '₹ ',
                      ),
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      forceErrorText: serverError('creditLimit'),
                      onChanged: (_) => clearServerError('creditLimit'),
                      validator: (v) => optionalNumber(v, min: 0),
                    ),
                    TextFormField(
                      controller: _creditDays,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'Credit days',
                        helperText: 'Invoice due date = invoice date + days',
                        suffixText: 'days',
                      ),
                      keyboardType: TextInputType.number,
                      inputFormatters: [decimalInput(decimals: 0)],
                      forceErrorText: serverError('creditDays'),
                      onChanged: (_) => clearServerError('creditDays'),
                      validator: (v) {
                        final text = v?.trim() ?? '';
                        if (text.isEmpty) return null;
                        final days = int.tryParse(text);
                        if (days == null || days < 0) return 'Whole days only';
                        if (days > 365) return 'At most 365 days';
                        if (days > 45 &&
                            _type != PartyType.customer &&
                            (_msme == 'micro' || _msme == 'small')) {
                          return 'MSME suppliers must be paid within 45 days '
                              '(MSMED Act s.15)';
                        }
                        return null;
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'MSME and TDS',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    TextFormField(
                      controller: _udyam,
                      enabled: canSave,
                      decoration: const InputDecoration(
                        labelText: 'Udyam number (optional)',
                        hintText: 'UDYAM-XX-00-0000000',
                      ),
                      textCapitalization: TextCapitalization.characters,
                      forceErrorText: serverError('udyamNo'),
                      onChanged: (_) => clearServerError('udyamNo'),
                    ),
                    DropdownButtonFormField<String?>(
                      initialValue: _msme,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'MSME category',
                      ),
                      items: const [
                        DropdownMenuItem(value: null, child: Text('Not MSME')),
                        DropdownMenuItem(value: 'micro', child: Text('Micro')),
                        DropdownMenuItem(value: 'small', child: Text('Small')),
                        DropdownMenuItem(
                          value: 'medium',
                          child: Text('Medium'),
                        ),
                      ],
                      onChanged: canSave
                          ? (v) => setState(() {
                              _msme = v;
                              clearServerError('msmeCategory');
                              _formKey.currentState?.validate();
                            })
                          : null,
                    ),
                  ],
                ),
                if (_type != PartyType.customer) ...[
                  const SizedBox(height: 16),
                  TdsSectionPicker(
                    value: _tdsSectionId,
                    enabled: canSave,
                    label: 'Default TDS section (on purchases)',
                    errorText: serverError('tdsSectionId'),
                    onChanged: (s) => setState(() => _tdsSectionId = s?.id),
                  ),
                ],
              ],
            ),
          ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _saving
                    ? null
                    : () => context.go(
                        widget.party == null
                            ? '/parties'
                            : '/parties/${widget.party!.id}',
                      ),
                child: Text(canSave ? 'Cancel' : 'Back'),
              ),
              if (canSave)
                BusyButton(
                  busy: _saving,
                  onPressed: _save,
                  label: _editing ? 'Save changes' : 'Create party',
                ),
            ],
          ),
        ],
      ),
    );
  }
}
