import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../accounts/accounts_repository.dart';
import '../auth/session.dart';
import 'clinic_models.dart';
import 'clinic_repository.dart';
import 'clinic_widgets.dart';

class _BillLine {
  _BillLine(this.itemId, this.name, double rate)
    : rate = TextEditingController(text: formatPlain(rate)),
      qty = TextEditingController(text: '1');

  final String itemId;
  final String name;
  final TextEditingController rate;
  final TextEditingController qty;

  void dispose() {
    rate.dispose();
    qty.dispose();
  }
}

/// Bills a visit: the consultation fee is added by the server, plus any
/// services or medicines chosen here, and an optional receipt. Pops `true`.
class BillDialog extends ConsumerStatefulWidget {
  const BillDialog({super.key, required this.visitId});

  final String visitId;

  @override
  ConsumerState<BillDialog> createState() => _BillDialogState();
}

class _BillDialogState extends ConsumerState<BillDialog> {
  final _lines = <_BillLine>[];
  final _paid = TextEditingController();
  final _ref = TextEditingController();
  bool _consult = true;
  String _mode = 'cash';
  String? _accountId;
  bool _saving = false;
  BillResult? _result;

  @override
  void dispose() {
    for (final l in _lines) {
      l.dispose();
    }
    _paid.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final item = await pickItem(context, ref);
    if (item == null) return;
    setState(() => _lines.add(_BillLine(item.id, item.name, item.salePrice)));
  }

  Future<void> _save() async {
    final paid = parseNumber(_paid.text) ?? 0;
    if (paid > 0 && _accountId == null) {
      showErrorSnackBar(
        context,
        'Choose the cash or bank account for the payment.',
      );
      return;
    }
    for (final l in _lines) {
      if ((parseNumber(l.qty.text) ?? 0) <= 0) {
        showErrorSnackBar(context, 'Enter a quantity for ${l.name}.');
        return;
      }
    }
    setState(() => _saving = true);
    try {
      final r = await ref.read(clinicRepositoryProvider).bill(widget.visitId, {
        'includeConsultation': _consult,
        'lines': [
          for (final l in _lines)
            {
              'itemId': l.itemId,
              'qty': parseNumber(l.qty.text),
              'rate': parseNumber(l.rate.text),
            },
        ],
        if (paid > 0)
          'payment': {
            'accountId': _accountId,
            'mode': _mode,
            'amount': paid,
            'reference': trimmedOrNull(_ref.text),
          },
      });
      if (mounted) setState(() => _result = r);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final r = _result;
    if (r != null) {
      return AlertDialog(
        title: const Text('Bill created'),
        content: Text(
          '${r.invoice.number} for ${formatMoney(r.invoice.total)}.\n'
          '${switch (r.feeKind) {
            'follow_up' => 'Follow-up fee charged.',
            'consultation' => 'Consultation fee charged.',
            _ => 'No consultation fee.',
          }}\n'
          'Paid ${formatMoney(r.invoice.amountPaid)}.',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Done'),
          ),
        ],
      );
    }
    final canPay = ref.watch(permissionsProvider).can(Perm.paymentsCreate);
    final accounts = ref.watch(cashBankAccountsProvider).value ?? const [];
    return AlertDialog(
      title: const Text('Bill the visit'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Consultation fee'),
                subtitle: const Text(
                  'The doctor\'s fee, or the follow-up fee inside the follow-up days.',
                ),
                value: _consult,
                onChanged: _saving ? null : (v) => setState(() => _consult = v),
              ),
              const Divider(),
              Text(
                'Services and medicines',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 6),
              for (final (i, l) in _lines.indexed)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            tooltip: 'Remove ${l.name}',
                            onPressed: _saving
                                ? null
                                : () => setState(
                                    () => _lines.removeAt(i).dispose(),
                                  ),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      FormRow(
                        minCellWidth: 120,
                        children: [
                          TextField(
                            controller: l.qty,
                            keyboardType: decimalKeyboard,
                            inputFormatters: [decimalInput(decimals: 3)],
                            decoration: const InputDecoration(labelText: 'Qty'),
                          ),
                          TextField(
                            controller: l.rate,
                            keyboardType: decimalKeyboard,
                            inputFormatters: [decimalInput()],
                            decoration: const InputDecoration(
                              labelText: 'Rate',
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _add,
                  icon: const Icon(Icons.add),
                  label: const Text('Add service or medicine'),
                ),
              ),
              if (canPay) ...[
                const Divider(height: 28),
                Text(
                  'Payment now (optional)',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                FormRow(
                  minCellWidth: 160,
                  children: [
                    TextField(
                      controller: _paid,
                      keyboardType: decimalKeyboard,
                      inputFormatters: [decimalInput()],
                      decoration: const InputDecoration(
                        labelText: 'Amount received',
                        helperText: 'Leave empty to bill only',
                      ),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: _mode,
                      decoration: const InputDecoration(labelText: 'Mode'),
                      items: const [
                        DropdownMenuItem(value: 'cash', child: Text('Cash')),
                        DropdownMenuItem(value: 'upi', child: Text('UPI')),
                        DropdownMenuItem(value: 'card', child: Text('Card')),
                        DropdownMenuItem(
                          value: 'bank',
                          child: Text('Bank transfer'),
                        ),
                        DropdownMenuItem(
                          value: 'cheque',
                          child: Text('Cheque'),
                        ),
                      ],
                      onChanged: (v) => setState(() => _mode = v ?? 'cash'),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _accountId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Deposit to'),
                  items: [
                    for (final a in accounts)
                      DropdownMenuItem(
                        value: a.id,
                        child: Text(a.name, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (v) => setState(() => _accountId = v),
                ),
              ],
            ],
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
          label: 'Create bill',
        ),
      ],
    );
  }
}
