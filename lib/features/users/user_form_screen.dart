import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../locations/location_model.dart';
import '../locations/locations_repository.dart';
import 'user_models.dart';
import 'users_repository.dart';
import '../../widgets/busy.dart';

/// `POST /users`: a new user with one role and a location scope.
class UserFormScreen extends ConsumerStatefulWidget {
  const UserFormScreen({super.key});

  @override
  ConsumerState<UserFormScreen> createState() => _UserFormScreenState();
}

class _UserFormScreenState extends ConsumerState<UserFormScreen>
    with ServerFieldErrors, DirtyTracking<UserFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  String? _roleId;
  bool _allLocations = true;
  final Set<String> _locationIds = {};
  bool _saving = false;
  bool _obscure = true;

  @override
  void dispose() {
    for (final c in [_name, _email, _phone, _password]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    final valid = _formKey.currentState!.validate();
    if (!_allLocations && _locationIds.isEmpty) {
      setState(
        () => serverErrors = {
          ...serverErrors,
          'locationIds': 'Choose at least one location',
        },
      );
      return;
    }
    if (!valid) return;
    setState(() => _saving = true);
    try {
      final user = await ref
          .read(usersRepositoryProvider)
          .create(
            NewUser(
              name: _name.text.trim(),
              email: _email.text.trim(),
              phone: trimmedOrNull(_phone.text),
              password: _password.text,
              roleId: _roleId!,
              locationIds: _allLocations ? null : _locationIds.toList(),
            ),
          );
      ref.bump(const [DataKind.users]);
      if (!mounted) return;
      markSaved();
      showInfoSnackBar(context, 'Created ${user.name}');
      context.go('/users');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final roles = ref.watch(rolesProvider);
    final locations = ref.watch(locationsLookupProvider);
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        children: [
          Text('New user', style: theme.textTheme.headlineSmall),
          const SizedBox(height: 16),
          SectionCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
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
                      controller: _email,
                      decoration: const InputDecoration(labelText: 'Email'),
                      keyboardType: TextInputType.emailAddress,
                      forceErrorText: serverError('email'),
                      onChanged: (_) => clearServerError('email'),
                      validator: validateEmail,
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
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: 'Initial password',
                    helperText: 'At least 8 characters; share it securely',
                    suffixIcon: IconButton(
                      tooltip: _obscure ? 'Show password' : 'Hide password',
                      icon: Icon(
                        _obscure ? Icons.visibility : Icons.visibility_off,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  forceErrorText: serverError('password'),
                  onChanged: (_) => clearServerError('password'),
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Password is required';
                    if (v.length < 8) return 'Use at least 8 characters';
                    return null;
                  },
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Access',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                switch (roles) {
                  AsyncValue(:final error?, hasValue: false) => ErrorView(
                    error: error,
                    onRetry: () => ref.invalidate(rolesProvider),
                  ),
                  AsyncValue(:final value?) => _RoleDropdown(
                    roles: value,
                    value: _roleId,
                    errorText: serverError('roleId'),
                    onChanged: (v) {
                      clearServerError('roleId');
                      setState(() => _roleId = v);
                    },
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
                  _LocationChips(
                    locations: locations,
                    selected: _locationIds,
                    errorText: serverError('locationIds'),
                    onToggle: (id, on) => setState(() {
                      on ? _locationIds.add(id) : _locationIds.remove(id);
                      serverErrors = Map.of(serverErrors)
                        ..remove('locationIds');
                    }),
                    onRetry: () => ref.invalidate(locationsLookupProvider),
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
              BusyButton(busy: _saving, onPressed: _save, label: 'Create user'),
            ],
          ),
        ],
      ),
    );
  }
}

class _RoleDropdown extends StatelessWidget {
  const _RoleDropdown({
    required this.roles,
    required this.value,
    required this.onChanged,
    this.errorText,
  });

  final List<Role> roles;
  final String? value;
  final ValueChanged<String?> onChanged;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: roles.any((r) => r.id == value) ? value : null,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Role'),
      forceErrorText: errorText,
      items: [
        for (final role in roles)
          DropdownMenuItem(
            value: role.id,
            child: Text(
              role.description == null || role.description!.isEmpty
                  ? role.name
                  : '${role.name} — ${role.description}',
              overflow: TextOverflow.ellipsis,
            ),
          ),
      ],
      onChanged: onChanged,
      validator: (v) => v == null ? 'Choose a role' : null,
    );
  }
}

class _LocationChips extends StatelessWidget {
  const _LocationChips({
    required this.locations,
    required this.selected,
    required this.onToggle,
    required this.onRetry,
    this.errorText,
  });

  final AsyncValue<List<Location>> locations;
  final Set<String> selected;
  final void Function(String id, bool selected) onToggle;
  final VoidCallback onRetry;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = locations.value;
    if (list == null) {
      return locations.hasError
          ? ErrorView(error: locations.error!, onRetry: onRetry)
          : const LinearProgressIndicator();
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final location in list)
              FilterChip(
                label: Text(location.displayName),
                selected: selected.contains(location.id),
                onSelected: (on) => onToggle(location.id, on),
              ),
          ],
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              errorText!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }
}
