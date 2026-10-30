import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/json.dart';
import '../../../core/money.dart';
import '../../../core/permissions.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/picker_field.dart';
import '../../../widgets/search_picker.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../../locations/location_model.dart';
import '../../locations/locations_repository.dart';
import '../../parties/party_model.dart';
import '../../parties/party_picker.dart';
import '../../users/user_models.dart';
import '../../users/users_repository.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/common_models.dart';
import '../models/project_models.dart';
import '../../../widgets/busy.dart';

/// Create (`projectId == null`) or edit a project.
class ProjectFormScreen extends ConsumerWidget {
  const ProjectFormScreen({super.key, this.projectId});

  final String? projectId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = projectId;
    return CGate(
      anyOf: const [CPerm.projectsManage],
      child: id == null
          ? const _ProjectForm()
          : AsyncValueView(
              value: ref.watch(projectProvider(id)),
              onRetry: () => ref.invalidate(projectProvider(id)),
              data: (p) => _ProjectForm(key: ValueKey(p.id), original: p),
            ),
    );
  }
}

class _ProjectForm extends ConsumerStatefulWidget {
  const _ProjectForm({super.key, this.original});

  final Project? original;

  @override
  ConsumerState<_ProjectForm> createState() => _ProjectFormState();
}

class _ProjectFormState extends ConsumerState<_ProjectForm>
    with ServerFieldErrors, DirtyTracking<_ProjectForm> {
  final _formKey = GlobalKey<FormState>();
  late final Project? _p = widget.original;
  late final _code = TextEditingController(text: _p?.code);
  late final _name = TextEditingController(text: _p?.name);
  late final _contract = TextEditingController(
    text: _p == null || _p.contractValue == 0
        ? ''
        : formatPlain(_p.contractValue),
  );
  late final _address = TextEditingController(text: _p?.address);
  late NamedRef? _client = _p?.clientPartyId == null
      ? null
      : NamedRef(id: _p!.clientPartyId!, name: _p.clientName ?? 'Client');
  late NamedRef? _manager = _p?.managerUserId == null
      ? null
      : NamedRef(id: _p!.managerUserId!, name: _p.managerName ?? 'Manager');
  late ProjectStatus _status = _p?.status ?? ProjectStatus.planning;
  late DateTime? _start =
      parseApiDate(_p?.startDate) ?? (_p == null ? today() : null);
  late DateTime? _end = parseApiDate(_p?.endDate);
  late final Set<String> _siteIds = {...?_p?.sites.map((s) => s.id)};
  bool _saving = false;

  bool get _editing => _p != null;

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _contract.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _pickClient() async {
    final party = await pickParty(context, ref, type: PartyType.customer);
    if (party != null) {
      setState(() => _client = NamedRef(id: party.id, name: party.name));
    }
  }

  Future<void> _pickManager() async {
    final repo = ref.read(usersRepositoryProvider);
    final user = await showSearchPicker<UserRow>(
      context: context,
      title: 'Choose the project manager',
      hintText: 'Search name or email',
      search: (q) async => (await repo.users(
        q: q,
        limit: 50,
      )).data.where((u) => u.isActive).toList(),
      titleBuilder: (context, u) => Text(u.name),
      subtitleBuilder: (context, u) => Text(u.email),
    );
    if (user != null) {
      setState(() => _manager = NamedRef(id: user.id, name: user.name));
    }
  }

  Json _body() => {
    'code': _code.text.trim(),
    'name': _name.text.trim(),
    'clientPartyId': _client?.id,
    'managerUserId': _manager?.id,
    'status': _status.api,
    'startDate': _start == null ? null : apiDate(_start!),
    'endDate': _end == null ? null : apiDate(_end!),
    'contractValue': parseNumber(_contract.text) ?? 0,
    'address': trimmedOrNull(_address.text),
    'siteIds': _siteIds.toList(),
  };

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    final repo = ref.read(constructionRepositoryProvider);
    try {
      final saved = _editing
          ? await repo.updateProject(_p!, _body())
          : await repo.createProject(_body());
      ref.bumpC(const [CKind.projects]);
      if (!mounted) return;
      showSuccess(context, 'Project ${saved.code} saved');
      markSaved();
      context.go('/projects/${saved.id}');
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
    final locations = ref.watch(locationsLookupProvider);
    final sites = (locations.value ?? const <Location>[])
        .where(
          (l) => l.type == 'site' && (l.isActive || _siteIds.contains(l.id)),
        )
        .toList();

    return Form(
      key: _formKey,
      onChanged: markDirty,
      child: FormPage(
        maxWidth: 900,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(
              _editing ? 'Edit ${_p!.code}' : 'New project',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          SectionCard(
            title: 'Project',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FormRow(
                  children: [
                    TextFormField(
                      controller: _code,
                      decoration: InputDecoration(
                        labelText: 'Code',
                        hintText: 'e.g. PRJ-001',
                        errorText: serverError('code'),
                      ),
                      textCapitalization: TextCapitalization.characters,
                      validator: (v) => requiredField(v, 'Code'),
                      onChanged: (_) => clearServerError('code'),
                    ),
                    TextFormField(
                      controller: _name,
                      decoration: InputDecoration(
                        labelText: 'Name',
                        errorText: serverError('name'),
                      ),
                      textCapitalization: TextCapitalization.words,
                      validator: (v) => requiredField(v, 'Name'),
                      onChanged: (_) => clearServerError('name'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    _ClearablePicker(
                      label: 'Client (optional)',
                      value: _client?.name,
                      onTap: perms.can(Perm.partiesView) ? _pickClient : null,
                      onClear: () => setState(() => _client = null),
                      errorText: serverError('clientPartyId'),
                    ),
                    _ClearablePicker(
                      label: 'Project manager (optional)',
                      value: _manager?.name,
                      onTap: perms.can(Perm.usersManage) ? _pickManager : null,
                      onClear: () => setState(() => _manager = null),
                      errorText: serverError('managerUserId'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    DropdownButtonFormField<ProjectStatus>(
                      initialValue: _status,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: [
                        for (final s in ProjectStatus.values)
                          DropdownMenuItem(value: s, child: Text(s.label)),
                      ],
                      onChanged: (s) => setState(() => _status = s ?? _status),
                    ),
                    TextFormField(
                      controller: _contract,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      decoration: InputDecoration(
                        labelText: 'Contract value',
                        prefixText: '₹ ',
                        errorText: serverError('contractValue'),
                      ),
                      validator: (v) => optionalNumber(v, min: 0),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FormRow(
                  children: [
                    DateField(
                      label: 'Start date',
                      value: _start,
                      onChanged: (d) => setState(() => _start = d),
                      onCleared: () => setState(() => _start = null),
                      errorText: serverError('startDate'),
                    ),
                    DateField(
                      label: 'End date',
                      value: _end,
                      onChanged: (d) => setState(() => _end = d),
                      onCleared: () => setState(() => _end = null),
                      errorText:
                          serverError('endDate') ??
                          (_start != null &&
                                  _end != null &&
                                  _end!.isBefore(_start!)
                              ? 'Ends before it starts'
                              : null),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _address,
                  decoration: InputDecoration(
                    labelText: 'Address (optional)',
                    errorText: serverError('address'),
                  ),
                  maxLines: 2,
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Sites',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Choose the site locations that belong to this project. A '
                  'site can be in only one project.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 12),
                if (locations.isLoading && !locations.hasValue)
                  const LinearProgressIndicator()
                else if (locations.hasError)
                  Text(
                    'Could not load sites: ${errorMessage(locations.error!)}',
                  )
                else if (sites.isEmpty)
                  const Text(
                    'No site locations yet. Add a location of type "Site" '
                    'first.',
                  )
                else
                  Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final site in sites)
                        FilterChip(
                          label: Text(site.displayName),
                          selected: _siteIds.contains(site.id),
                          materialTapTargetSize: MaterialTapTargetSize.padded,
                          onSelected: (on) => setState(
                            () => on
                                ? _siteIds.add(site.id)
                                : _siteIds.remove(site.id),
                          ),
                        ),
                    ],
                  ),
                if (serverError('siteIds') != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      serverError('siteIds')!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.icon(
              style: bigButton,
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check),
              label: Text(_editing ? 'Save changes' : 'Create project'),
            ),
          ),
        ],
      ),
    );
  }
}

/// A picker tile with a clear button; disabled when [onTap] is null.
class _ClearablePicker extends StatelessWidget {
  const _ClearablePicker({
    required this.label,
    required this.value,
    required this.onTap,
    required this.onClear,
    this.errorText,
  });

  final String label;
  final String? value;
  final VoidCallback? onTap;
  final VoidCallback onClear;
  final String? errorText;

  @override
  Widget build(BuildContext context) {
    final field = PickerField(
      label: label,
      value: value,
      enabled: onTap != null,
      errorText: errorText,
      onTap: onTap ?? () {},
    );
    if (value == null || onTap == null) return field;
    return Row(
      children: [
        Expanded(child: field),
        IconButton(
          tooltip: 'Clear',
          constraints: BoxConstraints.tight(kTapTarget),
          icon: const Icon(Icons.close),
          onPressed: onClear,
        ),
      ],
    );
  }
}
