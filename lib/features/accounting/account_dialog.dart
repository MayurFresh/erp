import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/states.dart';
import 'accounting_models.dart';
import 'accounting_repository.dart';

/// Dialog inset that leaves room for content on phones.
EdgeInsets dialogInset(BuildContext context) =>
    MediaQuery.sizeOf(context).width < 600
    ? const EdgeInsets.symmetric(horizontal: 16, vertical: 24)
    : const EdgeInsets.symmetric(horizontal: 40, vertical: 24);

/// Creates an account (no [account]) or edits one. System accounts can
/// only be renamed. Pops with the saved [Account].
Future<Account?> showAccountDialog(BuildContext context, {Account? account}) =>
    showDialog<Account>(
      context: context,
      builder: (_) => AccountDialog(account: account),
    );

class AccountDialog extends ConsumerStatefulWidget {
  const AccountDialog({super.key, this.account});

  final Account? account;

  @override
  ConsumerState<AccountDialog> createState() => _AccountDialogState();
}

class _AccountDialogState extends ConsumerState<AccountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _code;
  late String _type;
  late String _subtype;
  late bool _active;
  bool _saving = false;
  Map<String, String> _fieldErrors = const {};
  Object? _error;

  Account? get _account => widget.account;
  bool get _editing => _account != null;
  bool get _system => _account?.isSystem ?? false;

  @override
  void initState() {
    super.initState();
    final a = _account;
    _name = TextEditingController(text: a?.name);
    _code = TextEditingController(text: a?.code);
    _type = a?.type ?? 'expense';
    _subtype = a?.subtype ?? 'other';
    _active = a?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    super.dispose();
  }

  void _clear(String field) {
    if (_fieldErrors.containsKey(field) || _error != null) {
      setState(() {
        _fieldErrors = Map.of(_fieldErrors)..remove(field);
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _fieldErrors = const {};
      _error = null;
    });
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(accountingRepositoryProvider);
    try {
      final code = trimmedOrNull(_code.text);
      final saved = _editing
          ? await repo.update(
              _account!,
              name: _name.text.trim(),
              code: code,
              isActive: _active,
            )
          : await repo.create(
              NewAccount(
                name: _name.text.trim(),
                type: _type,
                subtype: _type == 'asset' ? _subtype : 'other',
                code: code,
              ),
            );
      ref.bump(const [DataKind.accounts]);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (!mounted) return;
      final api = apiError(e);
      final fields = <String, String>{
        ...?api?.fieldErrors,
        // CONFLICT on a duplicate code carries `{code: 'Already used'}`.
        if (api != null && !api.isValidation)
          for (final MapEntry(:key, :value) in api.details.entries)
            key: asString(value),
      };
      setState(() {
        _fieldErrors = fields;
        _error = e;
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = !_editing
        ? 'New account'
        : _system
        ? 'Rename account'
        : 'Edit account';
    return AlertDialog(
      title: Text(title),
      insetPadding: dialogInset(context),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_system)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'This is a system account (code ${_account!.code}). It '
                    'can be renamed but not re-coded or deactivated.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Account name'),
                textCapitalization: TextCapitalization.words,
                forceErrorText: _fieldErrors['name'],
                onChanged: (_) => _clear('name'),
                validator: (v) {
                  final text = v?.trim() ?? '';
                  if (text.isEmpty) return 'Name is required';
                  if (text.length < 2) return 'Use at least 2 characters';
                  return null;
                },
              ),
              const SizedBox(height: 16),
              if (!_editing) ...[
                DropdownButtonFormField<String>(
                  initialValue: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Type'),
                  forceErrorText: _fieldErrors['type'],
                  items: [
                    for (final type in accountTypes)
                      DropdownMenuItem(
                        value: type,
                        child: Text(accountTypeLabel(type)),
                      ),
                  ],
                  onChanged: (v) => setState(() {
                    _type = v ?? _type;
                    if (_type != 'asset') _subtype = 'other';
                    _fieldErrors = Map.of(_fieldErrors)..remove('type');
                  }),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('kind-$_type'),
                  initialValue: _type == 'asset' ? _subtype : 'other',
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: 'Kind',
                    helperText: _type == 'asset'
                        ? 'Cash and bank accounts appear in receipts, '
                              'payments and expenses'
                        : 'Only asset accounts can be cash or bank',
                    helperMaxLines: 2,
                  ),
                  forceErrorText: _fieldErrors['subtype'],
                  items: [
                    for (final subtype in creatableSubtypes)
                      DropdownMenuItem(
                        value: subtype,
                        enabled: _type == 'asset' || subtype == 'other',
                        child: Text(accountSubtypeLabel(subtype)),
                      ),
                  ],
                  onChanged: _type == 'asset'
                      ? (v) => setState(() => _subtype = v ?? 'other')
                      : null,
                ),
                const SizedBox(height: 16),
              ],
              if (!_system)
                TextFormField(
                  controller: _code,
                  decoration: InputDecoration(
                    labelText: _editing ? 'Code' : 'Code (optional)',
                    helperText: _editing
                        ? '3 to 6 digits'
                        : 'Leave blank to number it automatically',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  forceErrorText: _fieldErrors['code'],
                  onChanged: (_) => _clear('code'),
                  validator: (v) {
                    final text = v?.trim() ?? '';
                    if (text.isEmpty) {
                      return _editing ? 'Code is required' : null;
                    }
                    return RegExp(r'^\d{3,6}$').hasMatch(text)
                        ? null
                        : 'Use 3 to 6 digits';
                  },
                ),
              if (_editing && !_system)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  subtitle: const Text(
                    'Inactive accounts keep their history but cannot be '
                    'used in new entries',
                  ),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
              if (_error != null && _fieldErrors.isEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  errorMessage(_error!),
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
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
          child: Text(_editing ? 'Save' : 'Create account'),
        ),
      ],
    );
  }
}
