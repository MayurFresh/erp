import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounting/account_dialog.dart' show dialogInset;
import '../auth/session.dart';
import '../locations/locations_repository.dart';
import 'settings_models.dart';
import 'settings_repository.dart';
import '../../widgets/busy.dart';

/// `/users/:id`: name, phone, active, role and location scope, plus a
/// password reset.
class UserEditScreen extends ConsumerWidget {
  const UserEditScreen({super.key, required this.userId});

  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(adminUserProvider(userId));
    if (value.error is UserNotFound) {
      return const EmptyView(
        icon: Icons.person_off_outlined,
        message: 'This user is not in the active company.',
      );
    }
    return AsyncValueView(
      value: value,
      onRetry: () => ref.invalidate(adminUserProvider(userId)),
      data: (user) => UserEditForm(key: ValueKey(user.id), user: user),
    );
  }
}

class UserEditForm extends ConsumerStatefulWidget {
  const UserEditForm({super.key, required this.user});

  final UserRow user;

  @override
  ConsumerState<UserEditForm> createState() => _UserEditFormState();
}

class _UserEditFormState extends ConsumerState<UserEditForm>
    with ServerFieldErrors, DirtyTracking<UserEditForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _phone;
  late bool _active;
  String? _roleId;
  late bool _allLocations;
  late final Set<String> _locationIds;
  bool _saving = false;

  /// 403 / 409 from the server, shown until the next save.
  Object? _blocked;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    final a = u.assignments.isEmpty ? null : u.assignments.first;
    _name = TextEditingController(text: u.name);
    _phone = TextEditingController(text: u.phone ?? '');
    _active = u.isActive;
    _roleId = a?.roleId;
    _allLocations = a == null || a.locationIds == null;
    _locationIds = {...?a?.locationIds};
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool get _isSelf =>
      ref.read(sessionProvider).value?.user?.id == widget.user.id;

  Future<void> _save() async {
    setState(() {
      serverErrors = const {};
      _blocked = null;
    });
    final valid = _formKey.currentState!.validate();
    if (!_allLocations && _locationIds.isEmpty) {
      setState(
        () => serverErrors = {'locationIds': 'Choose at least one location'},
      );
      return;
    }
    if (!valid) return;
    final changes = userPatch(
      widget.user,
      name: _name.text.trim(),
      phone: trimmedOrNull(_phone.text),
      isActive: _active,
      roleId: _roleId,
      locationIds: _allLocations ? null : (_locationIds.toList()..sort()),
    );
    if (changes.isEmpty) {
      markSaved();
      showInfoSnackBar(context, 'No changes to save');
      return;
    }
    setState(() => _saving = true);
    try {
      final saved = await ref
          .read(settingsRepositoryProvider)
          .updateUser(widget.user.id, changes);
      ref.bump(const [DataKind.users]);
      if (_isSelf) {
        try {
          await ref.read(sessionProvider.notifier).reloadMe();
        } catch (_) {}
      }
      if (!mounted) return;
      showInfoSnackBar(context, 'Saved ${saved.name}');
      context.go('/users');
    } catch (e) {
      if (!mounted) return;
      final status = apiError(e)?.statusCode;
      if (status == 403 || status == 409) {
        setState(() => _blocked = e);
      } else {
        showSubmitError(e);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _resetPassword() async {
    final done = await showDialog<bool>(
      context: context,
      builder: (_) => _ResetPasswordDialog(user: widget.user),
    );
    if (done == true && mounted) {
      showInfoSnackBar(
        context,
        'Password changed for ${widget.user.name}; they were signed out '
        'everywhere.',
      );
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final roles = ref.watch(adminRolesProvider);
    final locations = ref.watch(locationsLookupProvider);
    final self = _isSelf;
    final blocked = _blocked;

    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Edit user', style: theme.textTheme.headlineSmall),
                  Text(widget.user.email, style: theme.textTheme.bodyMedium),
                ],
              ),
              OutlinedButton.icon(
                onPressed: _resetPassword,
                icon: const Icon(Icons.password),
                label: const Text('Reset password'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (blocked != null)
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              color: theme.colorScheme.errorContainer,
              child: ListTile(
                leading: Icon(
                  Icons.block,
                  color: theme.colorScheme.onErrorContainer,
                ),
                title: Text(
                  apiError(blocked)?.statusCode == 409
                      ? 'This change would leave the company without an Owner'
                      : 'You cannot make this change',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
                subtitle: Text(
                  errorMessage(blocked),
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Name'),
                      textCapitalization: TextCapitalization.words,
                      forceErrorText: serverError('name'),
                      onChanged: (_) => clearServerError('name'),
                      validator: (v) {
                        final t = v?.trim() ?? '';
                        if (t.isEmpty) return 'Name is required';
                        return t.length < 2
                            ? 'Use at least 2 characters'
                            : null;
                      },
                    ),
                    TextFormField(
                      controller: _phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone (optional)',
                      ),
                      keyboardType: TextInputType.phone,
                      validator: validatePhone,
                      forceErrorText: serverError('phone'),
                      onChanged: (_) => clearServerError('phone'),
                    ),
                  ],
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  subtitle: Text(
                    self
                        ? 'You cannot deactivate yourself'
                        : 'Inactive users cannot sign in',
                  ),
                  value: _active,
                  onChanged: self ? null : (v) => setState(() => _active = v),
                ),
                if (serverError('isActive') != null)
                  Text(
                    serverError('isActive')!,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
              ],
            ),
          ),
          SectionCard(
            title: 'Access in this company',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                switch (roles) {
                  AsyncValue(:final error?, hasValue: false) => ErrorView(
                    error: error,
                    onRetry: () => ref.invalidate(adminRolesProvider),
                  ),
                  AsyncValue(value: final list?) =>
                    DropdownButtonFormField<String>(
                      initialValue: list.any((r) => r.id == _roleId)
                          ? _roleId
                          : null,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Role'),
                      forceErrorText: serverError('roleId'),
                      items: [
                        for (final role in list)
                          DropdownMenuItem(
                            value: role.id,
                            child: Text(
                              role.isSystem
                                  ? role.name
                                  : '${role.name} (custom)',
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        clearServerError('roleId');
                        setState(() => _roleId = v);
                      },
                      validator: (v) => v == null ? 'Choose a role' : null,
                    ),
                  _ => const LinearProgressIndicator(),
                },
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('All locations'),
                  subtitle: const Text(
                    'Turn off to limit the user to specific locations',
                  ),
                  value: _allLocations,
                  onChanged: (v) => setState(() {
                    _allLocations = v;
                    serverErrors = Map.of(serverErrors)..remove('locationIds');
                  }),
                ),
                if (!_allLocations)
                  switch (locations) {
                    AsyncValue(:final error?, hasValue: false) => ErrorView(
                      error: error,
                      onRetry: () => ref.invalidate(locationsLookupProvider),
                    ),
                    AsyncValue(value: final list?) => Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final l in list)
                          FilterChip(
                            label: Text(l.displayName),
                            selected: _locationIds.contains(l.id),
                            onSelected: (on) => setState(() {
                              on
                                  ? _locationIds.add(l.id)
                                  : _locationIds.remove(l.id);
                              serverErrors = Map.of(serverErrors)
                                ..remove('locationIds');
                            }),
                          ),
                      ],
                    ),
                    _ => const LinearProgressIndicator(),
                  },
                if (serverError('locationIds') != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      serverError('locationIds')!,
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
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
                onPressed: _saving ? null : () => leave('/users'),
                child: const Text('Cancel'),
              ),
              BusyButton(
                busy: _saving,
                onPressed: _save,
                label: 'Save changes',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// New password + confirmation fields with show/hide.
class PasswordFields extends StatefulWidget {
  const PasswordFields({
    super.key,
    required this.password,
    required this.confirm,
    this.label = 'New password',
    this.errorText,
    this.onChanged,
  });

  final TextEditingController password;
  final TextEditingController confirm;
  final String label;
  final String? errorText;
  final VoidCallback? onChanged;

  @override
  State<PasswordFields> createState() => _PasswordFieldsState();
}

class _PasswordFieldsState extends State<PasswordFields> {
  bool _obscure = true;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextFormField(
        controller: widget.password,
        obscureText: _obscure,
        autofillHints: const [AutofillHints.newPassword],
        decoration: InputDecoration(
          labelText: widget.label,
          helperText: 'At least 8 characters',
          suffixIcon: IconButton(
            tooltip: _obscure ? 'Show password' : 'Hide password',
            icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _obscure = !_obscure),
          ),
        ),
        forceErrorText: widget.errorText,
        onChanged: (_) => widget.onChanged?.call(),
        validator: (v) {
          if (v == null || v.isEmpty) return 'Enter a password';
          return v.length < 8 ? 'Use at least 8 characters' : null;
        },
      ),
      const SizedBox(height: 16),
      TextFormField(
        controller: widget.confirm,
        obscureText: _obscure,
        decoration: const InputDecoration(labelText: 'Confirm password'),
        validator: (v) =>
            v != widget.password.text ? 'Passwords do not match' : null,
      ),
    ],
  );
}

class _ResetPasswordDialog extends ConsumerStatefulWidget {
  const _ResetPasswordDialog({required this.user});

  final UserRow user;

  @override
  ConsumerState<_ResetPasswordDialog> createState() =>
      _ResetPasswordDialogState();
}

class _ResetPasswordDialogState extends ConsumerState<_ResetPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _saving = false;
  Object? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(settingsRepositoryProvider)
          .resetPassword(widget.user.id, _password.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      insetPadding: dialogInset(context),
      scrollable: true,
      title: Text('Reset password for ${widget.user.name}'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'They will be signed out on every device. Share the new '
                'password securely.',
              ),
              const SizedBox(height: 16),
              PasswordFields(
                password: _password,
                confirm: _confirm,
                errorText: error == null
                    ? null
                    : apiError(error)?.fieldErrors['password'],
              ),
              if (error != null &&
                  apiError(error)?.fieldErrors['password'] == null) ...[
                const SizedBox(height: 12),
                Text(
                  errorMessage(error),
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: const Text('Reset password'),
        ),
      ],
    );
  }
}
