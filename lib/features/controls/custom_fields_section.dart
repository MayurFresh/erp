import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/picker_field.dart';
import '../../widgets/form_support.dart';
import 'controls_models.dart';
import 'controls_repository.dart';

/// Active and inactive fields of an entity, for showing stored values.
final customFieldsAllProvider = FutureProvider.autoDispose
    .family<List<CustomField>, String>((ref, entity) {
      return ref
          .watch(controlsRepositoryProvider)
          .customFields(entity, includeInactive: true);
    });

/// Body helper: the `custom` value of a PATCH. Keys that had a value in
/// [original] and are gone from [values] are sent as `null` (clears them).
Json customPatch(Json original, Json values) => {
  ...values,
  for (final key in original.keys)
    if (!values.containsKey(key)) key: null,
};

/// Form section that renders the active custom fields of [entity] and edits
/// [values] (a `key → string|num|bool` map holding only keys with a value).
/// Server `custom.<key>` errors in [errors] show under their field. Renders
/// nothing when the entity has no active fields (or they fail to load).
class CustomFieldsSection extends ConsumerWidget {
  const CustomFieldsSection({
    super.key,
    required this.entity,
    required this.values,
    required this.onChanged,
    this.errors = const {},
  });

  final String entity;
  final Json values;
  final ValueChanged<Json> onChanged;

  /// Field errors keyed as the API returns them (`custom.<key>`).
  final Map<String, String> errors;

  void _set(String key, Object? value) {
    final next = Json.of(values);
    if (value == null || (value is String && value.trim().isEmpty)) {
      next.remove(key);
    } else {
      next[key] = value;
    }
    onChanged(next);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fields = (ref.watch(customFieldsProvider(entity)).value ?? const [])
        .where((f) => f.isActive)
        .toList();
    if (fields.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Additional details',
      child: FormRow(
        children: [
          for (final f in fields)
            _FieldInput(
              key: ValueKey('custom-${f.key}'),
              field: f,
              value: values[f.key],
              error: errors['custom.${f.key}'],
              onChanged: (v) => _set(f.key, v),
            ),
        ],
      ),
    );
  }
}

class _FieldInput extends StatelessWidget {
  const _FieldInput({
    super.key,
    required this.field,
    required this.value,
    required this.error,
    required this.onChanged,
  });

  final CustomField field;
  final Object? value;
  final String? error;
  final ValueChanged<Object?> onChanged;

  String get _label => field.required ? '${field.label} *' : field.label;

  String? _required(Object? v) =>
      field.required && (v == null || (v is String && v.trim().isEmpty))
      ? '${field.label} is required'
      : null;

  @override
  Widget build(BuildContext context) {
    switch (field.type) {
      case 'number':
        return TextFormField(
          initialValue: value == null ? '' : formatPlain(value as num),
          keyboardType: decimalKeyboard,
          inputFormatters: [decimalInput(decimals: 4)],
          decoration: InputDecoration(labelText: _label),
          forceErrorText: error,
          validator: (v) {
            final text = v?.trim() ?? '';
            if (text.isEmpty) return _required(null);
            return parseNumber(text) == null ? 'Enter a number' : null;
          },
          onChanged: (v) => onChanged(parseNumber(v.trim())),
        );
      case 'date':
        final text = value as String?;
        return PickerField(
          label: _label,
          value: text == null ? null : formatDate(text),
          icon: Icons.calendar_today_outlined,
          errorText: error,
          validator: () => _required(text),
          onTap: () async {
            final now = DateTime.now();
            final picked = await showDatePicker(
              context: context,
              initialDate: DateTime.tryParse(text ?? '') ?? now,
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (picked != null) onChanged(apiDate(picked));
          },
        );
      case 'boolean':
        return FormField<bool>(
          initialValue: value as bool?,
          validator: (_) => field.required && value == null
              ? '${field.label} is required'
              : null,
          builder: (state) => InputDecorator(
            decoration: InputDecoration(
              labelText: _label,
              errorText: error ?? state.errorText,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool?>(
                emptySelectionAllowed: true,
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: true, label: Text('Yes')),
                  ButtonSegment(value: false, label: Text('No')),
                ],
                selected: {?(value as bool?)},
                onSelectionChanged: (s) =>
                    onChanged(s.isEmpty ? null : s.first),
              ),
            ),
          ),
        );
      case 'select':
        final current = value as String?;
        final options = [
          ...field.options,
          if (current != null && !field.options.contains(current)) current,
        ];
        return DropdownButtonFormField<String>(
          initialValue: current,
          isExpanded: true,
          decoration: InputDecoration(labelText: _label),
          forceErrorText: error,
          items: [
            for (final o in options) DropdownMenuItem(value: o, child: Text(o)),
          ],
          validator: _required,
          onChanged: onChanged,
        );
      default:
        return TextFormField(
          initialValue: value as String? ?? '',
          maxLength: 500,
          decoration: InputDecoration(labelText: _label),
          forceErrorText: error,
          validator: _required,
          onChanged: onChanged,
        );
    }
  }
}

/// Read-only card of an entity's custom values for detail screens.
class CustomValuesCard extends ConsumerWidget {
  const CustomValuesCard({
    super.key,
    required this.entity,
    required this.custom,
  });

  final String entity;
  final Json custom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (custom.isEmpty) return const SizedBox.shrink();
    final fields = ref.watch(customFieldsAllProvider(entity)).value;
    if (fields == null) return const SizedBox.shrink();
    final shown = [
      for (final f in fields)
        if (custom[f.key] != null) f,
    ];
    if (shown.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Additional details',
      child: Wrap(
        spacing: 32,
        runSpacing: 12,
        children: [
          for (final f in shown)
            LabeledValue(
              f.label,
              f.type == 'date'
                  ? formatDate(custom[f.key])
                  : customValueText(f, custom[f.key]),
            ),
        ],
      ),
    );
  }
}
