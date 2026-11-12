import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../widgets/layout.dart';
import '../../widgets/search_field.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

/// `/manufacturing/boms`: bills of materials, every version.
class BomListScreen extends ConsumerStatefulWidget {
  const BomListScreen({super.key});

  @override
  ConsumerState<BomListScreen> createState() => _BomListScreenState();
}

class _BomListScreenState extends ConsumerState<BomListScreen> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return CGate(
      anyOf: const [MfgPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Bills of materials',
            actions: [
              if (ref.mfgCan(MfgPerm.bom))
                FilledButton.icon(
                  onPressed: () => context.go('/manufacturing/boms/new'),
                  icon: const Icon(Icons.add),
                  label: const Text('New BOM'),
                ),
            ],
          ),
          FilterBar(children: [SearchField(hintText: 'Search by item', onChanged: (v) => setState(() => _q = v.trim()))]),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(mfgBomsProvider(_q)),
              onRetry: () => ref.invalidate(mfgBomsProvider(_q)),
              data: (boms) {
                if (boms.isEmpty) {
                  return const EmptyView(
                    icon: Icons.account_tree_outlined,
                    message: 'No bills of materials yet.\nA BOM lists what goes into one finished item.',
                  );
                }
                return ListView.separated(
                  padding: EdgeInsets.all(pageGutter(context)),
                  itemCount: boms.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
                  itemBuilder: (_, i) {
                    final b = boms[i];
                    return Material(
                      color: theme.colorScheme.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: Radii.mediumAll,
                        side: BorderSide(color: context.colors.hairline),
                      ),
                      child: InkWell(
                        borderRadius: Radii.mediumAll,
                        onTap: () => context.go('/manufacturing/boms/${b.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(Space.md),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(b.itemName, style: theme.textTheme.titleSmall),
                                    Text(
                                      'Version ${b.version} · makes ${qtyUnit(b.outputQty, b.unit)} · ${b.lineCount} lines',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: Space.sm),
                              StatusChip(b.status),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
