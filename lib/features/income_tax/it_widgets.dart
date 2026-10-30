import 'package:flutter/material.dart';

import '../../core/money.dart';
import '../../widgets/layout.dart';

/// "Unverified" badge for a response with a non-empty `unverified` list;
/// tap to see which figures. Nothing when [items] is empty.
class UnverifiedNote extends StatelessWidget {
  const UnverifiedNote(this.items, {super.key});

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Tooltip(
          message: items.join('\n'),
          child: InkWell(
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Unverified figures'),
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'These rates, caps or dates have not been checked '
                        'against the current law. Confirm them before relying '
                        'on the result.',
                      ),
                      const SizedBox(height: 8),
                      for (final i in items) Text('• $i'),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('OK'),
                  ),
                ],
              ),
            ),
            child: Pill('Unverified', color: Colors.orange.shade800),
          ),
        ),
      ),
    );
  }
}

/// Asks for a mandatory reason; `null` when dismissed.
Future<String?> askReasonDialog(
  BuildContext context, {
  required String title,
  String? helper,
  String confirmLabel = 'Confirm',
}) => showDialog<String>(
  context: context,
  builder: (_) =>
      _ReasonDialog(title: title, helper: helper, confirmLabel: confirmLabel),
);

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog({
    required this.title,
    required this.helper,
    required this.confirmLabel,
  });

  final String title;
  final String? helper;
  final String confirmLabel;

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: TextFormField(
          controller: _reason,
          autofocus: true,
          maxLength: 500,
          decoration: InputDecoration(
            labelText: 'Reason',
            helperText: widget.helper,
            helperMaxLines: 3,
          ),
          validator: (v) => (v ?? '').trim().isEmpty ? 'Enter a reason' : null,
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Keep'),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, _reason.text.trim());
          }
        },
        child: Text(widget.confirmLabel),
      ),
    ],
  );
}

/// A date button bounded as the other statutory forms (2017 to next year).
Future<DateTime?> pickBoundedDate(
  BuildContext context,
  DateTime initial, {
  DateTime? first,
  DateTime? last,
  String? help,
}) {
  final now = DateTime.now();
  final lo = first ?? DateTime(2017);
  var hi = last ?? DateTime(now.year + 1, 12, 31);
  if (hi.isBefore(lo)) hi = lo;
  var init = initial;
  if (init.isBefore(lo)) init = lo;
  if (init.isAfter(hi)) init = hi;
  return showDatePicker(
    context: context,
    initialDate: init,
    firstDate: lo,
    lastDate: hi,
    helpText: help,
  );
}

class DateButton extends StatelessWidget {
  const DateButton({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.first,
    this.last,
    this.errorText,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime> onChanged;
  final DateTime? first;
  final DateTime? last;
  final String? errorText;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      OutlinedButton.icon(
        onPressed: () async {
          final d = await pickBoundedDate(
            context,
            value ?? DateTime.now(),
            first: first,
            last: last,
          );
          if (d != null) onChanged(d);
        },
        icon: const Icon(Icons.event_outlined),
        label: Text(
          value == null ? label : '$label: ${formatDate(apiDate(value!))}',
          overflow: TextOverflow.ellipsis,
        ),
      ),
      if (errorText != null)
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 4),
          child: Text(
            errorText!,
            style: TextStyle(
              color: Theme.of(context).colorScheme.error,
              fontSize: 12,
            ),
          ),
        ),
    ],
  );
}
