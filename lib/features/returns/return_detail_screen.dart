import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/json.dart';
import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../sales_orders/o2c_repository.dart';
import 'return_models.dart';
import 'returns_screen.dart';

class ReturnDetailScreen extends ConsumerWidget {
  const ReturnDetailScreen({super.key, required this.returnId});

  final String returnId;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    String action,
    String done, {
    Json? body,
    List<DataKind> also = const [],
  }) async {
    try {
      await ref
          .read(o2cRepositoryProvider)
          .returnAction(returnId, action, body: body);
      ref.read(o2cRevisionProvider.notifier).bump();
      if (also.isNotEmpty) ref.bump(also);
      if (context.mounted) showInfoSnackBar(context, done);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _receive(
    BuildContext context,
    WidgetRef ref,
    SalesReturn r,
  ) async {
    final lines = await showFormDialog<List<Json>>(
      context: context,
      builder: (_) => _ReceiveDialog(ret: r),
    );
    if (lines == null || !context.mounted) return;
    await _run(
      context,
      ref,
      'receive',
      'Return ${r.number} received',
      body: {'lines': lines},
    );
  }

  Future<void> _inspect(
    BuildContext context,
    WidgetRef ref,
    SalesReturn r,
  ) async {
    final lines = await showFormDialog<List<Json>>(
      context: context,
      builder: (_) => _InspectDialog(ret: r),
    );
    if (lines == null || !context.mounted) return;
    await _run(
      context,
      ref,
      'inspect',
      'Return ${r.number} inspected',
      body: {'lines': lines},
      also: const [DataKind.stock],
    );
  }

  Future<void> _cancel(
    BuildContext context,
    WidgetRef ref,
    SalesReturn r,
  ) async {
    final reason = await showFormDialog<String>(
      context: context,
      builder: (_) => CancelReasonDialog(
        title: 'Cancel ${r.number}?',
        message: 'The return is closed without any stock or credit change.',
        confirmLabel: 'Cancel return',
      ),
    );
    if (reason == null || !context.mounted) return;
    await _run(
      context,
      ref,
      'cancel',
      'Return ${r.number} cancelled',
      body: {'reason': reason},
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return AsyncValueView(
      value: ref.watch(salesReturnProvider(returnId)),
      onRetry: () => ref.invalidate(salesReturnProvider(returnId)),
      data: (r) {
        final manage = perms.can(Perm.returnsManage);
        return FormPage(
          maxWidth: 1000,
          children: [
            DocHeader(
              title: r.number,
              pills: Wrap(
                spacing: 6,
                children: [
                  StatusChip(r.status, label: returnLabel(r.status)),
                  if (r.isRto) const Pill('Return to origin'),
                ],
              ),
              actions: [
                if (manage && r.status == 'requested')
                  DocAction(
                    label: 'Receive goods',
                    icon: Icons.move_to_inbox_outlined,
                    primary: true,
                    onPressed: () => _receive(context, ref, r),
                  ),
                if (manage && r.status == 'received')
                  DocAction(
                    label: 'Inspect goods',
                    icon: Icons.fact_check_outlined,
                    primary: true,
                    onPressed: () => _inspect(context, ref, r),
                  ),
                if (manage && r.status == 'inspected')
                  DocAction(
                    label: 'Close and credit',
                    icon: Icons.task_alt,
                    primary: true,
                    onPressed: () => _run(
                      context,
                      ref,
                      'close',
                      'Return ${r.number} closed',
                      also: const [
                        DataKind.creditNotes,
                        DataKind.invoices,
                        DataKind.parties,
                        DataKind.stock,
                      ],
                    ),
                  ),
                if (manage && r.status == 'requested')
                  DocAction(
                    label: 'Cancel return',
                    icon: Icons.block,
                    destructive: true,
                    onPressed: () => _cancel(context, ref, r),
                  ),
                if (r.orderId != null)
                  DocAction(
                    label: 'Open order',
                    icon: Icons.shopping_bag_outlined,
                    onPressed: () => context.go('/sales-orders/${r.orderId}'),
                  ),
                if (r.creditNoteId != null && perms.can(Perm.invoicesView))
                  DocAction(
                    label: 'Open credit note',
                    icon: Icons.receipt_long_outlined,
                    onPressed: () =>
                        context.go('/credit-notes/${r.creditNoteId}'),
                  ),
              ],
              facts: [
                LabeledValue('Customer', r.partyName),
                if (r.orderNumber != null)
                  LabeledValue('Order', r.orderNumber!),
                if (r.invoiceNumber != null)
                  LabeledValue('Invoice', r.invoiceNumber!),
                LabeledValue('Location', r.locationName),
                LabeledValue('Reason', r.reason),
                if (r.creditNoteNumber != null)
                  LabeledValue('Credit note', r.creditNoteNumber!),
              ],
            ),
            SectionCard(
              title: 'Items',
              child: Column(
                children: [
                  for (final l in r.lines)
                    ListTile(
                      key: ValueKey('return-line-${l.id}'),
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.itemName),
                      subtitle: Text(
                        [
                          'Expected ${formatQty(l.qty)} ${l.unit}',
                          if (l.qtyReceived > 0)
                            'received ${formatQty(l.qtyReceived)}',
                          if (l.note != null) l.note!,
                        ].join(' · '),
                      ),
                      trailing: l.disposition == null
                          ? null
                          : Pill(dispositions[l.disposition] ?? l.disposition!),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ReceiveDialog extends StatefulWidget {
  const _ReceiveDialog({required this.ret});

  final SalesReturn ret;

  @override
  State<_ReceiveDialog> createState() => _ReceiveDialogState();
}

class _ReceiveDialogState extends State<_ReceiveDialog> {
  late final Map<String, TextEditingController> _qty = {
    for (final l in widget.ret.lines)
      l.id: TextEditingController(text: formatPlain(l.qty)),
  };
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Receive returned goods'),
    content: SizedBox(
      width: 440,
      child: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final l in widget.ret.lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: TextFormField(
                    controller: _qty[l.id],
                    keyboardType: decimalKeyboard,
                    inputFormatters: <TextInputFormatter>[
                      decimalInput(decimals: 3),
                    ],
                    decoration: InputDecoration(
                      labelText:
                          '${l.itemName} (expected ${formatQty(l.qty)} ${l.unit})',
                    ),
                    validator: (v) {
                      final n = parseNumber(v ?? '');
                      if (n == null || n < 0) return 'Enter a quantity';
                      if (n > l.qty) return 'At most ${formatQty(l.qty)}';
                      return null;
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (!validateAndReveal(_formKey)) return;
          Navigator.of(context).pop([
            for (final l in widget.ret.lines)
              {
                'lineId': l.id,
                'qtyReceived': parseNumber(_qty[l.id]!.text) ?? 0,
              },
          ]);
        },
        child: const Text('Receive'),
      ),
    ],
  );
}

class _InspectDialog extends StatefulWidget {
  const _InspectDialog({required this.ret});

  final SalesReturn ret;

  @override
  State<_InspectDialog> createState() => _InspectDialogState();
}

class _InspectDialogState extends State<_InspectDialog> {
  late final Map<String, String> _disp = {
    for (final l in widget.ret.lines.where((l) => l.qtyReceived > 0))
      l.id: l.disposition ?? 'restock',
  };
  late final Map<String, TextEditingController> _note = {
    for (final l in widget.ret.lines) l.id: TextEditingController(text: l.note),
  };

  @override
  void dispose() {
    for (final c in _note.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final received = widget.ret.lines.where((l) => l.qtyReceived > 0).toList();
    return AlertDialog(
      title: const Text('Inspect returned goods'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Only restocked units go back on the shelf. The credit note '
                'covers every unit received.',
              ),
              const SizedBox(height: 12),
              if (received.isEmpty) const Text('No units were received.'),
              for (final l in received) ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey('disposition-${l.id}'),
                  initialValue: _disp[l.id],
                  decoration: InputDecoration(
                    labelText:
                        '${l.itemName} (${formatQty(l.qtyReceived)} ${l.unit})',
                  ),
                  items: [
                    for (final e in dispositions.entries)
                      DropdownMenuItem(value: e.key, child: Text(e.value)),
                  ],
                  onChanged: (v) =>
                      setState(() => _disp[l.id] = v ?? 'restock'),
                ),
                TextField(
                  controller: _note[l.id],
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Note (optional)',
                  ),
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
        FilledButton(
          onPressed: received.isEmpty
              ? null
              : () => Navigator.of(context).pop([
                  for (final l in received)
                    {
                      'lineId': l.id,
                      'disposition': _disp[l.id],
                      'note': trimmedOrNull(_note[l.id]!.text),
                    },
                ]),
          child: const Text('Save inspection'),
        ),
      ],
    );
  }
}
