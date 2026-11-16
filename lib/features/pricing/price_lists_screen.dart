import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../auth/session.dart';
import 'pricing_models.dart';
import 'pricing_repository.dart';

String priceListRule(PriceList l) {
  if (!l.isPercent) return 'Listed item prices';
  final p = l.adjustPct;
  if (p == 0) return 'Item price';
  return p < 0
      ? '${formatPercent(-p)} below item price'
      : '${formatPercent(p)} above item price';
}

/// Named price lists (Wholesale, Dealer, Retail) and the link to schemes.
class PriceListsScreen extends ConsumerWidget {
  const PriceListsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canEdit = ref.watch(permissionsProvider).can(Perm.pricingManage);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PageHeader(
          title: 'Price lists',
          subtitle: 'Rates by customer group, with quantity slabs',
          actions: [
            OutlinedButton(
              onPressed: () => context.go('/price-schemes'),
              child: const Text('Schemes'),
            ),
            if (canEdit)
              FilledButton.icon(
                onPressed: () => context.go('/price-lists/new'),
                icon: const Icon(Icons.add),
                label: const Text('New price list'),
              ),
          ],
        ),
        Expanded(
          child: AsyncValueView(
            value: ref.watch(priceListsProvider),
            onRetry: () => ref.invalidate(priceListsProvider),
            data: (lists) {
              if (lists.isEmpty) {
                return const EmptyView(
                  message: 'No price lists yet. Add one for wholesale or dealer customers.',
                );
              }
              final gutter = pageGutter(context);
              return ListView.separated(
                padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 8),
                itemCount: lists.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final l = lists[i];
                  return ListTile(
                    minVerticalPadding: 12,
                    title: Text(l.name),
                    subtitle: Text(
                      [
                        priceListRule(l),
                        '${l.itemCount} item prices',
                        '${l.partyCount} customers',
                        if (l.validFrom != null || l.validTo != null)
                          '${l.validFrom ?? 'any time'} to ${l.validTo ?? 'no end'}',
                      ].join(' · '),
                    ),
                    trailing: StatusChip(
                      l.isActive ? 'active' : 'inactive',
                      label: l.isActive ? 'Active' : 'Inactive',
                    ),
                    onTap: () => context.go('/price-lists/${l.id}'),
                  );
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
