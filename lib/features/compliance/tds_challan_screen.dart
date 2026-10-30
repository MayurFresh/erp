import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../reports/report_widgets.dart' show ReportSectionTitle, tabularFigures;
import 'compliance_models.dart';
import 'compliance_repository.dart';
import 'compliance_widgets.dart';
import 'tax_perms.dart';
import '../../widgets/busy.dart';

/// `/tds-challans/:id`: one challan with its deductions; cancel here.
class TdsChallanScreen extends ConsumerWidget {
  const TdsChallanScreen({super.key, required this.id});

  final String id;

  Future<void> _cancel(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cancel challan?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Reason',
            helperText: 'The journal is reversed and the deductions are freed.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                Navigator.pop(context, controller.text.trim());
              }
            },
            child: const Text('Cancel challan'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reason == null || !context.mounted) return;
    try {
      await runBlocking(
        context,
        () => ref.read(complianceRepositoryProvider).cancelChallan(id, reason),
      );
      ref.read(complianceRevisionProvider.notifier).bump();
      ref.bump(const [DataKind.accounts]);
    } catch (e) {
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final value = ref.watch(tdsChallanProvider(id));
    final manage = ref.watch(permissionsProvider).can(TaxPerm.tdsManage);
    return AsyncValueView<TdsChallan>(
      value: value,
      onRetry: () => ref.invalidate(tdsChallanProvider(id)),
      data: (c) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: c.number,
            subtitle: 'TDS challan',
            actions: [
              OutlinedButton.icon(
                onPressed: () => context.go('/tds'),
                icon: const Icon(Icons.arrow_back),
                label: const Text('TDS'),
              ),
              if (manage && !c.cancelled)
                FilledButton.tonalIcon(
                  onPressed: () => _cancel(context, ref),
                  icon: const Icon(Icons.cancel_outlined),
                  label: const Text('Cancel challan'),
                ),
            ],
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              children: [
                if (c.cancelled)
                  WarningsBanner(
                    [c.cancelReason ?? ''],
                    title: 'This challan was cancelled',
                    error: true,
                  ),
                SectionCard(
                  child: Wrap(
                    spacing: 32,
                    runSpacing: 12,
                    children: [
                      LabeledValue('Deposit date', formatDate(c.depositDate)),
                      LabeledValue('BSR code', c.bsrCode),
                      LabeledValue('Challan serial', c.challanSerial),
                      LabeledValue('Paid from', c.paidFromAccountName),
                      LabeledValue('Tax', formatMoney(c.taxAmount)),
                      LabeledValue('Interest', formatMoney(c.interest)),
                      LabeledValue('Late fee', formatMoney(c.lateFee)),
                      LabeledValue('Total', formatMoney(c.total)),
                      LabeledValue('Recorded by', c.createdByName),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [StatusPill(c.status)],
                      ),
                    ],
                  ),
                ),
                const ReportSectionTitle('Deductions covered'),
                for (final d in c.deductions)
                  Card(
                    margin: const EdgeInsets.only(bottom: 6),
                    child: ListTile(
                      onTap: d.sourcePath == null
                          ? null
                          : () => context.go(d.sourcePath!),
                      title: Text('${d.partyName} · ${d.sectionCode}'),
                      subtitle: Text('${d.number} · ${formatDate(d.date)}'),
                      trailing: Text(
                        formatAmount(d.amount),
                        style: tabularFigures,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
