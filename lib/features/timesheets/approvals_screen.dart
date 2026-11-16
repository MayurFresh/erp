import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/permissions.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton, showSuccess;
import 'timesheet_models.dart';
import 'timesheet_repository.dart';

/// `/timesheets/approvals`: submitted hours, approved or sent back by person.
class ApprovalsScreen extends ConsumerStatefulWidget {
  const ApprovalsScreen({super.key});

  @override
  ConsumerState<ApprovalsScreen> createState() => _ApprovalsScreenState();
}

class _ApprovalsScreenState extends ConsumerState<ApprovalsScreen> {
  final Set<String> _picked = {};
  bool _busy = false;

  Future<void> _act(bool approve, List<TsEntry> all) async {
    final ids = _picked.isEmpty
        ? all.map((e) => e.id).toList()
        : _picked.toList();
    String? reason;
    if (!approve) {
      final c = TextEditingController();
      final ok = await showFormDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Send back for correction'),
          content: TextField(
            controller: c,
            decoration: const InputDecoration(labelText: 'Reason'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).maybePop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Send back'),
            ),
          ],
        ),
      );
      if (ok != true || c.text.trim().isEmpty) return;
      reason = c.text.trim();
    }
    setState(() => _busy = true);
    try {
      final repo = ref.read(timesheetRepositoryProvider);
      if (approve) {
        await repo.approve(ids);
      } else {
        await repo.reject(ids, reason!);
      }
      _picked.clear();
      ref.read(timesheetRevisionProvider.notifier).bump();
      if (mounted) showSuccess(context, approve ? 'Approved' : 'Sent back');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(submittedProvider);
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.timesheetsApprove],
      child: AsyncValueView<List<TsEntry>>(
        value: async,
        onRetry: () => ref.invalidate(submittedProvider),
        data: (list) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PageHeader(
              title: 'Approve hours',
              subtitle: _picked.isEmpty
                  ? 'Nothing selected: the buttons act on all ${list.length}'
                  : '${_picked.length} selected',
              actions: [
                OutlinedButton(
                  style: bigOutlinedButton,
                  onPressed: _busy || list.isEmpty
                      ? null
                      : () => _act(false, list),
                  child: const Text('Send back'),
                ),
                FilledButton(
                  style: bigButton,
                  onPressed: _busy || list.isEmpty
                      ? null
                      : () => _act(true, list),
                  child: const Text('Approve'),
                ),
              ],
            ),
            Expanded(
              child: list.isEmpty
                  ? const EmptyView(
                      message: 'No hours are waiting for approval.',
                    )
                  : ListView(
                      padding: EdgeInsets.symmetric(horizontal: gutter),
                      children: [
                        for (final e in list)
                          CheckboxListTile(
                            value: _picked.contains(e.id),
                            onChanged: (v) => setState(
                              () => v == true
                                  ? _picked.add(e.id)
                                  : _picked.remove(e.id),
                            ),
                            title: Text('${e.userName}: ${e.partyName}'),
                            subtitle: Text(
                              '${e.workDate}  ·  ${e.task}'
                              '${e.billable ? '' : '  ·  not billable'}',
                            ),
                            secondary: Text('${hoursText(e.hours)} h'),
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
