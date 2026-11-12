import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'rest_models.dart';
import 'rest_repository.dart';

class _PayRow {
  _PayRow(this.mode, double amount)
    : amount = TextEditingController(text: formatPlain(amount)),
      reference = TextEditingController();

  String mode;
  final TextEditingController amount;
  final TextEditingController reference;

  double get value => parseNumber(amount.text.trim()) ?? 0;

  void dispose() {
    amount.dispose();
    reference.dispose();
  }
}

/// Collects the payment (cash, UPI, card, split across several) and settles
/// the order. Pops with the [SettleResult] once the bill is posted.
class SettleDialog extends ConsumerStatefulWidget {
  const SettleDialog({super.key, required this.order});

  final RestOrder order;

  @override
  ConsumerState<SettleDialog> createState() => _SettleDialogState();
}

class _SettleDialogState extends ConsumerState<SettleDialog> {
  late final List<_PayRow> _rows = [_PayRow('cash', widget.order.bill.total)];
  bool _saving = false;

  double get _total => widget.order.bill.total;
  double get _paid => _rows.fold(0.0, (s, r) => s + r.value);
  double get _left => ((_total - _paid) * 100).round() / 100;

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  Future<void> _settle() async {
    if (_saving || _left != 0 || _rows.any((r) => r.value <= 0)) return;
    setState(() => _saving = true);
    try {
      final result = await ref
          .read(restaurantRepositoryProvider)
          .settle(widget.order.id, [
            for (final r in _rows)
              (
                mode: r.mode,
                amount: r.value,
                reference: r.mode == 'cash'
                    ? null
                    : trimmedOrNull(r.reference.text),
              ),
          ]);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  Future<void> _toRoom() async {
    final room = TextEditingController();
    final number = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Charge to room'),
        content: TextField(
          controller: room,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Room number',
            helperText:
                'The amount before tax goes on the guest folio and is taxed on the hotel bill at check-out.',
            helperMaxLines: 3,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(room.text.trim()),
            child: const Text('Charge'),
          ),
        ],
      ),
    );
    room.dispose();
    if (number == null || number.isEmpty || _saving) return;
    setState(() => _saving = true);
    try {
      final result = await ref
          .read(restaurantRepositoryProvider)
          .settle(widget.order.id, const [], roomNumber: number);
      if (mounted) Navigator.of(context).pop(result);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _left == 0 && _rows.every((r) => r.value > 0);
    return AlertDialog(
      title: const Text('Settle bill'),
      scrollable: true,
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Bill total', style: theme.textTheme.titleMedium),
                Text(
                  formatMoney(_total),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.md),
            for (var i = 0; i < _rows.length; i++) ...[
              _PayRowView(
                row: _rows[i],
                enabled: !_saving,
                onChanged: () => setState(() {}),
                onRemove: _rows.length > 1
                    ? () => setState(() => _rows.removeAt(i).dispose())
                    : null,
              ),
              const SizedBox(height: Space.md),
            ],
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _saving || _left <= 0
                    ? null
                    : () => setState(() => _rows.add(_PayRow('upi', _left))),
                icon: const Icon(Icons.call_split),
                label: const Text('Split payment'),
              ),
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _left > 0
                      ? 'Still to collect'
                      : _left < 0
                      ? 'Over by'
                      : 'Collected',
                ),
                Text(
                  formatMoney(_left.abs() == 0 ? _paid : _left.abs()),
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: _left == 0 ? null : theme.colorScheme.error,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving ? null : _toRoom,
          child: const Text('Charge to room'),
        ),
        BusyButton(
          busy: _saving,
          onPressed: ready ? _settle : null,
          label: 'Settle ${formatMoney(_total)}',
          icon: Icons.check,
        ),
      ],
    );
  }
}

class _PayRowView extends StatelessWidget {
  const _PayRowView({
    required this.row,
    required this.enabled,
    required this.onChanged,
    this.onRemove,
  });

  final _PayRow row;
  final bool enabled;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'cash', label: Text('Cash')),
                ButtonSegment(value: 'upi', label: Text('UPI')),
                ButtonSegment(value: 'card', label: Text('Card')),
              ],
              selected: {row.mode},
              onSelectionChanged: enabled
                  ? (s) {
                      row.mode = s.first;
                      onChanged();
                    }
                  : null,
            ),
          ),
          if (onRemove != null)
            IconButton(
              tooltip: 'Remove this payment',
              onPressed: enabled ? onRemove : null,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      const SizedBox(height: Space.sm),
      TextField(
        controller: row.amount,
        enabled: enabled,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'Amount',
          prefixText: '$moneySymbol ',
        ),
        onChanged: (_) => onChanged(),
      ),
      if (row.mode != 'cash') ...[
        const SizedBox(height: Space.sm),
        TextField(
          controller: row.reference,
          enabled: enabled,
          decoration: const InputDecoration(labelText: 'Reference (optional)'),
        ),
      ],
    ],
  );
}
