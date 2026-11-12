import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate, showSuccess;
import 'donations_home_screen.dart' show donationViewPerms, printReceipt;
import 'funds_models.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

/// `/donations/receipts`: every receipt, with reprint and cancel.
class ReceiptsScreen extends ConsumerStatefulWidget {
  const ReceiptsScreen({super.key});

  @override
  ConsumerState<ReceiptsScreen> createState() => _ReceiptsScreenState();
}

class _ReceiptsScreenState extends ConsumerState<ReceiptsScreen> {
  String _q = '';

  Future<void> _print(Donation d) async {
    try {
      await printReceipt(ref, d.id);
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  Future<void> _cancel(Donation d) async {
    final reason = await showFormDialog<String>(
      context: context,
      builder: (_) => const _ReasonDialog(),
    );
    if (reason == null) return;
    try {
      await ref.read(fundsRepositoryProvider).cancelDonation(d.id, reason);
      ref.bumpFunds();
      if (mounted) showSuccess(context, '${d.receiptNo} cancelled');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final manage = ref.watch(permissionsProvider).can(Perm.donationsManage);
    return CGate(
      anyOf: donationViewPerms,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Donation receipts'),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
            child: SearchField(
              hintText: 'Receipt number, name or phone',
              onChanged: (v) => setState(() => _q = v),
            ),
          ),
          Expanded(
            child: AsyncValueView<List<Donation>>(
              value: ref.watch(donationsProvider(_q)),
              onRetry: () => ref.invalidate(donationsProvider(_q)),
              data: (list) => list.isEmpty
                  ? const EmptyNote('No receipts found.')
                  : Gutter(
                      children: [
                        for (final d in list)
                          Card(
                            margin: EdgeInsets.zero,
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                key: ValueKey('receipt-${d.id}'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${d.receiptNo}  ${d.donorName}',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleSmall,
                                        ),
                                      ),
                                      Text(
                                        formatAmount(d.amount),
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleSmall,
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '${formatDate(d.date)}  |  ${donationModes[d.mode] ?? d.mode}${d.isCorpus ? '  |  Corpus' : ''}${(d.fundName ?? '').isEmpty ? '' : '  |  ${d.fundName}'}',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      if (d.cancelled)
                                        const StatusChip('cancelled'),
                                      if (d.tax80g &&
                                          d.deductionEligible &&
                                          !d.cancelled)
                                        const Pill('80G'),
                                      if (d.tax80g &&
                                          !d.deductionEligible &&
                                          !d.cancelled)
                                        const Pill('No 80G: cash over 2,000'),
                                      OutlinedButton(
                                        onPressed: () => _print(d),
                                        child: const Text('Print'),
                                      ),
                                      if (manage && !d.cancelled)
                                        TextButton(
                                          onPressed: () => _cancel(d),
                                          child: const Text('Cancel receipt'),
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReasonDialog extends StatefulWidget {
  const _ReasonDialog();

  @override
  State<_ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<_ReasonDialog> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Cancel receipt'),
    content: Form(
      key: _formKey,
      child: TextFormField(
        controller: _reason,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Reason'),
        validator: (v) => requiredField(v, 'Reason'),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Keep receipt'),
      ),
      FilledButton(
        onPressed: () {
          if (validateAndReveal(_formKey)) {
            Navigator.of(context).pop(_reason.text.trim());
          }
        },
        child: const Text('Cancel receipt'),
      ),
    ],
  );
}
