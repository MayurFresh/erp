import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton;
import 'helpdesk_models.dart';
import 'helpdesk_repository.dart';

StatusTone contractTone(Contract c) => c.status == 'active'
    ? (c.renewalDue ? StatusTone.warning : StatusTone.success)
    : c.status == 'expired'
    ? StatusTone.danger
    : StatusTone.neutral;

/// `/service-contracts`: AMC and service contracts with renewal flags.
class ContractListScreen extends ConsumerStatefulWidget {
  const ContractListScreen({super.key});

  @override
  ConsumerState<ContractListScreen> createState() => _ContractListScreenState();
}

class _ContractListScreenState extends ConsumerState<ContractListScreen> {
  String _status = 'active';

  static const _filters = {
    'active': 'Active',
    'renewal': 'Renewal due',
    'expired': 'Expired',
    '': 'All',
  };

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final data = ref.watch(
      contractListProvider(_status == 'renewal' ? 'active' : _status),
    );
    final gutter = pageGutter(context);
    return CGate(
      anyOf: const [Perm.serviceContractsView, Perm.serviceContractsManage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Service contracts',
            actions: [
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => context.go('/service-contracts/visits'),
                icon: const Icon(Icons.event_outlined),
                label: const Text('Visit calendar'),
              ),
              if (perms.can(Perm.serviceContractsManage))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/service-contracts/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New contract'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: gutter),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final e in _filters.entries)
                  ChoiceChip(
                    label: Text(e.value),
                    selected: _status == e.key,
                    onSelected: (_) => setState(() => _status = e.key),
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView<List<Contract>>(
              value: data,
              onRetry: () => ref.invalidate(contractListProvider),
              data: (all) {
                final list = _status == 'renewal'
                    ? all.where((c) => c.renewalDue).toList()
                    : all;
                if (list.isEmpty) {
                  return const EmptyView(message: 'No contracts here.');
                }
                return ListView.separated(
                  padding: EdgeInsets.all(gutter),
                  itemCount: list.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _ContractTile(contract: list[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ContractTile extends StatelessWidget {
  const _ContractTile({required this.contract});

  final Contract contract;

  @override
  Widget build(BuildContext context) {
    final c = contract;
    final theme = Theme.of(context);
    final end = c.status == 'active'
        ? (c.daysLeft < 0 ? 'ended' : '${c.daysLeft} days left')
        : contractStatusLabel(c.status);
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => context.go('/service-contracts/${c.id}'),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${c.number}  ${c.title}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                    const SizedBox(width: 8),
                    StatusChip(
                      c.status,
                      label: c.renewalDue ? 'Renewal due' : end,
                      tone: contractTone(c),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '${c.partyName}  ·  ${c.startDate} to ${c.endDate}  ·  ${formatMoney(c.value)}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
