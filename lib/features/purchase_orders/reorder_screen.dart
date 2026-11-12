import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/money.dart';
import '../../core/providers.dart';
import '../../widgets/form_support.dart';
import '../../core/permissions.dart';
import '../../widgets/layout.dart';
import '../../widgets/states.dart';
import '../auth/session.dart';
import '../locations/location_filter.dart';
import '../parties/party_model.dart';
import '../parties/party_picker.dart';
import 'po_models.dart';
import 'po_repository.dart';

class _Pick {
  _Pick(this.s)
    : qty = TextEditingController(text: formatPlain(s.suggestedQty)),
      vendorId = s.lastVendorId,
      vendorName = s.lastVendorName;

  final ReorderSuggestion s;
  final TextEditingController qty;
  bool selected = false;
  String? vendorId;
  String? vendorName;

  double get qtyValue => parseNumber(qty.text) ?? 0;
  bool get ready => qtyValue > 0 && vendorId != null;
}

/// Items at or below their reorder level, with the quantity to order up to
/// twice the level. Select rows and create draft purchase orders per vendor.
class ReorderScreen extends ConsumerStatefulWidget {
  const ReorderScreen({super.key});

  @override
  ConsumerState<ReorderScreen> createState() => _ReorderState();
}

class _ReorderState extends ConsumerState<ReorderScreen> {
  String? _locationId;
  final Map<String, _Pick> _picks = {};
  bool _creating = false;

  _Pick _pickFor(ReorderSuggestion s) =>
      _picks.putIfAbsent(s.key, () => _Pick(s));

  @override
  void dispose() {
    for (final p in _picks.values) {
      p.qty.dispose();
    }
    super.dispose();
  }

  Future<void> _chooseVendor(_Pick p) async {
    final party = await pickParty(context, ref, type: PartyType.vendor);
    if (party == null) return;
    if (mounted) {
      setState(() {
        p.vendorId = party.id;
        p.vendorName = party.name;
      });
    }
  }

  Future<void> _create(List<ReorderSuggestion> all) async {
    final chosen = [
      for (final s in all)
        if (_pickFor(s).selected) _pickFor(s),
    ];
    if (chosen.isEmpty) return;
    if (chosen.any((p) => !p.ready)) {
      showInfoSnackBar(
        context,
        'Each selected item needs a quantity and a vendor.',
      );
      return;
    }
    setState(() => _creating = true);
    try {
      final orders = await ref.read(poRepositoryProvider).createFromSuggestions(
        [
          for (final p in chosen)
            {
              'itemId': p.s.itemId,
              'locationId': p.s.locationId,
              'qty': p.qtyValue,
              'partyId': p.vendorId,
            },
        ],
      );
      ref.bump(poKinds);
      if (!mounted) return;
      showInfoSnackBar(
        context,
        orders.length == 1
            ? 'Draft order ${orders.single.number ?? ''} created'
            : '${orders.length} draft orders created',
      );
      context.go('/purchase-orders');
    } catch (e) {
      if (mounted) showErrorSnackBar(context, e);
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canManage = ref
        .watch(permissionsProvider)
        .can(Perm.purchaseOrdersManage);
    final value = ref.watch(reorderSuggestionsProvider(_locationId));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PageHeader(
          title: 'Reorder suggestions',
          subtitle:
              'Stock on hand, less reserved, plus open orders is at or below '
              'the reorder level.',
        ),
        FilterBar(
          children: [
            LocationFilter(
              value: _locationId,
              onChanged: (id) => setState(() => _locationId = id),
            ),
          ],
        ),
        Expanded(
          child: AsyncValueView<List<ReorderSuggestion>>(
            value: value,
            onRetry: () =>
                ref.invalidate(reorderSuggestionsProvider(_locationId)),
            data: (items) {
              if (items.isEmpty) {
                return const EmptyView(
                  icon: Icons.inventory_2_outlined,
                  message: 'Nothing to reorder. Every item is above its level.',
                );
              }
              final selected = items.where((s) => _pickFor(s).selected).length;
              return Column(
                children: [
                  Expanded(
                    child: ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, i) => _SuggestionCard(
                        pick: _pickFor(items[i]),
                        canManage: canManage,
                        onChanged: () => setState(() {}),
                        onVendor: () => _chooseVendor(_pickFor(items[i])),
                      ),
                    ),
                  ),
                  if (canManage)
                    Material(
                      elevation: 2,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Wrap(
                          alignment: WrapAlignment.spaceBetween,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 8,
                          children: [
                            Text('$selected selected'),
                            BusyButton(
                              busy: _creating,
                              onPressed: selected == 0
                                  ? null
                                  : () => _create(items),
                              label: 'Create purchase orders',
                              icon: Icons.add_shopping_cart,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.pick,
    required this.canManage,
    required this.onChanged,
    required this.onVendor,
  });

  final _Pick pick;
  final bool canManage;
  final VoidCallback onChanged;
  final VoidCallback onVendor;

  @override
  Widget build(BuildContext context) {
    final s = pick.s;
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (canManage)
                  Checkbox(
                    value: pick.selected,
                    onChanged: (v) {
                      pick.selected = v ?? false;
                      onChanged();
                    },
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.itemName, style: theme.textTheme.titleSmall),
                      Text(
                        [if (s.sku != null) s.sku!, s.locationName].join(' · '),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'On hand ${formatQty(s.onHand)} · reserved '
                        '${formatQty(s.reserved)} · on order '
                        '${formatQty(s.openPoQty)} · level '
                        '${formatQty(s.reorderLevel)} ${s.unit}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (canManage && pick.selected) ...[
              const SizedBox(height: 12),
              FormRow(
                children: [
                  TextFormField(
                    controller: pick.qty,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    inputFormatters: const [
                      NumberInputFormatter(decimals: 3, max: kMaxQty),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Order quantity (${s.unit})',
                    ),
                    onChanged: (_) => onChanged(),
                  ),
                  OutlinedButton.icon(
                    onPressed: onVendor,
                    icon: const Icon(Icons.storefront_outlined),
                    label: Text(pick.vendorName ?? 'Choose vendor'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
