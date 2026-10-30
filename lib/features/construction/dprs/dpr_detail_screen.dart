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
import '../common/photo_widgets.dart';
import '../data/construction_repository.dart';
import '../models/dpr_models.dart';

/// Read-only DPR detail, with draft-only edit / submit and approve actions.
class DprDetailScreen extends ConsumerStatefulWidget {
  const DprDetailScreen({super.key, required this.dprId});

  final String dprId;

  @override
  ConsumerState<DprDetailScreen> createState() => _DprDetailScreenState();
}

class _DprDetailScreenState extends ConsumerState<DprDetailScreen> {
  bool _busy = false;

  Future<void> _action(Future<Dpr> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.bumpC(const [CKind.dprs]);
      ref.invalidate(dprProvider(widget.dprId));
      if (mounted) showSuccess(context, done);
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _reject() async {
    final reason = await _reasonDialog();
    if (reason == null || !mounted) return;
    await _action(
      () => ref
          .read(constructionRepositoryProvider)
          .rejectDpr(widget.dprId, reason),
      'Report rejected',
    );
  }

  Future<String?> _reasonDialog() => showReasonDialog(
    context,
    title: 'Reject DPR',
    message:
        'Tell the site team what needs to be corrected before this '
        'report is submitted again.',
    confirmLabel: 'Reject report',
  );

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final session = ref.watch(sessionProvider).value;
    return CGate(
      anyOf: const [CPerm.dprView],
      child: AsyncValueView(
        value: ref.watch(dprProvider(widget.dprId)),
        onRetry: () => ref.invalidate(dprProvider(widget.dprId)),
        data: (dpr) {
          final creator = session?.user?.id == dpr.createdBy?.id;
          // Drafts, and rejected reports so they can be corrected before
          // resubmitting (the server keeps them rejected until then).
          final canEdit =
              (dpr.isDraft || dpr.isRejected) &&
              ((perms.can(CPerm.dprCreate) && creator) ||
                  perms.can(CPerm.dprApprove));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHeader(
                title: 'DPR · ${formatDate(dpr.date)}',
                subtitle: dpr.locationName,
                actions: [
                  if (canEdit)
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy
                          ? null
                          : () => context.go('/dprs/${dpr.id}/edit'),
                      icon: const Icon(Icons.edit_outlined),
                      label: Text(
                        dpr.isRejected ? 'Edit report' : 'Edit draft',
                      ),
                    ),
                  if ((dpr.isDraft || dpr.isRejected) &&
                      perms.can(CPerm.dprCreate))
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: _busy
                          ? null
                          : () => _action(
                              () => ref
                                  .read(constructionRepositoryProvider)
                                  .submitDpr(dpr.id),
                              'Report submitted',
                            ),
                      icon: const Icon(Icons.send),
                      label: Text(dpr.isRejected ? 'Resubmit' : 'Submit'),
                    ),
                  if (dpr.status == DprStatus.submitted &&
                      perms.can(CPerm.dprApprove)) ...[
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: _busy
                          ? null
                          : () => _action(
                              () => ref
                                  .read(constructionRepositoryProvider)
                                  .approveDpr(dpr.id),
                              'Report approved',
                            ),
                      icon: const Icon(Icons.approval_outlined),
                      label: const Text('Approve'),
                    ),
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : _reject,
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Reject'),
                    ),
                  ],
                ],
              ),
              Expanded(
                child: CPage(
                  maxWidth: 900,
                  children: [
                    if (dpr.isRejected)
                      _RejectedBanner(
                        reason: dpr.rejectReason,
                        by: dpr.rejectedBy?.name,
                        at: dpr.rejectedAt,
                      ),
                    SectionCard(
                      title: 'Report',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FactsWrap(
                            facts: [
                              ('Date', formatDate(dpr.date)),
                              ('Site', dpr.locationName),
                              ('Weather', weatherLabel(dpr.weather)),
                              ('Status', dpr.status.label),
                              ('Labour', '${dpr.labourTotal} workers'),
                              (
                                'Equipment',
                                '${formatQty(dpr.equipmentHours)} h',
                              ),
                              ('Created by', dpr.createdBy?.name ?? ''),
                              ('Approved by', dpr.approvedBy?.name ?? ''),
                            ],
                          ),
                          if (dpr.summary != null &&
                              dpr.summary!.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Summary',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(dpr.summary!),
                          ],
                          if (dpr.hindrances != null &&
                              dpr.hindrances!.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Hindrances',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(dpr.hindrances!),
                          ],
                        ],
                      ),
                    ),
                    SectionCard(
                      title: 'Work done',
                      child: dpr.workDone.isEmpty
                          ? const Text('No work entries.')
                          : Column(
                              children: [
                                for (final work in dpr.workDone)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(work.description),
                                    subtitle: work.boqCode == null
                                        ? null
                                        : Text('BOQ ${work.boqCode}'),
                                    trailing: work.qty == null
                                        ? null
                                        : Text(
                                            '${formatQty(work.qty)} ${work.unit ?? ''}',
                                          ),
                                  ),
                              ],
                            ),
                    ),
                    SectionCard(
                      title: 'Labour by trade',
                      child: dpr.labour.isEmpty
                          ? const Text('No labour entries.')
                          : Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                for (final row in dpr.labour)
                                  Pill('${row.label} · ${row.count}'),
                              ],
                            ),
                    ),
                    SectionCard(
                      title: 'Equipment',
                      child: dpr.equipment.isEmpty
                          ? const Text('No equipment entries.')
                          : Column(
                              children: [
                                for (final row in dpr.equipment)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    title: Text(row.name),
                                    trailing: Text('${formatQty(row.hours)} h'),
                                  ),
                              ],
                            ),
                    ),
                    SectionCard(
                      title: 'Photos',
                      child: dpr.photos.isEmpty
                          ? const Text('No photos attached.')
                          : Wrap(
                              spacing: 12,
                              runSpacing: 12,
                              children: [
                                for (final (index, photo) in dpr.photos.indexed)
                                  FileThumb(
                                    fileId: photo.fileId,
                                    size: 120,
                                    onTap: () => showPhotoViewer(
                                      context,
                                      dpr.photos,
                                      index,
                                    ),
                                  ),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Why the approver sent the report back. The creator (or an approver) can
/// correct the report and resubmit it.
class _RejectedBanner extends StatelessWidget {
  const _RejectedBanner({this.reason, this.by, this.at});

  final String? reason;
  final String? by;
  final DateTime? at;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final who = [?by, if (at != null) formatDateTime(at)].join(' · ');
    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      color: scheme.errorContainer,
      child: ListTile(
        leading: Icon(Icons.undo, color: scheme.onErrorContainer),
        title: Text(
          'Rejected${who.isEmpty ? '' : ' by $who'}',
          style: TextStyle(color: scheme.onErrorContainer),
        ),
        subtitle: reason == null
            ? null
            : Text(
                'Reason: $reason',
                style: TextStyle(color: scheme.onErrorContainer),
              ),
      ),
    );
  }
}
