import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'wh_models.dart';
import 'wh_perms.dart';
import 'wh_repository.dart';
import 'wh_widgets.dart';

/// `/warehouse/expiry`: batches that are expired or about to be.
class ExpiryScreen extends ConsumerStatefulWidget {
  const ExpiryScreen({super.key});

  @override
  ConsumerState<ExpiryScreen> createState() => _ExpiryScreenState();
}

class _ExpiryScreenState extends ConsumerState<ExpiryScreen> {
  int _days = 30; // 0 shows only what has expired

  @override
  Widget build(BuildContext context) {
    final loc = ref.watch(whLocationIdProvider);
    return CGate(
      anyOf: const [WhPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(
            title: 'Expiry report',
            subtitle: 'Stock to sell, return or write off',
          ),
          FilterBar(
            children: [
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.sm,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const WhLocationBar(),
                  for (final d in const [
                    (0, 'Expired'),
                    (30, 'Due in 30 days'),
                    (60, 'Due in 60 days'),
                    (90, 'Due in 90 days'),
                  ])
                    ChoiceChip(
                      label: Text(d.$2),
                      selected: _days == d.$1,
                      onSelected: (_) => setState(() => _days = d.$1),
                    ),
                ],
              ),
            ],
          ),
          Expanded(
            child: loc == null
                ? const EmptyView(
                    icon: Icons.warehouse_outlined,
                    message: 'Add a location first.',
                  )
                : AsyncValueView(
                    value: ref.watch(whExpiryProvider('$loc|$_days')),
                    onRetry: () =>
                        ref.invalidate(whExpiryProvider('$loc|$_days')),
                    data: (rows) {
                      if (rows.isEmpty) {
                        return const EmptyView(
                          icon: Icons.event_available_outlined,
                          message: 'No batches expire in this window.',
                        );
                      }
                      return WhTable<WhExpiryRow>(
                        rows: rows,
                        columns: [
                          WhCol('Item', (r) => r.itemName, flex: 3),
                          WhCol('Batch', (r) => r.batchNo, flex: 2),
                          WhCol(
                            'Expiry',
                            (r) => formatDate(r.expiryDate),
                            flex: 2,
                          ),
                          WhCol('Quantity', (r) => formatQty(r.qty), end: true),
                          WhCol('Status', (r) => r.expired ? 'Expired' : 'Due'),
                        ],
                        card: (context, r) => whCardBody(
                          context,
                          r.itemName,
                          [
                            'Batch ${r.batchNo} · expires ${formatDate(r.expiryDate)}',
                            '${formatQty(r.qty)} left',
                          ],
                          trailing: r.expired
                              ? const StatusChip(
                                  'expired',
                                  tone: StatusTone.danger,
                                )
                              : const StatusChip(
                                  'due',
                                  tone: StatusTone.warning,
                                ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
