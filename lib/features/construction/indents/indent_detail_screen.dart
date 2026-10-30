import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/money.dart';
import '../../../widgets/form_support.dart';
import '../../../widgets/layout.dart';
import '../../../widgets/states.dart';
import '../../auth/session.dart';
import '../common/c_perms.dart';
import '../common/c_revisions.dart';
import '../common/c_widgets.dart';
import '../data/construction_repository.dart';
import '../models/material_models.dart';

/// Material indent detail and its draft → review → fulfilment lifecycle.
class IndentDetailScreen extends ConsumerStatefulWidget {
  const IndentDetailScreen({super.key, required this.indentId});

  final String indentId;

  @override
  ConsumerState<IndentDetailScreen> createState() => _IndentDetailScreenState();
}

class _IndentDetailScreenState extends ConsumerState<IndentDetailScreen> {
  bool _busy = false;

  Future<void> _action(Future<Indent> Function() action, String done) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.bumpC(const [CKind.indents]);
      ref.invalidate(indentProvider(widget.indentId));
      if (mounted) showSuccess(context, done);
    } catch (error) {
      if (mounted) showErrorSnackBar(context, error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _approve(Indent indent) async {
    final approved = await _approvalDialog(indent);
    if (approved == null || !mounted) return;
    await _action(
      () => ref
          .read(constructionRepositoryProvider)
          .approveIndent(indent.id, approved),
      '${indent.number} approved',
    );
  }

  Future<void> _reject(Indent indent) async {
    final reason = await _reasonDialog();
    if (reason == null || !mounted) return;
    await _action(
      () => ref
          .read(constructionRepositoryProvider)
          .rejectIndent(indent.id, reason),
      '${indent.number} rejected',
    );
  }

  Future<void> _close(Indent indent) async {
    final ok = await confirm(
      context,
      title: 'Close indent',
      message:
          'Close ${indent.number}? Any remaining quantity will no longer be '
          'tracked against this indent.',
      confirmLabel: 'Close indent',
    );
    if (!ok || !mounted) return;
    await _action(
      () => ref.read(constructionRepositoryProvider).closeIndent(indent.id),
      '${indent.number} closed',
    );
  }

  Future<Map<String, double>?> _approvalDialog(Indent indent) =>
      showDialog<Map<String, double>>(
        context: context,
        builder: (_) => _ApproveDialog(indent: indent),
      );

  Future<String?> _reasonDialog() => showReasonDialog(
    context,
    title: 'Reject indent',
    message:
        'Tell the requester what needs to be changed before this indent '
        'is submitted again.',
    confirmLabel: 'Reject indent',
  );

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final session = ref.watch(sessionProvider).value;
    return CGate(
      anyOf: const [CPerm.indentsView],
      child: AsyncValueView(
        value: ref.watch(indentProvider(widget.indentId)),
        onRetry: () => ref.invalidate(indentProvider(widget.indentId)),
        data: (indent) {
          final creator = session?.user?.id == indent.createdBy?.id;
          final editable =
              (indent.status == IndentStatus.draft ||
                  indent.status == IndentStatus.rejected) &&
              ((perms.can(CPerm.indentsCreate) && creator) ||
                  perms.can(CPerm.indentsApprove));
          final canSubmit =
              (indent.status == IndentStatus.draft ||
                  indent.status == IndentStatus.rejected) &&
              perms.can(CPerm.indentsCreate);
          final canReview =
              indent.status == IndentStatus.submitted &&
              perms.can(CPerm.indentsApprove);
          final canClose =
              indent.status == IndentStatus.approved &&
              (perms.can(CPerm.indentsApprove) ||
                  (perms.can(CPerm.indentsCreate) && creator));
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              PageHeader(
                title: indent.number,
                subtitle: indent.locationName,
                actions: [
                  if (editable)
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy
                          ? null
                          : () => context.go('/indents/${indent.id}/edit'),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Edit indent'),
                    ),
                  if (canSubmit)
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: _busy
                          ? null
                          : () => _action(
                              () => ref
                                  .read(constructionRepositoryProvider)
                                  .submitIndent(indent.id),
                              '${indent.number} submitted',
                            ),
                      icon: const Icon(Icons.send),
                      label: Text(
                        indent.status == IndentStatus.rejected
                            ? 'Resubmit'
                            : 'Submit',
                      ),
                    ),
                  if (canReview) ...[
                    FilledButton.icon(
                      style: bigButton,
                      onPressed: _busy ? null : () => _approve(indent),
                      icon: const Icon(Icons.approval_outlined),
                      label: const Text('Approve'),
                    ),
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : () => _reject(indent),
                      icon: const Icon(Icons.cancel_outlined),
                      label: const Text('Reject'),
                    ),
                  ],
                  if (canClose)
                    OutlinedButton.icon(
                      style: bigOutlinedButton,
                      onPressed: _busy ? null : () => _close(indent),
                      icon: const Icon(Icons.archive_outlined),
                      label: const Text('Close indent'),
                    ),
                ],
              ),
              Expanded(
                child: CPage(
                  maxWidth: 900,
                  children: [
                    SectionCard(
                      title: 'Indent details',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          FactsWrap(
                            facts: [
                              ('Location', indent.locationName),
                              ('Required by', formatDate(indent.requiredBy)),
                              ('Status', indent.status.label),
                              ('Created by', indent.createdBy?.name ?? ''),
                              ('Approved by', indent.approvedBy?.name ?? ''),
                              ('Rejected by', indent.rejectedBy?.name ?? ''),
                              if (_tracksFulfilment(indent.status))
                                (
                                  'Fulfilled',
                                  '${formatQty(roundPct(indent.fulfilmentPct))}%',
                                ),
                            ],
                          ),
                          if (indent.rejectReason != null &&
                              indent.rejectReason!.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Rejection reason',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(indent.rejectReason!),
                          ],
                          if (indent.notes != null &&
                              indent.notes!.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            Text(
                              'Notes',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(indent.notes!),
                          ],
                        ],
                      ),
                    ),
                    SectionCard(
                      title: 'Material requested',
                      child: indent.lines.isEmpty
                          ? const Text('No material lines.')
                          : Column(
                              children: [
                                for (final (i, line)
                                    in indent.lines.indexed) ...[
                                  if (i > 0) const Divider(height: 20),
                                  _LineProgress(
                                    line: line,
                                    showFulfilment: _tracksFulfilment(
                                      indent.status,
                                    ),
                                  ),
                                ],
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

bool _tracksFulfilment(IndentStatus status) =>
    status == IndentStatus.approved || status == IndentStatus.closed;

/// One indent line: requested / approved / fulfilled, wrapping on phones,
/// with a fulfilment bar once approved.
class _LineProgress extends StatelessWidget {
  const _LineProgress({required this.line, required this.showFulfilment});

  final IndentLine line;
  final bool showFulfilment;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unit = line.unit;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(line.itemName, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Wrap(
          spacing: 16,
          runSpacing: 2,
          children: [
            Text('Requested ${formatQty(line.qty)} $unit'),
            if (line.approvedQty != null)
              Text(
                'Approved ${formatQty(line.approvedQty)} $unit',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            if (showFulfilment)
              Text('Received ${formatQty(line.fulfilledQty)} $unit'),
          ],
        ),
        if (showFulfilment) ...[
          const SizedBox(height: 6),
          PctBar(line.fulfilmentPct),
        ],
      ],
    );
  }
}

/// Approved quantity per line (prefilled with the request); owns its
/// controllers so they outlive the closing animation.
class _ApproveDialog extends StatefulWidget {
  const _ApproveDialog({required this.indent});

  final Indent indent;

  @override
  State<_ApproveDialog> createState() => _ApproveDialogState();
}

class _ApproveDialogState extends State<_ApproveDialog> {
  late final Map<String, TextEditingController> _controllers = {
    for (final line in widget.indent.lines)
      line.id: TextEditingController(text: formatPlain(line.qty)),
  };
  final Map<String, String> _errors = {};

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _submit() {
    final approved = <String, double>{};
    _errors.clear();
    for (final line in widget.indent.lines) {
      final qty = double.tryParse(_controllers[line.id]!.text.trim());
      if (qty == null || qty < 0) {
        _errors[line.id] = 'Enter 0 or more';
      } else if (qty > line.qty + 0.0005) {
        _errors[line.id] = 'At most ${formatQty(line.qty)}';
      } else {
        approved[line.id] = qty;
      }
    }
    if (_errors.isNotEmpty) {
      setState(() {});
      return;
    }
    Navigator.of(context).pop(approved);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Approve material'),
    scrollable: true,
    content: SizedBox(
      width: 520,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Reduce a quantity if only part of the request is approved.',
          ),
          const SizedBox(height: 12),
          for (final line in widget.indent.lines) ...[
            Text(
              '${line.itemName} · requested ${formatQty(line.qty)} '
              '${line.unit}',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            TextField(
              controller: _controllers[line.id],
              keyboardType: decimalKeyboard,
              inputFormatters: [decimalInput(decimals: 3)],
              decoration: InputDecoration(
                labelText: 'Approved quantity',
                suffixText: line.unit,
                errorText: _errors[line.id],
              ),
            ),
            const SizedBox(height: 12),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _submit, child: const Text('Approve')),
    ],
  );
}
