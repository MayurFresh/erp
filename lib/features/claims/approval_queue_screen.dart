import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/money_text.dart';
import '../../widgets/states.dart';
import 'claims_repository.dart';
import 'claims_widgets.dart';

/// `/claims/approvals`: submitted claims waiting for a decision, and a
/// by-employee, category or month summary below.
class ApprovalQueueScreen extends ConsumerStatefulWidget {
  const ApprovalQueueScreen({super.key});

  @override
  ConsumerState<ApprovalQueueScreen> createState() => _ApprovalQueueState();
}

class _ApprovalQueueState extends ConsumerState<ApprovalQueueScreen> {
  String _status = 'submitted';
  String _by = 'employee';

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(claimsListProvider((mine: false, status: _status)));
    final summary = ref.watch(claimsSummaryProvider(_by));
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(title: 'Claim approvals'),
        FilterBar(
          children: [
            SegmentedButton<String>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 'submitted', label: Text('To decide')),
                ButtonSegment(value: 'approved', label: Text('To pay')),
                ButtonSegment(value: 'paid', label: Text('Paid')),
              ],
              selected: {_status},
              onSelectionChanged: (s) => setState(() => _status = s.first),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
            children: [
              list.when(
                loading: () => const SizedBox(height: 120, child: LoadingView()),
                error: (e, _) => ErrorView(error: e),
                data: (claims) => claims.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.all(Space.lg),
                        child: EmptyView(message: 'Nothing here.'),
                      )
                    : Column(
                        children: [
                          for (final c in claims)
                            ClaimTile(claim: c, showEmployee: true, onTap: () => context.go('/claims/${c.id}')),
                        ],
                      ),
              ),
              const SizedBox(height: Space.lg),
              Text('Claims by', style: theme.textTheme.titleMedium),
              const SizedBox(height: Space.sm),
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 'employee', label: Text('Employee')),
                  ButtonSegment(value: 'category', label: Text('Category')),
                  ButtonSegment(value: 'month', label: Text('Month')),
                ],
                selected: {_by},
                onSelectionChanged: (s) => setState(() => _by = s.first),
              ),
              const SizedBox(height: Space.sm),
              summary.when(
                loading: () => const SizedBox(height: 80, child: LoadingView()),
                error: (e, _) => ErrorView(error: e),
                data: (rows) => Column(
                  children: [
                    for (final r in rows)
                      ListTile(
                        title: Text(r.label),
                        subtitle: Text('${r.count} claim${r.count == 1 ? '' : 's'}'),
                        trailing: MoneyText(r.total),
                      ),
                    if (rows.isEmpty) const ListTile(title: Text('No claims in this period')),
                  ],
                ),
              ),
              const SizedBox(height: Space.lg),
            ],
          ),
        ),
      ],
    );
  }
}
