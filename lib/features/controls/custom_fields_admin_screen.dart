import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import 'controls_models.dart';
import 'controls_repository.dart';
import 'custom_fields_section.dart';

final _adminFieldsProvider = FutureProvider.autoDispose
    .family<List<CustomField>, String>((ref, entity) {
      ref.watch(activeCompanyIdProvider);
      return ref
          .watch(controlsRepositoryProvider)
          .customFields(entity, includeInactive: true);
    });

/// `/custom-fields` (company.manage): fields per entity.
class CustomFieldsAdminScreen extends ConsumerStatefulWidget {
  const CustomFieldsAdminScreen({super.key});

  @override
  ConsumerState<CustomFieldsAdminScreen> createState() =>
      _CustomFieldsAdminScreenState();
}

class _CustomFieldsAdminScreenState
    extends ConsumerState<CustomFieldsAdminScreen> {
  String _entity = 'item';

  void _refresh() {
    ref.invalidate(_adminFieldsProvider(_entity));
    ref.invalidate(customFieldsProvider(_entity));
    ref.invalidate(customFieldsAllProvider(_entity));
  }

  Future<void> _edit([CustomField? field]) async {
    final saved = await showFormDialog<bool>(
      context: context,
      builder: (_) => _FieldDialog(entity: _entity, field: field),
    );
    if (saved == true) _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final fields = ref.watch(_adminFieldsProvider(_entity));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Custom fields',
          subtitle: 'Extra details on items, parties and documents',
          actions: [
            FilledButton.icon(
              onPressed: _edit,
              icon: const Icon(Icons.add),
              label: const Text('Add field'),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: [
                for (final e in customFieldEntities.entries)
                  ButtonSegment(value: e.key, label: Text(e.value)),
              ],
              selected: {_entity},
              onSelectionChanged: (v) => setState(() => _entity = v.first),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: AsyncValueView(
            value: fields,
            onRetry: _refresh,
            data: (rows) => rows.isEmpty
                ? const EmptyView(
                    icon: Icons.tune,
                    message: 'No custom fields for this record type yet.',
                  )
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                    children: [
                      for (final f in rows)
                        Card(
                          child: ListTile(
                            onTap: () => _edit(f),
                            title: Text(f.label),
                            subtitle: Text(
                              [
                                f.key,
                                customFieldTypes[f.type] ?? f.type,
                                if (f.required) 'required',
                                if (f.showOnPrint) 'on print',
                                if (!f.isActive) 'inactive',
                              ].join(' · '),
                            ),
                            trailing: const Icon(Icons.edit_outlined),
                          ),
                        ),
                    ],
                  ),
          ),
        ),
      ],
    );
  }
}

class _FieldDialog extends ConsumerStatefulWidget {
  const _FieldDialog({required this.entity, this.field});

  final String entity;
  final CustomField? field;

  @override
  ConsumerState<_FieldDialog> createState() => _FieldDialogState();
}

class _FieldDialogState extends ConsumerState<_FieldDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  late final _key = TextEditingController(text: widget.field?.key);
  late final _label = TextEditingController(text: widget.field?.label);
  late final _options = TextEditingController(
    text: widget.field?.options.join('\n'),
  );
  late final _sort = TextEditingController(
    text: '${widget.field?.sortOrder ?? 0}',
  );
  late String _type = widget.field?.type ?? 'text';
  late bool _required = widget.field?.required ?? false;
  late bool _print = widget.field?.showOnPrint ?? false;
  late bool _active = widget.field?.isActive ?? true;
  bool _saving = false;

  bool get _editing => widget.field != null;

  @override
  void dispose() {
    _key.dispose();
    _label.dispose();
    _options.dispose();
    _sort.dispose();
    super.dispose();
  }

  List<String> get _optionList => _options.text
      .split(RegExp(r'[\n,]'))
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Future<void> _save() async {
    setState(() => serverErrors = const {});
    if (!validateAndReveal(_formKey)) return;
    final body = <String, dynamic>{
      'label': _label.text.trim(),
      if (_type == 'select') 'options': _optionList,
      'required': _required,
      'showOnPrint': _print,
      'sortOrder': int.tryParse(_sort.text.trim()) ?? 0,
      if (_editing) 'isActive': _active,
      if (!_editing) 'entity': widget.entity,
      if (!_editing) 'key': _key.text.trim(),
      if (!_editing) 'type': _type,
    };
    setState(() => _saving = true);
    try {
      final repo = ref.read(controlsRepositoryProvider);
      if (_editing) {
        await repo.updateCustomField(widget.field!.id, body);
      } else {
        await repo.createCustomField(body);
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(_editing ? 'Edit field' : 'Add field'),
    content: SizedBox(
      width: 480,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _key,
                enabled: !_editing,
                decoration: const InputDecoration(
                  labelText: 'Key',
                  helperText: 'Lowercase letters, digits, underscore',
                ),
                forceErrorText: serverError('key'),
                validator: (v) =>
                    RegExp(r'^[a-z][a-z0-9_]{1,29}$').hasMatch(v?.trim() ?? '')
                    ? null
                    : 'Use 2–30 characters: a–z, 0–9, _ (start with a letter)',
              ),
              TextFormField(
                controller: _label,
                maxLength: 60,
                decoration: const InputDecoration(labelText: 'Label'),
                forceErrorText: serverError('label'),
                validator: (v) => requiredField(v, 'Label'),
              ),
              DropdownButtonFormField<String>(
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: [
                  for (final e in customFieldTypes.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: _editing
                    ? null
                    : (v) => setState(() => _type = v ?? _type),
              ),
              if (_type == 'select') ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _options,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Choices',
                    helperText: 'One per line (1–50 choices)',
                  ),
                  forceErrorText: serverError('options'),
                  validator: (_) => _optionList.isEmpty
                      ? 'Add at least one choice'
                      : _optionList.length > 50
                      ? 'At most 50 choices'
                      : null,
                ),
              ],
              const SizedBox(height: 12),
              TextFormField(
                controller: _sort,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Sort order'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Required'),
                value: _required,
                onChanged: (v) => setState(() => _required = v),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Show on printed invoice'),
                value: _print,
                onChanged: (v) => setState(() => _print = v),
              ),
              if (_editing)
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
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: 'Save'),
    ],
  );
}
