import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../parties/party_model.dart';
import '../../parties/party_picker.dart';
import '../data/construction_repository.dart';
import '../models/common_models.dart';
import '../models/subcontract_models.dart';
import 'c_widgets.dart';

Color _amber() => Colors.orange.shade800;

Widget labourAdvanceStatusPill(
  BuildContext context,
  LabourAdvanceStatus status,
) => Pill(
  status.label,
  color: switch (status) {
    LabourAdvanceStatus.open => _amber(),
    LabourAdvanceStatus.recovered => Colors.green.shade700,
    LabourAdvanceStatus.cancelled => Theme.of(context).colorScheme.error,
  },
);

Widget workOrderStatusPill(BuildContext context, WorkOrderStatus status) =>
    Pill(
      status.label,
      color: switch (status) {
        WorkOrderStatus.draft => Colors.blueGrey,
        WorkOrderStatus.active => Colors.green.shade700,
        WorkOrderStatus.closed => Theme.of(context).colorScheme.primary,
        WorkOrderStatus.cancelled => Theme.of(context).colorScheme.error,
      },
    );

Widget raBillStatusPill(BuildContext context, RaBillStatus status) => Pill(
  status.label,
  color: switch (status) {
    RaBillStatus.draft => Colors.blueGrey,
    RaBillStatus.submitted => _amber(),
    RaBillStatus.approved => Colors.green.shade700,
    RaBillStatus.cancelled => Theme.of(context).colorScheme.error,
  },
);

Widget raPaymentPill(BuildContext context, RaPaymentStatus status) => Pill(
  status.label,
  color: switch (status) {
    RaPaymentStatus.unpaid => _amber(),
    RaPaymentStatus.partial => Colors.blue.shade700,
    RaPaymentStatus.paid => Colors.green.shade700,
  },
);

/// Status and, for approved bills, payment status side by side.
Widget raBillPills(BuildContext context, RaBill bill) => Wrap(
  spacing: 6,
  runSpacing: 4,
  children: [
    raBillStatusPill(context, bill.status),
    if (bill.status == RaBillStatus.approved)
      raPaymentPill(context, bill.paymentStatus),
    if (bill.isFinal) const Pill('Final bill'),
  ],
);

/// "All …" dropdown over [options], for list filters.
class IdFilter extends StatelessWidget {
  const IdFilter({
    super.key,
    required this.label,
    required this.allLabel,
    required this.icon,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String allLabel;
  final IconData icon;
  final List<NamedRef> options;
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selected = options.any((o) => o.id == value) ? value : null;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: DropdownButtonFormField<String?>(
        key: ValueKey('$label-filter-$selected-${options.length}'),
        initialValue: selected,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          prefixIcon: Icon(icon),
        ),
        items: [
          DropdownMenuItem<String?>(value: null, child: Text(allLabel)),
          for (final o in options)
            DropdownMenuItem<String?>(
              value: o.id,
              child: Text(o.name, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// Project filter (all projects in scope).
class ProjectIdFilter extends ConsumerWidget {
  const ProjectIdFilter({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final projects = ref.watch(projectsLookupProvider);
    if (projects.hasError) return const SizedBox.shrink();
    return IdFilter(
      label: 'Project',
      allLabel: 'All projects',
      icon: Icons.apartment_outlined,
      options: [
        for (final p in projects.value ?? const [])
          NamedRef(id: p.id, name: p.name),
      ],
      value: value,
      onChanged: onChanged,
    );
  }
}

/// Contractor filter: a chip that opens the vendor picker.
class ContractorFilter extends ConsumerWidget {
  const ContractorFilter({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final NamedRef? value;
  final ValueChanged<NamedRef?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final current = value;
    Future<void> pick() async {
      final party = await pickParty(context, ref, type: PartyType.vendor);
      if (party != null) onChanged(NamedRef(id: party.id, name: party.name));
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: InputChip(
        avatar: const Icon(Icons.handyman_outlined, size: 18),
        label: Text(
          current?.name ?? 'All contractors',
          overflow: TextOverflow.ellipsis,
        ),
        materialTapTargetSize: MaterialTapTargetSize.padded,
        onPressed: pick,
        onDeleted: current == null ? null : () => onChanged(null),
      ),
    );
  }
}

/// Asks for an amount (and optionally an account, a date and notes).
/// Pops with the values; `null` if dismissed.
class AmountEntry {
  const AmountEntry({
    required this.amount,
    this.accountId,
    required this.date,
    this.notes,
  });

  final double amount;
  final String? accountId;
  final DateTime date;
  final String? notes;
}

Future<AmountEntry?> showAmountDialog(
  BuildContext context,
  WidgetRef ref, {
  required String title,
  required String message,
  required String confirmLabel,
  bool withAccount = true,
  double? maxAmount,
  double? initialAmount,
}) async {
  final accounts = withAccount
      ? await ref.read(payAccountsProvider.future)
      : const [];
  if (!context.mounted) return null;
  if (withAccount && accounts.isEmpty) {
    showInfoSnackBar(
      context,
      'Create an active cash or bank account before paying.',
    );
    return null;
  }
  return showDialog<AmountEntry>(
    context: context,
    builder: (context) => _AmountDialog(
      title: title,
      message: message,
      confirmLabel: confirmLabel,
      accounts: [for (final a in accounts) (id: a.id, name: a.displayName)],
      maxAmount: maxAmount,
      initialAmount: initialAmount,
    ),
  );
}

class _AmountDialog extends StatefulWidget {
  const _AmountDialog({
    required this.title,
    required this.message,
    required this.confirmLabel,
    required this.accounts,
    this.maxAmount,
    this.initialAmount,
  });

  final String title;
  final String message;
  final String confirmLabel;
  final List<({String id, String name})> accounts;
  final double? maxAmount;
  final double? initialAmount;

  @override
  State<_AmountDialog> createState() => _AmountDialogState();
}

class _AmountDialogState extends State<_AmountDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _amount = TextEditingController(
    text: widget.initialAmount == null ? '' : formatPlain(widget.initialAmount),
  );
  final _notes = TextEditingController();
  String? _accountId;
  DateTime _date = today();

  @override
  void initState() {
    super.initState();
    if (widget.accounts.isNotEmpty) _accountId = widget.accounts.first.id;
  }

  @override
  void dispose() {
    _amount.dispose();
    _notes.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      AmountEntry(
        amount: double.parse(_amount.text.trim()),
        accountId: _accountId,
        date: _date,
        notes: trimmedOrNull(_notes.text),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    scrollable: true,
    content: SizedBox(
      width: 440,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            const SizedBox(height: 16),
            TextFormField(
              controller: _amount,
              autofocus: true,
              keyboardType: decimalKeyboard,
              inputFormatters: [decimalInput()],
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixText: '₹ ',
              ),
              validator: (v) {
                final error = requiredNumber(v, label: 'Amount', min: 0.01);
                if (error != null) return error;
                final max = widget.maxAmount;
                if (max != null && double.parse(v!.trim()) > max + 0.004) {
                  return 'At most ${formatMoney(max)}';
                }
                return null;
              },
            ),
            if (widget.accounts.isNotEmpty) ...[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _accountId,
                decoration: const InputDecoration(labelText: 'Pay from'),
                items: [
                  for (final a in widget.accounts)
                    DropdownMenuItem(
                      value: a.id,
                      child: Text(a.name, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _accountId = v),
              ),
            ],
            const SizedBox(height: 12),
            DateField(
              label: 'Date',
              value: _date,
              lastDate: today(),
              onChanged: (v) => setState(() => _date = v),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _notes,
              maxLength: 300,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
    ],
  );
}
