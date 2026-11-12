import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import 'super_models.dart';
import 'super_repository.dart';
import 'super_widgets.dart';

final superAuditProvider = FutureProvider.autoDispose<List<SuperAuditEntry>>((
  ref,
) {
  ref.watch(superRevisionProvider);
  return ref.watch(superRepositoryProvider).audit();
});

/// `/platform/activity`: what platform admins changed.
class SuperActivityScreen extends ConsumerWidget {
  const SuperActivityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final entries = ref.watch(superAuditProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Activity'),
        Expanded(
          child: AsyncValueView<List<SuperAuditEntry>>(
            value: entries,
            onRetry: () => ref.invalidate(superAuditProvider),
            data: (list) => list.isEmpty
                ? const EmptyView(
                    icon: Icons.history,
                    message: 'No platform changes yet.',
                  )
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(
                      pageGutter(context),
                      Space.xs,
                      pageGutter(context),
                      Space.lg,
                    ),
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (_, i) => AuditTile(list[i]),
                  ),
          ),
        ),
      ],
    );
  }
}

/// One platform audit row.
class AuditTile extends StatelessWidget {
  const AuditTile(this.entry, {super.key});

  final SuperAuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final reason = entry.detail['reason'];
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(superActionLabel(entry.action)),
      subtitle: Text(
        [
          if (entry.tenantName != null) entry.tenantName!,
          'by ${entry.adminName}',
          whenText(entry.createdAt),
          if (reason is String) 'Reason: $reason',
        ].join(' · '),
      ),
    );
  }
}
