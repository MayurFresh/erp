import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/money.dart';
import '../../../core/providers.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../../documents/document_widgets.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/material_models.dart';
import '../../../widgets/busy.dart';

/// Material issue detail and stock movement record.
class IssueDetailScreen extends ConsumerWidget {
  const IssueDetailScreen({super.key, required this.issueId});

  final String issueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final perms = ref.watch(permissionsProvider);
    return CGate(
      anyOf: const [CPerm.consumptionView],
      child: AsyncValueView(
        value: ref.watch(issueProvider(issueId)),
        onRetry: () => ref.invalidate(issueProvider(issueId)),
        data: (issue) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: issue.number,
              subtitle: '${issue.locationName} · ${formatDate(issue.date)}',
              actions: [
                if (issue.status == IssueStatus.posted &&
                    perms.can(CPerm.consumptionCreate))
                  OutlinedButton.icon(
                    style: bigOutlinedButton,
                    onPressed: () async {
                      final reason = await _cancelDialog(context);
                      if (reason == null || !context.mounted) return;
                      try {
                        await runBlocking(
                          context,
                          () => ref
                              .read(constructionRepositoryProvider)
                              .cancelIssue(issue.id, reason),
                        );
                        ref.bumpC(const [CKind.issues], const [DataKind.stock]);
                        ref.invalidate(issueProvider(issue.id));
                        if (context.mounted) {
                          showSuccess(context, '${issue.number} cancelled');
                        }
                      } catch (error) {
                        if (context.mounted) showErrorSnackBar(context, error);
                      }
                    },
                    icon: const Icon(Icons.undo),
                    label: const Text('Cancel issue'),
                  ),
              ],
            ),
            Expanded(
              child: CPage(
                maxWidth: 900,
                children: [
                  if (issue.isCancelled)
                    CancelledBanner(
                      cancelledAt: issue.cancelledAt,
                      reason: issue.cancelReason,
                    ),
                  SectionCard(
                    title: 'Issue details',
                    child: FactsWrap(
                      facts: [
                        ('Site', issue.locationName),
                        ('Date', formatDate(issue.date)),
                        ('BOQ', issue.boqCode ?? ''),
                        ('Status', issue.status.label),
                        ('Created by', issue.createdBy?.name ?? ''),
                        // Absent without items.view_cost.
                        if (issue.totalValue != null)
                          ('Total value', formatMoney(issue.totalValue)),
                      ],
                    ),
                  ),
                  SectionCard(
                    title: 'Material issued',
                    child: issue.lines.isEmpty
                        ? const Text('No material lines were issued.')
                        : Column(
                            children: [
                              for (final line in issue.lines)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 10),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          line.itemName,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleMedium,
                                        ),
                                      ),
                                      Text(
                                        '${formatQty(line.qty)} ${line.unit}',
                                      ),
                                      const SizedBox(width: 16),
                                      SizedBox(
                                        width: 120,
                                        child: Text(
                                          line.value == null
                                              ? '—'
                                              : formatMoney(line.value),
                                          textAlign: TextAlign.right,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
                  if (issue.notes != null && issue.notes!.isNotEmpty)
                    SectionCard(title: 'Notes', child: Text(issue.notes!)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<String?> _cancelDialog(BuildContext context) => showReasonDialog(
    context,
    title: 'Cancel material issue',
    message:
        'This returns the issued stock to inventory and reverses the '
        'accounting voucher. Enter a reason.',
    confirmLabel: 'Cancel issue',
    cancelLabel: 'Keep issue',
  );
}
