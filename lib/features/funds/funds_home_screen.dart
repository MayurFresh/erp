import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart' show CGate, bigButton;
import 'funds_models.dart';
import 'funds_repository.dart';
import 'funds_widgets.dart';

/// `/funds`: budget used by head, funds with balances and sanctions waiting.
class FundsHomeScreen extends ConsumerStatefulWidget {
  const FundsHomeScreen({super.key});

  @override
  ConsumerState<FundsHomeScreen> createState() => _FundsHomeScreenState();
}

class _FundsHomeScreenState extends ConsumerState<FundsHomeScreen> {
  late String _fy = currentFy();

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final entry = perms.canAny(const [Perm.fundsEntry, Perm.fundsManage]);
    return CGate(
      anyOf: const [Perm.fundsView, Perm.fundsEntry, Perm.fundsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Funds and budget',
            actions: [
              FySelector(value: _fy, onChanged: (v) => setState(() => _fy = v)),
              if (entry)
                FilledButton.icon(
                  key: const ValueKey('new-sanction'),
                  style: bigButton,
                  onPressed: () => context.go('/funds/sanctions'),
                  icon: const Icon(Icons.add),
                  label: const Text('New sanction'),
                ),
            ],
          ),
          Expanded(
            child: AsyncValueView<FundsHome>(
              value: ref.watch(fundsHomeProvider(_fy)),
              onRetry: () => ref.invalidate(fundsHomeProvider(_fy)),
              data: (h) => _body(context, h),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, FundsHome h) {
    final t = h.totals;
    return Gutter(
      children: [
        SectionCard(
          child: FigureRow([
            Figure('Budget', formatAmount(t.budget)),
            Figure('Spent', formatAmount(t.actual)),
            Figure('Committed', formatAmount(t.committed)),
            Figure(
              'Available',
              formatAmount(t.available),
              warn: t.available < 0,
            ),
          ]),
        ),
        if (h.pendingReapp > 0)
          SoftNote(
            '${h.pendingReapp} re-appropriation request${h.pendingReapp == 1 ? '' : 's'} waiting for approval.',
          ),
        SectionCard(
          title: 'Budget used by head',
          trailing: TextButton(
            onPressed: () => context.go('/funds/budget'),
            child: const Text('Budget heads'),
          ),
          child: h.heads.isEmpty
              ? const Text(
                  'No budget heads for this year yet. Set them up under Budget heads.',
                )
              : Column(
                  children: [
                    for (final head in h.heads)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: BudgetBar(head: head),
                      ),
                  ],
                ),
        ),
        SectionCard(
          title: 'Funds',
          trailing: TextButton(
            onPressed: () => context.go('/funds/funds'),
            child: const Text('All funds'),
          ),
          child: h.funds.isEmpty
              ? const Text('No funds yet.')
              : Column(
                  children: [
                    for (final f in h.funds)
                      ListTile(
                        key: ValueKey('fund-${f.id}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(f.name),
                        subtitle: Text(
                          'Received ${formatAmount(f.received)}  |  Spent ${formatAmount(f.spent)}',
                        ),
                        trailing: Text(
                          formatAmount(f.balance),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                  ],
                ),
        ),
        SectionCard(
          title: 'Sanctions waiting',
          trailing: TextButton(
            onPressed: () => context.go('/funds/sanctions'),
            child: const Text('Sanctions'),
          ),
          child: h.pending.isEmpty
              ? const Text('Nothing is waiting for approval.')
              : Column(
                  children: [
                    for (final s in h.pending)
                      ListTile(
                        key: ValueKey('pending-${s.id}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          s.purpose,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${s.number}  |  ${s.headCode}  |  ${s.fundName}',
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              formatAmount(s.amount),
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const StatusChip('pending'),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: () => context.go('/funds/spending'),
                child: const Text('Link spending'),
              ),
              OutlinedButton(
                onPressed: () => context.go('/funds/reports'),
                child: const Text('Reports'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
