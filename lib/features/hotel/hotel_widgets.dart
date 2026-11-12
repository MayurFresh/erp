import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_colors.dart';
import '../../core/json.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/status_chip.dart';
import '../accounts/accounts_repository.dart';
import 'hotel_models.dart';

export '../../core/design_tokens.dart' show Space;
export '../construction/common/c_widgets.dart'
    show
        BottomBarLayout,
        CGate,
        CountStepper,
        DateField,
        bigButton,
        bigOutlinedButton,
        confirm,
        isPhone,
        parseApiDate,
        showReasonDialog,
        showSuccess,
        today;

/// "12 Nov" for a `YYYY-MM-DD` string.
String shortDate(String ymd) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final d = DateTime.tryParse(ymd);
  return d == null ? ymd : '${d.day} ${months[d.month - 1]}';
}

String nightsText(int n) => n == 1 ? '1 night' : '$n nights';

StatusTone reservationTone(String s) => switch (s) {
  'confirmed' => StatusTone.info,
  'checked_in' => StatusTone.success,
  'tentative' => StatusTone.warning,
  'cancelled' || 'no_show' => StatusTone.danger,
  _ => StatusTone.neutral,
};

StatusTone roomTone(String s) => switch (s) {
  'clean' => StatusTone.info,
  'inspected' => StatusTone.success,
  'dirty' => StatusTone.warning,
  'out_of_order' => StatusTone.danger,
  _ => StatusTone.neutral,
};

class ReservationChip extends StatelessWidget {
  const ReservationChip(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) => StatusChip(
    status,
    label: resStatusLabel(status),
    tone: reservationTone(status),
  );
}

class RoomStatusChip extends StatelessWidget {
  const RoomStatusChip(this.status, {super.key});

  final String status;

  @override
  Widget build(BuildContext context) =>
      StatusChip(status, label: roomStatusLabel(status), tone: roomTone(status));
}

/// A square of colour for a room status, used on the board legend.
Color roomColour(BuildContext context, String status) {
  final c = context.colors;
  return switch (status) {
    'clean' => c.toneAccent(StatusTone.info),
    'inspected' => c.toneAccent(StatusTone.success),
    'dirty' => c.toneAccent(StatusTone.warning),
    'out_of_order' => c.toneAccent(StatusTone.danger),
    _ => c.toneAccent(StatusTone.neutral),
  };
}

/// Collects a payment: amount, mode and the cash or bank account. Pops the
/// request body, or `null` when cancelled.
Future<Json?> showPaymentDialog(
  BuildContext context, {
  required String title,
  double? suggested,
  String confirmLabel = 'Take payment',
  String? note,
}) => showFormDialog<Json>(
  context: context,
  builder: (_) => _PaymentDialog(
    title: title,
    suggested: suggested,
    confirmLabel: confirmLabel,
    note: note,
  ),
);

class _PaymentDialog extends ConsumerStatefulWidget {
  const _PaymentDialog({
    required this.title,
    required this.suggested,
    required this.confirmLabel,
    required this.note,
  });

  final String title;
  final double? suggested;
  final String confirmLabel;
  final String? note;

  @override
  ConsumerState<_PaymentDialog> createState() => _PaymentDialogState();
}

class _PaymentDialogState extends ConsumerState<_PaymentDialog> {
  late final _amount = TextEditingController(
    text: widget.suggested != null && widget.suggested! > 0
        ? formatPlain(widget.suggested)
        : '',
  );
  final _ref = TextEditingController();
  String _mode = 'cash';
  String? _accountId;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    super.dispose();
  }

  void _submit() {
    final amount = parseNumber(_amount.text) ?? 0;
    if (amount <= 0) {
      setState(() => _error = 'Enter the amount.');
      return;
    }
    if (_accountId == null) {
      setState(() => _error = 'Choose the account the money goes to.');
      return;
    }
    Navigator.of(context).pop(<String, Object?>{
      'accountId': _accountId,
      'mode': _mode,
      'amount': amount,
      'reference': trimmedOrNull(_ref.text),
    });
  }

  @override
  Widget build(BuildContext context) {
    final accounts = ref.watch(cashBankAccountsProvider).value ?? const [];
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.note != null) ...[
                Text(widget.note!),
                const SizedBox(height: 12),
              ],
              FormRow(
                minCellWidth: 150,
                children: [
                  TextField(
                    controller: _amount,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    decoration: const InputDecoration(labelText: 'Amount'),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: _mode,
                    decoration: const InputDecoration(labelText: 'Mode'),
                    items: const [
                      DropdownMenuItem(value: 'cash', child: Text('Cash')),
                      DropdownMenuItem(value: 'upi', child: Text('UPI')),
                      DropdownMenuItem(value: 'card', child: Text('Card')),
                      DropdownMenuItem(value: 'bank', child: Text('Bank transfer')),
                      DropdownMenuItem(value: 'cheque', child: Text('Cheque')),
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
              const SizedBox(height: 12),
              TextField(
                controller: _ref,
                decoration: const InputDecoration(labelText: 'Reference (optional)'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
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
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

/// One line of a list on the front office home: guest, rooms and dates.
class DeskTile extends StatelessWidget {
  const DeskTile({super.key, required this.item, required this.onTap, this.trailing});

  final DeskItem item;
  final VoidCallback onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.guest,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                    Text(
                      [
                        if (item.rooms.isNotEmpty) item.rooms,
                        '${shortDate(item.arrival)} to ${shortDate(item.departure)}',
                        if (item.balance != null && item.balance! > 0)
                          'Due ${formatMoney(item.balance)}',
                      ].join('  |  '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            ],
          ),
        ),
      ),
    );
  }
}
