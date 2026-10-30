import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'settings_models.dart';
import 'settings_repository.dart';
import '../../widgets/busy.dart';

/// `/roles`: built-in roles (read-only, can be duplicated) and custom
/// roles.
class RolesScreen extends ConsumerWidget {
  const RolesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canManage = ref.watch(permissionsProvider).can(Perm.rolesManage);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Roles',
          subtitle: 'What each role may see and do',
          actions: [
            if (canManage)
              FilledButton.icon(
                onPressed: () => context.go('/roles/new'),
                icon: const Icon(Icons.add),
                label: const Text('New role'),
              ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: ref.watch(adminRolesProvider),
            onRetry: () => ref.invalidate(adminRolesProvider),
            data: (roles) => roles.isEmpty
                ? const EmptyView(message: 'No roles yet.')
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: roles.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (context, i) {
                      final role = roles[i];
                      final count = role.permissions.length;
                      return Card(
                        margin: EdgeInsets.zero,
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => context.go('/roles/${role.id}'),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 4,
                                        crossAxisAlignment:
                                            WrapCrossAlignment.center,
                                        children: [
                                          Text(
                                            role.name,
                                            style: theme.textTheme.titleMedium,
                                          ),
                                          if (role.isSystem)
                                            Pill(
                                              'Built-in',
                                              color: theme.colorScheme.tertiary,
                                            ),
                                        ],
                                      ),
                                      if (role.description != null &&
                                          role.description!.isNotEmpty)
                                        Text(
                                          role.description!,
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      Text(
                                        '$count ${count == 1 ? 'permission' : 'permissions'}',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                if (canManage)
                                  IconButton(
                                    tooltip: 'Duplicate',
                                    icon: const Icon(Icons.copy_outlined),
                                    onPressed: () => context.go(
                                      '/roles/new?from=${role.id}',
                                    ),
                                  ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}

/// `/roles/new` (optionally `?from=<roleId>` to duplicate) and
/// `/roles/:id`. Built-in roles open read-only.
class RoleFormScreen extends ConsumerWidget {
  const RoleFormScreen({super.key, this.roleId, this.copyFromId});

  final String? roleId;
  final String? copyFromId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final roles = ref.watch(adminRolesProvider);
    final defs = ref.watch(permissionDefsProvider);
    return switch ((roles, defs)) {
      (AsyncValue(:final error?, hasValue: false), _) ||
      (_, AsyncValue(:final error?, hasValue: false)) => ErrorView(
        error: error,
        onRetry: () {
          ref.invalidate(adminRolesProvider);
          ref.invalidate(permissionDefsProvider);
        },
      ),
      (AsyncValue(value: final r?), AsyncValue(value: final d?)) => () {
        Role? find(String? id) {
          for (final role in r) {
            if (role.id == id) return role;
          }
          return null;
        }

        final original = find(roleId);
        if (roleId != null && original == null) {
          return const EmptyView(
            icon: Icons.search_off,
            message: 'This role could not be found.',
          );
        }
        return RoleForm(
          key: ValueKey('${roleId ?? 'new'}-$copyFromId'),
          role: original,
          copyFrom: find(copyFromId),
          existingNames: [for (final role in r) role.name],
          permissions: d,
        );
      }(),
      _ => const LoadingView(),
    };
  }
}

class RoleForm extends ConsumerStatefulWidget {
  const RoleForm({
    super.key,
    required this.permissions,
    required this.existingNames,
    this.role,
    this.copyFrom,
  });

  /// Editing this role; `null` creates one.
  final Role? role;

  /// Pre-fills a new role from this one.
  final Role? copyFrom;
  final List<String> existingNames;
  final List<PermissionDef> permissions;

  @override
  ConsumerState<RoleForm> createState() => _RoleFormState();
}

class _RoleFormState extends ConsumerState<RoleForm>
    with ServerFieldErrors, DirtyTracking<RoleForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _description;
  late final Set<String> _selected;
  bool _saving = false;

  Role? get _role => widget.role;
  bool get _readOnly =>
      (_role?.isSystem ?? false) ||
      !ref.read(permissionsProvider).can(Perm.rolesManage);

  @override
  void initState() {
    super.initState();
    final source = _role ?? widget.copyFrom;
    _name = TextEditingController(
      text:
          _role?.name ??
          (widget.copyFrom == null
              ? ''
              : copyName(widget.copyFrom!.name, widget.existingNames)),
    );
    _description = TextEditingController(text: source?.description ?? '');
    _selected = {...?source?.permissions};
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    super.dispose();
  }

  void _toggle(Iterable<String> keys, bool on) => setState(() {
    on ? _selected.addAll(keys) : _selected.removeAll(keys);
    serverErrors = Map.of(serverErrors)..remove('permissions');
  });

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    if (_selected.isEmpty) {
      setState(
        () => serverErrors = {'permissions': 'Choose at least one permission'},
      );
      return;
    }
    final input = RoleInput(
      name: _name.text.trim(),
      description: trimmedOrNull(_description.text),
      permissions: _selected,
    );
    setState(() => _saving = true);
    try {
      final repo = ref.read(settingsRepositoryProvider);
      final saved = _role == null
          ? await repo.createRole(input)
          : await repo.updateRole(_role!, input);
      ref.bump(const [DataKind.users]);
      try {
        // Editing a role you hold changes your own permissions.
        await ref.read(sessionProvider.notifier).reloadMe();
      } catch (_) {}
      if (!mounted) return;
      markSaved();
      showInfoSnackBar(context, 'Saved role "${saved.name}"');
      context.go('/roles');
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => track(_buildBody(context));

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final readOnly = _readOnly;
    final canManage = ref.watch(permissionsProvider).can(Perm.rolesManage);
    final modules = groupPermissions(widget.permissions);
    final known = {for (final d in widget.permissions) d.key};
    final unknown = _selected.where((k) => !known.contains(k)).toList()..sort();
    final title = _role == null
        ? (widget.copyFrom == null ? 'New role' : 'Duplicate role')
        : readOnly
        ? _role!.name
        : 'Edit role';

    final moduleCards = [
      for (final MapEntry(key: module, value: defs) in modules.entries)
        _ModuleCard(
          module: module,
          defs: defs,
          selected: _selected,
          enabled: !readOnly,
          onToggle: _toggle,
        ),
    ];

    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        maxWidth: 1100,
        children: [
          Text(title, style: theme.textTheme.headlineSmall),
          const SizedBox(height: 16),
          if (_role?.isSystem ?? false)
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    const Text(
                      'Built-in roles cannot be changed. Duplicate it to make '
                      'an editable copy.',
                    ),
                    if (canManage)
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            context.go('/roles/new?from=${_role!.id}'),
                        icon: const Icon(Icons.copy_outlined),
                        label: const Text('Duplicate'),
                      ),
                  ],
                ),
              ),
            ),
          SectionCard(
            child: FormRow(
              children: [
                TextFormField(
                  controller: _name,
                  enabled: !readOnly,
                  decoration: const InputDecoration(labelText: 'Role name'),
                  textCapitalization: TextCapitalization.words,
                  forceErrorText: serverError('name'),
                  onChanged: (_) => clearServerError('name'),
                  validator: (v) {
                    final t = v?.trim() ?? '';
                    if (t.isEmpty) return 'Name is required';
                    return t.length < 2 ? 'Use at least 2 characters' : null;
                  },
                ),
                TextFormField(
                  controller: _description,
                  enabled: !readOnly,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                  ),
                  forceErrorText: serverError('description'),
                  onChanged: (_) => clearServerError('description'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              runSpacing: 4,
              children: [
                Text('Permissions', style: theme.textTheme.titleMedium),
                Text(
                  '${_selected.length} of ${widget.permissions.length} chosen',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (serverError('permissions') != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                serverError('permissions')!,
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 840) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: moduleCards,
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final column in [0, 1]) ...[
                    if (column == 1) const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (var i = column; i < moduleCards.length; i += 2)
                            moduleCards[i],
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
          if (unknown.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Text(
                'Also kept: ${unknown.join(', ')}',
                style: theme.textTheme.bodySmall,
              ),
            ),
          Wrap(
            alignment: WrapAlignment.end,
            spacing: 12,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: _saving ? null : () => leave('/roles'),
                child: Text(readOnly ? 'Back' : 'Cancel'),
              ),
              if (!readOnly)
                BusyButton(
                  busy: _saving,
                  onPressed: _save,
                  label: _role == null ? 'Create role' : 'Save changes',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ModuleCard extends StatelessWidget {
  const _ModuleCard({
    required this.module,
    required this.defs,
    required this.selected,
    required this.enabled,
    required this.onToggle,
  });

  final String module;
  final List<PermissionDef> defs;
  final Set<String> selected;
  final bool enabled;
  final void Function(Iterable<String> keys, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final state = moduleSelection(defs, selected);
    final count = defs.where((d) => selected.contains(d.key)).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          CheckboxListTile(
            tristate: true,
            value: state,
            title: Text(module, style: Theme.of(context).textTheme.titleSmall),
            subtitle: Text('$count of ${defs.length} · select all'),
            onChanged: enabled
                ? (_) => onToggle(defs.map((d) => d.key), state != true)
                : null,
          ),
          const Divider(height: 1),
          for (final d in defs)
            CheckboxListTile(
              dense: true,
              value: selected.contains(d.key),
              title: Text(d.label),
              subtitle: Text(d.key),
              onChanged: enabled ? (v) => onToggle([d.key], v ?? false) : null,
            ),
        ],
      ),
    );
  }
}
