import 'package:flutter/material.dart';

import '../../widgets/layout.dart';
import '../../widgets/states.dart';

/// A form dialog with Cancel and a Save button that disables while the save
/// runs. [onSave] throws to keep the dialog open and show the error.
class EditDialog extends StatefulWidget {
  const EditDialog({
    super.key,
    required this.title,
    required this.formKey,
    required this.children,
    required this.onSave,
    this.saveLabel = 'Save',
  });

  final String title;
  final GlobalKey<FormState> formKey;
  final List<Widget> children;
  final Future<void> Function() onSave;
  final String saveLabel;

  @override
  State<EditDialog> createState() => _EditDialogState();
}

class _EditDialogState extends State<EditDialog> {
  bool _saving = false;

  Future<void> _run() async {
    if (_saving || !widget.formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await widget.onSave();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 420,
      child: Form(
        key: widget.formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: widget.children,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(busy: _saving, onPressed: _run, label: widget.saveLabel),
    ],
  );
}

/// Two fields side by side inside a dialog. `FormRow` measures its width with
/// a `LayoutBuilder`, which dialogs cannot size, so dialogs use this.
class FieldPair extends StatelessWidget {
  const FieldPair(this.first, this.second, {super.key});

  final Widget first, second;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: first),
      const SizedBox(width: 12),
      Expanded(child: second),
    ],
  );
}
