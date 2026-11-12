import 'package:flutter/material.dart';

import '../../core/design_tokens.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'hr_widgets.dart';

enum HrFieldKind { text, number, date, multiline, toggle, choice }

/// One input of an [HrFormDialog].
class HrField {
  const HrField(
    this.key,
    this.label, {
    this.kind = HrFieldKind.text,
    this.required = false,
    this.initial,
    this.options = const [],
    this.readOnly = false,
  });

  final String key;
  final String label;
  final HrFieldKind kind;
  final bool required;
  final Object? initial;

  /// For [HrFieldKind.choice]: value and label pairs.
  final List<(String, String)> options;
  final bool readOnly;
}

/// A small form in a dialog. [onSubmit] gets only the fields that have a
/// value; a thrown error is shown and the dialog stays open.
class HrFormDialog extends StatefulWidget {
  const HrFormDialog({
    super.key,
    required this.title,
    required this.fields,
    required this.onSubmit,
    this.action = 'Save',
    this.intro,
  });

  final String title, action;
  final String? intro;
  final List<HrField> fields;
  final Future<void> Function(Map<String, Object?> values) onSubmit;

  @override
  State<HrFormDialog> createState() => _HrFormDialogState();
}

class _HrFormDialogState extends State<HrFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _ctl = <String, TextEditingController>{};
  final _flags = <String, bool>{};
  final _picks = <String, String?>{};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    for (final f in widget.fields) {
      switch (f.kind) {
        case HrFieldKind.toggle:
          _flags[f.key] = f.initial == true;
        case HrFieldKind.choice:
          _picks[f.key] = f.initial?.toString();
        default:
          _ctl[f.key] = TextEditingController(text: f.initial?.toString() ?? '');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _ctl.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    final out = <String, Object?>{};
    for (final f in widget.fields) {
      switch (f.kind) {
        case HrFieldKind.toggle:
          out[f.key] = _flags[f.key];
        case HrFieldKind.choice:
          if (_picks[f.key] != null) out[f.key] = _picks[f.key];
        case HrFieldKind.number:
          final n = parseAmount(_ctl[f.key]!.text);
          if (n != null) out[f.key] = n;
        default:
          final t = trimmedOrNull(_ctl[f.key]!.text);
          if (t != null) out[f.key] = t;
      }
    }
    setState(() => _saving = true);
    try {
      await widget.onSubmit(out);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  Widget _input(HrField f) {
    switch (f.kind) {
      case HrFieldKind.toggle:
        return SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(f.label),
          value: _flags[f.key]!,
          onChanged: (v) => setState(() => _flags[f.key] = v),
        );
      case HrFieldKind.choice:
        return DropdownButtonFormField<String>(
          initialValue: _picks[f.key],
          isExpanded: true,
          decoration: InputDecoration(labelText: f.required ? '${f.label} *' : f.label),
          items: [
            for (final o in f.options) DropdownMenuItem(value: o.$1, child: Text(o.$2)),
          ],
          onChanged: (v) => setState(() => _picks[f.key] = v),
          validator: (v) => f.required && v == null ? 'Required' : null,
        );
      case HrFieldKind.date:
        return HrDateField(controller: _ctl[f.key]!, label: f.label, required: f.required);
      case HrFieldKind.number:
        return TextFormField(
          controller: _ctl[f.key],
          readOnly: f.readOnly,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          decoration: InputDecoration(labelText: f.required ? '${f.label} *' : f.label),
          validator: (v) {
            if (f.required && (v == null || v.trim().isEmpty)) return 'Required';
            if (v != null && v.trim().isNotEmpty && parseAmount(v) == null) return 'Enter a number';
            return null;
          },
        );
      default:
        return TextFormField(
          controller: _ctl[f.key],
          readOnly: f.readOnly,
          maxLines: f.kind == HrFieldKind.multiline ? 2 : 1,
          decoration: InputDecoration(labelText: f.required ? '${f.label} *' : f.label),
          validator: f.required ? (v) => requiredField(v, f.label) : null,
        );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 400,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.intro != null)
              Padding(
                padding: const EdgeInsets.only(bottom: Space.md),
                child: Text(widget.intro!),
              ),
            for (final f in widget.fields) ...[
              _input(f),
              const SizedBox(height: Space.md),
            ],
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _save, label: widget.action),
    ],
  );
}

/// Opens an [HrFormDialog]; true when it saved.
Future<bool> showHrForm(
  BuildContext context, {
  required String title,
  required List<HrField> fields,
  required Future<void> Function(Map<String, Object?>) onSubmit,
  String action = 'Save',
  String? intro,
}) async =>
    await showFormDialog<bool>(
      context: context,
      builder: (_) => HrFormDialog(
        title: title,
        fields: fields,
        onSubmit: onSubmit,
        action: action,
        intro: intro,
      ),
    ) ??
    false;

/// Confirms an action; true when accepted.
Future<bool> hrConfirm(BuildContext context, String title, String body, String action) async =>
    await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(c).pop(true), child: Text(action)),
        ],
      ),
    ) ??
    false;
