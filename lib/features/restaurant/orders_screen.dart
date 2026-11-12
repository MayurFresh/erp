import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/app_colors.dart';
import '../../core/design_tokens.dart';
import '../../core/money.dart';
import '../../widgets/form_support.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../construction/common/c_widgets.dart'
    show CGate, bigButton, bigOutlinedButton;
import 'rest_perms.dart';
import 'rest_repository.dart';
import 'rest_widgets.dart';

/// `/restaurant/orders`: takeaway and delivery orders.
class OrdersScreen extends ConsumerStatefulWidget {
  const OrdersScreen({super.key});

  @override
  ConsumerState<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends ConsumerState<OrdersScreen> {
  static const _active = 'active';
  static const _done = 'settled,cancelled';
  String _status = _active;
  RestPoller? _poller;

  @override
  void initState() {
    super.initState();
    _poller = RestPoller(
      ref.read(restPollProvider),
      () => ref.invalidate(restOrdersProvider(_status)),
    );
  }

  @override
  void dispose() {
    _poller?.dispose();
    super.dispose();
  }

  Future<void> _new(String kind) async {
    final id = await showFormDialog<String>(
      context: context,
      builder: (_) => _NewOrderDialog(kind: kind),
    );
    if (id != null && mounted) {
      ref.bumpRest();
      context.go('/restaurant/order/$id');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = context.colors;
    return CGate(
      anyOf: const [RestPerm.orders, RestPerm.manage],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PageHeader(
            title: 'Takeaway and delivery',
            actions: [
              OutlinedButton.icon(
                style: bigOutlinedButton,
                onPressed: () => _new('delivery'),
                icon: const Icon(Icons.delivery_dining_outlined),
                label: const Text('New delivery'),
              ),
              FilledButton.icon(
                style: bigButton,
                onPressed: () => _new('takeaway'),
                icon: const Icon(Icons.takeout_dining_outlined),
                label: const Text('New takeaway'),
              ),
            ],
          ),
          FilterBar(
            children: [
              SegmentedButton<String>(
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: _active, label: Text('Open')),
                  ButtonSegment(value: _done, label: Text('Finished')),
                ],
                selected: {_status},
                onSelectionChanged: (s) => setState(() => _status = s.first),
              ),
            ],
          ),
          Expanded(
            child: AsyncValueView(
              value: ref.watch(restOrdersProvider(_status)),
              onRetry: () => ref.invalidate(restOrdersProvider(_status)),
              data: (orders) {
                if (orders.isEmpty) {
                  return EmptyView(
                    icon: Icons.takeout_dining_outlined,
                    message: _status == _active
                        ? 'No open takeaway or delivery orders.'
                        : 'Nothing finished yet.',
                  );
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
                        side: BorderSide(color: colors.hairline),
                      ),
                      child: InkWell(
                        borderRadius: Radii.mediumAll,
                        onTap: () => context.go('/restaurant/order/${o.id}'),
                        child: Padding(
                          padding: const EdgeInsets.all(Space.md),
                          child: Row(
                            children: [
                              Icon(
                                o.kind == 'delivery'
                                    ? Icons.delivery_dining_outlined
                                    : Icons.takeout_dining_outlined,
                              ),
                              const SizedBox(width: Space.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      (o.customerName ?? '').isEmpty
                                          ? o.number
                                          : '${o.customerName} · ${o.number}',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall,
                                    ),
                                    Text(
                                      [
                                        o.kind == 'delivery'
                                            ? 'Delivery'
                                            : 'Takeaway',
                                        if ((o.customerPhone ?? '').isNotEmpty)
                                          o.customerPhone!,
                                        '${o.itemCount} item${o.itemCount == 1 ? '' : 's'}',
                                        ageText(o.createdAt),
                                      ].where((s) => s.isNotEmpty).join(' · '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                            color: theme
                                                .colorScheme
                                                .onSurfaceVariant,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                              if (o.readyLines > 0)
                                Padding(
                                  padding: const EdgeInsets.only(
                                    right: Space.sm,
                                  ),
                                  child: StatusTag(
                                    '${o.readyLines} ready',
                                    bg: colors.successContainer,
                                    fg: colors.onSuccessContainer,
                                  ),
                                ),
                              Text(
                                formatMoney(o.amount),
                                style: theme.textTheme.titleSmall,
                              ),
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
  const _NewOrderDialog({required this.kind});

  final String kind;

  @override
  ConsumerState<_NewOrderDialog> createState() => _NewOrderDialogState();
}

class _NewOrderDialogState extends ConsumerState<_NewOrderDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _phone = TextEditingController();
  final _address = TextEditingController();
  bool _saving = false;

  bool get _delivery => widget.kind == 'delivery';

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _address.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final order = await ref.read(restaurantRepositoryProvider).createOrder({
        'kind': widget.kind,
        'customerName': ?trimmedOrNull(_name.text),
        'customerPhone': ?trimmedOrNull(_phone.text),
        if (_delivery) 'deliveryAddress': ?trimmedOrNull(_address.text),
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
    title: Text(_delivery ? 'New delivery order' : 'New takeaway order'),
    scrollable: true,
    content: SizedBox(
      width: 380,
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              controller: _name,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Guest name'),
            ),
            const SizedBox(height: Space.md),
            TextFormField(
              controller: _phone,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: _delivery ? 'Phone' : 'Phone (optional)',
              ),
              validator: _delivery ? (v) => requiredField(v, 'Phone') : null,
            ),
            if (_delivery) ...[
              const SizedBox(height: Space.md),
              TextFormField(
                controller: _address,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Delivery address',
                ),
                validator: (v) => requiredField(v, 'Address'),
              ),
            ],
          ],
        ),
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
        label: 'Start order',
        icon: Icons.restaurant_menu,
      ),
    ],
  );
}
