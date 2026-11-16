import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/key_value_list.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../documents/document_widgets.dart';
import '../reports/pdf_actions.dart';
import 'challan_pdf.dart';
import 'export_models.dart';
import 'export_repository.dart';

class ChallanDetailScreen extends ConsumerWidget {
  const ChallanDetailScreen({super.key, required this.challanId});

  final String challanId;

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<Object?> Function() task, {
    String? then,
  }) async {
    try {
      final r = await task();
      ref.read(exportRevisionProvider.notifier).bump();
      if (context.mounted && then != null && r is String) {
        context.go('$then$r');
      }
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  /// Asks how much of each pending line to return or bill.
  Future<Map<String, double>?> _askQuantities(
    BuildContext context,
    Challan c,
    String title,
    String confirm,
  ) {
    final fields = {
      for (final l in c.lines.where((l) => l.pendingQty > 0))
        l.id: TextEditingController(text: formatPlain(l.pendingQty)),
    };
    return showFormDialog<Map<String, double>>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text(title),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final l in c.lines.where((l) => l.pendingQty > 0))
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: fields[l.id],
                  keyboardType: TextInputType.number,
                  decoration: InputDecoration(
                    labelText: '${l.description} (pending ${formatQty(l.pendingQty)} ${l.unit})',
                  ),
                ),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).maybePop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final out = <String, double>{};
              for (final e in fields.entries) {
                final q = parseNumber(e.value.text) ?? 0;
                if (q > 0) out[e.key] = q;
              }
              Navigator.of(d).pop(out);
            },
            child: Text(confirm),
          ),
        ],
      ),
    );
  }

  Future<void> _cancel(BuildContext context, WidgetRef ref, Challan c) async {
    final reason = TextEditingController();
    final ok = await showFormDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Cancel ${c.number}'),
        content: TextField(
          controller: reason,
          decoration: const InputDecoration(labelText: 'Reason'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(d).maybePop(),
            child: const Text('Keep challan'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Cancel challan'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await _run(
        context,
        ref,
        () => ref.read(exportRepositoryProvider).cancelChallan(c.id, reason.text.trim()),
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    final repo = ref.read(exportRepositoryProvider);
    return AsyncValueView(
      value: ref.watch(challanProvider(challanId)),
      onRetry: () => ref.invalidate(challanProvider(challanId)),
      data: (c) {
        final manage = perms.can(Perm.challansManage);
        return FormPage(
          maxWidth: 1100,
          children: [
            DocHeader(
              title: c.number,
              pills: StatusChip(c.status, label: challanStatuses[c.status] ?? c.status),
              actions: [
                ...pdfDocActions(
                  context,
                  ref,
                  fileName: challanFileName(c),
                  build: (p) async => buildChallanPdf(
                    c,
                    p.company,
                    brand: p.brand,
                    theme: p.theme,
                  ),
                ),
                if (manage && c.isActive && c.lines.any((l) => l.pendingQty > 0))
                  DocAction(
                    label: 'Goods returned',
                    icon: Icons.undo_outlined,
                    onPressed: () async {
                      final q = await _askQuantities(context, c, 'Goods returned', 'Record return');
                      if (q == null || q.isEmpty || !context.mounted) return;
                      await _run(context, ref, () => repo.returnGoods(c.id, q));
                    },
                  ),
                if (manage && c.canBill && perms.can(Perm.invoicesCreate))
                  DocAction(
                    label: 'Bill pending goods',
                    icon: Icons.receipt_long_outlined,
                    primary: true,
                    onPressed: () async {
                      final q = await _askQuantities(context, c, 'Bill from this challan', 'Create invoice');
                      if (q == null || q.isEmpty || !context.mounted) return;
                      await _run(
                        context,
                        ref,
                        () => repo.billChallan(c.id, qtyByLine: q),
                        then: '/invoices/',
                      );
                    },
                  ),
                if (manage && c.canCancel)
                  DocAction(
                    label: 'Cancel',
                    icon: Icons.block,
                    destructive: true,
                    onPressed: () => _cancel(context, ref, c),
                  ),
              ],
              facts: [
                LabeledValue('Consignee', c.consigneeName),
                LabeledValue('Date', formatDate(c.date)),
                LabeledValue('Reason', challanReasons[c.reason] ?? c.reason),
                LabeledValue('Taxable value', formatMoney(c.taxableTotal)),
              ],
            ),
            SectionCard(
              title: 'Movement',
              child: KeyValueList(
                items: [
                  KeyValue('From', c.locationName),
                  if (c.toLocationName != null) KeyValue('To', c.toLocationName!),
                  KeyValue('Consignor GSTIN', c.consignorGstin ?? ''),
                  KeyValue('Consignee GSTIN', c.consigneeGstin ?? ''),
                  KeyValue('Vehicle', c.vehicleNo ?? ''),
                  KeyValue('Transporter', c.transporter ?? ''),
                  KeyValue('E-way bill', c.ewbNo ?? ''),
                  if (c.reasonNote != null) KeyValue('Note', c.reasonNote!),
                ],
              ),
            ),
            SectionCard(
              title: 'Items',
              child: Column(
                children: [
                  for (final l in c.lines)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(l.description),
                      subtitle: Text(
                        '${formatQty(l.qty)} ${l.unit}${l.provisional ? ' (provisional)' : ''}'
                        ' · returned ${formatQty(l.returnedQty)}'
                        ' · billed ${formatQty(l.invoicedQty)}'
                        ' · pending ${formatQty(l.pendingQty)}',
                      ),
                      trailing: Text(formatMoney(l.taxableValue)),
                    ),
                  const Divider(),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text('Tax for information ${formatMoney(c.taxTotal)}'),
                  ),
                ],
              ),
            ),
            if (c.notes != null) SectionCard(title: 'Notes', child: Text(c.notes!)),
          ],
        );
      },
    );
  }
}
