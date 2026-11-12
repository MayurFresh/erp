import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../accounts/accounts_repository.dart';

/// The amount, mode and account of a receipt taken inside a dialog.
class PayController {
  final amount = TextEditingController();
  final reference = TextEditingController();
  String mode = 'cash';
  String? accountId;

  double get value => parseNumber(amount.text) ?? 0;

  /// Receipt body, or `null` when no amount was entered.
  Json? body() => value <= 0
      ? null
      : {
          'accountId': accountId,
          'mode': mode,
          'amount': value,
          'reference': trimmedOrNull(reference.text),
        };

  void dispose() {
    amount.dispose();
    reference.dispose();
  }
}

class PayFields extends ConsumerStatefulWidget {
  const PayFields({
    super.key,
    required this.controller,
    this.amountLabel = 'Amount received',
    this.helper,
  });

  final PayController controller;
  final String amountLabel;
  final String? helper;

  @override
  ConsumerState<PayFields> createState() => _PayFieldsState();
}

class _PayFieldsState extends ConsumerState<PayFields> {
  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final accounts = ref.watch(cashBankAccountsProvider).value ?? const [];
    if (c.accountId == null && accounts.isNotEmpty) {
      c.accountId = accounts.first.id;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FormRow(
          minCellWidth: 160,
          children: [
            TextField(
              controller: c.amount,
              keyboardType: decimalKeyboard,
              inputFormatters: [decimalInput()],
              decoration: InputDecoration(
                labelText: widget.amountLabel,
                helperText: widget.helper,
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: c.mode,
              decoration: const InputDecoration(labelText: 'Mode'),
              items: const [
                DropdownMenuItem(value: 'cash', child: Text('Cash')),
                DropdownMenuItem(value: 'upi', child: Text('UPI')),
                DropdownMenuItem(value: 'card', child: Text('Card')),
                DropdownMenuItem(value: 'bank', child: Text('Bank transfer')),
                DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
              ],
              onChanged: (v) => setState(() => c.mode = v ?? 'cash'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: accounts.any((a) => a.id == c.accountId)
              ? c.accountId
              : null,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Deposit to'),
          items: [
            for (final a in accounts)
              DropdownMenuItem(
                value: a.id,
                child: Text(a.name, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: (v) => setState(() => c.accountId = v),
        ),
      ],
    );
  }
}
