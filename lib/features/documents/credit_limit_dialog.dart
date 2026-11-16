import 'package:flutter/material.dart';

import '../../core/api_exception.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/states.dart';

/// The API error when a customer document would pass the credit limit, else null.
ApiException? creditLimitError(Object error) {
  final api = apiError(error);
  return api != null && api.code == 'CREDIT_LIMIT_EXCEEDED' ? api : null;
}

/// Shows the limit, what the customer owes, this document and the excess.
/// Returns true only when the user chose "Bill anyway" (offered when [canOverride]).
Future<bool> confirmCreditLimit(
  BuildContext context,
  ApiException error, {
  required bool canOverride,
  String document = 'bill',
}) async {
  double n(String k) => asDouble(error.details[k]);
  final chosen = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Credit limit exceeded'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Row('Credit limit', formatMoney(n('creditLimit'))),
            _Row('Already owes', formatMoney(n('owes'))),
            _Row('This $document', formatMoney(n('thisDocument'))),
            _Row('Over the limit by', formatMoney(n('over')), bold: true),
            const SizedBox(height: 12),
            Text(
              canOverride
                  ? 'You can bill anyway. The override is recorded.'
                  : 'Ask someone with credit override permission, or take a payment first.',
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Go back'),
        ),
        if (canOverride)
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Bill anyway'),
          ),
      ],
    ),
  );
  return chosen ?? false;
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value, {this.bold = false});

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold ? const TextStyle(fontWeight: FontWeight.w700) : null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}
