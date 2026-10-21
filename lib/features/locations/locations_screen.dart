import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/india_states.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/adaptive_data_list.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/paged_controller.dart';
import '../../widgets/search_field.dart';
import '../../widgets/state_dropdown.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'location_model.dart';
import 'locations_repository.dart';

class LocationsScreen extends ConsumerStatefulWidget {
  const LocationsScreen({super.key});

  @override
  ConsumerState<LocationsScreen> createState() => _LocationsScreenState();
}

class _LocationsScreenState extends ConsumerState<LocationsScreen> {
  String _query = '';
  late final PagedController<Location> _paged = PagedController(
    (offset, limit) => ref
        .read(locationsRepositoryProvider)
        .list(q: _query, offset: offset, limit: limit),
  );

  @override
  void initState() {
    super.initState();
    _paged.refresh();
  }

  @override
  void dispose() {
    _paged.dispose();
    super.dispose();
  }

  Future<void> _edit([Location? location]) async {
    final saved = await showDialog<Location>(
      context: context,
      builder: (_) => LocationDialog(location: location),
    );
    if (saved != null && mounted) {
      showInfoSnackBar(context, 'Saved "${saved.name}"');
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(
      revisionProvider(DataKind.locations),
      (_, _) => _paged.refresh(),
    );
    ref.listen(activeCompanyIdProvider, (_, _) => _paged.refresh());
    final canManage = ref.watch(permissionsProvider).can(Perm.locationsManage);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Locations',
          subtitle: 'Branches, sites, warehouses and departments',
          actions: [
            if (canManage)
              FilledButton.icon(
                onPressed: _edit,
                icon: const Icon(Icons.add),
                label: const Text('New location'),
              ),
          ],
        ),
        FilterBar(
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: SearchField(
                hintText: 'Search locations',
                onChanged: (q) {
                  _query = q;
                  _paged.refresh();
                },
              ),
            ),
          ],
        ),
        Expanded(
          child: AdaptiveDataList<Location>(
            controller: _paged,
            emptyMessage: 'No locations found.',
            emptyIcon: Icons.location_off_outlined,
            onTap: canManage ? _edit : null,
            columns: [
              TableColumnSpec('Name', (l) => Text(l.name)),
              TableColumnSpec('Code', (l) => Text(l.code ?? '—')),
              TableColumnSpec('Type', (l) => Text(locationTypeLabel(l.type))),
              TableColumnSpec('State', (l) => Text(stateLabel(l.stateCode))),
              TableColumnSpec(
                'Address',
                (l) => ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Text(
                    l.address ?? '—',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              TableColumnSpec('Status', (l) => _ActivePill(active: l.isActive)),
            ],
            cardBuilder: (context, l) => ListCard(
              onTap: canManage ? () => _edit(l) : null,
              leading: const Icon(Icons.location_on_outlined),
              title: Text(l.displayName, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${locationTypeLabel(l.type)} · ${stateName(l.stateCode) ?? l.stateCode}',
              ),
              trailing: l.isActive ? null : const _ActivePill(active: false),
            ),
          ),
        ),
      ],
    );
  }
}

class _ActivePill extends StatelessWidget {
  const _ActivePill({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) => active
      ? const Pill('Active', color: Colors.green)
      : Pill('Inactive', color: Theme.of(context).colorScheme.outline);
}

/// Create or edit a location; pops with the saved [Location].
class LocationDialog extends ConsumerStatefulWidget {
  const LocationDialog({super.key, this.location});

  final Location? location;

  @override
  ConsumerState<LocationDialog> createState() => _LocationDialogState();
}

class _LocationDialogState extends ConsumerState<LocationDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _code;
  late final TextEditingController _address;
  late String _type;
  String? _stateCode;
  late bool _active;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final l = widget.location;
    _name = TextEditingController(text: l?.name);
    _code = TextEditingController(text: l?.code);
    _address = TextEditingController(text: l?.address);
    _type = l?.type ?? 'site';
    _stateCode =
        l?.stateCode ?? ref.read(sessionProvider).value?.company?.stateCode;
    _active = l?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _code.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!_formKey.currentState!.validate()) return;
    final body = <String, dynamic>{
      'type': _type,
      'name': _name.text.trim(),
      'code': trimmedOrNull(_code.text),
      'stateCode': _stateCode,
      'address': trimmedOrNull(_address.text),
      'isActive': _active,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(locationsRepositoryProvider);
      final original = widget.location;
      final saved = original == null
          ? await repo.create(body)
          : await repo.update(original, body);
      ref.bump(const [DataKind.locations]);
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.location != null;
    return AlertDialog(
      title: Text(editing ? 'Edit location' : 'New location'),
      scrollable: true,
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<String>(
                initialValue: _type,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Type'),
                forceErrorText: serverError('type'),
                items: [
                  for (final type in {...locationTypes, _type})
                    DropdownMenuItem(
                      value: type,
                      child: Text(locationTypeLabel(type)),
                    ),
                ],
                onChanged: (v) => setState(() => _type = v ?? _type),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                textCapitalization: TextCapitalization.words,
                forceErrorText: serverError('name'),
                onChanged: (_) => clearServerError('name'),
                validator: (v) => requiredField(v, 'Name'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _code,
                decoration: const InputDecoration(labelText: 'Code (optional)'),
                textCapitalization: TextCapitalization.characters,
                forceErrorText: serverError('code'),
                onChanged: (_) => clearServerError('code'),
              ),
              const SizedBox(height: 16),
              StateDropdown(
                value: _stateCode,
                errorText: serverError('stateCode'),
                onChanged: (v) {
                  clearServerError('stateCode');
                  setState(() => _stateCode = v);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _address,
                decoration: const InputDecoration(
                  labelText: 'Address (optional)',
                ),
                minLines: 2,
                maxLines: 4,
                forceErrorText: serverError('address'),
                onChanged: (_) => clearServerError('address'),
              ),
              if (editing)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
                  value: _active,
                  onChanged: (v) => setState(() => _active = v),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
      ],
    );
  }
}
