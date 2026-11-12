import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton;
import 'rest_models.dart';
import 'rest_perms.dart';
import 'rest_repository.dart';
import 'rest_widgets.dart';

/// `/restaurant/floor`: every table by area with its status and running amount.
class FloorScreen extends ConsumerStatefulWidget {
  const FloorScreen({super.key});

  @override
  ConsumerState<FloorScreen> createState() => _FloorScreenState();
}

class _FloorScreenState extends ConsumerState<FloorScreen> {
  RestPoller? _poller;

  @override
  void initState() {
    super.initState();
    _poller = RestPoller(
      ref.read(restPollProvider),
      () => ref.invalidate(restFloorProvider),
    );
  }

  @override
  void dispose() {
    _poller?.dispose();
    super.dispose();
  }

  Future<void> _open(FloorTable table) async {
    if (table.order != null) {
      context.go('/restaurant/order/${table.order!.id}');
      return;
    }
    final id = await showFormDialog<String>(
      context: context,
      builder: (_) => _OpenTableDialog(table: table),
    );
    if (id != null && mounted) {
      ref.bumpRest();
      context.go('/restaurant/order/$id');
    }
  }

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(permissionsProvider);
    final colors = context.colors;
    return CGate(
      anyOf: const [RestPerm.orders, RestPerm.manage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Tables',
            actions: [
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => context.go('/restaurant/orders'),
                icon: const Icon(Icons.takeout_dining_outlined),
                label: const Text('Takeaway and delivery'),
              ),
              if (perms.can(RestPerm.kitchen) || perms.can(RestPerm.manage))
                OutlinedButton.icon(
                  style: bigOutlinedButton,
                  onPressed: () => context.go('/restaurant/kitchen'),
                  icon: const Icon(Icons.soup_kitchen_outlined),
                  label: const Text('Kitchen'),
                ),
              if (perms.can(RestPerm.manage))
                FilledButton.icon(
                  style: bigButton,
                  onPressed: () => context.go('/restaurant/setup'),
                  icon: const Icon(Icons.grid_view_outlined),
                  label: const Text('Floor setup'),
                ),
            ],
          ),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: pageGutter(context)),
            child: Wrap(
              spacing: Space.md,
              runSpacing: Space.xs,
              children: [
                for (final s in TableStatus.values)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: s.background(colors),
                          border: Border.all(color: s.foreground(colors)),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        s.label,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(restFloorProvider),
              onRetry: () => ref.invalidate(restFloorProvider),
              data: (areas) {
                final shown = [
                  for (final a in areas)
                    if (a.isActive && a.tables.any((t) => t.isActive)) a,
                ];
                if (shown.isEmpty) {
                  return EmptyView(
                    icon: Icons.table_restaurant_outlined,
                    message: perms.can(RestPerm.manage)
                        ? 'No tables yet. Add areas and tables in Floor setup.'
                        : 'No tables yet. Ask a manager to set up the floor.',
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async => ref.refresh(restFloorProvider.future),
                  child: ListView(
                    padding: EdgeInsets.all(pageGutter(context)),
                    children: [
                      for (final area in shown) ...[
                        Padding(
                          padding: const EdgeInsets.only(
                            top: Space.sm,
                            bottom: Space.sm,
                          ),
                          child: Text(
                            area.name,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 168,
                                mainAxisExtent: 112,
                                crossAxisSpacing: Space.sm,
                                mainAxisSpacing: Space.sm,
                              ),
                          itemCount: area.tables
                              .where((t) => t.isActive)
                              .length,
                          itemBuilder: (_, i) {
                            final t = area.tables
                                .where((t) => t.isActive)
                                .toList()[i];
                            return TableTile(table: t, onTap: () => _open(t));
                          },
                        ),
                      ],
                    ],
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

class TableTile extends StatelessWidget {
  const TableTile({super.key, required this.table, required this.onTap});

  final FloorTable table;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final fg = table.status.foreground(colors);
    final order = table.order;
    return Semantics(
      button: true,
      label: 'Table ${table.name}, ${table.status.label}',
      child: Material(
        color: table.status.background(colors),
        shape: RoundedRectangleBorder(
          borderRadius: Radii.largeAll,
          side: BorderSide(color: fg.withValues(alpha: 0.45)),
        ),
        child: InkWell(
          borderRadius: Radii.largeAll,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(Space.md),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: fg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          table.name,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleLarge?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      Icon(Icons.event_seat_outlined, size: 14, color: fg),
                      const SizedBox(width: 2),
                      Text(
                        '${table.seats}',
                        style: theme.textTheme.labelMedium,
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (order == null)
                    Text(
                      'Free',
                      style: theme.textTheme.bodyMedium?.copyWith(color: fg),
                    )
                  else ...[
                    Text(
                      formatMoney(order.amount),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      [
                        table.status == TableStatus.billPrinted
                            ? 'Bill printed'
                            : ageText(order.openedAt),
                        if (order.readyLines > 0) '${order.readyLines} ready',
                        if (order.unsentLines > 0)
                          '${order.unsentLines} unsent',
                      ].where((s) => s.isNotEmpty).join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: fg),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OpenTableDialog extends ConsumerStatefulWidget {
  const _OpenTableDialog({required this.table});

  final FloorTable table;

  @override
  ConsumerState<_OpenTableDialog> createState() => _OpenTableDialogState();
}

class _OpenTableDialogState extends ConsumerState<_OpenTableDialog> {
  final _covers = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _covers.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final order = await ref.read(restaurantRepositoryProvider).createOrder({
        'kind': 'dine_in',
        'tableId': widget.table.id,
        if (_covers.text.trim().isNotEmpty)
          'covers': int.parse(_covers.text.trim()),
      });
      if (mounted) Navigator.of(context).pop(order.id);
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorSnackBar(context, e);
      }
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text('Open table ${widget.table.name}'),
    content: SizedBox(
      width: 360,
      child: TextField(
        controller: _covers,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: 'Guests (optional)',
          helperText: 'Seats: ${widget.table.seats}',
        ),
        onSubmitted: (_) => _save(),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).maybePop(),
        child: const Text('Cancel'),
      ),
      BusyButton(
        busy: _saving,
        onPressed: _save,
        label: 'Open table',
        icon: Icons.restaurant_menu,
      ),
    ],
  );
}
