import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../../widgets/status_chip.dart';
import '../construction/common/c_widgets.dart' show CGate;
import '../items/item_picker.dart';
import 'bom_screen.dart' show PickerFieldBox;
import 'mfg_perms.dart';
import 'mfg_repository.dart';
import 'mfg_widgets.dart';

const mfgStatuses = <(String, String)>[
  ('', 'All'),
  ('draft', 'Draft'),
  ('released', 'Released'),
  ('in_progress', 'In progress'),
  ('completed', 'Completed'),
  ('cancelled', 'Cancelled'),
];

/// `/manufacturing/orders`: production orders, filtered by status.
class OrdersScreen extends ConsumerWidget {
  const OrdersScreen({super.key, this.status = ''});

  final String status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return CGate(
      anyOf: const [MfgPerm.view],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Production orders',
            actions: [
              if (ref.mfgCan(MfgPerm.orders))
                FilledButton.icon(
                  onPressed: () async {
                    final id = await showFormDialog<String>(context: context, builder: (_) => const _NewOrderDialog());
                    if (id != null && context.mounted) {
                      ref.bumpMfg();
                      context.go('/manufacturing/orders/$id');
                    }
                  },
                  icon: const Icon(Icons.add),
                  label: const Text('New order'),
                ),
            ],
          ),
          FilterBar(
            children: [
              Wrap(
                spacing: Space.sm,
                runSpacing: Space.xs,
                children: [
                  for (final s in mfgStatuses)
                    ChoiceChip(
                      label: Text(s.$2),
                      selected: status == s.$1,
                      onSelected: (_) => context.go(s.$1.isEmpty ? '/manufacturing/orders' : '/manufacturing/orders?status=${s.$1}'),
                    ),
                ],
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(mfgOrdersProvider(status)),
              onRetry: () => ref.invalidate(mfgOrdersProvider(status)),
              data: (orders) {
                if (orders.isEmpty) {
                  return const EmptyView(icon: Icons.precision_manufacturing_outlined, message: 'No production orders here.');
                }
                return ListView.separated(
                  padding: EdgeInsets.all(pageGutter(context)),
                  itemCount: orders.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Space.sm),
                  itemBuilder: (_, i) {
                    final o = orders[i];
                    return Material(
                      color: theme.colorScheme.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: Radii.mediumAll,
                        side: BorderSide(color: context.colors.hairline),
                      ),
                      child: InkWell(
                        borderRadius: Radii.mediumAll,
                        onTap: () => context.go('/manufacturing/orders/${o.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(Space.md),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${o.number} · ${o.itemName}', style: theme.textTheme.titleSmall),
                                    Text(
                                      'Plan ${qtyUnit(o.qty, o.unit)} · made ${formatQty(o.goodQty)}'
                                      '${o.rejectedQty > 0 ? ' · rejected ${formatQty(o.rejectedQty)}' : ''}'
                                      '${o.plannedEnd != null ? ' · due ${formatDate(o.plannedEnd)}' : ''}',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: Space.sm),
                              StatusChip(o.status),
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

class _NewOrderDialog extends ConsumerStatefulWidget {
  const _NewOrderDialog();

  @override
  ConsumerState<_NewOrderDialog> createState() => _NewOrderDialogState();
}

class _NewOrderDialogState extends ConsumerState<_NewOrderDialog> {
  final _key = GlobalKey<FormState>();
  final _qty = TextEditingController();
  final _notes = TextEditingController();
  String? _itemId, _itemName, _unit, _locationId;
  DateTime? _end;
  bool _busy = false;

  Future<void> _pick() async {
    final item = await pickItem(context, ref, stockOnly: true);
    if (item == null) return;
    setState(() {
      _itemId = item.id;
      _itemName = item.name;
      _unit = item.unit;
    });
  }

  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    if (_itemId == null) {
      mfgError(context, 'Choose the item to make.');
      return;
    }
    setState(() => _busy = true);
    String? id;
    final ok = await mfgGuarded(context, () async {
      id = (await ref.read(mfgRepositoryProvider).createOrder({
        'itemId': _itemId,
        'qty': parseNumber(_qty.text),
        'locationId': _locationId,
        if (_end != null) 'plannedEnd': _end!.toIso8601String().substring(0, 10),
        if (trimmedOrNull(_notes.text) != null) 'notes': _notes.text.trim(),
      })).id;
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(id);
    } else {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('New production order'),
    content: SizedBox(
      width: 420,
      child: Form(
        key: _key,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              PickerFieldBox(label: 'Item to make', value: _itemName, onTap: _pick),
              const SizedBox(height: Space.md),
              mfgNumberField(controller: _qty, label: 'Quantity', suffix: _unit),
              const SizedBox(height: Space.md),
              MfgLocationField(value: _locationId, onChanged: (v) => setState(() => _locationId = v), label: 'Make and store at'),
              const SizedBox(height: Space.md),
              InkWell(
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    initialDate: _end ?? DateTime.now(),
                    firstDate: DateTime.now().subtract(const Duration(days: 30)),
                    lastDate: DateTime.now().add(const Duration(days: 730)),
                  );
                  if (d != null) setState(() => _end = d);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Due date', suffixIcon: Icon(Icons.calendar_today_outlined)),
                  child: Text(_end == null ? 'Not set' : formatDate(_end!.toIso8601String())),
                ),
              ),
              const SizedBox(height: Space.md),
              TextFormField(controller: _notes, maxLines: 2, decoration: const InputDecoration(labelText: 'Notes')),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(onPressed: () => Navigator.of(context).maybePop(), child: const Text('Cancel')),
      FilledButton(onPressed: _busy ? null : _save, child: const Text('Create')),
    ],
  );
}
