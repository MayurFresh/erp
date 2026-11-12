import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/json.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../fulfilment/fulfilment_models.dart';
import 'o2c_repository.dart';
import 'sales_order_models.dart';

/// Dispatches packed quantity: creates the invoice and the shipment.
///
/// One Idempotency-Key is held for the life of the dialog, so a retry after a
/// dropped connection cannot create a second invoice.
class DispatchDialog extends ConsumerStatefulWidget {
  const DispatchDialog({super.key, required this.order});

  final SalesOrder order;

  @override
  ConsumerState<DispatchDialog> createState() => _DispatchDialogState();
}

class _DispatchDialogState extends ConsumerState<DispatchDialog> {
  final _courier = TextEditingController();
  final _awb = TextEditingController();
  final _cod = TextEditingController();
  final _notes = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final String _key =
      'dispatch-${DateTime.now().microsecondsSinceEpoch}-'
      '${UniqueKey().hashCode}';
  String _mode = 'prepaid';
  bool _busy = false;

  @override
  void dispose() {
    _courier.dispose();
    _awb.dispose();
    _cod.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!validateAndReveal(_formKey)) return;
    setState(() => _busy = true);
    try {
      final j = await ref
          .read(o2cRepositoryProvider)
          .dispatch(
            widget.order.id,
            idempotencyKey: _key,
            body: {
              'mode': _mode,
              'courier': trimmedOrNull(_courier.text),
              'awb': trimmedOrNull(_awb.text),
              'notes': trimmedOrNull(_notes.text),
              if (_mode == 'cod' && trimmedOrNull(_cod.text) != null)
                'codAmount': parseNumber(_cod.text),
            },
          );
      if (mounted) Navigator.of(context).pop(Shipment.fromJson(asJson(j)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.order;
    return AlertDialog(
      title: Text('Dispatch ${o.number}'),
      content: SizedBox(
        width: 460,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Packed items are invoiced and shipped. '
                  '${formatPackedCount(o)} to dispatch.',
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _courier,
                  maxLength: 100,
                  decoration: const InputDecoration(
                    labelText: 'Courier (optional)',
                  ),
                ),
                TextFormField(
                  controller: _awb,
                  maxLength: 60,
                  decoration: const InputDecoration(
                    labelText: 'Tracking number (optional)',
                  ),
                ),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _mode,
                  decoration: const InputDecoration(labelText: 'Payment mode'),
                  items: const [
                    DropdownMenuItem(value: 'prepaid', child: Text('Prepaid')),
                    DropdownMenuItem(
                      value: 'cod',
                      child: Text('Cash on delivery'),
                    ),
                  ],
                  onChanged: (v) => setState(() => _mode = v ?? 'prepaid'),
                ),
                if (_mode == 'cod') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _cod,
                    keyboardType: decimalKeyboard,
                    inputFormatters: [decimalInput()],
                    decoration: const InputDecoration(
                      labelText: 'Amount to collect (optional)',
                      helperText: 'Defaults to the invoice total',
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _notes,
                  maxLines: 2,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).maybePop(),
          child: const Text('Cancel'),
        ),
        BusyButton(
          busy: _busy,
          onPressed: _submit,
          label: 'Dispatch',
          icon: Icons.local_shipping_outlined,
        ),
      ],
    );
  }
}

String formatPackedCount(SalesOrder o) => '${_q(o.readyToDispatch)} units';

String _q(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';
