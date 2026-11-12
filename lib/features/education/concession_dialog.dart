import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import 'education_models.dart';
import 'education_repository.dart';

/// Adds a concession on one fee head for a student. Pops `true`.
class ConcessionDialog extends ConsumerStatefulWidget {
  const ConcessionDialog({super.key, required this.studentId});

  final String studentId;

  @override
  ConsumerState<ConcessionDialog> createState() => _ConcessionDialogState();
}

class _ConcessionDialogState extends ConsumerState<ConcessionDialog>
    with ServerFieldErrors {
  final _formKey = GlobalKey<FormState>();
  final _value = TextEditingController();
  final _reason = TextEditingController();
  String? _headId;
  String _kind = 'percent';
  bool _saving = false;

  @override
  void dispose() {
    _value.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !validateAndReveal(_formKey)) return;
    setState(() => _saving = true);
    try {
      await ref.read(eduRepositoryProvider).addConcession(widget.studentId, {
        'headId': _headId,
        'kind': _kind,
        'value': parseNumber(_value.text),
        'reason': _reason.text.trim(),
      });
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) showSubmitError(e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final heads = ref.watch(eduHeadsProvider).value ?? const <FeeHead>[];
    return AlertDialog(
      title: const Text('Add concession'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _headId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Fee head'),
                  validator: (v) => v == null ? 'Choose a fee head' : null,
                  items: [
                    for (final h in heads)
                      if (h.isActive)
                        DropdownMenuItem(value: h.id, child: Text(h.name)),
                  ],
                  onChanged: (v) => setState(() => _headId = v),
                ),
                const SizedBox(height: 12),
                FormRow(
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: _kind,
                      decoration: const InputDecoration(labelText: 'Type'),
                      items: const [
                        DropdownMenuItem(
                          value: 'percent',
                          child: Text('Percent off'),
                        ),
                        DropdownMenuItem(
                          value: 'amount',
                          child: Text('Amount off'),
                        ),
                      ],
                      onChanged: (v) => setState(() => _kind = v ?? 'percent'),
                    ),
                    TextFormField(
                      controller: _value,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      decoration: InputDecoration(
                        labelText: _kind == 'percent' ? 'Percent' : 'Amount',
                        helperText: _kind == 'amount'
                            ? 'Taken off this head in every instalment'
                            : null,
                        errorText: serverError('value'),
                      ),
                      validator: (v) {
                        final n = parseNumber(v ?? '');
                        if (n == null || n <= 0) return 'Enter a number';
                        if (_kind == 'percent' && n > 100) return 'At most 100';
                        return null;
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _reason,
                  decoration: InputDecoration(
                    labelText: 'Reason',
                    errorText: serverError('reason'),
                  ),
                  validator: (v) => requiredField(v, 'Reason'),
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
        BusyButton(
          busy: _saving,
          onPressed: _saving ? null : _save,
          label: 'Add',
        ),
      ],
    );
  }
}
