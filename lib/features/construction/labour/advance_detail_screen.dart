import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../common/subcontract_widgets.dart';
import '../data/subcontract_repository.dart';
import '../models/subcontract_models.dart';

/// A labour advance with its recoveries.
class AdvanceDetailScreen extends ConsumerStatefulWidget {
  const AdvanceDetailScreen({super.key, required this.advanceId});

  final String advanceId;

  @override
  ConsumerState<AdvanceDetailScreen> createState() =>
      _AdvanceDetailScreenState();
}

class _AdvanceDetailScreenState extends ConsumerState<AdvanceDetailScreen> {
  bool _busy = false;

  Future<void> _cancel(LabourAdvance advance) async {
    final reason = await showReasonDialog(
      context,
      title: 'Cancel advance',
      message:
          'Cancel ${advance.number}? The payment is reversed and the '
          'worker’s advance balance drops by ${formatMoney(advance.amount)}.',
      confirmLabel: 'Cancel advance',
      cancelLabel: 'Keep it',
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref
          .read(subcontractRepositoryProvider)
          .cancelLabourAdvance(advance.id, reason);
      ref.bumpC(const [CKind.labourAdvances, CKind.workers]);
      ref.invalidate(labourAdvanceProvider(widget.advanceId));
      if (mounted) showSuccess(context, '${advance.number} cancelled');
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.wagesView],
      child: AsyncValueView(
        value: ref.watch(labourAdvanceProvider(widget.advanceId)),
        onRetry: () => ref.invalidate(labourAdvanceProvider(widget.advanceId)),
        data: (a) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: a.number,
              subtitle: a.workerName,
              actions: [
                labourAdvanceStatusPill(context, a.status),
                if (perms.can(CPerm.wagesPay) && a.canCancel)
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: _busy ? null : () => _cancel(a),
                    icon: const Icon(Icons.cancel_outlined),
                    label: const Text('Cancel advance'),
                  ),
              ],
            ),
            Expanded(
              child: CPage(
                maxWidth: 760,
                children: [
                  SectionCard(
                    title: 'Advance',
                    child: FactsWrap(
                      facts: [
                        ('Worker', a.workerName),
                        ('Site', a.siteName ?? ''),
                        ('Date', formatDate(a.date)),
                        ('Amount', formatMoney(a.amount)),
                        ('Recovered', formatMoney(a.recovered)),
                        ('Balance', formatMoney(a.balance)),
                        ('Paid from', a.paidFromAccountName ?? ''),
                        ('Recorded by', a.createdBy?.name ?? ''),
                        ('Notes', a.notes ?? ''),
                        if (a.cancelledAt != null)
                          ('Cancelled', a.cancelReason ?? ''),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Recoveries',
                    child: (a.recoveries ?? const []).isEmpty
                        ? const Text('Nothing recovered yet.')
                        : Column(
                            children: [
                              for (final r in a.recoveries!)
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: Text(r.wageSheetNumber),
                                  subtitle: Text(formatDate(r.date)),
                                  trailing: Text(formatMoney(r.amount)),
                                  onTap: () => context.go(
                                    '/wage-sheets/${r.wageSheetId}',
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
