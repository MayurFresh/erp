import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/design_tokens.dart';
import '../../widgets/kpi_tile.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

/// `/manufacturing`: orders by status, today's output, shortages, job work.
class MfgHomeScreen extends ConsumerWidget {
  const MfgHomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CGate(
      anyOf: const [MfgPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const PageHeader(title: 'Production', subtitle: 'Orders, material and job work'),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(mfgHomeProvider),
              onRetry: () => ref.invalidate(mfgHomeProvider),
              data: (h) => mfgBody(context, [
                LayoutBuilder(
                  builder: (context, c) {
                    final cols = c.maxWidth >= 720 ? 4 : 2;
                    final w = (c.maxWidth - (cols - 1) * Space.md) / cols;
                    Widget tile(String label, int n, String path, {StatusTone tone = StatusTone.neutral}) => SizedBox(
                      width: w,
                      child: KpiTile(label: label, value: '$n', tone: tone, onTap: () => context.go(path)),
                    );
                    return Wrap(
                      spacing: Space.md,
                      runSpacing: Space.md,
                      children: [
                        tile('Draft', h.count('draft'), '/manufacturing/orders?status=draft'),
                        tile('Released', h.count('released'), '/manufacturing/orders?status=released'),
                        tile('In progress', h.count('in_progress'), '/manufacturing/orders?status=in_progress', tone: StatusTone.info),
                        tile('Completed', h.count('completed'), '/manufacturing/orders?status=completed', tone: StatusTone.success),
                        tile('Material short', h.shortagesCount, '/manufacturing/planning',
                            tone: h.shortagesCount > 0 ? StatusTone.warning : StatusTone.neutral),
                        tile('Open job work', h.openJobWork, '/manufacturing/jobwork'),
                      ],
                    );
                  },
                ),
                const SizedBox(height: Space.lg),
                MfgCard(
                  title: 'Output today',
                  child: h.todayOutput.isEmpty
                      ? const Text('Nothing recorded today.')
                      : Column(
                          children: [
                            for (final t in h.todayOutput)
                              MfgKv(
                                t.name,
                                '${qtyUnit(t.goodQty, t.unit)} good'
                                '${t.rejectedQty > 0 ? ', ${qtyUnit(t.rejectedQty, t.unit)} rejected' : ''}',
                              ),
                          ],
                        ),
                ),
                MfgCard(
                  title: 'Go to',
                  child: Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.sm,
                    children: [
                      OutlinedButton(onPressed: () => context.go('/manufacturing/orders'), child: const Text('Production orders')),
                      OutlinedButton(onPressed: () => context.go('/manufacturing/boms'), child: const Text('Bills of materials')),
                      OutlinedButton(onPressed: () => context.go('/manufacturing/planning'), child: const Text('Material planning')),
                      OutlinedButton(onPressed: () => context.go('/manufacturing/jobwork'), child: const Text('Job work')),
                      if (ref.mfgCan(MfgPerm.bom))
                        OutlinedButton(onPressed: () => context.go('/manufacturing/setup'), child: const Text('Setup')),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}
