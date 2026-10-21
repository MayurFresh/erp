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
import 'party_model.dart';

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

class _PartyFormState extends ConsumerState<PartyForm> with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _gstin;
  late final TextEditingController _phone;
  late final TextEditingController _email;
  late final TextEditingController _address;
  late final TextEditingController _creditLimit;
  late final TextEditingController _creditDays;
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
    _phone = TextEditingController(text: p?.phone);
    _email = TextEditingController(text: p?.email);
    _address = TextEditingController(text: p?.address);
    _creditLimit = TextEditingController(text: formatPlain(p?.creditLimit));
    _creditDays = TextEditingController(text: '${p?.creditDays ?? 0}');
    _type = p?.type ?? PartyType.customer;
    _stateCode = p?.stateCode;
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _gstin,
      _phone,
      _email,
      _address,
      _creditLimit,
      _creditDays,
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
      'creditLimit': parseNumber(_creditLimit.text) ?? 0,
      'creditDays': int.tryParse(_creditDays.text.trim()) ?? 0,
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
      showInfoSnackBar(context, 'Saved "${saved.name}"');
      context.go('/parties/${saved.id}');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final canSave = _editing
        ? perms.can(Perm.partiesEdit)
        : perms.can(Perm.partiesCreate);

    return Form(
      key: _formKey,
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
                        return days > 365 ? 'At most 365 days' : null;
                      },
                    ),
                  ],
                ),
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
